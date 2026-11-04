# Azure Local Update Management Module (AzLocal.UpdateManagement)

> ⚠️ **Disclaimer**: This module is **not** a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT license](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

**Latest Version:** v0.9.40 - [PowerShell Gallery](https://www.powershellgallery.com/packages/AzLocal.UpdateManagement/0.9.40)

**Release status:** unreleased candidate; publication and live release certification are pending. The versioned Gallery link is the target location after publication, not evidence that this candidate has shipped.

This folder contains the 'AzLocal.UpdateManagement' PowerShell module for managing updates on Azure Local (formerly Azure Stack HCI) clusters using the Azure Local REST API. The module supports both interactive use and CI/CD automation via Service Principal or Managed Identity authentication.

Azure Local REST API specification (includes update management endpoints): https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/stable/2026-04-30/hci.json

<details>
<summary><strong>📑 Table of Contents</strong> (click to expand)</summary>

**This README (overview + most-recent release notes):**

- [Where to Start](#where-to-start)
- [What's New in v0.9.40](#whats-new-in-v0940)
- [Files](#files)
- [Prerequisites](#prerequisites)
- [RBAC Requirements](#rbac-requirements) (summary; full reference in [docs/rbac.md](docs/rbac.md))
- [Quick Start](#quick-start)
- [Available Functions](#available-functions) (summary; full reference in [docs/cmdlet-reference.md](docs/cmdlet-reference.md))
- [Update States](#update-states) (summary; full reference in [docs/concepts.md](docs/concepts.md))
- [Troubleshooting](#troubleshooting) (summary; full reference in [docs/troubleshooting.md](docs/troubleshooting.md))
- [License](#license)
- [Release History](#release-history) (canonical archive in [docs/release-history.md](docs/release-history.md))

**Detailed references (in `docs/`):**

- [docs/cmdlet-reference.md](docs/cmdlet-reference.md) - every exported cmdlet (single-cluster + fleet-scale + API version reference)
- [docs/rbac.md](docs/rbac.md) - full RBAC role map, custom least-privilege role, role-assignment recipes
- [docs/concepts.md](docs/concepts.md) - update lifecycle states, Azure CLI direct usage, Az.StackHCI parity, CI/CD background
- [docs/troubleshooting.md](docs/troubleshooting.md) - symptom-to-fix table for common failure modes
- [docs/release-history.md](docs/release-history.md) - complete What's-New archive, including the current candidate
- [Release process](https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/docs/RELEASE-PROCESS.md) - how to cut a release (maintainer-facing; not packaged)
- [Automation-Pipeline-Examples/README.md](./Automation-Pipeline-Examples/README.md) - end-to-end CI/CD pipeline runbook

</details>

## Where to Start

This module supports **two main paths**. Pick the one that matches your scenario:

| Path | Best for | Auth | Where to read next |
|------|----------|------|--------------------|
| **Interactive** | Manual ops, ad-hoc fleet checks, tag clean-up, learning the module | `az login` | Continue below - the [Quick Start](#quick-start) and per-function reference sections in this README |
| **CI/CD / scheduled automation** | GitHub Actions, Azure DevOps, scheduled fleet reports, gated wave deployments | OIDC, Managed Identity, or Service Principal | **[Automation-Pipeline-Examples/README.md](./Automation-Pipeline-Examples/README.md)** - end-to-end pipeline guide with copy-pasteable workflows |

**Recommended automation platform:** GitHub Actions is the primary development and validation platform for this module and the recommended starting point for new deployments. Azure DevOps pipeline examples are also provided for organizations that standardize on Azure DevOps. Validate your chosen platform in a non-production environment before production use; automated template checks do not establish end-to-end platform readiness.

**Example pipelines, operator-owned deployment:** these are versioned examples shipped with the module, not a managed automation service. Installing a module update does not refresh committed workflows, and refreshing workflows does not change an existing runner runtime-version pin. Treat module selection, template refresh, and rollout as a coordinated change. See [pipeline ownership and upgrade lifecycle](Automation-Pipeline-Examples/README.md#59-pipeline-ownership-and-upgrade-lifecycle) for review, validation, and recovery guidance.

**Candidate testing (DevChannel):** the development-channel helper calls the normal updater in the **same consumer repository**, then manages the pipeline runtime pin. It does not create a separate branch, repository, or package feed; normally run it instead of running both helpers. `-NoPush` leaves refreshed files for review but still changes the GitHub repository-wide pin. See [which helper to use and how to isolate testing](Automation-Pipeline-Examples/README.md#56-test-an-exact-module-candidate).

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

> **For CI/CD?** Go straight to [Automation-Pipeline-Examples/README.md](./Automation-Pipeline-Examples/README.md) for OIDC / Managed Identity / Service Principal setup, federated credentials, and the GitHub Actions and Azure DevOps pipeline templates (including `sideload-updates`, `apply-updates`, `monitor-updates`, `fleet-update-status`, and `fleet-health-status`). Display names group workflows under `Config`, `Monitor`, and `Update`. Pipeline filenames no longer use `Step.N_`; `Update-AzLocalPipelineExample` migrates older filenames while preserving supported customizations.

### Common workflows (function-invocation order)

| Scenario | Recommended order |
|----------|-------------------|
| **One-off cluster update** | `az login` -> `Get-AzLocalUpdateSummary` -> `Get-AzLocalAvailableUpdates` -> `Start-AzLocalClusterUpdate` -> `Get-AzLocalUpdateRuns` |
| **Staged wave deployment** | `Get-AzLocalClusterInventory` -> `Set-AzLocalClusterUpdateRingTag` -> `Get-AzLocalClusterUpdateReadiness -ScopeByUpdateRingTag` -> `Start-AzLocalClusterUpdate -ScopeByUpdateRingTag` -> `Get-AzLocalFleetProgress` -> `New-AzLocalFleetStatusHtmlReport` |
| **Daily fleet status report** | `Get-AzLocalFleetStatusData -AllClusters -IncludeUpdateRuns -IncludeHealthDetails -ExportPath ...` -> `New-AzLocalFleetStatusHtmlReport -StatusData $data -OutputPath ...` |
| **Daily fleet health audit (v0.7.65)** | `Get-AzLocalFleetHealthFailures -View Summary -ExportPath fleet-health-summary.csv` -> review top failure reasons by cluster impact -> drill into [`Get-AzLocalFleetHealthFailures -View Detail`](docs/cmdlet-reference.md#get-azlocalfleethealthfailures) for per-cluster remediation |
| **Schedule coverage drift audit (v0.7.65)** | `Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath .\.github\workflows` -> for any `Uncovered` rows, copy the `RequiredCronUTC` value and paste it into `apply-updates.yml` -> re-run `-View Audit` to confirm `Covered` -> wire the bundled `apply-updates-schedule-audit.yml` pipeline (weekly Mon 05:17 UTC) so future tag drift is caught automatically. Full runbook: [`Automation-Pipeline-Examples/README.md` section 8.3](./Automation-Pipeline-Examples/README.md#83-end-to-end-runbook-apply-updates-schedule-coverage-audit) |
| **Pre-update health gate (CI/CD)** | `Test-AzLocalClusterHealth -BlockingOnly` -> `Test-AzLocalUpdateScheduleAllowed` -> `Test-AzLocalFleetHealthGate` -> proceed only on pass |
| **Manual sideloaded-payload gate (v0.7.1)** | Operator sets `UpdateSideloaded=False` -> stage payload out-of-band -> operator flips `UpdateSideloaded=True` -> `Start-AzLocalClusterUpdate` (auto-stamps `UpdateVersionInProgress`) -> `Get-AzLocalUpdateRuns` (auto-resets tags on success) -> `Reset-AzLocalSideloadedTag -Force` only if a tag gets stuck |
| **Automated disconnected-cluster sideload (Update: 2)** | Start with the [one-cluster walkthrough and checklist](Automation-Pipeline-Examples/docs/sideload.md#start-here-one-cluster-one-runner): review targeting and lead time, validate the plan, prepare one runner, and test copying before separately approving import and Update: 3. See the [sideload operations guide](Automation-Pipeline-Examples/docs/sideload.md) for the full reference. |
| **Pause / resume long fleet run** | `Stop-AzLocalFleetUpdate -SaveState` -> ... -> `Resume-AzLocalFleetUpdate -StateFilePath ...` |
| **Recover from emergency** | `Stop-AzLocalFleetUpdate` -> `Test-AzLocalClusterHealth` (assess) -> `Resume-AzLocalFleetUpdate -RetryFailed` |

> Most CI/CD pipelines in [Automation-Pipeline-Examples/](Automation-Pipeline-Examples/) are direct implementations of one of these workflows. Start there if you want a copy-pasteable end-to-end pipeline.

## What's New in v0.9.40

**Security hardening - GitHub action pinning:** bundled GitHub Actions workflows use verified full commit SHAs with readable release comments, including commented authentication alternatives. This prevents moving upstream tags from silently changing the selected action code. The selected commits match the existing action tags; pinning does not change action majors, inputs, permissions, or authentication configuration. This is not a claim of a specific vulnerability fix; runtime downloads remain outside the pin.

**Azure DevOps review guardrails:** YAML-aware regression tests restrict bundled templates to the six approved built-in task references and reviewed step shortcuts. Every release now requires task and runtime PowerShell dependency review; an [administrator checklist](Automation-Pipeline-Examples/README.md#58-azure-devops-dependency-governance) covers organization restrictions and access controls. This is repository regression coverage, not runtime task enforcement or SHA pinning. Task references, authentication, and organization settings are unchanged.

**Reliable runtime selection and fleet state:** both platforms resolve the explicit pin or latest listed module once per job and import that exact version in subsequent tasks. The banner rejects a loaded-version/pin mismatch. Fleet read operations retain structured results; resume preserves the original run ID, completed results, and cumulative attempts, writes full checkpoints atomically, and leaves state untouched when cancelled or previewed with `-WhatIf`. Checkpoint timestamps now represent UTC correctly.

**Reporting and diagnostics:** actionable-update reconciliation uses full cluster identity, preventing same-name collisions across subscriptions or resource groups. Public CSV exports neutralize spreadsheet formulas without changing raw objects or JSON. Diagnostic scrubbing covers quoted and short password arguments and secret URL parameters; query traces omit full KQL and URI query strings. Log-write failures warn without failing the workload. Timing files isolate pipeline runs and attempts; sideload ZIP manifests record runtime context and incomplete collection. Artifacts remain support-sensitive and require review before sharing.

**Refresh is required:** initial copies receive the pins, and normal marker-aware refresh replaces tag references while preserving supported operator customization blocks. A second refresh leaves workflow bytes unchanged. Installing a newer module alone does not update workflows already committed in a consumer repository. Markerless legacy files retain the documented `-Force` migration requirement.

**Actionable pipeline failures:** failed Azure login attempts and CLI enumeration errors no longer masquerade as zero-subscription RBAC failures. Optional timing/transcript upload failures are nonfatal on both platforms: GitHub warns, while Azure DevOps retains a visible `SucceededWithIssues` result. Required reports remain blocking. Both Apply templates publish JUnit only when the file exists, while successful producers must still generate results JSON and JUnit for nonempty results. No-target runs remain valid.

See the [action pin maintenance guide](Automation-Pipeline-Examples/README.md#57-github-action-pin-maintenance) for central revision review and consumer rollout. Export count remains 73; the subscription guard adds an optional `LoginFailed` switch. Pipeline generation stamps are `0.9.40`. Live action execution and organization-policy acceptance are separate rollout gates.

> Previous release notes are preserved in the [Release History](docs/release-history.md) archive.

See the repository [CHANGELOG.md](https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md) for full release details. See [`What's New in v0.9.39`](docs/release-history.md#whats-new-in-v0939) for the previous release.

## Files

| File | Description |
|------|-------------|
| `AzLocal.UpdateManagement.psd1` | PowerShell module manifest |
| `AzLocal.UpdateManagement.psm1` | PowerShell module with functions to start updates on multiple Azure Local clusters |
| `example-update-request.json` | Example JSON showing API request/response structures for the Update Manager API |

## Prerequisites

- **Azure CLI** (`az`) 2.78.0 or later installed and authenticated (2.90.0 or later recommended)
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

> 📝 **"Check for updates" (`checkUpdates`) is preview and is granted by the least-privilege custom role via a wildcard:** Since v0.8.88, `Sync-AzLocalClusterUpdateSummary` and the opt-out stale-assessment auto-scan in `Export-AzLocalClusterUpdateReadinessReport` POST the preview `Microsoft.AzureStackHCI/clusters/updateSummaries/default/checkUpdates` action (`2026-03-01-preview`). The RBAC action Azure enforces for it is `Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action` (confirmed verbatim from a live `403 AuthorizationFailed` body). A provider-operations-catalog check on 2026-06-18 (`az provider operation show --namespace Microsoft.AzureStackHCI`) confirms the explicit `checkUpdates/action` leaf is **not yet published in the catalog**, and `az role definition create` / `update` rejects an *explicit* unregistered action - but it **accepts a wildcard**. As of v0.8.92 the `Azure Stack HCI Update Operator (custom)` role therefore grants `Microsoft.AzureStackHCI/clusters/updateSummaries/*` (which also covers `updateSummaries/read`); Azure matches the enforced `checkUpdates/action` against that wildcard at authorization time, so the refresh is authorized under the custom role today - no fallback to `Azure Stack HCI Administrator` / `Contributor` required, and no `-SkipStaleAssessmentScan` needed. The only automation consumer is the **Update: 1 - Assess Update Readiness** pipeline (`assess-update-readiness.yml`) via the readiness-report auto-scan; `Sync-AzLocalClusterUpdateSummary` does the same on demand. The wildcard also sweeps in any future control-plane sub-operation under `clusters/updateSummaries/`. See [docs/rbac.md](docs/rbac.md) and [Automation-Pipeline-Examples/README.md](Automation-Pipeline-Examples/README.md#3-required-azure-permissions).
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
  uses: azure/login@a641126d1b8aa4d1fa005f4f92df94a3a4c4c906 # v3.1.0
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

For the complete inventory, including sideload identity, attempt/retry state, and
notification-suppression tags, see the
[Azure resource tags appendix](Automation-Pipeline-Examples/docs/appendix-resource-tags.md).
The table below is a core-tag overview; the appendix documents ownership and lifecycle.

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

  > **Pipeline timing allowance (fleet-settings schema v4):** Pipeline deployments can independently permit update attempts to start `0-60` minutes before and/or after every tagged window by activating `updateStartWindow.allowBeforeMinutes` and `updateStartWindow.allowAfterMinutes` in `config/fleet-settings.yml`. Both default to `0`, preserving the strict opening-inclusive/closing-exclusive window. The allowance is fleet-wide and changes only the runtime start gate; it does not rewrite tags, widen exclusion periods, or stop an update at the effective closing edge. See [Configure fleet scope, update-window allowances, and reporting](Automation-Pipeline-Examples/README.md#612-optional-configure-fleet-scope-update-window-allowances-concurrency-and-reporting) for exact cutoff examples, safety guidance, and schema migration behavior.


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

The module exports **73 cmdlets**. Full detail (parameters, ARM API surface, RBAC reminders, examples) lives in [docs/cmdlet-reference.md](docs/cmdlet-reference.md). Quick orientation:

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

The complete release history archive is maintained in [docs/release-history.md](docs/release-history.md). Only the current release's What's New appears above.

---

_Generated by `AzLocal.UpdateManagement` for Azure Local at-scale fleet updates._