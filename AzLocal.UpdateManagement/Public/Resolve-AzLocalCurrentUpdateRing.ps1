function Resolve-AzLocalCurrentUpdateRing {
    <#
    .SYNOPSIS
        Resolves which UpdateRing tag value(s) are eligible to update
        right now, given an apply-updates-schedule.yml config object and
        a UTC moment.

    .DESCRIPTION
        Implements the v0.7.69 ring-aware scheduling design:

        1. Compute (CycleWeek, DayOfWeek) for the supplied UTC moment,
           anchored at `cycleAnchorISOWeek / cycleAnchorYear`.
        2. For each row in `Schedule`, evaluate whether its
           `weeksInCycle` AND `daysOfWeek` selectors both match (CycleWeek,
           DayOfWeek).
        3. Union the `rings` columns of every matching row, dedupe
           (case-insensitively), and return the joined ';'-list.

        If zero rows match, returns a decision with Rings=@() and a
        human-readable Reason. Step.5 logs it and exits 0 (no error).

        Wildcards / ranges accepted in both selectors:
          weeksInCycle  '*' | '1' | '1-4' | '1,3,5' | '1-3,5,7'
          daysOfWeek    '*' | 'Mon-Fri' | 'Mon,Wed,Fri' | numeric 0-6 form
                        (0=Sun .. 6=Sat). 'Sun', 'Mon', 'Tue', 'Wed',
                        'Thu', 'Fri', 'Sat' (case-insensitive) all work.

        Cycle math uses ISO-8601 week numbers (Monday-start, week 1 is
        the week containing the first Thursday of the year). The
        algorithm is portable - no dependency on
        System.Globalization.ISOWeek (which is .NET Core / PS 7+ only).

    .PARAMETER Schedule
        The parsed config object from Get-AzLocalApplyUpdatesScheduleConfig
        (or the lower-level ConvertFrom-AzLocalScheduleYaml).

    .PARAMETER Now
        The UTC moment to resolve. Default: [DateTime]::UtcNow.

    .OUTPUTS
        [PSCustomObject] with:
          Rings                       [string[]] - deduped, ordered as-encountered
          UpdateRingValue             [string]   - ';'-joined for direct hand-off
          CycleWeek                   [int]      - 1..CycleWeeks
          DayOfWeek                   [int]      - 0=Sun .. 6=Sat
          DayOfWeekName               [string]   - 'Sun' .. 'Sat'
          Reason                      [string]   - human-readable summary
          MatchedRows                 [object[]] - the schedule rows that matched
          NowUtc                      [datetime] - the moment used
          AllowedUpdateVersions       [string[]] - resolved allow-list of
                                                  Azure Local solution-update
                                                  names / version strings (schema
                                                  v2 'allowedUpdateVersions'
                                                  field); empty array when the
                                                  field is absent everywhere
                                                  (meaning "no constraint - use
                                                  cmdlet default of latest Ready
                                                  update").
          AllowedUpdateVersionsValue  [string]   - ';'-joined for env-var bridge
                                                  in CI / CD pipelines; '' when
                                                  AllowedUpdateVersions is empty.
          AllowedUpdateVersionsSource [string]   - 'row' | 'top-level' | 'none'
                                                  - explains where the allow-list
                                                  came from for audit / logs.

    .EXAMPLE
        $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path .\.github\apply-updates-schedule.yml
        $decision = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg
        if (-not $decision.Rings) {
            Write-Log "No UpdateRing configured for $($decision.NowUtc.ToString('o')). $($decision.Reason)" -Level Info
            exit 0
        }
        Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue $decision.UpdateRingValue
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Schedule,

        [Parameter(Mandatory = $false)]
        [datetime]$Now = [datetime]::UtcNow
    )

    # ---- ISO-8601 week (year, week) for any DateTime ------------------
    # Portable across PS 5.1 / PS 7. Uses the canonical
    # "Thursday-of-the-week" trick: a date's ISO week number is the
    # week containing the Thursday that falls in the same week.
    function Get-AzLocalISOWeek([datetime]$d) {
        $dayOfWeekIso = ((($d.DayOfWeek.value__ + 6) % 7))     # Mon=0..Sun=6
        $thursday = $d.Date.AddDays(3 - $dayOfWeekIso)
        $isoYear  = $thursday.Year
        $jan4     = [datetime]::new($isoYear, 1, 4, 0, 0, 0, [DateTimeKind]::Utc)
        $jan4DowIso = ((($jan4.DayOfWeek.value__ + 6) % 7))
        $week1Mon = $jan4.AddDays(-1 * $jan4DowIso)
        $weekNum  = [int]([math]::Floor(($thursday - $week1Mon).TotalDays / 7)) + 1
        [pscustomobject]@{ Year = $isoYear; Week = $weekNum }
    }

    # Build an absolute ordinal: years are at most ~53 ISO-weeks long, so
    # ordinal = year * 53 + week is monotonic enough for differencing
    # *across* a few cycles. For correctness across multi-year cycles we
    # actually sum weeks between (anchorYear, anchorWeek) and (nowYear,
    # nowWeek) directly via week-count - simpler and exact.
    function Get-AzLocalWeeksBetween([int]$y1, [int]$w1, [int]$y2, [int]$w2) {
        # Convert each (Year, Week) to the Monday of its ISO week and
        # subtract calendar dates. Works for any year range.
        function MondayOfIsoWeek([int]$y, [int]$w) {
            $jan4 = [datetime]::new($y, 1, 4, 0, 0, 0, [DateTimeKind]::Utc)
            $jan4DowIso = ((($jan4.DayOfWeek.value__ + 6) % 7))
            $week1Mon = $jan4.AddDays(-1 * $jan4DowIso)
            return $week1Mon.AddDays(7 * ($w - 1))
        }
        $m1 = MondayOfIsoWeek $y1 $w1
        $m2 = MondayOfIsoWeek $y2 $w2
        return [int]([math]::Round(($m2 - $m1).TotalDays / 7))
    }

    # ---- weeksInCycle / daysOfWeek expression matchers --------------
    function Expand-AzLocalCyclesExpression([string]$expr, [int]$max) {
        # '*' = entire 1..$max range; otherwise comma-separated ranges/numbers
        if ($expr -eq '*') { return 1..$max }
        $out = New-Object System.Collections.Generic.HashSet[int]
        foreach ($tok in ($expr -split ',')) {
            $t = $tok.Trim()
            if ($t -match '^(\d+)-(\d+)$') {
                $lo = [int]$Matches[1]; $hi = [int]$Matches[2]
                if ($lo -lt 1 -or $hi -gt $max -or $lo -gt $hi) {
                    throw "Resolve-AzLocalCurrentUpdateRing: weeksInCycle range '$t' is out of 1..$max."
                }
                for ($n = $lo; $n -le $hi; $n++) { [void]$out.Add($n) }
            }
            elseif ($t -match '^\d+$') {
                $n = [int]$t
                if ($n -lt 1 -or $n -gt $max) {
                    throw "Resolve-AzLocalCurrentUpdateRing: weeksInCycle value '$t' is out of 1..$max."
                }
                [void]$out.Add($n)
            }
            else {
                throw "Resolve-AzLocalCurrentUpdateRing: weeksInCycle token '$t' must be '*', N, N-M, or a comma list of those."
            }
        }
        return @($out)
    }

    $dayNameToNum = @{
        'sun'=0; 'sunday'=0
        'mon'=1; 'monday'=1
        'tue'=2; 'tuesday'=2
        'wed'=3; 'wednesday'=3
        'thu'=4; 'thursday'=4
        'fri'=5; 'friday'=5
        'sat'=6; 'saturday'=6
    }

    function Resolve-AzLocalDayToken([string]$tok) {
        $t = $tok.Trim().ToLowerInvariant()
        if ($t -match '^\d+$') {
            $n = [int]$t
            if ($n -lt 0 -or $n -gt 6) {
                throw "Resolve-AzLocalCurrentUpdateRing: daysOfWeek numeric '$tok' must be 0-6 (Sun=0..Sat=6)."
            }
            return $n
        }
        if ($dayNameToNum.ContainsKey($t)) { return $dayNameToNum[$t] }
        throw "Resolve-AzLocalCurrentUpdateRing: daysOfWeek token '$tok' is not recognised (expected 0-6 or Sun/Mon/.../Sat)."
    }

    function Expand-AzLocalDaysExpression([string]$expr) {
        if ($expr -eq '*') { return 0..6 }
        $out = New-Object System.Collections.Generic.HashSet[int]
        foreach ($tok in ($expr -split ',')) {
            $t = $tok.Trim()
            if ($t -match '^(.+?)-(.+)$') {
                $lo = Resolve-AzLocalDayToken $Matches[1]
                $hi = Resolve-AzLocalDayToken $Matches[2]
                if ($lo -le $hi) {
                    for ($n = $lo; $n -le $hi; $n++) { [void]$out.Add($n) }
                }
                else {
                    # Wrap-around (e.g. 'Fri-Mon' = 5,6,0,1)
                    for ($n = $lo; $n -le 6; $n++)   { [void]$out.Add($n) }
                    for ($n = 0;   $n -le $hi; $n++) { [void]$out.Add($n) }
                }
            }
            else {
                [void]$out.Add((Resolve-AzLocalDayToken $t))
            }
        }
        return @($out)
    }

    # ---- Compute (CycleWeek, DayOfWeek) for $Now in UTC -------------
    $nowUtc = $Now.ToUniversalTime()
    $iso    = Get-AzLocalISOWeek $nowUtc
    $cycleWeeks = [int]$Schedule.CycleWeeks
    $anchorYr   = [int]$Schedule.CycleAnchorYear
    $anchorWk   = [int]$Schedule.CycleAnchorISOWeek

    $delta = Get-AzLocalWeeksBetween $anchorYr $anchorWk $iso.Year $iso.Week
    # In PowerShell, ((-1) % 7) = -1, so guard with (((x % m) + m) % m).
    $cycleWeek = ((($delta % $cycleWeeks) + $cycleWeeks) % $cycleWeeks) + 1

    $dowNum  = [int]$nowUtc.DayOfWeek.value__   # 0=Sun..6=Sat
    $dowName = ([System.Globalization.CultureInfo]::InvariantCulture.DateTimeFormat.GetAbbreviatedDayName($nowUtc.DayOfWeek))

    # ---- Walk schedule, union matching rows -------------------------
    $rings = New-Object System.Collections.Generic.List[string]
    $seen  = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $matched = New-Object System.Collections.Generic.List[object]

    foreach ($row in @($Schedule.Schedule)) {
        $weeks = Expand-AzLocalCyclesExpression $row.weeksInCycle $cycleWeeks
        if (-not ($weeks -contains $cycleWeek)) { continue }
        $days = Expand-AzLocalDaysExpression $row.daysOfWeek
        if (-not ($days -contains $dowNum))     { continue }
        $matched.Add($row) | Out-Null
        foreach ($r in ($row.rings -split ';')) {
            $tr = $r.Trim()
            if ($tr -and $seen.Add($tr)) { $rings.Add($tr) | Out-Null }
        }
    }

    # ---- Resolve AllowedUpdateVersions (schema v2) ------------------
    # Precedence:
    #   1. If ANY matched row has its own allowedUpdateVersions, take
    #      the UNION across those rows (rows WITHOUT the field are
    #      treated as "no opinion" - they do not collapse the allow-list
    #      to empty). Source = 'row'.
    #   2. Else if top-level allowedUpdateVersions exists, use it.
    #      Source = 'top-level'.
    #   3. Else empty array + Source = 'none' = "no constraint".
    # The validator pre-parsed both into typed arrays so this resolver
    # does not re-split.
    #
    # 'Latest' sentinel (v0.7.89): If the effective allow-list contains
    # the reserved sentinel 'Latest' (case-insensitive), the result is
    # treated as "no constraint" - AllowedUpdateVersions is emitted as
    # an empty array and the picker / pipeline falls back to the
    # historic "install latest Ready update" behaviour. The Source field
    # still reflects the origin (row / top-level) so audit logs explain
    # WHERE the 'Latest' decision came from. Cross-row UNION semantics:
    # if any matching row contributes 'Latest', the UNION is 'Latest'
    # (the explicit allow-lists on sibling rows are ignored for that
    # day). This is the only way to combine 'Latest' with explicit
    # versions across rows; mixing them WITHIN a single field is
    # rejected at validation.
    $allowList     = New-Object System.Collections.Generic.List[string]
    $allowSeen     = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $allowSource   = 'none'
    $rowsWithAllow = @($matched | Where-Object {
        $_.PSObject.Properties.Match('AllowedUpdateVersionsParsed').Count -gt 0 -and
        $null -ne $_.AllowedUpdateVersionsParsed -and
        @($_.AllowedUpdateVersionsParsed).Count -gt 0
    })
    if ($rowsWithAllow.Count -gt 0) {
        $allowSource = 'row'
        foreach ($r in $rowsWithAllow) {
            foreach ($v in @($r.AllowedUpdateVersionsParsed)) {
                $sv = [string]$v
                if ($sv -and $allowSeen.Add($sv)) { $allowList.Add($sv) | Out-Null }
            }
        }
    }
    elseif ($Schedule.PSObject.Properties.Match('AllowedUpdateVersions').Count -gt 0 -and
            $null -ne $Schedule.AllowedUpdateVersions -and
            @($Schedule.AllowedUpdateVersions).Count -gt 0) {
        $allowSource = 'top-level'
        foreach ($v in @($Schedule.AllowedUpdateVersions)) {
            $sv = [string]$v
            if ($sv -and $allowSeen.Add($sv)) { $allowList.Add($sv) | Out-Null }
        }
    }
    # Detect the 'Latest' sentinel in the resolved UNION. When present,
    # collapse the effective allow-list to empty (= no constraint). Use
    # ordinal-case-insensitive compare (the validator already
    # canonicalised tokens to 'Latest', but be defensive in case a
    # caller constructs the schedule object directly).
    $hasLatestSentinel = $false
    foreach ($v in $allowList) {
        if ([string]::Equals($v, 'Latest', [System.StringComparison]::OrdinalIgnoreCase)) {
            $hasLatestSentinel = $true
            break
        }
    }
    if ($hasLatestSentinel) {
        $allowArray = @()
        $allowValue = ''
    }
    else {
        $allowArray = $allowList.ToArray()
        $allowValue = ($allowArray -join ';')
    }

    # ---- Resolve prepare-first policy (schema v3) ------------------
    # Matching row overrides take precedence over the top-level default.
    # Multiple matching rows must agree so one firing has one deterministic
    # state-machine policy.
    $rowPrepareValues = @($matched | ForEach-Object {
        if ($_.PSObject.Properties.Match('PrepareOnlyFirstParsed').Count -gt 0 -and $null -ne $_.PrepareOnlyFirstParsed) {
            [bool]$_.PrepareOnlyFirstParsed
        }
    } | Select-Object -Unique)
    if ($rowPrepareValues.Count -gt 1) {
        throw "Resolve-AzLocalCurrentUpdateRing: matching schedule rows specify conflicting prepareOnlyFirst values: $($rowPrepareValues -join ', '). Use one value for all rows that can match the same firing."
    }
    if ($rowPrepareValues.Count -eq 1) {
        $prepareOnlyFirst = [bool]$rowPrepareValues[0]
        $prepareOnlyFirstSource = 'row'
    }
    elseif ($Schedule.PSObject.Properties.Match('PrepareOnlyFirst').Count -gt 0) {
        $prepareOnlyFirst = [bool]$Schedule.PrepareOnlyFirst
        $prepareOnlyFirstSource = 'top-level'
    }
    else {
        $prepareOnlyFirst = $false
        $prepareOnlyFirstSource = 'default'
    }

    $rowPrepareWindowValues = @($matched | ForEach-Object {
        if ($_.PSObject.Properties.Match('AllowPrepareOnlyOutsideOfUpdateStartWindowParsed').Count -gt 0 -and $null -ne $_.AllowPrepareOnlyOutsideOfUpdateStartWindowParsed) {
            [bool]$_.AllowPrepareOnlyOutsideOfUpdateStartWindowParsed
        }
    } | Select-Object -Unique)
    if ($rowPrepareWindowValues.Count -gt 1) {
        throw "Resolve-AzLocalCurrentUpdateRing: matching schedule rows specify conflicting allowPrepareOnlyOutsideOfUpdateStartWindow values: $($rowPrepareWindowValues -join ', '). Use one value for all rows that can match the same firing."
    }
    if ($rowPrepareWindowValues.Count -eq 1) {
        $allowPrepareOnlyOutsideOfUpdateStartWindow = [bool]$rowPrepareWindowValues[0]
        $allowPrepareOnlyOutsideOfUpdateStartWindowSource = 'row'
    }
    elseif ($Schedule.PSObject.Properties.Match('AllowPrepareOnlyOutsideOfUpdateStartWindow').Count -gt 0) {
        $allowPrepareOnlyOutsideOfUpdateStartWindow = [bool]$Schedule.AllowPrepareOnlyOutsideOfUpdateStartWindow
        $allowPrepareOnlyOutsideOfUpdateStartWindowSource = 'top-level'
    }
    else {
        $allowPrepareOnlyOutsideOfUpdateStartWindow = $true
        $allowPrepareOnlyOutsideOfUpdateStartWindowSource = 'default'
    }

    $reason = if ($matched.Count -eq 0) {
        "No schedule row matches (cycleWeek=$cycleWeek of $cycleWeeks, dayOfWeek=$dowName)."
    } else {
        $base = "Matched $($matched.Count) schedule row(s) for cycleWeek=$cycleWeek of $cycleWeeks, dayOfWeek=$dowName. Resolved UpdateRing(s): $($rings -join ', ')."
        if ($allowSource -ne 'none') {
            if ($hasLatestSentinel) {
                $base + " AllowedUpdateVersions ($allowSource): Latest (no constraint - install latest Ready update)."
            } else {
                $base + " AllowedUpdateVersions ($allowSource): $($allowArray -join ', ')."
            }
        } else {
            $base
        }
    }

    return [pscustomobject]@{
        Rings                       = $rings.ToArray()
        UpdateRingValue             = ($rings -join ';')
        CycleWeek                   = $cycleWeek
        DayOfWeek                   = $dowNum
        DayOfWeekName               = $dowName
        Reason                      = $reason
        MatchedRows                 = $matched.ToArray()
        NowUtc                      = $nowUtc
        AllowedUpdateVersions       = $allowArray
        AllowedUpdateVersionsValue  = $allowValue
        AllowedUpdateVersionsSource = $allowSource
        PrepareOnlyFirst             = $prepareOnlyFirst
        PrepareOnlyFirstSource       = $prepareOnlyFirstSource
        AllowPrepareOnlyOutsideOfUpdateStartWindow       = $allowPrepareOnlyOutsideOfUpdateStartWindow
        AllowPrepareOnlyOutsideOfUpdateStartWindowSource = $allowPrepareOnlyOutsideOfUpdateStartWindowSource
    }
}
