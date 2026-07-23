Function Start-AzLocalTemplateDeployment {
    <#
    .SYNOPSIS

    This script is used to deploy Azure Local using an ARM template deployment

    .DESCRIPTION

    This script is used to deploy Azure Local using an ARM template deployment. It requires the following parameters:
    - SubscriptionId: The ID of the Azure subscription to use for the deployment.
    - TenantId: The ID of the Azure tenant to use for the deployment.
    - TypeOfDeployment: The type of deployment to perform (e.g., SingleNode, StorageSwitched, StorageSwitchless, RackAware, Disaggregated).
    - DeploymentMode: Validate (validate only), Deploy (deploy only), or ValidateAndDeploy (validate first, then deploy on success).
    - NodeCount: The number of nodes for StorageSwitched (2-16), StorageSwitchless (2-4), RackAware (2, 4, 6, 8), or Disaggregated (1-64) deployments.

    Credentials can be supplied in three ways (highest to lowest priority):
    1. Azure Key Vault: -CredentialKeyVaultName (with optional -LocalAdminSecretName / -LCMAdminSecretName)
    2. PSCredential objects: -LocalAdminCredential and -LCMAdminCredential
    3. Interactive prompts: Read-Host -AsSecureString (default when no credential parameters are supplied)

    For fully non-interactive (CI/CD) deployments, also supply -UniqueID and -NetworkSettingsJson.
    Supports -WhatIf and -Confirm for safe dry-run and confirmation before ARM submission.

    Azure Local cluster deployments require two sequential ARM deployments: first with deploymentMode
    set to 'Validate', then once validation succeeds, a second deployment with deploymentMode set to
    'Deploy'. The 'ValidateAndDeploy' option automates this two-phase process.
    Reference: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template

    Resource naming standards are loaded from .config/naming-standards-config.json.
    Use -NamingConfigPath to specify a custom configuration file.

    #>

    [OutputType('Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroupDeployment')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialKeyVaultName',
        Justification = 'This is the name of the Key Vault resource, not a credential value.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory = $true,Position=0)]
        [guid]$SubscriptionId,

        [Parameter(Mandatory = $true,Position=1)]
        [ValidateSet("SingleNode","StorageSwitchless","StorageSwitched","RackAware","Disaggregated")]
        [string]$TypeOfDeployment,
        
        [Parameter(Mandatory = $true,Position=2)]
        [guid]$TenantId,

        [Parameter(Mandatory = $true,Position=3)]
        [ValidateSet("Validate","Deploy","ValidateAndDeploy")]
        [string]$DeploymentMode,

        [Parameter(Mandatory = $false,Position=4)]
        [ValidateRange(1, 64)]
        [int]$NodeCount = 0,

        [Parameter(Mandatory = $false,Position=5)]
        [string]$Location = "",

        [Parameter(Mandatory = $false,Position=6)]
        [string[]]$DnsServers = @(),

        [Parameter(Mandatory = $false,Position=7)]
        [string[]]$ComputeManagementAdapters = @(),

        [Parameter(Mandatory = $false,Position=8)]
        [string[]]$StorageAdapters = @(),

        # --- Disaggregated (SAN) deployment parameters ---
        # Required when -TypeOfDeployment is 'Disaggregated' and not supplied via -NetworkSettingsJson

        [Parameter(Mandatory = $false)]
        [string]$InfraVolLunId = "",

        [Parameter(Mandatory = $false)]
        [string]$InfraPerfLunId = "",

        [Parameter(Mandatory = $false)]
        [string]$SanNetworkAdapterName = "",

        [Parameter(Mandatory = $false)]
        # SAN cluster network VLAN ID. Valid VLANs are 0-4095 (0 = untagged).
        # The sentinel value -1 means "not provided" and triggers the JSON / config fallback.
        # Range explicitly includes -1 so callers can pass it explicitly without binder failure;
        # do NOT tighten this to (0, 4095) as that would break the sentinel contract.
        [ValidateRange(-1, 4095)]
        [int]$SanNetworkVlanId = -1,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}/\d{1,2}$|^$')]
        [string]$SanNetworkAddressPrefix = "",

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 97)]
        [int]$SanBandwidthPercentageSmb = 50,

        [Parameter(Mandatory = $false)]
        [ValidateSet(1514, 9014)]
        [int]$SanJumboPacket = 9014,

        [Parameter(Mandatory = $false)]
        [string]$LogFilePath = "",

        # --- Credential parameters (optional - falls back to interactive Read-Host prompts) ---

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$LocalAdminCredential,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.PSCredential]$LCMAdminCredential,

        # --- Azure Key Vault credential retrieval (optional - overrides interactive prompts) ---

        [Parameter(Mandatory = $false)]
        [string]$CredentialKeyVaultName = "",

        [Parameter(Mandatory = $false)]
        [string]$LocalAdminSecretName = "",

        [Parameter(Mandatory = $false)]
        [string]$LCMAdminSecretName = "",

        # --- Non-interactive parameters (optional - bypass Read-Host prompts) ---

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^[a-zA-Z0-9]{2,8}$')]
        [string]$UniqueID = "",

        [Parameter(Mandatory = $false)]
        [string]$NetworkSettingsJson = "",

        # --- Internal switch: skip pre-flight checks when called from Start-AzLocalCsvDeployment ---
        # (Pre-flight checks were already performed by Test-AzLocalClusterPreFlight)
        [Parameter(Mandatory = $false, DontShow = $true)]
        [switch]$SkipPreFlightChecks,

        # --- Optional: skip searching the Azure Local Supportability TSG repository for matching troubleshooting guides on failure ---
        # (Online TSG search is enabled by default; use this switch to disable it)
        [Parameter(Mandatory = $false)]
        [switch]$SkipOnlineTSGSearch,

        # --- Optional: path to a custom naming-standards-config.json file ---
        # (Overrides the default user profile and module config file resolution)
        [Parameter(Mandatory = $false)]
        [string]$NamingConfigPath = ""

    )

    # Reset module-scoped log path (prevents bleed-over from previous function calls)
    $script:AzLocalLogFilePath = $null

    # Initialise log file if specified
    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        Initialize-AzLocalLogFile -LogFilePath $LogFilePath
    }

    Write-AzLocalLog "Starting Azure Local Template Deployment" -Level Success
    Write-AzLocalLog "/////////////////////////////////////////" -Level Success -NoTimestamp
    Write-AzLocalLog "Subscription ID: $SubscriptionId" -Level Info
    Write-AzLocalLog "Tenant ID: $TenantId" -Level Info
    Write-AzLocalLog "Type of Deployment: $TypeOfDeployment" -Level Info
    Write-Verbose "DeploymentMode: $DeploymentMode | NodeCount: $NodeCount | Location: $Location"

    # Pin the Azure context to the requested subscription and tenant. In multi-subscription
    # tenants the signed-in identity can default to the WRONG subscription, which makes the
    # resource group / Arc node / prerequisite checks (and the deployment itself) run against
    # the wrong subscription and fail with misleading "not found" errors.
    # (Skipped when called from Start-AzLocalCsvDeployment, which already set the context.)
    if (-not $SkipPreFlightChecks) {
        try {
            Set-AzContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
            Write-AzLocalLog "Azure context set to subscription '$SubscriptionId'." -Level Success
        } catch {
            Write-AzLocalLog "Failed to set Azure context to subscription '$SubscriptionId' (tenant '$TenantId'): $($_.Exception.Message)" -Level Error
            throw "Failed to set Azure context to subscription '$SubscriptionId'. Verify you are signed in (Connect-AzAccount) and have access to this subscription. $($_.Exception.Message)"
        }
    }

    # Validate NodeCount for each deployment type
    if ($TypeOfDeployment -eq "SingleNode" -and $NodeCount -gt 1) {
        Write-AzLocalLog "SingleNode deployment does not support -NodeCount greater than 1. SingleNode is always a single node." -Level Error
        throw "SingleNode deployment does not support -NodeCount greater than 1. Use -NodeCount 1 or omit it for SingleNode deployments."
    }
    if ($TypeOfDeployment -eq "StorageSwitched" -and $NodeCount -lt 2) {
        Write-AzLocalLog "StorageSwitched deployment requires the -NodeCount parameter (minimum 2)." -Level Error
        throw "StorageSwitched deployment requires -NodeCount >= 2."
    }
    if ($TypeOfDeployment -eq "StorageSwitchless" -and ($NodeCount -lt 2 -or $NodeCount -gt 4)) {
        Write-AzLocalLog "StorageSwitchless deployment requires the -NodeCount parameter (2 to 4 nodes)." -Level Error
        throw "StorageSwitchless deployment requires -NodeCount between 2 and 4."
    }
    if ($TypeOfDeployment -eq "RackAware" -and ($NodeCount -notin @(2, 4, 6, 8))) {
        Write-AzLocalLog "RackAware deployment requires the -NodeCount parameter with an even number of nodes (2, 4, 6, or 8)." -Level Error
        throw "RackAware deployment requires -NodeCount of 2, 4, 6, or 8."
    }
    if ($TypeOfDeployment -eq "Disaggregated" -and ($NodeCount -lt 1 -or $NodeCount -gt 64)) {
        Write-AzLocalLog "Disaggregated (SAN) deployment requires the -NodeCount parameter (1 to 64 nodes)." -Level Error
        throw "Disaggregated deployment requires -NodeCount between 1 and 64."
    }

    #

    # Disaggregated: NodeCount of 1 is permitted (single SAN node) - SingleNode topology rules don't apply
    if ($TypeOfDeployment -eq "Disaggregated" -and $NodeCount -eq 0) {
        Write-AzLocalLog "Disaggregated deployment requires -NodeCount (1-64)." -Level Error
        throw "Disaggregated deployment requires -NodeCount between 1 and 64."
    }
    # Determine effective node count early (needed for parameter file selection and node IP validation)
    switch ($TypeOfDeployment) {
        "SingleNode"    { $effectiveNodeCount = 1 }
        "Disaggregated" { $effectiveNodeCount = $NodeCount }
        default         { $effectiveNodeCount = $NodeCount }
    }

    # Load naming configuration (user profile, explicit path, or module default)
    Write-Verbose "Loading naming configuration..."
    $configResult = Get-AzLocalNamingConfig -Path $NamingConfigPath
    $NamingConfig = $configResult.Config
    $resolvedConfigPath = $configResult.ResolvedPath

    # Validate the config has been customised from shipped defaults
    Test-AzLocalNamingConfigDefaults -Config $NamingConfig -ConfigFilePath $resolvedConfigPath

    # Get Unique ID - use parameter if provided, otherwise prompt interactively
    if (-not [string]::IsNullOrWhiteSpace($UniqueID)) {
        Write-AzLocalLog "Unique ID '$UniqueID' provided via parameter." -Level Success
    } else {
        $UniqueID = Get-ValidUniqueID
    }

    Write-AzLocalLog "Unique ID: $UniqueID" -Level Success

    # Get Deployment Network Settings - use JSON file/string if provided, otherwise prompt interactively
    if (-not [string]::IsNullOrWhiteSpace($NetworkSettingsJson)) {
        Write-Verbose "Loading network settings from provided JSON..."
        $NetworkSettings = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $NetworkSettingsJson -TypeOfDeployment $TypeOfDeployment -NodeCount $NodeCount
    } else {
        Write-Verbose "Collecting network settings interactively for $TypeOfDeployment deployment..."
        $NetworkSettings = Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment $TypeOfDeployment -NodeCount $NodeCount
    }

    # Call function to Get Parameter File Path (StorageSwitchless uses node-count-specific templates)
    $ParameterFilePath = Get-AzLocalParameterFilePath -TypeOfDeployment $TypeOfDeployment -NodeCount $effectiveNodeCount

    # Disaggregated (SAN) deployments use a separate ARM template with SAN-specific schema
    # (storage.storageType = SAN, storage.san block, hostNetwork.sanNetworks instead of storageNetworks).
    if ($TypeOfDeployment -eq 'Disaggregated') {
        $TemplateFilePath = Join-Path $script:ModuleRoot "templates\azure-local-deployment-template-san.json"
    } else {
        $TemplateFilePath = Join-Path $script:ModuleRoot "templates\azure-local-deployment-template.json"
    }
    if(-Not (Test-Path $TemplateFilePath)) {
        Write-AzLocalLog "Template file not found at '$TemplateFilePath'." -Level Error
        throw "Template file not found at '$TemplateFilePath'."
    }
    Write-Verbose "Template file found: $TemplateFilePath"

    # Define the network settings, from the returned object
    $SubnetMask = $NetworkSettings.subnetMask
    $DefaultGateway = $NetworkSettings.defaultGateway
    $startingIPAddress = $NetworkSettings.startingIPAddress
    $endingIPAddress = $NetworkSettings.endingIPAddress
    $nodeIPAddresses = $NetworkSettings.nodeIPAddresses

    # Resolve resource names from naming configuration using UniqueID
    $ClusterWitnessStorageAccountName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.clusterWitnessStorageAccountName -UniqueID $UniqueID
    $ClusterName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.clusterName -UniqueID $UniqueID
    $ResourceGroupName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.resourceGroupName -UniqueID $UniqueID
    # Location: use parameter override if provided, otherwise fall back to config default
    if ([string]::IsNullOrWhiteSpace($Location)) {
        $Location = $NamingConfig.defaults.location
    }
    $DomainFqdn = Resolve-AzLocalResourceName -Pattern $NamingConfig.defaults.domainFqdn -UniqueID $UniqueID
    $NamingPrefix = Resolve-AzLocalResourceName -Pattern $NamingConfig.defaults.namingPrefix -UniqueID $UniqueID
    # DnsServers precedence (highest to lowest):
    #   1. -DnsServers parameter (explicit CLI override)
    #   2. dnsServers array inside -NetworkSettingsJson (per-deployment override)
    #   3. NamingConfig.defaults.dnsServers (environment-wide default)
    if ($DnsServers.Count -eq 0) {
        if ($NetworkSettings.PSObject.Properties['dnsServers'] -and $NetworkSettings.dnsServers -and @($NetworkSettings.dnsServers).Count -gt 0) {
            $DnsServers = @($NetworkSettings.dnsServers)
            Write-Verbose "Using dnsServers override from NetworkSettingsJson ($($DnsServers.Count) server(s))."
        } else {
            $DnsServers = @($NamingConfig.defaults.dnsServers)
        }
    }
    # ComputeManagementAdapters: use parameter override if provided, otherwise fall back to config default
    if ($ComputeManagementAdapters.Count -eq 0) {
        $ComputeManagementAdapters = @($NamingConfig.defaults.computeManagementAdapters | ForEach-Object { Resolve-AzLocalResourceName -Pattern $_ -UniqueID $UniqueID })
    }
    # StorageAdapters: use parameter override if provided, otherwise fall back to config default
    if ($StorageAdapters.Count -eq 0) {
        $StorageAdapters = @($NamingConfig.defaults.storageAdapters | ForEach-Object { Resolve-AzLocalResourceName -Pattern $_ -UniqueID $UniqueID })
    }
    $AzureStackLCMAdminUsername = Resolve-AzLocalResourceName -Pattern $NamingConfig.defaults.azureStackLCMAdminUsername -UniqueID $UniqueID
    $KeyVaultName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.keyVaultName -UniqueID $UniqueID
    $CustomLocation = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.customLocation -UniqueID $UniqueID
    $ResourceBridgeName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.resourceBridgeName -UniqueID $UniqueID

    # Storage Account for diagnostics
    $StorageAccountName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.diagnosticStorageAccountName -UniqueID $UniqueID
    $StorageAccountType = $NamingConfig.defaults.storageAccountType

    # Validate all resolved resource names against Azure naming rules (early fail-fast)
    Write-Verbose "Validating resolved resource names against Azure naming constraints..."
    $deploymentName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.deploymentName -UniqueID $UniqueID -TypeOfDeployment $TypeOfDeployment
    $namesToValidate = @{
        'ClusterName'                      = $ClusterName
        'ResourceGroupName'                = $ResourceGroupName
        'KeyVaultName'                     = $KeyVaultName
        'CustomLocation'                   = $CustomLocation
        'ResourceBridgeName'               = $ResourceBridgeName
        'DiagnosticStorageAccountName'     = $StorageAccountName
        'ClusterWitnessStorageAccountName' = $ClusterWitnessStorageAccountName
        'DeploymentName'                   = $deploymentName
    }
    Test-AzLocalResourceNames -Names $namesToValidate

    # Initialize $phase so the catch block has a sensible value if a failure occurs
    # before the deployment-phase foreach loop is entered (StrictMode otherwise throws
    # "variable not set" inside the catch and masks the real root cause).
    $phase = '<pre-deployment>'
    $ClusterDeploymentError = $null

    # Wrap all post-credential code in try/finally to ensure SecureString disposal on any failure path
    try{

    # Resolve credentials: Key Vault > PSCredential parameter > Interactive prompt
    # Priority: CredentialKeyVaultName (highest) > LocalAdminCredential/LCMAdminCredential > Read-Host (lowest)

    if (-not [string]::IsNullOrWhiteSpace($CredentialKeyVaultName)) {
        # --- Retrieve credentials from Azure Key Vault ---
        # Verify Az.KeyVault module is available before attempting retrieval
        if (-not (Get-Module -ListAvailable -Name 'Az.KeyVault')) {
            Write-AzLocalLog "Az.KeyVault module is not installed. Install it with: Install-Module Az.KeyVault" -Level Error
            throw "Az.KeyVault module is required for Key Vault credential retrieval. Install with: Install-Module Az.KeyVault -Scope CurrentUser"
        }
        Write-AzLocalLog "Retrieving credentials from Key Vault '$CredentialKeyVaultName'..." -Level Info
        Write-Verbose "Key Vault credential retrieval mode enabled."

        # Local Admin password from Key Vault
        $kvLocalSecretName = if (-not [string]::IsNullOrWhiteSpace($LocalAdminSecretName)) { $LocalAdminSecretName } else { "LocalAdminCredential" }
        try {
            $kvLocalSecret = Get-AzKeyVaultSecret -VaultName $CredentialKeyVaultName -Name $kvLocalSecretName -ErrorAction Stop
            $localAdminPassword = $kvLocalSecret.SecretValue
            Write-AzLocalLog "Local admin password retrieved from Key Vault secret '$kvLocalSecretName'." -Level Success
        } catch {
            $kvError = $_.Exception.Message
            if ($kvError -match 'SecretNotFound|does not exist|was not found') {
                Write-AzLocalLog "Key Vault secret '$kvLocalSecretName' not found in vault '$CredentialKeyVaultName'. Verify the secret name." -Level Error
                throw "Key Vault secret '$kvLocalSecretName' not found in vault '$CredentialKeyVaultName'."
            } elseif ($kvError -match 'Forbidden|Access denied|does not have.*permission|Unauthorized') {
                Write-AzLocalLog "Permission denied accessing Key Vault '$CredentialKeyVaultName'. Verify the identity has 'Get' secret permission." -Level Error
                throw "Permission denied accessing Key Vault secret '$kvLocalSecretName' in vault '$CredentialKeyVaultName'."
            } else {
                Write-AzLocalLog "Failed to retrieve local admin secret '$kvLocalSecretName' from Key Vault '$CredentialKeyVaultName'." -Level Error
                throw "Failed to retrieve Key Vault secret '$kvLocalSecretName'. $kvError"
            }
        }

        # LCM Admin password from Key Vault
        $kvLCMSecretName = if (-not [string]::IsNullOrWhiteSpace($LCMAdminSecretName)) { $LCMAdminSecretName } else { "AzureStackLCMUserCredential" }
        try {
            $kvLCMSecret = Get-AzKeyVaultSecret -VaultName $CredentialKeyVaultName -Name $kvLCMSecretName -ErrorAction Stop
            $AzureStackLCMAdminPassword = $kvLCMSecret.SecretValue
            Write-AzLocalLog "LCM admin password retrieved from Key Vault secret '$kvLCMSecretName'." -Level Success
        } catch {
            $kvError = $_.Exception.Message
            if ($kvError -match 'SecretNotFound|does not exist|was not found') {
                Write-AzLocalLog "Key Vault secret '$kvLCMSecretName' not found in vault '$CredentialKeyVaultName'. Verify the secret name." -Level Error
                throw "Key Vault secret '$kvLCMSecretName' not found in vault '$CredentialKeyVaultName'."
            } elseif ($kvError -match 'Forbidden|Access denied|does not have.*permission|Unauthorized') {
                Write-AzLocalLog "Permission denied accessing Key Vault '$CredentialKeyVaultName'. Verify the identity has 'Get' secret permission." -Level Error
                throw "Permission denied accessing Key Vault secret '$kvLCMSecretName' in vault '$CredentialKeyVaultName'."
            } else {
                Write-AzLocalLog "Failed to retrieve LCM admin secret '$kvLCMSecretName' from Key Vault '$CredentialKeyVaultName'." -Level Error
                throw "Failed to retrieve Key Vault secret '$kvLCMSecretName'. $kvError"
            }
        }

    } elseif ($LocalAdminCredential -and $LCMAdminCredential) {
        # --- Use PSCredential parameters ---
        Write-Verbose "Using credentials supplied via -LocalAdminCredential and -LCMAdminCredential parameters."
        $localAdminPassword = $LocalAdminCredential.Password
        $AzureStackLCMAdminPassword = $LCMAdminCredential.Password
        Write-AzLocalLog "Credentials provided via PSCredential parameters." -Level Success

    } else {
        # --- Interactive prompt fallback ---
        Write-Verbose "No credential parameters or Key Vault specified. Prompting interactively..."
        $localAdminPassword = Read-Host "`nPlease enter the Nodes Local Admin Password" -AsSecureString -ErrorAction Stop
        if (-not $localAdminPassword -or $localAdminPassword.Length -eq 0) {
            Write-AzLocalLog "Local admin password is required and cannot be empty." -Level Error
            throw "Local admin password is required."
        }
        Write-Verbose "Local admin password captured."

        $AzureStackLCMAdminPassword = Read-Host "`nPlease enter the LCM domain user account admin Password" -AsSecureString -ErrorAction Stop
        if (-not $AzureStackLCMAdminPassword -or $AzureStackLCMAdminPassword.Length -eq 0) {
            Write-AzLocalLog "LCM domain user account password is required and cannot be empty." -Level Error
            throw "LCM domain user account password is required."
        }
        Write-Verbose "LCM admin password captured."
    }

    if($TypeOfDeployment -eq "SingleNode") {
        $effectiveNodeCount = 1
        $storageConnectivitySwitchless = $true
        $witnessType = "No Witness"

    } elseif ($TypeOfDeployment -eq "StorageSwitchless") {
        $effectiveNodeCount = $NodeCount
        $storageConnectivitySwitchless = $true
        $witnessType = "Cloud"

    } elseif ($TypeOfDeployment -eq "StorageSwitched") {
        $effectiveNodeCount = $NodeCount
        $storageConnectivitySwitchless = $false
        $witnessType = "Cloud"

    } elseif ($TypeOfDeployment -eq "RackAware") {
        $effectiveNodeCount = $NodeCount
        $storageConnectivitySwitchless = $false
        $witnessType = "Cloud"

    } elseif ($TypeOfDeployment -eq "Disaggregated") {
        # SAN-backed disaggregated cluster: storageConnectivitySwitchless is meaningful only for S2D,
        # for SAN it is reported as false. Witness Type follows standard rules (Cloud for >=2 nodes).
        $effectiveNodeCount = $NodeCount
        $storageConnectivitySwitchless = $false
        if ($effectiveNodeCount -le 1) { $witnessType = "No Witness" } else { $witnessType = "Cloud" }
    }

    # Build RackAware local availability zones (auto-split evenly across 2 zones)
    $clusterPattern = "Standard"
    $localAvailabilityZones = @()
    if ($TypeOfDeployment -eq "RackAware") {
        $clusterPattern = "RackAware"
        # Zone assignment will be populated after node names are built below
    }

    # Build node names and Arc resource IDs dynamically using naming config
    $nodeNames = @()
    $arcNodeResourceIds = @()
    for ($i = 1; $i -le $effectiveNodeCount; $i++) {
        $nodeName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.nodeNamePattern -UniqueID $UniqueID -NodeNumber $i
        $nodeNames += $nodeName
        $arcNodeResourceIds += "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$nodeName"
    }

    # Validate node names against Azure naming rules (NetBIOS: 1-15 chars, alphanumeric only)
    $nodeNamesToValidate = @{}
    for ($i = 0; $i -lt $nodeNames.Count; $i++) {
        $nodeNamesToValidate["NodeName$($i + 1)"] = $nodeNames[$i]
    }
    Test-AzLocalResourceNames -Names $nodeNamesToValidate

    # Populate RackAware local availability zones after node names are built
    if ($TypeOfDeployment -eq "RackAware") {
        $halfCount = $effectiveNodeCount / 2
        $zoneANodes = $nodeNames[0..($halfCount - 1)]
        $zoneBNodes = $nodeNames[$halfCount..($effectiveNodeCount - 1)]
        $localAvailabilityZones = @(
            [PSCustomObject][Ordered]@{
                "localAvailabilityZoneName" = "ZoneA"
                "nodes" = @($zoneANodes)
            },
            [PSCustomObject][Ordered]@{
                "localAvailabilityZoneName" = "ZoneB"
                "nodes" = @($zoneBNodes)
            }
        )
        Write-AzLocalLog "RackAware: ZoneA nodes: $($zoneANodes -join ', ')" -Level Success
        Write-AzLocalLog "RackAware: ZoneB nodes: $($zoneBNodes -join ', ')" -Level Success
    }

    # Dynamic OU path for the AD Objects of the cluster using the Unique ID
    $adouPath = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.adouPath -UniqueID $UniqueID

    # Get the HCI Resource Provider Object ID
    # Priority: runtime lookup via Get-AzADServicePrincipal > config file value
    $hciResourceProviderObjectID = $null
    try {
        $hciResourceProviderObjectID = (Get-AzADServicePrincipal -DisplayName "Microsoft.AzureStackHCI Resource Provider" -ErrorAction Stop).Id
    } catch {
        Write-Verbose "Get-AzADServicePrincipal lookup failed: $($_.Exception.Message)"
    }
    if (-not $hciResourceProviderObjectID -and $NamingConfig.PSObject.Properties['environment'] -and
        $NamingConfig.environment -and $NamingConfig.environment.PSObject.Properties['hciResourceProviderObjectID'] -and
        -not [string]::IsNullOrWhiteSpace($NamingConfig.environment.hciResourceProviderObjectID)) {
        $hciResourceProviderObjectID = $NamingConfig.environment.hciResourceProviderObjectID
        Write-AzLocalLog "HCI Resource Provider Object ID loaded from config: $hciResourceProviderObjectID" -Level Success
    }
    if (-not $hciResourceProviderObjectID) {
        Write-AzLocalLog "Unable to find the HCI Resource Provider Object ID." -Level Error
        throw "HCI Resource Provider 'Microsoft.AzureStackHCI Resource Provider' not found. Set it in .config/naming-standards-config.json under environment.hciResourceProviderObjectID, or ensure it is registered in the tenant."
    }
    Write-AzLocalLog "HCI Resource Provider Object ID: $hciResourceProviderObjectID" -Level Success

    if($TypeOfDeployment -eq "SingleNode") {
        $physicalNodeSettings = [PSCustomObject][Ordered]@{"value" = @([PSCustomObject][Ordered]@{
            "name" = $nodeNames[0]
            "ipv4Address" = $nodeIPAddresses[0]
            })
        }
    } else {
        # StorageSwitched, StorageSwitchless, RackAware and Disaggregated: build physical node settings dynamically
        $nodeSettingsArray = @()
        for ($i = 0; $i -lt $effectiveNodeCount; $i++) {
            $nodeSettingsArray += [PSCustomObject][Ordered]@{
                "name" = $nodeNames[$i]
                "ipv4Address" = $nodeIPAddresses[$i]
            }
        }
        $physicalNodeSettings = [PSCustomObject][Ordered]@{"value" = $nodeSettingsArray}
    }

    # Disaggregated: resolve SAN-specific settings (LUN IDs, SAN cluster network) from
    # explicit parameters > NetworkSettingsJson sanSettings block > error
    $sanNetworkListValue = $null
    if ($TypeOfDeployment -eq 'Disaggregated') {
        $sanFromJson = $null
        if ($NetworkSettings -and $NetworkSettings.PSObject.Properties['sanSettings']) {
            $sanFromJson = $NetworkSettings.sanSettings
        }

        # Resolve each SAN field: explicit parameter wins; otherwise fall back to JSON sanSettings
        if ([string]::IsNullOrWhiteSpace($InfraVolLunId))           { if ($sanFromJson) { $InfraVolLunId = $sanFromJson.infraVolLunId } }
        if ([string]::IsNullOrWhiteSpace($InfraPerfLunId))          { if ($sanFromJson) { $InfraPerfLunId = $sanFromJson.infraPerfLunId } }
        if ([string]::IsNullOrWhiteSpace($SanNetworkAdapterName))   { if ($sanFromJson) { $SanNetworkAdapterName = $sanFromJson.sanNetworkAdapterName } }
        if ($SanNetworkVlanId -lt 0)                                { if ($sanFromJson) { $SanNetworkVlanId = [int]$sanFromJson.sanNetworkVlanId } }
        if ([string]::IsNullOrWhiteSpace($SanNetworkAddressPrefix)) { if ($sanFromJson) { $SanNetworkAddressPrefix = $sanFromJson.sanNetworkAddressPrefix } }

        # Validate all required SAN fields are now resolved
        $missingSan = @()
        if ([string]::IsNullOrWhiteSpace($InfraVolLunId))           { $missingSan += '-InfraVolLunId' }
        if ([string]::IsNullOrWhiteSpace($InfraPerfLunId))          { $missingSan += '-InfraPerfLunId' }
        if ([string]::IsNullOrWhiteSpace($SanNetworkAdapterName))   { $missingSan += '-SanNetworkAdapterName' }
        if ($SanNetworkVlanId -lt 0)                                { $missingSan += '-SanNetworkVlanId' }
        if ([string]::IsNullOrWhiteSpace($SanNetworkAddressPrefix)) { $missingSan += '-SanNetworkAddressPrefix' }
        if ($missingSan.Count -gt 0) {
            $list = $missingSan -join ', '
            Write-AzLocalLog "Disaggregated deployment is missing required SAN parameters: $list" -Level Error
            throw "Disaggregated deployment requires SAN parameters: $list (or supply them via -NetworkSettingsJson sanSettings block)."
        }
        if (-not (Test-AzLocalIPv4Cidr -Value $SanNetworkAddressPrefix)) {
            throw "SanNetworkAddressPrefix '$SanNetworkAddressPrefix' is not valid IPv4 CIDR notation."
        }

        # Build the sanNetworks object that the deploymentSettings.hostNetwork.sanNetworks expects.
        # Schema: clusterNetworkConfig { adapterProperties{...}, adapterIPConfig[ {...} ] }
        $sanNetworkListValue = [PSCustomObject][Ordered]@{
            "clusterNetworkConfig" = [PSCustomObject][Ordered]@{
                "adapterProperties" = [PSCustomObject][Ordered]@{
                    "bandwidthPercentageSmb"          = $SanBandwidthPercentageSmb
                    "jumboPacket"                     = $SanJumboPacket
                    "priorityValue8021ActionCluster"  = 7
                    "priorityValue8021ActionSmb"      = 3
                }
                "adapterIPConfig" = @(
                    [PSCustomObject][Ordered]@{
                        "name"               = "clusterNetwork-A"
                        "networkAdapterName" = $SanNetworkAdapterName
                        "vlanId"             = $SanNetworkVlanId
                        "addressPrefix"      = $SanNetworkAddressPrefix
                    }
                )
            }
        }
        Write-AzLocalLog "Disaggregated SAN config: InfraVolLunId='$InfraVolLunId', InfraPerfLunId='$InfraPerfLunId', SanNetworkAdapter='$SanNetworkAdapterName', VLAN=$SanNetworkVlanId, Prefix='$SanNetworkAddressPrefix'" -Level Success
    }

    # Determine the deployment phases based on DeploymentMode
    if ($DeploymentMode -eq "ValidateAndDeploy") {
        $deploymentPhases = @("Validate", "Deploy")
    } else {
        $deploymentPhases = @($DeploymentMode)
    }

    # Define the parameters that need to be modified for the ARM template deployment
    # This variable is a PSCustomObject, that contains the parameters (stored as [PSCustomObject] with value property)
    # The parameters are defined in the template parameter files, and are passed to the Resource Group deployment
    $Parameters = [PSCustomObject][Ordered]@{
        "location" = [PSCustomObject][Ordered]@{"value" = $Location}
        "clusterName" = [PSCustomObject][Ordered]@{"value" = $ClusterName}
        "tenantId" = [PSCustomObject][Ordered]@{"value" = $TenantId}
        "arcNodeResourceIds" = [PSCustomObject][Ordered]@{"value" = $arcNodeResourceIds}
        "keyVaultName" = [PSCustomObject][Ordered]@{"value" = $KeyVaultName}
        "azureStackLCMAdminUsername" = [PSCustomObject][Ordered]@{"value" = $AzureStackLCMAdminUsername}
        "customLocation" = [PSCustomObject][Ordered]@{"value" = $CustomLocation}
        "resourceBridgeName" = [PSCustomObject][Ordered]@{"value" = $ResourceBridgeName}
        "diagnosticStorageAccountName" = [PSCustomObject][Ordered]@{"value" = $StorageAccountName}
        "witnessType" = [PSCustomObject][Ordered]@{"value" = $witnessType}
        "clusterWitnessStorageAccountName" = [PSCustomObject][Ordered]@{"value" = $ClusterWitnessStorageAccountName}
        "storageAccountType" = [PSCustomObject][Ordered]@{"value" = $StorageAccountType}
        "subnetMask" = [PSCustomObject][Ordered]@{"value" = $SubnetMask}
        "defaultGateway" = [PSCustomObject][Ordered]@{"value" = $DefaultGateway}
        "startingIPAddress" = [PSCustomObject][Ordered]@{"value" = $startingIPAddress}
        "endingIPAddress" = [PSCustomObject][Ordered]@{"value" = $endingIPAddress}
        "domainFqdn" = [PSCustomObject][Ordered]@{"value" = $DomainFqdn}
        "namingPrefix" = [PSCustomObject][Ordered]@{"value" = $NamingPrefix}
        "adouPath" = [PSCustomObject][Ordered]@{"value" = $adouPath}
        "dnsServers" = [PSCustomObject][Ordered]@{"value" = $DnsServers}
        "storageConnectivitySwitchless" = [PSCustomObject][Ordered]@{"value" = $storageConnectivitySwitchless}
        "physicalNodesSettings" = $physicalNodeSettings
        "hciResourceProviderObjectID" = [PSCustomObject][Ordered]@{"value" = $hciResourceProviderObjectID}
        "deploymentMode" = [PSCustomObject][Ordered]@{"value" = $deploymentPhases[0]}
    }

    if ($TypeOfDeployment -eq 'Disaggregated') {
        # SAN template parameters: storage LUN IDs, sanNetworkList object, configurationMode forced to InfraOnly.
        # The SAN ARM template does NOT define clusterPattern / localAvailabilityZones / enableStorageAutoIp parameters.
        $Parameters | Add-Member -MemberType NoteProperty -Name "infraVolLunId"   -Value ([PSCustomObject][Ordered]@{"value" = $InfraVolLunId})
        $Parameters | Add-Member -MemberType NoteProperty -Name "infraPerfLunId"  -Value ([PSCustomObject][Ordered]@{"value" = $InfraPerfLunId})
        $Parameters | Add-Member -MemberType NoteProperty -Name "sanNetworkList"  -Value ([PSCustomObject][Ordered]@{"value" = $sanNetworkListValue})
        $Parameters | Add-Member -MemberType NoteProperty -Name "configurationMode" -Value ([PSCustomObject][Ordered]@{"value" = "InfraOnly"})
    } else {
        # Non-SAN templates: include RackAware-specific parameters
        $Parameters | Add-Member -MemberType NoteProperty -Name "clusterPattern"          -Value ([PSCustomObject][Ordered]@{"value" = $clusterPattern})
        $Parameters | Add-Member -MemberType NoteProperty -Name "localAvailabilityZones"  -Value ([PSCustomObject][Ordered]@{"value" = $localAvailabilityZones})
    }

    # Create the deployment
    # ($deploymentName was resolved and validated earlier alongside other resource names)
    
    # Verify the resource group and Arc nodes exist before starting deployment
    # (Skip when called from Start-AzLocalCsvDeployment - pre-flight already performed by Test-AzLocalClusterPreFlight)
    if ($SkipPreFlightChecks) {
        Write-Verbose "Skipping pre-flight checks (already performed by caller)."
    } else {
        $ResourceGroup = $null
        try {
            $ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Stop
        } catch {
            if (-not (Test-AzLocalNotFoundError -ErrorRecord $_ -ErrorCode @('ResourceGroupNotFound', 'ResourceNotFound'))) {
                throw "Failed to query resource group '$ResourceGroupName': $($_.Exception.Message)"
            }
        }
        if(-not($ResourceGroup)) {
            Write-AzLocalLog "Resource group '$ResourceGroupName' not found in Subscription: $SubscriptionID." -Level Error
            Write-AzLocalLog "Unable to proceed - Arc Node(s) cannot exist in Azure if the resource group does not exist." -Level Error
            throw "Resource group '$ResourceGroupName' not found."

        } else {

            # Resource group exists - run Azure prerequisite checks before proceeding
            Write-AzLocalLog "Found target resource group '$ResourceGroupName' for deployment." -Level Success

            # Check Azure prerequisites (resource providers registered + RBAC advisory)
            $prereqResult = Test-AzLocalAzurePrerequisites -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
            if ($prereqResult.Status -eq 'Failed') {
                foreach ($msg in $prereqResult.Messages) { Write-AzLocalLog $msg -Level Warning }
                Write-AzLocalLog "Azure prerequisite checks failed. See messages above for details." -Level Error
                throw "Azure prerequisite checks failed. Ensure all required resource providers are registered. Reference: https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions"
            }

            # Check if the Arc Nodes exist in the resource group
            ForEach($arcNodeResourceId in $arcNodeResourceIds) {
                Write-AzLocalLog "Checking Arc Node is registered in resource group: '$ResourceGroupName'" -Level Warning
                Write-Verbose "Arc Node Resource ID: '$arcNodeResourceId'"
                $ClusterNodeCheck = $null
                # Existence-aware lookup: returns $null only for a genuine 404; a real
                # failure (e.g. unsupported api-version, auth, RBAC) throws with the real
                # ARM error instead of being masked as "Arc node not found".
                # Default to the GA api-version for Microsoft.HybridCompute/machines; the
                # helper self-heals (parses ARM's supported list) if a region rejects it.
                $arcMachineApiVersion = '2025-01-13'
                $ClusterNodeCheck = Get-AzLocalArmResource -ResourceId $arcNodeResourceId -ResourceKind 'Arc node' -ApiVersion $arcMachineApiVersion
                if($ClusterNodeCheck) {
                    Write-AzLocalLog "Arc Node exists in target resource group: '$ResourceGroupName'" -Level Success
                } else {
                    Write-AzLocalLog "Arc node not found in target resource group: '$ResourceGroupName'" -Level Error
                    Write-AzLocalLog "Missing Resource ID: $arcNodeResourceId" -Level Error
                    throw "Arc node '$arcNodeResourceId' not found in resource group '$ResourceGroupName'."
                }
            }
        }
    }

        # Execute each deployment phase (Validate, then optionally Deploy)
        foreach ($phase in $deploymentPhases) {

            Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
            Write-AzLocalLog "  Deployment Phase: $phase" -Level Info -NoTimestamp
            Write-AzLocalLog "========================================================" -Level Info -NoTimestamp

            # ShouldProcess gate - respects -WhatIf and -Confirm
            if (-not $PSCmdlet.ShouldProcess("Resource Group '$ResourceGroupName'", "$phase deployment '$deploymentName'")) {
                Write-AzLocalLog "Deployment phase '$phase' skipped by user." -Level Warning
                continue
            }

            # Update the deploymentMode in the parameter file for this phase
            $Parameters.deploymentMode = [PSCustomObject][Ordered]@{"value" = $phase}

            # Re-generate the deployment parameter file with the updated deploymentMode
            # Reload the base parameter file settings to avoid stale state
            Write-Verbose "Reloading parameter file settings for '$phase' phase..."
            [PsCustomObject]$PhaseParameterFileSettings = Get-AzLocalParameterFileSettings -ParameterFilePath $ParameterFilePath

            # Re-apply adapter overrides to the fresh parameter file settings
            foreach ($intent in $PhaseParameterFileSettings.parameters.intentList.value) {
                if ($intent.name -eq "Compute_Management") { $intent.adapter = $ComputeManagementAdapters }
                if ($intent.name -eq "Storage") { $intent.adapter = $StorageAdapters }
            }
            # storageNetworkList only applies to non-SAN templates (Disaggregated has sanNetworkList instead)
            if ($TypeOfDeployment -ne 'Disaggregated' -and $PhaseParameterFileSettings.parameters.PSObject.Properties['storageNetworkList']) {
                for ($si = 0; $si -lt $PhaseParameterFileSettings.parameters.storageNetworkList.value.Count; $si++) {
                    if ($si -lt $StorageAdapters.Count) {
                        $PhaseParameterFileSettings.parameters.storageNetworkList.value[$si].networkAdapterName = $StorageAdapters[$si]
                    }
                }
            }

            $DeploymentParameterFile = New-AzLocalDeploymentParameterFile -Parameters $Parameters -UniqueID $UniqueID -TypeOfDeployment $TypeOfDeployment -ParameterFileSettings $PhaseParameterFileSettings -NodeCount $effectiveNodeCount
            if(-Not (Test-Path $DeploymentParameterFile)) {
                throw "Deployment parameter file was not created for '$phase' phase."
            }

            # Start the deployment for this phase
            Write-AzLocalLog "Starting '$phase' deployment '$deploymentName' in resource group: '$ResourceGroupName'" -Level Success
            $ClusterDeployment = New-AzResourceGroupDeployment -Name $deploymentName -ResourceGroupName $ResourceGroupName -TemplateFile $TemplateFilePath -TemplateParameterFile $DeploymentParameterFile -AzureStackLCMAdminPassword $AzureStackLCMAdminPassword -localAdminPassword $localAdminPassword -Verbose -ErrorVariable ClusterDeploymentError -ErrorAction Stop

            if ($ClusterDeployment.ProvisioningState -eq "Succeeded") {
                Write-AzLocalLog "'$phase' phase succeeded!" -Level Success
            } else {
                Write-AzLocalLog "'$phase' phase failed! ProvisioningState: $($ClusterDeployment.ProvisioningState)" -Level Error
                Write-AzLocalLog "Error details: $ClusterDeploymentError" -Level Error
                return $ClusterDeployment
            }

            # If this was the Validate phase and there is a Deploy phase next, inform the user
            if ($phase -eq "Validate" -and $deploymentPhases.Count -gt 1) {
                Write-AzLocalLog "Validation succeeded. Proceeding to Deploy phase..." -Level Success
                Write-Verbose "Reference: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template"
            }
        }
    } catch {
        # Save the original error before any nested catch can overwrite $_
        $deployError = $_
        Write-AzLocalLog "Error during '$phase' deployment: $($deployError.Exception.Message)" -Level Error

        $errorDetailsMessage = $null
        if ($deployError.PSObject.Properties['ErrorDetails'] -and $deployError.ErrorDetails -and
            $deployError.ErrorDetails.PSObject.Properties['Message']) {
            $errorDetailsMessage = [string]$deployError.ErrorDetails.Message
        }

        # Surface ARM inner error details when available (InvalidTemplateDeployment wraps the real errors)
        if (-not [string]::IsNullOrWhiteSpace($errorDetailsMessage)) {
            try {
                $errorBody = $errorDetailsMessage | ConvertFrom-Json
                if ($errorBody.error.details) {
                    Write-AzLocalLog "ARM validation inner errors:" -Level Error
                    foreach ($detail in $errorBody.error.details) {
                        Write-AzLocalLog "  [$($detail.code)] $($detail.message)" -Level Error
                    }
                }
            } catch {
                # ErrorDetails wasn't JSON - log it raw
                Write-AzLocalLog "Error details: $errorDetailsMessage" -Level Error
            }
        }

        # Also surface the -ErrorVariable content if available
        if ($ClusterDeploymentError) {
            Write-AzLocalLog "Deployment error variable: $ClusterDeploymentError" -Level Error
        }

        # Provide troubleshooting hints for common validation/deployment failures
        $troubleshootErrorText = "$($deployError.Exception.Message)"
        if (-not [string]::IsNullOrWhiteSpace($errorDetailsMessage)) { $troubleshootErrorText += " $errorDetailsMessage" }
        $troubleshootParams = @{ ErrorText = $troubleshootErrorText }
        if (-not $SkipOnlineTSGSearch) { $troubleshootParams['SearchOnline'] = $true }
        Get-AzLocalValidationTroubleshootingHints @troubleshootParams

        throw $deployError
    } finally {
        # Securely dispose sensitive credential variables from memory.
        # Each Dispose() is wrapped individually so that a failure on one variable
        # does not skip cleanup of subsequent variables.
        try { if ($localAdminPassword -is [System.Security.SecureString]) { $localAdminPassword.Dispose() } } catch { Write-Verbose "Failed to dispose localAdminPassword: $($_.Exception.Message)" }
        try { if ($AzureStackLCMAdminPassword -is [System.Security.SecureString]) { $AzureStackLCMAdminPassword.Dispose() } } catch { Write-Verbose "Failed to dispose AzureStackLCMAdminPassword: $($_.Exception.Message)" }
        $localAdminPassword = $null
        $AzureStackLCMAdminPassword = $null
        $kvLocalSecret = $null
        $kvLCMSecret = $null
    }
    
    Write-AzLocalLog "All deployment phases completed successfully!" -Level Success
    
    # Return the deployment object for further processing
    return $ClusterDeployment
}
