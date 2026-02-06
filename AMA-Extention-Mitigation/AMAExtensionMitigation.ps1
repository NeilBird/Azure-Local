##########################################################################################################
<#
.SYNOPSIS
    Author:     Neil Bird, MSFT
    Version:    1.0.0
    Created:    February 6th 2026

.DESCRIPTION
    This script applies the AMA Extension mitigation to stop MetricsExtension.Native.exe if it owned by AMAExtHealthMonitor.exe, 
    and renames the executable to MetricsExtension.Native.exe.org to prevent performance issues on Azure Local clusters with 
    affected AMA Extension Extension version (<=1.40.0.0), fix in 1.41.0.0 and later.
    The script returns a PSObject with the results for each node, including the cluster name, node name, status, message, and AMA Extension version.
    
    It connects to each cluster, retrieves the nodes, and applies the mitigation to each node.
    You can specify clusters either directly via -ClusterName or from a CSV file via -CSVFilePath.

.PARAMETER ClusterName
    Optional. Name of one or more clusters to apply mitigation. Can be a single cluster name or an array of names.
    Use this parameter for quick operations without needing a CSV file.
    Alias: -Cluster

.PARAMETER CSVFilePath
    Optional. Path to the CSV file containing cluster names. If neither -ClusterName nor -CSVFilePath 
    is provided, the script will prompt for CSV input. The CSV file must contain a 'Cluster' column.

.PARAMETER OutputPath
    Optional. Directory path where results CSV will be saved. Defaults to current directory.

.PARAMETER NoConfirm
    Optional. Skip the confirmation prompt before starting the mitigation.

.EXAMPLE
    .\AMAExtensionMitigation.ps1 -ClusterName "MyCluster01"
    Applies mitigation to a single cluster.

.EXAMPLE
    .\AMAExtensionMitigation.ps1 -ClusterName "Cluster01", "Cluster02", "Cluster03" -NoConfirm
    Applies mitigation to multiple clusters without confirmation prompt.

.EXAMPLE
    .\AMAExtensionMitigation.ps1 -CSVFilePath "C:\Clusters\clusters.csv"
    Uses the specified CSV file to get cluster names and applies mitigation.

.EXAMPLE
    .\AMAExtensionMitigation.ps1 -CSVFilePath "C:\Clusters\clusters.csv" -OutputPath "C:\Results" -NoConfirm
    Uses the specified CSV file, saves results to specified directory, without confirmation.

.NOTES
    Requires the FailoverClusters module for Get-Cluster and Get-ClusterNode cmdlets.
    Requires PowerShell 5.1 or later.

    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.
#>
##########################################################################################################

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, ParameterSetName='CSV')]
    [string]$CSVFilePath,

    [Parameter(Mandatory=$false, ParameterSetName='Direct')]
    [Alias('Cluster')]
    [string[]]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = (Get-Location).Path,

    [Parameter(Mandatory=$false)]
    [switch]$NoConfirm
)

#region Helper Functions
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Processing', 'Start', 'Complete')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = switch ($Level) {
        'Info'       { 'White' }
        'Warning'    { 'Yellow' }
        'Error'      { 'Red' }
        'Success'    { 'Green' }
        'Processing' { 'Cyan' }
        'Start'      { 'Magenta' }
        'Complete'   { 'Green' }
    }
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}
#endregion

