Set-StrictMode -Version Latest

function Get-CheckpointHealthDefaultPolicy {
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        SchemaVersion = 1
        Source = 'BuiltInDefaults'
        Storage = [pscustomobject]@{
            ImageLibraryPathPatterns = @(
                '(?i)[\\/](?:image|images|imagestore|template|templates|library|gallery|golden)(?:[\\/]|$)'
            )
        }
        Orphan = [pscustomobject]@{
            LiveMountPathPatterns = @('(?i)rubriklivemount', '(?i)_temp_')
            ClassifyZeroByteAsLiveMount = $true
        }
        CsvFreeSpace = [pscustomobject]@{
            Enabled = $false
            MinimumFreePercent = 15.0
            MinimumFreeGB = 100.0
        }
        Replication = [pscustomobject]@{
            Hrl = [pscustomobject]@{
                Enabled = $true
                CadenceMultiplier = 10.0
                MinimumStaleMinutes = 15.0
                RequireReplicationConcern = $true
            }
        }
    }
}

function Get-CheckpointHealthPolicyProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) { return [pscustomobject]@{ Exists = $false; Value = $null } }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if (([string]$key).Equals($Name, [StringComparison]::OrdinalIgnoreCase)) {
                return [pscustomobject]@{ Exists = $true; Value = $Object[$key] }
            }
        }
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return [pscustomobject]@{ Exists = $true; Value = $property.Value } }
    return [pscustomobject]@{ Exists = $false; Value = $null }
}

function Test-CheckpointHealthRegexPatterns {
    param([string[]]$Patterns, [string]$PropertyName)
    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { throw "$PropertyName cannot contain an empty pattern." }
        try { [void][regex]::new($pattern) }
        catch { throw "Invalid regular expression in $PropertyName ('$pattern'): $($_.Exception.Message)" }
    }
}

function Import-CheckpointHealthPolicy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Policy file was not found: $Path" }
    $yamlCommand = Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue
    if (-not $yamlCommand) {
        try { Import-Module powershell-yaml -ErrorAction Stop }
        catch { throw "Reading -PolicyPath requires the optional 'powershell-yaml' module. Install it with: Install-Module powershell-yaml -Scope CurrentUser" }
    }
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Yaml
    if ($null -eq $raw) { throw 'The policy file is empty.' }

    $schemaProperty = Get-CheckpointHealthPolicyProperty -Object $raw -Name 'schemaVersion'
    if (-not $schemaProperty.Exists -or [int]$schemaProperty.Value -ne 1) {
        throw "Unsupported policy schemaVersion '$($schemaProperty.Value)'. This module supports schemaVersion 1."
    }

    $policy = Get-CheckpointHealthDefaultPolicy
    $policy.Source = [System.IO.Path]::GetFullPath($Path)
    $property = Get-CheckpointHealthPolicyProperty -Object $raw -Name 'storage'
    $storage = if ($property.Exists) { $property.Value } else { $null }
    $property = Get-CheckpointHealthPolicyProperty -Object $raw -Name 'orphan'
    $orphan = if ($property.Exists) { $property.Value } else { $null }
    $property = Get-CheckpointHealthPolicyProperty -Object $raw -Name 'csvFreeSpace'
    $csv = if ($property.Exists) { $property.Value } else { $null }
    $property = Get-CheckpointHealthPolicyProperty -Object $raw -Name 'replication'
    $replication = if ($property.Exists) { $property.Value } else { $null }
    $property = Get-CheckpointHealthPolicyProperty -Object $replication -Name 'hrl'
    $hrl = if ($property.Exists) { $property.Value } else { $null }

    $property = Get-CheckpointHealthPolicyProperty -Object $storage -Name 'imageLibraryPathPatterns'
    if ($property.Exists) { $policy.Storage.ImageLibraryPathPatterns = @($property.Value | ForEach-Object { [string]$_ }) }
    $property = Get-CheckpointHealthPolicyProperty -Object $orphan -Name 'liveMountPathPatterns'
    if ($property.Exists) { $policy.Orphan.LiveMountPathPatterns = @($property.Value | ForEach-Object { [string]$_ }) }
    $property = Get-CheckpointHealthPolicyProperty -Object $orphan -Name 'classifyZeroByteAsLiveMount'
    if ($property.Exists) { $policy.Orphan.ClassifyZeroByteAsLiveMount = [bool]$property.Value }
    $property = Get-CheckpointHealthPolicyProperty -Object $csv -Name 'enabled'
    if ($property.Exists) { $policy.CsvFreeSpace.Enabled = [bool]$property.Value }
    $property = Get-CheckpointHealthPolicyProperty -Object $csv -Name 'minimumFreePercent'
    if ($property.Exists) { $policy.CsvFreeSpace.MinimumFreePercent = [double]$property.Value }
    $property = Get-CheckpointHealthPolicyProperty -Object $csv -Name 'minimumFreeGB'
    if ($property.Exists) { $policy.CsvFreeSpace.MinimumFreeGB = [double]$property.Value }
    $property = Get-CheckpointHealthPolicyProperty -Object $hrl -Name 'enabled'
    if ($property.Exists) { $policy.Replication.Hrl.Enabled = [bool]$property.Value }
    $property = Get-CheckpointHealthPolicyProperty -Object $hrl -Name 'cadenceMultiplier'
    if ($property.Exists) { $policy.Replication.Hrl.CadenceMultiplier = [double]$property.Value }
    $property = Get-CheckpointHealthPolicyProperty -Object $hrl -Name 'minimumStaleMinutes'
    if ($property.Exists) { $policy.Replication.Hrl.MinimumStaleMinutes = [double]$property.Value }
    $property = Get-CheckpointHealthPolicyProperty -Object $hrl -Name 'requireReplicationConcern'
    if ($property.Exists) { $policy.Replication.Hrl.RequireReplicationConcern = [bool]$property.Value }

    if ($policy.CsvFreeSpace.MinimumFreePercent -lt 0 -or $policy.CsvFreeSpace.MinimumFreePercent -gt 100) { throw 'csvFreeSpace.minimumFreePercent must be between 0 and 100.' }
    if ($policy.CsvFreeSpace.MinimumFreeGB -lt 0) { throw 'csvFreeSpace.minimumFreeGB must be zero or greater.' }
    if ($policy.Replication.Hrl.CadenceMultiplier -lt 1) { throw 'replication.hrl.cadenceMultiplier must be at least 1.' }
    if ($policy.Replication.Hrl.MinimumStaleMinutes -lt 1) { throw 'replication.hrl.minimumStaleMinutes must be at least 1.' }
    Test-CheckpointHealthRegexPatterns -Patterns $policy.Storage.ImageLibraryPathPatterns -PropertyName 'storage.imageLibraryPathPatterns'
    Test-CheckpointHealthRegexPatterns -Patterns $policy.Orphan.LiveMountPathPatterns -PropertyName 'orphan.liveMountPathPatterns'
    return $policy
}

