function Get-AzLocalApplyScheduleSourceBanner {
    <#
    .SYNOPSIS
        Builds a short operator-facing markdown banner that explains, for a
        SCHEDULE-triggered (cron) apply-updates run, that the targeted
        UpdateRing(s) are derived from the caller's apply-updates-schedule.yml,
        which cycle day the current run falls on, and which rings that maps to.

    .DESCRIPTION
        v0.9.17. Rendered at the TOP of both the "Check Cluster Readiness"
        (readiness gate) and the "Apply Updates" step summaries so it is clear
        the pipeline acts ONLY on the operator's own schedule configuration -
        no rings are chosen by the tooling.

        The banner is SELF-CONTAINED and read-only: it detects the pipeline
        host + trigger, resolves the schedule file path the same way
        Resolve-AzLocalPipelineUpdateRing does (APPLY_UPDATES_SCHEDULE_PATH env
        or the host default), re-reads the schedule and resolves the current
        (cycleWeek, dayOfWeek) -> ring mapping for display.

        It returns an EMPTY array (renders nothing) when:
          - the trigger is not a schedule/cron firing (manual runs are opt-out
            of this banner per design - the operator chose the ring), OR
          - no schedule file is present at the resolved path, OR
          - the schedule cannot be read/resolved (never blocks the run - the
            banner is purely informational).

    .PARAMETER SchedulePath
        Path to apply-updates-schedule.yml. Defaults to env var
        APPLY_UPDATES_SCHEDULE_PATH, or './.github/apply-updates-schedule.yml'
        (GitHub) / './apply-updates-schedule.yml' (Azure DevOps / Local).

    .PARAMETER ResolveForDateUtc
        Optional 'yyyy-MM-dd' UTC date to resolve for (preview). Empty = now.

    .PARAMETER Trigger
        'Manual' or 'Schedule'. Auto-detected from the pipeline host when
        omitted (GitHub: GITHUB_EVENT_NAME != 'workflow_dispatch' is Schedule;
        ADO: BUILD_REASON == 'Schedule').

    .PARAMETER IncludeAuditRecommendation
        Switch. When set, appends a line recommending the operator run the
        'Config: 3 - Apply-Updates Schedule Coverage Audit' pipeline for the
        full per-day view of their entire cycle. Used on the Apply Updates
        step banner.

    .OUTPUTS
        [string[]] - markdown lines (blockquote paragraph), or empty array.

    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.9.17
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$SchedulePath = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ResolveForDateUtc = '',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Manual', 'Schedule', '')]
        [string]$Trigger = '',

        [switch]$IncludeAuditRecommendation
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

    # Trigger auto-detection (host-specific) - mirrors Resolve-AzLocalPipelineUpdateRing.
    if (-not $Trigger) {
        switch ($pipelineHost) {
            'GitHub' {
                $eventName = $env:GITHUB_EVENT_NAME
                if (-not $eventName) { $eventName = 'workflow_dispatch' }
                $Trigger = if ($eventName -eq 'workflow_dispatch') { 'Manual' } else { 'Schedule' }
            }
            'AzureDevOps' {
                $buildReason = $env:BUILD_REASON
                $Trigger = if ($buildReason -eq 'Schedule') { 'Schedule' } else { 'Manual' }
            }
            default {
                $Trigger = 'Manual'
            }
        }
    }

    # Banner is only for schedule/cron firings - a manual run chose its own ring.
    if ($Trigger -ne 'Schedule') { return @() }

    # SchedulePath default (host-specific) - mirrors Resolve-AzLocalPipelineUpdateRing.
    if (-not $SchedulePath) {
        $envPath = $env:APPLY_UPDATES_SCHEDULE_PATH
        if ($envPath) {
            $SchedulePath = $envPath
        }
        else {
            $SchedulePath = if ($pipelineHost -eq 'GitHub') { './.github/apply-updates-schedule.yml' } else { './apply-updates-schedule.yml' }
        }
    }

    if (-not (Test-Path -LiteralPath $SchedulePath)) { return @() }

    $resolveAt = [datetime]::UtcNow
    if (-not [string]::IsNullOrWhiteSpace($ResolveForDateUtc)) {
        try {
            $resolveAt = [datetime]::ParseExact(
                $ResolveForDateUtc.Trim(),
                'yyyy-MM-dd',
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
            )
        }
        catch {
            $null = $_  # malformed preview date - fall back to now, never block the banner
        }
    }

    try {
        $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath
        $decision = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $resolveAt
    }
    catch {
        # Purely informational - never let a schedule read/parse issue break the run.
        Write-Verbose ("Get-AzLocalApplyScheduleSourceBanner: could not resolve schedule '{0}': {1}" -f $SchedulePath, $_.Exception.Message)
        return @()
    }

    $cycleWeek  = [int]$decision.CycleWeek
    $cycleTotal = [int]$cfg.CycleWeeks
    $dayName    = [string]$decision.DayOfWeekName
    $dateDisplay = $decision.NowUtc.ToString('yyyy-MM-dd')
    $ringsMatched = @($decision.Rings)
    $hasRings   = ($ringsMatched.Count -gt 0)
    $ringsDisplay = if ($hasRings) { ($ringsMatched -join ', ') } else { '' }

    $bt = [string][char]96  # backtick, to emit markdown code spans without escaping

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("> **Schedule-driven run - targeting is derived from your own configuration.**")
    $lines.Add("> ")
    $lines.Add("> The UpdateRing(s) this run targets are read from your apply-updates schedule file " + $bt + $SchedulePath + $bt + " (in your own repository) - not chosen by the pipeline.")
    $lines.Add("> ")
    if ($hasRings) {
        $lines.Add("> Today - **$dayName, $dateDisplay UTC** - is **cycle week $cycleWeek of $cycleTotal**, which your schedule maps to ring(s): **$ringsDisplay**.")
    }
    else {
        $lines.Add("> Today - **$dayName, $dateDisplay UTC** - is **cycle week $cycleWeek of $cycleTotal**, which your schedule maps to **no rings**, so this run will make no changes.")
    }
    $lines.Add("> ")
    $lines.Add("> This pipeline acts only on the rings your schedule marks eligible for the current cycle day; no other clusters are touched, and each cluster is gated by its " + $bt + "UpdateStartWindow" + $bt + " tag value, which is UTC.")
    if ($IncludeAuditRecommendation) {
        $lines.Add("> ")
        $lines.Add("> To review your entire cycle at a glance (every date mapped to its eligible rings), run the **'Config: 3 - Apply-Updates Schedule Coverage Audit'** pipeline and review its output.")
    }
    $lines.Add("")

    return $lines.ToArray()
}
