function Invoke-AzCliJson {
    <#
    .SYNOPSIS
        Internal helper that invokes an arbitrary 'az' subcommand and safely
        parses the JSON response, using the stderr/stdout stream-split pattern
        from Invoke-AzRestJson / Invoke-AzResourceGraphQuery.
    .DESCRIPTION
        v0.7.67: factored out so 'az' calls outside the ARM 'az rest' path
        (notably 'az account show') do not have to repeat the
        2>&1 + Where-Object stream-split + ConvertFrom-Json scaffolding inline.

        Previously, three sites used the unsafe pattern:

            $json = az <cmd> ... 2>&1 | ConvertFrom-Json

        which silently corrupts the JSON when the CLI emits a stderr warning
        line - for example the cp1252 encode warning seen on Windows runners
        with non-UTF-8 console code pages. Even with --only-show-errors the
        warning can leak through some CLI subcommands, and the merged 2>&1
        capture would feed both streams to ConvertFrom-Json. This helper
        always feeds only the string (stdout) stream to ConvertFrom-Json.

        Designed as a thin generic shim for one-off 'az' subcommands. For ARM
        REST calls (POST/GET/PATCH/PUT against management.azure.com), prefer
        Invoke-AzRestJson which adds token-refresh-on-401 retry and body
        handling.
    .PARAMETER Arguments
        The 'az' CLI arguments as a string array. --only-show-errors is
        appended automatically so callers do not need to include it.

        Example: @('account', 'show', '--subscription', $subId)
    .OUTPUTS
        PSCustomObject with:
            Ok    - [bool] $true when CLI exit was 0 and JSON parsed (or empty).
            Data  - parsed JSON object, or $null if the response body was empty.
            Error - [string] - scrubbed error text when Ok=$false, else $null.
    .EXAMPLE
        $res = Invoke-AzCliJson -Arguments @('account', 'show', '--subscription', $id)
        if ($res.Ok) { $res.Data.name } else { "(failed: $($res.Error))" }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    $prevPyEncoding = $env:PYTHONIOENCODING
    try {
        # Best-effort UTF-8 hint (az.cmd's python is -I/-E so this is mostly
        # defence-in-depth; the real fix is --only-show-errors + the post-capture
        # stream split below).
        $env:PYTHONIOENCODING = 'utf-8'

        $azArgs = @($Arguments) + '--only-show-errors'
        # Use Continue so ErrorRecord objects from native az stderr do not become
        # terminating exceptions when the caller sets -ErrorAction Stop. The exit
        # code ($LASTEXITCODE) is the authoritative failure signal; we handle it
        # explicitly below.
        $local:ErrorActionPreference = 'Continue'
        $raw = @(& az @azArgs 2>&1)
        $exit = $LASTEXITCODE

        # Split merged stdout+stderr by stream type. Stderr lines (Python
        # warnings, deprecation notices) surface as ErrorRecord objects when
        # using 2>&1; stdout lines surface as strings. We only pass the string
        # stream to ConvertFrom-Json so a stray stderr warning can never
        # corrupt JSON parsing.
        $stderrLines = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
        $stdoutLines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

        if ($exit -ne 0) {
            return [PSCustomObject]@{
                Ok    = $false
                Data  = $null
                Error = ConvertTo-ScrubbedCliOutput -Text ((($stderrLines + $stdoutLines) | Out-String).Trim())
            }
        }

        $rawText = ($stdoutLines | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($rawText)) {
            return [PSCustomObject]@{ Ok = $true; Data = $null; Error = $null }
        }
        try {
            $parsed = $rawText | ConvertFrom-Json -ErrorAction Stop
            return [PSCustomObject]@{ Ok = $true; Data = $parsed; Error = $null }
        }
        catch {
            $snippet = $rawText.Substring(0, [Math]::Min(500, $rawText.Length))
            return [PSCustomObject]@{
                Ok    = $false
                Data  = $null
                Error = "JSON parse failure: $($_.Exception.Message); raw: $(ConvertTo-ScrubbedCliOutput -Text $snippet)"
            }
        }
    }
    finally {
        if ($null -eq $prevPyEncoding) {
            Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue -WhatIf:$false
        }
        else {
            $env:PYTHONIOENCODING = $prevPyEncoding
        }
    }
}
