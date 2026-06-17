function Test-AzLocalUpdateAssessmentStale {
    <#
    .SYNOPSIS
        Determines whether a cluster's update assessment looks STALE relative to the
        latest released solution version in the public manifest.

    .DESCRIPTION
        A cluster can report `state = AppliedSuccessfully` / "Up to date" while a newer
        solution build is actually available, because its cached update assessment has
        not been refreshed (the portal "Check for updates" / checkUpdates action has not
        run recently). This helper detects that condition WITHOUT calling any ARM action:
        it compares the cluster's installed solution YYMM (parsed from -CurrentVersion)
        against the manifest's LatestYYMM (from Get-AzLocalLatestSolutionVersion).

        The YYMM extraction matches Get-AzLocalLatestSolutionVersion exactly: the first
        dotted token that is 4 digits with YY in 20-99 and MM in 01-12 (e.g. the '2605'
        in '12.2605.1003.210').

        This is a heuristic. It only flags a cluster as stale when its installed YYMM is
        STRICTLY BEHIND the latest manifest YYMM. It intentionally does NOT consider the
        rolling support window - a cluster one month behind the latest release is still a
        candidate for a refreshed scan, even if it remains in support.

    .PARAMETER CurrentVersion
        The cluster's installed solution version string (e.g. '12.2605.1003.210'), as
        surfaced in updateSummaries properties.currentVersion / the readiness row.

    .PARAMETER LatestYYMM
        The latest released YYMM from the public manifest (Get-AzLocalLatestSolutionVersion
        .LatestYYMM), e.g. '2606'.

    .OUTPUTS
        PSCustomObject with:
          - IsStale     : bool  - $true only when ClusterYYMM is strictly behind LatestYYMM
          - ClusterYYMM : string or $null - parsed installed YYMM
          - LatestYYMM  : string or $null - the supplied manifest YYMM
          - Reason      : string - human-readable explanation

    .EXAMPLE
        Test-AzLocalUpdateAssessmentStale -CurrentVersion '12.2605.1003.210' -LatestYYMM '2606'
        # IsStale = $true (installed 2605 is behind latest 2606)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$CurrentVersion,

        [Parameter(Mandatory = $false)]
        [string]$LatestYYMM
    )

    $clusterYymm = $null
    if (-not [string]::IsNullOrWhiteSpace($CurrentVersion)) {
        foreach ($token in ($CurrentVersion -split '\.')) {
            if ($token -match '^[0-9]{4}$') {
                $yy = [int]$token.Substring(0, 2)
                $mm = [int]$token.Substring(2, 2)
                if ($yy -ge 20 -and $yy -le 99 -and $mm -ge 1 -and $mm -le 12) {
                    $clusterYymm = $token
                    break
                }
            }
        }
    }

    $result = [PSCustomObject]@{
        IsStale     = $false
        ClusterYYMM = $clusterYymm
        LatestYYMM  = if ([string]::IsNullOrWhiteSpace($LatestYYMM)) { $null } else { $LatestYYMM }
        Reason      = ''
    }

    if ([string]::IsNullOrWhiteSpace($CurrentVersion)) {
        $result.Reason = 'No installed version available; cannot assess staleness.'
        return $result
    }
    if ($null -eq $clusterYymm) {
        $result.Reason = "Installed version '$CurrentVersion' has no parseable YYMM token; cannot assess staleness."
        return $result
    }
    if ([string]::IsNullOrWhiteSpace($LatestYYMM) -or ($LatestYYMM -notmatch '^[0-9]{4}$')) {
        $result.Reason = 'No valid manifest LatestYYMM supplied; cannot assess staleness.'
        return $result
    }

    if ([int]$clusterYymm -lt [int]$LatestYYMM) {
        $result.IsStale = $true
        $result.Reason = "Installed YYMM $clusterYymm is behind the latest released YYMM $LatestYYMM - assessment may be stale (run Check for Updates)."
    }
    else {
        $result.Reason = "Installed YYMM $clusterYymm is current with (or ahead of) the latest released YYMM $LatestYYMM."
    }

    return $result
}
