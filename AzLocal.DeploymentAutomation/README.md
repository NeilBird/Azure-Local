# AzLocal.DeploymentAutomation

### Latest Version: **1.0.3**

```powershell
# Install the module (initial setup)
Install-Module -Name AzLocal.DeploymentAutomation -Scope CurrentUser

# Update the module (already installed)
Update-Module -Name AzLocal.DeploymentAutomation
```

PowerShell module for deploying Azure Local (formerly Azure Stack HCI) clusters using ARM templates and parameter files. Supports SingleNode, StorageSwitched (2-16 nodes with storage network switch), StorageSwitchless (2-4 nodes), Rack-Aware Cluster (2, 4, 6 and 8), and **Disaggregated / SAN (1-64 nodes, SAN-backed storage)** deployment topologies with configurable resource naming standards and automated two-phase deployment process. This requires the physical nodes to have a running OS installed, with hardware component drivers installed, and Azure Arc Agent registered and resources present in an Azure subscription.

> **Disclaimer:** This module is **NOT** a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT license](../LICENSE) for further information.

## Overview

Azure Local cluster deployments via ARM templates require a **two-phase process**: first a **Validate** deployment to verify configuration, then a **Deploy** deployment to provision the cluster, this module provides a **ValidateAndDeploy** option that automates both steps. This is implemented by the module monitoring the Validate deployment (step 1), and immediately stating the Deploy (step 2) once the Validate deployment completes successfully. This module provides four exported functions:

| Function | Purpose |
|----------|---------|
| **`Start-AzLocalTemplateDeployment`** | Orchestrates the end-to-end deployment workflow for a **single cluster** (parameter collection, naming resolution, ARM template submission). Supports interactive and non-interactive usage. |
| **`Watch-AzLocalDeployment`** | Monitors a running ARM deployment by polling for status changes. Useful for tracking long-running validate/deploy operations from the same or a separate PowerShell session. |
| **`Start-AzLocalCsvDeployment`** | **Batch/CI/CD function.** Reads a CSV file of cluster definitions, runs pre-flight checks, and submits ARM deployments for all eligible clusters. Generates JUnit XML reports. |
| **`Get-AzLocalDeploymentStatus`** | **Batch/CI/CD function.** Checks the current ARM deployment status for all clusters in a CSV file. Generates JUnit XML, HTML, and Markdown reports for dashboards and stakeholder visibility. |

> **Reference:** [Deploy Azure Local using ARM templates](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)

---

## Prerequisites

- **PowerShell** 5.1 or later
- **Az PowerShell modules:**
  - `Az.Accounts` (v2.0.0+)
  - `Az.Resources` (v6.0.0+)
  - `Az.KeyVault` (v4.0.0+) — *optional*, only required when using `-CredentialKeyVaultName` to retrieve credentials from Azure Key Vault
