function ConvertFrom-AzLocalScheduleYaml {
    <#
    .SYNOPSIS
        Parses the AzLocal apply-updates-schedule.yml (schema v1) into a
        [PSCustomObject]. Zero external dependencies.

    .DESCRIPTION
        Intentionally NOT a general-purpose YAML parser. Accepts only the
        narrow shape documented in
        Automation-Pipeline-Examples/apply-updates-schedule.example.yml:

          schemaVersion:        <int>
          cycleWeeks:           <int>
          cycleAnchorISOWeek:   <int>
          cycleAnchorYear:      <int>
          schedule:
            - weeksInCycle: '<expr>'
              daysOfWeek:   '<expr>'
              rings:        '<expr>'
              notes:        '<text>'     # optional
            - ...

        Indentation must be 2 spaces (list-item marker) + 2 spaces
        (continuation keys), exactly. Inline '#' comments and blank
        lines are ignored. Quoted strings (single or double) and bare
        integers are supported as scalar values; everything else is
        treated as a bare string.

        Validation lives in Get-AzLocalApplyUpdatesScheduleConfig - this
        function only converts text to structure. Errors here are limited
        to structural problems (unexpected indent, malformed key:value).

    .PARAMETER Text
        The raw file contents (read via Get-Content -Raw).

    .PARAMETER SourcePath
        Optional path used in error messages so operators see the file
        they were trying to load.

    .OUTPUTS
        [PSCustomObject] with top-level scalar properties and a Schedule
        property of type [PSCustomObject[]]. Property names match the
        YAML keys exactly. Missing top-level keys are emitted as $null
        - the validator surfaces them.

    .EXAMPLE
        $text = Get-Content -Raw .\.github\apply-updates-schedule.yml
        ConvertFrom-AzLocalScheduleYaml -Text $text
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [string]$SourcePath = '<inline>'
    )

    # ---- Scalar parser -------------------------------------------------
    # Strips one matching pair of surrounding single or double quotes.
    # Bare integers (^-?\d+$) become [int]; everything else stays string.
    # Trailing '# comment' is stripped BEFORE we get here; this is just
    # the value side.
    function ConvertTo-AzLocalScalar([string]$raw) {
        $v = $raw.Trim()
        if ($v.Length -ge 2) {
            $first = $v[0]; $last = $v[$v.Length - 1]
            if (($first -eq "'" -and $last -eq "'") -or
                ($first -eq '"' -and $last -eq '"')) {
                return $v.Substring(1, $v.Length - 2)
            }
        }
        if ($v -match '^-?\d+$') { return [int]$v }
        return $v
    }

    # ---- Trailing-comment stripper ------------------------------------
    # Walks the line and finds the first '#' that is NOT inside a single
    # or double-quoted string. The match before it is the value; from #
    # onward is a YAML comment.
    function Remove-AzLocalTrailingYamlComment([string]$line) {
        $inSingle = $false; $inDouble = $false
        for ($i = 0; $i -lt $line.Length; $i++) {
            $c = $line[$i]
            if ($c -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle; continue }
            if ($c -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble; continue }
            if ($c -eq '#' -and -not $inSingle -and -not $inDouble) {
                return $line.Substring(0, $i).TrimEnd()
            }
        }
        return $line.TrimEnd()
    }

    # ---- Tokenise -----------------------------------------------------
    # Each non-comment, non-blank line becomes a (LineNumber, Indent,
    # Kind, Key, RawValue) record. Kind is 'Pair' for "key: value", or
    # 'ListItemPair' for "- key: value". Continuation keys for a list
    # item are also 'Pair' but with higher indent than the marker line.
    $tokens = New-Object System.Collections.Generic.List[psobject]
    $lineNum = 0
    foreach ($raw in ($Text -split "`r?`n")) {
        $lineNum++
        $stripped = Remove-AzLocalTrailingYamlComment $raw
        if ([string]::IsNullOrWhiteSpace($stripped)) { continue }

        $indent = 0
        while ($indent -lt $stripped.Length -and $stripped[$indent] -eq ' ') { $indent++ }
        $body = $stripped.Substring($indent)

        if ($body.StartsWith('- ')) {
            $rest = $body.Substring(2)
            $m = [regex]::Match($rest, '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
            if (-not $m.Success) {
                throw "ConvertFrom-AzLocalScheduleYaml: malformed list item at $SourcePath line $($lineNum): '$raw'."
            }
            $tokens.Add([pscustomobject]@{
                LineNumber = $lineNum
                Indent     = $indent
                Kind       = 'ListItemPair'
                Key        = $m.Groups[1].Value
                RawValue   = $m.Groups[2].Value
            }) | Out-Null
            continue
        }

        $m = [regex]::Match($body, '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$')
        if (-not $m.Success) {
            throw "ConvertFrom-AzLocalScheduleYaml: malformed key:value at $SourcePath line $($lineNum): '$raw'."
        }
        $tokens.Add([pscustomobject]@{
            LineNumber = $lineNum
            Indent     = $indent
            Kind       = 'Pair'
            Key        = $m.Groups[1].Value
            RawValue   = $m.Groups[2].Value
        }) | Out-Null
    }

    # ---- Assemble ------------------------------------------------------
    # Top-level scalars accumulate into a hashtable. The `schedule:` key
    # (which has an empty RawValue) opens a list block; subsequent
    # ListItemPair tokens start new entries, and Pair tokens with indent
    # > the marker indent extend the current entry.
    $topLevel = [ordered]@{}
    $schedule = New-Object System.Collections.Generic.List[psobject]
    $currentItem = $null
    $inSchedule  = $false
    $scheduleIndent = -1

    foreach ($t in $tokens) {
        if (-not $inSchedule) {
            if ($t.Indent -ne 0) {
                throw "ConvertFrom-AzLocalScheduleYaml: unexpected indented key '$($t.Key)' at $SourcePath line $($t.LineNumber) - top-level keys must start at column 0."
            }
            if ($t.Key -eq 'schedule') {
                if (-not [string]::IsNullOrWhiteSpace($t.RawValue)) {
                    throw "ConvertFrom-AzLocalScheduleYaml: top-level 'schedule' key must have NO inline value (list follows on subsequent lines) at $SourcePath line $($t.LineNumber)."
                }
                $inSchedule = $true
                continue
            }
            $topLevel[$t.Key] = ConvertTo-AzLocalScalar $t.RawValue
            continue
        }

        # Inside the schedule list now.
        if ($t.Kind -eq 'ListItemPair') {
            # New list entry begins.
            if ($scheduleIndent -lt 0) { $scheduleIndent = $t.Indent }
            if ($t.Indent -ne $scheduleIndent) {
                throw "ConvertFrom-AzLocalScheduleYaml: schedule list items must all share the same indent (expected $scheduleIndent, got $($t.Indent)) at $SourcePath line $($t.LineNumber)."
            }
            if ($currentItem) { $schedule.Add([pscustomobject]$currentItem) | Out-Null }
            $currentItem = [ordered]@{
                _LineNumber = $t.LineNumber
                ($t.Key)    = ConvertTo-AzLocalScalar $t.RawValue
            }
            continue
        }

        # Pair while inside schedule. Indent 0 closes the list and goes
        # back to top-level (rare, but supported). Otherwise it extends
        # the current item, provided the indent is greater than the
        # marker indent.
        if ($t.Indent -eq 0) {
            if ($currentItem) { $schedule.Add([pscustomobject]$currentItem) | Out-Null; $currentItem = $null }
            $inSchedule = $false
            $topLevel[$t.Key] = ConvertTo-AzLocalScalar $t.RawValue
            continue
        }
        if (-not $currentItem) {
            throw "ConvertFrom-AzLocalScheduleYaml: indented key '$($t.Key)' at $SourcePath line $($t.LineNumber) has no preceding list-item marker."
        }
        if ($t.Indent -le $scheduleIndent) {
            throw "ConvertFrom-AzLocalScheduleYaml: continuation key '$($t.Key)' at $SourcePath line $($t.LineNumber) must be indented further than the list-item marker."
        }
        $currentItem[$t.Key] = ConvertTo-AzLocalScalar $t.RawValue
    }

    if ($currentItem) { $schedule.Add([pscustomobject]$currentItem) | Out-Null }

    # ---- Project to a stable shape -----------------------------------
    # Always emit the four scalar keys (as $null when missing) plus an
    # array Schedule. Validator decides what's required.
    # v0.7.89 (schema v2) added an optional top-level
    # 'allowedUpdateVersions' string (semicolon-separated). It is
    # surfaced here as AllowedUpdateVersionsRaw (the raw string, or
    # $null when absent) so the validator + resolver can split + dedupe
    # it without re-parsing the file. Per-row 'allowedUpdateVersions' is
    # passed through generically via the row PSCustomObject (the
    # tokenizer accepts any continuation key) - no projection needed
    # here.
    $obj = [ordered]@{
        SchemaVersion              = $topLevel['schemaVersion']
        CycleWeeks                 = $topLevel['cycleWeeks']
        CycleAnchorISOWeek         = $topLevel['cycleAnchorISOWeek']
        CycleAnchorYear            = $topLevel['cycleAnchorYear']
        AllowedUpdateVersionsRaw   = $topLevel['allowedUpdateVersions']
        PrepareOnlyFirstRaw        = $topLevel['prepareOnlyFirst']
        AllowPrepareOnlyOutsideOfUpdateStartWindowRaw = $topLevel['allowPrepareOnlyOutsideOfUpdateStartWindow']
        Schedule                   = @($schedule)
        SourcePath                 = $SourcePath
    }
    return [pscustomobject]$obj
}
