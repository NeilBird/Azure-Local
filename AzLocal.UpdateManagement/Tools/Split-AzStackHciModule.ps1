<#
.SYNOPSIS
    One-shot refactor tool: split AzStackHci.ManageUpdates.psm1 into
    Public/<func>.ps1 + Private/<func>.ps1 dot-sourced files.

.DESCRIPTION
    Uses the PowerShell AST (NOT regex) to find every top-level
    FunctionDefinitionAst, extracts its exact source extent verbatim,
    and writes one file per function. The original .psm1 is then
    regenerated as a thin shell (prologue + NestedModules dot-source
    fallback + Export-ModuleMember) and the .psd1 is updated with
    a NestedModules list.

    Intended to be run ONCE. The script is checked in for audit / replay
    only; routine builds do not need it.

    HISTORICAL: This script was used once against AzStackHci.ManageUpdates
    (the monolithic v0.7.2 .psm1). The module has since been renamed to
    AzLocal.UpdateManagement (v0.7.3). The path references inside this
    script ('AzStackHci.ManageUpdates.psm1' / '.psd1') are preserved
    verbatim as an accurate record of what was processed. The script
    is NOT runnable in the current layout - re-running it would target
    files that no longer exist under those names.

.NOTES
    Source-of-truth for which functions are public: the manifest's
    FunctionsToExport list. Anything not in that list is treated as
    private.

    All file writes use UTF-8 NO BOM via [IO.File]::WriteAllText to
    avoid the cp1252 / mojibake failure modes called out in the user's
    PowerShell-patterns memory.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ModuleRoot = (Join-Path $PSScriptRoot '..'),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModuleRoot = (Resolve-Path -LiteralPath $ModuleRoot).Path
$psm1Path   = Join-Path $ModuleRoot 'AzStackHci.ManageUpdates.psm1'
$psd1Path   = Join-Path $ModuleRoot 'AzStackHci.ManageUpdates.psd1'
$publicDir  = Join-Path $ModuleRoot 'Public'
$privateDir = Join-Path $ModuleRoot 'Private'

if (-not (Test-Path -LiteralPath $psm1Path)) { throw "psm1 not found: $psm1Path" }
if (-not (Test-Path -LiteralPath $psd1Path)) { throw "psd1 not found: $psd1Path" }

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# --- 1. Parse manifest to get the authoritative public-function list ---
$manifest = Import-PowerShellDataFile -LiteralPath $psd1Path
$publicNames = @($manifest.FunctionsToExport) | Where-Object { $_ -and $_ -ne '*' }
if (-not $publicNames -or $publicNames.Count -eq 0) {
    throw "Manifest FunctionsToExport is empty or wildcard; cannot determine public set."
}
Write-Host ("[manifest] {0} public function(s) declared in FunctionsToExport" -f $publicNames.Count)

# --- 2. Parse the psm1 with the PowerShell AST ---
$tokens    = $null
$parseErrs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($psm1Path, [ref]$tokens, [ref]$parseErrs)
if ($parseErrs -and $parseErrs.Count -gt 0) {
    $parseErrs | ForEach-Object { Write-Warning $_ }
    throw "Parser reported $($parseErrs.Count) errors. Aborting."
}

# Read raw text once for extent-slicing.
$rawText = [IO.File]::ReadAllText($psm1Path, $utf8NoBom)

# Find top-level function definitions only (not nested inside other functions / classes).
$allFnAst = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)
$topFns = @($allFnAst | Where-Object {
        $p = $_.Parent
        while ($p -and -not ($p -is [System.Management.Automation.Language.ScriptBlockAst] -and $p.Parent -is [System.Management.Automation.Language.ScriptBlockAst] -eq $false)) {
            if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
            $p = $p.Parent
        }
        # Top-level: its closest function-ancestor must be itself
        $cur = $_.Parent
        while ($cur) {
            if ($cur -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $false }
            $cur = $cur.Parent
        }
        return $true
    })

Write-Host ("[ast] {0} top-level function definitions found" -f $topFns.Count)

# --- 3. Sort, capture inter-function NON-function statements ---
# IMPORTANT: a previous version of this script only collected FunctionDefinitionAst nodes,
# which silently dropped 6 non-function top-level statements - notably the
# $script:DayAbbreviations / $script:UpdateStartWindowTagName / $script:UpdateSideloadedTagName
# / $script:UpdateVersionInProgressTagName / $script:DayMap / $script:FleetOperationState
# initialisers that were defined BETWEEN function definitions in the monolithic .psm1.
# We now walk EndBlock.Statements and segregate functions from everything else, then
# fold the non-function statements back into the prologue text so module-scope state
# survives the refactor.
$topFns = $topFns | Sort-Object { $_.Extent.StartLineNumber }
$first  = $topFns[0]
$last   = $topFns[-1]
Write-Host ("[range] first function: L{0} {1}" -f $first.Extent.StartLineNumber, $first.Name)
Write-Host ("[range] last  function: L{0} {1}" -f $last.Extent.EndLineNumber,   $last.Name)

