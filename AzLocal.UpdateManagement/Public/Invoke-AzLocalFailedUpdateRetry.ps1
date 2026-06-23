function Invoke-AzLocalFailedUpdateRetry {
    <#
    .SYNOPSIS
        Re-applies (retries) a previously FAILED Azure Local cluster update, once.

    .DESCRIPTION
        Issues the same `updates/{updateName}/apply` ARM action that the Azure
        portal's "Try again" button uses, to resume a cluster update whose latest
        run reached a terminal FAILED state. Azure Local update runs are resumable,
        so re-applying the same update version resumes it from where it failed.

        Guard rails (all enforced before any apply is issued):

        1. FAILED-state gate. The cluster's updateSummary state MUST be one of
           'NeedsAttention', 'UpdateFailed' or 'PreparationFailed'. A cluster that
           is still 'UpdateInProgress' (including a STALLED / orphaned run whose
           lastUpdatedTime has frozen) is deliberately SKIPPED - ARM rejects an
           apply over an in-flight run, and the orphaned run must be cleared first.
           This is the safe, intended behaviour for clusters like the Arizona
           orphaned-run case.

        2. One-time guard (idempotent). The retry is recorded in a DEDICATED
           'UpdateRetryAttempted' cluster tag (the durable one-time guard). On a
           subsequent invocation, if that tag already records an attempt for the
           SAME update version, the cluster is SKIPPED with status
           'RetryAlreadyAttempted' so a scheduled pipeline never re-applies in a
           loop. Use -Force to override and retry again. Both tags are auto-cleared
           together by the normal post-success reconciliation
           (Invoke-AzLocalSideloadedAutoResetForCluster) once the retried update
           reaches Succeeded, re-arming a future retry naturally.

        Two tags are written by the retry, sharing one value format:
          - 'UpdateLastAttempt'    (Outcome 'UpdateRetried' / 'Failed') - the
            generic last-attempt audit pointer, so the retry surfaces in the
            Step.08 audit trail like any other attempt. This tag is overwritten by
            every Start attempt, so it is NOT used as the retry guard.
          - 'UpdateRetryAttempted' (Outcome 'RetryStarted' / 'RetryFailed') - the
            dedicated, durable one-time guard read in step 5 below.
        Both tag values are length-clamped to the Azure 256 character limit by
        Format-AzLocalUpdateLastAttemptTagValue.

    .PARAMETER ClusterName
        Name of a single Azure Local cluster to retry. Resolved via Azure Resource
        Graph / ARM. Use with -ResourceGroupName / -SubscriptionId to disambiguate.

    .PARAMETER ResourceGroupName
        Resource group containing the cluster (only used with -ClusterName).

    .PARAMETER ClusterResourceId
        Full Azure resource ID of a single cluster (alternative to -ClusterName).

    .PARAMETER SubscriptionId
        Azure subscription ID. Defaults to the current az CLI subscription.

    .PARAMETER UpdateName
        The failed update version to retry (e.g. 'Solution12.2604.1003.1005').
        When omitted, the cmdlet auto-detects it from the cluster's most recent
        update run (which must itself be Failed/Error). Supply this explicitly for
        a targeted retry, or when the latest run cannot be auto-classified.

    .PARAMETER ApiVersion
        Azure REST API version. Defaults to the module default API version.

    .PARAMETER Force
        Override the one-time guard (retry even if a 'UpdateRetried' attempt is
        already recorded for this update version) and suppress the confirmation
        prompt.

    .OUTPUTS
        PSCustomObject with ClusterName, Status, Message, UpdateName, StartTime,
        EndTime, Duration. Status is one of: RetryStarted, RetryAlreadyAttempted,
        Skipped, NotFound, Failed, WhatIf.

    .EXAMPLE
        Invoke-AzLocalFailedUpdateRetry -ClusterName 'Arizona'
        Auto-detects the failed update on 'Arizona' and retries it once (prompts
        for confirmation). Skips if the cluster is still UpdateInProgress.

    .EXAMPLE
        Invoke-AzLocalFailedUpdateRetry -ClusterName 'Arizona' -UpdateName 'Solution12.2604.1003.1005' -Force
        Targeted, unattended retry of a specific failed update version, overriding
        the one-time guard.

    .NOTES
        Author : AzLocal.UpdateManagement
        Version: 0.8.95
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'ByName')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName', Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterName,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId', ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    begin {
        Test-AzCliAvailable | Out-Null

        # updateSummary states that indicate a terminal failed/aborted update run.
        # InProgress (incl. stalled/orphaned) is intentionally absent - see help.
        $failedStates = @('NeedsAttention', 'UpdateFailed', 'PreparationFailed')
        # States that confirm the latest run itself terminated in failure.
        $failedRunStates = @('Failed', 'Error')
        # Outcome written to the generic UpdateLastAttempt audit tag on success.
        $retryOutcome = 'UpdateRetried'
        # Outcomes written to the dedicated UpdateRetryAttempted one-time guard tag.
        $retryGuardStartedOutcome = 'RetryStarted'
        $retryGuardFailedOutcome = 'RetryFailed'

        # Honour -Force as "do not prompt" without forcing the caller to also pass
        # -Confirm:$false against the High ConfirmImpact declared above.
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
            $ConfirmPreference = 'None'
        }
    }

    process {
        $startTime = Get-Date
        $clusterDisplay = if ($PSCmdlet.ParameterSetName -eq 'ByResourceId') { ($ClusterResourceId -split '/')[-1] } else { $ClusterName }

        # Local helper to build a consistent result row.
        $newResult = {
            param($Name, $Status, $Message, $Update)
            $end = Get-Date
            [PSCustomObject]@{
                ClusterName = $Name
                Status      = $Status
                Message     = $Message
                UpdateName  = $Update
                StartTime   = $startTime
                EndTime     = $end
                Duration    = ($end - $startTime).ToString('hh\:mm\:ss')
            }
        }

        Write-Log -Message "" -Level Info
        Write-Log -Message "Retry failed update: $clusterDisplay" -Level Header

        try {
            # 1. Resolve cluster resource (id, tags, name).
            if ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
                $uri = "https://management.azure.com$ClusterResourceId`?api-version=$ApiVersion"
                $clusterInfo = (Invoke-AzRestJson -Uri $uri).Data
                if ($LASTEXITCODE -ne 0) { $clusterInfo = $null }
            }
            else {
                if (-not $SubscriptionId) {
                    $SubscriptionId = (az account show --query id -o tsv)
                    Write-Log -Message "Using current subscription: $SubscriptionId" -Level Info
                }
                $clusterInfo = Get-AzLocalClusterInfo -ClusterName $ClusterName `
                    -ResourceGroupName $ResourceGroupName `
                    -SubscriptionId $SubscriptionId `
                    -ApiVersion $ApiVersion
            }

            if (-not $clusterInfo -or -not $clusterInfo.id) {
                Write-Log -Message "Cluster '$clusterDisplay' not found." -Level Warning
                return (& $newResult $clusterDisplay 'NotFound' 'Cluster not found' $null)
            }
            $resolvedName = if ($clusterInfo.PSObject.Properties['name'] -and $clusterInfo.name) { [string]$clusterInfo.name } else { $clusterDisplay }
            Write-Log -Message "Found cluster: $($clusterInfo.id)" -Level Success

            # 2. Update summary state.
            $summary = Get-AzLocalUpdateSummary -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
            $state = if ($summary -and $summary.properties -and $summary.properties.PSObject.Properties['state']) { [string]$summary.properties.state } else { '' }
            Write-Log -Message "Update summary state: $state" -Level Info

            # 3. FAILED-state gate.
            if ($state -notin $failedStates) {
                $reason = if ($state -match 'InProgress') {
                    "Cluster state is '$state' - an in-flight (or stalled/orphaned) run cannot be retried; clear the run first"
                }
                else {
                    "Cluster state is '$state' - no failed update to retry"
                }
                Write-Log -Message $reason -Level Warning
                return (& $newResult $resolvedName 'Skipped' $reason $null)
            }

            # 4. Determine the failed update name to retry.
            $targetUpdateName = $null
            if ($UpdateName) {
                $targetUpdateName = $UpdateName
                Write-Log -Message "Using caller-supplied update name: $targetUpdateName" -Level Info
            }
            else {
                $allRuns = Get-AzLocalClusterUpdateRuns -resourceId $clusterInfo.id -apiVer $ApiVersion
                $latestRun = $allRuns | Sort-Object { $_.properties.timeStarted } -Descending | Select-Object -First 1
                if ($latestRun) {
                    $formattedRun = Format-AzLocalUpdateRun -run $latestRun -clusterResourceId $clusterInfo.id
                    if ($formattedRun.State -in $failedRunStates -and $formattedRun.UpdateName) {
                        $targetUpdateName = $formattedRun.UpdateName
                        Write-Log -Message "Auto-detected failed update from latest run: $targetUpdateName (run state: $($formattedRun.State))" -Level Info
                    }
                    else {
                        Write-Log -Message "Latest run state '$($formattedRun.State)' did not confirm a failed update name." -Level Warning
                    }
                }
            }

            if (-not $targetUpdateName) {
                $msg = 'Could not determine a failed update to retry; re-run with -UpdateName'
                Write-Log -Message $msg -Level Warning
                return (& $newResult $resolvedName 'Skipped' $msg $null)
            }

            # 5. One-time guard via the dedicated UpdateRetryAttempted tag.
            # ANY recorded retry attempt (RetryStarted OR RetryFailed) for the
            # same update version blocks a second automatic retry; -Force overrides.
            $retryGuardRaw = Get-TagValue -Tags $clusterInfo.tags -Name $script:UpdateRetryAttemptedTagName
            $parsedGuard = ConvertFrom-AzLocalUpdateLastAttemptTagValue -Value $retryGuardRaw
            if (-not $Force -and $parsedGuard `
                    -and -not [string]::IsNullOrWhiteSpace($parsedGuard.UpdateName) `
                    -and $parsedGuard.UpdateName.Trim() -ieq $targetUpdateName.Trim()) {
                $msg = "Already retried update '$targetUpdateName' once (recorded $($parsedGuard.AttemptUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')), outcome '$($parsedGuard.Outcome)'); use -Force to retry again"
                Write-Log -Message $msg -Level Warning
                return (& $newResult $resolvedName 'RetryAlreadyAttempted' $msg $targetUpdateName)
            }

            # 6. Apply (ShouldProcess + High confirmation unless -Force).
            if (-not $PSCmdlet.ShouldProcess($resolvedName, "Retry failed update '$targetUpdateName'")) {
                return (& $newResult $resolvedName 'WhatIf' "Would retry update '$targetUpdateName'" $targetUpdateName)
            }

            Write-Log -Message "Retrying update '$targetUpdateName' on cluster '$resolvedName'..." -Level Info
            $applyResult = Invoke-AzLocalUpdateApply -ClusterResourceId $clusterInfo.id `
                -UpdateName $targetUpdateName `
                -ApiVersion $ApiVersion

            if ($applyResult) {
                Write-Log -Message "Retry initiated successfully." -Level Success
                Write-Log -Message "Monitor progress using: Get-AzLocalUpdateRuns -ClusterName '$resolvedName'" -Level Info
                $attemptUtc = $startTime.ToUniversalTime()
                # Generic last-attempt audit pointer.
                Write-AzLocalUpdateLastAttemptTag `
                    -ClusterResourceId $clusterInfo.id `
                    -ClusterName $resolvedName `
                    -AttemptUtc $attemptUtc `
                    -Outcome $retryOutcome `
                    -UpdateName $targetUpdateName `
                    -Reason 'One-time retry of failed update initiated' `
                    -ApiVersion $ApiVersion
                # Dedicated durable one-time guard.
                Write-AzLocalUpdateLastAttemptTag `
                    -ClusterResourceId $clusterInfo.id `
                    -ClusterName $resolvedName `
                    -AttemptUtc $attemptUtc `
                    -Outcome $retryGuardStartedOutcome `
                    -UpdateName $targetUpdateName `
                    -Reason 'One-time retry of failed update initiated' `
                    -TagName $script:UpdateRetryAttemptedTagName `
                    -ApiVersion $ApiVersion
                return (& $newResult $resolvedName 'RetryStarted' 'Retry initiated successfully' $targetUpdateName)
            }
            else {
                Write-Log -Message "Retry apply call was rejected for cluster '$resolvedName'." -Level Error
                $attemptUtc = $startTime.ToUniversalTime()
                Write-AzLocalUpdateLastAttemptTag `
                    -ClusterResourceId $clusterInfo.id `
                    -ClusterName $resolvedName `
                    -AttemptUtc $attemptUtc `
                    -Outcome 'Failed' `
                    -UpdateName $targetUpdateName `
                    -Reason 'Retry apply call was rejected by ARM' `
                    -ApiVersion $ApiVersion
                # Record the attempt in the guard tag too so a rejected call still
                # consumes the one-time retry (use -Force to try again).
                Write-AzLocalUpdateLastAttemptTag `
                    -ClusterResourceId $clusterInfo.id `
                    -ClusterName $resolvedName `
                    -AttemptUtc $attemptUtc `
                    -Outcome $retryGuardFailedOutcome `
                    -UpdateName $targetUpdateName `
                    -Reason 'Retry apply call was rejected by ARM' `
                    -TagName $script:UpdateRetryAttemptedTagName `
                    -ApiVersion $ApiVersion
                return (& $newResult $resolvedName 'Failed' 'Retry apply call was rejected by ARM' $targetUpdateName)
            }
        }
        catch {
            Write-Log -Message "Failed to retry update on '$clusterDisplay': $($_.Exception.Message)" -Level Error
            return (& $newResult $clusterDisplay 'Failed' $_.Exception.Message $null)
        }
    }
}
