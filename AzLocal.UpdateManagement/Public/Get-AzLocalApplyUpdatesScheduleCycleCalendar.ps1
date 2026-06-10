function Get-AzLocalApplyUpdatesScheduleCycleCalendar {
    <#
    .SYNOPSIS
        Projects an apply-updates-schedule.yml forward one full cycle
        (or any -Days window) and renders a human-readable per-day
        calendar of which UpdateRing(s) are eligible on each UTC day.

    .DESCRIPTION
        Step.3's "what is the upcoming cycle going to do?" advisor.
        Built on top of Get-AzLocalApplyUpdatesScheduleNextFirings so all
        ISO-8601 week math, cycle-anchor wrap arithmetic, UNION semantics
        across overlapping schedule rows, and AllowedUpdateVersions
        resolution flow through Resolve-AzLocalCurrentUpdateRing - no
        duplicate week-arithmetic code paths to drift.

        Works correctly for cycles of any length (4, 8, 13, 26, 52
        weeks) and across year boundaries (ISO weeks 52 / 53 / W1).

        Default projection horizon is one full cycle (CycleWeeks * 7
        days) starting today, which means an operator currently in week
        8 of an 8-week cycle sees week 8 (today + a few days), then the
        full new week-1-through-week-7 of the next cycle, exposing
        exactly when each ring will fire next.

        The IsCycleWrap flag and CycleWeekLabel ("X of N (cycle wraps)")
        make the moment of rotation back to the start of the cycle
        unambiguous in both the object output and the markdown table.

    .PARAMETER Schedule
        Parsed config object from Get-AzLocalApplyUpdatesScheduleConfig.

    .PARAMETER StartDate
        First UTC day to project. Default: today (UTC).

    .PARAMETER Days
        Number of consecutive UTC days to project. Default: one full
        cycle ($Schedule.CycleWeeks * 7). Range: 1..3650 so operators
        can ask for multi-cycle views.

    .PARAMETER AsMarkdown
        Switch. When set, returns a single [string] containing a fully
        rendered markdown report (heading + intro + calendar table, plus
        the per-ring projection section when -IncludePerRingSummary is
        also supplied). When not set, returns the per-day [PSCustomObject]
        pipeline for programmatic consumers.

    .PARAMETER IncludePerRingSummary
        Switch. When set together with -AsMarkdown, also emits a
        "### Per-ring projection" section that lists each ring referenced
        by the schedule with its next eligible UTC date and the full set
        of eligible dates within the projection horizon. Helpful for
        operators answering "when will my Prod ring fire next?".

    .PARAMETER ClusterRingCounts
        Optional hashtable mapping ring name (case-insensitive) to the
        count of clusters currently tagged with that UpdateRing. When
        supplied AND -AsMarkdown is set, the per-day calendar table and
        the per-ring projection table both gain a "Clusters in ring(s)"
        / "Cluster count" column so operators can see at a glance how
        many clusters each upcoming firing will touch. Pure cmdlet -
        callers (e.g. Test-AzLocalApplyUpdatesScheduleCoverage / Step.3
        yml) build this dictionary from their cluster CSV or live tag
        scan; the cmdlet itself does no Azure or CSV I/O.

    .PARAMETER CronFiringsByDate
        Optional hashtable mapping 'yyyy-MM-dd' (UTC) date strings to a
        sorted, deduplicated [string[]] of 'HH:mm' UTC firing times that
        the Step.6 apply-updates pipeline cron(s) will produce on that
        date. When supplied AND -AsMarkdown is set, the per-day calendar
        table gains a centered "Ring CRON Start Time (Step 6 pipeline)"
        column immediately after "Date (UTC)". The cell renders up to 2
        firing times verbatim; any additional firings beyond the first 2
        are summarised as "(+N)" (e.g. "02:00, 04:00 (+1)" when there
        are 3 firings). Days with no entry in the hashtable, no firings
        for the day, or that are "dead days" (no eligible rings) render
        as "_(none)_". Pure render-time - this cmdlet does no YAML I/O;
        callers (e.g. Export-AzLocalApplyUpdatesScheduleAudit) build the
        dictionary from `Read-AzLocalApplyUpdatesYamlCrons` +
        `ConvertFrom-AzLocalCronExpression`.

    .PARAMETER WindowMatchByRingAndDate
        Optional nested hashtable indicating, per (UpdateRing, UTC date)
        pair, what fraction of the clusters tagged with that ring have
        an `UpdateStartWindow` tag that covers AT LEAST ONE Step.6 cron
        firing on that date. Shape:

            @{
                'Cdn'  = @{
                    '2026-06-15' = @{ Matching = 29; Total = 30 }
                    '2026-06-22' = @{ Matching = 28; Total = 30 }
                }
                'Prod' = @{
                    '2026-06-15' = @{ Matching =  1; Total = 40 }
                }
            }

        Ring keys are case-insensitive; the inner per-date hashtable
        keys are 'yyyy-MM-dd' UTC; the leaf hashtables MUST include
        integer-coercible 'Matching' and 'Total' values. 'Pct' is
        computed when not supplied (Matching/Total, with Total=0 short-
        circuiting to a "(0 clusters)" cell). When supplied AND
        -AsMarkdown is set, the per-day calendar table gains a "Tag
        Start Window Match (>=95%)" column immediately after "Eligible
        rings". When multiple rings are eligible on a single date, the
        cell shows a per-ring breakdown: ``Cdn``: True 29/30 (97%);
        ``Prod``: False 1/40 (3%). "True" iff Matching/Total >= 0.95.
        Dead-day rows and rings missing from the hashtable render as
        "_(n/a)_". Same pure-render contract as -CronFiringsByDate;
        callers compute the dictionary from the cluster CSV they already
        load and the cron firings already parsed for -CronFiringsByDate.

    .OUTPUTS
        Default: [PSCustomObject[]], one per UTC day, with:
          DateUtc                     [datetime] - midnight UTC
          DayOfWeekName               [string]   - 'Sun'..'Sat'
          CycleWeek                   [int]      - 1..CycleWeeks
          CycleWeeksTotal             [int]      - Schedule.CycleWeeks
          CycleWeekLabel              [string]   - 'X of N' (+ ' (cycle wraps)' on the wrap day)
          IsCycleWrap                 [bool]     - true on day-of-week-Monday when CycleWeek rolls back to 1
          Rings                       [string[]] - UNION of all matching rows
          UpdateRingValue             [string]   - ';'-joined for display
          AllowedUpdateVersions       [string[]] - effective allow-list ([] = no constraint / Latest)
          AllowedUpdateVersionsValue  [string]   - ';'-joined for display
          AllowedUpdateVersionsSource [string]   - 'row' | 'top-level' | 'none'
          MatchedRowCount             [int]
          IsDeadDay                   [bool]     - true when Rings is empty
          Reason                      [string]   - Resolve-AzLocalCurrentUpdateRing reason

        With -AsMarkdown: [string] containing the rendered markdown
        report.

    .EXAMPLE
        $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path .\.github\apply-updates-schedule.yml
        Get-AzLocalApplyUpdatesScheduleCycleCalendar -Schedule $cfg | Format-Table -AutoSize

    .EXAMPLE
        # Render the markdown for a pipeline step summary (the Step.3 use case)
        $md = Get-AzLocalApplyUpdatesScheduleCycleCalendar -Schedule $cfg -AsMarkdown -IncludePerRingSummary
        $md | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append

    .EXAMPLE
        # Three full cycles ahead for a 13-week quarterly rotation
        Get-AzLocalApplyUpdatesScheduleCycleCalendar -Schedule $cfg -Days ($cfg.CycleWeeks * 7 * 3) |
            Where-Object IsDeadDay | Format-Table DateUtc, DayOfWeekName, CycleWeek
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]], [string])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Schedule,

        [Parameter(Mandatory = $false)]
        [datetime]$StartDate = ([datetime]::UtcNow.Date),

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 3650)]
        [int]$Days = 0,

        [Parameter(Mandatory = $false)]
        [switch]$AsMarkdown,

        [Parameter(Mandatory = $false)]
        [switch]$IncludePerRingSummary,

        [Parameter(Mandatory = $false)]
        [hashtable]$ClusterRingCounts,

        [Parameter(Mandatory = $false)]
        [hashtable]$CronFiringsByDate,

        [Parameter(Mandatory = $false)]
        [hashtable]$WindowMatchByRingAndDate
    )

    Set-StrictMode -Version Latest

    $cycleWeeks = [int]$Schedule.CycleWeeks
    if ($cycleWeeks -lt 1) {
        throw "Get-AzLocalApplyUpdatesScheduleCycleCalendar: Schedule.CycleWeeks must be >= 1. Got: $cycleWeeks."
    }
    if ($Days -eq 0) { $Days = $cycleWeeks * 7 }

    $start = [datetime]::SpecifyKind($StartDate.Date, [DateTimeKind]::Utc)

    # Re-use the existing day-iterator so we inherit all of
    # Resolve-AzLocalCurrentUpdateRing's correctness (ISO week math,
    # anchor wrap across years, AllowedUpdateVersions resolution).
    # Get-AzLocalApplyUpdatesScheduleNextFirings caps -Days at 366; for
    # longer horizons we iterate in chunks.
    $rawRows = New-Object System.Collections.Generic.List[psobject]
    $cursor  = $start
    $remain  = $Days
    while ($remain -gt 0) {
        $chunk = if ($remain -gt 366) { 366 } else { $remain }
        $batch = Get-AzLocalApplyUpdatesScheduleNextFirings -Schedule $Schedule -StartDate $cursor -Days $chunk
        foreach ($r in @($batch)) { [void]$rawRows.Add($r) }
        $cursor = $cursor.AddDays($chunk)
        $remain -= $chunk
    }

    # Enrich each day with CycleWeekLabel, IsCycleWrap, IsDeadDay, and
    # the allow-list trio that NextFirings does not project today. For
    # the allow-list we call Resolve-AzLocalCurrentUpdateRing once per
    # day (NextFirings already does this internally; calling again is
    # cheap and keeps the enrichment local to this cmdlet without
    # changing NextFirings' contract).
    $rows = New-Object System.Collections.Generic.List[psobject]
    $prevCycleWeek = $null
    foreach ($r in $rawRows) {
        $moment = ([datetime]::SpecifyKind($r.DateUtc.Date, [DateTimeKind]::Utc)).AddHours(12)
        $resolved = Resolve-AzLocalCurrentUpdateRing -Schedule $Schedule -Now $moment
        # IsCycleWrap = the first day on which CycleWeek rolls back to
        # 1 after being at CycleWeeksTotal. For a 1-week "cycle" this
        # is true every Monday; for an N-week cycle it is true once per
        # cycle on the day-of-week when ISO-week increments from
        # anchor+N-1 to anchor+N (canonically a Monday in ISO-8601).
        $isWrap = ($null -ne $prevCycleWeek -and $r.CycleWeek -eq 1 -and $prevCycleWeek -eq $cycleWeeks)
        $label  = if ($isWrap) { "**1** of $cycleWeeks _(cycle wraps)_" } else { "$($r.CycleWeek) of $cycleWeeks" }
        $rings  = @($r.Rings)
        $rows.Add([pscustomobject]@{
            DateUtc                     = $r.DateUtc
            DayOfWeekName               = $r.DayOfWeekName
            CycleWeek                   = $r.CycleWeek
            CycleWeeksTotal             = $cycleWeeks
            CycleWeekLabel              = $label
            IsCycleWrap                 = $isWrap
            Rings                       = $rings
            UpdateRingValue             = $r.UpdateRingValue
            AllowedUpdateVersions       = @($resolved.AllowedUpdateVersions)
            AllowedUpdateVersionsValue  = $resolved.AllowedUpdateVersionsValue
            AllowedUpdateVersionsSource = $resolved.AllowedUpdateVersionsSource
            MatchedRowCount             = $r.MatchedRowCount
            IsDeadDay                   = ($rings.Count -eq 0)
            Reason                      = $resolved.Reason
        }) | Out-Null
        $prevCycleWeek = $r.CycleWeek
    }

    if (-not $AsMarkdown) {
        return $rows.ToArray()
    }

    # Normalise the optional ring -> count map to case-insensitive lookup
    # so callers can pass any casing (tag values are not consistent in
    # the wild). $hasCounts gates the extra column in the markdown.
    $ringCounts = $null
    $hasCounts  = $false
    if ($PSBoundParameters.ContainsKey('ClusterRingCounts') -and $ClusterRingCounts) {
        $ringCounts = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $ClusterRingCounts.Keys) {
            if ($null -eq $k) { continue }
            $kn = [string]$k
            if ([string]::IsNullOrWhiteSpace($kn)) { continue }
            $vRaw = $ClusterRingCounts[$k]
            $vInt = 0
            if ($null -ne $vRaw -and [int]::TryParse([string]$vRaw, [ref]$vInt)) { } else { $vInt = 0 }
            if (-not $ringCounts.ContainsKey($kn.Trim())) { $ringCounts[$kn.Trim()] = $vInt }
        }
        $hasCounts = ($ringCounts.Count -gt 0)
    }

    # Normalise the optional cron-firings-by-date map. Keys are
    # 'yyyy-MM-dd' strings; values are sorted, deduplicated 'HH:mm' UTC
    # firing times. $hasCronFirings gates the new "Ring CRON Start
    # Time" column in the per-day calendar markdown.
    $cronFirings    = $null
    $hasCronFirings = $false
    if ($PSBoundParameters.ContainsKey('CronFiringsByDate') -and $CronFiringsByDate) {
        $cronFirings = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($k in $CronFiringsByDate.Keys) {
            if ($null -eq $k) { continue }
            $kn = ([string]$k).Trim()
            if ([string]::IsNullOrWhiteSpace($kn)) { continue }
            $raw = $CronFiringsByDate[$k]
            if ($null -eq $raw) { continue }
            $arr = @($raw | ForEach-Object { if ($null -ne $_) { ([string]$_).Trim() } } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($arr.Count -eq 0) { continue }
            $sorted = [string[]]($arr | Sort-Object -Unique)
            if (-not $cronFirings.ContainsKey($kn)) { $cronFirings[$kn] = $sorted }
        }
        $hasCronFirings = ($cronFirings.Count -gt 0)
    }

    # Normalise the optional window-match map. Outer keys are ring
    # names (case-insensitive); inner keys are 'yyyy-MM-dd' UTC dates;
    # leaf hashtables MUST include 'Matching' and 'Total' (integers).
    # 'Pct' is computed if not supplied. $hasWindowMatch gates the new
    # "Tag Start Window Match (>=95%)" column.
    $windowMatch    = $null
    $hasWindowMatch = $false
    if ($PSBoundParameters.ContainsKey('WindowMatchByRingAndDate') -and $WindowMatchByRingAndDate) {
        $windowMatch = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.Dictionary[string,hashtable]]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($rk in $WindowMatchByRingAndDate.Keys) {
            if ($null -eq $rk) { continue }
            $rn = ([string]$rk).Trim()
            if ([string]::IsNullOrWhiteSpace($rn)) { continue }
            $perDateRaw = $WindowMatchByRingAndDate[$rk]
            if ($null -eq $perDateRaw -or -not ($perDateRaw -is [hashtable])) { continue }
            $perDate = New-Object 'System.Collections.Generic.Dictionary[string,hashtable]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($dk in $perDateRaw.Keys) {
                if ($null -eq $dk) { continue }
                $dn = ([string]$dk).Trim()
                if ([string]::IsNullOrWhiteSpace($dn)) { continue }
                $leafRaw = $perDateRaw[$dk]
                if ($null -eq $leafRaw -or -not ($leafRaw -is [hashtable])) { continue }
                $matchingI = 0
                $totalI    = 0
                if ($leafRaw.ContainsKey('Matching')) { [void][int]::TryParse([string]$leafRaw['Matching'], [ref]$matchingI) }
                if ($leafRaw.ContainsKey('Total'))    { [void][int]::TryParse([string]$leafRaw['Total'],    [ref]$totalI) }
                $pctD = 0.0
                if ($leafRaw.ContainsKey('Pct') -and $null -ne $leafRaw['Pct']) {
                    [void][double]::TryParse([string]$leafRaw['Pct'], [ref]$pctD)
                } elseif ($totalI -gt 0) {
                    $pctD = [double]$matchingI / [double]$totalI
                }
                if (-not $perDate.ContainsKey($dn)) {
                    $perDate[$dn] = @{ Matching = $matchingI; Total = $totalI; Pct = $pctD }
                }
            }
            if ($perDate.Count -gt 0 -and -not $windowMatch.ContainsKey($rn)) { $windowMatch[$rn] = $perDate }
        }
        $hasWindowMatch = ($windowMatch.Count -gt 0)
    }

    # ---- Markdown rendering ----------------------------------------
    $sb = New-Object System.Text.StringBuilder
    $endDate = $start.AddDays($Days - 1)
    [void]$sb.AppendLine("## Cycle calendar - next $Days day(s) (cycle length: $cycleWeeks week(s))")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("**Projection horizon.** ``$($start.ToString('yyyy-MM-dd'))`` -> ``$($endDate.ToString('yyyy-MM-dd'))`` (UTC). For each UTC day the table below lists which ``UpdateRing`` value(s) ``Resolve-AzLocalCurrentUpdateRing`` would return given your schedule file. Days where multiple schedule rows match are UNIONed (all eligible rings shown, deduplicated). The ``AllowedUpdateVersions`` column shows the effective allow-list for that day (empty = no constraint - install the latest Ready update).")
    [void]$sb.AppendLine()
    if ($Days -ge $cycleWeeks * 7) {
        [void]$sb.AppendLine("**Why this is one full cycle.** Your schedule declares ``cycleWeeks: $cycleWeeks``, so the projection covers $($cycleWeeks * 7) day(s). If today is partway through the current cycle (for example week $cycleWeeks of a $cycleWeeks-week cycle), the table starts on today's CycleWeek and rolls through the start of the next cycle - so you can see exactly when each ring will next fire. The ``(cycle wraps)`` annotation marks the row on which the rotation resets to week 1.")
        [void]$sb.AppendLine()
    }
    # Header pieces: build incrementally so a future 3rd optional
    # column slots in cleanly. Order MUST be:
    #   Date | [Cron firings] | Day | CycleWeek | Eligible rings | [Window match] | [Cluster counts] | AllowedUpdateVersions
    $headerCells = New-Object System.Collections.Generic.List[string]
    $alignCells  = New-Object System.Collections.Generic.List[string]
    [void]$headerCells.Add('Date (UTC)'); [void]$alignCells.Add('---')
    if ($hasCronFirings) {
        [void]$headerCells.Add('Ring CRON Start Time<br>(Step 6 pipeline)')
        [void]$alignCells.Add(':---:')
    }
    [void]$headerCells.Add('Day');             [void]$alignCells.Add('---')
    [void]$headerCells.Add('CycleWeek');       [void]$alignCells.Add('---')
    [void]$headerCells.Add('Eligible rings');  [void]$alignCells.Add('---')
    if ($hasWindowMatch) {
        [void]$headerCells.Add('Tag Start Window Match (>=95%)')
        [void]$alignCells.Add('---')
    }
    if ($hasCounts) {
        [void]$headerCells.Add('Clusters in ring(s)')
        [void]$alignCells.Add('---')
    }
    [void]$headerCells.Add('AllowedUpdateVersions'); [void]$alignCells.Add('---')
    [void]$sb.AppendLine('| ' + ($headerCells -join ' | ') + ' |')
    [void]$sb.AppendLine('|' + (($alignCells | ForEach-Object { $_ }) -join '|') + '|')
    foreach ($r in $rows) {
        $dateKey = $r.DateUtc.ToString('yyyy-MM-dd')
        $isDead  = (-not $r.Rings -or @($r.Rings).Count -eq 0)
        $ringsCell = if (-not $isDead) {
            (@($r.Rings) | ForEach-Object { '`' + $_ + '`' }) -join ', '
        } else {
            '_(none - dead day)_'
        }
        $allowCell = if (@($r.AllowedUpdateVersions).Count -gt 0) {
            (@($r.AllowedUpdateVersions) | ForEach-Object { '`' + $_ + '`' }) -join ', '
        } else {
            '_(no constraint)_'
        }
        $cronCell = $null
        if ($hasCronFirings) {
            if ($isDead) {
                $cronCell = '_(none - dead day)_'
            } else {
                $fires = @()
                if ($cronFirings.ContainsKey($dateKey)) { $fires = @($cronFirings[$dateKey]) }
                if ($fires.Count -eq 0) {
                    $cronCell = '_(none)_'
                } elseif ($fires.Count -le 2) {
                    $cronCell = ($fires -join ', ')
                } else {
                    $extra = $fires.Count - 2
                    $cronCell = (($fires | Select-Object -First 2) -join ', ') + " (+$extra)"
                }
            }
        }
        $matchCell = $null
        if ($hasWindowMatch) {
            if ($isDead) {
                $matchCell = '_(n/a - dead day)_'
            } else {
                $parts = @()
                foreach ($rg in @($r.Rings)) {
                    $perDate = $null
                    if ($windowMatch.ContainsKey($rg)) { $perDate = $windowMatch[$rg] }
                    if ($null -eq $perDate -or -not $perDate.ContainsKey($dateKey)) {
                        $parts += "``$rg``: _(n/a)_"
                        continue
                    }
                    $leaf = $perDate[$dateKey]
                    $tot  = [int]$leaf['Total']
                    $mat  = [int]$leaf['Matching']
                    if ($tot -le 0) {
                        $parts += "``$rg``: _(0 clusters)_"
                        continue
                    }
                    $pct  = [double]$leaf['Pct']
                    $isOk = ($pct -ge 0.95)
                    $pctTxt = [int][math]::Round($pct * 100)
                    $parts += "``$rg``: $isOk $mat/$tot ($pctTxt%)"
                }
                $matchCell = ($parts -join '; ')
            }
        }
        $countCell = $null
        if ($hasCounts) {
            $countCell = if (-not $isDead) {
                $cparts = @()
                $total = 0
                foreach ($rg in @($r.Rings)) {
                    $cnt = 0
                    if ($ringCounts.ContainsKey($rg)) { $cnt = $ringCounts[$rg] }
                    $cparts += "``$rg``: $cnt"
                    $total += $cnt
                }
                if (@($r.Rings).Count -gt 1) {
                    (($cparts -join ', ') + " (total: $total)")
                } else {
                    ($cparts -join ', ')
                }
            } else {
                '_(0 - dead day)_'
            }
        }
        # Assemble cells in the same order as the header.
        $rowCells = New-Object System.Collections.Generic.List[string]
        [void]$rowCells.Add($dateKey)
        if ($hasCronFirings) { [void]$rowCells.Add($cronCell) }
        [void]$rowCells.Add([string]$r.DayOfWeekName)
        [void]$rowCells.Add([string]$r.CycleWeekLabel)
        [void]$rowCells.Add($ringsCell)
        if ($hasWindowMatch) { [void]$rowCells.Add($matchCell) }
        if ($hasCounts)      { [void]$rowCells.Add($countCell) }
        [void]$rowCells.Add($allowCell)
        [void]$sb.AppendLine('| ' + ($rowCells -join ' | ') + ' |')
    }
    [void]$sb.AppendLine()

    if ($IncludePerRingSummary) {
        # Build the universe of rings: UNION of all rings the schedule
        # ever references (so we surface "this ring is configured but
        # never fires in the horizon" as a dead-ring signal too).
        $allRings = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($srow in @($Schedule.Schedule)) {
            foreach ($rg in ($srow.rings -split ';')) {
                $tg = $rg.Trim()
                if (-not [string]::IsNullOrWhiteSpace($tg)) { [void]$allRings.Add($tg) }
            }
        }

        # Index ring -> sorted list of eligible dates within the horizon.
        $ringToDates = @{}
        foreach ($ring in $allRings) { $ringToDates[$ring] = New-Object System.Collections.Generic.List[datetime] }
        foreach ($r in $rows) {
            foreach ($rg in @($r.Rings)) {
                if ($ringToDates.ContainsKey($rg)) {
                    [void]$ringToDates[$rg].Add($r.DateUtc)
                } else {
                    # Ring appeared in resolver output but not in schedule
                    # ring set (case-insensitive miss?). Add defensively.
                    $ringToDates[$rg] = New-Object System.Collections.Generic.List[datetime]
                    [void]$ringToDates[$rg].Add($r.DateUtc)
                }
            }
        }

        [void]$sb.AppendLine('### Per-ring projection (next eligible UTC dates within the horizon)')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("**What this shows.** One row per ``UpdateRing`` referenced anywhere in your schedule. ``Next eligible`` is the soonest UTC date in the horizon when ``Resolve-AzLocalCurrentUpdateRing`` returns that ring. ``All eligible dates`` is the full list (deduplicated, ordered). A ring with ``(none in horizon)`` is configured in the schedule but does not fire within the next $Days day(s) - usually because its ``weeksInCycle`` does not intersect the horizon (e.g. a Prod ring scheduled for weeks 5-8 of an 8-week cycle, when today is still in week 1).")
        [void]$sb.AppendLine()
        if ($hasCounts) {
            [void]$sb.AppendLine('| UpdateRing | Cluster count | Next eligible | Eligible days (count) | All eligible dates |')
            [void]$sb.AppendLine('|---|---|---|---|---|')
        } else {
            [void]$sb.AppendLine('| UpdateRing | Next eligible | Eligible days (count) | All eligible dates |')
            [void]$sb.AppendLine('|---|---|---|---|')
        }
        foreach ($ring in ($ringToDates.Keys | Sort-Object)) {
            $dates = @($ringToDates[$ring])
            $clusterCountCell = if ($hasCounts) {
                $cv = 0
                if ($ringCounts.ContainsKey($ring)) { $cv = $ringCounts[$ring] }
                $cv.ToString()
            } else { $null }
            if ($dates.Count -eq 0) {
                if ($hasCounts) {
                    [void]$sb.AppendLine("| ``$ring`` | $clusterCountCell | _(none in horizon)_ | 0 | - |")
                } else {
                    [void]$sb.AppendLine("| ``$ring`` | _(none in horizon)_ | 0 | - |")
                }
                continue
            }
            $next  = $dates[0].ToString('yyyy-MM-dd')
            $count = $dates.Count
            $list  = ($dates | ForEach-Object { $_.ToString('yyyy-MM-dd') }) -join ', '
            if ($hasCounts) {
                [void]$sb.AppendLine("| ``$ring`` | $clusterCountCell | $next | $count | $list |")
            } else {
                [void]$sb.AppendLine("| ``$ring`` | $next | $count | $list |")
            }
        }
        [void]$sb.AppendLine()
    }

    return $sb.ToString()
}
