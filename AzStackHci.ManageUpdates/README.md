# Azure Local - Managing Updates Module (AzStackHci.ManageUpdates)

**Latest Version:** v0.4.2

This folder contains the 'AzStackHci.ManageUpdates' PowerShell module for managing updates on Azure Local (Azure Stack HCI) clusters using the Azure Stack HCI REST API. The module supports both interactive use and CI/CD automation via Service Principal or Managed Identity authentication.

Azure Stack HCI REST API specification (includes update management endpoints): https://github.com/Azure/azure-rest-api-specs/blob/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/stable/2025-10-01/hci.json

## What's New in v0.4.2

### ðŸ“– Documentation
- Verified and documented that **all functions work with all three authentication methods**:
  1. **Interactive** - Standard user login via `az login`
  2. **Service Principal** - For CI/CD pipelines using `Connect-AzureLocalServicePrincipal`
  3. **Managed Identity (MSI)** - For Azure-hosted agents using `Connect-AzureLocalServicePrincipal -UseManagedIdentity`

---

## What's New in v0.4.1

### New Features
- **Managed Identity (MSI) Support**: `Connect-AzureLocalServicePrincipal` now supports Managed Identity authentication with `-UseManagedIdentity` switch, ideal for Azure-hosted runners, VMs, and containers

### Bug Fixes
- **CRITICAL**: Fixed Azure Resource Graph queries in `Get-AzureLocalClusterInventory`, `Start-AzureLocalClusterUpdate`, and `Get-AzureLocalClusterUpdateReadiness` that were returning incorrect resource types (mixed resources like networkInterfaces, virtualHardDisks instead of clusters only). The issue was caused by HERE-STRING query format causing malformed az CLI commands. Queries now use single-line string format.
- **CRITICAL**: Fixed `Set-AzureLocalClusterUpdateRingTag` failing with JSON deserialization errors when applying tags. Two issues were resolved:
  1. PowerShell/cmd.exe mangling JSON quotes when passed to `az rest --body` - now uses temp file with `@file` syntax
  2. PowerShell hashtable internal properties (`Keys`, `Values`, etc.) being included in JSON - now uses `[PSCustomObject]` with filtered `NoteProperty` members only

### Improvements
- `Get-AzureLocalClusterInventory` no longer dumps objects to console when using `-ExportCsvPath` (cleaner output with summary and next steps)
- Added `-PassThru` switch to `Get-AzureLocalClusterInventory` for CI/CD pipelines that need both CSV export AND returned objects

---

## What's New in v0.4.0

### New Features
- **Cluster Inventory Function**: New `Get-AzureLocalClusterInventory` function queries all clusters and their UpdateRing tag status
- **CSV-Based Tag Workflow**: Export inventory to CSV, edit UpdateRing values in Excel, then import back to apply tags
- **CSV Input for Tags**: `Set-AzureLocalClusterUpdateRingTag` now accepts `-InputCsvPath` for bulk tag operations
- **JUnit XML Export for CI/CD**: Export results to JUnit XML format for visualization in Azure DevOps, GitHub Actions, Jenkins, and other CI/CD tools

### Improvements
- Renamed `-ScopeByTagName` to `-ScopeByUpdateRingTag` (now a switch parameter for clarity)
- Renamed `-TagValue` to `-UpdateRingValue` for consistency
- UpdateRing tag queries now use the standardized 'UpdateRing' tag name
- `-ExportResultsPath` and `-ExportCsvPath` now support `.xml` extension for JUnit format

## Files

| File | Description |
|------|-------------|
| `AzStackHci.ManageUpdates.psd1` | PowerShell module manifest |
| `AzStackHci.ManageUpdates.psm1` | PowerShell module with functions to start updates on multiple Azure Local clusters |
| `example-update-request.json` | Example JSON showing API request/response structures for the Update Manager API |

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated
- **PowerShell** 5.1 or later (Desktop or Core edition)
- **Permissions**: Azure Stack HCI Administrator or equivalent role (see RBAC Requirements below)
- **Cluster Requirements**: Cluster must be in "Connected" status with updates available
- **For tag-based filtering**: Azure CLI `resource-graph` extension (automatically installed by the module when using `-ScopeByUpdateRingTag`)

## RBAC Requirements

To start updates on Azure Local clusters, users need specific permissions on the `Microsoft.AzureStackHCI` resource provider.

### Recommended Built-in Roles

| Role | Role ID | Description |
|------|---------|-------------|
| **Azure Stack HCI Administrator** | `bda0d508-adf1-4af0-9c28-88919fc3ae06` | Full access to cluster and resources, including updates |
| **Azure Stack HCI Device Management Role** | `865ae368-6a45-4bd1-8fbf-0d5151f56fc1` | Full cluster operations including updates |

### Specific Permissions Required

The following permissions are required for update operations:

| Operation | Required Permission |
|-----------|---------------------|
| Read cluster info | `Microsoft.AzureStackHCI/clusters/read` |
| Read update summary | `Microsoft.AzureStackHCI/clusters/updateSummaries/read` |
| List available updates | `Microsoft.AzureStackHCI/clusters/updates/read` |
| **Start/Apply update** | `Microsoft.AzureStackHCI/clusters/updates/apply/action` |
| Monitor update runs | `Microsoft.AzureStackHCI/clusters/updateRuns/read` |

