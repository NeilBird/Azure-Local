# CI/CD Pipeline Examples for Azure Local Cluster Deployments

> ⚠️ **Disclaimer**: This module is **NOT** a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT license](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

This folder contains example CI/CD pipelines for automating Azure Local cluster deployments at scale using GitHub Actions and Azure DevOps.

## Overview

Four pipelines are provided for each platform:

| Pipeline | Description |
|----------|-------------|
| **Validate Deployments** | Runs pre-flight checks (Arc nodes, resource groups, naming) and submits ARM Validate for eligible clusters |
| **Deploy Clusters** | Submits ARM Deploy requests for clusters that passed validation |
| **Deployment Monitor** | Monitors deployment progress with JUnit XML reports for dashboards (every 15 min) |
| **Deployment Status Report** | Generates HTML and Markdown status reports for stakeholder visibility (daily/weekly) |

### Multi-Stage Pipeline Flow

```
 ┌─────────────────────┐
 │   CSV File           │  cluster-deployments.csv
 │   (ReadyToDeploy)    │  (checked into source control)
 └─────────┬───────────┘
           │
           ▼
 ┌─────────────────────┐
 │ 1. Validate          │  Pre-flight checks + ARM Validate
 │    Deployments       │  (manual trigger)
 └─────────┬───────────┘
           │ ✅ Passed
           ▼
 ┌─────────────────────┐
 │ 2. Deploy            │  ARM Deploy (actual deployment)
 │    Clusters          │  (manual trigger with validation gate)
 └─────────┬───────────┘
           │ Submitted
           ▼
 ┌─────────────────────┐
 │ 3. Deployment        │  Status monitoring every 15 min
 │    Monitor           │  (scheduled + manual trigger)
 └─────────┬───────────┘
           │ On schedule
           ▼
 ┌─────────────────────┐
 │ 4. Deployment        │  HTML/Markdown report (daily/weekly)
 │    Status Report     │  (scheduled + manual trigger)
 └─────────────────────┘
```

## Prerequisites

Before using these pipelines, you need:

1. **Azure subscription** with Azure Local (Azure Stack HCI) clusters
2. **Azure identity** — Service Principal or Managed Identity (see [Authentication Options](#-authentication-options) below)
3. **CI/CD platform** (GitHub or Azure DevOps)
4. **Az PowerShell modules** — `Az.Accounts` (v2.0.0+), `Az.Resources` (v6.0.0+), and `Az.KeyVault` (v4.0.0+)
5. **Arc-registered nodes** — All physical nodes must be registered with Azure Arc in their target resource groups
6. **Key Vault** — Deployment credentials (Local Admin and LCM Admin passwords) stored in Azure Key Vault
7. **Naming configuration** — A customised copy of `.config/naming-standards-config.json` checked into your repository with your environment-specific values (tenantId, domain FQDN, OU path, etc.). The pipelines pass this file via the `-NamingConfigPath` parameter. See [Configuration](../README.md#configuration) in the main README for details.
8. **Resource providers** — 12 required providers (auto-registered during pre-flight if the identity has `*/register/action`, or [pre-register manually](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions))

---

## CSV File Format

The CSV file drives all deployments. Each row represents one cluster/site.

### Required Columns

| Column | Type | Description | Example |
|--------|------|-------------|---------|
| `UniqueID` | String | 2–8 character alphanumeric identifier | `Store001` |
| `ReadyToDeploy` | Boolean | `TRUE` or `FALSE` — only TRUE rows are processed | `TRUE` |
| `SubscriptionId` | GUID | Azure subscription ID for this cluster | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `TenantId` | GUID | Entra ID tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `TypeOfDeployment` | String | Deployment type (see table below) | `SingleNode` |
| `NodeCount` | Integer | Number of physical nodes | `1` |
| `Location` | String | Azure region | `eastus` |
| `CredentialKeyVaultName` | String | Key Vault containing deployment credentials | `kv-deploy-creds` |
| `LocalAdminSecretName` | String | Secret name for local admin password | `LocalAdminCredential` |
| `LCMAdminSecretName` | String | Secret name for LCM admin password | `AzureStackLCMAdminPasswd` |
| `SubnetMask` | String | Network subnet mask | `255.255.255.0` |
| `DefaultGateway` | IP | Network default gateway | `10.0.1.1` |
| `StartingIPAddress` | IP | Start of IP range for cluster IPs | `10.0.1.100` |
| `EndingIPAddress` | IP | End of IP range for cluster IPs | `10.0.1.110` |
| `DnsServers` | String | DNS server IPs (semicolon-separated for multiple) | `10.0.1.10;10.0.1.11` |
| `NodeIPAddresses` | String | Node management IPs (semicolon-separated for multiple) | `10.0.1.50;10.0.1.51` |
| `InfraVolLunId` | String | **Disaggregated only.** SAN infrastructure volume LUN ID. | `PURE1234567890ABCDEF` |
| `InfraPerfLunId` | String | **Disaggregated only.** SAN performance LUN ID. | `PURE0987654321MNOPQR` |
| `SanNetworkAdapterName` | String | **Disaggregated only.** Physical NIC name used for the SAN cluster network. | `ethernet 3` |
| `SanNetworkVlanId` | Int | **Disaggregated only.** VLAN ID for the SAN cluster network (0-4095, 0 = untagged). | `711` |
| `SanNetworkAddressPrefix` | CIDR | **Disaggregated only.** CIDR for the SAN cluster network. | `10.10.30.0/24` |

### TypeOfDeployment Values

| Value | Description | Nodes |
|-------|-------------|-------|
| `SingleNode` | Single-node cluster | 1 |
| `StorageSwitched` | Multi-node cluster with storage network switch | 2–16 |
| `StorageSwitchless` | Switchless cluster. The module automatically selects the correct per-node-count parameter template with the appropriate number of storage networks: 2 for 2-node, 4 for 3-node, 6 for 4-node (formula: 2×(N-1) for dual-link mesh). | 2–4 |
| `RackAware` | Rack-aware deployment with availability zones | 2, 4, 6, 8 |
| `Disaggregated` | SAN-backed cluster (Pure / NetApp / PowerStore, etc.) using external LUNs instead of Storage Spaces Direct. Requires the five SAN columns above. `configurationMode` is forced to `InfraOnly`. | 1–64 |

### Multi-Value Fields

For fields requiring multiple values (DNS servers, node IPs), use **semicolons** as separators:

```csv
UniqueID,...,DnsServers,NodeIPAddresses
Store002,...,10.0.2.10;10.0.2.11,10.0.2.50;10.0.2.51
```

### Example CSV

See [cluster-deployments.csv](cluster-deployments.csv) for a complete example with 4 different deployment types.

---

## Pre-Flight Checks

Before submitting any deployment, the pipeline runs these automated checks for each cluster:

| Check | Description |
|-------|-------------|
| **CSV Validation** | Validates CSV structure, required columns, UniqueID format, GUID fields, TypeOfDeployment values, IP addresses, and NodeIPAddresses count matches NodeCount |
| **Resource Naming** | Validates all resource names against Azure naming rules via `Test-AzLocalResourceNames` |
| **Resource Group** | Confirms the target resource group exists |
| **Azure Prerequisites** | Validates 12 required resource providers are registered (auto-registers any missing) and checks 6 RBAC role assignments (advisory). See [Required Permissions](https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions). |
| **Arc Nodes** | Verifies all expected nodes are registered with Azure Arc (`Microsoft.HybridCompute/machines`) |
| **Existing Cluster** | Checks for existing `Microsoft.AzureStackHCI/clusters` resource to prevent duplicate deployments |
| **In-Progress Deployment** | Checks for running ARM deployments in the resource group |

Results are published as **JUnit XML** for human-readable CI/CD reporting.

---

## 🔐 Authentication Options

Microsoft recommends three authentication methods for CI/CD pipelines, listed from **most to least secure**:

| Method | Security | Secrets Required | Best For |
|--------|----------|------------------|----------|
| **🥇 OpenID Connect (OIDC)** | ⭐⭐⭐⭐⭐ | None (secretless) | GitHub Actions, Azure DevOps |
| **🥈 Managed Identity** | ⭐⭐⭐⭐ | None | Self-hosted runners on Azure VMs |
| **🥉 Service Principal + Secret** | ⭐⭐ | Client Secret | Legacy systems only |

> ⚠️ **Important**: Microsoft recommends **OpenID Connect** over client secrets. Client secrets can expire, be leaked, and require rotation. OIDC uses short-lived tokens with no stored secrets.

---

### 🥇 Option 1: OpenID Connect (OIDC) — Recommended

OIDC uses federated identity credentials — your GitHub/Azure DevOps workflow requests a token from Azure without storing any secrets.

#### Benefits
- ✅ **No secrets to manage or rotate**
- ✅ **Short-lived tokens** (valid only for workflow execution)
- ✅ **No risk of secret leakage**
- ✅ **Audit trail** of token usage

#### Step 1: Create the App Registration

```bash
# Create App Registration
az ad app create --display-name "AzureLocal-DeployAutomation-OIDC"

# Note the appId from output — this is your AZURE_CLIENT_ID
```

#### Step 2: Create Service Principal and Assign Roles

```bash
# Create Service Principal from the App Registration
az ad sp create --id {app-id-from-step-1}

# Assign Azure Stack HCI Administrator role
az role assignment create \
    --assignee {app-id-from-step-1} \
    --role "Azure Stack HCI Administrator" \
    --scope "/subscriptions/{your-subscription-id}"

# Assign Reader role (required for RBAC checks)
az role assignment create \
    --assignee {app-id-from-step-1} \
    --role "Reader" \
    --scope "/subscriptions/{your-subscription-id}"

# Assign Key Vault Secrets User role (for credential retrieval)
az role assignment create \
    --assignee {app-id-from-step-1} \
    --role "Key Vault Secrets User" \
    --scope "/subscriptions/{your-subscription-id}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vault-name}"
```

#### Step 3: Configure Federated Credentials

**For GitHub Actions:**

```bash
# Create federated credential for workflow_dispatch
az ad app federated-credential create \
    --id {app-id-from-step-1} \
    --parameters '{
        "name": "GitHubActions-main",
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:{owner}/{repo}:ref:refs/heads/main",
        "audiences": ["api://AzureADTokenExchange"]
    }'
```

**For Azure DevOps:**

```bash
# Create federated credential for Azure DevOps
az ad app federated-credential create \
    --id {app-id-from-step-1} \
    --parameters '{
        "name": "AzureDevOps",
        "issuer": "https://vstoken.dev.azure.com/{organization-id}",
        "subject": "sc://{organization}/{project}/{service-connection-name}",
        "audiences": ["api://AzureADTokenExchange"]
    }'
```

#### Step 4: Add Secrets / Service Connections

**GitHub Actions:** Add repository secrets (no client secret needed!):

| Secret Name | Value |
|-------------|-------|
| `AZURE_CLIENT_ID` | App Registration ID |
| `AZURE_TENANT_ID` | Your Entra ID tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Your subscription ID |

**Azure DevOps:** Create a service connection:
1. Go to **Project Settings** → **Service connections**
2. Select **Azure Resource Manager** → **Workload identity federation (manual)**
3. Enter the App Registration details and service connection name (default: `AzureLocal-ServiceConnection`)

---

### 🥈 Option 2: Managed Identity (Self-Hosted Runners)

If you run self-hosted GitHub runners or Azure DevOps agents on Azure VMs, use Managed Identity.

```bash
# Enable system-assigned managed identity on runner VM
az vm identity assign --name "runner-vm" --resource-group "runners-rg"

# Assign required roles
az role assignment create \
    --assignee {principal-id} \
    --role "Azure Stack HCI Administrator" \
    --scope "/subscriptions/{your-subscription-id}"

az role assignment create \
    --assignee {principal-id} \
    --role "Reader" \
    --scope "/subscriptions/{your-subscription-id}"

az role assignment create \
    --assignee {principal-id} \
    --role "Key Vault Secrets User" \
    --scope "/subscriptions/{your-subscription-id}/resourceGroups/{rg}/providers/Microsoft.KeyVault/vaults/{vault-name}"
```

---

### 🥉 Option 3: Service Principal + Client Secret (Legacy)

> ⚠️ **Not Recommended**: Only use this if OIDC and Managed Identity are not available.

```bash
az ad sp create-for-rbac \
    --name "AzureLocal-DeployAutomation" \
    --role "Azure Stack HCI Administrator" \
    --scopes /subscriptions/{your-subscription-id}
```

---

## Required Permissions

| Permission | Purpose |
|------------|---------|
| `Microsoft.AzureStackHCI/*` | Deploy and manage Azure Local clusters |
| `Microsoft.HybridCompute/machines/read` | Verify Arc node registration |
| `Microsoft.Resources/deployments/*` | Create and monitor ARM deployments |
| `Microsoft.Resources/subscriptions/resourceGroups/read` | Verify resource group exists |
| `Microsoft.Resources/subscriptions/providers/read` | Check resource provider registration status |
| `*/register/action` | Auto-register missing resource providers |
| `Microsoft.Authorization/roleAssignments/read` | Check RBAC role assignments (advisory) |
| `Microsoft.KeyVault/vaults/secrets/getSecret/action` | Retrieve deployment credentials |

The built-in **Azure Stack HCI Administrator** role covers most requirements. Add **Key Vault Secrets User** for credential access. The `*/register/action` permission (needed to auto-register resource providers) is **not** included in Azure Stack HCI Administrator — either pre-register all required providers before first deployment, or assign **Contributor** at subscription scope.

> **Note:** If all 12 required resource providers are already registered in your subscription (common for established environments), the `*/register/action` permission is not needed. The module checks registration status first and only attempts registration for providers that are not yet registered. See the [Azure Prerequisites](../README.md#azure-prerequisites) section in the main README for the full list of required providers and RBAC roles.

### Grant Access to Multiple Subscriptions

If clusters span multiple subscriptions, assign roles to each:

```bash
az role assignment create \
    --assignee "{app-id-or-principal-id}" \
    --role "Azure Stack HCI Administrator" \
    --scope "/subscriptions/{additional-subscription-id}"
```

---

## GitHub Actions Setup

### Step 1: Copy Workflow Files

Copy the YAML files from `github-actions/` to your repository's `.github/workflows/` directory:

```
.github/workflows/
├── validate-deployments.yml
├── deploy-clusters.yml
├── deployment-monitor.yml
└── deployment-status-report.yml
```

### Step 2: Add Repository Secrets

| Secret Name | Value |
|-------------|-------|
| `AZURE_CLIENT_ID` | App Registration / Service Principal ID |
| `AZURE_TENANT_ID` | Entra ID tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Default subscription ID |

### Step 3: Run

1. Go to **Actions** tab → **Validate Deployments** → **Run workflow**
2. Specify the CSV file path (defaults to `AzLocal.DeploymentAutomation/automation-pipelines/cluster-deployments.csv`)
3. Review pre-flight and validation results
4. If validation passes, run **Deploy Clusters**
5. Monitor progress via **Deployment Monitor** (runs automatically every 15 minutes)

---

## Azure DevOps Setup

### Step 1: Create Service Connection

1. Go to **Project Settings** → **Service connections**
2. Create an **Azure Resource Manager** service connection
3. Name it `AzureLocal-ServiceConnection` (or update the YAML files with your name)

### Step 2: Create Pipelines

1. Go to **Pipelines** → **New pipeline**
2. Select your repository
3. Choose **Existing Azure Pipelines YAML file**
4. Select each YAML from `AzLocal.DeploymentAutomation/automation-pipelines/azure-devops/`
5. Repeat for all four pipelines

### Step 3: Run

1. Run **Validate Deployments** pipeline
2. Review pre-flight and validation results in the **Tests** tab
3. If validation passes, run **Deploy Clusters** pipeline
4. **Deployment Monitor** and **Deployment Status Report** run automatically on their schedules

---

## PowerShell Functions

These pipelines use two exported functions from the `AzLocal.DeploymentAutomation` module:

> **Important:** In CI/CD pipelines, always pass `-NamingConfigPath` pointing to a config file checked into source control. Ephemeral CI agents do not have a persistent user profile, so the module's automatic user-profile config initialisation is not appropriate for pipelines.

### `Start-AzLocalCsvDeployment`

Reads a CSV file and submits ARM deployments for eligible clusters.

```powershell
# Validate all ready clusters
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -DeploymentMode 'Validate' `
    -JUnitOutputPath './reports/validate-results.xml' `
    -Confirm:$false

# Deploy all ready clusters
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -DeploymentMode 'Deploy' `
    -JUnitOutputPath './reports/deploy-results.xml' `
    -Confirm:$false

# Preview what would happen (WhatIf)
Start-AzLocalCsvDeployment `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -DeploymentMode 'Validate' `
    -WhatIf
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `CsvFilePath` | String | Yes | Path to the cluster deployments CSV file |
| `DeploymentMode` | String | Yes | `Validate` or `Deploy` |
| `NamingConfigPath` | String | | Path to `naming-standards-config.json` (recommended for CI/CD) |
| `JUnitOutputPath` | String | | Path to write JUnit XML results |
| `LogFilePath` | String | | Path to write log file |
| `WhatIf` | Switch | | Preview mode --- runs pre-flight checks without submitting deployments |
| `Confirm` | Switch | | Suppresses confirmation prompts when set to `$false` (e.g., `-Confirm:$false` for CI/CD) |

### `Get-AzLocalDeploymentStatus`

Monitors the status of deployments defined in a CSV file. Optionally generates HTML and Markdown reports.

```powershell
# Check status of all deployments
Get-AzLocalDeploymentStatus `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -JUnitOutputPath './reports/status-results.xml'

# Generate HTML + Markdown reports
Get-AzLocalDeploymentStatus `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -NamingConfigPath './AzLocal.DeploymentAutomation/.config/naming-standards-config.json' `
    -JUnitOutputPath './reports/status-results.xml' `
    -HtmlOutputPath './reports/deployment-status.html' `
    -MarkdownOutputPath './reports/deployment-status.md' `
    -ReportTitle 'Production Fleet Status'
```

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `CsvFilePath` | String | Yes | Path to the cluster deployments CSV file |
| `NamingConfigPath` | String | | Path to `naming-standards-config.json` (recommended for CI/CD) |
| `JUnitOutputPath` | String | | Path to write JUnit XML results |
| `HtmlOutputPath` | String | | Path to write a self-contained HTML status report |
| `MarkdownOutputPath` | String | | Path to write a Markdown status report (for GitHub Step Summary / Azure DevOps) |
| `ReportTitle` | String | | Custom title for the HTML/Markdown report header |
| `LogFilePath` | String | | Path to write log file |

**Status Values:**

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

---

## JUnit XML Reporting

All pipelines generate JUnit XML reports for CI/CD test result visibility:

- **GitHub Actions**: Uses [dorny/test-reporter](https://github.com/dorny/test-reporter) for rich test result display
- **Azure DevOps**: Uses `PublishTestResults@2` task for the Tests tab

Reports include per-cluster results with pass/fail/skip status and detailed messages.

---

## Folder Structure

```
automation-pipelines/
├── README.md                              # This file
├── cluster-deployments.csv                # Example CSV file
├── github-actions/
│   ├── validate-deployments.yml           # Stage 1: Pre-flight checks, Stage 2: ARM Validate
│   ├── deploy-clusters.yml                # Stage 2: ARM Deploy
│   ├── deployment-monitor.yml             # Scheduled status monitor (every 15 min)
│   └── deployment-status-report.yml       # HTML/Markdown status report (daily/weekly)
└── azure-devops/
    ├── validate-deployments.yml            # Stage 1: Pre-flight checks, Stage 2: ARM Validate
    ├── deploy-clusters.yml                 # Stage 2: ARM Deploy
    ├── deployment-monitor.yml             # Scheduled status monitor (every 15 min)
    └── deployment-status-report.yml       # HTML/Markdown status report (daily/weekly)
```

---

## Troubleshooting

### Common Issues

| Issue | Resolution |
|-------|------------|
| `CSV file not found` | Ensure the CSV path parameter matches the file location in your repository |
| `Arc nodes not registered` | Check that nodes appear in the expected resource group as `Microsoft.HybridCompute/machines` resources |
| `Resource group does not exist` | Create the resource group before running the pipeline: `az group create --name {rg-name} --location {location}` |
| `Resource provider registration failed` | The CI/CD identity lacks `*/register/action`. Either pre-register providers manually (`az provider register --namespace Microsoft.HybridCompute`, etc.) or grant **Contributor** at subscription scope. See [Required Permissions](#required-permissions). |
| `Key Vault access denied` | Ensure the pipeline identity has **Key Vault Secrets User** role on the vault |
| `OIDC token request failed` | Verify federated credential subject matches your workflow trigger (branch, environment, etc.) |
| `Deployment already in progress` | Wait for the current deployment to complete or cancel it before retrying |

### Viewing Detailed Logs

- **GitHub Actions**: Download the report artifacts from the workflow run
- **Azure DevOps**: Check the **Tests** tab and download build artifacts

---

## Deployment Status Report

The **Deployment Status Report** pipeline generates a self-contained HTML report and a Markdown summary of all cluster deployment statuses. This is designed for stakeholder visibility and fleet management dashboards.

### What the Report Contains

- **Summary cards** showing total, succeeded, failed, in-progress, and not-started counts
- **Progress bar** with color-coded segments showing overall fleet health
- **Cluster details table** with per-cluster status, resource group, provisioning state, and messages
- **Color-coded status badges** for quick visual scanning
- **Failed deployment details** section highlighting clusters that need attention

### Report Formats

| Format | Purpose | Where It Appears |
|--------|---------|------------------|
| **HTML** | Self-contained report for sharing, archiving, or embedding in dashboards | Workflow artifact (downloadable) |
| **Markdown** | Summary with status icons and tables | GitHub Step Summary / Azure DevOps build log |
| **JUnit XML** | Machine-readable test results | dorny/test-reporter (GitHub) / Tests tab (Azure DevOps) |

### Schedule

By default, the report runs **daily at 06:00 UTC**. You can adjust the cron schedule in the workflow YAML, or run it manually at any time.

```yaml
# Daily at 06:00 UTC (default)
- cron: '0 6 * * *'

# Every Monday and Thursday at 08:00 UTC
- cron: '0 8 * * 1,4'

# Weekly on Monday at 06:00 UTC
- cron: '0 6 * * 1'
```

### GitHub Actions Usage

1. Copy `deployment-status-report.yml` to `.github/workflows/`
2. Configure repository secrets (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`)
3. Run manually from **Actions** tab or wait for the daily schedule
4. View the Markdown summary in the **Step Summary** tab
5. Download the HTML report from the **Artifacts** section

### Azure DevOps Usage

1. Create a pipeline from `azure-devops/deployment-status-report.yml`
2. Ensure the service connection name matches (default: `AzureLocal-ServiceConnection`)
3. Run manually or wait for the daily schedule
4. View JUnit results in the **Tests** tab
5. Download the HTML report from **Build Artifacts**

### Custom Report Title

When triggering manually, you can specify a custom report title:

```powershell
# GitHub Actions: Use the report_title input when running the workflow
# Azure DevOps: Use the reportTitle parameter when running the pipeline

# PowerShell (local):
Get-AzLocalDeploymentStatus `
    -CsvFilePath './automation-pipelines/cluster-deployments.csv' `
    -HtmlOutputPath './reports/production-status.html' `
    -ReportTitle 'Production Fleet - Weekly Status'
```

### Monitor vs. Status Report

| Feature | Deployment Monitor | Deployment Status Report |
|---------|-------------------|-------------------------|
| **Frequency** | Every 15 minutes | Daily/weekly |
| **Purpose** | Track active deployments in real-time | Fleet status summary for stakeholders |
| **Outputs** | JUnit XML + Step Summary | HTML report + Markdown + JUnit XML |
| **Best for** | CI/CD dashboards during deployments | Management reporting, fleet health checks |