#region Main Function
function Invoke-AMAExtensionMitigation {
    <#
    .SYNOPSIS
        Applies the AMA Extension mitigation to cluster nodes.
    
    .DESCRIPTION
        Stops MetricsExtension.Native.exe process and renames the file to prevent performance issues.
        Returns PSObjects with the results for each node.
    
    .PARAMETER ClusterList
        Array of cluster names to process.
    
    .OUTPUTS
        PSCustomObject with ClusterName, NodeName, Status, Message properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$ClusterList
    )

    # Results collection
    $Results = [System.Collections.Generic.List[pscustomobject]]::new()

    # Script block to run on each node
    $MitigationScriptBlock = {
        # Function to get MetricsExtension.Native.exe process information
        function Get-AMAProcessInfo {
            $all = Get-CimInstance Win32_Process |
                Select-Object Name, ProcessId, ParentProcessId, ExecutablePath, CommandLine

            $ama = $all | Where-Object { $_.Name -ieq 'MetricsExtension.Native.exe' }

            if (-not $ama) {
                Write-Host "MetricsExtension.Native.exe is not running." -ForegroundColor Yellow
                Return
            }

            foreach ($p in $ama) {
                $parent = $all | Where-Object { $_.ProcessId -eq $p.ParentProcessId } | Select-Object -First 1

                $AMAProcess = [pscustomobject]@{
                    Name             = $p.Name
                    ProcessId        = $p.ProcessId
                    ExecutablePath   = $p.ExecutablePath
                    CommandLine      = $p.CommandLine
                    ParentProcessId  = $p.ParentProcessId
                    ParentName       = if ($parent) { $parent.Name } else { 'exited/not found' }
                    ParentPath       = if ($parent) { $parent.ExecutablePath } else { $null }
                    ParentCommandLine= if ($parent) { $parent.CommandLine } else { $null }
                }
            }

            Return $AMAProcess
        }

        # Main script logic
        $resultMessage = ""
        
        # Call the function to get MetricsExtension.Native.exe process info
        $AMAProcessInfo = Get-AMAProcessInfo

        # Expected / example path for the extension installation folder:
        # 'C:\Packages\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent\1.39.0.0\'

        # Stop the process if it is running, then rename the target file
        # Get the path of the MetricsExtension.Native.exe process
        $AMAExtensionPath = $null
        if($AMAProcessInfo) {
            # Stop the MetricsExtension.Native.exe process only if it is a child of AMAExtHealthMonitor.exe
            ForEach($AMAProcess in $AMAProcessInfo) {
                if($AMAProcess.ParentName -ieq 'AMAExtHealthMonitor.exe') {
                    Write-Host "Found MetricsExtension.Native.exe process (PID: $($AMAProcess.ProcessId))"
                    # Set the extension path from the process info, for the parent path
                    $AMAExtensionPath = $AMAProcess.ParentPath
                    Write-Host "Stopping MetricsExtension.Native.exe (PID: $($AMAProcess.ProcessId)) as it is owned by '$($AMAProcess.ParentName)'..."
                    Stop-Process -Id $AMAProcess.ProcessId -Force -ErrorAction Stop
                    # Wait a few seconds to ensure the process has stopped
                    Start-Sleep -Seconds 3
                } else {
                    Write-Host "MetricsExtension.Native.exe process (PID: $($AMAProcess.ProcessId)) is NOT a child of AMAExtHealthMonitor.exe, Skipping process-stop action." -ForegroundColor Green
                }
            }
        }

        # If process not found, attempt to find the installation folder using Get-ChildItem directory search:
        if(-not $AMAExtensionPath) {
            Write-Host "MetricsExtension.Native.exe process not found, as a child process of AMAExtHealthMonitor.exe" -ForegroundColor Yellow
            # Attempt to find the AMA Extension installation folder via directory search:
            $AMAInstallationFolderSearch = Get-ChildItem -Path "C:\Packages\Plugins\Microsoft.Azure.Monitor.AzureMonitorWindowsAgent" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
            if($AMAInstallationFolderSearch) {
                $AMAInstallationFolder = $AMAInstallationFolderSearch.FullName
                Write-Host "Found AMA Extension installation folder: '$AMAInstallationFolder'"
            } else {
                Write-Host "AMA Extension is not installed on this node - skipping." -ForegroundColor Yellow
                Write-Host "Completed node: $env:COMPUTERNAME"
                Return [pscustomobject]@{
                    NodeName   = $env:COMPUTERNAME
                    Status     = 'Skipped'
                    Message    = 'AMA Extension not installed'
                    AMAVersion = 'N/A'
                }
            }
        }

        # Get the AMA Extension installation folder, using the process ID, and fallback to folder search, if needed
        if(-not $AMAInstallationFolder) {
            # AMAInstallationFolder has not set from fom the directory search, use process info: (preferred)
            if($AMAExtensionPath) {
                $AMAInstallationFolder = Split-Path -Path $AMAExtensionPath -Parent -ErrorAction Stop
            } else {
                Write-Host "AMA Extension process path not found, and directory search did not yield results." -ForegroundColor Red
                Write-Host "Completed node: $env:COMPUTERNAME"
                Return [pscustomobject]@{
                    NodeName = $env:COMPUTERNAME
                    Status   = 'Fail'
                    Message  = 'Unable to determine AMA Extension installation folder'
                }
            }
        }

        if(-not $AMAInstallationFolder) {
            Write-Host "Error: Unable to determine AMA Extension installation folder." -ForegroundColor Red
            Write-Host "Completed node: $env:COMPUTERNAME"
            Return [pscustomobject]@{
                NodeName = $env:COMPUTERNAME
                Status   = 'Fail'
                Message  = 'Unable to determine AMA Extension installation folder'
            }
        } else {
            # Successfully determined the installation folder
            Write-Host "AMA Extension installation folder: $AMAInstallationFolder"
        }

        # Get the AMA Extension Version from the installation folder name:
        try {
            [version]$AMAVersionFolder = (Get-Item $AMAInstallationFolder -ErrorAction Stop).Name
        } catch {
            Write-Host "Error: Unable to determine AMA Extension version from folder name." -ForegroundColor Red
            Write-Host "Completed node: $env:COMPUTERNAME"
            Return [pscustomobject]@{
                NodeName = $env:COMPUTERNAME
                Status   = 'Fail'
                Message  = 'Unable to determine AMA Extension version from folder name'
            }
        }

        # Validation issue present:
        # Check version is greater than or equal to 1.41.0.0, and if so, exit without mitigation
        if($AMAVersionFolder -ge [version]"1.41.0.0") {
            Write-Host "AMA Extension version is $AMAVersionFolder, which is 1.41.0.0 or higher. No mitigation needed." -ForegroundColor Green
            Write-Host "Completed node: $env:COMPUTERNAME"
            Return [pscustomobject]@{
                NodeName       = $env:COMPUTERNAME
                Status         = 'Success'
                Message        = "AMA Extension version $AMAVersionFolder is 1.41.0.0 or higher - no mitigation needed"
                AMAVersion     = $AMAVersionFolder.ToString()
            }
        } else {
            Write-Host "AMA Extension version is $AMAVersionFolder, which is lower than 1.41.0.0." -ForegroundColor Yellow
        }

        # Define the existing file to rename, with a try-catch to handle potential path issues, and define the new file name for the mitigation
        try {
            $FileToRename = Join-Path -Path $AMAInstallationFolder -ChildPath "Monitoring\Agent\Extensions\MetricsExtension\MetricsExtension.Native.exe" -ErrorAction Stop
        } catch {
            Write-Host "Error: Unable to determine path for MetricsExtension.Native.exe." -ForegroundColor Red
            Write-Host "Completed node: $env:COMPUTERNAME"
            Return [pscustomobject]@{
                NodeName = $env:COMPUTERNAME
                Status   = 'Fail'
                Message  = 'Unable to determine path for MetricsExtension.Native.exe'
                AMAVersion     = $AMAVersionFolder.ToString()
            }
        }
        # Define the new file name for the mitigation, with a try-catch to handle potential path issues:
        try {
            $NewFileName = Join-Path -Path $AMAInstallationFolder -ChildPath "Monitoring\Agent\Extensions\MetricsExtension\MetricsExtension.Native.exe.org" -ErrorAction Stop
        } catch {
            Write-Host "Error: Unable to determine path for renamed MetricsExtension.Native.exe.org." -ForegroundColor Red
            Write-Host "Completed node: $env:COMPUTERNAME"
            Return [pscustomobject]@{
                NodeName = $env:COMPUTERNAME
                Status   = 'Fail'
                Message  = 'Unable to determine path for renamed MetricsExtension.Native.exe.org'
                AMAVersion     = $AMAVersionFolder.ToString()
            }
        }

        # Check if the file exists before renaming
        if(-not (Test-Path -Path $FileToRename -ErrorAction Stop)) {
            if(Test-Path -Path $NewFileName -ErrorAction Continue) {
                Write-Host "MetricsExtension.Native.exe - File already renamed" -ForegroundColor Yellow
                Write-Host "Mitigation has been already applied" -ForegroundColor Green
                Write-Host "Completed node: $env:COMPUTERNAME"
                Return [pscustomobject]@{
                    NodeName       = $env:COMPUTERNAME
                    Status         = 'Success'
                    Message        = 'Mitigation already applied - file already renamed'
                    AMAVersion     = $AMAVersionFolder.ToString()
                }
            } else {
                Write-Host "Error: MetricsExtension.Native.exe file not found at expected path: $FileToRename" -ForegroundColor Red
                Write-Host "Completed node: $env:COMPUTERNAME"
                Return [pscustomobject]@{
                    NodeName       = $env:COMPUTERNAME
                    Status         = 'Fail'
                    Message        = "MetricsExtension.Native.exe file not found at: $FileToRename and mitigation (renamed) file not found at: $NewFileName - unable to apply mitigation"
                    AMAVersion     = $AMAVersionFolder.ToString()
                }
            }

        } else {
            # Apply Mitigation, (rename the file)
            Write-Host "Applying mitigation: Renaming MetricsExtension.Native.exe to MetricsExtension.Native.exe.org" -ForegroundColor Cyan
            Write-Host "Debug: Attempting to Rename file: '$FileToRename' to '$NewFileName'"
            try {
                # Attempt to rename the file:
                Rename-Item -Path $FileToRename -NewName $NewFileName -ErrorAction Stop
            } catch {
                Write-Host "Error renaming file: $_" -ForegroundColor Red
                Write-Error "MetricsExtension.Native.exe - Failed to rename the file."
                Write-Host "Completed node: $env:COMPUTERNAME"
                Return [pscustomobject]@{
                    NodeName       = $env:COMPUTERNAME
                    Status         = 'Fail'
                    Message        = "Failed to rename file: $($_.Exception.Message)"
                    AMAVersion     = $AMAVersionFolder.ToString()
                }
            }
        }

        # Validate Mitigation was Successful, check if the file has been renamed successfully
        if(Test-Path -Path $NewFileName -ErrorAction Stop) {
            Write-Host "MetricsExtension.Native.exe - File renamed successfully." -ForegroundColor Green
            Write-Host "Completed node: $env:COMPUTERNAME"
            Return [pscustomobject]@{
                NodeName       = $env:COMPUTERNAME
                Status         = 'Success'
                Message        = 'Mitigation applied successfully - file MetricsExtension.Native.exe renamed to MetricsExtension.Native.exe.org'
                AMAVersion     = $AMAVersionFolder.ToString()
            }
        } else {
            Write-Error "MetricsExtension.Native.exe - Failed to rename the file."
            Write-Host "Completed node: $env:COMPUTERNAME"
            Return [pscustomobject]@{
                NodeName       = $env:COMPUTERNAME
                Status         = 'Fail'
                Message        = 'Failed to verify file rename after applying mitigation - file MetricsExtension.Native.exe still exists and MetricsExtension.Native.exe.org not found'
                AMAVersion     = $AMAVersionFolder.ToString()
            }
        }
    }

    # Process each cluster
    $clusterCount = 0
    $totalClusters = $ClusterList.Count

    ForEach ($cluster in $ClusterList) {
        $clusterCount++
        Write-Progress -Activity "Processing clusters" -Status "Cluster $clusterCount of $totalClusters`: $cluster" -PercentComplete (($clusterCount / $totalClusters) * 100)
        Write-Log "Processing cluster $clusterCount of $totalClusters`: $cluster" -Level Processing

        try {
            Write-Log "Connecting to cluster: $cluster" -Level Info
            $ClusterObj = Get-Cluster -Name $cluster -ErrorAction Stop
            Write-Log "Successfully connected to cluster: $cluster" -Level Success

            try {
                Write-Log "Retrieving cluster nodes for: $cluster" -Level Processing
                $Nodes = $ClusterObj | Get-ClusterNode -ErrorAction Stop
                Write-Log "Found $($Nodes.Count) nodes in cluster: $cluster" -Level Info

                ForEach ($Node in $Nodes) {
                    $NodeName = $Node.Name
                    Write-Log "Connecting to node: $NodeName..." -Level Processing
                    
                    try {
                        # Invoke-Command to run the script block on each remote node
                        $nodeResult = Invoke-Command -ComputerName $NodeName -ScriptBlock $MitigationScriptBlock -ErrorAction Stop
                        
                        # Add cluster name to result
                        $Results.Add([pscustomobject]@{
                            ClusterName = $cluster
                            NodeName    = $nodeResult.NodeName
                            Status      = $nodeResult.Status
                            Message     = $nodeResult.Message
                            AMAVersion  = if ($nodeResult.AMAVersion) { $nodeResult.AMAVersion } else { 'N/A' }
                        })
                        
                        Write-Log "Completed node: $NodeName - Status: $($nodeResult.Status)" -Level $(if ($nodeResult.Status -eq 'Success') { 'Success' } else { 'Error' })
                    } catch {
                        Write-Log "Failed to connect to node '$NodeName': $($_.Exception.Message)" -Level Error
                        $Results.Add([pscustomobject]@{
                            ClusterName = $cluster
                            NodeName    = $NodeName
                            Status      = 'Fail'
                            Message     = "Failed to connect to node: $($_.Exception.Message)"
                            AMAVersion  = 'N/A'
                        })
                    }
                }
            } catch {
                Write-Log "Failed to get nodes for cluster '$cluster': $($_.Exception.Message)" -Level Error
                $Results.Add([pscustomobject]@{
                    ClusterName = $cluster
                    NodeName    = "$cluster (nodes unavailable)"
                    Status      = 'Fail'
                    Message     = "Failed to get cluster nodes: $($_.Exception.Message)"
                    AMAVersion  = 'N/A'
                })
            }
        } catch {
            Write-Log "Failed to connect to cluster '$cluster': $($_.Exception.Message)" -Level Error
            $Results.Add([pscustomobject]@{
                ClusterName = $cluster
                NodeName    = "$cluster (cluster unavailable)"
                Status      = 'Fail'
                Message     = "Failed to connect to cluster: $($_.Exception.Message)"
                AMAVersion  = 'N/A'
            })
        }
    }

    Write-Progress -Activity "Processing clusters" -Completed

    # Return results
    return $Results
}
#endregion

