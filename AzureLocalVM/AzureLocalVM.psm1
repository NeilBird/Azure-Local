##########################################################################################################
<#
.SYNOPSIS
    Author:     Neil Bird, MSFT
    Version:    0.1.6
    Created:    December 1st 2025
    Updated:    December 8th 2025

.DESCRIPTION
    PowerShell module for managing Azure Local VMs, networks, and shared storage.
    Initially created using Claud Sonnet v4.5 AI agent.
    Requires: Az.StackHCIVM, Az.CustomLocation, Az.Accounts, Az.KeyVault PowerShell modules, PowerShell 5.1+, FailoverClusters module

    This module provides functions for creating and managing Azure Local (Azure Stack HCI) resources:
    - Azure Local Virtual machines, optionally using a KeyVault secret for admin password
    - Logical networks
    - Virtual network interfaces (vNICs)
    - Create Shared VHD Sets for guest clustering inside Azure Local VMs
    - Attaching Shared VHD Sets to Azure Local VMs

.EXAMPLE
    Import-Module AzureLocalVM

    # Check prerequisites
    if (Test-Prerequisites) {
        Write-Host "All prerequisites met. Proceeding with Azure Local VM operations."
    } else {
        Write-Host "Prerequisite checks failed. Please resolve the issues and try again."
    }

    # Set variables
    $SubscriptionId = "<your-subscription-id>"
    $resourceGroup = "myResourceGroup"
    $clusterName = "myCluster"
    $customLocationId = Get-CustomLocationIdForCluster -ClusterName $clusterName -SubscriptionId $SubscriptionId -ResourceGroup $resourceGroup

    New-AzureLocalLogicalNetwork -NetworkName "dhcp-network" -SubscriptionId $SubscriptionId -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -VirtualSwitchName "ConvergedSwitch(compute_management)" -IpAllocationMethod Dynamic -vlanId "500"
    New-AzureLocalVM -VMName "TestVM-01" -SubscriptionId $SubscriptionId -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -NicName "TestVM-01-nic" -VMSize "Standard_D2s_v3" -VMImage "Windows Server 2022 Datacenter: Azure Edition Hotpatch - Gen2" -AdminUsername "admin" -KeyVaultSecretId "https://myvault.vault.azure.net/secrets/vmpassword"
    New-AzureLocalVM -VMName "TestVM-02" -SubscriptionId $SubscriptionId -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -NicName "TestVM-02-nic" -VMSize "Standard_D2s_v3" -VMImage "Windows Server 2022 Datacenter: Azure Edition Hotpatch - Gen2" -AdminUsername "admin" -KeyVaultSecretId "https://myvault.vault.azure.net/secrets/vmpassword"
    $vhdSetPath = New-HyperVVHDSet -TargetCluster $clusterName -ClusterSharedVolume "C:\ClusterStorage\UserStorage_1\VHDs" -VHDName "SQLSharedDisk01.vhds" -VHDSizeGB 20 -VHDType Dynamic
    Add-VHDSetToAzureLocalVM -TargetCluster $clusterName -VMNames @("TestVM-01", "TestVM-02") -VHDSetPath $vhdSetPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation -1


.NOTES
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.

    This sample is not supported under any Microsoft standard support program or service. 
    The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
    implied warranties including, without limitation, any implied warranties of merchantability
    or of fitness for a particular purpose. The entire risk arising out of the use or performance
    of the sample and documentation remains with you. In no event shall Microsoft, its authors,
    or anyone else involved in the creation, production, or delivery of the script be liable for 
    any damages whatsoever (including, without limitation, damages for loss of business profits, 
    business interruption, loss of business information, or other pecuniary loss) arising out of 
    the use of or inability to use the sample or documentation, even if Microsoft has been advised 
    of the possibility of such damages, rising out of the use of or inability to use the sample script, 
    even if Microsoft has been advised of the possibility of such damages.

#>
##########################################################################################################

    # region Helper Functions

<#
.SYNOPSIS
    Writes a log message with timestamp and severity level.

.PARAMETER Message
    The message to log.

.PARAMETER Level
    The severity level (Info, Warning, Error, Success).
#>
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $colorMap = @{
        "Info" = "Cyan"
        "Warning" = "Yellow"
        "Error" = "Red"
        "Success" = "Green"
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $colorMap[$Level]
}

<#
.SYNOPSIS
    Invokes a script block with retry logic for transient failures.

.PARAMETER ScriptBlock
    The script block to execute.

.PARAMETER OperationName
    Descriptive name of the operation for logging.

.PARAMETER MaxAttempts
    Maximum number of retry attempts.

.PARAMETER DelaySeconds
    Delay between retry attempts in seconds.
#>
function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$ScriptBlock,
        
        [Parameter(Mandatory = $true)]
        [string]$OperationName,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxAttempts = 3,
        
        [Parameter(Mandatory = $false)]
        [int]$DelaySeconds = 5
    )
    
    $attempt = 1
    while ($attempt -le $MaxAttempts) {
        try {
            Write-Log "Attempting $OperationName (Attempt $attempt of $MaxAttempts)"
            $result = & $ScriptBlock
            Write-Log "$OperationName succeeded" -Level Success
            return $result
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                Write-Log "$OperationName failed after $MaxAttempts attempts: $_" -Level Error
                throw
            }
            Write-Log "$OperationName failed (Attempt $attempt): $_. Retrying in $DelaySeconds seconds..." -Level Warning
            Start-Sleep -Seconds $DelaySeconds
            $attempt++
        }
    }
}

<#
.SYNOPSIS
    Validates PowerShell, Azure CLI, and module prerequisites.

.DESCRIPTION
    Checks for required PowerShell version, Azure CLI installation and authentication,
    and required PowerShell modules.

.OUTPUTS
    Boolean indicating whether all prerequisites are met.
#>
function Test-Prerequisites {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    
    Write-Log "Running prerequisite checks..."
    
    $checks = @()
    
    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
        $checks += "PowerShell 5.1 or later is required. Current version: $($PSVersionTable.PSVersion)"
    }
    
    # Check required Az modules
    $requiredAzModules = @('Az.StackHCIVM', 'Az.CustomLocation', 'Az.Accounts', 'Az.KeyVault')
    $missingModules = @()
    
    foreach ($module in $requiredAzModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missingModules += $module
        }
    }
    
    # Prompt to install missing modules
    if ($missingModules.Count -gt 0) {
        Write-Log "Missing required PowerShell modules: $($missingModules -join ', ')" -Level Warning
        $response = Read-Host "Would you like to install the missing modules now? (Y/N)"
        
        if ($response -eq 'Y' -or $response -eq 'y') {
            Write-Log "Installing missing modules..." -Level Info
            foreach ($module in $missingModules) {
                try {
                    Write-Log "Installing $module..." -Level Info
                    Install-Module $module -Force -AllowClobber -Scope CurrentUser -ErrorAction Stop
                    Write-Log "Successfully installed $module" -Level Success
                }
                catch {
                    $checks += "Failed to install module: $module - $_"
                }
            }
        }
        else {
            foreach ($module in $missingModules) {
                $checks += "Required PowerShell module not found: $module. Install with: Install-Module $module"
            }
        }
    }
    
    # Check Azure PowerShell authentication
    try {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context) {
            $checks += "Not logged in to Azure PowerShell. Run 'Connect-AzAccount' first"
        } else {
            Write-Log "Authenticated as: $($context.Account.Id)"
        }
    }
    catch {
        $checks += "Failed to verify Azure PowerShell authentication"
    }
    
    # Check for required modules
    $requiredModules = @('FailoverClusters')
    foreach ($module in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $checks += "Required PowerShell module not found: $module"
        }
    }
    
    if ($checks.Count -gt 0) {
        Write-Log "Prerequisite checks failed:" -Level Error
        foreach ($check in $checks) {
            Write-Log "  - $check" -Level Error
        }
        return $false
    }
    
    Write-Log "All prerequisite checks passed" -Level Success
    return $true
}

<#
.SYNOPSIS
    Tests if the current machine is a node in the specified cluster.

.PARAMETER TargetCluster
    The name of the cluster to check.

.OUTPUTS
    Boolean indicating if the current machine is a cluster node.
#>
function Test-IsClusterNode {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetCluster
    )
    
    try {
        Write-Log "Checking if current machine is a node in cluster: $TargetCluster"
        
        # Get cluster nodes
        $clusterNodes = Get-ClusterNode -Cluster $TargetCluster -ErrorAction Stop
        
        if (-not $clusterNodes) {
            Write-Log "No cluster nodes found for cluster: $TargetCluster" -Level Warning
            return $false
        }
        
        # Get current computer name
        $currentComputer = $env:COMPUTERNAME
        Write-Log "Current computer: $currentComputer"
        
        # Check if current computer is in the cluster
        $isClusterNode = $clusterNodes | Where-Object { $_.Name -eq $currentComputer }
        
        if ($isClusterNode) {
            Write-Log "Current machine is a node in cluster: $TargetCluster" -Level Success
            return $true
        } else {
            Write-Log "Current machine is NOT a node in cluster: $TargetCluster" -Level Info
            return $false
        }
    }
    catch {
        Write-Log "Error checking cluster node status: $_" -Level Warning
        return $false
    }
}

#endregion

#region Azure Local Functions

<#
.SYNOPSIS
    Retrieves the custom location ID from an Azure Local cluster name.

.PARAMETER ClusterName
    The name of the Azure Local cluster.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group containing the cluster.

.OUTPUTS
    String containing the custom location resource ID.
#>
function Get-CustomLocationIdForCluster {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    return Invoke-WithRetry -OperationName "Get Custom Location ID for Cluster" -ScriptBlock {
        Write-Log "Retrieving custom location id for cluster: $ClusterName"

        # Set the Azure subscription context
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

        # Get custom locations in the resource group
        $customLocations = Get-AzCustomLocation -ResourceGroupName $ResourceGroup -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue

        if (-not $customLocations) {
            throw "No custom locations found in resource group: $ResourceGroup"
        }

        # Find custom location associated with the cluster
        $matchingLocation = $customLocations | Where-Object {
            $_.HostResourceId -like "*$ClusterName*"
        }

        if ($matchingLocation) {
            $customLocationId = $matchingLocation.Id
            Write-Log "Found custom location: $customLocationId" -Level Success
            return $customLocationId
        } else {
            Write-Log "Available custom locations in resource group:" -Level Info
            foreach ($loc in $customLocations) {
                Write-Log "  - $($loc.Name) (Host: $($loc.HostResourceId))" -Level Info
            }
            throw "No custom location found for cluster: $ClusterName"
        }
    }
}

<#
.SYNOPSIS
    Tests whether an Azure Local logical network exists.

.PARAMETER NetworkName
    The name of the logical network, example: "ConvergedSwitch(compute_management)"

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.OUTPUTS
    Boolean indicating whether the network exists.
