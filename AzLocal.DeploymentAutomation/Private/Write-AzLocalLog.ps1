Function Write-AzLocalLog {
    <#
    .SYNOPSIS

    Internal logging helper for the AzLocal.DeploymentAutomation module.

    .DESCRIPTION

    Writes timestamped, colour-coded messages to the console and optionally to a log file.
    Supports Info, Warning, Error, Success, Debug, and Verbose severity levels.

    Console output uses Write-Host with appropriate colours. Additionally:
    - Verbose-level messages are written via Write-Verbose (visible with -Verbose).
    - Debug-level messages are written via Write-Debug (visible with -Debug).
    - Error-level messages are also written via Write-Error for pipeline consumers.

    When $script:AzLocalLogFilePath is set, all messages are appended to that file
    with a structured format: [Timestamp] [Level] Message

    .PARAMETER Message
    The log message text.

    .PARAMETER Level
    Severity level: Info, Warning, Error, Success, Debug, Verbose. Default: Info.

    .PARAMETER NoTimestamp
    If specified, omits the timestamp prefix (useful for banner/separator lines).

    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false, Position = 1)]
        [ValidateSet("Info", "Warning", "Error", "Success", "Debug", "Verbose")]
        [string]$Level = "Info",

        [Parameter(Mandatory = $false)]
        [switch]$NoTimestamp
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = if ($NoTimestamp) { "" } else { "[$timestamp] " }
    $logLine = "${prefix}[$Level] $Message"
    $consoleMessage = if ($NoTimestamp) { $Message } else { "[$( Get-Date -Format 'HH:mm:ss')] $Message" }

    # Console output with colour coding (suppressed when $script:SuppressConsoleOutput is $true)
    if (-not $script:SuppressConsoleOutput) {
        switch ($Level) {
            "Info"    { Write-Host $consoleMessage -ForegroundColor White }
            "Warning" { Write-Host $consoleMessage -ForegroundColor Yellow }
            "Error"   {
                Write-Host $consoleMessage -ForegroundColor Red
                Write-Error $Message -ErrorAction SilentlyContinue
            }
            "Success" { Write-Host $consoleMessage -ForegroundColor Green }
            "Debug"   { Write-Debug $Message }
            "Verbose" { Write-Verbose $Message }
        }
    } else {
        # Even when console is suppressed, still emit Debug/Verbose for -Debug/-Verbose callers
        switch ($Level) {
            "Debug"   { Write-Debug $Message }
            "Verbose" { Write-Verbose $Message }
        }
    }

    # Log file output (all levels, always written if path is set)
    if ($script:AzLocalLogFilePath) {
        try {
            $logLine | Out-File -FilePath $script:AzLocalLogFilePath -Append -Encoding utf8 -ErrorAction Stop -WhatIf:$false
        } catch {
            # Warn once about log write failure, then disable file logging to avoid repeated warnings
            Write-Host "WARNING: Failed to write to log file '$($script:AzLocalLogFilePath)': $($_.Exception.Message)" -ForegroundColor Yellow
            $script:AzLocalLogFilePath = $null
        }
    }
}