### Roles That Do NOT Have Update Permissions

| Role | Reason |
|------|--------|
| Azure Stack HCI VM Contributor | Only has `clusters/read` - cannot apply updates |
| Azure Stack HCI VM Reader | Read-only access to VMs, no cluster update permissions |
| Contributor (generic) | Does not include `Microsoft.AzureStackHCI` permissions by default |

### Custom "Azure Stack HCI Update Operator" Role Definition (Least Privilege)

If you need a least-privilege custom role specifically for update operations:

```json
{
  "Name": "Azure Stack HCI Update Operator",
  "IsCustom": true,
  "Description": "Can view and apply updates on Azure Local clusters",
  "Actions": [
    "Microsoft.AzureStackHCI/clusters/read",
    "Microsoft.AzureStackHCI/clusters/updateSummaries/read",
    "Microsoft.AzureStackHCI/clusters/updates/read",
    "Microsoft.AzureStackHCI/clusters/updates/apply/action",
    "Microsoft.AzureStackHCI/clusters/updateRuns/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/{subscription-id}"
  ]
}
```

Save this JSON to a file named `custom-role.json`, then create the custom role using Azure CLI:

```powershell
# Option 1: Create the file manually, then run:
az role definition create --role-definition custom-role.json

# Option 2: Create the file and role in one step using PowerShell:
@'
{
  "Name": "Azure Stack HCI Update Operator",
  "IsCustom": true,
  "Description": "Can view and apply updates on Azure Local clusters",
  "Actions": [
    "Microsoft.AzureStackHCI/clusters/read",
    "Microsoft.AzureStackHCI/clusters/updateSummaries/read",
    "Microsoft.AzureStackHCI/clusters/updates/read",
    "Microsoft.AzureStackHCI/clusters/updates/apply/action",
    "Microsoft.AzureStackHCI/clusters/updateRuns/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/{subscription-id}"
  ]
}
'@ | Out-File -FilePath "custom-role.json" -Encoding UTF8

az role definition create --role-definition custom-role.json
```

### Assigning a Role

```powershell
# Assign Azure Stack HCI Administrator role to a user
az role assignment create `
  --assignee "user@contoso.com" `
  --role "Azure Stack HCI Administrator" `
  --scope "/subscriptions/{subscription-id}/resourceGroups/{resource-group}"
```

> **Reference**: [Azure built-in roles for Hybrid + multicloud](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/hybrid-multicloud)

## Quick Start

### 1. Authenticate to Azure

**Interactive Login (for manual use):**
```powershell
# Login to Azure (add --tenant <TenantId> if you have multiple tenants)
az login

# Optionally, set the subscription context
az account set --subscription "Your-Subscription-Name-or-Id"
```

**Service Principal Login (for CI/CD automation):**
```powershell
# Using environment variables (recommended for pipelines)
$env:AZURE_CLIENT_ID = 'your-app-id'
$env:AZURE_CLIENT_SECRET = 'your-secret'
$env:AZURE_TENANT_ID = 'your-tenant-id'

# Import module and authenticate
Import-Module .\AzStackHci.ManageUpdates.psd1
Connect-AzureLocalServicePrincipal

# Or use parameters directly (not recommended - prefer env vars)
Connect-AzureLocalServicePrincipal -ServicePrincipalId $appId -ServicePrincipalSecret $secret -TenantId $tenant
```

### 2. Import the Module

```powershell
# Import the module from the current directory
Import-Module .\AzStackHci.ManageUpdates.psd1

# Or import using the full path
Import-Module "C:\Path\To\AzureLocal-Manage-Updates-Using-AUM-APIs\AzStackHci.ManageUpdates.psd1"
```

### 3. Start an Update on a Single Cluster

```powershell
# Start update on a single cluster (will prompt for confirmation)
Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG"

# Start update without prompting (use with caution)
Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG" -Force
```

### 4. Start Updates on Multiple Clusters

```powershell
# Update multiple clusters in the same resource group
Start-AzureLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02", "Cluster03") -ResourceGroupName "MyRG"

# Update clusters (function will search across all resource groups)
Start-AzureLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02")
```

### 5. Start a Specific Update

```powershell
# Apply a specific update version
Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -UpdateName "Solution12.2601.1002.38"
```

### 6. Check Update Progress

```powershell
# Get update run status
Get-AzureLocalUpdateRuns -ClusterName "MyCluster01" -ResourceGroupName "MyRG"
```

## Available Functions

### `Connect-AzureLocalServicePrincipal`

Authenticates to Azure using a Service Principal or Managed Identity (MSI) for CI/CD automation scenarios.

**Authentication Methods:**
1. **Managed Identity** (`-UseManagedIdentity`): For Azure-hosted runners, VMs, or containers with an assigned identity
2. **Service Principal** (default): Using credentials from parameters or environment variables

**Parameters:**
- `-UseManagedIdentity` (Optional): Use Managed Identity authentication instead of Service Principal
- `-ManagedIdentityClientId` (Optional): Client ID of a user-assigned managed identity. If not specified, system-assigned identity is used.
- `-ServicePrincipalId` (Optional): Application (client) ID. Can also use `AZURE_CLIENT_ID` environment variable.
- `-ServicePrincipalSecret` (Optional): Client secret. Can also use `AZURE_CLIENT_SECRET` environment variable.
- `-TenantId` (Optional): Azure AD tenant ID. Can also use `AZURE_TENANT_ID` environment variable.
- `-Force` (Optional): Force re-authentication even if already logged in.

**Returns:** `$true` if authentication succeeded, `$false` otherwise.

**Examples:**

```powershell
# Using Managed Identity (recommended for Azure-hosted agents/runners)
Connect-AzureLocalServicePrincipal -UseManagedIdentity

