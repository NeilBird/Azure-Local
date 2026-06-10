function Export-AzLocalFleetHealthStatusReport {
    <#
    .SYNOPSIS
        Snapshots 24-hour fleet health-check failures and emits the full
        Step.9 artefact bundle (CSV + JSON + JUnit XML + markdown summary).

    .DESCRIPTION
        Public entry-point for the v0.8.5 thin-YAML refactor of the Step.9
        fleet-health-status pipeline. Before v0.8.5 the GitHub Actions and
        Azure DevOps Step.9_fleet-health-status.yml files each carried
        ~600 lines of inline PowerShell (failure collection + summary
        roll-up + overview collection + JUnit XML construction +
        collapsible markdown rendering + step-output emission). This
        cmdlet condenses that workload into a single Public PowerShell
        entry-point that both pipeline platforms call with a thin
        parameter splat.

        The cmdlet:
          1. Queries the fleet for unresolved Critical / Warning
             health-check failures via Get-AzLocalFleetHealthFailures
             (ARG-first; -View Detail). Detail rows feed the JUnit XML,
             the in-process Summary roll-up, and the per-cluster
             collapsible markdown view.
          2. Computes a SUMMARY view (Group-Object FailureReason +
             Severity) entirely in-process, so the cmdlet issues at
             most ONE health-failures ARG query regardless of fleet
             size. Severity sorts FIRST (Critical before Warning),
             then ClusterCount desc, then FailureCount desc.
          3. Queries Get-AzLocalFleetHealthOverview for the per-cluster
             rollup (HealthStatus / UpdateStatus / CurrentVersion /
             SbeVersion / AzureConnection / LastChecked / NodeCount).
          4. Writes the standard CSV+JSON artefact bundle: detail,
             summary and overview pairs under -OutputDirectory.
          5. Generates a JUnit XML document with two diagnostic
             testsuites ('[JUnit Debug] Critical Health Failures' /
             '[JUnit Debug] Warning Health Failures'). Each testcase
             carries <properties> consumed by the New-AzLocalIncident
             ITSM connector (ClusterResourceId / FailureReason / Severity /
             ClusterPortalUrl / TargetResourceName / TargetResourceType).
             FailureReason is fed into the UpdateName slot of the SHA256
             dedupe key so the ITSM connector raises one ticket per
             (cluster, failing check) pair.
          6. Renders a four-section markdown step summary: KPI table,
             Fleet Health Overview (top 100 clusters, one row each),
             Health Check Failures By Reason (top 25 reasons, with
             zipped portal-link hyperlinks for affected clusters), and
             a per-cluster collapsible <details> block showing every
             failing check (capped at 100 clusters; CSV artefact carries
             the full list).
          7. Emits 8 lowercase step outputs describing fleet bucket
             counts (total_clusters, total_failures, critical_count,
             warning_count, distinct_reasons, overview_rows,
             healthy_clusters, total_in_sub).

        The cmdlet replaces the inline 'Collect Fleet Health Failures'
        AND the downstream 'Create Fleet Health Summary' steps from the
        pre-v0.8.5 YAML.

    .PARAMETER OutputDirectory
        Directory to write artefacts into. When omitted, defaults to
        $env:BUILD_ARTIFACTSTAGINGDIRECTORY\reports on Azure DevOps
        hosts (resolved via Get-AzLocalPipelineHost) and './reports'
        everywhere else (GitHub Actions, local interactive use).

    .PARAMETER Scope
        Fleet selector: 'all' (every cluster the caller can read) or
        'by-update-ring' (clusters whose UpdateRing tag matches
        -UpdateRing). 'by-update-ring' is forwarded to
        Get-AzLocalFleetHealthFailures and Get-AzLocalFleetHealthOverview
        via the -UpdateRingTag parameter.

    .PARAMETER UpdateRing
        UpdateRing tag value to filter on when Scope='by-update-ring'.
        Accepts a single value, a ';'-delimited list, or '***' (three
        stars) as a wildcard. Ignored when Scope='all'.

    .PARAMETER Severity
        Severity filter applied at Resource Graph. 'All' (default) =
        Critical + Warning; 'Critical' or 'Warning' restricts to that
        tier only. Informational is always excluded.

    .PARAMETER MaxOverviewRows
        Maximum rows rendered in the Fleet Health Overview table.
        Default 100. Beyond this the markdown shows a
        '*Showing first N clusters of M; see csv artifact for the full
        list.*' truncation note. Does NOT cap the CSV / JSON outputs.

    .PARAMETER MaxSummaryRows
        Maximum rows rendered in the Health Check Failures By Reason
        table. Default 25. Same truncation behaviour as
        -MaxOverviewRows.

    .PARAMETER MaxDetailClusters
        Maximum collapsible <details> blocks rendered. Default 100.
        Cap is per-CLUSTER, not per-row, so no cluster's failures are
        silently truncated.

    .PARAMETER DetailCsvFileName
        Override the default 'fleet-health-detail.csv' filename.

    .PARAMETER DetailJsonFileName
        Override the default 'fleet-health-detail.json' filename.

    .PARAMETER SummaryCsvFileName
        Override the default 'fleet-health-summary.csv' filename.

    .PARAMETER SummaryJsonFileName
        Override the default 'fleet-health-summary.json' filename.

    .PARAMETER OverviewCsvFileName
        Override the default 'fleet-health-overview.csv' filename.

    .PARAMETER OverviewJsonFileName
        Override the default 'fleet-health-overview.json' filename.

    .PARAMETER XmlFileName
        Override the default 'fleet-health-status.xml' JUnit filename.

    .PARAMETER SummaryFileName
        Override the default 'fleet-health-status-summary.md' filename
        (the markdown rendered into GITHUB_STEP_SUMMARY / ADO
        upload-summary).

    .PARAMETER InstalledModuleVersion
        Optional version string rendered in the markdown footer
        (e.g. v0.8.5). When omitted, no footer line is appended.

    .PARAMETER Now
        Optional [datetime] used as 'snapshot time' in the markdown
        summary (Generated at ...). Defaults to (Get-Date).
        Parameterised so unit tests can assert against a fixed value.

    .PARAMETER PassThru
        Return a PSCustomObject describing the snapshot (counts + file
        paths + DetailRows + SummaryRows + OverviewRows). Default is
        no return value (the cmdlet only writes files + step outputs
        + markdown summary).

    .OUTPUTS
        [PSCustomObject] when -PassThru is supplied. Properties:
          - TotalClusters, TotalFailures, CriticalCount, WarningCount,
            DistinctReasons, OverviewRows, HealthyClusters, TotalInSub
          - DetailCsvPath, DetailJsonPath, SummaryCsvPath,
            SummaryJsonPath, OverviewCsvPath, OverviewJsonPath,
            XmlPath, SummaryPath
          - DetailRows, SummaryRows, OverviewRowsData

    .EXAMPLE
        Export-AzLocalFleetHealthStatusReport
        # All-cluster snapshot; writes the full artefact bundle to ./reports/.

    .EXAMPLE
        Export-AzLocalFleetHealthStatusReport -Scope by-update-ring -UpdateRing Prod -PassThru
        # Restricts to clusters tagged UpdateRing=Prod and returns the
        # snapshot object for downstream PowerShell use.

    .EXAMPLE
        # Used by Step.9_fleet-health-status.yml (GitHub Actions + Azure DevOps):
        Export-AzLocalFleetHealthStatusReport `
            -Scope $env:INPUT_SCOPE `
            -UpdateRing $env:INPUT_UPDATE_RING `
            -Severity $env:INPUT_SEVERITY `
            -InstalledModuleVersion (Get-Module AzLocal.UpdateManagement).Version

    .NOTES
        Author : Neil Bird, Microsoft
        Version: v0.8.5
        Added  : v0.8.5 (Step.9 thin-YAML port - condenses ~600 lines of inline
                 PowerShell into a single Public entry-point).
        Reuses : Get-AzLocalFleetHealthFailures, Get-AzLocalFleetHealthOverview,
                 New-AzLocalPipelineJUnitXml, Set-AzLocalPipelineOutput,
                 Add-AzLocalPipelineStepSummary, Get-AzLocalPipelineHost.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateSet('all', 'by-update-ring')]
        [string]$Scope = 'all',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$UpdateRing,

        [Parameter(Mandatory = $false)]
        [ValidateSet('All', 'Critical', 'Warning')]
        [string]$Severity = 'All',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1000)]
        [int]$MaxOverviewRows = 100,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 500)]
        [int]$MaxSummaryRows = 25,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1000)]
        [int]$MaxDetailClusters = 100,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$DetailCsvFileName = 'fleet-health-detail.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$DetailJsonFileName = 'fleet-health-detail.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryCsvFileName = 'fleet-health-summary.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryJsonFileName = 'fleet-health-summary.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$OverviewCsvFileName = 'fleet-health-overview.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$OverviewJsonFileName = 'fleet-health-overview.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlFileName = 'fleet-health-status.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'fleet-health-status-summary.md',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$InstalledModuleVersion,

        [Parameter(Mandatory = $false)]
        [datetime]$Now = (Get-Date),

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $pipelineHost = Get-AzLocalPipelineHost

    if (-not $OutputDirectory) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $OutputDirectory = Join-Path -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY -ChildPath 'reports'
        }
        else {
            $OutputDirectory = './reports'
        }
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $detailCsv    = Join-Path -Path $OutputDirectory -ChildPath $DetailCsvFileName
    $detailJson   = Join-Path -Path $OutputDirectory -ChildPath $DetailJsonFileName
    $summaryCsv   = Join-Path -Path $OutputDirectory -ChildPath $SummaryCsvFileName
    $summaryJson  = Join-Path -Path $OutputDirectory -ChildPath $SummaryJsonFileName
    $overviewCsv  = Join-Path -Path $OutputDirectory -ChildPath $OverviewCsvFileName
    $overviewJson = Join-Path -Path $OutputDirectory -ChildPath $OverviewJsonFileName
    $xmlPath      = Join-Path -Path $OutputDirectory -ChildPath $XmlFileName

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Fleet Health Status Collection" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Scope     : $Scope"
    Write-Host "Severity  : $Severity"
    if ($Scope -eq 'by-update-ring' -and $UpdateRing) { Write-Host "UpdateRing: $UpdateRing" }
    Write-Host ""

    # ---- Step 1: pull DETAIL view once ------------------------------------
    $argSplat = @{ Severity = $Severity }
    if ($Scope -eq 'by-update-ring' -and $UpdateRing) { $argSplat['UpdateRingTag'] = $UpdateRing }

    Write-Host "Step 1: Collecting fleet health failure rows (Detail view)..." -ForegroundColor Yellow
    # NOTE: Get-AzLocalFleetHealthFailures uses unary-comma return (`return , $output`).
    # Direct assignment only - never @() wrap, or the entire row set collapses to Object[1].
    $detail = Get-AzLocalFleetHealthFailures -View Detail @argSplat -ExportPath $detailCsv -PassThru
    if ($null -eq $detail) { $detail = @() }
    if (-not $detail) { $detail = @() }
    $detail | ConvertTo-Json -Depth 6 | Out-File -FilePath $detailJson -Encoding utf8
    Write-Host "Found $($detail.Count) failing health-check entry/entries." -ForegroundColor Green

    # ---- Step 2: in-process SUMMARY view ----------------------------------
    # AffectedClusters uses '; ' separator (matches cmdlet); adds positionally
    # paired AffectedClusterPortalUrls so the markdown renderer can zip them
    # into hyperlinks. Severity sorts FIRST (Critical before Warning).
    $summary = @()
    if ($detail.Count -gt 0) {
        $summary = @(
            $detail | Group-Object -Property FailureReason, Severity | ForEach-Object {
                $first       = $_.Group | Select-Object -First 1
                $clusterList = @($_.Group | Select-Object -ExpandProperty ClusterName -Unique | Sort-Object)
                $clusterPortalUrls = @(
                    foreach ($cn in $clusterList) {
                        $portalRow = $_.Group | Where-Object { $_.ClusterName -eq $cn } | Select-Object -First 1
                        if ($portalRow -and $portalRow.ClusterPortalUrl) { $portalRow.ClusterPortalUrl } else { '' }
                    }
                )
                $latestOcc = ($_.Group | Measure-Object -Property LastOccurrence -Maximum).Maximum
                [pscustomobject]@{
                    FailureReason             = $first.FailureReason
                    Severity                  = $first.Severity
                    ClusterCount              = $clusterList.Count
                    FailureCount              = $_.Group.Count
                    AffectedClusters          = ($clusterList -join '; ')
                    AffectedClusterPortalUrls = ($clusterPortalUrls -join '; ')
                    LatestOccurrence          = $latestOcc
                    Description               = $first.Description
                    Remediation               = $first.Remediation
                }
            } | Sort-Object @{Expression={ if ($_.Severity -eq 'Critical') { 1 } elseif ($_.Severity -eq 'Warning') { 2 } else { 3 } };Descending=$false},
                            @{Expression={$_.ClusterCount};Descending=$true},
                            @{Expression={$_.FailureCount};Descending=$true}
        )
    }
    $summary | Export-Csv -Path $summaryCsv -NoTypeInformation -Force
    $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $summaryJson -Encoding utf8

    # ---- Step 3: OVERVIEW (one row per cluster) ---------------------------
    Write-Host "Step 2: Collecting fleet health overview rows (one per cluster)..." -ForegroundColor Yellow
    $overviewArgs = @{}
    if ($Scope -eq 'by-update-ring' -and $UpdateRing) { $overviewArgs['UpdateRingTag'] = $UpdateRing }
    # NOTE: Get-AzLocalFleetHealthOverview uses unary-comma return (`return , $output`).
    # Direct assignment only - never @() wrap, or the entire row set collapses to Object[1].
    $overview = Get-AzLocalFleetHealthOverview @overviewArgs -ExportPath $overviewCsv -PassThru
    if ($null -eq $overview) { $overview = @() }
    if (-not $overview) { $overview = @() }
    $overview | ConvertTo-Json -Depth 6 | Out-File -FilePath $overviewJson -Encoding utf8
    Write-Host "Overview rows: $($overview.Count)." -ForegroundColor Green

    # ---- Step 4: bucket counts -------------------------------------------
    $criticalDetail = @($detail | Where-Object { $_.Severity -eq 'Critical' })
    $warningDetail  = @($detail | Where-Object { $_.Severity -eq 'Warning'  })
    $totalClusters  = @($detail | Select-Object -ExpandProperty ClusterName -Unique).Count
    $totalFailures  = [int]$detail.Count
    $criticalCount  = [int]$criticalDetail.Count
    $warningCount   = [int]$warningDetail.Count
    $distinctReasons = [int]$summary.Count
    $healthyClusters = [int](@($overview | Where-Object { $_.HealthStatus -eq 'Healthy' }).Count)
    $totalInSub      = [int](@($overview).Count)

    # ---- Step 5: JUnit XML via shared emitter ----------------------------
    Write-Host "Step 3: Generating JUnit XML report..." -ForegroundColor Yellow
    $suites = @()
    foreach ($severityLabel in @('Critical','Warning')) {
        $rows = if ($severityLabel -eq 'Critical') { $criticalDetail } else { $warningDetail }
        if (-not $rows -or $rows.Count -eq 0) { continue }
        $tcList = New-Object 'System.Collections.Generic.List[hashtable]'
        foreach ($r in $rows) {
            $clusterResId     = if ($r.PSObject.Properties.Match('ClusterResourceId').Count -gt 0) { [string]$r.ClusterResourceId } else { '' }
            $clusterPortalUrl = if ($r.PSObject.Properties.Match('ClusterPortalUrl').Count -gt 0)  { [string]$r.ClusterPortalUrl }  else { '' }
            $targetResName    = if ($r.PSObject.Properties.Match('TargetResourceName').Count -gt 0){ [string]$r.TargetResourceName }else { '' }
            $targetResType    = if ($r.PSObject.Properties.Match('TargetResourceType').Count -gt 0){ [string]$r.TargetResourceType }else { '' }
            $msg = "{0}: {1} (last occurred {2:yyyy-MM-ddTHH:mm:ssZ})" -f $r.Severity, $r.FailureReason, $r.LastOccurrence
            $bodyLines = @(
                [string]$r.Description
                [string]$r.Remediation
                "ResourceGroup: $($r.ResourceGroup)"
                "SubscriptionId: $($r.SubscriptionId)"
            )
            if ($targetResName) { $bodyLines += "TargetResourceName: $targetResName" }
            if ($targetResType) { $bodyLines += "TargetResourceType: $targetResType" }
            if ($clusterPortalUrl) { $bodyLines += "ClusterPortalUrl: $clusterPortalUrl" }
            $tc = @{
                Name       = "{0} :: {1}" -f $r.ClusterName, $r.FailureReason
                ClassName  = [string]$r.ClusterName
                Time       = 0.0
                Properties = ([ordered]@{
                    ClusterName        = [string]$r.ClusterName
                    ClusterResourceId  = $clusterResId
                    UpdateName         = [string]$r.FailureReason   # ITSM dedupe key slot
                    Status             = [string]$r.Severity
                    FailureReason      = [string]$r.FailureReason
                    Severity           = [string]$r.Severity
                    ClusterPortalUrl   = $clusterPortalUrl
                    TargetResourceName = $targetResName
                    TargetResourceType = $targetResType
                })
                Failure    = @{
                    Type    = [string]$r.Severity
                    Message = $msg
                    Body    = ($bodyLines -join "`n")
                }
            }
            $tcList.Add($tc) | Out-Null
        }
        $suites += ,@{
            Name      = "[JUnit Debug] $severityLabel Health Failures"
            ClassName = "FleetHealth.$severityLabel"
            TestCases = @($tcList)
        }
    }
    if ($totalFailures -eq 0) {
        $suites += ,@{
            Name      = 'Fleet Health'
            ClassName = 'FleetHealth'
            TestCases = @(@{
                Name      = 'No Critical or Warning health-check failures across the fleet'
                ClassName = 'FleetHealth'
                Time      = 0.0
            })
        }
    }
    $null = New-AzLocalPipelineJUnitXml -TestSuitesName 'AzureLocalFleetHealthStatus' -Suites $suites -OutputPath $xmlPath -Timestamp $Now
    Write-Host "JUnit XML saved to: $xmlPath" -ForegroundColor Green

    # ---- Step 6: step outputs --------------------------------------------
    Set-AzLocalPipelineOutput -Name 'total_clusters'    -Value ([string]$totalClusters)
    Set-AzLocalPipelineOutput -Name 'total_failures'    -Value ([string]$totalFailures)
    Set-AzLocalPipelineOutput -Name 'critical_count'    -Value ([string]$criticalCount)
    Set-AzLocalPipelineOutput -Name 'warning_count'     -Value ([string]$warningCount)
    Set-AzLocalPipelineOutput -Name 'distinct_reasons'  -Value ([string]$distinctReasons)
    Set-AzLocalPipelineOutput -Name 'overview_rows'     -Value ([string]$overview.Count)
    Set-AzLocalPipelineOutput -Name 'healthy_clusters'  -Value ([string]$healthyClusters)
    Set-AzLocalPipelineOutput -Name 'total_in_sub'      -Value ([string]$totalInSub)

    Write-Host ""
    Write-Host "Fleet Health Collection complete:"
    Write-Host "  Total clusters in scope : $totalInSub"
    Write-Host "  Healthy clusters        : $healthyClusters"
    Write-Host "  Unhealthy clusters      : $totalClusters"
    Write-Host "  Total failing checks    : $totalFailures (Critical=$criticalCount, Warning=$warningCount)"
    Write-Host "  Distinct failure reasons: $distinctReasons"
    Write-Host "  Overview rows           : $($overview.Count)"

    # ---- Step 7: markdown summary ----------------------------------------
    $generatedUtc = $Now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
    $md = New-Object 'System.Collections.Generic.List[string]'
    [void]$md.Add('## Fleet Health Status Summary')
    [void]$md.Add('')
    [void]$md.Add('| Metric | Count |')
    [void]$md.Add('|--------|-------|')
    [void]$md.Add("| **Total Clusters in Subscription** | $totalInSub |")
    [void]$md.Add("| **Healthy Clusters** | $healthyClusters |")
    [void]$md.Add("| **Unhealthy Clusters** | $totalClusters |")
    [void]$md.Add("| **Total Failing Checks** | $totalFailures |")
    [void]$md.Add("| **Critical** | $criticalCount |")
    [void]$md.Add("| **Warning** | $warningCount |")
    [void]$md.Add("| **Distinct Failure Reasons** | $distinctReasons |")
    [void]$md.Add('')
    [void]$md.Add('> _**Healthy** / **Unhealthy** count clusters via `Get-AzLocalFleetHealthOverview`; **Unhealthy** = at least one Critical or Warning health-check failure. **Total Failing Checks** counts individual failing checks (one cluster can contribute multiple)._')
    [void]$md.Add('')

    # ---- Fleet Health Overview table -------------------------------------
    [void]$md.Add('### Fleet Health Overview (fleet rollup)')
    [void]$md.Add('')
    if ($overview.Count -eq 0) {
        [void]$md.Add('*No clusters returned from Get-AzLocalFleetHealthOverview.*')
    }
    else {
        [void]$md.Add('| Cluster | Health | Update Status | Current Version | SBE Version | Azure Connection | Last Checked | Health Check Age (days) | Node Count |')
        [void]$md.Add('|---------|--------|---------------|------------------|--------------|------------------|---------------|--------------------------|------------|')
        foreach ($o in (@($overview) | Select-Object -First $MaxOverviewRows)) {
            # target="_blank" so clicking a portal link opens in a new tab
            # and the operator does not lose the pipeline run page.
            $clusterCell = if ($o.ClusterPortalUrl) {
                ('<a href="{0}" target="_blank" rel="noopener noreferrer">{1}</a>' -f $o.ClusterPortalUrl, $o.ClusterName)
            }
            else { [string]$o.ClusterName }
            # Use literal Unicode glyphs (not GH ':name:' shortcodes) so GH +
            # ADO render identically. Label is retained for greppability.
            $healthTag = switch ($o.HealthStatus) {
                'Healthy'             { "$([char]0x2705) Healthy" }
                'Critical'            { "$([char]0x274C) Critical" }
                'Warning'             { "$([char]0x26A0)$([char]0xFE0F) Warning" }
                'In progress'         { "$([char]0x23F3) In progress" }
                'Health check failed' { "$([char]0x274C) Failed" }
                default               { '[' + [string]$o.HealthStatus + ']' }
            }
            [void]$md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $clusterCell, $healthTag, $o.UpdateStatus, $o.CurrentVersion, $o.SbeVersion, $o.AzureConnection, $o.LastChecked, $o.HealthResultsAgeDays, $o.NodeCount))
        }
        if ($overview.Count -gt $MaxOverviewRows) {
            [void]$md.Add('')
            [void]$md.Add(('*Showing first {0} clusters of {1}; see `{2}` artifact for the full list.*' -f $MaxOverviewRows, $overview.Count, $OverviewCsvFileName))
        }
    }
    [void]$md.Add('')

    # ---- Health Check Failures By Reason ----------------------------------
    [void]$md.Add('### Health Check Failures By Reason (most widespread first)')
    [void]$md.Add('')
    if ($summary.Count -eq 0) {
        [void]$md.Add('*No Critical or Warning health-check failures across the fleet.*')
    }
    else {
        [void]$md.Add('| Severity | Failure Reason | Cluster Count | Failure Count | Affected Clusters | Latest |')
        [void]$md.Add('|----------|----------------|---------------|---------------|--------------------|--------|')
        foreach ($r in (@($summary) | Select-Object -First $MaxSummaryRows)) {
            $sevTag = if ($r.Severity -eq 'Critical') { '[Critical]' } else { '[Warning]' }
            # Keep @() OUTSIDE the 'if' so single-element splits do not unwrap
            # to a bare String (PowerShell scalar-unwrap guard).
            $names = @(if ($r.AffectedClusters)          { $r.AffectedClusters          -split '; ' } else { @() })
            $urls  = @(if ($r.AffectedClusterPortalUrls) { $r.AffectedClusterPortalUrls -split '; ' } else { @() })
            $linkedParts = for ($i = 0; $i -lt $names.Count; $i++) {
                $n = $names[$i]
                $u = if ($i -lt $urls.Count) { $urls[$i] } else { '' }
                if ($u) { ('<a href="{0}" target="_blank" rel="noopener noreferrer">{1}</a>' -f $u, $n) } else { $n }
            }
            $clList = if ($linkedParts.Count -le 10) {
                $linkedParts -join ', '
            }
            else {
                (($linkedParts | Select-Object -First 10) -join ', ') + (' ... (+{0} more)' -f ($linkedParts.Count - 10))
            }
            [void]$md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $sevTag, $r.FailureReason, $r.ClusterCount, $r.FailureCount, $clList, $r.LatestOccurrence))
        }
        if ($summary.Count -gt $MaxSummaryRows) {
            [void]$md.Add('')
            [void]$md.Add(('*Showing top {0} failure reasons of {1}; see `{2}` artifact for the full list.*' -f $MaxSummaryRows, $summary.Count, $SummaryCsvFileName))
        }
    }
    [void]$md.Add('')

    # ---- Detailed Results (collapsible per-cluster) -----------------------
    [void]$md.Add('### Detailed Results (per-cluster, per-failure)')
    [void]$md.Add('')
    if ($detail.Count -eq 0) {
        [void]$md.Add('*No detail rows.*')
    }
    else {
        [void]$md.Add('*Click a cluster to expand its failing health checks. Worst-affected clusters appear first.*')
        [void]$md.Add('')
        $detailByCluster = @(
            $detail | Group-Object -Property ClusterName | ForEach-Object {
                $rows      = @($_.Group)
                $crit      = @($rows | Where-Object { $_.Severity -eq 'Critical' }).Count
                $warn      = @($rows | Where-Object { $_.Severity -eq 'Warning'  }).Count
                $portalRow = $rows | Where-Object {
                    $_.PSObject.Properties.Match('ClusterPortalUrl').Count -gt 0 -and $_.ClusterPortalUrl
                } | Select-Object -First 1
                $lastOcc   = ($rows | Measure-Object -Property LastOccurrence -Maximum).Maximum
                [pscustomobject]@{
                    ClusterName      = $_.Name
                    ClusterPortalUrl = if ($portalRow) { [string]$portalRow.ClusterPortalUrl } else { '' }
                    CriticalCount    = $crit
                    WarningCount     = $warn
                    LastOccurrence   = $lastOcc
                    Rows             = @(
                        $rows | Sort-Object @{Expression={ if ($_.Severity -eq 'Critical') { 1 } else { 2 } };Descending=$false},
                                            @{Expression={$_.LastOccurrence};Descending=$true}
                    )
                }
            } | Sort-Object @{Expression={$_.CriticalCount};Descending=$true},
                            @{Expression={$_.WarningCount};Descending=$true},
                            @{Expression={$_.LastOccurrence};Descending=$true}
        )
        $totalDetailClusters = $detailByCluster.Count
        $clustersToShow      = @($detailByCluster | Select-Object -First $MaxDetailClusters)
        foreach ($cl in $clustersToShow) {
            $sevParts = @()
            if ($cl.CriticalCount -gt 0) { $sevParts += ('[Critical] x {0}' -f $cl.CriticalCount) }
            if ($cl.WarningCount  -gt 0) { $sevParts += ('[Warning] x {0}'  -f $cl.WarningCount)  }
            $sevTally = $sevParts -join ' &nbsp;&middot;&nbsp; '

            $clusterCell = if ($cl.ClusterPortalUrl) {
                ('<a href="{0}" target="_blank" rel="noopener noreferrer">{1}</a>' -f $cl.ClusterPortalUrl, $cl.ClusterName)
            }
            else { [string]$cl.ClusterName }
            $lastOccStr = if ($cl.LastOccurrence) { ('{0:yyyy-MM-ddTHH:mm:ssZ}' -f $cl.LastOccurrence) } else { '-' }

            [void]$md.Add('<details>')
            [void]$md.Add(('<summary><strong>{0}</strong> &nbsp;&middot;&nbsp; {1} &nbsp;&middot;&nbsp; last {2}</summary>' -f $clusterCell, $sevTally, $lastOccStr))
            [void]$md.Add('')
            [void]$md.Add('| Severity | Failure Reason | Failure Remediation | Target Resource Name | Target Resource Type | Last Occurrence | Resource Group |')
            [void]$md.Add('|----------|----------------|---------------------|----------------------|----------------------|------------------|----------------|')
            foreach ($r in $cl.Rows) {
                $sevTag = if ($r.Severity -eq 'Critical') { '[Critical]' } else { '[Warning]' }
                $rem    = if ($r.PSObject.Properties.Match('Remediation').Count -gt 0) { [string]$r.Remediation } else { '' }
                $remCell = if ($rem -and $rem.StartsWith('https://')) { ('<a href="{0}" target="_blank" rel="noopener noreferrer">link</a>' -f $rem) } else { $rem }
                $tName = if ($r.PSObject.Properties.Match('TargetResourceName').Count -gt 0) { [string]$r.TargetResourceName } else { '' }
                $tType = if ($r.PSObject.Properties.Match('TargetResourceType').Count -gt 0) { [string]$r.TargetResourceType } else { '' }
                [void]$md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $sevTag, $r.FailureReason, $remCell, $tName, $tType, $r.LastOccurrence, $r.ResourceGroup))
            }
            [void]$md.Add('</details>')
            [void]$md.Add('')
        }
        if ($totalDetailClusters -gt $MaxDetailClusters) {
            [void]$md.Add(('*Showing first {0} clusters of {1}; see `{2}` artifact for the full list.*' -f $MaxDetailClusters, $totalDetailClusters, $DetailCsvFileName))
            [void]$md.Add('')
        }
    }

    [void]$md.Add('### Reports Available')
    [void]$md.Add(('- `{0}` - one row per (cluster, failing health check)' -f $DetailCsvFileName))
    [void]$md.Add(('- `{0}` - one row per (FailureReason, Severity); ordered Critical-first, then by ClusterCount desc' -f $SummaryCsvFileName))
    [void]$md.Add(('- `{0}` - one row per cluster (ARG-first fleet health summary)' -f $OverviewCsvFileName))
    [void]$md.Add(('- `{0}` / `{1}` / `{2}` - same data, machine-readable' -f $DetailJsonFileName, $SummaryJsonFileName, $OverviewJsonFileName))
    [void]$md.Add(('- `{0}` - JUnit XML for CI/CD visualisation' -f $XmlFileName))
    [void]$md.Add('')
    [void]$md.Add('_Note: test sections prefixed **[JUnit Debug]** in the Tests view are a diagnostic mirror of the tables above (for CI tooling/ITSM integration). For primary readability, use this summary and the CSV artifacts._')
    [void]$md.Add('')
    [void]$md.Add("*Generated at $generatedUtc*")
    if ($InstalledModuleVersion) {
        [void]$md.Add('')
        [void]$md.Add(('_Generated by AzLocal.UpdateManagement v{0}._' -f $InstalledModuleVersion))
    }

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown ($md -join [Environment]::NewLine) -SummaryFileName $SummaryFileName

    if ($criticalCount -gt 0) {
        Write-Warning "$criticalCount Critical health-check failure(s) across the fleet. Check the detailed reports."
    }

    if ($PassThru) {
        return [pscustomobject]@{
            TotalClusters     = [int]$totalClusters
            TotalFailures     = [int]$totalFailures
            CriticalCount     = [int]$criticalCount
            WarningCount      = [int]$warningCount
            DistinctReasons   = [int]$distinctReasons
            OverviewRows      = [int]$overview.Count
            HealthyClusters   = [int]$healthyClusters
            TotalInSub        = [int]$totalInSub
            DetailCsvPath     = $detailCsv
            DetailJsonPath    = $detailJson
            SummaryCsvPath    = $summaryCsv
            SummaryJsonPath   = $summaryJson
            OverviewCsvPath   = $overviewCsv
            OverviewJsonPath  = $overviewJson
            XmlPath           = $xmlPath
            SummaryPath       = $summaryPath
            DetailRows        = $detail
            SummaryRows       = $summary
            OverviewRowsData  = $overview
        }
    }
}
