########################################
<#
.SYNOPSIS
    Builds the fleet connectivity status markdown summary consumed by Step.4
    pipelines (GitHub Actions and Azure DevOps).

.DESCRIPTION
    Renders the markdown step-summary that previously lived inline as a
    ~22 KB pwsh `run:` body in both the GitHub Actions and Azure DevOps
    Step.4 YAML templates. Extracting the renderer into a single module
    function gives the pipelines a single source of truth, makes the
    markdown layout unit-testable in Pester, and keeps the pipeline `run:`
    bodies far below the GitHub Actions 21,000-char expression-length
    cap (which the v0.7.85 'How to interpret + act on a non-zero
    reconciliation' subsection growth tripped at workflow parse time;
    v0.7.86 mitigated by moving step-output substitutions to env: vars,
    v0.7.87 ships this extraction as the durable fix).

    The function consumes the seven CSV reports produced by
    `Get-AzLocalFleetConnectivityStatus` (and emitted earlier in the
    Step.4 pipeline by the Collect step) plus an explicit hashtable of
    KPI counts (`-Counts`). It does NOT re-query Azure - it is a pure
    renderer over already-collected data and is therefore safe to call
    from any environment (no Azure CLI, no Resource Graph extension,
    no Az.* modules required).

    Two parameter sets:
      - FromCsvReports (default): reads the 6 CSVs from a folder. The
        7th report (the JUnit XML) is referenced by filename in the
        'Reports Available' list but is not consumed.
      - FromObjects: callers pass in already-loaded `[object[]]` arrays
        directly. Used by Pester unit tests and by callers that already
        hold the data in memory.

