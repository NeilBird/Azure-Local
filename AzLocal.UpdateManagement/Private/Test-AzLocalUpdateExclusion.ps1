function Test-AzLocalUpdateExclusion {
    <#
    .SYNOPSIS
        Tests whether a given date falls within any exclusion (blackout) period.
    .DESCRIPTION
        Parses the UpdateWindowExclusions tag value and checks if the specified (or current) UTC date
        falls within any of the defined blackout periods.
    .PARAMETER ExclusionString
        The UpdateWindowExclusions tag value to evaluate.
    .PARAMETER TestDate
        The UTC date to test against. Defaults to current UTC date.
    .OUTPUTS
        PSCustomObject with Excluded (bool), Reason (string), MatchedExclusion (string or $null)
    .EXAMPLE
        Test-AzLocalUpdateExclusion -ExclusionString "2026-12-20/2027-01-03"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExclusionString,

        [Parameter(Mandatory = $false)]
        [datetime]$TestDate = (Get-Date).ToUniversalTime().Date
    )

    $testDateOnly = $TestDate.Date
    $exclusions = ConvertFrom-AzLocalUpdateExclusion -ExclusionString $ExclusionString -ReferenceDate $testDateOnly

    foreach ($exclusion in $exclusions) {
        if ($testDateOnly -ge $exclusion.StartDate -and $testDateOnly -le $exclusion.EndDate) {
            return [PSCustomObject]@{
                Excluded         = $true
                Reason           = "Date $($testDateOnly.ToString('yyyy-MM-dd')) falls within exclusion period: $($exclusion.Raw) ($($exclusion.StartDate.ToString('yyyy-MM-dd')) to $($exclusion.EndDate.ToString('yyyy-MM-dd')))"
                MatchedExclusion = $exclusion.Raw
            }
        }
    }

    return [PSCustomObject]@{
        Excluded         = $false
        Reason           = "Date $($testDateOnly.ToString('yyyy-MM-dd')) is not in any exclusion period"
        MatchedExclusion = $null
    }
}