#>
function Test-AzureLocalLogicalNetwork {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$NetworkName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup
    )

    try {
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        $network = Get-AzStackHCIVMLogicalNetwork -ResourceGroupName $ResourceGroup -Name $NetworkName -ErrorAction SilentlyContinue
        return ($null -ne $network)
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Tests whether an Azure Local VM image exists, with optional prompt to download from marketplace.

.PARAMETER ImageName
    The name of the VM image.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER CustomLocationId
    The custom location resource ID (required for downloading marketplace images).

.PARAMETER PromptForDownload
    If true, prompts the user to download from marketplace when image is not found. Default is false.

.OUTPUTS
    PSCustomObject with properties: ImageExists (bool), ImageName (string), Downloaded (bool)
#>
function Test-AzureLocalVMImage {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ImageName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $false)]
        [string]$CustomLocationId,
        
        [Parameter(Mandatory = $false)]
        [bool]$PromptForDownload = $false
    )

    try {
        Write-Log "Checking if VM image exists: $ImageName"
        
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        
        # List all available images and search for the specified image
        $imageList = Get-AzStackHCIVMImage -ResourceGroupName $ResourceGroup

        if (-not $imageList) {
            $imageList = @()
        }

        # Check if the image exists in the list (match by name)
        $imageExists = $imageList | Where-Object { $_.Name -eq $ImageName -or $_.ImagePath -like "*$ImageName*" }
        
        if ($imageExists) {
            Write-Log "VM image found: $ImageName" -Level Success
            return [PSCustomObject]@{
                ImageExists = $true
                ImageName = $ImageName
                Downloaded = $false
            }
        } else {
            Write-Log "VM image not found: $ImageName" -Level Warning
            
            # Display available images (only those that are fully downloaded and ready)
            if ($imageList.Count -gt 0) {
                # Filter to only show images with ProvisioningState = 'Succeeded'
                $availableImages = $imageList | Where-Object { $_.ProvisioningState -eq 'Succeeded' }
                
                if ($availableImages.Count -gt 0) {
                    Write-Log "Available images in resource group:" -Level Info
                    for ($i = 0; $i -lt $availableImages.Count; $i++) {
                        Write-Log "  [$($i + 1)] $($availableImages[$i].Name)" -Level Info
                    }
                } else {
                    Write-Log "No images currently available in resource group: $ResourceGroup" -Level Warning
                    
                    # Check if there are images still downloading
                    $downloadingImages = $imageList | Where-Object { $_.ProvisioningState -in @('Creating', 'Updating', 'Accepted') }
                    if ($downloadingImages.Count -gt 0) {
                        Write-Log "Note: $($downloadingImages.Count) image(s) currently downloading:" -Level Info
                        foreach ($img in $downloadingImages) {
                            Write-Log "  - $($img.Name) (State: $($img.ProvisioningState))" -Level Info
                        }
                    }
                }
            } else {
                Write-Log "No images currently available in resource group: $ResourceGroup" -Level Warning
            }
            
            # Prompt to download from marketplace if enabled
            if ($PromptForDownload -and -not [string]::IsNullOrWhiteSpace($CustomLocationId)) {
                # Query Edge Marketplace Offers API for Azure Stack HCI
                Write-Log "Fetching available marketplace offers from Azure Stack HCI cluster..." -Level Info
                    
                    $marketplaceImages = @()
                    
                    try {
                        # Get access token for Azure REST API
                        $azContext = Get-AzContext
                        $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
                        $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
                        $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
                        $accessToken = $token.AccessToken
                        
                        # Create headers
                        $headers = @{
                            'Authorization' = "Bearer $accessToken"
                            'Content-Type' = 'application/json'
                        }
                        
                        # Get cluster name from resource group (assumes single cluster per RG)
                        Write-Log "Discovering Azure Stack HCI cluster in resource group..." -Level Info
                        $clustersUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/clusters?api-version=2023-08-01"
                        $clustersResponse = Invoke-RestMethod -Uri $clustersUri -Method Get -Headers $headers -ErrorAction Stop
                        
                        if (-not $clustersResponse.value -or $clustersResponse.value.Count -eq 0) {
                            throw "No Azure Stack HCI cluster found in resource group $ResourceGroup"
                        }
                        
                        $clusterName = $clustersResponse.value[0].name
                        Write-Log "Found cluster: $clusterName" -Level Info
                        
                        # Edge Marketplace Offers API
                        $apiVersion = "2023-08-01-preview"
                        $marketplaceUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/clusters/$clusterName/providers/Microsoft.EdgeMarketplace/offers?api-version=$apiVersion"
                        
                        Write-Log "Querying Edge Marketplace offers API..." -Level Info
                        Write-Log "API URI: $marketplaceUri" -Level Info
                        $response = Invoke-RestMethod -Uri $marketplaceUri -Method Get -Headers $headers -ErrorAction Stop
                        
                        Write-Verbose "API Response: $($response | ConvertTo-Json -Depth 5 -Compress)"
                        
                        if ($response.value -and $response.value.Count -gt 0) {
                            Write-Log "Found $($response.value.Count) offers in response" -Level Info
                            
                            foreach ($offer in $response.value) {
                                # Extract offer properties
                                $offerName = $offer.name
                                $publisherId = if ($offer.properties.offerContent.offerPublisher.publisherId) { 
                                    $offer.properties.offerContent.offerPublisher.publisherId 
                                } else { 
                                    ($offerName -split ':')[0] 
                                }
                                $offerId = if ($offer.properties.offerContent.offerId) { 
                                    $offer.properties.offerContent.offerId 
                                } else { 
                                    ($offerName -split ':')[1] 
                                }
                                
                                # Check if marketplace SKUs exist
                                if (-not $offer.properties.marketplaceSkus -or $offer.properties.marketplaceSkus.Count -eq 0) {
                                    Write-Log "No SKUs found for offer: $offerName" -Level Warning
                                    continue
                                }
                                
                                Write-Log "Processing $($offer.properties.marketplaceSkus.Count) SKUs for offer: $($offer.properties.offerContent.displayName)" -Level Info
                                
                                # Get SKUs for this offer
                                foreach ($sku in $offer.properties.marketplaceSkus) {
                                    $skuId = $sku.marketplaceSkuId
                                    $catalogPlanId = $sku.catalogPlanId
                                    
                                    # Determine OS type from the SKU's operatingSystem property
                                    $osType = if ($sku.operatingSystem.family) {
                                        if ($sku.operatingSystem.family -eq 'Windows') { 'Windows' } else { 'Linux' }
                                    } else {
                                        if ($publisherId -match 'microsoft' -and $offerId -match 'windows') { 'Windows' } else { 'Linux' }
                                    }
                                    
                                    # Construct URN
                                    $urn = "${publisherId}:${offerId}:${skuId}:latest"
                                    $displayName = $sku.displayName
                                    
                                    $marketplaceImages += [PSCustomObject]@{
                                        DisplayName = $displayName
                                        URN = $urn
                                        OSType = $osType
                                        Publisher = $publisherId
                                        Offer = $offerId
                                        SKU = $skuId
                                        Version = 'latest'
                                        HyperVGeneration = $sku.generation
                                        Description = $sku.displayName
                                        ResourceName = $offerName
                                        CatalogPlanId = $catalogPlanId
                                    }
                                }
                            }
                            
                            Write-Log "Found $($marketplaceImages.Count) marketplace offers from Edge Marketplace" -Level Success
                        } else {
                            Write-Log "No marketplace offers found for cluster, using fallback catalog..." -Level Warning
                            throw "No offers from API"
                        }
                    }
                    catch {
                        Write-Log "Failed to fetch marketplace images from API: $_" -Level Warning
                        Write-Log "Using curated marketplace image catalog..." -Level Info
                        
                        # Fallback to curated list if API fails
                        $marketplaceImages = @(
                            [PSCustomObject]@{
                                DisplayName = "WindowsServer - 2022-datacenter-azure-edition"
                                URN = "MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest"
                                OSType = "Windows"
                                Publisher = "MicrosoftWindowsServer"
                                Offer = "WindowsServer"
                                SKU = "2022-datacenter-azure-edition"
                                Version = "latest"
                                HyperVGeneration = "V2"
                                Description = "Windows Server 2022 Datacenter Azure Edition"
                            },
                            [PSCustomObject]@{
                                DisplayName = "WindowsServer - 2022-datacenter-azure-edition-hotpatch"
                                URN = "MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition-hotpatch:latest"
                                OSType = "Windows"
                                Publisher = "MicrosoftWindowsServer"
                                Offer = "WindowsServer"
                                SKU = "2022-datacenter-azure-edition-hotpatch"
                                Version = "latest"
                                HyperVGeneration = "V2"
                                Description = "Windows Server 2022 Datacenter Azure Edition Hotpatch"
                            },
                            [PSCustomObject]@{
                                DisplayName = "WindowsServer - 2019-Datacenter"
                                URN = "MicrosoftWindowsServer:WindowsServer:2019-Datacenter:latest"
                                OSType = "Windows"
                                Publisher = "MicrosoftWindowsServer"
                                Offer = "WindowsServer"
                                SKU = "2019-Datacenter"
                                Version = "latest"
                                HyperVGeneration = "V2"
                                Description = "Windows Server 2019 Datacenter"
                            },
                            [PSCustomObject]@{
                                DisplayName = "0001-com-ubuntu-server-jammy - 22_04-lts-gen2"
                                URN = "Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest"
                                OSType = "Linux"
                                Publisher = "Canonical"
                                Offer = "0001-com-ubuntu-server-jammy"
                                SKU = "22_04-lts-gen2"
                                Version = "latest"
                                HyperVGeneration = "V2"
                                Description = "Ubuntu Server 22.04 LTS Gen2"
                            },
                            [PSCustomObject]@{
                                DisplayName = "0001-com-ubuntu-server-focal - 20_04-lts-gen2"
                                URN = "Canonical:0001-com-ubuntu-server-focal:20_04-lts-gen2:latest"
                                OSType = "Linux"
                                Publisher = "Canonical"
                                Offer = "0001-com-ubuntu-server-focal"
                                SKU = "20_04-lts-gen2"
                                Version = "latest"
                                HyperVGeneration = "V2"
                                Description = "Ubuntu Server 20.04 LTS Gen2"
                            }
                        )
                    }
                    
                    # Try to find a fuzzy match for the requested image name in marketplace
                    $fuzzyMatch = $null
                    $searchTerms = $ImageName -replace '[^a-zA-Z0-9]', '' -replace '\s+', '' -replace '\-+', ''
                    
                    foreach ($img in $marketplaceImages) {
                        # Check various fields for a match (remove special chars and spaces)
                        $imgDisplaySearch = $img.DisplayName -replace '[^a-zA-Z0-9]', '' -replace '\s+', '' -replace '\-+', ''
                        $imgSKUSearch = $img.SKU -replace '[^a-zA-Z0-9]', '' -replace '\s+', '' -replace '\-+', ''
                        $imgDescSearch = $img.Description -replace '[^a-zA-Z0-9]', '' -replace '\s+', '' -replace '\-+', ''
                        
                        # Check for matches
                        if ($imgDisplaySearch -match $searchTerms -or 
                            $searchTerms -match $imgSKUSearch -or 
                            $imgSKUSearch -match $searchTerms -or
                            $imgDescSearch -match $searchTerms) {
                            $fuzzyMatch = $img
                            break
                        }
                    }
                    
                    # If we found a fuzzy match, offer to download it specifically
                    $selectedImageObj = $null
                    if ($fuzzyMatch) {
                        Write-Log "Found potential marketplace match: $($fuzzyMatch.DisplayName)" -Level Success
                        Write-Log "  OS: $($fuzzyMatch.OSType) | $($fuzzyMatch.Description)" -Level Info
                        Write-Host ""
                        Write-Host "Download this image from Azure Marketplace? (Y/N/L to list all): " -NoNewline -ForegroundColor Yellow
                        $downloadResponse = Read-Host
                        
                        if ($downloadResponse -eq 'Y' -or $downloadResponse -eq 'y') {
                            $selectedImageObj = $fuzzyMatch
                        } elseif ($downloadResponse -eq 'L' -or $downloadResponse -eq 'l') {
                            # Show full list - fall through to list below
                        } else {
                            Write-Log "Download cancelled by user" -Level Info
                        }
                    }
                    
                    # If no match found or user wants to see full list
                    if (-not $selectedImageObj) {
                        Write-Log "Available marketplace images:" -Level Info
                        for ($i = 0; $i -lt $marketplaceImages.Count; $i++) {
                            $img = $marketplaceImages[$i]
                            Write-Log "  [$($i + 1)] $($img.DisplayName)" -Level Info
                            Write-Log "      OS: $($img.OSType) | $($img.Description)" -Level Info
                        }
                        Write-Log "  [0] Cancel" -Level Info
                        
                        Write-Host "Select an image to download (enter number): " -NoNewline -ForegroundColor Yellow
                        $selection = Read-Host
                        
                        if ($selection -match '^\d+$' -and [int]$selection -gt 0 -and [int]$selection -le $marketplaceImages.Count) {
                            $selectedImageObj = $marketplaceImages[[int]$selection - 1]
                        } else {
                            Write-Log "Download cancelled by user" -Level Info
                        }
                    }
                    
                    # Process the selected image
                    if ($selectedImageObj) {
                        Write-Log "Selected image: $($selectedImageObj.DisplayName)" -Level Info
                        
                        # Create a descriptive image name combining offer and SKU
                        # Remove spaces and special characters, replace with hyphens for Azure naming compliance
                        $offerPart = $selectedImageObj.Offer -replace '[^a-zA-Z0-9]', '-' -replace '-+', '-'
                        $skuPart = $selectedImageObj.SKU -replace '[^a-zA-Z0-9]', '-' -replace '-+', '-'
                        
                        # Combine offer and SKU for a more descriptive name (e.g., "sql2022-ws2022-standard-gen2")
                        if ($offerPart -ne $skuPart) {
                            $imageName = "$offerPart-$skuPart"
                        } else {
                            $imageName = $skuPart
                        }
                        
                        # Ensure name doesn't exceed Azure resource name limits and clean up any edge cases
                        $imageName = $imageName.Trim('-').ToLower()
                        if ($imageName.Length -gt 80) {
                            $imageName = $imageName.Substring(0, 80).TrimEnd('-')
                        }
                        
                        Write-Log "Image resource name: $imageName" -Level Info
                        
                        # Check if this marketplace image is already downloaded or being provisioned
                        $existingImage = $imageList | Where-Object { $_.Name -eq $imageName }
                        
                        if ($existingImage) {
                            Write-Log "Marketplace image '$imageName' already exists or is being provisioned." -Level Info
                            
                            # Check provisioning state
                            $provisioningState = $existingImage.ProvisioningState
                            
                            if ($provisioningState -eq 'Succeeded') {
                                Write-Log "Image is ready to use: $imageName" -Level Success
                                return [PSCustomObject]@{
                                    ImageExists = $true
                                    ImageName = $imageName
                                    Downloaded = $false
                                }
                            } elseif ($provisioningState -in @('Accepted', 'Creating', 'Updating')) {
                                Write-Log "Image download is already in progress (State: $provisioningState)" -Level Warning
                                Write-Log "Please wait for the download to complete and re-run the VM creation command." -Level Info
                                Write-Log "You can check status in Azure portal or use: Get-AzStackHCIVMImage -Name '$imageName' -ResourceGroupName '$ResourceGroup'" -Level Info
                                return [PSCustomObject]@{
                                    ImageExists = $false
                                    ImageName = $imageName
                                    Downloaded = $true
                                }
                            } else {
                                Write-Log "Image exists with provisioning state: $provisioningState" -Level Warning
                            }
                        }
                        
                        # Check if Azure CLI is available (preferred method per Microsoft documentation)
                        $azCliAvailable = $false
                        $azCliAuthenticated = $false
                        try {
                            $azVersion = az version 2>$null | ConvertFrom-Json
                            if ($azVersion.'azure-cli') {
                                $azCliAvailable = $true
                                Write-Log "Azure CLI version $($azVersion.'azure-cli') detected" -Level Info
                                
                                # Verify Azure CLI authentication
                                try {
                                    $accountInfo = az account show 2>$null | ConvertFrom-Json
                                    if ($accountInfo -and $accountInfo.id) {
                                        $azCliAuthenticated = $true
                                        Write-Log "Azure CLI authenticated with subscription: $($accountInfo.name) ($($accountInfo.id))" -Level Info
                                    }
                                    else {
                                        Write-Log "Azure CLI is installed but not authenticated." -Level Warning
                                        Write-Host "Would you like to authenticate now using device code login? (Y/N): " -NoNewline -ForegroundColor Yellow
                                        $loginResponse = Read-Host
                                        
                                        if ($loginResponse -eq 'Y' -or $loginResponse -eq 'y') {
                                            Write-Log "Initiating Azure CLI device code login..." -Level Info
                                            az login --use-device-code
                                            
                                            if ($LASTEXITCODE -eq 0) {
                                                # Verify authentication was successful
                                                $accountInfo = az account show 2>$null | ConvertFrom-Json
                                                if ($accountInfo -and $accountInfo.id) {
                                                    $azCliAuthenticated = $true
                                                    Write-Log "Azure CLI authentication successful!" -Level Success
                                                    Write-Log "Authenticated with subscription: $($accountInfo.name) ($($accountInfo.id))" -Level Info
                                                }
                                                else {
                                                    Write-Log "Authentication verification failed. Please try 'az login' manually." -Level Warning
                                                }
                                            }
                                            else {
                                                Write-Log "Azure CLI login failed. Will use REST API method instead." -Level Warning
                                            }
                                        }
                                        else {
                                            Write-Log "Azure CLI authentication skipped. Will use REST API method instead." -Level Info
                                        }
                                    }
                                }
                                catch {
                                    Write-Log "Azure CLI is installed but not authenticated." -Level Warning
                                    Write-Host "Would you like to authenticate now using device code login? (Y/N): " -NoNewline -ForegroundColor Yellow
                                    $loginResponse = Read-Host
                                    
                                    if ($loginResponse -eq 'Y' -or $loginResponse -eq 'y') {
                                        Write-Log "Initiating Azure CLI device code login..." -Level Info
                                        az login --use-device-code
                                        
                                        if ($LASTEXITCODE -eq 0) {
                                            # Verify authentication was successful
                                            $accountInfo = az account show 2>$null | ConvertFrom-Json
                                            if ($accountInfo -and $accountInfo.id) {
                                                $azCliAuthenticated = $true
                                                Write-Log "Azure CLI authentication successful!" -Level Success
                                                Write-Log "Authenticated with subscription: $($accountInfo.name) ($($accountInfo.id))" -Level Info
                                            }
                                            else {
                                                Write-Log "Authentication verification failed. Please try 'az login' manually." -Level Warning
                                            }
                                        }
                                        else {
                                            Write-Log "Azure CLI login failed. Will use REST API method instead." -Level Warning
                                        }
                                    }
                                    else {
                                        Write-Log "Azure CLI authentication skipped. Will use REST API method instead." -Level Info
                                    }
                                }
                            }
                        }
                        catch {
                            Write-Log "Azure CLI not found. Will use REST API method (may have limitations)." -Level Warning
                        }
                        
                        # Method 1: Azure CLI (Recommended) - Run as background job
                        if ($azCliAvailable -and $azCliAuthenticated) {
                            Write-Log "Using Azure CLI to download marketplace image (recommended method)..." -Level Info
                            Write-Log "  Publisher: $($selectedImageObj.Publisher)" -Level Info
                            Write-Log "  Offer: $($selectedImageObj.Offer)" -Level Info
                            Write-Log "  SKU: $($selectedImageObj.SKU)" -Level Info
                            Write-Log "  OS Type: $($selectedImageObj.OSType)" -Level Info
                            
                            try {
                                # Build the az stack-hci-vm image create command
                                $azCommand = "az stack-hci-vm image create " +
                                    "--resource-group `"$ResourceGroup`" " +
                                    "--custom-location `"$CustomLocationId`" " +
                                    "--name `"$imageName`" " +
                                    "--os-type `"$($selectedImageObj.OSType)`" " +
                                    "--offer `"$($selectedImageObj.Offer)`" " +
                                    "--publisher `"$($selectedImageObj.Publisher)`" " +
                                    "--sku `"$($selectedImageObj.SKU)`" " +
                                    "--subscription `"$SubscriptionId`""
                                
                                Write-Log "Starting Azure CLI download as background job..." -Level Info
                                Write-Log "Initiating marketplace image download. This process may take approx. 10 to 30 minutes, depending on VM image size and your cluster download speed..." -Level Info
                                Write-Host ""
                                
                                # Start Azure CLI command as a background job
                                $job = Start-Job -ScriptBlock {
                                    param($command)
                                    $output = & cmd /c "$command 2>&1"
                                    return @{
                                        Output = $output
                                        ExitCode = $LASTEXITCODE
                                    }
                                } -ArgumentList $azCommand
                                
                                Write-Log "Azure CLI job started (Job ID: $($job.Id))" -Level Info
                                Write-Log "Monitoring image download progress for status changes using REST API..." -Level Info
                                Start-Sleep -Seconds 5  # Give Azure CLI time to initiate the request
                                
                                # Poll for completion using REST API while Azure CLI runs in background
                                $maxRetries = 120  # 20 minutes
                                $retryCount = 0
                                $imageReady = $false
                                
                                # Get access token for REST API calls
                                $azContext = Get-AzContext
                                $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
                                $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
                                $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
                                $accessToken = $token.AccessToken
                                
                                $headers = @{
                                    'Authorization' = "Bearer $accessToken"
                                    'Content-Type' = 'application/json'
                                }
                                
                                $apiVersion = "2024-01-01"
                                $imageResourceUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/marketplaceGalleryImages/$imageName`?api-version=$apiVersion"
                                
                                while (-not $imageReady -and $retryCount -lt $maxRetries) {
                                    Start-Sleep -Seconds 10
                                    $retryCount++
                                    
                                    try {
                                        $imageStatus = Invoke-RestMethod -Uri $imageResourceUri -Method Get -Headers $headers -ErrorAction SilentlyContinue
                                        $provisioningState = $imageStatus.properties.provisioningState
                                        
                                        # Display progress information if available
                                        if ($imageStatus.properties.status.provisioningStatus) {
                                            $detailedStatus = $imageStatus.properties.status.provisioningStatus.status
                                            $progressPercent = $imageStatus.properties.status.progressPercentage
                                            
                                            if ($progressPercent -ne $null) {
                                                $downloadSizeMB = $imageStatus.properties.status.downloadStatus.downloadSizeInMB
                                                
                                                # Try to calculate total size from progress percentage
                                                if ($downloadSizeMB -and $progressPercent -gt 0) {
                                                    $estimatedTotalMB = [math]::Round($downloadSizeMB / ($progressPercent / 100), 0)
                                                    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Download progress: $progressPercent% complete" -ForegroundColor Cyan
                                                    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Downloaded: $downloadSizeMB MB of ~$estimatedTotalMB MB" -ForegroundColor Cyan
                                                }
                                                elseif ($downloadSizeMB) {
                                                    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Download progress: $progressPercent% complete" -ForegroundColor Cyan
                                                    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Downloaded: $downloadSizeMB MB" -ForegroundColor Cyan
                                                }
                                                else {
                                                    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Download progress: $progressPercent% complete" -ForegroundColor Cyan
                                                }
                                            }
                                            
                                            if ($detailedStatus -eq "Succeeded") {
                                                $imageReady = $true
                                                Write-Log "Image download completed successfully" -Level Success
                                            }
                                            elseif ($detailedStatus -eq "Failed") {
                                                $errorInfo = $imageStatus.properties.status.errorCode
                                                Write-Log "Image download failed: $errorInfo" -Level Error
                                                break
                                            }
                                            else {
                                                if ($retryCount % 6 -eq 0) {  # Log status every minute
                                                    Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Status: $detailedStatus (elapsed: $($retryCount * 10)s)" -ForegroundColor Cyan
                                                }
                                            }
                                        }
                                        elseif ($provisioningState -eq "Succeeded") {
                                            $imageReady = $true
                                            Write-Log "Image provisioned successfully" -Level Success
                                        }
                                        elseif ($provisioningState -eq "Failed") {
                                            Write-Log "Image provisioning failed" -Level Error
                                            break
                                        }
                                        else {
                                            if ($retryCount % 6 -eq 0) {
                                                Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Provisioning state: $provisioningState (elapsed: $($retryCount * 10)s)" -ForegroundColor Cyan
                                            }
                                        }
                                        
                                        # Check if job completed (success or failure)
                                        if ($job.State -eq "Completed" -or $job.State -eq "Failed") {
                                            $jobResult = Receive-Job -Job $job
                                            if ($job.State -eq "Failed" -or $jobResult.ExitCode -ne 0) {
                                                Write-Log "Azure CLI job completed with errors" -Level Warning
                                                if ($jobResult.Output) {
                                                    Write-Log "Azure CLI output: $($jobResult.Output)" -Level Warning
                                                }
                                            }
                                            Remove-Job -Job $job -Force
                                        }
                                    }
                                    catch {
                                        # Image might not exist yet, continue waiting
                                        if ($retryCount % 6 -eq 0) {
                                            Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [Info] Waiting for image resource to be created... (elapsed: $($retryCount * 10)s)" -ForegroundColor Cyan
                                        }
                                    }
                                }
                                
                                # Clean up job if still running
                                if ($job.State -eq "Running") {
                                    Write-Log "Stopping Azure CLI background job..." -Level Info
                                    Stop-Job -Job $job
                                    Remove-Job -Job $job -Force
                                }
                                
                                if ($imageReady) {
                                    return [PSCustomObject]@{
                                        ImageExists = $true
                                        ImageName = $imageName
                                        Downloaded = $true
                                    }
                                }
                                else {
                                    Write-Log "Image download did not complete within 20 minutes" -Level Warning
                                    Write-Log "The download may still be in progress. Check Azure portal for status." -Level Info
                                    return [PSCustomObject]@{
                                        ImageExists = $false
                                        ImageName = $imageName
                                        Downloaded = $false
                                    }
                                }
                            }
                            catch {
                                Write-Log "Azure CLI method failed: $_" -Level Error
                                Write-Log "Falling back to REST API method..." -Level Warning
                                $azCliAuthenticated = $false  # Force fallback to REST API
                            }
                        }
                        
                        # Method 2: REST API (Fallback - has known limitations with marketplace images)
                        if (-not $azCliAvailable) {
                        try {
                            # For Azure Stack HCI, we need to create a marketplace gallery image resource
                            # NOTE: This REST API method has known limitations and may fail with SAS token errors
                            # Azure CLI method is strongly recommended when available
                            $location = (Get-AzResourceGroup -Name $ResourceGroup).Location
                            
                            Write-Log "Using REST API to download marketplace image..." -Level Warning
                            Write-Log "Note: REST API has known limitations. Consider installing Azure CLI for better reliability." -Level Warning
                            
                            # Get access token
                            $azContext = Get-AzContext
                            $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
                            $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
                            $token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)
                            $accessToken = $token.AccessToken
                            
                            $headers = @{
                                'Authorization' = "Bearer $accessToken"
                                'Content-Type' = 'application/json'
                            }
                            
                            # Create marketplace gallery image resource
                            # Note: containerId is NOT specified - it will be assigned automatically during download
                            $apiVersion = "2024-01-01"
                            $imageResourceUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/marketplaceGalleryImages/$imageName`?api-version=$apiVersion"
                            
                            # Build the image body for marketplace gallery images
                            $imageBody = @{
                                location = $location
                                extendedLocation = @{
                                    type = "CustomLocation"
                                    name = $CustomLocationId
                                }
                                properties = @{
                                    osType = $selectedImageObj.OSType
                                    identifier = @{
                                        publisher = $selectedImageObj.Publisher
                                        offer = $selectedImageObj.Offer
                                        sku = $selectedImageObj.SKU
                                    }
                                    version = @{
                                        name = 'latest'
                                    }
                                }
                            } | ConvertTo-Json -Depth 10
                            
                            Write-Log "Creating marketplace gallery image resource:" -Level Info
                            Write-Log "  Publisher: $($selectedImageObj.Publisher)" -Level Info
                            Write-Log "  Offer: $($selectedImageObj.Offer)" -Level Info
                            Write-Log "  SKU: $($selectedImageObj.SKU)" -Level Info
                            Write-Log "  Image name: $imageName" -Level Info
                            
                            $response = Invoke-RestMethod -Uri $imageResourceUri -Method Put -Headers $headers -Body $imageBody -ErrorAction Stop
                            
                            if ($response) {
                                Write-Log "Successfully initiated image download: $imageName" -Level Success
                                Write-Log "Monitoring image download progress..." -Level Info
                                
                                # Poll the image status to monitor download progress
                                $maxRetries = 180  # 30 minutes total (180 * 10 seconds)
                                $retryCount = 0
                                $imageReady = $false
                                
                                while (-not $imageReady -and $retryCount -lt $maxRetries) {
                                    Start-Sleep -Seconds 10
                                    $retryCount++
                                    
                                    try {
                                        $imageStatus = Invoke-RestMethod -Uri $imageResourceUri -Method Get -Headers $headers
                                        $provisioningState = $imageStatus.properties.provisioningState
                                        
                                        # Check detailed deployment status if available
                                        if ($imageStatus.properties.status.provisioningStatus) {
                                            $detailedStatus = $imageStatus.properties.status.provisioningStatus.status
                                            $progressPercent = $imageStatus.properties.status.progressPercentage
                                            
                                            if ($detailedStatus -eq "Succeeded") {
                                                $imageReady = $true
                                                $downloadSize = $imageStatus.properties.status.downloadStatus.downloadSizeInMB
                                                Write-Log "Image download completed successfully ($downloadSize MB)" -Level Success
                                            }
                                            elseif ($detailedStatus -eq "Failed") {
                                                # Query deployments to get detailed error information
                                                Write-Log "Image download failed. Checking deployment details..." -Level Warning
                                                
                                                $deploymentsUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deployments?api-version=2021-04-01"
                                                $deployments = Invoke-RestMethod -Uri $deploymentsUri -Method Get -Headers $headers -ErrorAction SilentlyContinue
                                                
                                                if ($deployments.value) {
                                                    $recentDeployment = $deployments.value | 
                                                        Where-Object { $_.properties.timestamp -gt (Get-Date).AddHours(-1) } |
                                                        Sort-Object -Property @{Expression={$_.properties.timestamp}} -Descending |
                                                        Select-Object -First 1
                                                    
                                                    if ($recentDeployment -and $recentDeployment.properties.error) {
                                                        $errorCode = $recentDeployment.properties.error.code
                                                        $errorMessage = $recentDeployment.properties.error.message
                                                        Write-Log "Deployment error: [$errorCode] $errorMessage" -Level Error
                                                    }
                                                }
                                                
                                                $errorInfo = $imageStatus.properties.status.errorCode
                                                Write-Log "Image download failed: $errorInfo" -Level Error
                                                return [PSCustomObject]@{
                                                    ImageExists = $false
                                                    ImageName = $imageName
                                                    Downloaded = $false
                                                    Error = $errorInfo
                                                }
                                            }
                                            else {
                                                if ($progressPercent) {
                                                    Write-Log "Image download in progress... $progressPercent% complete (elapsed: $($retryCount * 10)s)" -Level Info
                                                }
                                                else {
                                                    Write-Log "Image download in progress... Status: $detailedStatus (elapsed: $($retryCount * 10)s)" -Level Info
                                                }
                                            }
                                        }
                                        elseif ($provisioningState -eq "Succeeded") {
                                            $imageReady = $true
                                            Write-Log "Image provisioned successfully" -Level Success
                                        }
                                        elseif ($provisioningState -eq "Failed") {
                                            # Query deployments to get more details
                                            Write-Log "Image provisioning failed. Checking deployment status..." -Level Warning
                                            
                                            $deploymentsUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deployments?api-version=2021-04-01"
                                            $deployments = Invoke-RestMethod -Uri $deploymentsUri -Method Get -Headers $headers -ErrorAction SilentlyContinue
                                            
                                            if ($deployments.value) {
                                                $recentDeployment = $deployments.value | 
                                                    Where-Object { $_.properties.timestamp -gt (Get-Date).AddHours(-1) } |
                                                    Sort-Object -Property @{Expression={$_.properties.timestamp}} -Descending |
                                                    Select-Object -First 1
                                                
                                                if ($recentDeployment) {
                                                    $deploymentState = $recentDeployment.properties.provisioningState
                                                    Write-Log "Recent deployment state: $deploymentState" -Level Info
                                                    
                                                    if ($recentDeployment.properties.error) {
                                                        $errorCode = $recentDeployment.properties.error.code
                                                        $errorMessage = $recentDeployment.properties.error.message
                                                        Write-Log "Deployment error: [$errorCode] $errorMessage" -Level Error
                                                    }
                                                }
                                            }
                                            
                                            Write-Log "Image provisioning failed. Check Azure portal for details." -Level Error
                                            return [PSCustomObject]@{
                                                ImageExists = $false
                                                ImageName = $imageName
                                                Downloaded = $false
                                            }
                                        }
                                        else {
                                            Write-Log "Image provisioning in progress... Status: $provisioningState (elapsed: $($retryCount * 10)s)" -Level Info
                                        }
                                    }
                                    catch {
                                        Write-Log "Error checking image status: $_" -Level Warning
                                    }
                                }
                                
                                if (-not $imageReady) {
                                    # Final deployment check before timeout
                                    Write-Log "Download timeout reached. Checking deployment status..." -Level Warning
                                    try {
                                        $deploymentsUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Resources/deployments?api-version=2021-04-01"
                                        $deployments = Invoke-RestMethod -Uri $deploymentsUri -Method Get -Headers $headers -ErrorAction SilentlyContinue
                                        
                                        if ($deployments.value) {
                                            $recentDeployment = $deployments.value | 
                                                Where-Object { $_.properties.timestamp -gt (Get-Date).AddHours(-1) } |
                                                Sort-Object -Property @{Expression={$_.properties.timestamp}} -Descending |
                                                Select-Object -First 1
                                            
                                            if ($recentDeployment) {
                                                $deploymentState = $recentDeployment.properties.provisioningState
                                                Write-Log "Most recent deployment state: $deploymentState" -Level Info
                                                
                                                if ($recentDeployment.properties.error) {
                                                    $errorCode = $recentDeployment.properties.error.code
                                                    $errorMessage = $recentDeployment.properties.error.message
                                                    Write-Log "Deployment error: [$errorCode] $errorMessage" -Level Error
                                                }
                                            }
                                        }
                                    }
                                    catch {
                                        Write-Log "Could not retrieve deployment information: $_" -Level Warning
                                    }
                                    
                                    Write-Log "Image download did not complete within 30 minutes. Check Azure portal for current status." -Level Warning
                                    Write-Log "You can check status with: Get-AzStackHCIVMImage -Name '$imageName' -ResourceGroupName '$ResourceGroup'" -Level Info
                                    return [PSCustomObject]@{
                                        ImageExists = $false
                                        ImageName = $imageName
                                        Downloaded = $false
                                    }
                                }
                                
                                # Image download completed successfully
                                return [PSCustomObject]@{
                                    ImageExists = $true
                                    ImageName = $imageName
                                    Downloaded = $true
                                }
                            } else {
                                Write-Log "Image download may be in progress. Please check Azure portal for status." -Level Warning
                                return [PSCustomObject]@{
                                    ImageExists = $false
                                    ImageName = $imageName
                                    Downloaded = $false
                                }
                            }
                        }
                        catch {
                            # Check if error is because image is already being provisioned
                            if ($_.Exception.Message -like "*being provisioned*" -or $_.Exception.Message -like "*already exists*") {
                                Write-Log "Image '$imageName' is already being provisioned or exists." -Level Warning
                                Write-Log "Please wait for the download to complete and re-run the VM creation command." -Level Info
                                Write-Log "You can check status with: Get-AzStackHCIVMImage -Name '$imageName' -ResourceGroupName '$ResourceGroup'" -Level Info
                                return [PSCustomObject]@{
                                    ImageExists = $false
                                    ImageName = $imageName
                                    Downloaded = $true
                                }
                            } 
                            elseif ($_.Exception.Message -like "*GenerateTokenFromEdgeMarketplaceServiceFailed*" -or 
                                    $_.Exception.Message -like "*Failed to generate SAS token*") {
                                Write-Log "REST API marketplace download failed (SAS token error)." -Level Error
                                Write-Log "This is a known limitation of the REST API method." -Level Warning
                                Write-Log "Please install Azure CLI and retry, or download the image manually from Azure portal." -Level Info
                                Write-Log "Azure CLI installation: https://learn.microsoft.com/cli/azure/install-azure-cli" -Level Info
                                return [PSCustomObject]@{
                                    ImageExists = $false
                                    ImageName = $imageName
                                    Downloaded = $false
                                }
                            }
                            else {
                                Write-Log "Failed to download marketplace image: $_" -Level Error
                                return [PSCustomObject]@{
                                    ImageExists = $false
                                    ImageName = $ImageName
                                    Downloaded = $false
                                }
                            }
                        }
                        }  # End of REST API fallback block
                    } 
            }
            
            return [PSCustomObject]@{
                ImageExists = $false
                ImageName = $ImageName
                Downloaded = $false
            }
        }
    }
    catch {
        Write-Log "Error checking VM image: $_" -Level Error
        return [PSCustomObject]@{
            ImageExists = $false
            ImageName = $ImageName
            Downloaded = $false
        }
    }
}