# Inter-function and post-function top-level statements (everything in EndBlock.Statements
# that is NOT a function). We keep their VERBATIM source via Extent.Text.
$allStmts   = @($ast.EndBlock.Statements)
$nonFnStmts = @($allStmts | Where-Object { -not ($_ -is [System.Management.Automation.Language.FunctionDefinitionAst]) })
Write-Host ("[ast] {0} non-function top-level statements (will be hoisted into .psm1)" -f $nonFnStmts.Count)

# Build the prologue from line-based slicing of the original text so we preserve
# every comment, blank line, and `Set-StrictMode` / `Requires` directive exactly.
$prologueLines = $rawText -split "`r?`n"
$preFirstFn    = ($prologueLines[0..($first.Extent.StartLineNumber - 2)] -join "`r`n") + "`r`n"

# Gather any non-function statements that appear AFTER the first function but BEFORE the last.
# These go into a single "hoisted module-scope state" block in the prologue so they are
# defined before any dot-sourced function runs.
$interFnStmts = @($nonFnStmts | Where-Object { $_.Extent.StartLineNumber -gt $first.Extent.StartLineNumber -and $_.Extent.EndLineNumber -lt $last.Extent.EndLineNumber })
if ($interFnStmts.Count -gt 0) {
    $hoistBlock  = "`r`n# ---------------------------------------------------------------------------`r`n"
    $hoistBlock += "# Module-scope state hoisted from between function definitions during refactor.`r`n"
    $hoistBlock += "# These declarations must run BEFORE any function body that references them.`r`n"
    $hoistBlock += "# ---------------------------------------------------------------------------`r`n"
    foreach ($s in $interFnStmts) {
        $hoistBlock += ($s.Extent.Text.TrimEnd() + "`r`n`r`n")
    }
} else {
    $hoistBlock = ''
}

# Anything AFTER the last function (e.g. the closing Export-ModuleMember) becomes the epilogue.
$postLastFnStmts = @($nonFnStmts | Where-Object { $_.Extent.StartLineNumber -gt $last.Extent.EndLineNumber })
$epilogue = if ($postLastFnStmts.Count -gt 0) {
    ($postLastFnStmts | ForEach-Object { $_.Extent.Text.TrimEnd() }) -join "`r`n`r`n"
} else { '' }

$prologue = $preFirstFn + $hoistBlock
Write-Host ("[prologue] {0} bytes" -f $prologue.Length)
Write-Host ("[epilogue] {0} bytes ({1} statements)" -f $epilogue.Length, $postLastFnStmts.Count)

# Compose the new thin psm1 body. We use a deterministic dot-source loader keyed
# off the manifest's NestedModules list - this matches AzLocal.DeploymentAutomation's pattern.
$loader = @'

# ---------------------------------------------------------------------------
# Dot-source all function files listed in the manifest's NestedModules.
# When loaded via the .psd1, these are already imported by NestedModules; this
# loop is a harmless no-op in that case (PowerShell tolerates redefinition).
# When loaded via the .psm1 directly (e.g. some Pester scenarios), this
# guarantees all functions are present in the module scope.
# ---------------------------------------------------------------------------
$manifestPath = Join-Path -Path $PSScriptRoot -ChildPath 'AzStackHci.ManageUpdates.psd1'
if (Test-Path -LiteralPath $manifestPath) {
    $manifestData = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction SilentlyContinue
    if ($manifestData -and $manifestData.NestedModules) {
        foreach ($nestedModule in $manifestData.NestedModules) {
            $nestedPath = Join-Path -Path $PSScriptRoot -ChildPath $nestedModule
            if (Test-Path -LiteralPath $nestedPath) {
                . $nestedPath
            }
        }
    }
}
'@

# --- 4. Decide destination for each function and build file content ---
$publicSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($n in $publicNames) { [void]$publicSet.Add($n) }

$plans = New-Object System.Collections.Generic.List[object]
foreach ($fn in $topFns) {
    $isPublic = $publicSet.Contains($fn.Name)
    $destDir  = if ($isPublic) { 'Public' } else { 'Private' }
    $destPath = Join-Path (Join-Path $ModuleRoot $destDir) ($fn.Name + '.ps1')
    # Use Extent.Text - returns the verbatim source text for this AST node, no offset math.
    # (Avoids CRLF/LF offset-shift bugs in some PowerShell versions where StartOffset is reported
    # in LF-normalized space but our raw read is CRLF.)
    $body     = $fn.Extent.Text
    $plans.Add([pscustomobject]@{
        Name      = $fn.Name
        IsPublic  = $isPublic
        DestPath  = $destPath
        RelPath   = ((Join-Path $destDir ($fn.Name + '.ps1')) -replace '\\','/')
        Body      = $body
        StartLine = $fn.Extent.StartLineNumber
        EndLine   = $fn.Extent.EndLineNumber
    })
}

