function Invoke-AzRestJson {
    <#
    .SYNOPSIS
        Internal helper that invokes 'az rest' and safely parses the JSON response.
    .DESCRIPTION
        Wraps 'az rest' to centralise error handling, LASTEXITCODE checks, and
        ConvertFrom-Json failure handling. Returns a uniform result object so
        callers no longer have to duplicate the same guard pattern.
        
        Captures stderr via 2>&1 so that non-JSON error text returned by the
        Azure CLI never reaches ConvertFrom-Json, which would otherwise throw
        an uncaught parse error under Set-StrictMode.
    .PARAMETER Uri
        Full ARM URI, e.g. https://management.azure.com/<resourceId>?api-version=...
    .PARAMETER Method
        HTTP method (GET, POST, PATCH, PUT, DELETE). Defaults to GET.
    .PARAMETER Body
        Optional JSON body string. Written to a temp file and passed via @file
        to avoid shell escaping issues.
    .PARAMETER Headers
        Optional extra headers (array of 'Name=Value' strings).
    .OUTPUTS
        PSCustomObject with: Ok (bool), Data (parsed JSON or $null), Error (string or $null)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE', 'HEAD')]
        [string]$Method = 'GET',

        [Parameter(Mandatory = $false)]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [string[]]$Headers
    )

    $tempBodyFile = $null
    $prevPyEncoding = $env:PYTHONIOENCODING
    $resourcePath = try { ([System.Uri]$Uri).AbsolutePath } catch { ([string]$Uri -split '\?')[0] }
    if ($resourcePath.Length -gt 500) { $resourcePath = $resourcePath.Substring(0, 500) + '...' }
    Write-Verbose ("ARM request start: method={0}; path={1}; hasBody={2}." -f $Method, $resourcePath, [bool]($PSBoundParameters.ContainsKey('Body') -and $Body))
    try {
        # Force Azure CLI (Python) to write UTF-8 to stdout/stderr regardless of the
        # host console code page. Without this, any non-cp1252 character in the ARM
        # response (seen in updateRuns error text, localised health messages, etc.)
        # causes the CLI to emit a stderr warning line like
        #   "WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded."
        # which, when captured via 2>&1, gets prepended to the JSON and breaks
        # ConvertFrom-Json. That previously manifested as silently-dropped update
        # runs / available updates for affected clusters.
        #
        # NOTE: az.cmd launches python with the -I (isolated) flag, which causes
        # python to ignore PYTHONIOENCODING / PYTHONUTF8 (-I implies -E). The
        # env-var assignment below is therefore best-effort defence-in-depth and
        # is not, on its own, sufficient. The hard fix is the --only-show-errors
        # CLI flag added to $azArgs below: it suppresses the encode warning at
        # source, keeping the captured stderr/stdout streams clean. Reference:
        # https://github.com/Azure/azure-cli/issues/14426 (jiasli's recommended
        # workaround), https://github.com/Azure/azure-cli/issues/28497
        # (confirmation that az uses python -I and PYTHONIOENCODING is ignored).
        $env:PYTHONIOENCODING = 'utf-8'

        # --only-show-errors mutes ALL CLI-level warnings, including the cp1252
        # encode warning. Characters that fail to encode are still replaced
        # silently, but for ARM cluster/update payloads (timestamps, GUIDs,
        # status enums, resource IDs - all ASCII) this is a non-issue. Any
        # genuine error from the CLI (auth failures, 4xx/5xx ARM responses,
        # invalid args) still surfaces normally.
        $azArgs = @('rest', '--method', $Method, '--uri', $Uri, '--only-show-errors')
        if ($PSBoundParameters.ContainsKey('Body') -and $Body) {
            $tempBodyFile = [System.IO.Path]::GetTempFileName()
            Write-Utf8NoBomFile -Path $tempBodyFile -Content $Body
            $azArgs += @('--body', "@$tempBodyFile")
            if (-not $Headers) { $Headers = @('Content-Type=application/json') }
        }
        if ($Headers) {
            foreach ($h in $Headers) { $azArgs += @('--headers', $h) }
        }

        $raw = & az @azArgs 2>&1
        $exit = $LASTEXITCODE

        # Split merged stdout+stderr by stream type. Stderr lines (Python warnings,
        # deprecation notices) surface as ErrorRecord objects when using 2>&1;
        # stdout lines surface as strings. We only pass the string stream to
        # ConvertFrom-Json so a stray stderr warning can never corrupt JSON.
        $stderrLines = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $stdoutLines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

        # Mid-run token expiry: detect 401 / ExpiredAuthenticationToken in the
        # CLI error text, force a token refresh, and retry the original call
        # exactly once. This avoids breaking long-running fleet operations when
        # the cached access token crosses its expiry during the run.
        if ($exit -ne 0) {
            $errText = (($stderrLines + $stdoutLines) | Out-String)
            $is401 = ($errText -match '\b401\b' -or
                      $errText -match 'ExpiredAuthenticationToken' -or
                      $errText -match 'InvalidAuthenticationToken' -or
                      $errText -match 'AuthenticationFailed')
            if ($is401) {
                Write-Verbose "Invoke-AzRestJson: detected 401 / token-expiry on $Method $Uri; refreshing access token and retrying once."
                try {
                    # Forces the CLI to refresh the cached bearer token.
                    $null = & az account get-access-token --resource 'https://management.azure.com/' --output none 2>&1
                }
                catch {
                    Write-Verbose "Invoke-AzRestJson: token refresh failed: $($_.Exception.Message)"
                }
                $raw = & az @azArgs 2>&1
                $exit = $LASTEXITCODE
                $stderrLines = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $stdoutLines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
            }
        }

        if ($exit -ne 0) {
            $scrubbedError = ConvertTo-ScrubbedCliOutput -Text ((($stderrLines + $stdoutLines) | Out-String).Trim())
            Write-Verbose ("ARM request failed: method={0}; path={1}; exit={2}; error={3}" -f $Method, $resourcePath, $exit, $scrubbedError)
            return [PSCustomObject]@{
                Ok    = $false
                Data  = $null
                Error = $scrubbedError
            }
        }

        # Success path: parse JSON from stdout only (empty body is OK for PATCH/DELETE)
        $rawText = ($stdoutLines | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($rawText)) {
            Write-Verbose ("ARM request completed with empty response: method={0}; path={1}." -f $Method, $resourcePath)
            return [PSCustomObject]@{ Ok = $true; Data = $null; Error = $null }
        }
        try {
            $parsed = $rawText | ConvertFrom-Json -ErrorAction Stop
            $resultCount = if ($parsed -is [System.Array]) {
                @($parsed).Count
            }
            elseif ($parsed.PSObject.Properties['value']) {
                @($parsed.value).Count
            }
            else {
                1
            }
            $resultShape = if ($parsed -is [System.Array]) { 'array' } elseif ($parsed.PSObject.Properties['value']) { 'value collection' } else { 'object' }
            Write-Verbose ("ARM request completed: method={0}; path={1}; shape={2}; resultCount={3}." -f $Method, $resourcePath, $resultShape, $resultCount)
            return [PSCustomObject]@{ Ok = $true; Data = $parsed; Error = $null }
        }
        catch {
            $parseError = "JSON parse failure: $($_.Exception.Message); raw: $(ConvertTo-ScrubbedCliOutput -Text $rawText.Substring(0, [Math]::Min(500, $rawText.Length)))"
            Write-Verbose ("ARM request failed: method={0}; path={1}; error={2}" -f $Method, $resourcePath, $parseError)
            return [PSCustomObject]@{
                Ok    = $false
                Data  = $null
                Error = $parseError
            }
        }
    }
    finally {
        if ($tempBodyFile -and (Test-Path -LiteralPath $tempBodyFile)) {
            Remove-Item -LiteralPath $tempBodyFile -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
        # Restore caller's prior PYTHONIOENCODING (may have been $null/unset).
        if ($null -eq $prevPyEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue -WhatIf:$false
        }
        else {
            $env:PYTHONIOENCODING = $prevPyEncoding
        }
    }
}
