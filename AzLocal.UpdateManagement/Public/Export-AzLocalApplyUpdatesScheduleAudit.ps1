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
        Path (file or folder) to Step.7_apply-updates.yml. REQUIRED so
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

    .PARAMETER SideloadEnabled
        Opt-in switch for the v0.8.7 "Recommended sideload schedule" section.
        When not explicitly bound, it is resolved from the SIDELOAD_UPDATES
        environment variable (true/1/yes/on => enabled). When disabled the
        section is omitted entirely and the audit is byte-identical to v0.8.6.

    .PARAMETER SideloadLeadDays
        How many days before a ring's apply window the media should already be
        sideloaded (drives the recommended sideload kickoff cron = apply firing
        shifted back this many days). When not explicitly bound it is resolved
        from the SIDELOAD_LEAD_DAYS environment variable, defaulting to 7.

    .PARAMETER MonitorFiresPerHour
        How often the v0.8.87 "Recommended in-flight monitor schedule" section
        suggests the Update: 4 monitor-updates pipeline should poll while an
        update run is in flight (1-12, default 2 = every 30 minutes). Drives
        the minute field of the recommended monitor cron.

    .PARAMETER MonitorTrailingDays
        How many days after an apply window opens an update run may still be
        in flight (0-14, default 3, mirroring the Update: 4 monitor's CRITICAL
        elapsed tier). The recommended monitor cron covers the apply weekday(s)
        plus this many trailing days so multi-day runs stay observed.

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
        [bool]$SideloadEnabled,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 365)]
        [int]$SideloadLeadDays = 7,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 12)]
        [int]$MonitorFiresPerHour = 2,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 14)]
        [int]$MonitorTrailingDays = 3,

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
        throw "PipelineYamlPath '$PipelineYamlPath' does not exist. Set it to the folder containing apply-updates.yml (e.g. '.github/workflows' or '.azure-pipelines') so the Recommend view can diff its proposed crons against the existing file."
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
    Write-Host "MonitorFires/hr  : $MonitorFiresPerHour"
    Write-Host "MonitorTrailDays : $MonitorTrailingDays"
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
    # v0.8.75: suppress the inner plain (5-column) cycle calendar from
    # the Recommend output; this wrapper renders its own enriched
    # (7-column) calendar below, so without this switch the Step.3
    # step summary would render two cycle-calendar tables back-to-back.
    $recoArgs.OmitCycleCalendar = $true
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
        [void]$md.Add('### Reference - Recommended schedule (copy into apply-updates.yml)')
        [void]$md.Add('')
        [void]$md.Add($recoContent)
        [void]$md.Add('')
    }

    # ---- Cycle calendar - ALWAYS when -SchedulePath supplied --------------
    # v0.8.5 fix for the v0.8.4 $hasIssues-gate regression where the
    # calendar silently disappeared from clean-fleet runs.
    # v0.8.6 enrichment: when PipelineYamlPath (always) and ClusterCsvPath
    # (optional) are available, build two extra columns:
    #   * "Ring CRON Start Time (apply-updates pipeline)" - per-day UTC firing
    #     times projected from Step.6 cron triggers.
    #   * "Tag Start Window Match (>=95%)" - per (ring, date) pair: do
    #     >=95% of clusters in the ring have an UpdateStartWindow tag
    #     that covers AT LEAST ONE Step.6 cron firing on that date?
    # Both columns are pure render-time data computed here (Azure I/O
    # / file I/O lives in this caller, not the cycle-calendar cmdlet).
    if ($haveSchedule) {
        $calendarMd = $null
        $cronFiringsByDate        = $null
        $windowMatchByRingAndDate = $null
        $clusterRingCountMap      = $null
        try {
            $schedForCalendar = if ($sched) { $sched } else { Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath -ErrorAction Stop }

            # Build cron firings per UTC date across the cycle-calendar's
            # default horizon (CycleWeeks * 7 days, mirroring the cmdlet's
            # default $Days). Best-effort: parse failures degrade gracefully
            # to "no firings" rather than aborting the whole calendar.
            try {
                $cronFireRows = New-Object System.Collections.Generic.List[psobject]
                # NOTE: Read-AzLocalApplyUpdatesYamlCrons uses unary-comma return; direct assignment only (no @() wrap).
                $cronTriggers = Read-AzLocalApplyUpdatesYamlCrons -Path $PipelineYamlPath -ErrorAction Stop
                foreach ($ct in $cronTriggers) {
                    try {
                        $parsed = ConvertFrom-AzLocalCronExpression -Expression $ct.CronExpression -ErrorAction Stop
                        if ($parsed.IsValid -and -not $parsed.IsComplex) {
                            foreach ($ft in @($parsed.FireTimes)) {
                                $cronFireRows.Add([pscustomobject]@{
                                    DayOfWeek = $ft.DayOfWeek
                                    Time      = $ft.TimeOfDay
                                }) | Out-Null
                            }
                        }
                    }
                    catch {
                        Write-Verbose "Cron parse failed for '$($ct.CronExpression)': $($_.Exception.Message)"
                    }
                }

                $horizonDays = [int]$schedForCalendar.CycleWeeks * 7
                if ($horizonDays -lt 7) { $horizonDays = 7 }
                $startDay = [datetime]::SpecifyKind([datetime]::UtcNow.Date, [DateTimeKind]::Utc)

                $cronFiringsByDate = @{}
                for ($i = 0; $i -lt $horizonDays; $i++) {
                    $d   = $startDay.AddDays($i)
                    $dow = $d.DayOfWeek
                    $fires = @(
                        $cronFireRows |
                            Where-Object { $_.DayOfWeek -eq $dow } |
                            ForEach-Object { ($_.Time).ToString('hh\:mm') }
                    ) | Sort-Object -Unique
                    $cronFiringsByDate[$d.ToString('yyyy-MM-dd')] = @($fires)
                }

                # Window-match column needs cluster CSV input.
                if ($haveCsv) {
                    $clusters = @(Import-Csv -LiteralPath $ClusterCsvPath -ErrorAction Stop)

                    # Build a ring -> tagged-cluster-count map so the
                    # cycle calendar can fold the count inline into the
                    # "Eligible rings (cluster count)" column.
                    $clusterRingCountMap = @{}
                    foreach ($c in $clusters) {
                        $cr = ''
                        if ($c.PSObject.Properties.Name -contains 'UpdateRing' -and $null -ne $c.UpdateRing) {
                            $cr = ([string]$c.UpdateRing).Trim()
                        }
                        if ([string]::IsNullOrWhiteSpace($cr)) { continue }
                        if ($clusterRingCountMap.ContainsKey($cr)) {
                            $clusterRingCountMap[$cr] = [int]$clusterRingCountMap[$cr] + 1
                        } else {
                            $clusterRingCountMap[$cr] = 1
                        }
                    }
                    if ($clusterRingCountMap.Count -eq 0) { $clusterRingCountMap = $null }

                    # Pre-parse each cluster's UpdateStartWindow once.
                    $ringsToClusters = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[psobject]]' ([System.StringComparer]::OrdinalIgnoreCase)
                    foreach ($c in $clusters) {
                        $ring = ''
                        if ($c.PSObject.Properties.Name -contains 'UpdateRing' -and $null -ne $c.UpdateRing) {
                            $ring = ([string]$c.UpdateRing).Trim()
                        }
                        if ([string]::IsNullOrWhiteSpace($ring)) { continue }
                        $winStr = ''
                        if ($c.PSObject.Properties.Name -contains 'UpdateStartWindow' -and $null -ne $c.UpdateStartWindow) {
                            $winStr = ([string]$c.UpdateStartWindow).Trim()
                        }
                        $segments = @()
                        if (-not [string]::IsNullOrWhiteSpace($winStr)) {
                            try { $segments = @(ConvertFrom-AzLocalUpdateWindow -WindowString $winStr -ErrorAction Stop) }
                            catch { $segments = @() }
                        }
                        if (-not $ringsToClusters.ContainsKey($ring)) {
                            $ringsToClusters[$ring] = New-Object System.Collections.Generic.List[psobject]
                        }
                        $ringsToClusters[$ring].Add([pscustomobject]@{ Segments = $segments }) | Out-Null
                    }

                    $windowMatchByRingAndDate = @{}
                    for ($i = 0; $i -lt $horizonDays; $i++) {
                        $d       = $startDay.AddDays($i)
                        $dow     = $d.DayOfWeek
                        $prevDow = $d.AddDays(-1).DayOfWeek
                        $dKey    = $d.ToString('yyyy-MM-dd')
                        $firesToday = @(
                            $cronFireRows |
                                Where-Object { $_.DayOfWeek -eq $dow } |
                                ForEach-Object { $_.Time }
                        )
                        if ($firesToday.Count -eq 0) { continue }
                        foreach ($ring in $ringsToClusters.Keys) {
                            $clist = @($ringsToClusters[$ring])
                            $tot   = $clist.Count
                            $mat   = 0
                            foreach ($cw in $clist) {
                                $hit = $false
                                foreach ($seg in @($cw.Segments)) {
                                    $segDays = @($seg.Days)
                                    if ($seg.Overnight) {
                                        # Two cases for overnight windows:
                                        # (a) opens today before midnight -> fires today >= StartTime,
                                        # (b) opened yesterday and still active -> fires today < EndTime.
                                        foreach ($ft in $firesToday) {
                                            if ($segDays -contains $dow     -and $ft -ge $seg.StartTime) { $hit = $true; break }
                                            if ($segDays -contains $prevDow -and $ft -lt $seg.EndTime)   { $hit = $true; break }
                                        }
                                    }
                                    else {
                                        if (-not ($segDays -contains $dow)) { continue }
                                        foreach ($ft in $firesToday) {
                                            if ($ft -ge $seg.StartTime -and $ft -lt $seg.EndTime) { $hit = $true; break }
                                        }
                                    }
                                    if ($hit) { break }
                                }
                                if ($hit) { $mat++ }
                            }
                            if ($tot -gt 0) {
                                if (-not $windowMatchByRingAndDate.ContainsKey($ring)) { $windowMatchByRingAndDate[$ring] = @{} }
                                $windowMatchByRingAndDate[$ring][$dKey] = @{ Matching = $mat; Total = $tot }
                            }
                        }
                    }
                }
            }
            catch {
                Write-Warning "Failed to build cycle-calendar enrichment columns: $($_.Exception.Message)"
                $cronFiringsByDate        = $null
                $windowMatchByRingAndDate = $null
                $clusterRingCountMap      = $null
            }

            $calArgs = @{
                Schedule              = $schedForCalendar
                AsMarkdown            = $true
                IncludePerRingSummary = $true
                ErrorAction           = 'Stop'
            }
            if ($cronFiringsByDate)        { $calArgs.CronFiringsByDate        = $cronFiringsByDate }
            if ($windowMatchByRingAndDate) { $calArgs.WindowMatchByRingAndDate = $windowMatchByRingAndDate }
            if ($clusterRingCountMap)      { $calArgs.ClusterRingCounts        = $clusterRingCountMap }
            $calendarMd = Get-AzLocalApplyUpdatesScheduleCycleCalendar @calArgs
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

    # ---- Recommended sideload schedule (Step.6, opt-in v0.8.7) ------------
    # Gated on SIDELOAD_UPDATES (parameter override -> env var). When disabled
    # the section is omitted and the audit output is byte-identical to v0.8.6.
    # The on-prem Step.6 sideload pipeline is re-entrant and driven by a
    # frequent poll cron; its planner uses SIDELOAD_LEAD_DAYS to decide when a
    # cluster is "due". This section reuses the apply-window crons already read
    # from PipelineYamlPath to recommend, per apply firing, the EARLIEST weekly
    # cron at which staging should begin (apply firing shifted back LeadDays).
    #
    # NOTE: the local accumulator is deliberately NOT named $sideloadEnabled -
    # PowerShell variable names are CASE-INSENSITIVE, so $sideloadEnabled would
    # alias the [bool]$SideloadEnabled parameter and clobber the bound value to
    # $false on the first assignment (silent: -SideloadEnabled $true then
    # rendered nothing while only the env-var path worked).
    $emitSideloadSection = $false
    if ($PSBoundParameters.ContainsKey('SideloadEnabled')) {
        $emitSideloadSection = $SideloadEnabled
    }
    elseif ($env:SIDELOAD_UPDATES) {
        $emitSideloadSection = (([string]$env:SIDELOAD_UPDATES).Trim().ToLowerInvariant() -in @('true', '1', 'yes', 'on'))
    }
    $sideloadScheduleIncluded = $false
    if ($emitSideloadSection) {
        $leadDays = $SideloadLeadDays
        if (-not $PSBoundParameters.ContainsKey('SideloadLeadDays') -and $env:SIDELOAD_LEAD_DAYS) {
            $parsedLead = 0
            if ([int]::TryParse((([string]$env:SIDELOAD_LEAD_DAYS).Trim()), [ref]$parsedLead) -and $parsedLead -ge 0 -and $parsedLead -le 365) {
                $leadDays = $parsedLead
            }
        }

        # Distinct apply-window weekly firings (DayOfWeek + TimeOfDay) from the
        # apply pipeline crons. Read-AzLocalApplyUpdatesYamlCrons uses a
        # unary-comma return - direct assignment only (NEVER @() wrap).
        $applyFirings = New-Object 'System.Collections.Generic.List[psobject]'
        try {
            $sideloadCronTriggers = Read-AzLocalApplyUpdatesYamlCrons -Path $PipelineYamlPath -ErrorAction Stop
            foreach ($sct in $sideloadCronTriggers) {
                try {
                    $sparsed = ConvertFrom-AzLocalCronExpression -Expression $sct.CronExpression -ErrorAction Stop
                    if ($sparsed.IsValid -and -not $sparsed.IsComplex) {
                        foreach ($sft in @($sparsed.FireTimes)) {
                            $applyFirings.Add([pscustomobject]@{
                                DayOfWeek = [int]$sft.DayOfWeek
                                TimeOfDay = $sft.TimeOfDay
                            }) | Out-Null
                        }
                    }
                }
                catch {
                    Write-Verbose "Sideload section: cron parse failed for '$($sct.CronExpression)': $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-Warning "Failed to read apply-updates crons for the sideload schedule recommendation: $($_.Exception.Message)"
        }

        [void]$md.Add('### Recommended sideload schedule (sideload-updates - opt-in)')
        [void]$md.Add('')
        [void]$md.Add("`SIDELOAD_UPDATES` is enabled, so media must be pre-staged on each cluster **$leadDays day(s)** before its apply window opens. The on-prem **Sideload Updates** pipeline is re-entrant: drive it on a frequent poll cron and its planner uses `SIDELOAD_LEAD_DAYS=$leadDays` to decide when each cluster is due.")
        [void]$md.Add('')
        [void]$md.Add('Recommended sideload-updates poll cron (every 30 minutes) - paste into the `schedule:`/`schedules:` block of `sideload-updates.yml`:')
        [void]$md.Add('')
        [void]$md.Add('```')
        [void]$md.Add('*/30 * * * *')
        [void]$md.Add('```')
        [void]$md.Add('')

        # Build a distinct, ordered list of apply firings.
        $distinctFirings = @(
            $applyFirings |
                Sort-Object DayOfWeek, TimeOfDay -Unique
        )
        if ($distinctFirings.Count -gt 0) {
            $dayNames = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
            [void]$md.Add("Per apply-window firing, the EARLIEST weekly cron at which staging should begin (apply firing shifted back $leadDays day(s)):")
            [void]$md.Add('')
            [void]$md.Add('| Apply firing (UTC) | Lead (days) | Begin-staging (UTC) | Sideload kickoff cron |')
            [void]$md.Add('|--------------------|------------:|---------------------|-----------------------|')
            foreach ($f in $distinctFirings) {
                $applyDow = [int]$f.DayOfWeek
                $hhmm = ([timespan]$f.TimeOfDay).ToString('hh\:mm')
                $minute = ([timespan]$f.TimeOfDay).Minutes
                $hour = ([timespan]$f.TimeOfDay).Hours
                $shiftedDow = ((($applyDow - ($leadDays % 7)) % 7) + 7) % 7
                $kickoffCron = ('{0} {1} * * {2}' -f $minute, $hour, $shiftedDow)
                [void]$md.Add(('| {0} {1} | {2} | {3} {1} | `{4}` |' -f $dayNames[$applyDow], $hhmm, $leadDays, $dayNames[$shiftedDow], $kickoffCron))
            }
            [void]$md.Add('')
            [void]$md.Add('> The kickoff cron is the EARLIEST point staging could start for that window. The re-entrant sideload-updates pipeline (frequent poll) advances the multi-hour copy from that point; you do NOT need a separate cron per ring.')
            [void]$md.Add('')
        }
        else {
            [void]$md.Add('> No simple weekly apply-window firings were found in the pipeline YAML, so a per-window kickoff cron could not be derived. Drive sideload-updates on the recommended poll cron above; its planner will stage each cluster `SIDELOAD_LEAD_DAYS` days before its apply window.')
            [void]$md.Add('')
        }
        $sideloadScheduleIncluded = $true
    }

    # ---- Recommended in-flight monitor schedule (Update: 4) ----------------
    # v0.8.87: recommend a poll cron for the 'Update: 4 - Monitor In-Flight
    # Updates' (monitor-updates.yml) pipeline, scaled to how often updates are
    # applied. Once an apply window fires, an update run can stay in-flight for
    # hours to days (the monitor's own CRITICAL elapsed tier defaults to 3
    # days), so the monitor must poll frequently across the apply weekday(s)
    # AND the trailing days an update may still be running. Cadence (fires/hour)
    # is driven by -MonitorFiresPerHour; trailing coverage by -MonitorTrailingDays.
    # Always emitted (independent of the sideload opt-in).
    $monitorFires = $MonitorFiresPerHour
    $monitorIntervalMinutes = [int][math]::Floor(60 / $monitorFires)
    if ($monitorIntervalMinutes -lt 1) { $monitorIntervalMinutes = 1 }
    $monitorMinuteField = if ($monitorFires -le 1) { '0' } else { ('*/{0}' -f $monitorIntervalMinutes) }

    # Distinct apply-window weekly firings (DayOfWeek) from the apply pipeline
    # crons. Read-AzLocalApplyUpdatesYamlCrons uses a unary-comma return -
    # direct assignment only (NEVER @() wrap).
    $monitorApplyFirings = New-Object 'System.Collections.Generic.List[psobject]'
    try {
        $monitorCronTriggers = Read-AzLocalApplyUpdatesYamlCrons -Path $PipelineYamlPath -ErrorAction Stop
        foreach ($mct in $monitorCronTriggers) {
            try {
                $mparsed = ConvertFrom-AzLocalCronExpression -Expression $mct.CronExpression -ErrorAction Stop
                if ($mparsed.IsValid -and -not $mparsed.IsComplex) {
                    foreach ($mft in @($mparsed.FireTimes)) {
                        $monitorApplyFirings.Add([pscustomobject]@{
                            DayOfWeek = [int]$mft.DayOfWeek
                        }) | Out-Null
                    }
                }
            }
            catch {
                Write-Verbose "Monitor section: cron parse failed for '$($mct.CronExpression)': $($_.Exception.Message)"
            }
        }
    }
    catch {
        Write-Warning "Failed to read apply-updates crons for the monitor schedule recommendation: $($_.Exception.Message)"
    }

    [void]$md.Add('### Recommended in-flight monitor schedule (Update: 4)')
    [void]$md.Add('')
    [void]$md.Add(('The **Update: 4 - Monitor In-Flight Updates** (`monitor-updates.yml`) pipeline should poll frequently while any update run is in flight. An update can stay in-flight for hours to days after its apply window opens, so poll **{0}x/hour** (every {1} min) across the apply weekday(s) plus the next **{2} day(s)** to catch multi-day runs.' -f $monitorFires, $monitorIntervalMinutes, $MonitorTrailingDays))
    [void]$md.Add('')

    $monitorDayNames = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
    $monitorApplyDows = @($monitorApplyFirings | ForEach-Object { [int]$_.DayOfWeek } | Sort-Object -Unique)
    if ($monitorApplyDows.Count -gt 0) {
        # Expand each apply weekday across the trailing coverage days.
        $monitorCoverageSet = New-Object 'System.Collections.Generic.HashSet[int]'
        foreach ($applyDow in $monitorApplyDows) {
            for ($k = 0; $k -le $MonitorTrailingDays; $k++) {
                [void]$monitorCoverageSet.Add((($applyDow + $k) % 7))
            }
        }
        $monitorCoverageDows = @($monitorCoverageSet) | Sort-Object
        $monitorDayField = if ($monitorCoverageDows.Count -ge 7) { '*' } else { ($monitorCoverageDows -join ',') }
        $monitorCron = ('{0} * * * {1}' -f $monitorMinuteField, $monitorDayField)
        $monitorCoverageLabel = if ($monitorCoverageDows.Count -ge 7) { 'every day' } else { (($monitorCoverageDows | ForEach-Object { $monitorDayNames[$_] }) -join ', ') }
        $monitorApplyLabel = ($monitorApplyDows | ForEach-Object { $monitorDayNames[$_] }) -join ', '

        [void]$md.Add(('Apply firing weekday(s): **{0}**. With {1} trailing day(s) of coverage, the monitor should run on: **{2}**.' -f $monitorApplyLabel, $MonitorTrailingDays, $monitorCoverageLabel))
        [void]$md.Add('')
        [void]$md.Add('Recommended Update: 4 monitor cron - paste into the `schedule:` block of `monitor-updates.yml`:')
        [void]$md.Add('')
        [void]$md.Add('```')
        [void]$md.Add($monitorCron)
        [void]$md.Add('```')
        [void]$md.Add('')
        [void]$md.Add('> GitHub Actions supports sub-hour cron (e.g. `*/30`). Azure DevOps YAML `schedules:` is hourly-only - for sub-hour cadence on ADO, trigger `monitor-updates.yml` from an external scheduler via REST. Widen the day list above if your runs routinely exceed the trailing-day coverage.')
        [void]$md.Add('')
    }
    else {
        $monitorFallbackCron = ('{0} * * * *' -f $monitorMinuteField)
        [void]$md.Add('> No simple weekly apply-window firings were found in the pipeline YAML, so a focused monitor window could not be derived. Run the monitor 24x7 at the configured cadence:')
        [void]$md.Add('')
        [void]$md.Add('```')
        [void]$md.Add($monitorFallbackCron)
        [void]$md.Add('```')
        [void]$md.Add('')
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
