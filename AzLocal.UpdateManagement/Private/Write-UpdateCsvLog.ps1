function Write-UpdateCsvLog {
    <#
    .SYNOPSIS
        Writes a CSV entry to the Update_Skipped or Update_Started log file.
    .DESCRIPTION
        Writes detailed information about skipped or started updates to CSV files.
        For skipped clusters, includes additional diagnostic information such as
        health check failures and update run error details.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Skipped', 'Started')]
        [string]$LogType,

        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroup = "",

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId = "",

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$UpdateState = "",

        [Parameter(Mandatory = $false)]
        [string]$HealthState = "",

        [Parameter(Mandatory = $false)]
        [string]$HealthCheckFailures = "",

        [Parameter(Mandatory = $false)]
        [string]$LastUpdateErrorStep = "",

        [Parameter(Mandatory = $false)]
        [string]$LastUpdateErrorMessage = ""
    )

    # Defence in depth: route every string field through ConvertTo-SafeCsvField first
    # so that hostile cluster names / error messages from ARM (e.g. starting with '=',
    # '+', '-', '@', or containing CR/LF) cannot trigger formula evaluation when an
    # operator opens this interim CSV in Excel. The exported (final) results path
    # already does this via ConvertTo-SafeCsvCollection; this aligns the diagnostic
    # log path with the same posture.
    $safeClusterName            = ConvertTo-SafeCsvField -Value $ClusterName
    $safeResourceGroup          = ConvertTo-SafeCsvField -Value $ResourceGroup
    $safeSubscriptionId         = ConvertTo-SafeCsvField -Value $SubscriptionId
    $safeMessage                = ConvertTo-SafeCsvField -Value (ConvertTo-ScrubbedCliOutput -Text $Message)
    $safeUpdateState            = ConvertTo-SafeCsvField -Value $UpdateState
    $safeHealthState            = ConvertTo-SafeCsvField -Value $HealthState
    $safeHealthCheckFailures    = ConvertTo-SafeCsvField -Value (ConvertTo-ScrubbedCliOutput -Text $HealthCheckFailures)
    $safeLastUpdateErrorStep    = ConvertTo-SafeCsvField -Value $LastUpdateErrorStep
    $safeLastUpdateErrorMessage = ConvertTo-SafeCsvField -Value (ConvertTo-ScrubbedCliOutput -Text $LastUpdateErrorMessage)

    # Escape quotes in values for CSV
    $escapedClusterName = $safeClusterName -replace '"', '""'
    $escapedResourceGroup = $safeResourceGroup -replace '"', '""'
    $escapedSubscriptionId = $safeSubscriptionId -replace '"', '""'
    $escapedMessage = $safeMessage -replace '"', '""'
    $escapedUpdateState = $safeUpdateState -replace '"', '""'
    $escapedHealthState = $safeHealthState -replace '"', '""'
    $escapedHealthCheckFailures = $safeHealthCheckFailures -replace '"', '""'
    $escapedLastUpdateErrorStep = $safeLastUpdateErrorStep -replace '"', '""'
    $escapedLastUpdateErrorMessage = $safeLastUpdateErrorMessage -replace '"', '""'

    if ($LogType -eq 'Skipped') {
        # Extended format for skipped clusters with diagnostic columns
        $csvLine = "`"$escapedClusterName`",`"$escapedResourceGroup`",`"$escapedSubscriptionId`",`"$escapedMessage`",`"$escapedUpdateState`",`"$escapedHealthState`",`"$escapedHealthCheckFailures`",`"$escapedLastUpdateErrorStep`",`"$escapedLastUpdateErrorMessage`""
        $logPath = $script:UpdateSkippedLogPath
    }
    else {
        # Simple format for started clusters
        $csvLine = "`"$escapedClusterName`",`"$escapedResourceGroup`",`"$escapedSubscriptionId`",`"$escapedMessage`""
        $logPath = $script:UpdateStartedLogPath
    }
    
    if ($logPath) {
        try {
            Add-Content -LiteralPath $logPath -Value $csvLine -Encoding UTF8 -ErrorAction Stop -WhatIf:$false
        }
        catch {
            Write-Warning ("Failed to write to CSV log ({0}); the workload will continue." -f $_.Exception.GetType().Name) -WarningAction Continue
        }
    }
}