#region Main Script Execution
Write-Log "=== AMA Extension Mitigation Script ===" -Level Start
Write-Log "Script execution started" -Level Info

# Validate output path
if (-not (Test-Path -Path $OutputPath -PathType Container)) {
    Write-Log "Output path does not exist: $OutputPath" -Level Error
    exit 1
}

# Determine input mode: Direct cluster name(s) or CSV file
$clusterList = @()

if ($ClusterName -and $ClusterName.Count -gt 0) {
    # Direct cluster name input
    Write-Log "Using direct cluster input: $($ClusterName.Count) cluster(s) specified" -Level Info
    $clusterList = $ClusterName
} else {
    # CSV file input
    if ([string]::IsNullOrWhiteSpace($CSVFilePath)) {
        Write-Log "Requesting CSV file input..." -Level Processing
        $CSVFilePath = Read-Host -Prompt "Enter the path to the CSV file containing cluster names (requires a 'Cluster' column)"
    }

    Write-Log "Validating CSV file: $CSVFilePath" -Level Processing
    if (-not (Test-Path -Path $CSVFilePath)) {
        Write-Log "CSV file not found at path: $CSVFilePath" -Level Error
        exit 1
    }

    Write-Log "Importing CSV file..." -Level Processing
    try {
        $csvData = Import-Csv -Path $CSVFilePath -ErrorAction Stop
    } catch {
        Write-Log "Failed to import CSV file: $($_.Exception.Message)" -Level Error
        exit 1
    }

    if ($csvData.Count -eq 0) {
        Write-Log "No clusters found in CSV file." -Level Warning
        exit 1
    } elseif (-not ($csvData | Get-Member -Name 'Cluster')) {
        Write-Log "CSV file does not contain 'Cluster' column." -Level Error
        exit 1
    } else {
        Write-Log "Successfully imported $($csvData.Count) clusters from CSV file." -Level Success
        $clusterList = $csvData.Cluster
    }
}