.PARAMETER ReportsPath
    Folder containing the 6 CSV reports written by
    `Get-AzLocalFleetConnectivityStatus`:
        fleet-cluster-connectivity.csv
        fleet-arc-status-summary.csv
        fleet-arc-non-connected-machines.csv
        fleet-physical-nics.csv
        fleet-physical-nic-stats.csv
        fleet-arb-status.csv
    Missing files are treated as empty (the renderer emits "No X
    returned" placeholders for each missing section).

.PARAMETER ClusterRows
    Rows from fleet-cluster-connectivity.csv as already-parsed objects
    (each row has ClusterName, ClusterId, ConnectivityStatus,
    ClusterStatus, NodeCount, ResourceGroup, Location). FromObjects set.

.PARAMETER ArcSummary
    Rows from fleet-arc-status-summary.csv (AgentStatus + Count). FromObjects set.

.PARAMETER ArcRows
    Rows from fleet-arc-non-connected-machines.csv (NodeName, MachineId,
    ClusterName, ClusterId, AgentStatus, OsSku, OsVersion, ClusterVersion,
    LastStatusChange, ResourceGroup, SubscriptionId). FromObjects set.

.PARAMETER NicRows
    Rows from fleet-physical-nics.csv (NodeName, NicName, NicStatus,
    DriverVersion, Ip4Address, InterfaceDescription, ClusterName).
    FromObjects set.

.PARAMETER NicStats
    Rows from fleet-physical-nic-stats.csv (NicType, NicStatus, Count).
    FromObjects set.

.PARAMETER ArbRows
    Rows from fleet-arb-status.csv (ArbName, ArbId, ArbStatus, ClusterId,
    ResourceGroup, DaysSinceLastModified). FromObjects set.

.PARAMETER Counts
    Hashtable of KPI counts computed earlier by the pipeline's Collect
    step. Required keys: ClusterTotal, ClusterFail, ArcTotal, ArcFail,
    NicTotal, NicFail, ArbTotal, ArbFail, TotalFailures, CriticalCount,
    WarningCount. All values are coerced via `[int]` so the caller may
    pass strings (env-var pipeline pattern) or integers freely.

.PARAMETER OutputPath
    Optional file path to write the markdown to. If omitted, the markdown
    is only returned to the pipeline.

.PARAMETER PassThru
    Returns the markdown content as a string regardless of -OutputPath.
    Without -OutputPath the markdown is returned by default; -PassThru
    is only meaningful WITH -OutputPath (write file AND return string).

.OUTPUTS
    System.String - the markdown summary, returned unless -OutputPath is
    used without -PassThru.

.EXAMPLE
    $counts = @{
        ClusterTotal   = [int]$env:CLUSTER_TOTAL
        ClusterFail    = [int]$env:CLUSTER_FAIL
        ArcTotal       = [int]$env:ARC_TOTAL
        ArcFail        = [int]$env:ARC_FAIL
        NicTotal       = [int]$env:NIC_TOTAL
        NicFail        = [int]$env:NIC_FAIL
        ArbTotal       = [int]$env:ARB_TOTAL
        ArbFail        = [int]$env:ARB_FAIL
        TotalFailures  = [int]$env:TOTAL_FAILURES
        CriticalCount  = [int]$env:CRITICAL_COUNT
        WarningCount   = [int]$env:WARNING_COUNT
    }
    $md = New-AzLocalFleetConnectivityStatusSummary -ReportsPath './reports' -Counts $counts
    $md | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append

    GitHub Actions Step.4: reads the CSVs the Collect step wrote, builds
    the markdown, and appends it to the run summary view.

.EXAMPLE
    $mdPath = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'fleet-connectivity-summary.md'
    New-AzLocalFleetConnectivityStatusSummary -ReportsPath '$(reportsPath)' -Counts $counts -OutputPath $mdPath | Out-Null
    Write-Host "##vso[task.uploadsummary]$mdPath"

    Azure DevOps Step.4: writes the markdown to a file and tells ADO to
    upload it as the run extension summary.

.EXAMPLE
    $clusters = Import-Csv -Path .\fleet-cluster-connectivity.csv
    $arc      = Import-Csv -Path .\fleet-arc-status-summary.csv
    # ...
    New-AzLocalFleetConnectivityStatusSummary `
        -ClusterRows $clusters -ArcSummary $arc -ArcRows @() -NicRows @() -NicStats @() -ArbRows @() `
        -Counts @{ ClusterTotal=$clusters.Count; ClusterFail=0; ArcTotal=0; ArcFail=0; NicTotal=0; NicFail=0; ArbTotal=0; ArbFail=0; TotalFailures=0; CriticalCount=0; WarningCount=0 }

    Unit-test use: pass already-loaded objects directly (FromObjects set).

.NOTES
    Author: Neil Bird
    Version: 0.7.87 (introduced)
    Created: 2026-05-22

    The renderer body is deliberately a single function rather than a
    chain of smaller per-section helpers. Per-section helpers would
    re-incur the cap risk if any one of them ever grew large again;
    keeping the rendering in one function with explicit string-builder
    chunks lets the Pester regression guard (which measures the rendered
    string length) catch unbounded growth at test time, not in production.
#>
########################################
function New-AzLocalFleetConnectivityStatusSummary {
    [CmdletBinding(DefaultParameterSetName = 'FromCsvReports')]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'FromCsvReports')]
        [ValidateNotNullOrEmpty()]
        [string]$ReportsPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'FromObjects')]
        [AllowEmptyCollection()]
        [object[]]$ClusterRows,

        [Parameter(Mandatory = $true, ParameterSetName = 'FromObjects')]
        [AllowEmptyCollection()]
        [object[]]$ArcSummary,

        [Parameter(Mandatory = $true, ParameterSetName = 'FromObjects')]
        [AllowEmptyCollection()]
        [object[]]$ArcRows,

        [Parameter(Mandatory = $true, ParameterSetName = 'FromObjects')]
        [AllowEmptyCollection()]
        [object[]]$NicRows,

        [Parameter(Mandatory = $true, ParameterSetName = 'FromObjects')]
        [AllowEmptyCollection()]
        [object[]]$NicStats,

        [Parameter(Mandatory = $true, ParameterSetName = 'FromObjects')]
        [AllowEmptyCollection()]
        [object[]]$ArbRows,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Counts,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # ------------------------------------------------------------------
    # 1. Validate -Counts keys (KPI numbers come from the upstream
    #    Collect step and must all be present even if zero).
    # ------------------------------------------------------------------
    $requiredKeys = @(
        'ClusterTotal', 'ClusterFail',
        'ArcTotal',     'ArcFail',
        'NicTotal',     'NicFail',
        'ArbTotal',     'ArbFail',
        'TotalFailures', 'CriticalCount', 'WarningCount'
    )
    $missingKeys = @($requiredKeys | Where-Object { -not $Counts.ContainsKey($_) })
    if ($missingKeys.Count -gt 0) {
        throw "Counts hashtable is missing required key(s): $($missingKeys -join ', '). Required keys: $($requiredKeys -join ', ')."
    }

    # Coerce every count via [int] - the pipeline pattern passes env-var
    # strings (`$env:CLUSTER_TOTAL` etc.) and callers should not have to
    # cast every value themselves.
    $clusterTotal = [int]$Counts['ClusterTotal']
    $clusterFail  = [int]$Counts['ClusterFail']
    $arcTotal     = [int]$Counts['ArcTotal']
    $arcFail      = [int]$Counts['ArcFail']
    $nicTotal     = [int]$Counts['NicTotal']
    $nicFail      = [int]$Counts['NicFail']
    $arbTotal     = [int]$Counts['ArbTotal']
    $arbFail      = [int]$Counts['ArbFail']
    $totalFail    = [int]$Counts['TotalFailures']
    $crit         = [int]$Counts['CriticalCount']
    $warn         = [int]$Counts['WarningCount']

    # ------------------------------------------------------------------
    # 2. Load row data: from CSVs (default) or from explicit objects
    #    (FromObjects parameter set used by Pester tests).
    # ------------------------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'FromCsvReports') {
        $clusterCsv = Join-Path -Path $ReportsPath -ChildPath 'fleet-cluster-connectivity.csv'
        $arcSumCsv  = Join-Path -Path $ReportsPath -ChildPath 'fleet-arc-status-summary.csv'
        $arcCsv     = Join-Path -Path $ReportsPath -ChildPath 'fleet-arc-non-connected-machines.csv'
        $nicCsv     = Join-Path -Path $ReportsPath -ChildPath 'fleet-physical-nics.csv'
        $nicStatCsv = Join-Path -Path $ReportsPath -ChildPath 'fleet-physical-nic-stats.csv'
        $arbCsv     = Join-Path -Path $ReportsPath -ChildPath 'fleet-arb-status.csv'

        if (Test-Path -LiteralPath $clusterCsv) { $ClusterRows = @(Import-Csv -Path $clusterCsv) } else { $ClusterRows = @() }
        if (Test-Path -LiteralPath $arcSumCsv)  { $ArcSummary  = @(Import-Csv -Path $arcSumCsv)  } else { $ArcSummary  = @() }
        if (Test-Path -LiteralPath $arcCsv)     { $ArcRows     = @(Import-Csv -Path $arcCsv)     } else { $ArcRows     = @() }
        if (Test-Path -LiteralPath $nicCsv)     { $NicRows     = @(Import-Csv -Path $nicCsv)     } else { $NicRows     = @() }
        if (Test-Path -LiteralPath $nicStatCsv) { $NicStats    = @(Import-Csv -Path $nicStatCsv) } else { $NicStats    = @() }
        if (Test-Path -LiteralPath $arbCsv)     { $ArbRows     = @(Import-Csv -Path $arbCsv)     } else { $ArbRows     = @() }
    }

    # ------------------------------------------------------------------
    # 3. Severity classifiers + emoji icons. Emoji are emitted as literal
    #    Unicode via `[char]` so the source file stays ASCII-only.
    # ------------------------------------------------------------------
    $okIcon   = [string][char]0x2705                                   # white heavy check mark
    $critIcon = [string][char]0x274C                                   # cross mark
    $warnIcon = [string][char]0x26A0 + [string][char]0xFE0F            # warning sign + VS16

    function Get-StatusIcon {
        param([string]$Severity)
        switch ($Severity) {
            'Pass'     { return $okIcon }
            'Critical' { return $critIcon }
            'Warning'  { return $warnIcon }
            default    { return $warnIcon }
        }
    }
    function Get-ClusterSev { param([string]$s) switch -Regex ($s) { '^(Connected|ConnectedRecently)$' { 'Pass'; break } '^(Disconnected|Expired|Offline|Error)$' { 'Critical'; break } default { 'Warning' } } }
    function Get-ArcSev     { param([string]$s) switch -Regex ($s) { '^(Connected)$'                   { 'Pass'; break } '^(Disconnected|Expired|Offline|Error)$' { 'Critical'; break } default { 'Warning' } } }
    function Get-NicSev     { param([string]$s) switch -Regex ($s) { '^(Connected|Up)$'                { 'Pass'; break } '^(Disconnected|Down|Disabled)$'         { 'Critical'; break } default { 'Warning' } } }
    function Get-ArbSev     { param([string]$s) switch -Regex ($s) { '^(Running)$'                     { 'Pass'; break } '^(Offline|Failed)$'                    { 'Critical'; break } default { 'Warning' } } }

    # ------------------------------------------------------------------
    # 4. Build ClusterId <-> ARB lookup. The ARB ClusterId field can be
    #    comma-separated when one RG hosts multiple HCI clusters (multi-
    #    cluster-per-RG case from the summarize/make_set ARB query).
    #
    #    v0.7.83 lesson: [string[]] cast prevents single-cluster ClusterId
    #    from collapsing to a bare [string] (which would then iterate as
    #    a scalar in foreach - currently safe with the @() wrap pattern
    #    below, but the explicit cast is defensive).
    # ------------------------------------------------------------------
    $arbByClusterId = @{}
    foreach ($a in $ArbRows) {
        [string[]]$arbClusterIds = if ($a.ClusterId) { ($a.ClusterId -split ',\s*') | Where-Object { $_ } } else { @() }
        foreach ($id in $arbClusterIds) {
            $key = $id.Trim().ToLowerInvariant()
            if ($key -and -not $arbByClusterId.ContainsKey($key)) { $arbByClusterId[$key] = $a }
        }
    }
    $clusterIdsLower = @{}
    foreach ($c in $ClusterRows) {
        if ($c.ClusterId) { $clusterIdsLower[$c.ClusterId.ToLowerInvariant()] = $true }
    }
    $orphanArbs = @($ArbRows | Where-Object {
        [string[]]$candidateIds = if ($_.ClusterId) { ($_.ClusterId -split ',\s*') | Where-Object { $_ } } else { @() }
        $matched = $false
        foreach ($id in $candidateIds) { if ($clusterIdsLower.ContainsKey($id.Trim().ToLowerInvariant())) { $matched = $true; break } }
        -not $matched
    })

    # Reconciliation counts.
    $clusterNodeSum = 0
    foreach ($row in $ClusterRows) {
        if ($row -and $row.PSObject.Properties['NodeCount']) {
            $n = $row.NodeCount
            if ($n -is [int] -or $n -is [long] -or $n -is [double]) { $clusterNodeSum += [int]$n }
            elseif ($n -is [string] -and $n.Length -gt 0) { $tmp = 0; if ([int]::TryParse($n, [ref]$tmp)) { $clusterNodeSum += $tmp } }
        }
    }
    $clustersWithArb    = @($ClusterRows | Where-Object { $_.ClusterId -and $arbByClusterId.ContainsKey($_.ClusterId.ToLowerInvariant()) }).Count
    $clustersWithoutArb = [math]::Max(0, $ClusterRows.Count - $clustersWithArb)
    $nodeCoverageDelta  = [int]$clusterNodeSum - [int]$arcTotal

    # ------------------------------------------------------------------
    # 5. Build the markdown. The here-string is at column 0 in the source
    #    so the rendered markdown has no spurious leading whitespace
    #    (avoids the 4+ space markdown-code-block trap).
    # ------------------------------------------------------------------
    $sb = [System.Text.StringBuilder]::new()

    # 5a. KPI summary table
    [void]$sb.AppendLine('## Fleet Connectivity Status Summary')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Scope | Total | Failing | Healthy |')
    [void]$sb.AppendLine('|-------|-------|---------|---------|')
    [void]$sb.AppendLine("| **Clusters** | $clusterTotal | $clusterFail | $([math]::Max(0, $clusterTotal - $clusterFail)) |")
    [void]$sb.AppendLine("| **Arc Agents (per machine)** | $arcTotal | $arcFail | $([math]::Max(0, $arcTotal - $arcFail)) |")
    [void]$sb.AppendLine("| **Physical NICs (issues only)** | - | $nicFail | - |")
    [void]$sb.AppendLine("| **Azure Resource Bridges** | $arbTotal | $arbFail | $([math]::Max(0, $arbTotal - $arbFail)) |")
    [void]$sb.AppendLine("| **TOTAL FAILURES** | - | **$totalFail** | (Critical=$crit, Warning=$warn) |")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('> _**Physical NICs** is filtered at the query layer to actionable issues only: NicStatus=Disconnected with a non-APIPA IPv4 address. ''Up'' adapters and adapters without a real IP are intentionally NOT reported (noise reduction)._')
    [void]$sb.AppendLine('')

    # 5b. Reconciliation table
    [void]$sb.AppendLine('### Node + ARB Coverage Reconciliation')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_Cross-scope consistency check. The Cluster-reported count and the Arc-tagged count come from **independent** KQL queries (``microsoft.azurestackhci/clusters.reportedProperties.nodes`` vs ``microsoft.hybridcompute/machines`` with ``provider=AzSHCI``). They can legitimately disagree in **EITHER** direction. Read the delta sign first, then jump to the ''How to interpret + act'' subsection below the table for the matching remediation step._')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Source | Count | Notes |')
    [void]$sb.AppendLine('|--------|-------|-------|')
    [void]$sb.AppendLine("| Clusters in scope | $clusterTotal | One row per ``microsoft.azurestackhci/clusters`` resource |")
    [void]$sb.AppendLine("| Cluster-reported node count (sum) | $clusterNodeSum | Sum of ``array_length(properties.reportedProperties.nodes)`` across all clusters |")
    [void]$sb.AppendLine("| Arc-tagged physical nodes | $arcTotal | Count of ``microsoft.hybridcompute/machines`` with ``properties.detectedProperties.cloudprovider=AzSHCI`` and ``kind!=HCI``. **NOT** a join against ``cluster.reportedProperties.nodes`` - it is the raw Arc-side count and can be greater OR less than the Cluster-reported sum |")
    [void]$sb.AppendLine("| Node coverage delta | $nodeCoverageDelta | (Cluster-reported) - (Arc-tagged). **Positive** = clusters claim more nodes than Arc has (Arc-onboarding lag / deleted Arc resource / missing ``AzSHCI`` provider tag / stale ``cluster.reportedProperties.nodes`` array). **Negative** = Arc has more ``AzSHCI``-tagged machines than clusters claim (orphan/decommissioned Arc resource / pre-staged node not yet joined / mis-tagged non-cluster machine). See 'How to interpret + act' below |")
    [void]$sb.AppendLine("| ARBs in scope | $arbTotal | One row per ``resourceconnector/appliances`` (multi-cluster-per-RG collapsed via summarize/make_set) |")
    [void]$sb.AppendLine("| Clusters with an ARB | $clustersWithArb | Clusters matched to an ARB by ClusterId |")
    [void]$sb.AppendLine("| Clusters without an ARB | $clustersWithoutArb | Clusters that show ``_(no ARB)_`` in the per-cluster table below |")
    [void]$sb.AppendLine("| Orphan ARBs | $($orphanArbs.Count) | ARBs whose RG contains no in-scope HCI cluster (listed in the 'Non-Azure Local and/or Orphan ARB appliances' section below when > 0; may include VMware/SCVMM resource bridges) |")
    [void]$sb.AppendLine('')

    # 5c. "How to interpret + act" static prose
    [void]$sb.AppendLine('### How to interpret + act on a non-zero reconciliation')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Each non-zero row above points to drift between two control planes (Azure Local cluster state vs Arc/ARB state). Read the direction first, then take the matching remediation step. Goal is parity: delta = 0, no orphan ARBs, every cluster has exactly one ARB.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**``Node coverage delta`` is POSITIVE** _(cluster-reported > Arc-tagged: clusters claim more nodes than Arc has)_')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **Arc-onboarding lag** - new node added on-prem, Arc agent still bootstrapping. Usually resolves within an hour; re-run this pipeline to confirm.')
    [void]$sb.AppendLine('- **Arc resource deleted** - the ``microsoft.hybridcompute/machines`` record was removed but the cluster still lists the node. Re-onboard the Arc agent on the affected node (``azcmagent connect``).')
    [void]$sb.AppendLine('- **Missing ``AzSHCI`` provider tag** - the Arc machine exists but does not carry ``properties.detectedProperties.cloudprovider=AzSHCI``. Run the AzSHCI onboarding extension to re-stamp the provider tag.')
    [void]$sb.AppendLine('- **Stale ``cluster.reportedProperties.nodes``** - the cluster service has not refreshed after a node-remove. Compare the array against ``Get-ClusterNode`` on the cluster.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**``Node coverage delta`` is NEGATIVE** _(Arc-tagged > cluster-reported: Arc sees AzSHCI machines that no in-scope cluster claims)_')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **Orphan / decommissioned Arc resource** - node removed from the cluster but its Arc record was never deleted. Delete the orphan Arc resource (or re-attach the node if removal was unintentional).')
    [void]$sb.AppendLine('- **Pre-staged node** - Arc agent installed on hardware being prepared to join a cluster but not yet added to ``nodes[]``. Track against your build sheet; no action until commissioning completes.')
    [void]$sb.AppendLine('- **Mis-tagged Arc machine** - non-cluster machine accidentally tagged ``provider=AzSHCI``. Clear the provider tag or remove the machine from AzSHCI scope.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('To find the specific Arc machines causing a negative delta, run this Resource Graph query (replace the placeholder with your in-scope cluster IDs):')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('``````kusto')
    [void]$sb.AppendLine('resources')
    [void]$sb.AppendLine("| where type =~ 'microsoft.hybridcompute/machines'")
    [void]$sb.AppendLine("| where tolower(tostring(properties.detectedProperties.cloudprovider)) == 'azshci'")
    [void]$sb.AppendLine("| where tolower(tostring(kind)) != 'hci'")
    [void]$sb.AppendLine('| extend parentClusterId = tolower(tostring(properties.parentClusterResourceId))')
    [void]$sb.AppendLine('| where isempty(parentClusterId) or not(parentClusterId in~ (/* in-scope cluster IDs, lowercased */))')
    [void]$sb.AppendLine('| project name, parentClusterId, status = properties.status, lastStatusChange = properties.lastStatusChange')
    [void]$sb.AppendLine('``````')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**``Clusters without an ARB`` > 0** _(every cluster should have exactly one ``microsoft.resourceconnector/appliances``)_')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Look for the cluster rows showing ``_(no ARB)_`` in the per-cluster table below. Causes:')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **ARB never deployed** - run the AzSHCI extension installer to create the ARB.')
    [void]$sb.AppendLine('- **ARB deleted but cluster still present** - re-create the ARB via the cluster''s ''Connect'' experience in the portal.')
    [void]$sb.AppendLine('- **ARB resource provider not registered** on the subscription: ``az provider register --namespace Microsoft.ResourceConnector`` and re-run.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('An ARB that exists but is ``Offline`` / ``Failed`` still counts toward ''Clusters with an ARB'' - check the ARB Status column in the per-cluster table and the ''Azure Resource Bridges'' table further down for remediation.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**``Orphan ARBs`` > 0** _(ARBs whose RG contains no in-scope HCI cluster)_')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Inspect the ''Non-Azure Local and/or Orphan ARB appliances'' section below for the full resource IDs. Causes:')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- **ARB serves a different platform** - Azure Arc resource bridge is also used by VMware vSphere and SCVMM; the appliance may be a healthy bridge for a non-Azure Local deployment, not an orphan. Confirm the platform before acting.')
    [void]$sb.AppendLine('- **Cluster deleted but its ARB was not cleaned up** - delete the orphan ARB.')
    [void]$sb.AppendLine('- **ARB in a different sub/RG from the cluster it serves** - scope-list drift; correct the input parameter list to include the matching cluster.')
    [void]$sb.AppendLine('- **ARB created for a cluster excluded from this run** (e.g. environment filter) - verify the filter; no action if expected.')
    [void]$sb.AppendLine('')

    # 5d. Cluster Connectivity (with ARB Status) per-cluster table
    [void]$sb.AppendLine('### Cluster Connectivity (with ARB Status)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_One row per cluster, left-joined to the cluster''s Azure Resource Bridge (ARB) appliance status. Each cluster has at most one ARB. ARBs without a matching cluster in scope are listed separately under ''Non-Azure Local and/or Orphan ARB appliances''._')
    [void]$sb.AppendLine('')
    if ($ClusterRows.Count -eq 0) {
        [void]$sb.AppendLine('*No clusters returned.*')
    }
    else {
        [void]$sb.AppendLine('| Cluster | Connectivity | Cluster Status | Nodes | ARB | ARB Status | ARB Days Since LastModified | Resource Group | Location |')
        [void]$sb.AppendLine('|---------|---------------|-----------------|-------|-----|-------------|------------------------------|----------------|----------|')
        foreach ($r in ($ClusterRows | Select-Object -First 100)) {
            $sev          = Get-ClusterSev $r.ConnectivityStatus
            $icon         = Get-StatusIcon $sev
            $clusterCell  = if ($r.ClusterId) { '[{0}](https://portal.azure.com/#@/resource{1})' -f $r.ClusterName, $r.ClusterId } else { $r.ClusterName }

            $arb = $null
            if ($r.ClusterId) { $arb = $arbByClusterId[$r.ClusterId.ToLowerInvariant()] }

            if ($arb) {
                $arbSev        = Get-ArbSev $arb.ArbStatus
                $arbIcon       = Get-StatusIcon $arbSev
                $arbCell       = if ($arb.ArbId) { '[{0}](https://portal.azure.com/#@/resource{1})' -f $arb.ArbName, $arb.ArbId } else { $arb.ArbName }
                $arbStatusCell = '{0} {1}' -f $arbIcon, $arb.ArbStatus
                $arbDaysCell   = $arb.DaysSinceLastModified
            }
            else {
                $arbCell       = '_(no ARB)_'
                $arbStatusCell = '-'
                $arbDaysCell   = '-'
            }

            [void]$sb.AppendLine(('| {0} | {1} {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |' -f $clusterCell, $icon, $r.ConnectivityStatus, $r.ClusterStatus, $r.NodeCount, $arbCell, $arbStatusCell, $arbDaysCell, $r.ResourceGroup, $r.Location))
        }
        if ($ClusterRows.Count -gt 100) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("*Showing first 100 of $($ClusterRows.Count); see ``fleet-cluster-connectivity.csv`` and ``fleet-arb-status.csv`` for the full lists.*")
        }
    }

    # 5e. Orphan ARBs table (conditional)
    if ($orphanArbs.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('### Non-Azure Local and/or Orphan ARB appliances')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('These ARB appliances do not have a matching Azure Local instance (cluster) in scope.')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('_ARB appliances whose resource group does not contain any HCI cluster visible to this run. This does **not** by itself mean the appliance is stale or orphaned: Azure Arc resource bridge is also used by **VMware vSphere** and **System Center Virtual Machine Manager (SCVMM)** Arc-enabled deployments, so an appliance listed here may be a healthy, in-use resource bridge for a non-Azure Local platform. Other causes include a stale appliance left behind after a cluster was deleted, or a cluster that is outside the configured scope of this run. **Fully investigate each appliance - check its resource type, associated custom location, and the platform it serves - before taking any action; do not delete an ARB until you have confirmed it is genuinely orphaned.**_')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('| ARB | Status | Resource Group | Days Since LastModified |')
        [void]$sb.AppendLine('|-----|--------|----------------|--------------------------|')
        foreach ($a in ($orphanArbs | Select-Object -First 50)) {
            $arbSev  = Get-ArbSev $a.ArbStatus
            $arbIcon = Get-StatusIcon $arbSev
            $arbCell = if ($a.ArbId) { '[{0}](https://portal.azure.com/#@/resource{1})' -f $a.ArbName, $a.ArbId } else { $a.ArbName }
            [void]$sb.AppendLine(('| {0} | {1} {2} | {3} | {4} |' -f $arbCell, $arbIcon, $a.ArbStatus, $a.ResourceGroup, $a.DaysSinceLastModified))
        }
    }

    # 5f. Arc Agent Connection Status Summary
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Arc Agent Connection Status Summary')
    [void]$sb.AppendLine('')
    if ($ArcSummary.Count -eq 0) {
        [void]$sb.AppendLine('*No Arc-enabled machines returned for the selected scope.*')
    }
    else {
        [void]$sb.AppendLine('| Status | Machine Count | Severity |')
        [void]$sb.AppendLine('|--------|----------------|----------|')
        foreach ($r in ($ArcSummary | Sort-Object @{Expression = { [int]$_.Count }; Descending = $true })) {
            $sev  = Get-ArcSev $r.AgentStatus
            $icon = Get-StatusIcon $sev
            [void]$sb.AppendLine(('| {0} | {1} | {2} {3} |' -f $r.AgentStatus, $r.Count, $icon, $sev))
        }
    }

    # 5g. Non-Connected Machines table
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Non-Connected Machines')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_Physical machines whose Arc agent status is NOT ''Connected'' (Disconnected, Expired, Error, Unknown, etc.). Columns mirror the cluster-management dashboard''s ''Non-Connected Machines'' view._')
    [void]$sb.AppendLine('')
    if ($ArcRows.Count -eq 0) {
        [void]$sb.AppendLine('*All machines are Connected.*')
    }
    else {
        $arcSorted = $ArcRows | Sort-Object LastStatusChange, ClusterName, NodeName
        [void]$sb.AppendLine('| Machine Name | Cluster Name | Status | OS SKU | OS Version | Cluster Version | Disconnected Since | Resource Group | Subscription |')
        [void]$sb.AppendLine('|--------------|--------------|--------|--------|------------|------------------|---------------------|----------------|--------------|')
        foreach ($r in ($arcSorted | Select-Object -First 100)) {
            $sev         = Get-ArcSev $r.AgentStatus
            $icon        = Get-StatusIcon $sev
            $nodeCell    = if ($r.MachineId) { '[{0}](https://portal.azure.com/#@/resource{1})' -f $r.NodeName, $r.MachineId } else { $r.NodeName }
            $clusterCell = if ($r.ClusterId) { '[{0}](https://portal.azure.com/#@/resource{1})' -f $r.ClusterName, $r.ClusterId } else { $r.ClusterName }
            [void]$sb.AppendLine(('| {0} | {1} | {2} {3} | {4} | {5} | {6} | {7} | {8} | {9} |' -f $nodeCell, $clusterCell, $icon, $r.AgentStatus, $r.OsSku, $r.OsVersion, $r.ClusterVersion, $r.LastStatusChange, $r.ResourceGroup, $r.SubscriptionId))
        }
        if ($ArcRows.Count -gt 100) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("*Showing first 100 of $($ArcRows.Count); see ``fleet-arc-non-connected-machines.csv`` for the full list.*")
        }
    }

    # 5h. Physical NIC Statistics (histogram)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Physical NIC Statistics (full inventory)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_One row per (NicType, NicStatus) pair across every NIC reported by every Azure Local edge device in scope. Use this to spot fleet-wide patterns (e.g. many Physical NICs in ''Disconnected'' state across multiple clusters)._')
    [void]$sb.AppendLine('')
    if ($NicStats.Count -eq 0) {
        [void]$sb.AppendLine('*No NIC data returned for the selected scope.*')
    }
    else {
        [void]$sb.AppendLine('| NIC Type | NIC Status | Count | Severity |')
        [void]$sb.AppendLine('|----------|------------|-------|----------|')
        foreach ($r in ($NicStats | Sort-Object NicType, @{Expression = { [int]$_.Count }; Descending = $true })) {
            $sev  = Get-NicSev $r.NicStatus
            $icon = Get-StatusIcon $sev
            [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} {4} |' -f $r.NicType, $r.NicStatus, $r.Count, $icon, $sev))
        }
    }

    # 5i. Physical NIC Issues (Disconnected, non-APIPA IP)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Physical NIC Issues (Disconnected, non-APIPA IP)')
    [void]$sb.AppendLine('')
    if ($NicRows.Count -eq 0) {
        [void]$sb.AppendLine('*No physical NIC issues. All physical adapters either Up, or Disconnected without a real IP (filtered as noise).*')
    }
    else {
        $nicSorted = $NicRows | Sort-Object ClusterName, NodeName, NicName
        [void]$sb.AppendLine('| Node | NIC | Status | Driver | IP | Interface | Cluster |')
        [void]$sb.AppendLine('|------|-----|--------|--------|-----|-----------|---------|')
        foreach ($r in ($nicSorted | Select-Object -First 100)) {
            $sev  = Get-NicSev $r.NicStatus
            $icon = Get-StatusIcon $sev
            [void]$sb.AppendLine(('| {0} | {1} | {2} {3} | {4} | {5} | {6} | {7} |' -f $r.NodeName, $r.NicName, $icon, $r.NicStatus, $r.DriverVersion, $r.Ip4Address, $r.InterfaceDescription, $r.ClusterName))
        }
        if ($NicRows.Count -gt 100) {
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine("*Showing first 100 of $($NicRows.Count); see ``fleet-physical-nics.csv`` for the full list.*")
        }
    }

    # 5j. Reports Available list
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('### Reports Available')
    [void]$sb.AppendLine('- ``fleet-cluster-connectivity.csv`` - one row per cluster (connectivityStatus + cluster.status)')
    [void]$sb.AppendLine('- ``fleet-arc-status-summary.csv`` - one row per distinct Arc agent status value (histogram)')
    [void]$sb.AppendLine('- ``fleet-arc-non-connected-machines.csv`` - one row per machine whose Arc agent status is NOT Connected (full column set: Machine Name, Cluster Name, Status, OS SKU, OS Version, Cluster Version, Disconnected Since, Resource Group, Subscription)')
    [void]$sb.AppendLine('- ``fleet-physical-nics.csv`` - one row per physical NIC issue (Disconnected, non-APIPA IP)')
    [void]$sb.AppendLine('- ``fleet-physical-nic-all.csv`` - full unfiltered NIC inventory (every NIC across every edge device; Physical + Virtual; all statuses)')
    [void]$sb.AppendLine('- ``fleet-physical-nic-stats.csv`` - NIC histogram by NicType + NicStatus (one row per pair, with count)')
    [void]$sb.AppendLine('- ``fleet-arb-status.csv`` - one row per ARB appliance (status + days since lastModified; multi-cluster-per-RG safe via summarize/make_set)')
    [void]$sb.AppendLine('- JSON copies of each, same shape, machine-readable')
    [void]$sb.AppendLine('- ``fleet-connectivity-status.xml`` - JUnit XML (test results for the CI/CD test-reporter)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('_Note: test sections prefixed **[JUnit Debug]** in the pipeline test-reporter view are a diagnostic mirror of the tables above (for CI tooling/ITSM integration). For primary readability, use this summary and the CSV artifacts._')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("*Generated at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')*")

    $md = $sb.ToString()

    # ------------------------------------------------------------------
    # 6. Optional file write + return.
    # ------------------------------------------------------------------
    if ($OutputPath) {
        $parent = Split-Path -Path $OutputPath -Parent
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        # UTF-8 without BOM (GH Actions step summary parsing tolerates BOM
        # but ADO uploadsummary does not in some agent versions).
        [System.IO.File]::WriteAllText($OutputPath, $md, [System.Text.UTF8Encoding]::new($false))
    }

    if ($PassThru -or -not $OutputPath) {
        return $md
    }
}
