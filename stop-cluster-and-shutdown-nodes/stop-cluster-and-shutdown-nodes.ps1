<#
.SYNOPSIS
    Stops a Windows Server Failover Cluster and shuts down all cluster nodes.

.DESCRIPTION
    This script safely stops the cluster service on all nodes, then shuts down each node.
    The script ensures that the local node (where the script is executed) is shut down last
    to avoid timing issues.

.PARAMETER ClusterName
    The name of the cluster. If not specified, uses the local cluster.

.PARAMETER ShutdownTimeout
    Time in seconds to wait between stopping the cluster and initiating shutdown. Default is 30 seconds.

.PARAMETER Force
    Forces shutdown without waiting for user confirmation.

.EXAMPLE
    .\Stop-ClusterAndShutdownNodes.ps1
    Stops the local cluster and shuts down all nodes with confirmation prompts.

.EXAMPLE
    .\Stop-ClusterAndShutdownNodes.ps1 -Force
    Stops the local cluster and shuts down all nodes without confirmation.

.EXAMPLE
    .\Stop-ClusterAndShutdownNodes.ps1 -ClusterName "MyCluster" -ShutdownTimeout 60 -Force
    Stops the specified cluster, waits 60 seconds, then shuts down all nodes without confirmation.

.NOTES
    Author: Neil Bird, Claude Sonnet v4.5 Generated Script
    Date: October 31, 2025
    Requires: Administrator privileges and Failover Clustering PowerShell module

    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.

    This sample is not supported under any Microsoft standard support program or service. 
    The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
    implied warranties including, without limitation, any implied warranties of merchantability
    or of fitness for a particular purpose. The entire risk arising out of the use or performance
    of the sample and documentation remains with you. In no event shall Microsoft, its authors,
    or anyone else involved in the creation, production, or delivery of the script be liable for 
    any damages whatsoever (including, without limitation, damages for loss of business profits, 
    business interruption, loss of business information, or other pecuniary loss) arising out of 
    the use of or inability to use the sample or documentation, even if Microsoft has been advised 
    of the possibility of such damages, rising out of the use of or inability to use the sample script, 
    even if Microsoft has been advised of the possibility of such damages. 

#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterName,
    
    [Parameter(Mandatory=$false)]
    [int]$ShutdownTimeoutMinutes = 30,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force
)

# Requires -RunAsAdministrator
# Requires -Modules FailoverClusters

