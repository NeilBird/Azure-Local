function ConvertTo-AzLocalClusterTagFilterKqlClause {
    <#
    .SYNOPSIS
        Builds cluster-resource KQL clauses for global fleet tag filters.
    .DESCRIPTION
        Produces one case-insensitive equality clause per configured tag pair.
        Adjacent clauses use AND semantics. This helper is only for queries
        whose current rows are microsoft.azurestackhci/clusters resources.
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

    $clauses = [System.Collections.Generic.List[string]]::new()
    foreach ($filter in $ClusterTagFilters) {
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
        [void]$clauses.Add("| where tostring(tags['$escapedName']) =~ '$escapedValue'")
    }

    return ($clauses -join ' ')
}