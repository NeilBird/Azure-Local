function Invoke-AzLocalItsmHttp {
    <#
    .SYNOPSIS
        Shared HTTP layer for ITSM connector adapters.

    .DESCRIPTION
        Wraps Invoke-RestMethod with:
          - TLS 1.2+ enforced
          - 30s default timeout
          - Honour Retry-After on retryable GET responses
          - Exponential backoff capped at 3 retry attempts (1s, 2s, 4s)
          - Structured Write-Verbose logging with secret redaction

        Returns the parsed response object. Throws on non-retryable errors
        and on retry-exhaustion. Designed to be mocked in tests via
        Mock Invoke-AzLocalItsmHttp.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Uri,
        [Parameter(Mandatory = $false)][hashtable]$Headers,
        [Parameter(Mandatory = $false)][object]$Body,
        [Parameter(Mandatory = $false)][string]$ContentType = 'application/json',
        [Parameter(Mandatory = $false)][ValidateRange(1, 300)][int]$TimeoutSec = 30,
        [Parameter(Mandatory = $false)][ValidateRange(1, 10)][int]$MaxAttempts = 3
    )

    Assert-AzLocalItsmUri -Uri $Uri

    # Enforce TLS 1.2+ once per session (idempotent).
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Verbose "Invoke-AzLocalItsmHttp: could not enable TLS 1.2 on ServicePointManager: $($_.Exception.Message)"
    }

    $params = @{
        Method      = $Method
        Uri         = $Uri
        ContentType = $ContentType
        TimeoutSec  = $TimeoutSec
        ErrorAction = 'Stop'
        MaximumRedirection = 0
    }
    if ($Headers) { $params['Headers'] = $Headers }
    if ($null -ne $Body -and $Method -in 'POST','PUT','PATCH') {
        if ($Body -is [string] -or $Body -is [byte[]]) {
            # Pass-through: caller is responsible for wire format (form-urlencoded
            # string, raw octet-stream bytes for attachments, etc.).
            $params['Body'] = $Body
        } else {
            $params['Body'] = ($Body | ConvertTo-Json -Depth 12 -Compress)
        }
    }

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $redactedUri = $Uri -replace '(client_secret|access_token|password)=[^&]+', '$1=***'
            Write-Verbose "Invoke-AzLocalItsmHttp: attempt $attempt $Method $redactedUri"
            return Invoke-RestMethod @params
        }
        catch {
            $ex = $_.Exception
            $status = 0
            $retryAfter = 0
            if ($ex.PSObject.Properties['Response'] -and $ex.Response) {
                try {
                    $status = [int]$ex.Response.StatusCode
                    $raHeader = $ex.Response.Headers['Retry-After']
                    if ($raHeader) {
                        [int]::TryParse($raHeader, [ref]$retryAfter) | Out-Null
                    }
                }
                catch {
                    Write-Verbose "Invoke-AzLocalItsmHttp: failed to extract status from response: $($_.Exception.Message)"
                }
            }

            $retryable = $Method -eq 'GET' -and $status -in 429,500,502,503,504
            if (-not $retryable -or $attempt -ge $MaxAttempts) {
                throw [System.Exception]::new("ITSM HTTP $Method $redactedUri failed (status=$status, attempt=$attempt): $($ex.Message)", $ex)
            }

            if ($retryAfter -le 0) {
                $retryAfter = [Math]::Pow(2, $attempt - 1)
            }
            $retryAfter = [Math]::Min(60, $retryAfter)
            Write-Verbose "Invoke-AzLocalItsmHttp: status=$status, sleeping ${retryAfter}s before retry (attempt $attempt/$MaxAttempts)."
            Start-Sleep -Seconds $retryAfter
        }
    }
}
