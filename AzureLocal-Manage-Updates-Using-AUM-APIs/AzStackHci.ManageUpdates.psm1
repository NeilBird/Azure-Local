<#
.SYNOPSIS
    Starts updates on one or more Azure Local (Azure Stack HCI) clusters.

.DESCRIPTION
    This function queries Azure Local clusters by name, checks their update status,
    and starts specified updates on clusters that are in "Ready" state with "UpdatesAvailable".
    
    It uses the Azure REST API directly via az rest to call the Update Manager API.
    
    Includes comprehensive logging capabilities with timestamped log files, 
    transcript support, and result export to JSON/CSV.

.PARAMETER ClusterNames
    An array of Azure Local cluster names to update.

.PARAMETER ResourceGroupName
    The resource group containing the clusters. If not specified, the function will 
    search for the cluster across all resource groups in the subscription.

.PARAMETER SubscriptionId
    The Azure subscription ID. If not specified, uses the current az CLI subscription.

.PARAMETER UpdateName
    The specific update name to apply. If not specified, the function will list 
    available updates and prompt for selection or apply the latest available update.

.PARAMETER ApiVersion
    The API version to use. Defaults to "2026-02-01".

.PARAMETER LogPath
    Path to the log file. If not specified, logs are written to the current directory
    with timestamp: AzureLocalUpdate_YYYYMMDD_HHmmss.log

.PARAMETER EnableTranscript
    Enables PowerShell transcript recording to capture all console output.

.PARAMETER ExportResultsPath
    Path to export results. Supports .json and .csv extensions.
    If not specified, no export is created.

.PARAMETER WhatIf
    Shows what would happen if the cmdlet runs. The cmdlet is not run.

.EXAMPLE
    # Start update on a single cluster with logging
    Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG" -LogPath "C:\Logs\update.log"

.EXAMPLE
    # Start updates on multiple clusters with transcript and JSON export
    Start-AzureLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") -EnableTranscript -ExportResultsPath "C:\Logs\results.json"

.EXAMPLE
    # Start a specific update with full logging
    Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -UpdateName "Solution12.2601.1002.38" -LogPath "C:\Logs\update.log" -EnableTranscript

.NOTES
    Author: Neil Bird, Microsoft.
    Requires: Azure CLI (az) installed and authenticated
    API Reference: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/stable/2026-02-01/hci.json
#>

# Script-level variables for logging
$script:LogFilePath = $null
$script:ErrorLogPath = $null

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to console and optionally to file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Verbose', 'Header')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $false)]
        [string]$ForegroundColor
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
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
            Add-Content -Path $script:LogFilePath -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # Silently continue if log file write fails
        }
    }

    # Write errors to separate error log
    if ($Level -eq 'Error' -and $script:ErrorLogPath) {
        try {
            Add-Content -Path $script:ErrorLogPath -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # Silently continue if error log write fails
        }
    }
}

