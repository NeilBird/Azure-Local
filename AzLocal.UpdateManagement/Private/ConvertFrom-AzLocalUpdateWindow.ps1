function ConvertFrom-AzLocalUpdateWindow {
    <#
    .SYNOPSIS
        Parses an UpdateStartWindow tag value into structured window objects.
    .DESCRIPTION
        Parses the compact maintenance window syntax used in the UpdateStartWindow Azure resource tag
        into structured objects suitable for schedule evaluation and display.

        Syntax: <days>_<HH:MM>-<HH:MM>[;<days>_<HH:MM>-<HH:MM>]
        Days: Mon,Tue,Wed,Thu,Fri,Sat,Sun (ranges with -), * or Daily for all days
        Times: 24-hour UTC. Overnight wraps supported (22:00-06:00 = wraps to next day).
    .PARAMETER WindowString
        The UpdateStartWindow tag value to parse.
    .OUTPUTS
        PSCustomObject[] with Days (DayOfWeek[]), StartTime (TimeSpan), EndTime (TimeSpan), Overnight (bool)
    .EXAMPLE
        ConvertFrom-AzLocalUpdateWindow -WindowString "Sat-Sun_02:00-06:00"
    .NOTES
        Time zone / DST behaviour:
        - Window times are compared against the current time of the host running the
          automation (Get-Date), NOT against the cluster's local time zone. Run your
          pipeline on a host configured for UTC (recommended for fleet automation)
          so that tag values map unambiguously to wall-clock intervals.
        - Daylight Saving Time (DST) transitions on the host where the automation runs
          can cause a window to appear to shift by +/-1 hour on the transition day. A
          22:00-06:00 window evaluated on a host that "springs forward" will have one
          fewer hour of effective coverage that night, and "falls back" will have one
          extra hour. If strict wall-clock coverage matters, (a) use UTC on the
          automation host, and/or (b) set the window wide enough to absorb a 1-hour
          shift on transition days.
        - The parser does not interpret UTC offsets embedded in tag values; supply
          times in the host's effective time zone.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$WindowString
    )

    if ([string]::IsNullOrWhiteSpace($WindowString)) {
        throw "UpdateStartWindow value cannot be empty."
    }

    # Azure tag values max 256 chars
    if ($WindowString.Length -gt 256) {
        throw "UpdateStartWindow value exceeds Azure tag limit of 256 characters (length: $($WindowString.Length))."
    }

    $windows = @()
    $segments = $WindowString -split ';'

    foreach ($segment in $segments) {
        $segment = $segment.Trim()
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }

        # Parse <days>_<start>-<end>
        if ($segment -notmatch '^([^_]+)_(\d{2}:\d{2})-(\d{2}:\d{2})$') {
            throw "Invalid window segment syntax: '$segment'. Expected format: <days>_<HH:MM>-<HH:MM>"
        }

        $daysPart = $matches[1]
        $startStr = $matches[2]
        $endStr = $matches[3]

        # Parse time components (PS 5.1 compatible - avoid TryParse [ref] issues)
        $startTime = $null
        $endTime = $null
        try { $startTime = [TimeSpan]::Parse($startStr) }
        catch { throw "Invalid start time '$startStr' in segment '$segment'." }
        try { $endTime = [TimeSpan]::Parse($endStr) }
        catch { throw "Invalid end time '$endStr' in segment '$segment'." }

        # Parse days
        $resolvedDays = @()

        if ($daysPart -eq '*' -or $daysPart -ieq 'Daily') {
            $resolvedDays = @([DayOfWeek]::Monday, [DayOfWeek]::Tuesday, [DayOfWeek]::Wednesday,
                              [DayOfWeek]::Thursday, [DayOfWeek]::Friday, [DayOfWeek]::Saturday,
                              [DayOfWeek]::Sunday)
        }
        else {
            $daySpecs = $daysPart -split ','
            foreach ($spec in $daySpecs) {
                $spec = $spec.Trim()
                if ($spec -match '^(\w{3})-(\w{3})$') {
                    # Day range (e.g., Mon-Fri, Sat-Sun)
                    $rangeStart = $matches[1]
                    $rangeEnd = $matches[2]

                    # Find indices in ordered day list
                    $startIdx = -1; $endIdx = -1
                    for ($i = 0; $i -lt $script:DayAbbreviations.Count; $i++) {
                        if ($script:DayAbbreviations[$i] -ieq $rangeStart) { $startIdx = $i }
                        if ($script:DayAbbreviations[$i] -ieq $rangeEnd) { $endIdx = $i }
                    }
                    if ($startIdx -lt 0) { throw "Invalid day abbreviation '$rangeStart' in segment '$segment'. Valid: Mon,Tue,Wed,Thu,Fri,Sat,Sun" }
                    if ($endIdx -lt 0) { throw "Invalid day abbreviation '$rangeEnd' in segment '$segment'. Valid: Mon,Tue,Wed,Thu,Fri,Sat,Sun" }

                    # Handle wrap-around (e.g., Fri-Mon)
                    if ($startIdx -le $endIdx) {
                        for ($i = $startIdx; $i -le $endIdx; $i++) {
                            $resolvedDays += $script:DayMap[$script:DayAbbreviations[$i]]
                        }
                    }
                    else {
                        # Wrap: Fri-Mon = Fri,Sat,Sun,Mon
                        for ($i = $startIdx; $i -lt 7; $i++) {
                            $resolvedDays += $script:DayMap[$script:DayAbbreviations[$i]]
                        }
                        for ($i = 0; $i -le $endIdx; $i++) {
                            $resolvedDays += $script:DayMap[$script:DayAbbreviations[$i]]
                        }
                    }
                }
                elseif ($spec -match '^\w{3}$') {
                    # Single day
                    $matched = $false
                    foreach ($abbr in $script:DayAbbreviations) {
                        if ($abbr -ieq $spec) {
                            $resolvedDays += $script:DayMap[$abbr]
                            $matched = $true
                            break
                        }
                    }
                    if (-not $matched) { throw "Invalid day abbreviation '$spec' in segment '$segment'. Valid: Mon,Tue,Wed,Thu,Fri,Sat,Sun" }
                }
                else {
                    throw "Invalid day specification '$spec' in segment '$segment'. Use 3-letter abbreviations (Mon-Sun), ranges (Mon-Fri), or * / Daily."
                }
            }
        }

        $overnight = ($endTime -le $startTime)

        $windows += [PSCustomObject]@{
            Days      = @($resolvedDays | Select-Object -Unique)
            StartTime = $startTime
            EndTime   = $endTime
            Overnight = $overnight
            Raw       = $segment
        }
    }

    if ($windows.Count -eq 0) {
        throw "No valid window segments found in '$WindowString'."
    }

    return $windows
}