function Test-CheckpointHealthPathPattern {
    [OutputType([bool])]
    param([AllowEmptyString()][string]$Path, [string[]]$Patterns = @())
    foreach ($pattern in @($Patterns)) { if ($Path -match $pattern) { return $true } }
    return $false
}

function Get-CsvFreeSpaceAssessment {
    [OutputType([pscustomobject])]
    param(
        [object[]]$Volumes = @(),
        [Parameter(Mandatory)]$Policy
    )
    $breaches = @($Volumes | Where-Object {
        ([double]$_.FreePct -lt [double]$Policy.MinimumFreePercent) -or
        ([double]$_.FreeGB -lt [double]$Policy.MinimumFreeGB)
    })
    [pscustomobject]@{
        Enabled = [bool]$Policy.Enabled
        IsConcern = ([bool]$Policy.Enabled -and $breaches.Count -gt 0)
        MinimumFreePercent = [double]$Policy.MinimumFreePercent
        MinimumFreeGB = [double]$Policy.MinimumFreeGB
        Breaches = $breaches
    }
}

function Get-HrlCadenceAssessment {
    [OutputType([pscustomobject])]
    param(
        [object[]]$Files = @(),
        [bool]$ReplicationEnabled,
        [double]$FrequencySeconds,
        [bool]$ReplicationConcern,
        [Parameter(Mandatory)]$Policy,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $cadenceMinutes = if ($FrequencySeconds -gt 0) { $FrequencySeconds / 60.0 } else { 0.0 }
    $thresholdMinutes = [math]::Max([double]$Policy.MinimumStaleMinutes, ($cadenceMinutes * [double]$Policy.CadenceMultiplier))
    $rows = @($Files | ForEach-Object {
        $ageMinutes = if ($_.LastWriteTimeUtc) { ($NowUtc.ToUniversalTime() - ([datetime]$_.LastWriteTimeUtc).ToUniversalTime()).TotalMinutes } else { $null }
        [pscustomobject]@{
            Name = [string]$_.Name
            FullName = [string]$_.FullName
            Length = [long]$_.Length
            LastWriteTimeUtc = $_.LastWriteTimeUtc
            AgeMinutes = $ageMinutes
            ExceedsCadence = ($null -ne $ageMinutes -and $ageMinutes -ge $thresholdMinutes)
        }
    })
    $staleRows = @($rows | Where-Object ExceedsCadence)
    $corroborated = (-not [bool]$Policy.RequireReplicationConcern) -or $ReplicationConcern
    [pscustomobject]@{
        Enabled = [bool]$Policy.Enabled
        ReplicationEnabled = $ReplicationEnabled
        CadenceMinutes = $cadenceMinutes
        ThresholdMinutes = $thresholdMinutes
        ExceedsCadenceCount = $staleRows.Count
        IsConcern = ([bool]$Policy.Enabled -and $ReplicationEnabled -and $staleRows.Count -gt 0 -and $corroborated)
        CorroboratedByReplication = [bool]($ReplicationConcern -and $staleRows.Count -gt 0)
        Rows = $rows
    }
}

Export-ModuleMember -Function Get-CheckpointHealthDefaultPolicy, Import-CheckpointHealthPolicy, Test-CheckpointHealthPathPattern, Get-CsvFreeSpaceAssessment, Get-HrlCadenceAssessment