function Start-AzureLocalClusterUpdate {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ClusterNames,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2026-02-01",

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$LogPath,

        [Parameter(Mandatory = $false)]
        [switch]$EnableTranscript,

        [Parameter(Mandatory = $false)]
        [string]$ExportResultsPath
    )

    begin {
        # Initialize logging
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        
        if ($LogPath) {
            $script:LogFilePath = $LogPath
        }
        else {
            $script:LogFilePath = Join-Path -Path (Get-Location) -ChildPath "AzureLocalUpdate_$timestamp.log"
        }
        
        # Create error log path (same location, different suffix)
        $logDir = Split-Path -Path $script:LogFilePath -Parent
        if (-not $logDir) { $logDir = Get-Location }
        $logName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogFilePath)
        $script:ErrorLogPath = Join-Path -Path $logDir -ChildPath "${logName}_errors.log"

        # Ensure log directory exists
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Start transcript if enabled
        $transcriptPath = $null
        if ($EnableTranscript) {
            $transcriptPath = Join-Path -Path $logDir -ChildPath "${logName}_transcript.log"
            try {
                Start-Transcript -Path $transcriptPath -Force | Out-Null
                Write-Log -Message "Transcript started: $transcriptPath" -Level Info
            }
            catch {
                Write-Log -Message "Failed to start transcript: $_" -Level Warning
            }
        }

        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Cluster Update - Started" -Level Header
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Log file: $($script:LogFilePath)" -Level Info
        Write-Log -Message "Error log: $($script:ErrorLogPath)" -Level Info
        Write-Log -Message "Clusters to process: $($ClusterNames -join ', ')" -Level Info

        # Verify Azure CLI is installed and logged in
        try {
            $null = az account show 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI is not logged in. Please run 'az login' first."
            }
            Write-Log -Message "Azure CLI authentication verified" -Level Success
        }
        catch {
            Write-Log -Message "Azure CLI is not installed or not logged in. Please install Azure CLI and run 'az login'." -Level Error
            throw
        }

        # Get subscription ID if not provided
        if (-not $SubscriptionId) {
            $SubscriptionId = (az account show --query id -o tsv)
            Write-Log -Message "Using current subscription: $SubscriptionId" -Level Info
        }

        # Results collection
        $results = @()
    }

    process {
        foreach ($clusterName in $ClusterNames) {
            Write-Log -Message "" -Level Info
            Write-Log -Message "========================================" -Level Header
            Write-Log -Message "Processing cluster: $clusterName" -Level Header
            Write-Log -Message "========================================" -Level Header

            $clusterStartTime = Get-Date

            try {
                # Step 1: Get cluster resource ID
                Write-Log -Message "Step 1: Looking up cluster resource..." -Level Info
                $clusterInfo = Get-AzureLocalClusterInfo -ClusterName $clusterName `
                    -ResourceGroupName $ResourceGroupName `
                    -SubscriptionId $SubscriptionId `
                    -ApiVersion $ApiVersion

                if (-not $clusterInfo) {
                    Write-Log -Message "Cluster '$clusterName' not found." -Level Warning
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotFound"
                        Message       = "Cluster not found"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                Write-Log -Message "Found cluster: $($clusterInfo.id)" -Level Success
                Write-Log -Message "Cluster Status: $($clusterInfo.properties.status)" -Level Info

                # Step 2: Get update summaries to check if updates are available
                Write-Log -Message "Step 2: Retrieving update summary..." -Level Info
                $updateSummary = Get-AzureLocalUpdateSummary -ClusterResourceId $clusterInfo.id `
                    -ApiVersion $ApiVersion

                if (-not $updateSummary) {
                    Write-Log -Message "Unable to retrieve update summary for cluster '$clusterName'." -Level Warning
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "Error"
                        Message       = "Unable to retrieve update summary"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                Write-Log -Message "Update State: $($updateSummary.properties.state)" -Level Info

                # Step 3: Check if cluster is ready for updates
                Write-Log -Message "Step 3: Validating cluster state for updates..." -Level Info
                $validStates = @("UpdateAvailable", "Ready")
                if ($updateSummary.properties.state -notin $validStates) {
                    Write-Log -Message "Cluster '$clusterName' is not in a valid state for updates. Current state: $($updateSummary.properties.state)" -Level Warning
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotReady"
                        Message       = "Cluster state: $($updateSummary.properties.state)"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                # Step 4: List available updates
                Write-Log -Message "Step 4: Listing available updates..." -Level Info
                $availableUpdates = Get-AzureLocalAvailableUpdates -ClusterResourceId $clusterInfo.id `
                    -ApiVersion $ApiVersion

                if (-not $availableUpdates -or $availableUpdates.Count -eq 0) {
                    Write-Log -Message "No updates available for cluster '$clusterName'." -Level Warning
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NoUpdatesAvailable"
                        Message       = "No updates available"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                # Filter updates that are in "Ready" state
                $readyUpdates = $availableUpdates | Where-Object { $_.properties.state -eq "Ready" }
                
                if (-not $readyUpdates -or $readyUpdates.Count -eq 0) {
                    Write-Log -Message "No updates in 'Ready' state for cluster '$clusterName'." -Level Warning
                    Write-Log -Message "Available updates and their states:" -Level Info
                    foreach ($update in $availableUpdates) {
                        Write-Log -Message "  - $($update.name): $($update.properties.state)" -Level Verbose
                    }
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NoReadyUpdates"
                        Message       = "No updates in Ready state"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                Write-Log -Message "Available updates in 'Ready' state:" -Level Success
                foreach ($update in $readyUpdates) {
                    Write-Log -Message "  - $($update.name) (Version: $($update.properties.version), State: $($update.properties.state))" -Level Info
                }

                # Step 5: Select update to apply
                Write-Log -Message "Step 5: Selecting update to apply..." -Level Info
                $selectedUpdate = $null
                if ($UpdateName) {
                    $selectedUpdate = $readyUpdates | Where-Object { $_.name -eq $UpdateName }
                    if (-not $selectedUpdate) {
                        Write-Log -Message "Specified update '$UpdateName' not found or not in Ready state for cluster '$clusterName'." -Level Warning
                        $results += [PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "UpdateNotFound"
                            Message       = "Specified update '$UpdateName' not found or not ready"
                            UpdateName    = $UpdateName
                            StartTime     = $clusterStartTime
                            EndTime       = Get-Date
                            Duration      = $null
                        }
                        continue
                    }
                }
                else {
                    # Select the first ready update (typically the latest)
                    $selectedUpdate = $readyUpdates | Select-Object -First 1
                    Write-Log -Message "Auto-selecting update: $($selectedUpdate.name)" -Level Info
                }

                # Step 6: Apply the update
                Write-Log -Message "Step 6: Applying update..." -Level Info
                if ($PSCmdlet.ShouldProcess("$clusterName", "Apply update '$($selectedUpdate.name)'")) {
                    if (-not $Force) {
                        $confirmation = Read-Host "  Do you want to start update '$($selectedUpdate.name)' on cluster '$clusterName'? (Y/N)"
                        if ($confirmation -notmatch '^[Yy]') {
                            Write-Log -Message "Update skipped by user." -Level Warning
                            $results += [PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "Skipped"
                                Message       = "Update skipped by user"
                                UpdateName    = $selectedUpdate.name
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }
                            continue
                        }
                    }

                    Write-Log -Message "Initiating update '$($selectedUpdate.name)' on cluster '$clusterName'..." -Level Info
                    $applyResult = Invoke-AzureLocalUpdateApply -ClusterResourceId $clusterInfo.id `
                        -UpdateName $selectedUpdate.name `
                        -ApiVersion $ApiVersion

                    $endTime = Get-Date
                    $duration = $endTime - $clusterStartTime

                    if ($applyResult) {
                        Write-Log -Message "Update started successfully!" -Level Success
                        Write-Log -Message "Monitor progress using: Get-AzureLocalUpdateRuns -ClusterName '$clusterName'" -Level Info
                        $results += [PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "UpdateStarted"
                            Message       = "Update initiated successfully"
                            UpdateName    = $selectedUpdate.name
                            StartTime     = $clusterStartTime
                            EndTime       = $endTime
                            Duration      = $duration.ToString("hh\:mm\:ss")
                        }
                    }
                    else {
                        Write-Log -Message "Failed to start update on cluster '$clusterName'." -Level Error
                        $results += [PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "Failed"
                            Message       = "Failed to start update"
                            UpdateName    = $selectedUpdate.name
                            StartTime     = $clusterStartTime
                            EndTime       = $endTime
                            Duration      = $duration.ToString("hh\:mm\:ss")
                        }
                    }
                }
            }
            catch {
                $endTime = Get-Date
                $duration = $endTime - $clusterStartTime
                Write-Log -Message "Error processing cluster '$clusterName': $($_.Exception.Message)" -Level Error
                Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level Error
                $results += [PSCustomObject]@{
                    ClusterName   = $clusterName
                    Status        = "Error"
                    Message       = $_.Exception.Message
                    UpdateName    = $null
                    StartTime     = $clusterStartTime
                    EndTime       = $endTime
                    Duration      = $duration.ToString("hh\:mm\:ss")
                }
            }
        }
    }

    end {
        Write-Log -Message "" -Level Info
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Summary" -Level Header
        Write-Log -Message "========================================" -Level Header
        
        # Display summary statistics
        $totalClusters = $results.Count
        $succeeded = ($results | Where-Object { $_.Status -eq "UpdateStarted" }).Count
        $failed = ($results | Where-Object { $_.Status -in @("Failed", "Error") }).Count
        $skipped = ($results | Where-Object { $_.Status -in @("Skipped", "NotReady", "NoUpdatesAvailable", "NoReadyUpdates", "NotFound", "UpdateNotFound") }).Count

        Write-Log -Message "Total clusters processed: $totalClusters" -Level Info
        Write-Log -Message "Updates started: $succeeded" -Level Success
        if ($failed -gt 0) {
            Write-Log -Message "Failed: $failed" -Level Error
        } else {
            Write-Log -Message "Failed: $failed" -Level Info
        }
        if ($skipped -gt 0) {
            Write-Log -Message "Skipped/Not Ready: $skipped" -Level Warning
        } else {
            Write-Log -Message "Skipped/Not Ready: $skipped" -Level Info
        }

        # Display results table
        Write-Log -Message "" -Level Info
        Write-Log -Message "Detailed Results:" -Level Info
        $results | Format-Table ClusterName, Status, UpdateName, Duration, Message -AutoSize | Out-String -Stream | ForEach-Object { 
            if ($_ -ne "") { Write-Log -Message $_ -Level Info }
        }

        # Export results if path specified
        if ($ExportResultsPath) {
            try {
                $exportDir = Split-Path -Path $ExportResultsPath -Parent
                if ($exportDir -and -not (Test-Path $exportDir)) {
                    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
                }

                $extension = [System.IO.Path]::GetExtension($ExportResultsPath).ToLower()
                
                switch ($extension) {
                    '.json' {
                        $exportData = @{
                            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            TotalClusters = $totalClusters
                            Succeeded     = $succeeded
                            Failed        = $failed
                            Skipped       = $skipped
                            Results       = $results
                        }
                        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ExportResultsPath -Encoding UTF8
                        Write-Log -Message "Results exported to JSON: $ExportResultsPath" -Level Success
                    }
                    '.csv' {
                        $results | Export-Csv -Path $ExportResultsPath -NoTypeInformation -Encoding UTF8
                        Write-Log -Message "Results exported to CSV: $ExportResultsPath" -Level Success
                    }
                    default {
                        # Default to JSON
                        $jsonPath = $ExportResultsPath + ".json"
                        $exportData = @{
                            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            TotalClusters = $totalClusters
                            Succeeded     = $succeeded
                            Failed        = $failed
                            Skipped       = $skipped
                            Results       = $results
                        }
                        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                        Write-Log -Message "Results exported to JSON: $jsonPath" -Level Success
                    }
                }
            }
            catch {
                Write-Log -Message "Failed to export results: $($_.Exception.Message)" -Level Error
            }
        }

        Write-Log -Message "" -Level Info
        Write-Log -Message "Log file saved to: $($script:LogFilePath)" -Level Info
        if ($script:ErrorLogPath -and (Test-Path $script:ErrorLogPath)) {
            $errorContent = Get-Content $script:ErrorLogPath -ErrorAction SilentlyContinue
            if ($errorContent) {
                Write-Log -Message "Error log saved to: $($script:ErrorLogPath)" -Level Warning
            }
        }

        # Stop transcript if it was started
        if ($EnableTranscript) {
            try {
                Stop-Transcript | Out-Null
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] Transcript saved to: $transcriptPath" -ForegroundColor Cyan
            }
            catch {
                # Transcript may not have been started successfully
            }
        }

        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Cluster Update - Completed" -Level Header
        Write-Log -Message "========================================" -Level Header

        return $results
    }
}

function Get-AzureLocalClusterInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2026-02-01"
    )

    if ($ResourceGroupName) {
        # Direct lookup if resource group is known
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/clusters/${ClusterName}?api-version=$ApiVersion"
        
        Write-Verbose "Getting cluster info from: $uri"
        
        $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0) {
            return $result
        }
    }
    else {
        # Search across all resource groups
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.AzureStackHCI/clusters?api-version=$ApiVersion"
        
        Write-Verbose "Searching for cluster across subscription: $uri"
        
        $allClusters = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and $allClusters.value) {
            $cluster = $allClusters.value | Where-Object { $_.name -eq $ClusterName }
            if ($cluster) {
                return $cluster
            }
        }
    }

    return $null
}

function Get-AzureLocalUpdateSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2026-02-01"
    )

    $uri = "https://management.azure.com$ClusterResourceId/updateSummaries/default?api-version=$ApiVersion"
    
    Write-Verbose "Getting update summary from: $uri"
    
    $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0) {
        return $result
    }

    return $null
}

function Get-AzureLocalAvailableUpdates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2026-02-01"
    )

    $uri = "https://management.azure.com$ClusterResourceId/updates?api-version=$ApiVersion"
    
    Write-Verbose "Getting available updates from: $uri"
    
    $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and $result.value) {
        return $result.value
    }

    return @()
}

function Invoke-AzureLocalUpdateApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $true)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2026-02-01"
    )

    $uri = "https://management.azure.com$ClusterResourceId/updates/$UpdateName/apply?api-version=$ApiVersion"
    
    Write-Verbose "Applying update via POST to: $uri"
    
    # The apply endpoint is a POST with empty body
    $result = az rest --method POST --uri $uri 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    elseif ($result -match "202" -or $result -match "Accepted") {
        # 202 Accepted is a valid response for long-running operations
        return $true
    }
    
    Write-Verbose "Apply result: $result"
    return $false
}

function Get-AzureLocalUpdateRuns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2026-02-01"
    )

    # Get subscription ID if not provided
    if (-not $SubscriptionId) {
        $SubscriptionId = (az account show --query id -o tsv)
    }

    # Get cluster info
    $clusterInfo = Get-AzureLocalClusterInfo -ClusterName $ClusterName `
        -ResourceGroupName $ResourceGroupName `
        -SubscriptionId $SubscriptionId `
        -ApiVersion $ApiVersion

    if (-not $clusterInfo) {
        Write-Error "Cluster '$ClusterName' not found."
        return $null
    }

    if ($UpdateName) {
        $uri = "https://management.azure.com$($clusterInfo.id)/updates/$UpdateName/updateRuns?api-version=$ApiVersion"
    }
    else {
        # Get all updates first, then get runs for each
        $updates = Get-AzureLocalAvailableUpdates -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
        $allRuns = @()
        
        foreach ($update in $updates) {
            $uri = "https://management.azure.com$($clusterInfo.id)/updates/$($update.name)/updateRuns?api-version=$ApiVersion"
            $runs = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
            if ($runs.value) {
                $allRuns += $runs.value
            }
        }
        
        return $allRuns
    }

    $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and $result.value) {
        return $result.value
    }

    return @()
}

# Export module members
Export-ModuleMember -Function @(
    'Start-AzureLocalClusterUpdate',
    'Get-AzureLocalClusterInfo',
    'Get-AzureLocalUpdateSummary',
    'Get-AzureLocalAvailableUpdates',
    'Get-AzureLocalUpdateRuns',
    'Write-Log'
)
