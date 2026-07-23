function Test-AzLocalClusterMatchesTagFilter {
    <#
    .SYNOPSIS
        Tests cluster tags against every configured global fleet tag filter.
    .DESCRIPTION
        Tag names and values are compared case-insensitively. A missing tag or
        any value mismatch returns false. An empty filter list returns true.
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

    foreach ($filter in $ClusterTagFilters) {
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
            return $false
        }
    }

    return $true
}