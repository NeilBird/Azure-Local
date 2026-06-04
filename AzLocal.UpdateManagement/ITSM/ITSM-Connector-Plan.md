# ITSM Connector for AzLocal.UpdateManagement - Design & Implementation Plan

> Target module version: **v0.7.4** (Phase 1 shipped) - this document describes the full three-phase design; Phases 2 and 3 are tracked as deferred.
> Status: **Phase 1 - Implemented**. Phase 2 (lifecycle close-out via `Sync-AzLocalIncident`) and Phase 3 (Teams + Slack mirror adapters) are deferred to a future release.
> Scope shipped in v0.7.4: ServiceNow incident creation, dedupe, OAuth2 client_credentials secret resolution, config loader, connection probe. Sections marked "(Deferred)" below describe the design but are NOT yet implemented in the module code or pipelines.
> Refactor of the monolithic `.psm1` into `Public/` + `Private/` dot-sourced files (Section 9) was completed pre-v0.7.4 and is therefore historical context, not a v0.7.4 work item.

---

## 1. Goals

1. Allow `apply-updates` and `fleet-update-status` CI/CD pipelines to **optionally** open ITSM tickets when a cluster needs operator action that the module's own retries cannot resolve.
2. **ServiceNow** is the v0.7.4 live target. The connector is built around a small adapter interface so other systems (Jira Service Management, Azure DevOps Work Items, generic webhook) can be added in a future release without changing pipeline YAML or core module code.
3. Side-channel notifications via **Teams** and **Slack** adapters that mirror the ticket (link + summary), wired through the same matrix. **(Deferred - design only, not shipped in v0.7.4.)**
4. **Lifecycle management**: when a previously failed cluster transitions to a healthy / succeeded state, the connector finds the open ticket(s) it opened for that cluster + update and posts a comment / transitions state (configurable). **(Deferred - design only, not shipped in v0.7.4.)**
5. **No raw secrets in YAML**. Azure Key Vault is the recommended source; native GitHub / Azure DevOps secrets are supported as a fallback for users without Key Vault access.
6. Operator-configurable **trigger matrix**: which `Status` values raise tickets, at what severity, with what category - so `ScheduleBlocked` (which self-resolves) is suppressed by default but can be opted-in.

## 2. Non-goals (deferred to v0.7.4+)

- Live Jira Service Management, Azure DevOps Work Items, generic-webhook adapters (the adapter framework is in place; additional targets remain a future-release item).
- Bidirectional sync (ITSM state -> pipeline gating, e.g. "skip cluster if open Sev 1 ticket exists").
- Custom ITSM workflows like change-request approval gates before update apply.
- Email transport (deliberately omitted - Teams/Slack/ITSM cover all observability needs and email channels diverge per tenant).

---

## 3. High-level architecture

```
+--------------------------+        +------------------------------+
| Step.6_apply-updates.yml        |        | New-AzLocalIncident       |
| Step.7_fleet-update-status.yml  | -----> | (Public)                     |
|                          |        | + Sync-AzLocalIncident    |
| Reads JUnit + CSV        |        |   (lifecycle / Phase 2)      |
| Runs ITSM step only if   |        +---------------+--------------+
| raise_itsm_ticket=true   |                        |
+--------------------------+                        |
                                                    v
                            +-----------------------+-----------------------+
                            |    Resolve-AzLocalItsmSecret                  |
                            |    (KV first, native-secret fallback)         |
                            +-----------------------+-----------------------+
                                                    |
                          +-------------------------+-------------------------+
                          |                         |                         |
                          v                         v                         v
              +-------------------+     +-------------------+     +-------------------+
              | Invoke-AzLocal    |     | Invoke-AzLocal    |     | Invoke-AzLocal    |
              | ServiceNowAdapter |     | TeamsAdapter      |     | SlackAdapter      |
              +-------------------+     +-------------------+     +-------------------+
              (Phase 1)                 (Phase 3 mirror)          (Phase 3 mirror)
              writes tickets + reads
              tickets for lifecycle
```