# Using user-assigned Managed Identity with specific client ID
Connect-AzureLocalServicePrincipal -UseManagedIdentity -ManagedIdentityClientId "12345678-1234-1234-1234-123456789012"

# Using environment variables for Service Principal (recommended for CI/CD)
$env:AZURE_CLIENT_ID = 'your-app-id'
$env:AZURE_CLIENT_SECRET = 'your-secret'
$env:AZURE_TENANT_ID = 'your-tenant-id'
Connect-AzureLocalServicePrincipal

# Using parameters for Service Principal (not recommended - secrets may be logged)
Connect-AzureLocalServicePrincipal -ServicePrincipalId $appId -ServicePrincipalSecret $secret -TenantId $tenant
```

---

### `Start-AzureLocalClusterUpdate`

Main function to start updates on one or more Azure Local clusters.

**Parameters:**
- `-ClusterNames` (Required*): Array of cluster names to update. Use this OR `-ClusterResourceIds` OR `-ScopeByUpdateRingTag`.
- `-ClusterResourceIds` (Required*): Array of full Azure Resource IDs for clusters. Use this when clusters are in different resource groups. Resource IDs are validated before processing to ensure the format is correct, the resource exists, and you have the required permissions. Use this OR `-ClusterNames` OR `-ScopeByUpdateRingTag`.
- `-ScopeByUpdateRingTag` (Required*): Switch parameter to find clusters by their 'UpdateRing' tag value via Azure Resource Graph. Must be used with `-UpdateRingValue`. Use this OR `-ClusterNames` OR `-ClusterResourceIds`.
- `-UpdateRingValue` (Required*): The value of the 'UpdateRing' tag to match when using `-ScopeByUpdateRingTag`.
- `-ResourceGroupName` (Optional): Resource group containing the clusters (only used with `-ClusterNames`)
- `-SubscriptionId` (Optional): Azure subscription ID (defaults to current, only used with `-ClusterNames`)
- `-UpdateName` (Optional): Specific update name to apply
- `-ApiVersion` (Optional): API version (default: "2025-10-01")
- `-Force` (Optional): Skip confirmation prompts
- `-WhatIf` (Optional): Show what would happen without executing
- `-LogFolderPath` (Optional): Folder path for log files. Default: `C:\ProgramData\AzStackHci.ManageUpdates\`
- `-EnableTranscript` (Optional): Enable PowerShell transcript recording
- `-ExportResultsPath` (Optional): Export results to JSON (`.json`), CSV (`.csv`), or JUnit XML (`.xml`) file

**Examples using Resource IDs:**

```powershell
# Update clusters in different resource groups using Resource IDs
$resourceIds = @(
    "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
    "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
)
Start-AzureLocalClusterUpdate -ClusterResourceIds $resourceIds -Force
```

**Examples using Tags (Azure Resource Graph):**

```powershell
# Update all clusters tagged with "UpdateRing" = "Wave1" (across all subscriptions)
Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force

# Update all production clusters
Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Production" -Force

# Update clusters with specific UpdateRing and update version
Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Pilot" -UpdateName "Solution12.2601.1002.38" -Force
```

> **Prerequisites for Tag-based Filtering:**
> 
> 1. **Azure CLI `resource-graph` extension** (required for `-ScopeByUpdateRingTag`):
>    The module **automatically installs** this extension if it's missing (using `az extension add --name resource-graph --yes`). This enables fully automated pipeline scenarios without manual intervention.
>
> 2. **Set up UpdateRing tags on your clusters** (if you haven't already):
>    If you want to use `-ScopeByUpdateRingTag` but your clusters don't have `UpdateRing` tags yet, use the [`Get-AzureLocalClusterInventory`](#get-azurelocalclusterinventory) and [`Set-AzureLocalClusterUpdateRingTag`](#set-azurelocalclusterupdateringtag) functions:
>    ```powershell
>    # Option 1: Export inventory to CSV, edit in Excel, then import
>    Get-AzureLocalClusterInventory -ExportCsvPath "C:\Temp\ClusterInventory.csv"
>    # Edit the CSV in Excel to populate UpdateRing values, then:
>    Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"
>    
>    # Option 2: Set tags directly using Resource IDs
>    $ring1Clusters = @(
>        "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
>        "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
>    )
>    Set-AzureLocalClusterUpdateRingTag -ClusterResourceIds $ring1Clusters -UpdateRingValue "Wave1"
>    
>    # Then, update all Wave1 clusters
>    Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
>    ```

### `Get-AzureLocalClusterUpdateReadiness`

Assesses update readiness across Azure Local clusters and provides a summary report. This is a "pre-flight check" to help plan update deployments.

**Features:**
- Shows which clusters are in "Ready" state for updates
- Lists available and ready-to-install updates for each cluster
- Displays health check state and failures for each cluster
- Provides summary statistics with cluster counts per update version
- Identifies the most common applicable update across your fleet
- Shows clusters with health check issues and their failure reasons
- Exports results to CSV for reporting (includes all diagnostic columns)

**Parameters:**
- `-ClusterNames`, `-ClusterResourceIds`, or `-ScopeByUpdateRingTag`/`-UpdateRingValue` (same as `Start-AzureLocalClusterUpdate`)
- `-ExportCsvPath` (Optional): Export results to a CSV file

**Output Columns (and CSV Export):**
| Column | Description |
|--------|-------------|
| `ClusterName` | Name of the Azure Local cluster |
| `ResourceGroup` | Resource group containing the cluster |
| `SubscriptionId` | Azure subscription ID |
| `ClusterState` | Cluster connection state (e.g., "ConnectedRecently") |
| `UpdateState` | Current update state (e.g., "UpdateAvailable", "NeedsAttention") |
| `HealthState` | Health check state: "Success", "Warning", "Failure", or "InProgress" |
| `ReadyForUpdate` | Boolean indicating if the cluster is ready for updates |
| `AvailableUpdates` | List of available update names |
| `ReadyUpdates` | List of updates in "Ready" state |
| `RecommendedUpdate` | The recommended (latest) ready update |
| `HealthCheckFailures` | Summary of failed health checks with severity |

**Examples:**

```powershell
# Assess all clusters with a specific UpdateRing tag value
Get-AzureLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Wave1"

