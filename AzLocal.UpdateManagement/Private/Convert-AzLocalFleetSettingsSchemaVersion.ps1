function Convert-AzLocalFleetSettingsSchemaVersion {
    <#
    .SYNOPSIS
        Upgrades active fleet-settings.yml schema v1 text to schema v2.
    .DESCRIPTION
        Performs narrow text surgery on the active top-level schemaVersion
        declaration, or on the single commented declaration in a legacy inert
        starter, then appends the new schema-v2 clusterTagFilters settings as a
        fully commented example. Existing text, comments, ordering, and line
        endings are preserved. Already-v2 text is returned unchanged.
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
                ToVersion   = 2
                NewText     = $Text
                Reason      = 'NoSchemaDeclaration'
            }
        }
    }
    if ($matches.Count -ne 1) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' contains multiple schemaVersion declarations."
    }

    $currentVersion = [int]$matches[0].Groups[2].Value
    if ($currentVersion -gt 2) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' uses schemaVersion $currentVersion, which is newer than this module supports."
    }
    if ($currentVersion -eq 2) {
        return [pscustomobject]@{
            Migrated    = $false
            FromVersion = 2
            ToVersion   = 2
            NewText     = $Text
            Reason      = 'Current'
        }
    }
    if ($currentVersion -ne 1) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' uses unsupported schemaVersion $currentVersion."
    }

    $match = $matches[0]
    $replacement = $match.Groups[1].Value + '2' + $match.Groups[3].Value
    $newText = $Text.Substring(0, $match.Index) + $replacement + $Text.Substring($match.Index + $match.Length)

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $settingsMarker = '# AZLOCAL-FLEET-SETTINGS-SCHEMA-V2'
    if ($newText -notmatch '(?im)^\s*#?\s*clusterTagFilters\s*:') {
        $commentedSettings = @(
            $settingsMarker
            '# Optional global cluster admission policy. Every pair must match (AND).'
            '# Matching is exact and case-insensitive; a missing tag excludes the cluster.'
            '# Add these lines beneath your active scope block when enabling the policy:'
            '#   clusterTagFilters:'
            '#     - name: Environment'
            '#       value: Production'
            '#     - name: ManagedBy'
            '#       value: CentralIT'
        ) -join $newline
        if ($newText.Length -gt 0 -and -not $newText.EndsWith($newline)) {
            $newText += $newline
        }
        $newText += $newline + $commentedSettings + $newline
    }

    return [pscustomobject]@{
        Migrated    = $true
        FromVersion = 1
        ToVersion   = 2
        NewText     = $newText
        Reason      = 'Upgraded'
    }
}