- Azure subscription with [required permissions and resource providers registered](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions). The module **automatically checks and registers** the 12 required resource providers at deployment time, and provides advisory warnings for any missing RBAC role assignments. See [Azure Prerequisites](#azure-prerequisites) below.
- Arc-enabled servers (Azure Local physical node(s)) already registered in the target subscription and resource group
- Active Directory OU structure prepared for the deployment, more information and 'AD preparation module' is documented here: https://learn.microsoft.com/azure/azure-local/deploy/deployment-prep-active-directory

Install the required Az modules if not already present:

```powershell
Install-Module -Name Az.Accounts -MinimumVersion 2.0.0 -Scope CurrentUser
Install-Module -Name Az.Resources -MinimumVersion 6.0.0 -Scope CurrentUser
Install-Module -Name Az.KeyVault -MinimumVersion 4.0.0 -Scope CurrentUser
```

### Azure Prerequisites

Before deploying, your Azure subscription must have the required resource providers registered and the deploying identity must have appropriate RBAC role assignments. Full details are documented in the official Microsoft guide: [Assign required permissions for Azure Local deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions).

**This module automatically checks and handles these prerequisites at deployment time:**

**Resource Providers (12 required)** — The module checks the registration state of all required providers and **automatically registers** any that are missing. Registration may take a few minutes to propagate. If auto-registration fails (e.g., insufficient subscription permissions), the deployment is blocked with a clear error message.

| Resource Provider | Purpose |
|-------------------|---------|
| `Microsoft.HybridCompute` | Arc-enabled server management |
| `Microsoft.GuestConfiguration` | Guest configuration policies |
| `Microsoft.HybridConnectivity` | Hybrid connectivity endpoints |
| `Microsoft.AzureStackHCI` | Azure Stack HCI / Azure Local cluster resources |
| `Microsoft.Kubernetes` | Kubernetes cluster management |
| `Microsoft.KubernetesConfiguration` | Kubernetes configuration extensions |
| `Microsoft.ExtendedLocation` | Custom locations for hybrid resources |
| `Microsoft.ResourceConnector` | Resource bridge for hybrid hosting |
| `Microsoft.HybridContainerService` | Hybrid container services |
| `Microsoft.Attestation` | Hardware attestation services |
| `Microsoft.Storage` | Storage account resources |
| `Microsoft.Insights` | Monitoring, diagnostics, and Key Vault audit logging |

**RBAC Role Assignments** — The module checks the deploying identity's role assignments and reports any missing roles as **advisory warnings**. Missing RBAC roles do not block deployment, but the ARM deployment itself will fail if permissions are insufficient.

| Scope | Required Role |
|-------|---------------|
| Subscription | `Azure Stack HCI Administrator` |
| Subscription | `Reader` |
| Resource Group | `Key Vault Data Access Administrator` |
| Resource Group | `Key Vault Secrets Officer` |
| Resource Group | `Key Vault Contributor` |
| Resource Group | `Storage Account Contributor` |

> **Note:** If the deploying identity has the `Owner` role at subscription scope, all RBAC requirements are automatically satisfied. The RBAC check handles both user accounts and service principal identities (CI/CD pipelines).

---

## Module Structure

```
AzLocal.DeploymentAutomation/
├── AzLocal.DeploymentAutomation.psm1          # Root module (shared state and strict mode)
├── AzLocal.DeploymentAutomation.psd1          # Module manifest (NestedModules allowlist)
├── Public/                                    # Exported functions
│   ├── Start-AzLocalTemplateDeployment.ps1    # Deploy a single Azure Local cluster
│   ├── Start-AzLocalCsvDeployment.ps1         # CSV-driven batch deployment
│   ├── Watch-AzLocalDeployment.ps1            # Poll deployment status until completion
│   └── Get-AzLocalDeploymentStatus.ps1        # Query deployment status across clusters
├── Private/                                   # Internal helper functions
│   ├── Write-AzLocalLog.ps1                   # Logging helper
│   ├── Initialize-AzLocalLogFile.ps1          # Log file initialisation
│   ├── Get-ValidUniqueID.ps1                  # Unique ID generation
│   ├── Get-AzLocalDeploymentNetworkSettings.ps1
│   ├── Get-AzLocalNetworkSettingsFromJson.ps1
│   ├── Get-AzLocalParameterFilePath.ps1
│   ├── Get-AzLocalParameterFileSettings.ps1
│   ├── New-AzLocalDeploymentParameterFile.ps1
│   ├── Test-AzLocalResourceNames.ps1
│   ├── Get-AzLocalNamingConfig.ps1
│   ├── Initialize-AzLocalUserConfig.ps1
│   ├── Resolve-AzLocalResourceName.ps1
│   ├── Format-Json.ps1                        # JSON pretty-printer (PS 5.1 compatible)
│   ├── New-AzLocalDeploymentReport.ps1         # Deployment status report generation (HTML/Markdown)
│   ├── New-AzLocalJUnitXml.ps1                # JUnit XML report generation
│   ├── Import-AzLocalDeploymentCsv.ps1        # CSV import and validation
│   ├── Test-AzLocalClusterPreFlight.ps1       # Pre-flight validation checks
│   ├── Test-AzLocalNamingConfigDefaults.ps1   # Config default-value validation
│   ├── Test-AzLocalAzurePrerequisites.ps1     # Azure RP registration + RBAC checks
│   └── Get-AzLocalValidationTroubleshootingHints.ps1  # Deployment failure analysis + remediation hints
├── .config/
│   └── naming-standards-config.json           # Naming standards and default values
├── templates/
│   └── azure-local-deployment-template.json      # ARM deployment template
├── template-parameter-files/                  # Base parameter templates (do not edit directly)
│   ├── single-node-parameters-file.json
│   ├── storage-switchless-2node-parameters-file.json
│   ├── storage-switchless-3node-parameters-file.json
│   ├── storage-switchless-4node-parameters-file.json
│   ├── storage-switched-parameters-file.json
│   └── rack-aware-parameters-file.json
├── cluster-specific-parameter-files/          # Example cluster-specific files
├── deployment-parameter-files/                # Generated per-deployment parameter files (auto-created)
├── automation-pipelines/                      # CI/CD pipeline examples (GitHub Actions & Azure DevOps)
│   ├── cluster-deployments.csv                # Example CSV for batch deployments
│   ├── github-actions/                        # GitHub Actions workflow YAML files
│   └── azure-devops/                          # Azure DevOps pipeline YAML files
└── Tests/                                     # Pester unit tests
    ├── AzLocal.DeploymentAutomation.Tests.ps1 # Test definitions
    ├── Invoke-Tests.ps1                       # Test runner with HTML report
    └── TestResults/                           # Generated test output (git-ignored)
```

---

## Installation

### Install from PowerShell Gallery (Recommended)

The module is published on the [PowerShell Gallery](https://www.powershellgallery.com/packages/AzLocal.DeploymentAutomation/):

```powershell
# Install the module with -Scope CurrentUser, could use -Scope 'AllUsers' if running with admin rights
Install-Module -Name AzLocal.DeploymentAutomation -Scope CurrentUser

# Install required Az modules (if not already present)
Install-Module -Name Az.Accounts -MinimumVersion 2.0.0 -Scope CurrentUser
Install-Module -Name Az.Resources -MinimumVersion 6.0.0 -Scope CurrentUser

# Optional: only needed if using -CredentialKeyVaultName for Key Vault credential retrieval
Install-Module -Name Az.KeyVault -MinimumVersion 4.0.0 -Scope CurrentUser
```

To update to the latest version:

```powershell
Update-Module -Name AzLocal.DeploymentAutomation
```

### Install from Source (Alternative)

Clone the repository and import the module directly:

```powershell
git clone https://github.com/NeilBird/Azure-Local.git
Import-Module .\Azure-Local\AzLocal.DeploymentAutomation\AzLocal.DeploymentAutomation.psd1
```

---

## Getting Started — Standalone (Single Cluster)

Use `Start-AzLocalTemplateDeployment` to deploy a single Azure Local cluster interactively or via parameters.

### Step 1: Customise the Configuration

Before running a deployment, you need a customised `naming-standards-config.json` with your environment settings.

**First-run automatic setup:** If you run any deployment function without a config file in your user profile, the module automatically copies the default configuration to `$env:USERPROFILE\.AzLocalDeploymentAutomation\naming-standards-config.json` and prompts you to edit it. This ensures your customisations survive module updates via `Update-Module`.

**Manual setup (optional):** You can trigger the config initialisation explicitly:

```powershell
# Import the module
Import-Module AzLocal.DeploymentAutomation

# Run any deployment function — the module will auto-initialise the user config
# and display the path. Then edit the file:
$configPath = Join-Path $env:USERPROFILE '.AzLocalDeploymentAutomation\naming-standards-config.json'
notepad $configPath
```

**Per-invocation override:** Use `-NamingConfigPath` to point to a specific config file (useful for multi-site deployments with different naming standards):

```powershell
Start-AzLocalTemplateDeployment -NamingConfigPath 'C:\MyConfigs\site-1-config.json' ...
```

**Configuration resolution order:**

| Priority | Source | Description |
|----------|--------|-------------|
| 1 | `-NamingConfigPath` parameter | Explicit path passed to the function |
| 2 | User profile directory | `$env:USERPROFILE\.AzLocalDeploymentAutomation\naming-standards-config.json` |
| 3 | Auto-initialise | Copies module default to user profile directory on first use |

Update these sections:

1. **`environment.tenantId`** — Set to your Entra ID (Azure AD) tenant ID. Find it with `(Get-AzContext).Tenant.Id`
2. **`environment.hciResourceProviderObjectID`** — *(Optional)* Set to the Object ID of the HCI Resource Provider in your tenant. If left empty, the module will look it up at runtime via `Get-AzADServicePrincipal`. Find it with:
   ```powershell
   (Get-AzADServicePrincipal -DisplayName "Microsoft.AzureStackHCI Resource Provider").Id
   ```
3. **`defaults`** — Review and update domain FQDN, DNS servers, network adapter names, location, and other defaults
4. **`namingStandards`** — Adjust naming patterns if your organisation requires different conventions

See [Configuration](#configuration) for full details on placeholders, naming patterns, and Azure naming limits.

### Step 2: Authenticate to Azure

```powershell
Connect-AzAccount -SubscriptionId "<your-subscription-id>" -TenantId "<your-tenant-id>"
```

### Step 3: Run a Deployment

```powershell
# Interactive — prompts for Unique ID, network settings, and credentials
Start-AzLocalTemplateDeployment `
    -SubscriptionId "<subscription-guid>" `
    -TypeOfDeployment "SingleNode" `
    -TenantId "<tenant-guid>" `
    -DeploymentMode "ValidateAndDeploy"
```

The function will interactively prompt for (unless supplied via parameters):

- **Unique ID** — A 2–8 character alphanumeric identifier (e.g., store number, site code). Override with `-UniqueID`
- **Network settings** — Subnet mask, default gateway, management IP range, and node IP addresses. Override with `-NetworkSettingsJson`
- **Passwords** — Local admin password and LCM domain user account password. Override with `-LocalAdminCredential`/`-LCMAdminCredential` or `-CredentialKeyVaultName`

### Step 4 (Optional): Monitor the Deployment

```powershell
# Monitor from the same or a separate PowerShell session
Watch-AzLocalDeployment `
    -DeploymentName "azlocal-NYC01-SingleNode-deployment" `
    -ResourceGroupName "rg-NYC01-azurelocal-prod"
```

### End-to-End Example — StorageSwitchless 2-Node Deployment

The following is a complete working example that deploys a 2-node storage-switchless Azure Local cluster. It assumes you have already:

- Updated `.config/naming-standards-config.json` with your environment settings (domain, DNS, adapters, tenant ID)
- Prepared the Active Directory OU structure
- Registered both physical nodes as Arc-enabled servers in the target subscription and resource group

```powershell
# Step 1: Import the module
Import-Module .\AzLocal.DeploymentAutomation.psd1 -Force

# Step 2: Define your Azure tenant and subscription
$Tenant = "80dd9f50-xxxx-496f-xxxx-da9bd7dadf55"
$Subscription = "f40bfb33-xxxx-4b20-xxxx-0fccb4255956"

# Step 3: Authenticate to Azure
Connect-AzAccount -SubscriptionId $Subscription -TenantId $Tenant

# Step 4: Define the network settings for the deployment
$networkSettingsJson = @'
{
    "subnetMask": "255.255.255.0",
    "defaultGateway": "10.10.32.1",
    "startingIPAddress": "10.10.32.161",
    "endingIPAddress": "10.10.32.190",
    "nodeIPAddresses": ["10.10.32.25", "10.10.32.26"]
}
'@

# Step 5: Start the deployment — will prompt for credentials interactively
Start-AzLocalTemplateDeployment `
    -SubscriptionId $Subscription `
    -TypeOfDeployment "StorageSwitchless" `
    -TenantId $Tenant `
    -DeploymentMode "ValidateAndDeploy" `
    -NodeCount 2 `
    -NetworkSettingsJson $networkSettingsJson `
    -UniqueID "15"
```

> **What happens:** The module resolves all resource names using UniqueID `15` (e.g., cluster name `AZCLUSTER15`, resource group `rg-15-azurelocal-prod`), checks Azure prerequisites (resource providers + RBAC), selects the storage-switchless 2-node parameter template, prompts for local admin and LCM admin passwords, then submits ARM Validate followed by ARM Deploy.

---

## Getting Started — CI/CD (Batch Deployment at Scale)

Use `Start-AzLocalCsvDeployment` and `Get-AzLocalDeploymentStatus` to deploy multiple clusters from a CSV file. These functions are designed for CI/CD pipelines with JUnit XML reporting.

> **Full CI/CD setup guide:** See [automation-pipelines/README.md](automation-pipelines/README.md) for GitHub Actions and Azure DevOps pipeline examples, authentication options (OIDC, Managed Identity, Service Principal), and CSV file format.

### Step 1: Prepare the CSV File

Create a CSV file with one row per cluster. See [automation-pipelines/cluster-deployments.csv](automation-pipelines/cluster-deployments.csv) for the format. Key columns:

| Column | Description |
|--------|-------------|
| `UniqueID` | 2–8 character alphanumeric identifier |
| `ReadyToDeploy` | `TRUE` or `FALSE` — only TRUE rows are processed |
| `SubscriptionId` / `TenantId` | Azure identifiers for the target environment |
| `TypeOfDeployment` | `SingleNode`, `StorageSwitched`, `StorageSwitchless`, `RackAware`, or `Disaggregated` |
| `NodeCount` | Number of physical nodes |
| `CredentialKeyVaultName` | Key Vault containing deployment credentials |
| Network columns | `SubnetMask`, `DefaultGateway`, `StartingIPAddress`, `EndingIPAddress`, `DnsServers`, `NodeIPAddresses` |

### Step 2: Import the Module and Authenticate

```powershell
Import-Module .\AzLocal.DeploymentAutomation.psd1
Connect-AzAccount  # Or use OIDC/Managed Identity in CI/CD
```

### Step 3: Validate Clusters (Pre-Flight + ARM Validate)

```powershell
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -DeploymentMode 'Validate' `
    -JUnitOutputPath './reports/validate-results.xml' `
    -Confirm:$false
```

This runs automated pre-flight checks (Azure prerequisite validation, resource group exists, Arc nodes registered, no duplicate cluster, no in-progress deployment) and then submits ARM Validate for eligible clusters.

### Step 4: Deploy Clusters

```powershell
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -DeploymentMode 'Deploy' `
    -JUnitOutputPath './reports/deploy-results.xml' `
    -Confirm:$false
```

### Step 5: Monitor Deployment Progress

```powershell
Get-AzLocalDeploymentStatus `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -JUnitOutputPath './reports/status-results.xml'
```

---

## Function Reference

### `Start-AzLocalTemplateDeployment`

Main entry point for deploying a single Azure Local cluster.

#### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-SubscriptionId` | `[guid]` | Yes | Azure subscription ID |
| `-TypeOfDeployment` | `[string]` | Yes | Deployment topology (see below) |
| `-TenantId` | `[guid]` | Yes | Azure tenant ID |
| `-DeploymentMode` | `[string]` | Yes | `Validate`, `Deploy`, or `ValidateAndDeploy` |
| `-NodeCount` | `[int]` | No | Number of nodes for StorageSwitchless (2-4), StorageSwitched (2-16), RackAware (2, 4, 6, 8), or Disaggregated (1-64) |
| `-Location` | `[string]` | No | Azure region override (default: config value) |
| `-DnsServers` | `[string[]]` | No | DNS server IPs override (default: config value) |
| `-ComputeManagementAdapters` | `[string[]]` | No | Compute/Management NIC names override (default: config value) |
| `-StorageAdapters` | `[string[]]` | No | Storage NIC names override (default: config value) |
| `-LogFilePath` | `[string]` | No | Path to a log file for debug/diagnostic output |
| `-UniqueID` | `[string]` | No | Unique identifier (2–8 alphanumeric chars) to skip interactive prompt |
| `-NetworkSettingsJson` | `[string]` | No | JSON file path or inline JSON string with network settings (skips interactive prompts) |
| `-LocalAdminCredential` | `[PSCredential]` | No | Local admin credential (password used for deployment) |
| `-LCMAdminCredential` | `[PSCredential]` | No | LCM domain admin credential (password used for deployment) |
| `-CredentialKeyVaultName` | `[string]` | No | Azure Key Vault name to retrieve credentials from |
| `-LocalAdminSecretName` | `[string]` | No | Key Vault secret name for local admin password (default: `LocalAdminCredential`) |
| `-LCMAdminSecretName` | `[string]` | No | Key Vault secret name for LCM admin password (default: `AzureStackLCMUserCredential`) |
| `-SkipOnlineTSGSearch` | `[switch]` | No | Disables the automatic online search of the [Azure Local Supportability TSG repository](https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/Deployment/README.md) on failure (online search is enabled by default) |
| `-NamingConfigPath` | `[string]` | No | Path to a custom `naming-standards-config.json` file (overrides user profile and module default) |
| `-WhatIf` | `[switch]` | No | Shows what deployment actions would be taken without executing them |
| `-Confirm` | `[switch]` | No | Prompts for confirmation before each deployment phase |

#### Deployment Types

| Value | Description | Nodes |
|-------|-------------|-------|
| `SingleNode` | Single server deployment | 1 |
| `StorageSwitchless` | Switchless deployment (requires `-NodeCount`). Uses a node-count-specific template with the correct number of storage networks: 2 for 2-node, 4 for 3-node, 6 for 4-node (formula: 2×(N-1) for dual-link mesh). | 2–4 |
| `StorageSwitched` | Multi-node switched deployment (requires `-NodeCount`) | 2–16 |
| `RackAware` | Rack-aware deployment with availability zones (requires `-NodeCount`) | 2, 4, 6, 8 |
| `Disaggregated` | **SAN-backed cluster.** Uses an external SAN (Pure, NetApp, Dell PowerStore, etc.) instead of Storage Spaces Direct. Requires LUN IDs and a dedicated SAN cluster network. Storage `configurationMode` is forced to `InfraOnly`. Scales to **64 nodes** in a single cluster. See [Disaggregated (SAN) Deployments](#disaggregated-san-deployments) below. | 1–64 |

#### Deployment Modes

| Mode | Description |
|------|-------------|
| `Validate` | Runs only the validation phase — verifies configuration without provisioning resources |
| `Deploy` | Runs only the deploy phase — use this if validation was previously completed separately |
| `ValidateAndDeploy` | **Recommended.** Runs validation first, then automatically proceeds to deploy if validation succeeds |

> **Important:** Azure Local ARM deployments require a successful `Validate` deployment before a `Deploy` deployment can proceed. The `ValidateAndDeploy` mode automates this two-phase requirement.
> See: [Deploy Azure Local using ARM templates](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)

#### Credential Handling

Credentials (local admin password and LCM domain account password) are resolved in priority order:

| Priority | Method | Parameters | Use Case |
|----------|--------|------------|----------|
| 1 | **Azure Key Vault** | `-CredentialKeyVaultName` | CI/CD pipelines with secrets in Key Vault |
| 2 | **PSCredential** | `-LocalAdminCredential`, `-LCMAdminCredential` | Automation scripts with pre-built credentials |
| 3 | **Interactive** | *(none)* | Manual deployments with `Read-Host -AsSecureString` prompts |

**Key Vault retrieval** uses `Get-AzKeyVaultSecret` (requires `Az.KeyVault` module) with default secret names `LocalAdminCredential` and `AzureStackLCMUserCredential`. Override with `-LocalAdminSecretName` and `-LCMAdminSecretName` if your secrets use different names.

> **Note:** Only the password portion of each credential is used by the ARM deployment. The LCM admin username is defined in `.config/naming-standards-config.json` (`azureStackLCMAdminUsername`).

#### Network Settings JSON

For non-interactive deployments, supply network settings via `-NetworkSettingsJson` as either a file path or an inline JSON string:

```json
{
    "subnetMask": "255.255.255.0",
    "defaultGateway": "10.0.0.1",
    "startingIPAddress": "10.0.0.10",
    "endingIPAddress": "10.0.0.50",
    "nodeIPAddresses": ["10.0.0.100", "10.0.0.101"],
    "dnsServers": ["10.0.0.5", "10.0.0.6"]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `subnetMask` | `string` | Yes | Subnet mask for the management network |
| `defaultGateway` | `string` | Yes | Default gateway IP address |
| `startingIPAddress` | `string` | Yes | Start of management IP range |
| `endingIPAddress` | `string` | Yes | End of management IP range |
| `nodeIPAddresses` | `string[]` | Yes | IP addresses for each node (count must match deployment type/node count) |
| `dnsServers` | `string[]` | No | DNS servers for this cluster. When present (non-empty), overrides `defaults.dnsServers` from `naming-standards-config.json`. Omit (or pass an empty array) to use the config default. |

All IP address fields are validated at parse time. The number of entries in `nodeIPAddresses` must match the expected node count for the deployment type (e.g., 1 for SingleNode, 2 for StorageSwitched with `-NodeCount 2`).

#### DNS Servers Precedence (v1.0.1)

DNS servers are resolved in the following order (highest priority wins):

1. `-DnsServers` parameter on `Start-AzLocalTemplateDeployment` (explicit CLI override).
2. `dnsServers` array inside `-NetworkSettingsJson` (per-deployment override) — new in v1.0.1.
3. `defaults.dnsServers` in `naming-standards-config.json` (environment-wide default).

The `-DnsServers` parameter on the cmdlet (and the `DnsServers` column in `cluster-deployments.csv`, which is mapped to it) still take precedence over the JSON field, so existing pipelines are unaffected.

#### ShouldProcess Support (-WhatIf / -Confirm)

`Start-AzLocalTemplateDeployment` supports `-WhatIf` and `-Confirm` via `SupportsShouldProcess` with `ConfirmImpact = 'High'`. Each deployment phase (Validate, Deploy) is individually gated:

```powershell
# Preview what would happen without executing
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "SingleNode" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -UniqueID "NYC01" `
    -WhatIf

# Prompt for confirmation before each deployment phase
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "SingleNode" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -Confirm
```

---

### `Watch-AzLocalDeployment`

Monitors a running ARM deployment by polling for status changes. Displays timestamped status transitions and a summary when the deployment reaches a terminal state (`Succeeded`, `Failed`, or `Canceled`).

#### Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-DeploymentName` | `[string]` | Yes | — | The name of the ARM deployment to monitor |
| `-ResourceGroupName` | `[string]` | Yes | — | The resource group containing the deployment |
| `-PollingIntervalSeconds` | `[int]` | No | `30` | How often (in seconds) to poll for status changes (10–600) |
| `-TimeoutMinutes` | `[int]` | No | `0` | Maximum monitoring time in minutes. `0` = no timeout (0–1440) |
| `-PassThru` | `[switch]` | No | — | Returns the final deployment object when monitoring completes |
| `-SkipOnlineTSGSearch` | `[switch]` | No | — | Disables the automatic online search of the [Azure Local Supportability TSG repository](https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/Deployment/README.md) on failure (online search is enabled by default) |
| `-LogFilePath` | `[string]` | No | — | Path to a log file for debug/diagnostic output |

#### Usage

```powershell
# Monitor a deployment with default settings (poll every 30 seconds, no timeout)
Watch-AzLocalDeployment -DeploymentName "azlocal-NYC01-SingleNode-deployment" `
    -ResourceGroupName "rg-NYC01-azurelocal-prod"

# Monitor with custom polling interval and timeout
Watch-AzLocalDeployment -DeploymentName "azlocal-NYC01-SingleNode-deployment" `
    -ResourceGroupName "rg-NYC01-azurelocal-prod" `
    -PollingIntervalSeconds 60 `
    -TimeoutMinutes 120

# Monitor and capture the final deployment object
$deployment = Watch-AzLocalDeployment -DeploymentName "azlocal-NYC01-SingleNode-deployment" `
    -ResourceGroupName "rg-NYC01-azurelocal-prod" `
    -PassThru

# Monitor with debug log file output
Watch-AzLocalDeployment -DeploymentName "azlocal-NYC01-SingleNode-deployment" `
    -ResourceGroupName "rg-NYC01-azurelocal-prod" `
    -LogFilePath "C:\Logs\deployment-monitor.log"
```

> **Tip:** `Watch-AzLocalDeployment` can be run from a separate PowerShell session to monitor a deployment started by `Start-AzLocalTemplateDeployment` or directly from the Azure Portal. The deployment name follows the pattern defined in `.config/naming-standards-config.json` (default: `azlocal-{UniqueID}-{TypeOfDeployment}-deployment`).

---

### `Start-AzLocalCsvDeployment`

Reads a CSV file and submits ARM deployments for all eligible clusters (where `ReadyToDeploy = TRUE`). Runs pre-flight checks before each deployment and generates JUnit XML reports for CI/CD pipeline visibility.

#### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-CsvFilePath` | `[string]` | Yes | Path to the cluster deployments CSV file |
| `-DeploymentMode` | `[string]` | Yes | `Validate` or `Deploy` |
| `-JUnitOutputPath` | `[string]` | No | Path to write JUnit XML test results |
| `-LogFilePath` | `[string]` | No | Path to write a log file for diagnostic output |
| `-NamingConfigPath` | `[string]` | No | Path to a custom `naming-standards-config.json` file (overrides user profile and module default) |
| `-WhatIf` | `[switch]` | No | Preview mode — runs pre-flight checks without submitting deployments |
| `-Confirm` | `[switch]` | No | Prompts for confirmation (use `-Confirm:$false` for CI/CD) |

#### Usage

```powershell
# Validate all ready clusters
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -DeploymentMode 'Validate' `
    -JUnitOutputPath './reports/validate-results.xml' `
    -Confirm:$false

# Deploy all ready clusters
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -DeploymentMode 'Deploy' `
    -JUnitOutputPath './reports/deploy-results.xml' `
    -Confirm:$false

# Preview what would happen (WhatIf)
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -DeploymentMode 'Validate' `
    -WhatIf
```

---

### `Get-AzLocalDeploymentStatus`

Checks the current ARM deployment status for all clusters with `ReadyToDeploy = TRUE` in a CSV file. Designed to run on a schedule (e.g., every 15 minutes) to track long-running deployments.

#### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-CsvFilePath` | `[string]` | Yes | Path to the cluster deployments CSV file |
| `-JUnitOutputPath` | `[string]` | No | Path to write JUnit XML test results |
| `-HtmlOutputPath` | `[string]` | No | Path to write a self-contained HTML deployment status report |
| `-MarkdownOutputPath` | `[string]` | No | Path to write a Markdown status report (for GitHub Step Summary / Azure DevOps) |
| `-ReportTitle` | `[string]` | No | Custom title for the HTML/Markdown report header (default: 'Azure Local Deployment Status Report') |
| `-NamingConfigPath` | `[string]` | No | Path to a custom `naming-standards-config.json` file (overrides user profile and module default) |
| `-LogFilePath` | `[string]` | No | Path to write a log file for diagnostic output |

#### Status Values

| Status | Description |
|--------|-------------|
| `NotStarted` | No deployment found for this cluster |
| `ValidateInProgress` | ARM Validate is running |
| `ValidateSucceeded` | ARM Validate completed successfully |
| `ValidateFailed` | ARM Validate failed |
| `DeployInProgress` | ARM Deploy is running |
| `DeploySucceeded` | ARM Deploy completed successfully |
| `DeployFailed` | ARM Deploy failed |
| `ClusterExists` | Cluster resource already exists in Azure |

#### Usage

```powershell
# Check status of all deployments
Get-AzLocalDeploymentStatus `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -JUnitOutputPath './reports/status-results.xml'

# Generate HTML and Markdown reports for stakeholder visibility
Get-AzLocalDeploymentStatus `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -JUnitOutputPath './reports/status-results.xml' `
    -HtmlOutputPath './reports/deployment-status.html' `
    -MarkdownOutputPath './reports/deployment-status.md' `
    -ReportTitle 'Production Fleet - Weekly Status'
```

---

## Usage Examples

### Single Node — Validate and Deploy

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "SingleNode" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy"
```

### Two-Node Switched — Validate Only

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "StorageSwitched" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "Validate" `
    -NodeCount 2
```

### StorageSwitchless (3 nodes) — Deploy Only (after prior validation)

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "StorageSwitchless" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "Deploy" `
    -NodeCount 3
```

### StorageSwitched (4 nodes) with Overrides

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "StorageSwitched" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -NodeCount 4 `
    -Location "eastus" `
    -DnsServers "10.1.1.1","10.1.1.2" `
    -ComputeManagementAdapters "NIC1","NIC2" `
    -StorageAdapters "STORAGE1","STORAGE2"
```

### RackAware (4 nodes) — Validate and Deploy

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "RackAware" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -NodeCount 4
```

> **RackAware:** Nodes are automatically split evenly into two local availability zones (ZoneA and ZoneB). For example, with 4 nodes, nodes 1–2 are assigned to ZoneA and nodes 3–4 to ZoneB. Only even node counts (2, 4, 6, 8) are supported.

### Disaggregated (SAN) Deployments

Disaggregated deployments use **external SAN storage** (Pure Storage, NetApp, Dell PowerStore, etc.) instead of local Storage Spaces Direct (S2D), and scale to **64 nodes** in a single cluster. The module ships a separate ARM template (`templates/azure-local-deployment-template-san.json`) and parameter file (`template-parameter-files/disaggregated-parameters-file.json`) that match the SAN deploymentSettings schema (`storage.storageType = SAN`, `storage.san.{infraVolLunId,infraPerfLunId}`, `hostNetwork.sanNetworks` instead of `storageNetworks`). Modeled on the official quickstart [microsoft.azurestackhci/create-cluster-san](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster-san).

#### Required additional parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `-InfraVolLunId` | `[string]` | Vendor-issued infrastructure volume LUN ID (e.g. `PURE1234567890ABCDEF`). |
| `-InfraPerfLunId` | `[string]` | Vendor-issued performance LUN ID (e.g. `PURE0987654321MNOPQR`). |
| `-SanNetworkAdapterName` | `[string]` | Physical NIC used for the SAN cluster network (e.g. `"ethernet 3"`). |
| `-SanNetworkVlanId` | `[int]` | VLAN tag for the SAN cluster network, 0–4095 (0 = untagged). |
| `-SanNetworkAddressPrefix` | `[string]` | CIDR for the SAN cluster network (e.g. `10.10.30.0/24`). |

#### Optional QoS overrides (sensible defaults provided)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SanBandwidthPercentageSmb` | `50` | SMB bandwidth allocation, 1–97. |
| `-SanJumboPacket` | `9014` | Jumbo packet size: `1514` or `9014`. |

> **Behaviour notes for Disaggregated:**
> - Storage `configurationMode` is forced to `InfraOnly` (the only value supported by the SAN deploymentSettings schema).
> - `clusterPattern` and `localAvailabilityZones` are NOT emitted (the SAN template does not declare them).
> - `storageConnectivitySwitchless` is set to `false`; the SAN cluster network replaces SMB-Direct/RDMA storage networks.
> - `NodeCount` accepts 1–64. For NodeCount = 1, witness type is `No Witness`; for ≥ 2, witness type is `Cloud`.

#### Interactive (Disaggregated, 8 nodes)

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "Disaggregated" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -NodeCount 8
```

The module will prompt for the management network (subnet/gateway/IP pool/node IPs) **and** the SAN-specific values (LUN IDs, SAN adapter name, VLAN ID, SAN address prefix).

#### Non-Interactive (Disaggregated)

Pass all SAN parameters explicitly, or include a `sanSettings` block in `-NetworkSettingsJson`:

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "Disaggregated" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -UniqueID "NYC02" `
    -NodeCount 16 `
    -CredentialKeyVaultName "kv-deployments-prod" `
    -NetworkSettingsJson "C:\Pipeline\san-network-settings.json" `
    -InfraVolLunId   "PURE1234567890ABCDEF" `
    -InfraPerfLunId  "PURE0987654321MNOPQR" `
    -SanNetworkAdapterName "ethernet 3" `
    -SanNetworkVlanId 711 `
    -SanNetworkAddressPrefix "10.10.30.0/24" `
    -Confirm:$false
```

Or with the `sanSettings` block embedded in the JSON file:

```json
{
    "subnetMask": "255.255.255.0",
    "defaultGateway": "10.0.5.1",
    "startingIPAddress": "10.0.5.10",
    "endingIPAddress": "10.0.5.30",
    "nodeIPAddresses": [ "10.0.5.100", "10.0.5.101", "10.0.5.102", "10.0.5.103",
                         "10.0.5.104", "10.0.5.105", "10.0.5.106", "10.0.5.107" ],
    "sanSettings": {
        "infraVolLunId": "PURE1234567890ABCDEF",
        "infraPerfLunId": "PURE0987654321MNOPQR",
        "sanNetworkAdapterName": "ethernet 3",
        "sanNetworkVlanId": 711,
        "sanNetworkAddressPrefix": "10.10.30.0/24"
    }
}
```

#### CSV-driven Disaggregated (CI/CD)

The example CSV ships with a `Store005` Disaggregated row demonstrating the additional columns: `InfraVolLunId`, `InfraPerfLunId`, `SanNetworkAdapterName`, `SanNetworkVlanId`, `SanNetworkAddressPrefix`. Existing rows leave these columns blank — they are validated only when `TypeOfDeployment = Disaggregated`.

### Fully Non-Interactive (CI/CD Pipeline)

Supply all inputs via parameters to avoid interactive prompts:

```powershell
# Credentials from Azure Key Vault
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "SingleNode" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -UniqueID "NYC01" `
    -CredentialKeyVaultName "kv-deployments-prod" `
    -NetworkSettingsJson "C:\Pipeline\network-settings.json" `
    -LogFilePath "C:\Pipeline\deployment.log" `
    -Confirm:$false
```

### Credentials via PSCredential

```powershell
$localAdmin = Get-Credential -UserName "Administrator" -Message "Local Admin"
$lcmAdmin = Get-Credential -UserName "LCMAdminUserName" -Message "LCM Admin"

Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "StorageSwitched" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -NodeCount 2 `
    -UniqueID "STORE42" `
    -LocalAdminCredential $localAdmin `
    -LCMAdminCredential $lcmAdmin `
    -NetworkSettingsJson '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100","10.0.0.101"]}'
```

### Key Vault with Custom Secret Names

```powershell
Start-AzLocalTemplateDeployment `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -TypeOfDeployment "StorageSwitched" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -DeploymentMode "ValidateAndDeploy" `
    -NodeCount 4 `
    -UniqueID "DC02" `
    -CredentialKeyVaultName "kv-secrets-prod" `
    -LocalAdminSecretName "azlocal-local-admin" `
    -LCMAdminSecretName "azlocal-lcm-admin" `
    -NetworkSettingsJson "C:\Config\dc02-network.json"
```

---

## Configuration

All naming standards and environment defaults are managed centrally in `.config/naming-standards-config.json`. This file is loaded at runtime and values are applied to the ARM template parameters.

### Naming Standards

Naming patterns use placeholders that are replaced at runtime:

| Placeholder | Description | Example |
|------------|-------------|---------|
| `{UniqueID}` | The Unique ID entered during deployment (2–8 alphanumeric characters) | `STORE01`, `NYC01`, `AB` |
| `{NodeNumber}` | Zero-padded node number (auto-generated, 2 digits) | `01`, `02` |
| `{TypeOfDeployment}` | The deployment type | `SingleNode`, `StorageSwitchless`, `StorageSwitched`, `RackAware` |

#### Default Naming Patterns

| Resource | Pattern | Example (UniqueID=`NYC01`) |
|----------|---------|----------------------------|
| Cluster Name | `AZCLUSTER{UniqueID}` | `AZCLUSTERNYC01` |
| Resource Group | `rg-{UniqueID}-azurelocal-prod` | `rg-NYC01-azurelocal-prod` |
| Key Vault | `kv-{UniqueID}-azlocal` | `kv-NYC01-azlocal` |
| Custom Location | `{UniqueID}-azlocal-customlocation` | `NYC01-azlocal-customlocation` |
| Resource Bridge | `{UniqueID}-azlocal-arcbridge` | `NYC01-azlocal-arcbridge` |
| Diagnostics Storage | `{UniqueID}azlocaldiag` | `nyc01azlocaldiag` |
| Witness Storage | `{UniqueID}azlocalwitness` | `nyc01azlocalwitness` |
| Node Name | `{UniqueID}NODE{NodeNumber}` | `NYC01NODE01` |
| AD OU Path | `OU=AzLocal-{UniqueID},OU=AzureLocal,DC=contoso,DC=com` | `OU=AzLocal-NYC01,OU=AzureLocal,DC=contoso,DC=com` |
| Deployment Name | `azlocal-{UniqueID}-{TypeOfDeployment}-deployment` | `azlocal-NYC01-SingleNode-deployment` |

#### Azure Resource Naming Limits

When customising naming patterns, ensure the resolved names stay within Azure resource naming constraints. The table below shows the Azure limits and the maximum UniqueID length supported by each default pattern:

| Resource Type | Azure Limit | Allowed Characters | Default Pattern | Fixed Chars | Max UniqueID |
|---------------|-------------|-------------------|-----------------|-------------|--------------|
| Storage Account (diagnostic) | 3–24 chars | Lowercase alphanumeric only | `{UniqueID}azlocaldiag` | 10 | **14** |
| Storage Account (witness) | 3–24 chars | Lowercase alphanumeric only | `{UniqueID}azlocalwitness` | 14 | **10** |
| Cluster Name (NetBIOS) | 1–15 chars | Alphanumeric only | `AZCLUSTER{UniqueID}` | 9 | **6** |
| Node Name (NetBIOS) | 1–15 chars | Alphanumeric only | `{UniqueID}NODE{NodeNumber}` | 6 (4 + 2) | **9** |
| Key Vault | 3–24 chars | Alphanumeric + hyphens, must start with letter | `kv-{UniqueID}-azlocal` | 12 | **12** |
| Custom Location | 1–63 chars | Alphanumeric + hyphens | `{UniqueID}-azlocal-customlocation` | 25 | **38** |
| Resource Bridge | 1–63 chars | Alphanumeric + hyphens | `{UniqueID}-azlocal-arcbridge` | 20 | **43** |
| Deployment Name | 1–64 chars | Alphanumeric, hyphens, underscores, periods | `azlocal-{UniqueID}-{TypeOfDeployment}-deployment` | ~30 | **34** |

> **Note:** With the default patterns, the **cluster name** is the tightest constraint — limiting UniqueID to **6 characters**. If you need longer UniqueIDs, shorten the fixed portions of the patterns (e.g., change `AZCLUSTER{UniqueID}` to `AZC{UniqueID}`). All resolved names are validated at runtime by `Test-AzLocalResourceNames` before deployment begins.

### Default Values

These values are used unless overridden by function parameters:

| Setting | Default Value | Override Parameter |
|---------|---------------|--------------------|
| `location` | `westeurope` | `-Location` |
| `domainFqdn` | `contoso.com` | — (edit config) |
| `namingPrefix` | `HCI01` | — (edit config) |
| `azureStackLCMAdminUsername` | `LCMAdminUserName` | — (edit config) |
| `storageAccountType` | `Standard_LRS` | — (edit config) |
| `dnsServers` | `["10.0.0.1", "10.0.0.2"]` | `-DnsServers` (or `dnsServers` in `-NetworkSettingsJson`) |
| `computeManagementAdapters` | `["MGMT_COMP_Slot1_Port1", "MGMT_COMP_Slot1_Port2"]` | `-ComputeManagementAdapters` |
| `storageAdapters` | `["SMB_Slot2_Port1", "SMB_Slot2_Port2"]` | `-StorageAdapters` |

### Environment Settings

The `environment` section contains tenant-specific values that **must be updated** before running deployments:

| Setting | Description | How to Find |
|---------|-------------|-------------|
| `tenantId` | Your Entra ID (Azure AD) tenant GUID | `(Get-AzContext).Tenant.Id` |
| `hciResourceProviderObjectID` | Object ID of the HCI Resource Provider service principal in your tenant. If left empty, the module will look it up at runtime via `Get-AzADServicePrincipal`. | `(Get-AzADServicePrincipal -DisplayName "Microsoft.AzureStackHCI Resource Provider").Id` |

> **Important:** The `tenantId` is **required** — update this before your first deployment. The `hciResourceProviderObjectID` is optional; if left blank, the module resolves it automatically at runtime. Pre-populating it avoids the Azure AD lookup and is useful for CI/CD pipelines where the service principal may not have directory read permissions.

### Configuration Validation

The module validates that critical settings have been customised from their shipped defaults before any deployment is attempted. If any of the following placeholder values are detected, the deployment is blocked with a clear error listing all values that need updating:

| Setting | Shipped Default | Action Required |
|---------|----------------|------------------|
| `environment.tenantId` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` | Set to your Entra ID tenant GUID |
| `defaults.domainFqdn` | `contoso.com` | Set to your Active Directory domain FQDN |
| `namingStandards.adouPath` | `DC=contoso,DC=com` | Update to match your AD structure |

This check runs in `Start-AzLocalTemplateDeployment`, `Start-AzLocalCsvDeployment`, and `Get-AzLocalDeploymentStatus` immediately after the configuration is loaded, and prevents deployments with settings that would always fail.

### Example Configuration

```json
{
    "namingStandards": {
        "clusterName": "AZCLUSTER{UniqueID}",
        "resourceGroupName": "rg-{UniqueID}-azurelocal-prod",
        "keyVaultName": "kv-{UniqueID}-azlocal",
        "nodeNamePattern": "{UniqueID}NODE{NodeNumber}"
    },
    "defaults": {
        "location": "westeurope",
        "domainFqdn": "contoso.com",
        "dnsServers": ["10.0.0.1", "10.0.0.2"],
        "computeManagementAdapters": ["MGMT_COMP_Slot1_Port1", "MGMT_COMP_Slot1_Port2"],
        "storageAdapters": ["SMB_Slot2_Port1", "SMB_Slot2_Port2"]
    },
    "environment": {
        "tenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "hciResourceProviderObjectID": ""
    }
}
```

---

## Deployment Workflow

The following describes what happens when you run `Start-AzLocalTemplateDeployment`:

1. **Load Configuration** — Naming standards and defaults are loaded from the user profile, an explicit `-NamingConfigPath`, or the module default (auto-initialised on first use). The loaded config is validated to ensure shipped placeholder values have been replaced.
2. **Collect Unique ID** — Uses `-UniqueID` parameter or prompts interactively (2–8 alphanumeric chars)
3. **Collect Network Settings** — Uses `-NetworkSettingsJson` (file path or inline JSON) or prompts interactively for subnet mask, gateway, IP range, and node IPs
4. **Resolve Credentials** — Key Vault (`-CredentialKeyVaultName`) > PSCredential parameters > interactive `Read-Host -AsSecureString`
5. **Resolve Resource Names** — All resource names are generated from naming patterns + Unique ID
6. **Verify Prerequisites** — Checks that the resource group and Arc-registered nodes exist in Azure
7. **Generate Parameter File** — A deployment-specific parameter file is created in `deployment-parameter-files/`
8. **Execute Deployment** — ARM template deployment is submitted to Azure (subject to `-WhatIf` / `-Confirm` gates)
   - If `ValidateAndDeploy`: runs Validate first, then Deploy on success
   - If `Validate` or `Deploy`: runs only that single phase

### Two-Phase Deployment Flow (`ValidateAndDeploy`)

```
┌─────────────────────────────────────────────┐
│  Phase 1: Validate                          │
│  - deploymentMode = "Validate"              │
│  - ARM template deployment submitted        │
│  - Waits for completion                     │
├─────────────────────────────────────────────┤
│  ✓ Validation Succeeded?                    │
│    Yes → Proceed to Phase 2                 │
│    No  → Stop and report error              │
├─────────────────────────────────────────────┤
│  Phase 2: Deploy                            │
│  - deploymentMode = "Deploy"                │
│  - ARM template deployment submitted        │
│  - Waits for completion                     │
├─────────────────────────────────────────────┤
│  ✓ Deployment Succeeded                     │
└─────────────────────────────────────────────┘
```

---

## Deployment Times

Azure Local deployments are long-running operations. Actual deployment times vary depending on several factors:

- **Number of physical nodes** — more nodes increases provisioning and configuration time
- **Network speed to Azure** — bandwidth and latency between the on-premises environment and Azure datacentres
- **Proxy servers and firewalls** — additional network hops and inspection can add significant overhead
- **Hardware performance** — disk speed, memory, and CPU on the physical nodes
- **Azure region distance** — resource provider round trip response times (based on geographic distant and the speed of light for network connections)

### Example Deployment Times

The following times were observed during a real 2-node StorageSwitchless deployment using the Azure Local 2602 release:

| Phase | Start | End | Duration |
|-------|-------|-----|----------|
| **Validate** | 12:14 | 13:52 | ~1 hour 38 minutes |
| **Deploy** | 14:11 | 18:08 | ~3 hours 57 minutes |
| **Total** | 12:14 | 18:08 | ~5 hours 54 minutes |

> **Note:** These times are indicative only and will vary between environments. Single-node deployments are typically faster, while larger multi-node or rack-aware deployments may take longer. Use `Watch-AzLocalDeployment` to monitor progress in real time.

---

## Template Parameter Files

The `template-parameter-files/` directory contains base parameter templates for each deployment type. Values marked as `<calculated>` are populated automatically by the module at runtime. **Do not edit these files** unless you need to change static deployment settings (e.g., security policies, networking patterns).

Key static settings in the parameter files that you may wish to review:

- **Security settings** — `securityLevel`, `driftControlEnforced`, `wdacEnforced`, etc.
- **Networking pattern** — `networkingPattern`, `intentList` structure
- **Storage network** — `storageNetworkList` VLAN IDs
- **SBE (Solution Builder Extension)** — `sbeVersion`, `sbeFamily`, `sbePublisher`, etc.

## Deployment Parameter Files

When a deployment is executed, the module generates a deployment-specific parameter file in the `deployment-parameter-files/` directory. These files contain the fully resolved parameters for the deployment and are named using the pattern:

```
{UniqueID}-{deployment-type}-parameters-file.json
```

For example: `NYC01-single-node-parameters-file.json`

---

## Troubleshooting

When a deployment or validation step fails, the module automatically analyses the ARM error codes and messages to provide **targeted troubleshooting hints** in the console output. These hints cover the most common failure patterns and include specific remediation steps.

### Automatic Troubleshooting Hints

The following failure patterns are detected automatically — no additional parameters required:

| Error Pattern | Hint Title | What It Detects |
|---------------|------------|------------------|
| `NetworkIntentValidationFailed` | Network Adapter Mismatch | NIC names in deployment parameters don't match the physical adapters on the node(s) |
| `NetAdapter_RDMA_Operational` | Network Adapter RDMA Operational Status Failure | RDMA is not operational or not supported on adapters - install vendor-specific NIC drivers or configure OverrideAdapterProperty to disable NetworkDirect |
| `InboxDriver` / `DriverProvider Microsoft` | Network Adapters Using Inbox Drivers | Adapters are using inbox (Microsoft/Windows) drivers instead of vendor-specific drivers required for RDMA and Azure Local |
| `vManagement(vManagement(...))` | Management Intent Name Double-Wrapped | Intent name includes the `vManagement()` prefix that the system adds automatically |
| `OuGpoInheritance` / `GpoInheritanceBlocked` | GPO Inheritance Block Required | GPO inheritance is not blocked on the AD OU — may also need WMI filters for enforced parent GPOs |
| `RoleAssignmentExists` | Duplicate RBAC Role Assignment | A previous deployment attempt already created the role assignment — includes `az role assignment delete` command guidance |
| `PhysicalDisk` / `CanPool` / `HCISupportedData` | Physical Disk / Storage Validation Failure | Data disks not visible or behind a RAID controller — includes S2D requirements and disk reset steps |
| `MandatoryRPRegistration` / `ValidateArcIntegration` | Required Resource Providers Not Registered | One or more required Azure RPs are not registered in the subscription - lists all 12 required RPs with registration commands |
| `OperationTimeout` | Deployment Settings Validation Timeout | Environment checker timed out during validation |
| `UpdateDeploymentSettingsDataFailed` | Deployment Settings Validation Failed | General wrapper — identifies which validation step failed and provides per-step guidance |

### Online TSG Search (Enabled by Default)

On any deployment or validation failure, the module automatically searches the [Azure Local Supportability TSG repository](https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/Deployment/README.md) for matching troubleshooting guides. This behaviour is **enabled by default** — use `-SkipOnlineTSGSearch` to disable it.

```powershell
# Online TSG search happens automatically on failure — no extra parameter needed
Start-AzLocalTemplateDeployment -SubscriptionId $subId -TypeOfDeployment SingleNode `
    -TenantId $tenantId -DeploymentMode Validate -UniqueID "NYC01"

# Disable online TSG search (e.g., air-gapped environments)
Start-AzLocalTemplateDeployment -SubscriptionId $subId -TypeOfDeployment SingleNode `
    -TenantId $tenantId -DeploymentMode Validate -UniqueID "NYC01" -SkipOnlineTSGSearch

# Works the same way on Watch-AzLocalDeployment
Watch-AzLocalDeployment -DeploymentName "azlocal-NYC01-SingleNode-deployment" `
    -ResourceGroupName "rg-NYC01-azurelocal-prod" -SkipOnlineTSGSearch
```

The online search:
- Queries the GitHub API for TSG files in `Azure/AzureLocal-Supportability/TSG/Deployment`
- Extracts keywords from the error text and matches them against TSG filenames
- Returns direct links to matching troubleshooting guides
- Fails gracefully when offline (known pattern hints are still displayed)

### General Troubleshooting Reference

| Issue | Resolution |
|-------|------------|
| Resource group not found | Ensure the resource group exists and Arc nodes are registered before running the deployment |
| Arc node not found | Verify nodes are Arc-enabled and registered in the correct resource group |
| HCI Resource Provider not found | Run `Get-AzADServicePrincipal -DisplayName "Microsoft.AzureStackHCI Resource Provider"` to verify |
| Validation fails | Review the Azure portal deployment details for specific validation errors |
| Deploy fails after Validate | Check the deployment phase output for the specific error. Ensure Validate completed successfully first |
| Naming config not found | Ensure `.config/naming-standards-config.json` exists in the module directory |
| Template file not found | Ensure `templates/azure-local-deployment-template.json` exists |
| Key Vault access denied | Ensure `Az.KeyVault` module is installed and the identity has **Key Vault Secrets User** role on the vault |

---

## Testing

The module includes a comprehensive Pester test suite in the `Tests/` folder.

### Prerequisites

- [Pester](https://pester.dev/) v5.0 or higher (auto-installed by the runner if missing)

### Running Tests

```powershell
# Basic run (Normal verbosity)
.\Tests\Invoke-Tests.ps1

# Open HTML report in browser after completion
.\Tests\Invoke-Tests.ps1 -OpenReport

# Detailed output (saved to log file)
.\Tests\Invoke-Tests.ps1 -Full

# Custom output path
.\Tests\Invoke-Tests.ps1 -OutputPath "C:\TestResults"
```

### Test Coverage

The test suite validates:

| Area | What Is Tested |
|------|----------------|
| Module Load | Manifest validity, exported functions, required modules (`Az.Accounts`, `Az.Resources`), optional module (`Az.KeyVault`) |
| Parameter Validation | Types, ValidateSet values, ValidateRange, mandatory flags |
| Credential Parameters | PSCredential types, Key Vault secret name defaults, non-mandatory validation |
| ShouldProcess | SupportsShouldProcess enabled, ConfirmImpact = High |
| UniqueID Parameter | ValidatePattern attribute, regex validation (2–8 alphanumeric characters) |
| NetworkSettingsJson | JSON parsing, file/string input, required field validation, IP format validation, node count validation |
| Naming Resolution | `Resolve-AzLocalResourceName` placeholder replacement (2-digit node numbers) |
| Resource Name Validation | `Test-AzLocalResourceNames` Azure naming limits (length, allowed characters) |
| Config Loading | `Get-AzLocalNamingConfig` structure and completeness |
| Parameter File Paths | Correct file mapping for each deployment type |
| Parameter File Settings | `Get-AzLocalParameterFileSettings` loading and content structure |
| Parameter File Generation | `New-AzLocalDeploymentParameterFile` parameter definitions |
| UniqueID Validation | Valid/invalid input handling via mocked `Read-Host` |
| Network Settings | Node count resolution, IP address prompting |
| Format-Json | Prettify, minify, and custom indentation |
| Deployment Logic | Node count per type, deployment phase splitting |
| File Integrity | Template/config existence, no deprecated references |
| Watch-AzLocalDeployment | Parameter definitions, types, mandatory flags, ValidateRange bounds, terminal state detection |
| Write-AzLocalLog | Function existence, parameter definitions (Message, Level, NoTimestamp), log file output |
| LogFilePath Parameter | Presence, type, and non-mandatory flag on exported functions |
| Pre-Flight Checks | Resource group, Azure prerequisites (RP registration + RBAC), Arc node, cluster existence, deployment state checks (mocked) |
| Azure Prerequisites | Resource provider registration (12 providers), auto-registration, RBAC role validation, identity type handling (mocked) |
| Validation Troubleshooting Hints | Known pattern matching (10 patterns), hint output structure, online TSG search keyword extraction, empty/null input handling, `-SkipOnlineTSGSearch` parameter on exported functions |
| CSV Deployment | Batch deployment with pre-flight, JUnit output, skip logic (mocked) |
| Deployment Status | Status monitoring with all status categories (mocked) |
| CI/CD Pipelines | Automation pipeline file structure, CSV format, workflow file existence |
| Code Quality | `Set-StrictMode` declaration, `OutputType` attributes, `Join-Path` usage, credential cleanup in `finally` block, `Az.KeyVault` availability check, no dead code patterns |

### Output

The test runner generates:
- **NUnit XML** — For CI/CD pipeline integration
- **HTML Report** — Human-readable results with pass/fail summary
- **Log file** — Detailed output when using `-Full` or `-Verbosity Detailed`

---

## References

- [Deploy Azure Local using ARM templates](https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template)
- [Assign required permissions for Azure Local deployment](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions) — resource provider registration and RBAC role requirements
- [Azure Local documentation](https://learn.microsoft.com/azure/azure-local/)
- [Azure Quickstart Templates — Azure Stack HCI](https://github.com/Azure/azure-quickstart-templates/tree/master/quickstarts/microsoft.azurestackhci/create-cluster)

## License

This project contains example / sample code that is provided "AS IS", without warranty of any kind. See [LICENSE](../LICENSE) for details.
