function Convert-AzLocalScheduleSchemaVersion {
    <#
    .SYNOPSIS
        Migrates an apply-updates-schedule.yml file from an older schema
        version to the module's current schema version (or any chosen
        target). Text-surgery based - customer comments and row order are
        preserved verbatim.

    .DESCRIPTION
        The function walks the per-hop recipe table registered in this
        file (see $script:ScheduleSchemaRecipes below). Each recipe is a
        ScriptBlock with signature:

            param([string]$Text) -> @{ Text = <new>; Changes = @(<strings>) }

        Recipes operate on RAW TEXT, not on the parsed structure. This is
        deliberate so operator-authored YAML comments above schedule
        rows (typically change-control references) survive every
        migration hop. Each recipe is expected to be IDEMPOTENT: running
        it twice on the same input must produce the same output.

        Walker behaviour:
          * If $current == $target  -> return Migrated=$false (no-op).
          * If $current  > $target  -> throw (downgrade requested; bad).
          * If $current  < $target  -> walk recipes $current -> $current+1
                                       -> ... -> $target. If any hop is
                                       missing from the table, throw.

        Backup-on-write is performed by the caller
        (Update-AzLocalApplyUpdatesScheduleConfig) - this function only
        computes the new text and reports what changed.

    .PARAMETER Text
        Raw YAML text of the customer's schedule file.

    .PARAMETER TargetSchemaVersion
        Schema version to migrate TO. Default: this module's current
        ($script:ScheduleSchemaCurrentVersion). Tests can override to
        exercise specific hops.

    .PARAMETER SourcePath
        Optional path used in error messages.

    .OUTPUTS
        [PSCustomObject] with:
          Migrated       [bool]
          FromVersion    [int]
          ToVersion      [int]
          NewText        [string]   - migrated YAML text (or original if no-op)
          Hops           [object[]] - one row per executed recipe:
                                       { FromVersion, ToVersion, Changes[] }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [int]$TargetSchemaVersion = $script:ScheduleSchemaCurrentVersion,

        [Parameter(Mandatory = $false)]
        [string]$SourcePath = '<inline>'
    )

    # Parse just enough to read the current schemaVersion. Re-parse after
    # each hop so future recipes can rely on structured access if they want.
    $cfg = ConvertFrom-AzLocalScheduleYaml -Text $Text -SourcePath $SourcePath
    if ($null -eq $cfg.SchemaVersion -or $cfg.SchemaVersion -isnot [int]) {
        throw "Convert-AzLocalScheduleSchemaVersion: '$SourcePath' has no readable top-level 'schemaVersion'. Cannot migrate."
    }
    $current = [int]$cfg.SchemaVersion

    if ($current -gt $TargetSchemaVersion) {
        throw "Convert-AzLocalScheduleSchemaVersion: '$SourcePath' is on schemaVersion=$current but this module only supports up to $TargetSchemaVersion. Upgrade the AzLocal.UpdateManagement module, then re-run Update-AzLocalApplyUpdatesScheduleConfig."
    }

    if ($current -eq $TargetSchemaVersion) {
        return [pscustomobject]@{
            Migrated    = $false
            FromVersion = $current
            ToVersion   = $TargetSchemaVersion
            NewText     = $Text
            Hops        = @()
        }
    }

    $hops = New-Object System.Collections.Generic.List[object]
    $workingText = $Text
    for ($v = $current; $v -lt $TargetSchemaVersion; $v++) {
        $key = "$v->$($v + 1)"
        # $script:ScheduleSchemaRecipes is an [ordered] dictionary, which
        # exposes .Contains() but NOT .ContainsKey() - the latter throws
        # MethodNotFound on System.Collections.Specialized.OrderedDictionary.
        if (-not $script:ScheduleSchemaRecipes.Contains($key)) {
            throw "Convert-AzLocalScheduleSchemaVersion: no migration recipe registered for '$key'. The module is missing a hop - this is a bug; file at https://github.com/NeilBird/Azure-Local/issues."
        }
        $recipe = $script:ScheduleSchemaRecipes[$key]
        $scheduleBeforeMatch = [regex]::Match($workingText, '(?ms)^schedule\s*:.*\z')
        if (-not $scheduleBeforeMatch.Success) {
            throw "Convert-AzLocalScheduleSchemaVersion: '$SourcePath' has no readable top-level 'schedule:' section before recipe '$key'. Refusing to migrate."
        }
        $scheduleBefore = $scheduleBeforeMatch.Value
        $hopResult = & $recipe $workingText
        if (-not $hopResult.ContainsKey('Text') -or -not $hopResult.ContainsKey('Changes')) {
            throw "Convert-AzLocalScheduleSchemaVersion: recipe '$key' did not return the expected @{ Text=...; Changes=... } shape."
        }
        $workingText = [string]$hopResult.Text
        $scheduleAfterMatch = [regex]::Match($workingText, '(?ms)^schedule\s*:.*\z')
        if (-not $scheduleAfterMatch.Success -or
            -not [string]::Equals($scheduleBefore, $scheduleAfterMatch.Value, [System.StringComparison]::Ordinal)) {
            throw "Convert-AzLocalScheduleSchemaVersion: recipe '$key' changed the operator-owned 'schedule:' section in '$SourcePath'. Migration was aborted before any file write."
        }
        $hops.Add([pscustomobject]@{
            FromVersion = $v
            ToVersion   = $v + 1
            Changes     = @($hopResult.Changes)
        }) | Out-Null
    }

    return [pscustomobject]@{
        Migrated    = $true
        FromVersion = $current
        ToVersion   = $TargetSchemaVersion
        NewText     = $workingText
        Hops        = $hops.ToArray()
    }
}