<#
.SYNOPSIS
    Creates an Azure Local logical network.

.PARAMETER NetworkName
    The name of the logical network to create.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER CustomLocationId
    The custom location resource ID.

.PARAMETER VirtualSwitchName
    The name of the virtual switch on the Azure Stack HCI cluster.

.PARAMETER IpAllocationMethod
    The IP allocation method (Static or Dynamic). Default is Static.

.PARAMETER AddressPrefix
    The address prefix (CIDR notation) for the network. Required when IpAllocationMethod is Static.

.PARAMETER DnsServers
    Comma-separated list of DNS servers (optional).

.PARAMETER DefaultGateway
    The default gateway IP address (optional). Only applicable for Static IP allocation.

.PARAMETER VlanId
    The VLAN ID (optional).

.OUTPUTS
    Boolean indicating success or failure.

.EXAMPLE
    New-AzureLocalLogicalNetwork -NetworkName "static-network" -SubscriptionId "12345" -ResourceGroup "myRG" -CustomLocationId "/subscriptions/..." -VirtualSwitchName "ConvergedSwitch" -IpAllocationMethod Static -AddressPrefix "10.0.0.0/24" -DefaultGateway "10.0.0.1"

.EXAMPLE
    New-AzureLocalLogicalNetwork -NetworkName "dhcp-network" -SubscriptionId "12345" -ResourceGroup "myRG" -CustomLocationId "/subscriptions/..." -VirtualSwitchName "ConvergedSwitch" -IpAllocationMethod Dynamic
