########################################
<#
.SYNOPSIS
    Collects fleet-wide connectivity status across four scopes: cluster
    connectivity, Arc agent status, physical NIC issues, and Azure Resource
    Bridge appliances.

.DESCRIPTION
    Replaces the inline PowerShell query block previously embedded in the
    Step.4_fleet-connectivity-status YAML pipelines. All four data-collection
    scopes are now handled here using the module's Invoke-AzResourceGraphQuery
    helper. Each query projects only the fields consumed by the report to keep
    fleet-scale ARG responses below the service payload limit. Aggregation and
    joins remain client-side; field extraction accepts both the lean projected
    schema and the legacy full-resource schema.

    The function runs five ARG queries:
      1. microsoft.azurestackhci/clusters           - cluster connectivity
      2. microsoft.azurestackhci/clusters/updatesummaries - current versions
      3. microsoft.hybridcompute/machines           - Arc agent status (per node)
      4. microsoft.azurestackhci/edgedevices        - physical NIC inventory
      5. microsoft.resourceconnector/appliances     - ARB appliance status

    From the machine rows it builds:
      - ArcSummary: grouped count by AgentStatus (no KQL summarize dependency)
      - NonConnectedMachines: filtered + enriched with cluster version

    From the NIC rows (mv-expanded server-side) it builds:
      - NicAll:    full inventory (all types, all statuses)
      - NicIssues: Physical NICs that are Disconnected with a non-APIPA IP
      - NicStats:  NicType + NicStatus histogram

    ARB-to-cluster mapping is done client-side by matching ARB resource group
    to cluster resource group (multi-cluster-per-RG safe).

    When -ExportPath is supplied, writes the same seven CSV+JSON files that
    the previous inline YAML script produced so the 'Create Fleet Connectivity
    Summary' step (which reads those files) continues to work without change.

.PARAMETER SubscriptionId
    Optional. Limit all queries to a single Azure subscription ID.
    Omit to query every subscription the caller can read.

.PARAMETER ExportPath
    Optional directory path. When provided, seven CSV files and seven JSON
    files are written there (creating the directory if needed):
      fleet-cluster-connectivity.{csv,json}
      fleet-arc-status-summary.{csv,json}
      fleet-arc-non-connected-machines.{csv,json}
      fleet-physical-nics.{csv,json}
      fleet-physical-nic-all.{csv,json}
      fleet-physical-nic-stats.{csv,json}
      fleet-arb-status.{csv,json}

.PARAMETER PassThru
    Return the result object to the pipeline even when -ExportPath is given.
    Without -ExportPath the object is always returned.

.OUTPUTS
    [PSCustomObject] with properties:
      ClusterRows          - one row per HCI cluster (connectivity + status)
      ArcSummary           - one row per distinct Arc agent status (with Count)
      NonConnectedMachines - one row per physical machine not in Connected state
      NicIssues            - Physical NICs Disconnected with a non-APIPA IP
      NicAll               - full NIC inventory (all types, all statuses)
      NicStats             - NicType + NicStatus histogram (one row per pair)
      ArbRows              - one row per ARB appliance with cluster mapping

.EXAMPLE
    $data = Get-AzLocalFleetConnectivityStatus
    $data.ClusterRows | Where-Object { $_.ConnectivityStatus -ne 'Connected' }

.EXAMPLE
    Get-AzLocalFleetConnectivityStatus -ExportPath './reports' -PassThru

.NOTES
    Author:  Neil Bird, Microsoft.
    Added:   v0.7.79
    Module:  AzLocal.UpdateManagement
