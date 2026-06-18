# AzLocal.UpdateManagement Cmdlet Reference

> **What you will find here:** Every exported cmdlet, organised first by single-cluster operations and then by fleet-scale (Get-AzLocalFleet*) operations, followed by an API-version reference. Each cmdlet entry shows the supported parameters, the ARM surface it calls, and a minimum-RBAC reminder.
>
> **Cross-reference:** The main [README.md](../README.md) shows only a single-line summary per cmdlet so it stays printable. Open this file for full signatures and examples.

---

## Available Functions

### Cmdlet Inventory & Design (Reads vs Writes)

This table is the canonical index of every public cmdlet the module ships. It is the answer to "what does each function actually do, and does it touch Azure?"

**Design principle.** This module is **ARG-first for READs and ARM-fan-out for WRITEs**. Read cmdlets converge on a single Azure Resource Graph query no matter how many clusters are in scope, so they finish in seconds and do not need parallelism (no `-ThrottleLimit` parameter). Write cmdlets still call ARM (or Azure REST) once per cluster - ARG is a read-only plane and cannot mutate resources - so write cmdlets keep `-ThrottleLimit` to bound concurrent fan-out. Composite cmdlets that only delegate to other module cmdlets inherit the type of the cmdlets they call.

**Type legend:**

- **READ** - calls only Azure Resource Graph and/or Azure REST GET. No state changes.
- **READ (composite)** - calls other READ cmdlets in this module, optionally writes a local report file.
- **READ (validation)** - evaluates local inputs (schedules, pipeline YAML); no Azure calls.
- **WRITE** - mutates Azure resources via ARM PUT/POST/PATCH or tag update.
- **WRITE (local)** - writes only to the local filesystem (scaffolding/templates).
- **AUTH** - establishes an Azure context; no data-plane calls.

#### Azure data-plane: READ cmdlets