#>
function New-AzureLocalLogicalNetwork {
    [CmdletBinding(DefaultParameterSetName = 'Dynamic', SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$NetworkName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $true)]
        [string]$CustomLocationId,
        
        [Parameter(Mandatory = $true)]
        [string]$VirtualSwitchName,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'Static')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Dynamic')]
        [ValidateSet("Static", "Dynamic")]
        [string]$IpAllocationMethod,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'Static')]
        [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
        [string]$AddressPrefix,
        
        [Parameter(Mandatory = $false)]
        [string]$DnsServers = "",
        
        [Parameter(Mandatory = $false, ParameterSetName = 'Static')]
        [string]$DefaultGateway = "",
        
        [Parameter(Mandatory = $false)]
        [string]$VlanId = ""
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    # Check if logical network already exists
    if (Test-AzureLocalLogicalNetwork -NetworkName $NetworkName -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup) {
        Write-Log "Logical network '$NetworkName' already exists. Skipping creation." -Level Warning
        return $true
    }

    if ($PSCmdlet.ShouldProcess($NetworkName, "Create logical network")) {
        return Invoke-WithRetry -OperationName "Create Logical Network: $NetworkName" -ScriptBlock {
            Write-Log "Creating logical network: $NetworkName with IP allocation method: $IpAllocationMethod"

            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

            # Build the network parameters
            $networkParams = @{
                Name = $NetworkName
                ResourceGroupName = $ResourceGroup
                CustomLocationId = $CustomLocationId
                VmSwitchName = $VirtualSwitchName
                Location = (Get-AzResourceGroup -Name $ResourceGroup).Location
            }

            # Add IP allocation method
            if ($IpAllocationMethod -eq "Static") {
                $networkParams['IPAllocationMethod'] = 'Static'
                if ($AddressPrefix) {
                    $networkParams['AddressPrefix'] = $AddressPrefix
                }
                if ($DefaultGateway) {
                    $networkParams['DefaultGateway'] = $DefaultGateway
                }
            } else {
                $networkParams['IPAllocationMethod'] = 'Dynamic'
            }

            # Add optional parameters
            if ($DnsServers) {
                $dnsArray = $DnsServers -split ' '
                $networkParams['DnsServer'] = $dnsArray
            }

            if ($VlanId) {
                $networkParams['Vlan'] = [int]$VlanId
            }

            # Create the logical network
            $network = New-AzStackHCIVMLogicalNetwork @networkParams

            if (-not $network) {
                throw "Failed to create logical network: $NetworkName"
            }

            Write-Log "Successfully created logical network: $NetworkName" -Level Success
            return $true
        }
    }
    
    return $false
}

