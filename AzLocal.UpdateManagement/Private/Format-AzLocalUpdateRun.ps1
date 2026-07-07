function Format-AzLocalUpdateRun {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param($run, $clusterName = "", $clusterResourceId = "")

    $props = $run.properties

    # Resolve EndTime once via the central helper (used for both display and Duration fallback).
    $endTimeDt = Get-AzLocalRunEndTime -props $props
    $endTimeDisplay = if ($endTimeDt) { $endTimeDt.ToString("yyyy-MM-dd HH:mm") } else { "" }

    # v0.8.95: capture properties.lastUpdatedTime - the wall-clock instant the
    # ARM update-run resource was last mutated by the orchestrator. This is the
    # authoritative "is this run still alive?" signal. A healthy InProgress run
    # has its lastUpdatedTime bumped continuously; an ORPHANED run (orchestrator
    # died mid-step) keeps State=InProgress forever but lastUpdatedTime freezes.
    # Surfaced so callers can detect a stalled run that is making zero progress
    # (e.g. Arizona run 19444cab: timeStarted 2026-05-21, duration frozen at
    # PT9M33S, lastUpdatedTime never advanced past 2026-05-21 - yet ARM still
    # reports InProgress 30+ days later). Format-only: no behaviour change here.
    $lastUpdatedDt = $null
    if ($props.PSObject.Properties['lastUpdatedTime'] -and $props.lastUpdatedTime) {
        try { $lastUpdatedDt = [datetime]$props.lastUpdatedTime } catch { $null = $_ <# malformed lastUpdatedTime; leave blank #> }
    }
    $lastUpdatedDisplay = if ($lastUpdatedDt) { $lastUpdatedDt.ToString("yyyy-MM-dd HH:mm") } else { "" }

    # Duration: prefer ARM-reported properties.duration (ISO-8601, e.g. "PT8H37M58S")
    # because it's authoritative and immune to clock skew. Fall back to
    # EndTime - StartTime, then to "running" for in-flight runs.
    $duration = ""
    $durationSpan = $null
    if ($props.PSObject.Properties['duration'] -and $props.duration) {
        try { $durationSpan = [System.Xml.XmlConvert]::ToTimeSpan([string]$props.duration) } catch { $null = $_ <# malformed ISO-8601 duration; fall through to EndTime-StartTime fallback #> }
    }
    if (-not $durationSpan -and $props.timeStarted -and $endTimeDt) {
        try { $durationSpan = $endTimeDt - [datetime]$props.timeStarted } catch { $null = $_ <# malformed timeStarted; leave duration blank #> }
    }
    if ($durationSpan) {
        $duration = Format-AzLocalDurationHuman -Value $durationSpan
    }
    elseif ($props.timeStarted -and $props.state -eq "InProgress") {
        try {
            $runningSpan = (Get-Date) - [datetime]$props.timeStarted
            $human = Format-AzLocalDurationHuman -Value $runningSpan
            if ($human) { $duration = "$human (running)" }
        } catch { $null = $_ <# malformed timeStarted on in-flight run; leave duration blank #> }
    }

    $currentStep = ""
    $currentStepDetail = ""
    $progress = ""
    $stepStartTimeDisplay = ""
    $stepElapsedDisplay = ""
    # Surfaced separately from State (v0.7.96) - exposes the portal 'Status' filter value.
    # Operationally critical: a run can sit at State=InProgress for days while progress.status
    # already shows 'Error', telling the operator a step has errored and the run is stuck.
    # v0.9.17: guard `progress` itself (not just its children) - a failed run's ARM
    # `properties` can omit `progress` entirely, and a `progress` object can omit `steps`.
    # Bare `$props.progress` / `$props.progress.steps` reads THROW under
    # Set-StrictMode -Version Latest (observed live: Tacoma retry -> "The property
    # 'steps' cannot be found on this object").
    $hasProgress = ($props.PSObject.Properties['progress'] -and $props.progress)
    $progressStatus = if ($hasProgress -and $props.progress.PSObject.Properties['status']) { [string]$props.progress.status } else { '' }
    $errorMessage = ''
    $errorDescription = ''
    if ($hasProgress -and $props.progress.PSObject.Properties['steps'] -and $props.progress.steps) {
        $steps = $props.progress.steps
        # Progress must reflect the DEEP nested step tree, not the top-level wrapper steps.
        # Real Azure Local update runs expose only ~2 coarse top-level steps ("Prepare update"
        # Success + "Start update" InProgress/Error), so counting the top level alone reported a
        # near-constant "1/2 steps" for the entire multi-hour run regardless of real progress
        # (validated against live ARM data: a 7-level / 167-leaf run still showed top-level 1/2).
        # Get-AzLocalUpdateRunStepStats walks to the leaf steps (the atomic work units) so the
        # numerator climbs as the install proceeds, mirroring how CurrentStep already traverses
        # the full tree via Get-DeepestActiveStep.
        $stepStats = Get-AzLocalUpdateRunStepStats -Steps $steps
        if ($stepStats.TotalLeaf -gt 0) {
            $pct = [int][math]::Round((($stepStats.CompletedLeaf / $stepStats.TotalLeaf) * 100))
            $progress = "$($stepStats.CompletedLeaf)/$($stepStats.TotalLeaf) steps ($pct%)"
            if ($stepStats.FailedLeaf -gt 0) {
                $progress = "$progress, $($stepStats.FailedLeaf) failed"
            }
        }
        else {
            # Defensive fallback: no leaf steps resolved (e.g. an empty nested array). Use the
            # top-level Success count so the column is never blank. Guarded property read keeps
            # this safe under Set-StrictMode -Version Latest.
            $completedSteps = @($steps | Where-Object { $_.PSObject.Properties['status'] -and $_.status -eq 'Success' }).Count
            $totalSteps = @($steps).Count
            $progress = "$completedSteps/$totalSteps steps"
        }

        # Resolve the deepest InProgress/Error/Failed step in the nested progress tree.
        # The top-level steps array only exposes a coarse wrapper step (e.g. "Start update")
        # that stays InProgress for the entire run, so selecting the first InProgress/Failed
        # step from that level alone always reported the wrapper as the "current step".
        # Walking to the deepest active step keeps CurrentStep consistent with
        # CurrentStepDetail and the standard update-progress output, both of which already
        # traverse the full tree.
        $deepestActive = Get-DeepestActiveStep -Steps $steps
        if ($deepestActive) {
            if ($deepestActive.status -in @("Error", "Failed")) {
                $currentStep = "$($deepestActive.name) (FAILED)"
            }
            else {
                $currentStep = $deepestActive.name
            }
        }

        $currentStepDetail = Get-CurrentStepPath -Steps $steps -IncludeErrorMessage
        if ([string]::IsNullOrWhiteSpace($currentStepDetail)) {
            $currentStepDetail = $currentStep
        }
        if ($currentStepDetail -match 'health check' -and $props.state -eq 'Failed') {
            if ($currentStepDetail -notmatch 'Critical health issues') {
                $currentStepDetail = "$currentStepDetail - Critical health issues must be resolved before updates can proceed"
            }
        }

        # Per-step elapsed (v0.7.96): use the deepest InProgress/Failed step (resolved above)
        # and surface its startTimeUtc + computed elapsed. This is the primary "is something
        # stuck?" signal for large-node clusters where overall-run duration alone is unreliable
        # (a 16-node legitimate run can easily exceed 8h while every individual step ticks along
        # normally).

        # Deepest non-empty errorMessage from any Error/Failed step in the tree (v0.7.96).
        # Uses a coalesce(e8Msg..e1Msg) recursion so operators see the actual leaf failure
        # (e.g. CAU exception) rather than the generic parent step name.
        # v0.8.80: also capture the deepest step's `description` (human-readable line) so
        # the Step.08 monitor renderer can show BOTH the description and the errorMessage
        # trace in the same cell. Previously the description was silently dropped.
        $deepest = Get-DeepestErrorMessage -Steps $steps -IncludeDescription
        $errorMessage = if ($deepest -is [hashtable]) { [string]$deepest.Msg } else { [string]$deepest }
        $errorDescription = if ($deepest -is [hashtable]) { [string]$deepest.Description } else { '' }
        if ($deepestActive -and $deepestActive.PSObject.Properties['startTimeUtc'] -and $deepestActive.startTimeUtc) {
            try {
                $stepStartDt = [datetime]::SpecifyKind(([datetime]$deepestActive.startTimeUtc).ToUniversalTime(), [DateTimeKind]::Utc)
                $stepStartTimeDisplay = $stepStartDt.ToString('yyyy-MM-dd HH:mm')
                $stepSpan = $null
                if ($props.state -eq 'InProgress' -and $deepestActive.status -eq 'InProgress') {
                    $stepSpan = (Get-Date).ToUniversalTime() - $stepStartDt
                    $human = Format-AzLocalDurationHuman -Value $stepSpan
                    if ($human) { $stepElapsedDisplay = "$human (running)" }
                }
                elseif ($deepestActive.PSObject.Properties['endTimeUtc'] -and $deepestActive.endTimeUtc) {
                    try {
                        $stepEndDt = [datetime]::SpecifyKind(([datetime]$deepestActive.endTimeUtc).ToUniversalTime(), [DateTimeKind]::Utc)
                        $stepSpan = $stepEndDt - $stepStartDt
                        $human = Format-AzLocalDurationHuman -Value $stepSpan
                        if ($human) { $stepElapsedDisplay = $human }
                    } catch { $null = $_ <# malformed endTimeUtc on deepest step; leave step elapsed blank #> }
                }
            } catch { $null = $_ <# malformed startTimeUtc on deepest step; leave step start/elapsed blank #> }
        }
    }

    $updateNameExtracted = ""
    $runId = ""
    if ($run.id -match '/updates/([^/]+)/updateRuns/([^/]+)$') {
        $updateNameExtracted = $matches[1]
        $runId = $matches[2]
    }
    elseif ($run.name -match '/([^/]+)$') {
        $runId = $matches[1]
    }
    else {
        $runId = $run.name
    }

    $result = [PSCustomObject]@{
        UpdateName        = $updateNameExtracted
        RunId             = $runId
        RunResourceId     = if ($run.PSObject.Properties['id']) { [string]$run.id } else { '' }
        State             = $props.state
        Status            = $progressStatus
        StartTime         = if ($props.timeStarted) { ([datetime]$props.timeStarted).ToString("yyyy-MM-dd HH:mm") } else { "" }
        EndTime           = $endTimeDisplay
        LastUpdatedTime   = $lastUpdatedDisplay
        Duration          = $duration
        Progress          = $progress
        CurrentStep       = $currentStep
        CurrentStepDetail = $currentStepDetail
        StepStartTime     = $stepStartTimeDisplay
        StepElapsed       = $stepElapsedDisplay
        ErrorMessage      = $errorMessage
        ErrorDescription  = $errorDescription
        # v0.9.17: guard `location` - a failed run's ARM `properties` can omit it,
        # and a bare read THROWS under Set-StrictMode -Version Latest (observed live:
        # Arizona retry -> "The property 'location' cannot be found on this object").
        Location          = if ($props.PSObject.Properties['location']) { $props.location } else { '' }
    }

    if ($clusterName) {
        $result | Add-Member -NotePropertyName "ClusterName" -NotePropertyValue $clusterName -Force
    }

    if ($clusterResourceId) {
        $result | Add-Member -NotePropertyName "ClusterResourceId" -NotePropertyValue $clusterResourceId -Force
    }

    return $result
}
