#requires -Version 5.1
<#
    Insert BEGIN/END-AZLOCAL-CUSTOMIZE markers around operator-customizable
    structural values in the bundled pipeline YAMLs.

    Targets:
      ADO (azure-devops/*.yml):
        - service-connection : each 'azureSubscription:' line (single line)
        - runner-target / sideload-runner : each 'pool:' block (multi-line);
          sideload-runner when the block mentions 'azlocal-sideload', else runner-target
      GH (github-actions/*.yml):
        - runner-target / sideload-runner : each 'runs-on:' line (single line);
          sideload-runner when the line mentions 'azlocal-sideload', else runner-target

    Region names are made unique per file via a context suffix (nearest
    stage/job for ADO, nearest job id for GH) plus a collision counter.

    Line-based (NOT regex) to avoid structural corruption. UTF-8 no BOM,
    newline style preserved. Idempotent (skips already-wrapped targets).

    Dry-run by default; pass -Apply to write.
#>
[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'Automation-Pipeline-Examples'
$enc  = [System.Text.UTF8Encoding]::new($false)

function Get-Indent {
    param([string]$Line)
    return ($Line.Length - $Line.TrimStart().Length)
}

function Get-AdoContext {
    param([System.Collections.Generic.List[string]]$Lines, [int]$From)
    for ($k = $From - 1; $k -ge 0; $k--) {
        $t = $Lines[$k].Trim()
        $m = [regex]::Match($t, '^-?\s*(?:stage|job):\s*''?([A-Za-z0-9_.-]+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return 'pipeline'
}

function Get-GhContext {
    param([System.Collections.Generic.List[string]]$Lines, [int]$From)
    for ($k = $From - 1; $k -ge 0; $k--) {
        $m = [regex]::Match($Lines[$k], '^  ([A-Za-z0-9_.-]+):\s*$')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return 'job'
}

function Sanitize {
    param([string]$S)
    return ([regex]::Replace($S, '[^A-Za-z0-9_-]', '-'))
}

$report = New-Object System.Collections.Generic.List[pscustomobject]

foreach ($platform in @('azure-devops', 'github-actions')) {
    $isAdo = $platform -eq 'azure-devops'
    $dir = Join-Path $root $platform
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.yml' -File | Sort-Object Name) {
        $text = [System.IO.File]::ReadAllText($file.FullName, $enc)
        $crlf = $text.Contains("`r`n")
        $lf   = $text -replace "`r`n", "`n"
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($l in ($lf -split "`n")) { [void]$lines.Add($l) }

        # ---- collect target specs -------------------------------------
        $specs = New-Object System.Collections.Generic.List[pscustomobject]
        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            $trim = $line.TrimStart()

            if ($isAdo -and $trim.StartsWith('azureSubscription:')) {
                $specs.Add([pscustomobject]@{ Start = $i; End = $i; Base = 'service-connection' })
                continue
            }
            if ($isAdo -and ($trim -eq 'pool:' -or $trim.StartsWith('pool:'))) {
                $poolIndent = Get-Indent $line
                $j = $i
                while (($j + 1) -lt $lines.Count) {
                    $nxt = $lines[$j + 1]
                    if ($nxt.Trim() -eq '') { break }
                    if ((Get-Indent $nxt) -le $poolIndent) { break }
                    $j++
                }
                $blockText = ($lines[$i..$j] -join "`n")
                $base = if ($blockText -match 'azlocal-sideload') { 'sideload-runner' } else { 'runner-target' }
                $specs.Add([pscustomobject]@{ Start = $i; End = $j; Base = $base })
                continue
            }
            if (-not $isAdo -and $trim.StartsWith('runs-on:')) {
                $base = if ($line -match 'azlocal-sideload') { 'sideload-runner' } else { 'runner-target' }
                $specs.Add([pscustomobject]@{ Start = $i; End = $i; Base = $base })
                continue
            }
        }

        if ($specs.Count -eq 0) { continue }

        # ---- assign unique region names -------------------------------
        $used = @{}
        foreach ($s in $specs) {
            $ctx = if ($isAdo) { Get-AdoContext $lines $s.Start } else { Get-GhContext $lines $s.Start }
            $region = Sanitize("$($s.Base)-$ctx")
            $candidate = $region
            $n = 1
            while ($used.ContainsKey($candidate)) { $n++; $candidate = "$region-$n" }
            $used[$candidate] = $true
            $s | Add-Member -NotePropertyName Region -NotePropertyValue $candidate
            $s | Add-Member -NotePropertyName Indent -NotePropertyValue (Get-Indent $lines[$s.Start])
        }

        # ---- idempotency: skip targets already wrapped ----------------
        $specs = @($specs | Where-Object {
            $above = if ($_.Start -gt 0) { $lines[$_.Start - 1] } else { '' }
            -not ($above -match 'BEGIN-AZLOCAL-CUSTOMIZE')
        })
        if ($specs.Count -eq 0) { continue }

        # ---- insert markers, descending by Start ----------------------
        foreach ($s in ($specs | Sort-Object Start -Descending)) {
            $pad = ' ' * $s.Indent
            $begin = "$pad# BEGIN-AZLOCAL-CUSTOMIZE:$($s.Region)"
            $end   = "$pad# END-AZLOCAL-CUSTOMIZE:$($s.Region)"
            $lines.Insert($s.End + 1, $end)
            $lines.Insert($s.Start, $begin)
            $report.Add([pscustomobject]@{
                File   = "$platform/$($file.Name)"
                Line   = $s.Start + 1
                Span   = ($s.End - $s.Start + 1)
                Region = $s.Region
            })
        }

        if ($Apply) {
            $out = ($lines -join "`n")
            if ($crlf) { $out = $out -replace "`n", "`r`n" }
            [System.IO.File]::WriteAllText($file.FullName, $out, $enc)
        }
    }
}

$report | Sort-Object File, Line | ForEach-Object {
    Write-Host ("{0,-48} L{1,-5} span={2} {3}" -f $_.File, $_.Line, $_.Span, $_.Region)
}
Write-Host ""
Write-Host ("TOTAL marker pairs: {0}  (Apply={1})" -f $report.Count, $Apply.IsPresent)
# uniqueness check per file
$dupes = $report | Group-Object File | ForEach-Object {
    $g = $_.Group | Group-Object Region | Where-Object Count -gt 1
    if ($g) { [pscustomobject]@{ File = $_.Name; Dupes = ($g.Name -join ',') } }
}
if ($dupes) { Write-Host "DUPLICATE REGION NAMES:" -ForegroundColor Red; $dupes | Format-Table -AutoSize }
else { Write-Host "All region names unique within each file." -ForegroundColor Green }
