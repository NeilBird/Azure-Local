# Sideload Updates (on-prem, opt-in) - Update: 2

> **Introduced in v0.8.7. Preflight job added in v0.8.76.** Opt-in, off by default.
> The job is inert unless the repository (GH) / pipeline (ADO) variable
> `SIDELOAD_UPDATES` is one of `'true'`, `'True'`, `'TRUE'`, or `'1'`.
>
> Every run starts with a `preflight` job/stage (~10s on a Microsoft-hosted Windows
> runner) that writes a clear panel to the run step summary explaining what is set,
> what is missing, and how to enable Update: 2. When the gate is OFF the preflight
> succeeds with an enablement walkthrough; when the gate is ON but required
> configuration is missing it fails fast and the `sideload` job/stage is skipped.
> See section 9 below for the preflight behaviour matrix.

The **Sideload Updates** pipeline (`sideload-updates.yml`, logical pipeline id
`sideload-updates`, displayed as **Update: 2**) pre-stages Azure Local solution-update
media onto clusters that **cannot pull updates from Azure directly** - dark,
air-gapped, or restricted-egress fabrics. Once the media is staged, verified, and
imported, the pipeline flips the `UpdateSideloaded=True` gate so the downstream
**Update: 3 - Apply Updates** pipeline can proceed exactly as it does for
internet-connected clusters.