<#
.SYNOPSIS
    Creates an Azure Local virtual network interface (vNIC).

.PARAMETER NicName
    The name of the vNIC to create.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER CustomLocationId
    The custom location resource ID.

.PARAMETER LogicalNetworkName
    The name of the logical network to attach to.

.OUTPUTS
    Boolean indicating success or failure.
#>
function New-AzureLocalVNIC {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$NicName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $true)]
        [string]$CustomLocationId,
        
        [Parameter(Mandatory = $true)]
        [string]$LogicalNetworkName
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    if ($PSCmdlet.ShouldProcess($NicName, "Create vNIC")) {
        return Invoke-WithRetry -OperationName "Create vNIC: $NicName" -ScriptBlock {
            Write-Log "Creating vNIC: $NicName"

            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

            $nicParams = @{
                Name = $NicName
                ResourceGroupName = $ResourceGroup
                CustomLocationId = $CustomLocationId
                SubnetId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/logicalnetworks/$LogicalNetworkName"
                Location = (Get-AzResourceGroup -Name $ResourceGroup).Location
            }

            $nic = New-AzStackHCIVMNetworkInterface @nicParams

            if (-not $nic) {
                throw "Failed to create vNIC: $NicName"
            }

            Write-Log "Successfully created vNIC: $NicName" -Level Success
            return $true
        }
    }
    
    return $false
}

<#
.SYNOPSIS
    Creates an Azure Local virtual machine. Wrapper for New-AzStackHCIVMVirtualMachine, but includes 
    commands to create a new vNIC and download VM images Azure marketplace is required.
    https://learn.microsoft.com/en-us/powershell/module/az.stackhcivm/new-azstackhcivmvirtualmachine

.PARAMETER VMName
    The name of the VM to create.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER CustomLocationId
    The custom location resource ID.

.PARAMETER NicName
    The name of the vNIC to attach.

.PARAMETER VMSize
    The VM size/SKU.

.PARAMETER VMImage
    The VM image name.

.PARAMETER AdminUsername
    The administrator username.

.PARAMETER AdminPassword
    The administrator password as a SecureString. Either AdminPassword or KeyVaultSecretId must be provided.