# Assess specific clusters and export to CSV
Get-AzureLocalClusterUpdateReadiness -ClusterNames @("Cluster01", "Cluster02") -ExportCsvPath "C:\Reports\readiness.csv"

# Assess clusters by UpdateRing tag across all subscriptions
Get-AzureLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Production"
```

**Sample Output:**

```
========================================
Azure Local Cluster Update Readiness Assessment
========================================

Assessing 5 cluster(s)...

  Checking: Cluster01... Ready (Solution12.2601.1002.38)
  Checking: Cluster02... Ready (Solution12.2601.1002.38)
  Checking: Cluster03... Update In Progress
  Checking: Cluster04... NeedsAttention (Failure)
  Checking: Cluster05... Ready (Solution12.2601.1002.38)

========================================
Summary
========================================

Total Clusters Assessed:    5
Ready for Update:           3
Not Ready / Other State:    2
Update In Progress:         1

Health Check Issues:
  Critical Failures:        1
  Warnings:                 0

Available Update Versions (clusters ready to install):
  Solution12.2601.1002.38: 3 cluster(s) (100%)

Most Common Applicable Update: Solution12.2601.1002.38

Detailed Results:

ClusterName   ResourceGroup  UpdateState       HealthState  ReadyForUpdate  RecommendedUpdate
-----------   -------------  -----------       -----------  --------------  -----------------
Cluster01     RG-West        UpdateAvailable   Success      True            Solution12.2601.1002.38
Cluster02     RG-West        UpdateAvailable   Success      True            Solution12.2601.1002.38
Cluster03     RG-East        UpdateInProgress  Success      False
Cluster04     RG-East        NeedsAttention    Failure      False
Cluster05     RG-North       UpdateAvailable   Success      True            Solution12.2601.1002.38

Clusters with Health Check Issues:
  Cluster04: [Critical] Test-CauSetup; [Warning] Test-ClusterQuorum
```

### `Get-AzureLocalClusterInfo`

Gets cluster information by name.

```powershell
$cluster = Get-AzureLocalClusterInfo -ClusterName "MyCluster" -SubscriptionId "xxx"
```

### `Get-AzureLocalUpdateSummary`

Gets the update summary for a cluster.

```powershell
$summary = Get-AzureLocalUpdateSummary -ClusterResourceId $cluster.id
Write-Host "Update State: $($summary.properties.state)"
```

### `Get-AzureLocalAvailableUpdates`

Lists all available updates for a cluster.

```powershell
$updates = Get-AzureLocalAvailableUpdates -ClusterResourceId $cluster.id
$updates | Where-Object { $_.properties.state -eq "Ready" }
```

### `Get-AzureLocalUpdateRuns`

Gets update run history and status.

```powershell
$runs = Get-AzureLocalUpdateRuns -ClusterName "MyCluster" -ResourceGroupName "MyRG"
$runs | Format-Table name, @{L='State';E={$_.properties.state}}, @{L='Started';E={$_.properties.timeStarted}}
```

### `Get-AzureLocalClusterInventory`

Gets an inventory of all Azure Local clusters with their UpdateRing tag status. This function is designed to support a CSV-based workflow for managing update rings.

**Features:**
- Queries all Azure Local clusters across all accessible subscriptions using Azure Resource Graph
- Shows the current UpdateRing tag value for each cluster (or indicates if tag doesn't exist)
- Retrieves subscription names for better readability
- Provides summary statistics showing UpdateRing distribution
- Exports to CSV for editing in Excel and re-importing with `Set-AzureLocalClusterUpdateRingTag`

**Parameters:**
- `-SubscriptionId` (Optional): Limit query to a specific Azure subscription
- `-ExportCsvPath` (Optional): Export inventory to CSV file for editing
- `-PassThru` (Optional): Return inventory objects even when exporting to CSV. Useful for CI/CD pipelines that need both the CSV artifact and objects for processing.

**Output Columns:**
| Column | Description |
|--------|-------------|
| `ClusterName` | Name of the Azure Local cluster |
| `ResourceGroup` | Resource group containing the cluster |
| `SubscriptionId` | Azure subscription ID |
| `SubscriptionName` | Human-readable subscription name |
| `UpdateRing` | Current UpdateRing tag value (empty if not set) |
| `HasUpdateRingTag` | "Yes" or "No" indicator |
| `ResourceId` | Full Azure Resource ID |

**CSV Workflow Examples:**

```powershell
# Step 1: Export inventory to CSV
Get-AzureLocalClusterInventory -ExportCsvPath "C:\Temp\ClusterInventory.csv"

