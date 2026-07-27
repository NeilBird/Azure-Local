function Export-AzLocalClusterReadinessGateReport {
    <#
    .SYNOPSIS
        Runs Get-AzLocalClusterUpdateReadiness for the given UpdateRing,
        writes readiness-report.csv to the pipeline artifact folder, emits
        step outputs READY_COUNT/TOTAL_COUNT/NOT_READY_COUNT, and renders the
        per-cluster readiness markdown table to the run summary.
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Replaces the ~80-line inline `run:`
        block that lived in both Step.7_apply-updates.yml pipelines.

        Behaviour matches the prior inline block byte-for-byte:
          - When -UpdateRing is empty/whitespace (no schedule row matched
            today): skips the readiness query, emits zero counts, and exits
            cleanly. Downstream apply-updates is gated on ready_count > 0
            and will be skipped.
          - Otherwise: discovers clusters by tag, exports CSV, counts ready
            vs not-ready, emits the same READY_COUNT/TOTAL_COUNT step outputs
            the apply-updates job consumes.
          - Markdown table: one row per assessed cluster (sorted Ready-first
            then ClusterName ASC), capped at -MaxRows (default 100). Same
            columns and emoji as Enhancement D introduced in v0.8.4.
    .PARAMETER UpdateRing
        UpdateRing tag value to filter clusters by. Empty string OR whitespace
        triggers the zero-clusters short-circuit (see DESCRIPTION).
    .PARAMETER OutputDirectory
        Directory where readiness-report.csv is written. Defaults to:
          - Azure DevOps: $env:BUILD_ARTIFACTSTAGINGDIRECTORY
          - GitHub / Local: './artifacts'
    .PARAMETER ReadinessCsvFileName
        Filename for the CSV. Default: 'readiness-report.csv'.
    .PARAMETER MaxRows
        Maximum rows rendered into the markdown table. Default 100. The CSV
        always contains every assessed cluster regardless of this cap.
    .PARAMETER SummaryFileName
        Filename for the per-task markdown summary (ADO/Local only). Default:
        'azlocal-step6-readiness-summary.md'.
    .PARAMETER PassThru
        Returns PSCustomObject with: TotalCount, ReadyCount, UpToDateCount,
        NotReadyCount, StaleAssessmentCount, UpdateRing, ReadinessCsvPath,
        SummaryPath, Results (raw rows from Get-AzLocalClusterUpdateReadiness
        when not in the short-circuit path, else @()).
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
        [string]$UpdateRing = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$OutputDirectory = '',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessCsvFileName = 'readiness-report.csv',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [int]$MaxRows = 100,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-step6-readiness-summary.md',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

    # OutputDirectory default (host-specific, byte-for-byte the same as the
    # prior inline block).
    if (-not $OutputDirectory) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $OutputDirectory = $env:BUILD_ARTIFACTSTAGINGDIRECTORY
        }
        else {
            $OutputDirectory = './artifacts'
        }
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $csvPath = Join-Path -Path $OutputDirectory -ChildPath $ReadinessCsvFileName

    # Per-host step-output naming - PRESERVE existing pipeline downstream
    # bindings byte-for-byte: GH uses UPPER_SNAKE, ADO uses PascalCase
    # (e.g. stageDependencies.CheckReadiness.ReadinessCheck.outputs['readiness.ReadyCount']).
    if ($pipelineHost -eq 'AzureDevOps') {
        $nReadyCount = 'ReadyCount'; $nTotalCount = 'TotalCount'; $nNotReadyCount = 'NotReadyCount'; $nUpToDateCount = 'UpToDateCount'
    }
    else {
        $nReadyCount = 'READY_COUNT'; $nTotalCount = 'TOTAL_COUNT'; $nNotReadyCount = 'NOT_READY_COUNT'; $nUpToDateCount = 'UP_TO_DATE_COUNT'
    }

    # Short-circuit when the schedule resolver returned no ring.
    if ([string]::IsNullOrWhiteSpace($UpdateRing)) {
        Write-Host "No UpdateRing scheduled for this firing - skipping readiness check."
        Set-AzLocalPipelineOutput -Name $nReadyCount    -Value '0' -CrossJob
        Set-AzLocalPipelineOutput -Name $nTotalCount    -Value '0' -CrossJob
        Set-AzLocalPipelineOutput -Name $nUpToDateCount -Value '0' -CrossJob
        Set-AzLocalPipelineOutput -Name $nNotReadyCount -Value '0' -CrossJob
        if ($PassThru) {
            return [pscustomobject]@{
                TotalCount       = 0
                ReadyCount       = 0
                UpToDateCount    = 0
                NotReadyCount    = 0
                StaleAssessmentCount = 0
                UpdateRing       = ''
                ReadinessCsvPath = $csvPath
                SummaryPath      = $null
                Results          = @()
            }
        }
        return
    }

    Write-Host "Checking readiness for clusters with UpdateRing = '$UpdateRing'"

    $results = @(Get-AzLocalClusterUpdateReadiness `
            -ScopeByUpdateRingTag `
            -UpdateRingValue $UpdateRing `
            -ExportPath $csvPath `
            -PassThru)

    $totalCount    = $results.Count
    $readyCount    = @($results | Where-Object { $_.ReadyForUpdate -eq $true }).Count
    # v0.8.74: Up to Date is now its own displayed bucket (shared cascade with
    # Step.5 / Step.9) so clusters that have already applied all updates are not
    # lumped into "Not Ready" - that previously implied failure for healthy,
    # fully-patched clusters. READY_COUNT (the apply-updates gate) is unchanged.
    $upToDateCount = @($results | Where-Object { (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'UpToDate' }).Count
    $notReadyCount = $totalCount - $readyCount - $upToDateCount

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Readiness Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Total Clusters: $totalCount"
    Write-Host "Ready for Update: $readyCount"
    Write-Host "Up to Date: $upToDateCount"
    Write-Host "Not Ready: $notReadyCount"

    Set-AzLocalPipelineOutput -Name $nReadyCount    -Value "$readyCount"    -CrossJob
    Set-AzLocalPipelineOutput -Name $nTotalCount    -Value "$totalCount"    -CrossJob
    Set-AzLocalPipelineOutput -Name $nUpToDateCount -Value "$upToDateCount" -CrossJob
    Set-AzLocalPipelineOutput -Name $nNotReadyCount -Value "$notReadyCount" -CrossJob

    if ($readyCount -eq 0 -and $pipelineHost -eq 'AzureDevOps') {
        # Preserve byte-for-byte the original Step.6 ADO warning text.
        Write-Host "##vso[task.logissue type=warning]No clusters are ready for updates in ring '$UpdateRing'"
    }

    # v0.8.97: anchor a support window + stale-assessment detection on the
    # public Azure Local update manifest (mirrors Monitor: 3 - Fleet Update
    # Status). A disconnected cluster can report ARM UpdateState 'UpToDate'
    # while a newer solution build is already released, because its cached
    # assessment ("Updates Available") has not refreshed. We compare each
    # cluster's installed YYMM to the manifest's latest YYMM and flag the
    # difference so the readiness table does not show a misleading
    # "Up to Date" for clusters that are actually behind.
    $latestReleasedYymm    = ''
    $latestReleasedVersion = ''
    $supportedYymms        = @()
    try {
        Write-Host "Querying https://aka.ms/AzureEdgeUpdates for the latest released Azure Local solution version..."
        $manifestProbe         = Get-AzLocalLatestSolutionVersion -ErrorAction Stop
        $latestReleasedYymm    = [string]$manifestProbe.LatestYYMM
        $latestReleasedVersion = [string]$manifestProbe.LatestVersion
        $supportedYymms        = @($manifestProbe.SupportedYYMMs)
        Write-Host ("Latest released solution version: {0} (YYMM={1})." -f $latestReleasedVersion, $latestReleasedYymm) -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to query the public update manifest - Support column falls back to a fleet-observed top-6 YYMM window and stale-assessment detection is skipped. Error: $($_.Exception.Message)"
        $observedYymms = @($results | ForEach-Object {
                $vp = ([string]$_.CurrentVersion) -split '\.'
                if ($vp.Count -ge 2) { $vp[1] } else { '' }
            } | Where-Object { $_ -match '^[0-9]{4}$' } | Sort-Object -Unique)
        $supportedYymms = @($observedYymms | Sort-Object -Descending | Select-Object -First 6)
    }

    # Stale pre-pass: annotate each row so the render loop (and the summary
    # header count) agree. Only clusters the shared cascade classifies as
    # 'UpToDate' are candidates; staleness needs a manifest LatestYYMM.
    $staleCount = 0
    foreach ($r in $results) {
        $isStale = $false
        if ($latestReleasedYymm -and (Get-AzLocalClusterReadinessStatus -ReadinessRow $r) -eq 'UpToDate') {
            $staleCheck = Test-AzLocalUpdateAssessmentStale -CurrentVersion ([string]$r.CurrentVersion) -LatestYYMM $latestReleasedYymm
            if ($staleCheck.IsStale) { $isStale = $true; $staleCount++ }
        }
        $r | Add-Member -MemberType NoteProperty -Name _IsStaleAssessment -Value $isStale -Force
    }

    # Per-cluster readiness markdown table. Heading is `# Cluster Readiness`
    # on ADO (file is its own summary card) and `## Cluster Readiness` on
    # GitHub (appended into GITHUB_STEP_SUMMARY which already has H1).
    $headingLevel = if ($pipelineHost -eq 'AzureDevOps') { '#' } else { '##' }
    # v0.8.81: shared status-icon map + portal deep-link + Ctrl+click tip so
    # the Step.6 gate report mirrors the markdown polish in Step.05 / Step.10.
    $iconMap = Get-AzLocalStatusIconMap -PipelineHost $pipelineHost
    $sb = New-Object System.Text.StringBuilder
    # v0.9.17: on a SCHEDULE (cron) firing, prepend a banner making it explicit that
    # the targeted UpdateRing(s) are derived from the operator's own
    # apply-updates-schedule.yml (path + current cycle day + matched rings). Renders
    # nothing on manual runs or when no schedule file is present.
    foreach ($bannerLine in (Get-AzLocalApplyScheduleSourceBanner)) {
        [void]$sb.AppendLine($bannerLine)
    }
    [void]$sb.AppendLine("$headingLevel Cluster Readiness ($UpdateRing)")
    [void]$sb.AppendLine()
    $staleSegment = if ($staleCount -gt 0) { " &nbsp;|&nbsp; **Stale assessment:** $staleCount" } else { '' }
    [void]$sb.AppendLine("**Total:** $totalCount &nbsp;|&nbsp; **Ready:** $readyCount &nbsp;|&nbsp; **Up to Date:** $upToDateCount &nbsp;|&nbsp; **Not Ready:** $notReadyCount$staleSegment")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine((Get-AzLocalCtrlClickTip))
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Cluster | UpdateRing | Current Version | Update State | Health | Status | Support | Recommended Update | Blocking Reasons |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|---|---|')

    $rendered = 0
    foreach ($r in ($results | Sort-Object @{Expression = { [bool]$_.ReadyForUpdate }; Descending = $true }, ClusterName)) {
        if ($rendered -ge $MaxRows) { break }
        # v0.8.74: a readable Status cell driven by the shared readiness cascade.
        # Up-to-Date clusters now show a green check + "Up to Date" instead of the
        # no-entry icon that the old binary Ready? column rendered for them.
        # v0.8.81: icon glyph now comes from Get-AzLocalStatusIconMap (host-aware).
        $statusKey = Get-AzLocalClusterReadinessStatus -ReadinessRow $r
        # v0.8.97: a disconnected/stale cluster can report ARM UpdateState
        # 'UpToDate' while a newer solution build is already released. The
        # stale pre-pass flagged these; surface them as an actionable warning
        # instead of a misleading "Up to Date" so the operator runs Check for
        # Updates (e.g. Sync-AzLocalClusterUpdateSummary).
        $isStaleAssessment = ($r.PSObject.Properties['_IsStaleAssessment'] -and $r._IsStaleAssessment)
        $statusCell = if ($isStaleAssessment) {
            ('{0} Update Available (stale assessment)' -f $iconMap['Warn'])
        }
        elseif ($iconMap.ContainsKey($statusKey)) { $iconMap[$statusKey] }
        else { $iconMap['NeedsInvestigation'] }
        # v0.8.97: Support column mirrors the Monitor: 3 - Fleet Update Status
        # rolling 6-month YYMM support window (public manifest, fleet-observed
        # top-6 fallback when the manifest is unreachable).
        $verParts = ([string]$r.CurrentVersion) -split '\.'
        $verYymm  = if ($verParts.Count -ge 2) { $verParts[1] } else { '' }
        $supportCell = if ($verYymm -match '^[0-9]{4}$') {
            if ($supportedYymms -contains $verYymm) { $iconMap['SupportSupported'] } else { $iconMap['SupportUnsupported'] }
        }
        else { $iconMap['SupportUnknown'] }
        $hSt = "$($r.HealthState)"
        $hCell = switch -Regex ($hSt) {
            '^Success$' { $iconMap['Healthy'] -replace ' Healthy$', " $hSt"; break }
            '^Warning$' { $iconMap['Warning'] -replace ' Warning$', " $hSt"; break }
            '^Failure$' { $iconMap['Critical'] -replace ' Critical$', " $hSt"; break }
            default     { $hSt }
        }
        $blocking = "$($r.BlockingReasons)"
        if ($blocking.Length -gt 200) { $blocking = $blocking.Substring(0, 197) + '...' }
        $blocking = ConvertTo-AzLocalMarkdownTableCell -Value $blocking
        $reco = if ($r.RecommendedUpdate) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.RecommendedUpdate) } else { '-' }
        $curr = if ($r.CurrentVersion) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.CurrentVersion) } else { '-' }
        $clusterResId = if ($r.PSObject.Properties['ClusterResourceId'] -and $r.ClusterResourceId) { [string]$r.ClusterResourceId } else { '' }
        $clusterCell = Get-AzLocalClusterPortalLink -ClusterName ([string]$r.ClusterName) -ClusterResourceId $clusterResId -MarkdownTableCell
        # v0.9.17: per-cluster UpdateRing tag - the readiness gate can be scoped to a
        # ';'-joined multi-ring value, so show which ring each cluster belongs to.
        $ringCell = if ($r.PSObject.Properties['UpdateRing'] -and $r.UpdateRing) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.UpdateRing) } else { '-' }
        $updateStateCell = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$r.UpdateState)
        $healthCell = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$hCell)
        [void]$sb.AppendLine("| $clusterCell | $ringCell | $curr | $updateStateCell | $healthCell | $statusCell | $supportCell | $reco | $blocking |")
        $rendered++
    }

    if ($staleCount -gt 0) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("> **Note:** $staleCount cluster(s) report ARM state 'Up to Date' but are running a solution version behind the latest released build (YYMM ``$latestReleasedYymm``). Their cached update assessment is stale - run 'Check for Updates' (e.g. ``Sync-AzLocalClusterUpdateSummary``) to refresh. These clusters are NOT truly up to date.")
    }

    if ($totalCount -gt $MaxRows) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("_Showing first $MaxRows of $totalCount clusters. Download the readiness-report.csv artifact for the full list._")
    }
    [void]$sb.AppendLine()

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown $sb.ToString() -SummaryFileName $SummaryFileName

    if ($PassThru) {
        return [pscustomobject]@{
            TotalCount       = $totalCount
            ReadyCount       = $readyCount
            UpToDateCount    = $upToDateCount
            NotReadyCount    = $notReadyCount
            StaleAssessmentCount = $staleCount
            UpdateRing       = $UpdateRing
            ReadinessCsvPath = $csvPath
            SummaryPath      = $summaryPath
            Results          = $results
        }
    }
}
