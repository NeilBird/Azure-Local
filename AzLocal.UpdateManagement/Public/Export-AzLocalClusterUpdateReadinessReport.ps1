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
        (TotalCount, ReadyForUpdateCount, UpToDateCount, NotReadyCount,
        CriticalFindings, ClustersWithCritical, ReadinessRows,
        HealthRows, and the 5 file paths). Without -PassThru the cmdlet
        emits nothing to the pipeline; the artifacts and step outputs
        are still produced.

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
    if ($Scope -eq 'by-update-ring' -and $UpdateRing) {
        $scopeParams['ScopeByUpdateRingTag'] = $true
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
                    NotReadyCount        = 0
                    CriticalFindings     = 0
                    ClustersWithCritical = 0
                    ReadinessRows        = @()
                    HealthRows           = @()
                    ReadinessCsvPath     = $readinessCsv
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

    # CSV for humans
    $readiness = Get-AzLocalClusterUpdateReadiness @scopeParams `
        -ExportPath $readinessCsv `
        -PassThru

    # JUnit XML for the test reporter (ExportPath .xml auto-detects JUnitXml).
    # Two calls intentionally - this preserves the v0.8.4 dorny/test-reporter
    # contract byte-for-byte (the cmdlet's native JUnit shape is what operators
    # have screenshots / automations for). ARG round-trip is cheap.
    $null = Get-AzLocalClusterUpdateReadiness @scopeParams `
        -ExportPath $readinessXml

    # v0.7.99: 3-bucket model matches Get-AzLocalClusterUpdateReadiness Summary.
    # UpToDate clusters are NOT rolled into NotReady - they are a distinct bucket.
    $readyForUpdate = @($readiness | Where-Object { $_.ReadyForUpdate -eq $true }).Count
    $upToDate = @($readiness | Where-Object {
            $_.ReadyForUpdate -ne $true -and
            $_.UpdateState -in @('UpToDate', 'AppliedSuccessfully') -and
            [string]::IsNullOrEmpty([string]$_.AllAvailableUpdates)
        }).Count
    $total = @($readiness).Count
    $notReady = $total - $readyForUpdate - $upToDate

    Write-Host ''
    Write-Host "Total clusters in scope: $total"
    Write-Host "Ready for update      : $readyForUpdate"
    Write-Host "Up to date            : $upToDate"
    Write-Host "Not ready for update  : $notReady"

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
        [void]$md.Add("> **Action required**: $notReady cluster(s) not ready and/or $clustersWithCritical cluster(s) with Critical health failures. Review the **Not-Ready** and **Critical-health** sections below first; the CSV artifacts in ``azlocal-step.5-readiness-assessment-report_*`` carry the full per-finding detail. Remediate (hardware vendor SBE / firmware / cluster health) before or alongside the next apply-updates run. **The healthy clusters are safe to proceed** - Step.7_apply-updates.yml is per-cluster scoped.")
    }
    else {
        [void]$md.Add('> **All clear**: every cluster in scope is ready for update. Safe to proceed with Step.7_apply-updates.yml for this ring.')
    }
    [void]$md.Add('')

    # 3. Summary counts
    [void]$md.Add('### Summary counts')
    [void]$md.Add('')
    [void]$md.Add('| Metric | Count |')
    [void]$md.Add('|--------|-------|')
    [void]$md.Add("| Total clusters in scope | $total |")
    [void]$md.Add("| Ready for update | $readyForUpdate |")
    [void]$md.Add("| Up to date | $upToDate |")
    [void]$md.Add("| Not ready for update | $notReady |")
    [void]$md.Add("| Clusters with Critical health failures | $clustersWithCritical |")
    [void]$md.Add("| Total Critical findings | $criticalFindings |")
    [void]$md.Add('')

    # 4. Not-Ready cluster table (blocking findings first)
    $notReadyRows = @($readiness | Where-Object { $_.ReadyForUpdate -ne $true })
    if ($notReadyRows.Count -gt 0) {
        [void]$md.Add('### Not-Ready clusters (review first)')
        [void]$md.Add('')
        [void]$md.Add('| Cluster | UpdateRing | Current version | Update state | Health | Blocking reasons |')
        [void]$md.Add('|---------|------------|-----------------|--------------|--------|------------------|')
        foreach ($r in ($notReadyRows | Sort-Object @{Expression={ if ($ringByResourceId.ContainsKey($_.ClusterResourceId)) { $ringByResourceId[$_.ClusterResourceId] } else { 'zzz' } }}, ClusterName)) {
            $ring = if ($ringByResourceId.ContainsKey($r.ClusterResourceId)) { $ringByResourceId[$r.ClusterResourceId] } else { '-' }
            $cv = if ($r.CurrentVersion) { $r.CurrentVersion } else { '-' }
            $br = if ($r.PSObject.Properties['BlockingReasons'] -and $r.BlockingReasons) { $r.BlockingReasons } else { '-' }
            [void]$md.Add("| $($r.ClusterName) | $ring | $cv | $($r.UpdateState) | $($r.HealthState) | $br |")
        }
        [void]$md.Add('')
    }

    # 5. Critical-health cluster table
    $criticalRows = @($health | Where-Object { [int]$_.CriticalCount -gt 0 })
    if ($criticalRows.Count -gt 0) {
        [void]$md.Add('### Critical-health clusters')
        [void]$md.Add('')
        [void]$md.Add('_Cross-link: see **Step.4_fleet-connectivity-status** for connectivity-class failures and **Step.10_fleet-health-status** for the broader Critical/Warning catalog._')
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
            $gReady = @($g.Group | Where-Object { $_.ReadyForUpdate -eq $true }).Count
            $gUpToDate = @($g.Group | Where-Object {
                    $_.ReadyForUpdate -ne $true -and
                    $_.UpdateState -in @('UpToDate', 'AppliedSuccessfully') -and
                    [string]::IsNullOrEmpty([string]$_.AllAvailableUpdates)
                }).Count
            $gNotReady = $g.Count - $gReady - $gUpToDate
            [void]$md.Add("| $($g.Name) | $($g.Count) | $gReady | $gUpToDate | $gNotReady |")
        }
        [void]$md.Add('')
    }

    # 7. All-clusters detail table
    if ($total -gt 0) {
        [void]$md.Add('### All clusters detail')
        [void]$md.Add('')
        [void]$md.Add('| Cluster | UpdateRing | Current version | Current SBE version | Update state | Health | Ready | Recommended update |')
        [void]$md.Add('|---------|------------|-----------------|---------------------|--------------|--------|-------|--------------------|')
        foreach ($r in ($readiness | Sort-Object @{Expression={ if ($ringByResourceId.ContainsKey($_.ClusterResourceId)) { $ringByResourceId[$_.ClusterResourceId] } else { 'zzz' } }}, ClusterName)) {
            $ring = if ($ringByResourceId.ContainsKey($r.ClusterResourceId)) { $ringByResourceId[$r.ClusterResourceId] } else { '-' }
            $cv  = if ($r.CurrentVersion) { $r.CurrentVersion } else { '-' }
            $csv = if ($r.PSObject.Properties['CurrentSbeVersion'] -and $r.CurrentSbeVersion) { $r.CurrentSbeVersion } else { '-' }
            $ru  = if ($r.RecommendedUpdate) { $r.RecommendedUpdate } else { '-' }
            [void]$md.Add("| $($r.ClusterName) | $ring | $cv | $csv | $($r.UpdateState) | $($r.HealthState) | $($r.ReadyForUpdate) | $ru |")
        }
        [void]$md.Add('')
    }

    # 8. Cross-links to other pipelines
    [void]$md.Add('### Cross-link to other pipelines')
    [void]$md.Add('')
    [void]$md.Add('- **Step.4_fleet-connectivity-status** - root-cause Disconnected / Offline / partial-connectivity findings on the Not-Ready and Critical-health rows above.')
    [void]$md.Add('- **Step.7_apply-updates** - apply updates to the Ready clusters in this ring (manual workflow_dispatch, or wait for the scheduled cron firing).')
    [void]$md.Add('- **Step.8_monitor-updates** - tail in-flight runs once Step.7 has started (auto-trigger on Step.7 completion, or manual).')
    [void]$md.Add('- **Step.10_fleet-health-status** - broader Critical / Warning health catalog across the whole fleet (not just blocking-only).')
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
            NotReadyCount        = [int]$notReady
            CriticalFindings     = [int]$criticalFindings
            ClustersWithCritical = [int]$clustersWithCritical
            ReadinessRows        = @($readiness)
            HealthRows           = @($health)
            ReadinessCsvPath     = $readinessCsv
            ReadinessXmlPath     = $readinessXml
            HealthCsvPath        = $healthCsv
            HealthXmlPath        = $healthXml
            CombinedXmlPath      = $combinedXml
        }
    }
}