# Step 2: Open the CSV in Excel and populate the 'UpdateRing' column with values like:
#   - "Wave1", "Wave2", "Wave3" for wave-based deployments
#   - "Pilot", "Production" for environment-based rings
#   - "Ring1", "Ring2" for ring-based deployments

# Step 3: Import the CSV and apply tags
Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"

# Step 4: Update clusters by their UpdateRing tag
Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
```

**CI/CD Pipeline Example (with -PassThru):**

```powershell
# Export to CSV AND return objects for pipeline processing
$inventory = Get-AzureLocalClusterInventory -ExportCsvPath "./artifacts/inventory.csv" -PassThru

# Use returned objects for pipeline logic
Write-Host "Total clusters: $($inventory.Count)"
$withoutTag = ($inventory | Where-Object { $_.HasUpdateRingTag -eq 'No' }).Count
Write-Host "Clusters needing UpdateRing tag: $withoutTag"
```

**Sample Output:**

```
========================================
Azure Local Cluster Inventory
========================================

Querying Azure Resource Graph for all Azure Local clusters...
  Querying across all accessible subscriptions
Found 5 Azure Local cluster(s)

Retrieving subscription details...

Inventory Summary:
  Total Clusters: 5
  Clusters with UpdateRing tag: 3
  Clusters without UpdateRing tag: 2

  UpdateRing Distribution:
    Wave1: 2 cluster(s)
    Wave2: 1 cluster(s)

Inventory exported to: C:\Temp\ClusterInventory.csv

Next Steps:
  1. Open the CSV in Excel
  2. Populate the 'UpdateRing' column with values (e.g., 'Wave1', 'Wave2', 'Pilot')
  3. Save the CSV file
  4. Run: Set-AzureLocalClusterUpdateRingTag -InputCsvPath 'C:\Temp\ClusterInventory.csv'
```

---

### `Set-AzureLocalClusterUpdateRingTag`

Sets or updates the "UpdateRing" tag on Azure Local clusters for organizing update deployment waves.

**Features:**
- **NEW**: Accepts CSV file input for bulk tag operations (`-InputCsvPath`)
- Validates that Resource IDs are valid `microsoft.azurestackhci/clusters` resources
- Checks if clusters already have an "UpdateRing" tag before applying
- Warns and skips clusters with existing tags unless `-Force` is specified
- Logs previous tag values when updating with `-Force`
- Outputs results to a timestamped CSV log file

**Parameters:**
- `-InputCsvPath` (Required*): Path to CSV file with ResourceId and UpdateRing columns. Use with output from `Get-AzureLocalClusterInventory`.
- `-ClusterResourceIds` (Required*): Array of full Azure Resource IDs for clusters to tag. Use this OR `-InputCsvPath`.
- `-UpdateRingValue` (Required*): Value to assign to the "UpdateRing" tag (required when using `-ClusterResourceIds`)
- `-Force` (Optional): Overwrite existing "UpdateRing" tags (logs previous value)
- `-LogFolderPath` (Optional): Folder path for log files. Default: `C:\ProgramData\AzStackHci.ManageUpdates\`
- `-WhatIf` (Optional): Preview changes without applying

**Output Columns (CSV Log: `UpdateRingTag_YYYYMMDD_HHmmss.csv`):**
| Column | Description |
|--------|-------------|
| `ClusterName` | Name of the Azure Local cluster |
| `ResourceGroup` | Resource group containing the cluster |
| `SubscriptionId` | Azure subscription ID |
| `ResourceId` | Full Azure Resource ID |
| `Action` | Action taken: "Created", "Updated", "Skipped", or "Error" |
| `PreviousTagValue` | Previous tag value (if updating existing tag) |
| `NewTagValue` | New tag value being set |
| `Status` | Result status: "Success", "Failed", "Skipped", or "WhatIf" |
| `Message` | Detailed status message |

**Examples:**

```powershell
# Import tags from a CSV file (preferred workflow)
Get-AzureLocalClusterInventory -ExportCsvPath "C:\Temp\ClusterInventory.csv"
# Edit CSV in Excel to set UpdateRing values, then:
Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"

# Set UpdateRing tag on multiple clusters directly
$resourceIds = @(
    "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
    "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02",
    "/subscriptions/xxx/resourceGroups/RG3/providers/Microsoft.AzureStackHCI/clusters/Cluster03"
)
Set-AzureLocalClusterUpdateRingTag -ClusterResourceIds $resourceIds -UpdateRingValue "Wave1"