# =====================================================================
# Schedule schema migration recipes - dispatch table
# =====================================================================
# Each value is a ScriptBlock with signature:
#   param([string]$Text) -> @{ Text = <new YAML>; Changes = @(<strings>) }
#
# Recipes MUST be idempotent (running twice = same output as running once)
# and MUST update the top-level 'schemaVersion:' line themselves.
#
# To add a new hop in a future module version:
#   1. Bump $script:ScheduleSchemaCurrentVersion in the .psm1.
#   2. Append a recipe here with the new 'N->N+1' key.
#   3. Add tests in Tests/AzLocal.UpdateManagement.Tests.ps1 for the new
#      hop in isolation AND chained from version 1.
# =====================================================================
$script:ScheduleSchemaRecipes = [ordered]@{
    # =====================================================================
    # 1 -> 2  (shipped in v0.7.89)
    # =====================================================================
    # v2 makes the top-level 'allowedUpdateVersions' field MANDATORY and
    # adds the optional per-row override. The migration is ADDITIVE -
    # existing schedule rows are not modified:
    #   * The 'schemaVersion: 1' line is rewritten to 'schemaVersion: 2'
    #     in place (preserving leading whitespace and any trailing
    #     comment).
    #   * A documented top-level block is inserted just above the
    #     '# ---- Schedule entries ----' header (or, if missing, just
    #     before the 'schedule:' key). The block contains:
    #       (a) explanatory comments describing the new field; and
    #       (b) the active line  allowedUpdateVersions: 'Latest'
    #     'Latest' is the reserved sentinel meaning "no constraint -
    #     install the latest Ready update on each cluster" (the
    #     historic v0.7.88 behaviour), so the migrated file behaves
    #     identically to the v1 source out of the box. Operators
    #     replace 'Latest' with a semicolon-separated list of explicit
    #     update names / version strings to enforce a "minimum updates"
    #     allow-list policy fleet-wide.
    # The recipe is idempotent:
    #   * 'schemaVersion: 2' is left alone if it is already there.
    #   * The block is keyed off the literal marker
    #     '# >>> ALLOWED-UPDATE-VERSIONS-V2 <<<'. If that marker is
    #     present anywhere in the file, the block is not re-inserted.
    # Per-row allowedUpdateVersions opt-in is the operator's choice on
    # their own schedule rows; the migration does not touch row content.
    '1->2' = {
        param([string]$Text)
        $changes = New-Object System.Collections.Generic.List[string]
        $work    = $Text
        $newLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }

        # 1. Rewrite schemaVersion line.
        $svPattern = '(?m)^(\s*)schemaVersion(\s*:\s*)1(\s*(?:#.*)?)$'
        $svRegex   = [regex]::new($svPattern)
        $svMatch   = $svRegex.Match($work)
        if ($svMatch.Success) {
            $work = $svRegex.Replace($work, { param($m)
                "$($m.Groups[1].Value)schemaVersion$($m.Groups[2].Value)2$($m.Groups[3].Value)"
            }, 1)
            $changes.Add("Rewrote 'schemaVersion: 1' to 'schemaVersion: 2'.") | Out-Null
        }

        # 2. Insert the mandatory top-level block (idempotent via marker).
        $marker = '# >>> ALLOWED-UPDATE-VERSIONS-V2 <<<'
        if ($work -notmatch [regex]::Escape($marker)) {
            $block = @(
                '',
                "# ---- AllowedUpdateVersions (schema v2, MANDATORY top-level) -------",
                "# $marker",
                "# Fleet-wide allow-list of Azure Local solution-update names or",
                "# version strings that Step.6 (apply-updates) is permitted to install.",
                "#",
                "# Default 'Latest' (case-insensitive) is a reserved sentinel meaning",
                "# 'no constraint - install the latest Ready update on each cluster'",
                "# (the historic v0.7.88 default). Leave it as 'Latest' to keep your",
                "# v1 behaviour unchanged.",
                "#",
                "# To enforce a 'minimum updates' policy (~4 updates per year - YY04 +",
                "# YY10 feature updates plus the preceding YY03 + YY09 cumulative",
                "# updates), replace 'Latest' with a semicolon-separated list of",
                "# explicit update names or version strings. Clusters with no Ready",
                "# update matching the list are SKIPPED with status 'NotInAllowList'",
                "# (strict no-op; never falls back to 'latest').",
                "#",
                "# Example (uncomment + edit, replacing the 'Latest' line below):",
                "#   allowedUpdateVersions: '10.2604.0.123;10.2610.0.456'",
                "#",
                "# Per-row override: any schedule row below may set its own",
                "# 'allowedUpdateVersions:' field. Per-row beats top-level; multiple",
                "# matching rows UNION their lists; rows without the field on a",
                "# UNION day are treated as 'no opinion' (not 'allow nothing'); if",
                "# any matching row contributes 'Latest', the effective list is",
                "# 'Latest' (no constraint).",
                "allowedUpdateVersions: 'Latest'",
                ''
            ) -join $newLine

            # Prefer to insert right before the '# ---- Schedule entries' banner.
            # Fall back to inserting just before the bare 'schedule:' key.
            $headerRx = [regex]::new('(?m)^(?<spc>[ \t]*)# ---- Schedule entries[^\r\n]*[\r\n]+')
            $schedRx  = [regex]::new('(?m)^(?<spc>[ \t]*)schedule\s*:')
            $headerM  = $headerRx.Match($work)
            if ($headerM.Success) {
                $work = $work.Insert($headerM.Index, $block)
                $changes.Add("Inserted mandatory top-level 'allowedUpdateVersions: ''Latest''' block above '# ---- Schedule entries ----'.") | Out-Null
            }
            else {
                $schedM = $schedRx.Match($work)
                if ($schedM.Success) {
                    $work = $work.Insert($schedM.Index, $block)
                    $changes.Add("Inserted mandatory top-level 'allowedUpdateVersions: ''Latest''' block above 'schedule:'.") | Out-Null
                }
                else {
                    # No anchor found - append at end. Should be rare; the
                    # validator already requires a 'schedule:' key.
                    $work = $work.TrimEnd("`r","`n") + $newLine + $block + $newLine
                    $changes.Add("Appended mandatory top-level 'allowedUpdateVersions: ''Latest''' block at end (no 'schedule:' anchor found).") | Out-Null
                }
            }
        }

        return @{
            Text    = $work
            Changes = $changes.ToArray()
        }
    }

    # =====================================================================
    # 2 -> 3  (shipped in v0.9.33)
    # =====================================================================
    # v3 adds mandatory top-level prepareOnlyFirst and
    # allowPrepareOnlyOutsideOfUpdateStartWindow settings, plus optional
    # per-row overrides. Their defaults preserve all v2 automation behavior.
    '2->3' = {
        param([string]$Text)
        $changes = New-Object System.Collections.Generic.List[string]
        $work = $Text
        $newLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }

        $svRegex = [regex]::new('(?m)^(\s*)schemaVersion(\s*:\s*)2(\s*(?:#.*)?)$')
        if ($svRegex.IsMatch($work)) {
            $work = $svRegex.Replace($work, { param($m)
                "$($m.Groups[1].Value)schemaVersion$($m.Groups[2].Value)3$($m.Groups[3].Value)"
            }, 1)
            $changes.Add("Rewrote 'schemaVersion: 2' to 'schemaVersion: 3'.") | Out-Null
        }

        $marker = '# >>> PREPARE-ONLY-FIRST-V3 <<<'
        if ($work -notmatch [regex]::Escape($marker)) {
            $block = @(
                '# ---- Prepare before install (schema v3, MANDATORY) ------------',
                $marker,
                '# false preserves the existing one-step apply behavior.',
                '# true prepares Ready updates first; a later firing installs only',
                '# after they reach ReadyToInstall and UpdateStartWindow permits it.',
                '# Preparation ignores UpdateStartWindow but still honors the',
                '# UpdateExclusionsWindow hard blackout.',
                '# Any schedule row may override this boolean for that firing.',
                'prepareOnlyFirst: false',
                '# true allows out-of-window preparation; false requires the',
                '# preparation phase to pass the UpdateStartWindow gate.',
                'allowPrepareOnlyOutsideOfUpdateStartWindow: true',
                ''
            ) -join $newLine

            $header = [regex]::Match($work, '(?m)^# ---- Schedule entries[^\r\n]*[\r\n]+')
            $scheduleKey = [regex]::Match($work, '(?m)^schedule\s*:')
            if ($header.Success) {
                $work = $work.Insert($header.Index, $block)
            }
            elseif ($scheduleKey.Success) {
                $work = $work.Insert($scheduleKey.Index, $block)
            }
            else {
                $work = $work.TrimEnd("`r", "`n") + $newLine + $block + $newLine
            }
            $changes.Add("Inserted mandatory top-level 'prepareOnlyFirst: false' and 'allowPrepareOnlyOutsideOfUpdateStartWindow: true' settings.") | Out-Null
        }

        return @{ Text = $work; Changes = $changes.ToArray() }
    }
}
