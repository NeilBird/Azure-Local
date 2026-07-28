function Get-AzLocalFleetSettings {
    <#
    .SYNOPSIS
        Reads the optional fleet-wide pipeline settings file.
    .DESCRIPTION
        Reads config/fleet-settings.yml by default, or the path supplied by
        -Path or AZLOCAL_FLEET_SETTINGS_PATH. The file is optional. A missing,
        empty, or fully commented file returns the existing implicit Azure
        subscription scope used by earlier module versions.

        Schema versions 1, 3, and 4 support scope.managementGroups. When one or more
        management-group IDs are configured, Azure Resource Graph queries that
        do not already specify an explicit subscription use those management
        groups as their query scope.

        Schema version 3 adds grouped scope.clusterTagFilters. Tags within one
        named group use AND semantics; groups use OR semantics. A group with one
        tag is therefore a singular alternative.

        Schema version 4 adds updateStartWindow.allowBeforeMinutes and
        updateStartWindow.allowAfterMinutes. Each independently widens the UTC
        runtime gate by 0 to 60 minutes and defaults to 0.

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
        ClusterTagFilterMode = 'AnyGroup'
        UpdateStartWindowAllowBeforeMinutes = 0
        UpdateStartWindowAllowAfterMinutes  = 0
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
    $updateStartWindowDeclared = $false
    $activeSection = ''
    $managementGroups = [System.Collections.Generic.List[string]]::new()
    $clusterTagFilters = [System.Collections.Generic.List[object]]::new()
    $currentTagFilterGroup = $null
    $currentTagFilterTag = $null

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
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
            continue
        }
        if ($line -match '^reporting\s*:\s*(?:#.*)?$') {
            $activeSection = 'reporting'
            $inScope = $false
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
            continue
        }
        if ($line -match '^updateStartWindow\s*:\s*(?:#.*)?$') {
            $activeSection = 'updateStartWindow'
            $updateStartWindowDeclared = $true
            $inScope = $false
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
            continue
        }
        if ($line -match '^itsm\s*:\s*(?:#.*)?$') {
            $activeSection = 'itsm'
            $inScope = $false
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
            continue
        }
        if ($line -match '^\S') {
            $activeSection = ''
            $inScope = $false
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
            continue
        }
        if ($inScope -and $line -match '^\s{2}managementGroups\s*:\s*(?:#.*)?$') {
            $inManagementGroups = $true
            $inClusterTagFilters = $false
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
            continue
        }
        if ($inScope -and $line -match '^\s{2}clusterTagFilters\s*:\s*(?:#.*)?$') {
            $clusterTagFiltersDeclared = $true
            $inManagementGroups = $false
            $inClusterTagFilters = $true
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
            continue
        }
        if ($inScope -and $line -match '^\s{2}\S') {
            $inManagementGroups = $false
            $inClusterTagFilters = $false
            $currentTagFilterGroup = $null
            $currentTagFilterTag = $null
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
            $currentTagFilterGroup = [ordered]@{
                Name = ConvertFrom-AzLocalFleetSettingsScalar -RawValue $Matches[1] -PropertyName 'scope.clusterTagFilters.name'
                Tags = [System.Collections.Generic.List[object]]::new()
            }
            $currentTagFilterTag = $null
            [void]$clusterTagFilters.Add($currentTagFilterGroup)
            continue
        }
        if ($inClusterTagFilters -and $line -match '^\s{6}tags\s*:\s*(?:#.*)?$') {
            if ($null -eq $currentTagFilterGroup) {
                throw "Get-AzLocalFleetSettings: each scope.clusterTagFilters group must contain one name followed by tags."
            }
            continue
        }
        if ($inClusterTagFilters -and $line -match '^\s{8}-\s*name\s*:\s*(.*?)\s*$') {
            if ($null -eq $currentTagFilterGroup) {
                throw "Get-AzLocalFleetSettings: tag entries must be nested beneath a named scope.clusterTagFilters group."
            }
            $currentTagFilterTag = [ordered]@{
                Name  = ConvertFrom-AzLocalFleetSettingsScalar -RawValue $Matches[1] -PropertyName 'scope.clusterTagFilters.tags.name'
                Value = $null
            }
            [void]$currentTagFilterGroup.Tags.Add($currentTagFilterTag)
            continue
        }
        if ($inClusterTagFilters -and $line -match '^\s{10}value\s*:\s*(.*?)\s*$') {
            if ($null -eq $currentTagFilterTag -or $null -ne $currentTagFilterTag.Value) {
                throw "Get-AzLocalFleetSettings: each grouped tag entry must contain one name followed by one value."
            }
            $currentTagFilterTag.Value = ConvertFrom-AzLocalFleetSettingsScalar -RawValue $Matches[1] -PropertyName 'scope.clusterTagFilters.tags.value'
            continue
        }
        if ($activeSection -eq 'reporting' -and $line -match '^\s{2}maxRowsPerTable\s*:\s*([0-9]+)\s*(?:#.*)?$') {
            $result.MaxRowsPerTable = [int]$Matches[1]
            continue
        }
        if ($activeSection -eq 'updateStartWindow' -and $line -match '^\s{2}allowBeforeMinutes\s*:\s*(-?[0-9]+)\s*(?:#.*)?$') {
            $result.UpdateStartWindowAllowBeforeMinutes = [int]$Matches[1]
            continue
        }
        if ($activeSection -eq 'updateStartWindow' -and $line -match '^\s{2}allowAfterMinutes\s*:\s*(-?[0-9]+)\s*(?:#.*)?$') {
            $result.UpdateStartWindowAllowAfterMinutes = [int]$Matches[1]
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
        throw "Get-AzLocalFleetSettings: active settings in '$($result.Path)' must declare schemaVersion: 1, 3, or 4."
    }
    if ($schemaVersion -notin @(1, 3, 4)) {
        throw "Get-AzLocalFleetSettings: unsupported schemaVersion '$schemaVersion' in '$($result.Path)'. This module supports schemaVersion 1, 3, and 4."
    }
    if ($schemaVersion -eq 1 -and $clusterTagFiltersDeclared) {
        throw "Get-AzLocalFleetSettings: scope.clusterTagFilters requires schemaVersion: 3."
    }
    if ($schemaVersion -ne 4 -and $updateStartWindowDeclared) {
        throw "Get-AzLocalFleetSettings: updateStartWindow allowances require schemaVersion: 4."
    }
    if ($clusterTagFiltersDeclared -and $clusterTagFilters.Count -eq 0) {
        throw "Get-AzLocalFleetSettings: scope.clusterTagFilters must contain at least one named group."
    }

    $groupNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
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
    foreach ($tagGroup in $clusterTagFilters) {
        $groupName = [string]$tagGroup.Name
        if ([string]::IsNullOrWhiteSpace($groupName)) {
            throw "Get-AzLocalFleetSettings: each scope.clusterTagFilters group requires a non-empty name."
        }
        if (-not $groupNames.Add($groupName)) {
            throw "Get-AzLocalFleetSettings: duplicate scope.clusterTagFilters group name '$groupName'."
        }
        if ($tagGroup.Tags.Count -eq 0) {
            throw "Get-AzLocalFleetSettings: scope.clusterTagFilters group '$groupName' must contain at least one tag."
        }
        $tagNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($tagFilter in $tagGroup.Tags) {
            $tagName = [string]$tagFilter.Name
            $tagValue = [string]$tagFilter.Value
            if ([string]::IsNullOrWhiteSpace($tagName) -or [string]::IsNullOrWhiteSpace($tagValue)) {
                throw "Get-AzLocalFleetSettings: each tag in group '$groupName' requires non-empty name and value properties."
            }
            if ($tagName.Length -gt 512) {
                throw "Get-AzLocalFleetSettings: tag name in group '$groupName' must not exceed 512 characters."
            }
            if ($tagValue.Length -gt 256) {
                throw "Get-AzLocalFleetSettings: tag value in group '$groupName' must not exceed 256 characters."
            }
            if ($tagName.IndexOfAny(@([char]0x0A, [char]0x0D)) -ge 0 -or
                $tagValue.IndexOfAny(@([char]0x0A, [char]0x0D)) -ge 0) {
                throw "Get-AzLocalFleetSettings: tag names and values must be single-line strings."
            }
            if (-not $tagNames.Add($tagName)) {
                throw "Get-AzLocalFleetSettings: duplicate tag name '$tagName' in group '$groupName'."
            }
            if ($reservedTagNames.Contains($tagName)) {
                throw "Get-AzLocalFleetSettings: scope.clusterTagFilters cannot use module-owned control tag '$tagName'. Use an externally governed admission tag such as Environment or ManagedBy."
            }
        }
    }
    if ($result.MaxRowsPerTable -lt 1 -or $result.MaxRowsPerTable -gt 2000) {
        throw "Get-AzLocalFleetSettings: reporting.maxRowsPerTable must be between 1 and 2000."
    }
    if ($result.UpdateStartWindowAllowBeforeMinutes -lt 0 -or $result.UpdateStartWindowAllowBeforeMinutes -gt 60) {
        throw "Get-AzLocalFleetSettings: updateStartWindow.allowBeforeMinutes must be between 0 and 60."
    }
    if ($result.UpdateStartWindowAllowAfterMinutes -lt 0 -or $result.UpdateStartWindowAllowAfterMinutes -gt 60) {
        throw "Get-AzLocalFleetSettings: updateStartWindow.allowAfterMinutes must be between 0 and 60."
    }
    if ($result.MaxSummaryBytes -lt 10000 -or $result.MaxSummaryBytes -gt 1000000) {
        throw "Get-AzLocalFleetSettings: reporting.maxSummaryBytes must be between 10000 and 1000000."
    }
    if ($result.MaxIncidentsPerRun -lt 0 -or $result.MaxIncidentsPerRun -gt 1000) {
        throw "Get-AzLocalFleetSettings: itsm.maxIncidentsPerRun must be between 0 and 1000."
    }

    $result.SchemaVersion = $schemaVersion
    $result.ManagementGroups = $managementGroups.ToArray()
    $result.ClusterTagFilters = @($clusterTagFilters | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; Tags = $_.Tags.ToArray() }
    })
    if ($result.ManagementGroups.Count -gt 0) {
        $result.ScopeMode = 'ManagementGroups'
    }

    return $result
}