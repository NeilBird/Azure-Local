function Test-AzLocalClusterResourceInGlobalScope {
    <#
    .SYNOPSIS
        Verifies that one cluster resource ID is admitted by global tag policy.
    .DESCRIPTION
        Returns true without an Azure query when no global filters are active.
        Otherwise queries the cluster resource with the configured clauses and
        returns true only when that exact resource ID remains in scope.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterResourceId
    )

    $settings = Get-AzLocalFleetSettings
    $filters = @($settings.ClusterTagFilters)
    if ($filters.Count -eq 0) { return $true }

    $escapedResourceId = $ClusterResourceId.ToLowerInvariant() -replace "'", "''"
    $tagClause = ConvertTo-AzLocalClusterTagFilterKqlClause -ClusterTagFilters $filters
    $query = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where tolower(id) == '$escapedResourceId' $tagClause | project id, tags"
    $subscriptionMatch = [regex]::Match($ClusterResourceId, '(?i)^/subscriptions/([^/]+)/')
    $invokeParams = @{ Query = $query }
    if ($subscriptionMatch.Success) {
        $invokeParams['SubscriptionId'] = $subscriptionMatch.Groups[1].Value
    }

    $rows = Invoke-AzResourceGraphQuery @invokeParams
    foreach ($row in $rows) {
        if ($row.PSObject.Properties['id'] -and
            [string]::Equals([string]$row.id, $ClusterResourceId, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Test-AzLocalClusterMatchesTagFilter -Tags $row.tags -ClusterTagFilters $filters)) {
            return $true
        }
    }
    return $false
}