# Preview changes without applying
Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -WhatIf

# Force update existing tags (logs previous values)
Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -Force

# Use with Start-AzureLocalClusterUpdate for wave-based deployments
# Step 1: Tag clusters for Wave1
Set-AzureLocalClusterUpdateRingTag -ClusterResourceIds $wave1Clusters -UpdateRingValue "Wave1"

# Step 2: Update only Wave1 clusters
Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
```

**Sample Output:**

```
========================================
Azure Local Cluster UpdateRing Tag Management
========================================

Log file: C:\ProgramData\AzStackHci.ManageUpdates\UpdateRingTag_20260129_091500.log
CSV log: C:\ProgramData\AzStackHci.ManageUpdates\UpdateRingTag_20260129_091500.csv
Input mode: CSV file
CSV path: C:\Temp\ClusterInventory.csv
Found 3 row(s) with UpdateRing values to process
Force mode: False
Clusters to process: 3

Azure CLI authentication verified

----------------------------------------
Processing: /subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01
Target UpdateRing: Wave1
----------------------------------------
Cluster: Cluster01
Resource Group: RG1
Subscription: xxx
Verifying cluster exists and retrieving current tags...
Cluster verified: Cluster01
No existing UpdateRing tag - will create new tag
Applying UpdateRing tag with value: 'Wave1'...
Successfully created UpdateRing tag

----------------------------------------
Processing: /subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02
Target UpdateRing: Wave2
----------------------------------------
Cluster: Cluster02
Existing UpdateRing tag found with value: 'Wave1'
Skipping cluster - use -Force to overwrite existing tag

========================================
Summary
========================================

Total clusters processed: 3
Tags created: 1
Tags updated: 0
Skipped (existing tag, no -Force): 1
Failed: 1

ClusterName Action  PreviousTagValue NewTagValue Status
----------- ------  ---------------- ----------- ------
Cluster01   Created                  Ring1       Success
Cluster02   Skipped Wave1            Ring1       Skipped
Cluster03   Skipped                  Ring1       Failed
```

## Logging and Output

The module includes comprehensive logging capabilities for tracking update operations.

### Log Files

By default, log files are created in `C:\ProgramData\AzStackHci.ManageUpdates\` which is accessible across different user profiles. This folder is automatically created if it doesn't exist.

When you run `Start-AzureLocalClusterUpdate`, the following files are automatically created:

| File | Description |
|------|-------------|
| `AzureLocalUpdate_YYYYMMDD_HHmmss.log` | Main log file with timestamped entries |
| `AzureLocalUpdate_YYYYMMDD_HHmmss_errors.log` | Separate error log (only created if errors occur) |
| `AzureLocalUpdate_YYYYMMDD_HHmmss_Update_Skipped.csv` | CSV of clusters where updates were skipped (not in Ready state) |
| `AzureLocalUpdate_YYYYMMDD_HHmmss_Update_Started.csv` | CSV of clusters where updates were successfully started |
| `AzureLocalUpdate_YYYYMMDD_HHmmss_transcript.log` | Full PowerShell transcript (if `-EnableTranscript` is used) |

#### CSV Summary Files

The `Update_Skipped.csv` and `Update_Started.csv` files provide a quick summary for reporting.

##### Update_Started.csv Columns

| Column | Description |
|--------|-------------|
| `ClusterName` | Name of the Azure Local cluster |
| `ResourceGroup` | Resource group containing the cluster |
| `SubscriptionId` | Azure subscription ID |
| `Message` | Status message (e.g., "Update Started: Solution12.2601.1002.38") |

##### Update_Skipped.csv Columns (Extended Diagnostics)

The skipped CSV includes additional diagnostic columns to help understand why clusters were not updated:

| Column | Description |
|--------|-------------|
| `ClusterName` | Name of the Azure Local cluster |
| `ResourceGroup` | Resource group containing the cluster |
| `SubscriptionId` | Azure subscription ID |
| `Message` | Status message explaining why the update was skipped |
| `UpdateState` | Current update state (e.g., "NeedsAttention", "UpdateFailed", "UpdateInProgress") |
| `HealthState` | Health check state: "Success", "Warning", "Failure", "InProgress", or "Unknown" |
| `HealthCheckFailures` | Summary of failed health checks with severity (e.g., "[Critical] StoragePool; [Warning] ClusterQuorum") |
| `LastUpdateErrorStep` | The specific step that failed in the last update run (if applicable) |
| `LastUpdateErrorMessage` | Error message from the last failed update step (truncated to 500 chars) |

This diagnostic information is sourced from:
- `healthCheckResult` property in the cluster's updateSummaries resource
- `progress.steps` property in the cluster's failed updateRuns (nested step traversal)

##### Example Update_Skipped.csv content:
```csv
"ClusterName","ResourceGroup","SubscriptionId","Message","UpdateState","HealthState","HealthCheckFailures","LastUpdateErrorStep","LastUpdateErrorMessage"
"Cluster01","RG-West","12345-abcd","Update Not started as Cluster NOT in Ready state (Current state: NeedsAttention)","NeedsAttention","Failure","[Critical] Test-CauSetup; [Warning] Test-VMNetAdapter","DownloadSBE","Failed to download SBE package from storage account."
"Cluster02","RG-East","12345-abcd","Update Not started as Cluster NOT in Ready state (Current state: UpdateInProgress)","UpdateInProgress","Success","","",""
"Cluster03","RG-North","12345-abcd","Update skipped by user","UpdateAvailable","Success","","",""
```

### Logging Examples

```powershell
# Basic logging (logs created in default folder: C:\ProgramData\AzStackHci.ManageUpdates\)
Start-AzureLocalClusterUpdate -ClusterNames "MyCluster" -Force

