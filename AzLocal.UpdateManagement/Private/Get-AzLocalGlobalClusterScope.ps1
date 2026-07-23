function Get-AzLocalGlobalClusterScope {
    <#
    .SYNOPSIS
        Resolves globally selected Azure Local cluster resources and IDs.
    .DESCRIPTION
        Reads fleet settings and queries cluster resources only when global
        tag filters are configured. The returned ID map is case-insensitive
        and can be used to scope child resources by their parent cluster ID.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string[]]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeReportedNodes
    )

    $settings = Get-AzLocalFleetSettings
    $filters = @($settings.ClusterTagFilters)
    $clusterById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($filters.Count -eq 0) {
        return [pscustomobject]@{
            Enabled           = $false
            ClusterTagFilters = [object[]]@()
            ClusterRows       = [object[]]@()
            ClusterIds        = [string[]]@()
            ClusterById       = $clusterById
        }
    }

    $tagClause = ConvertTo-AzLocalClusterTagFilterKqlClause -ClusterTagFilters $filters
    $propertiesProjection = if ($IncludeReportedNodes.IsPresent) { ', properties' } else { '' }
    $query = "resources | where type =~ 'microsoft.azurestackhci/clusters' $tagClause | project id, name, resourceGroup, subscriptionId, tags$propertiesProjection | order by id asc"
    $invokeParams = @{ Query = $query }
    if ($null -ne $SubscriptionId -and $SubscriptionId.Count -gt 0) {
        $invokeParams['SubscriptionId'] = $SubscriptionId
    }

    $clusterRows = Invoke-AzResourceGraphQuery @invokeParams
    $clusterRows = @($clusterRows | Where-Object {
        $_.PSObject.Properties['id'] -and $_.id -and
        (Test-AzLocalClusterMatchesTagFilter -Tags $_.tags -ClusterTagFilters $filters)
    })
    foreach ($clusterRow in $clusterRows) {
        $clusterById[[string]$clusterRow.id] = $clusterRow
    }

    return [pscustomobject]@{
        Enabled           = $true
        ClusterTagFilters = $filters
        ClusterRows       = $clusterRows
        ClusterIds        = [string[]]@($clusterById.Keys)
        ClusterById       = $clusterById
    }
}