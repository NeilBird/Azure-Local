function Resume-AzLocalFleetUpdate {
    <#
    .SYNOPSIS
        Resumes a previously interrupted fleet update operation.
    
    .DESCRIPTION
        Loads a saved fleet operation state and continues processing any
        pending or failed clusters. This enables recovery from:
        - Pipeline timeouts
        - Network interruptions  
        - Manual cancellations
        - Transient failures
    
    .PARAMETER StateFilePath
        Path to the saved state file from a previous operation.
    
    .PARAMETER State
        A state object loaded via Import-AzLocalFleetState.
    
    .PARAMETER RetryFailed
        Also retry clusters that previously failed (not just pending).
    
    .PARAMETER MaxRetries
        Maximum additional retry attempts for failed clusters.
    
    .PARAMETER Force
        Skip confirmation prompts.
    
    .PARAMETER PassThru
        Return the updated state object.
    
    .EXAMPLE
        Resume-AzLocalFleetUpdate -StateFilePath "C:\Logs\fleet-state.json" -Force
        Resumes pending clusters from the saved state.
    
    .EXAMPLE
        Resume-AzLocalFleetUpdate -StateFilePath "C:\Logs\fleet-state.json" -RetryFailed -Force
        Resumes pending clusters and retries failed ones.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByPath')]
        [ValidateScript({ Test-Path $_ })]
        [string]$StateFilePath,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'ByState')]
        [PSCustomObject]$State,
        
        [Parameter(Mandatory = $false)]
        [switch]$RetryFailed,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force,
        
        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )
    
    # Load state
    $resumeState = if ($State) { $State } else { Import-AzLocalFleetState -Path $StateFilePath }
    
    if (-not $resumeState) {
        Write-Error "Failed to load fleet state."
        return $null
    }
    
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Resuming Fleet Operation" -Level Header
    Write-Log -Message "Original Run ID: $($resumeState.RunId)" -Level Header
    Write-Log -Message "========================================" -Level Header
    
    # Identify clusters to process
    $pendingClusters = @($resumeState.Clusters | Where-Object { $_.Status -eq "Pending" })
    $failedClusters = @($resumeState.Clusters | Where-Object { $_.Status -eq "Failed" })
    
    Write-Log -Message "State Summary:" -Level Info
    Write-Log -Message "  Pending: $($pendingClusters.Count)" -Level Info
    Write-Log -Message "  Failed: $($failedClusters.Count)" -Level Info
    Write-Log -Message "  Succeeded: $($resumeState.SucceededCount)" -Level Info
    
    $clustersToProcess = $pendingClusters
    if ($RetryFailed) {
        $clustersToProcess += $failedClusters
    }
    
    if ($clustersToProcess.Count -eq 0) {
        Write-Log -Message "No pending clusters selected for resume." -Level Info
        return $resumeState
    }
    
    Write-Log -Message "Clusters to process: $($clustersToProcess.Count)" -Level Info

    if (-not $PSCmdlet.ShouldProcess($resumeState.RunId, "Resume fleet operation on $($clustersToProcess.Count) cluster(s)")) {
        return $resumeState
    }
    
    # Confirmation
    if (-not $Force) {
        $confirmation = Read-Host "Resume operation on $($clustersToProcess.Count) cluster(s)? (y/n)"
        if ($confirmation -ne 'y') {
            Write-Log -Message "Resume cancelled by user." -Level Warning
            return $resumeState
        }
    }
    
    $params = @{
        Operation = $resumeState.Operation
        BatchSize = $resumeState.BatchSize
        ThrottleLimit = $resumeState.ThrottleLimit
        MaxRetries = $MaxRetries
        Force = $true
        PassThru = $true
        Confirm = $false
    }
    
    if ($resumeState.UpdateName) {
        $params['UpdateName'] = $resumeState.UpdateName
    }
    
    $checkpointPath = if ($StateFilePath) { $StateFilePath } else { $resumeState.StateFilePath }
    $clusterByResourceId = @{}
    foreach ($cluster in $resumeState.Clusters) {
        $clusterByResourceId[$cluster.ResourceId] = $cluster
    }
    $resumeState.EndTime = $null
    for ($batchOffset = 0; $batchOffset -lt $clustersToProcess.Count; $batchOffset += $resumeState.BatchSize) {
        $batchEnd = [math]::Min($batchOffset + $resumeState.BatchSize - 1, $clustersToProcess.Count - 1)
        $params['ClusterResourceIds'] = @($clustersToProcess[$batchOffset..$batchEnd] | ForEach-Object { $_.ResourceId })
        try {
            $batchResult = Invoke-AzLocalFleetOperation @params
            if (-not $batchResult) { throw 'The resumed fleet batch returned no state.' }
            foreach ($updated in $batchResult.Clusters) {
                $original = $clusterByResourceId[$updated.ResourceId]
                $original.Attempts = [int]$original.Attempts + [int]$updated.Attempts
                foreach ($propertyName in @('Status', 'LastAttempt', 'LastError', 'Result')) {
                    $original.$propertyName = $updated.$propertyName
                }
            }
        }
        finally {
            $script:FleetOperationState = $resumeState
        }
        $resumeState.TotalClusters = @($resumeState.Clusters).Count
        $resumeState.SucceededCount = @($resumeState.Clusters | Where-Object Status -eq 'Succeeded').Count
        $resumeState.FailedCount = @($resumeState.Clusters | Where-Object Status -eq 'Failed').Count
        $resumeState.PendingCount = @($resumeState.Clusters | Where-Object Status -eq 'Pending').Count
        $resumeState.CompletedCount = $resumeState.SucceededCount + $resumeState.FailedCount
        $resumeState.CurrentBatch = [math]::Ceiling($resumeState.CompletedCount / $resumeState.BatchSize)
        if ($batchEnd -eq $clustersToProcess.Count - 1) {
            $resumeState.EndTime = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
        if ($checkpointPath) {
            Export-AzLocalFleetState -State $resumeState -Path $checkpointPath | Out-Null
        }
        if ($batchEnd -lt $clustersToProcess.Count - 1) {
            Start-Sleep -Seconds 30
        }
    }
    
    if ($PassThru) {
        return $resumeState
    }
}