# Custom log folder location (auto-creates folder if needed)
Start-AzureLocalClusterUpdate -ClusterNames "MyCluster" -LogFolderPath "D:\Logs\Updates" -Force

# Enable transcript recording for complete console output capture
Start-AzureLocalClusterUpdate -ClusterNames "MyCluster" -EnableTranscript -Force

# Export results to JSON for automation/reporting
Start-AzureLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") -ExportResultsPath "C:\Logs\results.json" -Force

# Export results to CSV for Excel analysis
Start-AzureLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") -ExportResultsPath "C:\Logs\results.csv" -Force

# Full logging with all options
Start-AzureLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") `
    -LogFolderPath "D:\Logs\Updates" `
    -EnableTranscript `
    -ExportResultsPath "D:\Logs\Updates\results.json" `
    -Force
```

### Log Entry Format

Each log entry includes a timestamp and severity level:

```
[2026-01-28 14:30:45] [Info] Processing cluster: MyCluster01
[2026-01-28 14:30:46] [Success] Found cluster: /subscriptions/.../clusters/MyCluster01
[2026-01-28 14:30:47] [Warning] No updates in 'Ready' state for cluster 'MyCluster01'
[2026-01-28 14:30:48] [Error] Failed to start update on cluster 'MyCluster01'
```

### Results Export Format

**JSON Export** includes summary statistics:

```json
{
  "Timestamp": "2026-01-28 14:30:45",
  "TotalClusters": 3,
  "Succeeded": 2,
  "Failed": 0,
  "Skipped": 1,
  "Results": [...]
}
```

**CSV Export** includes one row per cluster with columns: ClusterName, Status, UpdateName, Duration, Message, StartTime, EndTime

## API Reference

The functions use the Azure Stack HCI REST API (version 2025-10-01):

| Operation | HTTP Method | Endpoint |
|-----------|-------------|----------|
| List Clusters | GET | `/subscriptions/{sub}/providers/Microsoft.AzureStackHCI/clusters` |
| Get Cluster | GET | `/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.AzureStackHCI/clusters/{cluster}` |
| Get Update Summary | GET | `...clusters/{cluster}/updateSummaries/default` |
| List Updates | GET | `...clusters/{cluster}/updates` |
| Get Update | GET | `...clusters/{cluster}/updates/{updateName}` |
| **Apply Update** | **POST** | `...clusters/{cluster}/updates/{updateName}/apply` |
| List Update Runs | GET | `...clusters/{cluster}/updates/{updateName}/updateRuns` |

## Update States

### Cluster Update Summary States

| State | Description | Can Start Update? |
|-------|-------------|-------------------|
| `UpdateAvailable` | Updates are available | ? Yes |
| `AppliedSuccessfully` | All updates applied | ? No updates to apply |
| `UpdateInProgress` | Update is running | ? Wait for completion |
| `UpdateFailed` | Last update failed | ?? Investigate first |
| `NeedsAttention` | Manual intervention needed | ? Resolve issues first |

### Individual Update States

| State | Description | Can Apply? |
|-------|-------------|------------|
| `Ready` | Update is ready to install | ? Yes |
| `ReadyToInstall` | Preparation complete | ? Yes |
| `HasPrerequisite` | Prerequisites required | ? Install prerequisites first |
| `Installing` | Currently installing | ? In progress |
| `Installed` | Successfully installed | ? Already done |
| `InstallationFailed` | Installation failed | ?? Retry or investigate |

## Using Azure CLI Directly

You can also use `az rest` commands directly:

```powershell
# List all clusters in subscription
az rest --method GET --uri "https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.AzureStackHCI/clusters?api-version=2025-10-01"

# Get update summary
az rest --method GET --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}/updateSummaries/default?api-version=2025-10-01"

# List available updates
az rest --method GET --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}/updates?api-version=2025-10-01"

# Apply an update (no body required)
az rest --method POST --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}/updates/{updateName}/apply?api-version=2025-10-01"
```

## Alternative: Az.StackHCI PowerShell Module

Microsoft also provides native PowerShell cmdlets in the `Az.StackHCI` module:

```powershell
# Install the module
Install-Module -Name Az.StackHCI -Force

# Apply an update
Invoke-AzStackHciUpdate -ClusterName 'MyCluster' -Name 'Solution12.2601.1002.38' -ResourceGroupName 'MyRG'
```

## CI/CD Automation

The module supports Service Principal authentication for use in automated pipelines, and can export results in **JUnit XML format** for test result visualization in CI/CD tools.

> ðŸ“ **Complete Pipeline Examples**: For production-ready CI/CD pipeline examples including inventory collection, tag management, and update deployment workflows, see the **[Automation-Pipeline-Examples](./Automation-Pipeline-Examples/README.md)** folder. It includes:
> - Complete GitHub Actions workflows (3 pipelines)
> - Complete Azure DevOps pipelines (3 pipelines)
> - Service Principal setup instructions
> - Typical automation workflow diagrams

