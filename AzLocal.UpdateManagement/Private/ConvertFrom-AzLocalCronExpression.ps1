function ConvertFrom-AzLocalCronExpression {
    <#
    .SYNOPSIS
        Parses a 5-field cron expression and enumerates every fire time within a
        reference week (Sunday 00:00 -> Saturday 23:59 UTC).
    .DESCRIPTION
        Used by Test-AzLocalApplyUpdatesScheduleCoverage to decide whether a
        cron entry from Step.7_apply-updates.yml covers any of the maintenance windows
        derived from cluster UpdateStartWindow tags.

        Supports the subset of cron syntax that GitHub Actions and Azure DevOps
        both honour for `schedule:` / `schedules:` blocks:
            <Minute> <Hour> <DayOfMonth> <Month> <DayOfWeek>
        Per field:
            *
            <n>                       (e.g. 5)
            <n>,<n>,<n>...            (e.g. 6,0)
            <a>-<b>                   (e.g. 1-5)
            comma-separated mix       (e.g. 0,15,30,45 or 1-3,5)
            */N                       (v0.7.67: every N from Min to Max, e.g. */15 in minute field -> 0,15,30,45)
            <a>-<b>/N                 (v0.7.67: every N within [a,b], e.g. 9-17/2 in hour field -> 9,11,13,15,17)
            <a>/N                     (v0.7.67: every N from a to Max, e.g. 5/15 in minute field -> 5,20,35,50)

        DayOfMonth and Month MUST be * - any other value returns IsComplex=$true
        and FireTimes=@(), so the caller can surface "this cron is too complex
        for the advisor to reason about" rather than emit a wrong answer.

        DayOfWeek: 0 and 7 both mean Sunday (cron convention). Wrap-around
        ranges (e.g. 5-1) are NOT supported - use comma syntax (5,6,0,1).
    .PARAMETER Expression
        The cron string, e.g. '55 1 * * 6,0'.
    .OUTPUTS
        PSCustomObject with:
            Raw         - the input string
            IsValid     - $true if parsed without error
            IsComplex   - $true if DOM or Month are non-* (advisor cannot evaluate)
            ErrorMessage - parse error if IsValid is $false
            FireTimes   - DateTime[] in a reference week starting Sunday 2024-01-07 00:00 UTC,
                          one entry per cron firing in that week
    .EXAMPLE
        ConvertFrom-AzLocalCronExpression -Expression '55 1 * * 6,0'
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # AllowEmptyString lets the IsNullOrWhiteSpace handler below actually run.
        # Without it, [Parameter(Mandatory)][string] rejects '' at the binder
        # with 'Cannot bind argument to parameter Expression because it is an
        # empty string', which crashes any caller piping cron records from a
        # YAML pre-scan instead of getting a structured invalid result back.
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Expression
    )

    # Reference week: Sunday 2024-01-07 00:00 UTC -> Saturday 2024-01-13 23:59 UTC.
    # All FireTimes are within this 7-day window; the caller does day-of-week
    # matching against the calendar dates rather than DayOfWeek enum directly.
    $weekStart = [datetime]::new(2024, 1, 7, 0, 0, 0, [DateTimeKind]::Utc)

    $result = [PSCustomObject]@{
        Raw          = $Expression
        IsValid      = $false
        IsComplex    = $false
        ErrorMessage = $null
        FireTimes    = @()
    }

    if ([string]::IsNullOrWhiteSpace($Expression)) {
        $result.ErrorMessage = 'Cron expression is empty.'
        return $result
    }

    $trimmed = $Expression.Trim()
    $fields = $trimmed -split '\s+'
    if ($fields.Count -ne 5) {
        $result.ErrorMessage = "Expected 5 cron fields (M H DoM Month DoW), got $($fields.Count): '$Expression'"
        return $result
    }

    $minField  = $fields[0]
    $hourField = $fields[1]
    $domField  = $fields[2]
    $monField  = $fields[3]
    $dowField  = $fields[4]

    if ($domField -ne '*' -or $monField -ne '*') {
        $result.IsValid   = $true
        $result.IsComplex = $true
        $result.ErrorMessage = "DayOfMonth='$domField' or Month='$monField' is not '*' - advisor cannot reason about month/day-of-month restrictions."
        return $result
    }

    # Inner helper: expand a single field into a sorted, deduped int[] within [min,max].
    function Expand-AzLocalCronField {
        param(
            [string]$Field,
            [int]$Min,
            [int]$Max
        )
        if ($Field -eq '*') {
            return ($Min..$Max)
        }
        $values = @()
        foreach ($part in $Field -split ',') {
            $part = $part.Trim()
            # Step syntax (v0.7.67): '*/N' fires every N starting at $Min;
            # '<a>-<b>/N' fires every N within the explicit range [a,b];
            # '<a>/N' fires every N from a to $Max (cron treats a single
            # value with a step as 'from a to max in steps of N').
            # N must be a positive integer; N==1 is allowed but degenerate.
            if ($part -match '^(\*|\d+|\d+-\d+)/(\d+)$') {
                $base = $matches[1]
                $step = [int]$matches[2]
                if ($step -le 0) { throw "Invalid step '$part' (step value must be a positive integer)." }
                $rangeStart = $Min
                $rangeEnd = $Max
                if ($base -eq '*') {
                    # full range
                }
                elseif ($base -match '^(\d+)-(\d+)$') {
                    $rangeStart = [int]$matches[1]; $rangeEnd = [int]$matches[2]
                    if ($rangeStart -gt $rangeEnd) { throw "Invalid range '$part' (start > end). Wrap-around ranges are not supported - use comma syntax." }
                }
                elseif ($base -match '^\d+$') {
                    $rangeStart = [int]$base
                    # rangeEnd stays at $Max so '5/15' under [0,59] means 5,20,35,50.
                }
                if ($rangeStart -lt $Min -or $rangeEnd -gt $Max) { throw "Step base '$base' out of bounds [$Min-$Max]." }
                for ($i = $rangeStart; $i -le $rangeEnd; $i += $step) { $values += $i }
            }
            elseif ($part -match '^(\d+)-(\d+)$') {
                $a = [int]$matches[1]; $b = [int]$matches[2]
                if ($a -gt $b) { throw "Invalid range '$part' (start > end). Wrap-around ranges are not supported - use comma syntax." }
                if ($a -lt $Min -or $b -gt $Max) { throw "Range '$part' out of bounds [$Min-$Max]." }
                for ($i = $a; $i -le $b; $i++) { $values += $i }
            }
            elseif ($part -match '^\d+$') {
                $n = [int]$part
                if ($n -lt $Min -or $n -gt $Max) { throw "Value '$part' out of bounds [$Min-$Max]." }
                $values += $n
            }
            else {
                throw "Unsupported cron token '$part' (named months/days and other shorthand are not supported by the advisor)."
            }
        }
        return @($values | Sort-Object -Unique)
    }

    try {
        $minutes  = Expand-AzLocalCronField -Field $minField  -Min 0 -Max 59
        $hours    = Expand-AzLocalCronField -Field $hourField -Min 0 -Max 23
        $dowRaw   = Expand-AzLocalCronField -Field $dowField  -Min 0 -Max 7
        # Normalise: 7 -> 0 (Sunday).
        $dows     = @($dowRaw | ForEach-Object { if ($_ -eq 7) { 0 } else { $_ } } | Sort-Object -Unique)
    }
    catch {
        $result.ErrorMessage = "Cron field parse error: $($_.Exception.Message)"
        return $result
    }

    # Enumerate fire times across the reference week. Cron day-of-week index:
    # 0 = Sunday, 1 = Monday, ..., 6 = Saturday. The reference week starts on
    # Sunday so dayOffset == cron DOW.
    $fireTimes = New-Object System.Collections.Generic.List[datetime]
    foreach ($dow in $dows) {
        $dayDate = $weekStart.AddDays($dow)
        foreach ($h in $hours) {
            foreach ($m in $minutes) {
                $fireTimes.Add($dayDate.Date.AddHours($h).AddMinutes($m))
            }
        }
    }

    $result.IsValid   = $true
    $result.IsComplex = $false
    $result.FireTimes = $fireTimes.ToArray() | Sort-Object
    return $result
}
