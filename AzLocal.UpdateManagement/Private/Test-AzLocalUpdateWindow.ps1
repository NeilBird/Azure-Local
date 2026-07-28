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
    .PARAMETER AllowBeforeMinutes
        Minutes before the configured window opens that an update attempt is
        allowed to start. Default 0.
    .PARAMETER AllowAfterMinutes
        Minutes after the configured window closes that an update attempt is
        allowed to start. Default 0.
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
        [datetime]$TestTime = (Get-Date).ToUniversalTime(),

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$AllowBeforeMinutes = 0,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$AllowAfterMinutes = 0
    )

    # Maintenance windows are evaluated in UTC. If caller accidentally supplies
    # a Local or Unspecified DateTime, convert to UTC to avoid silently picking
    # the wrong hour/day (cluster update runs in the wrong window).
    if ($TestTime.Kind -ne [System.DateTimeKind]::Utc) {
        Write-Verbose "Test-AzLocalUpdateWindow: TestTime kind '$($TestTime.Kind)' converted to UTC."
        $TestTime = $TestTime.ToUniversalTime()
    }

    $windows = ConvertFrom-AzLocalUpdateWindow -WindowString $WindowString

    foreach ($window in $windows) {
        # Evaluate the previous, current, and next UTC dates as possible window
        # opening dates. The next date is required when a before allowance crosses
        # midnight; the previous date covers overnight and after allowances.
        foreach ($openingDate in @($TestTime.Date.AddDays(-1), $TestTime.Date, $TestTime.Date.AddDays(1))) {
            if ($openingDate.DayOfWeek -notin $window.Days) {
                continue
            }

            $windowStart = $openingDate.Add($window.StartTime)
            $windowEnd = if ($window.Overnight) {
                $openingDate.AddDays(1).Add($window.EndTime)
            }
            else {
                $openingDate.Add($window.EndTime)
            }
            $effectiveStart = $windowStart.AddMinutes(-$AllowBeforeMinutes)
            $effectiveEnd = $windowEnd.AddMinutes($AllowAfterMinutes)

            if ($TestTime -ge $effectiveStart -and $TestTime -lt $effectiveEnd) {
                $allowanceDetail = if ($AllowBeforeMinutes -gt 0 -or $AllowAfterMinutes -gt 0) {
                    " (allowance: $AllowBeforeMinutes minute(s) before, $AllowAfterMinutes minute(s) after)"
                }
                else {
                    ''
                }
                return [PSCustomObject]@{
                    Allowed       = $true
                    Reason        = "Within maintenance window: $($window.Raw)$allowanceDetail"
                    MatchedWindow = $window.Raw
                }
            }
        }
    }

    # No window matched
    $dayNames = ($windows | ForEach-Object { $_.Raw }) -join '; '
    return [PSCustomObject]@{
        Allowed       = $false
        Reason        = "Current time ($(($TestTime).ToString('yyyy-MM-dd HH:mm')) UTC, $($TestTime.DayOfWeek)) is outside all maintenance windows: $dayNames (allowance: $AllowBeforeMinutes minute(s) before, $AllowAfterMinutes minute(s) after)"
        MatchedWindow = $null
    }
}
