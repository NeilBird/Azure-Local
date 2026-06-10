function Resolve-AzLocalPipelineUpdateRing {
    <#
    .SYNOPSIS
        Resolves the UpdateRing (and optional AllowedUpdateVersions allow-list)
        for the current pipeline firing, from either an operator-supplied
        manual input or apply-updates-schedule.yml.
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Replaces the ~80-line inline `run:`
        block that lived in both Step.6_apply-updates.yml pipelines (GitHub
        Actions + Azure DevOps).

        Three resolution paths:
          1. Manual trigger + UseScheduleFile=$false (back-compat):
             - Returns ManualUpdateRing verbatim. No schedule file read.
             - AllowedUpdateVersions is empty (the cmdlet's default 'latest
               Ready update', or operator-supplied -UpdateName, applies).
          2. Manual trigger + UseScheduleFile=$true:
             - Reads apply-updates-schedule.yml and runs the ring/AllowedUpdateVersions
               resolver against UtcNow OR a user-supplied ResolveForDateUtc.
          3. Schedule trigger:
             - Reads apply-updates-schedule.yml and runs the resolver against
               UtcNow (ResolveForDateUtc is ignored for schedule firings).

        Side effects:
          - Emits two cross-job step outputs via Set-AzLocalPipelineOutput:
              RESOLVED_UPDATE_RING               (e.g. 'Wave1' or 'Prod;Ring2' or '')
              RESOLVED_ALLOWED_UPDATE_VERSIONS   (';'-joined allow-list or '')
          - On GitHub Actions, ALSO appends both to $env:GITHUB_ENV so later
            steps in the same job can consume via $env:RESOLVED_UPDATE_RING.
          - Throws on hard failures (missing schedule file when one is
            required; malformed ResolveForDateUtc).

        Byte-for-byte output preservation: the emitted step output names and
        formats match the prior inline `run:` block exactly so downstream
        cross-job/cross-stage variable bindings keep working unchanged.
    .PARAMETER ManualUpdateRing
        Operator-supplied UpdateRing tag value (single 'Wave1', list
        'Prod;Ring2', or '***' for ALL). Used when -Trigger is 'Manual' AND
        -UseScheduleFile is not set. Required in that combination.
    .PARAMETER UseScheduleFile
        Switch. When set, force-runs the schedule-file resolver even when the
        trigger is 'Manual' (preview / re-run-missed-day use case).
    .PARAMETER SchedulePath
        Path to apply-updates-schedule.yml. Defaults to env var
        APPLY_UPDATES_SCHEDULE_PATH, or './.github/apply-updates-schedule.yml'
        (GitHub) / './apply-updates-schedule.yml' (Azure DevOps / Local).
    .PARAMETER ResolveForDateUtc
        Only honoured when -Trigger='Manual' AND -UseScheduleFile is set.
        UTC date string in 'yyyy-MM-dd' to resolve the schedule for (preview
        a future cycleWeek/dayOfWeek). Empty/whitespace = UtcNow.
    .PARAMETER Trigger
        'Manual' or 'Schedule'. Auto-detected from the pipeline host when
        omitted (GitHub: GITHUB_EVENT_NAME != 'workflow_dispatch' is Schedule;
        ADO: BUILD_REASON == 'Schedule').
    .PARAMETER PassThru
        Switch. Returns a PSCustomObject with: ResolvedUpdateRing,
        ResolvedAllowedUpdateVersions, IsManual, UseScheduleFile, ResolveAt,
        SchedulePath, Decision (Resolve-AzLocalCurrentUpdateRing output or
        $null for back-compat manual path).
    .EXAMPLE
        # Schedule trigger (cron firing) - resolves from default path.
        Resolve-AzLocalPipelineUpdateRing
    .EXAMPLE
        # Manual trigger, pass operator input through verbatim.
        Resolve-AzLocalPipelineUpdateRing -Trigger Manual -ManualUpdateRing 'Wave1'
    .EXAMPLE
        # Manual trigger, override into schedule-resolver preview mode.
        Resolve-AzLocalPipelineUpdateRing -Trigger Manual `
            -ManualUpdateRing 'Wave1' `
            -UseScheduleFile `
            -ResolveForDateUtc '2026-07-15' `
            -PassThru
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.5 (Step.6 thin-YAML port)
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ManualUpdateRing = '',

        [switch]$UseScheduleFile,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$SchedulePath = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ResolveForDateUtc = '',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Manual', 'Schedule', '')]
        [string]$Trigger = '',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

    # Trigger auto-detection (host-specific).
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

    $isManual = ($Trigger -eq 'Manual')

    # SchedulePath default (host-specific).
    if (-not $SchedulePath) {
        $envPath = $env:APPLY_UPDATES_SCHEDULE_PATH
        if ($envPath) {
            $SchedulePath = $envPath
        }
        else {
            $SchedulePath = if ($pipelineHost -eq 'GitHub') { './.github/apply-updates-schedule.yml' } else { './apply-updates-schedule.yml' }
        }
    }

    $resolved = ''
    $resolvedAllow = ''
    $resolveAt = [datetime]::UtcNow
    $decision = $null

    if ($isManual -and -not $UseScheduleFile) {
        # Back-compat path: manual ring verbatim, schedule file ignored.
        if ([string]::IsNullOrWhiteSpace($ManualUpdateRing)) {
            throw "Resolve-AzLocalPipelineUpdateRing: Trigger='Manual' with UseScheduleFile=`$false requires -ManualUpdateRing to be non-empty. Supply -ManualUpdateRing (e.g. 'Wave1', 'Prod;Ring2', or '***'), OR set -UseScheduleFile to resolve from apply-updates-schedule.yml."
        }
        $resolved = $ManualUpdateRing
        Write-Host "Trigger='Manual', UseScheduleFile=`$false - using manual input UpdateRing='$resolved' (schedule file ignored). AllowedUpdateVersions is not applied for manual runs - the cmdlet's default 'latest Ready update' (or -UpdateName) is used."
    }
    else {
        # Schedule trigger OR manual-with-schedule-file: same resolver pipeline.
        $modeLabel = "Trigger='$Trigger'"
        if ($isManual -and $UseScheduleFile) {
            $modeLabel = "Trigger='Manual', UseScheduleFile=`$true"
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
                    throw "Resolve-AzLocalPipelineUpdateRing: -ResolveForDateUtc='$ResolveForDateUtc' is not a valid date. Use YYYY-MM-DD (e.g. 2026-07-15), or leave empty to resolve for today (UTC)."
                }
                Write-Host "$modeLabel - resolving UpdateRing from schedule file '$SchedulePath' for date $($resolveAt.ToString('yyyy-MM-dd')) UTC (PREVIEW - operator-supplied date)."
            }
            else {
                Write-Host "$modeLabel - resolving UpdateRing from schedule file '$SchedulePath' for today UTC."
            }
        }
        else {
            Write-Host "$modeLabel - resolving UpdateRing from schedule file '$SchedulePath' (UTC now)."
        }

        if (-not (Test-Path -LiteralPath $SchedulePath)) {
            $hint = if ($isManual) {
                "Manual trigger with -UseScheduleFile requires a schedule file at this path."
            }
            else {
                "The apply-updates pipeline was triggered by a schedule event but no schedule file is present."
            }
            throw "Resolve-AzLocalPipelineUpdateRing: apply-updates-schedule.yml not found at '$SchedulePath'. $hint Generate a STRAWMAN from your fleet via: New-AzLocalApplyUpdatesScheduleConfig -OutputPath '$SchedulePath' (then review and UNCOMMENT at least one row before re-running). Set APPLY_UPDATES_SCHEDULE_PATH if you keep the schedule elsewhere."
        }

        $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath
        $decision = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $resolveAt
        Write-Host "Resolver decision: $($decision.Reason)"

        if ($decision.Rings -and $decision.Rings.Count -gt 0) {
            $resolved = $decision.UpdateRingValue
            Write-Host "Resolved UpdateRing='$resolved' (cycleWeek=$($decision.CycleWeek), dayOfWeek=$($decision.DayOfWeekName))."
            if ($decision.AllowedUpdateVersions -and $decision.AllowedUpdateVersions.Count -gt 0) {
                $resolvedAllow = $decision.AllowedUpdateVersionsValue
                Write-Host "Resolved AllowedUpdateVersions ($($decision.AllowedUpdateVersionsSource)): $resolvedAllow"
            }
            else {
                Write-Host "Resolved AllowedUpdateVersions: <none> - apply-updates will install the latest Ready update on each cluster."
            }
        }
        else {
            # Preserve original Step.6 severity per host (GH=notice, ADO=warning).
            switch ($pipelineHost) {
                'GitHub'      { Write-Host "::notice title=No UpdateRing scheduled for this firing::$($decision.Reason)" }
                'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]No UpdateRing scheduled for this firing: $($decision.Reason)" }
                default       { Write-Host "[notice] No UpdateRing scheduled for this firing: $($decision.Reason)" }
            }
            Write-Host "Setting resolved UpdateRing to empty - check-readiness will report ready_count=0 and apply-updates will be skipped cleanly."
            $resolved = ''
        }
    }

    # Bridge: cross-job step outputs (GitHub: GITHUB_OUTPUT; ADO: isOutput=true).
    Set-AzLocalPipelineOutput -Name 'RESOLVED_UPDATE_RING'              -Value $resolved      -CrossJob
    Set-AzLocalPipelineOutput -Name 'RESOLVED_ALLOWED_UPDATE_VERSIONS'  -Value $resolvedAllow -CrossJob

    # GitHub-only: ALSO append to GITHUB_ENV so same-job downstream steps can
    # read via $env:RESOLVED_*. Azure DevOps already achieves this via the
    # isOutput=true variable being readable in the same job as $(name.var).
    if ($pipelineHost -eq 'GitHub' -and $env:GITHUB_ENV) {
        "RESOLVED_UPDATE_RING=$resolved"                | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
        "RESOLVED_ALLOWED_UPDATE_VERSIONS=$resolvedAllow" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    }

    if ($PassThru) {
        return [pscustomobject]@{
            ResolvedUpdateRing            = $resolved
            ResolvedAllowedUpdateVersions = $resolvedAllow
            IsManual                      = $isManual
            UseScheduleFile               = [bool]$UseScheduleFile
            ResolveAt                     = $resolveAt
            SchedulePath                  = $SchedulePath
            Decision                      = $decision
        }
    }
}