Every box is a function inside the existing `AzLocal.UpdateManagement` module - no new module is created. After the refactor (see [Section 9](#9-pre-requisite-module-refactor)), each box is a `.ps1` under `Private/` or `Public/`.

---

## 4. Public surface (4 new functions)

Three of the four public functions are exported from `AzLocal.UpdateManagement.psd1` in v0.7.4 and follow the module's uniform naming convention (`Verb-AzLocal<Noun>` for both public and private functions, normalised in v0.7.76). `Sync-AzLocalIncident` is **deferred to a future release** - its row remains in the table below as a forward-looking design note.

| Function | Phase | Status (v0.7.4) | Purpose |
|---|---|---|---|
| `New-AzLocalIncident` | 1 | Implemented | Read a JUnit results file (and optional readiness CSV), evaluate against the trigger matrix, open / update tickets in the configured ITSM target. Returns one row per cluster considered with `Action`, `TicketId`, `TicketUrl`, `Severity`, `DedupeKey`. |
| `Sync-AzLocalIncident` | 2 | **Deferred** | Find tickets opened by previous runs (by dedupe key) whose underlying cluster + update has since transitioned to a healthy / succeeded state. Post a comment, optionally transition to Resolved. Idempotent. |
| `Get-AzLocalItsmConfig` | 1 | Implemented | Load and validate the YAML/JSON trigger matrix + adapter wiring config. Returns a strongly typed config object. Lets pipelines validate config in a separate step before secrets are mounted. |
| `Test-AzLocalItsmConnection` | 1 | Implemented | Dry-run probe of the configured ITSM endpoint. Resolves secrets, performs the OAuth token grant, and probes a one-row read against the `incident` table. Custom-field presence and rate-limit headroom checks are planned for a follow-up phase. Surfaces as a step the user can run manually before enabling ticketing. |

### Internal helpers (Private, dot-sourced)

| Function | Phase | Status (v0.7.4) | Purpose |
|---|---|---|---|
| `Resolve-AzLocalItsmSecret` | 1 | Implemented | Resolve a credential reference (`kv://<vault>/<secret>`, `env://<NAME>`, or `literal://` with `-AllowLiteral`) to plaintext using the currently signed-in `Az` context. |
| `Get-AzLocalItsmTriggerDecision` | 1 | Implemented | Apply the trigger matrix to a JUnit row -> decision object (`ShouldTicket`, `Severity`, `Category`, `MirrorTargets`, `Reason`). |
| `Get-AzLocalItsmDedupeKey` | 1 | Implemented | Build the deterministic SHA256 hash used as the idempotency key. Default formula: `{ClusterResourceId}|{UpdateName}|{TriggerCategory}`. |
| `Format-AzLocalIncidentBody` | 1 | Implemented | Render the ticket title + description from a Mustache-style template against the JUnit + readiness + run-error context. |
| `Invoke-AzLocalServiceNowAdapter` | 1 | Implemented (subset) | ServiceNow HTTP - `GetToken`, `TestConnection`, `FindByDedupe`, `CreateIncident`. `AttachFile`, `AddWorkNote`, and `Transition` actions are reserved in the action surface but are deferred along with Phase 2 / attachments. |
| `Invoke-AzLocalTeamsAdapter` | 3 | **Deferred** | Adaptive Card POST to a Teams Incoming Webhook. |
| `Invoke-AzLocalSlackAdapter` | 3 | **Deferred** | Block-Kit `chat.postMessage` to Slack (webhook or bot token). |
| `Invoke-AzLocalItsmHttp` | 1 | Implemented | Shared HTTP layer: TLS 1.2+, `Retry-After` honour, exponential backoff capped at 3 attempts, structured logging. |

Naming convention (uniform since v0.7.76):
- `Verb-AzLocal*` = both public exported functions and private helpers. Public vs private separation is enforced by the manifest's `FunctionsToExport` list, not by name prefix.

---

## 5. Configuration matrix

The matrix lives in a single YAML or JSON file checked in to the user's repo (path passed via pipeline input `itsm_config_path`, default `./.itsm/azurelocal-itsm.yml`). All values are validated by `Get-AzLocalItsmConfig` at the start of the pipeline step so misconfiguration fails fast before any HTTP calls.

### 5.1 Schema (YAML reference; JSON equivalent supported)

```yaml
# .itsm/azurelocal-itsm.yml
schemaVersion: 1

# ----- Authentication -----
secrets:
  source: keyvault                 # 'keyvault' | 'envvar' | 'mixed' (per-secret override)
  keyvaultName: corp-prod-kv-01    # required when source = keyvault or mixed
  # Per-target secret references. Each value may be 'kv://<vault>/<secret>'
  # or 'env://<NAME>'. When 'source: keyvault' the bare name is interpreted
  # as the secret name in the named keyvault.
  servicenow:
    clientId: sn-azlocal-clientid
    clientSecret: sn-azlocal-clientsecret
    instanceUrl: env://ITSM_SN_INSTANCE_URL   # never a secret, kept here for parity
  teams:
    webhookUrl: kv://corp-prod-kv-01/teams-azlocal-webhook
  slack:
    webhookUrl: kv://corp-prod-kv-01/slack-azlocal-webhook

# ----- Default target -----
defaults:
  itsmTarget: ServiceNow           # required: 'ServiceNow' (v0.7.4)
  mirrorTo: [Teams]                # optional list: 'Teams' | 'Slack'
  assignmentGroup: AzureLocal-Ops
  callerId: svc-azlocal-cicd@contoso.com
  category: Compute / Azure Local
  cmdbCi: ${cluster.resourceId}    # token substitution planned for Phase 1.5; Phase 1 passes through verbatim
  templates:
    titleTemplate: "[Azure Local] {{cluster.name}} - {{trigger.category}} ({{run.updateName}})"
    bodyTemplatePath: ./.itsm/templates/incident-body.md
    workNoteTemplatePath: ./.itsm/templates/work-note.md     # used by Sync (Phase 2)

# ----- Trigger matrix (Section 5.2) -----
triggers:
  Failed:
    raiseTicket: true
    severity: 2                    # ServiceNow urgency/impact -> mapped per Section 5.3
    category: "Cluster update failure"
    mirrorTo: [Teams, Slack]
  Error:
    raiseTicket: true
    severity: 2
    category: "Cluster update failure"
  HealthCheckBlocked:
    raiseTicket: true
    severity: 3
    category: "Pre-update health resolution"
  SideloadedBlocked:
    raiseTicket: true
    severity: 4
    category: "Operator action: stage sideloaded payload"
    mirrorTo: []                   # quiet: no Teams/Slack noise for this one
  ExcludedByTag:
    raiseTicket: false             # operator-set UpdateExcluded=True; opt-in if you want a per-run audit ticket
  ScheduleBlocked:
    raiseTicket: false             # DEFAULT: schedule-blocked self-resolves
    # If a user wants to opt-in, just flip raiseTicket to true and set:
    # raiseAfterConsecutiveOccurrences: 3
  Skipped:
    raiseTicket: false
  NotReady:
    raiseTicket: false

# ----- Lifecycle (Phase 2) -----
lifecycle:
  enabled: true
  onSuccessAction: comment         # 'comment' | 'resolve' | 'comment-and-resolve'
  resolveCode: Solved Remotely     # ServiceNow close_code (required if action includes 'resolve')
  resolveNotes: "Auto-resolved by AzLocal.UpdateManagement: run {{run.id}} succeeded."
  # When the ticket reaches this age with no transition, do nothing (avoid touching very old tickets).
  maxAgeDays: 30

# ----- Notification mirror behaviour (Phase 3) -----
mirror:
  teams:
    minSeverity: 3                 # don't mirror noisier sev 4 unless overridden per-trigger
    includeRunLogsLink: true
  slack:
    minSeverity: 3
    channelOverride: "#azurelocal-incidents"
```

### 5.2 How the trigger matrix maps statuses to action

For every cluster row in `update-results.xml`, the connector looks up the row's `Status` in `triggers.<status>`. If `raiseTicket: false` (or the status is missing from the matrix), the row is skipped. Otherwise:

1. **Severity** flows to the ITSM target's priority field (mapping table in Section 5.3).
2. **Category** flows to the ticket subject + ServiceNow `category` field + a label/work-note.
3. **MirrorTo** overrides `defaults.mirrorTo` for this trigger.
4. **raiseAfterConsecutiveOccurrences** (optional) requires the *same dedupe key* to have been seen in the previous N pipeline runs before raising. Backed by one of three pluggable run-history stores - see [Section 5.4](#54-run-history-store-for-raiseafterconsecutiveoccurrences).

### 5.3 Severity -> ServiceNow priority mapping

ServiceNow priority is computed from `impact + urgency`. The connector exposes a single `severity` knob (1-5) and maps it to a sensible impact/urgency pair. Users can override via `triggers.<status>.impact` and `triggers.<status>.urgency` if they need exact ServiceNow priority control.

| `severity` | Impact | Urgency | Resulting SN priority |
|---|---|---|---|
| 1 (Critical) | 1 | 1 | 1 - Critical |
| 2 (High) | 2 | 2 | 2 - High |
| 3 (Moderate) | 3 | 3 | 3 - Moderate |
| 4 (Low) | 4 | 4 | 4 - Low |
| 5 (Planning) | 4 | 4 | 4 - Low (with `state: -5 = New (Pending)`) |

### 5.4 Run-history store for `raiseAfterConsecutiveOccurrences`

When any trigger uses `raiseAfterConsecutiveOccurrences: <N>`, the connector needs to remember dedupe-key occurrences across pipeline runs. The store is pluggable via `storage.kind` in the config; users with no Storage Account and a hard "no extra Azure infra" constraint pick `cicd-cache`. The `localFile` path exists for fully air-gapped / on-prem CI agents - it intentionally does *not* try to commit the file back to the repo, because that approach has too many failure modes (see decisions log below).

```yaml
storage:
  kind: blob              # 'blob' | 'cicd-cache' | 'localFile'

  # ---- when kind = blob (DEFAULT, RECOMMENDED) ----
  blob:
    accountName: corpazlocalstate01
    containerName: azlocal-itsm-state
    # Auth uses the current Az session (same identity that authenticated
    # to apply updates). Pipeline SP needs 'Storage Blob Data Contributor'
    # on the container. No SAS or storage keys.
    blobName: ${pipeline.workflowName}/run-history.json   # token-substituted

  # ---- when kind = cicd-cache (FALLBACK, no Azure infra) ----
  cicdCache:
    # On GitHub Actions: actions/cache@v4 with this key prefix.
    # On Azure DevOps:   Cache@2 task with this key prefix.
    # The pipeline YAML examples include the cache step; the connector
    # just reads/writes ./.itsm/state/run-history.json and the cache
    # action persists it across runs.
    keyPrefix: azlocal-itsm-state
    localPath: ./.itsm/state/run-history.json

  # ---- when kind = localFile (FULLY USER-MANAGED) ----
  localFile:
    path: ./.itsm/state/run-history.json
    # Connector reads and writes this file. How (or whether) it persists
    # across pipeline runs is the user's responsibility - e.g. a
    # self-hosted runner's persistent volume, an SMB mount, etc.
    # This is NOT a 'commit-back-to-repo' mode.
```

**Concurrency**: All three stores use a JSON document with an `etag`-style optimistic-concurrency field. The `blob` store uses native Azure Blob ETag + `If-Match`. The `cicd-cache` and `localFile` stores fall back to a `lastWriteUtc` field with a last-writer-wins note in the docs - acceptable because `raiseAfterConsecutiveOccurrences` is a soft heuristic, not a correctness gate.

**Format**: JSON document, ~1 KB per cluster + trigger, capped at `storage.retention.maxEntries` (default 10,000) with LRU eviction. Each entry: `{ dedupeKey, occurrences, lastSeenUtc, lastSeenRunId }`.

**Why not commit-back-to-repo?** Documented in Section 15 / Q1. Three concrete issues: (1) pipeline needs `contents: write` just for state, much broader than the ticketing feature itself; (2) concurrent pipelines race on the same file and one silently loses; (3) doesn't work for forked-PR triggered runs at all. Users who need an in-repo audit trail can run a separate scheduled workflow that exports the blob store to a CSV in the repo - the connector does not own that loop.

---

## 6. Authentication: Key Vault with native-secret fallback

`Resolve-AzLocalItsmSecret` accepts these reference forms:

| Reference | Resolution |
|---|---|
| `kv://<vault>/<secret>` | `Get-AzKeyVaultSecret -VaultName <vault> -Name <secret> -AsPlainText`. Uses the *current* `Az` session - this is the same identity that authenticated to apply updates, so no extra principal management. |
| `env://<NAME>` | Reads `$env:NAME`. Used for native GH / ADO secret fallback. |
| `<bare name>` | Resolved against `secrets.keyvaultName` when `secrets.source: keyvault`. Allows ergonomic config files. |
| (literal) | Treated as a literal value **only** when `secrets.source: mixed` AND the value is wrapped in `literal://`. Anything else throws. Prevents accidental secret-in-config. |

### Required Azure RBAC

The pipeline service principal already has cluster-update-management RBAC; for Key Vault it additionally needs **Key Vault Secrets User** on the `secrets.keyvaultName` scope. Documented as a one-line `az role assignment create` in the pipeline-examples README.

### Why we did not pick OIDC -> ServiceNow direct federation

ServiceNow does support inbound OAuth 2.0 JWT bearer flow which would let us avoid client_secret entirely. Adding it would require each customer's ServiceNow admin to register a JWT verifier per Azure tenant, which is non-trivial for first-time setup. v0.7.4 ships **OAuth 2.0 client credentials with the secret retrieved from Key Vault** as the recommended path; the adapter is structured so a JWT bearer path can be added in a future release without touching the pipeline YAML.

---

## 7. ServiceNow specifics (Phase 1)

| Concern | Detail |
|---|---|
| API | Table API: `POST /api/now/table/incident`, `GET /api/now/table/incident?sysparm_query=...`, `PATCH /api/now/table/incident/{sys_id}`, `POST /api/now/attachment/file`. |
| Auth | OAuth 2.0 client credentials. Token cached for `expires_in - 60s`. Refresh on HTTP 401 once before failing. |
| Required custom fields on `incident` table | `u_azlocal_dedupe_key` (string, 64 chars, indexed), `u_azlocal_cluster_resource_id` (string), `u_azlocal_update_name` (string), `u_azlocal_run_id` (string), `u_azlocal_source` (string, defaults to `AzLocal.UpdateManagement`). All five are created via a single ServiceNow Update Set provided as `Docs/ServiceNow-AzureLocal-Setup-UpdateSet.xml` (out-of-band; documented in pipeline-examples README). |
| Attachments | The JUnit row for the failing cluster + the readiness CSV slice (if available) + the last 200 lines of the run's `Get-AzLocalUpdateRuns` error summary. Attached via `/api/now/attachment/file?table_name=incident&table_sys_id={sys_id}`. |
| State transitions | Phase 2 closes via `PATCH` to `state=6 (Resolved)`, `close_code`, `close_notes`. Never closes tickets that have been **manually transitioned out of state 1/2/3** - protects in-flight investigations. |
| Rate limits | ServiceNow REST is throttled per-instance; default is 100 req/min. Adapter caps concurrency to 4 (configurable) and honours `Retry-After`. |

---

## 8. Lifecycle / Phase 2 detail **(Deferred - not shipped in v0.7.4)**

> The behaviour described below is design intent for `Sync-AzLocalIncident`. The function is not implemented in v0.7.4 - pipeline YAML examples that reference it are commented out / gated until the function ships in a later release.

`Sync-AzLocalIncident` runs in two places:

1. **Inside `Step.6_apply-updates.yml`** after the apply step, when this run succeeded a cluster that had a previous open ticket - close-out happens immediately.
2. **Inside `Step.7_fleet-update-status.yml`** as a periodic sweep - catches manual recovery, sideloaded successes, schedule-blocked clusters that subsequently updated, etc.

### Detection algorithm

For each cluster in the run output with `Status in (Started, UpdateStarted, Success, NoUpdatesAvailable)`:

1. Compute the dedupe keys for **every** trigger category (`Failed`, `Error`, `HealthCheckBlocked`, `SideloadedBlocked`, `ExcludedByTag` if opted-in, `ScheduleBlocked` if opted-in).
2. Query the ITSM target for open tickets carrying any of those dedupe keys, filtered to `state IN (1, 2, 3)` (New / In Progress / On Hold) and `u_azlocal_source = AzLocal.UpdateManagement`.
3. For each match:
   - Always add a **work-note comment** with: timestamp, run id, current cluster status, link to GH/ADO run.
   - If `lifecycle.onSuccessAction` includes `resolve`, transition `state -> 6 (Resolved)` with the configured `close_code` / `close_notes`.
   - Never touch tickets older than `lifecycle.maxAgeDays`.
   - Never touch tickets whose `assigned_to` is set AND whose `assignment_group` has been changed from the default (heuristic: "human has taken ownership").

The transitioned-state detection is **idempotent**: re-running the same workflow re-finds the same already-resolved ticket and skips with `Action = NoChange`.

---

## 9. Pre-requisite module refactor **(Historical - completed prior to v0.7.4)**

> This section is preserved for context. The Public/Private dot-sourced refactor described here was completed before the v0.7.4 ITSM work began and is therefore not a v0.7.4 deliverable.

Before any ITSM code lands, `AzLocal.UpdateManagement.psm1` (11,679 lines, 60 functions) is split into `Public/` + `Private/` dot-sourced files, matching the layout of `AzLocal.DeploymentAutomation` in this repo.

### Target layout

```
AzLocal.UpdateManagement/
  AzLocal.UpdateManagement.psd1        # bumped to 0.7.4; NestedModules lists every .ps1
  AzLocal.UpdateManagement.psm1        # shrinks to ~100 lines: header, strict-mode,
                                       # script-scoped state, NestedModules dot-source fallback
  Public/                              # 22 files - one exported function each
    Connect-AzLocalServicePrincipal.ps1
    Start-AzLocalClusterUpdate.ps1
    Get-AzLocalClusterUpdateReadiness.ps1
    Get-AzLocalClusterInventory.ps1
    Get-AzLocalClusterInfo.ps1
    Get-AzLocalUpdateSummary.ps1
    Get-AzLocalAvailableUpdates.ps1
    Get-AzLocalUpdateRuns.ps1
    Set-AzLocalClusterUpdateRingTag.ps1
    Invoke-AzLocalFleetOperation.ps1
    Get-AzLocalFleetProgress.ps1
    Test-AzLocalFleetHealthGate.ps1
    Export-AzLocalFleetState.ps1
    Resume-AzLocalFleetUpdate.ps1
    Stop-AzLocalFleetUpdate.ps1
    Test-AzLocalClusterHealth.ps1
    Get-AzLocalFleetStatusData.ps1
    New-AzLocalFleetStatusHtmlReport.ps1
    Test-AzLocalUpdateScheduleAllowed.ps1
    Reset-AzLocalSideloadedTag.ps1
    # v0.7.4 additions:
    New-AzLocalIncident.ps1
    Sync-AzLocalIncident.ps1
    Get-AzLocalItsmConfig.ps1
    Test-AzLocalItsmConnection.ps1
  Private/                             # 38 existing private helpers + 8 new ITSM helpers
    Test-AzCliAvailable.ps1
    Test-ExportPathWritable.ps1
    Install-AzGraphExtension.ps1
    Write-Log.ps1
    Invoke-AzRestJson.ps1
    Invoke-AzResourceGraphQuery.ps1
    Invoke-FleetJobsInParallel.ps1
    Invoke-FleetOpClusterAction.ps1
    Resolve-SafeOutputPath.ps1
    Get-TagValue.ps1
    ConvertTo-ScrubbedCliOutput.ps1
    ConvertTo-SafeCsvField.ps1
    Write-Utf8NoBomFile.ps1
    ConvertTo-SafeCsvCollection.ps1
    ConvertTo-AzLocalAdditionalProperties.ps1
    Get-HealthCheckFailureSummary.ps1
    Get-LastUpdateRunErrorSummary.ps1
    Get-LatestUpdateByYYMM.ps1
    Get-CurrentStepPath.ps1
    Export-ResultsToJUnitXml.ps1
    Get-ExportFormat.ps1
    Write-UpdateCsvLog.ps1
    Format-AzLocalDurationHuman.ps1
    Get-AzLocalRunEndTime.ps1
    Format-AzLocalUpdateRun.ps1
    Get-AzLocalClusterUpdateRuns.ps1
    ConvertFrom-AzLocalUpdateWindow.ps1
    ConvertFrom-AzLocalUpdateExclusion.ps1
    Resolve-WildcardDateRange.ps1
    Resolve-WildcardDate.ps1
    Test-AzLocalUpdateWindow.ps1
    Test-AzLocalUpdateExclusion.ps1
    ConvertFrom-AzLocalUpdateSideloaded.ps1
    Test-AzLocalUpdateSideloadedAllowed.ps1
    Test-AzLocalUpdateVersionInProgressMatch.ps1
    Set-AzLocalClusterTagsMerge.ps1
    Invoke-AzLocalSideloadedAutoResetForCluster.ps1
    Invoke-AzLocalSideloadedAutoReset.ps1
    Import-AzLocalFleetState.ps1     # currently private-but-exported; moves to Private
    Invoke-AzLocalUpdateApply.ps1    # currently private; stays private
    # v0.7.4 ITSM additions:
    Resolve-AzLocalItsmSecret.ps1
    Get-AzLocalItsmTriggerDecision.ps1
    Get-AzLocalItsmDedupeKey.ps1
    Format-AzLocalIncidentBody.ps1
    Invoke-AzLocalServiceNowAdapter.ps1
    Invoke-AzLocalTeamsAdapter.ps1
    Invoke-AzLocalSlackAdapter.ps1
    Invoke-AzLocalItsmHttp.ps1
  Tests/
  ITSM/
    README.md                          # Phase 1 deliverable: setup + configure landing page (auto-renders on GitHub)
    ITSM-Connector-Plan.md             (this file)
    ITSM-Config-Reference.md           # Phase 1 deliverable: full schema reference
    ServiceNow-AzureLocal-Setup-UpdateSet.xml   # Phase 1 deliverable
  Automation-Pipeline-Examples/
    .itsm/                             # Phase 1 deliverable: example config + templates
      azurelocal-itsm.yml
      templates/
        incident-body.md
        work-note.md
    github-actions/
      Step.6_apply-updates.yml                # gets new optional ITSM step
      Step.7_fleet-update-status.yml          # gets new optional ITSM + Sync step
    azure-devops/
      Step.6_apply-updates.yml                # mirrors GH
      Step.7_fleet-update-status.yml          # mirrors GH
```

### Refactor mechanics

1. Each function comes out of the monolith with a banner comment block (`.SYNOPSIS`, `.DESCRIPTION`, `.NOTES`) and an explicit `[CmdletBinding()]` / `[OutputType(...)]` where missing.
2. Module-scope variables (`$script:ModuleRoot`, log-suppression flag, token cache) stay in the `.psm1`.
3. `.psm1` shrinks to a thin shell that:
   - Sets `Set-StrictMode -Version Latest`
   - Declares `$script:*` state
   - Dot-sources every `.ps1` listed in the manifest's `NestedModules` (fallback for direct `Import-Module .\AzLocal.UpdateManagement.psm1`)
4. `.psd1` `NestedModules` lists every `Private/*.ps1` and `Public/*.ps1` explicitly. `FunctionsToExport` lists only the public set.
5. ASCII-only enforcement carries forward; the existing module banner is preserved.
6. Pester suite runs end-to-end after the split with **zero functional changes** required - file refactor only.

### Refactor risk controls

- Split is mechanical: extract one function, delete its body from the .psm1, dot-source it, run a targeted test. Repeat. Each function lands in its own commit so any regression is bisectable.
- Heavy use of cross-function calls is fine because dot-sourced files share the module's session state - no `Export-ModuleMember` per file.
- One concrete failure mode to watch: functions that reference *script-scope* variables defined elsewhere in the monolith. Any such reference goes into `.psm1` as `$script:Foo = $null` *before* dot-sourcing, then is set inside the appropriate function.

---

## 10. Pipeline changes

### 10.1 `Step.6_apply-updates.yml` (GH Actions + ADO mirror)

New `workflow_dispatch` inputs:

```yaml
raise_itsm_ticket:
  description: 'Open ITSM tickets for clusters needing manual action'
  type: boolean
  default: false
itsm_config_path:
  description: 'Path to ITSM matrix config (YAML or JSON)'
  type: string
  default: './.itsm/azurelocal-itsm.yml'
itsm_dry_run:
  description: 'Build payloads but do not POST'
  type: boolean
  default: false
itsm_force_create:
  description: 'Bypass dedupe (use with caution)'
  type: boolean
  default: false
```

New step **after** `Publish Test Results` and **before** `Summary`:

```yaml
- name: Raise ITSM tickets
  if: ${{ inputs.raise_itsm_ticket == true }}
  shell: pwsh
  run: |
    Import-Module "${{ env.MODULE_PATH }}/AzLocal.UpdateManagement.psd1" -Force
    $cfg = Get-AzLocalItsmConfig -Path "${{ inputs.itsm_config_path }}"
    $results = New-AzLocalIncident `
        -InputArtifactPath ./artifacts/update-results.xml `
        -Config $cfg `
        -RunMetadata @{
            Platform = 'github'
            RunId    = $env:GITHUB_RUN_ID
            RunUrl   = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
            Branch   = $env:GITHUB_REF
        } `
        -DryRun:([bool]::Parse('${{ inputs.itsm_dry_run }}')) `
        -ForceCreate:([bool]::Parse('${{ inputs.itsm_force_create }}')) `
        -ExportPath ./artifacts/itsm-results.csv `
        -ExportJUnitPath ./artifacts/itsm-results.xml
    $results | Format-Table ClusterName, Action, TicketId, Severity -AutoSize

- name: Sync ITSM tickets (close-out on success) - DEFERRED (Phase 2, not in v0.7.4)
  # `Sync-AzLocalIncident` is not implemented in v0.7.4 - this step is
  # documented for forward compatibility only. Do not enable it until the
  # function ships in a later release.
  if: ${{ false }}
  shell: pwsh
  run: |
    Sync-AzLocalIncident `
        -InputArtifactPath ./artifacts/update-results.xml `
        -Config (Get-AzLocalItsmConfig -Path "${{ inputs.itsm_config_path }}") `
        -RunMetadata @{ Platform='github'; RunId=$env:GITHUB_RUN_ID; RunUrl="..." } `
        -ExportPath ./artifacts/itsm-sync-results.csv `
        -ExportJUnitPath ./artifacts/itsm-sync-results.xml

- name: Upload ITSM artefacts
  if: ${{ inputs.raise_itsm_ticket == true }}
  uses: actions/upload-artifact@v4
  with: { name: itsm-results, path: ./artifacts/itsm-*.* }

- name: Publish ITSM test results
  if: ${{ inputs.raise_itsm_ticket == true }}
  uses: dorny/test-reporter@v1
  with:
    name: ITSM Tickets
    path: ./artifacts/itsm-*.xml
    reporter: java-junit
  continue-on-error: true
```

### 10.2 `Step.7_fleet-update-status.yml` **(Deferred along with Phase 2)**

Adds the same `Sync-AzLocalIncident` step (no `New-AzLocalIncident` - that is only for the apply pipeline). Lets a hourly / daily fleet read sweep close out tickets when a cluster recovered between apply runs. Not shipped in v0.7.4.

### 10.3 Azure DevOps parity

Both ADO `Step.6_apply-updates.yml` and (when Phase 2 lands) `Step.7_fleet-update-status.yml` get exactly the same step structure using `task.logissue` and `PublishTestResults@2` (already in use elsewhere in those YAMLs). Inputs are declared as pipeline parameters with the same names and defaults. v0.7.4 ships only the `Step.6_apply-updates.yml` ITSM step on both GitHub Actions and Azure DevOps; the Sync step is deferred.

---

## 11. Security

- All ITSM credentials referenced through Key Vault (recommended) or native GH / ADO secrets (fallback). No raw secret in YAML or config file ever.
- Pipeline SP needs **Key Vault Secrets User** on the configured vault; no other new RBAC.
- HTTP layer: TLS 1.2+, default 30s timeout, `Retry-After` honoured, exponential backoff. Server cert pinning is *not* enabled in Phase 1; an `Invoke-AzLocalItsmHttp -AllowedThumbprints` surface is planned for a later phase for high-assurance tenants.
- All free-text fields (cluster names, tag values, error summaries) are CSV-injection-sanitised on the way in (already true in v0.7.0+) and **HTML-escaped** when rendered into ticket descriptions to defend against ITSM-side HTML injection.
- Token cache lives only in memory of the runner; never written to disk or logs. `Write-Log` redacts anything matching `bearer\s+[\w.-]+` / `client_secret=...`.
- Teams / Slack webhook URLs are themselves secrets - same KV / env handling.

---

## 12. Testing

Pester additions land in `Tests/AzLocal.UpdateManagement.Tests.ps1` and split into clear `Describe` blocks per new function. Targets below are the full three-phase plan; Phase 2 / Phase 3 rows are deferred along with their functions.

| Area | Phase | Test count target | Status (v0.7.4) |
|---|---|---|---|
| `Resolve-AzLocalItsmSecret` (KV path, env path, mixed, error paths) | 1 | 8 | Shipped |
| `Get-AzLocalItsmConfig` (schema validation, missing fields, defaults, YAML normalisation) | 1 | 12 | Shipped |
| `Get-AzLocalItsmTriggerDecision` (every status, mirror override, raiseAfterN) | 1 | 15 | Shipped |
| `Get-AzLocalItsmDedupeKey` (stability across versions, collision class) | 1 | 4 | Shipped |
| `Format-AzLocalIncidentBody` (template tokens, missing context, escaping) | 1 | 8 | Shipped |
| `Invoke-AzLocalServiceNowAdapter` (POST, dedupe GET, 401-refresh, 429-backoff) | 1 | ~10 | Shipped (attachment / transition tests deferred with their actions) |
| `Invoke-AzLocalTeamsAdapter` (card render, severity filter) | 3 | 6 | **Deferred** |
| `Invoke-AzLocalSlackAdapter` (block render, channel override) | 3 | 6 | **Deferred** |
| `New-AzLocalIncident` end-to-end (mocked adapter; JUnit -> tickets, DryRun dedupe, JUnit export, CSV sanitization) | 1 | 10+ | Shipped |
| `Sync-AzLocalIncident` (no-change, comment-only, comment+resolve, age guard, ownership guard) | 2 | 10 | **Deferred** |
| `Test-AzLocalItsmConnection` (success, bad auth, missing custom fields) | 1 | 6 | Shipped |

Phase 1 total shipped in v0.7.4: ~75 new ITSM tests integrated into the suite's existing 337-test baseline. All HTTP via `Mock Invoke-RestMethod` / `Mock Invoke-WebRequest`. No live ServiceNow contact in CI; a manual contract test against a ServiceNow Personal Developer Instance is documented for maintainers but not in the default pipeline.

Tests use the existing safe-detached Pester pattern (`-Output None -PassThru` + summary file) - this is non-negotiable and documented in the user's memory file.

---

## 13. Documentation deliverables

All produced as part of v0.7.4 (Phase 1 scope only - Phase 2/3 docs deferred):

| File | Purpose |
|---|---|
| `ITSM/README.md` | Landing page - setup, prerequisites, secret-source guidance, quick-start, troubleshooting. Auto-rendered on GitHub when browsing the `ITSM/` folder. |
| `ITSM/ITSM-Connector-Plan.md` | This document - design + decisions log. |
| `ITSM/ITSM-Config-Reference.md` | Full schema reference for the matrix config, every field documented with type / default / examples. |
| `ITSM/ServiceNow-AzureLocal-Setup-UpdateSet.xml` | Update Set installing the five `u_azlocal_*` custom fields + the OAuth app role + a sample assignment group. |
| `Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml` | Working example config. |
| `Automation-Pipeline-Examples/.itsm/templates/incident-body.md` | Mustache-style template used by `Format-AzLocalIncidentBody`. |
| `Automation-Pipeline-Examples/.itsm/templates/work-note.md` | Template used by `Sync-AzLocalIncident` for close-out comments. |
| `README.md` (module root) | New "## ITSM Connector (v0.7.4)" section + cross-link to `ITSM/` folder. |
| `Automation-Pipeline-Examples/README.md` | New "## ITSM Ticketing" section walking through KV setup, native-secret fallback, dry-run, mirror-channel setup. |
| `CHANGELOG.md` | v0.7.4 entry covering Phase 1 ITSM connector (refactor was completed earlier). |

---

## 14. Delivery sequence

| Step | Scope | Status |
|---|---|---|
| 1 | **Refactor** the monolithic `.psm1` into `Public/` + `Private/` dot-sourced files; bump psd1/psm1 banner. Run Pester to green. Each function lands in its own commit so any regression is bisectable. | **Completed** (pre-v0.7.4) |
| 2 | **Phase 1 implementation** - Section 4 public + Section 4 private (excluding Teams/Slack and `Sync-AzLocalIncident`). Tests, dry-run validated against ServiceNow Personal Developer Instance. Pipeline YAML updates. Docs. | **Shipped in v0.7.4** |
| 3 | **Phase 2 implementation** - `Sync-AzLocalIncident` + lifecycle wiring + `Sync` job in both pipelines + lifecycle docs. Tests. | **Deferred** (post-v0.7.4) |
| 4 | **Phase 3 implementation** - `Invoke-AzLocalTeamsAdapter`, `Invoke-AzLocalSlackAdapter`, mirror config plumbing. Tests. | **Deferred** (post-v0.7.4) |
| 5 | **Cross-cutting** - README updates, CHANGELOG, version bump, run full Pester suite, commit, raise PR. | **Shipped for Phase 1 in v0.7.4**; will recur for each deferred phase. |

Each phase is one or more commits on the same branch off `main`; the PR is opened at the start of each phase and incrementally reviewed.

---

## 15. Open questions tracked for review

These are items I want to confirm before / during implementation. None block starting the refactor.

| # | Question | Decision |
|---|---|---|
| Q1 | Run-history state for `raiseAfterConsecutiveOccurrences`. | **Resolved.** Three-tier pluggable store (Section 5.4): Azure Blob (default, recommended) -> CI cache (no-Azure-infra fallback) -> localFile (user-managed). Repo-commit-back explicitly rejected: requires `contents: write`, races on concurrent runs, fails on forked-PR triggers. |
| Q2 | Should `Sync-AzLocalIncident` also reach into `Step.7_fleet-update-status.yml` results when triggered from `Step.6_apply-updates.yml` (cross-pipeline visibility) or stay scoped to the run that called it? | Stay scoped. Cross-pipeline visibility added in v0.7.4 if requested. |
| Q3 | When `lifecycle.onSuccessAction = resolve` and the ticket has an `assigned_to` set, should we still resolve? | No. Treat assigned ticket as "human owns it" and only post a work-note. (Encoded in plan above.) |
| Q4 | Teams Adaptive Card schema version? | 1.4 (broad Teams compatibility, supports Action.OpenUrl). |
| Q5 | Slack: webhook URL only, or also support `chat.postMessage` with bot token (richer formatting, threading)? | Webhook first (simpler), bot token later. Phase 3 itself is deferred beyond v0.7.4. |
