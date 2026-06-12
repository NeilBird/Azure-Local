# Azure Local Update Management Module (AzLocal.UpdateManagement)

> ⚠️ **Disclaimer**: This module is **NOT** a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT license](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

**Latest Version:** v0.8.75 - [Published in PowerShell Gallery](https://www.powershellgallery.com/packages/AzLocal.UpdateManagement/0.8.75)

> 📢 **Renamed in v0.7.3**: this module was previously published as `AzStackHci.ManageUpdates`. The new module name aligns with the Azure Local product name (_Microsoft retired the *Azure Stack HCI* brand in late 2024_). The module GUID is preserved across the rename. If you have the old name installed, run:
>
> ```powershell
> Get-Module AzStackHci.ManageUpdates -ListAvailable | Uninstall-Module -Force -Verbose
> Install-Module AzLocal.UpdateManagement
> ```
>
> All previously-published `AzStackHci.ManageUpdates` versions have been unlisted from PSGallery. See [CHANGELOG.md](CHANGELOG.md) for the full migration note. This message will be removed in two releases time.

This folder contains the 'AzLocal.UpdateManagement' PowerShell module for managing updates on Azure Local (formerly Azure Stack HCI) clusters using the Azure Local REST API. The module supports both interactive use and CI/CD automation via Service Principal or Managed Identity authentication.

Azure Local REST API specification (includes update management endpoints): https://github.com/Azure/azure-rest-api-specs/blob/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/stable/2026-02-01/hci.json

<details>
<summary><strong>📑 Table of Contents</strong> (click to expand)</summary>

**This README (overview + most-recent release notes):**

- [Where to Start](#where-to-start)
- [What's New in v0.8.75](#whats-new-in-v0875)
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
| **Sideloaded payload (v0.7.1)** | Operator sets `UpdateSideloaded=False` -> stage payload out-of-band -> operator flips `UpdateSideloaded=True` -> `Start-AzLocalClusterUpdate` (auto-stamps `UpdateVersionInProgress`) -> `Get-AzLocalUpdateRuns` (auto-resets tags on success) -> `Reset-AzLocalSideloadedTag -Force` only if a tag gets stuck |
| **Pause / resume long fleet run** | `Stop-AzLocalFleetUpdate -SaveState` -> ... -> `Resume-AzLocalFleetUpdate -StateFilePath ...` |
| **Recover from emergency** | `Stop-AzLocalFleetUpdate` -> `Test-AzLocalClusterHealth` (assess) -> `Resume-AzLocalFleetUpdate -RetryFailed` |

> Most CI/CD pipelines in [Automation-Pipeline-Examples/](Automation-Pipeline-Examples/) are direct implementations of one of these workflows. Start there if you want a copy-pasteable end-to-end pipeline.

## What's New in v0.8.75

**Patch release. Removes the duplicate Cycle calendar table from the Step.3 apply-updates schedule audit step summary** - before v0.8.75 the Recommend view's plain 5-column calendar was inlined into the wrapper output (as part of the action-required block) **above** the wrapper's own enriched 7-column calendar, so operators saw two calendars back-to-back. Also lands three Step.3 step-summary screenshots in `Automation-Pipeline-Examples/README.md` section 8.3. No public API or export-count change (still 60).

1. **Fixed**: the Step.3 step summary rendered the Cycle calendar twice. `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` writes its own plain (5-column) cycle-calendar block (`Date | Day | CycleWeek | Eligible rings | AllowedUpdateVersions`) to its `recommend.md` output. `Export-AzLocalApplyUpdatesScheduleAudit` (the Step.3 wrapper) inlined that file as the action-required block AND then rendered its OWN enriched (7-column) calendar lower in the summary - with two extra columns (`Ring CRON Start Time (apply-updates pipeline)` and `Tag Start Window Match (>=95%)`) computed from the Step.6 cron triggers + cluster CSV.
2. **Added**: new additive `[switch]$OmitCycleCalendar` parameter on `Test-AzLocalApplyUpdatesScheduleCoverage` (default off, so direct callers see the calendar unchanged). `Export-AzLocalApplyUpdatesScheduleAudit` passes `-OmitCycleCalendar=$true` so only the enriched calendar surfaces in the Step.3 summary.
3. **Added**: Pester regression spies on the Recommend mock to assert the switch is bound, and asserts the rendered step summary contains exactly one `## Cycle calendar - next` heading.
4. **Changed (drift-notice banner)**: `Add-AzLocalPipelineVersionBanner` now recommends `Update-AzLocalPipelineExample` (the marker-aware merge tool that preserves `AZLOCAL-CUSTOMIZE` blocks) instead of `Copy-AzLocalPipelineExample -Update` (the clean-overwrite tool) in the YAML-older-than-module annotation, and inlines the right `-Platform` value plus a sensible `-Destination` hint based on the detected pipeline host: `Update-AzLocalPipelineExample -Destination '<repo-root>\.github\workflows' -Platform GitHub` on GitHub Actions, `Update-AzLocalPipelineExample -Destination '<repo-root>\pipelines' -Platform AzureDevOps` on Azure DevOps. Symmetric warning when the YAML is newer than the installed module gets the same treatment. Three new Pester cases pin the GH / ADO / verdict text.
5. **Docs**: section 8.3 of `Automation-Pipeline-Examples/README.md` (Apply-Updates Schedule Coverage Audit runbook) gains three Step.3 step-summary screenshots - cron coverage remediation, NoWindowTag remediation, and the enriched cycle calendar.

`GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.74` to `0.8.75` across all bundled pipeline templates.

See [CHANGELOG.md](CHANGELOG.md#0875---2026-06-12) for the full v0.8.75 entry. See [`What's New in v0.8.74`](docs/release-history.md#whats-new-in-v0874) in the Release History for the previous release.

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
| Setting / clearing ring tags (`Set-AzLocalClusterUpdateRingTag`) | `Tag Contributor` + `Reader` (or any role with `Microsoft.Resources/tags/write`) | Subscription or Resource Group |
| Resource Graph fleet queries | `Reader` on every subscription you want included | Subscription |

A least-privilege custom role definition (`Azure Stack HCI Update Operator (custom)`) and the exact `actions:` list are documented in [docs/rbac.md](docs/rbac.md), along with `az role assignment create` recipes for OIDC federated credentials, Managed Identity, and Service Principal authentication.
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

> 🔄 **Refreshing pipelines after a module upgrade?** Use `Update-AzLocalPipelineExample` instead of `Copy-AzLocalPipelineExample`. It is a marker-aware merge that refreshes everything **outside** the `# BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `# END-AZLOCAL-CUSTOMIZE:<region>` blocks in each YAML and **preserves** everything inside them - so your custom cron schedules (`schedule-triggers`) and ITSM secret bindings (`itsm-secrets` in Step.7) survive the upgrade.
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

The most recent release notes for **v0.8.75** stay above under [`What's New in v0.8.75`](#whats-new-in-v0875).

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