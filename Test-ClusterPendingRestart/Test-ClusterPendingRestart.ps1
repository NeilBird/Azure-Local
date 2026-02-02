##########################################################################################################
<#
.SYNOPSIS
    Author:     Neil Bird, MSFT
    Version:    0.2.4
    Created:    January 30th 2026
    Updated:    February 2nd 2026

.DESCRIPTION
    This script checks all nodes in clusters for pending restart indicators.
    It connects to each cluster, retrieves the nodes, and checks each node for common pending restart signals.
    Supports parallel processing using runspaces for improved performance on large clusters.
    
    You can specify clusters either directly via -ClusterName or from a CSV file via -CSVFilePath.

.PARAMETER ClusterName
    Optional. Name of one or more clusters to check. Can be a single cluster name or an array of names.
    Use this parameter for quick checks without needing a CSV file.
    Alias: -Cluster

.PARAMETER CSVFilePath
    Optional. Path to the CSV file containing cluster names. If neither -ClusterName nor -CSVFilePath 
    is provided, the script will prompt for CSV input. The CSV file must contain a 'Cluster' column.

.PARAMETER OutputPath
    Optional. Directory path where results CSV will be saved. Defaults to current directory.

.PARAMETER Credential
    Optional. PSCredential for remote computer authentication.

.PARAMETER TimeoutSeconds
    Optional. Timeout in seconds for remote connection attempts. Default is 30 seconds.

.PARAMETER ThrottleLimit
    Optional. Maximum number of concurrent node checks. Default is 10.

.PARAMETER NoConfirm
    Optional. Skip the confirmation prompt before starting checks.

.PARAMETER Detailed
    Optional. Include detailed diagnostic information in results.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1 -ClusterName "MyCluster01"
    Checks a single cluster for pending restart indicators on all nodes.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1 -ClusterName "Cluster01", "Cluster02", "Cluster03" -NoConfirm
    Checks multiple clusters without confirmation prompt.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1
    Prompts for CSV file path and runs the pending restart check on all cluster nodes.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1 -CSVFilePath "C:\Clusters\clusters.csv" -NoConfirm
    Uses the specified CSV file and runs without confirmation prompt.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1 -CSVFilePath "C:\Clusters\clusters.csv" -Credential (Get-Credential) -OutputPath "C:\Results"
    Uses explicit credentials and saves results to specified directory.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1 -ClusterName "MyCluster01" -Credential (Get-Credential) -Detailed
    Checks a single cluster with explicit credentials and detailed output.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1 -CSVFilePath "C:\Clusters\clusters.csv" -ThrottleLimit 20 -Detailed -NoConfirm
    High-performance run with 20 concurrent checks, detailed output, and no confirmation.

.EXAMPLE
    .\Test-ClusterPendingRestart.ps1 -CSVFilePath "C:\Clusters\clusters.csv" -TimeoutSeconds 60
    Uses a 60-second timeout for remote connections (default is 30 seconds).

.NOTES
    Requires the TestPendingRestart module in the TestPendingRestart-Module subfolder.
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
    [PSCredential]$Credential,

    [Parameter(Mandatory=$false)]
    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 30,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 50)]
    [int]$ThrottleLimit = 10,

    [Parameter(Mandatory=$false)]
    [switch]$NoConfirm,

    [Parameter(Mandatory=$false)]
    [switch]$Detailed
)

# Import the module from the TestPendingRestart-Module subfolder
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$modulePath = Join-Path -Path $scriptPath -ChildPath 'TestPendingRestart-Module\TestPendingRestart.psd1'

if (-not (Test-Path -Path $modulePath)) {
    Write-Error "Module not found at: $modulePath. Please ensure the TestPendingRestart-Module folder exists with TestPendingRestart.psd1 and TestPendingRestart.psm1."
    exit 1
}

Import-Module $modulePath -Force -ErrorAction Stop

# Results collection using List for better performance
$Results = [System.Collections.Generic.List[pscustomobject]]::new()

# Validate output path
if (-not (Test-Path -Path $OutputPath -PathType Container)) {
    Write-Error "Output path does not exist: $OutputPath"
    exit 1
}

# CSV file schema example:
<#
    Cluster,HealthStatus,State
    cluster01,Healthy,UpdateAvailable
    cluster02,Healthy,UpdateAvailable
#>

# Script startup
Write-Log "=== Azure Local - Cluster Node Pending Restart Check Script ===" -Level Start
Write-Log "Script execution started" -Level Info

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
        $CSVFilePath = Read-Host -Prompt "Enter the path to the CSV file containing cluster names: (requires a 'Cluster' column in the CSV file)"
    }

    Write-Log "Validating CSV file: $CSVFilePath" -Level Processing
    if(-not(Test-Path -Path $CSVFilePath)) {
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

    if($csvData.Count -eq 0) {
        Write-Log "No clusters found in CSV file." -Level Warning
        exit 1
    } elseif(-not($csvData | Get-Member -Name 'Cluster')) {
        Write-Log "CSV file does not contain 'Cluster' column." -Level Error
        exit 1
    } else {
        Write-Log "Successfully imported $($csvData.Count) clusters from CSV file." -Level Success
        $clusterList = $csvData.Cluster
    }
}

