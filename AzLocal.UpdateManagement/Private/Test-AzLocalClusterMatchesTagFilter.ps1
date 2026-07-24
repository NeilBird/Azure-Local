function Test-AzLocalClusterMatchesTagFilter {
    <#
    .SYNOPSIS
        Tests cluster tags against grouped global fleet tag filters.
    .DESCRIPTION
        Tag names and values are compared case-insensitively. Tags within a
        group use AND semantics; groups use OR semantics. An empty list passes.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $Tags,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$ClusterTagFilters
    )

    if ($null -eq $ClusterTagFilters -or $ClusterTagFilters.Count -eq 0) {
        return $true
    }
    if ($null -eq $Tags) {
        return $false
    }

    foreach ($group in $ClusterTagFilters) {
        $filters = if ($group.PSObject.Properties['Tags']) { @($group.Tags) } else { @($group) }
        $groupMatches = $true
        foreach ($filter in $filters) {
        $expectedName = [string]$filter.Name
        $expectedValue = [string]$filter.Value
        $actualValue = $null
        $found = $false

        if ($Tags -is [System.Collections.IDictionary]) {
            foreach ($key in $Tags.Keys) {
                if ([string]::Equals([string]$key, $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $actualValue = [string]$Tags[$key]
                    $found = $true
                    break
                }
            }
        }
        else {
            foreach ($property in $Tags.PSObject.Properties) {
                if ([string]::Equals($property.Name, $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $actualValue = [string]$property.Value
                    $found = $true
                    break
                }
            }
        }

            if (-not $found -or
                -not [string]::Equals($actualValue, $expectedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
                $groupMatches = $false
                break
            }
        }
        if ($groupMatches) {
            return $true
        }
    }

    return $false
}