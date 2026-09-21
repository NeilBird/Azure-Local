function Invoke-AzLocalFleetOperation {
    <#
    .SYNOPSIS
        Executes fleet-wide operations with batching, throttling, and retry logic.
    
    .DESCRIPTION
        Orchestrates update operations across large numbers of Azure Local clusters
        with enterprise-scale features:
        
        - Batch processing: Process clusters in configurable batches
        - Throttling: Control parallel execution and rate limiting
        - Retry logic: Automatic retries with exponential backoff
        - State management: Checkpoint/resume capability
        - Progress tracking: Real-time status updates
        
        Designed for fleets of 1000-3000+ clusters.
    
    .PARAMETER Operation
        The operation to perform:
        - ApplyUpdate: Start updates on clusters (default)
        - CheckReadiness: Check update readiness across fleet
        - GetStatus: Get current update status
    
    .PARAMETER ScopeByUpdateRingTag
        Target clusters with a specific UpdateRing tag.
    
    .PARAMETER UpdateRingValue
        The UpdateRing tag value to filter by.
    
    .PARAMETER ClusterResourceIds
        Explicit list of cluster resource IDs to operate on.
    
    .PARAMETER UpdateName
        Specific update name to apply (for ApplyUpdate operation).
    
    .PARAMETER BatchSize
        Number of clusters to process per batch. Default: 50.
    
    .PARAMETER ThrottleLimit
        Maximum parallel operations per batch. Default: 10.
    
    .PARAMETER DelayBetweenBatchesSeconds
        Delay between batches in seconds. Default: 30.
    
    .PARAMETER MaxRetries
        Maximum retry attempts per cluster. Default: 3.
    
    .PARAMETER RetryDelaySeconds
        Base delay between retries (uses exponential backoff). Default: 30.
    
    .PARAMETER StateFilePath
        Path to save operation state for resume capability.
    
    .PARAMETER Force
        Skip confirmation prompts.
    
    .PARAMETER PassThru
        Return the fleet state object for pipeline use.
    
    .EXAMPLE
        Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
        Starts updates on all Wave1 clusters with default batching.
    
    .EXAMPLE
        Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Production" `
            -BatchSize 100 -ThrottleLimit 20 -DelayBetweenBatchesSeconds 60 -Force
        Processes Production clusters with larger batches and more parallelism.
    
    .EXAMPLE
        $state = Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Ring1" `
            -StateFilePath "C:\Logs\ring1-state.json" -Force -PassThru
        Runs operation with state saved for potential resume.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByTag')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('ApplyUpdate', 'CheckReadiness', 'GetStatus')]
        [string]$Operation = 'ApplyUpdate',
        
        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [switch]$ScopeByUpdateRingTag,
        
        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [string]$UpdateRingValue,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,
        
        [Parameter(Mandatory = $false)]
        [string]$UpdateName,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 500)]
        [int]$BatchSize = 50,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 50)]
        [int]$ThrottleLimit = 10,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 600)]
        [int]$DelayBetweenBatchesSeconds = 30,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3,
        
        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 300)]
        [int]$RetryDelaySeconds = 30,
        
        [Parameter(Mandatory = $false)]
        [string]$StateFilePath,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force,
        
        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )
    
    $runId = [guid]::NewGuid().ToString()
    $startTime = Get-Date
    
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Fleet Operation: $Operation" -Level Header
    Write-Log -Message "Run ID: $runId" -Level Header
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Configuration:" -Level Info
    Write-Log -Message "  Batch Size: $BatchSize" -Level Info
    Write-Log -Message "  Throttle Limit: $ThrottleLimit" -Level Info
    Write-Log -Message "  Delay Between Batches: $DelayBetweenBatchesSeconds seconds" -Level Info
    Write-Log -Message "  Max Retries: $MaxRetries" -Level Info
    
    # Get list of clusters
    $allClusters = @()
    
    if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
        Write-Log -Message "Querying clusters with UpdateRing = '$UpdateRingValue'..." -Level Info
        $inventory = Get-AzLocalClusterInventory -PassThru
        $allClusters = @($inventory | Where-Object { $_.UpdateRing -eq $UpdateRingValue })
        
        if ($allClusters.Count -eq 0) {
            Write-Warning "No clusters found with UpdateRing = '$UpdateRingValue'"
            return $null
        }
    }
    else {
        Write-Log -Message "Using $($ClusterResourceIds.Count) provided cluster Resource IDs..." -Level Info
        foreach ($resourceId in $ClusterResourceIds) {
            $parts = $resourceId -split '/'
            $allClusters += [PSCustomObject]@{
                ClusterName = $parts[-1]
                ResourceId = $resourceId
                ResourceGroup = $parts[4]
                SubscriptionId = $parts[2]
            }
        }
    }
    
    $totalClusters = $allClusters.Count
    Write-Log -Message "Total clusters to process: $totalClusters" -Level Info

    # Honour -WhatIf / -Confirm at the fleet level. Per-cluster gating would be
    # too noisy for the typical fleet size; one prompt describing the whole
    # operation is sufficient. The -Force interactive prompt below is retained
    # for ApplyUpdate so the historical caller experience is preserved.
    $scopeDescription = if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
        "$totalClusters cluster(s) with UpdateRing='$UpdateRingValue'"
    } else {
        "$totalClusters cluster(s) supplied by ResourceId"
    }
    if (-not $PSCmdlet.ShouldProcess($scopeDescription, "Fleet $Operation")) {
        Write-Log -Message "Fleet operation cancelled by ShouldProcess." -Level Warning
        return $null
    }

    # Confirmation
    if (-not $Force -and $Operation -eq 'ApplyUpdate') {
        $confirmation = Read-Host "This will start updates on $totalClusters cluster(s). Continue? (y/n)"
        if ($confirmation -ne 'y') {
            Write-Log -Message "Operation cancelled by user." -Level Warning
            return $null
        }
    }
    
    # Initialize state
    $state = [PSCustomObject]@{
        RunId = $runId
        Operation = $Operation
        StartTime = $startTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
        EndTime = $null
        TotalClusters = $totalClusters
        CompletedCount = 0
        SucceededCount = 0
        FailedCount = 0
        PendingCount = $totalClusters
        BatchSize = $BatchSize
        ThrottleLimit = $ThrottleLimit
        CurrentBatch = 0
        TotalBatches = [math]::Ceiling($totalClusters / $BatchSize)
        UpdateRingValue = $UpdateRingValue
        UpdateName = $UpdateName
        StateFilePath = $StateFilePath
        LastSaved = $null
        Clusters = @()
    }
    
    # Initialize cluster tracking
    foreach ($cluster in $allClusters) {
        $state.Clusters += [PSCustomObject]@{
            ClusterName = $cluster.ClusterName
            ResourceId = $cluster.ResourceId
            ResourceGroup = $cluster.ResourceGroup
            SubscriptionId = $cluster.SubscriptionId
            Status = "Pending"
            Attempts = 0
            LastAttempt = $null
            LastError = $null
            Result = $null
        }
    }
    
    # Store state script-level for progress tracking
    $script:FleetOperationState = $state

    # Build a hashtable keyed by ResourceId for O(1) merge-back of per-job
    # cluster states. Parallel jobs receive deserialized copies of cluster
    # state objects; we merge their mutations back into the canonical
    # $state.Clusters list via this index.
    $clusterStateByRid = @{}
    foreach ($__cs in $state.Clusters) {
        if ($__cs -and $__cs.ResourceId) {
            $clusterStateByRid[$__cs.ResourceId] = $__cs
        }
    }

    # Shared operation parameters forwarded to Invoke-FleetOpClusterAction
    # inside each parallel job. Start-AzLocalClusterUpdate / ...Readiness /
    # GetStatus each accept a different subset; Invoke-FleetOpClusterAction
    # splats -OperationParameters into the underlying cmdlet.
    $opParams = @{}
    if ($Operation -eq 'ApplyUpdate') {
        $opParams['Force'] = $true
        if ($UpdateName) { $opParams['UpdateName'] = $UpdateName }
    }

    # Per-batch job scriptblock. Runs either inline (ThrottleLimit=1, fast path)
    # or inside Start-Job (ThrottleLimit>1). Imports the module by path so
    # exported helpers are available, then iterates the shard and mutates
    # each cluster state via Invoke-FleetOpClusterAction.
    $perBatchJob = {
        param(
            [object[]]$ShardItems,
            [string]$JobOperation,
            [hashtable]$JobOpParams,
            [int]$JobMaxRetries,
            [int]$JobRetryDelaySeconds,
            [string]$ModulePath
        )
        # Only import when not already loaded. In the inline fast-path (ThrottleLimit=1)
        # we are already running inside the module; a -Force reimport here would
        # remove the in-flight module and break callers above us on the stack that
        # rely on private functions such as Write-Log.
        if (-not (Get-Command -Name Invoke-FleetOpClusterAction -ErrorAction SilentlyContinue)) {
            Import-Module $ModulePath -Force -ErrorAction Stop
        }
        $workerModule = Get-Module AzLocal.UpdateManagement
        & $workerModule {
            param($Items, $Operation, $OpParams, $MaxRetries, $RetryDelaySeconds)
            foreach ($clusterState in $Items) {
                if ($clusterState.Status -eq 'Succeeded') { continue }
                Invoke-FleetOpClusterAction -ClusterState $clusterState -Operation $Operation `
                    -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds `
                    -OperationParameters $OpParams
            }
            return , $Items
        } $ShardItems $JobOperation $JobOpParams $JobMaxRetries $JobRetryDelaySeconds
    }

    # Process in batches
    $batchNumber = 0
    $totalBatches = $state.TotalBatches

    for ($i = 0; $i -lt $totalClusters; $i += $BatchSize) {
        $batchNumber++
        $state.CurrentBatch = $batchNumber
        $batchClusters = $state.Clusters[$i..[math]::Min($i + $BatchSize - 1, $totalClusters - 1)]

        # Filter out already-succeeded clusters (resume scenarios)
        $pendingInBatch = @($batchClusters | Where-Object { $_.Status -ne 'Succeeded' })

        Write-Log -Message "" -Level Info
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Batch $batchNumber of $totalBatches ($($batchClusters.Count) clusters; $($pendingInBatch.Count) to process)" -Level Header
        Write-Log -Message "========================================" -Level Header

        if ($pendingInBatch.Count -eq 0) {
            Write-Log -Message "  All clusters in this batch already succeeded - skipping." -Level Info
        }
        else {
            # Dispatch the batch across parallel jobs (or inline when ThrottleLimit=1).
            # Invoke-FleetJobsInParallel handles sharding, timeouts, Receive-Job, and
            # cleanup; each returned result contains .Output (mutated shard) or .Error.
            $jobResults = Invoke-FleetJobsInParallel `
                -InputItems $pendingInBatch `
                -ScriptBlock $perBatchJob `
                -ThrottleLimit $ThrottleLimit `
                -ArgumentList @($Operation, $opParams, $MaxRetries, $RetryDelaySeconds) `
                -ActivityName "FleetOp-B$batchNumber"

            foreach ($jr in $jobResults) {
                if ($jr.Failed) {
                    # The whole shard failed before any per-cluster work completed.
                    # Mark every cluster in that shard as Failed with the batch error
                    # so progress stays accurate and retry counters are non-zero.
                    foreach ($item in @($jr.Items)) {
                        if (-not $item -or -not $item.ResourceId) { continue }
                        $orig = $clusterStateByRid[$item.ResourceId]
                        if ($orig) {
                            $orig.Status = 'Failed'
                            $orig.LastError = "Batch job failed: $($jr.Error)"
                            if (-not $orig.Attempts -or $orig.Attempts -lt 1) { $orig.Attempts = 1 }
                            $orig.LastAttempt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
                        }
                    }
                }
                else {
                    # Merge each deserialized/returned ClusterState back into the
                    # canonical object in $state.Clusters via the hash index.
                    foreach ($updated in @($jr.Output)) {
                        if (-not $updated -or -not $updated.ResourceId) { continue }
                        $orig = $clusterStateByRid[$updated.ResourceId]
                        if (-not $orig) { continue }
                        # Same object identity in the inline fast-path (ThrottleLimit=1);
                        # distinct deserialized copy under Start-Job. Assignments are
                        # idempotent either way.
                        $orig.Status = $updated.Status
                        $orig.Attempts = $updated.Attempts
                        $orig.LastAttempt = $updated.LastAttempt
                        $orig.LastError = $updated.LastError
                        $orig.Result = $updated.Result
                    }
                }
            }

            # Recompute counters and emit per-cluster status after merge.
            foreach ($cs in $pendingInBatch) {
                $orig = $clusterStateByRid[$cs.ResourceId]
                if (-not $orig) { continue }
                if ($orig.Status -eq 'Succeeded') {
                    $state.SucceededCount++
                    Write-Log -Message "  [OK] $($orig.ClusterName) - Succeeded" -Level Success
                }
                else {
                    if ($orig.Status -ne 'Failed') { $orig.Status = 'Failed' }
                    $state.FailedCount++
                    Write-Log -Message "  [FAILED] $($orig.ClusterName) - Failed: $($orig.LastError)" -Level Error
                }
                $state.CompletedCount++
            }
            $state.PendingCount = $totalClusters - $state.CompletedCount
        }

        # Save checkpoint after each batch
        if ($StateFilePath) {
            Export-AzLocalFleetState -State $state -Path $StateFilePath | Out-Null
        }

        # Delay between batches (if not the last batch)
        if ($batchNumber -lt $totalBatches -and $DelayBetweenBatchesSeconds -gt 0) {
            Write-Log -Message "Batch $batchNumber complete. Waiting $DelayBetweenBatchesSeconds seconds before next batch..." -Level Info
            Start-Sleep -Seconds $DelayBetweenBatchesSeconds
        }
    }
    
    # Final state update
    $state.EndTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    
    # Final save
    if ($StateFilePath) {
        Export-AzLocalFleetState -State $state -Path $StateFilePath | Out-Null
    }
    
    # Summary
    $duration = (Get-Date) - $startTime
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Fleet Operation Complete" -Level Header
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Run ID: $runId" -Level Info
    Write-Log -Message "Duration: $([math]::Round($duration.TotalMinutes, 1)) minutes" -Level Info
    Write-Log -Message "Total Clusters: $totalClusters" -Level Info
    Write-Log -Message "Succeeded: $($state.SucceededCount)" -Level $(if ($state.SucceededCount -eq $totalClusters) { "Success" } else { "Info" })
    Write-Log -Message "Failed: $($state.FailedCount)" -Level $(if ($state.FailedCount -gt 0) { "Error" } else { "Info" })
    
    if ($StateFilePath) {
        Write-Log -Message "State file: $StateFilePath" -Level Info
    }
    
    if ($PassThru) {
        return $state
    }
}