For the per-pipeline reference card (inputs, artefacts, RBAC, exit conditions) see
[appendix-pipelines.md - Update: 2](appendix-pipelines.md#update-2---sideload-updates-opt-in).
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

For the exact firewall endpoints the runner/agent needs - CI/CD control plane, Azure
control plane, the cluster fabric, and the optional Microsoft update-media download hosts -
see [section 10 - External endpoints requirements](#10-external-endpoints-requirements).

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
walk each cluster through the persisted `State` values (the `State` field in each
cluster's state JSON under `state\`):

```
(plan status: Planned) --> Copying --> Copied --> Imported
                              |           |
                              v           v
                           Failed      Verified   (NeedsSbe: the Microsoft solution
                        (retries        imported, but an OEM SBE package is
                         exhausted)      still required)
```

The full on-disk `State` enum is `Copying | Copied | Verified | Imported | Failed`.
`Planned` is a **plan** status emitted by `Resolve-AzLocalSideloadPlan` (a cluster due
within `SIDELOAD_LEAD_DAYS`), **not** a persisted state. `Copied` means the media landed;
the SHA256 verify + `Add-SolutionUpdate` import step then promotes it straight to
`Imported`. `Verified` is written **only** for the `NeedsSbe` case. There is no
`SideloadFlagged` state - the `UpdateSideloaded=True` **tag** (not a state) is what the
downstream apply pipelines gate on.

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

### 2.1 The per-cluster state JSON *is* the heartbeat

There is **no separate heartbeat or marker file**. Each cluster's `state\<cluster>.json`
holds both the current `State` and the progress fields the detached worker rewrites
roughly every **30 seconds** while the copy runs: `LastHeartbeatUtc`, `OwningMachine`,
`TotalBytes`, `CopiedBytes`, `Mbps`, `EtaUtc`, `ExitCode`, `Retries`, `TaskName`,
`LogPath`, `Message`. The state machine branches on `State` plus the freshness of
`LastHeartbeatUtc` - it does **not** parse the robocopy log. A `Copying` record whose
`LastHeartbeatUtc` is older than `SIDELOAD_HEARTBEAT_STALE_MINUTES` (default 60) is treated
as a dead host and re-driven on the current runner, up to `MaxRetries` (fixed at **3**;
not currently exposed as a `SIDELOAD_*` variable).

### 2.2 The detached copy Scheduled Task (and an important account caveat)

The copy worker is registered with `Register-ScheduledTask` (not `schtasks`) as
`AzLocalSideload_<sanitized-cluster>`, running `powershell.exe -File
Tools/Invoke-AzLocalSideloadCopyTask.ps1` with `ExecutionTimeLimit = 0` (no time limit, so
a multi-hour copy is never killed). The task is **removed** (`Unregister-ScheduledTask`)
only when the cluster reaches `Imported`. A terminally `Failed`, `Verified` (NeedsSbe), or
still-importing task is **left registered**; the next retry re-registers the same-named
task, which replaces the old one.

> **IMPORTANT - task logon account.** Out of the box the task registers with logon type
> **`S4U`** (the shipped YAML passes no logon-type override). S4U runs **without network
> credentials**, so it **cannot reach UNC paths** - neither the shared cache nor the
> cluster `import` share. For a production UNC copy the task must run under an account that
> carries a network identity: a **gMSA** (`ServiceAccount` logon) or a **stored-password**
> principal. Provision that account with read on `SIDELOAD_CACHE_ROOT` and write on each
> cluster's `import` share. If a copy task starts but immediately writes `Failed` with an
> access / `ERROR 5` / "network path" message, this S4U caveat is almost always the cause.
> (This is the cluster **WinRM** credential's sibling but a *different* identity - see
> section 4.)

---

## 3. Shared state and multi-runner / multi-agent contract

`SIDELOAD_STATE_ROOT` must be a **UNC path that every runner/agent can read and write**.
It holds three subfolders:

- `state\` - one JSON document per cluster tracking the current transition + heartbeat.
- `logs\`  - one robocopy log per copy run, named `<cluster>.<yyyyMMddHHmmss>.robocopy.log` (the worker appends `/LOG:<that path>` to its robocopy switches). There are **no** separate verify/import log files - the SHA256-verify and `Add-SolutionUpdate` outcomes live in the state JSON `Message` field and the step summary.
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
   (`oidc | managedidentity | serviceprincipal`). This variable is **advisory only** - no
   cmdlet reads it; it documents which `azure/login` / `Connect-AzAccount` pattern you wire
   into the YAML to establish the Az PowerShell context that `Get-AzKeyVaultSecret` then
   uses. Tag writes need only **Tag Contributor**
   (they reuse `Set-AzLocalClusterTagsMerge`).
2. **Cluster WinRM credential** (fabric plane) - an Active Directory `[pscredential]`
   built at run time from **two Key Vault secrets** named in the matching sideload
   auth-map row (a username secret + a password secret). This credential - **not** the
   pipeline identity - is used for the WinRM session and `Add-SolutionUpdate`. The
   detached copy Scheduled Task runs as the runner service account, which needs UNC
   rights to the shared cache and the cluster import share.

### 4.1 Sideload auth-map CSV (`SIDELOAD_AUTH_MAP_PATH`)

Maps the numeric `UpdateAuthAccountId` tag (written onto clusters by Config: 2) to the Key
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
| `SIDELOAD_UPDATES` | (unset) | **Master gate.** The job is skipped unless this is one of `'true'`, `'True'`, `'TRUE'`, or `'1'`. Any other value (including blanks, `'false'`, `'yes'`) keeps the pipeline inert. |
| `SIDELOAD_STATE_ROOT` | (none) | Shared UNC root holding `state\`, `logs\`, `cache\`. **Required** when enabled. Validated by the preflight (section 9). |
| `SIDELOAD_CACHE_ROOT` | `<state-root>\cache` | Shared verified media cache. |
| `SIDELOAD_AUTH_MAP_PATH` | `./config/sideload-auth-map.csv` | Auth-map CSV (see 4.1). `Copy-AzLocalPipelineExample` drops a header-only starter here (same `config/` folder on GitHub and Azure DevOps). |
| `SIDELOAD_CATALOG_PATH` | `./config/sideload-catalog.yml` | Catalog YAML (see 5). `Copy-AzLocalPipelineExample` drops an empty skeleton starter here. |
| `SIDELOAD_LEAD_DAYS` | `7` | Days before a cluster's next apply window that media should be sideloaded. |
| `SIDELOAD_ROBOCOPY_SWITCHES` | `/R:5 /W:30` | Extra robocopy switches for the detached worker (see [sideload-robocopy.md](sideload-robocopy.md)). |
| `SIDELOAD_HEARTBEAT_STALE_MINUTES` | `60` | Minutes after which a `Copying` heartbeat is considered stale and re-driven. |
| `SIDELOAD_REMOTING_FQDN_SUFFIX` | (empty) | Global FQDN suffix appended to a cluster name to form the WinRM host when the auth-map row does not override it. |
| `SIDELOAD_KV_AUTH` | `oidc` | Key Vault auth mode for the on-prem runner. |
| `APPLY_UPDATES_SCHEDULE_PATH` | `./config/apply-updates-schedule.yml` | Ring-aware apply-updates schedule; the planner reads it to find each cluster's next apply window. |

---

## 7. Cmdlets

| Cmdlet | Role |
|---|---|
| `Resolve-AzLocalSideloadPlan` | Read-only planner. Reads the fleet (ARG), apply schedule, auth-map, and catalog; emits one plan row per `UpdateAuthAccountId`-tagged cluster (plus error rows for misconfigurations) and marks which clusters are due within `LeadDays`. Reuses the same "next update" selection as the apply path. |
| `Invoke-AzLocalSideloadUpdate` | The re-entrant state machine (section 2). `SupportsShouldProcess` - `-WhatIf` previews transitions with no staging / task / tag changes. |
| `Export-AzLocalSideloadStatusReport` / `Add-AzLocalSideloadStepSummary` | JUnit XML + Markdown step-summary emitters. |
| `Update-AzLocalSideloadCatalog` | Auto-populates Solution rows by parsing the Microsoft Learn offline-updates table. SBE rows are added manually. |
| `Reset-AzLocalSideloadedTag` | Operator escape hatch to clear a stuck `UpdateSideloaded` tag. |

> **Automatic gate reset - you normally never run `Reset-AzLocalSideloadedTag` by hand.**
> After a sideloaded cluster's update run **succeeds**, `Get-AzLocalUpdateRuns` (used by
> Monitor: 3 / Monitor: 4) calls `Invoke-AzLocalSideloadedAutoReset`, which flips
> `UpdateSideloaded` back to `False` and clears `UpdateVersionInProgress` - reopening the
> gate so the cluster is ready to be sideloaded again next cycle (it also tidies stale
> `UpdateLastAttempt` / `UpdateRetryAttempted` tags). `Reset-AzLocalSideloadedTag` is the
> manual escape hatch for a payload you abandoned before it ever applied.

### 7.1 What the status report shows

`Export-AzLocalSideloadStatusReport` reads every `state\*.json` and renders a **`## Sideload
status`** table - one row per cluster, columns `Cluster | Version | State | Progress | Mbps
| ETA (UTC) | Owner | Retries | Message`. The rows that reached `Imported` **are** the list
of clusters successfully sideloaded (there is no separate roll-up table). When the planner
produced misconfiguration rows it also renders a **`### Plan warnings / errors`** table
(`Cluster | Status | Message`, with statuses `NotInAllowList`, `UnknownAuthAccountId`,
`NoCatalogEntry`, `NoneReady`). It writes `sideload-status.md` + `sideload-junit.xml` to the
reports directory (uploaded as the `azlocal-sideload-updates-report_<UTC>` artefact); the
JUnit test-suites name is `AzLocalSideload` with one `<testcase>` per cluster and `Failed`
states emitted as `<failure Type='SideloadFailed'>`.

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
5. **Tag the fleet** (Config: 1 / Config: 2): set `UpdateRing`, `UpdateStartWindow`, and
   `UpdateAuthAccountId` on each sideloaded cluster.
6. **Set the repository variables** (section 6), starting with `SIDELOAD_UPDATES=true`.
7. **Dry run**: trigger the pipeline manually with `dry_run=true` and review the planned
   transitions + the `sideload-status` artefacts.
8. **Enable the CRON**: uncomment the bundled `*/30 * * * *` schedule inside the
   `BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` block (preserved across
   `Update-AzLocalPipelineExample` upgrades). The Config: 3 schedule-coverage audit can
   recommend a lead-time-aware cron (apply window minus `SIDELOAD_LEAD_DAYS`).
9. The state machine advances each cluster to `Imported` / `SideloadFlagged`; the
   downstream **Update: 3 - Apply Updates** wave then applies the staged update during the
   cluster's `UpdateStartWindow`.

---

## 9. Preflight (v0.8.76+)

Update: 2 is **opt-in and off by default** and requires an on-prem self-hosted runner /
agent that most repos and projects do not have. Before v0.8.76 a triggered run with
no setup completed simply showed `Status: Skipped` (no logs, no annotation), which
gave operators no actionable feedback. v0.8.76 prepends a `preflight` job
(GitHub Actions) / `Preflight` stage (Azure DevOps) that always runs on
`windows-latest` (Microsoft-hosted, no Azure/Key Vault access, ~10s).

### Behaviour matrix

| `SIDELOAD_UPDATES` | `SIDELOAD_STATE_ROOT` | Self-hosted runner (GH only) | Preflight outcome | `sideload` job |
|---|---|---|---|---|
| unset / `'false'` / other | n/a | n/a | **Succeeds** with enablement walkthrough in step summary + `::notice` annotation | Skipped by its own `if:` / `condition:` |
| `'true'` / `'True'` / `'TRUE'` / `'1'` | unset | n/a | **Fails** (exit 1) with "missing variable" panel + `::error` | Skipped (`needs:` / `dependsOn:` unmet) |
| accepted | set | no online `azlocal-sideload` runner AND runners API returned a list | **Fails** (exit 1) with "no online runner" panel + `::error` | Skipped |
| accepted | set | runners API returned 403/404 (most repos) | **Succeeds** with warning ("could not enumerate runners - verify manually") | Runs |
| accepted | set | online `azlocal-sideload` runner found | **Succeeds** with "Preflight passed" panel | Runs |

### Why a Microsoft-hosted Windows runner is fine for preflight

The preflight does NOT touch the cluster fabric, Key Vault, or any Azure resource.
It only reads workflow / pipeline variables, optionally queries the GH runners API,
and writes markdown to the step summary. There is no domain-membership or
VLAN-reachability requirement, so `windows-latest` is the correct minimal-cost host.

The actual `sideload` job still **must** run on the self-hosted runner with the
`azlocal-sideload` label (GH) or pool capability (ADO), because the on-prem copy +
WinRM steps cannot work from a Microsoft-hosted runner (no line-of-sight to the
fabric VLAN, no AD trust).

### Runner-enumeration permission (GH Actions only)

The preflight tries to call `GET /repos/{owner}/{repo}/actions/runners` with
`GITHUB_TOKEN` and the workflow's `actions: read` permission. GitHub's repo
runners API actually requires **repo-admin** privilege, which `GITHUB_TOKEN` does
not hold by default - so for most callers the API will return 403 and the
preflight degrades to a warning ("verify manually under Settings -> Actions ->
Runners"). When the API does return a list (e.g. a fine-grained PAT or a GitHub
App is wired into the workflow with `administration: read`) the preflight reports
the exact set of matching online runners.

### Azure DevOps does not enumerate agents

The ADO preflight stage validates the gate + `SIDELOAD_STATE_ROOT` only. The
`Agent Pools (read)` scope required to call the ADO agent enumeration API is
not normally granted to the pipeline identity, so the preflight relies on the
operator having verified the `azlocal-sideload` capability is present in their
self-hosted pool (Project Settings -> Agent pools -> &lt;pool&gt; -> Capabilities).
If no matching agent is online the `Sideload` stage will sit `Queued` until
manually cancelled.

---

## 10. External endpoints requirements

The self-hosted runner/agent has **two independent network conversations** - its CI/CD
control plane and the on-prem cluster fabric - plus an Azure control-plane conversation and
an **optional** Microsoft update-media download. Plan firewall rules for each separately.

### 10.1 CI/CD control-plane endpoints (runner/agent <-> GitHub / Azure DevOps)

The runner/agent must reach its CI/CD service to receive jobs and upload logs/artefacts.
These are the **standard self-hosted runner/agent endpoints** - not specific to this module -
and the authoritative, always-current allow-list is in the vendor docs:

- **GitHub Actions self-hosted runners** - [About self-hosted runners -> communication requirements](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners). The commonly required hosts include `github.com`, `api.github.com`, `*.actions.githubusercontent.com`, `codeload.github.com`, and `objects.githubusercontent.com` (plus `*.pkg.github.com` / `ghcr.io` if you pull container actions). Treat the linked doc as canonical - GitHub changes the list over time. GitHub also publishes its ranges at [`https://api.github.com/meta`](https://api.github.com/meta).
- **Azure DevOps self-hosted agents** - [Self-hosted agents: firewall URLs / allowed addresses](https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/agents). Core hosts include `dev.azure.com`, `*.dev.azure.com`, `*.vssps.visualstudio.com`, and `*.vsblob.vsassets.io`; the doc's Azure DevOps IP/allow-list guidance is authoritative.

### 10.2 Azure control-plane endpoints (pipeline identity)

The `sideload` job reads the fleet via Azure Resource Graph, reads the Key Vault secrets,
and writes the `UpdateSideloaded` / `UpdateVersionInProgress` tags. That needs outbound
HTTPS to:

- `https://management.azure.com` - Azure Resource Manager + Resource Graph.
- `https://login.microsoftonline.com` - Entra ID token acquisition.
- `https://<your-vault>.vault.azure.net` - Key Vault secret reads.

### 10.3 Fabric-plane endpoints (runner/agent <-> clusters)

- **SMB (TCP 445)** to each cluster's infrastructure `import` share for the robocopy.
- **WinRM over HTTPS (TCP 5986)** to a cluster node for the SHA256 verify + `Add-SolutionUpdate`.

These live on the fabric VLAN and are the reason the runner/agent must be on-prem.

### 10.4 Microsoft update-media endpoints (OPTIONAL - only if the runner downloads bundles)

**A fully air-gapped runner needs none of the endpoints in this subsection.** In that case
you pre-stage the media yourself - set `localPath` on a `Solution` catalog row, or use an
`SBE` `sourceFolder` - and the pipeline verifies + copies it with **no internet access**.

If instead you allow the runner **limited egress** to fetch the Microsoft solution bundles
automatically, the relevant Microsoft endpoints are:

- **Update manifest (XML):** [`https://aka.ms/AzureEdgeUpdates`](https://aka.ms/AzureEdgeUpdates) - the unauthenticated Azure Edge Updates manifest (root element `ASZSolutionBundleUpdates`) that lists the currently-applicable solution-bundle versions. This is the same manifest the module uses to compute the supported-version window.
- **Solution-bundle download URIs:** each catalog row's `downloadUri`, sourced from the Microsoft Learn *"[Import and discover updates offline](https://learn.microsoft.com/en-us/azure/azure-local/manage/import-discover-updates-offline-23h2)"* table. These bundles are served from Microsoft content-delivery hosts - **confirm the exact host of each `downloadUri` in your own catalog and allow-list it** rather than assuming a fixed CDN name (Microsoft may change hosts between releases).
- **Catalog refresh (author's workstation, not necessarily the fabric runner):** `Update-AzLocalSideloadCatalog` fetches the Learn page above to populate/refresh the `Solution` rows in `sideload-catalog.yml`. Run it wherever you author the catalog.

### 10.5 Should the pipeline auto-download, cache, and commit the catalog?

**The download-and-cache behaviour already exists, and it does *not* require a Git commit.**
`Get-AzLocalSolutionUpdateDownload` downloads a `Solution` bundle from its catalog
`downloadUri` into `SIDELOAD_CACHE_ROOT` on first use, SHA256-verifies it (atomic move, so
concurrent runners are safe), and serves every subsequent cluster from that cache. The
cache is a **runtime UNC location**, not a source-controlled file - nothing is committed
for the download itself, and only the first cluster of a given version pays the
download + hash cost.

The **only** thing that lives in Git is the catalog *metadata* (`version`, `downloadUri`,
`sha256`, `availabilityDate`), and refreshing it is a **deliberate, reviewable** step you
run with `Update-AzLocalSideloadCatalog` and merge via a normal PR. This split is by
design - pinning the `sha256` in source control is what lets the runtime path **prove** the
bundle it downloaded (or that you pre-staged) is exactly the one you reviewed. An
auto-commit from the pipeline would defeat that supply-chain check and would require the
pipeline identity to hold write access to your repository. Recommended split:

- **Author / refresh the catalog** with `Update-AzLocalSideloadCatalog` -> review -> commit (occasional, human-in-the-loop).
- **Let the runtime path download + cache + verify** against the committed `sha256` (automatic, every run, no commit).

