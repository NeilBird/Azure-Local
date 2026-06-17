##########################################################################################################
<#
.SYNOPSIS
    Author:     Neil Bird, MSFT
    Version:    1.0.2
    Created:    May 15th 2025
    Updated:    June 17th 2026

.DESCRIPTION

    AzLocal.DeploymentAutomation module for deploying Azure Local using ARM templates and parameter files using PowerShell.

    This script is used to deploy Azure Local using an ARM template deployment. It requires the following parameters:
    - SubscriptionId: The ID of the Azure subscription to use for the deployment.
    - TenantId: The ID of the Azure tenant to use for the deployment.
    - TypeOfDeployment: The type of deployment to perform (e.g., SingleNode, StorageSwitched, StorageSwitchless, RackAware, Disaggregated).
    
    Credentials can be supplied via three methods (in priority order):
    1. Azure Key Vault: -CredentialKeyVaultName with optional -LocalAdminSecretName / -LCMAdminSecretName
    2. PSCredential parameters: -LocalAdminCredential and -LCMAdminCredential
    3. Interactive prompts: Read-Host with -AsSecureString (default fallback)

    Non-interactive deployment is supported via -UniqueID and -NetworkSettingsJson parameters.
    The function supports -WhatIf and -Confirm via SupportsShouldProcess.
    
    The script builds the following parameters:
    - UniqueID: The unique identifier for the deployment (e.g., store number, site code).
    - ClusterName: The name of the cluster to be created.
    - ResourceGroupName: The name of the resource group to be created.
    - Location: The location for the deployment (e.g., EastUS or WestEurope).
    - AzureStackLCMAdminUsername: The username for the Azure Stack LCM admin account.
    - KeyVaultName: The name of the Key Vault to be created.
    - CustomLocation: The name of the custom location to be created.
    - ResourceBridgeName: The name of the resource bridge to be created.
    - DiagnosticStorageAccountName: The name of the storage account for diagnostics.
    - StorageAccountType: The type of storage account to be created (e.g., Standard_LRS).
    - SubnetMask: The subnet mask for the deployment (e.g., 255.255.255.0).
    - NetworkSettings: The network settings for the deployment (e.g., subnet mask, default gateway, starting IP address, ending IP address, cluster IP address).
    - ParameterFilePath: The path to the parameter file for the deployment.
    - ParameterFileSettings: The settings for the parameter file.
    - Parameters: The parameters for the deployment.
    - DeploymentParameterFile: The path to the deployment-specific parameter file.
    - TemplateFilePath: The path to the template file for the deployment.

    Resource naming standards are loaded from .config/naming-standards-config.json and use the UniqueID
    placeholder to build environment-specific resource names. Edit the config file to customise
    naming conventions for your organisation.

    # External references:
        # https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster
        # https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template

.EXAMPLE

    This module contains the following exported functions:

        1. Start-AzLocalTemplateDeployment
        2. Watch-AzLocalDeployment
        3. Start-AzLocalCsvDeployment
        4. Get-AzLocalDeploymentStatus

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

#Requires -Modules Az.Accounts, Az.Resources

Set-StrictMode -Version Latest

# Module root directory - used by all functions for path resolution
$script:ModuleRoot = $PSScriptRoot

# Module-scoped log file path - set by exported functions via -LogFilePath parameter
$script:AzLocalLogFilePath = $null

# When set to $true, Write-AzLocalLog skips Write-Host console output.
# Used during Pester testing to prevent VS Code terminal from becoming unresponsive.
$script:SuppressConsoleOutput = $false

# Dot-source all function files listed in the manifest's NestedModules.
# When loaded via the .psd1, these are already loaded by NestedModules (harmless re-define).
# When loaded via the .psm1 directly (e.g., Pester tests bypassing RequiredModules),
# this ensures all functions are available in the module scope.
$manifestPath = Join-Path $PSScriptRoot 'AzLocal.DeploymentAutomation.psd1'
if (Test-Path $manifestPath) {
    $manifestData = Import-PowerShellDataFile -Path $manifestPath -ErrorAction SilentlyContinue
    if ($manifestData -and $manifestData.NestedModules) {
        foreach ($nestedModule in $manifestData.NestedModules) {
            $nestedPath = Join-Path $PSScriptRoot $nestedModule
            if (Test-Path $nestedPath) {
                . $nestedPath
            }
        }
    }
}