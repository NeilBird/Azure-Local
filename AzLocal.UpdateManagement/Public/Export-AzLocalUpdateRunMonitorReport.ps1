function Export-AzLocalUpdateRunMonitorReport {
    <#
    .SYNOPSIS
        Runs the Step.7 in-flight update-run monitor pipeline workload:
        snapshots the fleet's latest update runs, classifies them by
        per-step + overall elapsed and progress-status, writes the CSV +
        JUnit XML artifacts, and emits the step-summary markdown + step
        outputs for the v0.8.5 thin-YAML Step.7 pipeline.

    .DESCRIPTION
        Phase 1 (v0.8.5) of the thin-YAML refactor. Condenses the inline
        `run: |` body of the v0.8.4 Step.8_monitor-updates.yml (GitHub
        Actions + Azure DevOps) into a single cmdlet call so the
        per-platform yml shrinks to a few lines and the workload becomes
        unit-testable against a synthetic Get-AzLocalUpdateRuns result.

        The cmdlet:

          1. Resolves the output directory (defaults to './reports' on
             GitHub Actions / Local, or `$env:BUILD_ARTIFACTSTAGINGDIRECTORY`
             on Azure DevOps - matching the v0.8.4 yml).
          2. Queries the fleet's latest update runs:
               - Scope = 'all'           -> `Get-AzLocalClusterInventory -PassThru`
                                            then `Get-AzLocalUpdateRuns
                                            -ClusterResourceIds <ids> -Latest
                                            -PassThru -SkipSideloadedReset`.
               - Scope = 'by-update-ring'-> `Get-AzLocalUpdateRuns
                                            -ScopeByUpdateRingTag
                                            -UpdateRingValue <ring> -Latest
                                            -PassThru -SkipSideloadedReset`.
             Both code paths match the v0.8.4 yml byte-for-byte.
          3. Enriches each run row with elapsed durations, threshold
             flags (per-step warn/crit, overall warn/crit/skull), step-error
             signal, recent-failure / unresolved-failure flags, severity
             score, and portal URLs - identical to the v0.8.4 yml.
          4. Writes update-monitor.csv (sorted by severity score) and
             update-monitor.xml (JUnit, one <testcase> per in-flight + one
             per unresolved-failed cluster) into the output directory.
          5. Emits the markdown step summary (top status badge + scope/
             threshold line + metric table + 'In-flight runs' table +
             'Failed runs (unresolved)' table + action-required / healthy
             footer) via `Add-AzLocalPipelineStepSummary`.
          6. Emits 8 step outputs via `Set-AzLocalPipelineOutput`:
             in_flight, long_running, long_running_step, step_errored,
             stalled, recent_failures, unresolved_failures,
             attempts_without_run.

        Internal reuse (per the v0.8.5 thin-YAML consistency contract):
          * `Get-AzLocalUpdateRuns` (with `-PassThru -SkipSideloadedReset`)
            for the actual run query - the v0.8.4 yml comments call out
            that `-PassThru` is REQUIRED (without it Get-AzLocalUpdateRuns
            only writes formatted output to the host and returns nothing).
          * `Get-AzLocalClusterInventory` for the all-clusters scope.
          * `New-AzLocalPipelineJUnitXml` (Private) for JUnit emission.
          * `Add-AzLocalPipelineStepSummary` for the rendered markdown.
          * `Set-AzLocalPipelineOutput` for the step outputs.
          * `Get-AzLocalPipelineHost` is implicit (the above branch on it).

    .PARAMETER OutputDirectory
        Directory to write update-monitor.csv + update-monitor.xml into.
        Created if it does not exist. Defaults to './reports' (which is
        what the v0.8.4 GH yml uses) or, on AzureDevOps, to
        `$env:BUILD_ARTIFACTSTAGINGDIRECTORY` if that env var is set.

    .PARAMETER Scope
        'all' (default) - query every cluster the identity can see (via
        Get-AzLocalClusterInventory). 'by-update-ring' - query only
        clusters whose UpdateRing tag matches -UpdateRing.

    .PARAMETER UpdateRing
        UpdateRing tag value to filter by when -Scope is 'by-update-ring'.
        Accepts a single ring ('Wave1'), a semicolon-delimited list
        ('Prod;Ring2'), or '***' to match every cluster that HAS the
        UpdateRing tag set. Ignored when -Scope is 'all'.

    .PARAMETER LongRunningStepHours
        PRIMARY stuck-step signal. Flag in-flight runs whose CURRENT STEP
        has been running longer than this many hours. Default 2.

    .PARAMETER LongRunningThresholdHours
        Belt-and-braces overall-elapsed flag. Default 24h.

    .PARAMETER RecentFailureWindowHours
        Surface FAILED runs whose End time falls within the last N hours.
        Default 24. Set to 0 to disable the 'recent' chip (unresolved
        failures are always surfaced).

    .PARAMETER CriticalElapsedDays
        CRITICAL tier for overall-elapsed. In-flight runs older than this
        many days get a rotating_light chip; older than 2x get a skull
        chip. Default 3.

    .PARAMETER StalledNoProgressHours
        STALLED-run detection. An InProgress run whose ARM `lastUpdatedTime`
        has not advanced for more than this many hours is treated as
        stalled / making zero progress (the orchestrator died mid-step but
        ARM still reports InProgress - e.g. an orphaned run stuck for weeks).
        Stalled runs get a CRITICAL status, a ':zzz: stalled' chip, and are
        counted separately (StalledCount / 'stalled' step output). Default
        24. Set to 0 to disable stalled detection.

    .PARAMETER CsvFileName
        Filename for the per-cluster CSV. Default 'update-monitor.csv'.

    .PARAMETER XmlFileName
        Filename for the JUnit XML report. Default 'update-monitor.xml'.

    .PARAMETER SummaryFileName
        Per-task summary filename used by `Add-AzLocalPipelineStepSummary`
        on Azure DevOps and Local hosts. Default
        'update-monitor-summary.md'.

    .PARAMETER InstalledModuleVersion
        Optional [string] used in the markdown footer
        ('Generated by AzLocal.UpdateManagement v<x>').

    .PARAMETER Now
        DateTime used to compute elapsed durations and the failure window.
        Defaults to `Get-Date` at invocation time. Tests pass a fixed
        value so elapsed comparisons are deterministic.

    .PARAMETER PassThru
        When set, returns a single PSCustomObject summarising the run
        (InFlightCount, LongRunningCount, LongRunningStepCount,
        StepErroredCount, StalledCount, RecentFailureCount,
        UnresolvedFailureCount, CsvPath, XmlPath, Rows). Without -PassThru
        the cmdlet emits
        nothing to the pipeline; the artifacts and step outputs are still
        produced.

    .PARAMETER SkipWhenIdle
        Performance fast path for high-frequency / event-driven schedules.
        When set, the cmdlet first runs ONE cheap fleet-wide Resource Graph
        probe ('is any update run InProgress?'). If ARG reports idle, admitted
        inventory is checked for recent UpdateStarted/UpdateRetried tags. The
        cmdlet emits the IDLE result and skips the update-run sweep only when
        both checks are empty. A recent attempt, an in-flight ARG row, or an
        error in either probe runs the full sweep and ARM reconciliation.

    .OUTPUTS
        Nothing by default. When -PassThru is set, a single PSCustomObject.

    .EXAMPLE
        Export-AzLocalUpdateRunMonitorReport -Scope all -PassThru

    .NOTES
        Module: AzLocal.UpdateManagement (v0.8.5+)
        Roadmap: Step.7 - Monitor In-Flight Updates.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateSet('all', 'by-update-ring')]
        [string]$Scope = 'all',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$UpdateRing,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 8760)]
        [int]$LongRunningStepHours = 2,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 8760)]
        [int]$LongRunningThresholdHours = 24,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 8760)]
        [int]$RecentFailureWindowHours = 24,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 8760)]
        [int]$RecentAttemptWindowHours = 72,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 365)]
        [int]$CriticalElapsedDays = 3,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 8760)]
        [int]$StalledNoProgressHours = 24,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvFileName = 'update-monitor.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlFileName = 'update-monitor.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'update-monitor-summary.md',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$InstalledModuleVersion,

        [Parameter(Mandatory = $false)]
        [datetime]$Now = (Get-Date),

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$SkipWhenIdle
    )

    $pipelineHost = Get-AzLocalPipelineHost

    # v0.8.81: shared status-icon map (host-aware) - replaces the inline
    # red/yellow/green-circle and check/cross shortcodes that previously
    # rendered as literal text on Azure DevOps.
    $iconMap = Get-AzLocalStatusIconMap -PipelineHost $pipelineHost

    if (-not $OutputDirectory) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $OutputDirectory = $env:BUILD_ARTIFACTSTAGINGDIRECTORY
        }
        else {
            $OutputDirectory = './reports'
        }
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $monitorCsv = Join-Path -Path $OutputDirectory -ChildPath $CsvFileName
    $monitorXml = Join-Path -Path $OutputDirectory -ChildPath $XmlFileName

    $nowUtc            = $Now.ToUniversalTime()
    $thresholdSpan     = [TimeSpan]::FromHours($LongRunningThresholdHours)
    $stepThresholdSpan = [TimeSpan]::FromHours($LongRunningStepHours)
    $stepCritSpan      = [TimeSpan]::FromHours($LongRunningStepHours * 2)
    $critElapsedSpan   = [TimeSpan]::FromDays($CriticalElapsedDays)
    $skullElapsedSpan  = [TimeSpan]::FromDays($CriticalElapsedDays * 2)
    # v0.8.95: an InProgress run whose ARM lastUpdatedTime has not advanced for
    # this long is treated as STALLED (orchestrator died mid-step; the run is
    # making zero progress yet ARM still reports InProgress). 0 disables the check.
    $stalledSpan       = if ($StalledNoProgressHours -gt 0) { [TimeSpan]::FromHours($StalledNoProgressHours) } else { [TimeSpan]::Zero }
    $failureWindowStart = if ($RecentFailureWindowHours -gt 0) { $nowUtc.AddHours(-$RecentFailureWindowHours) } else { [datetime]::MaxValue }

    Write-Host ("Thresholds: per-step={0}h (warn) / {1}h (crit), overall={2}h (warn) / {3}d (crit) / {4}d (skull), recent-failure-window={5}h, stalled-no-progress={6}h" -f $LongRunningStepHours, ($LongRunningStepHours * 2), $LongRunningThresholdHours, $CriticalElapsedDays, ($CriticalElapsedDays * 2), $RecentFailureWindowHours, $StalledNoProgressHours)

    # v0.8.90: shared idle-completion emitter. Writes the empty CSV + JUnit, the
    # 7 all-zero step outputs, and the IDLE status badge, then returns the
    # all-zero PassThru shape. Used by BOTH the -SkipWhenIdle fast path (below)
    # and the empty-inventory path so the two idle outcomes stay identical.
    function Complete-MonitorIdle {
        param([Parameter(Mandatory = $true)][string]$StatusLine)
        # Write empty CSV so the artifact upload step has something to attach.
        '' | Set-Content -LiteralPath $monitorCsv -Encoding utf8
        # Write empty JUnit XML so the publish-test-results step has something to read.
        $emptyXml = New-AzLocalPipelineJUnitXml -TestSuitesName 'Update Run Monitor' -Suites @(
            @{ Name = 'Update Run Monitor'; ClassName = 'UpdateMonitor'; TestCases = @() }
        ) -OutputPath $monitorXml
        $null = $emptyXml
        Set-AzLocalPipelineOutput -Name 'in_flight'           -Value '0'
        Set-AzLocalPipelineOutput -Name 'long_running'        -Value '0'
        Set-AzLocalPipelineOutput -Name 'long_running_step'   -Value '0'
        Set-AzLocalPipelineOutput -Name 'step_errored'        -Value '0'
        Set-AzLocalPipelineOutput -Name 'stalled'             -Value '0'
        Set-AzLocalPipelineOutput -Name 'recent_failures'     -Value '0'
        Set-AzLocalPipelineOutput -Name 'unresolved_failures' -Value '0'
        Set-AzLocalPipelineOutput -Name 'attempts_without_run' -Value '0'
        $idleSb = New-Object System.Text.StringBuilder
        [void]$idleSb.AppendLine('## In-Flight Update Monitor')
        [void]$idleSb.AppendLine('')
        [void]$idleSb.AppendLine($StatusLine)
        Add-AzLocalPipelineStepSummary -Markdown $idleSb.ToString() -SummaryFileName $SummaryFileName | Out-Null
        return [pscustomobject]@{
            InFlightCount          = 0
            LongRunningCount       = 0
            LongRunningStepCount   = 0
            StepErroredCount       = 0
            StalledCount           = 0
            RecentFailureCount     = 0
            UnresolvedFailureCount = 0
            AttemptWithoutRunCount = 0
            AttemptGaps            = @()
            CsvPath                = $monitorCsv
            XmlPath                = $monitorXml
            Rows                   = @()
        }
    }

    $inventoryForTags = $null
    $inventory = $null

    # v0.8.90: -SkipWhenIdle fast path. Run one cheap fleet-wide ARG probe
    # ("is any update run InProgress?"). When ARG says idle, inspect inventory
    # for recent attempt tags before skipping: ARG can omit the exact nested run
    # that the direct ARM reconciliation below is designed to recover.
    # Fail-safe: if either probe errors, run the full sweep.
    if ($SkipWhenIdle) {
        $anyInFlight = $true
        try {
            $anyInFlight = [bool](Test-AzLocalUpdateRunsInFlight)
        }
        catch {
            Write-Warning ("SkipWhenIdle probe failed; running full sweep. {0}" -f $_.Exception.Message)
            $anyInFlight = $true
        }
        if (-not $anyInFlight) {
            $hasRecentAttempt = $false
            try {
                if ($Scope -eq 'by-update-ring' -and $UpdateRing) {
                    $inventoryForTags = @(Get-AzLocalClusterInventory -ScopeByUpdateRingTag -UpdateRingValue $UpdateRing -PassThru 6>$null)
                }
                else {
                    $inventory = @(Get-AzLocalClusterInventory -PassThru 6>$null)
                    $inventoryForTags = @($inventory)
                }
                if ($RecentAttemptWindowHours -gt 0) {
                    $attemptCutoff = $nowUtc.AddHours(-$RecentAttemptWindowHours)
                    foreach ($inventoryRow in $inventoryForTags) {
                        $tagBag = if ($inventoryRow -and $inventoryRow.PSObject.Properties['tags']) { $inventoryRow.tags } else { $null }
                        $tagValue = Get-TagValue -Tags $tagBag -Name $script:UpdateLastAttemptTagName
                        if ([string]::IsNullOrWhiteSpace($tagValue)) { continue }
                        $attempt = ConvertFrom-AzLocalUpdateLastAttemptTagValue -Value $tagValue
                        if ($attempt -and $attempt.Outcome -in @('UpdateStarted', 'UpdateRetried') -and
                            $attempt.UpdateName -and $attempt.AttemptUtc -ge $attemptCutoff) {
                            $hasRecentAttempt = $true
                            break
                        }
                    }
                }
            }
            catch {
                Write-Warning ("SkipWhenIdle inventory/tag probe failed; running full sweep. {0}" -f $_.Exception.Message)
                $hasRecentAttempt = $true
                $inventoryForTags = $null
                $inventory = $null
            }

            if (-not $hasRecentAttempt) {
                Write-Host 'SkipWhenIdle: ARG reports no in-flight runs and inventory has no recent update attempts - skipping update-run sweep.'
                $idleResult = Complete-MonitorIdle -StatusLine ':white_circle: **Fleet Status: IDLE** - no in-flight runs or recent update attempts (update-run sweep skipped via -SkipWhenIdle)'
                if ($PassThru) { return $idleResult }
                return
            }
            Write-Host 'SkipWhenIdle: ARG reports no in-flight runs, but inventory has a recent update attempt - running full ARM reconciliation sweep.'
        }
        else {
            Write-Host 'SkipWhenIdle: update run(s) in flight - running full sweep.'
        }
    }

    # ---- Query runs --------------------------------------------------------
    # v0.8.82: always fetch inventory (both scope paths) so we have per-cluster
    # tags available for the UpdateLastAttempt reconciliation pass. Previously
    # the by-update-ring path skipped the inventory call entirely.
    $runs = @()
    if ($Scope -eq 'by-update-ring' -and $UpdateRing) {
        Write-Host "Scope: UpdateRing = $UpdateRing"
        if ($null -eq $inventoryForTags) {
            $inventoryForTags = @(Get-AzLocalClusterInventory -ScopeByUpdateRingTag -UpdateRingValue $UpdateRing -PassThru 6>$null)
        }
        $runs = @(Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue $UpdateRing -Latest -PassThru -SkipSideloadedReset 6>$null)
    }
    else {
        Write-Host "Scope: all clusters (via inventory)"
        if ($null -eq $inventory) {
            $inventory = @(Get-AzLocalClusterInventory -PassThru 6>$null)
        }
        if (-not $inventory -or @($inventory).Count -eq 0) {
            Write-Warning 'No clusters found in inventory.'
            $idleResult = Complete-MonitorIdle -StatusLine ':white_circle: **Fleet Status: IDLE** - no clusters found in inventory'
            if ($PassThru) { return $idleResult }
            return
        }
        $resourceIds = @($inventory | Select-Object -ExpandProperty ResourceId)
        $runs = @(Get-AzLocalUpdateRuns -ClusterResourceIds $resourceIds -Latest -PassThru -SkipSideloadedReset 6>$null)
        $inventoryForTags = @($inventory)
    }

    # ARG can omit nested updateRun resources even when the ARM endpoint and
    # portal expose them. Reconcile every durable UpdateStarted/UpdateRetried
    # tag through ARM when ARG has no covering run. The recent-attempt window
    # controls alerting below, but must not allow an older successful run to
    # replace a newer failed run merely because the missing run is older.
    if ($inventoryForTags -and $inventoryForTags.Count -gt 0) {
        $argRunCount = @($runs).Count
        $reconciliationCandidateCount = 0
        $armEmptyCount = 0
        $reconciliationFailureCount = 0
        $runsByAttemptKey = @{}
        foreach ($run in $runs) {
            $runResourceId = if ($run.PSObject.Properties['ClusterResourceId']) { [string]$run.ClusterResourceId } else { '' }
            $runUpdateName = if ($run.PSObject.Properties['UpdateName']) { [string]$run.UpdateName } else { '' }
            if ($runResourceId -and $runUpdateName) {
            $runsByAttemptKey[('{0}|{1}' -f $runResourceId.ToLowerInvariant(), $runUpdateName.ToLowerInvariant())] = $run
            }
        }
        $recoveredRuns = [System.Collections.Generic.List[object]]::new()
        foreach ($inventoryRow in $inventoryForTags) {
            $tagBag = if ($inventoryRow -and $inventoryRow.PSObject.Properties['tags']) { $inventoryRow.tags } else { $null }
            $tagValue = Get-TagValue -Tags $tagBag -Name $script:UpdateLastAttemptTagName
            if ([string]::IsNullOrWhiteSpace($tagValue)) { continue }
            $attempt = ConvertFrom-AzLocalUpdateLastAttemptTagValue -Value $tagValue
            if (-not $attempt -or $attempt.Outcome -notin @('UpdateStarted', 'UpdateRetried') -or -not $attempt.UpdateName) { continue }

            $resourceId = if ($inventoryRow.PSObject.Properties['ResourceId']) { [string]$inventoryRow.ResourceId } else { '' }
            if (-not $resourceId) { continue }
            $runKey = '{0}|{1}' -f $resourceId.ToLowerInvariant(), ([string]$attempt.UpdateName).ToLowerInvariant()
            $existingRun = if ($runsByAttemptKey.ContainsKey($runKey)) { $runsByAttemptKey[$runKey] } else { $null }
            $existingRunCoversAttempt = $false
            if ($existingRun -and $existingRun.PSObject.Properties['StartTime'] -and $existingRun.StartTime) {
                [datetime]$existingStart = [datetime]::MinValue
                if ([datetime]::TryParse([string]$existingRun.StartTime, [ref]$existingStart)) {
                    $existingRunCoversAttempt = $existingStart.ToUniversalTime() -ge $attempt.AttemptUtc.AddMinutes(-5)
                }
            }
            if (-not $existingRunCoversAttempt -and $existingRun -and
                $existingRun.PSObject.Properties['LastUpdatedTime'] -and $existingRun.LastUpdatedTime) {
                [datetime]$existingUpdated = [datetime]::MinValue
                if ([datetime]::TryParse([string]$existingRun.LastUpdatedTime, [ref]$existingUpdated)) {
                    $existingRunCoversAttempt = $existingUpdated.ToUniversalTime() -ge $attempt.AttemptUtc.AddMinutes(-5)
                }
            }
            if ($existingRunCoversAttempt) { continue }

            $reconciliationCandidateCount++
            $attemptAge = $nowUtc - $attempt.AttemptUtc
            $clusterName = if ($inventoryRow.PSObject.Properties['ClusterName']) { [string]$inventoryRow.ClusterName } else { '' }
            Write-Verbose ("ARM reconciliation candidate: cluster='{0}', update='{1}', attemptAgeMinutes={2:N0}, ARG covering run=false." -f $clusterName, $attempt.UpdateName, $attemptAge.TotalMinutes)
            try {
                $armRuns = @(Get-AzLocalClusterUpdateRuns -resourceId $resourceId -updateNameFilter $attempt.UpdateName -apiVer $script:DefaultApiVersion)
                $coveringRun = @($armRuns | Where-Object {
                    $_ -and $_.PSObject.Properties['properties'] -and $_.properties -and
                    (($_.properties.PSObject.Properties['timeStarted'] -and $_.properties.timeStarted -and
                        ([datetime]$_.properties.timeStarted).ToUniversalTime() -ge $attempt.AttemptUtc.AddMinutes(-5)) -or
                        ($_.properties.PSObject.Properties['lastUpdatedTime'] -and $_.properties.lastUpdatedTime -and
                        ([datetime]$_.properties.lastUpdatedTime).ToUniversalTime() -ge $attempt.AttemptUtc.AddMinutes(-5)))
                } | Sort-Object {
                    if ($_.properties.PSObject.Properties['lastUpdatedTime'] -and $_.properties.lastUpdatedTime) {
                        [datetime]$_.properties.lastUpdatedTime
                    }
                    else { [datetime]$_.properties.timeStarted }
                } -Descending | Select-Object -First 1)
                if ($coveringRun.Count -eq 0) {
                    $armEmptyCount++
                    Write-Verbose ("ARM reconciliation result: cluster='{0}', update='{1}', covering run=false, ARM rows={2}." -f $clusterName, $attempt.UpdateName, $armRuns.Count)
                    continue
                }

                $recoveredRun = Format-AzLocalUpdateRun -run $coveringRun[0] -clusterName $clusterName -clusterResourceId $resourceId
                $recoveredRuns.Add($recoveredRun) | Out-Null
                $runsByAttemptKey[$runKey] = $recoveredRun
                $runs = @($runs | Where-Object {
                    $candidateResourceId = if ($_.PSObject.Properties['ClusterResourceId']) { [string]$_.ClusterResourceId } else { '' }
                    -not $candidateResourceId -or $candidateResourceId -ine $resourceId
                })
                Write-Warning ("Recovered update run for cluster '{0}' and update '{1}' through ARM because Resource Graph did not return it." -f $clusterName, $attempt.UpdateName)
                Write-Verbose ("ARM reconciliation result: cluster='{0}', update='{1}', covering run=true, recoveredRun='{2}'." -f $clusterName, $attempt.UpdateName, $recoveredRun.RunId)
            }
            catch {
                $reconciliationFailureCount++
                Write-Warning ("ARM reconciliation failed for cluster '{0}' and update '{1}': {2}" -f $resourceId, $attempt.UpdateName, $_.Exception.Message)
            }
        }
        if ($recoveredRuns.Count -gt 0) {
            $runs = @($runs) + $recoveredRuns.ToArray()
        }
        $argScopeMode = Get-Variable -Name LastResourceGraphScopeMode -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $argScopeCount = Get-Variable -Name LastResourceGraphScopeCount -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $argRetryCount = Get-Variable -Name LastResourceGraphRetryCount -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        $argTruncated = Get-Variable -Name LastResourceGraphQueryTruncated -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        Write-Verbose ("Update-run reconciliation summary: inventoryClusters={0}, argRows={1}, candidates={2}, recoveredFromArm={3}, armWithoutCoveringRun={4}, failures={5}, argScopeMode='{6}', argScopeCount={7}, argRetries={8}, argTruncated={9}." -f @($inventoryForTags).Count, $argRunCount, $reconciliationCandidateCount, $recoveredRuns.Count, $armEmptyCount, $reconciliationFailureCount, $argScopeMode, $argScopeCount, $argRetryCount, $argTruncated)
    }

    # ---- Project + enrich rows --------------------------------------------
    $rows = foreach ($r in $runs) {
        $startDt = $null
        if ($r.StartTime) {
            [datetime]$tmp = [datetime]::MinValue
            if ([datetime]::TryParse([string]$r.StartTime, [ref]$tmp)) {
                $startDt = [datetime]::SpecifyKind($tmp, [DateTimeKind]::Utc)
            }
        }
        $endDt = $null
        if ($r.EndTime) {
            [datetime]$tmpE = [datetime]::MinValue
            if ([datetime]::TryParse([string]$r.EndTime, [ref]$tmpE)) {
                $endDt = [datetime]::SpecifyKind($tmpE, [DateTimeKind]::Utc)
            }
        }
        $stepStartDt = $null
        if ($r.PSObject.Properties['StepStartTime'] -and $r.StepStartTime) {
            [datetime]$tmpS = [datetime]::MinValue
            if ([datetime]::TryParse([string]$r.StepStartTime, [ref]$tmpS)) {
                $stepStartDt = [datetime]::SpecifyKind($tmpS, [DateTimeKind]::Utc)
            }
        }
        $elapsed = if ($startDt) { $nowUtc - $startDt } else { $null }
        $elapsedDisplay = if ($elapsed) {
            if ($elapsed.TotalDays -ge 1) { ('{0}d {1}h {2}m' -f [int]$elapsed.TotalDays, $elapsed.Hours, $elapsed.Minutes) }
            elseif ($elapsed.TotalHours -ge 1) { ('{0}h {1}m' -f [int]$elapsed.TotalHours, $elapsed.Minutes) }
            else { ('{0}m' -f [int]$elapsed.TotalMinutes) }
        } else { '' }
        $stepElapsed = if ($stepStartDt -and $r.State -eq 'InProgress') { $nowUtc - $stepStartDt } else { $null }
        $stepElapsedHoursVal = if ($stepElapsed) { [math]::Round($stepElapsed.TotalHours, 2) } else { '' }
        $stepElapsedDisplay = if ($r.PSObject.Properties['StepElapsed']) { [string]$r.StepElapsed } else { '' }
        if ([string]::IsNullOrWhiteSpace($stepElapsedDisplay) -and $stepElapsed) {
            $stepElapsedDisplay = if ($stepElapsed.TotalHours -ge 1) { ('{0}h {1}m' -f [int]$stepElapsed.TotalHours, $stepElapsed.Minutes) } else { ('{0}m' -f [int]$stepElapsed.TotalMinutes) }
        }
        $exceeds     = if ($elapsed     -and ($r.State -eq 'InProgress')) { $elapsed -gt $thresholdSpan } else { $false }
        $exceedsStep = if ($stepElapsed -and ($r.State -eq 'InProgress')) { $stepElapsed -gt $stepThresholdSpan } else { $false }

        # v0.8.95: stalled-run detection. Parse the ARM lastUpdatedTime and, for
        # an InProgress run, measure how long the run resource has gone WITHOUT
        # any orchestrator activity. A genuinely-running update bumps
        # lastUpdatedTime continuously; an orphaned run (orchestrator died
        # mid-step) keeps State=InProgress forever while lastUpdatedTime freezes.
        # When the no-activity gap exceeds $stalledSpan the run is making zero
        # progress and is flagged STALLED so operators aren't misled into
        # thinking it is still actively applying (Arizona run 19444cab: 30+ days
        # InProgress, last touched after only 9m33s of runtime).
        $lastUpdatedDt = $null
        if ($r.PSObject.Properties['LastUpdatedTime'] -and $r.LastUpdatedTime) {
            [datetime]$tmpL = [datetime]::MinValue
            if ([datetime]::TryParse([string]$r.LastUpdatedTime, [ref]$tmpL)) {
                $lastUpdatedDt = [datetime]::SpecifyKind($tmpL, [DateTimeKind]::Utc)
            }
        }
        $sinceLastUpdate = if ($lastUpdatedDt) { $nowUtc - $lastUpdatedDt } else { $null }
        $isStalled = if ($r.State -eq 'InProgress' -and $stalledSpan -gt [TimeSpan]::Zero -and $sinceLastUpdate) {
            $sinceLastUpdate -gt $stalledSpan
        } else { $false }
        $sinceLastUpdateDisplay = if ($sinceLastUpdate) {
            if ($sinceLastUpdate.TotalDays -ge 1) { ('{0}d {1}h' -f [int]$sinceLastUpdate.TotalDays, $sinceLastUpdate.Hours) }
            elseif ($sinceLastUpdate.TotalHours -ge 1) { ('{0}h {1}m' -f [int]$sinceLastUpdate.TotalHours, $sinceLastUpdate.Minutes) }
            else { ('{0}m' -f [int]$sinceLastUpdate.TotalMinutes) }
        } else { '' }

        $isRecentFailure     = if ($RecentFailureWindowHours -gt 0 -and $r.State -eq 'Failed' -and $endDt) { $endDt -gt $failureWindowStart } else { $false }
        $isUnresolvedFailure = ($r.State -eq 'Failed')
        $progressStatus = if ($r.PSObject.Properties['Status']) { [string]$r.Status } else { '' }
        $hasStepError = ($progressStatus -eq 'Error' -and $r.State -eq 'InProgress')

        $clusterPortalUrl = if ($r.ClusterResourceId) { 'https://portal.azure.com/#@/resource' + [string]$r.ClusterResourceId + '/updates' } else { '' }
        $updateRunPortalUrl = ''
        if ($r.PSObject.Properties['RunResourceId'] -and $r.RunResourceId -and $r.ClusterResourceId) {
            $rm = [regex]::Match([string]$r.RunResourceId, '/updates/([^/]+)/updateRuns/([^/]+)$')
            if ($rm.Success) {
                $encClusterId = ((([string]$r.ClusterResourceId) -replace '/', '%2F') -replace ' ', '%20')
                $updateRunPortalUrl = 'https://portal.azure.com/#view/Microsoft_AzureStackHCI_PortalExtension/SingleInstanceHistoryDetails.ReactView/resourceId/' + $encClusterId + '/updateName/' + $rm.Groups[1].Value + '/updateRunName/' + $rm.Groups[2].Value + '/refresh~/false'
            }
        }

        $stepSeverity = 'none'
        if ($stepElapsed -and $r.State -eq 'InProgress') {
            if ($stepElapsed -gt $stepCritSpan) { $stepSeverity = 'crit' }
            elseif ($stepElapsed -gt $stepThresholdSpan) { $stepSeverity = 'warn' }
        }
        $runSeverity = 'none'
        if ($elapsed -and $r.State -eq 'InProgress') {
            if ($elapsed -gt $skullElapsedSpan) { $runSeverity = 'skull' }
            elseif ($elapsed -gt $critElapsedSpan) { $runSeverity = 'crit' }
            elseif ($elapsed -gt $thresholdSpan) { $runSeverity = 'warn' }
        }
        $stateIcon = switch ($r.State) {
            'InProgress' { $iconMap['StateInProgress'] }
            'Succeeded'  { $iconMap['StateSucceeded'] }
            'Failed'     { $iconMap['StateFailed'] }
            'NotStarted' { $iconMap['StateNotStarted'] }
            default      { $iconMap['StateUnknown'] }
        }
        $statusIcon = switch ($progressStatus) {
            'Success'    { $iconMap['Success'] }
            'Error'      { $iconMap['Fail'] }
            'InProgress' { $iconMap['StatusInProgress'] }
            'Skipped'    { $iconMap['Block'] }
            'Cancelled'  { $iconMap['StatusCancelled'] }
            default      { '' }
        }
        $chipList = New-Object 'System.Collections.Generic.List[string]'
        if ($hasStepError) { $chipList.Add(':rotating_light: step errored') | Out-Null }
        if ($isStalled) { $chipList.Add((':zzz: stalled - no activity {0}' -f $sinceLastUpdateDisplay)) | Out-Null }
        if ($stepSeverity -eq 'crit') { $chipList.Add((':rotating_light: step >{0}h' -f ($LongRunningStepHours * 2))) | Out-Null }
        elseif ($stepSeverity -eq 'warn') { $chipList.Add((':warning: step >{0}h' -f $LongRunningStepHours)) | Out-Null }
        if ($runSeverity -eq 'skull') { $chipList.Add((':skull: run >{0}d' -f ($CriticalElapsedDays * 2))) | Out-Null }
        elseif ($runSeverity -eq 'crit') { $chipList.Add((':rotating_light: run >{0}d' -f $CriticalElapsedDays)) | Out-Null }
        elseif ($runSeverity -eq 'warn') { $chipList.Add((':warning: run >{0}h' -f $LongRunningThresholdHours)) | Out-Null }
        if ($chipList.Count -eq 0 -and $r.State -eq 'InProgress') { $chipList.Add('within') | Out-Null }
        $flagDisplay = ($chipList -join '<br>')

        $severityScore = 0.0
        if ($hasStepError) { $severityScore += 1000 }
        if ($r.State -eq 'Failed') { $severityScore += 800 }
        if ($isStalled) { $severityScore += 600 }
        if ($runSeverity -eq 'skull') { $severityScore += 500 }
        elseif ($runSeverity -eq 'crit') { $severityScore += 300 }
        elseif ($runSeverity -eq 'warn') { $severityScore += 50 }
        if ($stepSeverity -eq 'crit') { $severityScore += 200 }
        elseif ($stepSeverity -eq 'warn') { $severityScore += 30 }
        $elapsedHoursForScore = if ($elapsed) { $elapsed.TotalHours } else { 0 }
        $severityScore += [math]::Round($elapsedHoursForScore / 24, 2)

        $runDurationSeconds = 0
        if ($r.State -ne 'InProgress' -and $startDt -and $endDt) {
            $runDurationSeconds = [int][math]::Round(($endDt - $startDt).TotalSeconds, 0)
        }
        elseif ($elapsed) {
            $runDurationSeconds = [int][math]::Round($elapsed.TotalSeconds, 0)
        }
        if ($runDurationSeconds -lt 0) { $runDurationSeconds = 0 }

        [PSCustomObject]@{
            ClusterName          = $r.ClusterName
            ClusterPortalUrl     = $clusterPortalUrl
            UpdateName           = $r.UpdateName
            UpdateRunPortalUrl   = $updateRunPortalUrl
            State                = $r.State
            Status               = $progressStatus
            CurrentStep          = $r.CurrentStep
            Progress             = $r.Progress
            StartTimeUtc         = if ($startDt)     { $startDt.ToString('yyyy-MM-dd HH:mm') }     else { '' }
            EndTimeUtc           = if ($endDt)       { $endDt.ToString('yyyy-MM-dd HH:mm') }       else { '' }
            LastUpdatedUtc       = if ($lastUpdatedDt) { $lastUpdatedDt.ToString('yyyy-MM-dd HH:mm') } else { '' }
            ElapsedDisplay       = $elapsedDisplay
            ElapsedHours         = if ($elapsed)     { [math]::Round($elapsed.TotalHours, 2) }     else { '' }
            SinceLastUpdateDisplay = $sinceLastUpdateDisplay
            SinceLastUpdateHours = if ($sinceLastUpdate) { [math]::Round($sinceLastUpdate.TotalHours, 2) } else { '' }
            IsStalled            = $isStalled
            StepStartTimeUtc     = if ($stepStartDt) { $stepStartDt.ToString('yyyy-MM-dd HH:mm') } else { '' }
            StepElapsedDisplay   = $stepElapsedDisplay
            StepElapsedHours     = $stepElapsedHoursVal
            ExceedsThreshold     = $exceeds
            ExceedsStepThreshold = $exceedsStep
            HasStepError         = $hasStepError
            IsRecentFailure      = $isRecentFailure
            IsUnresolvedFailure  = $isUnresolvedFailure
            ThresholdHours       = $LongRunningThresholdHours
            StepThresholdHours   = $LongRunningStepHours
            CriticalElapsedDays  = $CriticalElapsedDays
            StepSeverity         = $stepSeverity
            RunSeverity          = $runSeverity
            StateIcon            = $stateIcon
            StatusIcon           = $statusIcon
            Flags                = $flagDisplay
            SeverityScore        = $severityScore
            RunDurationSeconds   = $runDurationSeconds
            RunId                = $r.RunId
            RunResourceId        = if ($r.PSObject.Properties['RunResourceId']) { $r.RunResourceId } else { '' }
            ClusterResourceId    = $r.ClusterResourceId
            Duration             = $r.Duration
            CurrentStepDetail    = $r.CurrentStepDetail
            ErrorMessage         = if ($r.PSObject.Properties['ErrorMessage']) { [string]$r.ErrorMessage } else { '' }
            ErrorDescription     = if ($r.PSObject.Properties['ErrorDescription']) { [string]$r.ErrorDescription } else { '' }
        }
    }
    $rows = @($rows)

    $inFlight         = @($rows | Where-Object { $_.State -eq 'InProgress' })
    $longRunning      = @($inFlight | Where-Object { $_.ExceedsThreshold })
    $longRunningStep  = @($inFlight | Where-Object { $_.ExceedsStepThreshold })
    $stepErrored      = @($inFlight | Where-Object { $_.HasStepError })
    $stalled          = @($inFlight | Where-Object { $_.IsStalled })
    $recentlyFailed   = @($rows     | Where-Object { $_.IsRecentFailure })
    $unresolvedFailed = @($rows     | Where-Object { $_.IsUnresolvedFailure })

    # ---- v0.8.82: UpdateLastAttempt gap reconciliation --------------------
    # Surface clusters whose UpdateLastAttempt tag indicates an attempt was
    # made in the last $RecentAttemptWindowHours that does NOT have a matching
    # observable updateRun in $rows. Captures Portland-style URP-package
    # pre-install health-check failures (audit-log shows 'Apply Succeeded'
    # but no updateRun resource was ever persisted) AND our own pre-update
    # HealthCheckBlocked outcomes AND our own apply/action Failed outcomes.
    $attemptGaps = New-Object 'System.Collections.Generic.List[object]'
    if ($RecentAttemptWindowHours -gt 0 -and $inventoryForTags -and $inventoryForTags.Count -gt 0) {
        $attemptCutoff = $nowUtc.AddHours(-$RecentAttemptWindowHours)
        $runByResId = @{}
        foreach ($r in $rows) {
            if ($r.ClusterResourceId) { $runByResId[[string]$r.ClusterResourceId] = $r }
        }
        foreach ($inv in $inventoryForTags) {
            $tagBag = if ($inv -and $inv.PSObject.Properties['tags']) { $inv.tags } else { $null }
            $tagValue = Get-TagValue -Tags $tagBag -Name $script:UpdateLastAttemptTagName
            if ([string]::IsNullOrWhiteSpace($tagValue)) { continue }
            $parsed = ConvertFrom-AzLocalUpdateLastAttemptTagValue -Value $tagValue
            if (-not $parsed) { continue }
            if ($parsed.AttemptUtc -lt $attemptCutoff) { continue }

            $resId = if ($inv.PSObject.Properties['ResourceId']) { [string]$inv.ResourceId } else { '' }
            $matchedRun = if ($resId -and $runByResId.ContainsKey($resId)) { $runByResId[$resId] } else { $null }
            $hasCoveringRun = $false
            if ($matchedRun -and $matchedRun.StartTimeUtc) {
                [datetime]$rs = [datetime]::MinValue
                if ([datetime]::TryParse([string]$matchedRun.StartTimeUtc, [ref]$rs)) {
                    $runStartUtc = [datetime]::SpecifyKind($rs, [DateTimeKind]::Utc)
                    if ($runStartUtc -ge $parsed.AttemptUtc.AddMinutes(-5)) {
                        $hasCoveringRun = $true
                    }
                }
            }
            if (-not $hasCoveringRun -and $matchedRun -and $matchedRun.UpdateName -eq $parsed.UpdateName -and
                $matchedRun.LastUpdatedUtc) {
                [datetime]$ru = [datetime]::MinValue
                if ([datetime]::TryParse([string]$matchedRun.LastUpdatedUtc, [ref]$ru)) {
                    $runUpdatedUtc = [datetime]::SpecifyKind($ru, [DateTimeKind]::Utc)
                    if ($runUpdatedUtc -ge $parsed.AttemptUtc.AddMinutes(-5)) {
                        $hasCoveringRun = $true
                    }
                }
            }
            if ($hasCoveringRun) { continue }

            $attemptGaps.Add([pscustomobject]@{
                ClusterName       = if ($inv.PSObject.Properties['ClusterName']) { [string]$inv.ClusterName } else { '' }
                ClusterResourceId = $resId
                AttemptUtc        = $parsed.AttemptUtc
                AttemptUtcText    = $parsed.AttemptUtc.ToString('yyyy-MM-dd HH:mm:ssZ')
                Outcome           = $parsed.Outcome
                UpdateName        = $parsed.UpdateName
                Reason            = $parsed.Reason
            }) | Out-Null
        }
    }

    # ---- CSV (always emit, even if empty) ---------------------------------
    if ($rows.Count -gt 0) {
        $rows | Sort-Object @{Expression='SeverityScore';Descending=$true}, ClusterName | Export-Csv -Path $monitorCsv -NoTypeInformation -Encoding utf8
    }
    else {
        '' | Set-Content -LiteralPath $monitorCsv -Encoding utf8
    }

    # ---- JUnit XML via the shared emitter ---------------------------------
    $testCases = New-Object 'System.Collections.Generic.List[hashtable]'
    # v0.8.87: emit per-testcase <properties> (ClusterName / ClusterResourceId /
    # UpdateName / Status / CurrentStep / portal URLs) so the ITSM connector
    # (New-AzLocalIncident) can compute the SHA256 dedupe key and the Mustache
    # body template can deep-link into the Azure portal. The Status property is
    # what Get-AzLocalItsmTriggerDecision matches against the trigger matrix.
    $tcProps = {
        param($row, [string]$statusValue)
        [ordered]@{
            ClusterName        = [string]$row.ClusterName
            ClusterResourceId  = [string]$row.ClusterResourceId
            UpdateName         = [string]$row.UpdateName
            Status             = $statusValue
            CurrentStep        = [string]$row.CurrentStep
            ClusterPortalUrl   = [string]$row.ClusterPortalUrl
            UpdateRunPortalUrl = [string]$row.UpdateRunPortalUrl
        }
    }
    foreach ($r in ($inFlight | Sort-Object @{Expression='SeverityScore';Descending=$true}, ClusterName)) {
        $safeName = ($r.ClusterName -replace '[^A-Za-z0-9_.-]', '_')
        $caseName = "$safeName - $($r.UpdateName) - $($r.CurrentStep)"
        # v0.8.96: STALLED takes top classification priority. An InProgress run
        # whose ARM lastUpdatedTime has frozen past -StalledNoProgressHours is
        # orphaned/stuck, so surface that as the JUnit failure reason. Before
        # this, the cascade only reported step/overall elapsed, so the prominent
        # test-reporter check never mentioned the stall - only the CSV did
        # (the exact gap the Arizona 19444cab run exposed). 'Stalled' is a new
        # ITSM trigger-matrix status key (the sample matrix raises on it).
        if ($r.IsStalled) {
            # v0.8.96: spell out the manual remediation in the failure body. A
            # stalled run still reports InProgress, so the failed-update single-
            # retry job (Invoke-AzLocalFailedUpdateRetry) deliberately SKIPS it -
            # operator action is the only path. Surface the Get-SolutionUpdate /
            # Start-SolutionUpdate flow + the public troubleshooting doc inline.
            $msg = ('STALLED: no orchestration activity for {0} (ARM lastUpdatedTime {1} UTC). The run still reports InProgress but appears orphaned/stuck - the orchestrator likely died mid-step. CurrentStep: {2}. Step elapsed: {3}. Overall elapsed: {4}. Progress: {5}. MANUAL ACTION REQUIRED: this run is NOT auto-retried (it still reports InProgress, so the failed-update single-retry job skips it - that job only acts on terminal NeedsAttention / UpdateFailed / PreparationFailed states). On a cluster node run: Get-SolutionUpdate | Format-Table ResourceId,State,Version; then $u = Get-SolutionUpdate | Where-Object Version -eq <version>; $u | Get-SolutionUpdateRun to inspect the action plan; Start-MonitoringActionplanInstanceToComplete -actionPlanInstanceID <id> to watch it to completion; then $u | Start-SolutionUpdate to resume - or collect logs and open a support ticket if the run is truly orphaned. Docs: https://learn.microsoft.com/azure/azure-local/update/update-troubleshooting-23h2' -f $r.SinceLastUpdateDisplay, $r.LastUpdatedUtc, $r.CurrentStep, $r.StepElapsedDisplay, $r.ElapsedDisplay, $r.Progress)
            $testCases.Add(@{
                Name      = $caseName
                ClassName = 'UpdateMonitor'
                Time      = [double]$r.RunDurationSeconds
                Failure   = @{ Message = $msg; Type = 'Stalled'; Body = $msg }
                Properties = (& $tcProps $r 'Stalled')
            }) | Out-Null
        }
        elseif ($r.HasStepError) {
            # v0.8.80: prefer the deepest step's `description` (human-readable
            # line) PLUS the errorMessage trace when both are present, so the
            # operator sees WHAT failed and WHY in the same cell.
            $errSnippet = if ($r.ErrorDescription -and $r.ErrorMessage) {
                '{0} - {1}' -f $r.ErrorDescription, $r.ErrorMessage
            } elseif ($r.ErrorMessage) {
                $r.ErrorMessage
            } elseif ($r.ErrorDescription) {
                $r.ErrorDescription
            } else {
                '(no errorMessage on deepest failed step)'
            }
            $msg = ('Progress status is Error (state still InProgress) - step is stuck. CurrentStep: {0}. StepElapsed: {1}. ErrorMessage: {2}' -f $r.CurrentStep, $r.StepElapsedDisplay, $errSnippet)
            $testCases.Add(@{
                Name      = $caseName
                ClassName = 'UpdateMonitor'
                Time      = [double]$r.RunDurationSeconds
                Failure   = @{ Message = $msg; Type = 'StepError'; Body = $msg }
                Properties = (& $tcProps $r 'StepError')
            }) | Out-Null
        }
        elseif ($r.ExceedsStepThreshold) {
            $msg = ('Current step elapsed {0} exceeds per-step threshold of {1}h. CurrentStep: {2}. Overall elapsed: {3}. Progress: {4}.' -f $r.StepElapsedDisplay, $r.StepThresholdHours, $r.CurrentStep, $r.ElapsedDisplay, $r.Progress)
            $testCases.Add(@{
                Name      = $caseName
                ClassName = 'UpdateMonitor'
                Time      = [double]$r.RunDurationSeconds
                Failure   = @{ Message = $msg; Type = 'LongRunningStep'; Body = $msg }
                Properties = (& $tcProps $r 'LongRunningStep')
            }) | Out-Null
        }
        elseif ($r.ExceedsThreshold) {
            $msg = ('Overall elapsed {0} exceeds backstop threshold of {1}h (current step within {2}h per-step budget). CurrentStep: {3}. Progress: {4}.' -f $r.ElapsedDisplay, $r.ThresholdHours, $r.StepThresholdHours, $r.CurrentStep, $r.Progress)
            $testCases.Add(@{
                Name      = $caseName
                ClassName = 'UpdateMonitor'
                Time      = [double]$r.RunDurationSeconds
                Failure   = @{ Message = $msg; Type = 'LongRunningOverall'; Body = $msg }
                Properties = (& $tcProps $r 'LongRunningOverall')
            }) | Out-Null
        }
        else {
            $testCases.Add(@{
                Name      = $caseName
                ClassName = 'UpdateMonitor'
                Time      = [double]$r.RunDurationSeconds
                Properties = (& $tcProps $r 'InProgress')
            }) | Out-Null
        }
    }
    foreach ($r in ($unresolvedFailed | Sort-Object @{Expression='EndTimeUtc';Descending=$true})) {
        $safeName = ($r.ClusterName -replace '[^A-Za-z0-9_.-]', '_')
        $caseName = "$safeName - $($r.UpdateName) - FAILED"
        $detail = if ($r.ErrorDescription -and $r.ErrorMessage) {
            '{0} - {1}' -f $r.ErrorDescription, $r.ErrorMessage
        } elseif ($r.ErrorMessage) {
            $r.ErrorMessage
        } elseif ($r.ErrorDescription) {
            $r.ErrorDescription
        } elseif ($r.CurrentStepDetail) {
            $r.CurrentStepDetail
        } else {
            $r.CurrentStep
        }
        $msg = ('Run failed at {0} UTC. Step: {1}. Detail: {2}.' -f $r.EndTimeUtc, $r.CurrentStep, $detail)
        $testCases.Add(@{
            Name      = $caseName
            ClassName = 'UpdateMonitor'
            Time      = [double]$r.RunDurationSeconds
            Failure   = @{ Message = $msg; Type = 'RecentFailure'; Body = $msg }
            Properties = (& $tcProps $r 'Failed')
        }) | Out-Null
    }
    foreach ($gap in ($attemptGaps | Sort-Object @{Expression='AttemptUtc';Descending=$true}, ClusterName)) {
        $safeName = ($gap.ClusterName -replace '[^A-Za-z0-9_.-]', '_')
        $updateLabel = if ([string]::IsNullOrWhiteSpace($gap.UpdateName)) { '(no update name)' } else { $gap.UpdateName }
        $caseName = '{0} - {1} - ATTEMPT-NO-RUN ({2})' -f $safeName, $updateLabel, $gap.Outcome
        $reasonText = if ([string]::IsNullOrWhiteSpace($gap.Reason)) { '(no reason recorded)' } else { $gap.Reason }
        $msg = ("Cluster '{0}' carries an UpdateLastAttempt tag (outcome='{1}', update='{2}', at {3}) but no observable updateRun has materialised. Investigate via the Azure portal activity log; common cause is a URP package pre-install health-check failure (audit event 'Allows to apply updates: Succeeded' with no resulting updateRun). Reason recorded by module: {4}" -f $gap.ClusterName, $gap.Outcome, $updateLabel, $gap.AttemptUtcText, $reasonText)
        $testCases.Add(@{
            Name      = $caseName
            ClassName = 'UpdateMonitor'
            Time      = 0.0
            Failure   = @{ Message = $msg; Type = 'AttemptWithoutRun'; Body = $msg }
            Properties = [ordered]@{
                ClusterName        = [string]$gap.ClusterName
                ClusterResourceId  = [string]$gap.ClusterResourceId
                UpdateName         = $updateLabel
                Status             = 'AttemptWithoutRun'
                CurrentStep        = ''
                ClusterPortalUrl   = if ($gap.ClusterResourceId) { 'https://portal.azure.com/#@/resource' + [string]$gap.ClusterResourceId + '/updates' } else { '' }
                UpdateRunPortalUrl = ''
                Outcome            = [string]$gap.Outcome
                AttemptUtc         = [string]$gap.AttemptUtcText
            }
        }) | Out-Null
    }
    $null = New-AzLocalPipelineJUnitXml -TestSuitesName 'Update Run Monitor' -Suites @(
        @{
            Name      = 'Update Run Monitor'
            ClassName = 'UpdateMonitor'
            TestCases = @($testCases)
        }
    ) -OutputPath $monitorXml

    # ---- Step outputs -----------------------------------------------------
    Set-AzLocalPipelineOutput -Name 'in_flight'           -Value ([string]$inFlight.Count)
    Set-AzLocalPipelineOutput -Name 'long_running'        -Value ([string]$longRunning.Count)
    Set-AzLocalPipelineOutput -Name 'long_running_step'   -Value ([string]$longRunningStep.Count)
    Set-AzLocalPipelineOutput -Name 'step_errored'        -Value ([string]$stepErrored.Count)
    Set-AzLocalPipelineOutput -Name 'stalled'             -Value ([string]$stalled.Count)
    Set-AzLocalPipelineOutput -Name 'recent_failures'     -Value ([string]$recentlyFailed.Count)
    Set-AzLocalPipelineOutput -Name 'unresolved_failures' -Value ([string]$unresolvedFailed.Count)
    Set-AzLocalPipelineOutput -Name 'attempts_without_run' -Value ([string]$attemptGaps.Count)

    # ---- Markdown step summary -------------------------------------------
    $fleetSettings = Get-AzLocalFleetSettings
    $maxSummaryRows = $fleetSettings.MaxRowsPerTable
    $md = New-Object 'System.Collections.Generic.List[string]'
    [void]$md.Add('## In-Flight Update Monitor')
    [void]$md.Add('')
    $skullCount    = @($inFlight | Where-Object { $_.RunSeverity -eq 'skull' }).Count
    $critRunCount  = @($inFlight | Where-Object { $_.RunSeverity -eq 'crit' }).Count
    $critStepCount = @($inFlight | Where-Object { $_.StepSeverity -eq 'crit' }).Count
    $hasCritical   = ($stepErrored.Count -gt 0) -or ($unresolvedFailed.Count -gt 0) -or ($stalled.Count -gt 0) -or ($skullCount -gt 0) -or ($critRunCount -gt 0) -or ($critStepCount -gt 0)
    $warnCount     = @($inFlight | Where-Object { $_.StepSeverity -eq 'warn' -or $_.RunSeverity -eq 'warn' }).Count
    $hasWarn       = ($warnCount -gt 0)
    $statusBadge = if ($hasCritical) {
        $crits = @()
        if ($stepErrored.Count -gt 0)       { $crits += "$($stepErrored.Count) stuck step error(s)" }
        if ($stalled.Count -gt 0)           { $crits += "$($stalled.Count) stalled run(s) (no activity > ${StalledNoProgressHours}h)" }
        if ($skullCount    -gt 0)           { $crits += "$skullCount run(s) > $($CriticalElapsedDays * 2)d" }
        if ($critRunCount  -gt 0)           { $crits += "$critRunCount run(s) > ${CriticalElapsedDays}d" }
        if ($critStepCount -gt 0)           { $crits += "$critStepCount step(s) > $($LongRunningStepHours * 2)h" }
        if ($unresolvedFailed.Count -gt 0)  { $crits += "$($unresolvedFailed.Count) unresolved failure(s)" }
        ':red_circle: **Fleet Status: CRITICAL** - ' + ($crits -join ', ')
    }
    elseif ($hasWarn) {
        ":yellow_circle: **Fleet Status: WARN** - $warnCount long-running run(s)"
    }
    elseif ($inFlight.Count -gt 0) {
        ":green_circle: **Fleet Status: HEALTHY** - $($inFlight.Count) in-flight run(s) within all thresholds"
    }
    else {
        ':white_circle: **Fleet Status: IDLE** - no update runs currently in flight'
    }
    [void]$md.Add($statusBadge)
    [void]$md.Add('')
    $scopeLabel = if ($Scope -eq 'by-update-ring' -and $UpdateRing) { "by-update-ring (UpdateRing = $UpdateRing)" } else { 'all clusters' }
    [void]$md.Add("**Scope**: $scopeLabel - **Per-step warn/crit**: ${LongRunningStepHours}h / $($LongRunningStepHours * 2)h - **Overall warn/crit/skull**: ${LongRunningThresholdHours}h / ${CriticalElapsedDays}d / $($CriticalElapsedDays * 2)d - **Recent-failure window**: ${RecentFailureWindowHours}h - **Snapshot (UTC)**: $($nowUtc.ToString('yyyy-MM-dd HH:mm'))")
    [void]$md.Add('')
    $clustersScoped = @($inventoryForTags).Count
    $formatPercentage = {
        param([int]$Count)
        if ($clustersScoped -eq 0) { return 'N/A' }
        [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}%', (($Count / $clustersScoped) * 100))
    }
    [void]$md.Add('| Metric | Count | Percentage |')
    [void]$md.Add('|--------|-------|------------|')
    [void]$md.Add("| Clusters scoped | $clustersScoped | $(& $formatPercentage $clustersScoped) |")
    [void]$md.Add("| Update runs in flight | $($inFlight.Count) | $(& $formatPercentage $inFlight.Count) |")
    [void]$md.Add("| Step errored (progress.status == 'Error', state still InProgress) | $($stepErrored.Count) | $(& $formatPercentage $stepErrored.Count) |")
    if ($StalledNoProgressHours -gt 0) {
        [void]$md.Add("| Stalled runs (InProgress, no activity > ${StalledNoProgressHours}h) | $($stalled.Count) | $(& $formatPercentage $stalled.Count) |")
    }
    [void]$md.Add("| Step elapsed > ${LongRunningStepHours}h (primary) | $($longRunningStep.Count) | $(& $formatPercentage $longRunningStep.Count) |")
    [void]$md.Add("| Overall elapsed > ${LongRunningThresholdHours}h (backstop) | $($longRunning.Count) | $(& $formatPercentage $longRunning.Count) |")
    [void]$md.Add("| Unresolved-failed runs (latest run is Failed) | $($unresolvedFailed.Count) | $(& $formatPercentage $unresolvedFailed.Count) |")
    if ($RecentFailureWindowHours -gt 0) {
        [void]$md.Add("| Recently-failed runs (last ${RecentFailureWindowHours}h) | $($recentlyFailed.Count) | $(& $formatPercentage $recentlyFailed.Count) |")
    }
    if ($RecentAttemptWindowHours -gt 0) {
        [void]$md.Add("| Update attempts without observable run (last ${RecentAttemptWindowHours}h) | $($attemptGaps.Count) | $(& $formatPercentage $attemptGaps.Count) |")
    }
    [void]$md.Add('')
    if ($inFlight.Count -gt 0 -or $unresolvedFailed.Count -gt 0) {
        # GitHub / ADO step-summary sanitisers strip `target="_blank"`, so the
        # Cluster + Update portal links open in the current tab by default.
        [void]$md.Add('> **Tip:** Hold `Ctrl` (or `Cmd` on macOS) when clicking - or middle-click - Cluster or Update links to open them in a new tab. (GitHub markdown strips `target="_blank"`.)')
        [void]$md.Add('')
    }
    if ($inFlight.Count -gt 0) {
        [void]$md.Add('### In-flight runs (sorted by severity score, worst first)')
        [void]$md.Add('')
        [void]$md.Add('| Cluster | Update | State | Progress Status | Current Step | Progress | Step Started (UTC) | Step Elapsed | Run Started (UTC) | Run Elapsed | Last Activity (UTC) | Flags |')
        [void]$md.Add('|---------|--------|-------|-----------------|--------------|----------|--------------------|--------------|-------------------|-------------|---------------------|-------|')
        foreach ($r in ($inFlight | Sort-Object @{Expression='SeverityScore';Descending=$true}, ClusterName | Select-Object -First $maxSummaryRows)) {
            $cs = if ($r.CurrentStep) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.CurrentStep) } else { '-' }
            $pg = if ($r.Progress) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.Progress) } else { '-' }
            $stepStart = if ($r.StepStartTimeUtc) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.StepStartTimeUtc) } else { '-' }
            $stateCell = if ($r.StateIcon) { "$($r.StateIcon) $($r.State)" } else { [string]$r.State }
            $stateCell = ConvertTo-AzLocalMarkdownTableCell -Value $stateCell
            $statusCell = if (-not $r.Status) { '-' }
                          elseif ($r.StatusIcon) { "$($r.StatusIcon) $($r.Status)" }
                          else { [string]$r.Status }
            $statusCell = ConvertTo-AzLocalMarkdownTableCell -Value $statusCell
            $stepElPrefix = switch ($r.StepSeverity) { 'crit' { ':rotating_light: ' } 'warn' { ':warning: ' } default { '' } }
            $runElPrefix  = switch ($r.RunSeverity)  { 'skull' { ':skull: ' } 'crit' { ':rotating_light: ' } 'warn' { ':warning: ' } default { '' } }
            $stepEl = if ($r.StepElapsedDisplay) { $stepElPrefix + $r.StepElapsedDisplay } else { '-' }
            $runEl  = if ($r.ElapsedDisplay)     { $runElPrefix  + $r.ElapsedDisplay }     else { '-' }
            # Last Activity column surfaces ARM lastUpdatedTime + how long since the
            # run resource last advanced. A continuously-bumping value = healthy
            # progress; a frozen value (with the stalled chip) = orphaned run.
            $lastAct = if ($r.LastUpdatedUtc) {
                $sinceTxt = if ($r.SinceLastUpdateDisplay) { ' (' + $r.SinceLastUpdateDisplay + ' ago)' } else { '' }
                $stallPrefix = if ($r.IsStalled) { ':zzz: ' } else { '' }
                $stallPrefix + $r.LastUpdatedUtc + $sinceTxt
            } else { '-' }
            $flagCell = if ($r.Flags) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.Flags) } else { '-' }
            # target="_blank" intentionally omitted: GitHub Actions + ADO step-summary
            # markdown sanitisers strip it (and force `rel="nofollow"`). The Tip above
            # the table tells operators to Ctrl-click to open in a new tab.
            $clusterLabel = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.ClusterName)
            $updateLabel  = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.UpdateName)
            $clusterCell = if ($r.ClusterPortalUrl)   { '<a href="' + $r.ClusterPortalUrl   + '">' + $clusterLabel + '</a>' } else { $clusterLabel }
            $updateCell  = if ($r.UpdateRunPortalUrl) { '<a href="' + $r.UpdateRunPortalUrl + '">' + $updateLabel  + '</a>' } else { $updateLabel }
            $runStartCell = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.StartTimeUtc)
            [void]$md.Add("| $clusterCell | $updateCell | $stateCell | $statusCell | $cs | $pg | $stepStart | $stepEl | $runStartCell | $runEl | $lastAct | $flagCell |")
        }
        if ($inFlight.Count -gt $maxSummaryRows) {
            [void]$md.Add('')
            [void]$md.Add("_Showing $maxSummaryRows of $($inFlight.Count) in-flight runs, worst first. Download ``$CsvFileName`` for the full list._")
        }
        # v0.8.96: when any in-flight row is stalled/orphaned, spell out the
        # manual remediation under the table. These runs still report InProgress
        # so the failed-update single-retry job skips them - operator action only.
        if (@($inFlight | Where-Object { $_.IsStalled }).Count -gt 0) {
            [void]$md.Add('')
            [void]$md.Add('> :zzz: **Stalled / orphaned run(s) detected.** A run flagged `stalled` still reports `InProgress` but its ARM `lastUpdatedTime` has frozen past the threshold, so it is **not** auto-retried by the failed-update single-retry job (that job only acts on terminal `NeedsAttention` / `UpdateFailed` / `PreparationFailed` states). **Manual action required:** on a cluster node run `Get-SolutionUpdate | Format-Table ResourceId,State,Version`, then `$u = Get-SolutionUpdate | Where-Object Version -eq <version>; $u | Get-SolutionUpdateRun` to inspect the action plan, `Start-MonitoringActionplanInstanceToComplete -actionPlanInstanceID <id>` to watch it to completion, then `$u | Start-SolutionUpdate` to resume - or collect logs and open a support ticket if the run is truly orphaned. Docs: [Troubleshoot solution updates for Azure Local](https://learn.microsoft.com/azure/azure-local/update/update-troubleshooting-23h2).')
        }
        [void]$md.Add('')
    }
    else {
        [void]$md.Add('### No update runs currently in flight')
        [void]$md.Add('')
        [void]$md.Add('No clusters in scope have a latest run in state `InProgress`. To verify scope, see the artifact CSV (`update-monitor.csv`).')
        [void]$md.Add('')
    }
    if ($unresolvedFailed.Count -gt 0) {
        [void]$md.Add('### Failed runs (latest run is Failed, unresolved - shown regardless of age)')
        [void]$md.Add('')
        [void]$md.Add('| Cluster | Update | Ended (UTC) | Failed Step | Verbose Error Details | Recent |')
        [void]$md.Add('|---------|--------|-------------|-------------|-----------------------|--------|')
        foreach ($r in ($unresolvedFailed | Sort-Object @{Expression='EndTimeUtc';Descending=$true} | Select-Object -First $maxSummaryRows)) {
            $cs = if ($r.CurrentStep) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.CurrentStep) } else { '-' }
            # v0.8.80: combine the deepest step's description (the human
            # 'what step was running') with its errorMessage (the trace).
            # Falls back through ErrorMessage -> ErrorDescription -> CurrentStepDetail.
            $rawDetail = if ($r.ErrorDescription -and $r.ErrorMessage) {
                ('{0}{1}{1}Trace: {2}' -f $r.ErrorDescription, [System.Environment]::NewLine, $r.ErrorMessage)
            } elseif ($r.ErrorMessage) {
                [string]$r.ErrorMessage
            } elseif ($r.ErrorDescription) {
                [string]$r.ErrorDescription
            } elseif ($r.CurrentStepDetail) {
                [string]$r.CurrentStepDetail
            } else { '' }
            $detailCell = if ([string]::IsNullOrWhiteSpace($rawDetail)) { '_(no error detail)_' } else {
                $e = $rawDetail -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
                $e = $e -replace "`r`n",'<br>' -replace "`n",'<br>' -replace '\|','\|'
                '<details><summary>Show error</summary><br><code>' + $e + '</code></details>'
            }
            $recentTag = if ($r.IsRecentFailure) { ":fire: last ${RecentFailureWindowHours}h" } else { '-' }
            # target="_blank" intentionally omitted (see in-flight table above).
            $clusterLabel = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.ClusterName)
            $updateLabel  = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.UpdateName)
            $clusterCell = if ($r.ClusterPortalUrl)   { '<a href="' + $r.ClusterPortalUrl   + '">' + $clusterLabel + '</a>' } else { $clusterLabel }
            $updateCell  = if ($r.UpdateRunPortalUrl) { '<a href="' + $r.UpdateRunPortalUrl + '">' + $updateLabel  + '</a>' } else { $updateLabel }
            [void]$md.Add("| $clusterCell | $updateCell | $($r.EndTimeUtc) | $cs | $detailCell | $recentTag |")
        }
        if ($unresolvedFailed.Count -gt $maxSummaryRows) {
            [void]$md.Add('')
            [void]$md.Add("_Showing $maxSummaryRows of $($unresolvedFailed.Count) unresolved failed runs, most recent first. Download ``$CsvFileName`` for the full list._")
        }
        [void]$md.Add('')
    }
    if ($attemptGaps.Count -gt 0) {
        [void]$md.Add("### Recent update attempts with no observable updateRun (last ${RecentAttemptWindowHours}h)")
        [void]$md.Add('')
        [void]$md.Add('Sourced from the per-cluster `UpdateLastAttempt` tag (set by `Start-AzLocalClusterUpdate`). The most common cause is a URP package pre-install health-check failure: the cluster activity log shows `Allows to apply updates: Succeeded` but no `updateRun` child resource is ever persisted, so the standard "Failed runs" table cannot see it.')
        [void]$md.Add('')
        [void]$md.Add('| Cluster | Outcome | Update | Attempted (UTC) | Reason |')
        [void]$md.Add('|---------|---------|--------|-----------------|--------|')
        foreach ($gap in ($attemptGaps | Sort-Object @{Expression='AttemptUtc';Descending=$true}, ClusterName | Select-Object -First $maxSummaryRows)) {
            $clusterCell = Get-AzLocalClusterPortalLink -ClusterName ([string]$gap.ClusterName) -ClusterResourceId ([string]$gap.ClusterResourceId) -MarkdownTableCell
            $updateLabel = if ([string]::IsNullOrWhiteSpace($gap.UpdateName)) { '-' } else { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$gap.UpdateName) }
            $reasonText = if ([string]::IsNullOrWhiteSpace($gap.Reason)) { '-' } else {
                ConvertTo-AzLocalMarkdownTableCell -Value ([string]$gap.Reason)
            }
            $outcomeCell = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$gap.Outcome)
            $attemptTimeCell = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$gap.AttemptUtcText)
            [void]$md.Add("| $clusterCell | $outcomeCell | $updateLabel | $attemptTimeCell | $reasonText |")
        }
        if ($attemptGaps.Count -gt $maxSummaryRows) {
            [void]$md.Add('')
            [void]$md.Add("_Showing $maxSummaryRows of $($attemptGaps.Count) recent attempt gaps, most recent first. Download ``$CsvFileName`` for the full list._")
        }
        [void]$md.Add('')
        [void]$md.Add('> **What this means.** The module recorded an apply attempt against this cluster, but the corresponding `updateRun` resource cannot be queried via Azure Resource Graph. Either URP rejected the orchestration after the audit-log `apply/action` succeeded (typical for package-internal pre-install health failures), or the run was created and then deleted before this report ran.')
        [void]$md.Add('>')
        [void]$md.Add('> **Diagnosis (in order):**')
        [void]$md.Add('>')
        [void]$md.Add('> 1. **Azure portal -> cluster blade -> Activity Log** - filter on `Allows to apply updates` for the timestamp above. A successful audit event with no follow-on `updateRuns` PUT confirms URP swallowed the attempt.')
        [void]$md.Add('> 2. **Azure portal -> cluster blade -> Updates** - check whether an `updateRun` exists in `Pending` / `InProgress` that ARG simply has not surfaced yet (rare, but can happen around RP failover).')
        [void]$md.Add('> 3. **URP service health (process of elimination, last resort).** If the activity log shows no errors and no in-portal updateRun exists, bounce the URP cluster groups on the target cluster to ensure the in-cluster Update RP is online. Run the following on **any node of the cluster** (Failover Clustering cmdlets, must be local to the cluster):')
        [void]$md.Add('>')
        [void]$md.Add('> ```powershell')
        [void]$md.Add('> # Check current owner + state first:')
        [void]$md.Add('> Get-ClusterGroup ''Azure Stack HCI Update Service Cluster Group'', ''Azure Stack HCI Orchestrator Service Cluster Group'' |')
        [void]$md.Add('>     Format-Table Name, OwnerNode, State')
        [void]$md.Add('>')
        [void]$md.Add('> # Multi-node clusters: failover ownership (zero-downtime, ~10s):')
        [void]$md.Add('> Move-ClusterGroup ''Azure Stack HCI Update Service Cluster Group''')
        [void]$md.Add('> Get-ClusterGroup  ''Azure Stack HCI Update Service Cluster Group'' |')
        [void]$md.Add('>     Format-Table Name, OwnerNode, State')
        [void]$md.Add('>')
        [void]$md.Add('> # Single-node clusters, or if the move alone did not recover:')
        [void]$md.Add('> Get-ClusterGroup ''Azure Stack HCI Update Service Cluster Group'' | Stop-ClusterGroup')
        [void]$md.Add('> Get-ClusterGroup ''Azure Stack HCI Update Service Cluster Group'' | Start-ClusterGroup')
        [void]$md.Add('> Get-ClusterGroup ''Azure Stack HCI Update Service Cluster Group'' |')
        [void]$md.Add('>     Format-Table Name, OwnerNode, State')
        [void]$md.Add('> ```')
        [void]$md.Add('>')
        [void]$md.Add('> The companion `Azure Stack HCI Orchestrator Service Cluster Group` (ECE control plane) can be bounced the same way **only if no updateRun is actively in progress** - bouncing ECE during a healthy in-flight run will interrupt it. Re-run the Monitor Updates pipeline after the cluster groups report `State = Online` to confirm the attempt-gap clears or reproduces.')
        [void]$md.Add('')
    }
    if (($stepErrored.Count + $longRunningStep.Count + $longRunning.Count + $unresolvedFailed.Count) -gt 0) {
        [void]$md.Add('> **Action required.** One or more update runs have errored, hit a threshold, or have an unresolved Failed latest run. Common causes (consult the Azure Local Update Manager portal + the cluster activity log for the affected cluster(s)):')
        [void]$md.Add('>')
        [void]$md.Add('> - Health check failures (storage / network / cluster service) blocking the run from progressing')
        [void]$md.Add('> - Node drain stuck (VM live-migration timeout, anti-affinity blocking move)')
        [void]$md.Add('> - Sideloaded payload / pre-staged content mismatch on one or more nodes')
        [void]$md.Add('> - ARB (Arc Resource Bridge) connectivity loss or extension-version drift')
        [void]$md.Add('>')
        [void]$md.Add('> Troubleshooting guides:')
        [void]$md.Add('> - **Microsoft Learn:** [Troubleshoot update failures (Azure Local 23H2)](https://learn.microsoft.com/azure/azure-local/update/update-troubleshooting-23h2#troubleshoot-update-failures)')
        [void]$md.Add('> - **GitHub TSG:** [Azure/AzureLocal-Supportability/TSG/Update](https://github.com/Azure/AzureLocal-Supportability/tree/main/TSG/Update)')
        [void]$md.Add('>')
        [void]$md.Add('> The Checks tab shows the same rows as JUnit failures (`StepError`, `LongRunningStep`, `LongRunningOverall`, `RecentFailure`).')
        [void]$md.Add('')
    }
    elseif ($inFlight.Count -gt 0) {
        [void]$md.Add("> **All in-flight runs are healthy (no step errors, per-step <=${LongRunningStepHours}h, overall <=${LongRunningThresholdHours}h) and no unresolved failures.**")
        [void]$md.Add('')
    }
    [void]$md.Add('_Source data: `Get-AzLocalUpdateRuns -Latest -PassThru`. JUnit emitted as `' + $monitorXml + '`; full per-cluster rows in `' + $monitorCsv + '`._')
    if ($InstalledModuleVersion) {
        [void]$md.Add('')
        [void]$md.Add(('_Generated by AzLocal.UpdateManagement v{0}._' -f $InstalledModuleVersion))
    }

    Add-AzLocalPipelineStepSummary -Markdown ($md -join [Environment]::NewLine) -SummaryFileName $SummaryFileName | Out-Null

    if ($PassThru) {
        return [pscustomobject]@{
            InFlightCount          = [int]$inFlight.Count
            LongRunningCount       = [int]$longRunning.Count
            LongRunningStepCount   = [int]$longRunningStep.Count
            StepErroredCount       = [int]$stepErrored.Count
            StalledCount           = [int]$stalled.Count
            RecentFailureCount     = [int]$recentlyFailed.Count
            UnresolvedFailureCount = [int]$unresolvedFailed.Count
            AttemptWithoutRunCount = [int]$attemptGaps.Count
            AttemptGaps            = $attemptGaps.ToArray()
            CsvPath                = $monitorCsv
            XmlPath                = $monitorXml
            Rows                   = $rows
        }
    }
}