| Cmdlet | Type | Target |
|---|---|---|
| [`Get-AzLocalClusterInfo`](#get-azlocalclusterinfo) | READ | Azure REST (single cluster lookup) |
| [`Get-AzLocalClusterInventory`](#get-azlocalclusterinventory) | READ | Azure Resource Graph |
| [`Get-AzLocalAvailableUpdates`](#get-azlocalavailableupdates) | READ | Azure Resource Graph |
| [`Get-AzLocalUpdateSummary`](#get-azlocalupdatesummary) | READ | Azure Resource Graph |
| [`Get-AzLocalUpdateRuns`](#get-azlocalupdateruns) | READ | Azure Resource Graph |
| `Get-AzLocalUpdateRunFailures` | READ | Azure Resource Graph |
| [`Get-AzLocalClusterUpdateReadiness`](#get-azlocalclusterupdatereadiness) | READ | Azure Resource Graph |
| [`Get-AzLocalFleetHealthFailures`](#get-azlocalfleethealthfailures) | READ | Azure Resource Graph |
| `Get-AzLocalFleetHealthOverview` | READ | Azure Resource Graph |
| `Get-AzLocalLatestSolutionVersion` | READ | Microsoft public catalog (`aka.ms/AzureEdgeUpdates`, unauthenticated) |
| [`Get-AzLocalFleetProgress`](#get-azlocalfleetprogress) | READ | Azure Resource Graph |
| [`Test-AzLocalClusterHealth`](#test-azlocalclusterhealth) | READ | Azure Resource Graph |
| [`Test-AzLocalFleetHealthGate`](#test-azlocalfleethealthgate) | READ (composite) | Azure (via `Test-AzLocalClusterHealth`) |
| [`Get-AzLocalFleetStatusData`](#get-azlocalfleetstatusdata) | READ (composite) | Azure (delegates to four READ cmdlets above) |
| [`New-AzLocalFleetStatusHtmlReport`](#new-azlocalfleetstatushtmlreport) | READ (composite) | Azure + local HTML report file |
| [`Export-AzLocalFleetState`](#export-azlocalfleetstate) | READ (composite) | Azure + local JSON state file |

#### Azure data-plane: WRITE cmdlets

| Cmdlet | Type | Target |
|---|---|---|
| [`Start-AzLocalClusterUpdate`](#start-azlocalclusterupdate) | **WRITE** | Azure REST (ARM `PUT .../updateRuns/{id}`) |
| [`Sync-AzLocalClusterUpdateSummary`](#sync-azlocalclusterupdatesummary) | **WRITE** | Azure REST (ARM `POST .../updateSummaries/default/checkUpdates`) |
| [`Stop-AzLocalFleetUpdate`](#stop-azlocalfleetupdate) | **WRITE** | Azure REST (ARM `POST .../updateRuns/{id}/cancel`) |
| [`Resume-AzLocalFleetUpdate`](#resume-azlocalfleetupdate) | **WRITE** | Azure REST (ARM `POST .../updateRuns/{id}/retry`) |
| [`Invoke-AzLocalFleetOperation`](#invoke-azlocalfleetoperation) | **WRITE** | Azure REST (generic per-cluster mutation) |
| [`Set-AzLocalClusterUpdateRingTag`](#set-azlocalclusterupdateringtag) | **WRITE** | Azure tags (`UpdateRing`, `UpdateStartWindow`) |
| [`Reset-AzLocalSideloadedTag`](#reset-azlocalsideloadedtag) | **WRITE** | Azure tags (`UpdateSideloaded`, `UpdateVersionInProgress`) |

#### Local-only validation and scaffolding

| Cmdlet | Type | Target |
|---|---|---|
| [`Test-AzLocalApplyUpdatesScheduleCoverage`](#test-azlocalapplyupdatesschedulecoverage) | READ (validation) | Local pipeline YAML + tag inputs |
| [`Test-AzLocalUpdateScheduleAllowed`](#test-azlocalupdatescheduleallowed) | READ (validation) | Local schedule input |
| [`Connect-AzLocalServicePrincipal`](#connect-azlocalserviceprincipal) | AUTH | Az PowerShell context (no data-plane calls) |
| [`Copy-AzLocalPipelineExample`](#copy-azlocalpipelineexample) | WRITE (local) | Local file scaffold |
| `Copy-AzLocalItsmSample` | WRITE (local) | Local file scaffold |

#### ITSM integration

| Cmdlet | Type | Target |
|---|---|---|
| `Get-AzLocalItsmConfig` | READ | Local ITSM config file |
| `Test-AzLocalItsmConnection` | READ | External ITSM endpoint |
| `New-AzLocalIncident` | **WRITE** | External ITSM (creates ticket) |

### `Copy-AzLocalPipelineExample`

Copies the bundled `Automation-Pipeline-Examples/` folder (GitHub Actions YAML, Azure DevOps Pipelines YAML, ITSM sample config + ticket-body template, plus the step-by-step setup README) out of the module install location into a destination folder you control. The function is read-only relative to the module install and only destructive relative to the destination (and only when `-Force` is supplied and the target is already populated).

**Parameters:**

- `-Destination` (Optional, Position 0): Target folder. If missing, it is created. Default is `$PWD`.
- `-Platform` (Optional): `All` (default), `GitHub`, or `AzureDevOps`. Filters which `*-actions/` / `*-devops/` subfolders are copied. The top-level `README.md` and `.itsm/` sample folder are platform-agnostic and always copied.
- `-Flatten` (Optional Switch): Copy contents directly into `-Destination` (no `Automation-Pipeline-Examples` parent folder).
- `-Force` (Optional Switch): Required if the destination already contains pipeline files; overwrites them.
- `-PassThru` (Optional Switch): Return the destination `[DirectoryInfo]`.
- Supports `-WhatIf` and `-Confirm`.

**Returns:** `[System.IO.DirectoryInfo]` when `-PassThru` is specified. Nothing otherwise. Always prints a short "next steps" summary to the console.

**Examples:**

```powershell
# Default (-Platform All): copies the full sample tree into
# .\Automation-Pipeline-Examples\ under the current directory (browse mode)
Copy-AzLocalPipelineExample

# Drop the GitHub Actions workflow YAML files DIRECTLY into .github\workflows\
# (no wrapper folder, no README, no .itsm). This is the canonical layout for a
# GitHub Actions runner, which only scans .github/workflows/*.yml non-recursively.
New-Item -ItemType Directory .\.github\workflows -Force | Out-Null
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub

# Same idea for Azure DevOps (ADO has no fixed-path convention)
New-Item -ItemType Directory .\pipelines -Force | Out-Null
Copy-AzLocalPipelineExample -Destination .\pipelines -Platform AzureDevOps

# Capture the destination and cd into it
$dest = Copy-AzLocalPipelineExample -Destination C:\repos\fleet -PassThru
Set-Location $dest
```

> By default the function refuses to overwrite any file that already exists in the destination - all conflicts are listed in the error message and the copy is aborted. To refresh after a module upgrade, pass `-Update`: you will be prompted per file (`Y` / `A` / `N` / `L` / `S` / `?`) before each overwrite. Use `-Update -Confirm:$false` to bypass the prompts in scripted / CI scenarios, or `-Update -WhatIf` to preview the changes. Pipeline files are expected to be under git source control so `git diff` gives you the post-overwrite safety net.
>
> ```powershell
> # Interactive refresh - prompt per file
> Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Update
>
> # Scripted / CI refresh - no prompts, review afterwards with 'git diff'
> Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Update -Confirm:$false
> ```

---

### `Connect-AzLocalServicePrincipal`

Authenticates to Azure using a Service Principal or Managed Identity (MSI) for CI/CD automation scenarios.

**Authentication Methods:**
1. **Managed Identity** (`-UseManagedIdentity`): For Azure-hosted runners, VMs, or containers with an assigned identity
2. **Service Principal** (default): Using credentials from parameters or environment variables

**Parameters:**
- `-UseManagedIdentity` (Optional): Use Managed Identity authentication instead of Service Principal
- `-ManagedIdentityClientId` (Optional): Client ID of a user-assigned managed identity. If not specified, system-assigned identity is used.
- `-ServicePrincipalId` (Optional): Application (client) ID. Can also use `AZURE_CLIENT_ID` environment variable.
- `-ServicePrincipalSecret` (Optional): Client secret as `[SecureString]` (preferred) or `[string]`. Can also use `AZURE_CLIENT_SECRET` environment variable. A security warning is logged when a plaintext `[string]` is passed because command-line arguments may be visible to other users/EDR on the host.
- `-TenantId` (Optional): Azure AD tenant ID. Can also use `AZURE_TENANT_ID` environment variable.
- `-Force` (Optional): Force re-authentication even if already logged in.

**Returns:** `$true` if authentication succeeded, `$false` otherwise.

**Examples:**

```powershell
# Using Managed Identity (recommended for Azure-hosted agents/runners)
Connect-AzLocalServicePrincipal -UseManagedIdentity

# Using user-assigned Managed Identity with specific client ID
Connect-AzLocalServicePrincipal -UseManagedIdentity -ManagedIdentityClientId "12345678-1234-1234-1234-123456789012"

# Using environment variables for Service Principal (recommended for CI/CD)
$env:AZURE_CLIENT_ID = 'your-app-id'
$env:AZURE_CLIENT_SECRET = 'your-secret'
$env:AZURE_TENANT_ID = 'your-tenant-id'
Connect-AzLocalServicePrincipal

# Using a SecureString for the secret (preferred when passing via parameter)
$secret = Read-Host -AsSecureString -Prompt 'Service Principal Secret'
Connect-AzLocalServicePrincipal -ServicePrincipalId $appId -ServicePrincipalSecret $secret -TenantId $tenant

# Plaintext [string] still works but logs a security warning - prefer SecureString or env var
Connect-AzLocalServicePrincipal -ServicePrincipalId $appId -ServicePrincipalSecret $secret -TenantId $tenant
```

> **Security note (Service Principal + secret path):** internally `Connect-AzLocalServicePrincipal` invokes `az login --service-principal --password <secret>`. The secret is materialised as a plaintext command-line argument for the duration of the `az login` call, which means on Windows it can be visible to other processes via the `Win32_Process.CommandLine` WMI surface (and likewise to EDR, audit, and process-creation logs). The module always tries the safer paths first (OIDC, Managed Identity, and only then SP) and clears the plaintext copy in a `finally` block, but you should still prefer **OIDC** or **Managed Identity** for any production runner. If you must use SP + secret, run on an isolated, EDR-aware host, keep secrets in `AZURE_CLIENT_SECRET` (env var) or a `[SecureString]` rather than a literal `[string]`, and rotate frequently.

---

### `Start-AzLocalClusterUpdate`

Main function to start updates on one or more Azure Local clusters.

**Parameters:**
- `-ClusterNames` (Required*): Array of cluster names to update. Use this OR `-ClusterResourceIds` OR `-ScopeByUpdateRingTag`.
- `-ClusterResourceIds` (Required*): Array of full Azure Resource IDs for clusters. Use this when clusters are in different resource groups or subscriptions. Resource IDs are validated before processing: the subscription is verified via `az account set`, and the resource is confirmed to exist with the required permissions. Use this OR `-ClusterNames` OR `-ScopeByUpdateRingTag`.
- `-ScopeByUpdateRingTag` (Required*): Switch parameter to find clusters by their 'UpdateRing' tag value via Azure Resource Graph. Must be used with `-UpdateRingValue`. Use this OR `-ClusterNames` OR `-ClusterResourceIds`.
- `-UpdateRingValue` (Required*): The value of the 'UpdateRing' tag to match when using `-ScopeByUpdateRingTag`.
- `-ResourceGroupName` (Optional): Resource group containing the clusters (only used with `-ClusterNames`)
- `-SubscriptionId` (Optional): Azure subscription ID (defaults to current, only used with `-ClusterNames`)
- `-UpdateName` (Optional): Specific update name to apply (e.g., `Solution12.2603.1002.15`). If not specified, the latest cumulative update is auto-selected by YYMM version from the update name
- `-ApiVersion` (Optional): API version (default: "2025-10-01")
- `-Force` (Optional): Skip confirmation prompts
- `-WhatIf` (Optional): Show what would happen without executing
- `-LogFolderPath` (Optional): Folder path for log files. Default: `C:\ProgramData\AzLocal.UpdateManagement\`
- `-EnableTranscript` (Optional): Enable PowerShell transcript recording
- `-ExportResultsPath` (Optional): Export results to JSON (`.json`), CSV (`.csv`), or JUnit XML (`.xml`) file

**Examples using Resource IDs:**

```powershell
# Update clusters in different resource groups using Resource IDs
$resourceIds = @(
    "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
    "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
)
Start-AzLocalClusterUpdate -ClusterResourceIds $resourceIds -Force
```

**Examples using Tags (Azure Resource Graph):**

```powershell
# Update all clusters tagged with "UpdateRing" = "Wave1" (across all subscriptions)
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force

# Update all production clusters
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Production" -Force

# Update clusters with specific UpdateRing and update version
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Pilot" -UpdateName "Solution12.2601.1002.38" -Force
```

> **Prerequisites for Tag-based Filtering:**
> 
> 1. **Azure CLI `resource-graph` extension** (required for `-ScopeByUpdateRingTag`):
>    The module **automatically installs** this extension if it's missing (using `az extension add --name resource-graph --yes`). This enables fully automated pipeline scenarios without manual intervention.
>
> 2. **Set up UpdateRing tags on your clusters** (if you haven't already):
>    If you want to use `-ScopeByUpdateRingTag` but your clusters don't have `UpdateRing` tags yet, use the [`Get-AzLocalClusterInventory`](#get-azlocalclusterinventory) and [`Set-AzLocalClusterUpdateRingTag`](#set-azlocalclusterupdateringtag) functions:
>    ```powershell
>    # Option 1: Export inventory to CSV, edit in Excel, then import
>    Get-AzLocalClusterInventory -ExportPath "C:\Temp\ClusterInventory.csv"
>    # Edit the CSV in Excel to populate UpdateRing values, then:
>    Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"
>    
>    # Option 2: Set tags directly using Resource IDs
>    $ring1Clusters = @(
>        "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
>        "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
>    )
>    Set-AzLocalClusterUpdateRingTag -ClusterResourceIds $ring1Clusters -UpdateRingValue "Wave1"
>    
>    # Then, update all Wave1 clusters
>    Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
>    ```

### `Get-AzLocalClusterUpdateReadiness`

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
- `-ClusterNames`, `-ClusterResourceIds`, or `-ScopeByUpdateRingTag`/`-UpdateRingValue` (same as `Start-AzLocalClusterUpdate`)
- `-ExportPath` (Optional): Export results to a CSV file

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
| `AllAvailableUpdates` | All available update names (every state - Ready, NotReady, Installed, etc.). _Renamed from `AvailableUpdates` in v0.7.99._ |
| `ReadyUpdates` | List of updates in "Ready" state |
| `RecommendedUpdate` | The recommended (latest) ready update |
| `HealthCheckFailures` | Summary of failed health checks with severity |

**Examples:**

```powershell
# Assess all clusters with a specific UpdateRing tag value
Get-AzLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Wave1"

# Assess specific clusters and export to CSV
Get-AzLocalClusterUpdateReadiness -ClusterNames @("Cluster01", "Cluster02") -ExportPath "C:\Reports\readiness.csv"

# Assess clusters by UpdateRing tag across all subscriptions
Get-AzLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Production"
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
Up to Date:                 0
Not Ready for Update:       2
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

### `Get-AzLocalClusterInfo`

Gets cluster information by name.

```powershell
$cluster = Get-AzLocalClusterInfo -ClusterName "MyCluster" -SubscriptionId "xxx"
```

### `Get-AzLocalUpdateSummary`

Gets the update summary for a cluster.

```powershell
$summary = Get-AzLocalUpdateSummary -ClusterResourceId $cluster.id
Write-Host "Update State: $($summary.properties.state)"
```

### `Sync-AzLocalClusterUpdateSummary`

**WRITE.** Triggers a fresh "Check for updates" scan on one or more clusters by POSTing to the cluster's `updateSummaries/default/checkUpdates` ARM action - the programmatic equivalent of the Azure portal **Check for updates** button. Use it to remediate a **stale assessment**: a cluster that reports "Up to date" while a newer solution version is actually available, because its cached assessment has not refreshed. Clusters are selected by name, by Resource ID, or by `UpdateRing` tag (mirroring `Start-AzLocalClusterUpdate`).

The action is asynchronous on the ARM side (202 Accepted). By default the cmdlet is fire-and-forget (returns a `Triggered` result per cluster immediately, so an offline or busy cluster cannot stall a fleet run). Pass `-Wait` to poll each cluster's `updateSummaries/default` until `lastChecked` advances (or `-TimeoutSeconds` elapses) and attach the refreshed summary to the result object.

> **Preview API / RBAC note:** `checkUpdates` is exposed only on the `2026-03-01-preview` API surface. The RBAC action Azure enforces for it - `Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action` - is **not yet published in the `Microsoft.AzureStackHCI` provider operations catalog** (checked 2026-06-18 with `az provider operation show`), so it **cannot be added to a custom role today** and the least-privilege `Azure Stack HCI Update Operator (custom)` role deliberately omits it (see [rbac.md](rbac.md)). Under that role the call returns a non-fatal `403 AuthorizationFailed`; built-in roles granting the broad `Microsoft.AzureStackHCI/clusters/*` wildcard (e.g. **Azure Stack HCI Administrator**) or **Contributor** authorize it. **The action will be added to the custom role once it GAs into the operations catalog.**

Key parameters:

- `-ClusterNames` / `-ClusterResourceIds` / `-ScopeByUpdateRingTag` + `-UpdateRingValue` - cluster selection (one set, mutually exclusive).
- `-ResourceGroupName`, `-SubscriptionId` - scope (defaults to the current `az` CLI subscription).
- `-ApiVersion` - REST API version for both the POST and the poll (default `2026-03-01-preview`).
- `-Wait`, `-TimeoutSeconds` (default 300), `-PollIntervalSeconds` (default 15) - synchronous completion polling.
- `-Force` - skip the confirmation prompt (state-changing action).
- `-PassThru` - emit a result object per cluster.

```powershell
# Fire-and-forget: trigger a fresh scan on one cluster
Sync-AzLocalClusterUpdateSummary -ClusterNames "Sydney" -ResourceGroupName "Prod-RG" -Force

# Trigger and wait for the refreshed summary
Sync-AzLocalClusterUpdateSummary -ClusterNames "Sydney" -Wait -PassThru

# Refresh every cluster tagged UpdateRing=Production
Sync-AzLocalClusterUpdateSummary -ScopeByUpdateRingTag -UpdateRingValue "Production" -Force
```

### `Get-AzLocalAvailableUpdates`

Lists all available updates for a cluster with enriched state information including SBE dependency details.

```powershell
# Get enriched update objects (default) - includes PackageType, SBEDependency, UpdateState
$updates = Get-AzLocalAvailableUpdates -ClusterResourceId $cluster.id
$updates | Where-Object { $_.UpdateState -eq "Ready" }

# Get raw ARM API objects for programmatic processing
$raw = Get-AzLocalAvailableUpdates -ClusterResourceId $cluster.id -Raw
$raw | Where-Object { $_.properties.state -eq "Ready" }
```

### `Get-AzLocalUpdateRuns`

Gets update run history and status for one or more clusters. Returns formatted objects showing the update name, state, duration, step progress, and current/failed step.

**Parameters:**
- `-ClusterName` (Required*): Single cluster name (original behavior)
- `-ClusterNames`, `-ClusterResourceIds`, or `-ScopeByUpdateRingTag`/`-UpdateRingValue`: Multi-cluster mode
- `-ResourceGroupName` (Optional): Resource group (only with `-ClusterName`/`-ClusterNames`)
- `-UpdateName` (Optional): Filter runs for a specific update
- `-Latest` (Optional): Return only the most recent update run per cluster
- `-Raw` (Optional): Return raw API response objects instead of formatted output
- `-ExportPath` (Optional): Export results to CSV, JSON, or JUnit XML

**Output Properties:**
| Property | Description |
|----------|-------------|
| `UpdateName` | The update package name (e.g., `Solution12.2603.1002.500`) |
| `State` | Current state: `InProgress`, `Succeeded`, `Failed`, etc. |
| `StartTime` | When the update run started |
| `Duration` | How long the update took, human-readable (e.g., `2 hours 30 minutes`, `45 minutes (running)`) |
| `Progress` | Step completion (e.g., `3/5 steps`) |
| `CurrentStep` | Currently executing or failed step name |

**Examples:**

```powershell
# Get all update runs for a cluster
Get-AzLocalUpdateRuns -ClusterName "MyCluster" -ResourceGroupName "MyRG"

# Get only the latest update run
Get-AzLocalUpdateRuns -ClusterName "MyCluster" -Latest

# Get raw API response for programmatic processing
Get-AzLocalUpdateRuns -ClusterName "MyCluster" -Raw

# Multi-cluster: Get latest run for all clusters in an update ring
Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Latest

# Export update run history to CSV
Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue "Production" -Latest -ExportPath "C:\Reports\runs.csv"
```

**Sample Output:**
```
UpdateName                State       StartTime        EndTime          Duration               Progress    CurrentStep
----------                -----       ---------        -------          --------               --------    -----------
Solution12.2603.1002.500  InProgress  2026-04-09 16:50                  1 hour 12 minutes      3/5 steps   DownloadSBE
Solution12.2602.1002.501  Succeeded   2026-03-15 09:00 2026-03-15 11:30 2 hours 30 minutes     5/5 steps
```

### `Test-AzLocalClusterHealth`

Validates cluster health before applying updates by checking for blocking health check failures. Critical failures prevent updates from being applied.

**Parameters:**
- `-ClusterResourceIds`, `-ClusterNames`, or `-ScopeByUpdateRingTag`/`-UpdateRingValue`: Target clusters
- `-BlockingOnly` (Optional): Show only Critical severity failures (the ones that block updates)
- `-ExportPath` (Optional): Export results to CSV, JSON, or JUnit XML

**Examples:**

```powershell
# Check health for a single cluster
Test-AzLocalClusterHealth -ClusterResourceIds @("/subscriptions/.../clusters/Seattle")

# Check only update-blocking issues for an update ring
Test-AzLocalClusterHealth -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -BlockingOnly

# Export health results to CSV
Test-AzLocalClusterHealth -ClusterNames @("Cluster01", "Cluster02") -ExportPath "C:\Reports\health.csv"
```

**Sample Output:**
```
========================================
Health Validation Summary
========================================
Total Clusters:  1
Passed:          0 (no critical failures)
Blocked:         1 (critical failures present)

Health Check Failures:

ClusterName  Severity  CheckName           Description
-----------  --------  ---------           -----------
Seattle      Critical  Test-CauSetup       CAU is not configured correctly
Seattle      Critical  Test-StoragePool    Storage pool health degraded

Remediation for Critical (Update-Blocking) Failures:
  Seattle - Test-CauSetup: Run Test-CauSetup on the cluster to validate CAU configuration
  Seattle - Test-StoragePool: Check storage pool health using Get-StoragePool

HEALTH VALIDATION FAILED - Critical health issues must be resolved before updates can proceed
```

> **Note**: `Start-AzLocalClusterUpdate` automatically runs this check (Step 3b) before applying updates. If Critical failures are found, the cluster is skipped with detailed diagnostics.

---

### `Get-AzLocalClusterInventory`

Gets an inventory of all Azure Local clusters with their UpdateRing tag status. This function supports both CSV and JSON export formats for different workflows.

**Features:**
- Queries all Azure Local clusters across all accessible subscriptions using Azure Resource Graph
- Shows the current UpdateRing tag value for each cluster (or indicates if tag doesn't exist)
- Retrieves subscription names for better readability
- Provides summary statistics showing UpdateRing distribution
- **CSV export**: For editing in Excel and re-importing with `Set-AzLocalClusterUpdateRingTag`
- **JSON export**: For CI/CD pipelines, API integrations, dashboards, and CMDB systems

**Parameters:**
- `-SubscriptionId` (Optional): Limit query to a specific Azure subscription
- `-ExportPath` (Optional): Export inventory to CSV or JSON file. Format is auto-detected from file extension (`.csv` or `.json`)
- `-PassThru` (Optional): Return inventory objects even when exporting. Useful for CI/CD pipelines that need both the file artifact and objects for processing.

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

**CSV Workflow (for Excel editing):**

```powershell
# Step 1: Export inventory to CSV
Get-AzLocalClusterInventory -ExportPath "C:\Temp\ClusterInventory.csv"

# Step 2: Open the CSV in Excel and populate the 'UpdateRing' column with values like:
#   - "Wave1", "Wave2", "Wave3" for wave-based deployments
#   - "Pilot", "Production" for environment-based rings
#   - "Ring1", "Ring2" for ring-based deployments

# Step 3: Import the CSV and apply tags
Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"

# Step 4: Update clusters by their UpdateRing tag
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
```

**JSON Export (for CI/CD and integrations):**

```powershell
# Export to JSON for API integrations, dashboards, or CMDB systems
Get-AzLocalClusterInventory -ExportPath "C:\Reports\inventory.json"

# Export to JSON AND return objects for pipeline processing
$inventory = Get-AzLocalClusterInventory -ExportPath "./artifacts/inventory.json" -PassThru
Write-Host "Total clusters: $($inventory.Count)"
```

**CI/CD Pipeline Example (export both formats):**

```powershell
# Export both CSV and JSON in CI/CD pipelines
# CSV: For human review and Excel editing workflow
Get-AzLocalClusterInventory -ExportPath "./artifacts/inventory.csv"

# JSON: For dashboard integrations and programmatic processing
$inventory = Get-AzLocalClusterInventory -ExportPath "./artifacts/inventory.json" -PassThru
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

Inventory exported to CSV: C:\Temp\ClusterInventory.csv

Next Steps (CSV export):
  1. Open the CSV in Excel
  2. Populate the 'UpdateRing' column with values (e.g., 'Wave1', 'Wave2', 'Pilot')
  3. Save the CSV file
  4. Run: Set-AzLocalClusterUpdateRingTag -InputCsvPath 'C:\Temp\ClusterInventory.csv'
```

---

### `Set-AzLocalClusterUpdateRingTag`

Sets or updates the "UpdateRing" tag on Azure Local clusters for organizing update deployment waves.

**Features:**
- **NEW**: Accepts CSV file input for bulk tag operations (`-InputCsvPath`)
- Validates that Resource IDs are valid `microsoft.azurestackhci/clusters` resources
- Checks if clusters already have an "UpdateRing" tag before applying
- Steady-state clusters (existing tag value already matches the target) are logged as `AlreadyInSync` / `NoChange` and skipped silently - no warning, no ARM PATCH
- Clusters whose existing `UpdateRing` tag value differs from the target are warned and skipped unless `-Force` is specified
- `-Force` short-circuits when all managed tags already match desired state (no wasted ARM PATCH on already-clean fleets)
- Logs previous tag values when updating with `-Force`
- Outputs results to a timestamped CSV log file; opt-in `-PassThru` returns the same rows as objects for pipeline consumption

**Parameters:**
- `-InputCsvPath` (Required*): Path to CSV file with ResourceId and UpdateRing columns. Use with output from `Get-AzLocalClusterInventory`.
- `-ClusterResourceIds` (Required*): Array of full Azure Resource IDs for clusters to tag. Use this OR `-InputCsvPath`.
- `-UpdateRingValue` (Required*): Value to assign to the "UpdateRing" tag (required when using `-ClusterResourceIds`)
- `-Force` (Optional): Overwrite existing "UpdateRing" tags (logs previous value)
- `-LogFolderPath` (Optional): Folder path for log files. Default: `C:\ProgramData\AzLocal.UpdateManagement\`
- `-WhatIf` (Optional): Preview changes without applying

**Output Columns (CSV Log: `UpdateRingTag_YYYYMMDD_HHmmss.csv`):**
| Column | Description |
|--------|-------------|
| `ClusterName` | Name of the Azure Local cluster |
| `ResourceGroup` | Resource group containing the cluster |
| `SubscriptionId` | Azure subscription ID |
| `ResourceId` | Full Azure Resource ID |
| `Action` | Action taken: `Created`, `Updated`, `NoChange`, `Skipped`, or `Error` |
| `PreviousTagValue` | Previous tag value (if updating existing tag) |
| `NewTagValue` | New tag value being set |
| `Status` | Result status: `Success`, `AlreadyInSync`, `Failed`, `Skipped`, or `WhatIf` |
| `Message` | Detailed status message |

**Examples:**

```powershell
# Import tags from a CSV file (preferred workflow)
Get-AzLocalClusterInventory -ExportPath "C:\Temp\ClusterInventory.csv"
# Edit CSV in Excel to set UpdateRing values, then:
Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"

# Set UpdateRing tag on multiple clusters directly
$resourceIds = @(
    "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
    "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02",
    "/subscriptions/xxx/resourceGroups/RG3/providers/Microsoft.AzureStackHCI/clusters/Cluster03"
)
Set-AzLocalClusterUpdateRingTag -ClusterResourceIds $resourceIds -UpdateRingValue "Wave1"

# Preview changes without applying
Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -WhatIf

# Force update existing tags (logs previous values)
Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -Force

# Use with Start-AzLocalClusterUpdate for wave-based deployments
# Step 1: Tag clusters for Wave1
Set-AzLocalClusterUpdateRingTag -ClusterResourceIds $wave1Clusters -UpdateRingValue "Wave1"

# Step 2: Update only Wave1 clusters
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
```

**Sample Output:**

```
========================================
Azure Local Cluster UpdateRing Tag Management
========================================

Log file: C:\ProgramData\AzLocal.UpdateManagement\UpdateRingTag_20260129_091500.log
CSV log: C:\ProgramData\AzLocal.UpdateManagement\UpdateRingTag_20260129_091500.csv
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
Skipping cluster - UpdateRing differs from target; use -Force to overwrite existing tag

----------------------------------------
Processing: /subscriptions/xxx/resourceGroups/RG3/providers/Microsoft.AzureStackHCI/clusters/Cluster03
Target UpdateRing: Wave1
----------------------------------------
Cluster: Cluster03
Existing UpdateRing tag found with value: 'Wave1'
All managed tags already match desired state - no action needed

========================================
Summary
========================================

Total clusters processed: 3
Tags created: 1
Tags updated: 0
Already in sync (no change needed): 1
Skipped (UpdateRing differs, no -Force): 1
Failed: 0

ClusterName Action   PreviousTagValue NewTagValue Status
----------- ------   ---------------- ----------- ------
Cluster01   Created                   Wave1       Success
Cluster02   Skipped  Wave1            Wave2       Skipped
Cluster03   NoChange Wave1            Wave1       AlreadyInSync
```

---

## Fleet-Scale Operations

The following six functions enable enterprise-scale update management across fleets of 1000-3000+ clusters with batching, throttling, retry logic, health gates, and state management. Originally introduced in v0.5.6 and extended through subsequent releases (parallelism + paginated ARG in v0.7.0, sideloaded payload workflow in v0.7.1, ThrottleLimit-safe private-helper dispatch in v0.7.2).

### `Invoke-AzLocalFleetOperation`

Orchestrates fleet-wide update operations with enterprise-scale features including batch processing, throttling, and automatic retry with exponential backoff.

**Features:**
- **Batch Processing**: Process clusters in configurable batches (default: 50 clusters)
- **Throttling**: Control parallel execution (default: 10 concurrent operations)
- **Retry Logic**: Automatic retries with exponential backoff (default: 3 retries)
- **State Management**: Checkpoint/resume capability via state files
- **Progress Tracking**: Real-time status updates during execution

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Operation` | String | No | `ApplyUpdate` | Operation to perform: `ApplyUpdate`, `CheckReadiness`, or `GetStatus` |
| `-ScopeByUpdateRingTag` | Switch | Yes* | - | Target clusters by UpdateRing tag |
| `-UpdateRingValue` | String | Yes* | - | The UpdateRing tag value to filter by |
| `-ClusterResourceIds` | String[] | Yes* | - | Explicit list of cluster resource IDs |
| `-UpdateName` | String | No | - | Specific update version to apply |
| `-BatchSize` | Int | No | `50` | Clusters per batch (1-500) |
| `-ThrottleLimit` | Int | No | `10` | Max parallel operations per batch (1-50) |
| `-DelayBetweenBatchesSeconds` | Int | No | `30` | Seconds to wait between batches (0-600) |
| `-MaxRetries` | Int | No | `3` | Retry attempts per cluster (0-10) |
| `-RetryDelaySeconds` | Int | No | `30` | Base delay between retries - uses exponential backoff (5-300) |
| `-StateFilePath` | String | No | - | Path to save state for resume capability |
| `-Force` | Switch | No | - | Skip confirmation prompts |
| `-PassThru` | Switch | No | - | Return the fleet state object |

*One of `-ScopeByUpdateRingTag`/`-UpdateRingValue` OR `-ClusterResourceIds` is required.

**Examples:**

```powershell
# Start updates on all Wave1 clusters with default settings
Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force

# Large fleet with increased batching and parallelism
Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Production" `
    -BatchSize 100 -ThrottleLimit 20 -DelayBetweenBatchesSeconds 60 -Force

# Save state for resume capability
$state = Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Ring1" `
    -StateFilePath "C:\Logs\ring1-state.json" -Force -PassThru

# Check readiness across fleet (no updates applied)
Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Canary" `
    -Operation CheckReadiness

# Apply specific update version
Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Pilot" `
    -UpdateName "Solution12.2601.1002.38" -Force
```

**Sample Output:**

```
========================================
Fleet Operation: ApplyUpdate
Run ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
========================================
Configuration:
  Batch Size: 50
  Throttle Limit: 10
  Delay Between Batches: 30 seconds
  Max Retries: 3

Querying clusters with UpdateRing = 'Wave1'...
Total clusters to process: 150

========================================
Batch 1 of 3 (50 clusters)
========================================
Processing: Cluster001
  ✓ Cluster001 - Succeeded
Processing: Cluster002
  ✓ Cluster002 - Succeeded
...

========================================
Fleet Operation Complete
========================================
Run ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
Duration: 45.2 minutes
Total Clusters: 150
Succeeded: 147
Failed: 3
```

---

### `Get-AzLocalFleetProgress`

Gets real-time progress of a fleet-wide update operation with aggregated statistics and optional per-cluster details.

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-State` | PSCustomObject | No | - | Fleet operation state object from `Invoke-AzLocalFleetOperation` |
| `-ScopeByUpdateRingTag` | Switch | Yes* | - | Query clusters by UpdateRing tag |
| `-UpdateRingValue` | String | Yes* | - | The UpdateRing tag value to filter by |
| `-Detailed` | Switch | No | - | Include per-cluster status in output |

*Either `-State` OR `-ScopeByUpdateRingTag`/`-UpdateRingValue` is required.

**Output Properties:**
| Property | Description |
|----------|-------------|
| `Timestamp` | When the progress was checked |
| `TotalClusters` | Total clusters in scope |
| `Completed` | Clusters that have finished (succeeded + up to date) |
| `ProgressPercent` | Completion percentage |
| `Succeeded` | Clusters where update succeeded |
| `UpToDate` | Clusters already up to date |
| `InProgress` | Clusters with updates currently running |
| `Failed` | Clusters where update failed |
| `NotStarted` | Clusters not yet processed |
| `ClusterStatuses` | Per-cluster details (when `-Detailed` used) |

**Examples:**

```powershell
# Check progress during an operation
Get-AzLocalFleetProgress -State $fleetState

# Check progress for all Production clusters
Get-AzLocalFleetProgress -ScopeByUpdateRingTag -UpdateRingValue "Production"

# Get detailed per-cluster status
Get-AzLocalFleetProgress -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Detailed

# Monitor in a loop
while ($true) {
    $progress = Get-AzLocalFleetProgress -ScopeByUpdateRingTag -UpdateRingValue "Wave1"
    if ($progress.InProgress -eq 0) { break }
    Start-Sleep -Seconds 60
}
```

**Sample Output:**

```
========================================
Fleet Update Progress Check
========================================

Checking status of 150 cluster(s)...

Progress Summary:
  Total Clusters: 150
  Completed: 135 (90%)
  - Succeeded: 130
  - Up to Date: 5
  In Progress: 10
  Failed: 3
  Not Started: 2
```

---

### `Test-AzLocalFleetHealthGate`

Evaluates fleet health to determine if it's safe to proceed with additional update waves. Acts as a "gate" in CI/CD pipelines to prevent cascading failures.

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-State` | PSCustomObject | No | - | Fleet operation state to evaluate |
| `-ScopeByUpdateRingTag` | Switch | Yes* | - | Evaluate clusters by UpdateRing tag |
| `-UpdateRingValue` | String | Yes* | - | The UpdateRing tag value to filter by |
| `-MaxFailurePercent` | Int | No | `5` | Maximum allowed failure percentage (0-100) |
| `-MinSuccessPercent` | Int | No | `90` | Minimum required success percentage (0-100) |
| `-WaitForCompletion` | Switch | No | - | Wait for in-progress updates to complete before evaluating |
| `-WaitTimeoutMinutes` | Int | No | `120` | Maximum wait time for completion (minutes) |
| `-PollIntervalSeconds` | Int | No | `60` | How often to check status while waiting |

*Either `-State` OR `-ScopeByUpdateRingTag`/`-UpdateRingValue` is required.

**Output Properties:**
| Property | Description |
|----------|-------------|
| `Passed` | Boolean - did the gate pass? |
| `Reason` | Explanation of pass/fail |
| `TotalClusters` | Total clusters evaluated |
| `Succeeded` | Clusters that succeeded |
| `Failed` | Clusters that failed |
| `InProgress` | Clusters still in progress |
| `SuccessPercent` | Calculated success rate |
| `FailurePercent` | Calculated failure rate |

**Examples:**

```powershell
# Basic health gate check
Test-AzLocalFleetHealthGate -ScopeByUpdateRingTag -UpdateRingValue "Canary"

# Strict gate for production (max 2% failure, min 95% success)
Test-AzLocalFleetHealthGate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" `
    -MaxFailurePercent 2 -MinSuccessPercent 95

# Wait for completion before evaluating
Test-AzLocalFleetHealthGate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" `
    -WaitForCompletion -WaitTimeoutMinutes 180

# CI/CD pipeline integration
$gate = Test-AzLocalFleetHealthGate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" `
    -MaxFailurePercent 2 -WaitForCompletion
if (-not $gate.Passed) {
    Write-Error "Health gate failed: $($gate.Reason)"
    exit 1
}
# Proceed to Wave2...
```

**Sample Output (Passed):**

```
========================================
Fleet Health Gate Check
========================================
Criteria: MaxFailure=5%, MinSuccess=90%

✓ HEALTH GATE PASSED
  Success Rate: 97.3% (min: 90%)
  Failure Rate: 2% (max: 5%)
```

**Sample Output (Failed):**

```
========================================
Fleet Health Gate Check
========================================
Criteria: MaxFailure=5%, MinSuccess=90%

✗ HEALTH GATE FAILED
  - Failure rate (8%) exceeds maximum (5%)
  - 2 cluster(s) have critical health failures
  Success Rate: 85% (min: 90%)
  Failure Rate: 8% (max: 5%)
```

---

### `Export-AzLocalFleetState`

Exports the current fleet operation state to a JSON file for resume capability, audit trails, and progress tracking across sessions.

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-State` | PSCustomObject | No | - | State object to export. Uses current in-memory state if not provided. |
| `-Path` | String | No | Auto-generated | File path for the JSON state file |

**Returns:** The path where the state was saved.

**State File Contents:**
- Run ID and timestamps
- Operation configuration (batch size, throttle limit, etc.)
- Total/completed/failed/pending cluster counts
- Per-cluster status with attempt history and errors

**Examples:**

```powershell
# Export current state to default location
Export-AzLocalFleetState

# Export to specific path
Export-AzLocalFleetState -Path "C:\Logs\fleet-state.json"

# Export state from operation
$state = Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -PassThru
Export-AzLocalFleetState -State $state -Path "C:\Logs\wave1-checkpoint.json"
```

**Sample State File:**

```json
{
  "RunId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "Operation": "ApplyUpdate",
  "StartTime": "2026-01-29T10:00:00Z",
  "TotalClusters": 150,
  "CompletedCount": 75,
  "SucceededCount": 73,
  "FailedCount": 2,
  "PendingCount": 75,
  "BatchSize": 50,
  "Clusters": [
    {
      "ClusterName": "Cluster001",
      "ResourceId": "/subscriptions/.../clusters/Cluster001",
      "Status": "Succeeded",
      "Attempts": 1
    },
    ...
  ]
}
```

---

### `Resume-AzLocalFleetUpdate`

Resumes a previously interrupted fleet update operation from a saved state file. Enables recovery from pipeline timeouts, network interruptions, or manual cancellations.

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-StateFilePath` | String | Yes* | - | Path to the saved state file |
| `-State` | PSCustomObject | Yes* | - | State object loaded via `Import-AzLocalFleetState` |
| `-RetryFailed` | Switch | No | - | Also retry clusters that previously failed (not just pending) |
| `-MaxRetries` | Int | No | `3` | Maximum additional retry attempts for failed clusters (0-10) |
| `-Force` | Switch | No | - | Skip confirmation prompts |
| `-PassThru` | Switch | No | - | Return the updated state object |

*Either `-StateFilePath` OR `-State` is required.

**Examples:**

```powershell
# Resume from state file (process only pending clusters)
Resume-AzLocalFleetUpdate -StateFilePath "C:\Logs\fleet-state.json" -Force

# Resume and retry failed clusters
Resume-AzLocalFleetUpdate -StateFilePath "C:\Logs\fleet-state.json" -RetryFailed -Force

# Load state manually and resume
$state = Import-AzLocalFleetState -Path "C:\Logs\fleet-state.json"
Resume-AzLocalFleetUpdate -State $state -RetryFailed -MaxRetries 5 -Force
```

**Sample Output:**

```
========================================
Resuming Fleet Operation
Original Run ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
========================================
State Summary:
  Pending: 75
  Failed: 2
  Succeeded: 73

Clusters to process: 77
```

---

### `Stop-AzLocalFleetUpdate`

Gracefully stops an in-progress fleet update operation after the current batch completes and saves state for later resumption.

> **Note:** This function signals the operation to stop but does NOT cancel individual cluster updates that are already in progress. For emergency cancellation, use Azure Portal or `az` CLI to cancel individual update runs.

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-SaveState` | Switch | No | - | Save the current state to a file before stopping |
| `-StateFilePath` | String | No | Auto-generated | Path to save the state file |

**Examples:**

```powershell
# Stop and save state
Stop-AzLocalFleetUpdate -SaveState

# Stop and save to specific location
Stop-AzLocalFleetUpdate -SaveState -StateFilePath "C:\Logs\fleet-stopped.json"
```

**Sample Output:**

```
========================================
Stopping Fleet Operation
========================================

State saved to: C:\Logs\fleet-stopped.json
Use Resume-AzLocalFleetUpdate to continue later.

Operation Status at Stop:
  Run ID: a1b2c3d4-e5f6-7890-abcd-ef1234567890
  Total: 150
  Completed: 75
  Succeeded: 73
  Failed: 2
  Pending: 75

Fleet operation marked for stop.
Note: Updates already in progress on individual clusters will continue.
```

---

### `Test-AzLocalUpdateScheduleAllowed`

Master gate that evaluates whether an update is allowed against the `UpdateStartWindow` (maintenance schedule) and `UpdateExclusionsWindow` (blackout periods; renamed from `UpdateExclusions` in v0.7.90) tag values. Exclusions take priority over windows. Returns a structured result with `Allowed`, `Reason`, `WindowOpen`, `ExclusionActive`, and `Details`. Used internally by `Start-AzLocalClusterUpdate` and exposed as a public function so pipelines can pre-flight a wave before triggering the apply step.

> **Fail-closed behaviour**: malformed `UpdateStartWindow` / `UpdateExclusionsWindow` tag values cause this function to throw rather than swallow - this is intentional so the calling apply path can block the update unless `-Force` is supplied.

> Note: the separate **`UpdateExcluded`** tag (operator hard override, new in v0.7.90) is evaluated by `Start-AzLocalClusterUpdate` directly in a step BEFORE the schedule gate, not by this function. See the `Start-AzLocalClusterUpdate` entry for the `ExcludedByTag` status.

**Parameters:**
| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-UpdateStartWindow` | String | No | (none) | The `UpdateStartWindow` tag value (e.g. `Mon-Fri_22:00-02:00;Sat-Sun_02:00-06:00`). Empty/null = no window restriction. |
| `-UpdateExclusionsWindow` | String | No | (none) | The `UpdateExclusionsWindow` tag value (e.g. `2026-12-20/2027-01-03;2027-04-05`). Empty/null = no exclusion restriction. Renamed from `-UpdateExclusions` in v0.7.90. |
| `-TestTime` | DateTime | No | `(Get-Date).ToUniversalTime()` | UTC time to test against. Local/Unspecified inputs are normalised to UTC automatically. |

**Examples:**

```powershell
# Pre-flight a wave: would now be allowed?
$gate = Test-AzLocalUpdateScheduleAllowed `
    -UpdateStartWindow 'Sat-Sun_02:00-06:00' `
    -UpdateExclusionsWindow '2026-12-20/2027-01-03'

if (-not $gate.Allowed) {
    Write-Host "Wave blocked: $($gate.Reason) - $($gate.Details)"
    exit 1
}

# Test a specific UTC point in time (e.g. when the pipeline will run tonight)
Test-AzLocalUpdateScheduleAllowed `
    -UpdateStartWindow 'Mon-Fri_22:00-02:00' `
    -TestTime ([DateTime]::UtcNow.AddHours(6))
```

---

### `Reset-AzLocalSideloadedTag`

Explicit, scope-required entry point for the same auto-reset logic that `Get-AzLocalUpdateRuns` runs by default. Use it to: (a) manually reset the sideloaded tags after an out-of-band update where `Get-AzLocalUpdateRuns` was not executed (or was run with `-SkipSideloadedReset`), or (b) force-clear a stuck `UpdateSideloaded=True` tag with `-Force`.

For each in-scope cluster the function fetches the latest update run and applies the same decision matrix as the auto-reset path - see [the action-values table in section 7a](#7a-sideloaded-payload-workflow-v071) for the full meaning of `Reset` / `OrphanCleared` / `NoTag` / `RunNotSucceeded` / `Skipped`. **Scope must be explicit** - there is no implicit `-AllClusters`. Supports `-WhatIf` / `-Confirm` (`ConfirmImpact = Medium`).

**Parameter sets:**

| Parameter set | Required | Use when |
|---------------|----------|----------|
| `ByName` | `-ClusterNames <string[]>` (+ optional `-ResourceGroupName`) | Resetting one or a small list of named clusters. |
| `ByResourceId` | `-ClusterResourceIds <string[]>` | Resetting by full ARM resource IDs (e.g. piped from another query). |
| `ByTag` | `-ScopeByUpdateRingTag` + `-UpdateRingValue <string>` | Bulk reset across an UpdateRing (e.g. all of `Wave1`). |

**Common parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-SubscriptionId` | String | No | Current `az` subscription | Override subscription context. |
| `-ApiVersion` | String | No | Module default | ARM api-version for the cluster + tag PATCH calls. |
| `-Force` | Switch | No | - | Bypasses the `UpdateVersionInProgress` match check. **Still requires the cluster's latest run state to be `Succeeded`** - this prevents flipping the gate while an in-flight update is still running. |

**Returns:** `PSCustomObject[]` - one row per cluster with `ClusterName`, `Action`, `PreviousSideloaded`, `NewSideloaded`, `StagedVersion`, `MatchedRunUpdateName`, `Message`.

**Examples:**

```powershell
# Inspect a single cluster (no changes)
Reset-AzLocalSideloadedTag -ClusterNames 'cl-01' -ResourceGroupName 'rg-fleet' -WhatIf

# Bulk reset across an UpdateRing, default behaviour: only succeeded runs get reset
Reset-AzLocalSideloadedTag -ScopeByUpdateRingTag -UpdateRingValue 'Wave1'

# Force-clear a stuck cluster (operator abandoned the staged payload).
# -Force still requires latest run = Succeeded; it just bypasses the version-match check.
Reset-AzLocalSideloadedTag -ClusterNames 'cl-stuck' -Force -Confirm:$false
```

> **No new RBAC required.** Uses the same `Microsoft.Resources/tags/read` + `Microsoft.Resources/tags/write` already required by `Set-AzLocalClusterUpdateRingTag`.

---

### `Get-AzLocalFleetStatusData`

Single-pass data collector that gathers everything `New-AzLocalFleetStatusHtmlReport` needs, in one structured object. Returns a `PSCustomObject` with `SchemaVersion`, `Timestamp`, `ModuleVersion`, `Scope`, `Readiness`, `ClusterDetails`, `LatestRuns`, `HealthResults`. Use this when you want to:

- Decouple data collection from rendering (collect once in a CI/CD job, render in another).
- Pass data between pipeline stages as a JSON artifact (`-ExportPath`).
- Avoid the redundant API calls that happen if you call the readiness / inventory / health functions separately.

Honours `-ThrottleLimit 1-8` for parallel collection; default 4.

**Parameter sets:** `ByResourceId` / `ByName` / `ByTag` / `All` (mirrors the other fleet functions).

**Common parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-IncludeUpdateRuns` | Switch | - | Collect latest update run history per cluster. |
| `-IncludeHealthDetails` | Switch | - | Collect detailed health-check failure data per cluster. |
| `-ThrottleLimit` | Int 1-8 | 4 | Parallel workers. Set 1 for sequential / debugging. |
| `-MaxClusters` | Int 0-100000 | 0 (no cap) | Optional cap when `-AllClusters` is used. |
| `-ExportPath` | String | - | JSON path for the artifact. |

**Examples:**

```powershell
# One-step: collect + render
$data = Get-AzLocalFleetStatusData -AllClusters -ThrottleLimit 4 -IncludeUpdateRuns -IncludeHealthDetails
New-AzLocalFleetStatusHtmlReport -StatusData $data -OutputPath 'C:\Reports\fleet.html'

# CI/CD: collect in job 1, render in job 2 from the artifact
Get-AzLocalFleetStatusData -ScopeByUpdateRingTag -UpdateRingValue 'Wave1' `
    -IncludeUpdateRuns -IncludeHealthDetails `
    -ExportPath '$(Pipeline.Workspace)/fleet-data.json'
```

---

### `New-AzLocalFleetStatusHtmlReport`

Renders a self-contained HTML report (executive summary, progress bar, cluster status table, optional health-details and update-run-history sections, embedded CSS). UTF-8 without BOM; safe to email or host on SharePoint. Supports `-WhatIf` / `-Confirm`.

Two ways to drive it:

1. **Self-collecting** (default): pass a scope (`-AllClusters` / `-ClusterNames` / `-ScopeByUpdateRingTag` / `-ClusterResourceIds`) and the function will call `Get-AzLocalClusterInventory`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates` (and optionally `Get-AzLocalUpdateRuns` / `Test-AzLocalClusterHealth`) itself.
2. **From pre-collected data**: pass `-StatusData $data` (the object returned by `Get-AzLocalFleetStatusData`) and the function skips all API calls, going straight to rendering. **Use this in CI/CD to avoid double-billing yourself for ARM reads.**

**Common parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-OutputPath` | String | Yes | - | Destination `.html` / `.htm` file. Validated. |
| `-StatusData` | PSCustomObject | No | - | Pre-collected payload from `Get-AzLocalFleetStatusData`. |
| `-IncludeUpdateRuns` | Switch | No | - | Add the **Recent Update Run History** section (now includes `End Time` column - v0.7.1). |
| `-IncludeHealthDetails` | Switch | No | - | Add the detailed health-check failure section. |
| `-Title` | String | No | Auto | Custom report title (auto-derived from scope if omitted). |
| `-MaxClusters` | Int 0-100000 | No | 0 (no cap) | Optional cap when `-AllClusters` is used. |
| `-ThrottleLimit` | Int 1-8 | No | 4 | Parallel workers (only relevant when self-collecting). |
| `-PassThru` | Switch | No | - | Also return the HTML string (useful for emailing). |

**Examples:**

```powershell
# Whole fleet, full detail
New-AzLocalFleetStatusHtmlReport -AllClusters `
    -OutputPath 'C:\Reports\fleet.html' `
    -IncludeUpdateRuns -IncludeHealthDetails

# Wave-scoped, capture HTML for email body
$html = New-AzLocalFleetStatusHtmlReport `
    -ScopeByUpdateRingTag -UpdateRingValue 'Wave1' `
    -OutputPath 'C:\Reports\wave1.html' -PassThru

# Two-stage CI/CD pattern (no double API calls)
$data = Get-AzLocalFleetStatusData -AllClusters -IncludeUpdateRuns -IncludeHealthDetails
New-AzLocalFleetStatusHtmlReport -StatusData $data -OutputPath 'C:\Reports\fleet.html'
```

---

### `Get-AzLocalFleetHealthFailures`

*Added in v0.7.65.*

Surfaces the in-flight **24-hour system health-check failures** across every Azure Local cluster the caller can read. The 24-hour system health checks continue to run on the cluster even when no update is in flight, which means clusters that are **already "up to date" can still surface Critical or Warning health issues** that administrators need to triage. This cmdlet is the dedicated entry point for that workflow.

Under the covers it executes a single Azure Resource Graph query against the `extensibilityresources` table (paging transparently for fleets larger than 1000 entries), `mv-expand`s `properties.healthCheckResult` so each failing entry becomes its own row, and projects to a stable output schema.

**Parameters:**

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-SubscriptionId` | String | No | All accessible | Optional. Limit the query to a single subscription. |
| `-Severity` | String | No | `All` | `Critical`, `Warning`, or `All` (Critical + Warning). Informational entries are always excluded. |
| `-View` | String | No | `Detail` | `Detail` (one row per (cluster, failing check)) or `Summary` (aggregated by `FailureReason` + `Severity`, ordered "most widespread first"). |
| `-UpdateRingTag` | String | No | - | Optional. Narrow to clusters whose `UpdateRing` tag matches. Accepts a single ring (`Wave1`), a semicolon-delimited list (`Prod;Ring2`), or the literal `***` wildcard for every cluster with a non-empty `UpdateRing` tag (untagged clusters are excluded). Single `*`, double `**`, and quadruple `****` are deliberately rejected. Validated `^(\*\*\*\|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$`. |
| `-ExportPath` | String | No | - | Optional `.csv` or `.json` path; format auto-detected from extension. |
| `-PassThru` | Switch | No | - | Emit objects to the pipeline **even when** `-ExportPath` is used. |

**Detail view columns:** `ClusterName`, `ResourceGroup`, `SubscriptionId`, `Severity`, `FailureReason`, `FailureName`, `Description`, `Remediation`, `LastOccurrence`, `ClusterResourceId`. Rows are ordered Critical-before-Warning, then by ClusterName, then by FailureReason.

**Summary view columns:** `FailureReason`, `Severity`, `ClusterCount`, `FailureCount`, `AffectedClusters` (semicolon-separated), `LatestOccurrence`, `Description`, `Remediation`. Rows are ordered by `ClusterCount desc, Critical-before-Warning, FailureCount desc` so the highest-impact issues are at the top.

**Examples:**

```powershell
# Per-cluster detail across the entire fleet (default view)
Get-AzLocalFleetHealthFailures

# Pivot by failure reason - "what should we fix first?" - and export
Get-AzLocalFleetHealthFailures -View Summary -ExportPath .\fleet-health-summary.csv

# Critical issues only, narrowed to one ring, for a focussed report
Get-AzLocalFleetHealthFailures -Severity Critical -UpdateRingTag 'Wave1'

# CI/CD pipeline: detail for JUnit emission, summary for the markdown summary
$detail  = Get-AzLocalFleetHealthFailures -View Detail  -ExportPath .\reports\fleet-health-detail.csv  -PassThru
$summary = Get-AzLocalFleetHealthFailures -View Summary -ExportPath .\reports\fleet-health-summary.csv -PassThru
```

> **CI/CD**: the bundled `fleet-health-status.yml` pipeline samples (GitHub Actions and Azure DevOps) wire this cmdlet into a daily-scheduled run that emits JUnit XML, CSV/JSON exports, and a Markdown step summary. See [Automation-Pipeline-Examples/README.md](./Automation-Pipeline-Examples/README.md).

**Required permissions** (read-only):
- `Microsoft.AzureStackHCI/clusters/read`
- `Microsoft.AzureStackHCI/clusters/updateSummaries/read`
- `Microsoft.ResourceGraph/resources/read`

`Reader` on the cluster (or the containing resource group / subscription) is sufficient.

---

### `Test-AzLocalApplyUpdatesScheduleCoverage`

*Added in v0.7.65.*

Read-only **schedule-coverage advisor**. Compares the cron schedule(s) declared in your `apply-updates.yml` pipeline (GitHub Actions and/or Azure DevOps) to the `UpdateStartWindow` tag values actually present on your clusters, and flags every `(UpdateRing, UpdateStartWindow)` pair that no cron in the pipeline will ever reach. Never edits cluster tags. Never edits pipeline YAML. It is the safety net that closes the loop between section 8 of [`Automation-Pipeline-Examples/README.md`](./Automation-Pipeline-Examples/README.md) (the `UpdateStartWindow` tag is a *gate*, not a *trigger*) and `Test-AzLocalUpdateScheduleAllowed` (the runtime per-cluster gate inside `Start-AzLocalClusterUpdate`).

Under the covers it pre-scans the pipeline YAML file(s) with a regex (no `powershell-yaml` dependency), runs a single Azure Resource Graph query against `resources` for clusters with `UpdateStartWindow` / `UpdateRing` tags, parses each tag value with the same `ConvertFrom-AzLocalUpdateWindow` helper used by the runtime gate, then enumerates every cron fire time over a reference week and compares it to each parsed window (with a configurable lead-time buffer).

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-SubscriptionId` | String | No | All accessible | Optional. Limit the ARG query to a single subscription. |
| `-View` | String | No | `Audit` | `Audit` (one row per `(Ring, Window)` pair with `Covered` / `Uncovered` / `PartiallyCovered` / `MalformedTag` / `NoWindowTag` / `UnparseableCron` status + remediation), `Matrix` (every distinct `(Ring, Window)` pair with the cron expression the advisor would generate for it), or `Recommend` (ready-to-paste GH Actions + Azure DevOps cron blocks). |
| `-PipelineYamlPath` | String | Audit only | - | Path to `apply-updates.yml` file(s) or a folder containing them. Required when `-View Audit`. |
| `-Platform` | String | No | `Both` | `GitHubActions`, `AzureDevOps`, or `Both`. Filters which YAML files are scanned and which cron blocks the Recommend view emits. |
| `-LeadTimeMinutes` | Int | No | `5` | Range 0-60. How many minutes the cron should fire **before** the window opens (so cluster enumeration + auth completes before `Test-AzLocalUpdateScheduleAllowed` evaluates). |
| `-UpdateRingTag` | String[] | No | - | Optional. Narrow the audit to one or more `UpdateRing` tag values. |
| `-IncludeUntagged` | Switch | No | - | Include clusters that have no `UpdateStartWindow` tag in the Audit view (`Status = NoWindowTag`). |
| `-ExportPath` | String | No | - | Optional `.csv` / `.json` / `.md` path; format auto-detected from extension. `.md` emits the YAML snippet for Recommend, a markdown table for Audit/Matrix. |
| `-PassThru` | Switch | No | - | Emit objects to the pipeline even when `-ExportPath` is used. |

**Audit view columns:** `UpdateRing`, `UpdateStartWindow`, `ClusterCount`, `Status`, `Issue`, `Recommendation`, `MatchingCrons`, `RequiredCronUTC`. Rows are ordered by `Status` (Uncovered first), then `ClusterCount desc`.

**Matrix view columns:** `UpdateRing`, `UpdateStartWindow`, `ClusterCount`, `RequiredCronUTC`, `Segment`, `Days`.

**Recommend view columns:** `Platform`, `CronExpression`, `WindowsServed`, `ClustersServed`, `Comment`.

**Examples:**

```powershell
# Audit the in-repo pipeline samples against the live fleet (default view)
Test-AzLocalApplyUpdatesScheduleCoverage `
    -PipelineYamlPath .\AzLocal.UpdateManagement\Automation-Pipeline-Examples

# Audit only the GitHub Actions sample, with a 10-minute lead time
Test-AzLocalApplyUpdatesScheduleCoverage `
    -PipelineYamlPath .\.github\workflows\apply-updates.yml `
    -Platform GitHubActions `
    -LeadTimeMinutes 10

# Just emit the recommended cron block(s), no comparison required
Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -Platform GitHubActions

# Inventory every (Ring, Window) pair with its required cron, export to CSV
Test-AzLocalApplyUpdatesScheduleCoverage -View Matrix -ExportPath .\windows.csv

# CI/CD pipeline: emit all three artefacts for the schedule audit pipeline
$audit  = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit  -PipelineYamlPath .\.github\workflows -ExportPath .\schedule-coverage-audit.csv     -PassThru
$matrix = Test-AzLocalApplyUpdatesScheduleCoverage -View Matrix -ExportPath .\schedule-coverage-matrix.csv -PassThru
$rec    = Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -ExportPath .\schedule-coverage-recommend.md -PassThru
```

> **CI/CD**: the bundled `apply-updates-schedule-audit.yml` pipeline samples (GitHub Actions and Azure DevOps) wire this cmdlet into a weekly-scheduled run (Mon 05:00 UTC) that emits JUnit XML, three CSV/MD exports, and a Markdown step summary. Full end-to-end runbook in [`Automation-Pipeline-Examples/README.md` section 8.3](./Automation-Pipeline-Examples/README.md#83-end-to-end-runbook-apply-updates-schedule-coverage-audit).

**Required permissions** (read-only):
- `Microsoft.Resources/subscriptions/resourceGroups/read`
- `Microsoft.AzureStackHCI/clusters/read`
- `Microsoft.ResourceGraph/resources/read`

`Reader` on the cluster scope (or the containing resource group / subscription) is sufficient. No write actions are ever taken.

---

The module includes comprehensive logging capabilities for tracking update operations.

### Log Files

By default, log files are created in `C:\ProgramData\AzLocal.UpdateManagement\` which is accessible across different user profiles. This folder is automatically created if it doesn't exist.

When you run `Start-AzLocalClusterUpdate`, the following files are automatically created:

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
# Basic logging (logs created in default folder: C:\ProgramData\AzLocal.UpdateManagement\)
Start-AzLocalClusterUpdate -ClusterNames "MyCluster" -Force

# Custom log folder location (auto-creates folder if needed)
Start-AzLocalClusterUpdate -ClusterNames "MyCluster" -LogFolderPath "D:\Logs\Updates" -Force

# Enable transcript recording for complete console output capture
Start-AzLocalClusterUpdate -ClusterNames "MyCluster" -EnableTranscript -Force

# Export results to JSON for automation/reporting
Start-AzLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") -ExportResultsPath "C:\Logs\results.json" -Force

# Export results to CSV for Excel analysis
Start-AzLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") -ExportResultsPath "C:\Logs\results.csv" -Force

# Full logging with all options
Start-AzLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") `
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

