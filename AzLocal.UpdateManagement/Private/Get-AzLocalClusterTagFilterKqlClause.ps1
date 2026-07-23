function Get-AzLocalClusterTagFilterKqlClause {
    <#
    .SYNOPSIS
        Returns the configured global fleet tag clause for a cluster query.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $settings = Get-AzLocalFleetSettings
    return ConvertTo-AzLocalClusterTagFilterKqlClause -ClusterTagFilters $settings.ClusterTagFilters
}