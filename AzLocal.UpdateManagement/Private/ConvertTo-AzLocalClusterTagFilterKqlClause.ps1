function ConvertTo-AzLocalClusterTagFilterKqlClause {
    <#
    .SYNOPSIS
        Builds cluster-resource KQL clauses for global fleet tag filters.
    .DESCRIPTION
        Produces one case-insensitive expression with AND semantics within each
        tag group and OR semantics across groups. This helper is only for
        queries whose current rows are microsoft.azurestackhci/clusters.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$ClusterTagFilters
    )

    if ($null -eq $ClusterTagFilters -or $ClusterTagFilters.Count -eq 0) {
        return ''
    }

    $groupClauses = [System.Collections.Generic.List[string]]::new()
    foreach ($group in $ClusterTagFilters) {
        $filters = if ($group.PSObject.Properties['Tags']) { @($group.Tags) } else { @($group) }
        $tagClauses = [System.Collections.Generic.List[string]]::new()
        foreach ($filter in $filters) {
        $hasName = $null -ne $filter -and (
            ($filter -is [System.Collections.IDictionary] -and $filter.Contains('Name')) -or
            ($filter -isnot [System.Collections.IDictionary] -and $filter.PSObject.Properties['Name'])
        )
        $hasValue = $null -ne $filter -and (
            ($filter -is [System.Collections.IDictionary] -and $filter.Contains('Value')) -or
            ($filter -isnot [System.Collections.IDictionary] -and $filter.PSObject.Properties['Value'])
        )
        if (-not $hasName -or -not $hasValue) {
            throw 'ConvertTo-AzLocalClusterTagFilterKqlClause: each filter requires Name and Value properties.'
        }

        $filterName = if ($filter -is [System.Collections.IDictionary]) { $filter['Name'] } else { $filter.Name }
        $filterValue = if ($filter -is [System.Collections.IDictionary]) { $filter['Value'] } else { $filter.Value }
        $escapedName = ([string]$filterName) -replace "'", "''"
        $escapedValue = ([string]$filterValue) -replace "'", "''"
            [void]$tagClauses.Add("tostring(tags['$escapedName']) =~ '$escapedValue'")
        }
        if ($tagClauses.Count -eq 0) {
            throw 'ConvertTo-AzLocalClusterTagFilterKqlClause: each group requires at least one tag.'
        }
        [void]$groupClauses.Add("($($tagClauses -join ' and '))")
    }

    return "| where $($groupClauses -join ' or ')"
}