function Convert-AzLocalSideloadCatalogSchemaVersion {
    <#
    .SYNOPSIS
        Migrates a sideload-catalog.yml file from an older schema version to
        the module's current schema version (or any chosen target). Text-surgery
        based - operator comments, SBE (OEM) entries, and row order are
        preserved verbatim.

    .DESCRIPTION
        Sibling of Convert-AzLocalScheduleSchemaVersion.ps1 (the schedule-file
        migrator) and follows the IDENTICAL design so the two schema frameworks
        behave the same way.

        The function walks the per-hop recipe table registered in this file
        (see $script:SideloadCatalogSchemaRecipes below). Each recipe is a
        ScriptBlock with signature:

            param([string]$Text) -> @{ Text = <new>; Changes = @(<strings>) }

        Recipes operate on RAW TEXT, not on the parsed structure. This is
        deliberate so operator-authored YAML comments, manually-staged SBE
        (OEM) package entries, and download/TODO annotations survive every
        migration hop. Each recipe is expected to be IDEMPOTENT: running it
        twice on the same input must produce the same output, and MUST update
        the top-level 'schemaVersion:' line itself.

        Walker behaviour (identical to the schedule migrator):
          * If $current == $target  -> return Migrated=$false (no-op).
          * If $current  > $target  -> throw (downgrade requested; bad).
          * If $current  < $target  -> walk recipes $current -> $current+1
                                       -> ... -> $target. If any hop is
                                       missing from the table, throw.

        The recipe table ships EMPTY at schema v1: there is no hop to run yet,
        so a v1 catalog is always a no-op. The framework exists so the FIRST
        non-additive catalog format change is a small, well-tested recipe
        addition rather than a from-scratch build.

        Backup-on-write is performed by the caller
        (Update-AzLocalSideloadCatalog -SchemaMigrate) - this function only
        computes the new text and reports what changed.

    .PARAMETER Text
        Raw YAML text of the customer's catalog file.

    .PARAMETER TargetSchemaVersion
        Schema version to migrate TO. Default: this module's current
        ($script:SideloadCatalogSchemaCurrentVersion). Tests can override to
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
        [int]$TargetSchemaVersion = $script:SideloadCatalogSchemaCurrentVersion,

        [Parameter(Mandatory = $false)]
        [string]$SourcePath = '<inline>'
    )

    # Read the current schemaVersion straight from the text. The catalog has
    # no struct parser that surfaces schemaVersion, so a narrow regex is used.
    # A catalog with NO schemaVersion line is treated as v1 (back-compat: the
    # v1 reader ignored the field, so early files may omit it).
    $current = 1
    $svMatch = [regex]::Match($Text, '(?m)^\s*schemaVersion\s*:\s*(\d+)\b')
    if ($svMatch.Success) {
        $current = [int]$svMatch.Groups[1].Value
    }

    if ($current -gt $TargetSchemaVersion) {
        throw "Convert-AzLocalSideloadCatalogSchemaVersion: '$SourcePath' is on schemaVersion=$current but this module only supports up to $TargetSchemaVersion. Upgrade the AzLocal.UpdateManagement module, then re-run Update-AzLocalSideloadCatalog -SchemaMigrate."
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
        # $script:SideloadCatalogSchemaRecipes is an [ordered] dictionary,
        # which exposes .Contains() but NOT .ContainsKey() - the latter throws
        # MethodNotFound on System.Collections.Specialized.OrderedDictionary.
        if (-not $script:SideloadCatalogSchemaRecipes.Contains($key)) {
            throw "Convert-AzLocalSideloadCatalogSchemaVersion: no migration recipe registered for '$key'. The module is missing a hop - this is a bug; file at https://github.com/NeilBird/Azure-Local/issues."
        }
        $recipe = $script:SideloadCatalogSchemaRecipes[$key]
        $hopResult = & $recipe $workingText
        if (-not $hopResult.ContainsKey('Text') -or -not $hopResult.ContainsKey('Changes')) {
            throw "Convert-AzLocalSideloadCatalogSchemaVersion: recipe '$key' did not return the expected @{ Text=...; Changes=... } shape."
        }
        $workingText = [string]$hopResult.Text
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
# Sideload-catalog schema migration recipes - dispatch table
# =====================================================================
# Each value is a ScriptBlock with signature:
#   param([string]$Text) -> @{ Text = <new YAML>; Changes = @(<strings>) }
#
# Recipes MUST be idempotent (running twice = same output as running once)
# and MUST update the top-level 'schemaVersion:' line themselves.
#
# The table ships EMPTY at schema v1 - there is no migration hop to run yet.
# This is intentional: the framework is wired up (engine + version var +
# reader guard + -SchemaMigrate entry point) so that the FIRST non-additive
# catalog format change is a small, well-tested recipe addition.
#
# To add the first hop in a future module version:
#   1. Bump $script:SideloadCatalogSchemaCurrentVersion in the .psm1.
#   2. Append a recipe here with the new 'N->N+1' key (text-surgery,
#      idempotent, marker-keyed - see the schedule recipe table in
#      Private/Convert-AzLocalScheduleSchemaVersion.ps1 for a worked
#      example that preserves operator comments and rows verbatim).
#   3. Add tests in Tests/AzLocal.UpdateManagement.Tests.ps1 for the new
#      hop in isolation AND chained from version 1.
# =====================================================================
$script:SideloadCatalogSchemaRecipes = [ordered]@{}
