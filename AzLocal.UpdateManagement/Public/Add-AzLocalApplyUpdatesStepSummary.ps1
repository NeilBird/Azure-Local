function Add-AzLocalApplyUpdatesStepSummary {
    <#
    .SYNOPSIS
        Renders the Update Application Summary markdown for the apply-updates
        job in Step.6. Replaces ~100 lines of inline `run:` summary boilerplate
        in both Step.6 pipeline YAMLs.
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Emits the same markdown layout the
        prior inline blocks produced:
          - H1: 'Update Application Summary' (ADO) / H2 (GitHub - already
            inside a single $GITHUB_STEP_SUMMARY file).
          - Target UpdateRing line.
          - 'This was a dry run' note when -DryRun is set.
          - Readiness KPI table (Total / Ready).
          - Results KPI table (the seven status buckets).
          - Cluster Actions table read from apply-results.json (when present).
          - Clusters Skipped at Readiness Gate table read from
            readiness-report.csv (when present, capped at MaxSkippedRows).
          - Actions Required bullet list (one bullet per non-zero blocking
            bucket, with the same operator-facing remediation text).

        Per-host emoji choice (preserved byte-for-byte from the prior inline
        blocks):
          - GitHub Actions   : Unicode emoji glyphs (U+2705 / U+274C / U+26D4 / U+23ED).
          - Azure DevOps     : GitHub-Markdown shortcode tokens
                               (:white_check_mark: / :x: / :no_entry: /
                               :next_track_button: / :warning:).
          - Local            : same as GitHub (Unicode emoji glyphs).
    .PARAMETER UpdateRing
        Resolved UpdateRing label (string).
    .PARAMETER DryRun
        Switch. When set, the dry-run note is rendered and Actions Required
        is suppressed (matching prior inline behaviour on ADO).
    .PARAMETER TotalCount
        Readiness total count (string-or-int accepted; coerced to string for
        display, to int for KPI checks).
    .PARAMETER ReadyCount
        Readiness ready count.
    .PARAMETER Succeeded
        Apply succeeded count.
    .PARAMETER Skipped
        Apply skipped count.
    .PARAMETER Failed
        Apply failed count.
    .PARAMETER HealthBlocked
        Apply health-blocked count.
    .PARAMETER ScheduleBlocked
        Apply schedule-blocked count.
    .PARAMETER SideloadedBlocked
        Apply sideloaded-blocked count.
    .PARAMETER ExcludedByTag
        Apply excluded-by-tag count.
    .PARAMETER ApplyResultsJsonPath
        Path to apply-results.json written by Invoke-AzLocalReadinessGatedClusterUpdate.
        When the file is missing the Cluster Actions table is omitted.
    .PARAMETER ReadinessCsvPath
        Path to readiness-report.csv. When missing the Clusters Skipped table
        is omitted.
    .PARAMETER MaxClusterActionRows
        Maximum cluster action rows rendered. Default 200 (the prior inline
        block had no explicit cap - the entire list was rendered).
    .PARAMETER MaxSkippedRows
        Maximum skipped-cluster rows rendered. Default 100 (matches prior).
    .PARAMETER SummaryFileName
        Per-task markdown filename (ADO/Local only). Default
        'azlocal-step6-apply-summary.md'.
    .PARAMETER PassThru
        Returns PSCustomObject with: SummaryPath, ActionsRequiredCount,
        ClusterActionsRendered, SkippedClustersRendered.
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.5 (Step.6 thin-YAML port)
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$UpdateRing,

        [switch]$DryRun,

        [Parameter(Mandatory = $false)] [object]$TotalCount        = 0,
        [Parameter(Mandatory = $false)] [object]$ReadyCount        = 0,
        [Parameter(Mandatory = $false)] [object]$Succeeded         = 0,
        [Parameter(Mandatory = $false)] [object]$Skipped           = 0,
        [Parameter(Mandatory = $false)] [object]$Failed            = 0,
        [Parameter(Mandatory = $false)] [object]$HealthBlocked     = 0,
        [Parameter(Mandatory = $false)] [object]$ScheduleBlocked   = 0,
        [Parameter(Mandatory = $false)] [object]$SideloadedBlocked = 0,
        [Parameter(Mandatory = $false)] [object]$ExcludedByTag     = 0,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ApplyResultsJsonPath = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ReadinessCsvPath = '',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [int]$MaxClusterActionRows = 200,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [int]$MaxSkippedRows = 100,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-step6-apply-summary.md',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost
    $useShortcodeIcons = ($pipelineHost -eq 'AzureDevOps')

    # Unicode emoji glyphs (GH/Local) vs GitHub-Markdown shortcodes (ADO).
    $iconSuccess = if ($useShortcodeIcons) { ':white_check_mark:' } else { [string][char]0x2705 }
    $iconFail    = if ($useShortcodeIcons) { ':x:' }                else { [string][char]0x274C }
    $iconBlock   = if ($useShortcodeIcons) { ':no_entry:' }         else { [string][char]0x26D4 }
    $iconSkip    = if ($useShortcodeIcons) { ':next_track_button:' } else { ([string][char]0x23ED + [string][char]0xFE0F) }
    $iconWarn    = if ($useShortcodeIcons) { ':warning:' }          else { ([string][char]0x26A0 + [string][char]0xFE0F) }

    $headingLevel = if ($pipelineHost -eq 'AzureDevOps') { '#' } else { '##' }

    # Coerce numeric inputs.
    $totalInt           = [int]([string]$TotalCount)
    $readyInt           = [int]([string]$ReadyCount)
    $succeededInt       = [int]([string]$Succeeded)
    $skippedInt         = [int]([string]$Skipped)
    $failedInt          = [int]([string]$Failed)
    $healthBlockedInt   = [int]([string]$HealthBlocked)
    $scheduleBlockedInt = [int]([string]$ScheduleBlocked)
    $sideloadedInt      = [int]([string]$SideloadedBlocked)
    $excludedTagInt     = [int]([string]$ExcludedByTag)

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("$headingLevel Update Application Summary")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("**Target UpdateRing:** $UpdateRing")
    [void]$sb.AppendLine()

    if ($DryRun) {
        [void]$sb.AppendLine("**This was a dry run. No updates were applied.**")
        [void]$sb.AppendLine()
    }

    $h3 = if ($pipelineHost -eq 'AzureDevOps') { '##' } else { '###' }

    [void]$sb.AppendLine("$h3 Readiness")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Metric | Count |')
    [void]$sb.AppendLine('|--------|-------|')
    [void]$sb.AppendLine("| Total Clusters | $totalInt |")
    [void]$sb.AppendLine("| Ready for Update | $readyInt |")
    [void]$sb.AppendLine()

    [void]$sb.AppendLine("$h3 Results")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Status | Count |')
    [void]$sb.AppendLine('|--------|-------|')
    [void]$sb.AppendLine("| Updates Started | $succeededInt |")
    [void]$sb.AppendLine("| Skipped | $skippedInt |")
    [void]$sb.AppendLine("| Failed | $failedInt |")
    [void]$sb.AppendLine("| Health Blocked | $healthBlockedInt |")
    [void]$sb.AppendLine("| Schedule Blocked | $scheduleBlockedInt |")
    [void]$sb.AppendLine("| Sideloaded Blocked | $sideloadedInt |")
    [void]$sb.AppendLine("| Excluded By Tag | $excludedTagInt |")

    $actionsRendered = 0

    # Per-cluster apply results table (from apply-results.json).
    if ($ApplyResultsJsonPath -and (Test-Path -LiteralPath $ApplyResultsJsonPath)) {
        $applyRows = @(Get-Content -Raw -Path $ApplyResultsJsonPath | ConvertFrom-Json)
        if ($applyRows.Count -gt 0) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("$h3 Cluster Actions ($($applyRows.Count) cluster(s))")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('| Cluster | Status | Update | Duration | Message |')
            [void]$sb.AppendLine('|---|---|---|---|---|')
            $startedStates = @('UpdateStarted', 'Started', 'Success')
            $blockedStates = @('HealthCheckBlocked', 'ScheduleBlocked', 'SideloadedBlocked', 'ExcludedByTag', 'NotConnected')
            $failedStates  = @('Failed', 'Error', 'NotFound')
            foreach ($r in ($applyRows | Sort-Object Status, ClusterName)) {
                if ($actionsRendered -ge $MaxClusterActionRows) { break }
                $st = "$($r.Status)"
                $icon = if ($startedStates -contains $st) { $iconSuccess }
                        elseif ($failedStates -contains $st) { $iconFail }
                        elseif ($blockedStates -contains $st) { $iconBlock }
                        else { $iconSkip }
                $upd = if ($r.UpdateName) { '`' + $r.UpdateName + '`' } else { '-' }
                $dur = if ($r.Duration) { "$($r.Duration)" } else { '-' }
                $msg = "$($r.Message)"
                if ($msg.Length -gt 180) { $msg = $msg.Substring(0, 177) + '...' }
                $msg = $msg -replace '\|', '\|' -replace '\r?\n', ' '
                [void]$sb.AppendLine("| ``$($r.ClusterName)`` | $icon $st | $upd | $dur | $msg |")
                $actionsRendered++
            }
        }
    }

    # Clusters Skipped at Readiness Gate table (from readiness-report.csv).
    $skippedRendered = 0
    if ($ReadinessCsvPath -and (Test-Path -LiteralPath $ReadinessCsvPath)) {
        $blockedRows = @(Import-Csv -Path $ReadinessCsvPath | Where-Object { $_.ReadyForUpdate -ne 'True' })
        if ($blockedRows.Count -gt 0) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("$h3 Clusters Skipped at Readiness Gate ($($blockedRows.Count) cluster(s))")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('_These clusters were assessed by Check Update Readiness but not handed to Apply Updates. Resolve the listed blocking reasons (or wait for them to clear) then re-run the pipeline._')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('| Cluster | Update State | Health | Current Version | Recommended | Blocking Reasons |')
            [void]$sb.AppendLine('|---|---|---|---|---|---|')
            foreach ($b in ($blockedRows | Sort-Object UpdateState, ClusterName)) {
                if ($skippedRendered -ge $MaxSkippedRows) { break }
                $blocking = "$($b.BlockingReasons)"
                if ($blocking.Length -gt 200) { $blocking = $blocking.Substring(0, 197) + '...' }
                $blocking = $blocking -replace '\|', '\|' -replace '\r?\n', ' '
                $reco = if ($b.RecommendedUpdate) { '`' + $b.RecommendedUpdate + '`' } else { '-' }
                $curr = if ($b.CurrentVersion) { '`' + $b.CurrentVersion + '`' } else { '-' }
                $hSt  = "$($b.HealthState)"
                $hCell = switch -Regex ($hSt) {
                    '^Success$' { "$iconSuccess $hSt"; break }
                    '^Warning$' { "$iconWarn $hSt"; break }
                    '^Failure$' { "$iconFail $hSt"; break }
                    default     { $hSt }
                }
                [void]$sb.AppendLine("| ``$($b.ClusterName)`` | $($b.UpdateState) | $hCell | $curr | $reco | $blocking |")
                $skippedRendered++
            }
            if ($blockedRows.Count -gt $MaxSkippedRows) {
                [void]$sb.AppendLine()
                [void]$sb.AppendLine("_Showing first $MaxSkippedRows of $($blockedRows.Count) skipped clusters. Download the readiness-report.csv artifact for the full list._")
            }
        }
    }

    # Actions Required section (suppressed when -DryRun was set, matching ADO
    # prior behaviour). GitHub always rendered it - keep consistent: emit
    # when there is at least one actionable bucket regardless of dry-run.
    # NOTE: prior GH inline block rendered Actions Required even on dry-run,
    # so we match GH and ALWAYS rendered when non-dry; for dry-run we skip
    # on ADO (matching ADO prior behaviour) but emit on GitHub.
    $shouldRenderActions = if ($DryRun -and $pipelineHost -eq 'AzureDevOps') { $false } else { $true }
    $actionsNeeded = @()
    if ($shouldRenderActions) {
        if ($failedInt -gt 0)          { $actionsNeeded += "- **$failedInt cluster(s) failed** - Review pipeline logs and cluster health in Azure Portal" }
        if ($healthBlockedInt -gt 0)   { $actionsNeeded += "- **$healthBlockedInt cluster(s) blocked by health checks** - Resolve critical health failures before retrying" }
        if ($scheduleBlockedInt -gt 0) { $actionsNeeded += "- **$scheduleBlockedInt cluster(s) outside maintenance window** - Updates will proceed when the cluster's UpdateStartWindow schedule allows, or re-run during the maintenance window" }
        if ($sideloadedInt -gt 0)      { $actionsNeeded += "- **$sideloadedInt cluster(s) blocked by UpdateSideloaded=False** - Operator must stage the sideloaded payload and flip the tag to True (or run Reset-AzLocalSideloadedTag) before updates can proceed" }
        if ($excludedTagInt -gt 0)     { $actionsNeeded += "- **$excludedTagInt cluster(s) excluded by UpdateExcluded=True operator override** - Flip the cluster's UpdateExcluded tag to False (Azure portal or 'az tag update') once the cluster should rejoin automation" }
    }
    if ($actionsNeeded.Count -gt 0) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("$h3 Actions Required")
        [void]$sb.AppendLine()
        foreach ($a in $actionsNeeded) { [void]$sb.AppendLine($a) }
    }

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown $sb.ToString() -SummaryFileName $SummaryFileName

    if ($PassThru) {
        return [pscustomobject]@{
            SummaryPath             = $summaryPath
            ActionsRequiredCount    = $actionsNeeded.Count
            ClusterActionsRendered  = $actionsRendered
            SkippedClustersRendered = $skippedRendered
        }
    }
}