.PARAMETER KeyVaultSecretId
    The full Azure Key Vault secret ID (e.g., https://myvault.vault.azure.net/secrets/vmadminpassword/version).
    Either AdminPassword or KeyVaultSecretId must be provided.

.PARAMETER ProvisionVMConfigAgent
    Whether to provision the VM Config Agent on the VM. Default is $true. Set to $false to skip agent provisioning.

.OUTPUTS
    Boolean indicating success or failure.

.EXAMPLE
    New-AzureLocalVM -VMName "myVM01" -SubscriptionId "12345" -ResourceGroup "myRG" -CustomLocationId "/subscriptions/..." -NicName "myVM01-nic" -VMSize "Standard_D2s_v3" -VMImage "Windows Server 2022" -AdminUsername "admin" -KeyVaultSecretId "https://myvault.vault.azure.net/secrets/vmpassword"
#>
function New-AzureLocalVM {
    [CmdletBinding(DefaultParameterSetName = 'Password', SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $true)]
        [string]$CustomLocationId,
        
        [Parameter(Mandatory = $true)]
        [string]$NicName,
        
        [Parameter(Mandatory = $true)]
        [string]$VMSize,
        
        [Parameter(Mandatory = $true)]
        [string]$VMImage,
        
        [Parameter(Mandatory = $true)]
        [string]$AdminUsername,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'Password')]
        [SecureString]$AdminPassword,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'KeyVault')]
        [ValidatePattern('^https://[a-zA-Z0-9-]+\.vault\.azure\.net/secrets/[a-zA-Z0-9-]+(/[a-zA-Z0-9-]+)?$')]
        [string]$KeyVaultSecretId,
        
        [Parameter(Mandatory = $false)]
        [bool]$ProvisionVMConfigAgent = $true
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    # Validate that the VM image exists, with prompt to download from marketplace
    $imageValidation = Test-AzureLocalVMImage -ImageName $VMImage -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -CustomLocationId $CustomLocationId -PromptForDownload $true
    
    if (-not $imageValidation.ImageExists) {
        if ($imageValidation.Downloaded) {
            throw "Image download initiated: $($imageValidation.ImageName). Please wait for download to complete and re-run the VM creation command."
        } else {
            throw "VM image '$VMImage' not found in resource group '$ResourceGroup'. Please verify the image name or download from marketplace."
        }
    }
    
    # Update VMImage name if user selected a different image from marketplace
    if ($imageValidation.ImageName -ne $VMImage) {
        Write-Log "Using selected image: $($imageValidation.ImageName)" -Level Info
        $VMImage = $imageValidation.ImageName
    }

    # Check if vNIC exists, create automatically if not found
    Write-Log "Checking if vNIC exists: $NicName"
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $existingNic = Get-AzStackHCIVMNetworkInterface -ResourceGroupName $ResourceGroup -Name $NicName -ErrorAction SilentlyContinue
    
    if (-not $existingNic) {
        Write-Log "vNIC '$NicName' not found, creating automatically..." -Level Warning
        
        # List available logical networks
        $logicalNetworks = Get-AzStackHCIVMLogicalNetwork -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
        
        if ($logicalNetworks -and $logicalNetworks.Count -gt 0) {
            # Use the first available logical network
            $selectedNetwork = $logicalNetworks[0]
            Write-Log "Creating vNIC '$NicName' on network '$($selectedNetwork.Name)'..." -Level Info
            
            try {
                $nicParams = @{
                    Name = $NicName
                    ResourceGroupName = $ResourceGroup
                    CustomLocationId = $CustomLocationId
                    SubnetId = $selectedNetwork.Id
                    Location = (Get-AzResourceGroup -Name $ResourceGroup).Location
                }
                
                $newNic = New-AzStackHCIVMNetworkInterface @nicParams
                
                if ($newNic) {
                    Write-Log "Successfully created vNIC: $NicName" -Level Success
                } else {
                    throw "Failed to create vNIC: $NicName"
                }
            }
            catch {
                Write-Log "Error creating vNIC: $_" -Level Error
                throw "Failed to create vNIC '$NicName'. Please create it manually and retry."
            }
        } else {
            Write-Log "No logical networks found in resource group: $ResourceGroup" -Level Error
            throw "Cannot create vNIC without a logical network. Please create a logical network first using New-AzureLocalLogicalNetwork."
        }
    } else {
        Write-Log "vNIC found: $NicName" -Level Success
        
        # Check if the NIC is already attached to another VM
        Write-Log "Checking if vNIC is already attached to another VM..." -Level Info
        $allVMs = Get-AzStackHCIVMVirtualMachine -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
        
        if ($allVMs) {
            foreach ($existingVM in $allVMs) {
                if ($existingVM.NetworkProfile.NetworkInterface) {
                    foreach ($attachedNic in $existingVM.NetworkProfile.NetworkInterface) {
                        # Extract NIC name from the resource ID
                        $attachedNicName = ($attachedNic.Id -split '/')[-1]
                        
                        if ($attachedNicName -eq $NicName) {
                            Write-Log "vNIC '$NicName' is already attached to VM '$($existingVM.Name)'" -Level Error
                            throw "vNIC '$NicName' is already attached to VM '$($existingVM.Name)'. Each vNIC can only be attached to one VM. Please use a different vNIC name or detach it from the existing VM first."
                        }
                    }
                }
            }
        }
        
        Write-Log "vNIC '$NicName' is not attached to any other VM" -Level Success
    }

    if ($PSCmdlet.ShouldProcess($VMName, "Create VM")) {
        # Capture parameter set and Key Vault ID before entering scriptblock
        $parameterSet = $PSCmdlet.ParameterSetName
        $keyVaultId = $KeyVaultSecretId
        $adminPwd = $AdminPassword
        
        return Invoke-WithRetry -OperationName "Create VM: $VMName" -ScriptBlock {
            Write-Log "Creating VM: $VMName"
            Write-Log "Using parameter set: $parameterSet" -Level Info

            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

            # Get the NIC resource ID
            $nicId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.AzureStackHCI/networkinterfaces/$NicName"

            # Get password from Key Vault if specified, otherwise use provided password
            $adminPlainPassword = $null
            if ($parameterSet -eq 'KeyVault') {
                Write-Log "Retrieving password from Key Vault: $keyVaultId" -Level Info
                try {
                    $vaultName = ($keyVaultId -split '/')[2].Split('.')[0]
                    $secretName = ($keyVaultId -split '/')[-1]
                    
                    $secret = Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName
                    if (-not $secret) {
                        throw "Failed to retrieve secret from Key Vault: $keyVaultId"
                    }
                    
                    # Get the SecureString value and convert directly to plain text
                    $kvSecureString = $secret.SecretValue
                    
                    if (-not $kvSecureString) {
                        throw "Secret value is empty from Key Vault: $keyVaultId"
                    }
                    
                    # Verify it's a SecureString
                    if ($kvSecureString -isnot [System.Security.SecureString]) {
                        throw "Retrieved value is not a SecureString: $($kvSecureString.GetType().FullName)"
                    }
                    
                    # Verify SecureString has content
                    if ($kvSecureString.Length -eq 0) {
                        throw "SecureString password is empty from Key Vault: $keyVaultId"
                    }
                    
                    # Convert SecureString to plain text for the cmdlet
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($kvSecureString)
                    try {
                        $adminPlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
                        Write-Log "Successfully retrieved password from Key Vault (Length: $($adminPlainPassword.Length))" -Level Success
                    }
                    finally {
                        # Clear BSTR from memory
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    }
                }
                catch {
                    Write-Log "Error retrieving Key Vault secret: $_" -Level Error
                    throw
                }
            }
            else {
                # Convert provided SecureString password to plain text
                $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($adminPwd)
                try {
                    $adminPlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
                }
                finally {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                }
            }

            # Determine OS type from the image object
            Write-Log "Retrieving OS type from image: $VMImage"
            try {
                $imageObject = Get-AzStackHCIVMImage -ResourceGroupName $ResourceGroup -Name $VMImage
                
                if ($imageObject -and $imageObject.OSType) {
                    $osType = $imageObject.OSType
                    Write-Log "Detected OS type from image: $osType" -Level Success
                } else {
                    # Fallback to heuristic if OSType not set
                    $osType = if ($($VMImage.ToLower()) -match "windows|win|azure|datacenter") { "Windows" } else { "Linux" }
                    Write-Log "Using heuristic OS type detection: $osType" -Level Warning
                }
            }
            catch {
                # Fallback to heuristic if image object not found
                Write-Log "Could not retrieve image object, using heuristic detection: $_" -Level Warning
                $osType = if ($($VMImage.ToLower()) -match "windows|win|azure|datacenter") { "Windows" } else { "Linux" }
            }
            
            # Verify password before VM creation
            if ([string]::IsNullOrWhiteSpace($adminPlainPassword)) {
                throw "AdminPassword is null or empty - cannot create VM"
            }
            
            Write-Log "Creating VM with password (Length: $($adminPlainPassword.Length))" -Level Info
            
            try {
                # Get location once
                $location = (Get-AzResourceGroup -Name $ResourceGroup).Location
                
                # Log parameters (excluding password value)
                Write-Log "VM Parameters: Name=$VMName, RG=$ResourceGroup, CustomLocationId=$CustomLocationId, Location=$location, OsType=$osType, Image=$VMImage, Size=$VMSize, User=$AdminUsername, Computer=$VMName, Password=<length:$($adminPlainPassword.Length)>, NicId=$nicId, ProvisionVMConfigAgent=$ProvisionVMConfigAgent" -Level Info

                # Call cmdlet directly with parameters (not using hashtable splatting)
                if ($ProvisionVMConfigAgent) {
                    $vm = New-AzStackHCIVMVirtualMachine `
                        -Name $VMName `
                        -ResourceGroupName $ResourceGroup `
                        -CustomLocationId $CustomLocationId `
                        -Location $location `
                        -OsType $osType `
                        -ImageName $VMImage `
                        -VmSize $VMSize `
                        -AdminUsername $AdminUsername `
                        -AdminPassword $adminPlainPassword `
                        -ComputerName $VMName `
                        -NicId $nicId `
                        -ProvisionVMConfigAgent
                } else {
                    $vm = New-AzStackHCIVMVirtualMachine `
                        -Name $VMName `
                        -ResourceGroupName $ResourceGroup `
                        -CustomLocationId $CustomLocationId `
                        -Location $location `
                        -OsType $osType `
                        -ImageName $VMImage `
                        -VmSize $VMSize `
                        -AdminUsername $AdminUsername `
                        -AdminPassword $adminPlainPassword `
                        -ComputerName $VMName `
                        -NicId $nicId
                }
            }
            finally {
                # Clear plain text password from memory
                $adminPlainPassword = $null
            }

            # Clear passwords from memory
            $adminSecurePassword = $null

            if (-not $vm) {
                throw "Failed to create VM: $VMName"
            }

            Write-Log "Successfully created VM: $VMName" -Level Success
            return $true
        }
    }
    
    return $false
}

<#
.SYNOPSIS
    Gets the Cluster Shared Volume with the most free space on an Azure Local cluster.

.PARAMETER TargetCluster
    The name of the target cluster.

.OUTPUTS
    PSCustomObject with properties: Name, FreeSpaceGB, TotalSizeGB, PercentFree, and LocalPath.

.EXAMPLE
    $csv = Get-CSVWithMostFreeSpace -TargetCluster "MyCluster"
    Write-Host "CSV: $($csv.Name), Free Space: $($csv.FreeSpaceGB) GB, Path: $($csv.LocalPath)"
#>
function Get-CSVWithMostFreeSpace {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetCluster
    )

    return Invoke-WithRetry -OperationName "Get CSV with Most Free Space" -ScriptBlock {
        Write-Log "Querying Cluster Shared Volumes on cluster: $TargetCluster"

        # Get cluster nodes
        $clusterNodes = Get-ClusterNode -Cluster $TargetCluster -ErrorAction Stop
        
        if ($clusterNodes.Count -eq 0) {
            throw "No cluster nodes found for cluster: $TargetCluster"
        }

        # Check if running on a cluster node
        $isClusterNode = Test-IsClusterNode -TargetCluster $TargetCluster
        
        if ($isClusterNode) {
            # Execute locally
            Write-Log "Executing locally on cluster node" -Level Info
            
            $csvVolumes = Get-ClusterSharedVolume
            
            if (-not $csvVolumes -or $csvVolumes.Count -eq 0) {
                throw "No Cluster Shared Volumes found on this cluster"
            }

            $csvInfo = @()
            foreach ($csv in $csvVolumes) {
                $volumeInfo = $csv.SharedVolumeInfo[0]
                $partition = $volumeInfo.Partition
                
                $freeSpaceBytes = $partition.FreeSpace
                $totalSizeBytes = $partition.Size
                $freeSpaceGB = [math]::Round($freeSpaceBytes / 1GB, 2)
                $totalSizeGB = [math]::Round($totalSizeBytes / 1GB, 2)
                $percentFree = [math]::Round(($freeSpaceBytes / $totalSizeBytes) * 100, 2)
                
                # Extract the local path (e.g., C:\ClusterStorage\Volume1)
                $localPath = $volumeInfo.FriendlyVolumeName
                
                $csvInfo += [PSCustomObject]@{
                    Name = $csv.Name
                    FreeSpaceGB = $freeSpaceGB
                    TotalSizeGB = $totalSizeGB
                    PercentFree = $percentFree
                    LocalPath = $localPath
                }
            }
            
            # Return the CSV with the most free space
            $result = $csvInfo | Sort-Object -Property FreeSpaceGB -Descending | Select-Object -First 1
        } else {
            # Execute remotely
            $targetNode = $clusterNodes[0].Name
            Write-Log "Using cluster node: $targetNode"

            # Create PS Session to the cluster node
            $session = New-PSSession -ComputerName $targetNode -ErrorAction Stop

            try {
                # Query CSV information remotely
                $scriptBlock = {
                    $csvVolumes = Get-ClusterSharedVolume
                    
                    if (-not $csvVolumes -or $csvVolumes.Count -eq 0) {
                        throw "No Cluster Shared Volumes found on this cluster"
                    }

                    $csvInfo = @()
                    foreach ($csv in $csvVolumes) {
                        $volumeInfo = $csv.SharedVolumeInfo[0]
                        $partition = $volumeInfo.Partition
                        
                        $freeSpaceBytes = $partition.FreeSpace
                        $totalSizeBytes = $partition.Size
                        $freeSpaceGB = [math]::Round($freeSpaceBytes / 1GB, 2)
                        $totalSizeGB = [math]::Round($totalSizeBytes / 1GB, 2)
                        $percentFree = [math]::Round(($freeSpaceBytes / $totalSizeBytes) * 100, 2)
                        
                        # Extract the local path (e.g., C:\ClusterStorage\Volume1)
                        $localPath = $volumeInfo.FriendlyVolumeName
                        
                        $csvInfo += [PSCustomObject]@{
                            Name = $csv.Name
                            FreeSpaceGB = $freeSpaceGB
                            TotalSizeGB = $totalSizeGB
                            PercentFree = $percentFree
                            LocalPath = $localPath
                        }
                    }
                    
                    # Return the CSV with the most free space
                    return $csvInfo | Sort-Object -Property FreeSpaceGB -Descending | Select-Object -First 1
                }

                $result = Invoke-Command -Session $session -ScriptBlock $scriptBlock
            }
            finally {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        }

        if ($result) {
            Write-Log "Found CSV with most free space: $($result.Name)" -Level Success
            Write-Log "  Free Space: $($result.FreeSpaceGB) GB / $($result.TotalSizeGB) GB ($($result.PercentFree)%)" -Level Info
            Write-Log "  Local Path: $($result.LocalPath)" -Level Info
            return $result
        } else {
            throw "Failed to retrieve CSV information"
        }
    }
}

<#
.SYNOPSIS
    Creates a Hyper-V VHD Set file on an Azure Local cluster.

.PARAMETER TargetCluster
    The name of the target cluster.

.PARAMETER ClusterSharedVolume
    The cluster shared volume path (e.g., "C$\ClusterStorage\Volume1\VHDs"). 
    If not specified, the CSV with the most free space will be automatically selected.

.PARAMETER VHDName
    The name of the VHD Set file.

.PARAMETER VHDSizeGB
    The size of the VHD in GB.

.PARAMETER VHDType
    The VHD type (Dynamic or Fixed). Default is Dynamic.

.PARAMETER BlockSizeBytes
    The block size in bytes. Default is 1MB.

.OUTPUTS
    String containing the VHD Set path, or $null on failure.
#>
function New-HyperVVHDSet {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetCluster,
        
        [Parameter(Mandatory = $false)]
        [string]$ClusterSharedVolume,
        
        [Parameter(Mandatory = $true)]
        [string]$VHDName,
        
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65536)]
        [int]$VHDSizeGB,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Dynamic", "Fixed")]
        [string]$VHDType = "Dynamic",
        
        [Parameter(Mandatory = $false)]
        [int]$BlockSizeBytes = 1MB
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    if ($PSCmdlet.ShouldProcess($VHDName, "Create VHD Set")) {
        return Invoke-WithRetry -OperationName "Create VHD Set: $VHDName" -ScriptBlock {
            Write-Log "Creating VHD Set: $VHDName on cluster $TargetCluster..."

            # If ClusterSharedVolume not specified, find the CSV with most free space
            if ([string]::IsNullOrWhiteSpace($ClusterSharedVolume)) {
                Write-Log "No CSV specified, finding CSV with most free space..."
                $csvInfo = Get-CSVWithMostFreeSpace -TargetCluster $TargetCluster
                
                if (-not $csvInfo) {
                    throw "Failed to find a suitable CSV on cluster: $TargetCluster"
                }
                
                # Use the local path from the CSV info (e.g., C:\ClusterStorage\Volume1)
                $ClusterSharedVolume = $csvInfo.LocalPath
                
                Write-Log "Selected CSV: $($csvInfo.Name) with $($csvInfo.FreeSpaceGB) GB free" -Level Success
                # Add "VHDs" folder to the path
                $ClusterSharedVolume = Join-Path -Path $ClusterSharedVolume -ChildPath "VHDs"
                Write-Log "Using path: $ClusterSharedVolume" -Level Info
                # Check if the directory exists, create if not
                if (-not (Test-Path $ClusterSharedVolume)) {
                    Write-Log "Creating VHDs directory: $ClusterSharedVolume" -Level Info
                    try {
                        New-Item -Path $ClusterSharedVolume -ItemType Directory -Force | Out-Null
                        Write-Log "Successfully created 'VHDs' directory: $ClusterSharedVolume" -Level Success
                    } catch {
                        Write-Log "Error creating VHDs directory: $_" -Level Error
                    }
                }
            } else {
                Write-Log "Using specified CSV path: $ClusterSharedVolume" -Level Info
            }

            # Convert GB to Bytes
            $VHDSizeBytes = $VHDSizeGB * 1GB
            
            # Construct the VHD Set path - use local path since we're executing in remote session
            $vhdSetPath = Join-Path -Path $ClusterSharedVolume -ChildPath $VHDName
            
            # Ensure the VHD name has the .vhds extension
            if (-not $vhdSetPath.EndsWith(".vhds")) {
                $vhdSetPath += ".vhds"
            }

            Write-Log "VHD Set Path: $vhdSetPath"

            # Create a session to a cluster node
            Write-Log "Connecting to cluster node..."
            $clusterNodes = Get-ClusterNode -Cluster $TargetCluster -ErrorAction Stop
            
            if ($clusterNodes.Count -eq 0) {
                throw "No cluster nodes found for cluster: $TargetCluster"
            }

            # Check if running on a cluster node
            $isClusterNode = Test-IsClusterNode -TargetCluster $TargetCluster
            
            if ($isClusterNode) {
                # Execute locally
                Write-Log "Executing locally on cluster node" -Level Info
                
                # Check if VHD Set already exists
                if (Test-Path $vhdSetPath) {
                    Write-Warning "VHD Set already exists: $vhdSetPath"
                    return $vhdSetPath
                }

                # Create the directory if it doesn't exist
                $directory = Split-Path -Path $vhdSetPath -Parent
                if (-not (Test-Path $directory)) {
                    New-Item -Path $directory -ItemType Directory -Force | Out-Null
                }

                # Create the VHD Set (the .vhds extension determines it's a VHD Set)
                if ($VHDType -eq "Fixed") {
                    try {
                        New-VHD -Path $vhdSetPath -SizeBytes $VHDSizeBytes -Fixed -BlockSizeBytes $BlockSizeBytes | Out-Null
                    } catch {
                        Write-Log "Error creating Fixed VHD Set: $_" -Level Error
                    }
                } else {
                    try {
                        New-VHD -Path $vhdSetPath -SizeBytes $VHDSizeBytes -Dynamic -BlockSizeBytes $BlockSizeBytes | Out-Null
                    } catch {
                        Write-Log "Error creating Dynamic VHD Set: $_" -Level Error
                    }
                }

                # Ensure VHD Set was created, then return path, throw error if not
                if (Test-Path $vhdSetPath) {
                    # Success
                    Write-Log "Successfully created VHD Set: $vhdSetPath" -Level Success
                    return $vhdSetPath
                } else {
                    # Failure
                    Write-Log "VHD Set creation failed: $vhdSetPath" -Level Error
                    throw "VHD Set was not created"
                }

            } else {
                # Execute remotely
                $targetNode = $clusterNodes[0].Name
                Write-Log "Using cluster node: $targetNode"

                # Create PS Session to the cluster node
                $session = New-PSSession -ComputerName $targetNode -ErrorAction Stop

                try {
                    # Create the VHD Set file remotely
                    $scriptBlock = {
                        param($Path, $SizeBytes, $Type, $BlockSize)
                        
                        # Check if VHD Set already exists
                        if (Test-Path $Path) {
                            Write-Warning "VHD Set already exists: $Path"
                            return $true
                        }

                        # Create the directory if it doesn't exist
                        $directory = Split-Path -Path $Path -Parent
                        if (-not (Test-Path $directory)) {
                            New-Item -Path $directory -ItemType Directory -Force | Out-Null
                        }

                        # Create the VHD Set (the .vhds extension determines it's a VHD Set)
                        if ($Type -eq "Fixed") {
                            New-VHD -Path $Path -SizeBytes $SizeBytes -Fixed -BlockSizeBytes $BlockSize | Out-Null
                        } else {
                            New-VHD -Path $Path -SizeBytes $SizeBytes -Dynamic -BlockSizeBytes $BlockSize | Out-Null
                        }

                        if (Test-Path $Path) {
                            return $true
                        } else {
                            throw "VHD Set was not created"
                        }
                    }

                    $result = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $vhdSetPath, $VHDSizeBytes, $VHDType, $BlockSizeBytes

                    if ($result) {
                        Write-Log "Successfully created VHD Set: $vhdSetPath" -Level Success
                        return $vhdSetPath
                    } else {
                        throw "Failed to create VHD Set: $vhdSetPath"
                    }
                }
                finally {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                }
            }
        }
    }
    
    return $null
}

<#
.SYNOPSIS
    Attaches a VHD Set to one or more Azure Local VMs.

.PARAMETER TargetCluster
    The name of the target cluster.

.PARAMETER VMNames
    Array of VM names to attach the VHD Set to.

.PARAMETER VHDSetPath
    The path to the VHD Set file.

.PARAMETER ControllerType
    The controller type (SCSI or IDE). Default is SCSI.

.PARAMETER ControllerNumber
    The controller number. Default is 0.

.PARAMETER ControllerLocation
    The controller location. Default is -1 (auto-select).

.OUTPUTS
    Boolean indicating success or failure.
#>
function Add-VHDSetToAzureLocalVM {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetCluster,
        
        [Parameter(Mandatory = $true)]
        [string[]]$VMNames,
        
        [Parameter(Mandatory = $true)]
        [string]$VHDSetPath,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("SCSI", "IDE")]
        [string]$ControllerType = "SCSI",
        
        [Parameter(Mandatory = $false)]
        [int]$ControllerNumber = 0,
        
        [Parameter(Mandatory = $false)]
        [int]$ControllerLocation = -1
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    if ($PSCmdlet.ShouldProcess(($VMNames -join ', '), "Attach VHD Set")) {
        Write-Log "Attaching VHD Set to Azure Local VMs..."
        Write-Log "VHD Set Path: $VHDSetPath"
        Write-Log "Target VMs: $($VMNames -join ', ')"

        # Get cluster nodes
        Write-Log "Connecting to cluster: $TargetCluster..."
        $clusterNodes = Get-ClusterNode -Cluster $TargetCluster -ErrorAction Stop
        
        if ($clusterNodes.Count -eq 0) {
            throw "No cluster nodes found for cluster: $TargetCluster"
        }

        # Check if running on a cluster node
        $isClusterNode = Test-IsClusterNode -TargetCluster $TargetCluster
        
        # Results hashtable to track success/failure per VM
        $results = @{}

        if ($isClusterNode) {
            # Execute locally
            Write-Log "Executing locally on cluster node" -Level Info
            
            # Loop through each VM and attach the VHD Set
            foreach ($vmName in $VMNames) {
                Write-Log "Attaching VHD Set to VM: $vmName..."

                try {
                    # Check if VHD Set exists
                    if (-not (Test-Path $VHDSetPath)) {
                        throw "VHD Set not found: $VHDSetPath"
                    }

                    # Try to get the VM - will throw if VM doesn't exist
                    $vm = Get-VM -Name $vmName -CimSession (Get-Cluster).Name -ErrorAction Stop

                    # Check if the VHD Set is already attached to this VM
                    $allAttachedDisks = Get-VMHardDiskDrive -VMName $vmName -CimSession (Get-Cluster).Name -ErrorAction SilentlyContinue
                    $alreadyAttached = $allAttachedDisks | Where-Object { $_.Path -eq $VHDSetPath }
                    
                    if ($alreadyAttached) {
                        Write-Log "VHD Set is already attached to VM: $vmName at $($alreadyAttached.ControllerType)-$($alreadyAttached.ControllerNumber)-$($alreadyAttached.ControllerLocation)" -Level Warning
                        $results[$vmName] = $true
                        continue
                    }

                    # Determine the controller location if not specified
                    $actualControllerLocation = $ControllerLocation
                    if ($actualControllerLocation -eq -1) {
                        $attachedDisks = Get-VMHardDiskDrive -VMName $vmName -ControllerType $ControllerType -ControllerNumber $ControllerNumber -CimSession (Get-Cluster).Name -ErrorAction SilentlyContinue
                        if ($attachedDisks) {
                            $usedLocations = $attachedDisks | Select-Object -ExpandProperty ControllerLocation
                            $actualControllerLocation = 0
                            while ($usedLocations -contains $actualControllerLocation) {
                                $actualControllerLocation++
                            }
                        } else {
                            $actualControllerLocation = 0
                        }
                    }

                    # Attach the VHD Set to the VM
                    # Use -ComputerName to target the VM's host node directly
                    $vmHost = $vm.ComputerName
                    Add-VMHardDiskDrive -VMName $vmName -ComputerName $vmHost -Path $VHDSetPath -ControllerType $ControllerType -ControllerNumber $ControllerNumber -ControllerLocation $actualControllerLocation -SupportPersistentReservations

                    Write-Log "Successfully attached VHD Set to VM: $vmName at $ControllerType-$ControllerNumber-$actualControllerLocation" -Level Success
                    $results[$vmName] = $true
                }
                catch {
                    Write-Log "Failed to attach VHD Set to VM: $vmName - $_" -Level Error
                    $results[$vmName] = $false
                }
            }
        } else {
            # Execute remotely
            $targetNode = $clusterNodes[0].Name
            Write-Log "Using cluster node: $targetNode"

            # Create PS Session to the cluster node
            try {
                Remove-Variable -Name sessionError -ErrorAction SilentlyContinue
                $session = New-PSSession -ComputerName $targetNode -ErrorAction Stop -ErrorVariable sessionError

            } catch {
                throw "Failed to create PS session to cluster node: $targetNode - $sessionError"
            }

            # Error checking logic, for session creation to cluster node
            if(-not $sessionError) {
                # Session created successfully
                Write-Log "Successfully created PS session to cluster node: $targetNode" -Level Success
            } else {
                # Session creation failed
                Write-Log "Failed to create PS session to cluster node: $targetNode  - $sessionError" -Level Error
                throw "Failed to create PS session to cluster node: $targetNode"
            }

            try {
                # Loop through each VM and attach the VHD Set
                foreach ($vmName in $VMNames) {
                    Write-Log "Attaching VHD Set to VM: $vmName..."

                    # Attach the VHD Set to the VM remotely
                    $scriptBlock = {
                        param($VMName, $VHDPath, $Controller, $ControllerNum, $ScsiControllerId)
                        
                        # Check if VM exists
                        $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
                        if (-not $vm) {
                            throw "VM not found: $VMName"
                        }

                        # Check if VHD Set exists
                        if (-not (Test-Path $VHDPath)) {
                            throw "VHD Set not found: $VHDPath"
                        }

                        # Determine the controller location if not specified
                        if ($ScsiControllerId -eq -1) {
                            $attachedDisks = Get-VMHardDiskDrive -VMName $VMName -ControllerType $Controller -ControllerNumber $ControllerNum -ErrorAction SilentlyContinue
                            if ($attachedDisks) {
                                $usedLocations = $attachedDisks | Select-Object -ExpandProperty ControllerLocation
                                $ScsiControllerId = 0
                                while ($usedLocations -contains $ScsiControllerId) {
                                    $ScsiControllerId++
                                }
                            } else {
                                $ScsiControllerId = 0
                            }
                        }

                        # Add the VHD Set to the VM using Hyper-V PowerShell cmdlet
                        # with "persistent reservations = true" option, to allow shared disk access
                        Add-VMHardDiskDrive -VMName $VMName `
                            -ControllerType $Controller `
                            -ControllerNumber $ControllerNum `
                            -ControllerLocation $ScsiControllerId `
                            -Path $VHDPath `
                            -SupportPersistentReservations
                        
                        # Start-Sleep -Seconds 2 # Optional: wait for a moment to ensure the disk is attached
                        Start-Sleep -Seconds 2

                        # Verify the disk was added
                        $newDisk = Get-VMHardDiskDrive -VMName $VMName | Where-Object { $_.Path -eq $VHDPath }
                        if (-not $newDisk) {
                            throw "Failed to attach VHD Set to VM: $VMName"
                        } else {
                            Write-Output "VHD Set attached successfully to VM: $VMName"
                        }
                        
                        return $true
                    }

                    try {
                        $result = Invoke-Command -Session $session -ScriptBlock $scriptBlock -ArgumentList $vmName, $VHDSetPath, $ControllerType, $ControllerNumber, $ControllerLocation
                        $results[$vmName] = $result

                        if ($result) {
                            Write-Log "Successfully attached VHD Set to VM: $vmName" -Level Success
                        } else {
                            Write-Log "Failed to attach VHD Set to VM: $vmName" -Level Error
                        }
                    }
                    catch {
                        Write-Log "Failed to attach VHD Set to VM: $vmName - $_" -Level Error
                        $results[$vmName] = $false
                    }
                }
            }
            finally {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
        }

        # Return overall success
        $allSuccess = ($results.Values -notcontains $false)
        
        if ($allSuccess) {
            Write-Log "Successfully attached VHD Set to all VMs" -Level Success
            return $true
        } else {
            Write-Log "Failed to attach VHD Set to one or more VMs" -Level Warning
            return $false
        }
    }
    
    return $false
}