$pubCount = ($plans | Where-Object IsPublic).Count
$prvCount = ($plans | Where-Object { -not $_.IsPublic }).Count
Write-Host ("[plan] {0} public + {1} private = {2} total files" -f $pubCount, $prvCount, $plans.Count)

# Sanity check: every name in FunctionsToExport must have a matching function defined.
$definedNames = @($plans | Select-Object -ExpandProperty Name)
$missing = @($publicNames | Where-Object { $_ -notin $definedNames })
if ($missing.Count -gt 0) {
    throw ("Public names in manifest with no function definition in psm1: {0}" -f ($missing -join ', '))
}

# Detect duplicates (would clobber files)
$dupes = $plans | Group-Object Name | Where-Object Count -gt 1
if ($dupes) {
    throw ("Duplicate function definitions detected: {0}" -f (($dupes | ForEach-Object Name) -join ', '))
}

if ($DryRun) {
    Write-Host "[dry-run] Plan summary:"
    $plans | Sort-Object IsPublic, Name -Descending | Select-Object @{n='Where';e={if($_.IsPublic){'Public'}else{'Private'}}}, Name, StartLine, EndLine | Format-Table -AutoSize
    return
}

# --- 5. Write Public/ and Private/ files ---
foreach ($dir in @($publicDir, $privateDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Path $dir)
    }
}

foreach ($p in $plans) {
    # Trim leading blank lines so the file starts on the `function` keyword cleanly,
    # and ensure exactly one trailing newline.
    $content = $p.Body -replace "^\s*\r?\n",""
    if ($content[-1] -ne "`n") { $content += "`r`n" }
    [IO.File]::WriteAllText($p.DestPath, $content, $utf8NoBom)
}
Write-Host ("[write] wrote {0} function file(s)" -f $plans.Count)

# --- 6. Regenerate the .psm1 ---
$newPsm1 = $prologue.TrimEnd() + "`r`n" + $loader + "`r`n" + $epilogue.TrimStart()
[IO.File]::WriteAllText($psm1Path, $newPsm1, $utf8NoBom)
Write-Host ("[write] regenerated {0} ({1} bytes)" -f $psm1Path, $newPsm1.Length)

# --- 7. Update the .psd1 NestedModules list ---
# Build the new NestedModules list: Private/ first (alphabetical), then Public/ (alphabetical).
$privList = $plans | Where-Object { -not $_.IsPublic } | Sort-Object Name | ForEach-Object { $_.RelPath }
$pubList  = $plans | Where-Object IsPublic           | Sort-Object Name | ForEach-Object { $_.RelPath }
$nestedAll = @($privList) + @($pubList)

# Render the NestedModules list as a PowerShell array literal that fits the existing manifest style.
$indent = '        '
$rendered = "@(`r`n"
$rendered += "        # Private helpers (loaded first)`r`n"
foreach ($r in $privList) { $rendered += "$indent'" + $r + "',`r`n" }
$rendered += "`r`n        # Public exported functions`r`n"
for ($i = 0; $i -lt $pubList.Count; $i++) {
    $sep = if ($i -lt $pubList.Count - 1) { "',`r`n" } else { "'`r`n" }
    $rendered += "$indent'" + $pubList[$i] + $sep
}
$rendered += "    )"

$psd1Text = [IO.File]::ReadAllText($psd1Path, $utf8NoBom)

# Find existing NestedModules entry (if any). We allow:
#   NestedModules = @()
#   NestedModules = @('a','b')
#   # NestedModules = @(...)   <- commented out (current state)
# Replace the first uncommented occurrence; if none, inject before FunctionsToExport.
$nmRegex = [regex]'(?ms)^\s*NestedModules\s*=\s*@\([^\)]*\)'
$commentedNmRegex = [regex]'(?m)^\s*#\s*NestedModules\s*=\s*@\(\s*\)\s*$'

if ($nmRegex.IsMatch($psd1Text)) {
    $psd1Text = $nmRegex.Replace($psd1Text, "    NestedModules = $rendered", 1)
    Write-Host "[psd1] replaced existing uncommented NestedModules entry"
} elseif ($commentedNmRegex.IsMatch($psd1Text)) {
    $psd1Text = $commentedNmRegex.Replace($psd1Text, "    NestedModules = $rendered", 1)
    Write-Host "[psd1] replaced commented-out NestedModules placeholder"
} else {
    # Inject just before FunctionsToExport block
    $injectRegex = [regex]'(?m)^(\s*)FunctionsToExport\s*='
    if (-not $injectRegex.IsMatch($psd1Text)) { throw "Could not find FunctionsToExport in manifest" }
    $psd1Text = $injectRegex.Replace($psd1Text, "    NestedModules = $rendered`r`n`r`n`$1FunctionsToExport =", 1)
    Write-Host "[psd1] injected new NestedModules entry before FunctionsToExport"
}
[IO.File]::WriteAllText($psd1Path, $psd1Text, $utf8NoBom)
Write-Host "[done] Refactor complete. Run Pester to verify."