Write-Log "Starting pending restart checks (this will connect to each node of each cluster)..." -Level Start
Write-Log "Parallel processing enabled with throttle limit: $ThrottleLimit" -Level Info

if (-not $NoConfirm) {
    $confirmation = Read-Host "Press Enter to continue or 'Q' to quit"
    if ($confirmation -eq 'Q') {
        Write-Log "Operation cancelled by user." -Level Warning
        exit 0
    }
}

#region Runspace Pool Setup for Parallel Processing
# Create a runspace pool for parallel node checks
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
$runspacePool.Open()

# Script block for runspace jobs
$nodeCheckScript = {
    param($NodeName, $ClusterName, $NodeState, $ModulePath, $Credential, $TimeoutSeconds, $Detailed)
    
    # Import module in runspace
    Import-Module $ModulePath -Force -ErrorAction Stop
    
    # Build parameters for Test-PendingRestart
    $params = @{
        ComputerName    = $NodeName
        TimeoutSeconds  = $TimeoutSeconds
    }
    if ($Credential) { $params['Credential'] = $Credential }
    if ($Detailed) { $params['Detailed'] = $true }
    
    $result = Test-PendingRestart @params
    $result | Add-Member -NotePropertyName 'ClusterName' -NotePropertyValue $ClusterName -Force
    $result | Add-Member -NotePropertyName 'NodeState' -NotePropertyValue $NodeState -Force
    
    return $result
}

$runspaceJobs = [System.Collections.Generic.List[hashtable]]::new()
#endregion

# For each cluster, connect to the cluster, get nodes and queue pending restart checks
$clusterCount = 0
$totalClusters = $clusterList.Count
$totalNodesQueued = 0

ForEach ($cluster in $clusterList) {
    $clusterCount++
    Write-Progress -Activity "Processing clusters" -Status "Cluster $clusterCount of $totalClusters`: $cluster" -PercentComplete (($clusterCount / $totalClusters) * 100)
    Write-Log "Processing cluster $clusterCount of $totalClusters`: $cluster" -Level Processing
    try {
        Write-Log "Connecting to cluster: $cluster" -Level Info
        $ClusterObj = Get-Cluster -Name $cluster -ErrorAction Stop
        Write-Log "Successfully connected to cluster: $cluster" -Level Success
        try {
            Write-Log "Retrieving cluster nodes for: $cluster" -Level Processing
            $Nodes = Get-ClusterNode -Cluster ($ClusterObj).Name -ErrorAction Stop
            
            # Build node state map (Up/Paused/Down/etc.)
            $nodeStateMap = @{}
            $Nodes | ForEach-Object { $nodeStateMap[$_.Name.ToUpperInvariant()] = $_.State.ToString() }
            
            Write-Log "Found $($Nodes.Count) nodes in cluster: $cluster - queueing for parallel processing" -Level Info
            
            ForEach ($Node in $Nodes) {
                $NodeName = $Node.Name
                $NodeState = $nodeStateMap[$NodeName.ToUpperInvariant()]
                
                # Create PowerShell instance for this node
                $powerShell = [PowerShell]::Create()
                $powerShell.RunspacePool = $runspacePool
                [void]$powerShell.AddScript($nodeCheckScript)
                [void]$powerShell.AddParameter('NodeName', $NodeName)
                [void]$powerShell.AddParameter('ClusterName', $cluster)
                [void]$powerShell.AddParameter('NodeState', $NodeState)
                [void]$powerShell.AddParameter('ModulePath', $modulePath)
                [void]$powerShell.AddParameter('Credential', $Credential)
                [void]$powerShell.AddParameter('TimeoutSeconds', $TimeoutSeconds)
                [void]$powerShell.AddParameter('Detailed', $Detailed.IsPresent)
                
                # Start async execution
                $runspaceJobs.Add(@{
                    PowerShell = $powerShell
                    Handle     = $powerShell.BeginInvoke()
                    NodeName   = $NodeName
                    ClusterName = $cluster
                    NodeState  = $NodeState
                })
                $totalNodesQueued++
            }
            Write-Log "Queued $($Nodes.Count) nodes for cluster: $cluster" -Level Success
        } catch {
            Write-Log "Failed to get nodes for cluster '$cluster': $($_.Exception.Message)" -Level Error
            $Results.Add([pscustomobject]@{
                ClusterName     = $cluster
                ComputerName    = "$cluster (nodes unavailable)"
                NodeState       = 'Unknown'
                PendingRestart  = $null
                MsiInstallationInProgress = $null
                Reasons         = ''
                CheckSucceeded  = "False: Failed to get cluster nodes: $($_.Exception.Message)"
            })
        }
    } catch {
        Write-Log "Failed to connect to cluster '$cluster': $($_.Exception.Message)" -Level Error
        $Results.Add([pscustomobject]@{
            ClusterName     = $cluster
            ComputerName    = "$cluster (cluster unavailable)"
            NodeState       = 'Unknown'
            PendingRestart  = $null
            MsiInstallationInProgress = $null
            Reasons         = ''
            CheckSucceeded  = "False: Failed to connect to cluster: $($_.Exception.Message)"
        })
    }
}