<#
.SYNOPSIS
    Adds a data disk to an existing Azure Local VM using the Azure control plane.

.PARAMETER VMName
    The name of the VM to add the disk to.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER CustomLocationId
    The custom location ID for the Azure Local cluster.

.PARAMETER DiskName
    The name for the new data disk.

.PARAMETER DiskSizeGB
    The size of the disk in GB.

.PARAMETER StoragePathId
    Optional: The storage path resource ID. If not specified, will use the default storage path.

.PARAMETER Dynamic
    If specified, creates a dynamic disk. Otherwise creates a fixed disk.

.OUTPUTS
    Boolean indicating success or failure.

.EXAMPLE
    Add-AzureLocalVMDataDisk -VMName "TestVM-01" -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -DiskName "TestVM-01-datadisk01" -DiskSizeGB 100 -Dynamic

.EXAMPLE
    Add-AzureLocalVMDataDisk -VMName "TestVM-01" -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -DiskName "TestVM-01-datadisk02" -DiskSizeGB 500
#>
function Add-AzureLocalVMDataDisk {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $true)]
        [string]$CustomLocationId,
        
        [Parameter(Mandatory = $true)]
        [string]$DiskName,
        
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 32767)]
        [int]$DiskSizeGB,
        
        [Parameter(Mandatory = $false)]
        [string]$StoragePathId,
        
        [Parameter(Mandatory = $false)]
        [switch]$Dynamic
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    if ($PSCmdlet.ShouldProcess($DiskName, "Add data disk to VM $VMName")) {
        return Invoke-WithRetry -OperationName "Add Data Disk: $DiskName to VM: $VMName" -ScriptBlock {
            Write-Log "Adding data disk to Azure Local VM: $VMName"
            Write-Log "  Disk Name: $DiskName"
            Write-Log "  Disk Size: $DiskSizeGB GB"
            Write-Log "  Disk Type: $(if ($Dynamic) { 'Dynamic' } else { 'Fixed' })"

            # Set the Azure subscription context
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

            # Check if VM exists
            try {
                $vm = Get-AzStackHCIVMVirtualMachine -Name $VMName -ResourceGroupName $ResourceGroup -ErrorAction Stop
                Write-Log "Found VM: $VMName" -Level Info
            }
            catch {
                throw "VM not found: $VMName in resource group: $ResourceGroup"
            }

            # Check if disk already exists
            try {
                $existingDisk = Get-AzStackHCIVMVirtualHardDisk -Name $DiskName -ResourceGroupName $ResourceGroup -ErrorAction SilentlyContinue
                if ($existingDisk) {
                    Write-Log "Data disk '$DiskName' already exists. Checking if it's attached to the VM..." -Level Warning
                    
                    # Check if it's already attached to this VM
                    if ($vm.StorageProfile.DataDisk | Where-Object { $_.Name -eq $DiskName }) {
                        Write-Log "Disk is already attached to VM: $VMName" -Level Warning
                        return $true
                    }
                    
                    Write-Log "Disk exists but is not attached. Attaching to VM..." -Level Info
                }
            }
            catch {
                # Disk doesn't exist, we'll create it
                Write-Log "Disk does not exist, will create new disk" -Level Info
            }

            # If disk doesn't exist, create it
            if (-not $existingDisk) {
                Write-Log "Creating new virtual hard disk: $DiskName" -Level Info
                
                # If storage path not specified, try to get default storage path
                if ([string]::IsNullOrWhiteSpace($StoragePathId)) {
                    try {
                        $storagePaths = Get-AzStackHCIVMStoragePath -ResourceGroupName $ResourceGroup
                        if ($storagePaths -and $storagePaths.Count -gt 0) {
                            # Use the first available storage path or one with most free space
                            $StoragePathId = $storagePaths[0].Id
                            Write-Log "Using storage path: $($storagePaths[0].Name)" -Level Info
                        }
                        else {
                            throw "No storage paths found in resource group. Please specify StoragePathId parameter."
                        }
                    }
                    catch {
                        throw "Failed to find storage path: $_"
                    }
                }
                
                # Get location from resource group
                $rgLocation = (Get-AzResourceGroup -Name $ResourceGroup).Location
                
                # Create the virtual hard disk
                $diskParams = @{
                    Name = $DiskName
                    ResourceGroupName = $ResourceGroup
                    Location = $rgLocation
                    CustomLocationId = $CustomLocationId
                    StoragePathId = $StoragePathId
                    SizeGb = $DiskSizeGB
                }
                
                if ($Dynamic) {
                    $diskParams['Dynamic'] = $true
                }
                
                try {
                    $newDisk = New-AzStackHCIVMVirtualHardDisk @diskParams
                    Write-Log "Successfully created virtual hard disk: $DiskName" -Level Success
                }
                catch {
                    throw "Failed to create virtual hard disk: $_"
                }
            }
            else {
                $newDisk = $existingDisk
            }

            # Attach the disk to the VM
            Write-Log "Attaching disk to VM: $VMName" -Level Info
            
            try {
                # Get current data disks
                $currentDataDisks = $vm.StorageProfile.DataDisk
                if (-not $currentDataDisks) {
                    $currentDataDisks = @()
                }
                
                # Determine next available LUN
                if ($currentDataDisks.Count -gt 0) {
                    $maxLun = ($currentDataDisks | Measure-Object -Property Lun -Maximum).Maximum
                    $nextLun = $maxLun + 1
                }
                else {
                    $nextLun = 0
                }
                
                Write-Log "Assigning LUN: $nextLun" -Level Info
                
                # Add the new disk
                $vm = Add-AzStackHCIVMVirtualMachineDataDisk -Name $VMName -ResourceGroupName $ResourceGroup -DataDiskId $newDisk.Id
                
                Write-Log "Successfully attached disk to VM: $VMName at LUN $nextLun" -Level Success
                return $true
            }
            catch {
                Write-Log "Failed to attach disk to VM: $_" -Level Error
                throw
            }
        }
    }
    
    return $false
}

