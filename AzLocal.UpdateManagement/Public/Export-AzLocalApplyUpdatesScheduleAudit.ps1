function Export-AzLocalApplyUpdatesScheduleAudit {
    <#
    .SYNOPSIS
        Runs the Step.3 Apply-Updates Schedule Coverage Audit workload:
        Test-AzLocalApplyUpdatesScheduleCoverage (Audit + Matrix +
        Recommend views) + JUnit XML + markdown step summary + cycle
        calendar + allow-list coverage + step outputs for the v0.8.5
        thin-YAML Step.3 pipeline.

    .DESCRIPTION
        Phase 1 (v0.8.5) of the thin-YAML refactor. Condenses the
        ~220-line inline `run: |` audit block and the ~210-line inline
        Create Summary block in v0.8.4 Step.3_apply-updates-schedule-
        audit.yml (GitHub Actions + Azure DevOps) into a single cmdlet
        call so the per-platform yml shrinks to a few lines and the
        workload becomes unit-testable against synthetic schedule and
        pipeline YAML inputs.

        The cmdlet:

          1. Resolves the output directory (defaults to './reports' on
             GitHub Actions / Local, or `$env:BUILD_ARTIFACTSTAGINGDIRECTORY`
             on Azure DevOps).
          2. Calls `Test-AzLocalApplyUpdatesScheduleCoverage` 3 times:
             -View Audit -PassThru (rows + CSV), -View Matrix
             (CSV only), -View Recommend (markdown only). Re-uses the
             v0.7.65+ advisor instead of re-implementing the
             ring/cron diff math inline.
          3. Bucketises rows by Status into Covered / Uncovered /
             PartiallyCovered / MalformedTag / UnparseableCron /
             NoWindowTag / RingMissingFromSchedule /
             RingOrphanedInSchedule / RingMixedWindows.
          4. Builds a JUnit XML report via the shared
             `New-AzLocalPipelineJUnitXml` Private helper. Schedule
             rows go in the 'Schedule (ring diff)' suite FIRST
             (higher blast radius), Cron rows in the 'Cron coverage'
             suite. Any non-Covered status becomes a <failure>.
          5. Emits 12 step outputs via `Set-AzLocalPipelineOutput`
             (lowercase snake_case per v0.8.5 convention):
             total_rows, covered, uncovered, partial, malformed,
             unparseable, no_window_tag, ring_missing, ring_orphan,
             ring_mixed, have_schedule, schedule_path.
          6. Builds the markdown step summary:
             - Summary counts table (10 rows)
             - Recommend snippet at the top when $hasIssues
             - Audit Detail - Schedule (ring-file gap) sub-table
               (rendered whenever -SchedulePath was supplied)
             - Allow-list coverage section (renders schema v1
               migration nudge or schema v2 per-row effective
               allow-list with optional pin-snippet)
             - Audit Detail - Cron coverage sub-table
             - Recommend snippet at the bottom when clean fleet
             - **Cycle calendar** - ALWAYS rendered when
               -SchedulePath is supplied (v0.8.5 fix for the v0.8.4
               $hasIssues-gate regression that silently dropped the
               calendar from clean-fleet runs).
             - Reports list with artifact filenames
          7. Pushes the markdown via `Add-AzLocalPipelineStepSummary`.

        Internal reuse (per the v0.8.5 thin-YAML consistency contract):
          * `Test-AzLocalApplyUpdatesScheduleCoverage` for advisor data.
          * `Get-AzLocalApplyUpdatesScheduleConfig` for allow-list / cycle.
          * `Get-AzLocalApplyUpdatesScheduleCycleCalendar -AsMarkdown
            -IncludePerRingSummary` for the calendar section.
          * `New-AzLocalPipelineJUnitXml` for JUnit XML.
          * `Add-AzLocalPipelineStepSummary` for the rendered markdown.
          * `Set-AzLocalPipelineOutput` for the step outputs.
          * `Get-AzLocalPipelineHost` is implicit (the above branch on it).

    .PARAMETER OutputDirectory
        Directory to write artifacts into. Created if it does not exist.
        Defaults to './reports' (GH / Local) or
        `$env:BUILD_ARTIFACTSTAGINGDIRECTORY` (Azure DevOps).

    .PARAMETER PipelineYamlPath
        Path (file or folder) to Step.6_apply-updates.yml. REQUIRED so
        the Recommend view can diff its proposed crons against what is
        already in Step.6 and only emit a snippet for the truly missing
        entries.

    .PARAMETER SchedulePath
        Optional path to apply-updates-schedule.yml. When set, the audit
        also reports RingMissingFromSchedule / RingOrphanedInSchedule
        rows, the Allow-list coverage section, and the always-rendered
        Cycle calendar.

    .PARAMETER LeadTimeMinutes
        Minutes before UpdateStartWindow opens that the pipeline should
        fire (0-60). Default 5.

    .PARAMETER RecommendFiresPerWindow
        Cron entries the Recommend view should emit per UpdateStartWindow
        segment. 1 = opening edge only. 2 = belt-and-braces (default).

    .PARAMETER IncludeUntagged
        Surface clusters with no UpdateStartWindow tag as their own row.

    .PARAMETER ClusterCsvPath
        Optional path to the source-controlled cluster inventory CSV.
        When set (and the file exists) the Recommend view emits a
        NoWindowTag remediation section.

    .PARAMETER Platform
        Pipeline platform for the Recommend snippet:
        GitHubActions (default in pipeline contexts), AzureDevOps, Both.

    .PARAMETER AuditCsvFileName
        Filename for the per-(Ring, Window) audit CSV.
        Default 'schedule-coverage-audit.csv'.

    .PARAMETER MatrixCsvFileName
        Filename for the matrix-view CSV. Default 'schedule-coverage-matrix.csv'.

    .PARAMETER RecommendMdFileName
        Filename for the Recommend snippet markdown.
        Default 'schedule-coverage-recommend.md'.

    .PARAMETER JUnitXmlFileName
        Filename for the JUnit XML report.
        Default 'schedule-coverage-audit.xml'.

    .PARAMETER SummaryFileName
        Per-task markdown summary filename used by
        `Add-AzLocalPipelineStepSummary` on Azure DevOps and Local hosts.
        Default 'schedule-coverage-summary.md'.

    .PARAMETER InstalledModuleVersion
        Optional [string] used in the markdown footer
        ('Generated by AzLocal.UpdateManagement v<x>').

    .PARAMETER PassThru
        When set, returns a single PSCustomObject summarising the run.
        Without -PassThru the cmdlet emits nothing to the pipeline; the
        artifacts and step outputs are still produced.

    .OUTPUTS
        Nothing by default. When -PassThru is set, a single PSCustomObject
        with: TotalRows, Covered, Uncovered, Partial, Malformed,
        Unparseable, NoWindowTag, RingMissing, RingOrphan, RingMixed,
        HaveSchedule, SchedulePath, AuditRows, AuditCsvPath,
        MatrixCsvPath, RecommendMdPath, JUnitXmlPath, SummaryPath.

    .EXAMPLE
        Export-AzLocalApplyUpdatesScheduleAudit `
            -PipelineYamlPath '.github/workflows' `
            -SchedulePath '.github/apply-updates-schedule.yml' `
            -Platform GitHubActions -PassThru

    .NOTES
        Author:  Neil Bird, MSFT
        Added:   v0.8.5
        Module:  AzLocal.UpdateManagement
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PipelineYamlPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$SchedulePath,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$LeadTimeMinutes = 5,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 2)]
        [int]$RecommendFiresPerWindow = 2,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUntagged,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$ClusterCsvPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('GitHubActions', 'AzureDevOps', 'Both')]
        [string]$Platform = 'GitHubActions',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$AuditCsvFileName = 'schedule-coverage-audit.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$MatrixCsvFileName = 'schedule-coverage-matrix.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RecommendMdFileName = 'schedule-coverage-recommend.md',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$JUnitXmlFileName = 'schedule-coverage-audit.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'schedule-coverage-summary.md',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$InstalledModuleVersion,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

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

    if (-not (Test-Path -LiteralPath $PipelineYamlPath)) {
        throw "PipelineYamlPath '$PipelineYamlPath' does not exist. Set it to the folder containing Step.6_apply-updates.yml (e.g. '.github/workflows' or '.azure-pipelines') so the Recommend view can diff its proposed crons against the existing file."
    }

    $haveSchedule = $false
    if ($SchedulePath -and (Test-Path -LiteralPath $SchedulePath)) {
        $haveSchedule = $true
    }
    $haveCsv = $false
    if ($ClusterCsvPath -and (Test-Path -LiteralPath $ClusterCsvPath)) {
        $haveCsv = $true
    }

    $auditCsv  = Join-Path -Path $OutputDirectory -ChildPath $AuditCsvFileName
    $matrixCsv = Join-Path -Path $OutputDirectory -ChildPath $MatrixCsvFileName
    $recoMd    = Join-Path -Path $OutputDirectory -ChildPath $RecommendMdFileName
    $xmlPath   = Join-Path -Path $OutputDirectory -ChildPath $JUnitXmlFileName

    Write-Host '========================================'
    Write-Host 'Apply-Updates Schedule Coverage Audit'
    Write-Host '========================================'
    Write-Host "PipelineYamlPath : $PipelineYamlPath"
    Write-Host "SchedulePath     : $(if ($haveSchedule) { $SchedulePath } else { '(skipped - empty or missing)' })"
    Write-Host "LeadTimeMinutes  : $LeadTimeMinutes"
    Write-Host "FiresPerWindow   : $RecommendFiresPerWindow"
    Write-Host "IncludeUntagged  : $IncludeUntagged"
    Write-Host "ClusterCsvPath   : $(if ($haveCsv) { $ClusterCsvPath } else { '(skipped - empty or missing)' })"
    Write-Host "Platform         : $Platform"
    Write-Host ''

    # ---- Audit view (rows + CSV) ------------------------------------------
    $auditArgs = @{
        View                    = 'Audit'
        LeadTimeMinutes         = $LeadTimeMinutes
        RecommendFiresPerWindow = $RecommendFiresPerWindow
        ExportPath              = $auditCsv
        Platform                = $Platform
        PassThru                = $true
        PipelineYamlPath        = $PipelineYamlPath
    }
    if ($haveSchedule) { $auditArgs.SchedulePath   = $SchedulePath }
    if ($IncludeUntagged) { $auditArgs.IncludeUntagged = $true }
    if ($haveCsv)      { $auditArgs.ClusterCsvPath = $ClusterCsvPath }
    $audit = Test-AzLocalApplyUpdatesScheduleCoverage @auditArgs
    if (-not $audit) { $audit = @() }
    $audit = @($audit)

    # ---- Matrix view (CSV only) -------------------------------------------
    Test-AzLocalApplyUpdatesScheduleCoverage -View Matrix `
        -LeadTimeMinutes $LeadTimeMinutes -ExportPath $matrixCsv | Out-Null

    # ---- Recommend view (markdown only) -----------------------------------
    $recoArgs = @{
        View                    = 'Recommend'
        LeadTimeMinutes         = $LeadTimeMinutes
        RecommendFiresPerWindow = $RecommendFiresPerWindow
        Platform                = $Platform
        ExportPath              = $recoMd
        PipelineYamlPath        = $PipelineYamlPath
    }
    if ($haveSchedule) { $recoArgs.SchedulePath   = $SchedulePath }
    if ($haveCsv)      { $recoArgs.ClusterCsvPath = $ClusterCsvPath }
    Test-AzLocalApplyUpdatesScheduleCoverage @recoArgs | Out-Null

    # ---- Bucketise --------------------------------------------------------
    $covered     = @($audit | Where-Object { $_.Status -eq 'Covered' })
    $uncovered   = @($audit | Where-Object { $_.Status -eq 'Uncovered' })
    $partial     = @($audit | Where-Object { $_.Status -eq 'PartiallyCovered' })
    $malformed   = @($audit | Where-Object { $_.Status -eq 'MalformedTag' })
    $unparseable = @($audit | Where-Object { $_.Status -eq 'UnparseableCron' })
    $noWindowTag = @($audit | Where-Object { $_.Status -eq 'NoWindowTag' })
    $ringMissing = @($audit | Where-Object { $_.Status -eq 'RingMissingFromSchedule' })
    $ringOrphan  = @($audit | Where-Object { $_.Status -eq 'RingOrphanedInSchedule' })
    $ringMixed   = @($audit | Where-Object { $_.Status -eq 'RingMixedWindows' })

    $hasIssues = ($uncovered.Count + $partial.Count + $malformed.Count + $unparseable.Count + $noWindowTag.Count + $ringMissing.Count + $ringOrphan.Count) -gt 0

    Write-Host ''
    Write-Host 'Audit complete:'
    Write-Host "  Covered                  : $($covered.Count)"
    Write-Host "  Uncovered                : $($uncovered.Count)"
    Write-Host "  PartiallyCovered         : $($partial.Count)"
    Write-Host "  MalformedTag             : $($malformed.Count)"
    Write-Host "  UnparseableCron          : $($unparseable.Count)"
    Write-Host "  NoWindowTag              : $($noWindowTag.Count)"
    Write-Host "  RingMissingFromSchedule  : $($ringMissing.Count)"
    Write-Host "  RingOrphanedInSchedule   : $($ringOrphan.Count)"
    Write-Host "  RingMixedWindows         : $($ringMixed.Count)"

    # ---- JUnit XML --------------------------------------------------------
    $scheduleRows = @($audit | Where-Object { $_.Section -eq 'Schedule' })
    $cronRows     = @($audit | Where-Object { $_.Section -ne 'Schedule' })

    $buildCase = {
        param($Row)
        $tcName = '{0} / {1}' -f $Row.UpdateRing, ($(if ($Row.UpdateStartWindow) { $Row.UpdateStartWindow } else { '(no window)' }))
        $tc = @{ Name = $tcName; ClassName = 'ScheduleCoverage' }
        if ($Row.Status -ne 'Covered') {
            $issue = if ($Row.PSObject.Properties['Issue'] -and $Row.Issue) { [string]$Row.Issue } else { '' }
            $reco  = if ($Row.PSObject.Properties['Recommendation'] -and $Row.Recommendation) { [string]$Row.Recommendation } else { '' }
            $clCnt = if ($Row.PSObject.Properties['ClusterCount']) { [string]$Row.ClusterCount } else { '0' }
            $body  = "Recommendation: $reco`nCluster count: $clCnt"
            $tc.Failure = @{ Message = $issue; Type = [string]$Row.Status; Body = $body }
        }
        $tc
    }

    $suites = @()
    if ($haveSchedule -or $scheduleRows.Count -gt 0) {
        $cases = @()
        foreach ($r in $scheduleRows) { $cases += ,(& $buildCase $r) }
        if ($cases.Count -eq 0) {
            $cases = @(@{ Name = 'Schedule and fleet ring sets match - no gaps.'; ClassName = 'ScheduleCoverage' })
        }
        $suites += ,@{
            Name      = 'Apply-Updates Schedule Coverage - Schedule (ring diff)'
            ClassName = 'ScheduleCoverage'
            TestCases = $cases
        }
    }
    if ($cronRows.Count -gt 0 -or -not $haveSchedule) {
        $cases = @()
        foreach ($r in $cronRows) { $cases += ,(& $buildCase $r) }
        if ($cases.Count -eq 0) {
            $cases = @(@{ Name = 'No tagged clusters found - nothing to audit'; ClassName = 'ScheduleCoverage' })
        }
        $suites += ,@{
            Name      = 'Apply-Updates Schedule Coverage - Cron coverage'
            ClassName = 'ScheduleCoverage'
            TestCases = $cases
        }
    }
    New-AzLocalPipelineJUnitXml -TestSuitesName 'Apply-Updates Schedule Coverage' -Suites $suites -OutputPath $xmlPath | Out-Null

    # ---- Step outputs -----------------------------------------------------
    Set-AzLocalPipelineOutput -Name 'total_rows'    -Value ([string]$audit.Count)
    Set-AzLocalPipelineOutput -Name 'covered'       -Value ([string]$covered.Count)
    Set-AzLocalPipelineOutput -Name 'uncovered'     -Value ([string]$uncovered.Count)
    Set-AzLocalPipelineOutput -Name 'partial'       -Value ([string]$partial.Count)
    Set-AzLocalPipelineOutput -Name 'malformed'     -Value ([string]$malformed.Count)
    Set-AzLocalPipelineOutput -Name 'unparseable'   -Value ([string]$unparseable.Count)
    Set-AzLocalPipelineOutput -Name 'no_window_tag' -Value ([string]$noWindowTag.Count)
    Set-AzLocalPipelineOutput -Name 'ring_missing'  -Value ([string]$ringMissing.Count)
    Set-AzLocalPipelineOutput -Name 'ring_orphan'   -Value ([string]$ringOrphan.Count)
    Set-AzLocalPipelineOutput -Name 'ring_mixed'    -Value ([string]$ringMixed.Count)
    Set-AzLocalPipelineOutput -Name 'have_schedule' -Value ([string]$haveSchedule)
    Set-AzLocalPipelineOutput -Name 'schedule_path' -Value $(if ($haveSchedule) { $SchedulePath } else { '' })

    # ---- Recommend snippet content (for top-of-summary inlining) ----------
    $recoContent = ''
    if (Test-Path -LiteralPath $recoMd) {
        $recoContent = Get-Content -LiteralPath $recoMd -Raw
        if ($null -eq $recoContent) { $recoContent = '' }
    }

    # ---- Markdown step summary --------------------------------------------
    $md = New-Object 'System.Collections.Generic.List[string]'
    [void]$md.Add('## Apply-Updates Schedule Coverage Audit')
    [void]$md.Add('')
    [void]$md.Add('| Metric | Count |')
    [void]$md.Add('|--------|-------|')
    [void]$md.Add("| **(Ring, Window) pairs audited** | $($audit.Count) |")
    [void]$md.Add("| **Covered** | $($covered.Count) |")
    [void]$md.Add("| **Uncovered** | $($uncovered.Count) |")
    [void]$md.Add("| **PartiallyCovered** | $($partial.Count) |")
    [void]$md.Add("| **MalformedTag** | $($malformed.Count) |")
    [void]$md.Add("| **UnparseableCron** | $($unparseable.Count) |")
    [void]$md.Add("| **NoWindowTag** | $($noWindowTag.Count) |")
    [void]$md.Add("| **RingMissingFromSchedule** | $($ringMissing.Count) |")
    [void]$md.Add("| **RingOrphanedInSchedule** | $($ringOrphan.Count) |")
    [void]$md.Add("| **RingMixedWindows** | $($ringMixed.Count) |")
    [void]$md.Add('')

    if ($hasIssues -and $recoContent) {
        [void]$md.Add($recoContent)
        [void]$md.Add('')
    }

    # Helper for the per-section detail table (Schedule + Cron).
    $addDetailTable = {
        param([string]$Heading, [object[]]$DetailRows, [string]$EmptyText)
        if ($Heading) { [void]$md.Add($Heading) }
        [void]$md.Add('')
        if ($DetailRows.Count -eq 0) {
            [void]$md.Add("*$EmptyText*")
            [void]$md.Add('')
            return
        }
        [void]$md.Add('| Status | UpdateRing | UpdateStartWindow | Clusters | Required Cron (UTC) | Recommendation |')
        [void]$md.Add('|--------|------------|--------------|---------:|----------------------|----------------|')
        $shown = 0
        foreach ($r in $DetailRows) {
            if ($shown -ge 100) { break }
            $status   = if ($r.PSObject.Properties['Status']) { [string]$r.Status } else { '' }
            $ring     = if ($r.PSObject.Properties['UpdateRing']) { [string]$r.UpdateRing } else { '' }
            $win      = if ($r.PSObject.Properties['UpdateStartWindow']) { [string]$r.UpdateStartWindow } else { '' }
            $clCnt    = if ($r.PSObject.Properties['ClusterCount']) { [string]$r.ClusterCount } else { '' }
            $reqCron  = if ($r.PSObject.Properties['RequiredCronUTC']) { [string]$r.RequiredCronUTC } else { '' }
            $reco     = if ($r.PSObject.Properties['Recommendation']) { [string]$r.Recommendation } else { '' }
            [void]$md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $status, $ring, $win, $clCnt, $reqCron, $reco))
            $shown++
        }
        if ($DetailRows.Count -gt 100) {
            [void]$md.Add('')
            [void]$md.Add("*Showing first 100 of $($DetailRows.Count); see ``$AuditCsvFileName`` artifact for the full list.*")
        }
        [void]$md.Add('')
    }

    # Schedule detail (always rendered when -SchedulePath supplied OR when
    # any Schedule-section rows exist - defensive fallback).
    if ($haveSchedule -or $scheduleRows.Count -gt 0) {
        [void]$md.Add('### Audit Detail - Schedule (ring-file gap)')
        [void]$md.Add('')
        [void]$md.Add('> **Higher blast radius.** A `RingMissingFromSchedule` row means apply-updates will NEVER fire on those clusters until you either add the ring to `apply-updates-schedule.yml` or retag them onto an existing scheduled ring.')
        & $addDetailTable '' $scheduleRows 'Schedule and fleet ring sets match - no gaps.'
    }

    # Allow-list coverage (schema v1 nudge or schema v2 per-row table).
    if ($haveSchedule) {
        $sched = $null
        try {
            $sched = Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath -ErrorAction Stop
        }
        catch {
            [void]$md.Add('### Allow-list coverage')
            [void]$md.Add('')
            [void]$md.Add("*Could not load schedule file ``$SchedulePath`` for allow-list analysis: $($_.Exception.Message)*")
            [void]$md.Add('')
        }
        if ($sched) {
            [void]$md.Add("### Allow-list coverage (schema v$($sched.SchemaVersion))")
            [void]$md.Add('')
            if ($sched.SchemaVersion -lt 2) {
                [void]$md.Add('*This schedule is on schema v1. Schema v2 adds `allowedUpdateVersions` for fleet-wide + per-ring update allow-lists (e.g. enforce a ''minimum updates'' policy on Prod). Migrate the file with:*')
                [void]$md.Add('')
                [void]$md.Add('```powershell')
                [void]$md.Add("Update-AzLocalApplyUpdatesScheduleConfig -Path '$SchedulePath' -SchemaMigrate")
                [void]$md.Add('```')
                [void]$md.Add('')
            }
            else {
                $topAllow = @()
                if ($sched.PSObject.Properties['AllowedUpdateVersions'] -and $sched.AllowedUpdateVersions) {
                    $topAllow = @($sched.AllowedUpdateVersions)
                }
                $topIsLatest = ($topAllow.Count -eq 1 -and $topAllow[0] -eq 'Latest')
                if ($topIsLatest) {
                    $topLabel = '`Latest` _(no constraint - install the latest Ready update on each cluster)_'
                }
                else {
                    $topLabel = "``$($topAllow -join '; ')`` _(explicit allow-list - clusters only install matching updates)_"
                }
                [void]$md.Add("**Top-level fleet default:** $topLabel")
                [void]$md.Add('')
                [void]$md.Add('| Row | weeksInCycle | daysOfWeek | rings | Effective allowedUpdateVersions |')
                [void]$md.Add('|----:|--------------|------------|-------|---------------------------------|')
                $rowsMissingOverride = New-Object System.Collections.Generic.List[object]
                $rowIdx = 0
                foreach ($r in @($sched.Schedule)) {
                    $rowIdx++
                    $rowAllow = @()
                    if ($r.PSObject.Properties['AllowedUpdateVersionsParsed'] -and $r.AllowedUpdateVersionsParsed) {
                        $rowAllow = @($r.AllowedUpdateVersionsParsed)
                    }
                    if ($rowAllow.Count -gt 0) {
                        if ($rowAllow.Count -eq 1 -and $rowAllow[0] -eq 'Latest') {
                            $effLabel = '`Latest` _(row override: no constraint)_'
                        }
                        else {
                            $effLabel = "``$($rowAllow -join '; ')`` _(row override)_"
                        }
                    }
                    else {
                        if ($topIsLatest) {
                            $effLabel = '`Latest` _(inherits top-level - no constraint)_'
                        }
                        else {
                            $effLabel = "``$($topAllow -join '; ')`` _(inherits top-level)_"
                        }
                        $rowsMissingOverride.Add([pscustomobject]@{
                            Row          = $rowIdx
                            WeeksInCycle = $r.weeksInCycle
                            DaysOfWeek   = $r.daysOfWeek
                            Rings        = $r.rings
                        })
                    }
                    [void]$md.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $rowIdx, $r.weeksInCycle, $r.daysOfWeek, $r.rings, $effLabel))
                }
                [void]$md.Add('')
                if ($rowsMissingOverride.Count -gt 0) {
                    [void]$md.Add("*$($rowsMissingOverride.Count) row(s) inherit the top-level allow-list. This is fine when you want each ring to install the latest Ready update as soon as it is available.*")
                    [void]$md.Add('')
                    [void]$md.Add("### Optional - pin a ring to a specific update in ``$SchedulePath``")
                    [void]$md.Add('')
                    [void]$md.Add('*Only needed if you want to PIN a ring to a specific update (e.g. keep Prod on the latest feature drop only). This is NOT a fix for the cron-coverage or ring-diff sections above.* Add `allowedUpdateVersions:` to the row that covers the ring you want to pin. Use `Get-AzLocalAvailableUpdates` (or the Azure portal -> Azure Local -> Updates) to find valid update names / version strings.')
                    [void]$md.Add('')
                    [void]$md.Add('```yaml')
                    [void]$md.Add("- weeksInCycle: '*'")
                    [void]$md.Add("  daysOfWeek:   'Tue,Wed,Thu'")
                    [void]$md.Add("  rings:        'Prod'")
                    [void]$md.Add("  allowedUpdateVersions: 'Solution12.2604.1003.1005;Solution12.2610.1003.XX'")
                    [void]$md.Add('```')
                    [void]$md.Add('')
                }
                else {
                    [void]$md.Add('*Every schedule row has an explicit `allowedUpdateVersions:` override - no inheritance from the top-level default.*')
                    [void]$md.Add('')
                }
            }
        }
    }

    & $addDetailTable '### Audit Detail - Cron coverage (Uncovered / Partial / Malformed first)' $cronRows 'No tagged clusters found - nothing to audit.'

    if (-not $hasIssues -and $recoContent) {
        [void]$md.Add('### Reference - Recommended schedule (copy into Step.6_apply-updates.yml)')
        [void]$md.Add('')
        [void]$md.Add($recoContent)
        [void]$md.Add('')
    }

    # ---- Cycle calendar - ALWAYS when -SchedulePath supplied --------------
    # v0.8.5 fix for the v0.8.4 $hasIssues-gate regression where the
    # calendar silently disappeared from clean-fleet runs.
    if ($haveSchedule) {
        $calendarMd = $null
        try {
            $schedForCalendar = if ($sched) { $sched } else { Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath -ErrorAction Stop }
            $calendarMd = Get-AzLocalApplyUpdatesScheduleCycleCalendar -Schedule $schedForCalendar -AsMarkdown -IncludePerRingSummary -ErrorAction Stop
        }
        catch {
            $calendarMd = $null
            Write-Warning "Failed to build cycle calendar: $($_.Exception.Message)"
        }
        if ($calendarMd) {
            [void]$md.Add($calendarMd)
            [void]$md.Add('')
        }
    }

    [void]$md.Add('### Reports Available')
    [void]$md.Add("- ``$AuditCsvFileName`` - one row per (UpdateRing, UpdateStartWindow) pair")
    [void]$md.Add("- ``$MatrixCsvFileName`` - full inventory + required cron per row")
    [void]$md.Add("- ``$RecommendMdFileName`` - ready-to-paste cron block")
    [void]$md.Add("- ``$JUnitXmlFileName`` - JUnit XML for CI/CD visualisation")
    [void]$md.Add('')
    [void]$md.Add("*Generated at $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC*")

    if ($InstalledModuleVersion) {
        [void]$md.Add('')
        [void]$md.Add(('_Generated by AzLocal.UpdateManagement v{0}._' -f $InstalledModuleVersion))
    }

    Add-AzLocalPipelineStepSummary -Markdown ($md -join [Environment]::NewLine) -SummaryFileName $SummaryFileName | Out-Null

    if ($PassThru) {
        return [pscustomobject]@{
            TotalRows       = [int]$audit.Count
            Covered         = [int]$covered.Count
            Uncovered       = [int]$uncovered.Count
            Partial         = [int]$partial.Count
            Malformed       = [int]$malformed.Count
            Unparseable     = [int]$unparseable.Count
            NoWindowTag     = [int]$noWindowTag.Count
            RingMissing     = [int]$ringMissing.Count
            RingOrphan      = [int]$ringOrphan.Count
            RingMixed       = [int]$ringMixed.Count
            HaveSchedule    = [bool]$haveSchedule
            SchedulePath    = $(if ($haveSchedule) { $SchedulePath } else { '' })
            AuditRows       = $audit
            AuditCsvPath    = $auditCsv
            MatrixCsvPath   = $matrixCsv
            RecommendMdPath = $recoMd
            JUnitXmlPath    = $xmlPath
            SummaryPath     = (Join-Path -Path $OutputDirectory -ChildPath $SummaryFileName)
        }
    }
}