#>
########################################
function Get-AzLocalFleetConnectivityStatus {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ExportPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    # Traverse a dot-separated property path on an object, e.g.
    # 'properties.connectivityStatus'. Returns $null if any segment is
    # missing rather than throwing.
    function Get-NestedProp {
        param([object]$Obj, [string]$Path)
        $cur = $Obj
        foreach ($seg in $Path -split '\.') {
            if ($null -eq $cur) { return $null }
            try { $cur = $cur.$seg } catch { return $null }
        }
        return $cur
    }

    # Return $Val coerced to string, or $Default when null/empty.
    function CoerceStr {
        param([object]$Val, [string]$Default = '')
        if ($null -eq $Val) { return $Default }
        $s = [string]$Val
        if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
        return $s
    }

    function NormalizeNodeName {
        param([object]$Value)
        $nodeName = CoerceStr $Value
        if (-not $nodeName) { return '' }
        return (($nodeName.Trim().TrimEnd('.') -split '\.')[0]).ToLowerInvariant()
    }

    $invokeArgs = @{}
    if ($PSBoundParameters.ContainsKey('SubscriptionId') -and $SubscriptionId) {
        $invokeArgs['SubscriptionId'] = $SubscriptionId
    }

    # ------------------------------------------------------------------
    # 1. Cluster connectivity
    # ------------------------------------------------------------------
    Write-Log -Message '[1/5] Querying cluster connectivity...' -Level Info

    $globalTagFilter = Get-AzLocalClusterTagFilterKqlClause
    $globalFilterEnabled = -not [string]::IsNullOrWhiteSpace($globalTagFilter)
    $clusterKql = @"
resources
| where type =~ 'microsoft.azurestackhci/clusters'
$globalTagFilter
| project id, name, resourceGroup, subscriptionId, location,
          ConnectivityStatus = tostring(properties.connectivityStatus),
          ClusterStatus = tostring(properties.status),
          NodeCount = array_length(properties.reportedProperties.nodes),
          ReportedNodes = properties.reportedProperties.nodes
| order by id asc
"@
    $clusterRaw = Invoke-AzResourceGraphQuery -Query $clusterKql @invokeArgs

    $clusterRows = @($clusterRaw | ForEach-Object {
        $r = $_
        $connStatusValue = if ($r.PSObject.Properties['ConnectivityStatus']) { $r.ConnectivityStatus } else { Get-NestedProp $r 'properties.connectivityStatus' }
        $clusterStatusValue = if ($r.PSObject.Properties['ClusterStatus']) { $r.ClusterStatus } else { Get-NestedProp $r 'properties.status' }
        $connStatus = CoerceStr $connStatusValue
        $clsStatus  = CoerceStr $clusterStatusValue
        # v0.7.84 fix: cluster ARG records expose 'properties.reportedProperties.nodes' (array),
        # NOT a 'nodeCount' scalar. Previously reading 'nodeCount' returned $null for every
        # cluster which surfaced as Nodes=0 in the Step.4 summary and a misleading
        # 'Node coverage delta' of -(Arc-joined nodes).
        $nodes = Get-NestedProp $r 'properties.reportedProperties.nodes'
        $nodeCount = if ($r.PSObject.Properties['NodeCount'] -and $null -ne $r.NodeCount) { [int]$r.NodeCount } elseif ($nodes) { @($nodes).Count } else { 0 }
        [PSCustomObject][ordered]@{
            ClusterName        = CoerceStr $r.name (CoerceStr $r.resourceGroup 'Unknown')
            ClusterId          = CoerceStr $r.id
            ConnectivityStatus = if ([string]::IsNullOrWhiteSpace($connStatus)) { if ([string]::IsNullOrWhiteSpace($clsStatus)) { 'Unknown' } else { $clsStatus } } else { $connStatus }
            ClusterStatus      = if ([string]::IsNullOrWhiteSpace($clsStatus)) { 'Unknown' } else { $clsStatus }
            NodeCount          = [int]$nodeCount
            Location           = CoerceStr $r.location
            ResourceGroup      = CoerceStr $r.resourceGroup
            SubscriptionId     = CoerceStr $r.subscriptionId
        }
    } | Sort-Object ConnectivityStatus, ClusterName)

    Write-Log -Message "  Clusters: $($clusterRows.Count) row(s)" -Level Info

    # Cluster ID -> row lookup (lower-case for joins)
    $clusterById = @{}
    foreach ($c in $clusterRows) {
        if ($c.ClusterId) { $clusterById[$c.ClusterId.ToLowerInvariant()] = $c }
    }

    # Subscription + resource group -> cluster rows (multi-cluster RG safe).
    $clustersByRg = @{}
    foreach ($c in $clusterRows) {
        $rg = '{0}|{1}' -f $c.SubscriptionId.ToLowerInvariant(), $c.ResourceGroup.ToLowerInvariant()
        if (-not $clustersByRg.ContainsKey($rg)) {
            $clustersByRg[$rg] = [System.Collections.Generic.List[object]]::new()
        }
        [void]$clustersByRg[$rg].Add($c)
    }

    # Cluster-reported node names are the authoritative physical-machine map.
    $clusterByNodeName = @{}
    foreach ($rawCluster in @($clusterRaw)) {
        $rawClusterId = CoerceStr $rawCluster.id
        if (-not $rawClusterId -or -not $clusterById.ContainsKey($rawClusterId.ToLowerInvariant())) { continue }
        $reportedNodes = if ($rawCluster.PSObject.Properties['ReportedNodes']) { $rawCluster.ReportedNodes } else { Get-NestedProp $rawCluster 'properties.reportedProperties.nodes' }
        foreach ($reportedNode in @($reportedNodes)) {
            if ($null -eq $reportedNode) { continue }
            $reportedNodeName = if ($reportedNode.PSObject.Properties['name']) { $reportedNode.name } elseif ($reportedNode.PSObject.Properties['nodeName']) { $reportedNode.nodeName } else { '' }
            $shortNodeName = NormalizeNodeName $reportedNodeName
            if ($shortNodeName -and -not $clusterByNodeName.ContainsKey($shortNodeName)) {
                $clusterByNodeName[$shortNodeName] = $clusterById[$rawClusterId.ToLowerInvariant()]
            }
        }
    }

    # ------------------------------------------------------------------
    # 2. Update summaries (current version per cluster)
    # ------------------------------------------------------------------
    Write-Log -Message '[2/5] Querying update summaries for cluster versions...' -Level Info

    $versionKql = "extensibilityresources | where type =~ 'microsoft.azurestackhci/clusters/updatesummaries' | project id, CurrentVersion = tostring(properties.currentVersion) | order by id asc"
    $versionRaw = Invoke-AzResourceGraphQuery -Query $versionKql @invokeArgs

    $clusterVersionMap = @{}
    foreach ($us in $versionRaw) {
        # Strip the '/updateSummaries/default' suffix to get the parent cluster id
        $rawId = CoerceStr $us.id
        if (-not $rawId) { continue }
        $sepIdx = $rawId.ToLowerInvariant().IndexOf('/updatesummaries/')
        $cIdLower = if ($sepIdx -gt 0) { $rawId.Substring(0, $sepIdx).ToLowerInvariant() } else { $rawId.ToLowerInvariant() }
        if (-not $clusterVersionMap.ContainsKey($cIdLower)) {
            $currentVersion = if ($us.PSObject.Properties['CurrentVersion']) { $us.CurrentVersion } else { Get-NestedProp $us 'properties.currentVersion' }
            $clusterVersionMap[$cIdLower] = CoerceStr $currentVersion
        }
    }

    # ------------------------------------------------------------------
    # 3. Arc machines (all physical HCI nodes)
    #    Query returns full resources; all field extraction is client-side.
    #    ArcSummary is built via Group-Object so there is no dependency on
    #    ARG honouring '| summarize'.
    # ------------------------------------------------------------------
    Write-Log -Message '[3/5] Querying Arc machine status...' -Level Info

    $machinesKql = @"
resources
| where type =~ 'microsoft.hybridcompute/machines'
| where properties.cloudMetadata.provider =~ 'AzSHCI'
| where kind !~ 'HCI'
| project id, name, resourceGroup, subscriptionId,
          ParentClusterResourceId = tostring(properties.parentClusterResourceId),
          AgentStatus = tostring(properties.status),
          OsSku = tostring(properties.osSku),
          OsVersion = tostring(properties.osVersion),
          AgentVersion = tostring(properties.agentVersion),
          LastStatusChange = tostring(properties.lastStatusChange)
| order by id asc
"@
    $machinesRaw = Invoke-AzResourceGraphQuery -Query $machinesKql @invokeArgs

    $allMachines = @($machinesRaw | ForEach-Object {
        $m = $_
        $shortNodeName = NormalizeNodeName $m.name
        $cluster = if ($clusterByNodeName.ContainsKey($shortNodeName)) { $clusterByNodeName[$shortNodeName] } else { $null }
        $parentClusterResourceId = if ($m.PSObject.Properties['ParentClusterResourceId']) { $m.ParentClusterResourceId } else { Get-NestedProp $m 'properties.parentClusterResourceId' }
        if ($null -eq $cluster -and $globalFilterEnabled) { return }
        $clusterId = if ($cluster) { $cluster.ClusterId } else { CoerceStr $parentClusterResourceId }
        # v0.7.84 fix: extract the cluster name (last segment of the ARM ID).
        # Pre-fix code cast the WHOLE split array to a string (joining the
        # elements with spaces) before indexing with -1, which then returned
        # the last CHARACTER of the joined string rather than the last array
        # element (e.g. cluster 'Mobile' became 'e', 'alrs-cc' became 'c').
        # This surfaced as a corrupted ClusterName column in the
        # 'Non-Connected Machines' table. The fix indexes the split array
        # directly with [-1], no string cast.
        $clusterName = if ($cluster) { $cluster.ClusterName } elseif ($clusterId) { CoerceStr (($clusterId -split '/')[-1]) } else { '' }
        $version     = if ($clusterId) { CoerceStr $clusterVersionMap[$clusterId.ToLowerInvariant()] } else { '' }
        [PSCustomObject][ordered]@{
            NodeName         = CoerceStr $m.name
            MachineId        = CoerceStr $m.id
            ClusterName      = $clusterName
            ClusterId        = $clusterId
            AgentStatus      = CoerceStr $(if ($m.PSObject.Properties['AgentStatus']) { $m.AgentStatus } else { Get-NestedProp $m 'properties.status' }) 'Unknown'
            OsSku            = CoerceStr $(if ($m.PSObject.Properties['OsSku']) { $m.OsSku } else { Get-NestedProp $m 'properties.osSku' })
            OsVersion        = CoerceStr $(if ($m.PSObject.Properties['OsVersion']) { $m.OsVersion } else { Get-NestedProp $m 'properties.osVersion' })
            ClusterVersion   = $version
            AgentVersion     = CoerceStr $(if ($m.PSObject.Properties['AgentVersion']) { $m.AgentVersion } else { Get-NestedProp $m 'properties.agentVersion' })
            LastStatusChange = CoerceStr $(if ($m.PSObject.Properties['LastStatusChange']) { $m.LastStatusChange } else { Get-NestedProp $m 'properties.lastStatusChange' })
            ResourceGroup    = CoerceStr $m.resourceGroup
            SubscriptionId   = CoerceStr $m.subscriptionId
        }
    })

    # Arc status summary: group by AgentStatus client-side.
    # This replaces the KQL '| summarize Count = count() by AgentStatus'
    # which ARG silently drops, returning raw rows instead of grouped counts.
    $arcSummary = @($allMachines | Group-Object AgentStatus | ForEach-Object {
        [PSCustomObject][ordered]@{ AgentStatus = $_.Name; Count = $_.Count }
    } | Sort-Object @{Expression = { [int]$_.Count }; Descending = $true })

    # Non-connected machines: filter client-side, already have full schema.
    $nonConnectedMachines = @($allMachines |
        Where-Object { $_.AgentStatus -ine 'Connected' } |
        Sort-Object LastStatusChange, ClusterName, NodeName)

    Write-Log -Message "  Arc machines: $($allMachines.Count) total; $($nonConnectedMachines.Count) non-Connected" -Level Info

    # Build short-name lookup for NIC join (edge device name == machine short name)
    $machineByShortName = @{}
    foreach ($m in $allMachines) {
        $short = NormalizeNodeName $m.NodeName
        if ($short -and -not $machineByShortName.ContainsKey($short)) {
            $machineByShortName[$short] = $m
        }
    }

    # ------------------------------------------------------------------
    # 4. Physical NICs via edge devices (mv-expand done server-side by ARG)
    #    extend'd fields are accessible as top-level properties on returned
    #    rows even when ARG drops the final '| project'.
    #    Machine join done client-side using $machineByShortName.
    # ------------------------------------------------------------------
    Write-Log -Message '[4/5] Querying NIC inventory...' -Level Info

    $nicKql = @'
extensibilityresources
| where type =~ 'microsoft.azurestackhci/edgedevices'
| extend edgeMachineName = tolower(tostring(split(id, '/')[8]))
| extend nicDetails = todynamic(properties.reportedProperties.networkProfile.nicDetails)
| mv-expand nic = nicDetails
| extend NicName = tostring(nic.adapterName)
| extend NicStatus = tostring(nic.nicStatus)
| extend DriverVersion = tostring(nic.driverVersion)
| extend InterfaceDescription = tostring(nic.interfaceDescription)
| extend NicType = case(InterfaceDescription contains 'Hyper-V', 'Virtual', InterfaceDescription contains 'Virtual', 'Virtual', 'Physical')
| extend Ip4Address = tostring(nic.ip4Address)
| extend SubnetMask = tostring(nic.subnetMask)
| extend DefaultGateway = tostring(nic.defaultGateway)
| extend DnsServers = strcat_array(nic.dnsServers, ', ')
| extend MacAddress = tostring(nic.macAddress)
| project id, resourceGroup, subscriptionId, edgeMachineName, NicName, NicStatus,
          DriverVersion, InterfaceDescription, NicType, Ip4Address, SubnetMask,
          DefaultGateway, DnsServers, MacAddress
| order by id asc, NicName asc
'@
    $nicRaw = Invoke-AzResourceGraphQuery -Query $nicKql @invokeArgs

    $nicAllRows = @($nicRaw | ForEach-Object {
        $n = $_
        $edgeName = NormalizeNodeName $n.edgeMachineName
        $machine  = $machineByShortName[$edgeName]
        if ($globalFilterEnabled -and $null -eq $machine) { return }
        [PSCustomObject][ordered]@{
            NodeName             = if ($machine) { $machine.NodeName } else { $edgeName }
            MachineId            = if ($machine) { $machine.MachineId } else { '' }
            ClusterName          = if ($machine) { $machine.ClusterName } else { '' }
            ClusterId            = if ($machine) { $machine.ClusterId } else { '' }
            MachineConnectivity  = if ($machine) { $machine.AgentStatus } else { 'Unknown' }
            NicName              = CoerceStr $n.NicName '(unknown)'
            NicType              = CoerceStr $n.NicType 'Physical'
            NicStatus            = CoerceStr $n.NicStatus 'Unknown'
            DriverVersion        = CoerceStr $n.DriverVersion
            InterfaceDescription = CoerceStr $n.InterfaceDescription
            Ip4Address           = CoerceStr $n.Ip4Address
            SubnetMask           = CoerceStr $n.SubnetMask
            DefaultGateway       = CoerceStr $n.DefaultGateway
            DnsServers           = CoerceStr $n.DnsServers
            MacAddress           = CoerceStr $n.MacAddress
            ResourceGroup        = CoerceStr $n.resourceGroup
            SubscriptionId       = CoerceStr $n.subscriptionId
        }
    } | Sort-Object NodeName, NicType, NicName)

    # Issues only: Physical, Disconnected, non-APIPA IP
    $nicIssues = @($nicAllRows | Where-Object {
        $_.NicType -eq 'Physical' -and
        $_.NicStatus -ieq 'Disconnected' -and
        -not [string]::IsNullOrWhiteSpace($_.Ip4Address) -and
        -not $_.Ip4Address.StartsWith('169.254.')
    } | Sort-Object ClusterName, NodeName, NicName)

    # NIC type+status histogram (no KQL summarize dependency)
    $nicStats = @($nicAllRows | Group-Object NicType, NicStatus | ForEach-Object {
        $g = $_.Group[0]
        [PSCustomObject][ordered]@{ NicType = $g.NicType; NicStatus = $g.NicStatus; Count = $_.Count }
    } | Sort-Object NicType, NicStatus)

    Write-Log -Message "  NICs: $($nicAllRows.Count) total; $($nicIssues.Count) issue(s)" -Level Info

    # ------------------------------------------------------------------
    # 5. Azure Resource Bridge - client-side join to clusters by RG
    #    Replaces the KQL summarize/make_set join that ARG silently drops.
    #    Multi-cluster-per-RG is safe: clustersByRg holds a list per key.
    # ------------------------------------------------------------------
    Write-Log -Message '[5/5] Querying Azure Resource Bridge status...' -Level Info

    # v0.7.84 fix: explicitly `extend lastModifiedAt = tostring(systemData.lastModifiedAt)`.
    # The default `resources` ARG response sometimes omits/strips `systemData`,
    # which caused DaysSinceLastModified to fall through to the -1 sentinel for
    # every ARB regardless of status. The extend guarantees the column is present
    # in the row dictionary (empty string if truly missing).
    $arbKql = "resources | where type =~ 'microsoft.resourceconnector/appliances' | extend lastModifiedAt = tostring(systemData.lastModifiedAt) | project id, name, resourceGroup, subscriptionId, ArbStatus = tostring(properties.status), lastModifiedAt | order by id asc"
    $arbRaw  = Invoke-AzResourceGraphQuery -Query $arbKql @invokeArgs

    $arbRows = @($arbRaw | ForEach-Object {
        $a  = $_
        $rg = '{0}|{1}' -f ([string]$a.subscriptionId).ToLowerInvariant(), ([string]$a.resourceGroup).ToLowerInvariant()
        # v0.8.6-fix3: when the RG has no matching cluster, do NOT use @($null) -
        # PowerShell's @() wrap on a $null produces an Object[1] containing $null
        # (not an empty array), so $matched.Count is 1 and downstream $_.ClusterName
        # fails with PropertyNotFoundException. Branch explicitly on ContainsKey
        # and emit @() for the miss case.
        if ($clustersByRg.ContainsKey($rg)) {
            $matched = @($clustersByRg[$rg])
        } else {
            $matched = @()
        }
        $matchedCount = $matched.Count
        if ($globalFilterEnabled -and $matchedCount -eq 0) { return }

        $clusterName   = if ($matchedCount -gt 0) { ($matched | ForEach-Object { $_.ClusterName })   -join ', ' } else { '(no cluster)' }
        $clusterId     = if ($matchedCount -gt 0) { ($matched | ForEach-Object { $_.ClusterId })     -join ', ' } else { '' }
        $clusterStatus = if ($matchedCount -gt 0) { ($matched | ForEach-Object { $_.ClusterStatus }) -join ', ' } else { '' }

        $arbStatus = if ($a.PSObject.Properties['ArbStatus']) { $a.ArbStatus } else { Get-NestedProp $a 'properties.status' }
        $status = CoerceStr $arbStatus 'Unknown'
        # Read the extended top-level column first, fall back to systemData.lastModifiedAt
        # in case the ARG CLI strips the extend column too (defence in depth).
        $lastMod = CoerceStr $a.lastModifiedAt
        if (-not $lastMod) { $lastMod = CoerceStr (Get-NestedProp $a 'systemData.lastModifiedAt') }

        # v0.7.84 UX fix: compute real days for ALL ARBs (previously short-
        # circuited to -1 for Running). Real days is useful information even
        # for healthy ARBs (e.g. last upgrade activity). -1 is now reserved
        # solely for "unknown/can't compute" (missing or unparseable timestamp).
        $daysSince = if ($lastMod) {
            try { [int]((Get-Date) - [datetime]::Parse($lastMod)).TotalDays } catch { [int]-1 }
        } else { [int]-1 }

        [PSCustomObject][ordered]@{
            ArbName               = CoerceStr $a.name
            ArbId                 = CoerceStr $a.id
            ArbStatus             = $status
            ClusterName           = $clusterName
            ClusterId             = $clusterId
            ClusterStatus         = $clusterStatus
            ClusterAttribution    = if ($matchedCount -eq 1) { 'Exact' } elseif ($matchedCount -gt 1) { 'Ambiguous' } else { 'NoCluster' }
            CandidateClusterCount = $matchedCount
            LastModified          = $lastMod
            DaysSinceLastModified = $daysSince
            ResourceGroup         = CoerceStr $a.resourceGroup
            SubscriptionId        = CoerceStr $a.subscriptionId
        }
    } | Sort-Object ArbStatus, ClusterName)

    Write-Log -Message "  ARB appliances: $($arbRows.Count)" -Level Info

    # ------------------------------------------------------------------
    # Export to files when ExportPath is provided
    # ------------------------------------------------------------------
    if ($ExportPath) {
        if (-not (Test-Path $ExportPath)) {
            New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
        }
        $exports = @(
            @{ Rows = $clusterRows;          Name = 'fleet-cluster-connectivity' }
            @{ Rows = $arcSummary;           Name = 'fleet-arc-status-summary' }
            @{ Rows = $nonConnectedMachines; Name = 'fleet-arc-non-connected-machines' }
            @{ Rows = $nicIssues;            Name = 'fleet-physical-nics' }
            @{ Rows = $nicAllRows;           Name = 'fleet-physical-nic-all' }
            @{ Rows = $nicStats;             Name = 'fleet-physical-nic-stats' }
            @{ Rows = $arbRows;              Name = 'fleet-arb-status' }
        )
        foreach ($export in $exports) {
            $export.Rows | Export-Csv  -Path (Join-Path $ExportPath "$($export.Name).csv")  -NoTypeInformation -Force
            $jsonContent = if ($export.Rows.Count -eq 0) { '[]' } else { $export.Rows | ConvertTo-Json -Depth 20 }
            $jsonContent | Out-File -FilePath (Join-Path $ExportPath "$($export.Name).json") -Encoding utf8
        }
        Write-Log -Message "  Exported 7 scopes (CSV + JSON) to: $ExportPath" -Level Info
    }

    $result = [PSCustomObject]@{
        ClusterRows          = $clusterRows
        ArcSummary           = $arcSummary
        NonConnectedMachines = $nonConnectedMachines
        NicIssues            = $nicIssues
        NicAll               = $nicAllRows
        NicStats             = $nicStats
        ArbRows              = $arbRows
    }

    if (-not $ExportPath -or $PassThru) {
        return $result
    }
}