Write-Log "Starting AMA Extension mitigation (this will connect to each node of each cluster)..." -Level Start
Write-Log "Clusters to process: $($clusterList -join ', ')" -Level Info

if (-not $NoConfirm) {
    $confirmation = Read-Host "Press Enter to continue or 'Q' to quit"
    if ($confirmation -eq 'Q') {
        Write-Log "Operation cancelled by user." -Level Warning
        exit 0
    }
}

# Call the main function
$Results = Invoke-AMAExtensionMitigation -ClusterList $clusterList

# Export results to CSV
Write-Log "Exporting results to CSV file..." -Level Processing
[string]$ExportFileName = Join-Path -Path $OutputPath -ChildPath "AMAExtensionMitigation_Results_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

@($Results) | Export-Csv -Path $ExportFileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

# Summary
$successCount = @($Results | Where-Object { $_.Status -eq 'Success' }).Count
$skippedCount = @($Results | Where-Object { $_.Status -eq 'Skipped' }).Count
$failCount = @($Results | Where-Object { $_.Status -eq 'Fail' }).Count

Write-Log "=== Summary ===" -Level Complete
Write-Log "Total nodes processed: $(@($Results).Count)" -Level Info
Write-Log "Successful: $successCount" -Level Success
Write-Log "Skipped (not installed): $skippedCount" -Level Info
Write-Log "Failed: $failCount" -Level $(if ($failCount -gt 0) { 'Warning' } else { 'Info' })
Write-Log "Results exported to CSV file: '$ExportFileName'" -Level Success
Write-Log "Script execution completed" -Level Complete

# Return results for pipeline usage
return $Results
#endregion