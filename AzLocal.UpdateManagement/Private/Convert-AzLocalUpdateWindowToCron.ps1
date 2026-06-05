function Convert-AzLocalUpdateWindowToCron {
    <#
    .SYNOPSIS
        Derives the recommended cron expression(s) needed to fire an apply-updates
        pipeline at the opening edge of every maintenance window encoded in an
        UpdateStartWindow tag value.
    .DESCRIPTION
        Used by Test-AzLocalApplyUpdatesScheduleCoverage. Reuses the existing
        ConvertFrom-AzLocalUpdateWindow parser, then for each parsed segment:

          - computes the fire time = StartTime - LeadTimeMinutes
            (with day wrap when the fire time goes negative)
          - converts the DayOfWeek[] set to cron DoW notation
            (Sun=0, Mon=1, ..., Sat=6 - contiguous sets emit ranges, others emit comma lists)
          - emits one cron string '<M> <H> * * <DoW>' per window opening edge

        Same-day window:   fire at (start - lead) on each day in the set.
        Overnight window:  the window opens on the listed day(s); fire only on the
                           opening edge - the runtime gate (Test-AzLocalUpdateScheduleAllowed)
                           handles the wrap into the next day.

        Multi-segment windows like 'Mon-Fri_22:00-04:00;Sat-Sun_02:00-10:00'
        produce one cron string per segment.

        Belt-and-braces (FiresPerWindow=2, default 1 for back-compat):
        When -FiresPerWindow 2 is supplied, each segment ALSO emits a second
        "retry" cron INSIDE the window. The retry fire time is computed as
        the lesser of:
          - the window midpoint (StartTime + (WindowDurationMinutes / 2)), or
          - 60 minutes after the window opens.
        The cap keeps retries quick on long windows (a 24h window retries at
        +60min, not at +12h). Day-shift handling mirrors the opening-edge
        logic but in the FORWARD direction (e.g. a 23:30-00:30 window with
        a 30min retry offset retries at 00:00 the NEXT day).
        Each row's IsRetry property tags whether it is the opening-edge cron
        (IsRetry=$false, first row per segment) or a retry cron
        (IsRetry=$true, subsequent rows).
    .PARAMETER UpdateStartWindow
        The raw UpdateStartWindow tag value.
    .PARAMETER LeadTimeMinutes
        Minutes before the window opens that the pipeline should fire. Default 5.
    .PARAMETER FiresPerWindow
        How many cron entries to emit per window segment. Default 1 (opening
        edge only - back-compat for v0.7.91 and earlier callers). Set to 2
        for the belt-and-braces pattern: opening edge + one mid-window
        retry. Range 1-2; values above 2 are reserved for future use.
    .OUTPUTS
        PSCustomObject[] - one per window segment when FiresPerWindow=1, two
        per segment when FiresPerWindow=2. Each row carries:
            Segment        - the raw window segment string
            Days           - DayOfWeek[]
            CronDoWSet     - sorted int[] (cron 0-6) of firing days
            CronExpression - '<M> <H> * * <DoW>' string suitable for GitHub Actions / ADO
            FireMinute     - int 0-59
            FireHour       - int 0-23
            DayShift       - $true if the fire time landed on a different
                             day from the window opening (lead-time pushed
                             backward, or retry offset pushed forward)
            IsRetry        - $false for the opening-edge cron, $true for the
                             belt-and-braces mid-window retry
    .EXAMPLE
        Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Sat-Sun_02:00-06:00' -LeadTimeMinutes 5
        # Returns one row, CronExpression = '55 1 * * 6,0'
    .EXAMPLE
        Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon-Fri_20:00-23:00' -FiresPerWindow 2
        # Returns two rows:
        #   '55 19 * * 1-5' (IsRetry=$false, opening edge minus 5min lead)
        #   '0 21 * * 1-5'  (IsRetry=$true, window midpoint capped at +60min)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateStartWindow,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$LeadTimeMinutes = 5,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 2)]
        [int]$FiresPerWindow = 1
    )

    # DayOfWeek enum value -> cron DoW int. Cron: Sun=0, Mon=1, ..., Sat=6 -
        # this also matches the .NET DayOfWeek enum numeric values.
    $dowToCron = @{
        [System.DayOfWeek]::Sunday    = 0
        [System.DayOfWeek]::Monday    = 1
        [System.DayOfWeek]::Tuesday   = 2
        [System.DayOfWeek]::Wednesday = 3
        [System.DayOfWeek]::Thursday  = 4
        [System.DayOfWeek]::Friday    = 5
        [System.DayOfWeek]::Saturday  = 6
    }

    $parsed = ConvertFrom-AzLocalUpdateWindow -WindowString $UpdateStartWindow

    $output = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($w in $parsed) {
        # Compute fire time = StartTime - LeadTimeMinutes. If this crosses
        # midnight backwards, push each firing day back by one (e.g. Mon 00:05
        # window with 10min lead fires at Sun 23:55).
        $startMinutes = ($w.StartTime.Hours * 60) + $w.StartTime.Minutes
        $fireMinutes  = $startMinutes - $LeadTimeMinutes
        $dayShift     = $false
        if ($fireMinutes -lt 0) {
            $fireMinutes += (24 * 60)
            $dayShift = $true
        }
        $fireHour   = [int]([math]::Floor($fireMinutes / 60))
        $fireMinute = $fireMinutes - ($fireHour * 60)

        # Translate firing days (with optional shift) to cron DoW ints.
        $cronDows = New-Object System.Collections.Generic.List[int]
        foreach ($d in $w.Days) {
            $cronDow = $dowToCron[$d]
            if ($dayShift) {
                $cronDow = ($cronDow + 6) % 7   # shift back one day, wrap Sun->Sat
            }
            $cronDows.Add($cronDow)
        }
        $cronDowSet = @($cronDows | Sort-Object -Unique)

        # Render DoW set: a contiguous range becomes '<a>-<b>', otherwise a comma list.
        # Special-case Sun (0) merged with Sat (6) - the parser may emit {0,6}
        # which is logically Sat-Sun but cron can't express a wrap range, so
        # emit as '6,0' (Sat first, then Sun) to read like the human tag value
        # 'Sat-Sun'. Cron treats day lists as unordered so '6,0' and '0,6' are
        # equivalent at runtime - this is purely cosmetic.
        $dowStr = if ($cronDowSet.Count -eq 1) {
            "$($cronDowSet[0])"
        }
        elseif ($cronDowSet.Count -eq 2 -and $cronDowSet[0] -eq 0 -and $cronDowSet[1] -eq 6) {
            '6,0'
        }
        elseif ($cronDowSet.Count -gt 1 -and ($cronDowSet[-1] - $cronDowSet[0]) -eq ($cronDowSet.Count - 1)) {
            "$($cronDowSet[0])-$($cronDowSet[-1])"
        }
        else {
            ($cronDowSet -join ',')
        }

        $output.Add([PSCustomObject]@{
            Segment        = $w.Raw
            Days           = $w.Days
            CronDoWSet     = $cronDowSet
            CronExpression = "$fireMinute $fireHour * * $dowStr"
            FireMinute     = $fireMinute
            FireHour       = $fireHour
            DayShift       = $dayShift
            IsRetry        = $false
        })

        # Belt-and-braces retry cron (FiresPerWindow=2). Fires INSIDE the
        # window at min(midpoint, +60min after open) so:
        #   - GitHub Actions scheduled-workflow jitter (~15 min) cannot
        #     cause the opening-edge cron to miss the window entirely
        #     without a second chance,
        #   - a transient first-fire failure (auth, runner exhaustion,
        #     module install hiccup) is retried while the gate is still
        #     open,
        #   - long windows do not wait half the window for the retry
        #     (a 24h window retries at +60min, not at +12h).
        # Test-AzLocalUpdateScheduleAllowed + the in-flight guard ensure
        # the retry never double-triggers a cluster whose first run is
        # already in progress.
        if ($FiresPerWindow -ge 2) {
            # Window duration in minutes, supporting overnight wrap.
            $endMinutes = ($w.EndTime.Hours * 60) + $w.EndTime.Minutes
            $windowMinutes = $endMinutes - $startMinutes
            if ($windowMinutes -le 0) { $windowMinutes += (24 * 60) }

            $retryOffset = [int][math]::Min(($windowMinutes / 2), 60)
            # Retry must be strictly after the opening edge; if a tiny
            # window (<= 2min) collapses the offset to 0, skip the retry
            # rather than emit a duplicate cron.
            if ($retryOffset -le 0) { continue }

            $retryFireMinutes = $startMinutes + $retryOffset
            $retryDayShift    = $false
            if ($retryFireMinutes -ge (24 * 60)) {
                $retryFireMinutes -= (24 * 60)
                $retryDayShift = $true
            }
            $retryHour   = [int]([math]::Floor($retryFireMinutes / 60))
            $retryMinute = $retryFireMinutes - ($retryHour * 60)

            # Retry day shift is FORWARD (next day) - opposite to the
            # lead-time shift which is BACKWARD (previous day).
            $retryDows = New-Object System.Collections.Generic.List[int]
            foreach ($d in $w.Days) {
                $cronDow = $dowToCron[$d]
                if ($retryDayShift) {
                    $cronDow = ($cronDow + 1) % 7
                }
                $retryDows.Add($cronDow)
            }
            $retryDowSet = @($retryDows | Sort-Object -Unique)

            $retryDowStr = if ($retryDowSet.Count -eq 1) {
                "$($retryDowSet[0])"
            }
            elseif ($retryDowSet.Count -eq 2 -and $retryDowSet[0] -eq 0 -and $retryDowSet[1] -eq 6) {
                '6,0'
            }
            elseif ($retryDowSet.Count -gt 1 -and ($retryDowSet[-1] - $retryDowSet[0]) -eq ($retryDowSet.Count - 1)) {
                "$($retryDowSet[0])-$($retryDowSet[-1])"
            }
            else {
                ($retryDowSet -join ',')
            }

            $output.Add([PSCustomObject]@{
                Segment        = $w.Raw
                Days           = $w.Days
                CronDoWSet     = $retryDowSet
                CronExpression = "$retryMinute $retryHour * * $retryDowStr"
                FireMinute     = $retryMinute
                FireHour       = $retryHour
                DayShift       = $retryDayShift
                IsRetry        = $true
            })
        }
    }

    # WARNING: Callers MUST use direct assignment ($x = func ...) and NEVER
    # wrap with @(func ...). The unary-comma return below preserves Object[N]
    # shape for any N including 0 and 1, but @() at the call site collapses
    # to Object[1] containing the inner array, silently producing one-row
    # output instead of N rows. See `docs/MODULE-REVIEW-AND-RECOMMENDATIONS.md`
    # Finding 1 for the v0.7.75 incident.
    return , $output.ToArray()
}
