function Convert-AzLocalFleetSettingsSchemaVersion {
    <#
    .SYNOPSIS
        Upgrades fleet-settings.yml schema v1 or v2 text to schema v3.
    .DESCRIPTION
        Schema v1 receives the grouped tag-filter example. Schema v2 flat tag
        pairs are converted to named one-tag groups, preserving their OR intent.
        Existing comments, ordering, and line endings are preserved. Schema v3
        text is returned unchanged.
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
                ToVersion   = 3
                NewText     = $Text
                Reason      = 'NoSchemaDeclaration'
            }
        }
    }
    if ($matches.Count -ne 1) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' contains multiple schemaVersion declarations."
    }

    $currentVersion = [int]$matches[0].Groups[2].Value
    if ($currentVersion -gt 3) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' uses schemaVersion $currentVersion, which is newer than this module supports."
    }
    if ($currentVersion -eq 3) {
        return [pscustomobject]@{
            Migrated    = $false
            FromVersion = 3
            ToVersion   = 3
            NewText     = $Text
            Reason      = 'Current'
        }
    }
    if ($currentVersion -notin @(1, 2)) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' uses unsupported schemaVersion $currentVersion."
    }

    $match = $matches[0]
    $replacement = $match.Groups[1].Value + '3' + $match.Groups[3].Value
    $newText = $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)
    $newText = [regex]::Replace($newText, '(?im)(fleet settings \(schema version )\d+(\))', '${1}3${2}')
    $newText = [regex]::Replace($newText, '(?m)^(\s*#\s*AZLOCAL-FLEET-SETTINGS-SCHEMA-)V[12](\s*)$', '${1}V3${2}')

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $settingsMarker = '# AZLOCAL-FLEET-SETTINGS-SCHEMA-V3'
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

    return [pscustomobject]@{
        Migrated    = $true
        FromVersion = $currentVersion
        ToVersion   = 3
        NewText     = $newText
        Reason      = 'Upgraded'
    }
}