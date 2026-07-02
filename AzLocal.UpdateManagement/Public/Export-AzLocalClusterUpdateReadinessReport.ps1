function Export-AzLocalClusterUpdateReadinessReport {
    <#
    .SYNOPSIS
        Runs the Step.5 pre-flight Update Readiness Assessment workload:
        Get-AzLocalClusterUpdateReadiness + Test-AzLocalClusterHealth
        -BlockingOnly against a target UpdateRing (or whole fleet),
        writes per-check CSV/JUnit XML artifacts, merges them into a
        combined JUnit report, and emits the markdown step summary +
        step outputs for the v0.8.5 thin-YAML Step.5 pipeline.

    .DESCRIPTION
        Phase 1 (v0.8.5) of the thin-YAML refactor. Condenses the inline
        `run: |` body of the v0.8.4 Step.5_assess-update-readiness.yml
        (GitHub Actions + Azure DevOps) into a single cmdlet call so the
        per-platform yml shrinks to a few lines and the workload becomes
        unit-testable against synthetic Get-AzLocalClusterUpdateReadiness
        and Test-AzLocalClusterHealth results.

        The cmdlet:

          1. Resolves the output directory (defaults to './artifacts' on
             GitHub Actions / Local, or `$env:BUILD_ARTIFACTSTAGINGDIRECTORY`
             on Azure DevOps - matching the v0.8.4 yml).
          2. Calls `Get-AzLocalClusterInventory -PassThru` to build a
             ResourceId -> UpdateRing map for the per-ring pivot section.
          3. When -Scope is 'all' and the inventory is empty, short-
             circuits with zero counts, an IDLE markdown summary, and
             empty step outputs (matches the v0.8.4 yml early-exit).
          4. Calls `Get-AzLocalClusterUpdateReadiness` TWICE so the
             cmdlet's native -ExportPath emitter produces both the
             readiness.csv (humans) and readiness.xml (JUnit, one
             <testcase> per cluster). This preserves the v0.8.4
             dorny/test-reporter contract byte-for-byte.
          5. Calls `Test-AzLocalClusterHealth -BlockingOnly` TWICE
             (CSV + JUnit) for the same reason.
          6. Computes the 3-bucket model that matches the
             Get-AzLocalClusterUpdateReadiness Summary:
             ReadyForUpdate / UpToDate / NotReady.
          7. Computes Critical-health bucket counts from the
             Test-AzLocalClusterHealth -PassThru row shape
             (ClusterName, HealthState, CriticalCount, WarningCount).
          8. Merges readiness.xml + health-blocking.xml into a single
             combined assess-readiness.xml (single Checks-tab entry).
          9. Emits the markdown step summary (8 sections: header tile,
             action banner, summary counts, Not-Ready table, Critical-
             health table, per-ring pivot, all-clusters detail,
             cross-link list) via `Add-AzLocalPipelineStepSummary`.
         10. Emits 2 step outputs via `Set-AzLocalPipelineOutput`:
             not_ready, critical_failures.

        Internal reuse (per the v0.8.5 thin-YAML consistency contract):
          * `Get-AzLocalClusterInventory` for the all-clusters scope and
            the UpdateRing pivot map.
          * `Get-AzLocalClusterUpdateReadiness` for the readiness CSV
            and JUnit XML.
          * `Test-AzLocalClusterHealth -BlockingOnly` for the blocking
            health CSV and JUnit XML.
          * `Add-AzLocalPipelineStepSummary` for the rendered markdown.
          * `Set-AzLocalPipelineOutput` for the step outputs.
          * `Get-AzLocalPipelineHost` is implicit (the above branch on it).

    .PARAMETER OutputDirectory
        Directory to write artifacts into. Created if it does not exist.
        Defaults to './artifacts' (GH / Local) or
        `$env:BUILD_ARTIFACTSTAGINGDIRECTORY` (Azure DevOps).

    .PARAMETER Scope
        'all' (default) - assess every cluster the identity can see (via
        Get-AzLocalClusterInventory). 'by-update-ring' - assess only
        clusters whose UpdateRing tag matches -UpdateRing.

    .PARAMETER UpdateRing
        UpdateRing tag value to filter by when -Scope is 'by-update-ring'.
        Accepts a single ring ('Wave1'), a semicolon-delimited list
        ('Prod;Ring2'), or '***' to match every cluster that HAS the
        UpdateRing tag set. Ignored when -Scope is 'all'.

    .PARAMETER ReadinessCsvFileName
        Filename for the per-cluster readiness CSV.
        Default 'readiness.csv'.

    .PARAMETER ReadyForUpdateCsvFileName
        Filename for the CSV that lists only the clusters classified as
        'Ready for Update' (ClusterName, UpdateRing, CurrentVersion,
        RecommendedUpdate, ClusterResourceId). Default 'ready-for-update.csv'.

    .PARAMETER ReadinessXmlFileName
        Filename for the readiness JUnit XML report.
        Default 'readiness.xml'.

    .PARAMETER HealthCsvFileName
        Filename for the per-cluster blocking-health CSV.
        Default 'health-blocking.csv'.

    .PARAMETER HealthXmlFileName
        Filename for the blocking-health JUnit XML report.
        Default 'health-blocking.xml'.

    .PARAMETER CombinedXmlFileName
        Filename for the merged readiness + blocking-health JUnit report.
        Default 'assess-readiness.xml'.

    .PARAMETER SummaryFileName
        Per-task summary filename used by `Add-AzLocalPipelineStepSummary`
        on Azure DevOps and Local hosts.
        Default 'assess-readiness-summary.md'.

    .PARAMETER InstalledModuleVersion
        Optional [string] used in the markdown footer
        ('Generated by AzLocal.UpdateManagement v<x>').

    .PARAMETER PassThru
        When set, returns a single PSCustomObject summarising the run
        (TotalCount, ReadyForUpdateCount, UpToDateCount, AllowListHeldCount,
        NotReadyCount, CriticalFindings, ClustersWithCritical, ReadinessRows,
        HealthRows, and the file paths incl. ReadyForUpdateCsvPath).
        AllowListHeldCount is a labelled SUBSET of UpToDateCount (clusters that
        are Up to Date only because the allowedUpdateVersions allow-list held
        their Ready update).
        Without -PassThru the cmdlet emits nothing to the pipeline; the
        artifacts and step outputs are still produced.

    .OUTPUTS
        Nothing by default. When -PassThru is set, a single PSCustomObject.

    .EXAMPLE
        Export-AzLocalClusterUpdateReadinessReport -Scope all -PassThru

    .EXAMPLE
        Export-AzLocalClusterUpdateReadinessReport -Scope by-update-ring -UpdateRing 'Wave1'

    .NOTES
        Module: AzLocal.UpdateManagement (v0.8.5+)
        Roadmap: Step.5 - Assess Update Readiness (pre-flight gate).
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
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessCsvFileName = 'readiness.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadyForUpdateCsvFileName = 'ready-for-update.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessXmlFileName = 'readiness.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$HealthCsvFileName = 'health-blocking.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$HealthXmlFileName = 'health-blocking.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$CombinedXmlFileName = 'assess-readiness.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'assess-readiness-summary.md',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$InstalledModuleVersion,

        # v0.8.88: opt-OUT of the automatic "Check for updates" scan. By default,
        # any cluster bucketed Up-to-Date whose installed YYMM is behind the latest
        # released YYMM in the public manifest is treated as having a STALE update
        # assessment, and a fire-and-forget checkUpdates scan is triggered to refresh
        # it (Sync-AzLocalClusterUpdateSummary). Supplying this switch detects and
        # reports the stale clusters but does NOT trigger the refresh.
        [Parameter(Mandatory = $false)]
        [switch]$SkipStaleAssessmentScan,

        # API version for the checkUpdates action when auto-triggering a refresh.
        # The action is only exposed on the preview API surface.
        [Parameter(Mandatory = $false)]
        [string]$StaleAssessmentApiVersion = '2026-03-01-preview',

        # v0.9.1: optional apply-updates schedule (schema v2) whose
        # allowedUpdateVersions allow-list constrains which updates each ring may
        # install. When supplied, readiness is recomputed using ONLY the
        # allow-listed Ready updates (per-ring override beats the top-level
        # default; 'Latest' alone = no constraint) - clusters whose Ready updates
        # are all outside their allow-list are reported UpToDate.
        [Parameter(Mandatory = $false)]
        [string]$SchedulePath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $pipelineHost = Get-AzLocalPipelineHost

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

    $readinessCsv = Join-Path -Path $OutputDirectory -ChildPath $ReadinessCsvFileName
    $readyForUpdateCsv = Join-Path -Path $OutputDirectory -ChildPath $ReadyForUpdateCsvFileName
    $readinessXml = Join-Path -Path $OutputDirectory -ChildPath $ReadinessXmlFileName
    $healthCsv    = Join-Path -Path $OutputDirectory -ChildPath $HealthCsvFileName
    $healthXml    = Join-Path -Path $OutputDirectory -ChildPath $HealthXmlFileName
    $combinedXml  = Join-Path -Path $OutputDirectory -ChildPath $CombinedXmlFileName

    # Always fetch inventory so we can build a ResourceId -> UpdateRing map
    # for the per-ring pivot in the markdown summary (cheap ARG round-trip).
    $inventory = Get-AzLocalClusterInventory -PassThru
    $ringByResourceId = @{}
    if ($inventory) {
        foreach ($inv in $inventory) {
            $ringValue = if ($inv.UpdateRing) { [string]$inv.UpdateRing } else { '(no ring tag)' }
            $ringByResourceId[$inv.ResourceId] = $ringValue
        }
    }

    # ---- Scope params -----------------------------------------------------
    $scopeParams = @{}
    if ($Scope -eq 'by-update-ring' -and $UpdateRing) {        $scopeParams['ScopeByUpdateRingTag'] = $true
        $scopeParams['UpdateRingValue']      = $UpdateRing
        Write-Host "Scope: UpdateRing = $UpdateRing"
    }
    else {
        Write-Host "Scope: all clusters (via inventory)"
        if (-not $inventory -or @($inventory).Count -eq 0) {
            Write-Warning 'No clusters found in inventory.'
            Set-AzLocalPipelineOutput -Name 'not_ready'         -Value '0'
            Set-AzLocalPipelineOutput -Name 'critical_failures' -Value '0'
            $idleSb = New-Object 'System.Collections.Generic.List[string]'
            [void]$idleSb.Add('## Update Readiness Assessment')
            [void]$idleSb.Add('')
            [void]$idleSb.Add('**[IDLE]** No clusters found in inventory. Nothing to assess.')
            Add-AzLocalPipelineStepSummary -Markdown ($idleSb -join [Environment]::NewLine) -SummaryFileName $SummaryFileName | Out-Null
            if ($PassThru) {
                return [pscustomobject]@{
                    TotalCount           = 0
                    ReadyForUpdateCount  = 0
                    UpToDateCount        = 0
                    AllowListHeldCount   = 0
                    NotReadyCount        = 0
                    CriticalFindings     = 0
                    ClustersWithCritical = 0
                    ReadinessRows        = @()
                    HealthRows           = @()
                    StaleAssessmentCount         = 0
                    StaleAssessmentClusters      = @()
                    StaleAssessmentScanTriggered = $false
                    ReadinessCsvPath     = $readinessCsv
                    ReadyForUpdateCsvPath = $readyForUpdateCsv
                    ReadinessXmlPath     = $readinessXml
                    HealthCsvPath        = $healthCsv
                    HealthXmlPath        = $healthXml
                    CombinedXmlPath      = $combinedXml
                }
            }
            return
        }
        $scopeParams['ClusterResourceIds'] = @($inventory | Select-Object -ExpandProperty ResourceId)
    }

    Write-Host ''
    Write-Host '========================================'
    Write-Host 'Step 1: Readiness (Get-AzLocalClusterUpdateReadiness)'
    Write-Host '========================================'

    # v0.9.1: forward the schedule allow-list to BOTH readiness calls so the
    # CSV and the JUnit XML reflect the same constrained Ready/UpToDate buckets.
    # SchedulePath is added to a readiness-only clone so it does NOT leak into
    # $scopeParams (which is also reused by Test-AzLocalClusterHealth, which has
    # no -SchedulePath parameter).
    $readinessParams = $scopeParams.Clone()
    if ($SchedulePath) {
        $readinessParams['SchedulePath'] = $SchedulePath
        Write-Host "Allow-list: apply-updates schedule '$SchedulePath'"
    }

    # CSV for humans
    $readiness = Get-AzLocalClusterUpdateReadiness @readinessParams `
        -ExportPath $readinessCsv `
        -PassThru

    # JUnit XML for the test reporter (ExportPath .xml auto-detects JUnitXml).
    # Two calls intentionally - this preserves the v0.8.4 dorny/test-reporter
    # contract byte-for-byte (the cmdlet's native JUnit shape is what operators
    # have screenshots / automations for). ARG round-trip is cheap.
    $null = Get-AzLocalClusterUpdateReadiness @readinessParams `
        -ExportPath $readinessXml

    # v0.7.99: 3-bucket model matches Get-AzLocalClusterUpdateReadiness Summary.
    # UpToDate clusters are NOT rolled into NotReady - they are a distinct bucket.
    # v0.8.74: classification now uses the shared Get-AzLocalClusterReadinessStatus
    # priority cascade (identical to Step.9) so a cluster that has applied all
    # updates is counted as Up to Date even though its AllAvailableUpdates still
    # lists the already-installed packages. The previous strict
    # IsNullOrEmpty(AllAvailableUpdates) test silently returned zero.
    $readyForUpdate = @($readiness | Where-Object { (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'ReadyForUpdate' }).Count
    $upToDate = @($readiness | Where-Object { (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'UpToDate' }).Count
    $total = @($readiness).Count
    $notReady = $total - $readyForUpdate - $upToDate

    # v0.9.15: clusters that classify 'Up to Date' ONLY because the
    # allowedUpdateVersions allow-list filtered out every Ready update. These
    # are surfaced in a dedicated VISIBLE table (section 6b) + a summary
    # sub-count so operators no longer have to expand 'All clusters detail' to
    # find them. Membership uses the SAME predicate as the detail ' *' marker
    # (classified UpToDate AND a non-empty ReadyUpdates list). It is a labelled
    # SUBSET of Up to Date - kept INSIDE the $upToDate total so the summary and
    # per-UpdateRing pivot arithmetic (Ready + UpToDate + NotReady = Total)
    # stays consistent.
    $allowListHeldRows = @($readiness | Where-Object {
            (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'UpToDate' -and
            $_.PSObject.Properties['ReadyUpdates'] -and $_.ReadyUpdates -and
            (@(([string]$_.ReadyUpdates) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }).Count -gt 0)
        })
    $allowListHeld = $allowListHeldRows.Count

    Write-Host ''
    Write-Host "Total clusters in scope: $total"
    Write-Host "Ready for update      : $readyForUpdate"
    Write-Host "Up to date            : $upToDate"
    Write-Host "  (held by allow-list): $allowListHeld"
    Write-Host "Not ready for update  : $notReady"

    # ---- Ready-for-Update subset (v0.8.97) --------------------------------
    # Shared projection (Get-AzLocalReadyForUpdateRows) reused by the markdown
    # "Clusters - Ready for Update" table below AND by the dedicated CSV
    # artefact. The same projection/table is rendered by Monitor: 3 - Fleet
    # Update Status.
    $readyForUpdateRows = @(Get-AzLocalReadyForUpdateRows -ReadinessRows $readiness -RingByResourceId $ringByResourceId)
    try {
        if ($readyForUpdateRows.Count -gt 0) {
            $readyForUpdateRows | ConvertTo-SafeCsvCollection | Export-Csv -Path $readyForUpdateCsv -NoTypeInformation -Force
        }
        else {
            # Always emit a header-only CSV so the artefact is present even when
            # no clusters are ready. ASCII keeps it BOM-free.
            Set-Content -Path $readyForUpdateCsv -Value '"ClusterName","UpdateRing","CurrentVersion","RecommendedUpdate","ClusterResourceId"' -Encoding ASCII
        }
        Write-Host "Ready-for-Update CSV  : $readyForUpdateCsv ($($readyForUpdateRows.Count) cluster(s))"
    }
    catch {
        Write-Warning "Failed to write ready-for-update CSV: $($_.Exception.Message)"
    }

    # ---- Stale update-assessment detection (v0.8.88) ----------------------
    # A cluster can report Up-to-Date while a newer solution build is actually
    # available, because its cached update assessment has not been refreshed.
    # Detect that by comparing each Up-to-Date cluster's installed YYMM against
    # the latest released YYMM in the public manifest. Detection is read-only and
    # never throws; the auto-refresh (checkUpdates) is fire-and-forget and is
    # suppressed by -SkipStaleAssessmentScan.
    $staleClusters = New-Object 'System.Collections.Generic.List[object]'
    $staleScanTriggered = $false
    $latestManifest = $null
    try {
        $latestManifest = Get-AzLocalLatestSolutionVersion
    }
    catch {
        Write-Warning "Could not fetch the latest released solution version for stale-assessment detection: $($_.Exception.Message)"
    }
    if ($latestManifest -and $latestManifest.LatestYYMM) {
        foreach ($r in $readiness) {
            if ((Get-AzLocalClusterReadinessStatus -ReadinessRow $r) -ne 'UpToDate') { continue }
            $cv = if ($r.PSObject.Properties['CurrentVersion'] -and $r.CurrentVersion) { [string]$r.CurrentVersion } else { '' }
            $staleCheck = Test-AzLocalUpdateAssessmentStale -CurrentVersion $cv -LatestYYMM ([string]$latestManifest.LatestYYMM)
            if ($staleCheck.IsStale) {
                $clusterResId = if ($r.PSObject.Properties['ClusterResourceId'] -and $r.ClusterResourceId) { [string]$r.ClusterResourceId } else { '' }
                $staleClusters.Add([pscustomobject]@{
                        ClusterName       = [string]$r.ClusterName
                        ClusterResourceId = $clusterResId
                        CurrentVersion    = $cv
                        ClusterYYMM       = $staleCheck.ClusterYYMM
                        LatestYYMM        = $staleCheck.LatestYYMM
                    }) | Out-Null
            }
        }
    }
    if ($staleClusters.Count -gt 0) {
        Write-Host ''
        Write-Host "Stale update assessments: $($staleClusters.Count) Up-to-Date cluster(s) behind the latest released YYMM ($($latestManifest.LatestYYMM))"
        $staleResourceIds = @($staleClusters | Where-Object { $_.ClusterResourceId } | Select-Object -ExpandProperty ClusterResourceId)
        if ($SkipStaleAssessmentScan) {
            Write-Host '  -SkipStaleAssessmentScan set: NOT triggering an automatic Check for Updates.'
        }
        elseif ($staleResourceIds.Count -gt 0) {
            try {
                Write-Host "  Triggering fire-and-forget 'Check for updates' on $($staleResourceIds.Count) cluster(s)..."
                Sync-AzLocalClusterUpdateSummary -ClusterResourceIds $staleResourceIds -ApiVersion $StaleAssessmentApiVersion -Force | Out-Null
                $staleScanTriggered = $true
            }
            catch {
                Write-Warning "Automatic Check for Updates failed: $($_.Exception.Message)"
            }
        }
    }

    Write-Host ''
    Write-Host '========================================'
    Write-Host 'Step 2: Blocking health (Test-AzLocalClusterHealth -BlockingOnly)'
    Write-Host '========================================'

    $health = Test-AzLocalClusterHealth @scopeParams `
        -BlockingOnly `
        -ExportPath $healthCsv `
        -PassThru

    $null = Test-AzLocalClusterHealth @scopeParams `
        -BlockingOnly `
        -ExportPath $healthXml

    # ---- Combined JUnit XML ------------------------------------------------
    # Merge readiness.xml + health-blocking.xml into assess-readiness.xml so
    # operators get one Checks-tab entry instead of two. The individual XMLs
    # are still published below as [JUnit Debug] entries for parity.
    try {
        $readinessDoc = [xml](Get-Content -LiteralPath $readinessXml -Raw)
        $healthDoc    = [xml](Get-Content -LiteralPath $healthXml -Raw)
        $combinedDoc  = New-Object System.Xml.XmlDocument
        $declaration  = $combinedDoc.CreateXmlDeclaration('1.0', 'utf-8', $null)
        $combinedDoc.AppendChild($declaration) | Out-Null
        $rootElement  = $combinedDoc.CreateElement('testsuites')
        $rootElement.SetAttribute('name', 'Update Readiness Assessment')
        $combinedDoc.AppendChild($rootElement) | Out-Null
        foreach ($srcDoc in @($readinessDoc, $healthDoc)) {
            $suites = if ($srcDoc.DocumentElement.LocalName -eq 'testsuites') {
                $srcDoc.DocumentElement.SelectNodes('testsuite')
            }
            else {
                ,$srcDoc.DocumentElement
            }
            foreach ($suite in $suites) {
                $imported = $combinedDoc.ImportNode($suite, $true)
                $rootElement.AppendChild($imported) | Out-Null
            }
        }
        $combinedDoc.Save($combinedXml)
        Write-Host "Combined JUnit report: $combinedXml"
    }
    catch {
        Write-Warning "Failed to build combined JUnit report: $($_.Exception.Message)"
    }

    # Test-AzLocalClusterHealth -PassThru row shape (one row per cluster):
    #   ClusterName, HealthState, Passed, CriticalCount, WarningCount, Failures
    # Aggregate from CriticalCount / Failures (NOT a non-existent Severity
    # property, which silently returned 0 in earlier yml versions).
    $criticalSum = ($health | Measure-Object -Property CriticalCount -Sum).Sum
    $criticalFindings = if ($criticalSum) { [int]$criticalSum } else { 0 }
    $clustersWithCritical = @($health | Where-Object { [int]$_.CriticalCount -gt 0 }).Count

    Write-Host ''
    Write-Host "Critical findings      : $criticalFindings"
    Write-Host "Clusters with Critical : $clustersWithCritical"

    # ---- Step outputs -----------------------------------------------------
    Set-AzLocalPipelineOutput -Name 'not_ready'         -Value ([string]$notReady)
    Set-AzLocalPipelineOutput -Name 'critical_failures' -Value ([string]$clustersWithCritical)

    # ---- Markdown step summary (8 sections) -------------------------------
    $md = New-Object 'System.Collections.Generic.List[string]'
    [void]$md.Add('## Update Readiness Assessment')
    [void]$md.Add('')

    # 1. Header tile (one-line status, ASCII-safe brackets)
    $scopeLabel = $Scope
    if ($UpdateRing) { $scopeLabel = "$Scope (UpdateRing = $UpdateRing)" }
    $statusWord = if ($notReady -gt 0 -or $clustersWithCritical -gt 0) { 'ATTENTION' } else { 'OK' }
    [void]$md.Add("**[$statusWord]** $total cluster(s) assessed | $readyForUpdate Ready for Update | $upToDate Up to Date | $notReady Not Ready for Update | $clustersWithCritical with Critical health failures | Scope: $scopeLabel")
    [void]$md.Add('')

    # 2. Action banner
    if ($notReady -gt 0 -or $clustersWithCritical -gt 0) {
        [void]$md.Add("> **Action required**: $notReady cluster(s) not ready and/or $clustersWithCritical cluster(s) with Critical health failures. Review the **Not-Ready** and **Critical-health** sections below first; the CSV artifacts in ``azlocal-readiness-assessment-report_*`` carry the full per-finding detail. Remediate (hardware vendor SBE / firmware / cluster health) before or alongside the next apply-updates run. **The healthy clusters are safe to proceed** - the **apply-updates** pipeline is per-cluster scoped.")
    }
    else {
        [void]$md.Add('> **All clear**: every cluster in scope is ready for update. Safe to proceed with the **apply-updates** pipeline for this ring.')
    }
    [void]$md.Add('')

    # 3. Summary counts
    # v0.8.82: use shared icon map cells AS the metric label (each icon-map
    # value already includes its own text, e.g. "<U+2705> Ready for Update").
    # Previously each row also appended a duplicate trailing label, producing
    # "<U+2705> Ready for Update Ready for update" - fixed by emitting the
    # icon-map cell unmodified.
    $iconMap = Get-AzLocalStatusIconMap -PipelineHost $pipelineHost
    [void]$md.Add('### Summary counts')
    [void]$md.Add('')
    [void]$md.Add('| Metric | Count |')
    [void]$md.Add('|--------|-------|')
    [void]$md.Add("| Total clusters in scope | $total |")
    [void]$md.Add(("| {0} | {1} |" -f $iconMap['ReadyForUpdate'], $readyForUpdate))
    [void]$md.Add(("| {0} | {1} |" -f $iconMap['UpToDate'], $upToDate))
    # v0.9.15: labelled sub-count (only when non-zero) of the Up-to-Date rows
    # that are Up to Date ONLY because their Ready update was allow-list-held.
    if ($allowListHeld -gt 0) {
        [void]$md.Add(("| &nbsp;&nbsp;of which held by allow-list | {0} |" -f $allowListHeld))
    }
    [void]$md.Add(("| {0} | {1} |" -f $iconMap['ActionRequired'], $notReady))
    [void]$md.Add(("| {0} (Clusters with Critical health failures) | {1} |" -f $iconMap['HealthFailure'], $clustersWithCritical))
    [void]$md.Add("| Total Critical findings | $criticalFindings |")
    [void]$md.Add('')

    # 4. Not-Ready cluster table (blocking findings first)
    # v0.8.74: exclude Up-to-Date clusters (and Ready clusters) - they require no
    # action and previously cluttered this "review first" table, implying failure.
    $notReadyRows = @($readiness | Where-Object {
            (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -notin @('ReadyForUpdate', 'UpToDate')
        })
    if ($notReadyRows.Count -gt 0) {
        [void]$md.Add('### Not-Ready clusters (review first)')
        [void]$md.Add('')
        # v0.8.81: portal deep-links on the Cluster column - operators can
        # jump straight to the cluster blade. Tip explains the GitHub-strips-
        # target=_blank behaviour for the first column.
        [void]$md.Add((Get-AzLocalCtrlClickTip))
        [void]$md.Add('')
        [void]$md.Add('| Cluster | UpdateRing | Current version | Update state | Health | Status | Blocking reasons |')
        [void]$md.Add('|---------|------------|-----------------|--------------|--------|--------|------------------|')
        # v0.9.15: track whether any Not-Ready cluster is SBE-prerequisite
        # blocked so a manual-action knowledge note can be emitted once below.
        $anySbeBlocked = $false
        foreach ($r in ($notReadyRows | Sort-Object @{Expression={ if ($ringByResourceId.ContainsKey($_.ClusterResourceId)) { $ringByResourceId[$_.ClusterResourceId] } else { 'zzz' } }}, ClusterName)) {
            $ring = if ($ringByResourceId.ContainsKey($r.ClusterResourceId)) { $ringByResourceId[$r.ClusterResourceId] } else { '-' }
            $cv = if ($r.CurrentVersion) { $r.CurrentVersion } else { '-' }
            # v0.8.82: when BlockingReasons is empty for a Not-Ready row,
            # derive a meaningful token from the Status bucket so the column
            # never shows '-' in the "review first" table. The previous
            # behaviour left InProgress / UpdateFailed / NeedsAttention /
            # Warning-only HealthFailure / SbeBlocked rows with '-', forcing
            # operators to cross-read Update state + Health to infer the
            # reason. The derived label complements (does not replace) the
            # Status icon and is host-agnostic plain text.
            $statusKey = Get-AzLocalClusterReadinessStatus -ReadinessRow $r
            $existingBr = if ($r.PSObject.Properties['BlockingReasons'] -and $r.BlockingReasons) { [string]$r.BlockingReasons } else { '' }
            if ($existingBr) {
                $br = $existingBr
            } else {
                $derived = switch ($statusKey) {
                    'InProgress'         { 'UpdateInProgress (run in-flight)' }
                    'UpdateFailed'       {
                        if ($r.PSObject.Properties['UpdateState'] -and $r.UpdateState) {
                            'UpdateState={0}' -f $r.UpdateState
                        } else { 'UpdateFailed' }
                    }
                    'ActionRequired'     { 'UpdateState=PreparationFailed' }
                    'HealthFailure'      { 'HealthState=Failure (no Critical findings; review Warning findings)' }
                    'SbeBlocked'         { 'PrerequisiteRequired (SBE update first)' }
                    'NeedsInvestigation' { 'NeedsInvestigation (no Update or Health signal)' }
                    default              { '-' }
                }
                # Append Warning health context where it adds information.
                if ($r.PSObject.Properties['HealthState'] -and $r.HealthState -eq 'Warning' -and $statusKey -notin @('HealthFailure')) {
                    $derived = '{0}; HealthState=Warning' -f $derived
                }
                $br = $derived
            }
            $clusterResId = if ($r.PSObject.Properties['ClusterResourceId'] -and $r.ClusterResourceId) { [string]$r.ClusterResourceId } else { '' }
            $clusterCell = Get-AzLocalClusterPortalLink -ClusterName ([string]$r.ClusterName) -ClusterResourceId $clusterResId
            $statusCell = if ($iconMap.ContainsKey($statusKey)) { $iconMap[$statusKey] } else { $iconMap['NeedsInvestigation'] }
            if ($statusKey -eq 'SbeBlocked') { $anySbeBlocked = $true }
            [void]$md.Add("| $clusterCell | $ring | $cv | $($r.UpdateState) | $($r.HealthState) | $statusCell | $br |")
        }
        # v0.9.15: SBE-prerequisite clusters need a manual, hardware-vendor
        # (OEM) step the pipeline cannot perform - explain it once, only when
        # at least one Not-Ready cluster is SBE-blocked.
        if ($anySbeBlocked) {
            [void]$md.Add('')
            [void]$md.Add('> **`SBE Prerequisite` - manual action required.** These clusters have a Solution Builder Extension (SBE) update that must be applied **before** the Azure Local platform/OS update can proceed. The pipeline cannot action this automatically. Review your **Hardware OEM provider''s** Azure Local / SBE documentation for the correct SBE package and version, then **sideload the SBE update onto the cluster**. Once it is applied and the cluster re-assesses, it moves out of this table.')
        }
        [void]$md.Add('')
    }

    # 5. Critical-health cluster table
    $criticalRows = @($health | Where-Object { [int]$_.CriticalCount -gt 0 })
    if ($criticalRows.Count -gt 0) {
        [void]$md.Add('### Critical-health clusters')
        [void]$md.Add('')
        [void]$md.Add('_Cross-link: see the **fleet-connectivity-status** pipeline for connectivity-class failures and the **fleet-health-status** pipeline for the broader Critical/Warning catalog._')
        [void]$md.Add('')
        [void]$md.Add('| Cluster | UpdateRing | Health state | Critical | Warning |')
        [void]$md.Add('|---------|------------|--------------|----------|---------|')
        foreach ($r in ($criticalRows | Sort-Object @{Expression={[int]$_.CriticalCount}; Descending=$true}, ClusterName)) {
            $invMatch = $inventory | Where-Object { $_.ClusterName -eq $r.ClusterName } | Select-Object -First 1
            $ring = if ($invMatch -and $invMatch.UpdateRing) { $invMatch.UpdateRing } else { '-' }
            [void]$md.Add("| $($r.ClusterName) | $ring | $($r.HealthState) | $($r.CriticalCount) | $($r.WarningCount) |")
        }
        [void]$md.Add('')
    }

    # 6. Per-UpdateRing pivot (only when >1 ring in scope)
    $ringGroups = $readiness | Group-Object @{Expression={ if ($ringByResourceId.ContainsKey($_.ClusterResourceId)) { $ringByResourceId[$_.ClusterResourceId] } else { '(no ring tag)' } }} | Sort-Object Name
    if (@($ringGroups).Count -gt 1) {
        [void]$md.Add('### Per UpdateRing breakdown')
        [void]$md.Add('')
        [void]$md.Add('| UpdateRing | Total | Ready for Update | Up to Date | Not Ready for Update |')
        [void]$md.Add('|------------|-------|------------------|------------|----------------------|')
        foreach ($g in $ringGroups) {
            $gReady = @($g.Group | Where-Object { (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'ReadyForUpdate' }).Count
            $gUpToDate = @($g.Group | Where-Object { (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'UpToDate' }).Count
            $gNotReady = $g.Count - $gReady - $gUpToDate
            [void]$md.Add("| $($g.Name) | $($g.Count) | $gReady | $gUpToDate | $gNotReady |")
        }
        [void]$md.Add('')
    }

    # 6b. Up-to-date-but-held-by-allow-list table (v0.9.15)
    # A dedicated VISIBLE table (not behind the 'All clusters detail' expander)
    # for clusters that are 'Up to Date' ONLY because their Ready update was
    # filtered out by the allowedUpdateVersions allow-list. Rendering it as its
    # own top-level section means operators see the exact update name/version
    # to copy into apply-updates-schedule.yml without expanding anything.
    if ($allowListHeldRows.Count -gt 0) {
        [void]$md.Add('### Up to date - Ready update held by allow-list')
        [void]$md.Add('')
        [void]$md.Add('> These clusters are reported **Up to Date** for this run **only because their Available Ready update(s) are not in the `allowedUpdateVersions` allow-list** - they were filtered out, so there is no action to take right now. To let a cluster proceed, copy the exact update name/version from the **Available Ready updates** column into your `apply-updates-schedule.yml` allow-list.')
        [void]$md.Add('')
        [void]$md.Add((Get-AzLocalCtrlClickTip))
        [void]$md.Add('')
        [void]$md.Add('| Cluster | UpdateRing | Current version | Available Ready updates | Allow-list rule |')
        [void]$md.Add('|---------|------------|-----------------|-------------------------|-----------------|')
        foreach ($r in ($allowListHeldRows | Sort-Object @{Expression={ if ($ringByResourceId.ContainsKey($_.ClusterResourceId)) { $ringByResourceId[$_.ClusterResourceId] } else { 'zzz' } }}, ClusterName)) {
            $ring = if ($ringByResourceId.ContainsKey($r.ClusterResourceId)) { $ringByResourceId[$r.ClusterResourceId] } else { '-' }
            $cv  = if ($r.CurrentVersion) { $r.CurrentVersion } else { '-' }
            $readyRaw = if ($r.PSObject.Properties['ReadyUpdates'] -and $r.ReadyUpdates) { [string]$r.ReadyUpdates } else { '' }
            $readyItems = @($readyRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($readyItems.Count -eq 1) {
                $availCell = $readyItems[0]
            }
            elseif ($readyItems.Count -gt 1) {
                $availCell = ('<details><summary>{0} update(s)</summary>{1}</details>' -f $readyItems.Count, ($readyItems -join '<br>'))
            }
            else {
                $availCell = '-'
            }
            $allowRule = if ($r.PSObject.Properties['AllowedUpdateVersions'] -and $r.AllowedUpdateVersions) { [string]$r.AllowedUpdateVersions } else { '-' }
            $clusterResId = if ($r.PSObject.Properties['ClusterResourceId'] -and $r.ClusterResourceId) { [string]$r.ClusterResourceId } else { '' }
            $clusterCell = Get-AzLocalClusterPortalLink -ClusterName ([string]$r.ClusterName) -ClusterResourceId $clusterResId
            [void]$md.Add("| $clusterCell | $ring | $cv | $availCell | $allowRule |")
        }
        [void]$md.Add('')
    }

    # 7. All-clusters detail table
    if ($total -gt 0) {
        # 7a. Clusters - Ready for Update (shared table, rendered before the
        # full detail list so operators see the actionable "go now" set first).
        foreach ($line in (Get-AzLocalReadyForUpdateTableMarkdown -ReadyRows $readyForUpdateRows)) {
            [void]$md.Add($line)
        }

        [void]$md.Add('### All clusters detail')
        [void]$md.Add('')
        # v0.8.81: portal deep-links on the Cluster column + status icons via
        # shared iconMap (mirrors Step.06 readiness-gate output).
        [void]$md.Add((Get-AzLocalCtrlClickTip))
        [void]$md.Add('')
        # v0.8.97: collapse the full per-cluster list behind a details block
        # (matches the "Expand to view clusters" pattern in Monitor: 1 - Fleet
        # Connectivity Status) so the actionable tables above stay in view.
        [void]$md.Add('<details>')
        [void]$md.Add('<summary>Expand to view clusters</summary>')
        [void]$md.Add('')
        # v0.8.82: sort UpdateRing first, then Status priority (operator-actionable
        # items first within each ring), then ClusterName. Previous v0.8.82
        # ordering put Status first which grouped failures across rings; the
        # ring-first ordering matches how operators reason about wave rollout.
        $statusOrder = @{
            'InProgress'         = 1
            'HealthFailure'      = 2
            'UpdateFailed'       = 3
            'ActionRequired'     = 4
            'SbeBlocked'         = 5
            'NeedsInvestigation' = 6
            'ReadyForUpdate'     = 7
            'UpToDate'           = 8
        }
        $sorted = $readiness | Sort-Object `
            @{Expression={ if ($ringByResourceId.ContainsKey($_.ClusterResourceId)) { $ringByResourceId[$_.ClusterResourceId] } else { 'zzz' } }}, `
            @{Expression={ $k = Get-AzLocalClusterReadinessStatus -ReadinessRow $_; if ($statusOrder.ContainsKey($k)) { $statusOrder[$k] } else { 99 } }}, `
            ClusterName
        # v0.9.14: build the detail rows first so we know whether ANY cluster is
        # 'Up to Date' ONLY because the allow-list filtered out every Ready
        # update. Those rows get a ' *' marker on the Status cell and a footnote
        # is emitted above the table so a green icon is never read as "genuinely
        # current" when Azure actually has updates waiting.
        $detailRows = New-Object System.Collections.Generic.List[string]
        $anyAllowListSuppressed = $false
        foreach ($r in $sorted) {
            $ring = if ($ringByResourceId.ContainsKey($r.ClusterResourceId)) { $ringByResourceId[$r.ClusterResourceId] } else { '-' }
            $cv  = if ($r.CurrentVersion) { $r.CurrentVersion } else { '-' }
            $csv = if ($r.PSObject.Properties['CurrentSbeVersion'] -and $r.CurrentSbeVersion) { $r.CurrentSbeVersion } else { '-' }
            $ru  = if ($r.RecommendedUpdate) { $r.RecommendedUpdate } else { '-' }
            $lu  = if ($r.PSObject.Properties['LastUpdated'] -and $r.LastUpdated) { $r.LastUpdated } else { '-' }
            $statusKey = Get-AzLocalClusterReadinessStatus -ReadinessRow $r
            $statusCell = if ($iconMap.ContainsKey($statusKey)) { $iconMap[$statusKey] } else { $iconMap['NeedsInvestigation'] }
            $clusterResId = if ($r.PSObject.Properties['ClusterResourceId'] -and $r.ClusterResourceId) { [string]$r.ClusterResourceId } else { '' }
            $clusterCell = Get-AzLocalClusterPortalLink -ClusterName ([string]$r.ClusterName) -ClusterResourceId $clusterResId
            # Per-cell list of the Ready updates available for this cluster
            # (name/version exactly as Azure reports them). A single update is
            # rendered inline; 2+ collapse behind a <details> expander. '-' when
            # the cluster genuinely has nothing Ready.
            $readyRaw = if ($r.PSObject.Properties['ReadyUpdates'] -and $r.ReadyUpdates) { [string]$r.ReadyUpdates } else { '' }
            $readyItems = @($readyRaw -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($readyItems.Count -eq 0) {
                $availCell = '-'
            }
            elseif ($readyItems.Count -eq 1) {
                # v0.9.14: a lone Ready update is shown inline (no expander) so
                # the tell-tale "UpToDate yet one update available" allow-list
                # mismatch is visible at a glance - the single most common case
                # for a silently-suppressed OEM SBE - without needing a click.
                $availCell = $readyItems[0]
            }
            else {
                $availCell = ('<details><summary>{0} update(s)</summary>{1}</details>' -f $readyItems.Count, ($readyItems -join '<br>'))
            }
            # v0.9.14: a cluster reporting 'Up to Date' while it STILL has Ready
            # updates can only be in that state because the allow-list excluded
            # every one. Mark the Status cell with ' *' (explained by the
            # footnote above the table) so the operator isn't misled.
            $isAllowListSuppressed = ($statusKey -eq 'UpToDate') -and ($readyItems.Count -gt 0)
            if ($isAllowListSuppressed) {
                $statusCell = "$statusCell *"
                $anyAllowListSuppressed = $true
            }
            [void]$detailRows.Add("| $clusterCell | $ring | $cv | $csv | $($r.UpdateState) | $($r.HealthState) | $statusCell | $lu | $ru | $availCell |")
        }
        # v0.9.14: footnote (only when at least one cluster is suppressed) that
        # explains the ' *' Status marker and points at the exact remediation.
        if ($anyAllowListSuppressed) {
            [void]$md.Add('> \* **Status is `Up to Date` only because the cluster''s Available Ready update(s) are not listed in the `allowedUpdateVersions` allow-list** - they were filtered out, so there is no action to take this run. Copy the update name/version from the **Available Ready updates** column into your `apply-updates-schedule.yml` allow-list to let the cluster proceed.')
            [void]$md.Add('')
        }
        # v0.9.14: 'Available Ready updates' column exposes every update Azure
        # reports in a Ready state for the cluster (the pre-allow-list-filter
        # list). Collapsed per-cell via <details> so the table stays tidy. A row
        # showing 'Up to Date *' but a NON-empty available list is the tell-tale
        # sign an allowedUpdateVersions entry is missing/mistyped - the operator
        # can copy the exact name/version straight into the YML.
        [void]$md.Add('| Cluster | UpdateRing | Current version | Current SBE version | Update state | Health | Status | Last Updated | Recommended update | Available Ready updates |')
        [void]$md.Add('|---------|------------|-----------------|---------------------|--------------|--------|--------|--------------|--------------------|-------------------------|')
        foreach ($row in $detailRows) {
            [void]$md.Add($row)
        }
        [void]$md.Add('')
        [void]$md.Add('</details>')
        [void]$md.Add('')
    }

    # 8. Stale update assessments (v0.8.88)
    if ($staleClusters.Count -gt 0) {
        [void]$md.Add('### Stale update assessments')
        [void]$md.Add('')
        $scanNote = if ($SkipStaleAssessmentScan) {
            'A refresh was **not** triggered (`-SkipStaleAssessmentScan`). Run **Sync-AzLocalClusterUpdateSummary** (or the portal "Check for updates" button) on these clusters, then re-run this assessment.'
        }
        elseif ($staleScanTriggered) {
            'A fire-and-forget **Check for updates** (checkUpdates) was triggered automatically on these clusters to refresh the assessment. Re-run this assessment shortly to pick up the refreshed state.'
        }
        else {
            'No refresh was triggered (no resolvable Resource IDs, or the trigger failed - see the run log).'
        }
        [void]$md.Add("> These clusters report **Up to Date** but their installed build is behind the latest released version ($($latestManifest.LatestYYMM)) in the public manifest - their update assessment is likely stale. $scanNote")
        [void]$md.Add('')
        [void]$md.Add('| Cluster | Installed version | Installed YYMM | Latest released YYMM |')
        [void]$md.Add('|---------|-------------------|----------------|----------------------|')
        foreach ($s in ($staleClusters | Sort-Object ClusterName)) {
            $cvCell = if ($s.CurrentVersion) { $s.CurrentVersion } else { '-' }
            [void]$md.Add("| $($s.ClusterName) | $cvCell | $($s.ClusterYYMM) | $($s.LatestYYMM) |")
        }
        [void]$md.Add('')
    }

    # 9. Cross-links to other pipelines
    [void]$md.Add('### Cross-link to other pipelines')
    [void]$md.Add('')
    [void]$md.Add('- **fleet-connectivity-status** - root-cause Disconnected / Offline / partial-connectivity findings on the Not-Ready and Critical-health rows above.')
    [void]$md.Add('- **apply-updates** - apply updates to the Ready clusters in this ring (manual workflow_dispatch, or wait for the scheduled cron firing).')
    [void]$md.Add('- **monitor-updates** - tail in-flight runs once apply-updates has started (auto-trigger on apply-updates completion, or manual).')
    [void]$md.Add('- **fleet-health-status** - broader Critical / Warning health catalog across the whole fleet (not just blocking-only).')
    [void]$md.Add('')
    [void]$md.Add('_Note: the **Update Readiness Assessment** entry in the Checks tab is the merged combined view; the [JUnit Debug] entries are diagnostic mirrors for CI/test tooling._')

    if ($InstalledModuleVersion) {
        [void]$md.Add('')
        [void]$md.Add(('_Generated by AzLocal.UpdateManagement v{0}._' -f $InstalledModuleVersion))
    }

    Add-AzLocalPipelineStepSummary -Markdown ($md -join [Environment]::NewLine) -SummaryFileName $SummaryFileName | Out-Null

    if ($PassThru) {
        return [pscustomobject]@{
            TotalCount           = [int]$total
            ReadyForUpdateCount  = [int]$readyForUpdate
            UpToDateCount        = [int]$upToDate
            AllowListHeldCount   = [int]$allowListHeld
            NotReadyCount        = [int]$notReady
            CriticalFindings     = [int]$criticalFindings
            ClustersWithCritical = [int]$clustersWithCritical
            ReadinessRows        = @($readiness)
            HealthRows           = @($health)
            StaleAssessmentCount         = [int]$staleClusters.Count
            StaleAssessmentClusters      = $staleClusters.ToArray()
            StaleAssessmentScanTriggered = [bool]$staleScanTriggered
            ReadinessCsvPath     = $readinessCsv
            ReadyForUpdateCsvPath = $readyForUpdateCsv
            ReadinessXmlPath     = $readinessXml
            HealthCsvPath        = $healthCsv
            HealthXmlPath        = $healthXml
            CombinedXmlPath      = $combinedXml
        }
    }
}
