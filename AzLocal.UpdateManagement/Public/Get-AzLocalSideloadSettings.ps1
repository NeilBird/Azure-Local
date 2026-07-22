function Get-AzLocalSideloadSettings {
    <#
    .SYNOPSIS
        Reads and validates the authoritative sideload settings YAML.
    .DESCRIPTION
        Parses config/sideload-settings.yml, validates the supported schema and
        required path, reconciliation, copy-profile, task-identity, remoting, and
        reporting fields, then returns a normalized settings object. The file is
        read-only: this cmdlet never creates, overwrites, or migrates settings.
    .PARAMETER Path
        Path to sideload-settings.yml. Defaults to ./config/sideload-settings.yml.
    .OUTPUTS
        [PSCustomObject] containing the validated sideload settings.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Path = (Join-Path -Path $PWD.Path -ChildPath 'config\sideload-settings.yml')
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Get-AzLocalSideloadSettings: settings file not found at '$Path'. Run Copy-AzLocalPipelineExample to create it."
    }
    if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
        throw "Get-AzLocalSideloadSettings: powershell-yaml is required. Install with: Install-Module powershell-yaml -Scope CurrentUser"
    }

    Import-Module powershell-yaml -ErrorAction Stop
    $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    try {
        $rawConfig = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $fullPath -Raw -ErrorAction Stop) -Ordered:$false
    }
    catch {
        throw "Get-AzLocalSideloadSettings: failed to parse '$fullPath': $($_.Exception.Message)"
    }
    $config = ConvertTo-AzLocalSideloadSettingsHashtable -InputObject $rawConfig
    if (-not $config -or -not $config.ContainsKey('schemaVersion')) {
        throw "Get-AzLocalSideloadSettings: '$fullPath' must declare schemaVersion."
    }
    if ([int]$config.schemaVersion -ne $script:SideloadSettingsSchemaCurrentVersion) {
        throw "Get-AzLocalSideloadSettings: '$fullPath' uses schemaVersion=$($config.schemaVersion); this module requires $($script:SideloadSettingsSchemaCurrentVersion). Upgrade AzLocal.UpdateManagement and regenerate the starter settings file."
    }

    foreach ($requiredSection in @('paths', 'planning', 'reconciliation', 'copy', 'identity', 'remoting', 'reporting')) {
        if (-not $config.ContainsKey($requiredSection) -or -not ($config[$requiredSection] -is [hashtable])) {
            throw "Get-AzLocalSideloadSettings: '$fullPath' is missing the '$requiredSection' section."
        }
    }
    foreach ($requiredPath in @('stateRoot', 'authMap', 'catalog', 'applySchedule')) {
        if (-not $config.paths.ContainsKey($requiredPath) -or [string]::IsNullOrWhiteSpace([string]$config.paths[$requiredPath])) {
            throw "Get-AzLocalSideloadSettings: paths.$requiredPath is required."
        }
    }

    $leadDays = [int]$config.planning.leadDays
    $heartbeatIntervalSeconds = [int]$config.reconciliation.heartbeatIntervalSeconds
    $heartbeatStaleMinutes = [int]$config.reconciliation.heartbeatStaleMinutes
    $noProgressMinutes = [int]$config.reconciliation.noProgressMinutes
    $maxConcurrentCopies = [int]$config.reconciliation.maxConcurrentCopies
    if ($leadDays -lt 0 -or $leadDays -gt 365) { throw 'Get-AzLocalSideloadSettings: planning.leadDays must be between 0 and 365.' }
    if ($heartbeatIntervalSeconds -lt 10 -or $heartbeatIntervalSeconds -gt 300) { throw 'Get-AzLocalSideloadSettings: reconciliation.heartbeatIntervalSeconds must be between 10 and 300.' }
    if ($heartbeatStaleMinutes -lt 1 -or $heartbeatStaleMinutes -gt 1440) { throw 'Get-AzLocalSideloadSettings: reconciliation.heartbeatStaleMinutes must be between 1 and 1440.' }
    if ($noProgressMinutes -lt 1 -or $noProgressMinutes -gt 1440) { throw 'Get-AzLocalSideloadSettings: reconciliation.noProgressMinutes must be between 1 and 1440.' }
    if ($maxConcurrentCopies -lt 1 -or $maxConcurrentCopies -gt 64) { throw 'Get-AzLocalSideloadSettings: reconciliation.maxConcurrentCopies must be between 1 and 64.' }

    $defaultProfileName = [string]$config.copy.defaultProfile
    if ([string]::IsNullOrWhiteSpace($defaultProfileName) -or -not $config.copy.profiles.ContainsKey($defaultProfileName)) {
        throw "Get-AzLocalSideloadSettings: copy.defaultProfile '$defaultProfileName' does not identify a configured copy profile."
    }
    $defaultProfile = $config.copy.profiles[$defaultProfileName]
    foreach ($profileField in @('retryCount', 'waitSeconds', 'interPacketGapMilliseconds', 'restartable', 'unbuffered')) {
        if (-not $defaultProfile.ContainsKey($profileField)) {
            throw "Get-AzLocalSideloadSettings: copy profile '$defaultProfileName' is missing '$profileField'."
        }
    }
    if ([int]$defaultProfile.retryCount -lt 0 -or [int]$defaultProfile.retryCount -gt 100) {
        throw "Get-AzLocalSideloadSettings: copy profile '$defaultProfileName' retryCount must be between 0 and 100."
    }
    if ([int]$defaultProfile.waitSeconds -lt 0 -or [int]$defaultProfile.waitSeconds -gt 3600) {
        throw "Get-AzLocalSideloadSettings: copy profile '$defaultProfileName' waitSeconds must be between 0 and 3600."
    }
    if ([int]$defaultProfile.interPacketGapMilliseconds -lt 0 -or [int]$defaultProfile.interPacketGapMilliseconds -gt 60000) {
        throw "Get-AzLocalSideloadSettings: copy profile '$defaultProfileName' interPacketGapMilliseconds must be between 0 and 60000."
    }
    if ([bool]$defaultProfile.restartable -and [bool]$defaultProfile.unbuffered) {
        throw "Get-AzLocalSideloadSettings: copy profile '$defaultProfileName' cannot enable both restartable and unbuffered modes."
    }

    if (-not $config.identity.ContainsKey('task') -or -not ($config.identity.task -is [hashtable])) {
        throw "Get-AzLocalSideloadSettings: identity.task is required."
    }
    $taskLogonType = [string]$config.identity.task.logonType
    if ($taskLogonType -notin @('ServiceAccount', 'Password')) {
        throw "Get-AzLocalSideloadSettings: identity.task.logonType must be ServiceAccount or Password for UNC access."
    }
    if ([bool]$config.enabled -and [string]::IsNullOrWhiteSpace([string]$config.identity.task.principalUserId)) {
        throw "Get-AzLocalSideloadSettings: identity.task.principalUserId is required when sideloading is enabled."
    }
    if ([bool]$config.enabled -and $taskLogonType -eq 'Password') {
        foreach ($secretField in @('passwordKeyVaultName', 'passwordSecretName')) {
            if ([string]::IsNullOrWhiteSpace([string]$config.identity.task[$secretField])) {
                throw "Get-AzLocalSideloadSettings: identity.task.$secretField is required when logonType is Password."
            }
        }
    }

    return [pscustomobject]@{
        SchemaVersion  = [int]$config.schemaVersion
        SourcePath     = $fullPath
        Enabled        = [bool]$config.enabled
        Paths          = $config.paths
        Planning       = $config.planning
        Reconciliation = $config.reconciliation
        Copy           = $config.copy
        Identity       = $config.identity
        Remoting       = $config.remoting
        Reporting      = $config.reporting
        Raw            = $config
    }
}