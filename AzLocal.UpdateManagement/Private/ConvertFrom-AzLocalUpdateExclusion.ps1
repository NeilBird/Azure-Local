function ConvertFrom-AzLocalUpdateExclusion {
    <#
    .SYNOPSIS
        Parses an UpdateExclusionsWindow tag value into structured date range objects.
    .DESCRIPTION
        Parses the exclusion date range syntax used in the UpdateExclusionsWindow Azure resource
        tag (renamed from 'UpdateExclusions' in v0.7.90; tag VALUE format is unchanged).
        Supports wildcards (*) for recurring annual patterns.

        Syntax: <start_date>/<end_date>[,<start_date>/<end_date>]
        Dates: YYYY-MM-DD format. * replaces a single digit for recurring patterns.
    .PARAMETER ExclusionString
        The UpdateExclusionsWindow tag value to parse.
    .PARAMETER ReferenceDate
        The date to use for resolving wildcards. Defaults to today (UTC).
    .OUTPUTS
        PSCustomObject[] with StartDate (datetime), EndDate (datetime), IsWildcard (bool), Raw (string)
    .EXAMPLE
        ConvertFrom-AzLocalUpdateExclusion -ExclusionString "2026-12-20/2027-01-03"
    .EXAMPLE
        ConvertFrom-AzLocalUpdateExclusion -ExclusionString "20**-12-20/20**-01-03"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExclusionString,

        [Parameter(Mandatory = $false)]
        [datetime]$ReferenceDate = (Get-Date).ToUniversalTime().Date
    )

    if ([string]::IsNullOrWhiteSpace($ExclusionString)) {
        throw "UpdateExclusionsWindow value cannot be empty."
    }

    if ($ExclusionString.Length -gt 256) {
        throw "UpdateExclusionsWindow value exceeds Azure tag limit of 256 characters (length: $($ExclusionString.Length))."
    }

    $exclusions = @()
    $ranges = $ExclusionString -split ','

    foreach ($range in $ranges) {
        $range = $range.Trim()
        if ([string]::IsNullOrWhiteSpace($range)) { continue }

        if ($range -notmatch '^([0-9*]{4}-[0-9*]{2}-[0-9*]{2})/([0-9*]{4}-[0-9*]{2}-[0-9*]{2})$') {
            throw "Invalid exclusion range syntax: '$range'. Expected format: YYYY-MM-DD/YYYY-MM-DD (wildcards * allowed)."
        }

        $startPattern = $matches[1]
        $endPattern = $matches[2]
        $isWildcard = ($startPattern -match '\*') -or ($endPattern -match '\*')

        if ($isWildcard) {
            # Resolve wildcards against current year and adjacent years
            $resolvedRanges = Resolve-WildcardDateRange -StartPattern $startPattern -EndPattern $endPattern -ReferenceDate $ReferenceDate
            foreach ($resolved in $resolvedRanges) {
                $exclusions += [PSCustomObject]@{
                    StartDate  = $resolved.StartDate
                    EndDate    = $resolved.EndDate
                    IsWildcard = $true
                    Raw        = $range
                }
            }
        }
        else {
            # Fixed dates (PS 5.1 compatible - avoid TryParseExact [ref] issues)
            $startDate = $null
            $endDate = $null
            try { $startDate = [datetime]::ParseExact($startPattern, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
            catch { throw "Invalid start date '$startPattern' in exclusion range '$range'." }
            try { $endDate = [datetime]::ParseExact($endPattern, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) }
            catch { throw "Invalid end date '$endPattern' in exclusion range '$range'." }

            if ($endDate -lt $startDate) {
                throw "End date ($endPattern) is before start date ($startPattern) in exclusion range '$range'."
            }

            $exclusions += [PSCustomObject]@{
                StartDate  = $startDate
                EndDate    = $endDate
                IsWildcard = $false
                Raw        = $range
            }
        }
    }

    return $exclusions
}
