function Convert-AzLocalFleetSettingsSchemaVersion {
    <#
    .SYNOPSIS
        Upgrades active fleet-settings.yml schema v1 text to schema v2.
    .DESCRIPTION
        Performs narrow text surgery on the active top-level schemaVersion
        declaration. All other text, comments, ordering, and line endings are
        preserved. Fully commented or already-v2 text is returned unchanged.
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
        return [pscustomobject]@{
            Migrated    = $false
            FromVersion = $null
            ToVersion   = 2
            NewText     = $Text
            Reason      = 'NoActiveSchema'
        }
    }
    if ($matches.Count -ne 1) {
        throw "Convert-AzLocalFleetSettingsSchemaVersion: '$SourcePath' contains multiple active schemaVersion declarations."
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
    return [pscustomobject]@{
        Migrated    = $true
        FromVersion = 1
        ToVersion   = 2
        NewText     = $newText
        Reason      = 'Upgraded'
    }
}