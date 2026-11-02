function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to console and optionally to file.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Message = "",

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Verbose', 'Header')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $false)]
        [string]$ForegroundColor
    )

    $Message = ConvertTo-ScrubbedCliOutput -Text $Message
    $timestamp = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $logEntry = "[$timestamp] [$Level] $Message"

    # Determine color based on level if not specified
    if (-not $ForegroundColor) {
        $ForegroundColor = switch ($Level) {
            'Info'    { 'White' }
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
            'Success' { 'Green' }
            'Verbose' { 'Gray' }
            'Header'  { 'Cyan' }
            default   { 'White' }
        }
    }

    # Write to console
    Write-Host $logEntry -ForegroundColor $ForegroundColor

    # Write to log file if path is set
    if ($script:LogFilePath) {
        try {
            # -WhatIf:$false -- log writes are internal side effects, must run
            # even when the caller invokes a cmdlet with -WhatIf.
            Add-Content -LiteralPath $script:LogFilePath -Value $logEntry -ErrorAction Stop -WhatIf:$false
        }
        catch {
            Write-Warning ("Failed to write to log file ({0}); console logging remains available." -f $_.Exception.GetType().Name) -WarningAction Continue
        }
    }

    # Write errors to separate error log
    if ($Level -eq 'Error' -and $script:ErrorLogPath) {
        try {
            Add-Content -LiteralPath $script:ErrorLogPath -Value $logEntry -ErrorAction Stop -WhatIf:$false
        }
        catch {
            Write-Warning ("Failed to write to error log file ({0}); console logging remains available." -f $_.Exception.GetType().Name) -WarningAction Continue
        }
    }
}
