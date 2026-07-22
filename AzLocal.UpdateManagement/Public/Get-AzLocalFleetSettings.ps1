function Get-AzLocalFleetSettings {
    <#
    .SYNOPSIS
        Reads the optional fleet-wide pipeline settings file.
    .DESCRIPTION
        Reads config/fleet-settings.yml by default, or the path supplied by
        -Path or AZLOCAL_FLEET_SETTINGS_PATH. The file is optional. A missing,
        empty, or fully commented file returns the existing implicit Azure
        subscription scope used by earlier module versions.

        Schema version 1 supports scope.managementGroups. When one or more
        management-group IDs are configured, Azure Resource Graph queries that
        do not already specify an explicit subscription use those management
        groups as their query scope.

        The parser is deliberately limited to this small operator-owned schema
        so the core fleet pipelines do not require powershell-yaml.
    .PARAMETER Path
        Optional path to fleet-settings.yml. Defaults first to
        AZLOCAL_FLEET_SETTINGS_PATH, then to ./config/fleet-settings.yml.
    .OUTPUTS
        PSCustomObject with Path, FileFound, SchemaVersion, ScopeMode, and
        ManagementGroups properties.
    .EXAMPLE
        Get-AzLocalFleetSettings

        Reads the default config/fleet-settings.yml file. A fully commented
        starter returns ScopeMode 'ImplicitSubscriptions'.
    .EXAMPLE
        Get-AzLocalFleetSettings -Path C:\repo\config\fleet-settings.yml

        Reads an explicit settings file path.
    .NOTES
        Author: Neil Bird, Microsoft
        Module: AzLocal.UpdateManagement
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not $PSBoundParameters.ContainsKey('Path')) {
        if (-not [string]::IsNullOrWhiteSpace($env:AZLOCAL_FLEET_SETTINGS_PATH)) {
            $Path = $env:AZLOCAL_FLEET_SETTINGS_PATH
        }
        else {
            $Path = Join-Path -Path $PWD.Path -ChildPath 'config\fleet-settings.yml'
        }
    }

    $result = [PSCustomObject]@{
        Path             = [System.IO.Path]::GetFullPath($Path)
        FileFound        = $false
        SchemaVersion    = 1
        ScopeMode        = 'ImplicitSubscriptions'
        ManagementGroups = [string[]]@()
        MaxRowsPerTable  = 100
        MaxSummaryBytes  = 900000
        MaxIncidentsPerRun = 25
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $result
    }

    $result.FileFound = $true
    $lines = [System.IO.File]::ReadAllLines($result.Path, [System.Text.UTF8Encoding]::new($false))
    $activeLines = @($lines | Where-Object {
        $trimmed = $_.Trim()
        $trimmed.Length -gt 0 -and -not $trimmed.StartsWith('#')
    })
    if ($activeLines.Count -eq 0) {
        return $result
    }

    $schemaVersion = $null
    $inScope = $false
    $inManagementGroups = $false
    $activeSection = ''
    $managementGroups = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $activeLines) {
        if ($line -match '^\s*schemaVersion\s*:\s*([0-9]+)\s*(?:#.*)?$') {
            $schemaVersion = [int]$Matches[1]
            continue
        }
        if ($line -match '^scope\s*:\s*(?:#.*)?$') {
            $activeSection = 'scope'
            $inScope = $true
            $inManagementGroups = $false
            continue
        }
        if ($line -match '^reporting\s*:\s*(?:#.*)?$') {
            $activeSection = 'reporting'
            $inScope = $false
            $inManagementGroups = $false
            continue
        }
        if ($line -match '^itsm\s*:\s*(?:#.*)?$') {
            $activeSection = 'itsm'
            $inScope = $false
            $inManagementGroups = $false
            continue
        }
        if ($line -match '^\S') {
            $activeSection = ''
            $inScope = $false
            $inManagementGroups = $false
            continue
        }
        if ($inScope -and $line -match '^\s{2}managementGroups\s*:\s*(?:#.*)?$') {
            $inManagementGroups = $true
            continue
        }
        if ($inScope -and $line -match '^\s{2}\S') {
            $inManagementGroups = $false
            continue
        }
        if ($inManagementGroups -and $line -match '^\s{4}-\s*([^#]+?)\s*(?:#.*)?$') {
            $managementGroupId = $Matches[1].Trim()
            if ($managementGroupId.Length -ge 2 -and
                (($managementGroupId.StartsWith("'") -and $managementGroupId.EndsWith("'")) -or
                 ($managementGroupId.StartsWith('"') -and $managementGroupId.EndsWith('"')))) {
                $managementGroupId = $managementGroupId.Substring(1, $managementGroupId.Length - 2).Trim()
            }
            if (-not [string]::IsNullOrWhiteSpace($managementGroupId) -and
                -not $managementGroups.Contains($managementGroupId)) {
                [void]$managementGroups.Add($managementGroupId)
            }
            continue
        }
        if ($activeSection -eq 'reporting' -and $line -match '^\s{2}maxRowsPerTable\s*:\s*([0-9]+)\s*(?:#.*)?$') {
            $result.MaxRowsPerTable = [int]$Matches[1]
            continue
        }
        if ($activeSection -eq 'reporting' -and $line -match '^\s{2}maxSummaryBytes\s*:\s*([0-9]+)\s*(?:#.*)?$') {
            $result.MaxSummaryBytes = [int]$Matches[1]
            continue
        }
        if ($activeSection -eq 'itsm' -and $line -match '^\s{2}maxIncidentsPerRun\s*:\s*([0-9]+)\s*(?:#.*)?$') {
            $result.MaxIncidentsPerRun = [int]$Matches[1]
            continue
        }

        throw "Get-AzLocalFleetSettings: unsupported or malformed active YAML at '$($result.Path)': $($line.Trim())"
    }

    if ($null -eq $schemaVersion) {
        throw "Get-AzLocalFleetSettings: active settings in '$($result.Path)' must declare schemaVersion: 1."
    }
    if ($schemaVersion -ne 1) {
        throw "Get-AzLocalFleetSettings: unsupported schemaVersion '$schemaVersion' in '$($result.Path)'. This module supports schemaVersion 1."
    }
    if ($result.MaxRowsPerTable -lt 1 -or $result.MaxRowsPerTable -gt 1000) {
        throw "Get-AzLocalFleetSettings: reporting.maxRowsPerTable must be between 1 and 1000."
    }
    if ($result.MaxSummaryBytes -lt 10000 -or $result.MaxSummaryBytes -gt 1000000) {
        throw "Get-AzLocalFleetSettings: reporting.maxSummaryBytes must be between 10000 and 1000000."
    }
    if ($result.MaxIncidentsPerRun -lt 0 -or $result.MaxIncidentsPerRun -gt 1000) {
        throw "Get-AzLocalFleetSettings: itsm.maxIncidentsPerRun must be between 0 and 1000."
    }

    $result.SchemaVersion = $schemaVersion
    $result.ManagementGroups = $managementGroups.ToArray()
    if ($result.ManagementGroups.Count -gt 0) {
        $result.ScopeMode = 'ManagementGroups'
    }

    return $result
}