#region Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info','Warning','Error','Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch($Level) {
        'Info'    { 'White' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Success' { 'Green' }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

#endregion

#region Pre-flight Checks

Write-Log "Starting cluster shutdown script..." -Level Info

# Check if running as Administrator
if (-not (Test-IsAdmin)) {
    Write-Log "This script must be run as Administrator!" -Level Error
    exit 1
}

# Check if Failover Clustering module is available
if (-not (Get-Module -ListAvailable -Name FailoverClusters)) {
    Write-Log "Failover Clustering PowerShell module is not installed!" -Level Error
    exit 1
}

# Import the module
try {
    Import-Module FailoverClusters -ErrorAction Stop
    Write-Log "Failover Clustering module loaded successfully." -Level Success
} catch {
    Write-Log "Failed to import Failover Clustering module: $($_.Exception.Message)" -Level Error
    exit 1
}

#endregion

#region Get Cluster Information

try {
    # Get cluster object
    if ($ClusterName) {
        Write-Log "Connecting to cluster: $ClusterName" -Level Info
        $cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
    } else {
        Write-Log "Connecting to local cluster..." -Level Info
        $cluster = Get-Cluster -ErrorAction Stop
        $ClusterName = $cluster.Name
    }
    
    Write-Log "Connected to cluster: $ClusterName" -Level Success
    
    # Get all cluster nodes
    $clusterNodes = Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop
    Write-Log "Found $($clusterNodes.Count) cluster nodes:" -Level Info
    foreach ($node in $clusterNodes) {
        Write-Log "  - $($node.Name) (State: $($node.State))" -Level Info
    }
    
    # Get the local computer name
    $localComputerName = $env:COMPUTERNAME
    Write-Log "Script is running on: $localComputerName" -Level Info
    
    # Separate local node from remote nodes
    $localNode = $clusterNodes | Where-Object { $_.Name -eq $localComputerName }
    $remoteNodes = $clusterNodes | Where-Object { $_.Name -ne $localComputerName }
    
    if (-not $localNode) {
        Write-Log "Warning: Local computer is not a member of this cluster!" -Level Warning
    }
    
} catch {
    Write-Log "Failed to get cluster information: $($_.Exception.Message)" -Level Error
    exit 1
}

#endregion

#region Confirmation

if (-not $Force) {
    Write-Host ""
    Write-Log "WARNING: This will stop the cluster and shut down all nodes!" -Level Warning
    Write-Log "Cluster: $ClusterName" -Level Warning
    Write-Log "Nodes to shutdown: $($clusterNodes.Count)" -Level Warning
    Write-Host ""
    
    $confirmation = Read-Host "Are you sure you want to continue? (yes/no)"
    if ($confirmation -ne 'yes') {
        Write-Log "Operation cancelled by user." -Level Warning
        exit 0
    }
}

#endregion

#region Stop Cluster

Write-Log "Stopping cluster: $ClusterName" -Level Info

try {
    # Stop the cluster service on all nodes, using -Force switch, not using -Wait parameter
    Stop-Cluster -Cluster $ClusterName -Force -ErrorAction Stop
    Write-Log "Cluster stopped successfully." -Level Success
} catch {
    Write-Log "Failed to stop cluster: $($_.Exception.Message)" -Level Error
    Write-Log "Attempting to continue with node shutdown..." -Level Warning
}

# Wait for cluster to fully stop
Write-Log "Waiting $ShutdownTimeoutMinutes minutes for cluster services to stop completely..." -Level Info
Start-Sleep -Seconds ($ShutdownTimeoutMinutes * 60)

#endregion

#region Verify Cluster is Stopped

Write-Log "Verifying cluster has stopped..." -Level Info

try {
    # Refresh cluster state
    $cluster = Get-Cluster -Name $ClusterName -ErrorAction Stop
    
    # Check cluster status
    # A stopped cluster should have no running nodes or the cluster service should be stopped
    $runningNodes = Get-ClusterNode -Cluster $ClusterName -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Up' }
    
    if ($runningNodes) {
        Write-Log "Warning: Found $($runningNodes.Count) node(s) still in 'Up' state:" -Level Warning
        foreach ($node in $runningNodes) {
            Write-Log "  - $($node.Name) (State: $($node.State))" -Level Warning
        }
        Write-Log "Cluster may not be fully stopped, but proceeding with shutdown..." -Level Warning
    } else {
        Write-Log "Cluster verification complete: All nodes are down or stopping." -Level Success
    }
} catch {
    # If we can't query the cluster, it's likely stopped
    Write-Log "Cannot query cluster (likely stopped): $($_.Exception.Message)" -Level Info
    Write-Log "Assuming cluster is stopped, proceeding with node shutdown..." -Level Info
}

#endregion

#region Shutdown Nodes

Write-Log "Beginning node shutdown sequence..." -Level Info

# Shutdown remote nodes first
if ($remoteNodes) {
    Write-Log "Shutting down remote nodes..." -Level Info
    foreach ($node in $remoteNodes) {
        try {
            Write-Log "Initiating shutdown on node: $($node.Name)" -Level Info
            
            # Use Invoke-Command to shutdown remote node
            Invoke-Command -ComputerName $node.Name -ScriptBlock {
                Stop-Computer -Force -ErrorAction Stop
            } -ErrorAction Stop
            
            Write-Log "Shutdown command sent to: $($node.Name)" -Level Success
        } catch {
            Write-Log "Failed to shutdown node $($node.Name): $($_.Exception.Message)" -Level Error
        }
    }
    
    # Give remote nodes time to start shutting down
    Write-Log "Waiting 15 seconds for remote nodes to begin shutdown..." -Level Info
    Start-Sleep -Seconds 15
}

# Shutdown local node last
if ($localNode) {
    Write-Log "Shutting down local node: $localComputerName (THIS NODE)" -Level Warning
    Write-Log "This system will shut down in 5 seconds..." -Level Warning
    Start-Sleep -Seconds 5
    
    try {
        Stop-Computer -Force -ErrorAction Stop
    } catch {
        Write-Log "Failed to shutdown local node: $($_.Exception.Message)" -Level Error
        exit 1
    }
} else {
    Write-Log "All cluster nodes have been sent shutdown commands." -Level Success
    Write-Log "Script execution complete." -Level Success
}

#endregion