### JUnit XML Export for CI/CD Pipelines

Use the `.xml` extension with `-ExportResultsPath` to generate JUnit-compatible test results for CI/CD toolchains:

```powershell
# Export update results to JUnit XML
Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Ring1" -Force `
    -ExportResultsPath "C:\Results\update-results.xml"

# Export readiness check to JUnit XML
Get-AzureLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Ring1" `
    -ExportCsvPath "C:\Results\readiness-results.xml"
```

**Supported CI/CD Tools:**

| CI/CD Tool | Integration |
|------------|-------------|
| **Azure DevOps** | Publish Test Results task |
| **GitHub Actions** | `dorny/test-reporter` or `mikepenz/action-junit-report` |
| **Jenkins** | Built-in JUnit plugin |
| **GitLab CI** | Native `artifacts:reports:junit` support |
| **TeamCity** | Built-in test report processing |

### GitHub Actions Example

```yaml
name: Update Azure Local Clusters

on:
  workflow_dispatch:
    inputs:
      update_ring:
        description: 'Update ring to target (e.g., Ring1, Ring2)'
        required: true
        default: 'Ring1'

jobs:
  update-clusters:
    runs-on: windows-latest
    
    steps:
    - name: Checkout repository
      uses: actions/checkout@v4
    
    - name: Install Azure CLI
      run: |
        Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi
        Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet'
    
    - name: Update Azure Local Clusters
      env:
        AZURE_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
        AZURE_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
        AZURE_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
      run: |
        Import-Module ./AzureLocal-Manage-Updates-Using-AUM-APIs/AzStackHci.ManageUpdates.psd1
        
        # Authenticate using Service Principal
        Connect-AzureLocalServicePrincipal
        
        # Update clusters by tag - export to JUnit XML for visualization
        Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "${{ github.event.inputs.update_ring }}" `
            -Force -ExportResultsPath "./test-results/update-results.xml"
    
    - name: Publish Test Results
      uses: dorny/test-reporter@v1
      if: always()
      with:
        name: Azure Local Update Results
        path: test-results/update-results.xml
        reporter: java-junit
```

### Azure DevOps Pipeline Example

```yaml
trigger: none

parameters:
- name: updateRing
  displayName: 'Update Ring'
  type: string
  default: 'Ring1'
  values:
  - Ring1
  - Ring2
  - Production

pool:
  vmImage: 'windows-latest'

steps:
- task: AzureCLI@2
  displayName: 'Update Azure Local Clusters'
  inputs:
    azureSubscription: 'Your-Service-Connection'
    scriptType: 'pscore'
    scriptLocation: 'inlineScript'
    inlineScript: |
      Import-Module $(System.DefaultWorkingDirectory)/AzureLocal-Manage-Updates-Using-AUM-APIs/AzStackHci.ManageUpdates.psd1
      
      # Azure CLI is already authenticated via the AzureCLI task
      # Update clusters by tag - export to JUnit XML
      Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "${{ parameters.updateRing }}" `
          -Force -ExportResultsPath "$(Build.ArtifactStagingDirectory)/update-results.xml"

- task: PublishTestResults@2
  displayName: 'Publish Update Results'
  condition: always()
  inputs:
    testResultsFormat: 'JUnit'
    testResultsFiles: '$(Build.ArtifactStagingDirectory)/update-results.xml'
    testRunTitle: 'Azure Local Cluster Updates - ${{ parameters.updateRing }}'
```

### Service Principal Setup

1. **Create a Service Principal:**
```bash
az ad sp create-for-rbac --name "AzureLocal-UpdateAutomation" --role "Azure Stack HCI Administrator" --scopes /subscriptions/{subscription-id}
```

2. **Store the credentials securely:**
   - **GitHub Actions**: Add `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AZURE_TENANT_ID` as repository secrets
   - **Azure DevOps**: Create a service connection with the Service Principal credentials

3. **Required permissions for the Service Principal:**
   - `Microsoft.AzureStackHCI/clusters/read`
   - `Microsoft.AzureStackHCI/clusters/updates/read`
   - `Microsoft.AzureStackHCI/clusters/updates/apply/action`
   - `Microsoft.AzureStackHCI/clusters/updateSummaries/read`
   - `Microsoft.AzureStackHCI/clusters/updateRuns/read`

## Troubleshooting

### Common Issues

1. **"Cluster not found"**: Verify the cluster name and ensure you have access to the subscription.

2. **"No updates available"**: The cluster may already be up to date. Check the update summary state.

3. **"Update not in Ready state"**: Updates may be downloading or have prerequisites. Check the update's state property.

4. **"Cluster not in valid state"**: The cluster must be "Connected" and the update summary state must be "UpdateAvailable".

5. **"Service Principal authentication failed"**: Verify the `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AZURE_TENANT_ID` values are correct and the Service Principal has the required permissions.

### Verbose Logging

Enable verbose output for debugging:

```powershell
Start-AzureLocalClusterUpdate -ClusterNames "MyCluster" -Verbose
```

## License

This code is provided as-is for educational and reference purposes.
