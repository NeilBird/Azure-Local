# Azure Local Update Management Module (AzLocal.UpdateManagement)

> ⚠️ **Disclaimer**: This module is **NOT** a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT license](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

**Latest Version:** v0.9.28 - [Published in PowerShell Gallery](https://www.powershellgallery.com/packages/AzLocal.UpdateManagement/0.9.28)

This folder contains the 'AzLocal.UpdateManagement' PowerShell module for managing updates on Azure Local (formerly Azure Stack HCI) clusters using the Azure Local REST API. The module supports both interactive use and CI/CD automation via Service Principal or Managed Identity authentication.

Azure Local REST API specification (includes update management endpoints): https://github.com/Azure/azure-rest-api-specs/blob/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/stable/2026-02-01/hci.json

<details>
<summary><strong>📑 Table of Contents</strong> (click to expand)</summary>

**This README (overview + most-recent release notes):**

- [Where to Start](#where-to-start)
- [What's New in v0.9.28](#whats-new-in-v0928)
- [Files](#files)
- [Prerequisites](#prerequisites)
- [RBAC Requirements](#rbac-requirements) (summary; full reference in [docs/rbac.md](docs/rbac.md))
- [Quick Start](#quick-start)
- [Available Functions](#available-functions) (summary; full reference in [docs/cmdlet-reference.md](docs/cmdlet-reference.md))
- [Update States](#update-states) (summary; full reference in [docs/concepts.md](docs/concepts.md))
- [Troubleshooting](#troubleshooting) (summary; full reference in [docs/troubleshooting.md](docs/troubleshooting.md))
- [License](#license)
- [Release History](#release-history) (most recent only; full history in [docs/release-history.md](docs/release-history.md))

**Detailed references (in `docs/`):**

- [docs/cmdlet-reference.md](docs/cmdlet-reference.md) - every exported cmdlet (single-cluster + fleet-scale + API version reference)
- [docs/rbac.md](docs/rbac.md) - full RBAC role map, custom least-privilege role, role-assignment recipes
- [docs/concepts.md](docs/concepts.md) - update lifecycle states, Azure CLI direct usage, Az.StackHCI parity, CI/CD background
- [docs/troubleshooting.md](docs/troubleshooting.md) - symptom-to-fix table for common failure modes
- [docs/release-history.md](docs/release-history.md) - v0.7.74 and earlier What's-New entries
- [docs/RELEASE-PROCESS.md](docs/RELEASE-PROCESS.md) - how to cut a release (maintainer-facing)
- [Automation-Pipeline-Examples/README.md](./Automation-Pipeline-Examples/README.md) - end-to-end CI/CD pipeline runbook

</details>

## Where to Start

This module supports **two main paths**. Pick the one that matches your scenario:

| Path | Best for | Auth | Where to read next |
|------|----------|------|--------------------|
| **Interactive** | Manual ops, ad-hoc fleet checks, tag clean-up, learning the module | `az login` | Continue below - the [Quick Start](#quick-start) and per-function reference sections in this README |
| **CI/CD / scheduled automation** | GitHub Actions, Azure DevOps, scheduled fleet reports, gated wave deployments | OIDC, Managed Identity, or Service Principal | **[Automation-Pipeline-Examples/README.md](./Automation-Pipeline-Examples/README.md)** - end-to-end pipeline guide with copy-pasteable workflows |

### Getting started interactively

If you are new to this module, work through these in order from a regular PowerShell session. Each step links to the dedicated reference section further down the README.

| Step | Goal | Function(s) |
|------|------|-------------|
| 1 | Authenticate to Azure | `az login` (interactive) - see [Quick Start - 1. Authenticate](#1-authenticate-to-azure) |
| 2 | Discover what is in the fleet | [`Get-AzLocalClusterInventory`](docs/cmdlet-reference.md#get-azlocalclusterinventory) |
| 3 | Tag clusters into rings (Wave1, Prod, Test, ...) | [`Set-AzLocalClusterUpdateRingTag`](docs/cmdlet-reference.md#set-azlocalclusterupdateringtag) |
| 4 | Assess readiness for the wave | [`Get-AzLocalClusterUpdateReadiness`](docs/cmdlet-reference.md#get-azlocalclusterupdatereadiness), [`Test-AzLocalClusterHealth`](docs/cmdlet-reference.md#test-azlocalclusterhealth) |
| 5 | Apply the update | [`Start-AzLocalClusterUpdate`](docs/cmdlet-reference.md#start-azlocalclusterupdate) (single cluster or `-ScopeByUpdateRingTag` for a wave) |
| 6 | Monitor and report | [`Get-AzLocalUpdateRuns`](docs/cmdlet-reference.md#get-azlocalupdateruns), [`Get-AzLocalFleetProgress`](docs/cmdlet-reference.md#get-azlocalfleetprogress), [`New-AzLocalFleetStatusHtmlReport`](docs/cmdlet-reference.md#new-azlocalfleetstatushtmlreport) |

> **For CI/CD?** Skip this table and go straight to [Automation-Pipeline-Examples/README.md](./Automation-Pipeline-Examples/README.md) - it covers OIDC / Managed Identity / Service Principal setup, federated credentials, eleven GitHub Actions workflows, and eleven Azure DevOps pipelines (including the on-prem `sideload-updates` pipeline plus `apply-updates`, `monitor-updates`, `fleet-update-status`, and `fleet-health-status`). Pipeline files are no longer prefixed with `Step.N_` - the in-pipeline display names still carry the `Step.N` ordering, and `Update-AzLocalPipelineExample` migrates any older `Step.N_*.yml` files to the new names automatically while preserving your customizations.

### Common workflows (function-invocation order)

| Scenario | Recommended order |
|----------|-------------------|
| **One-off cluster update** | `az login` -> `Get-AzLocalUpdateSummary` -> `Get-AzLocalAvailableUpdates` -> `Start-AzLocalClusterUpdate` -> `Get-AzLocalUpdateRuns` |
| **Staged wave deployment** | `Get-AzLocalClusterInventory` -> `Set-AzLocalClusterUpdateRingTag` -> `Get-AzLocalClusterUpdateReadiness -ScopeByUpdateRingTag` -> `Start-AzLocalClusterUpdate -ScopeByUpdateRingTag` -> `Get-AzLocalFleetProgress` -> `New-AzLocalFleetStatusHtmlReport` |
| **Daily fleet status report** | `Get-AzLocalFleetStatusData -AllClusters -IncludeUpdateRuns -IncludeHealthDetails -ExportPath ...` -> `New-AzLocalFleetStatusHtmlReport -StatusData $data -OutputPath ...` |
| **Daily fleet health audit (v0.7.65)** | `Get-AzLocalFleetHealthFailures -View Summary -ExportPath fleet-health-summary.csv` -> review top failure reasons by cluster impact -> drill into [`Get-AzLocalFleetHealthFailures -View Detail`](docs/cmdlet-reference.md#get-azlocalfleethealthfailures) for per-cluster remediation |
| **Schedule coverage drift audit (v0.7.65)** | `Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath .\.github\workflows` -> for any `Uncovered` rows, copy the `RequiredCronUTC` value and paste it into `apply-updates.yml` -> re-run `-View Audit` to confirm `Covered` -> wire the bundled `apply-updates-schedule-audit.yml` pipeline (weekly Mon 05:00 UTC) so future tag drift is caught automatically. Full runbook: [`Automation-Pipeline-Examples/README.md` section 8.3](./Automation-Pipeline-Examples/README.md#83-end-to-end-runbook-apply-updates-schedule-coverage-audit) |
| **Pre-update health gate (CI/CD)** | `Test-AzLocalClusterHealth -BlockingOnly` -> `Test-AzLocalUpdateScheduleAllowed` -> `Test-AzLocalFleetHealthGate` -> proceed only on pass |
| **Manual sideloaded-payload gate (v0.7.1)** | Operator sets `UpdateSideloaded=False` -> stage payload out-of-band -> operator flips `UpdateSideloaded=True` -> `Start-AzLocalClusterUpdate` (auto-stamps `UpdateVersionInProgress`) -> `Get-AzLocalUpdateRuns` (auto-resets tags on success) -> `Reset-AzLocalSideloadedTag -Force` only if a tag gets stuck |
| **Automated disconnected-cluster sideload (Update: 2)** | Configure `config/sideload-settings.yml` -> populate the catalog and auth map -> run `sideload-updates.yml` on a self-hosted runner -> review `Export-AzLocalSideloadStatusReport` -> let Update: 3 apply the imported update. See the [sideload operations guide](Automation-Pipeline-Examples/docs/sideload.md). |
| **Pause / resume long fleet run** | `Stop-AzLocalFleetUpdate -SaveState` -> ... -> `Resume-AzLocalFleetUpdate -StateFilePath ...` |
| **Recover from emergency** | `Stop-AzLocalFleetUpdate` -> `Test-AzLocalClusterHealth` (assess) -> `Resume-AzLocalFleetUpdate -RetryFailed` |

> Most CI/CD pipelines in [Automation-Pipeline-Examples/](Automation-Pipeline-Examples/) are direct implementations of one of these workflows. Start there if you want a copy-pasteable end-to-end pipeline.

## What's New in v0.9.28

**Update: 4 now distinguishes Resource Graph indexing lag from a genuinely missing update run, and every bundled pipeline can publish a bounded diagnostic transcript.** Recent `UpdateLastAttempt` tags with `UpdateStarted` or `UpdateRetried` outcomes are checked against the cluster's direct ARM `updateRuns` endpoint when ARG lacks a covering row. A run covers the attempt when its `timeStarted` is recent or its `lastUpdatedTime` advanced near the attempt, which handles retries that reuse the original run and start time. The `-SkipWhenIdle` heartbeat checks these tags before trusting an ARG-idle result, so ARG omission cannot bypass reconciliation. Recovered runs replace stale same-cluster/same-update ARG rows, while truly absent runs remain `AttemptWithoutRun`; ARM authorization/transport failures remain explicit. `Clusters scoped` now counts admitted inventory rows.

Every pipeline now publishes an always-on `pipeline-timings.json` report for comparing successful run performance. The new `Invoke-AzLocalPipelineTimedOperation` wrapper records ordered operation duration/status data, durable `Running` evidence for abrupt termination, and scrubbed failures without changing workload output or error behavior. Use manual `diagnostics=true` for one manually queued run or set `DEBUG_VERBOSE=true` for all triggers to add `pipeline-transcript.log`; normal artifacts contain one file and diagnostic artifacts contain two. Shared ARG/ARM boundaries record bounded scope, count, retry, explicit empty-result, and scrubbed failure details without logging query text, URI query parameters, or successful response payloads. GitHub defaults to 14-day retention and accepts `DEBUG_RETENTION_DAYS`; Azure DevOps uses project retention. Multi-cluster update-run reads also batch admitted resource IDs, keeping management-group fleets with grouped tag admission below Windows command-line limits. Public exports increase from 71 to 72; all bundled pipeline pins remain `0.9.28`. See the [pipeline troubleshooting runbook](Automation-Pipeline-Examples/README.md#12-troubleshooting-pipelines).

> Previous release notes have moved into the [Release History](#release-history) appendix at the bottom of this document.

See [CHANGELOG.md](CHANGELOG.md) for full release details. See [`What's New in v0.9.27`](#whats-new-in-v0927) in the Release History for the previous release.

## Files

| File | Description |
|------|-------------|
| `AzLocal.UpdateManagement.psd1` | PowerShell module manifest |
| `AzLocal.UpdateManagement.psm1` | PowerShell module with functions to start updates on multiple Azure Local clusters |
| `example-update-request.json` | Example JSON showing API request/response structures for the Update Manager API |

## Prerequisites

- **Azure CLI** (`az`) installed and authenticated
- **PowerShell** 5.1 or later (Desktop or Core edition)
- **Permissions**: Azure Stack HCI Administrator or equivalent role (see RBAC Requirements below)
- **Cluster Requirements**: Cluster must be in "Connected" status with updates available
- **For tag-based filtering**: Azure CLI `resource-graph` extension (automatically installed by the module when using `-ScopeByUpdateRingTag`)

## RBAC Requirements

The module needs a small number of Azure RBAC roles depending on what you call it for:

| Operation group | Recommended built-in role | Scope |
|-----------------|--------------------------|-------|
| Read-only inventory and fleet reports (`Get-AzLocal*`, `Test-AzLocal*`) | `Azure Stack HCI Reader` + `Reader` | Subscription or Resource Group |
| Starting updates (`Start-AzLocalClusterUpdate`, fleet wrappers) | `Azure Stack HCI Administrator` | Subscription, Resource Group, or per-cluster |
| Refreshing a stale update assessment (`Sync-AzLocalClusterUpdateSummary`, readiness report auto-scan) | `Azure Stack HCI Administrator` / `Contributor`, or the custom role (granted via its `updateSummaries/*` wildcard - see note below) | Subscription, Resource Group, or per-cluster |
| Setting / clearing ring tags (`Set-AzLocalClusterUpdateRingTag`) | `Tag Contributor` + `Reader` (or any role with `Microsoft.Resources/tags/write`) | Subscription or Resource Group |
| Resource Graph fleet queries | `Reader` on every subscription you want included | Subscription |

A least-privilege custom role definition (`Azure Stack HCI Update Operator (custom)`) and the exact `actions:` list are documented in [docs/rbac.md](docs/rbac.md), along with `az role assignment create` recipes for OIDC federated credentials, Managed Identity, and Service Principal authentication.

> 📝 **"Check for updates" (`checkUpdates`) is preview and is granted by the least-privilege custom role via a wildcard:** Since v0.8.88, `Sync-AzLocalClusterUpdateSummary` and the opt-out stale-assessment auto-scan in `Export-AzLocalClusterUpdateReadinessReport` POST the preview `Microsoft.AzureStackHCI/clusters/updateSummaries/default/checkUpdates` action (`2026-03-01-preview`). The RBAC action Azure enforces for it is `Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action` (confirmed verbatim from a live `403 AuthorizationFailed` body). A provider-operations-catalog check on 2026-06-18 (`az provider operation show --namespace Microsoft.AzureStackHCI`) confirms the explicit `checkUpdates/action` leaf is **not yet published in the catalog**, and `az role definition create` / `update` rejects an *explicit* unregistered action - but it **accepts a wildcard**. As of v0.8.92 the `Azure Stack HCI Update Operator (custom)` role therefore grants `Microsoft.AzureStackHCI/clusters/updateSummaries/*` (which also covers `updateSummaries/read`); Azure matches the enforced `checkUpdates/action` against that wildcard at authorization time, so the refresh is authorized under the custom role today - no fallback to `Azure Stack HCI Administrator` / `Contributor` required, and no `-SkipStaleAssessmentScan` needed. The only automation consumer is the **Update: 1 - Assess Update Readiness** pipeline (`assess-update-readiness.yml`) via the readiness-report auto-scan; `Sync-AzLocalClusterUpdateSummary` does the same on demand. The wildcard also sweeps in any future control-plane sub-operation under `clusters/updateSummaries/`. See [docs/rbac.md](docs/rbac.md) and [Automation-Pipeline-Examples/README.md](Automation-Pipeline-Examples/README.md#3-permissions).
## Quick Start

### 1. Authenticate to Azure

The module supports three authentication methods. Choose based on your scenario:

| Method | Best For | Secrets Required |
|--------|----------|------------------|
| **Interactive** | Manual/ad-hoc use | None (browser login) |
| **OpenID Connect (OIDC)** | GitHub Actions, Azure DevOps | None (federated) |
| **Managed Identity** | Azure VMs, self-hosted runners | None (assigned identity) |
| **Service Principal + Secret** | Legacy systems only | Client Secret |

> ⚠️ **For CI/CD pipelines, Microsoft recommends OpenID Connect (OIDC)** over client secrets. OIDC uses short-lived tokens with no stored secrets. See [Automation-Pipeline-Examples/](Automation-Pipeline-Examples/) for setup instructions.

**Interactive Login (for manual use):**
```powershell
# Login to Azure (add --tenant <TenantId> if you have multiple tenants)
az login

# Optionally, set the subscription context
az account set --subscription "Your-Subscription-Name-or-Id"
```

**Managed Identity Login (for Azure VMs/containers):**
```powershell
# Import module and authenticate with Managed Identity
Import-Module .\AzLocal.UpdateManagement.psd1
Connect-AzLocalServicePrincipal -UseManagedIdentity

# For user-assigned managed identity, specify the client ID
Connect-AzLocalServicePrincipal -UseManagedIdentity -ManagedIdentityClientId "your-client-id"
```

**OpenID Connect (OIDC) for CI/CD:**
```yaml
# In GitHub Actions - OIDC authentication (no client secret).
# AZURE_TENANT_ID and AZURE_SUBSCRIPTION_ID are repository *Variables* (vars.*) not Secrets.
# Both are public ARM/AAD identifiers (not credentials) and each is consumed in exactly one
# place here: the `tenant-id:` / `subscription-id:` inputs to azure/login@v3, which exchange
# the OIDC token in the named tenant and set the runner's default `az account` context. The
# bundled cmdlets run Azure Resource Graph queries fleet-wide (no --subscriptions scoping)
# and build portal deep-link URLs from the per-row `subscriptionId` returned by ARG.
- name: Azure CLI Login (OIDC)
  uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
```

> See [Automation-Pipeline-Examples/README.md](Automation-Pipeline-Examples/README.md) for complete OIDC setup instructions.

**Service Principal + Secret (Legacy - not recommended):**
```powershell
# Using environment variables
$env:AZURE_CLIENT_ID = 'your-app-id'
$env:AZURE_CLIENT_SECRET = 'your-secret'  # Secrets can be leaked/expire
$env:AZURE_TENANT_ID = 'your-tenant-id'

# Import module and authenticate
Import-Module .\AzLocal.UpdateManagement.psd1
Connect-AzLocalServicePrincipal
```

### 2. Install and Import the Module

**Install from PowerShell Gallery**
```powershell
# Install from PowerShell Gallery
Install-Module -Name AzLocal.UpdateManagement -Scope CurrentUser

# Import the module
Import-Module AzLocal.UpdateManagement
```

**Optional: copy the CI/CD pipeline samples out of the module install folder**

The module ships a working set of pipeline YAML files plus a step-by-step setup README under `Automation-Pipeline-Examples/`. They live inside the module install path (typically under `C:\Program Files\WindowsPowerShell\Modules\AzLocal.UpdateManagement\<version>\`), so the easiest way to start using them is to copy them somewhere you control:

```powershell
# Copy everything (GitHub + Azure DevOps + ITSM samples + README) to the current folder
Copy-AzLocalPipelineExample

# Or only the GitHub Actions YAML, into a target folder of your choice
Copy-AzLocalPipelineExample -Destination C:\repos\my-fleet -Platform GitHub
```

The function prints a short "next steps" summary pointing at the copied README and the platform-specific YAML folder. See [`Automation-Pipeline-Examples/README.md`](Automation-Pipeline-Examples/README.md) for the full step-by-step setup guide.

> 🔄 **Refreshing pipelines after a module upgrade?** Use `Update-AzLocalPipelineExample` instead of `Copy-AzLocalPipelineExample`. It is a marker-aware merge that refreshes everything **outside** the `# BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `# END-AZLOCAL-CUSTOMIZE:<region>` blocks in each YAML and **preserves** everything inside them - so your custom cron schedules (`schedule-triggers`), ITSM secret bindings (`itsm-secrets`), Azure DevOps service connection name (`service-connection-*`), agent pools / runner labels (`runner-target-*`) and sideload self-hosted pools (`sideload-runner-*`) all survive the upgrade.
>
> ```powershell
> # Preview what would change
> Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -WhatIf
>
> # Apply the upgrade (preserves your AZLOCAL-CUSTOMIZE blocks)
> Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
> ```
>
> Rule of thumb: `Copy-AzLocalPipelineExample` for the **initial drop** (or a deliberate hard reset to the shipped samples); `Update-AzLocalPipelineExample` for **every subsequent module-upgrade refresh** if you have customised the YAMLs. See [Automation-Pipeline-Examples/README.md](Automation-Pipeline-Examples/README.md) ("Preserving operator edits across upgrades") for the marker-region reference and a full migration walkthrough.

### 3. Start an Update on a Single Cluster

```powershell
# Start update on a single cluster (will prompt for confirmation)
Start-AzLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG"

# Start update without prompting (use with caution)
Start-AzLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG" -Force
```

### 4. Start Updates on Multiple Clusters

```powershell
# Update multiple clusters in the same resource group
Start-AzLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02", "Cluster03") -ResourceGroupName "MyRG"

# Update clusters (function will search across all resource groups)
Start-AzLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02")
```

### 5. Start a Specific Update

```powershell
# Apply a specific update version
Start-AzLocalClusterUpdate -ClusterNames "MyCluster01" -UpdateName "Solution12.2601.1002.38"
```

### 6. Check Update Progress

```powershell
# Get update run status
Get-AzLocalUpdateRuns -ClusterName "MyCluster01" -ResourceGroupName "MyRG"
```

### 7. Set Up Update Management Tags for Staged Rollouts

The module reads (and in some cases writes) the following Azure resource tags to control how clusters are grouped, when updates are allowed to start, and which clusters are excluded from automation:

| Tag | Purpose | Required? | Set By |
|-----|---------|-----------|--------|
| `UpdateRing` | Groups clusters into deployment waves (e.g., Pilot, Wave1, Production) | **Yes** - needed for `-ScopeByUpdateRingTag` | `Set-AzLocalClusterUpdateRingTag` or CSV import |
| `UpdateStartWindow` | Defines allowed maintenance windows in UTC (e.g., `Sat-Sun_02:00-06:00`) | Optional | CSV import via `Set-AzLocalClusterUpdateRingTag` |
| `UpdateExclusionsWindow` | Defines blackout/change-freeze periods (e.g., `2026-12-20/2027-01-03`). Renamed from `UpdateExclusions` in v0.7.90 | Optional | CSV import via `Set-AzLocalClusterUpdateRingTag` |
| `UpdateExcluded` (v0.7.90) | Operator hard override. `True` / `1` skips the cluster in `Start-AzLocalClusterUpdate` with `Status = ExcludedByTag` regardless of ring scope, sideloaded state, or schedule | Optional (default-stamped `False` by `Set-AzLocalClusterUpdateRingTag` if absent) | Edit in Azure portal, or CSV import via `Set-AzLocalClusterUpdateRingTag` |
| `UpdateSideloaded` | Sideloaded-payload gate. Values `True`/`False`/`1`/`0` (case-insensitive). When `False`, `Start-AzLocalClusterUpdate` skips the cluster with `Status = SideloadedBlocked`. Operator-set. | Optional (only used by the sideloaded-payload workflow) | Operator (Azure portal, CLI, or your tagging pipeline). Auto-reset to `False` by `Get-AzLocalUpdateRuns` / `Reset-AzLocalSideloadedTag` after the staged update succeeds. |
| `UpdateVersionInProgress` | Module-managed companion to `UpdateSideloaded`. Holds the staged update name (e.g. `Solution12.2604.1003.209`). | **Do not set manually.** | Module: written by `Start-AzLocalClusterUpdate` at update start; cleared by `Get-AzLocalUpdateRuns` / `Reset-AzLocalSideloadedTag` once the matching run succeeds. |

> ℹ️ **Tag matching is case-insensitive throughout this module.** Tag *names* (`UpdateRing`, `UpdateStartWindow`, `UpdateExclusionsWindow`, `UpdateExcluded`) and tag *values* (the ring name like `Prod1`, day tokens like `Mon`, the `Daily` keyword, the `True`/`False` override values) are all compared without regard to case. So `prod1`, `Prod1`, and `PROD1` resolve to the same set of clusters via `-ScopeByUpdateRingTag -UpdateRingValue 'Prod1'` (Azure Resource Graph `=~` operator), and `Mon-Fri`, `mon-fri`, and `MON-FRI` parse to the same maintenance window. This applies to every function that scopes clusters by tag, every CSV import path, and the `UpdateStartWindow` / `UpdateExclusionsWindow` parsers. Note: the day tokens themselves still require the strict 3-letter form - `Mon Tue Wed Thu Fri Sat Sun` - case doesn't matter, but `Thur` / `Tues` / `Friday` will be rejected (see the `UpdateStartWindow` section below for the full table).

> **What happens if you only set `UpdateRing`?** Updates proceed immediately with **no schedule restrictions**. The `UpdateStartWindow` and `UpdateExclusionsWindow` tags are entirely optional - if neither is present on a cluster, the schedule check returns "No schedule restrictions defined" and the update starts as soon as the pipeline runs. Add `UpdateStartWindow` and `UpdateExclusionsWindow` tags when you need to control *when* updates can be applied. The separate `UpdateExcluded` tag (v0.7.90) is the operator hard override: set it to `True` to skip a cluster regardless of every other tag.

**Step 1: Inventory clusters and export to CSV**
```powershell
# Get all clusters with their current tags, export to CSV
Get-AzLocalClusterInventory -ExportPath "C:\Temp\cluster-inventory.csv"
```

The CSV includes columns for all four tags: `UpdateRing`, `UpdateStartWindow`, `UpdateExclusionsWindow`, and `UpdateExcluded`.

**Step 2: Edit the CSV in Excel**

Open `cluster-inventory.csv` and populate the tag columns:

| ClusterName | UpdateRing | UpdateStartWindow | UpdateExclusionsWindow | UpdateExcluded |
|-------------|------------|---------------------|------------------------|----------------|
| HCI-Pilot01 | Pilot      |                     |                        | False          |
| HCI-Pilot02 | Pilot      |                     |                        | False          |
| HCI-Prod01  | Wave1      | Sat-Sun_02:00-06:00 | 20**-12-20/20**-01-03  | False          |
| HCI-Prod02  | Wave1      | Sat-Sun_02:00-06:00 | 20**-12-20/20**-01-03  | False          |
| HCI-Critical| Production | Sat_02:00-06:00     | 20**-12-20/20**-01-03  | True           |

- **UpdateRing** (required): The deployment wave for this cluster
- **UpdateStartWindow** (optional): UTC maintenance window. Format: `<days>_<HH:MM>-<HH:MM>`. Multiple windows separated by `;`.

  > ⏱️ **Important - `UpdateStartWindow` controls when an update is allowed to *START*, not how long it takes to complete.** The window is a **start gate** evaluated by `Test-AzLocalUpdateScheduleAllowed` at the moment `Start-AzLocalClusterUpdate` runs. Once the update has started, it runs to completion (or failure) regardless of whether the window is still open - Azure Local update runs are **not** paused, throttled, or aborted when the window closes. A typical Azure Local platform update can take **several hours** on a multi-node cluster (node drains, reboots, firmware/driver/SBE steps, validation), and a "happy path" run with no issues is still measured in hours, not minutes.
  >
  > **Plan your window to *start* far enough before any hard deadline that the full update can finish before that deadline** - for example, if updates must be complete before a retail store opens at 06:00 local time, or before a manufacturing line starts at 06:00 Mon-Fri, do **not** set `UpdateStartWindow` to (say) `Mon-Fri_04:00-06:00` and expect the update to be done by 06:00. Set it to start much earlier (e.g. `Sun-Thu_22:00-02:00` for an overnight start the evening before) so the run has enough headroom for the slowest realistic completion time, plus margin for retries and post-update validation. When in doubt, time a representative update on a non-production cluster first and add a safety buffer.

  > **Pipeline timing allowance (fleet-settings schema v4):** Pipeline deployments can independently permit update attempts to start `0-60` minutes before and/or after every tagged window by activating `updateStartWindow.allowBeforeMinutes` and `updateStartWindow.allowAfterMinutes` in `config/fleet-settings.yml`. Both default to `0`, preserving the strict opening-inclusive/closing-exclusive window. The allowance is fleet-wide and changes only the runtime start gate; it does not rewrite tags, widen exclusion periods, or stop an update at the effective closing edge. See [Configure fleet scope, update-window allowances, and reporting](Automation-Pipeline-Examples/README.md#612-optional-configure-fleet-scope-update-window-allowances-and-reporting) for exact cutoff examples, safety guidance, and schema migration behavior.


  **Day tokens** - strict 3-letter abbreviations only (case-insensitive - `Mon`, `mon`, `MON` all work):

  | Token | Day | Token | Day |
  |---|---|---|---|
  | `Mon` | Monday | `Fri` | Friday |
  | `Tue` | Tuesday | `Sat` | Saturday |
  | `Wed` | Wednesday | `Sun` | Sunday |
  | `Thu` | Thursday | `Daily` / `*` | All days |

  **Day specifiers**:
  - **Range**: `Mon-Fri` (Mon through Fri inclusive), `Sat-Sun`, `Fri-Mon` (wrap-around - Fri, Sat, Sun, Mon)
  - **Comma list**: `Mon,Wed,Fri` (Monday, Wednesday, Friday only - useful for non-contiguous days)
  - **Single day**: `Sat`
  - **All days**: `Daily` or `*`

  > ⚠️ Common mistakes: `Thur`, `Tues`, `Mond`, `Friday`, `tuesday-friday` - all rejected. Use the strict 3-letter form: `Thu`, `Tue`, `Mon`, `Fri`, `Tue-Fri`.

  **Time format**: 24-hour `HH:MM` UTC. Overnight wraps are supported (`22:00-02:00` means 10 PM today through 2 AM tomorrow).

  **Examples**:
  - `Sat-Sun_02:00-06:00` - Weekends 2-6 AM UTC
  - `Mon-Fri_22:00-06:00` - Weeknights 10 PM - 6 AM UTC (overnight wrap)
  - `Mon-Thu_20:00-04:00` - Mon/Tue/Wed/Thu nights 8 PM - 4 AM UTC (excludes Fri night)
  - `Mon,Wed,Fri_01:00-05:00` - Only Mon/Wed/Fri 1-5 AM UTC (note the **comma list**, not range)
  - `Sat_22:00-06:00;Sun_22:00-06:00` - Two separate Sat-night and Sun-night windows
  - `Sat-Sun_00:00-23:59` - Whole weekend
  - `Daily_02:00-06:00` (or `*_02:00-06:00`) - Every day 2-6 AM UTC
  - `Fri-Mon_22:00-06:00` - Long weekend (Fri/Sat/Sun/Mon nights, with wrap)

  > **Tag-value matching is case-insensitive everywhere** - both the day tokens above and the `UpdateRing` value used by `-ScopeByUpdateRingTag -UpdateRingValue 'Prod1'` (resolved via Azure Resource Graph `=~` operator), so `prod1`/`Prod1`/`PROD1` all match the same set of clusters.
- **UpdateExclusionsWindow** (optional; renamed from `UpdateExclusions` in v0.7.90): Change-freeze periods. Format: `YYYY-MM-DD/YYYY-MM-DD`. Multiple ranges separated by `,`. Wildcards with `*` for recurring annual patterns. Examples:
  - `2026-12-20/2027-01-03` - Specific date range
  - `20**-12-20/20**-01-03` - Every year, Dec 20 to Jan 3
- **UpdateExcluded** (optional; v0.7.90): Operator hard override. Values `True` / `False` / `1` / `0` (case-insensitive). `True` or `1` skips the cluster in `Start-AzLocalClusterUpdate` with `Status = ExcludedByTag`, regardless of `UpdateRing` scope, `UpdateSideloaded` state, or `UpdateStartWindow` / `UpdateExclusionsWindow` schedule. Leave empty or set to `False` to keep the cluster eligible. If the column is absent on a cluster, `Set-AzLocalClusterUpdateRingTag` default-stamps `UpdateExcluded=False` so the tag is visible in the Azure portal and ready to flip when needed.

Save the file.

**Step 3: Apply all tags from CSV**
```powershell
# Apply UpdateRing, UpdateStartWindow, UpdateExclusionsWindow, and UpdateExcluded tags from the edited CSV
Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\cluster-inventory.csv"

# Preview changes first with -WhatIf
Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\cluster-inventory.csv" -WhatIf

# Force overwrite existing tags
Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\cluster-inventory.csv" -Force
```

The function reads `UpdateStartWindow`, `UpdateExclusionsWindow`, and `UpdateExcluded` columns from the CSV (if present) and sets them alongside the `UpdateRing` tag in a single PATCH operation. Existing tags on the cluster are preserved. If `UpdateExcluded` is absent on the cluster AND not specified in the CSV/parameters, the function default-stamps `UpdateExcluded=False` so the tag is discoverable in the Azure portal.

**Step 4: Verify tags were applied**
```powershell
# Re-run inventory to confirm all tags
Get-AzLocalClusterInventory
```

**Step 5: Test schedule logic interactively (optional)**
```powershell
# Test if a specific time would be allowed by a maintenance window
Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow "Sat-Sun_02:00-06:00" -UpdateExclusionsWindow "2026-12-20/2027-01-03"

# Test a specific future time
Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow "Sat_02:00-06:00" -TestTime ([datetime]"2026-04-19 03:00:00")
```

**Step 6: Update clusters by UpdateRing**
```powershell
# Update all clusters in the "Pilot" ring first
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Pilot" -Force

# After validation, update Wave1
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force

# Finally, update Production
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Production" -Force
```

> 📝 **Note**: Tag operations require `Microsoft.Resources/tags/read` and `Microsoft.Resources/tags/write` permissions. Cluster inventory queries require `Microsoft.ResourceGraph/resources/read`. See [RBAC Requirements](#rbac-requirements) for the complete list. The v0.7.1 sideloaded-payload workflow (`UpdateSideloaded` / `UpdateVersionInProgress`) reads and writes through the same two tag permissions - **no new RBAC required**.

### 7a. Sideloaded Payload Workflow (v0.7.1)

Use this workflow when an admin manually copies an Azure Local update payload onto a cluster (sideloading) and wants the module to gate `Start-AzLocalClusterUpdate` until the payload is in place, then automatically clear the gate once the run succeeds.

> **Automating this flow for disconnected clusters:** use the self-hosted **Update: 2 - Sideload Updates** pipeline. Its authoritative configuration is `config/sideload-settings.yml`; it handles catalog planning, bounded Robocopy, verification, import/discovery, state ownership, and reporting. See the [sideload operations guide](Automation-Pipeline-Examples/docs/sideload.md). The manual tag flow below remains available for one-off staging.

> ✅ **Fully opt-in.** Clusters that do not have the `UpdateSideloaded` tag behave exactly as in v0.7.0 - the gate is bypassed entirely and updates proceed through the existing schedule/health checks. You only "join" the workflow by setting the tag on a specific cluster when you want to stage a sideloaded payload. No new RBAC, no fleet-wide opt-out switch needed.

**Two tags coordinate the workflow:**

| Tag | Set by | Values | Purpose |
|-----|--------|--------|---------|
| `UpdateSideloaded` | **Operator** (you) | `True` / `False` / `1` / `0` (case-insensitive) | When `False`/`0`, `Start-AzLocalClusterUpdate` skips the cluster with `Status = SideloadedBlocked`. When `True`/`1`, updates proceed normally. Empty/missing tag = no sideloaded gate (legacy behaviour). |
| `UpdateVersionInProgress` | **Module** (do not set manually) | The update name (e.g. `Solution12.2604.1003.209`) | Written automatically when an update kicks off. Cleared automatically once the matching run succeeds. Used to ensure auto-reset only fires for the run we actually started. |

**Typical flow (per cluster):**

1. **Stage**: Operator sets `UpdateSideloaded = False` on a target cluster, then sideloads the payload onto the cluster's nodes out-of-band. See [Import and discover Azure Local updates in offline / disconnected scenarios](https://learn.microsoft.com/en-us/azure/azure-local/update/import-discover-updates-offline-23h) for information and download links required to sideload updates.

   Set the gate tag on a cluster using the Az PowerShell module. `-Operation Merge` preserves all other tags already on the cluster (e.g. `UpdateRing`) and only adds/updates the `UpdateSideloaded` key:

   ```powershell
   $clusterId = '/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<cluster-name>'
   Update-AzTag -ResourceId $clusterId -Tag @{ UpdateSideloaded = 'False' } -Operation Merge
   ```

2. **Block while not ready**: Any pipeline run of `Start-AzLocalClusterUpdate` against this cluster sees `UpdateSideloaded = False` and skips with `Status = SideloadedBlocked` (visible in CSV log, JUnit XML, and HTML report skipped tally). The schedule and health gates are not even consulted.
3. **Release**: Operator confirms the payload is in place and flips `UpdateSideloaded = True`:

   ```powershell
   Update-AzTag -ResourceId $clusterId -Tag @{ UpdateSideloaded = 'True' } -Operation Merge
   ```
4. **Update**: Next pipeline run sees `True`, proceeds through schedule/health gates, and starts the update. As the run kicks off, the module writes `UpdateVersionInProgress = <update name>` to the cluster.
5. **Auto-reset**: When `Get-AzLocalUpdateRuns` next reads runs for this cluster, it inspects the latest run. If it is `Succeeded` **and** its update name matches `UpdateVersionInProgress`, it flips `UpdateSideloaded` back to `False` and clears `UpdateVersionInProgress` in a single PATCH. The cluster is now re-armed for the next sideloaded payload.

**Auto-reset action values** (returned by `Reset-AzLocalSideloadedTag` and surfaced in `Get-AzLocalUpdateRuns` verbose logs):

| Action | Meaning |
|--------|---------|
| `Reset` | Match success path - both tags flipped/cleared in a single PATCH. |
| `OrphanCleared` | `UpdateSideloaded` absent (cluster opted out) but a stale `UpdateVersionInProgress` tag matched the latest succeeded run name - the orphan tag was cleared. `UpdateSideloaded` is **never** written in this path. |
| `NoTag` | `UpdateSideloaded` tag is absent and there is nothing to clean up. Cluster is fully outside the workflow. |
| `NoRuns` | `UpdateSideloaded=True` but the cluster has no update-run history yet. Tag preserved. |
| `RunNotSucceeded` | Latest run is `InProgress` / `Failed`. Tag preserved (will be re-evaluated next run). |
| `Skipped` | `UpdateSideloaded=False` already, malformed tag value, version mismatch, or PATCH failure. Reason in the `Message` field. |

**Manual reset (escape hatch):**

```powershell
# Inspect (no changes) - relies on the default match-and-only-if-Succeeded gate
Reset-AzLocalSideloadedTag -ClusterName 'mycluster' -ResourceGroupName 'rg-fleet' -WhatIf

# Force-reset a stuck cluster (skips the run-success / version-match check). Use with care.
Reset-AzLocalSideloadedTag -ClusterName 'mycluster' -ResourceGroupName 'rg-fleet' -Force

# Bulk reset by tag (explicit scope - no implicit -AllClusters)
Reset-AzLocalSideloadedTag -ScopeByUpdateRingTag -UpdateRingValue 'Wave1'
```

`Reset-AzLocalSideloadedTag` is the same logic the auto-reset path uses; the difference is the entry point. Default behaviour requires `latest run = Succeeded` and a case-insensitive match between the run's update name and `UpdateVersionInProgress`. `-Force` bypasses both checks.

**Opt out of auto-reset:**

```powershell
# Read-only paths can suppress the PATCH
Get-AzLocalUpdateRuns -ClusterName 'mycluster' -ResourceGroupName 'rg-fleet' -SkipSideloadedReset
```

> ℹ️ **Concurrent updates**: Azure Local's on-cluster ECE component already serialises updates - it will refuse to start a second run while another is in flight or in a failed state. The match-on-update-name guardrail in this workflow is a defense-in-depth check on top of that, not a replacement for it.

> 🔐 **RBAC**: Unchanged. The workflow only reads and writes cluster tags, which already require `Microsoft.Resources/tags/read` and `Microsoft.Resources/tags/write` (see [RBAC Requirements](#rbac-requirements)).

### 8. Assess Readiness and Health BEFORE Applying Updates (Recommended)

Before rolling updates to a wave, confirm every cluster in that wave is actually ready - on the supported solution version, healthy, with an update in a `Ready` / `ReadyToInstall` state, and not blocked by an SBE prerequisite. `Start-AzLocalClusterUpdate` will already skip unhealthy clusters automatically, but running the assessment as a separate **readiness report** surfaces exactly what needs remediation so you can open tickets in parallel with the rollout - you do not need to block the entire wave for one or two unhealthy clusters.

**Step 1: Run the readiness check for the target ring**

```powershell
# Returns one row per cluster with: ReadyForUpdate, HealthState, UpdateState,
# HasPrerequisiteUpdates, SBEDependency, UpdateStartWindow, UpdateExclusionsWindow, UpdateExcluded
$readiness = Get-AzLocalClusterUpdateReadiness `
    -ScopeByUpdateRingTag -UpdateRingValue 'Wave1' `
    -ExportPath 'C:\Reports\wave1-readiness.csv' -PassThru

# Quick triage
$readiness | Group-Object ReadyForUpdate | Select-Object Name, Count
$readiness | Where-Object { -not $_.ReadyForUpdate } |
    Select-Object ClusterName, HealthState, UpdateState, HasPrerequisiteUpdates, SBEDependency
```

> 🎯 **Constrain readiness to an allow-list (v0.9.1).** By default the readiness
> check treats the latest `Ready` update as the recommendation. To instead gate
> readiness against the same `allowedUpdateVersions` allow-list used by the apply
> schedule, pass `-SchedulePath ./config/apply-updates-schedule.yml` (schema v2;
> per-ring override beats the top-level fleet default) or pass an explicit
> `-AllowedUpdateVersions '10.2604.0.123','10.2610.0.456'`. The reserved sentinel
> `Latest` means "no constraint". When a constraint is active, a cluster whose
> `Ready` updates all fall **outside** its allow-list is reported `UpToDate` /
> `ReadyForUpdate = $false` (there is no permitted action under the schedule); the
> raw Azure update-summary state is preserved in the new `AzureUpdateState` column
> alongside `AllowedUpdateVersions` and `AllowListSource`. The assess-update-readiness
> pipeline examples opt in automatically when a `./config/apply-updates-schedule.yml`
> file exists in the repo.

**Step 2: Drill into the Critical health failures that will block updates**

```powershell
# -BlockingOnly returns only Critical/update-blocking failures, suitable for CI/CD reporting
$health = Test-AzLocalClusterHealth `
    -ScopeByUpdateRingTag -UpdateRingValue 'Wave1' `
    -BlockingOnly `
    -ExportPath 'C:\Reports\wave1-health.csv' `
    -ExportFormat Csv `
    -PassThru

$health | Where-Object Severity -eq 'Critical' |
    Select-Object ClusterName, Title, Description, Remediation
```

**Step 3: Remediate Critical issues (outside this module's scope)**

Critical health failures must be fixed at the cluster / infrastructure layer - this module only *detects* them. Typical failure classes and where to remediate them:

| Failure class | Where to fix |
|---------------|--------------|
| Storage / drive / stamp health, ADDS/DC connectivity | Microsoft Learn: [Azure Local solution upgrades](https://learn.microsoft.com/en-us/azure-local/manage/update) and the cluster's own Windows Admin Center / Environment Checker output |
| SBE (Solution Builder Extension) / firmware / driver prerequisite | Your **hardware vendor's** SBE package (Dell APEX, HPE, Lenovo, DataON, etc.). `SBEDependency` / `HasPrerequisiteUpdates` identify the publisher + family + release notes URL. |
| Certificate, trust, or identity drift | Azure Local operations runbook for certificate rotation |
| Workload / VM / cluster resource state | Windows Admin Center "Update" workload + cluster validation; evacuate affected nodes first |

After remediation, re-run Step 1 and Step 2 to confirm `ReadyForUpdate = $true` and `Critical = 0` for the clusters you've fixed. Clusters that are still red can stay in the ring - `Start-AzLocalClusterUpdate` will skip them - but track them as follow-ups so the fleet converges over time.

**Step 4: Only now, apply updates**

```powershell
# Updates only start if the maintenance window / exclusion tags allow it.
# Start-AzLocalClusterUpdate will *still* re-check health per cluster and
# skip anything that has regressed since the assessment.
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue 'Wave1' -Force
```

**Step 5: Watch progress and capture a report**

```powershell
# Follow the run (PS 5.1 and Core safe)
Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue 'Wave1'

# Produce a self-contained HTML report for stakeholders (works for any scope)
New-AzLocalFleetStatusHtmlReport `
    -ScopeByUpdateRingTag -UpdateRingValue 'Wave1' `
    -OutputPath 'C:\Reports\wave1-status.html' `
    -IncludeHealthDetails -IncludeUpdateRuns
```

> 💡 **CI/CD**: this same assess -> remediate -> apply flow is wired into the pipeline examples under `Automation-Pipeline-Examples/`: see the `assess-update-readiness.yml` pipeline (report-only) and the `check-readiness` job inside `apply-updates.yml`.

## Available Functions

The module exports **36 cmdlets**. Full detail (parameters, ARM API surface, RBAC reminders, examples) lives in [docs/cmdlet-reference.md](docs/cmdlet-reference.md). Quick orientation:

| Cmdlet group | Typical use | Examples |
|--------------|-------------|----------|
| **Authentication** | Wire up a Service Principal or read the current `az` context | `Connect-AzLocalServicePrincipal` |
| **Single-cluster reads** | Inventory, available updates, last update run, current update state | `Get-AzLocalClusterInfo`, `Get-AzLocalClusterInventory`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalUpdateRuns` |
| **Single-cluster gates** | Pre-flight readiness + health checks before applying an update | `Get-AzLocalClusterUpdateReadiness`, `Test-AzLocalClusterHealth` |
| **Single-cluster writes** | Apply an update; tag a cluster into a ring; sideloaded-payload tag flow | `Start-AzLocalClusterUpdate`, `Set-AzLocalClusterUpdateRingTag`, `Reset-AzLocalSideloadedTag` |
| **Fleet reads** | Daily fleet status reports, fleet health audits, version distribution | `Get-AzLocalFleetStatusData`, `New-AzLocalFleetStatusHtmlReport`, `Get-AzLocalFleetHealthOverview`, `Get-AzLocalFleetHealthFailures`, `Get-AzLocalFleetProgress` |
| **Fleet gates** | Schedule coverage audit, fleet-wide health gate before a wave | `Test-AzLocalApplyUpdatesScheduleCoverage`, `Test-AzLocalFleetHealthGate`, `Test-AzLocalUpdateScheduleAllowed` |
| **Fleet writes** | Wave-scoped update launcher with pause/resume state file | `Invoke-AzLocalFleetOperation`, `Stop-AzLocalFleetUpdate`, `Resume-AzLocalFleetUpdate`, `Export-AzLocalFleetState` |
| **Pipeline support** | Refresh bundled `*.yml` workflow templates while preserving operator edits | `Update-AzLocalPipelineExample` |
| **Diagnostics** | Resolve effective ring for a cluster, latest solution version from the public catalog | `Resolve-AzLocalCurrentUpdateRing`, `Get-AzLocalLatestSolutionVersion`, `Get-AzLocalUpdateRunFailures` |

Full signatures, ARM endpoints, and worked examples: **[docs/cmdlet-reference.md](docs/cmdlet-reference.md)**.
## Update States

The ARM update lifecycle has two related state machines you should understand before reading the cmdlet output:

1. **Cluster Update Summary state** (`Microsoft.AzureStackHCI/clusters/updateSummaries/default`) - rolls up the *latest* run of *any* update against the cluster. Values include `Succeeded`, `Failed`, `InProgress`, `NotApplicable`, `Unknown`.
2. **Individual Update state** (`Microsoft.AzureStackHCI/clusters/updates/<version>`) - per-update lifecycle: `HasPrerequisite`, `Ready`, `Downloading`, `Installing`, `Installed`, `Failed`.

The module's gating cmdlets (`Get-AzLocalClusterUpdateReadiness`, `Test-AzLocalClusterHealth`) reason about these states explicitly. Background on transitions, edge cases (`Unknown` after a failed sideloaded payload, `HasPrerequisite` chains, manual `Stop-AzLocalFleetUpdate` rollbacks), Azure CLI direct usage, Az.StackHCI parity, and the CI/CD design assumptions all live in [docs/concepts.md](docs/concepts.md).
## Troubleshooting

Most common issues fall into one of these buckets:

- **`az login` succeeds but `Get-AzLocalClusterInventory` returns nothing** - the identity has tenant-level `Reader` but not subscription `Reader` on the subscriptions where clusters live. Run the **`authentication-test`** pipeline to enumerate the subscriptions the identity actually sees.
- **`Start-AzLocalClusterUpdate` returns `Unauthorized`** - the identity has `Azure Stack HCI Reader` instead of `Azure Stack HCI Administrator`. See [docs/rbac.md](docs/rbac.md).
- **`Get-AzLocalFleetHealthOverview` returns `ParserFailure: token=<EOF>`** - the underlying ARG query exceeded the `az graph query -q` Windows argument-truncation threshold (~2.8 KB). Fixed in v0.7.74; refresh your pipeline pins to v0.7.74+.
- **`Test-AzLocalClusterHealth` reports duplicate findings** - ARM upstream sometimes emits byte-identical `healthCheckResult` rows; fixed in v0.7.76 via row-tuple dedup.
- **`WARNING: Unable to encode the output with cp1252 encoding`** - Windows console code page conflict with cmdlet emoji output. Set `$OutputEncoding = [System.Text.Encoding]::UTF8` before invoking.
- **Readiness says `RecommendedUpdate=<X>` but `<X>` is already installed** - ARM `updateSummaries` cache is stale. Run `Get-AzLocalUpdateRuns -Refresh` to force ARM to re-evaluate.

Full symptom-to-fix table including verbose-logging recipes: [docs/troubleshooting.md](docs/troubleshooting.md).
## License

This code is provided as-is for educational and reference purposes.

---

## Release History

The full What's-New history (v0.7.81 and earlier) has moved to [docs/release-history.md](docs/release-history.md).

The most recent release notes for **v0.9.28** stay above under [`What's New in v0.9.28`](#whats-new-in-v0928).

### What's New in v0.9.27

**Scheduled pipelines now avoid crowded five-minute boundaries, every pipeline job has an explicit maximum runtime, and fleet settings can safely widen tagged update-start windows.** All active schedules start at minute 17. Config: 3 uses a seven-minute Apply lead, `AZLOCAL_MAX_PIPELINE_RUNTIME_MINUTES` controls the native per-job timeout, and schema v4 adds strict before/after update-window allowances with backed-up migration. No public function or export-count change (71); pipeline pins are updated to `0.9.27`. See [CHANGELOG.md](CHANGELOG.md#0927---2026-07-28) for full details.

### What's New in v0.9.26

**Update: 1 now respects fleet admission before collecting child resources, avoids duplicate Azure reads, and keeps a Ready solution actionable when a separate SBE update has prerequisites.** Update-summary, available-update, and blocking-health ARG queries are constrained to admitted cluster IDs in command-line-safe batches. Sparse direct ARM verification reconciles temporary ARG gaps, and clean runs publish valid zero-test JUnit artifacts. No public function or export-count change (71); pipeline pins are updated to `0.9.26`. See [CHANGELOG.md](CHANGELOG.md#0926---2026-07-27) for full details.

### What's New in v0.9.25

**Configured fleet-summary limits above 1,000 now render correctly, and dynamic pipeline table values remain inside their Markdown rows.** The Ready-for-Update renderer accepts the documented 2,000-row range. A shared normalizer hardens ARM, ARG, tag, and free-text cells across readiness, apply, connectivity, health, update-status, monitor, and schedule reports. Config: 3 makes its missing-tag remediation table collapsible but open by default and shows four CRON firings per calendar day before truncation. The schedule template explicitly documents same-week/different-day rows and order-independent per-row `allowedUpdateVersions`. No public function or export-count change (71); pipeline pins are updated to `0.9.25`. See [CHANGELOG.md](CHANGELOG.md#0925---2026-07-27) for full details.

### What's New in v0.9.24

**Fleet settings gain grouped tag admission, and sparse Azure payloads no longer cause strict-mode collection failures.** Schema v3 uses AND semantics for tags inside each named `scope.clusterTagFilters` group and OR semantics across groups; a one-tag group is a singular alternative. Normal pipeline refreshes create an exact version-specific backup and migrate schema v1/v2 to v3, including fully commented files that remain inert. Shared ARG and Azure CLI JSON boundaries discard null top-level rows, and ARM REST plus nested cloud arrays skip null placeholders before inspecting properties. `reporting.maxRowsPerTable` accepts up to 2,000 rows. No public function or export-count change (71); pipeline pins are updated to `0.9.24`. See [CHANGELOG.md](CHANGELOG.md#0924---2026-07-24) for full details.

### What's New in v0.9.23

**Fleet settings schema v2 adds one global, source-controlled cluster admission policy across every GitHub Actions and Azure DevOps pipeline.** Configure one or more `scope.clusterTagFilters` name/value pairs; all pairs must match, missing tags exclude a cluster, and matching is exact and case-insensitive. Cluster discovery and mutation paths share that membership, child update resources inherit it through normalized parent IDs, connectivity uses cluster-reported physical nodes, and Resource Bridge attribution reports ambiguity in shared resource groups. Normal pipeline updates safely migrate active or legacy commented schema-v1 settings with an exact backup while preserving operator content; every pipeline banner snapshots active management groups and tag filters. No public/export change (71). See [CHANGELOG.md](CHANGELOG.md#0923---2026-07-23) for full details.

### What's New in v0.9.21

**Monitor: 2 - Fleet Health Status: the "Cluster Counts" summary table now counts each cluster once, by its highest failing-check severity, and the icons no longer duplicate the severity word.** The unhealthy bucket is split into Critical and Warning-only rows; a cluster with both severities is counted in Critical only. The Other bucket is renamed for In progress / Unknown health, count rows use bare-glyph icons, and new outputs expose `critical_clusters` / `warning_only_clusters`. **Monitor: 1** adds bare-glyph status indicators to each connectivity KPI row. The Sideload updates guide also gains dedicated navigation, external endpoint requirements, and an accuracy pass. No public function or export-count change (69). See [CHANGELOG.md](CHANGELOG.md#0921---2026-07-15) for full details.

### What's New in v0.9.20

**Monitor: 3 - Fleet Update Status - the "Fleet - SBE Version(s) Distribution" table now groups by hardware OEM and reads the correct YYMM.** The table groups **primarily by hardware OEM** (Dell / HPE / Lenovo / Microsoft / ...) and **secondarily by SBE YYMM**, sorted by OEM name, with **OEM Provider** as the first column. The OEM is resolved from each cluster's reported node manufacturer (`properties.reportedProperties.nodes[].manufacturer`) via the new private helper `Resolve-AzLocalHardwareOem`; a new readiness-row field `SbeOemProvider` carries it (also in `readiness-status.csv`). SBE YYMM is now read from the **third** version octet (`<major>.<minor>.<YYMM>.<build>`, e.g. `5.0.2605.1000` -> `2605`); v0.9.19 incorrectly used the second octet. Clusters with no vendor SBE (base placeholders `2.0.0.0` / `2.1.0.0` and any cluster with no SBE package) now show **N/A - No SBE Installed** for YYMM while still grouping under their hardware OEM. Export count unchanged at **69** (`Resolve-AzLocalHardwareOem` is private). See [CHANGELOG.md](CHANGELOG.md#0920---2026-07-08) for the full v0.9.20 entry.

### What's New in v0.9.19

**Update: 1 - Assess Update Readiness fixes an SBE-prerequisite mis-classification + adds two operator aids; Monitor: 3 adds two tables.** **Fixed:** a cluster with a genuinely-`Ready` update is no longer mislabelled "SBE Prerequisite / Not-Ready" just because it also has a `HasPrerequisite` SBE update - the shared classifier `Get-AzLocalClusterReadinessStatus` (Update: 1 / Apply-Updates readiness gate / Monitor: 3) tested SbeBlocked before ReadyForUpdate; it is now gated on there being no Ready update, so such clusters correctly classify as **Ready for Update** (only a cluster whose sole available update is the prereq item stays SBE-blocked). Assess Update Readiness also adds a **Status checked (UTC)** column (the updateSummary `lastChecked` - when Azure last scanned the cluster; new row field `StatusLastChecked`) and an **Updates filtered out by the allow-list** fleet-aggregate table (Global vs Per-Ring scope + distinct cluster count; new step output `allowlist_filtered_updates` + PassThru `AllowListFilteredUpdateCount`). Monitor: 3 - Fleet Update Status adds a **Fleet - SBE Version(s) Distribution** table and an **Updates - Recent Successful Updates** table (State=Succeeded in the last 48h), and renames two headers. New step outputs `sbe_version_dist_count`, `recently_completed_48h`. No export-count change (69). See [CHANGELOG.md](CHANGELOG.md#0919---2026-07-08) for the full v0.9.19 entry.

### What's New in v0.9.18

**Follow-up strict-mode hardening after v0.9.17.** A live re-run of Update: 3 - Apply Updates showed the failed-update single-retry still crashed on one cluster with `The property 'steps' cannot be found on this object`. v0.9.17 guarded only the top-level `progress.steps` read in `Format-AzLocalUpdateRun`; the recursive step-tree walkers it calls (`Get-DeepestActiveStep`, `Get-CurrentStepPath`, `Get-DeepestErrorMessage`, `Find-DeepestError`) still read `$step.steps` / `status` / `name` / `errorMessage` **bare** and threw under `Set-StrictMode -Version Latest` on a leaf step omitting `steps`; all walker reads are now guarded with `PSObject.Properties[...]`. A broader strict-mode audit guarded more optional-field bare reads across `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalFleetStatusData`, `Get-AzLocalUpdateRunHealthEvidence` and `Get-AzLocalFleetHealthFailures`. Also new: a **Support disclaimer** footer (new exported helper `Add-AzLocalPipelineSupportFooter`, wired as a final `if: always()` step in all 20 templates) renders at the bottom of every pipeline run summary, plus a caveat line on the install-step version banner. Export count **68 -> 69**. `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.9.18`. See [CHANGELOG.md](CHANGELOG.md#0918---2026-07-07) for the full v0.9.18 entry.

### What's New in v0.9.16

**Pipeline bootstrap hardening + benign No Clusters Ready job made non-fatal.** The shared install step in all 20 templates hardened its transient-PSGallery-blip retry from 3 to 5 attempts with capped exponential backoff + jitter (10s, 20s, 40s, 60s cap), and the benign `no-clusters-ready` job (GH) / `NoClustersReady` stage (ADO) in `apply-updates` became `continue-on-error` / `continueOnError` so a persistent blip on a nothing-to-apply run no longer reds a healthy no-op. No public function/export change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.9.16`. See [CHANGELOG.md](CHANGELOG.md#0916---2026-07-06) for the full v0.9.16 entry.

### What's New in v0.9.15

**Update: 1 - Assess Update Readiness operator-guidance + Update: 2 FORCE allow-list fix.** Allow-list-held clusters get their own visible "Up to date - Ready update held by allow-list" table plus an "of which held by allow-list" summary sub-count (new PassThru `AllowListHeldCount`), and SBE-prerequisite Not-Ready clusters carry a manual-action knowledge note (review the Hardware OEM provider's docs + sideload the SBE update). Fixed: a FORCE (break-glass) apply on the manual path now HONOURS the `allowedUpdateVersions` allow-list instead of silently installing the latest Ready update - `Resolve-AzLocalPipelineUpdateRing` gains a `-ForceImmediateUpdate` switch (new private helper `Resolve-AzLocalForceAllowList`) that bypasses only the schedule window, never the version allow-list; both `apply-updates` templates forward the force input under the existing manual-only gating. Also corrected two fabricated REST targets in `docs/cmdlet-reference.md`. No public function/export change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.9.15`. See [CHANGELOG.md](CHANGELOG.md#0915---2026-07-02) for the full v0.9.15 entry.

### What's New in v0.9.14

**Version bump to publish the allow-list-suppressed Ready-update surfacing (PR #117) to the PowerShell Gallery, plus a pipeline-bootstrap retry.** The shared "Install AzLocal.UpdateManagement from PSGallery" step in all 20 GitHub Actions + Azure DevOps templates now wraps `Install-Module` in a 3-attempt exponential-backoff (10s, then 20s) retry so a transient PSGallery lookup blip (`No match was found ... 'AzLocal.UpdateManagement'`) no longer fails the run on the first hit. `Export-AzLocalClusterUpdateReadinessReport` gained an `Available Ready updates` column and an `Up to Date *` marker + footnote for allow-list-suppressed clusters; `Get-AzLocalClusterUpdateReadiness` emits a per-cluster allow-list-mismatch warning and the `Select-AzLocalNextUpdateForCluster` matcher accepts both the full update `name` and the bare `properties.version`. No public function, parameter, or export-count change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.9.14`. See [CHANGELOG.md](CHANGELOG.md#0914---2026-07-02) for the full v0.9.14 entry.

### What's New in v0.9.13

**Bug fix - Monitor: 3 (Fleet Update Status) no longer crashes on a failed run with a short deepest-error message.** `Export-AzLocalFleetUpdateStatusReport`'s deepest-error truncation guard read `[string]$f.DeepestErrMsg.Length`, which PowerShell parses as `[string]($f.DeepestErrMsg.Length)` (member access binds tighter than the cast); it stringified the *length* and compared that string to `4000` **lexically**, pushing a short message into `.Substring(0,4000)` and throwing `Index and length must refer to a location within the string`. The message is now cast once (`$deepMsg = [string]$f.DeepestErrMsg`) before the integer length check; a regression test feeds a short message and asserts no throw. No public function, parameter, or export-count change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.9.13`. See [CHANGELOG.md](CHANGELOG.md#0913---2026-07-02) for the full v0.9.13 entry.

### What's New in v0.9.12

**Pipeline preflight guards - two confusing failure cascades become one clear run-summary message.** Adds two guard cmdlets and wires them into all 20 bundled pipeline templates (10 GitHub Actions + 10 Azure DevOps) so failures are visible in the **run summary** without drilling into agent step logs. `Assert-AzLocalAzureSubscriptionAccess` counts the `Enabled` subscriptions visible to the authenticated identity and, when none are visible, writes a remediation block to the run summary and throws - replacing the cryptic "No subscriptions found for \*\*\*" cascade. `Assert-AzLocalPipelineReport` verifies the collect step produced a report BEFORE the publish step fires its misleading "No test report files were found" warning. Both are wired into all 20 bundled templates (publish steps now skip on upstream failure); new private helper `Write-AzLocalPipelineError`. Also, Monitor: 2 - Fleet Health Status (`Export-AzLocalFleetHealthStatusReport`) adds an operator "Knowledge" note reminding operators to re-run the system health checks (`Invoke-SolutionUpdatePrecheck -SystemHealth`) after remediating a failure so the ARM-stored health results refresh. Export count 66 -> 68. `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.9.12`. See [CHANGELOG.md](CHANGELOG.md#0912---2026-06-27) for the full v0.9.12 entry.

### What's New in v0.9.11

A small fix + tuning release. Fixes the v0.9.1 assess-update-readiness pipeline failure (exit code 1 at the health step) and tightens the recommended in-flight monitor defaults. `Export-AzLocalClusterUpdateReadinessReport` no longer leaks `-SchedulePath` into `Test-AzLocalClusterHealth` (readiness clones `$scopeParams` into a dedicated `$readinessParams`), and `Export-AzLocalApplyUpdatesScheduleAudit` tightens the recommended in-flight monitor defaults (`-MonitorTrailingDays` 3 -> 1, `-MonitorInFlightHours` 6 -> 2). No public function, parameter, or export-count change (still 66). `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.9.11`. See [CHANGELOG.md](CHANGELOG.md#0911---2026-06-26) for the full v0.9.11 entry.

### What's New in v0.9.10

Hardens the optional subscription-exclusion **starter files** so they survive being opened and re-saved in Excel, and auto-heals files from the brief v0.9.1 format. The dropped `Excluded-Subscription-Ids.csv` is now a clean, comment-free header-only CSV; all operator guidance moves to a sidecar `Excluded-Subscription-Ids_README.txt`; and a new private helper `Repair-AzLocalExcludedSubscriptionCsv` rewrites a legacy commented CSV in place on the next `Copy`/`Update-AzLocalPipelineExample` run (idempotent on clean files). No public function, parameter, or export-count change (still 66). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.9.1` to `0.9.10`. See [CHANGELOG.md](CHANGELOG.md#0910---2026-06-26) for the full v0.9.10 entry.

### What's New in v0.9.1

**Readiness allow-list override, optional subscription-exclusion list, transient login retry, and a dry-run reporting fix.** `Get-AzLocalClusterUpdateReadiness` / `Export-AzLocalClusterUpdateReadinessReport` gained an opt-in `-SchedulePath` + `-AllowedUpdateVersions` allow-list override (new `AllowedUpdateVersions` / `AllowListSource` / `AzureUpdateState` columns; private resolver `Resolve-AzLocalClusterAllowList`). A new opt-in subscription-exclusion CSV (`AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH`) filters every Azure Resource Graph query, with two new public cmdlets `Get-AzLocalExcludedSubscription` / `Set-AzLocalExcludedSubscription` (export count 64 -> **66**). Every read-only pipeline task retries the transient `azure/login` OIDC failure once, and dry-run pipeline steps once again emit their full step summary + outputs (the `$WhatIfPreference` cascade that suppressed the reporting `Out-File` writes is fixed with `-WhatIf:$false`). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.9.0` to `0.9.1`. See [CHANGELOG.md](CHANGELOG.md#091---2026-06-26) for the full v0.9.1 entry.

### What's New in v0.9.0

**Managed repo README auto-drop.** `Copy-AzLocalPipelineExample` and `Update-AzLocalPipelineExample` now also drop a lightweight, link-first `README.md` into the customer repo root so a freshly set-up pipelines repo explains itself: what it is, how to refresh after a module release (`.\Update-Module-And-Pipelines.ps1`), and where the docs live. Operator content is never destroyed - the README is written only when the repo has no usable README (missing, whitespace-only, or a GitHub default stub), and a README carrying the hidden `<!-- AZLOCAL-README-VERSION -->` marker is version-gate refreshed in place; any other non-empty README is left untouched. Default-on for `-Platform GitHub|AzureDevOps`, suppressed by `-SkipReadme`, skipped for `-Platform All`. The turnkey `Update-Module-And-Pipelines.ps1` template marker is bumped `1.1.0` -> `1.2.0` to also stage the managed README. Additive - no public function, parameter-removal, or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.99` to `0.9.0`. See [CHANGELOG.md](CHANGELOG.md#090---2026-06-25) for the full v0.9.0 entry.

### What's New in v0.8.99

A small follow-up to the v0.8.98 turnkey updater: the dropped `Update-Module-And-Pipelines.ps1` now **stages itself** so its own version-gated self-refresh is committed and pushed automatically. When a future module release ships an improved updater template, `Update-AzLocalPipelineExample` (called inside the script) version-refreshes the dropped script **in place**; in v0.8.98 the script's scoped `git add` staged only the workflow folder + `config`, so that self-refresh was left as an uncommitted working-tree change. The template now resolves its own repo-relative path from `$PSCommandPath` (only when the script actually lives inside the repo) and appends it to the staged paths, so the self-update is committed and pushed alongside the regenerated YAMLs. The updater template marker is bumped `1.0.0` -> `1.1.0`. Additive - no public function, parameter-removal, or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.98` to `0.8.99`. See [CHANGELOG.md](CHANGELOG.md#0899---2026-06-25) for the full v0.8.99 entry.

### What's New in v0.8.98

**Turnkey "refresh after every release" updater for the customer repo.** `Copy-AzLocalPipelineExample` now also drops a self-contained `Update-Module-And-Pipelines.ps1` into the repo root (with the chosen platform + workflow subpath baked in): it installs the latest module only when newer, regenerates the pipeline YAMLs via `Update-AzLocalPipelineExample` (preserving `BEGIN/END-AZLOCAL-CUSTOMIZE` edits), then commits + pushes under ShouldProcess (`-WhatIf`/`-NoPush`). Default-on for single-platform modes, suppressed by `-SkipStarterUpdater`, skipped for `-Platform All`. Existing repos get it via `Update` too. The dropped script is version-stamped (`# AZLOCAL-UPDATER-VERSION`, a dedicated template semver from `1.0.0`) and self-refreshes in place only when its marker is strictly older - markerless/operator-owned files are preserved. The maintainer `Test-Pipelines.ps1` was renamed to `Tools/Update-Module-And-Pipelines.ps1` (Tools/ is stripped from the package, fixing a prior nupkg leak). Additive - no public API or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.97` to `0.8.98`. See [CHANGELOG.md](CHANGELOG.md#0898---2026-06-25) for the full v0.8.98 entry.

### What's New in v0.8.97

**Update-readiness reporting clarity across the fleet reports, plus intelligent detection of stale "Up to Date" clusters in the Apply Updates readiness table.** `Get-AzLocalUpdateRunFailures` (Detail view) gains an `UpdateRing` column from the cluster ARM `UpdateRing` tag; Monitor: 3 and Assess Readiness gain a shared "Clusters - Ready for Update" table (Assess Readiness also writes a separate `ready-for-update.csv`); and the Apply Updates "Cluster Readiness" table now flags clusters reporting "Up to Date" against a newer public manifest build as **Update Available (stale assessment)** and adds a **Support** column. The "All clusters detail" / "Fleet Health Overview" tables are collapsed behind an expander. Report-only and additive - no public API, parameter, or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.96` to `0.8.97`. See [CHANGELOG.md](CHANGELOG.md#0897---2026-06-24) for the full v0.8.97 entry.

### What's New in v0.8.96

**Follow-up to v0.8.95 that surfaces the stalled / orphaned in-flight run signal in the prominent pipeline summary output (the JUnit test-reporter check), not just the artifact CSV.** A new top-priority branch in the in-flight `<testcase>` cascade in `Export-AzLocalUpdateRunMonitorReport` emits `Status` / failure `Type` = `Stalled` whenever `IsStalled` is set (previously a frozen `InProgress` run was reported only as a long-running step). The stalled output spells out the manual remediation (the run is NOT auto-retried by the single-retry job) and the bundled `azurelocal-itsm.yml` gains an additive `Stalled:` trigger key. Report-only and additive - no public API, parameter, or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.95` to `0.8.96`. See [CHANGELOG.md](CHANGELOG.md#0896---2026-06-24) for the full v0.8.96 entry.

### What's New in v0.8.95

**Adds a guarded, opt-in ONE-TIME automatic retry of FAILED Azure Local cluster updates, plus the transient-error and stalled-run hardening that motivated it.** New cmdlets `Invoke-AzLocalFailedUpdateRetry` (per-cluster primitive - re-issues the portal "Try again" `updates/{name}/apply` action only when the updateSummary state is `NeedsAttention`/`UpdateFailed`/`PreparationFailed`; an in-progress or stalled run is skipped), `Invoke-AzLocalReadinessGatedFailedUpdateRetry` (Apply-Updates fan-out), and `Add-AzLocalFailedUpdateRetryHintSummary` (discoverability notice). The one-time guard is a durable `UpdateRetryAttempted` tag that auto-clears once the retried run succeeds; the capability is OFF by default and gated by `FAILED_UPDATES_SINGLE_RETRY`. Also ships `Export-AzLocalUpdateRunMonitorReport -StalledNoProgressHours` stalled/orphaned-run detection and `Invoke-AzResourceGraphQuery` transient-network retry. Export count 61 -> 64. `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.94` to `0.8.95`. See [CHANGELOG.md](CHANGELOG.md#0895---2026-06-23) for the full v0.8.95 entry.

### What's New in v0.8.94

**Expands `BEGIN/END-AZLOCAL-CUSTOMIZE` marker coverage across every bundled CI/CD pipeline YAML (GitHub Actions and Azure DevOps)** so operator-owned infrastructure values survive `Update-AzLocalPipelineExample` - including with `-Force`. Three new uniquely-named marker region families wrap the Azure DevOps WIF service connection (`service-connection-<job>`), the hosted agent pool / GitHub `runs-on:` label (`runner-target-<job>`), and the sideload self-hosted pool/runner (`sideload-runner-<job>`); 45 marker pairs across 20 files. The merge engine and parser were already generic, so no cmdlet code changed - template + docs + tests only. No public-API or export-count change (still 61). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.93` to `0.8.94`. See [CHANGELOG.md](CHANGELOG.md#0894---2026-06-19) for the full v0.8.94 entry.

### What's New in v0.8.93

**Fixes a Bad Request in the "Update: 1 - Assess Update Readiness" pipeline.** `Sync-AzLocalClusterUpdateSummary` (and the `Export-AzLocalClusterUpdateReadinessReport` stale-assessment auto-scan that calls it) POSTed the `checkUpdates` ARM action with no request body; the `2026-03-01-preview` API spec now requires one. The cmdlet now sends an empty JSON object `{}` (no properties are mandatory for a plain re-scan), validated end-to-end against a live cluster, and refreshes the now-stale RBAC comment to reflect that the v0.8.92 `updateSummaries/*` wildcard already authorizes `checkUpdates`. Bug-fix only - no API, parameter, or export-count change (still 61). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.92` to `0.8.93`. See [CHANGELOG.md](CHANGELOG.md#0893---2026-06-18) for the full v0.8.93 entry.

### What's New in v0.8.92

**The least-privilege custom role now grants the preview "Check for updates" (`checkUpdates`) action via a wildcard.** The bundled `Azure Stack HCI Update Operator (custom)` role swaps the explicit `Microsoft.AzureStackHCI/clusters/updateSummaries/read` action for the `Microsoft.AzureStackHCI/clusters/updateSummaries/*` wildcard. `az role definition create` / `update` rejects the explicit `.../updateSummaries/checkUpdates/action` leaf (still absent from the `Microsoft.AzureStackHCI` provider operations catalog as of 2026-06-18), but it accepts a wildcard whose prefix resolves to the registered `updateSummaries/read`, and Azure matches the enforced `checkUpdates/action` against that wildcard at authorization time. Doc / RBAC-only change - no behavioural, API, or export-count change (still 61). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.91` to `0.8.92`. See [CHANGELOG.md](CHANGELOG.md#0892---2026-06-20) for the full v0.8.92 entry.

### What's New in v0.8.91

**Operator-facing cleanup of stale `Step.N` pipeline references.** Removes the last "edit `Step.7_apply-updates.yml`" style instructions left over from the v0.8.7 filename de-numbering, so the report and audit output names the files operators actually have. Output / help text only - no behavioural, API, or export-count change (still 61). The intentional backward-compatibility `Step.N_*.yml` migration aliases in `Get-AzLocalPipelineManifest` are unchanged. `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.90` to `0.8.91`. See [CHANGELOG.md](CHANGELOG.md#0891---2026-06-20) for the full v0.8.91 entry.

### What's New in v0.8.90

**Event-driven, idle-aware in-flight update monitoring.** Update: 4 (Monitor In-Flight Updates) now runs right after Update: 3 (Apply Updates) starts an update, yet stays cheap the rest of the time. Adds a fleet-wide idle short-circuit on `Export-AzLocalUpdateRunMonitorReport` (`-SkipWhenIdle`, new private helper `Test-AzLocalUpdateRunsInFlight`), an apply-to-monitor event-driven trigger on both platforms (`apply-updates.yml` fires `monitor-updates.yml` after starting >=1 update, optional `MONITOR_TRIGGER_DELAY_MINUTES` 15-240), a 6-hourly default monitor cron (`0 */6 * * *`), and Config: 3 monitor-recommendation tuning inputs (`MonitorPollIntervalMinutes` / `MonitorTrailingDays` / `MonitorInFlightHours`). No public-API change (export count unchanged at 61 - the new helper is private). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.89` to `0.8.90`. See [CHANGELOG.md](CHANGELOG.md#0890---2026-06-20) for the full v0.8.90 entry.

### What's New in v0.8.89

**A sharper Config: 3 monitor-cron recommendation + a "which updates install, and when" runbook.** Tunes the schedule audit (`Export-AzLocalApplyUpdatesScheduleAudit`) so the **Recommended in-flight monitor schedule (Update: 4)** it prints only polls while an update can actually be in flight - instead of a blunt 24x7 cron - and adds a README section explaining the three layers that decide which updates install on which clusters and when. Replaces `-MonitorFiresPerHour` with `-MonitorPollIntervalMinutes` (`ValidateSet` 15/20/30/60/120/180/240, default 30) and adds `-MonitorInFlightHours` (`ValidateRange` 0-48, default 6). Monitor days now derive from `apply-updates-schedule.yml` ring eligibility (or the apply cron weekday) and monitor hours from the `UpdateStartWindow` span plus the in-flight buffer. Also catalog-checks, documents, and guards the `checkUpdates` RBAC action (deliberately omitted from the least-privilege role until it GAs). No public-API change (export count 61). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.88` to `0.8.89`. See [CHANGELOG.md](CHANGELOG.md#0889---2026-06-18) for the full v0.8.89 entry.

### What's New in v0.8.88

**"Check for updates" automation + stale-assessment detection.** Adds a new public cmdlet (`Sync-AzLocalClusterUpdateSummary`, export count 60 -> 61) and an opt-out auto-scan in `Export-AzLocalClusterUpdateReadinessReport` so an Azure Local cluster that reports "Up to date" while a newer solution build is actually available (a stale cached assessment) is detected and refreshed without leaving the pipeline. `Sync-AzLocalClusterUpdateSummary` POSTs the `updateSummaries/default/checkUpdates` ARM action (the programmatic equivalent of the portal **Check for updates** button); fire-and-forget by default, `-Wait` polls until `lastChecked` advances. Authorization / `403` failures on the refresh call are now surfaced (with the exact action name) and are non-fatal. `checkUpdates` is still a preview action not yet in the provider operations catalog, so it cannot be added to the least-privilege custom role yet - use `Azure Stack HCI Administrator` / `Contributor` or `-SkipStaleAssessmentScan` until it GAs. `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.87` to `0.8.88`. See [CHANGELOG.md](CHANGELOG.md#0888---2026-06-17) for the full v0.8.88 entry.

### What's New in v0.8.87

**Pipeline display-name rename + in-flight monitor ITSM auto-ticketing.** Renames the bundled pipeline display names into a three-group `Config: N` / `Monitor: N` / `Update: N` scheme (single-digit, replacing the former `Setup: 0N` / `Fleet: 0N` prefixes; filenames and `AZLOCAL-PIPELINE-ID` values unchanged). Renames the Fleet Connectivity Status "Orphan ARBs" output section to "Non-Azure Local and/or Orphan ARB appliances" with a caveat that an Arc resource bridge with no in-scope Azure Local cluster is not necessarily orphaned (also used by VMware vSphere / SCVMM). Joins the Update: 4 in-flight monitor to the ServiceNow ITSM connector so stuck / failed / attempt-without-run clusters auto-raise deduped incidents (`Export-AzLocalUpdateRunMonitorReport` emits per-`<testcase>` properties; opt-in `raise_itsm_ticket` / `raiseItsmTicket` step in `monitor-updates.yml`), and teaches the Config: 3 schedule auditor to recommend a monitor poll cadence (`-MonitorFiresPerHour`, `-MonitorTrailingDays`). Backward-compatible defaults; export count unchanged (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.86` to `0.8.87`. See [CHANGELOG.md](CHANGELOG.md#0887---2026-06-16) for the full v0.8.87 entry.

### What's New in v0.8.86

**Pipeline sidebar-ordering fix.** Renames the three onboarding pipeline templates from `Setup: 0N` to `Config: 0N` so the GitHub Actions sidebar (and the Azure DevOps Pipelines list) lists the onboarding / configuration workflows *ahead of* the `Fleet: 0N` operational workflows. Both surfaces sort alphabetically by the workflow `name:` / definition name, and `C` (Config) sorts before `F` (Fleet) - the previous `Setup:` prefix sorted *after* `Fleet:`. Display-name change only - filenames, `AZLOCAL-PIPELINE-ID` values, aliases, and `-PruneDeprecated` logic are unchanged. See [CHANGELOG.md](CHANGELOG.md#0886---2026-06-16) for the full v0.8.86 entry.

### What's New in v0.8.85

**Pipeline UX consolidation release.** Introduces Setup/Fleet naming in bundled pipelines, adds the merged GitHub onboarding workflow `setup-validate-and-inventory.yml` (Setup: 01), and updates pipeline refresh tooling to safely handle deprecated workflow cleanup with pipeline-ID verification. Also bumps bundled pipeline `GENERATED_AGAINST_MODULE_VERSION` pins to `0.8.85`. (Superseded in v0.8.86, which renames the `Setup: 0N` workflows to `Config: 0N`.) See [CHANGELOG.md](CHANGELOG.md#0885---2026-06-16) for the full v0.8.85 entry.

### What's New in v0.8.83

**Patch release. Fix-forward for v0.8.82 Item-5.** The new Step.08 `UpdateLastAttempt` reconciliation pass in `Export-AzLocalUpdateRunMonitorReport` reads `$inv.tags` from `Get-AzLocalClusterInventory`, but the v0.8.82 inventory projection did not carry the raw ARM `tags` bag - so the "Recent update attempts with no observable updateRun" section was silently always empty in production regardless of fleet state. v0.8.83 surfaces the raw `tags` bag on every inventory row (in-memory only; the on-disk CSV / JSON export keeps its explicit `$selectColumns` whitelist so artefacts continue to omit the raw bag). Also fixes the GitHub Actions `monitor-updates.yml` `jobs.outputs:` block to expose `attempts_without_run` to downstream jobs (the cmdlet was already emitting it in v0.8.82 - only the YAML wiring was missing), and a docstring drift in `Export-AzLocalUpdateRunMonitorReport` ("6 step outputs" -> "7 step outputs"). No public API change. Export count unchanged (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.82` to `0.8.83` across all bundled pipeline templates. See [CHANGELOG.md](CHANGELOG.md#0883---2026-06-15) for the full v0.8.83 entry and [docs/release-history.md](docs/release-history.md#whats-new-in-v0883) for the archived entry.

### What's New in v0.8.82

**Patch release. Step.05 + Step.10 step-summary UX polish from the v0.8.81 manual pipeline-run review.** Four small fixes; no public API or export-count change (still 60 exports). Step.05 Summary counts table no longer duplicates row labels (each row was reusing the shared `Get-AzLocalStatusIconMap` cell - which already includes its own label - AND appending a duplicate trailing label). Step.05 All clusters detail table sorts by **Status priority** first (`InProgress` -> `HealthFailure` -> `UpdateFailed` -> `ActionRequired` -> `SbeBlocked` -> `NeedsInvestigation` -> `ReadyForUpdate` -> `UpToDate`), then `UpdateRing` + `ClusterName`; Up-to-Date drops to the bottom so operators see actionable items first. Step.05 Not-Ready clusters Blocking reasons column derives an actionable token from the Status bucket when upstream `BlockingReasons` is empty (`UpdateInProgress (run in-flight)`, `UpdateState=<UpdateState>`, `PrerequisiteRequired (SBE update first)`, `NeedsInvestigation (no Update or Health signal)`, etc.; appends `; HealthState=Warning` when relevant). Step.10 Detailed Results Description column inline-vs-collapse threshold bumped from 120 to 280 characters in `Export-AzLocalFleetHealthStatusReport`. `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.81` to `0.8.82` across all bundled pipeline templates. See [CHANGELOG.md](CHANGELOG.md#0882---2026-06-15) for the full v0.8.82 entry and [docs/release-history.md](docs/release-history.md#whats-new-in-v0882) for the archived entry.

### What's New in v0.8.81

**Patch release. Step summary polish across Steps 05-10.** Fixes a Step.10 KPI counting bug, surfaces drive/volume-level detail in the Step.10 health-failure renderer, and consolidates status-icon / cluster-deep-link / Ctrl-click-tip rendering onto three new shared private helpers so Steps 05-09 stay consistent and the Azure DevOps step summary no longer leaks literal GitHub-Markdown shortcodes (`:white_check_mark:`, etc.) into the rendered output. Step.10 KPI block is now split into `Cluster Counts` (Total / Healthy / Unhealthy / **Other**, where Other captures `In progress` / `Unknown` / `Health check failed` clusters previously dropped) and `Failing Checks Breakdown` (Total / Critical / Warning / Distinct Reasons); new `other_clusters` step output and `OtherClusters` `-PassThru` field. Detailed Results columns reordered to put Title first and add a collapsible `<details>` Description block surfacing drive/volume-level detail. Three new Private helpers: `Get-AzLocalStatusIconMap` (host-aware icon map), `Get-AzLocalClusterPortalLink` (portal deep-link wrapper) and `Get-AzLocalCtrlClickTip` (single-source Ctrl-click banner). No public API or export-count change (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.80` to `0.8.81` across all bundled pipeline templates. See [CHANGELOG.md](CHANGELOG.md#0881---2026-06-17) for the full v0.8.81 entry and [docs/release-history.md](docs/release-history.md#whats-new-in-v0881) for the archived entry.

### What's New in v0.8.80

**Minor release. Pipeline failure-rendering improvements** bundled as three additive changes targeting the Step.05 / Step.08 / Step.09 / Step.10 step summaries. (Q1) `Get-AzLocalUpdateRunFailures` attaches a `HealthCheckEvidence` array column with same-cluster Critical health-check entries within +/-2h of a HealthCheck-category run (new private helper `Get-AzLocalUpdateRunHealthEvidence`; opt-out via `-EnrichWithHealthEvidence:$false`). (Q2) `Get-AzLocalFleetHealthFailures` (Step.10) and `Test-AzLocalClusterHealth` (Step.05) project per-check `Title` and full `TargetResourceID`; `Export-AzLocalFleetHealthStatusReport` adds Title as a column and wraps TargetResourceName in a portal hyperlink. (Q3) Both deepest-error walkers (`Resolve-AzLocalUpdateRunDeepestError`, `Get-DeepestErrorMessage`) now capture step `description` alongside `errorMessage`; new `DeepestStepDescription` column on `Get-AzLocalUpdateRunFailures`; new `ErrorDescription` field on `Format-AzLocalUpdateRun` / `Get-AzLocalUpdateRuns -PassThru`; Step.08 + Step.09 renderers combine the two in markdown failure cells and JUnit bodies. No public API or export-count change (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.79` to `0.8.80` across all bundled pipeline templates. See [CHANGELOG.md](CHANGELOG.md#0880---2026-06-16) for the full v0.8.80 entry and [docs/release-history.md](docs/release-history.md#whats-new-in-v0880) for the archived entry.

### What's New in v0.8.78

**Patch release. Pipeline-summary UX polish** on the bundled apply-updates pipeline (Step.07). Three improvements landed together: (1) `ScheduleBlocked` / `SideloadedBlocked` / `ExcludedByTag` outcomes now render as JUnit `<skipped>` instead of `<failure>` so `dorny/test-reporter` no longer flips Step.07 RED on by-design gate-respect outcomes (`HealthCheckBlocked` stays a `<failure>`); (2) the new optional `-UpToDateCount` / `-NotReadyCount` parameters on `Add-AzLocalApplyUpdatesStepSummary` add `Already Up to Date` and `Not Ready (needs attention before updating)` rows to the Readiness KPI table; (3) `actions/download-artifact@v6 -> @v7` in `apply-updates.yml` (GitHub Actions) silences the Node.js 20 deprecation warning. No public API change or new exports (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.77` to `0.8.78` across all bundled pipeline templates. See [CHANGELOG.md](CHANGELOG.md#0878---2026-06-15) for the full v0.8.78 entry and [docs/release-history.md](docs/release-history.md#whats-new-in-v0878) for the archived entry.

### What's New in v0.8.77

**Patch release. Fixes two production strict-mode crashes** that surfaced in Step.05 / Step.06 / Step.07 of the bundled apply-updates pipelines. Both bugs share the same root cause: bare `$obj.Prop` property access under `Set-StrictMode -Version Latest` **throws** when `Prop` is absent on a `PSCustomObject` instead of returning `$null`. Fixes use the `$obj.PSObject.Properties['Prop'] -and $obj.Prop` guard idiom (and `IDictionary.Contains()` for tag bags returned by `Invoke-AzRestJson`). No public API change or new exports (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.76` to `0.8.77` across all bundled pipeline templates. See [CHANGELOG.md](CHANGELOG.md#0877---2026-06-14) for the full per-bullet detail and [docs/release-history.md](docs/release-history.md#whats-new-in-v0877) for the archived entry.

### What's New in v0.8.76

**Patch release. Adds a Microsoft-hosted Windows preflight job (GitHub Actions) / preflight stage (Azure DevOps) in front of the opt-in Step.6 `sideload-updates.yml` pipeline.** Before v0.8.76, triggering Step.6 without first completing the opt-in setup (master gate `SIDELOAD_UPDATES` not set, or set without registering a self-hosted `azlocal-sideload` runner) produced `Status: Skipped` with no logs, no annotation, and no actionable feedback - operators had to read the YAML to figure out why. v0.8.76 prepends a `preflight` job (`runs-on: windows-latest`, ~10s, no Azure access) that ALWAYS runs and writes a clear panel to the run step summary explaining what is set, what is missing, and how to enable Step.6. Also broadens the master gate to accept `'true'`, `'True'`, `'TRUE'`, or `'1'` (was strict-literal `'true'` only). No public API change or new exports (still 60).

See [CHANGELOG.md](CHANGELOG.md#0876---2026-06-12) for the full v0.8.76 entry.

### What's New in v0.8.73

**Cycle-calendar refinement.** The Step.3 apply-updates schedule audit now shows the per-ring cluster count INLINE in the "Eligible rings" column (instead of a separate column), and the Step.3 pipeline render path actually populates those counts. `Get-AzLocalApplyUpdatesScheduleCycleCalendar` no longer adds a separate "Clusters in ring(s)" column when `-ClusterRingCounts` is supplied; instead the per-day calendar relabels the header "Eligible rings" -> "Eligible rings (cluster count)" and appends each ring's count inline. `Export-AzLocalApplyUpdatesScheduleAudit` now forwards `-ClusterRingCounts` (previously it never did, so the counts were silently absent). No public API or export-count change (still 60).

See [CHANGELOG.md](CHANGELOG.md#0873---2026-06-11) for the full v0.8.73 entry.

### What's New in v0.8.72

**Patch release: pipeline-template polish only.** Moves the `apply-updates.yml` schedule-file author guidance out of the customise marker so corrections reach already-deployed consumers, and zero-pads single-digit step numbers in pipeline display names so the GitHub Actions sidebar / Azure DevOps pipelines list sort in execution order. No public API or export-count change (still 60). `apply-updates.yml` author guidance was trapped inside the `# BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` block (which `Update-AzLocalPipelineExample` preserves verbatim from the consumer's file), so corrections such as the v0.8.71 `.github` -> `config` schedule-path fix could never reach an already-deployed consumer; all guidance is now ABOVE the marker. Single-digit pipeline step numbers were zero-padded to two digits across all display names / titles (`Step.0` -> `Step.00` ... `Step.9` -> `Step.09`; `Step.10` unchanged) so the GitHub Actions sidebar and Azure DevOps pipelines list sort in execution order.

See [CHANGELOG.md](CHANGELOG.md#0872---2026-06-11) for the full v0.8.72 entry.

### What's New in v0.8.71

**Patch release: JUnit export strict-mode crash fix + sideload schedule-path default corrected + de-numbered stale pipeline doc-string filenames.** No public API or export-count change (still 60). `Export-ResultsToJUnitXml` no longer throws `The property 'CurrentState' cannot be found on this object` under `Set-StrictMode -Version Latest` when an Apply Updates run emits an `UpdateStarted` success row that legitimately lacks `CurrentState`/`Progress` (the bare reads are now guarded with `PSObject.Properties[...]`). The GitHub Actions `sideload-updates.yml` `APPLY_UPDATES_SCHEDULE_PATH` default was corrected from `./.github/apply-updates-schedule.yml` to `./config/apply-updates-schedule.yml`, and stale `Step.N_*.yml` filename references in pipeline doc strings were de-numbered to match the v0.8.7 rename.

See [CHANGELOG.md](CHANGELOG.md#0871---2026-06-11) for the full v0.8.71 entry.

### What's New in v0.8.7

**On-prem solution-update sideloading automation: new self-hosted Step.6 pipeline + 5 new Public cmdlets + de-numbered pipeline filenames.** Adds an opt-in, off-by-default workflow for Azure Local clusters that cannot pull solution updates from Azure directly: a new Step.6 pipeline (`sideload-updates.yml`) robocopies update media to each cluster's import share, verifies the SHA256 over WinRM, runs `Add-SolutionUpdate`, and flips the `UpdateSideloaded=True` tag so the downstream apply (now Step.7) picks it up. The 5 new cmdlets are `Update-AzLocalSideloadCatalog`, `Resolve-AzLocalSideloadPlan`, `Invoke-AzLocalSideloadUpdate`, `Export-AzLocalSideloadStatusReport`, `Add-AzLocalSideloadStepSummary`. BREAKING: bundled pipeline filenames are de-numbered (`Step.7_apply-updates.yml` -> `apply-updates.yml`, etc.; `Update-AzLocalPipelineExample` is now rename-aware), four display steps renumber to make room for sideload at Step.6, and all operator config relocates to a repo-root `config/` folder. Module export count grows 55 -> 60.

See [CHANGELOG.md](CHANGELOG.md#087---2026-06-11) for the full v0.8.7 entry.

### What's New in v0.8.6

**Step.3 cycle calendar enrichment: per-day Step.6 CRON firing times + per-(ring, date) `UpdateStartWindow` tag-coverage check (>=95% threshold).** Adds two opt-in render-time columns to `Get-AzLocalApplyUpdatesScheduleCycleCalendar` (auto-wired from `Export-AzLocalApplyUpdatesScheduleAudit`) so operators see in one table which Step.6 cron firing times fire on each calendar day and what fraction of eligible clusters have an `UpdateStartWindow` tag that covers a firing. Also fixes six v0.8.5 thin-YAML port regressions (Step.0/3/4/6/9) and adds Pester static-audit guards. Same module export count as v0.8.5 (55).

See [CHANGELOG.md](CHANGELOG.md#086---2026-06-10) for the full v0.8.6 entry.

### What's New in v0.8.4

**Step.3 advisor enhancements + Step.6 per-cluster Step Summary + version banner on every install step + RBAC custom-role rename.** Three new informational sections in `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` (NoWindowTag CSV remediation with new `-ClusterCsvPath` parameter; cycle calendar; configured exclusion windows). Step.6 `apply-updates` step persists `apply-results.json` and the downstream Summary renders `### Cluster Actions` + `### Clusters Skipped at Readiness Gate` per-cluster tables on both GH + ADO. Node.js 24 opt-in (`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`) added to all 10 bundled GH yml. Every install step on both platforms appends a `_Pipeline YAML v... | Module v... | PSGallery latest ... | <verdict>_` banner to the Run/Build Summary. Bundled custom role renamed from `Azure Stack HCI Update Operator` to `Azure Stack HCI Update Operator (custom)` (in-place `az role definition update` is a zero-downtime rename - GUID + all role assignments preserved).

See [CHANGELOG.md](CHANGELOG.md#084---2026-06-18) for the full v0.8.4 entry.

### What's New in v0.8.3

**Step.3 advisor accuracy + readability fixes.** Recommend now diff-prunes against `-PipelineYamlPath` (no more false-positive "Action required - cron coverage" on steady-state fleets); Step.3 GH/ADO yml `pipeline_path`/`pipelinePath` is now REQUIRED; Step.3 yml now passes `-PipelineYamlPath` to the Recommend invocation; Allow-list heading reframed; closing-fence typo fixed. See [CHANGELOG.md](CHANGELOG.md#083---2026-06-11) for the full v0.8.3 entry.

### What's New in v0.8.2

**Operator-experience release for `Test-AzLocalApplyUpdatesScheduleCoverage`.** Two paste-time pain points fixed in the `-View Recommend` snippet (UTC-comment embedded above `schedule:`/`schedules:`; new `> **Indent tip.**` blockquote above the snippet warns about IDE auto-indent-on-paste doubling the `schedule:` indent). `-View Audit` `NoWindowTag` row now names the first 15 affected cluster names grouped by `UpdateRing` instead of a generic nudge. Step.3 Allow-list section trimmed in both GH and ADO scaffolds. Five new internal (Private) helpers `Get-AzLocalPipelineHost`, `Set-AzLocalPipelineOutput`, `Add-AzLocalPipelineStepSummary`, `Write-AzLocalPipelineNotice`, `Write-AzLocalPipelineWarning` lay foundations for the upcoming executable-YAML refactor. `Azure Stack HCI Update Operator` custom-role Description rewritten to drop module-internal jargon (same RBAC grant, no operator action required). `GENERATED_AGAINST_MODULE_VERSION` bumped to `0.8.2` across all 20 bundled `Step.{0..9}.yml` templates.

See [CHANGELOG.md](CHANGELOG.md#082---2026-06-10) for the full v0.8.2 entry.

### What's New in v0.8.1

**Docs-and-snippet correctness release.** Fixed the `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` GitHub-Actions snippet so it can be pasted straight into `Step.6_apply-updates.yml` without producing the `'workflow_dispatch' is already defined` parse error. The GH snippet now emits ONLY the `schedule:` block (2-space `schedule:` indent + 4-space cron indent) so it slots straight under the existing `on:` key inside the `# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` markers. Azure DevOps snippet shape (top-level `schedules:`) unchanged. Four `AS7`-`AS10` Pester assertions updated to detect the new `(?m)^\s*schedule:\s*$` shape. `GENERATED_AGAINST_MODULE_VERSION` pin moved to `0.7.99` -> `0.8.0` -> `0.8.1` across all 20 bundled templates.

See [CHANGELOG.md](CHANGELOG.md#081---2026-06-09) for the full v0.8.1 entry.

### What's New in v0.8.0

**Patch release rolling up three follow-ups to v0.7.99 plus Step.2 UX fixes.** No public API changes. `Set-AzLocalClusterUpdateRingTag -PassThru` gains two new enum values (`Action='NoChange'` and `Status='AlreadyInSync'`) to distinguish steady-state clusters from genuinely-skipped ones. Step.7 form-defaults fixed (`criticalElapsedDays` `7`->`3`; `updateRing` `'Wave1'`->`''`) so the v0.7.99 behaviour change actually takes effect when operators leave the form untouched. New `Tests/Pii-Guard.Tests.ps1` repo-hygiene guard. `Publish-Module.ps1` excludes maintainer-only `docs/RELEASE-PROCESS.md` from the published `.nupkg`.

See [CHANGELOG.md](CHANGELOG.md#080---2026-06-09) for the full v0.8.0 entry.

### What's New in v0.7.99

**Breaking property and Summary renames in the readiness / fleet-status cmdlets** plus a Step.7 CRITICAL elapsed-days default tightening (7 -> 3) and an artifact-naming cleanup. `Get-AzLocalUpdateSummary.AvailableUpdatesCount` -> `ActionableUpdatesCount`; `Get-AzLocalClusterUpdateReadiness.AvailableUpdates` and `Get-AzLocalFleetStatusData.AvailableUpdates` -> `AllAvailableUpdates`. Readiness Summary went 2-bucket -> 3-bucket with a new `Up to Date` bucket distinct from `Not Ready for Update`; JSON keys: `ClustersReadyForUpdate` / `ClustersUpToDate` (new) / `ClustersNotReadyForUpdate`. Step.5 + Step.8 pipelines (GH + ADO) updated in lock-step. Every artifact zip now prefixed with `azlocal-step.X-` so operators can identify which Step.* produced it without unzipping. `GENERATED_AGAINST_MODULE_VERSION` pin moved to `0.7.99` across all 20 bundled templates.

See [CHANGELOG.md](CHANGELOG.md#0799---2026-06-09) for the full v0.7.99 entry.

### What's New in v0.7.98

**Step.7 monitor-updates UX overhaul + Step.7 / Step.8 JUnit `time=` populated with real run elapsed seconds.** Only the four monitor / fleet-status pipeline templates changed (`github-actions/Step.7_monitor-updates.yml`, `azure-devops/Step.7_monitor-updates.yml`, and the matching `Step.8_fleet-update-status.yml` pair) plus the bundled-template `GENERATED_AGAINST_MODULE_VERSION` pin bump. No public-cmdlet changes. Severity tiers + composite `SeverityScore` sort surface stuck step errors and runs > 14 days at the top of the Step.7 table; per-cell icons + a horizontal chip stack replace the single-status column; a fleet status badge collapses the worst row into a single `CRITICAL / WARN / OK` line; per-step `errorMessage` is collapsed under `<details><summary>Verbose error</summary>...</details>`. JUnit `time=` for Step.7 in-flight / unresolved-failed rows is real run duration (was always 0); Step.8 Update Run History `<testcase time="..">` now equals `DurationMinutes * 60` from `Get-AzLocalUpdateRunFailures`.

See [CHANGELOG.md](CHANGELOG.md#0798---2026-06-09) for the full v0.7.98 entry.

### What's New in v0.7.97

In-package documentation follow-up to v0.7.96 (no code or YAML run-block changes). The three Markdown files that ship inside the published PSGallery `.nupkg` under the module folder (`Automation-Pipeline-Examples/README.md`, `Automation-Pipeline-Examples/docs/appendix-pipelines.md`, `docs/release-history.md`) were refreshed to mirror the v0.7.96 module behaviour. Only the `GENERATED_AGAINST_MODULE_VERSION` pin changed across all 20 bundled templates (`'0.7.96'` -> `'0.7.97'`).

See [CHANGELOG.md](CHANGELOG.md#0797---2026-06-08) for the full v0.7.97 entry.

### What's New in v0.7.96

Operator-visibility release. Rolled every Azure portal Update Manager signal into the module + pipelines so operators no longer had to click into the Azure portal to triage stuck or failed runs. No breaking changes (additive fields only). Triggered by an Arizona cluster that sat 18+ days on the "Start update" step where the existing `State=InProgress` signal made it invisible to Step.7 long-running checks. `Get-AzLocalUpdateRuns` gained two new fields - `Status` (the 7-value `properties.progress.status` vocabulary: `Success` / `Error` / `InProgress` / `NotStarted` / `Skipped` / `Cancelled` / `Unknown`) and `ErrorMessage` (the deepest non-empty `errorMessage` walked from the `properties.progress.steps[]` tree, via a new `Get-DeepestErrorMessage` private helper that recurses up to depth 9). Step.7 `monitor-updates.yml` got a new JUnit failure type `StepError` (fires when `Status=Error && State=InProgress` - the Arizona stuck-step signal), replaced the "Recently-failed" table with an always-shown "Failed runs (unresolved)" block, added `Progress Status` + `ErrorMessage` columns, MS Learn TSG link, new `STEP_ERRORED` / `UNRESOLVED_FAILURES` outputs, and portal-linked Cluster / Update Name cells. Step.8 `fleet-update-status.yml` promoted `PreparationFailed` and `NeedsAttention` from the catch-all "Other" bucket to first-class signals: `NeedsAttention` joined `Update Failed`, `PreparationFailed` got its own new `Action Required` bucket with separate remediation prose, and `PreparationInProgress` was counted under `Update In Progress`. New JUnit testsuite `primaryActionRequired` property, new `ACTION_REQUIRED` output, new `Summary.UpdateFailures` + `Summary.ActionRequired` keys in `readiness-status.json`, per-cluster JUnit `failureType='PreparationFailed'` for ITSM routing.

See [CHANGELOG.md](CHANGELOG.md#0796---2026-06-09) for the full v0.7.96 entry.

### What's New in v0.7.95

v0.7.95 was a quality-of-life release that fixed `Update-AzLocalPipelineExample` silently skipping Step.0 / Step.1 YAMLs on every module bump (added `# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` marker blocks to those four bundled YAMLs + a pin-only short-circuit in `Update-AzLocalPipelineExample` branch 3c so `GENERATED_AGAINST_MODULE_VERSION` bumps no longer require `-Force`). Also restructured `Automation-Pipeline-Examples/README.md` section 3 (RBAC) around the recommended MG + Azure Policy `deployIfNotExists` path and renamed `docs/appendix-pipelines.md` per-pipeline sections from `A.N` to `Step N -` with new `Cmdlets invoked` / `Depends on` / `Exit conditions` / `ITSM` rows on each.

See [CHANGELOG.md](CHANGELOG.md#0795---2026-06-08) for the full v0.7.95 entry.

### What's New in v0.7.94

v0.7.94 was a pipeline-YAML-only hotfix release. No cmdlet behaviour changes, no schema changes, no breaking changes.

- **Fixed: `Step.7_monitor-updates.yml` (GitHub Actions + Azure DevOps) - missing `-PassThru` on `Get-AzLocalUpdateRuns` caused every scheduled monitor run to report `0 in-flight / 0 long-running` even when clusters had update runs stuck `InProgress`.** Both Step.7 variants called `Get-AzLocalUpdateRuns -ClusterResourceIds $ids -Latest` (and the `-ScopeByUpdateRingTag -Latest` branch) without `-PassThru`. In multi-cluster mode the cmdlet writes its formatted results to the host via `Format-Table | Out-Host` and only returns them to the pipeline when `-PassThru` is set, so the consuming pipelines silently received an empty `$runs` array. Fixed by adding `-PassThru -SkipSideloadedReset` to both `Get-AzLocalUpdateRuns` invocations in each of the two `Step.7_monitor-updates.yml` files.

See [CHANGELOG.md](CHANGELOG.md#0794---2026-06-08) for the full v0.7.94 entry.

### What's New in v0.7.93

v0.7.93 was a pipeline-YAML + tests-only patch release. No cmdlet behaviour changes, no schema changes, no breaking changes.

- **Fixed: pipeline JUnit summaries no longer render `NaNms` in the duration column.** Five inline JUnit XML writers under `Automation-Pipeline-Examples/{github-actions,azure-devops}/` (Step.0 `authentication-test`, Step.3 `apply-updates-schedule-audit`, Step.4 `fleet-connectivity-status`, Step.7 `monitor-updates`, Step.9 `fleet-health-status`) emitted `<testsuite>` / `<testcase>` without a `time=` attribute. `dorny/test-reporter` parsed that as `NaN` and printed `NaNms`, also collapsing the column alignment. v0.7.93 added `time="0"` to every emission across all 12 affected files.
- **Added: Pester regression guard.** New `It` block under `Context 'Inline JUnit XML emitters carry a numeric time attribute (v0.7.93 NaNms regression)'` statically scans every `*.yml` under `Automation-Pipeline-Examples/` and asserts each `<testsuites>` / `<testsuite>` / `<testcase>` carries `time=`.
- **Changed: `Test-AzLocalApplyUpdatesScheduleCoverage` `-RecommendFiresPerWindow` help text** dropped a `(pre-v0.7.92 back-compat)` parenthetical. Parameter default remains `2` and behaviour is unchanged - docstring tidy only.
- **Added: `docs/rbac.md` - management-group `AssignableScopes` + Azure Policy DINE recipe** for scaling the `Azure Stack HCI Update Operator` custom role across many subscriptions. New section walks through the Azure Landing Zones-style alternative to a per-subscription `AssignableScopes` list: one MG scope in `AssignableScopes` plus an Azure Policy `deployIfNotExists` at that MG to auto-create the per-subscription role assignment for the pipeline identity. Cross-linked from `Automation-Pipeline-Examples/README.md` sections 3.1 and 3.2.

See [CHANGELOG.md](CHANGELOG.md#0793---2026-06-05) for the full v0.7.93 entry.

### What's New in v0.7.92

v0.7.92 was a docs/YAML-only feature release: four pipelines moved (GitHub Actions + Azure DevOps in all cases) plus one operator-UX change to `Copy-AzLocalPipelineExample`. No cmdlet behaviour changes, no schema changes, no breaking changes.

- **`Step.9_fleet-health-status.yml`** - per-cluster collapsible `<details>` `Detailed Results` (replaced flat ~100-row `(cluster x check)` table), worst-affected ordering (`CriticalCount` desc -> `WarningCount` desc -> `LastOccurrence` desc), per-cluster pagination instead of per-row, plus hyperlinks open in a new tab.
- **`Step.8_fleet-update-status.yml`** - rendered hyperlinks (cluster blade deep-links, update-run blade deep-links, `aka.ms`/Microsoft Learn references in the version section) open in a new tab.
- **`Step.7_monitor-updates.yml`** - default schedule activated (5x/day at 20:00, 22:00, 00:00, 02:00, 04:00 UTC). Previously commented-out.
- **`Step.3_apply-updates-schedule-audit.yml`** - summary metric table now surfaces the missing `NoWindowTag` bucket so `(Ring, Window) pairs audited` reconciles with the per-bucket sum when `IncludeUntagged: true`. New `-RecommendFiresPerWindow` parameter on `Test-AzLocalApplyUpdatesScheduleCoverage` (default `2`) plus matching `fires_per_window` (GH) / `firesPerWindow` (ADO) workflow input: the Recommend snippet now emits TWO crons per window by default (`(open)` `LeadTimeMinutes` before the window opens + `(retry)` inside the window at midpoint-or-+60min). Pass `1` for pre-v0.7.92 single-cron behaviour. Runtime gate + in-flight guard prevent double-triggering. Also new: `RingMixedWindows` informational `Schedule` status when 2+ clusters share an `UpdateRing` tag but carry different `UpdateStartWindow` values.
- **`Copy-AzLocalPipelineExample` drops a starter `apply-updates-schedule.yml` by default.** Bundled `apply-updates-schedule.example.yml` is copied to `apply-updates-schedule.yml` one level up from `-Destination` (sibling of `.github\workflows\` for GitHub, sibling of the pipelines folder for ADO) when no file already exists at that path. Pre-existing files are NEVER overwritten. Safe alongside the bundled Step.6 which ships with every `cron:` commented out. New `[switch] -SkipStarterSchedule` opts out.

See [CHANGELOG.md](CHANGELOG.md#0792---2026-06-05) for the full v0.7.92 entry.

### What's New in v0.7.91

v0.7.91 was a docs/YAML-only patch release. The headline fix was the urgent `Step.7_monitor-updates.yml` PowerShell 7 parser bug (`The Unicode escape sequence is not valid`) - the runner was failing at the `Import-Module` step on the `no update runs currently in flight` branch on the v0.7.90 release. Fixed by switching the literal-backtick escape (`` \` ``) to the `` `` `` form already used elsewhere in the same line. Also bundled three cosmetic fixes to the Step.3 schedule-audit summary: wrong cmdlet name (`Get-AzLocalUpdate -Status Ready` -> `Get-AzLocalAvailableUpdates`), bogus example version strings (replaced with the canonical `Solution12.2604.1003.1005;Solution12.2610.1003.XX`), and a stray `n` after the closing markdown code-fence (missing backtick in `"``````n"`).

See [CHANGELOG.md](CHANGELOG.md#0791---2026-06-05) for the full v0.7.91 entry.

### What's New in v0.7.90

v0.7.90 shipped a new **`UpdateExcluded` operator-override tag** and a **breaking rename**: the existing `UpdateExclusions` schedule tag (date-range blackout periods) was renamed to **`UpdateExclusionsWindow`** to make its purpose unambiguous against the new override.

**New `UpdateExcluded` tag (operator hard override).** When set to `True` / `true` / `1` on a cluster, `Start-AzLocalClusterUpdate` skips that cluster with `Status = ExcludedByTag` **regardless of the `UpdateRing` scope, `UpdateSideloaded` state, or `UpdateStartWindow` / `UpdateExclusionsWindow` schedule**. The gate runs BEFORE the sideloaded and schedule gates so it overrides both. `Set-AzLocalClusterUpdateRingTag` always stamps `UpdateExcluded=False` on any cluster that does not already carry the tag, so the tag is discoverable in the Azure portal.

**Breaking rename: `UpdateExclusions` -> `UpdateExclusionsWindow`.** The tag VALUE format is unchanged. From v0.7.90 the module ONLY reads `UpdateExclusionsWindow` from cluster tags. The same rename applies to: the `-UpdateExclusions` parameter on `Test-AzLocalUpdateScheduleAllowed`, the `-UpdateExclusionsValue` parameter on `Set-AzLocalClusterUpdateRingTag`, the CSV column name, and the `UpdateExclusions` property on objects returned by `Get-AzLocalClusterInventory`, `Get-AzLocalClusterUpdateReadiness`, and `Get-AzLocalFleetStatusData`.

**Pipeline renumber + new Step.7 monitor.** A new `Step.7_monitor-updates.yml` (GitHub Actions + Azure DevOps) reports clusters whose latest update run is currently `InProgress`, with the CURRENT STEP each cluster is on, the PROGRESS (`completed/total steps`), and the ELAPSED DURATION; long-running runs are flagged via a configurable `long_running_threshold_hours` input (default 6h). The two daily snapshot pipelines shifted accordingly: `Step.7_fleet-update-status` -> `Step.8_fleet-update-status`, `Step.8_fleet-health-status` -> `Step.9_fleet-health-status`.

**Step.5 (assess-update-readiness) markdown summary redesign.** Audit-priority layout, header tile, Not-Ready and Critical-health tables before the all-clusters detail, per-UpdateRing breakdown, cross-links to Step.4 / 6 / 7 / 9, merged `assess-readiness.xml` JUnit XML.

**Step.8 (fleet-update-status) "Version Distribution" table** pivoted by YYMM (leading column = `Version` YYMM, new `Update Versions` column lists each full version as `<version> x <count>` separated by `<br>`).

**Six new per-pipeline smoke-test harnesses** in `Tools/` (Step.1/3/5/7/8/9) plus [Tools/SMOKE-COVERAGE.md](Tools/SMOKE-COVERAGE.md).

See [CHANGELOG.md](CHANGELOG.md#0790---2026-06-04) for the full v0.7.90 entry including migration recipe.

### What's New in v0.7.89

v0.7.89 was a customer-feedback driven feature release: an OPTIONAL `allowedUpdateVersions` allow-list field on `apply-updates-schedule.yml`, supporting both fleet-wide (top-level) and per-row (per-ring) scopes. New optional parameter `Start-AzLocalClusterUpdate -AllowedUpdateVersions [string[]]`, `Resolve-AzLocalCurrentUpdateRing` returns three new properties (`AllowedUpdateVersions`, `AllowedUpdateVersionsValue`, `AllowedUpdateVersionsSource`), schema migration recipe `1 -> 2` (`Update-AzLocalApplyUpdatesScheduleConfig`), and Step.6 pipeline plumbing (GH + ADO) - while keeping the historic "install the latest Ready update" behaviour unchanged for everyone who doesn't opt in. New result/CSV status `NotInAllowList`. All 18 bundled `Step.{0..8}.yml` templates pin-bumped to `'0.7.89'`. See [docs/release-history.md](docs/release-history.md) for the full v0.7.89 What's-New text.

---

_Generated by `AzLocal.UpdateManagement` for Azure Local at-scale fleet updates._