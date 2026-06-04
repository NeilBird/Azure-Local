function Test-AzLocalUpdateScheduleAllowed {
    <#
    .SYNOPSIS
        Master gate that evaluates whether an update is allowed based on UpdateStartWindow and UpdateExclusionsWindow tags.
    .DESCRIPTION
        Combines maintenance window and exclusion period checks to determine if an update
        should proceed. Exclusions take priority over windows (a blackout period blocks
        updates even if they fall within a maintenance window).

        If neither tag is present/provided, updates are allowed (no restrictions).

        Note: the UpdateExcluded operator-override tag is a SEPARATE hard gate evaluated
        upstream in Start-AzLocalClusterUpdate; this function only handles the schedule.
    .PARAMETER UpdateStartWindow
        The UpdateStartWindow tag value (maintenance schedule). If empty/null, no window restriction.
    .PARAMETER UpdateExclusionsWindow
        The UpdateExclusionsWindow tag value (blackout periods). If empty/null, no exclusion
        restriction. Renamed from 'UpdateExclusions' in v0.7.90 (breaking change).
    .PARAMETER TestTime
        The UTC time to test against. Defaults to current UTC time.
    .OUTPUTS
        PSCustomObject with Allowed (bool), Reason (string), WindowOpen (bool or $null),
        ExclusionActive (bool or $null), Details (string)
    .EXAMPLE
        Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow "Sat-Sun_02:00-06:00" -UpdateExclusionsWindow "2026-12-20/2027-01-03"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$UpdateStartWindow,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$UpdateExclusionsWindow,

        [Parameter(Mandatory = $false)]
        [datetime]$TestTime = (Get-Date).ToUniversalTime()
    )

    # Schedule evaluation is UTC-based. Normalise Local/Unspecified inputs to
    # UTC so callers don't silently hit the wrong maintenance window due to TZ.
    if ($TestTime.Kind -ne [System.DateTimeKind]::Utc) {
        Write-Verbose "Test-AzLocalUpdateScheduleAllowed: TestTime kind '$($TestTime.Kind)' converted to UTC."
        $TestTime = $TestTime.ToUniversalTime()
    }

    $windowOpen = $null
    $exclusionActive = $null
    $details = @()

    # Check exclusions first (they take priority)
    if (-not [string]::IsNullOrWhiteSpace($UpdateExclusionsWindow)) {
        try {
            $exclusionResult = Test-AzLocalUpdateExclusion -ExclusionString $UpdateExclusionsWindow -TestDate $TestTime.Date
            $exclusionActive = $exclusionResult.Excluded
            if ($exclusionActive) {
                return [PSCustomObject]@{
                    Allowed          = $false
                    Reason           = "Blocked by exclusion period"
                    WindowOpen       = $null
                    ExclusionActive  = $true
                    Details          = $exclusionResult.Reason
                }
            }
            $details += "No active exclusion"
        }
        catch {
            # Fail-closed: re-throw so the caller (Start-AzLocalClusterUpdate)
            # can block the update unless -Force is specified. Swallowing this
            # would allow a malformed UpdateExclusionsWindow tag to silently bypass
            # blackout periods.
            throw "Failed to parse UpdateExclusionsWindow tag value '$UpdateExclusionsWindow': $($_.Exception.Message)"
        }
    }

    # Check maintenance window
    if (-not [string]::IsNullOrWhiteSpace($UpdateStartWindow)) {
        try {
            $windowResult = Test-AzLocalUpdateWindow -WindowString $UpdateStartWindow -TestTime $TestTime
            $windowOpen = $windowResult.Allowed
            if (-not $windowOpen) {
                return [PSCustomObject]@{
                    Allowed          = $false
                    Reason           = "Outside maintenance window"
                    WindowOpen       = $false
                    ExclusionActive  = $false
                    Details          = $windowResult.Reason
                }
            }
            $details += "Within window: $($windowResult.MatchedWindow)"
        }
        catch {
            # Fail-closed: re-throw so the caller (Start-AzLocalClusterUpdate)
            # can block the update unless -Force is specified. Swallowing this
            # would allow a malformed UpdateStartWindow tag to silently bypass the
            # operator's configured maintenance window.
            throw "Failed to parse UpdateStartWindow tag value '$UpdateStartWindow': $($_.Exception.Message)"
        }
    }

    # All checks passed (or no tags defined)
    $reason = if ([string]::IsNullOrWhiteSpace($UpdateStartWindow) -and [string]::IsNullOrWhiteSpace($UpdateExclusionsWindow)) {
        "No schedule restrictions defined"
    } else {
        "Update allowed by schedule"
    }

    return [PSCustomObject]@{
        Allowed          = $true
        Reason           = $reason
        WindowOpen       = $windowOpen
        ExclusionActive  = $exclusionActive
        # $exclusionActive is $null when no UpdateExclusionsWindow tag was evaluated, or
        # $false when the tag was evaluated and no exclusion matched. The $true case
        # returns early above.
        Details          = $details -join '; '
    }
}