<#
.SYNOPSIS
    Removes a data disk from an existing Azure Local VM using the Azure control plane.

.PARAMETER VMName
    The name of the VM to remove the disk from.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER DiskName
    The name of the data disk to remove. You can specify either DiskName or DiskId.

.PARAMETER DiskId
    The resource ID of the data disk to remove. You can specify either DiskName or DiskId.

.PARAMETER DeleteDisk
    If specified, also deletes the disk resource after detaching it from the VM.

.OUTPUTS
    Boolean indicating success or failure.

.EXAMPLE
    Remove-AzureLocalVMDataDisk -VMName "TestVM-01" -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -DiskName "TestVM-01-datadisk01"

.EXAMPLE
    Remove-AzureLocalVMDataDisk -VMName "TestVM-01" -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -DiskName "TestVM-01-datadisk01" -DeleteDisk
#>
function Remove-AzureLocalVMDataDisk {
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByName')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string]$DiskName,
        
        [Parameter(Mandatory = $true, ParameterSetName = 'ById')]
        [string]$DiskId,
        
        [Parameter(Mandatory = $false)]
        [switch]$DeleteDisk
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    # Capture parameter set name and values before entering scriptblock
    $parameterSet = $PSCmdlet.ParameterSetName
    $diskIdentifier = if ($parameterSet -eq 'ByName') { $DiskName } else { $DiskId }
    
    if ($PSCmdlet.ShouldProcess($diskIdentifier, "Remove data disk from VM $VMName")) {
        return Invoke-WithRetry -OperationName "Remove Data Disk: $diskIdentifier from VM: $VMName" -ScriptBlock {
            Write-Log "Removing data disk from Azure Local VM: $VMName"
            Write-Log "  Disk: $diskIdentifier"

            # Set the Azure subscription context
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

            # Check if VM exists
            try {
                $vm = Get-AzStackHCIVMVirtualMachine -Name $VMName -ResourceGroupName $ResourceGroup
                Write-Log "Found VM: $VMName" -Level Info
            }
            catch {
                throw "VM not found: $VMName. Error: $_"
            }

            # Detach the disk from the VM
            Write-Log "Detaching disk from VM: $VMName" -Level Info
            
            try {
                if ($parameterSet -eq 'ByName') {
                    # When using disk name, also specify the resource group where the disk is located
                    Write-Log "Using parameter set: ByName with disk name: $DiskName" -Level Info
                    Remove-AzStackHCIVMVirtualMachineDataDisk -Name $VMName -ResourceGroupName $ResourceGroup -DataDiskName @($DiskName) -DataDiskResourceGroup $ResourceGroup | Out-Null
                }
                else {
                    # When using disk ID, we can pass the full resource ID
                    Write-Log "Using parameter set: ById with disk ID: $DiskId" -Level Info
                    Remove-AzStackHCIVMVirtualMachineDataDisk -Name $VMName -ResourceGroupName $ResourceGroup -DataDiskId @($DiskId) | Out-Null
                }
                
                Write-Log "Successfully detached disk from VM: $VMName" -Level Success
            }
            catch {
                Write-Log "Error details: $($_.Exception.Message)" -Level Error
                Write-Log "Parameter set name: $parameterSet" -Level Error
                throw "Failed to detach disk from VM: $_"
            }

            # Delete the disk if requested
            if ($DeleteDisk) {
                Write-Log "Deleting disk: $diskIdentifier" -Level Info
                
                try {
                    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
                        Remove-AzStackHCIVMVirtualHardDisk -Name $DiskName -ResourceGroupName $ResourceGroup
                    }
                    else {
                        # Extract disk name from ID if we have the ID
                        $diskNameFromId = $DiskId.Split('/')[-1]
                        Remove-AzStackHCIVMVirtualHardDisk -Name $diskNameFromId -ResourceGroupName $ResourceGroup
                    }
                    
                    Write-Log "Successfully deleted disk: $diskIdentifier" -Level Success
                }
                catch {
                    Write-Log "Failed to delete disk: $_" -Level Warning
                    Write-Log "Disk was detached but deletion failed. You may need to delete it manually." -Level Warning
                }
            }

            return $true
        }
    }
    
    return $false
}

<#
.SYNOPSIS
    Removes an Azure Local VM using the Azure control plane.

.PARAMETER VMName
    The name of the VM to remove.

.PARAMETER SubscriptionId
    The Azure subscription ID.

.PARAMETER ResourceGroup
    The resource group name.

.PARAMETER Force
    If specified, skips the confirmation prompt.

.OUTPUTS
    Boolean indicating success or failure.

.EXAMPLE
    Remove-AzureLocalVM -VMName "TestVM-01" -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup

.EXAMPLE
    Remove-AzureLocalVM -VMName "TestVM-01" -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -Force
#>
function Remove-AzureLocalVM {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VMName,
        
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroup,
        
        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Check prerequisites
    if (-not (Test-Prerequisites)) {
        throw "Prerequisites check failed. Please resolve the issues and try again."
    }

    if ($PSCmdlet.ShouldProcess($VMName, "Remove Azure Local VM")) {
        return Invoke-WithRetry -OperationName "Remove VM: $VMName" -ScriptBlock {
            Write-Log "Removing Azure Local VM: $VMName" -Level Info

            # Set the Azure subscription context
            Set-AzContext -SubscriptionId $SubscriptionId | Out-Null

            # Check if VM exists
            try {
                $vm = Get-AzStackHCIVMVirtualMachine -Name $VMName -ResourceGroupName $ResourceGroup
                Write-Log "Found VM: $VMName" -Level Info
                Write-Log "  Status: $($vm.StatusPowerState)" -Level Info
                Write-Log "  VM Size: $($vm.HardwareProfileVMSize)" -Level Info
            }
            catch {
                throw "VM not found: $VMName. Error: $_"
            }

            # Remove the VM
            Write-Log "Deleting VM: $VMName" -Level Info
            
            try {
                if ($Force) {
                    Remove-AzStackHCIVMVirtualMachine -Name $VMName -ResourceGroupName $ResourceGroup -Force
                }
                else {
                    Remove-AzStackHCIVMVirtualMachine -Name $VMName -ResourceGroupName $ResourceGroup
                }
                
                Write-Log "Successfully deleted VM: $VMName" -Level Success
                return $true
            }
            catch {
                throw "Failed to delete VM: $_"
            }
        }
    }
    
    return $false
}

#endregion

#region Module Exports

# Export helper functions
Export-ModuleMember -Function Write-Log
Export-ModuleMember -Function Invoke-WithRetry
Export-ModuleMember -Function Test-Prerequisites

# Export Azure Local functions
Export-ModuleMember -Function Get-CustomLocationIdForCluster
Export-ModuleMember -Function Test-AzureLocalLogicalNetwork
Export-ModuleMember -Function Test-AzureLocalVMImage
Export-ModuleMember -Function New-AzureLocalLogicalNetwork
Export-ModuleMember -Function New-AzureLocalVNIC
Export-ModuleMember -Function New-AzureLocalVM
Export-ModuleMember -Function Get-CSVWithMostFreeSpace
Export-ModuleMember -Function New-HyperVVHDSet
Export-ModuleMember -Function Add-VHDSetToAzureLocalVM
Export-ModuleMember -Function Add-AzureLocalVMDataDisk
Export-ModuleMember -Function Remove-AzureLocalVMDataDisk
Export-ModuleMember -Function Remove-AzureLocalVM

#endregion
