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
    .PARAMETER UpdateStartWindow
        The raw UpdateStartWindow tag value.
    .PARAMETER LeadTimeMinutes
        Minutes before the window opens that the pipeline should fire. Default 5.
    .OUTPUTS
        PSCustomObject[] - one per window segment, with:
            Segment        - the raw window segment string
            Days           - DayOfWeek[]
            CronDoWSet     - sorted int[] (cron 0-6) of firing days (after lead-time wrap)
            CronExpression - '<M> <H> * * <DoW>' string suitable for GitHub Actions / ADO
            FireMinute     - int 0-59
            FireHour       - int 0-23
            DayShift       - $true if the lead-time pushed the fire time onto the previous day
    .EXAMPLE
        Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Sat-Sun_02:00-06:00' -LeadTimeMinutes 5
        # Returns one row, CronExpression = '55 1 * * 6,0'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UpdateStartWindow,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 60)]
        [int]$LeadTimeMinutes = 5
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
        })
    }

    # WARNING: Callers MUST use direct assignment ($x = func ...) and NEVER
    # wrap with @(func ...). The unary-comma return below preserves Object[N]
    # shape for any N including 0 and 1, but @() at the call site collapses
    # to Object[1] containing the inner array, silently producing one-row
    # output instead of N rows. See `docs/MODULE-REVIEW-AND-RECOMMENDATIONS.md`
    # Finding 1 for the v0.7.75 incident.
    return , $output.ToArray()
}
