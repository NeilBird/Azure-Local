function Get-AzLocalFleetSettings {
    <#
    .SYNOPSIS
        Reads the optional fleet-wide pipeline settings file.
    .DESCRIPTION
        Reads config/fleet-settings.yml by default, or the path supplied by
        -Path or AZLOCAL_FLEET_SETTINGS_PATH. The file is optional. A missing,
        empty, or fully commented file returns the existing implicit Azure
        subscription scope used by earlier module versions.

        Schema versions 1 and 2 support scope.managementGroups. When one or more
        management-group IDs are configured, Azure Resource Graph queries that
        do not already specify an explicit subscription use those management
        groups as their query scope.

        Schema version 2 adds scope.clusterTagFilters. Every configured tag
        name/value pair must match for a cluster to be included in fleet reads
        and state-changing operations.

        The parser is deliberately limited to this small operator-owned schema
        so the core fleet pipelines do not require powershell-yaml.
    .PARAMETER Path
        Optional path to fleet-settings.yml. Defaults first to
        AZLOCAL_FLEET_SETTINGS_PATH, then to ./config/fleet-settings.yml.
    .OUTPUTS
        PSCustomObject with Path, FileFound, SchemaVersion, ScopeMode,
        ManagementGroups, and ClusterTagFilters properties.
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

    function ConvertFrom-AzLocalFleetSettingsScalar {
        param(
            [Parameter(Mandatory = $true)][string]$RawValue,
            [Parameter(Mandatory = $true)][string]$PropertyName
        )

        $value = $RawValue.Trim()
        if ($value.StartsWith("'")) {
            if ($value -notmatch "^'((?:[^']|'')*)'\s*(?:#.*)?$") {
                throw "Get-AzLocalFleetSettings: malformed quoted value for $PropertyName in '$Path'."
            }
            return ($Matches[1] -replace "''", "'")
        }
        if ($value.StartsWith('"')) {
            if ($value -notmatch '^"([^"\\]*)"\s*(?:#.*)?$') {
                throw "Get-AzLocalFleetSettings: malformed quoted value for $PropertyName in '$Path'. Double-quoted escape sequences are not supported; use single quotes."
            }
            return $Matches[1]
        }

        $commentIndex = $value.IndexOf(' #', [System.StringComparison]::Ordinal)
        if ($commentIndex -ge 0) {
            $value = $value.Substring(0, $commentIndex).TrimEnd()
        }
        return $value
    }

    if (-not $PSBoundParameters.ContainsKey('Path')) {
        if (-not [string]::IsNullOrWhiteSpace($env:AZLOCAL_FLEET_SETTINGS_PATH)) {
            $Path = $env:AZLOCAL_FLEET_SETTINGS_PATH
        }
        else {
            $Path = Join-Path -Path $PWD.Path -ChildPath 'config\fleet-settings.yml'
        }
    }

    $result = [PSCustomObject]@{
        Path               = [System.IO.Path]::GetFullPath($Path)
        FileFound          = $false
        SchemaVersion      = 1
        ScopeMode          = 'ImplicitSubscriptions'
        ManagementGroups   = [string[]]@()
        ClusterTagFilters  = [object[]]@()
        ClusterTagFilterMode = 'All'
        MaxRowsPerTable    = 100
        MaxSummaryBytes    = 900000
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
    $inClusterTagFilters = $false
    $clusterTagFiltersDeclared = $false
    $activeSection = ''
    $managementGroups = [System.Collections.Generic.List[string]]::new()
    $clusterTagFilters = [System.Collections.Generic.List[object]]::new()
    $currentTagFilter = $null

    foreach ($line in $activeLines) {
        if ($line -match '^\s*schemaVersion\s*:\s*([0-9]+)\s*(?:#.*)?$') {
            $schemaVersion = [int]$Matches[1]
            continue
        }
        if ($line -match '^scope\s*:\s*(?:#.*)?$') {
            $activeSection = 'scope'
            $inScope = $true
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilter = $null
            continue
        }
        if ($line -match '^reporting\s*:\s*(?:#.*)?$') {
            $activeSection = 'reporting'
            $inScope = $false
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilter = $null
            continue
        }
        if ($line -match '^itsm\s*:\s*(?:#.*)?$') {
            $activeSection = 'itsm'
            $inScope = $false
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilter = $null
            continue
        }
        if ($line -match '^\S') {
            $activeSection = ''
            $inScope = $false
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilter = $null
            continue
        }
        if ($inScope -and $line -match '^\s{2}managementGroups\s*:\s*(?:#.*)?$') {
            $inManagementGroups = $true
            $inClusterTagFilters = $false
            $currentTagFilter = $null
            continue
        }
        if ($inScope -and $line -match '^\s{2}clusterTagFilters\s*:\s*(?:#.*)?$') {
            $clusterTagFiltersDeclared = $true
            $inManagementGroups = $false
            $inClusterTagFilters = $true
            $currentTagFilter = $null
            continue
        }
        if ($inScope -and $line -match '^\s{2}\S') {
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilter = $null
            throw "Get-AzLocalFleetSettings: unsupported or malformed active YAML at '$($result.Path)': $($line.Trim())"
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
        if ($inClusterTagFilters -and $line -match '^\s{4}-\s*name\s*:\s*(.*?)\s*$') {
            $currentTagFilter = [ordered]@{
                Name  = ConvertFrom-AzLocalFleetSettingsScalar -RawValue $Matches[1] -PropertyName 'scope.clusterTagFilters.name'
                Value = $null
            }
            [void]$clusterTagFilters.Add($currentTagFilter)
            continue
        }
        if ($inClusterTagFilters -and $line -match '^\s{6}value\s*:\s*(.*?)\s*$') {
            if ($null -eq $currentTagFilter -or $null -ne $currentTagFilter.Value) {
                throw "Get-AzLocalFleetSettings: each scope.clusterTagFilters entry must contain one name followed by one value."
            }
            $currentTagFilter.Value = ConvertFrom-AzLocalFleetSettingsScalar -RawValue $Matches[1] -PropertyName 'scope.clusterTagFilters.value'
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
        throw "Get-AzLocalFleetSettings: active settings in '$($result.Path)' must declare schemaVersion: 1 or 2."
    }
    if ($schemaVersion -notin @(1, 2)) {
        throw "Get-AzLocalFleetSettings: unsupported schemaVersion '$schemaVersion' in '$($result.Path)'. This module supports schemaVersion 1 and 2."
    }
    if ($schemaVersion -eq 1 -and $clusterTagFiltersDeclared) {
        throw "Get-AzLocalFleetSettings: scope.clusterTagFilters requires schemaVersion: 2."
    }
    if ($clusterTagFiltersDeclared -and $clusterTagFilters.Count -eq 0) {
        throw "Get-AzLocalFleetSettings: scope.clusterTagFilters must contain at least one name/value pair."
    }

    $tagNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $reservedTagNames = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            'UpdateRing',
            'UpdateStartWindow',
            'UpdateExclusionsWindow',
            'UpdateExcluded',
            'UpdateSideloaded',
            'UpdateVersionInProgress',
            'UpdateLastAttempt',
            'UpdateRetryAttempted',
            'UpdateAuthAccountId'
        ),
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($tagFilter in $clusterTagFilters) {
        $tagName = [string]$tagFilter.Name
        $tagValue = [string]$tagFilter.Value
        if ([string]::IsNullOrWhiteSpace($tagName) -or [string]::IsNullOrWhiteSpace($tagValue)) {
            throw "Get-AzLocalFleetSettings: each scope.clusterTagFilters entry requires non-empty name and value properties."
        }
        if ($tagName.Length -gt 512) {
            throw "Get-AzLocalFleetSettings: scope.clusterTagFilters name must not exceed 512 characters."
        }
        if ($tagValue.Length -gt 256) {
            throw "Get-AzLocalFleetSettings: scope.clusterTagFilters value must not exceed 256 characters."
        }
        if ($tagName.IndexOfAny(@([char]0x0A, [char]0x0D)) -ge 0 -or
            $tagValue.IndexOfAny(@([char]0x0A, [char]0x0D)) -ge 0) {
            throw "Get-AzLocalFleetSettings: scope.clusterTagFilters names and values must be single-line strings."
        }
        if (-not $tagNames.Add($tagName)) {
            throw "Get-AzLocalFleetSettings: duplicate scope.clusterTagFilters name '$tagName'. Each tag name may appear only once."
        }
        if ($reservedTagNames.Contains($tagName)) {
            throw "Get-AzLocalFleetSettings: scope.clusterTagFilters cannot use module-owned control tag '$tagName'. Use an externally governed admission tag such as Environment or ManagedBy."
        }
    }
    if ($result.MaxRowsPerTable -lt 1 -or $result.MaxRowsPerTable -gt 2000) {
        throw "Get-AzLocalFleetSettings: reporting.maxRowsPerTable must be between 1 and 2000."
    }
    if ($result.MaxSummaryBytes -lt 10000 -or $result.MaxSummaryBytes -gt 1000000) {
        throw "Get-AzLocalFleetSettings: reporting.maxSummaryBytes must be between 10000 and 1000000."
    }
    if ($result.MaxIncidentsPerRun -lt 0 -or $result.MaxIncidentsPerRun -gt 1000) {
        throw "Get-AzLocalFleetSettings: itsm.maxIncidentsPerRun must be between 0 and 1000."
    }

    $result.SchemaVersion = $schemaVersion
    $result.ManagementGroups = $managementGroups.ToArray()
    $result.ClusterTagFilters = $clusterTagFilters.ToArray()
    if ($result.ManagementGroups.Count -gt 0) {
        $result.ScopeMode = 'ManagementGroups'
    }

    return $result
}