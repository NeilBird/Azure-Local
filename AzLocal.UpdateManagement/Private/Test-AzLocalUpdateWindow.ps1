function Test-AzLocalUpdateWindow {
    <#
    .SYNOPSIS
        Tests whether a given time falls within a maintenance window.
    .DESCRIPTION
        Parses the UpdateStartWindow tag value and checks if the specified (or current) UTC time
        falls within any of the defined maintenance windows.
    .PARAMETER WindowString
        The UpdateStartWindow tag value to evaluate.
    .PARAMETER TestTime
        The UTC time to test against. Defaults to current UTC time.
    .OUTPUTS
        PSCustomObject with Allowed (bool), Reason (string), MatchedWindow (string or $null)
    .EXAMPLE
        Test-AzLocalUpdateWindow -WindowString "Sat-Sun_02:00-06:00"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowString,

        [Parameter(Mandatory = $false)]
        [datetime]$TestTime = (Get-Date).ToUniversalTime()
    )

    # Maintenance windows are evaluated in UTC. If caller accidentally supplies
    # a Local or Unspecified DateTime, convert to UTC to avoid silently picking
    # the wrong hour/day (cluster update runs in the wrong window).
    if ($TestTime.Kind -ne [System.DateTimeKind]::Utc) {
        Write-Verbose "Test-AzLocalUpdateWindow: TestTime kind '$($TestTime.Kind)' converted to UTC."
        $TestTime = $TestTime.ToUniversalTime()
    }

    $windows = ConvertFrom-AzLocalUpdateWindow -WindowString $WindowString

    $testDay = $TestTime.DayOfWeek
    $testTimeOfDay = $TestTime.TimeOfDay

    foreach ($window in $windows) {
        if ($window.Overnight) {
            # Overnight window: Check if we're in the evening portion (same day) or morning portion (next day)
            # Evening: testDay is in Days AND time >= start
            # Morning: previous day is in Days AND time < end
            $inEvening = ($testDay -in $window.Days) -and ($testTimeOfDay -ge $window.StartTime)

            # Calculate previous day
            $prevDay = if ($testDay -eq [DayOfWeek]::Sunday) { [DayOfWeek]::Saturday }
                       elseif ($testDay -eq [DayOfWeek]::Monday) { [DayOfWeek]::Sunday }
                       elseif ($testDay -eq [DayOfWeek]::Tuesday) { [DayOfWeek]::Monday }
                       elseif ($testDay -eq [DayOfWeek]::Wednesday) { [DayOfWeek]::Tuesday }
                       elseif ($testDay -eq [DayOfWeek]::Thursday) { [DayOfWeek]::Wednesday }
                       elseif ($testDay -eq [DayOfWeek]::Friday) { [DayOfWeek]::Thursday }
                       else { [DayOfWeek]::Friday }
            $inMorning = ($prevDay -in $window.Days) -and ($testTimeOfDay -lt $window.EndTime)

            if ($inEvening -or $inMorning) {
                return [PSCustomObject]@{
                    Allowed       = $true
                    Reason        = "Within maintenance window: $($window.Raw)"
                    MatchedWindow = $window.Raw
                }
            }
        }
        else {
            # Same-day window: testDay in Days AND time between start and end
            if (($testDay -in $window.Days) -and ($testTimeOfDay -ge $window.StartTime) -and ($testTimeOfDay -lt $window.EndTime)) {
                return [PSCustomObject]@{
                    Allowed       = $true
                    Reason        = "Within maintenance window: $($window.Raw)"
                    MatchedWindow = $window.Raw
                }
            }
        }
    }

    # No window matched
    $dayNames = ($windows | ForEach-Object { $_.Raw }) -join '; '
    return [PSCustomObject]@{
        Allowed       = $false
        Reason        = "Current time ($(($TestTime).ToString('yyyy-MM-dd HH:mm')) UTC, $testDay) is outside all maintenance windows: $dayNames"
        MatchedWindow = $null
    }
}
