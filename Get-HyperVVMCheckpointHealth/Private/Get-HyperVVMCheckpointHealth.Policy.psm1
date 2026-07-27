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

function ConvertFrom-CheckpointHealthPolicyYaml {
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Yaml)

    $parsed = [ordered]@{}
    $context = [System.Collections.Generic.List[object]]::new()
    $lines = $Yaml -split "`r?`n"
    for ($lineNumber = 1; $lineNumber -le $lines.Count; $lineNumber++) {
        $line = $lines[$lineNumber - 1]
        if ([string]::IsNullOrWhiteSpace($line) -or $line -match '^\s*#') { continue }
        if ($line -match "`t") { throw "Policy YAML line $lineNumber contains a tab. Use spaces for indentation." }
        $indent = $line.Length - $line.TrimStart(' ').Length
        $content = $line.Trim()

        while ($context.Count -gt 0 -and [int]$context[$context.Count - 1].Indent -ge $indent) {
            $context.RemoveAt($context.Count - 1)
        }

        if ($content -match '^\-\s+(.+)$') {
            $path = @($context | ForEach-Object Name) -join '.'
            if ($path -notin @('storage.imageLibraryPathPatterns', 'orphan.liveMountPathPatterns')) {
                throw "Unsupported policy YAML list at line $lineNumber."
            }
            $listValue = $Matches[1].Trim()
            if ($listValue -notmatch "^'(.*)'$") {
                throw "Policy YAML list value at line $lineNumber must be single-quoted."
            }
            $listValue = $Matches[1] -replace "''", "'"
            if ($path -eq 'storage.imageLibraryPathPatterns') {
                $parsed.storage.imageLibraryPathPatterns = @($parsed.storage.imageLibraryPathPatterns) + @($listValue)
            } else {
                $parsed.orphan.liveMountPathPatterns = @($parsed.orphan.liveMountPathPatterns) + @($listValue)
            }
            continue
        }

        if ($content -notmatch '^([A-Za-z][A-Za-z0-9]*):(?:\s*(.*))?$') {
            throw "Unsupported policy YAML syntax at line $lineNumber."
        }
        $name = $Matches[1]
        $valueText = $Matches[2].Trim()
        $parentPath = @($context | ForEach-Object Name) -join '.'
        $path = (@($parentPath, $name) | Where-Object { $_ }) -join '.'
        if ($valueText -eq '') {
            if ($path -notin @('storage', 'orphan', 'csvFreeSpace', 'replication', 'replication.hrl', 'storage.imageLibraryPathPatterns', 'orphan.liveMountPathPatterns')) {
                throw "Unsupported policy YAML property '$path' at line $lineNumber."
            }
            switch ($path) {
                'storage' { $parsed.storage = [ordered]@{} }
                'orphan' { $parsed.orphan = [ordered]@{} }
                'csvFreeSpace' { $parsed.csvFreeSpace = [ordered]@{} }
                'replication' { $parsed.replication = [ordered]@{} }
                'replication.hrl' { $parsed.replication.hrl = [ordered]@{} }
                'storage.imageLibraryPathPatterns' { $parsed.storage.imageLibraryPathPatterns = @() }
                'orphan.liveMountPathPatterns' { $parsed.orphan.liveMountPathPatterns = @() }
            }
            [void]$context.Add([pscustomobject]@{ Indent = $indent; Name = $name })
            continue
        }

        $value = if ($valueText -eq '[]') { @() }
            elseif ($valueText -match '^(?i:true|false)$') { [bool]::Parse($valueText) }
            elseif ($valueText -match '^-?\d+(?:\.\d+)?$') { [double]::Parse($valueText, [Globalization.CultureInfo]::InvariantCulture) }
            elseif ($valueText -match "^'(.*)'$") { $Matches[1] -replace "''", "'" }
            else { throw "Unsupported policy YAML value at line $lineNumber. Use a boolean, number, [], or single-quoted string." }

        switch ($path) {
            'schemaVersion' { $parsed.schemaVersion = $value }
            'storage.imageLibraryPathPatterns' { $parsed.storage.imageLibraryPathPatterns = @($value) }
            'orphan.liveMountPathPatterns' { $parsed.orphan.liveMountPathPatterns = @($value) }
            'orphan.classifyZeroByteAsLiveMount' { $parsed.orphan.classifyZeroByteAsLiveMount = $value }
            'csvFreeSpace.enabled' { $parsed.csvFreeSpace.enabled = $value }
            'csvFreeSpace.minimumFreePercent' { $parsed.csvFreeSpace.minimumFreePercent = $value }
            'csvFreeSpace.minimumFreeGB' { $parsed.csvFreeSpace.minimumFreeGB = $value }
            'replication.hrl.enabled' { $parsed.replication.hrl.enabled = $value }
            'replication.hrl.cadenceMultiplier' { $parsed.replication.hrl.cadenceMultiplier = $value }
            'replication.hrl.minimumStaleMinutes' { $parsed.replication.hrl.minimumStaleMinutes = $value }
            'replication.hrl.requireReplicationConcern' { $parsed.replication.hrl.requireReplicationConcern = $value }
            default { throw "Unsupported policy YAML property '$path' at line $lineNumber." }
        }
    }
    return $parsed
}

function Import-CheckpointHealthPolicy {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Policy file was not found: $Path" }
    $rawText = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($rawText)) { throw 'The policy file is empty.' }
    $raw = ConvertFrom-CheckpointHealthPolicyYaml -Yaml $rawText

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