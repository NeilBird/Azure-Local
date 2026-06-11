function Resolve-AzLocalSideloadPlan {
    <#
    .SYNOPSIS
        Builds the per-cluster sideload plan: which solution-update version each
        UpdateAuthAccountId-tagged Azure Local cluster should have sideloaded, and
        whether it is due within the configured lead window.

    .DESCRIPTION
        Public planner for the v0.8.7 on-prem sideloading automation. It does NOT
        change any state - it only reads the fleet (Azure Resource Graph), the
        apply-updates schedule, the auth map and the catalog, then emits one plan
        object per cluster (plus error rows for misconfigurations such as an
        unknown auth account id, a version not in the allow-list, or a missing
        catalog entry).

        The plan objects feed Invoke-AzLocalSideloadUpdate (the re-entrant Step.6
        state machine). Selection reuses Select-AzLocalNextUpdateForCluster so the
        sideload path and the apply path agree on which update is "next".

    .PARAMETER SchedulePath
        Path to the apply-updates schedule YAML (Get-AzLocalApplyUpdatesScheduleConfig).

    .PARAMETER AuthMapPath
        Path to the sideload auth-map CSV (Get-AzLocalSideloadAuthMap).

    .PARAMETER CatalogPath
        Path to the sideload catalog YAML (Get-AzLocalSideloadCatalog).

    .PARAMETER LeadDays
        How many days before a cluster's next apply window the media should be
        sideloaded. A cluster is "due" when (nextWindow - LeadDays) <= Now.

    .PARAMETER UpdateRingValue
        Optional UpdateRing tag filter (single, list, or '***' wildcard for all
        rings). When omitted, all clusters carrying an UpdateAuthAccountId tag are
        considered.

    .PARAMETER FqdnSuffix
        Global default FQDN suffix appended to a cluster name to form the remoting
        host when the auth-map row does not override it (SIDELOAD_REMOTING_FQDN_SUFFIX).

    .PARAMETER Now
        The reference time (UTC). Defaults to now.

    .PARAMETER SubscriptionId
        Optional subscription scope for the Resource Graph query.

    .OUTPUTS
        [PSCustomObject[]] plan + error rows.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SchedulePath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$AuthMapPath,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$CatalogPath,
        [Parameter(Mandatory = $false)][ValidateRange(0, 365)][int]$LeadDays = 7,
        [Parameter(Mandatory = $false)][string]$UpdateRingValue = '***',
        [Parameter(Mandatory = $false)][string]$FqdnSuffix = '',
        [Parameter(Mandatory = $false)][datetime]$Now = [datetime]::UtcNow,
        [Parameter(Mandatory = $false)][string]$SubscriptionId
    )

    $config = Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath
    $authMap = Get-AzLocalSideloadAuthMap -Path $AuthMapPath
    $catalog = @(Get-AzLocalSideloadCatalog -Path $CatalogPath)

    $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
    $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where isnotempty(tags['UpdateAuthAccountId']) $ringFilter | project id, name, resourceGroup, subscriptionId, tags"

    $clusterRows = if ($PSBoundParameters.ContainsKey('SubscriptionId') -and $SubscriptionId) {
        Invoke-AzResourceGraphQuery -Query $argQuery -SubscriptionId $SubscriptionId
    }
    else {
        Invoke-AzResourceGraphQuery -Query $argQuery
    }

    # Pre-compute the next 366 days of firings so we can find each cluster's next window.
    $firings = @(Get-AzLocalApplyUpdatesScheduleNextFirings -Schedule $config -StartDate $Now.Date -Days 366)

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($cluster in $clusterRows) {
        $clusterName = [string]$cluster.name
        $accountId = [string]$cluster.tags.UpdateAuthAccountId
        $ringTag = [string]$cluster.tags.UpdateRing

        $row = [ordered]@{
            ClusterName         = $clusterName
            ClusterResourceId   = [string]$cluster.id
            ResourceGroup       = [string]$cluster.resourceGroup
            SubscriptionId      = [string]$cluster.subscriptionId
            UpdateAuthAccountId = $accountId
            Ring                = $ringTag
            NextWindowUtc       = $null
            LeadDays            = $LeadDays
            DueNow              = $false
            SelectedVersion     = ''
            SelectedUpdateName  = ''
            PackageType         = ''
            CatalogEntry        = $null
            RemotingHost        = ''
            TargetPath          = ''
            AuthRow             = $null
            Status              = 'Planned'
            Message             = ''
        }

        # Auth-map row.
        if (-not $authMap.ContainsKey($accountId)) {
            $row.Status = 'UnknownAuthAccountId'
            $row.Message = "Cluster '$clusterName' has UpdateAuthAccountId '$accountId' which is not present in the auth map."
            $results.Add([PSCustomObject]$row); continue
        }
        $authRow = $authMap[$accountId]
        $row.AuthRow = $authRow

        # Remoting host + target path.
        $remotingHost = if (-not [string]::IsNullOrWhiteSpace([string]$authRow.RemotingTargetFqdn)) {
            [string]$authRow.RemotingTargetFqdn
        }
        else {
            $suffix = if (-not [string]::IsNullOrWhiteSpace([string]$authRow.FqdnSuffix)) { [string]$authRow.FqdnSuffix } else { $FqdnSuffix }
            if (-not [string]::IsNullOrWhiteSpace($suffix)) { ('{0}{1}' -f $clusterName, $suffix) } else { $clusterName }
        }
        $row.RemotingHost = $remotingHost
        $row.TargetPath = Resolve-AzLocalSideloadTargetPath -RemotingHost $remotingHost -ImportSharePath ([string]$authRow.ImportSharePath)

        # Next apply window for this cluster's ring.
        $nextFiring = $firings | Where-Object {
            $_.Rings -and ($_.Rings -contains $ringTag) -and ($_.DateUtc -ge $Now.Date)
        } | Sort-Object DateUtc | Select-Object -First 1
        if ($nextFiring) {
            $row.NextWindowUtc = $nextFiring.DateUtc
            $dueDate = ([datetime]$nextFiring.DateUtc).AddDays(-$LeadDays)
            $row.DueNow = ($Now -ge $dueDate)
        }

        # Resolve allow-list for the cluster (today's resolution gives the list).
        $ringInfo = Resolve-AzLocalCurrentUpdateRing -Schedule $config -Now $Now
        $allowed = @($ringInfo.AllowedUpdateVersions)

        # Available Ready updates -> adapter shape for Select-AzLocalNextUpdateForCluster.
        $available = @(Get-AzLocalAvailableUpdates -ClusterResourceId ([string]$cluster.id) -ErrorAction SilentlyContinue)
        $readyAdapters = @(
            $available | Where-Object { [string]$_.UpdateState -eq 'Ready' } | ForEach-Object {
                [PSCustomObject]@{
                    name        = [string]$_.UpdateName
                    PackageType = [string]$_.PackageType
                    properties  = [PSCustomObject]@{ version = [string]$_.Version; state = [string]$_.UpdateState }
                }
            }
        )

        $selection = Select-AzLocalNextUpdateForCluster -ReadyUpdates $readyAdapters -AllowedUpdateVersions $allowed
        switch ($selection.Reason) {
            'Selected' {
                $sel = $selection.SelectedUpdate
                $version = [string]$sel.properties.version
                if ([string]::IsNullOrWhiteSpace($version)) { $version = [string]$sel.name }
                $row.SelectedVersion = $version
                $row.SelectedUpdateName = [string]$sel.name
                $row.PackageType = [string]$sel.PackageType

                $entry = $catalog | Where-Object { [string]$_.Version -eq $version } | Select-Object -First 1
                if ($null -eq $entry) {
                    $row.Status = 'NoCatalogEntry'
                    $row.Message = "Selected version '$version' for cluster '$clusterName' has no entry in the sideload catalog."
                }
                else {
                    $row.CatalogEntry = $entry
                    if (-not $row.PackageType) { $row.PackageType = [string]$entry.PackageType }
                    $row.Status = if ($row.DueNow) { 'Planned' } else { 'NotDue' }
                    $row.Message = if ($row.DueNow) {
                        "Cluster '$clusterName' due for sideload of '$version' (window $($row.NextWindowUtc))."
                    }
                    else {
                        "Cluster '$clusterName' not yet within the $LeadDays-day lead window for '$version'."
                    }
                }
            }
            'NotInAllowList' {
                $row.Status = 'NotInAllowList'
                $row.Message = "No Ready update for cluster '$clusterName' matches the allow-list [$($selection.AllowDisplay)]. Ready: [$($selection.ReadyDisplay)]."
            }
            'NoneReady' {
                $row.Status = 'NoneReady'
                $row.Message = "Cluster '$clusterName' has no Ready updates available."
            }
            default {
                $row.Status = [string]$selection.Reason
                $row.Message = "Cluster '$clusterName' selection reason: $($selection.Reason)."
            }
        }

        $results.Add([PSCustomObject]$row)
    }

    return $results.ToArray()
}
