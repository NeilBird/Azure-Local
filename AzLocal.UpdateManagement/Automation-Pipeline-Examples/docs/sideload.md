# Sideload Updates (on-prem, opt-in) - Step 6

> **Introduced in v0.8.7.** Opt-in, off by default. This pipeline is inert unless the
> repository variable `SIDELOAD_UPDATES` is the literal string `'true'`.

The **Sideload Updates** pipeline (`sideload-updates.yml`, logical pipeline id
`sideload-updates`, displayed as **Step.6**) pre-stages Azure Local solution-update
media onto clusters that **cannot pull updates from Azure directly** - dark,
air-gapped, or restricted-egress fabrics. Once the media is staged, verified, and
imported, the pipeline flips the `UpdateSideloaded=True` gate so the downstream
**Step.7 - Apply Updates** pipeline can proceed exactly as it does for
internet-connected clusters.

For the per-pipeline reference card (inputs, artefacts, RBAC, exit conditions) see
[appendix-pipelines.md - Step 6](appendix-pipelines.md#step-6---sideload-updates).
For robocopy throttling guidance see [sideload-robocopy.md](sideload-robocopy.md).

---

## 1. Why a self-hosted runner / agent

The runner (GitHub Actions) or agent (Azure DevOps) must sit on the **same network as
the target clusters** so it can:

1. **Robocopy** the `CombinedSolutionBundle` (or OEM SBE package) to each cluster's
   infrastructure `import` SMB share.
2. **PowerShell-remote (WinRM)** into a cluster node to verify the SHA256 and run
   `Add-SolutionUpdate`.

Microsoft-hosted / cloud-hosted runners cannot reach the on-prem fabric, so this
pipeline targets:

- **GitHub Actions** - a self-hosted **runner** labelled `azlocal-sideload`
  (`runs-on: [self-hosted, azlocal-sideload]`).
- **Azure DevOps** - a self-hosted **agent** in a pool that satisfies the
  `azlocal-sideload` demand (`pool: { name: <pool>, demands: azlocal-sideload }`).

> Terminology: GitHub uses **runners** (in runner groups); Azure DevOps uses **agents**
> (in agent pools). This is never an AKS "node pool".

---

## 2. Re-entrant state machine + scheduled-task survival model

A solution-bundle copy can take **hours** over a constrained on-prem link. A pipeline
run that blocked for that long would burn agent time, hit job timeouts, and lose all
progress if the agent restarted. Instead, the pipeline is a **re-entrant state
machine**:

- Each pipeline run advances **every in-scope cluster by exactly one transition**, then
  exits. No run is ever long-lived.
- The multi-hour copy itself runs in a **detached Windows Scheduled Task** (driven by
  the bundled `Tools/Invoke-AzLocalSideloadCopyTask.ps1` worker) that **survives** the
  pipeline run ending and the agent process recycling.
- Progress is persisted in **shared-UNC state JSON**, so any runner/agent can read the
  state and advance/report without cross-agent remoting.

Drive the pipeline on a **frequent CRON (every 30 minutes)** so successive short runs
walk each cluster through the states:

```
Planned -> Copying -> Copied -> Verified -> Imported -> SideloadFlagged
```

Per cluster, the current shared state determines the action taken by
`Invoke-AzLocalSideloadUpdate`:

| Current state | Action |
|---|---|
| (no state) + due now | Set `UpdateSideloaded=False`, ensure the verified bundle is in the shared cache, register + start the detached copy Scheduled Task, write `Copying` state. |
| `Copying` + fresh heartbeat | Report progress, leave the task running. |
| `Copying` + **stale** heartbeat (> `SIDELOAD_HEARTBEAT_STALE_MINUTES`) | Treat the host as dead and re-drive on the current (live) host, up to `MaxRetries`. |
| `Copied` | Open a WinRM session, verify the remote SHA256, run `Add-SolutionUpdate` + discovery, flip `UpdateSideloaded=True` + stamp `UpdateVersionInProgress`, mark `Imported`, remove the task. |
| `Failed` | Bounded retry, else surface the error as a JUnit `<failure>`. |
| `Imported` | Done - nothing to do. |

Re-running is **always safe** - the state machine is idempotent.

---

## 3. Shared state and multi-runner / multi-agent contract

`SIDELOAD_STATE_ROOT` must be a **UNC path that every runner/agent can read and write**.
It holds three subfolders:

- `state\` - one JSON document per cluster tracking the current transition + heartbeat.
- `logs\`  - per-run copy / verify / import logs.
- `cache\` - the verified media cache (overridable via `SIDELOAD_CACHE_ROOT`; defaults
  to `<state-root>\cache`).

Because a bundle is downloaded and hashed **once** into the shared cache and then reused
across every cluster that needs that version, only the first cluster pays the download +
hash cost. The pipeline's `concurrency` / queueing settings serialize overlapping runs so
they do not race on the same shared state.

---

## 4. Authentication

Two **distinct** identities are used - do not conflate them:

1. **Pipeline identity** (Azure plane) - reads the fleet via Azure Resource Graph, reads
   the Key Vault secrets, and writes the `UpdateSideloaded` / `UpdateVersionInProgress`
   tags. Defaults to `azure/login` OIDC; `enable-AzPSSession=true` is required because
   the Key Vault secrets are read via `Get-AzKeyVaultSecret` (Az PowerShell). For on-prem
   runners where OIDC is not viable, switch via the `SIDELOAD_KV_AUTH` variable
   (`oidc | managedidentity | serviceprincipal`). Tag writes need only **Tag Contributor**
   (they reuse `Set-AzLocalClusterTagsMerge`).
2. **Cluster WinRM credential** (fabric plane) - an Active Directory `[pscredential]`
   built at run time from **two Key Vault secrets** named in the matching sideload
   auth-map row (a username secret + a password secret). This credential - **not** the
   pipeline identity - is used for the WinRM session and `Add-SolutionUpdate`. The
   detached copy Scheduled Task runs as the runner service account, which needs UNC
   rights to the shared cache and the cluster import share.

### 4.1 Sideload auth-map CSV (`SIDELOAD_AUTH_MAP_PATH`)

Maps the numeric `UpdateAuthAccountId` tag (written onto clusters by Step.2) to the Key
Vault + secret names that hold the AD credential:

```csv
UpdateAuthAccountId,KeyVaultName,UsernameSecretName,PasswordSecretName
1,kv-fabric-east,sideload-user,sideload-pass
2,kv-fabric-west,sideload-user,sideload-pass
```

- `UpdateAuthAccountId` must match `^\d{1,3}$` (numeric, 1-3 digits) and be **unique** (a
  duplicate is a hard error).
- All four columns are required.

---

## 5. Catalog (`SIDELOAD_CATALOG_PATH`)

A source-controlled YAML describing the media available to the automation. Two package
classes are supported via `packageType`:

- **Solution** - a Microsoft `CombinedSolutionBundle.<build>.zip` downloadable from a
  direct `downloadUri` (published in the Microsoft Learn "import and discover updates
  offline" table). `sha256` is **required** so the download / pre-staged copy can be
  verified. `Update-AzLocalSideloadCatalog` can auto-populate these rows by parsing the
  Learn table.
- **SBE** - an OEM Solution Builder Extension package that Microsoft does **not** host.
  The operator stages the OEM files manually and records a `sourceFolder` (local or UNC
  path). `downloadUri` is not applicable; `sha256` is optional (verified only when
  supplied). These rows are added **manually**.

```yaml
schemaVersion: 1
packages:
  - version: '12.2605.1003.210'
    packageType: Solution
    buildNumber: '12.2605.1003.210'
    osBuild: '26100.4061'
    downloadUri: 'https://.../CombinedSolutionBundle.12.2605.1003.210.zip'
    sha256: 'ABCD...'                # required for Solution; ^[0-9A-Fa-f]{64}$
    availabilityDate: '2026-05-13'
    localPath: ''
  - version: 'DellSBE-4.1.2412.1'
    packageType: SBE
    sourceFolder: '\\fileserver\sbe\Dell\4.1.2412.1'
    sha256: ''                       # optional for SBE
    availabilityDate: '2026-05-20'
    notes: 'Dell OEM SBE package, staged manually'
```

---

## 6. Configuration (repository variables)

| Variable | Default | Purpose |
|---|---|---|
| `SIDELOAD_UPDATES` | `false` | **Master gate.** The job is skipped unless this is the literal `'true'`. |
| `SIDELOAD_STATE_ROOT` | (none) | Shared UNC root holding `state\`, `logs\`, `cache\`. **Required** when enabled. |
| `SIDELOAD_CACHE_ROOT` | `<state-root>\cache` | Shared verified media cache. |
| `SIDELOAD_AUTH_MAP_PATH` | `./sideload-auth-map.csv` | Auth-map CSV (see 4.1). |
| `SIDELOAD_CATALOG_PATH` | `./sideload-catalog.yml` | Catalog YAML (see 5). |
| `SIDELOAD_LEAD_DAYS` | `7` | Days before a cluster's next apply window that media should be sideloaded. |
| `SIDELOAD_ROBOCOPY_SWITCHES` | `/R:5 /W:30` | Extra robocopy switches for the detached worker (see [sideload-robocopy.md](sideload-robocopy.md)). |
| `SIDELOAD_HEARTBEAT_STALE_MINUTES` | `60` | Minutes after which a `Copying` heartbeat is considered stale and re-driven. |
| `SIDELOAD_REMOTING_FQDN_SUFFIX` | (empty) | Global FQDN suffix appended to a cluster name to form the WinRM host when the auth-map row does not override it. |
| `SIDELOAD_KV_AUTH` | `oidc` | Key Vault auth mode for the on-prem runner. |
| `APPLY_UPDATES_SCHEDULE_PATH` | `./.github/apply-updates-schedule.yml` | Ring-aware apply-updates schedule; the planner reads it to find each cluster's next apply window. |

---

## 7. Cmdlets

| Cmdlet | Role |
|---|---|
| `Resolve-AzLocalSideloadPlan` | Read-only planner. Reads the fleet (ARG), apply schedule, auth-map, and catalog; emits one plan row per `UpdateAuthAccountId`-tagged cluster (plus error rows for misconfigurations) and marks which clusters are due within `LeadDays`. Reuses the same "next update" selection as the apply path. |
| `Invoke-AzLocalSideloadUpdate` | The re-entrant state machine (section 2). `SupportsShouldProcess` - `-WhatIf` previews transitions with no staging / task / tag changes. |
| `Export-AzLocalSideloadStatusReport` / `Add-AzLocalSideloadStepSummary` | JUnit XML + Markdown step-summary emitters. |
| `Update-AzLocalSideloadCatalog` | Auto-populates Solution rows by parsing the Microsoft Learn offline-updates table. SBE rows are added manually. |
| `Reset-AzLocalSideloadedTag` | Operator escape hatch to clear a stuck `UpdateSideloaded` tag. |

---

## 8. End-to-end runbook

1. **Stand up the runner/agent** on the cluster fabric network and label it
   `azlocal-sideload` (GH) / give the pool the `azlocal-sideload` demand (ADO).
2. **Create the shared UNC root** (`SIDELOAD_STATE_ROOT`) readable + writable by the
   runner service account, and grant that account rights to each cluster's import share.
3. **Populate Key Vault** with the per-fabric AD username/password secrets and author
   `sideload-auth-map.csv`.
4. **Author `sideload-catalog.yml`** - run `Update-AzLocalSideloadCatalog` to fill the
   Microsoft Solution rows, then add any OEM SBE rows manually.
5. **Tag the fleet** (Step.1 / Step.2): set `UpdateRing`, `UpdateStartWindow`, and
   `UpdateAuthAccountId` on each sideloaded cluster.
6. **Set the repository variables** (section 6), starting with `SIDELOAD_UPDATES=true`.
7. **Dry run**: trigger the pipeline manually with `dry_run=true` and review the planned
   transitions + the `sideload-status` artefacts.
8. **Enable the CRON**: uncomment the bundled `*/30 * * * *` schedule inside the
   `BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` block (preserved across
   `Update-AzLocalPipelineExample` upgrades). The Step.3 schedule-coverage audit can
   recommend a lead-time-aware cron (apply window minus `SIDELOAD_LEAD_DAYS`).
9. The state machine advances each cluster to `Imported` / `SideloadFlagged`; the
   downstream **Step.7 - Apply Updates** wave then applies the staged update during the
   cluster's `UpdateStartWindow`.
