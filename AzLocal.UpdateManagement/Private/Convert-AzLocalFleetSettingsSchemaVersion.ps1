function Convert-AzLocalFleetSettingsSchemaVersion {
    <#
    .SYNOPSIS
        Upgrades fleet-settings.yml schema v1, v2, or v3 text to schema v4.
    .DESCRIPTION
        Schema v1 receives the grouped tag-filter example. Schema v2 flat tag
        pairs are converted to named one-tag groups, preserving their OR intent.
        Schema v4 adds independent before/after allowances for UpdateStartWindow.
        Existing comments and line endings are preserved, while recognized
        top-level sections are placed in the canonical v4 order: scope,
        updateStartWindow, reporting, itsm. Schema v4 text is returned unchanged.
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

    $matches = [regex]::Matches($Text, '(?m)^(\s*schemaVersion\s*:\s*)(\d+)(\s*(?:#.*)?)$')
    if ($matches.Count -eq 0) {
        $matches = [regex]::Matches($Text, '(?m)^(\s*#\s*schemaVersion\s*:\s*)(\d+)(\s*)$')
        if ($matches.Count -eq 0) {
            return [pscustomobject]@{
                Migrated    = $false
                FromVersion = $null
                ToVersion   = 4
                NewText     = $Text
                Reason      = 'NoSchemaDeclaration'
            }
        }
    }
    if ($matches.Count -ne 1) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' contains multiple schemaVersion declarations."
    }

    $currentVersion = [int]$matches[0].Groups[2].Value
    if ($currentVersion -gt 4) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' uses schemaVersion $currentVersion, which is newer than this module supports."
    }
    if ($currentVersion -eq 4) {
        return [pscustomobject]@{
            Migrated    = $false
            FromVersion = 4
            ToVersion   = 4
            NewText     = $Text
            Reason      = 'Current'
        }
    }
    if ($currentVersion -notin @(1, 2, 3)) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' uses unsupported schemaVersion $currentVersion."
    }

    $match = $matches[0]
    $replacement = $match.Groups[1].Value + '4' + $match.Groups[3].Value
    $newText = $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)
    $newText = [regex]::Replace($newText, '(?im)(fleet settings \(schema version )\d+(\))', '${1}4${2}')
    $newText = [regex]::Replace($newText, '(?m)^(\s*#\s*AZLOCAL-FLEET-SETTINGS-SCHEMA-)V[123](\s*)$', '${1}V4${2}')

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $settingsMarker = '# AZLOCAL-FLEET-SETTINGS-SCHEMA-V4'
    if ($currentVersion -eq 2 -and $newText -match '(?im)^\s*(?:#\s*)?clusterTagFilters\s*:') {
        $lines = [regex]::Split($newText, '\r?\n')
        $convertedLines = [System.Collections.Generic.List[string]]::new()
        $inTagFilters = $false
        $commentPrefix = ''
        foreach ($line in $lines) {
            $logicalLine = $line
            $lineCommentPrefix = ''
            if ($line -match '^(?<prefix>\s*#\s?)(?<content>.*)$') {
                $lineCommentPrefix = $Matches.prefix
                $logicalLine = $Matches.content
            }
            if ($logicalLine -match '^\s{2}clusterTagFilters\s*:') {
                $inTagFilters = $true
                $commentPrefix = $lineCommentPrefix
                [void]$convertedLines.Add($line)
                continue
            }
            if ($inTagFilters -and $logicalLine -match '^\S|^\s{2}\S') {
                $inTagFilters = $false
            }
            if ($inTagFilters -and $logicalLine -match '^\s{4}-\s*name\s*:\s*(.*?)\s*$') {
                $rawName = $Matches[1]
                [void]$convertedLines.Add($line)
                [void]$convertedLines.Add("${commentPrefix}      tags:")
                [void]$convertedLines.Add("${commentPrefix}        - name: $rawName")
                continue
            }
            if ($inTagFilters -and $logicalLine -match '^\s{6}value\s*:\s*(.*?)\s*$') {
                [void]$convertedLines.Add("${commentPrefix}          value: $($Matches[1])")
                continue
            }
            [void]$convertedLines.Add($line)
        }
        $newText = $convertedLines -join $newline
    }
    elseif ($newText -notmatch '(?im)^\s*#?\s*clusterTagFilters\s*:') {
        $commentedSettings = @(
            $settingsMarker
            '# Optional global cluster admission policy. Tags in a group use AND; groups use OR.'
            '# Matching is exact and case-insensitive; a missing tag does not match its group.'
            '# Add these lines beneath your active scope block when enabling the policy:'
            '#   clusterTagFilters:'
            '#     - name: Production'
            '#       tags:'
            '#         - name: Environment'
            '#           value: Production'
            '#         - name: ManagedBy'
            '#           value: CentralIT'
            '#     - name: Test'
            '#       tags:'
            '#         - name: Environment'
            '#           value: Test'
        ) -join $newline
        if ($newText.Length -gt 0 -and -not $newText.EndsWith($newline)) {
            $newText += $newline
        }
        $newText += $newline + $commentedSettings + $newline
    }

    if ($newText -notmatch '(?im)^\s*#?\s*updateStartWindow\s*:') {
        $toleranceSettings = @(
            '# Optional UTC allowance around every cluster UpdateStartWindow tag.'
            '# Values are independent, accept 0 to 60 minutes, and default to 0.'
            '# updateStartWindow:'
            '#   allowBeforeMinutes: 0'
            '#   allowAfterMinutes: 0'
        ) -join $newline
        if ($newText.Length -gt 0 -and -not $newText.EndsWith($newline)) {
            $newText += $newline
        }
        $newText += $newline + $toleranceSettings + $newline
    }

    # Reorder recognized top-level blocks to match fleet-settings.example.yml.
    # A contiguous documentation paragraph immediately before a heading moves
    # with that heading. A blank/comment-only separator line marks the boundary
    # from the preceding section, which keeps fully commented starters ordered
    # without attaching reporting guidance to scope (or ITSM guidance to reporting).
    $sectionLines = [regex]::Split($newText, '\r?\n')
    $sectionHeadings = [System.Collections.Generic.List[object]]::new()
    for ($lineIndex = 0; $lineIndex -lt $sectionLines.Count; $lineIndex++) {
        if ($sectionLines[$lineIndex] -match '^(?:#\s*)?(scope|updateStartWindow|reporting|itsm)\s*:') {
            [void]$sectionHeadings.Add([pscustomobject]@{
                Name        = $Matches[1]
                HeadingLine = $lineIndex
                StartLine   = $lineIndex
            })
        }
    }
    if ($sectionHeadings.Count -gt 0) {
        $sectionNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        for ($headingIndex = 0; $headingIndex -lt $sectionHeadings.Count; $headingIndex++) {
            $heading = $sectionHeadings[$headingIndex]
            if (-not $sectionNames.Add($heading.Name)) {
                throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' contains multiple '$($heading.Name)' sections."
            }

            $minimumLine = if ($headingIndex -gt 0) { $sectionHeadings[$headingIndex - 1].HeadingLine + 1 } else { 0 }
            $candidateStart = $heading.HeadingLine
            for ($precedingLine = $heading.HeadingLine - 1; $precedingLine -ge $minimumLine; $precedingLine--) {
                $line = $sectionLines[$precedingLine]
                if ($line -match '^\s*(?:#\s*)?$') {
                    break
                }
                if ($line -match '^\s*#') {
                    $candidateStart = $precedingLine
                    continue
                }
                break
            }
            $heading.StartLine = $candidateStart
        }

        $sections = @{}
        for ($headingIndex = 0; $headingIndex -lt $sectionHeadings.Count; $headingIndex++) {
            $heading = $sectionHeadings[$headingIndex]
            $endLine = if ($headingIndex + 1 -lt $sectionHeadings.Count) {
                $sectionHeadings[$headingIndex + 1].StartLine - 1
            }
            else {
                $sectionLines.Count - 1
            }
            $sections[$heading.Name] = @($sectionLines[$heading.StartLine..$endLine]) -join $newline
        }

        $preambleEnd = $sectionHeadings[0].StartLine - 1
        $orderedBlocks = [System.Collections.Generic.List[string]]::new()
        if ($preambleEnd -ge 0) {
            $preamble = @($sectionLines[0..$preambleEnd]) -join $newline
            $preamble = $preamble.TrimEnd("`r", "`n")
            if ($preamble) { [void]$orderedBlocks.Add($preamble) }
        }
        foreach ($sectionName in @('scope', 'updateStartWindow', 'reporting', 'itsm')) {
            if ($sections.ContainsKey($sectionName)) {
                [void]$orderedBlocks.Add(([string]$sections[$sectionName]).Trim("`r", "`n"))
            }
        }
        $newText = ($orderedBlocks -join ($newline + $newline)) + $newline
    }

    return [pscustomobject]@{
        Migrated    = $true
        FromVersion = $currentVersion
        ToVersion   = 4
        NewText     = $newText
        Reason      = 'Upgraded'
    }
}