Write-Progress -Activity "Processing clusters" -Completed

#region Collect Runspace Results
Write-Log "Waiting for $totalNodesQueued parallel node checks to complete..." -Level Processing
$completedCount = 0

foreach ($job in $runspaceJobs) {
    try {
        # Wait for the job to complete and get results
        # EndInvoke returns a PSDataCollection, so we need to get the first item
        $resultCollection = $job.PowerShell.EndInvoke($job.Handle)
        
        if ($resultCollection -and $resultCollection.Count -gt 0) {
            $result = $resultCollection[0]
            $Results.Add($result)
        } else {
            # Fallback if no result returned
            $Results.Add([pscustomobject]@{
                ClusterName     = $job.ClusterName
                ComputerName    = $job.NodeName
                NodeState       = $job.NodeState
                PendingRestart  = $null
                MsiInstallationInProgress = $null
                Reasons         = ''
                CheckSucceeded  = 'False: No result returned from runspace'
            })
        }
        
        # Check for errors in the PowerShell stream
        if ($job.PowerShell.Streams.Error.Count -gt 0) {
            $errorMsg = $job.PowerShell.Streams.Error[0].Exception.Message
            Write-Log "Error checking node '$($job.NodeName)': $errorMsg" -Level Warning
        }
    } catch {
        Write-Log "Failed to retrieve result for node '$($job.NodeName)': $($_.Exception.Message)" -Level Error
        $Results.Add([pscustomobject]@{
            ClusterName     = $job.ClusterName
            ComputerName    = $job.NodeName
            NodeState       = $job.NodeState
            PendingRestart  = $null
            MsiInstallationInProgress = $null
            Reasons         = ''
            CheckSucceeded  = "False: Runspace error: $($_.Exception.Message)"
        })
    } finally {
        # Cleanup
        $job.PowerShell.Dispose()
    }
    
    $completedCount++
    Write-Progress -Activity "Collecting results" -Status "Processed $completedCount of $totalNodesQueued nodes" -PercentComplete (($completedCount / $totalNodesQueued) * 100)
}

Write-Progress -Activity "Collecting results" -Completed

# Close runspace pool
$runspacePool.Close()
$runspacePool.Dispose()

Write-Log "Completed all node checks" -Level Complete
#endregion

# Export results
Write-Log "Exporting results to CSV file..." -Level Processing
[string]$ExportFileName = Join-Path -Path $OutputPath -ChildPath "Clusters_PendingRestartResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

# Convert List to array for Export-Csv and exclude Details column (not CSV-friendly)
$exportResults = $Results.ToArray() | Select-Object ClusterName, ComputerName, NodeState, PendingRestart, MsiInstallationInProgress, Reasons, CheckSucceeded
$exportResults | Export-Csv -Path $ExportFileName -NoTypeInformation -Encoding UTF8 -ErrorAction Stop

# Summary
$successCount = ($Results | Where-Object { $_.CheckSucceeded -eq 'True' }).Count
$failCount = ($Results | Where-Object { $_.CheckSucceeded -ne 'True' }).Count
$pendingRestartCount = ($Results | Where-Object { $_.PendingRestart -eq $true }).Count
$msiInProgressCount = ($Results | Where-Object { $_.MsiInstallationInProgress -eq $true }).Count

Write-Log "=== Summary ===" -Level Complete
Write-Log "Total nodes checked: $($Results.Count)" -Level Info
Write-Log "Successful checks: $successCount" -Level Success
Write-Log "Failed checks: $failCount" -Level $(if ($failCount -gt 0) { 'Warning' } else { 'Info' })
Write-Log "Nodes with pending restart: $pendingRestartCount" -Level $(if ($pendingRestartCount -gt 0) { 'Warning' } else { 'Info' })
Write-Log "Nodes with MSI installation in progress: $msiInProgressCount" -Level $(if ($msiInProgressCount -gt 0) { 'Warning' } else { 'Info' })
Write-Log "Results exported to CSV file: '$ExportFileName'" -Level Success
Write-Log "Script execution completed" -Level Complete
