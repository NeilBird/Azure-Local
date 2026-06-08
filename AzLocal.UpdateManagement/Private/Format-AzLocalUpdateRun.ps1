function Format-AzLocalUpdateRun {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param($run, $clusterName = "", $clusterResourceId = "")

    $props = $run.properties

    # Resolve EndTime once via the central helper (used for both display and Duration fallback).
    $endTimeDt = Get-AzLocalRunEndTime -props $props
    $endTimeDisplay = if ($endTimeDt) { $endTimeDt.ToString("yyyy-MM-dd HH:mm") } else { "" }

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
    # Surfaced separately from State (v0.7.96) - mirrors the LENS-Workbook 'Status' filter.
    # Operationally critical: a run can sit at State=InProgress for days while progress.status
    # already shows 'Error', telling the operator a step has errored and the run is stuck.
    $progressStatus = if ($props.progress -and $props.progress.PSObject.Properties['status']) { [string]$props.progress.status } else { '' }
    $errorMessage = ''
    if ($props.progress -and $props.progress.steps) {
        $steps = $props.progress.steps
        # Wrap in @() so .Count returns 0 (not $null) when no step matches -- previously the
        # "completed" numerator rendered blank for runs that failed before any step succeeded.
        $completedSteps = @($steps | Where-Object { $_.status -eq "Success" }).Count
        $totalSteps = @($steps).Count
        $progress = "$completedSteps/$totalSteps steps"

        $inProgressStep = $steps | Where-Object { $_.status -eq "InProgress" } | Select-Object -First 1
        $failedStep = $steps | Where-Object { $_.status -in @("Error", "Failed") } | Select-Object -First 1

        if ($inProgressStep) {
            $currentStep = $inProgressStep.name
        }
        elseif ($failedStep) {
            $currentStep = "$($failedStep.name) (FAILED)"
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

        # Per-step elapsed (v0.7.96): walk to the deepest InProgress/Failed step and surface its
        # startTimeUtc + computed elapsed. This is the primary "is something stuck?" signal for
        # large-node clusters where overall-run duration alone is unreliable (a 16-node legitimate
        # run can easily exceed 8h while every individual step ticks along normally).
        $deepestActive = Get-DeepestActiveStep -Steps $steps

        # Deepest non-empty errorMessage from any Error/Failed step in the tree (v0.7.96).
        # Mirrors the LENS-Workbook coalesce(e8Msg..e1Msg) pattern so operators see the actual
        # leaf failure (e.g. CAU exception) rather than the generic parent step name.
        $errorMessage = Get-DeepestErrorMessage -Steps $steps
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
        Duration          = $duration
        Progress          = $progress
        CurrentStep       = $currentStep
        CurrentStepDetail = $currentStepDetail
        StepStartTime     = $stepStartTimeDisplay
        StepElapsed       = $stepElapsedDisplay
        ErrorMessage      = $errorMessage
        Location          = $props.location
    }

    if ($clusterName) {
        $result | Add-Member -NotePropertyName "ClusterName" -NotePropertyValue $clusterName -Force
    }

    if ($clusterResourceId) {
        $result | Add-Member -NotePropertyName "ClusterResourceId" -NotePropertyValue $clusterResourceId -Force
    }

    return $result
}
