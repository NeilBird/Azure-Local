# Sideload Updates (on-prem, opt-in) - Update: 2

> **Introduced in v0.8.7. Hardened in v0.9.22. Improved in v0.9.39.** Opt-in, off by default.
> The fleet enablement setting lives only in `config/sideload-settings.yml`; the
> fleet pipeline is inert while that file contains `enabled: false`, except for an
> explicitly requested manual single-cluster validation run (v0.9.39).
>
> **Setup effort:** sideloading is one of the module's more involved initial setups.
> It is not a single CSV or YAML change: it brings together a self-hosted runner,
> shared storage and network access, pipeline and Windows identities, Key Vault
> secrets, and coordinated settings, auth-map, catalog, and ring-policy files.
> Plan the first setup with your CI/CD, Azure, and AD/cluster administrators, and
> follow the one-cluster pilot checklist below before enabling fleet schedules.
>
> **After initial acceptance:** most infrastructure and configuration can be reused.
> Each update cycle normally focuses on staging the approved media, reviewing its
> catalog path/version/checksum and allowed-version policy, approving execution,
> and monitoring copy/import and the separately approved installation. You do not
> recreate the runner, vault, secrets, or all configuration files for every update.
> Credential rotation, permission/network changes, and runner or template upgrades
> still require maintenance and appropriate revalidation.
>
> **Validation status:** this workflow has not yet been validated end to end on
> self-hosted runner/agent VMs with network access to target clusters. Unit tests,
> configuration checks, and local copy tests do not establish that remote SMB,
> WinRM, scheduled-task identities, verification, import, and readiness work together.
> Complete the pilot acceptance checklist below before enabling production schedules.
>
> Every run starts with a `preflight` job/stage on a Microsoft-hosted Windows
> runner that writes a clear panel to the run step summary explaining what is set,
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
For safe rate/logging profiles and the distinction between pipeline diagnostics and
detached worker logs, see [logging and downloadable diagnostics](sideload-robocopy.md#logging-and-downloadable-diagnostics).

---

## Start Here: One Cluster, One Runner

Use this checklist for a first customer pilot, then consult the numbered reference
sections below as needed. Start with one approved **non-production** cluster. You
can validate planning before building the copy infrastructure; a real copy still
requires the identities, storage, and connectivity checks below. The end-to-end
validation limitation at the top of this guide still applies.

### How Targeting and Look-Ahead Work

The pipeline does not sideload every cluster just because `enabled: true` is set.
That setting enables execution; the plan determines the targets:

1. Query Azure Resource Graph for clusters with a nonempty `UpdateAuthAccountId`,
   subject to fleet scope filters and the requested UpdateRing filter.
2. Match each cluster's `UpdateRing` to ring entries in the schedule referenced by
   `paths.applySchedule` (normally `config/apply-updates-schedule.yml`). The planner
   searches the next 366 days of schedule firings for a matching window.
3. Calculate `DueNow` from `NextWindowUtc - planning.leadDays`. The default is
   **7 days**, not one; set `planning.leadDays: 1` for a one-day staging lead.
   The schedule helper returns matching **UTC days at midnight**, so a ring due
   on September 30 has `NextWindowUtc` of September 30 at 00:00 UTC and becomes
   due for staging on September 23 at 00:00 UTC with a seven-day lead. This is
   day-based planning, not the cluster's precise `UpdateStartWindow` hour and not
   permission to install early. Inspect the actual `NextWindowUtc` in the plan.
4. Read the cluster's available updates, retain those with state `Ready`, and use
   the shared next-update selector with the resolved version allow-list. It chooses
   the latest eligible Ready update by YYMM; `Latest` alone means no version
   constraint. Match the selected version and package type to the sideload catalog to obtain the
   media source/hash.

**Selection limits:** the planner relies on Azure-reported (ARM) update availability; it
does not independently calculate the cluster's complete upgrade path or choose a
bundle just because it is the newest entry in the catalog. Improved in v0.9.39:
the allow-list is resolved for the cluster's next matching ring day, using only
that ring's matching rows (including wildcard rows), not today's unrelated rings.
`NoneReady`, `NotInAllowList`, `NoCatalogEntry`, and `NotDue` are reasons to inspect the plan, not force a copy.

**Allow-list safety boundary:** a new plan with an explicit effective allow-list
selects only matching Ready update names/versions; no match produces
`NotInAllowList`, with no fallback to latest. Configure `allowedUpdateVersions`
at the top level of `config/apply-updates-schedule.yml`, or override it on the
applicable schedule row. Row overrides take precedence; review all rows matching
the target ring and day. A validation update name does not bypass this policy.
Changing the list does not cancel a detached copy already in progress. Review
`AllowedUpdateVersions`, `SelectedUpdateName`, and `SelectedVersion` before each
live reconciliation; an ineligible plan or mismatched operation identity blocks
further advancement.

Existing in-flight sideload state for a cluster in the plan can still be reconciled when it is no longer due. Changing lead time or ring filters is not a cancellation mechanism. The `maxUpdateRingTagConcurrentJobs` setting is unrelated: sideloading uses
`reconciliation.maxConcurrentCopies` and `maxConcurrentCopiesPerRunner`.

### Step 1 - Isolate the Pilot

- [ ] Choose one cluster and record its full Azure resource ID. For the v0.9.39 exact-ID validation mode, retain its existing `UpdateRing`; a dedicated pilot ring is optional to test sideloading updates (_item below_).
- [ ] Optional - For a ring-only pilot instead, assign a dedicated ring such as `SideloadPilot` to **only that cluster** through the approved tag-management CSV and Config: 2 workflow. Review Config: 2's scope separately before applying tags; the sideload input does not constrain Config: 2.
- [ ] Confirm its numeric `UpdateAuthAccountId` matches the intended row in the source-controlled `config/sideload-auth-map.csv`. This file maps `UpdateAuthAccountId` (not `UpdateRing`) to Key Vault secret names for cluster WinRM authentication. Robocopy accesses UNC shares as the separately configured scheduled-task principal; see [authentication](#4-authentication).
- [ ] **GitHub Actions:** in your consumer repository, open `.github/workflows/sideload-updates.yml` (Update: 2) and `.github/workflows/apply-updates.yml` (Update: 3). Comment out each entire `on.schedule` block, including every `- cron:` entry, inside the `BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` markers. Leave `workflow_dispatch` enabled for approved manual runs. If the cron blocks are already commented out or absent, leave them that way.
- [ ] **Azure DevOps:** open the repository YAML files configured for your Update: 2 and Update: 3 pipelines (normally named `sideload-updates.yml` and `apply-updates.yml`). Comment out each entire top-level `schedules:` block, including its cron, branch filters, and other schedule properties, inside the schedule-trigger markers. Also disable any schedules configured in the pipeline UI; commenting YAML does not disable UI-defined schedules.
- [ ] **Publish and verify the pause:** commit and push the edited workflow files, completing the required PR/merge. For GitHub, the change must reach the repository's **default branch**; editing only a local or feature-branch copy does not stop scheduled runs. For Azure DevOps, update every branch whose pipeline schedules can target the pilot and verify the pipeline's scheduled-run view. Keep production Update: 3 apply schedules paused until installation is separately approved.
- [ ] **Check existing and competing runs:** inspect queued/running Update: 2 and Update: 3 runs, coordinate cancellation or completion, and prevent other operators or external automation from launching them against the pilot. Removing cron entries does not cancel queued/running jobs, stop detached copy tasks, or stop an update already submitted to the cluster. Retain `config/apply-updates-schedule.yml`: it supplies ring/ISO-week/version policy, not the CI/CD cron trigger.
- [ ] Agree on the bundle version, target node/import share, and whether today's approval covers planning, copying, or import.
- [ ] Open the manual run form: **GitHub: Actions > Update: 2 - Sideload Updates (Opt-in) > Run workflow**; **Azure DevOps: Pipelines > your sideload pipeline > Run pipeline**.
- [ ] For an exact-resource-ID pilot, enable **Single-cluster validation**, enter **Cluster resource ID** and the **exact Ready update name** (for example, `Solution12.2608.1003.9`, not just `12.2608.1003.9`), and leave **Preview / dry-run** at `true` initially. Copy the actual `UpdateName` offered by the cluster; this example is illustrative. These are per-run inputs, not repository variables or settings-file entries.
- [ ] For a ring-only pilot, enter `SideloadPilot` in the **UpdateRing tag value to scope the plan** field (`update_ring` in GitHub; `updateRing` in Azure DevOps). Do **not** leave that input at `***` unless an exact cluster resource ID is also supplied and verified. With an exact ID, `***` does not broaden the plan beyond that cluster.

**Checkpoint:** concurrency `1` limits simultaneous copies; it does not limit scope
to one cluster. The exact resource ID (or dedicated ring for a ring-only pilot) and
inspected plan provide that boundary. The new inputs require the refreshed v0.9.39
templates and module; they are not available in the published v0.9.38 templates.

### Step 2 - Prepare Files and Review the Plan

Use the consumer repository's generated files. The pipeline copy/update helper
creates missing starters but does not overwrite or migrate existing settings files.

| File | Minimum pilot preparation |
|---|---|
| `config/sideload-settings.yml` | Keep `enabled: false` initially. Review `paths.authMap`, `paths.catalog`, `paths.applySchedule`, and `planning.leadDays`. |
| `config/sideload-auth-map.csv` | Map the pilot's numeric account ID to Key Vault and username/password **secret names**, never secret values. See [authentication](#4-authentication). |
| `config/sideload-catalog.yml` | For the pre-downloaded-media pilot, set `localPath` to the full Solution ZIP path, `downloadUri: ''`, and the published SHA256. Follow Step 2a below; include OEM SBE media only when required. |
| `config/apply-updates-schedule.yml` | Include a valid upcoming window and allowed-version policy for the pilot cluster's ring. Validation bypasses the wait until that window's lead time, not the policy lookup. No live apply trigger is required. |

#### Step 2a - Configure the Pre-Downloaded Media Catalog

**Update name versus version:** these fields deliberately accept different values.
For a Solution update whose `UpdateName` is `Solution12.2608.1003.9` and `Version`
is `12.2608.1003.9`:

| Field | Expected value |
|---|---|
| Manual **Exact Ready update name** (`validation_update_name` / `validationUpdateName`; PowerShell `-ValidationUpdateName`) | `Solution12.2608.1003.9` only. The version-only value is not accepted as an alias. |
| Catalog `packages[].version` | `12.2608.1003.9`, matching the cluster's `Version`, with `packageType: Solution`. Do not add the `Solution` prefix. |
| Schedule `allowedUpdateVersions` (top-level or per-row) | Either `Solution12.2608.1003.9` or `12.2608.1003.9` is accepted. Full update names are recommended for consistency; `Latest` remains the unconstrained option. |

Read both values from the exact pilot cluster before filling in the files/form:

```powershell
Get-AzLocalAvailableUpdates -ClusterResourceId '<full cluster ARM resource ID>' -PassThru |
   Where-Object { $_.UpdateState -eq 'Ready' } |
   Select-Object UpdateName, Version, PackageType, UpdateState
```

For OEM SBE updates, copy the actual `UpdateName` and `Version` values separately;
do not construct the name by adding `SBE` to a version. The catalog version is not
necessarily numeric. If the cluster provides no version, the planner falls back
to its exact update name for catalog matching. The pilot still must pass the next
matching ring window's `allowedUpdateVersions` policy.

1. **Choose the source location.** Keep the approved, already downloaded
   `CombinedSolutionBundle.<build>.zip` intact on the pilot runner VM, for example
   `D:\SideloadMedia\CombinedSolutionBundle.12.2605.1003.210.zip`. Use the actual
   approved version, not this illustrative build. `localPath` must name the ZIP
   **file**, not a directory or the cluster's destination import share.
2. **Account for runner selection.** With a runner-local drive path, every eligible
   runner VM must have the same approved ZIP at that exact path. For a one-runner
   pilot, ensure only the prepared runner is eligible for this job. Alternatively,
   use a shared source such as
   `\\fileserver\update-media\CombinedSolutionBundle.12.2605.1003.210.zip`.
   Use UNC paths, not interactive-user mapped drives. Both the coordinator account
   and scheduled-task principal must be able to read the source; an administrator's
   successful file read alone does not prove this.
3. **Edit the consumer catalog.** In `config/sideload-settings.yml`, confirm
   `paths.catalog` points to `config/sideload-catalog.yml` (or your reviewed custom
   location). Edit that catalog, not just the module's example file. Include one
   entry for the approved Solution version and replace the hash placeholder below
   with its actual published 64-character SHA256. Remove unused starter entries
   from the pilot catalog, including the sample OEM SBE entry unless required.

```yaml
schemaVersion: 1
packages:
  - version: '12.2605.1003.210'
    packageType: Solution
    buildNumber: '12.2605.1003.210'
    localPath: 'D:\SideloadMedia\CombinedSolutionBundle.12.2605.1003.210.zip'
    downloadUri: ''
    sha256: '<replace with the published 64-character SHA256>'
```

4. **Verify the downloaded file before live copying.** On the prepared runner,
   run the following with your actual path. Compare the returned hash with the
   publisher's trusted checksum and the catalog value; stop on any mismatch.
   Do not use the starter's all-zero hash or treat a locally calculated hash alone
   as proof of publisher authenticity. Repeat for each runner-local copy.

```powershell
Get-FileHash -LiteralPath 'D:\SideloadMedia\CombinedSolutionBundle.12.2605.1003.210.zip' -Algorithm SHA256
```

5. **Handle OEM media separately if required.** Add an `SBE` entry with
   `sourceFolder` pointing to the approved staged OEM content, using the same
   runner-access rules. Do not put an SBE folder in a Solution `localPath`.
   Follow the OEM prerequisite procedure; a catalog entry does not resolve
   `NeedsSbe` by itself.
6. **Commit and push the configuration.** Review and commit the catalog and settings
   references, complete any required PR/merge, and select that revision for the
   manual pilot run. Do not commit ZIPs, extracted media, or secret values. Keep
   fleet `enabled: false` and the CI/CD cron triggers paused as described in Step 1.

**Source fallback:** an existing Solution `localPath` is SHA256-verified and used
directly; it is not automatically replicated to other runner VMs or copied into
the shared cache. If that file is missing, the runtime checks the shared cache and
then tries `downloadUri`. Setting `downloadUri: ''` prevents a download but still
allows a verified cache hit. If neither source is usable, staging fails. The shared
UNC state/cache setup in Step 3 is still required for this pilot.

#### Step 2b - Review the Plan

- [ ] With Azure read access, use `Resolve-AzLocalSideloadPlan` with `-SchedulePath`, `-AuthMapPath`, `-CatalogPath`, and `-UpdateRingValue SideloadPilot`; optionally narrow with `-SubscriptionId`.
- [ ] For exact-ID validation instead, supply `-ClusterResourceId`, `-SingleClusterValidation`, and `-ValidationUpdateName` with the three file paths. The existing ring schedule is still read to resolve policy; missing matching schedule entries block the plan.
- [ ] Check `ClusterName`, `SelectedVersion`, `NextWindowUtc`, `DueNow`, `Status`, `RemotingHost`, and `TargetPath`.
- [ ] Require exactly one intended cluster. Before a copy, require `Status=Planned`, `DueNow=True`, the approved version, and the approved target path.
- [ ] Stop on warnings or an unexpected version/target. Do not broaden fleet scope or production schedules to make a test pass.

**Planning checkpoint:** you can stop here without a self-hosted runner or a working
copy path. This read-only plan does not test Key Vault secret retrieval, SMB access,
WinRM, or the scheduled-task identity. A disabled pipeline preflight only displays
setup guidance; it is not a substitute for this plan review.

### Step 3 - Prepare One Runner and Its Identities

Use [runner preparation](#81-runner-vm-and-network-preparation) and
[authentication](#4-authentication) for the detailed requirements.

- [ ] Register one fabric-connected Windows runner labelled `azlocal-sideload` (GitHub), or one Windows agent in the selected pool satisfying the `azlocal-sideload` demand (Azure DevOps).
- [ ] Configure the pipeline identity for fleet reads, Key Vault secret reads, and tag writes, including the Az PowerShell context required for Key Vault.
- [ ] Complete [Key Vault and secret setup](#42-create-or-reuse-key-vault-and-populate-secrets): create or reuse the vault, grant secret access, create the cluster WinRM username/password secrets, and record their names in the auth-map CSV.
- [ ] Choose and test the scheduled-task principal separately: a suitable gMSA/service account, or the documented Key Vault-backed password option. S4U and Interactive are not supported for UNC copies.
- [ ] Provide a reviewed shared UNC state root and media cache. An empty `paths.cacheRoot` uses the state root's `cache` subfolder. A one-runner pilot still uses UNC state.
- [ ] Complete [Step 2a](#step-2a---configure-the-pre-downloaded-media-catalog) on the prepared runner: verify the catalog's exact ZIP path and published SHA256, then confirm source read access under both coordinator and task identities before the first live copy.
- [ ] Test task-principal access to read media, write state/logs, and write the cluster import share. Test the runner service account's coordinator access and ability to register/start/manage the task separately.
- [ ] Verify DNS, SMB, HTTPS WinRM, trusted certificates, free space, and required outbound endpoints. Do not bypass certificate validation.
- [ ] Inspect existing state and tasks for the pilot across known runners. Do not delete state or choose a new state root to conceal an existing operation.

### Step 4 - Configure and Dry Run

Start from [sideload-settings.example.yml](../sideload-settings.example.yml). Retain
its structure and defaults except for reviewed pilot values:

| Setting | Pilot value |
|---|---|
| `paths.stateRoot` | The approved shared UNC root. |
| `identity.task.principalUserId` / `logonType` | The tested task identity and supported logon type; supply password secret references when using `Password`. |
| `remoting.fqdnSuffix` | The suffix needed for the reviewed target, unless the auth-map override supplies it. |
| `reconciliation.maxConcurrentCopies` | `1` |
| `reconciliation.maxConcurrentCopiesPerRunner` | `1` |
| `enabled` | Keep `false` for explicit single-cluster validation. Set `true` only when approving normal ring/fleet sideload execution. |

- [ ] Manually run **Update: 2 - Sideload Updates** with the exact-ID validation inputs (or the isolated pilot ring) and dry run enabled (`dry_run=true` in GitHub; `dryRun=true` in Azure DevOps). Both default to `true`.
- [ ] Inspect preflight, plan warnings, and the sideload summary; confirm the single intended target and no unexpected existing state.
- [ ] Expect no media staging, task registration, or tag writes. A dry-run pass does not prove the real copy/import path.

Keep normal HTTPS certificate validation. The templates do not wire every remoting
configuration field through to execution; see [configuration](#6-configuration-configsideload-settingsyml).

### Step 5 - Test Copying Only, Then Stop

There is **no dedicated copy-only pipeline switch**. The following controlled test
uses the first transition of a fresh operation. It is safe to stop before import
only when there is no existing pilot state and no competing reconciliation run.

- [ ] Reconfirm exactly one `Planned` cluster and **no existing state or active operation** for it. If state exists, investigate it; do not clear it to force this procedure.
- [ ] Obtain approval for real media staging/copying and the `UpdateSideloaded=False` tag write. Keep all recurring sideload/apply runs disabled.
- [ ] Trigger **one** manual live run with the same exact-ID validation inputs (or isolated pilot ring), setting dry run to `false`. From no state, this run stages verified media and launches the detached copy task; it does not also import in that invocation. Exact-ID validation does not require changing fleet `enabled: false`.
- [ ] Verify the expected source/target, owner, task principal, operation ID, and `Copying` state. After the pipeline ends, inspect shared state and the central robocopy log directly as the worker continues.
- [ ] Confirm heartbeat and byte progress advance, then the worker records `Copied` and a successful copy result. Investigate failures instead of blindly rerunning.
- [ ] **Stop without another live pipeline run.** A later invocation seeing `Copied` can verify and import automatically. Do not use live reconciliation merely to refresh a copy-only test's display.
- [ ] Retain the state/log evidence and keep the apply gate closed. Do not set `UpdateSideloaded=True`, delete state, or remove media to manufacture success.

**Copy checkpoint:** `Copied` proves the worker completed its copy stage, not that
remote verification/import or update installation succeeded. Pausing here does not
cancel an active worker: disabling pipeline execution or ending the pipeline will
not stop a detached copy already running. If abandoning the pilot, coordinate task,
media, state, and tag cleanup using the [recovery guidance](#83-recovery-and-escalation).

### Step 6 - Separately Approve Import and Installation

- [ ] With import approval, rerun the same pilot scope to perform remote checksum verification and import/discovery. Continue serialized reconciliation as required.
- [ ] Stop on `Failed`, `ImportFailed`, or `NeedsSbe`. Accept staging only at `Imported`, with the approved version visible to the update service and expected gate/version tags present.
- [ ] Complete the [pilot acceptance checklist](#82-pilot-acceptance-checklist), including recovery tests and owner-side task cleanup.
- [ ] Separately approve Update: 3 within the pilot maintenance window; verify completion, health, and gate reset before widening scope.

Defer multiple runners, HA/failover design, fleet-scale tuning, and automatic schedules
until the pilot is accepted. Uncommenting cron alone does not enable scheduled live
operation; follow the acceptance checklist's scheduling guidance.

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
(plan status: Planned) -> Copying -> Copied -> Discovering -> Imported
                              |          |             |
                              v          v             v
                           Failed   ImportFailed    NeedsSbe
```

`Planned` is a plan status, not persisted state. Copy retries are separate from
import retries: `ImportFailed` reuses the copied media and does not launch another
robocopy. `Discovering` polls an already-submitted import without expanding the bundle
or calling `Add-SolutionUpdate` again. `NeedsSbe` is an explicit manual-action state.

Per cluster, the current shared state determines the action taken by
`Invoke-AzLocalSideloadUpdate`:

| Current state | Action |
|---|---|
| (no state) + due now | Set `UpdateSideloaded=False`, clear `UpdateSideloadedVersion`, resolve verified local/cache/download media, register + start the detached copy Scheduled Task, write `Copying` state with exact update name and cluster resource ID. |
| `Copying` + fresh heartbeat | Report progress, leave the task running. |
| `Copying` + stale heartbeat or no progress | Stop/replace the old task and re-drive with a new operation ID, up to the copy retry limit. |
| `Copied` | Open a WinRM session, verify the remote SHA256, run `Add-SolutionUpdate` + discovery, require the exact staged update name, flip `UpdateSideloaded=True`, stamp `UpdateSideloadedVersion` and `UpdateVersionInProgress`, mark `Imported`, remove the task. |
| `Discovering` | Poll discovery only; do not expand or submit the update again. |
| `NeedsSbe` | Surface the required OEM action; retain media and state. |
| `ImportFailed` | Bounded import-only retry; do not recopy media. |
| `Failed` | Bounded copy retry, else surface the error as a JUnit `<failure>`. |
| `Imported` + same selected identity | No new copy or import. |
| `Imported` + different eligible identity | Restage only when due and both copy limits have capacity, after a fresh update-state check. Otherwise defer without replacing existing state. |

**Improved in v0.9.39:** before advancing an operation, the coordinator checks its
exact update identity against the current eligible plan. A fresh Azure update read
must show the selected update as `Ready`, with no preparation, installation,
`ReadyToInstall`, or unknown update state, before copying/restaging or advancing an
in-flight operation. A failed read or failed safety check blocks advancement and
preserves state; it does not stop a detached worker already running. These checks
are not a lock against another process starting an installation: serialize sideload
and apply operations.

`UpdateSideloadedVersion` stores the exact update name (for example,
`Solution12.2605.1003.210`), not just the numeric version. When that tag is present,
Update: 3 requires the selected update to match it and satisfy the effective
allow-list, even with an explicit update name or `Force`. Successful reset clears
both version tags and closes the boolean apply gate for the next staging cycle.

**Existing state on upgrade:** legacy boolean-only apply gates remain supported.
Legacy in-flight state without the exact update identity is blocked for operator
review; do not invent an identity or delete state to bypass this check. An older
`Imported` record without identity is treated as requiring restaging, subject to
the same eligibility, lead-time, and active-update checks. State filenames remain
cluster-name based, so use unique cluster names within a shared state root; a
stored resource ID belonging to another cluster is rejected.

Reconciliation is designed to resume recorded work, but this is not an exactly-once
guarantee. Serialize runs, retain shared state, and investigate ambiguous import or
ownership outcomes before forcing a retry. Do not run competing copies of the workflow
against the same clusters or delete state to clear an error.

A detached worker survives the pipeline ending or the agent service recycling while
Windows remains running. It does **not** continue through a host reboot, and the task
has no automatic reboot trigger. After a reboot, the next reconciliation must detect
stale state and re-drive work within the configured retry limits. Confirm the previous
owner's copy has stopped before operator-directed failover.

### 2.1 The per-cluster state JSON *is* the heartbeat

There is **no separate heartbeat or marker file**. Each cluster's `state\<cluster>.json`
holds both the current `State` and the progress fields the detached worker rewrites
roughly every configured heartbeat interval while the copy runs. It includes
`UpdateName`, `ClusterResourceId`, `OperationId`, `LastHeartbeatUtc`, `LastProgressUtc`, `OwningMachine`, worker and
robocopy process IDs, byte progress, throughput, ETA, exit code, retries, task name,
log path, and message. Workers check the operation ID before replacing state. This
check is not a distributed lock: ownership checking and file replacement are separate
operations. Serialization and controlled failover remain required.

### 2.2 The detached copy Scheduled Task (and an important account caveat)

The copy worker is registered with `Register-ScheduledTask` (not `schtasks`) as
`AzLocalSideload_<sanitized-cluster>`, running `powershell.exe -File
Tools/Invoke-AzLocalSideloadCopyTask.ps1` with `ExecutionTimeLimit = 0` (no time limit, so
a multi-hour copy is never killed). The task is **removed** (`Unregister-ScheduledTask`)
only when the cluster reaches `Imported`. A terminally `Failed`, `Verified` (NeedsSbe), or
still-importing task is **left registered**; the next retry re-registers the same-named
task, which replaces the old one.

> **IMPORTANT - task logon account.** S4U and Interactive are rejected for UNC-backed
> copies. Configure a **gMSA/service account** (`ServiceAccount`) or a principal with a
> Key Vault-backed stored password (`Password`). `principalUserId` is required when
> sideloading is enabled. Provision read access to `paths.cacheRoot` and read/write access
> to `paths.stateRoot` and every cluster import share.
> (This is the cluster **WinRM** credential's sibling but a *different* identity - see
> section 4.)

---

## 3. Shared state and multi-runner / multi-agent contract

`paths.stateRoot` must be a **UNC path that every runner/agent can read and write**.
It holds three subfolders:

- `state\` - one JSON document per cluster tracking the current transition + heartbeat.
- `logs\`  - one robocopy log per copy run, named `<cluster>.<yyyyMMddHHmmss>.robocopy.log` (the worker appends `/LOG:<that path>` to its robocopy switches). There are **no** separate verify/import log files - the SHA256-verify and `Add-SolutionUpdate` outcomes live in the state JSON `Message` field and the step summary.
- `cache\` - the verified media cache (overridable via `paths.cacheRoot`; defaults
  to `<state-root>\cache`).

Because a bundle is downloaded and hashed **once** into the shared cache and then reused
across every cluster that needs that version, only the first cluster pays the download +
hash cost.

### 3.1 Scaling considerations for the self-hosted runner pool

The CI/CD scheduler assigns the entire sideload reconciliation job to **one** eligible
runner/agent. It does not split a 100-cluster plan across 100 runners. That selected host
can register up to `reconciliation.maxConcurrentCopies` detached Scheduled Tasks; later
reconciliation jobs may be assigned to a different host.

`maxConcurrentCopies` is the fleet/network ceiling. The optional
`maxConcurrentCopiesPerRunner` is the host ceiling; existing schema-1 files that omit it
fall back to `maxConcurrentCopies`. Each serialized run counts every fresh `Copying`
record globally, then counts records whose `OwningMachine` is the current host. A new copy
starts only when both limits have capacity.

For example, a pool whose runners have been tested with ten throttled copies could use:

```yaml
reconciliation:
   maxConcurrentCopies: 30
   maxConcurrentCopiesPerRunner: 10
```

This permits at most 30 copies across the fabric and at most 10 on any one runner. It does
not guarantee even distribution: the CI/CD scheduler chooses the host for each serialized
reconciliation job, and the same available host may receive successive jobs. Increase
either limit only after measuring the shared cache/file-server IOPS, WAN/SMB bandwidth,
per-cluster import-share capacity, and aggregate effect on production traffic. Configure a
copy profile with an appropriate `interPacketGapMilliseconds` when throttling is required;
an inter-packet gap is pacing, not a precise bandwidth reservation.

For 100 due clusters with the default `maxConcurrentCopies: 2`, work proceeds in roughly
50 copy waves. A new wave can start only on the next reconciliation after capacity becomes
free, so a practical lower-bound estimate is:

```text
copy waves = ceiling(cluster count / maxConcurrentCopies)
wave time   = copy duration rounded up to the reconciliation interval
total copy stage ~= copy waves * wave time
```

For example, if each copy takes about two hours and reconciliation runs every 30 minutes,
the copy stage is approximately 50 x 2 hours = 100 hours, before allowing for import time,
retries, or uneven links. Raising the limit to 10 gives about 10 waves, but only if the
storage and network can sustain ten concurrent copies. More runners alone do not change
that calculation.

### 3.2 Runner-local task affinity and failover

Each `AzLocalSideload_<cluster>` Scheduled Task exists only on the runner/agent that
started that copy. Its `OwningMachine`, task name, operation ID, worker PID, robocopy PID,
heartbeat, progress, and central log path are recorded in shared state.

If the next job lands on another host, that host can:

- read and report the existing heartbeat and progress;
- see `Copied` and perform remote verification/import;
- re-drive stale work with a new operation ID so the superseded worker cannot overwrite
   the current state.

It cannot manage Windows Task Scheduler on the previous host. In particular, importing
from Runner B cannot unregister the completed task definition left on Runner A. That task
is no longer doing copy work, but its definition can remain until Runner A next replaces
it for the same cluster or an operator removes it. For cleanup, use the `OwningMachine`
and `TaskName` fields from `state\<cluster>.json` and run on that host:

```powershell
Stop-ScheduledTask -TaskName 'AzLocalSideload_<cluster>' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'AzLocalSideload_<cluster>' -Confirm:$false
```

Do not delete shared state to move ownership. Let heartbeat/no-progress staleness trigger
the bounded re-drive, which creates a new operation ID and records the new owner.

PowerShell remoting between pool members can be used as an operator break-glass tool, but
it is deliberately not the orchestration control plane. Making it automatic would require
mutual WinRM/Kerberos or HTTPS trust, firewall paths between every runner, a privileged
identity able to administer every peer, and race protection around remote task actions.
It would also widen the blast radius of a compromised runner without deciding which host
should own new work. Shared state, operation ownership, stale re-drive, and the two copy
limits provide failover and capacity control without that peer-administration dependency.

### 3.3 HA and consistency contract

v0.9.22 supports an **active/passive runner pool**: multiple identically configured hosts
may be eligible so another host can run the next reconciliation when one is offline, but
only one reconciliation job may execute at a time. It is not an active-active sharding
system and does not contain a distributed lease that makes simultaneous jobs safe.

- GitHub Actions already enforces one run at a time with the workflow `concurrency` group
   and `cancel-in-progress: false`.
- For Azure DevOps, keep `batch: true` on every YAML schedule and configure the pipeline
   so manual and scheduled runs cannot overlap. Pool size or agent demands do not serialize
   runs by themselves.
- Every eligible host must use the same settings/catalog/auth-map revision, module version,
   task identity, and UNC paths.
- `paths.stateRoot` and `paths.cacheRoot` are control-plane dependencies. Put them on
   resilient SMB storage with backups, adequate capacity/IOPS, and consistent ACLs. If the
   share is unavailable, do not start another reconciliation against a different state root.

Operational control and reporting are centralized by `paths.stateRoot`, not by the runner:

- `state\*.json` is the current fleet control state and survives runner loss;
- `logs\*.robocopy.log` is the central copy log history from every runner;
- each pipeline summary/JUnit artifact is a point-in-time rendering of those shared records,
   so a later job on another runner reports the same underlying state;
- process IDs are meaningful only on the recorded `OwningMachine`.

The `reporting.retentionDays` value records the intended log-retention policy, but v0.9.22
does **not** automatically purge `logs\`. Apply a file-server lifecycle/cleanup policy and
exclude active logs referenced by a `Copying` state. Monitor free space on both the log and
cache volumes.

---

## 4. Authentication

Three **distinct identity roles** are used - do not conflate them:

1. **Pipeline identity** (Azure plane) - reads the fleet via Azure Resource Graph, reads
   the Key Vault secrets, and writes the `UpdateSideloaded`, `UpdateSideloadedVersion`, and `UpdateVersionInProgress`
   tags. Defaults to `azure/login` OIDC; `enable-AzPSSession=true` is required because
   the Key Vault secrets are read via `Get-AzKeyVaultSecret` (Az PowerShell). For on-prem
   runners where OIDC is not viable, use the `identity.keyVaultAuth` setting to document
   the `azure/login` / `Connect-AzAccount` pattern you wire
   into the YAML to establish the Az PowerShell context that `Get-AzKeyVaultSecret` then
   uses. Tag writes need only **Tag Contributor**
   (they reuse `Set-AzLocalClusterTagsMerge`).
2. **Cluster WinRM credential** (fabric plane) - an Active Directory `[pscredential]`
   built at run time from **two Key Vault secrets** named in the matching sideload
   auth-map row (a username secret + a password secret). This credential - **not** the
   pipeline identity - is used for the WinRM session and `Add-SolutionUpdate`. The
   detached copy does not automatically inherit this credential.
3. **Scheduled-task principal** - explicitly selected by
   `identity.task.principalUserId` and `logonType`. It needs read access to the
   cache/source and write access to shared state/logs and target import shares.
   It may differ from the runner service account. The runner service account must
   itself be able to register/start/manage the task and access the shared control
   state and media used by the coordinator. Test both identities separately.

### 4.1 Sideload auth-map CSV (`paths.authMap`)

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

### 4.2 Create or Reuse Key Vault and Populate Secrets

Complete this one-time setup before the first pipeline dry run. The pipeline reads
existing secrets; it does **not** create a vault, create AD accounts, populate
secrets, or grant itself access. Reuse an approved vault when its access boundaries
and network configuration are suitable; a separate vault per cluster is not required.

1. **Prepare the cluster account.** Have the AD/cluster administrator provision or
   approve the account used for HTTPS WinRM and the supported update-import
   operations. Confirm its required permissions on the target cluster. This is
   not the Azure pipeline identity and need not be the scheduled-task account.
2. **Create or select the vault.** In the Azure portal, open **Key vaults > Create**
   (or select the approved existing vault). Choose the approved subscription,
   resource group, region, and a globally unique vault name. For a new vault, use
   the **Azure role-based access control** permission model, retain soft delete,
   and enable purge protection according to your organization's policy. Record
   the vault **name**, not its URL, for the CSV. See Microsoft's
   [portal quickstart](https://learn.microsoft.com/azure/key-vault/general/quick-create-portal).
3. **Configure network access.** Ensure the self-hosted runner and the administrator's
   setup workstation can reach the vault's data-plane endpoint over HTTPS. With a
   private endpoint, verify private DNS and routing from both locations. With a
   firewall, allow only approved networks. Azure authentication and RBAC do not
   bypass the vault firewall; do not enable unrestricted public access just to
   make the test pass.
4. **Grant separate setup and runtime permissions.** Under the vault's **Access
   control (IAM)**, have an authorized administrator grant the secret-maintenance
   operator **Key Vault Secrets Officer**, or an approved equivalent. Grant the
   **pipeline's Azure identity** **Key Vault Secrets User** at the approved scope
   so it can read secret values. For GitHub this is the identity used by
   `azure/login`; for Azure DevOps it is the service-connection identity. Do not
   grant runtime secret-write permissions. **Reader**, **Key Vault Reader**, and
   **Tag Contributor** alone cannot read secret values. For an existing vault
   using access policies, have its owner configure equivalent secret permissions
   instead of changing its permission model without review. See
   [Key Vault RBAC guidance](https://learn.microsoft.com/azure/key-vault/general/rbac-guide).
5. **Create the two WinRM secrets.** Open **Secrets > Generate/Import**, choose
   **Manual**, and create a username secret and a separate password secret. For
   the first example row above, `sideload-user` contains the actual approved AD
   username (UPN or `DOMAIN\user`), and `sideload-pass` contains that account's
   password. Use your own naming convention and keep both secrets enabled and
   within their validity dates. Enter values directly in the portal; never put
   them in CSV/YAML, tickets, chat, screenshots, or pipeline logs. See
   [create a secret in the portal](https://learn.microsoft.com/azure/key-vault/secrets/quick-create-portal).
6. **Wire the auth-map row.** Edit the file selected by `paths.authMap` in
   `config/sideload-settings.yml` (default `config/sideload-auth-map.csv`). Set
   `KeyVaultName` to the vault name, `UsernameSecretName` to the username secret's
   name, and `PasswordSecretName` to the password secret's name. Match
   `UpdateAuthAccountId` exactly to the cluster tag, including leading zeros:
   `001` and `1` are different mapping keys. Commit only these references and any
   reviewed remoting overrides. Config: 2 assigns the cluster tag; this CSV only
   resolves that tag to credentials.
7. **Verify access without disclosing values.** Allow role assignments to propagate,
   then use an approved check on the self-hosted runner under the pipeline's Azure
   identity to retrieve both named secrets without printing or exporting their
   values. Verify enabled/expiry status and separately test authenticated HTTPS
   WinRM with the resolved cluster credential. Record success/failure only. A
   successful portal read as your own user does not prove pipeline access, and a
   pipeline dry run does not prove WinRM authentication. Clear temporary credential
   variables after the check and keep transcripts from capturing secret values.

**Optional scheduled-task password:** if `identity.task.logonType` is `Password`,
create a separate secret containing the password for `identity.task.principalUserId`.
In `config/sideload-settings.yml`, set `identity.task.passwordKeyVaultName` and
`identity.task.passwordSecretName` to its vault and secret names, and grant the
pipeline identity read access there too. These references belong in the settings
YAML, **not** the WinRM auth-map row. A correctly provisioned gMSA using
`ServiceAccount` does not need a task-password secret; its runner/AD prerequisites
and share permissions still apply.

**Rotation:** coordinate AD password changes with new versions of the corresponding
Key Vault secrets, then revalidate access. The runtime reads secrets by name rather
than pinning a secret version. Existing registered tasks may retain their previously
supplied password; coordinate task credential updates with any running copy instead
of assuming a vault change updates Task Scheduler automatically.

---

## 5. Catalog (`paths.catalog`)

A source-controlled YAML describing the media available to the automation. Two package
classes are supported via `packageType`:

For the test setup using media already downloaded onto runner VMs, follow
[Step 2a - Configure the Pre-Downloaded Media Catalog](#step-2a---configure-the-pre-downloaded-media-catalog).
The example below illustrates the alternative download-enabled configuration;
it is not the local-media-only pilot configuration.

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

## 6. Configuration (`config/sideload-settings.yml`)

The committed schema-1 file controls enablement, paths, planning lead time,
heartbeat/no-progress thresholds, maximum concurrent copies, named copy profiles,
task identity, remoting, and reporting. Secrets are referenced by Key Vault name and
secret name; no secret value belongs in YAML.

`Copy-AzLocalPipelineExample` and `Update-AzLocalPipelineExample` create the current
starter when it is absent. They never overwrite, merge, or migrate an existing file.
The runtime rejects unsupported schema versions with a clear error. There is no
`SIDELOAD_*` compatibility fallback.

**Upgrading to v0.9.39:** no settings-schema migration is required. Sideload
settings and catalog remain schema 1; the auth-map columns are unchanged.
`localPath` and `sourceFolder` already exist in the catalog schema. The new exact-ID
validation fields are manual pipeline inputs, not new settings-file keys. Once
the candidate is available, the normal `Update-Module-And-Pipelines.ps1` refresh
delivers the updated workflow templates through `Update-AzLocalPipelineExample`,
while preserving existing sideload settings, auth-map, and catalog files. Its
existing migrations for older fleet settings and apply schedules still apply;
v0.9.39 introduces no new migration for those files and requires no updater-script
version change. Refresh both the module and templates before using the new inputs.

Shared runtime JSON state is separate from these configuration files. New
operations record exact update and cluster identities; the updater does not
rewrite existing operations. Follow the [existing-state upgrade guidance](#2-re-entrant-state-machine--scheduled-task-survival-model)
before reconciling work started with an older module.

Start with the shipped [sideload-settings.example.yml](../sideload-settings.example.yml),
which the copy helper places at `config/sideload-settings.yml`. Keep `enabled: false`
until the identity, paths, and pilot scope have been reviewed. The current templates
use `remoting.fqdnSuffix` for target resolution but do not pass custom `port`,
`authentication`, `skipCaCheck`, or `useSsl` settings to the state machine. The bundled
execution path uses its default HTTPS remoting. Do not assume those configuration
fields override transport behavior; retain normal certificate validation and the
default HTTPS listener for the pilot.

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
> After a sideloaded cluster's update run **succeeds**, a `Get-AzLocalUpdateRuns` call
> that permits tag reset calls `Invoke-AzLocalSideloadedAutoReset`, which flips
> `UpdateSideloaded` back to `False` and clears `UpdateSideloadedVersion` and
> `UpdateVersionInProgress`, closing the apply gate until the next successful staging
> cycle (it also tidies stale
> `UpdateLastAttempt` / `UpdateRetryAttempted` tags). `Reset-AzLocalSideloadedTag` is the
> manual escape hatch for a payload you abandoned before it ever applied.
> Monitor: 3 and Update: 4 suppress this reset to remain read-only. Do not expect
> their reports alone to reset the gate; include an approved reset-capable operation
> in the post-update procedure and verify the resulting tags before the next cycle.

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

Rejected transitions also produce pipeline warnings. Because rejection preserves
the prior state, its report row can still say `Imported`; inspect the current plan
and warnings as well as the persisted-state report before approving apply.

---

## 8. End-to-end runbook

1. **Stand up the runner/agent** on the cluster fabric network and label it
   `azlocal-sideload` (GH) / give the pool the `azlocal-sideload` demand (ADO).
2. **Create the shared UNC root** (`paths.stateRoot`) readable + writable by the
   configured task principal, and grant that principal rights to each cluster's import share.
3. **Populate Key Vault** with the per-fabric AD username/password secrets and author
   `sideload-auth-map.csv`.
4. **Author `sideload-catalog.yml`** - run `Update-AzLocalSideloadCatalog` to fill the
   Microsoft Solution rows, then add any OEM SBE rows manually.
5. **Tag the fleet** (Config: 1 / Config: 2): set `UpdateRing`, `UpdateStartWindow`, and
   `UpdateAuthAccountId` on each sideloaded cluster.
6. **Configure `sideload-settings.yml`**, including the paths and network-capable task
   principal. Keep `enabled: false` for the explicit exact-ID validation pilot;
   set it to `true` only when approving normal ring/fleet execution.
7. **Dry run**: trigger the pipeline manually with `dry_run=true` and review the planned
   transitions + the `sideload-status` artefacts.
8. **Complete the pilot acceptance checklist below**, then enable the CRON:
   uncomment the bundled `*/30 * * * *` schedule inside the
   `BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` block (preserved across
   `Update-AzLocalPipelineExample` upgrades). The Config: 3 schedule-coverage audit can
   recommend a lead-time-aware cron based on `planning.leadDays`.
9. The state machine advances each cluster to `Imported`; the
   downstream **Update: 3 - Apply Updates** wave then applies the staged update during the
   cluster's `UpdateStartWindow`.

### 8.1 Runner VM and network preparation

1. Provision a supported Windows VM for the runner/agent, with PowerShell 7 for
   pipeline steps and Windows PowerShell 5.1, Task Scheduler, and robocopy for the
   detached worker. Install Azure CLI and the modules installed by the template:
   Az.Accounts, Az.KeyVault, powershell-yaml, and the intended AzLocal.UpdateManagement
   version. Record the version and settings revision used for acceptance.
2. Register the VM in the intended private repository/agent pool. Restrict who can
   queue code on it; never expose a privileged fabric runner to untrusted pull requests.
   Configure the label/capability and service account before starting the agent service.
3. From that VM, verify DNS resolution and TCP 445 to the cache/state file server
   and target import-share host, plus TCP 5986 to the selected cluster node. Verify
   the actual paths, not only ping. Use a routable, trusted network path; being on
   the same VLAN is not required, and being on a VLAN does not prove access.
4. Under the coordinator and task identities, verify the required share and NTFS
   permissions with a disposable file in an approved test directory. Confirm the
   gMSA/service account can log on for the scheduled task. For Password logon, store
   its password in the referenced Key Vault secret, never the YAML or transcript.
5. Test an authenticated HTTPS WinRM session using the separate cluster credential.
   Validate the listener certificate hostname, trust chain, and expiry. Confirm the
   identity can perform the supported import operations. Do not disable certificate
   checks or enable CredSSP simply to get past a failure. If a remote command must
   read a second UNC hop, explicitly design/test delegation or use node-local staged
   media; a successful first-hop session does not grant second-hop file access.
6. Check free space on source/cache, state/log storage, and target import/extraction
   volumes for the complete bundle and expanded payload. Use the published package
   checksum and an OEM-approved source for SBE media. Never substitute a fabricated
   hash to pass catalog validation. Validate Azure, Key Vault, and CI/CD egress
   separately using section 10; pre-staged media removes only the download requirement.

### 8.2 Pilot acceptance checklist

Keep production apply schedules disabled during this procedure. Use one approved
non-production cluster/ring, one runner, and concurrency limits of one initially.

1. Review the catalog version/hash, auth-map row, resolved node/import path, cluster
   tags, apply schedule, and planning lead time. Confirm only the pilot is due.
   Existing in-flight state may still be reconciled; inspect shared state before
   assuming a changed ring filter cancels prior work.
2. Run preflight and a manual dry run (`dry_run=true` on GitHub, `dryRun=true` on
   Azure DevOps). Inspect plan rows and warnings. Expect no media staging, task
   registration, or tag writes. A dry-run pass is not a network/credential test.
3. With change approval, run manually with dry-run false. Confirm the task principal,
   `OperationId`, owner, process IDs, source, target, heartbeat and central robocopy log.
   Confirm `UpdateSideloaded=False` while the copy is incomplete.
4. Let the pipeline finish and confirm the worker continues and heartbeats advance.
   Re-run reconciliation until `Copied`, then inspect remote checksum verification,
   import submission, and any `Discovering` or `NeedsSbe` outcome. Do not bypass a
   checksum mismatch or force `UpdateSideloaded=True` to clear a failure.
5. Accept staging only when the state is `Imported`, the selected version is visible
   to the update service, and the expected gate/version tags are present. Retain
   the plan, state, log, JUnit report and summary as restricted operational evidence.
6. Test controlled recovery in the pilot: agent restart, interrupted copy, stale
   heartbeat, share outage, invalid hash, and import failure. For host reboot or
   cross-host failover, confirm the old copy has stopped and inspect the new operation
   ID. Recovery must stay bounded and must not start an additional update/import
   blindly. Validate cleanup on the recorded owning VM.
7. Authorize the separate Update: 3 apply operation within the pilot maintenance
   window, monitor it to completion, verify health and gate reset, then approve wider
   rings only after the complete cycle has succeeded.

**Scheduled execution remains a deliberate choice.** Uncommenting cron alone is
insufficient: GitHub's `INPUT_DRY_RUN` fallback is `'true'` when no dispatch input
exists, and Azure DevOps's `dryRun` default is `true`. After pilot approval, review a
repository change that explicitly selects live operation for the scheduled path;
retain true as the manual default. Re-review that customization after template
refreshes because it is outside the preserved schedule-trigger block. Serialize all
manual and scheduled runs, including separate pipeline definitions targeting the same
state root. In Azure DevOps, `batch: true` alone is not an exclusive lock, and
`always: true` can override its scheduled overlap behavior; use an enforced exclusive
execution policy before enabling recurring live reconciliation.

### 8.3 Recovery and escalation

Disable future triggers first when investigating; cancelling a pipeline does not stop
its detached task or an already submitted cluster update. Inspect the shared state and
owner-host process/task before stopping work. Preserve logs and state, correct the
underlying access/capacity/media problem, then use the bounded reconciliation path.
`NeedsSbe` requires the OEM prerequisite procedure. An ambiguous import response
requires checking the cluster's update service before re-submission. Escalate exhausted
retries or inconsistent ownership to the operator; do not delete state or increase
retry limits until the previous operation is accounted for.

---

## 9. Preflight (v0.8.76+)

Update: 2 is **opt-in and off by default** and requires an on-prem self-hosted runner /
agent that most repos and projects do not have. Before v0.8.76 a triggered run with
no setup completed simply showed `Status: Skipped` (no logs, no annotation), which
gave operators no actionable feedback. v0.8.76 prepends a `preflight` job
(GitHub Actions) / `Preflight` stage (Azure DevOps) that always runs on
`windows-latest` (Microsoft-hosted, with no Azure or Key Vault access).

### Behaviour matrix

| `enabled` | Required settings/identity | Self-hosted runner (GH only) | Preflight outcome | `sideload` job |
|---|---|---|---|---|
| `false`, no explicit validation | n/a | n/a | **Succeeds** with enablement walkthrough | Skipped |
| `false`, manual single-cluster validation | valid settings, exact cluster resource ID, and exact update name | online matching runner | **Succeeds**; fleet flag remains off | Runs in preview by default; live copy/import requires dry-run false |
| either, invalid validation inputs or non-manual validation trigger | invalid | n/a | **Fails** before self-hosted dispatch | Skipped |
| `true` | missing path, unsupported schema, or invalid task identity | n/a | **Fails** before self-hosted dispatch | Skipped |
| `true` | valid | no online matching runner | **Succeeds**; self-hosted job waits in queue | Queued |
| `true` | valid | online matching runner | **Succeeds** | Runs |

Explicit validation still requires all normal infrastructure/identity settings.
With no matching runner it queues; with missing settings it fails preflight.
On the self-hosted runner, planning must resolve exactly one eligible cluster and
an allowed Ready update before any live transition. Validation skips waiting for
the ring's staging window, not the next matching ring policy lookup.

### Why a Microsoft-hosted Windows runner is fine for preflight

The preflight does NOT touch the cluster fabric, Key Vault, or any Azure resource.
It only reads and validates the committed settings file,
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

The ADO preflight stage validates the settings schema, required paths, and task identity. The
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
and writes the `UpdateSideloaded`, `UpdateSideloadedVersion`, and `UpdateVersionInProgress` tags. That needs outbound
HTTPS to:

- `https://management.azure.com` - Azure Resource Manager + Resource Graph.
- `https://login.microsoftonline.com` - Entra ID token acquisition.
- `https://<your-vault>.vault.azure.net` - Key Vault secret reads.

### 10.3 Fabric-plane endpoints (runner/agent <-> clusters)

- **SMB (TCP 445)** to each cluster's infrastructure `import` share for the robocopy.
- **WinRM over HTTPS (TCP 5986)** to a cluster node for the SHA256 verify + `Add-SolutionUpdate`.

These live on the fabric VLAN and are the reason the runner/agent must be on-prem.

### 10.4 Microsoft update-media endpoints (OPTIONAL - only if the runner downloads bundles)

**A runner with pre-staged media needs none of the download endpoints in this subsection.** In that case
you pre-stage the media yourself - set `localPath` on a `Solution` catalog row, or use an
`SBE` `sourceFolder` - and the media copy needs no internet download. The pipeline
still needs its CI/CD, Azure, and Key Vault control-plane connectivity; a fully isolated
runner cannot execute this cloud-orchestrated workflow as shipped.

If instead you allow the runner **limited egress** to fetch the Microsoft solution bundles
automatically, the relevant Microsoft endpoints are:

- **Update manifest (XML):** [`https://aka.ms/AzureEdgeUpdates`](https://aka.ms/AzureEdgeUpdates) - the unauthenticated Azure Edge Updates manifest (root element `ASZSolutionBundleUpdates`) that lists the currently-applicable solution-bundle versions. This is the same manifest the module uses to compute the supported-version window.
- **Solution-bundle download URIs:** each catalog row's `downloadUri`, sourced from the Microsoft Learn *"[Import and discover updates offline](https://learn.microsoft.com/en-us/azure/azure-local/manage/import-discover-updates-offline-23h2)"* table. These bundles are served from Microsoft content-delivery hosts - **confirm the exact host of each `downloadUri` in your own catalog and allow-list it** rather than assuming a fixed CDN name (Microsoft may change hosts between releases).
- **Catalog refresh (author's workstation, not necessarily the fabric runner):** `Update-AzLocalSideloadCatalog` fetches the Learn page above to populate/refresh the `Solution` rows in `sideload-catalog.yml`. Run it wherever you author the catalog.

### 10.5 Should the pipeline auto-download, cache, and commit the catalog?

**The download-and-cache behaviour already exists, and it does *not* require a Git commit.**
`Get-AzLocalSolutionUpdateDownload` downloads a `Solution` bundle from its catalog
`downloadUri` into `paths.cacheRoot` on first use, SHA256-verifies it (atomic move, so
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

