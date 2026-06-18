# Changelog

All notable changes to the AzLocal.UpdateManagement module (renamed from AzStackHci.ManageUpdates in v0.7.3) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.93] - 2026-06-18

Fixes a Bad Request in the **Update: 1 - Assess Update Readiness** pipeline: the
`checkUpdates` ARM action POST was missing its required request body. Bug-fix only -
no API, parameter, or export-count change (still 61).

### Fixed

- **`Sync-AzLocalClusterUpdateSummary` now sends an empty JSON body on the `checkUpdates` POST.**
  The cmdlet (and the `Export-AzLocalClusterUpdateReadinessReport` stale-assessment auto-scan
  that calls it) POSTed `Microsoft.AzureStackHCI/clusters/updateSummaries/default/checkUpdates`
  with no request body. The `2026-03-01-preview` API spec now requires a body to be present, so
  the bodyless POST was rejected with
  `HttpRequestPayloadAPISpecValidationFailed` / `MissingRequiredParameter "Value is required but
  was not provided. Paths in payload: '.body'"`. The POST now sends an empty JSON object `{}`
  (no properties are mandatory for a plain re-scan), validated end-to-end against a live cluster.

### Changed

- **Refreshed the now-stale RBAC comment / authorization warning** in
  `Sync-AzLocalClusterUpdateSummary` to reflect that the v0.8.92 `updateSummaries/*` wildcard
  already authorizes `checkUpdates`; a 403 therefore means the
  `Azure Stack HCI Update Operator (custom)` role (or an equivalent built-in) is simply not
  assigned at the scope, not that the action is ungranted.

## [0.8.92] - 2026-06-20

Grants the preview "Check for updates" (`checkUpdates`) action to the least-privilege
`Azure Stack HCI Update Operator (custom)` role via the
`Microsoft.AzureStackHCI/clusters/updateSummaries/*` wildcard. Doc / RBAC-only change -
no behavioural, API, or export-count change (still 61).

### Changed

- **Custom role grants `updateSummaries/*` instead of `updateSummaries/read`.**
  `az role definition create` / `update` rejects the explicit
  `Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action` leaf because it is
  not yet published in the `Microsoft.AzureStackHCI` provider operations catalog (checked
  2026-06-18), but it accepts a wildcard whose prefix (`updateSummaries/`) resolves to the
  registered `updateSummaries/read`. Azure's authorization engine then matches the enforced
  `checkUpdates/action` against the `updateSummaries/*` wildcard at request time. The wildcard
  subsumes `updateSummaries/read` and also covers any future control-plane sub-operation under
  `clusters/updateSummaries/`.
- As a result, `Sync-AzLocalClusterUpdateSummary` and the
  `Export-AzLocalClusterUpdateReadinessReport` stale-assessment auto-scan now succeed under the
  custom role - no fallback to `Azure Stack HCI Administrator` / `Contributor` and no
  `-SkipStaleAssessmentScan` needed.
- Updated the bundled `azlocal-update-management-custom-role.json`, `docs/rbac.md` (x3 role
  blocks), both READMEs, `docs/cmdlet-reference.md`, and the `Connect-AzLocalServicePrincipal`
  comment-based help. The offline and live RBAC tripwire tests now assert the `updateSummaries/*`
  wildcard is present and the explicit `checkUpdates` leaf is not enumerated.

### Notes

- **No public-API change** (export count unchanged at 61).
- **`GENERATED_AGAINST_MODULE_VERSION`** bumped from `0.8.91` to `0.8.92` across bundled pipeline templates.

## [0.8.91] - 2026-06-20

Operator-facing cleanup of stale `Step.N` pipeline references left over from the v0.8.7
filename de-numbering. No behavioural, API, or export-count change (still 61); the
intentional backward-compatibility `Step.N_*.yml` migration aliases in
`Get-AzLocalPipelineManifest` are unchanged.

### Changed

- **Config: 3 schedule-coverage audit no longer points operators at a non-existent file.**
  `Export-AzLocalApplyUpdatesScheduleAudit` / `Test-AzLocalApplyUpdatesScheduleCoverage`
  previously told operators to edit `Step.7_apply-updates.yml` (a filename removed in v0.8.7).
  The "How to fix" headings, throw message, comment-based help, and cron-coverage prose now
  name the shipped `apply-updates.yml` (with `.github/workflows/` and `azure-devops/` paths)
  and reference sibling pipelines by purpose (e.g. "the Manage UpdateRing Tags pipeline")
  instead of dead step numbers. The internal `$step6FileLabel` variable is renamed
  `$applyFileLabel`.
- **Step-summary headers drop their dead step-number prefix.**
  `## Step.0 - Authentication Validation...` -> `## Authentication Validation...`
  (`Export-AzLocalAuthValidationReport`), `## Step.1 - Cluster Inventory` ->
  `## Cluster Inventory` (`Invoke-AzLocalClusterInventory`), and
  `## Step.2 - UpdateRing Tag Management Summary` -> `## UpdateRing Tag Management Summary`
  (`Set-AzLocalClusterUpdateRingTagFromCsv`).
- **`Get-AzLocalFleetConnectivityStatus` progress log drops its `Step.4` prefix** (now `[N/5]`).
- **`GENERATED_AGAINST_MODULE_VERSION`** pin bumped to `'0.8.91'` across the bundled pipeline
  templates.

## [0.8.90] - 2026-06-20

Adds opt-in event-driven in-flight update monitoring so Update: 4 (Monitor In-Flight Updates)
runs right after Update: 3 (Apply Updates) starts an update, yet stays cheap the rest of the
time. Introduces a fleet-wide idle short-circuit on the monitor cmdlet, an event-driven trigger
from apply to monitor on both platforms, a 6-hourly default monitor cron, and Config: 3
recommendation tuning inputs.

### Added

- **`Export-AzLocalUpdateRunMonitorReport -SkipWhenIdle` switch.** Performs one low-cost
  fleet-wide Azure Resource Graph probe (new private helper `Test-AzLocalUpdateRunsInFlight`:
  "any `updateRuns` `InProgress`?") and short-circuits to an IDLE result - writing the empty
  CSV/JUnit artefacts and all-zero step outputs - skipping the per-cluster sweep when nothing
  is in flight. Fail-safe: a probe error runs the full sweep rather than skipping.
- **Event-driven trigger from Update: 3 to Update: 4.** `apply-updates.yml` fires the monitor
  after starting >=1 update - `gh workflow run monitor-updates.yml` on GitHub Actions
  (job gains `actions: write`) / the Pipelines REST queue API on Azure DevOps - tagged
  `triggered_by=apply-updates`. The monitor honours an optional `MONITOR_TRIGGER_DELAY_MINUTES`
  startup delay (unset/0 = off, otherwise clamped 15-240) so it lands AFTER updates move into
  `InProgress`. Cron/manual runs never delay. The monitor allows concurrent runs so a sleeping
  event-driven run never blocks the next.
- **Config: 3 monitor-recommendation tuning inputs.** Both `apply-updates-schedule-audit.yml`
  templates expose `MonitorPollIntervalMinutes` / `MonitorTrailingDays` / `MonitorInFlightHours`
  as workflow inputs/parameters and plumb them into `Export-AzLocalApplyUpdatesScheduleAudit`.

### Changed

- **`monitor-updates.yml` default cron drops from 5x/day to every 6h (`0 */6 * * *`)** and
  passes `-SkipWhenIdle` by default on both platforms.
- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.89'` to
  `'0.8.90'`. Export count unchanged (still 61 - the new helper is private).

## [0.8.89] - 2026-06-18

Sharpens the Config: 3 (`Export-AzLocalApplyUpdatesScheduleAudit`) "Recommended in-flight
monitor schedule (Update: 4)" so the recommended `monitor-updates.yml` cron only polls when
an update can actually be in flight, instead of 24x7. Adds an Automation-Pipeline-Examples
README section documenting how the three scheduling layers control which updates install, and
when.

### Changed

- **`Export-AzLocalApplyUpdatesScheduleAudit` monitor-cron recommendation is now schedule- and window-aware.**
  - Replaced `-MonitorFiresPerHour` (1-12) with `-MonitorPollIntervalMinutes`
    (`ValidateSet` 15/20/30/60/120/180/240, default 30). The new knob expresses a true
    poll interval, including multi-hour cadence for slow multi-node runs (which can take
    up to ~48h); values < 60 min set the cron minute field to `*/N`, values >= 60 min set
    the minute field to `0` and step the hour field every N/60 hours.
  - Added `-MonitorInFlightHours` (`ValidateRange` 0-48, default 6): a buffer past the
    latest `UpdateStartWindow` end so the monitor keeps polling for runs still finishing
    after the maintenance window closes.
  - Monitor **days** now derive from `apply-updates-schedule.yml` ring eligibility (the
    cycle calendar) when `-SchedulePath` is supplied, otherwise from the `apply-updates.yml`
    cron weekday(s). The base set is still expanded by `-MonitorTrailingDays`.
  - Monitor **hours** are now bounded to the `UpdateStartWindow` span (earliest start ->
    latest end) plus `-MonitorInFlightHours`, falling back to all-hours (`*`) when a run can
    cross midnight (an overnight window, `-MonitorTrailingDays > 0`, or the buffer pushing
    coverage past 24h) so no in-flight time is left unpolled.
- **`checkUpdates` RBAC action: catalog-checked, documented, and guarded (still omitted from the role).**
  A provider-operations-catalog check (`az provider operation show --namespace Microsoft.AzureStackHCI`,
  2026-06-18) confirms the "Check for updates" refresh action
  `Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action` (confirmed verbatim from a live
  `403 AuthorizationFailed` body) is **enforced by Azure but not yet published in the operations catalog** -
  so `az role definition create` / `update` would reject it. The least-privilege custom role therefore
  continues to **deliberately omit** it (the four registered update actions - `updateSummaries/read`,
  `updates/read`, `updates/apply/action`, `updates/updateRuns/read` - are the complete set the catalog
  exposes under those paths and are all already granted). Documented the cmdlet -> pipeline -> action
  mapping in the `docs/rbac.md` and Automation README permission tables: the action is exercised by
  `Sync-AzLocalClusterUpdateSummary` and by the stale-assessment auto-scan in
  `Export-AzLocalClusterUpdateReadinessReport` (the **Update: 1 - Assess Update Readiness** pipeline,
  `assess-update-readiness.yml`); the built-in **Azure Stack HCI Administrator** / **Contributor** roles
  authorize it via their `Microsoft.AzureStackHCI/clusters/*` wildcard, or use `-SkipStaleAssessmentScan`.
  The docs now state the action **will be added to the custom role once it GAs into the catalog**, and a new
  Pester tripwire (`v0.8.89 RBAC checkUpdates action`) asserts the four registered actions are present and
  that `checkUpdates` is absent - it fails the moment the action is added, forcing the role JSON and docs to
  be updated together.

### Added

- **Automation-Pipeline-Examples README section 1.2 "How to control which updates are installed, and when".**
  Documents the three-layer model (`apply-updates-schedule.yml` picks the days, the
  `apply-updates.yml` cron picks the wake cadence, `UpdateStartWindow` picks the time-of-day)
  and the end-to-end workflow: tag clusters (Config: 2) -> generate the schedule (6.5) -> run
  Config: 3, which outputs ready-to-paste apply and monitor crons -> paste into Update: 3 and
  Update: 4.

All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.88'` to
`'0.8.89'`. Export count unchanged (still 61).

## [0.8.88] - 2026-06-17

Adds programmatic "Check for updates" (checkUpdates) automation and stale-update-assessment
detection so a cluster that reports "Up to date" while a newer solution build is actually
available (a stale cached assessment) is detected and refreshed without leaving the pipeline.

### Added

- `Sync-AzLocalClusterUpdateSummary` - new Public cmdlet (export count 60 -> 61). POSTs the
  `Microsoft.AzureStackHCI/clusters/updateSummaries/default/checkUpdates` ARM action (the
  programmatic equivalent of the Azure portal "Check for updates" button) on the
  `2026-03-01-preview` API to force one or more clusters to re-evaluate update availability.
  Clusters are selected by name (`-ClusterNames` + `-ResourceGroupName` + `-SubscriptionId`),
  by Resource ID (`-ClusterResourceIds`), or by `UpdateRing` tag
  (`-ScopeByUpdateRingTag` + `-UpdateRingValue`), mirroring `Start-AzLocalClusterUpdate`.
  Fire-and-forget by default (an offline / busy cluster cannot stall a fleet run); `-Wait`
  polls the cluster's `updateSummaries/default` until `properties.lastChecked` advances past
  the pre-trigger baseline (or `-TimeoutSeconds` elapses, 30-3600 default 300; poll cadence
  `-PollIntervalSeconds` 5-300 default 15) and stores the refreshed `UpdateState` /
  `CurrentVersion` / `LastChecked` / `AvailableUpdateCount` / raw `UpdateSummary` on the
  returned object. Supports `SupportsShouldProcess` (`-WhatIf` / `-Confirm`), `-Force`, and
  `-PassThru`.
- Opt-out stale-assessment auto-scan in `Export-AzLocalClusterUpdateReadinessReport`. After
  the readiness cascade, any cluster reporting `UpToDate` whose installed version is behind
  the latest released `YYMM` (detected by the new private `Test-AzLocalUpdateAssessmentStale`
  helper plus `Get-AzLocalLatestSolutionVersion`) triggers a fire-and-forget Check for updates
  to refresh it. New `-SkipStaleAssessmentScan` switch (opt out; default scan ON) and
  `-StaleAssessmentApiVersion` parameter (default `2026-03-01-preview`); new
  "### Stale update assessments" markdown section; new `StaleAssessmentCount` /
  `StaleAssessmentClusters` / `StaleAssessmentScanTriggered` `-PassThru` fields (added to both
  the main and idle-path PassThru shapes).
- `Test-AzLocalUpdateAssessmentStale` - new private pure helper (`-CurrentVersion`,
  `-LatestYYMM` -> `{ IsStale; ClusterYYMM; LatestYYMM; Reason }`). `IsStale` is `$true` only
  when the cluster's installed `YYMM` is strictly less than the latest released `YYMM`.

### Changed

- Authorization / 403 failures on the refresh call are now surfaced in the console log.
  `Sync-AzLocalClusterUpdateSummary` always echoes the full `az rest` error text (which, for
  an RBAC denial, contains the exact `Action` name and scope) via `Write-Log -Level Error`,
  and when it detects `AuthorizationFailed` / `Forbidden` / `403` it emits an explicit
  `Write-Log -Level Warning` instructing the operator to capture the action name and assign
  `Azure Stack HCI Administrator` / `Contributor` (or pass `-SkipStaleAssessmentScan`). The
  message is visible even on the fire-and-forget readiness auto-scan path (the `| Out-Null`
  there suppresses only pipeline objects, not host output), and the failure is non-fatal -
  the readiness report still completes.
- Operator-facing pipeline cross-references de-numbered. Stale `Step.N_*.yml` references in
  rendered report text (`Export-AzLocalClusterUpdateReadinessReport`,
  `Export-AzLocalApplyUpdatesScheduleAudit`, `Export-AzLocalUpdateRunMonitorReport`) and in
  pipeline-example doc strings (`Copy-AzLocalPipelineExample`,
  `New-AzLocalApplyUpdatesScheduleConfig`) now use the descriptive filenames
  (`apply-updates.yml`, `monitor-updates.yml`, `sideload-updates.yml`,
  `setup-validate-and-inventory.yml`, etc.) that have shipped since v0.8.7. A non-existent
  `Step.0_authentication-test.yml` pointer in the Azure DevOps `Copy-AzLocalPipelineExample`
  guidance is corrected to `setup-validate-and-inventory.yml`.

### Docs

- Documented the future custom-RBAC requirement for `checkUpdates` in the module
  `README.md` (RBAC Requirements), `docs/rbac.md`, and
  `Automation-Pipeline-Examples/README.md`: the preview `checkUpdates` action is not yet in
  the `Microsoft.AzureStackHCI` provider operations catalog and so cannot be added to a
  custom role today (`az role definition update` rejects unregistered actions). Until it GAs,
  use `Azure Stack HCI Administrator` / `Contributor` or accept the non-fatal 403-and-warn
  behaviour; when it GAs, add the GA'd action (expected
  `Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action` - confirm from a 403
  body or the provider operations catalog) to the bundled
  `azlocal-update-management-custom-role.json` and the permission tables.

### Notes

- `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.87` to `0.8.88` across all bundled
  pipeline templates (GitHub Actions + Azure DevOps).

## [0.8.87] - 2026-06-16

Renames the bundled pipeline display names into a three-group `Config: N` /
`Monitor: N` / `Update: N` scheme (single-digit, e.g.
`Monitor: 1 - Fleet Connectivity Status`, `Update: 4 - Monitor In-Flight
Updates`), replacing the former `Setup: 0N` / `Fleet: 0N` prefixes so the
GitHub Actions and Azure DevOps lists group onboarding, day-2 monitoring, and
update-lifecycle workflows logically. Display name (`name:` / `displayName:`)
only - filenames and `AZLOCAL-PIPELINE-ID` values are unchanged.

Also renames the "Orphan ARBs" section in the
`New-AzLocalFleetConnectivityStatusSummary` (Monitor: 1 - Fleet Connectivity
Status) markdown output to "Non-Azure Local and/or Orphan ARB appliances" and
adds an explicit caveat that an Arc resource bridge with no matching in-scope
Azure Local cluster is NOT necessarily orphaned. Azure Arc resource bridge is
also used by VMware vSphere and System Center Virtual Machine Manager (SCVMM)
Arc-enabled deployments, so a listed appliance may be a healthy, in-use bridge
for a non-Azure Local platform. Output text only - no public API change. Export
count unchanged (still 60).

Also extends the in-flight monitor (Update: 4) and ITSM connector so stuck /
failed / attempt-without-run clusters surfaced by
`Export-AzLocalUpdateRunMonitorReport` can auto-raise deduped ServiceNow
incidents, and teaches the Config: 3 schedule auditor
(`Export-AzLocalApplyUpdatesScheduleAudit`) to recommend an Update: 4 monitor
poll cadence. New parameters are additive with backward-compatible defaults;
export count unchanged (still 60).

### Added

- `Export-AzLocalUpdateRunMonitorReport` now writes per-`<testcase>`
  `<properties>` into `update-monitor.xml` (`ClusterName`, `ClusterResourceId`,
  `UpdateName`, `Status`, `CurrentStep`, `ClusterPortalUrl`,
  `UpdateRunPortalUrl`). The `Status` values are `StepError`, `LongRunningStep`,
  `LongRunningOverall`, `InProgress`, `Failed`, and `AttemptWithoutRun` (the
  UpdateLastAttempt-reconciliation rows, which use a `(no update name)`
  `UpdateName` fallback so the ITSM dedupe key stays stable per cluster). This
  is what lets `New-AzLocalIncident` dedupe and deep-link from the monitor
  pipeline (previously every monitor row was skipped for missing
  ClusterResourceId / UpdateName).
- `Export-AzLocalApplyUpdatesScheduleAudit` (Config: 3) gains a new always-on
  "Recommended in-flight monitor schedule (Update: 4)" section that derives a
  `monitor-updates.yml` poll cron from the apply-window weekday(s), covering the
  apply day plus a configurable trailing window for multi-day runs. Two new
  parameters: `-MonitorFiresPerHour` (1-12, default 2 = every 30 min) and
  `-MonitorTrailingDays` (0-14, default 3, mirroring the Update: 4 CRITICAL
  elapsed tier).
- The bundled `monitor-updates.yml` (GitHub Actions and Azure DevOps) gains an
  opt-in ITSM ticketing step (`raise_itsm_ticket` / `raiseItsmTicket`,
  default off) that runs `New-AzLocalIncident` against the monitor JUnit after
  it is published. Strictly additive - the monitor remains report-only and
  always green.
- The sample ITSM trigger matrix
  (`Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml`) gains entries for
  the Update: 4 monitor statuses: `AttemptWithoutRun` (raise, severity 3),
  `StepError` (raise, severity 2), and opt-in `LongRunningOverall` /
  `LongRunningStep`. Documented in `ITSM/ITSM-Config-Reference.md`.

### Changed

- Renames the bundled pipeline display names (`name:` on GitHub Actions,
  `displayName:` / `name:` on Azure DevOps) into the three-group
  `Config: N` / `Monitor: N` / `Update: N` scheme with single-digit numbering:
  `Config: 1-3` (onboarding/config), `Monitor: 1-3` (day-2 fleet monitoring),
  and `Update: 1-4` (update lifecycle). `Monitor: 2` is Fleet Health Status and
  `Monitor: 3` is Fleet Update Status (numbered to match alphabetical order).
  Filenames, `AZLOCAL-PIPELINE-ID` values, aliases, and `-PruneDeprecated`
  logic are unchanged - this is a display-name-only change. Bundled pipeline
  `README.md`, `docs/appendix-pipelines.md`, and the ITSM / release docs are
  updated to match.
- `New-AzLocalFleetConnectivityStatusSummary` renames the `### Orphan ARBs (no
  matching cluster in scope)` section heading to `### Non-Azure Local and/or
  Orphan ARB appliances`, adds an intro line ("These ARB appliances do not have
  a matching Azure Local instance (cluster) in scope."), and expands the italic
  caveat to call out VMware vSphere and SCVMM Arc resource bridges and to add
  investigate-before-acting guidance (check resource type, custom location, and
  the platform served; do not delete an ARB until confirmed genuinely orphaned).
- The KPI-table "Orphan ARBs" note, the "how to interpret" causes list (new
  leading bullet about non-Azure Local resource bridges), and the cluster-table
  cross-reference now point at the renamed section.
- The `### Cluster Connectivity (with ARB Status)` table is split into two: a
  `### Cluster with Connectivity Issues` table (clusters that are not Connected
  with a Running ARB) shown first and expanded, and a `### Cluster without
  Connectivity Issues` table (Connectivity = Connected AND ARB Status = Running)
  collapsed behind a `<summary>Expand to view clusters</summary>` details block.
  Both tables share the same columns.
- `GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.86` to `0.8.87` across all
  bundled pipeline templates.

## [0.8.86] - 2026-06-16

Patch release. Renames the three onboarding pipeline templates from `Setup: 0N`
to `Config: 0N` so the GitHub Actions sidebar (and the Azure DevOps Pipelines
list) sorts the onboarding / configuration workflows ahead of the `Fleet: 0N`
operational workflows. Both surfaces sort alphabetically by the workflow `name:`
/ definition name, and `C` (Config) sorts before `F` (Fleet); the previous
`Setup:` prefix sorted *after* `Fleet:`. No public API change. Export count
unchanged (still 60).

### Changed

- Renames the operator-facing display names of the three onboarding workflows
  from `Setup: 01/02/03` to `Config: 01/02/03` across both GitHub Actions
  (`name:`) and Azure DevOps (`displayName:` / `name:`) templates. Filenames,
  `AZLOCAL-PIPELINE-ID` values, aliases, and `-PruneDeprecated` logic are
  unchanged - this is a display-name-only change.
- Updates the bundled pipeline `README.md` and `docs/appendix-pipelines.md`
  (section headings, dependency cross-references, naming rationale) to use the
  `Config: NN` naming.
- Clarifies in the bundled pipeline `README.md` (step 3, "federate the
  workflow") that **GitHub environments are optional**: the branch-scoped
  federated credential is all OIDC requires, so leaving the `environment` input
  blank is the supported minimal setup. Environments are a governance wrapper
  (approval gates, deployment-branch restrictions, wait timers, per-environment
  identities) and only need environment-scoped federated credentials when a run
  actually names one.
- `GENERATED_AGAINST_MODULE_VERSION` bumped from `'0.8.85'` to `'0.8.86'`
  across all bundled GitHub Actions and Azure DevOps pipeline templates.

## [0.8.85] - 2026-06-16

Patch release. Introduces Setup/Fleet naming in bundled pipeline templates,
adds the merged GitHub onboarding workflow (`setup-validate-and-inventory.yml`),
and updates pipeline refresh tooling to support optional pruning of deprecated
workflow files with pipeline-ID verification. No public API change. Export
count unchanged (still 60).

### Added

- Adds `setup-validate-and-inventory.yml` as the consolidated GitHub Setup
  workflow replacing separate auth/inventory onboarding templates.
- Standardizes Setup/Fleet naming across bundled GitHub Actions and Azure
  DevOps templates.
- Adds `-PruneDeprecated` handling in pipeline copy/update flows with
  AZLOCAL-PIPELINE-ID verification before deleting superseded files.

### Changed

- `GENERATED_AGAINST_MODULE_VERSION` bumped from `'0.8.84'` to `'0.8.85'`
  across all bundled GitHub Actions and Azure DevOps pipeline templates.

## [0.8.83] - 2026-06-15

Patch release. Fix-forward for v0.8.82 Item-5: the new Step.08 `UpdateLastAttempt`
reconciliation pass reads `$inv.tags` from `Get-AzLocalClusterInventory`, but the
v0.8.82 inventory projection did not carry the raw ARM `tags` bag. As a result the
"Recent update attempts with no observable updateRun" section was always empty in
production - the reconciliation found zero attempt gaps regardless of fleet
state. v0.8.83 surfaces the raw `tags` bag on every inventory row (in-memory only;
the on-disk CSV / JSON export keeps its explicit `$selectColumns` whitelist so
artefacts continue to omit the raw bag). Also fixes the GH Actions
`monitor-updates.yml` `jobs.outputs:` block to expose `attempts_without_run` to
downstream jobs (the cmdlet was already emitting it in v0.8.82 - only the YAML
wiring was missing), and a docstring drift in `Export-AzLocalUpdateRunMonitorReport`
("6 step outputs" -> "7 step outputs"). No public API change. Export count
unchanged (still 60).

### Fixed

- **`Get-AzLocalClusterInventory` PassThru output now carries the raw ARM `tags`
  bag** on every cluster row (`$itemProps['tags'] = $cluster.tags`). v0.8.82's
  Step.08 `UpdateLastAttempt` reconciliation pass in
  `Export-AzLocalUpdateRunMonitorReport` reads `$inv.tags` via
  `PSObject.Properties['tags']` to find the audit tag - without this fix, the
  reconciliation silently always reported zero gaps. The on-disk CSV / JSON
  export remains unchanged: the existing `$selectColumns` whitelist explicitly
  names the columns to persist and does NOT include `tags`, so artefacts do
  not leak the raw bag. New regression test
  (`v0.8.83: Get-AzLocalClusterInventory preserves raw ARM tag bag on PassThru`)
  asserts the in-memory property is present AND that `$selectColumns` does not
  surface `tags`.
- **GitHub Actions `monitor-updates.yml` `jobs.outputs:` block** now exposes the
  `attempts_without_run` step output (`${{ steps.snapshot.outputs.attempts_without_run }}`)
  so downstream jobs can gate on `attempts_without_run > 0` (e.g. open a triage
  issue when URP package-internal pre-install health-check failures are
  detected). The cmdlet was already emitting the step output in v0.8.82; only
  the pipeline-level `jobs.outputs:` wiring was missing. Azure DevOps requires
  no change here - `Set-AzLocalPipelineOutput` auto-publishes the step variable
  via `##vso[task.setvariable variable=...;isOutput=true]`.
- **`Export-AzLocalUpdateRunMonitorReport` cmdlet docstring drift**. The
  comment-based help still said "Emits 6 step outputs" after v0.8.82 added the
  seventh (`attempts_without_run`). Now reads "Emits 7 step outputs" with
  `attempts_without_run` listed alongside the existing six.

### Changed

- `GENERATED_AGAINST_MODULE_VERSION` bumped from `'0.8.82'` to `'0.8.83'`
  across all bundled GitHub Actions and Azure DevOps pipeline templates.

## [0.8.82] - 2026-06-15

Patch release. Step.05 + Step.10 step-summary UX polish from the v0.8.81 manual
pipeline-run review **plus three Item-5 deliverables**: (1) Step.05 "Last Updated"
column + UpdateRing-first sort, (2) per-cluster `UpdateLastAttempt` audit tag
written at every `Start-AzLocalClusterUpdate` outcome (and auto-cleared by the
existing sideloaded-reset path when a matching Succeeded run is observed), and
(3) a Step.08 reconciliation section that surfaces clusters where the
`UpdateLastAttempt` tag indicates an apply attempt with no observable updateRun
(captures Portland-style URP package-internal pre-install health-check failures).
No public API change. Export count unchanged (still 60).

### Added

- **`UpdateLastAttempt` cluster tag** (new). `Start-AzLocalClusterUpdate` now
  stamps each cluster with an ISO-8601 timestamp + outcome + update name +
  short reason at every attempt outcome: `HealthCheckBlocked`, `UpdateStarted`,
  and `Failed`. Format: `<UTC>;<Outcome>;<UpdateName>;<Reason>` truncated to
  the 256-char Azure tag-value limit (reason field truncated first with a
  trailing `~` sentinel; embedded `;` in reason is replaced with `,`). Writes
  swallow ARM errors and log a Warning - the audit tag MUST NOT block the
  apply flow. New Private helpers: `Format-AzLocalUpdateLastAttemptTagValue`,
  `ConvertFrom-AzLocalUpdateLastAttemptTagValue`,
  `Write-AzLocalUpdateLastAttemptTag`. New script-scoped constant
  `$script:UpdateLastAttemptTagName = 'UpdateLastAttempt'`.
- **Auto-clear of `UpdateLastAttempt`** in
  `Invoke-AzLocalSideloadedAutoResetForCluster`. The independent clear
  block (separate from the existing sideloaded reset logic) clears the tag
  when the latest update run is `Succeeded` AND either the UpdateName
  matches (case-insensitive) the recorded attempt OR the attempt was a
  `HealthCheckBlocked` / `Failed` outcome more than 1h old. Wrapped in
  try/catch with Verbose-only logging - never modifies the function's
  return shape.
- **Step.05 "Last Updated" column** in `Export-AzLocalClusterUpdateReadinessReport`.
  Sourced from `Get-AzLocalClusterUpdateReadiness`, which now computes the
  most-recent `packageVersions[].lastUpdated` timestamp across ALL
  packageTypes (Solution / Services / Platform / SBE / etc.) and exposes it
  as a new `LastUpdated` property on every output row (success, NotFound, and
  Error rows). The detail table grows a new "Last Updated" cell between
  "Status" and "Recommended update".
- **Step.05 sort change**: detail table now sorts by **UpdateRing -> Status
  priority -> ClusterName** (was Status -> UpdateRing -> ClusterName). Ring
  cohorts (Validation -> Canary -> Pilot -> Production / Default) stay
  grouped, with In-Flight + remediation rows surfacing at the top of each
  ring cohort. The Status-priority ordering inside each ring matches the
  v0.8.82 fix above (InProgress -> HealthFailure -> UpdateFailed -> ...).
- **Step.08 "Recent update attempts with no observable updateRun" section**
  in `Export-AzLocalUpdateRunMonitorReport`. Joins the per-cluster
  `UpdateLastAttempt` tag against the observed updateRun list and surfaces
  any attempt within the last `-RecentAttemptWindowHours` (default 72)
  that does not match an updateRun whose `StartTimeUtc` is at-or-after
  the attempt timestamp (-5 min slack). Each gap emits a JUnit testcase
  with `Type='AttemptWithoutRun'`. New pipeline output
  `attempts_without_run` and new `PassThru` fields
  `AttemptWithoutRunCount` + `AttemptGaps`. Common cause for a gap: URP
  package-internal pre-install health-check failure (audit log shows
  `Allows to apply updates: Succeeded` but no updateRun resource is ever
  persisted). New parameter:
  `[ValidateRange(0,8760)][int]$RecentAttemptWindowHours = 72`.

### Fixed

- **Step.05 Summary counts table** (`Export-AzLocalClusterUpdateReadinessReport`)
  no longer duplicates row labels. Each row reused the shared
  `Get-AzLocalStatusIconMap` cell (which already includes its own label) AND
  appended a duplicate trailing label, producing `Ready for Update Ready for
  update` / `Up to Date Up to date` / `Action Required Not ready for update` /
  `Health Failure Clusters with Critical health failures`. The icon-map cell
  is now emitted unmodified. The HealthFailure row keeps `(Clusters with
  Critical health failures)` in parentheses since it counts something
  different from the readiness cascade.
- **Step.05 All clusters detail table** now sorts by **Status priority** first
  (`InProgress` -> `HealthFailure` -> `UpdateFailed` -> `ActionRequired` ->
  `SbeBlocked` -> `NeedsInvestigation` -> `ReadyForUpdate` -> `UpToDate`),
  then `UpdateRing` + `ClusterName` as before. In-flight + remediation rows
  surface at the top; Up-to-Date drops to the bottom so operators see
  actionable items first.
- **Step.05 Not-Ready clusters (review first) table - Blocking reasons column**
  no longer shows `-` for rows blocked by `UpdateFailed` / `NeedsAttention` /
  `InProgress` / Warning-only `HealthFailure` / `SbeBlocked`. The upstream
  `Get-AzLocalClusterUpdateReadiness` only populates `BlockingReasons` for
  `CriticalHealthCheck` findings and abnormal cluster connectivity states
  (e.g. `NotConnectedRecently`). For every other Not-Ready category the
  column was left empty and rendered as `-`, forcing operators to cross-read
  the `Update state` + `Health` columns to infer the reason. The renderer
  now derives an actionable token from the Status bucket when the upstream
  `BlockingReasons` is empty:
  - `InProgress` -> `UpdateInProgress (run in-flight)`
  - `UpdateFailed` -> `UpdateState=<UpdateState>` (e.g. `UpdateState=NeedsAttention`, `UpdateState=UpdateFailed`)
  - `ActionRequired` -> `UpdateState=PreparationFailed`
  - `HealthFailure` -> `HealthState=Failure (no Critical findings; review Warning findings)`
  - `SbeBlocked` -> `PrerequisiteRequired (SBE update first)`
  - `NeedsInvestigation` -> `NeedsInvestigation (no Update or Health signal)`

  For any of the above, `; HealthState=Warning` is appended when the
  cluster's `HealthState` is `Warning` and the Status bucket is not already
  `HealthFailure`. The upstream `Get-AzLocalClusterUpdateReadiness` output
  shape is unchanged; the derivation is renderer-side only so JSON / CSV /
  `-PassThru` consumers continue to receive the original empty
  `BlockingReasons` value for these rows.
- **Step.10 Detailed Results Description column** inline-vs-collapse threshold
  bumped from 120 to **280 characters** in
  `Export-AzLocalFleetHealthStatusReport`. Short single-sentence descriptions
  render inline and only long multi-line descriptions collapse behind
  `<details><summary>view</summary>...</details>`. The previous 120-char
  cutoff put roughly half the rows inline and half collapsed on the same
  table, which looked broken.

### Changed

- `GENERATED_AGAINST_MODULE_VERSION` bumped from `'0.8.81'` to `'0.8.82'`
  across all bundled GitHub Actions and Azure DevOps pipeline templates.

## [0.8.81] - 2026-06-17

Patch release. Step summary polish across Steps 05-10: fixes a Step.10 KPI counting
bug, surfaces drive/volume-level detail in the Step.10 health-failure renderer, and
moves status-icon / cluster-deep-link / Ctrl-click-tip rendering onto three shared
private helpers so Steps 05-09 stay consistent and so the Azure DevOps step summary
no longer leaks literal GitHub-Markdown shortcodes (`:white_check_mark:`, etc.) into
the rendered output. No public API or export-count change (still 60 exports). One
new private helper trio (`Get-AzLocalStatusIconMap`, `Get-AzLocalClusterPortalLink`,
`Get-AzLocalCtrlClickTip`).

### Added

- **Shared private helpers** (Step summary DRY foundation):
  - `Private/Get-AzLocalStatusIconMap.ps1` - host-aware (GitHub vs Azure DevOps)
    status-name -> icon-cell map. Returns GitHub-Markdown shortcodes
    (`:white_check_mark:` / `:x:` / `:warning:` / ...) on the `GitHubActions` host
    where they render natively, and Unicode glyphs (U+2705 / U+274C / U+26A0 ...)
    on every other host (Azure DevOps and local console). Covers the full readiness
    cascade, health-overview buckets, severity tags, apply-updates outcomes, run-state
    buckets, progress-status buckets, fleet status, and version-support cells - so
    one helper is the single source of truth for every Step.* pipeline icon.
  - `Private/Get-AzLocalClusterPortalLink.ps1` - wraps a cluster name in a Markdown
    anchor pointing at the Azure Portal resource blade
    (`https://portal.azure.com/#@/resource{resourceId}`) when a resource id is
    supplied, falls back to the plain cluster name otherwise. Used by the
    Cluster column in Step.05 / Step.06 / Step.07 / Step.10 tables.
  - `Private/Get-AzLocalCtrlClickTip.ps1` - single-source the standing
    `> **Tip:** Hold Ctrl... when clicking - or middle-click - Cluster links to
    open them in a new tab.` line so it stays identical across pipelines.

- **Step.10 Fleet Health Status report** (`Export-AzLocalFleetHealthStatusReport`):
  - **Fixes "Healthy + Unhealthy != Total" KPI bug**. The KPI table previously
    summed only two buckets (Healthy + Unhealthy) and silently dropped clusters
    whose `HealthStatus` was `In progress` / `Unknown` / `Health check failed` AND
    had no failure rows. The table is now split into two:
    - **Cluster Counts** - Total / Healthy / Unhealthy / **Other** (new). Other
      is computed as `Total - Healthy - Unhealthy` (clamped non-negative) so the
      three buckets always sum to Total.
    - **Failing Checks Breakdown** - Total / Critical / Warning / Distinct
      Reasons (the old sub-counts, separated for clarity).
  - New `other_clusters` pipeline step output (number of clusters in the Other
    bucket); `-PassThru` PSCustomObject gains a matching `OtherClusters` field.
  - **Detailed Results columns reordered** to put the most-specific identifier
    first: `Severity | Title | Failure Reason | Description | Health Check Name |
    Failure Remediation | Target Resource Name | Target Resource Type |
    Last Occurrence | Resource Group`. Title is the per-check title (often
    names the failing node or volume); Description is a collapsible `<details>`
    block that surfaces drive/volume-level detail (e.g. the
    `\Device\HarddiskVolume6\...vhdx` file path emitted by a
    `Microsoft.Health.FaultType.Volume.FileSystem.Corruption.Correctable`
    warning); Health Check Name is the raw fault-type name (kept verbatim so
    operators can grep/triage by FaultType across runs).

### Changed

- **Step.05 Pre-flight Update Readiness Assessment**
  (`Export-AzLocalClusterUpdateReadinessReport`): Summary counts table and
  Not-Ready + All-clusters tables now render status icons via
  `Get-AzLocalStatusIconMap`; Cluster cells wrapped via
  `Get-AzLocalClusterPortalLink`; standing Ctrl-click tip via
  `Get-AzLocalCtrlClickTip`; "Up to Date" bucket gains the readiness-cascade
  check icon.
- **Step.06 Apply-Updates Readiness Gate report**
  (`Export-AzLocalClusterReadinessGateReport`): drops the inline icon `switch`
  block in favour of `Get-AzLocalStatusIconMap`; Cluster cells now wrap via
  `Get-AzLocalClusterPortalLink`; Ctrl-click tip via
  `Get-AzLocalCtrlClickTip`.
- **Step.07 Apply-Updates step summary** (`Add-AzLocalApplyUpdatesStepSummary`):
  drops the inline `$iconSuccess` / `$iconFail` / `$iconBlock` / `$iconSkip` /
  `$iconWarn` definitions in favour of `Get-AzLocalStatusIconMap` (so the
  icons render correctly on Azure DevOps). The Cluster Actions and Clusters
  Skipped at Readiness Gate tables now resolve each cluster's resource id from
  the readiness CSV (built from `Get-AzLocalClusterUpdateReadiness`) and wrap
  the Cluster cell via `Get-AzLocalClusterPortalLink`. Adds the standing
  Ctrl-click tip via `Get-AzLocalCtrlClickTip`. (The upstream apply-results
  JSON intentionally keeps its minimal `ClusterName / Status / UpdateName /
  Duration / Message` shape - the cluster id lookup is done in the renderer.)
- **Step.08 In-flight Update Run Monitor**
  (`Export-AzLocalUpdateRunMonitorReport`): the `$stateIcon` and `$statusIcon`
  switches no longer hard-code GitHub-Markdown shortcodes (e.g.
  `:large_blue_circle:` / `:hourglass_flowing_sand:`) which rendered as literal
  text on Azure DevOps. Both switches now read from `Get-AzLocalStatusIconMap`
  using the new `State*` (`StateInProgress` / `StateSucceeded` / `StateFailed` /
  `StateNotStarted` / `StateUnknown`) and `Status*`
  (`StatusInProgress` / `StatusCancelled`) keys.
- **Step.09 Fleet Update Status report**
  (`Export-AzLocalFleetUpdateStatusReport`): the inline shortcodes used by the
  Critical Health Status table, the Primary Status table, and the Version
  Distribution Support column are routed through `Get-AzLocalStatusIconMap`
  (new keys `Info`, `GreenCircle`, `YellowCircle`, `CycleArrows`,
  `GreyQuestion`, `SupportSupported`, `SupportUnsupported`,
  `SupportUnknown`) so they render correctly on both pipeline hosts.

### Pipeline templates

- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from
  `'0.8.80'` to `'0.8.81'`.

## [0.8.80] - 2026-06-16

Minor release. Bundles three pipeline-failure-rendering improvements that target the
Step.05 / Step.08 / Step.09 / Step.10 step summaries. All changes are additive and
backward-compatible (no exports renamed, no parameter contracts broken). One new
private helper (`Get-AzLocalUpdateRunHealthEvidence`).

### Added

- **Q1 - HealthCheck failure enrichment** (Step.09 `fleet-update-status`): when
  `Get-AzLocalUpdateRunFailures` categorises a failed run as
  `ErrorCategory='HealthCheck'` (the default), it now attaches a
  `HealthCheckEvidence` array column carrying same-cluster Critical
  `updateSummaries.healthCheckResult` entries that fired within a +/-2h window
  around the run. New private helper `Get-AzLocalUpdateRunHealthEvidence` (one
  ARG hop per HealthCheck-category row, scoped to a single cluster id; reuses
  the existing anti-mv-expand 128-cap pattern). The fleet-update-status
  markdown step summary now renders this evidence as bullets inside the per-row
  `<details>` panel, and the JUnit XML systemOut block lists each evidence
  entry's timestamp / title / severity / target resource id. New parameter
  `[bool]$EnrichWithHealthEvidence = $true` on `Get-AzLocalUpdateRunFailures`
  lets CSV-only consumers opt out of the extra ARG hops.
- **Q2 - Title and TargetResourceID columns** on both fleet-wide and
  per-cluster health failure outputs. `Get-AzLocalFleetHealthFailures` (Step.10)
  and `Test-AzLocalClusterHealth` (Step.05) now project the per-check `title`
  (often more specific than `displayName`, e.g. names the failing node) and the
  full `targetResourceID` (the ARM id of the failing component - lets renderers
  deep-link Server/Volume health failures back to the exact node or volume).
  `Export-AzLocalFleetHealthStatusReport` adds Title as a markdown column and
  wraps TargetResourceName in a portal hyperlink when TargetResourceID is
  present. `Test-AzLocalClusterHealth` adds Title to the dedup key, the
  Format-Table console output, and the JUnit Message field.
- **Q3 - Surface BOTH deepest-step `description` AND `errorMessage`**
  (Step.08 monitor + Step.09 fleet-update-status). Previously the two deepest-
  error walkers returned only the errorMessage trace and silently dropped the
  human-readable step description. Both walkers (`Resolve-AzLocalUpdateRunDeepestError`
  and `Get-DeepestErrorMessage`) now capture description at the same recursion
  site as errorMessage. `Get-AzLocalUpdateRunFailures` emits a new
  `DeepestStepDescription` column; `Format-AzLocalUpdateRun` emits a new
  `ErrorDescription` field on its PSCustomObject; the Step.08 and Step.09
  renderers combine description + errorMessage in the markdown failure cell
  and in the JUnit body (description heading, then trace).
- Cross-reference `.NOTES` headers added to the four parallel functions
  (the two deepest-error walkers and the two healthCheckResult readers) so
  future maintainers know to keep them in sync.

### Changed

- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from
  `'0.8.79'` to `'0.8.80'`.

### Notes

- No new exports (count unchanged at 60).
- Step.07 (`Add-AzLocalApplyUpdatesStepSummary`) was deliberately left out of
  the Q1/Q3 wiring because its data source is the live
  `Invoke-AzLocalReadinessGatedClusterUpdate` result row (apply-results.json),
  not `Get-AzLocalUpdateRunFailures`. Surfacing Q1/Q3 at Step.07 requires a
  separate upstream change to the readiness-gated invoker and is tracked for a
  follow-up release.

## [0.8.79] - 2026-06-15

Patch release. Adds an operator-only **Force Immediate Update** break-glass override to the Step.07 apply-updates pipeline that bypasses the per-cluster `UpdateStartWindow` / `UpdateExclusionsWindow` maintenance-window gate. Intended for emergency / out-of-window patching driven by an on-call operator; defaults to OFF; cannot be reached from the scheduled `apply-updates-schedule.yml` configuration file.

### Added

- **`Start-AzLocalClusterUpdate -IgnoreScheduleTags`** (new `[switch]` parameter). When set, the entire Step 3c maintenance-window block is skipped: the per-cluster `UpdateStartWindow` and `UpdateExclusionsWindow` tag lookups still execute (so the tag values can be logged), but `Test-AzLocalUpdateScheduleAllowed` is NOT called and the cluster is admitted regardless of the current UTC time. A `Warning`-level log entry is emitted per cluster recording the bypassed tag values so the override is visible in the transcript. Other gates (connectivity, health, sideload status, `UpdateExcluded` operator hard-override) continue to apply.
- **`Invoke-AzLocalReadinessGatedClusterUpdate -ForceImmediateUpdate`** (new `[switch]` parameter). When set, forwards `-IgnoreScheduleTags` to `Start-AzLocalClusterUpdate` for every cluster in the readiness CSV, and emits a high-visibility warning banner at the top of the apply run using the host-aware idiom (`::warning::` for GitHub Actions, `##vso[task.logissue type=warning]` for Azure DevOps, plain `Write-Warning` otherwise) so operators see the override has fired before any cluster is touched.
- **Pipeline parameter `force_immediate_update` (GitHub Actions `workflow_dispatch` input)** in `apply-updates.yml`. Choice input with values `false` (default) / `true`. The `description:` rendered in the GUI starts `WARNING:` and explicitly notes `MANUAL RUNS ONLY`. Wired into the apply step via an `INPUT_FORCE_IMMEDIATE_UPDATE` environment variable using an anti-injection collapse pattern: `${{ github.event_name == 'workflow_dispatch' && github.event.inputs.force_immediate_update || 'false' }}` - any `schedule` / `push` / `pull_request` / `repository_dispatch` event sees `'false'` even if a malicious upstream tried to inject the input.
- **Pipeline parameter `forceImmediateUpdate` (Azure DevOps `parameters:` boolean)** in `apply-updates.yml`. Defaults to `false`. The `displayName:` rendered in the Queue Build GUI starts `WARNING:` and explicitly notes `MANUAL QUEUE ONLY`. Wired into the apply step via a `FORCE_IMMEDIATE_UPDATE_PARAM` environment variable, with a runtime guard: the override is only forwarded to `Invoke-AzLocalReadinessGatedClusterUpdate` when `$env:BUILD_REASON -eq 'Manual'`. Scheduled / CI-triggered / PR-triggered runs log a `##vso[task.logissue type=warning]` explaining the parameter was ignored.
- **Bundled pipeline templates** all bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.78'` to `'0.8.79'`.

### Security / Anti-Injection Design

- The override is **deliberately unreachable from the apply-updates-schedule.yml configuration file**. No `forceImmediateUpdate` field exists on `New-AzLocalApplyUpdatesScheduleConfig`, `Resolve-AzLocalPipelineUpdateRing`, or `Get-AzLocalApplyUpdatesScheduleAudit`. A new Pester sweep asserts this.
- **Two layers of defence prevent a scheduled cron firing from honouring the flag**: (1) GitHub Actions YAML expression collapse to `'false'` for any non-`workflow_dispatch` event; (2) Azure DevOps runtime PowerShell guard requiring `$(Build.Reason) -eq 'Manual'`. Both layers fail closed.
- The `WARNING:` GUI label is required to make the override visible to anyone clicking through the Queue Build / Run Workflow dialog.

### Tests

- New parameter-presence regressions for `Start-AzLocalClusterUpdate -IgnoreScheduleTags` and `Invoke-AzLocalReadinessGatedClusterUpdate -ForceImmediateUpdate`.
- New `v0.8.79 Step.7 break-glass: force_immediate_update / forceImmediateUpdate` context (8 `It` blocks) that asserts: GHA input declaration + `WARNING:` GUI label + `MANUAL RUNS ONLY` text; ADO parameter declaration + `WARNING:` displayName + `MANUAL QUEUE ONLY` text; GHA `${{ github.event_name == 'workflow_dispatch' && ... || 'false' }}` anti-injection collapse; ADO `$(Build.Reason) -eq 'Manual'` runtime guard; pwsh forwarding of `-ForceImmediateUpdate` on both hosts; anti-leak sweep across `New-AzLocalApplyUpdatesScheduleConfig.ps1`, `Resolve-AzLocalPipelineUpdateRing.ps1`, and `Get-AzLocalApplyUpdatesScheduleAudit.ps1` confirming the override is NEVER referenced from any schedule-config code path.
- `Should have version 0.8.79` updated.

### Notes

- This release is operator-UX-only: no Az cmdlet API change, no readiness gate change, no schedule-config change, no new exports (still 60).
- The `UpdateExcluded` operator hard-override (`AzureLocalManagement.UpdateExcluded=true`) is INTENTIONALLY still respected by `Force Immediate Update`. The break-glass override is about time-window gates, not about per-cluster opt-outs. If a cluster must be force-included despite an `UpdateExcluded` tag, the operator removes the tag first.

## [0.8.78] - 2026-06-15

Patch release. Pipeline-summary UX polish driven by operator feedback on the bundled apply-updates pipeline (Step.07). Three improvements land together, plus the routine `actions/download-artifact` deprecation bump:

1. **JUnit re-classification of designed gate-respect outcomes.** `ScheduleBlocked` (cluster honouring its `UpdateStartWindow`), `SideloadedBlocked` (cluster honouring `UpdateSideloaded=False`), and `ExcludedByTag` (cluster honouring `AzureLocalManagement.UpdateExcluded=true`) are operator-configured opt-outs, not failures. They were previously rendered as `<failure>` rows by `Export-ResultsToJUnitXml`, which made `dorny/test-reporter` flip Step.07 runs RED with `##[error]Failed test were found` on otherwise-successful schedule-aware / sideload-gated / tag-excluded runs. They now render as `<skipped>` and the summary `<testsuite failures=N>` / `<testsuite skipped=N>` attributes agree. `HealthCheckBlocked` deliberately remains in the failure bucket - a Critical health failure blocking an update IS a real operational issue the team should action.
2. **Apply Updates summary now shows the FULL ring picture.** Previously the Readiness KPI table in the Apply Updates step summary showed only Total Clusters + Ready for Update, meaning the operator had no idea how many clusters were already fully patched (healthy steady state) or held back by the readiness gate (`state=NeedsAttention` / `UpdateInProgress` / `UpdateFailed` / pending SBE prerequisites / Critical health failure). The new optional `-UpToDateCount` / `-NotReadyCount` parameters on `Add-AzLocalApplyUpdatesStepSummary` add `Already Up to Date` and `Not Ready (needs attention before updating)` rows. Both apply-updates YAMLs (GitHub Actions + Azure DevOps) wire the upstream `readiness.UpToDateCount` / `readiness.NotReadyCount` outputs (already emitted by the check-readiness job/stage since v0.8.74) through to the summary task.
3. **`actions/download-artifact@v6` -> `@v7` in `apply-updates.yml` (GitHub Actions).** v6 still ran on Node.js 20 by default and was emitting `Node.js 20 actions are deprecated. Please update the following actions to use Node.js 24` warnings on every Step.07 run. `@v7` (Dec 2025 release) runs natively on Node 24 and silences the warning. **`@v7` is chosen deliberately over `@v8`**: v8 introduced a breaking change defaulting the `digest-mismatch` setting to `error`, which is more disruptive than the v6 -> v7 upgrade benefit.

No public API change or new exports (still 60). All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.77'` to `'0.8.78'`.

### Fixed

- **`Export-ResultsToJUnitXml` - JUnit re-classification of designed gate-respect outcomes.** Moved `ScheduleBlocked`, `SideloadedBlocked`, and `ExcludedByTag` from the `<failure>` bucket to the `<skipped>` bucket BOTH in the summary `<testsuite failures=...>` / `<testsuite skipped=...>` attributes AND in the per-testcase switch. `HealthCheckBlocked` deliberately retained in the failure bucket. `ExcludedByTag` was previously not explicitly classified at all - it fell through to the `<system-out>` default branch, which made it look like a successful test in `dorny/test-reporter` (now correctly classified as skipped).

### Added

- **`Add-AzLocalApplyUpdatesStepSummary` - optional `-UpToDateCount` and `-NotReadyCount` parameters.** Default `-1` (unknown) so the corresponding Readiness KPI rows are quietly omitted when callers do not supply them - existing consumers that have not regenerated their YAMLs see the same 2-row Readiness table they always did. When supplied (>= 0), the Readiness KPI table expands from 2 rows to 4 rows: `Total Clusters` / `Ready for Update` / `Already Up to Date` / `Not Ready (needs attention before updating)`. Up-to-Date is surfaced as a healthy steady state; Not-Ready surfaces clusters correctly held back by the readiness gate (state=NeedsAttention / UpdateInProgress / UpdateFailed, pending SBE prerequisites, critical health failures).

### Changed

- **`apply-updates.yml` (GitHub Actions)**: `actions/download-artifact@v6` -> `@v7` for the readiness-report download step (silences Node.js 20 deprecation warning). The `Summary` step now forwards `UpToDateCount` and `NotReadyCount` to `Add-AzLocalApplyUpdatesStepSummary` from `${{ needs.check-readiness.outputs.up_to_date_count }}` / `${{ needs.check-readiness.outputs.not_ready_count }}` (the check-readiness job has emitted these outputs since v0.8.74).
- **`apply-updates.yml` (Azure DevOps)**: the `ApplyClusterUpdates` job adds two new `variables:` (`upToDateCount` / `notReadyCount`) pulling from `stageDependencies.CheckReadiness.ReadinessCheck.outputs['readiness.UpToDateCount']` / `'.NotReadyCount'`. The `Generate Summary` task forwards them to `Add-AzLocalApplyUpdatesStepSummary`.

### Tests

- `Context 'JUnit XML export handles ScheduleBlocked'` and `Context 'JUnit XML export handles SideloadedBlocked (v0.7.1, reclassified v0.8.78)'` updated to assert the per-testcase element is `<skipped>` (not `<failure>`) AND the summary `<testsuite>` attributes agree (`failures=0`, `skipped=1`).
- New `It 'Export-ResultsToJUnitXml renders ExcludedByTag as <skipped> (v0.8.78)'` covers the third designed-skip status, asserting both per-testcase and summary-attr correctness.
- New `It 'Has v0.8.78 optional readiness-breakdown parameters UpToDateCount/NotReadyCount'` parameter-shape regression on `Add-AzLocalApplyUpdatesStepSummary` (in the existing `Thin-YAML Step.6: Add-AzLocalApplyUpdatesStepSummary` describe).

### Pipeline templates

- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.77'` to `'0.8.78'`. Bodies are unchanged except for the GitHub Actions `apply-updates.yml` (download-artifact bump + UpToDateCount/NotReadyCount wiring) and the Azure DevOps `apply-updates.yml` (UpToDateCount/NotReadyCount wiring).

## [0.8.77] - 2026-06-14

Patch release. Fixes two production strict-mode crashes that surfaced in Step.05 / Step.06 / Step.07 of the bundled apply-updates pipelines. Both bugs share the same root cause: bare `$obj.Prop` property access under `Set-StrictMode -Version Latest` **throws** when `Prop` is absent on a `PSCustomObject` instead of returning `$null`. Fixes use the `$obj.PSObject.Properties['Prop'] -and $obj.Prop` guard idiom (and `IDictionary.Contains()` for tag bags returned by `Invoke-AzRestJson`). No public API change or new exports (still 60). All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.76'` to `'0.8.77'`.

### Fixed

- **`Start-AzLocalClusterUpdate` (Step.07 main entry) - clusters without an `UpdateStartWindow` tag.** Production emitted `Error processing cluster '<Name>': The property 'UpdateStartWindow' cannot be found on this object.` for clusters whose tag bag did not include `UpdateStartWindow` / `UpdateExclusionsWindow`. The old guard `if ($clusterTags -and $clusterTags.$($script:UpdateStartWindowTagName))` threw **before** `-and` short-circuited because bare `.$()` member access on a missing `PSCustomObject` property is strict-mode-fatal. New code branches on `$clusterTags -is [System.Collections.IDictionary]` and uses `.Contains()` for hashtables / `PSObject.Properties[...]` for `PSCustomObject` tag bags. The semantic intent ("absent = any time eligible / no window restriction") is preserved: the outer `if ($windowTagValue -or $exclusionTagValue)` correctly skips the schedule gate when both are `$null`.
- **`Test-AzLocalClusterHealth` (Step.05/06 readiness gate) - clusters with no `properties.healthCheckResult` field.** Production emitted `Checking: <Cluster>... Error: The property 'healthCheckResult' cannot be found on this object.` for clusters whose ARM update summary genuinely had no `healthCheckResult` field (typical for clusters not yet probed by the update-health pipeline). The `catch` block then flagged the cluster `HealthState=Error / Passed=$false`, and the readiness gate falsely treated it as **blocked** - poisoning Step.5 / Step.7 / Step.9 readiness output for affected clusters (observed on Arizona and Sydney during the 2026-06-10..2026-06-14 window). The same bare-access pattern was present in `Get-HealthCheckFailureSummary` (Private helper) and `Get-AzLocalFleetStatusData` (Public, `-IncludeHealthDetails` path). All three sites now use the `PSObject.Properties[...]` guard idiom; `Test-AzLocalClusterHealth` correctly classifies such clusters as `HealthState="No Data" / Passed=$true` and continues.

### Tests

- Two new Pester regression contexts:
  - `v0.8.77 strict-mode regression: missing UpdateStartWindow tag` on `Start-AzLocalClusterUpdate` - feeds a `PSCustomObject` tag bag that deliberately omits the window tags, asserts `Should -Not -Throw`, and verifies `Test-AzLocalUpdateScheduleAllowed` is **not** called (proving the "no window tag = any time" semantic).
  - `v0.8.77 strict-mode regression: missing properties.healthCheckResult` on `Test-AzLocalClusterHealth` - feeds an ARG-shaped summary row whose `properties` PSCustomObject omits `healthCheckResult`, asserts `Should -Not -Throw`, and verifies the result row classifies as `HealthState='No Data'` / `Passed=$true`.
- Both bugs were **invisible** to parse-time analysis (`Get-CmdletErrors` / get_errors / lint) - only runtime against the property-less shape triggers the strict-mode throw. The new tests use the minimal real-world fixtures that match the production shapes.

### Pipeline templates

- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.76'` to `'0.8.77'`. The pipeline YAML bodies themselves are unchanged.

## [0.8.76] - 2026-06-12

Patch release. Adds a Microsoft-hosted Windows preflight job (GitHub Actions) / preflight stage (Azure DevOps) in front of the opt-in Step.6 `sideload-updates.yml` pipeline so an operator who triggers Step.6 without first completing the opt-in setup sees a clear "what to do next" panel in the run step summary instead of a silent `Status: Skipped`. Also broadens the master gate to accept `'true'`, `'True'`, `'TRUE'`, or `'1'` (was strict-literal `'true'` only).

### Added
- **GitHub Actions `sideload-updates.yml`**: new `preflight` job on `runs-on: windows-latest` with `permissions: actions: read, contents: read`. The job ALWAYS runs (no `if:` gate). It writes a markdown panel to `$GITHUB_STEP_SUMMARY` describing the gate state, required-variable check (currently `SIDELOAD_STATE_ROOT` only - other paths have sensible defaults), and a best-effort self-hosted-runner enumeration via the `/repos/{owner}/{repo}/actions/runners` API. The `sideload` job gains `needs: preflight`, so it cannot queue indefinitely when prerequisites are missing.
- **Azure DevOps `sideload-updates.yml`**: new `Preflight` stage on `pool: vmImage: windows-latest` that performs the gate + `SIDELOAD_STATE_ROOT` check and uploads the panel via `##vso[task.uploadsummary]`. The `Sideload` stage gains `dependsOn: Preflight`.
- **`Automation-Pipeline-Examples/docs/sideload.md` section 9** "Preflight (v0.8.76+)" - documents the full preflight behaviour matrix and explains why a Microsoft-hosted Windows runner is the right host for preflight (no fabric or Key Vault access required).

### Changed
- **Master gate broadened**: both `sideload-updates.yml` files now accept `SIDELOAD_UPDATES` in `'true'` / `'True'` / `'TRUE'` / `'1'`. GH Actions uses `contains(fromJSON('["true","True","TRUE","1"]'), vars.SIDELOAD_UPDATES)`; ADO uses an `or(eq..., eq...)` condition. The README continues to recommend `'true'` as the canonical value.
- **`docs/sideload.md` section 6** gate row updated to reflect the four accepted values; header note documents the preflight.
- **All bundled pipeline templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.75'` to `'0.8.76'`.

### Why preflight runs on a Microsoft-hosted Windows runner
The preflight does NOT touch the cluster fabric, Key Vault, or any Azure resource. It only reads workflow / pipeline variables, optionally queries the GH runners API with `GITHUB_TOKEN`, and writes markdown to the step summary. There is no domain-membership or VLAN-reachability requirement, so `windows-latest` is the correct minimal-cost host (~10s) and aligns with every other pipeline in the suite. The `sideload` job itself still requires the on-prem self-hosted runner with the `azlocal-sideload` label - that part has not changed.

### Notes on runner enumeration
The repo runners API requires repo-admin permission, which `GITHUB_TOKEN` does not normally grant. If the API call returns 403/404 the preflight degrades to a warning panel ("could not enumerate runners - verify manually under Settings -> Actions -> Runners"); it does NOT fail the run. If the API does return a list (e.g. a fine-grained PAT or GitHub App is wired in with `administration: read`), the preflight reports the exact set of matching online runners and fails fast when none are online. Azure DevOps does not enumerate agents at all (the `Agent Pools (read)` scope is not normally granted to the pipeline identity).

## [0.8.75] - 2026-06-12

Patch release. Removes the duplicate **Cycle calendar** table from the Step.3 apply-updates schedule audit step summary - before this fix, on any run where the Recommend view had at least one action-required finding (uncovered/partial cron windows, `RingMissingFromSchedule`, `RingOrphanedInSchedule`, `UnparseableCron`, or `NoWindowTag` when a cluster CSV was supplied), the Recommend snippet's plain 5-column calendar was inlined into the wrapper output **above** the wrapper's own enriched 7-column calendar, so operators saw two calendars back-to-back. Clean-fleet runs (no findings) were unaffected because the Recommend snippet is never written when its items list is empty. Also lands three Step.3 step-summary screenshots in `Automation-Pipeline-Examples/README.md` section 8.3. No public API or export-count change (still 60).

### Fixed

- **Step.3 step summary rendered the Cycle calendar twice when there were findings.** `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` writes a self-contained snippet to its `schedule-coverage-recommend.md` output - the snippet carries its action-required H2s, the proposed cron YAML block, AND a plain (5-column) cycle-calendar block (`Date | Day | CycleWeek | Eligible rings | AllowedUpdateVersions`). That snippet is only written when the Recommend view emits at least one row (so on a clean fleet, `$output.Count` is 0 and nothing is exported). `Export-AzLocalApplyUpdatesScheduleAudit` (the Step.3 wrapper) inlines that file as the action-required block when `$hasIssues` is true, and ALSO renders its OWN enriched (7-column) calendar later in the summary - with two extra columns (`Ring CRON Start Time (apply-updates pipeline)` and `Tag Start Window Match (>=95%)`) computed from the Step.6 cron triggers + cluster CSV. The wrapper used to be the only emitter; the inner emission was added in v0.8.5 (as a regression guard against a v0.8.4 silent-drop bug on clean fleets) and the two paths coexisted without anyone noticing the duplicate until v0.8.74's production Step.3 run.
- The fix is a new additive `[switch]$OmitCycleCalendar` parameter on `Test-AzLocalApplyUpdatesScheduleCoverage` (default off, no behaviour change for direct callers) that suppresses the inner calendar; `Export-AzLocalApplyUpdatesScheduleAudit` now opts in (`-OmitCycleCalendar=$true`) so only the enriched calendar surfaces in the Step.3 summary regardless of whether the run has findings.

### Changed (drift-notice banner)

- **`Add-AzLocalPipelineVersionBanner` now recommends `Update-AzLocalPipelineExample` (not `Copy-AzLocalPipelineExample -Update`) in the YAML-older-than-module annotation, and inlines the correct `-Platform` value and a sensible `-Destination` hint based on the detected pipeline host.** Before v0.8.75 the annotation said *"re-run 'Copy-AzLocalPipelineExample -Update' (you will be prompted per file; add `-Confirm:$false` to bypass)"* - which (a) used the clean-overwrite tool when the marker-aware merge tool exists for exactly this scenario, and (b) left the operator to figure out the right `-Platform` and `-Destination` themselves. The new annotation prints the complete copy-pasteable command: `Update-AzLocalPipelineExample -Destination '<repo-root>\.github\workflows' -Platform GitHub` on GitHub Actions, `Update-AzLocalPipelineExample -Destination '<repo-root>\pipelines' -Platform AzureDevOps` on Azure DevOps. Update preserves customer customisations bracketed by `AZLOCAL-CUSTOMIZE` markers (CRON schedules, ITSM secrets) so it is the correct tool to recommend on a repo that has already been customised. The symmetric YAML-newer-than-module warning gets the same treatment. Verdict text on `-PassThru` returns `'YAML older than module - run Update-AzLocalPipelineExample to refresh'`.

### Added

- **`Test-AzLocalApplyUpdatesScheduleCoverage -OmitCycleCalendar` switch** - opts out of the Recommend view's informational cycle calendar section. Used by `Export-AzLocalApplyUpdatesScheduleAudit` to avoid the duplicate-rendering bug above; direct callers see the calendar unchanged.
- New Pester regression test (`v0.8.75: passes -OmitCycleCalendar to the inner Recommend invocation so the step summary renders only one Cycle calendar`) spies on the Recommend mock to assert the switch is bound, and asserts the rendered step summary contains exactly one `## Cycle calendar - next` heading.

### Docs

- `Automation-Pipeline-Examples/README.md` section 8.3 gains three Step.3 step-summary screenshots: `apply-updates-schedule-audit-part1.png` (cron coverage remediation), `apply-updates-schedule-audit-part2.png` (NoWindowTag remediation), `apply-updates-schedule-audit-part3.png` (enriched cycle calendar). `docs/images/README.md` referenced-by table updated with the three new entries.

### Changed

- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.74'` to `'0.8.75'`.

## [0.8.74] - 2026-06-12

Consistency release for the cluster readiness reports. A cluster that has already applied every required update is now classified and labelled identically across the Step.5 readiness report, the Step.7 readiness gate, and the Step.9 fleet update-status report. Also corrects the `Progress` column in the Step.7 in-flight monitor and the standalone HTML report's "Recent Update Run History" table, which had been reporting a near-constant `1/2 steps` for the whole multi-hour run, and drops the dead `target="_blank"` / `rel="noopener"` attributes from every Step.7 / Step.8 / Step.10 portal-link cell (GitHub Actions and Azure DevOps step-summary sanitisers strip them anyway) in favour of an explicit Ctrl/Cmd/middle-click tip rendered above the affected tables. No public API or export-count change (still 60).

### Fixed

- **Fully-patched clusters mis-classified as "not ready" in Step.5 and Step.7** - a cluster that had successfully installed every required update showed `0` in the Step.5 (`Export-AzLocalClusterUpdateReadinessReport`) "Up to date" summary count and appeared in its "Not-Ready clusters (review first)" table, and rendered with a no-entry icon in the Step.7 (`Export-AzLocalClusterReadinessGateReport`) binary `Ready?` column - both implying failure. Root cause: the "Up to Date" determination required the `AllAvailableUpdates` collection to be empty, but a cluster that has installed all updates still lists those (now-Installed) package names there, so the test never matched a fully-patched cluster. Step.9 already classified these correctly via its priority cascade; Step.5/Step.7 now share that exact logic.
- **`Progress` column always reported the coarse top-level wrapper (`1/2 steps`) across the Step.7 monitor and the standalone HTML "Recent Update Run History" report.** Real Azure Local update runs expose only two top-level wrapper steps in `properties.progress.steps` (`Prepare update` + `Start update`), and `Start update` stays `InProgress` for the entire run. Counting that level alone reported `1/2 steps` (or `0/2 steps`) for multi-hour, ~150-leaf solution updates regardless of real progress. Both reporting paths now walk the full nested step tree via a new private helper (`Get-AzLocalUpdateRunStepStats`) and report leaf-step completion as `M/N steps (P%)`, optionally suffixed with `, K failed` when leaf-level errors are present - mirroring how `CurrentStep` already traverses the tree via `Get-DeepestActiveStep`. Affects the Step.7 monitor formatter (`Format-AzLocalUpdateRun`) and the fleet-status data collector (`Get-AzLocalFleetStatusData`, which feeds the HTML report's `Recent Update Run History` table and the `latest-runs.csv`).
- **Portal-link `target="_blank"` / `rel="noopener"` were silently stripped by the step-summary sanitiser**, so the Cluster / Update hyperlinks rendered in the Step.7 (`Export-AzLocalUpdateRunMonitorReport`) in-flight + failed-runs tables, Step.8 (`Export-AzLocalFleetUpdateStatusReport`) Update Run History table, and Step.10 (`Export-AzLocalFleetHealthStatusReport`) Fleet Health Overview / By-Reason / Detailed Results tables always opened in the current tab even though the markdown source asked for a new tab. Confirmed in the rendered HTML of a real GitHub Actions job summary: GitHub's GFM sanitiser drops `target` entirely and forces `rel="nofollow"` (also documented behaviour for `Set-Content` / step-summary markdown). The dead attributes are now removed (so the emitted markdown matches the rendered DOM) and each affected table is preceded by a short tip - **"Hold `Ctrl` (or `Cmd` on macOS) when clicking - or middle-click - Cluster or Update links to open them in a new tab. (GitHub markdown strips `target="_blank"`.)"** The standalone HTML report (`New-AzLocalFleetStatusHtmlReport`) is unaffected; it is written as a raw `.html` artifact, not a step-summary, so its `target="_blank"` already works as intended in any browser.

### Added

- **`Get-AzLocalClusterReadinessStatus` private helper** - the single source of truth for the readiness priority cascade (UpdateFailed > ActionRequired > HealthFailure > SbeBlocked > InProgress > ReadyForUpdate > UpToDate > NeedsInvestigation). Step.5, Step.7 and Step.9 (`Export-AzLocalFleetUpdateStatusReport`) now all classify clusters through this one helper; previously each report re-implemented the logic inline and the definitions had drifted.
- **Step.7 `UP_TO_DATE_COUNT` / `UpToDateCount` step output** - additive; the existing `READY_COUNT` gate semantics are unchanged. `Export-AzLocalClusterReadinessGateReport -PassThru` now also returns `UpToDateCount`.
- **Step.7 "No Clusters Ready" summary now explains why** - `Add-AzLocalNoReadyClustersStepSummary` accepts the new `-UpToDateCount` / `-NotReadyCount` parameters and renders an Up-to-Date vs Not-Ready breakdown table, so an idle apply-updates run makes clear that already-patched clusters are a healthy steady state (not a failure) and points to the per-cluster `Status` / `Blocking Reasons` detail. When every discovered cluster is already up to date the run now logs an informational notice instead of a warning. Both the GitHub Actions and Azure DevOps `apply-updates` templates wire the two new counts through from the readiness gate.

### Changed

- **Step.7 per-cluster table now has a `Status` column instead of a binary `Ready?` column** - it renders readable labels (`Ready`, `Up to Date`, `In Progress`, `SBE Prerequisite`, `Health Failure`, `Update Failed`, `Action Required`, `Needs Investigation`) and the header line now shows a distinct `Up to Date` count.
- **Step.5 "All clusters detail" table `Ready` boolean column replaced with the same readable `Status` label**, and the "Not-Ready clusters (review first)" table now excludes both Up-to-Date and Ready clusters.
- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.73'` to `'0.8.74'`.

## [0.8.73] - 2026-06-11

Cycle-calendar refinement. The Step.3 apply-updates schedule audit now shows the per-ring cluster count INLINE in the "Eligible rings" column instead of as a separate column, and the Step.3 pipeline render path actually populates those counts (previously the counts never reached the rendered calendar). No public API or export-count change (still 60).

### Changed

- **Cluster counts folded inline into the "Eligible rings" column** - `Get-AzLocalApplyUpdatesScheduleCycleCalendar` no longer adds a separate "Clusters in ring(s)" column when `-ClusterRingCounts` is supplied. Instead the per-day calendar relabels the header "Eligible rings" -> "Eligible rings (cluster count)" and appends each ring's count inline to its token, e.g. `` `Prod` (9), `Canary` (3) ``. Dead days still render `_(none - dead day)_`. The per-ring projection table (when `-IncludePerRingSummary` is set) keeps its separate "Cluster count" column unchanged.
- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.72'` to `'0.8.73'`.

### Fixed

- **Step.3 cycle calendar never showed cluster counts** - `Export-AzLocalApplyUpdatesScheduleAudit` (the cmdlet the Step.3 `apply-updates-schedule-audit` pipeline calls) never forwarded `-ClusterRingCounts` to the cycle-calendar cmdlet, so the cluster-count enrichment was silently absent from every rendered Step.3 summary even though the cmdlet supported it. The Export wrapper now builds a ring -> tagged-cluster-count map from the supplied cluster CSV and forwards it, so the inline counts appear whenever a `-ClusterCsvPath` is provided.

## [0.8.72] - 2026-06-11

Patch release. Pipeline-template polish only - no module code, public API, or export-count change (still 60). Moves the `apply-updates.yml` schedule-file author guidance out of the customise marker so it can be refreshed on already-deployed consumers, and zero-pads single-digit step numbers in pipeline display names so the GitHub Actions sidebar and Azure DevOps pipelines list sort in execution order.

### Fixed

- **`apply-updates.yml` author guidance trapped inside the customise marker (GitHub Actions + Azure DevOps)** - the schedule-file author guidance comments (including the `New-AzLocalApplyUpdatesScheduleConfig` example and the schedule-path default) lived INSIDE the `# BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` block. `Update-AzLocalPipelineExample` is a marker-aware merge: it keeps the BEGIN/END lines from the new source but preserves the BODY between them verbatim from the consumer's file. So any correction to guidance inside the marker - such as the v0.8.71 `.github` -> `config` schedule-path fix - could never propagate to a consumer who had customised their crons. All author guidance has been moved ABOVE the `# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` line (outside the preserved region); the marker body now holds only the trigger directive (a placeholder comment on GitHub, `trigger: none` on Azure DevOps). The guidance was also reworded to avoid mentioning the literal `BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` token, which the marker parser would otherwise mis-detect as a second marker.

### Changed

- **Pipeline display names zero-padded (display/title text only)** - single-digit step numbers are padded to two digits across all bundled pipeline display names and titles: GitHub Actions workflow `name:` fields, Azure DevOps top-level `name:` / stage `displayName:` labels, and the `# Step.N - ` header comments (`Step.0` -> `Step.00` ... `Step.9` -> `Step.09`; `Step.10` is unchanged). The GitHub Actions sidebar and Azure DevOps pipelines list sort workflows alphabetically by display name, so `Step.10` previously sorted between `Step.1` and `Step.2`. Functional identifiers (artifact names `azlocal-step.N-*`) and cross-reference prose comments are deliberately left unchanged.
- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.71'` to `'0.8.72'`.

## [0.8.71] - 2026-06-11

Patch release. Fixes a production strict-mode crash in JUnit export, corrects the GitHub Actions sideload schedule-path default, and de-numbers stale `Step.N_*.yml` filename references left behind in pipeline doc strings after the v0.8.7 rename. No public API or export-count change (still 60).

### Fixed

- **`Export-ResultsToJUnitXml` strict-mode crash (production)** - a live Apply Updates run failed with `Failed to export results: The property 'CurrentState' cannot be found on this object`. An `UpdateStarted` success row legitimately lacks `CurrentState`/`Progress`, but both the failure and success/default branches read those properties unguarded, which throws under `Set-StrictMode -Version Latest`. All bare reads (`CurrentState`, `Progress`, `UpdateName`) are now guarded with `if ($result.PSObject.Properties['<name>'] -and ...)`, matching the existing `StartTime`/`EndTime` pattern. Regression test added.
- **Sideload schedule-path default** - GitHub Actions `sideload-updates.yml` had `APPLY_UPDATES_SCHEDULE_PATH` defaulting to `./.github/apply-updates-schedule.yml`. Corrected to `./config/apply-updates-schedule.yml` so it matches where `Copy-AzLocalPipelineExample` drops the starter (alongside the auth-map and catalog, which already defaulted to `config/`).
- **Stale pipeline doc-string filenames** - de-numbered `Step.N_*.yml` references in header comments and input descriptions for `apply-updates-schedule-audit.yml`, `assess-update-readiness.yml`, `authentication-test.yml` (both platforms) and the `apply-updates-schedule.example.yml` starter. v0.8.7 renamed the files; these doc strings now name the current files (`apply-updates.yml`, `authentication-test.yml`, `apply-updates-schedule-audit.yml`).

### Changed

- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.7'` to `'0.8.71'`.

## [0.8.7] - 2026-06-11

On-prem solution-update sideloading automation release. Adds an opt-in, off-by-default workflow for Azure Local clusters that cannot pull solution updates from Azure directly: a new self-hosted Step.6 pipeline (`sideload-updates.yml`) robocopies update media to each cluster's import share, verifies the SHA256 over WinRM, runs `Add-SolutionUpdate`, and flips the `UpdateSideloaded=True` cluster tag so the downstream apply (now Step.7) picks it up. The long-running copy executes in a detached Windows Scheduled Task and is driven as a re-entrant state machine on a frequent CRON, so no individual pipeline run is long-lived. **This release de-numbers all bundled pipeline filenames and renumbers four display steps (BREAKING for any consumer that pins on the old `Step.N_*.yml` filenames).** Module export count grows 55 -> 60.

### New Public cmdlets (5)

- **`Update-AzLocalSideloadCatalog`** - validates / refreshes the sideload catalog (Solution and OEM SBE `packageType` entries) used to resolve which update media to stage.
- **`Resolve-AzLocalSideloadPlan`** - resolves the per-cluster sideload plan (target media, import share, current state) from inventory + catalog.
- **`Invoke-AzLocalSideloadUpdate`** - the re-entrant state-machine driver (Planned -> Copying -> Copied -> Verified -> Imported -> SideloadFlagged); spawns / re-attaches the detached robocopy Scheduled Task, verifies SHA256 over WinRM, runs `Add-SolutionUpdate`, and sets `UpdateSideloaded=True`.
- **`Export-AzLocalSideloadStatusReport`** - emits the per-cluster sideload status CSV + JUnit XML + step outputs for the Step.6 pipeline.
- **`Add-AzLocalSideloadStepSummary`** - renders the Step.6 markdown step summary (per-state table + shared-state contract + exit conditions).

### New Step.6 sideload pipeline

- **`sideload-updates.yml`** (GitHub Actions + Azure DevOps), opt-in via the `SIDELOAD_UPDATES` repository variable. Targets a self-hosted runner (`runs-on: [self-hosted, azlocal-sideload]`) on GitHub / a self-hosted agent pool (`pool: { name, demands: azlocal-sideload }`) on Azure DevOps. Manual `workflow_dispatch` plus a `*/30` CRON poll so the state machine can advance between runs.
- Catalog (Solution + OEM SBE), shared-UNC state for multi-runner coordination, a Key Vault-sourced AD credential for cluster WinRM, and robocopy throttling (`SIDELOAD_ROBOCOPY_SWITCHES`) are documented in `Automation-Pipeline-Examples/docs/sideload.md` and `sideload-robocopy.md`.

### BREAKING - pipeline filenames de-numbered

- The `Step.N_` filename prefix has been removed from every bundled pipeline (e.g. `Step.7_apply-updates.yml` -> `apply-updates.yml`). The in-pipeline `Step.N - ` **display** names are unchanged, so the operator-facing step ordering is preserved. Stable filenames mean future reorders become pure display-name edits.
- **`Update-AzLocalPipelineExample` is now rename-aware.** It matches each destination pipeline by a stable logical id (embedded `# AZLOCAL-PIPELINE-ID:` marker on line 1, with legacy-filename aliases) rather than by filename, and AUTO-RENAMES any older `Step.N_*.yml` on disk to the new de-numbered name while preserving the consumer's `BEGIN/END-AZLOCAL-CUSTOMIZE` CRON edits. It emits a `RenamedFrom` result field and a GitHub/Azure DevOps required-check warning when a rename occurs.

### BREAKING - display-step renumber

To make room for sideload at Step.6, four display steps shift up by one: apply-updates 6 -> 7, monitor-updates 7 -> 8, fleet-update-status 8 -> 9, fleet-health-status 9 -> 10.

### Sideload-aware existing steps

- **Step.1 inventory** can emit the `UpdateAuthAccountId` column (`-IncludeSideloadColumns`, auto-enabled when `SIDELOAD_UPDATES` is set). Byte-identical output when sideload is off.
- **Step.2 tag management** can set the `UpdateAuthAccountId` tag from CSV.
- **Step.3 schedule advisor** can emit a recommended sideload CRON (the apply window minus `SIDELOAD_LEAD_DAYS`) when sideloading is enabled.

### BREAKING - all operator config relocated to a repo-root `config/` folder

- Every operator-authored configuration file now lives in a single **`config/` folder at the repo root**, with the **identical path on GitHub Actions and Azure DevOps**. This consolidates around the convention already established for the ring CSV (`config/ClusterUpdateRings.csv`) and eliminates the previous `.github/`-vs-repo-root divergence. The four files are: `config/ClusterUpdateRings.csv`, `config/apply-updates-schedule.yml`, `config/sideload-auth-map.csv`, and `config/sideload-catalog.yml`.
- **The starter `apply-updates-schedule.yml` has moved** from its v0.7.92 location (`.github/apply-updates-schedule.yml` on GitHub / repo root on Azure DevOps) to `config/apply-updates-schedule.yml` on both platforms. The `apply-updates.yml` (Step.7) and `apply-updates-schedule-audit.yml` (Step.3) defaults for `APPLY_UPDATES_SCHEDULE_PATH` / `schedule_path` / `schedulePath` now point at `config/apply-updates-schedule.yml`.

### Scaffolding - starter sideload config drop

- **`Copy-AzLocalPipelineExample`** now drops two header-only starter config files alongside the starter `apply-updates-schedule.yml` in the repo-root **`config/`** folder when `-Platform GitHub` or `-Platform AzureDevOps` is used: `sideload-auth-map.csv` (CSV header row only) and `sideload-catalog.yml` (`schemaVersion: 1` + empty `packages:`). They land at `config/sideload-auth-map.csv` and `config/sideload-catalog.yml` - the same path on both platforms. Both are skeleton-only (no demo credential rows or media entries), so they parse to an empty auth-map / empty catalog and remain inert even if `SIDELOAD_UPDATES` is flipped on before they are populated. An existing file is **never** overwritten. Suppress with the new `-SkipStarterSideloadConfig` switch. The `sideload-updates.yml` `SIDELOAD_AUTH_MAP_PATH` / `SIDELOAD_CATALOG_PATH` defaults (both platforms) now point at `./config/` to match where the starters land.
- **`Update-AzLocalPipelineExample` does not touch `config/`.** It only refreshes the bundled pipeline YAMLs (matched by logical `# AZLOCAL-PIPELINE-ID:` marker), so all operator-owned config in `config/` is preserved across module upgrades.

### Schema migration - sideload catalog framework

- **New `sideload-catalog.yml` schema-migration framework**, symmetric with the existing `apply-updates-schedule.yml` one. Adds `$script:SideloadCatalogSchemaCurrentVersion` (currently `1`), a private text-surgery migration engine (`Private/Convert-AzLocalSideloadCatalogSchemaVersion.ps1`) with an EMPTY per-hop recipe table at v1, and a `-SchemaMigrate` parameter set on `Update-AzLocalSideloadCatalog` that migrates an existing catalog in place (backing the original up as `<name>.v<old>.old.yml`, preserving operator comments + OEM `SBE` entries verbatim, honouring `-WhatIf`/`-Confirm`, returning a `{ Action, FromVersion, ToVersion, BackupPath, Hops[] }` result). `Get-AzLocalSideloadCatalog` now reads the top-level `schemaVersion` and REFUSES to parse a catalog written by a newer module (missing `schemaVersion` is tolerated as v1 for back-compat). No behaviour change at v1 - the framework is wired up so the first non-additive catalog format change is a small, well-tested recipe addition.
- **Doc fix**: corrected stale references in `Convert-AzLocalScheduleSchemaVersion.ps1` and the `.psm1` that named `Update-AzLocalPipelineExample` as the schedule schema migrator; the actual migrator is `Update-AzLocalApplyUpdatesScheduleConfig`.


### Testing - sideload smoke coverage + wall-clock timing ledger

- **New Step.6 sideload smoke coverage.** Added `Tools/smoke-test-sideload-plan.ps1` (a dedicated, sequence-faithful harness) plus a `Resolve-AzLocalSideloadPlan` section in the unified `Tools/validate-arg-queries.ps1`. A single `Resolve-AzLocalSideloadPlan` call exercises the whole Step.6 read path - the schedule parser, the private auth-map + catalog parsers, and the live cluster ARG query - so any ARG-query regression, parser drift, or plan-row schema change is caught locally before the `sideload-updates.yml` pipeline runs. The auth-map and catalog are operator-authored config (no bundled live example), so the harness synthesises minimal valid temp files and points the planner at the bundled `apply-updates-schedule.example.yml`. On a fleet with no `UpdateAuthAccountId`-tagged clusters the plan is legitimately empty (recorded as `PASS-EMPTY`) - still validating that the ARG query parsed/executed and all three config parsers ran without throwing. `Tools/SMOKE-COVERAGE.md` gains the sideload row and a "no fleet tags required" note.
- **Wall-clock timing is now recorded to a git-tracked ledger.** A new shared helper `Tests/Add-PesterRunTiming.ps1` appends one row per full-suite run to `Tests/test-run-timings.csv` (timestamp, module version, total/passed/failed/skipped, wall-clock seconds, Pester execution seconds, discovery seconds, runner label, PS version). `Tests/Invoke-Tests.ps1` wraps the run in a stopwatch and calls the helper at the end. Tracking suite duration over time makes wall-clock regressions visible and informs whether the eventual test-file split for parallelism is worth it.

### Fixed

- **Step.6 Apply Updates logged "Failed to export results: The property 'CurrentState' cannot be found on this object" after a successful update start.** The JUnit XML exporter (`Export-ResultsToJUnitXml`) used bare property access (`if ($result.CurrentState)` / `if ($result.Progress)` / `if ($result.UpdateName)`) in both the failure and success branches. The `UpdateStarted` success-row shape emitted by `Start-AzLocalClusterUpdate` has no `CurrentState` or `Progress` property, so under `Set-StrictMode -Version Latest` the success branch threw when exporting to `.xml` - the update itself started fine, only the results export failed. All three accesses in both branches now guard with `$result.PSObject.Properties['...']` (matching the existing `StartTime`/`EndTime` pattern). Adds a regression test that exports a `CurrentState`-less `UpdateStarted` row and asserts no throw.
- **In-flight monitor "Current Step" column always showed the top-level wrapper step (e.g. "Start update").** `Format-AzLocalUpdateRun` (and the duplicate logic in `Get-AzLocalFleetStatusData`) selected `CurrentStep` from the **top-level** `properties.progress.steps` array only. Azure Local nests a coarse wrapper step that stays `InProgress` for the entire run, so the Step.8 monitor (`Export-AzLocalUpdateRunMonitorReport`) and fleet-status report always rendered the wrapper name instead of the real current activity. Both paths now reuse `Get-DeepestActiveStep` to walk to the deepest `InProgress`/`Error`/`Failed` leaf (preserving the `(FAILED)` suffix), making `CurrentStep` consistent with `CurrentStepDetail` / `Get-CurrentStepPath` and the standard update-progress output. Adds two `Format-AzLocalUpdateRun` regression tests.

### Versioning / tests

- `ModuleVersion` 0.8.6 -> 0.8.7 (`.psd1` + `.psm1`). Export count assertion 55 -> 60.
- All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.6'` to `'0.8.7'`.

## [0.8.6] - 2026-06-10

Step.3 cycle-calendar enrichment release. Adds two opt-in columns to the per-day `## Cycle calendar` markdown table produced by `Get-AzLocalApplyUpdatesScheduleCycleCalendar` and auto-wires them from `Export-AzLocalApplyUpdatesScheduleAudit` so operators can see (a) which Step.6 cron firing times will fire on each calendar day and (b) what fraction of clusters in the ring(s) eligible on that day have an `UpdateStartWindow` tag that actually covers at least one of those firings. **Also fixes six production regressions introduced by the v0.8.5 thin-YAML port (Step.0, Step.3, Step.4 x2, Step.6, Step.9) and adds Pester guards so the same anti-patterns cannot ship again.** No public API removed; no existing parameter changed; no behavioural change on callers that do NOT supply the new dictionaries. Same module export count as v0.8.5 (55).

### Pipeline regression fixes (v0.8.5 -> v0.8.6)

All bugs root-cause to three anti-patterns that bit the v0.8.5 thin-YAML port - all now Pester-guarded so any future caller that reintroduces them fails the local test suite:

- **Step.0 (`Export-AzLocalAuthValidationReport`)**: `$clusterRows = @(Invoke-AzResourceGraphQuery ...)` collapsed every fleet to "1 cluster(s) visible" no matter the real count. `Invoke-AzResourceGraphQuery` uses unary-comma `return , $allRows.ToArray()` to preserve array-shape on direct assignment; wrapping it in `@()` collected the outer single-item wrapper and silently dropped every row past the first. Fixed by switching to direct assignment plus a `$null` -> `@()` guard for the empty-fleet case, AND a defensive `$clusterRows = @($clusterRows)` coerce on the variable so a single-row shape can never short-circuit `.Count` to `$null` under strict mode.
- **Step.3 (`Test-AzLocalApplyUpdatesScheduleCoverage`)**: `$allMatched = @($segmentStatuses.MatchingCrons | Select-Object -Unique)` threw "The property 'MatchingCrons' cannot be found on this object." under `Set-StrictMode -Version Latest`. Two distinct root causes: (a) `$segmentStatuses` can stay `@()` when `$r.RequiredCrons` is empty, and (b) even when `Count > 0`, array-level member-access (`$arr.Prop`) trips strict mode v3+. Fixed by guarding with `if ($segmentStatuses.Count -gt 0)` AND switching to explicit enumeration: `$segmentStatuses | ForEach-Object { $_.MatchingCrons } | Select-Object -Unique`.
- **Step.4 (`Get-AzLocalFleetConnectivityStatus` AND `Export-AzLocalFleetConnectivityStatusReport`)**: ARB row rendering crashed under strict mode on any RG holding exactly one cluster. Two related anti-patterns bit here:
  - In `Get-AzLocalFleetConnectivityStatus`, `@($null)` produces an `Object[1]` containing `$null` (NOT an empty array), so `$matched.Count -gt 0` was true and `$_.ClusterName` on the null element threw PropertyNotFound. First fix attempt cast `[object[]]$matched = if (...)` - insufficient on production. Second fix used `$matchedList = if (...) { $clustersByRg[$rg] } else { $null }; $matched = @($matchedList)` - still broken because `@($null)` is `Object[1]`. Final fix (v0.8.6-fix3): explicit branch `if ($clustersByRg.ContainsKey($rg)) { $matched = @($clustersByRg[$rg]) } else { $matched = @() }`.
  - In `Export-AzLocalFleetConnectivityStatusReport`, `[string[]]$clusterIdList = if ($r.ClusterId) { ... } else { @() }` had the same scalar-unwrap pattern when `Where-Object` yielded a single string. Fixed via the same explicit if/else with `@()` wrap on the variable.
- **Step.6 (`Get-AzLocalClusterUpdateReadiness`)**: `if ($cluster.NotFound)` at line ~337 threw "The property 'NotFound' cannot be found on this object" because three of the four `$clustersToProcess += @{ ... }` builder paths (ByTag, ByResourceId-found, ByName-found) omitted the `NotFound` key - only the ByResourceId-not-found path set it. Under strict mode v3+, dot-access on a hashtable missing the key throws. Fixed by adding `NotFound = $false` to all three missing-key paths so the iteration is always safe.
- **Step.9 (`Export-AzLocalFleetHealthStatusReport`)**: both `$detail = @(Get-AzLocalFleetHealthFailures ...)` and `$overview = @(Get-AzLocalFleetHealthOverview ...)` collapsed multi-row helper output to `Object[1]`. Same `@()` wrap + unary-comma collision as Step.0. Step.9 had the most visible symptom: "Found 81 failing check(s) across 9 cluster(s)" from the helper, then "Found 1 failing health-check entry/entries" two lines later, followed by exit code 1 when `Group-Object` tried to property-access the wrapper. Fixed by switching both to direct assignment plus `$null` -> `@()` guards.
- **Node.js 20 deprecation warning**: bumped `actions/upload-artifact@v4` -> `@v6` in `Step.0_authentication-test.yml` (every other Step YAML was already on `@v6`).

### Step.2 UpdateRing tag-management UX fixes (v0.8.6)

- **Per-cluster `Message` now names the tags that actually changed.** When only a schedule tag (e.g. `UpdateExcluded`) differs between the cluster and the CSV, the success message previously read "UpdateRing tag updated successfully" - misleading because the `UpdateRing` value was unchanged. `Set-AzLocalClusterUpdateRingTag` now computes per-tag deltas (`$tagsToMerge.Keys` vs `$currentTags`) and writes a message of the form `Tags updated: UpdateExcluded: 'False' -> 'True'`. Falls back to the legacy phrasing only when the delta list is empty (e.g. dry-run paths). Same delta list also drives the `-WhatIf` message.
- **Per-cluster table split into outcome buckets in the GitHub Actions / Azure DevOps step summary.** `Set-AzLocalClusterUpdateRingTagFromCsv` previously rendered every cluster (created, updated, no-op, skipped, failed) into one `<details>` block titled "Per-cluster results (N rows)". On a 44-cluster fleet where only one cluster actually changed (e.g. a single `UpdateExcluded` flip on Seattle), the operator had to scroll through 43 steady-state rows to find the one row that mattered. The summary now renders three independent collapsible sections, each shown only when non-empty:
  - **Clusters with Tag Updates Applied (N rows)** - `Status=Success` or `Status=WhatIf`. Defaults to expanded.
  - **Clusters Skipped or Failed (N rows)** - `Status=Skipped` or `Status=Failed`. Defaults to expanded.
  - **Clusters with No Tag Updates (no-op) (N rows)** - `Status=AlreadyInSync`. Defaults to collapsed.
- **Total clusters processed count fixed (`44` vs `20` on a 20-row CSV).** `Set-AzLocalClusterUpdateRingTag` ended with `$results | Format-Table ... -AutoSize` (no `| Out-Host`), so the formatter wrapper objects (header / row / footer) leaked into the function's pipeline output and mixed with `return $results` under `-PassThru`. The caller's `$results = @(Set-AzLocalClusterUpdateRingTag @applyParams)` then captured ~1.2x as many objects as real cluster rows, inflating Step.2's `Total clusters processed` line (and the `Per-cluster results (N rows)` header) on every run. Fixed by piping Format-Table to `Out-Host`, plus a defence-in-depth filter in `Set-AzLocalClusterUpdateRingTagFromCsv` that drops any object without a string `ClusterName` property before tallying.
- **Pester guards added** for the new split markdown (asserts both bucket headers render with their per-bucket row counts), for the per-tag delta message (static-source assert that `Set-AzLocalClusterUpdateRingTag` builds a `$tagDeltas` list from `$tagsToMerge.Keys` and emits a `Tags <action>: ` prefix), and for the Format-Table `Out-Host` route (regex-asserts `Format-Table ... -AutoSize | Out-Host` is present so the formatter-object leak cannot reappear).

### New Pester regression guards (catch the bugs the v0.8.5 ship missed)

- **`v0.8.6 regression guard: @() wrap on unary-comma return helpers`** (4 It blocks, one per helper) - static scan of every Public/Private `.ps1` file looking for `@(\s*<Helper>\b` patterns. Zero tolerance: any future caller that re-introduces the row-collapse anti-pattern fails the suite. Helpers covered: `Invoke-AzResourceGraphQuery`, `Get-AzLocalFleetHealthFailures`, `Get-AzLocalFleetHealthOverview`, `Read-AzLocalApplyUpdatesYamlCrons`.
- **`v0.8.6 regression guard: Step.3 Test-AzLocalApplyUpdatesScheduleCoverage MatchingCrons strict-mode crash`** - asserts the fixed source uses explicit `$segmentStatuses | ForEach-Object { $_.MatchingCrons }` enumeration (NOT array-level member-access) AND retains the `$segmentStatuses.Count -gt 0` guard.
- **`v0.8.6 regression guard: Step.4 ARB strict-mode .Count crash on single-cluster RG`** - asserts the fixed source uses an explicit `if ($clustersByRg.ContainsKey($rg)) { $matched = @($clustersByRg[$rg]) } else { $matched = @() }` branch (because `@($null)` yields `Object[1]` containing `$null`, NOT an empty array). Blocks both the insufficient v0.8.6-fix1 `[object[]]$matched = if (...)` cast AND the v0.8.6-fix2 `$matchedList = ... else { $null }` pattern.
- **`v0.8.6 regression guard: Step.6 Get-AzLocalClusterUpdateReadiness $cluster.NotFound strict-mode crash`** - parses every `$clustersToProcess += @{ ... }` literal in the source and asserts each one defines a `NotFound` key. Catches future builder paths that forget the field.
- **`v0.8.6 regression guard: Step.0 Export-AzLocalAuthValidationReport defensive @() coerce on $clusterRows`** - asserts the source contains `$clusterRows = @($clusterRows)` after the ARG call so `.Count` is always a valid integer property even when callers mock with a single object.
- **`v0.8.6 regression guard: GitHub Actions Node.js 20 deprecation`** (2 It blocks) - scans every bundled GHA YAML for `actions/upload-artifact@v[1-4]` and `actions/download-artifact@v[1-3]`. Zero tolerance: any future YAML that pins a Node-20 action fails.
- **`v0.8.6 functional regression: Export-AzLocalAuthValidationReport preserves all cluster rows from unary-comma helper`** and the matching block for `Export-AzLocalFleetHealthStatusReport` - source-shape asserts on the fixed assignment lines so a regex regression in the production cmdlet is caught immediately.

### New optional columns on `Get-AzLocalApplyUpdatesScheduleCycleCalendar -AsMarkdown`

- **`-CronFiringsByDate <hashtable>`**: a `@{ 'yyyy-MM-dd' = @('HH:mm', ...) }` map of pre-computed UTC firing times. When supplied, a centered "Ring CRON Start Time<br>(Step 6 pipeline)" column is inserted immediately after "Date (UTC)". Cell renders up to 2 times verbatim; any additional firings collapse into a `(+N)` suffix (e.g. `02:00, 04:00 (+1)` for three firings). Days with no entry render `_(none)_`; dead days render `_(none - dead day)_`.
- **`-WindowMatchByRingAndDate <hashtable>`**: a nested `@{ '<ring>' = @{ 'yyyy-MM-dd' = @{ Matching = <int>; Total = <int>; Pct = <0..1?> } } }` map. When supplied, a "Tag Start Window Match (>=95%)" column is inserted immediately after "Eligible rings". For multi-ring days the cell shows a per-ring breakdown joined by `; ` (e.g. `` `Cdn`: True 29/30 (97%); `Prod`: False 1/40 (3%) ``). True iff `Matching / Total >= 0.95`; rings absent from the dict on a date render `_(n/a)_`; `Total == 0` renders `_(0 clusters)_`.
- **Pure render-time contract preserved**: `Get-AzLocalApplyUpdatesScheduleCycleCalendar` still does zero Azure / file I/O. Both columns are opt-in - omit either or both params and the v0.8.5 column layout is bit-identical.
- **Compose freely**: `-ClusterRingCounts`, `-CronFiringsByDate`, and `-WindowMatchByRingAndDate` can be supplied independently or together (all three coexist, in the canonical header order documented above).

### Auto-wiring in `Export-AzLocalApplyUpdatesScheduleAudit`

- After running the audit / matrix / recommend views, the Step.3 thin-YAML wrapper now builds both dictionaries from data it already has on hand and forwards them into the cycle calendar:
  - **`$cronFiringsByDate`** projected from the Step.6 cron triggers via `Read-AzLocalApplyUpdatesYamlCrons -Path $PipelineYamlPath` + `ConvertFrom-AzLocalCronExpression`; unparseable / complex crons are silently skipped (Write-Verbose) so a single malformed entry does not break the calendar.
  - **`$windowMatchByRingAndDate`** computed only when `-ClusterCsvPath` is also supplied: the CSV is grouped by `UpdateRing` (case-insensitive), each cluster's `UpdateStartWindow` tag is parsed via `ConvertFrom-AzLocalUpdateWindow`, and a cluster counts as "matching" on a given (ring, date) pair if ANY of its window segments covers at least one cron firing on that date. Overnight windows (e.g. `Mon-Fri_22:00-06:00`) correctly count the spillover into the following day.
- **Failure mode is non-fatal**: any error in the enrichment block degrades gracefully to a calendar without the new columns (matching v0.8.5 behaviour); a `Write-Warning` surfaces the cause but the Step.3 summary continues to render.

### Tests

- 12 new It blocks under `Describe 'v0.8.6 Apply-Updates Schedule: Get-AzLocalApplyUpdatesScheduleCycleCalendar - CronFiringsByDate and WindowMatchByRingAndDate columns (markdown)'` cover: backwards compat (no new params -> v0.8.5 5-column header preserved), single-param paths (cron-only / match-only), both-params path with 7-column header, `(+N)` suffix at 3+ firings, `_(none)_` cell when a date has no entry, 95% threshold boundary (95/100 -> True, 94/100 -> False), `_(0 clusters)_` rendering at Total=0, `_(n/a)_` rendering when a ring has no entry on a date, case-insensitivity on both ring keys and date keys, and three-optional-columns coexistence with `-ClusterRingCounts`.
- 2 new integration It blocks appended to `Describe 'Thin-YAML Step.3: Export-AzLocalApplyUpdatesScheduleAudit'` verify the Export wrapper actually forwards `-CronFiringsByDate` when given a real `Step.6_apply-updates.yml` with cron triggers, and additionally forwards `-WindowMatchByRingAndDate` when a `-ClusterCsvPath` is supplied alongside.

## [0.8.5] - 2026-06-09

Step.3 cycle-calendar refactor + regression fix release, followed by a **full thin-YAML port of all 10 Step pipelines** (GitHub Actions + Azure DevOps - 20 YAML files in total). Adds 15 new Public cmdlets (1 in the original 0.8.5 plus 14 over the thin-YAML port) and two new Step.6 manual-run inputs that let an operator trigger apply-updates by hand BUT resolve UpdateRing + AllowedUpdateVersions from `apply-updates-schedule.yml` exactly as a scheduled run would. No public API removed; no parameter changes on existing cmdlets. The v0.8.4 cycle-calendar silent-drop bug in `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` is fixed at the architectural level (decoupled from the advisor's findings gate). **Total module export count grows from 35 (v0.8.4) to 55 (v0.8.5).**

### Thin-YAML refactor across all 10 Step pipelines (Step.0 - Step.9)

- **Goal**: condense the multi-hundred-line `run: |` PowerShell blocks that were duplicated between each Step's GitHub Actions YAML and Azure DevOps YAML into a single Public cmdlet that both pipelines invoke. Zero UI / outcome delta - step output names, artifact contents, JUnit XML, markdown summaries, exit codes, error messages, and stageDependencies bindings all preserved byte-for-byte.
- **14 new Public cmdlets added** (one per Step plus shared helpers):
  - `Add-AzLocalPipelineVersionBanner` (shared) - emits the install-time drift banner used by every Step's install step.
  - `Export-AzLocalAuthValidationReport` (Step.0) - + shared `New-AzLocalPipelineJUnitXml` helper.
  - `Invoke-AzLocalClusterInventory` (Step.1).
  - `Set-AzLocalClusterUpdateRingTagFromCsv` (Step.2).
  - `Export-AzLocalApplyUpdatesScheduleAudit` (Step.3).
  - `Export-AzLocalFleetConnectivityStatusReport` (Step.4).
  - `Export-AzLocalClusterUpdateReadinessReport` (Step.5).
  - **6 Step.6 cmdlets** (apply-updates is the largest pipeline): `Resolve-AzLocalPipelineUpdateRing`, `Export-AzLocalClusterReadinessGateReport`, `Invoke-AzLocalReadinessGatedClusterUpdate`, `Add-AzLocalApplyUpdatesStepSummary`, `Add-AzLocalNoReadyClustersStepSummary`, `Invoke-AzLocalItsmTicketingFromArtifact`.
  - `Export-AzLocalUpdateRunMonitorReport` (Step.7).
  - `Export-AzLocalFleetUpdateStatusReport` (Step.8).
  - `Export-AzLocalFleetHealthStatusReport` (Step.9).
- **Per-host step-output naming** is owned by the cmdlet, not the YAML. GitHub Actions consumes `UPPER_SNAKE` names (e.g. `READY_COUNT`); Azure DevOps consumes `PascalCase` names (e.g. `ReadyCount`) for stageDependencies `outputs['readiness.ReadyCount']` bindings. Each cmdlet auto-detects the host (`$env:TF_BUILD` / `$env:GITHUB_ACTIONS`) and emits the correct naming convention.
- **Per-host icon style** is owned by the cmdlet: Unicode emoji on GitHub markdown summaries, GitHub-Markdown shortcodes (`:white_check_mark:` etc.) on Azure DevOps summaries.
- **Cumulative YAML reduction** across the 20 templates: approximately **9,000 lines** removed from `Automation-Pipeline-Examples/`. Step.6 alone: GitHub Actions 964 -> 480 lines (-484); Azure DevOps 985 -> 440 lines (-545).
- **Why this matters** for ongoing maintenance:
  - **Single source of truth.** Logic previously duplicated between GitHub Actions YAML and Azure DevOps YAML now lives in one place. A bug fix or feature lands in the cmdlet and immediately benefits both platforms.
  - **Unit-testable.** The new Public cmdlets are mocked + asserted in Pester (`Tests/AzLocal.UpdateManagement.Tests.ps1`). Previously, validating an inline `run: |` block required spinning up a pipeline run or hand-running a copy-paste of the block in PowerShell.
  - **Faster CI signal.** A typo or contract change is caught by the local Pester run (~5 minutes) instead of waiting for a pipeline run + artifact inspection on Azure.
  - **Cleaner diffs.** YAML reviewers see "one step calls one cmdlet" instead of 300 lines of inline PowerShell; reviewers can focus on YAML wiring (triggers, env, artifacts, OIDC) while cmdlet behaviour is reviewed under the unit tests.
  - **Discoverability.** Operators running the module interactively now have a documented `Get-Help <verb>-AzLocal*` for what was previously trapped inside a YAML `run:` block.
  - **Re-usable building blocks.** `Add-AzLocalPipelineVersionBanner`, `Set-AzLocalPipelineOutput`, `Add-AzLocalPipelineStepSummary`, `Write-AzLocalPipelineWarning`, `New-AzLocalPipelineJUnitXml` are shared across every Step cmdlet - the next pipeline doesn't re-invent host-detection, step-output emission, JUnit framing, or markdown rendering.
- **One semantically-significant fix shaken out during testing**: `Invoke-AzLocalReadinessGatedClusterUpdate`'s seven-counter emitter was originally defined as `$emitCounters = { ... }.GetNewClosure()`. `.GetNewClosure()` rebinds the scriptblock to the CALLER's SessionState - which makes Private (non-exported) module functions invisible from inside the closure. Removing `.GetNewClosure()` (lexical scoping already gives the inline scriptblock access to the surrounding `$n*` variables when invoked via `& $emitCounters` from the same function) restored access to the private `Set-AzLocalPipelineOutput` function. Pester regression guards are now in place for both GH and ADO short-circuit paths.
- **Pester suite growth**: ~190 new It blocks across the 14 new cmdlets (parameter shape + per-host short-circuit + host-aware naming + error-path guards). Full local suite: **1069 passed, 0 failed, 1 skipped, ~4m38s**. Function-count drift test bumped from 35 -> 55 in two sites.
- **Backwards compatibility**: every Step pipeline keeps its filename, name field, trigger block (cron / workflow_dispatch / schedules / parameters), env block, concurrency block, OIDC login + Option 2 commented block, action-version pins, step IDs, artifact names, ITSM markers, and per-host step-output naming. Consumer pipelines that were running v0.8.4 YAML against v0.8.4 module continue to work against v0.8.5 module (the install-time drift banner surfaces the version skew but does not block).

### New Step.6 manual schedule-file inputs (`use_schedule_file` / `useScheduleFile` + `resolve_for_date_utc` / `resolveForDateUtc`)

- **Problem**: in v0.8.4 and earlier, a manual `workflow_dispatch` / "Run pipeline" of Step.6 ALWAYS used the operator's `update_ring` / `updateRing` parameter verbatim and ignored `apply-updates-schedule.yml`. Operators wanting to (a) test a schedule change before the next scheduled tick, (b) re-run a missed scheduled day, or (c) preview a future cycleWeek/dayOfWeek had no clean way to do so - they had to hand-mirror what the resolver would have picked.
- **Fix - GH `workflow_dispatch.inputs`**:
  - `use_schedule_file` (choice `'false'`/`'true'`, default `'false'`) - "Resolve UpdateRing & AllowedUpdateVersions from apply-updates-schedule.yml (as a scheduled run would). Overrides update_ring."
  - `resolve_for_date_utc` (string, default `''`, format `YYYY-MM-DD`) - "Only used when use_schedule_file=true. Date (UTC) to resolve the schedule for. Empty = today UTC. Useful for previewing a future cycleWeek/dayOfWeek."
  - `update_ring` is no longer `required: true` - either supply it, OR set `use_schedule_file=true`. The resolver throws a helpful error if BOTH are empty.
- **Fix - ADO `parameters`**: symmetric `useScheduleFile` (boolean, default `false`) and `resolveForDateUtc` (string, default `''`) parameters, with the same 4-branch resolver decision tree in `resolveRing`.
- **Resolver decision tree (both platforms)**:
  1. Manual trigger + `use_schedule_file=false` -> use manual ring verbatim (back-compat, identical to v0.8.4).
  2. Manual trigger + `use_schedule_file=true` -> read schedule file, run `Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $resolveAt` for today UTC (or `resolve_for_date_utc` when set). Uses ring + AllowedUpdateVersions exactly as a scheduled run would.
  3. Manual trigger + `use_schedule_file=false` + `update_ring` empty -> throw with remediation pointing at both alternatives.
  4. Scheduled trigger -> unchanged (reads schedule for UTC now).
- **`resolve_for_date_utc` parsing**: `[datetime]::ParseExact` against `'yyyy-MM-dd'` with `AssumeUniversal | AdjustToUniversal` so the date is treated as UTC regardless of agent timezone. Invalid format throws a helpful error.
- **No change to scheduled runs**: scheduled `cron:` / `schedules:` firings still resolve via the schedule file for the current UTC moment (path 4) - no behaviour change.
- **Pester guard**: 12 new It blocks under `Context 'v0.8.5 Step.6 manual schedule-file input'` cover both GH and ADO yml: new input declarations, `update_ring` no longer required, resolver script env-var wiring, `-Now $resolveAt` plumbing through to `Resolve-AzLocalCurrentUpdateRing`, the both-empty throw, and the `yyyy-MM-dd` parsing + invalid-format throw.

### New Public cmdlet `Get-AzLocalApplyUpdatesScheduleCycleCalendar`

- **Projects an `apply-updates-schedule.yml` configuration forward across the calendar** - one row per UTC day - and emits either a structured object pipeline (default) or a fully-rendered markdown block (`-AsMarkdown`).
- **Parameters**:
  - `-Schedule <PSCustomObject>` (mandatory) - pre-loaded schedule object (the same `$scheduleCfg` Test-...Coverage already builds via `Get-AzLocalApplyUpdatesSchedule`).
  - `-StartDate <datetime>` - default UTC today.
  - `-Days <int>` - default = `CycleWeeks * 7` (one full cycle). ValidateRange 1-3650.
  - `-AsMarkdown` - switch. Without it: object pipeline. With it: full markdown block including `## Cycle calendar - next N day(s) (one full N-week cycle)` heading + per-day table + optional `### Per-ring projection` section.
  - `-IncludePerRingSummary` - switch. Adds a per-ring projection table after the per-day calendar (next eligible UTC date per ring + all eligible dates inside the horizon).
  - `-ClusterRingCounts <hashtable>` - case-insensitive map (`@{ Std='5'; Canary='3'; Prod='12' }`-shape). When supplied, the per-day table gains a 6th column `Clusters in ring(s)` (e.g. `3+12 (total: 15)` for UNION rows, `5` for single-ring days, blank for dead days), and the per-ring projection table gains a `Cluster count` column.
- **Object output (per day)**: `DateUtc, DayOfWeekName, CycleWeek, CycleWeeksTotal, CycleWeekLabel, IsCycleWrap, Rings, UpdateRingValue, AllowedUpdateVersions, AllowedUpdateVersionsValue, AllowedUpdateVersionsSource, MatchedRowCount, IsDeadDay, Reason`. `Rings` is the UNION of all matching schedule rows for that day (deduplicated, `OrdinalIgnoreCase`). `IsCycleWrap=$true` on the day where `prev CycleWeek = CycleWeeksTotal` AND `current CycleWeek = 1`.
- **Re-uses `Resolve-AzLocalCurrentUpdateRing` per-day** so cycle-week math, UNION semantics, and AllowedUpdateVersions precedence remain identical to runtime - no duplicate ISO-8601 / week-arithmetic logic to drift away from the resolver.
- **Variable cycle length safe** (4 / 8 / 52 weeks all tested via Pester) and **year-boundary safe** (W52 -> W1 wrap on the cycle-anchor week is correctly annotated; W53 years projected correctly).
- **Defensive**: throws when `Schedule.CycleWeeks` is 0 or missing.

### Regression fix: v0.8.4 cycle calendar silently dropped on healthy fleets

- **Symptom**: in v0.8.4, Step.3 GH/ADO Summary on a fleet with zero advisor findings did NOT include the cycle-calendar table even though `-SchedulePath` was supplied.
- **Root cause**: the v0.8.4 Enhancement B cycle-calendar block lived inside `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend`'s snippet builder, AFTER the "any findings?" gate. When there were no findings, the `$fullSb` snippet was empty, and the Step.3 yml `if ($hasIssues -and $reco)` / `if (-not $hasIssues -and $reco)` branches at lines 503/630 both fire only when `$reco` is non-empty - so the calendar quietly disappeared on healthy fleets.
- **Fix**: the new cmdlet is invoked unconditionally whenever `$scheduleCfg` is parsed, so `$reco` is never empty when `-SchedulePath` is supplied - one of the two existing yml branches always fires. NO structural Step.3 yml change required beyond the version bump.
- **Regression guard**: new Pester test `REGRESSION: -AsMarkdown returns the calendar even when the fleet has zero findings (v0.8.4 silent-drop bug)` asserts the markdown is non-empty and contains the `## Cycle calendar` heading even when the fleet input is empty.

### `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` Enhancement B now delegates to the new cmdlet

- The v0.8.4 inline cycle-calendar block (~37 lines, lines 931-967) in `Test-AzLocalApplyUpdatesScheduleCoverage.ps1` is replaced by a single call: `Get-AzLocalApplyUpdatesScheduleCycleCalendar -Schedule $scheduleCfg -AsMarkdown -IncludePerRingSummary -ClusterRingCounts $ringCountMap`. Wrapped in `try { ... } catch { ... }` with a `_Cycle calendar unavailable: $($_.Exception.Message)_` fallback line so a malformed schedule on a single fleet doesn't break Step.3 for the whole job.
- `$ringCountMap` is built from the live tagged `$clusters` (already in scope from the earlier ARG query) - iterates each `$c.UpdateRing.Trim()` and increments the map. The cmdlet itself stays pure (no CSV / Azure I/O) so it remains unit-testable from a synthetic schedule object.

### New: per-ring projection section (`-IncludePerRingSummary`)

- Renders a `### Per-ring projection` section after the per-day table. One row per ring with: ring name, next eligible UTC date inside the horizon (or `(none)`), all eligible UTC dates inside the horizon (comma-separated, first 10 + `+N more` for very long lists), and `Cluster count` (when `-ClusterRingCounts` is supplied).
- Step.3 yml passes `-IncludePerRingSummary` so the section always appears on healthy fleets.

### Pester suite updates

- `Module: AzLocal.UpdateManagement / Module Load / Should have version` drift test bumped to `'0.8.5'`.
- New drift assertion asserts `Get-AzLocalApplyUpdatesScheduleCycleCalendar` is present in `FunctionsToExport`.
- Two new Describe blocks (`v0.8.5 ... (object pipeline)` + `v0.8.5 ... (markdown)`) under `#region v0.8.5: Get-AzLocalApplyUpdatesScheduleCycleCalendar` cover ~28 It blocks:
  - **Object pipeline** (11): default `Days` math, row shape, `CycleWeeksTotal` invariant, day-0 resolution, `IsDeadDay` on no-match, UNION semantics on multi-row Friday, `IsCycleWrap` on `W8 -> W1` rollover, 52-week cycle 364 rows + year boundary, 8-week cycle with wrap, multi-cycle horizon, defensive `CycleWeeks=0` throw.
  - **Markdown** (~17): output type `[string]`, `## Cycle calendar` heading present, 5-column header (no `-ClusterRingCounts`), 6-column header (with `-ClusterRingCounts`), regression guard for v0.8.4 silent-drop, `### Per-ring projection` section structure, UNION row rendering, ClusterRingCounts column variants (single ring, multi-ring `(total: N)`, case-insensitive key match, dead-day blank), cycle-wrap `_(cycle wraps)_` annotation, year-boundary safe with 1-week cycle.
- Expected baseline shift: 882 / 0 / 1 (pre) -> ~910 / 0 / 1 (post).

### Version pin bumped across all 20 bundled `Step.{0..9}.yml` templates

- `GENERATED_AGAINST_MODULE_VERSION` moves from `0.8.4` to `0.8.5` across all 20 bundled `Step.{0..9}.yml` files (10 GitHub Actions + 10 Azure DevOps). The install-step drift annotation continues to surface stale YAML to operators.
- `$script:ModuleVersion` (psm1) == `ModuleVersion` (psd1) == `'0.8.5'` (test assertion); the drift guard introduced in v0.7.67 enforces this.

## [0.8.4] - 2026-06-18

Step.3 advisor enhancement release. No public API removed; one new optional parameter on `Test-AzLocalApplyUpdatesScheduleCoverage` (`-ClusterCsvPath`); three new Recommend-view sections that render when their respective inputs are supplied. All v0.8.3 behaviour preserved unchanged.

### `Test-AzLocalApplyUpdatesScheduleCoverage` - Enhancement A: NoWindowTag CSV-driven remediation (new `-ClusterCsvPath` parameter)

- **New optional parameter `-ClusterCsvPath <path>`** points at the source-controlled cluster inventory CSV (the file Step.2 consumes - default `config/ClusterUpdateRings.csv`). When supplied, `-View Recommend` emits a new `## Action required - NoWindowTag remediation` section.
- **For each cluster with an `UpdateRing` tag but no `UpdateStartWindow` tag**, the advisor proposes a peer-derived `UpdateStartWindow` value: it groups peers (other clusters in the same `UpdateRing`) by their `UpdateStartWindow` value, picks the mode, and emits a source label explaining the choice. Four cases:
  - **No peers** (cluster is first of its ring): `No other cluster carries UpdateRing=X; pick a value matching your maintenance policy`.
  - **Sole peer**: `Only peer in X (ClusterY) uses this value`.
  - **Unanimous N peers**: `All N peer(s) in X use this value (clusterA, clusterB, ...)`.
  - **Mixed M of N peers**: `M of N peer(s) in X use 'Mon-Fri_22:00-06:00'. Alternatives: 'Sat-Sun_08:00-20:00' (2)`.
- **CSV lookup is keyed on `ResourceId` first, with a `ClusterName + ResourceGroup` fallback** for older CSVs that pre-date the `ResourceId` column. Lookups are `OrdinalIgnoreCase`. Three CSV outcomes:
  - **Found by `ResourceId`**: tells the operator to edit the `UpdateStartWindow` cell on that row.
  - **Found by `ClusterName + ResourceGroup`**: same fix instruction + nudge to re-run Step.1 to regenerate the CSV with a `ResourceId` column for unambiguous matching.
  - **Not in CSV**: tells the operator to re-run Step.1 to regenerate the cluster inventory artifact, unzip it, and replace the source-controlled CSV with the artifact's CSV. The new row will appear with a blank `UpdateStartWindow` cell - fill it in with the suggested value above, commit, and re-run Step.2.
- **ARG query also projects `UpdateExclusionsWindow`** (additional `tostring(tags['UpdateExclusionsWindow'])` column) so Enhancement C below has data to render.

### `Test-AzLocalApplyUpdatesScheduleCoverage` - Enhancement B: Cycle calendar (informational, auto-renders when `-SchedulePath` supplied)

- **New `## Cycle calendar - next N day(s)` section** renders one row per UTC day for one full cycle (`CycleWeeks * 7` days starting today). Each row shows Date (UTC), Day-of-week, CycleWeek (`X of N`, with **`1` of N _(cycle wraps)_** annotation on the wrap row), Eligible rings (UNION of all matching schedule rows, deduplicated), and effective `AllowedUpdateVersions` (or `_(no constraint)_` when empty).
- **Re-uses `Resolve-AzLocalCurrentUpdateRing` per-day** so cycle-week math, UNION semantics, and AllowedUpdateVersions precedence are identical to runtime - no duplicate ISO-8601 / week-arithmetic logic that could drift away from the resolver.
- **Use cases**: verify ring coverage matches your maintenance policy; spot dead days where no ring is eligible (often a sign that a schedule row was deleted by mistake); preview the AllowedUpdateVersions pin a Prod ring will see on a specific date; understand exactly when the cycle wraps so you can align your customer-comms calendar.

### `Test-AzLocalApplyUpdatesScheduleCoverage` - Enhancement C: Configured exclusion windows summary (informational, auto-renders when any cluster has a non-empty `UpdateExclusionsWindow` tag)

- **New `## Configured exclusion windows (UpdateExclusionsWindow tag)` section** groups tagged clusters by `(UpdateRing, UpdateExclusionsWindow)` and renders a rollup table (cluster count + first 10 cluster names + `+N more`).
- **Plus a per-ring breakdown of clusters that have NO `UpdateExclusionsWindow` tag** so operators can spot drift where some clusters in a ring have a holiday blackout configured (e.g. `2025-12-10/2026-01-06`) and others do not.

### Step.3 GH + ADO yml updates

- **New `cluster_csv_path` / `clusterCsvPath` input** (default `config/ClusterUpdateRings.csv`). Validates the file exists at job time - missing file skips Enhancement A quietly (vs throwing) so repos that don't version-control a cluster CSV yet keep getting the legacy advisor output.
- **Both yml templates now also pass `-SchedulePath` to the `-View Recommend` invocation** so Enhancements B+C render in the Step Summary. Pre-v0.8.4 the Recommend call only passed `-PipelineYamlPath`, which meant the cmdlet could not render the cycle calendar or exclusion-windows sections even though `-SchedulePath` was already validated for the Audit invocation in the same job.
- **Banner line** added: `ClusterCsvPath   : ...` (or `(skipped - cluster_csv_path empty or file missing)`).

### Pester tests updated

- `Module: AzLocal.UpdateManagement / Module Load / Should have version` drift test bumped to `0.8.4`.
- New It blocks under `Function: Test-AzLocalApplyUpdatesScheduleCoverage` covering ResourceId lookup, ClusterName+ResourceGroup fallback, not-found "re-run Step.1" messaging, peer-derivation modes (unanimous / majority / sole peer / no peers), cycle-calendar math at year boundary + cycle-wrap rendering + UNION row rendering, and exclusion-windows rollup grouping.
- New drift tests asserting the `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24` opt-in is present in all 10 GitHub Actions yml; the `Pipeline YAML v` banner string is present in all 10 GH install steps and emits exactly once per ADO yml to the Build Summary (Step.6 ADO has 2 install steps but the second deliberately skips `##vso[task.uploadsummary]` to avoid duplicating the banner; total = 10 ADO Summary emits); the `### Cluster Actions` and `### Clusters Skipped at Readiness Gate` headers are present in the Step.6 Summary on both platforms; the new RBAC role display name `Azure Stack HCI Update Operator (custom)` is present in the bundled JSON, `Automation-Pipeline-Examples/README.md`, and `docs/rbac.md`; and the bare pre-v0.8.4 name no longer appears in any currently-shipping doc (CHANGELOG and `docs/release-history.md` are excluded - they describe past releases).

### Step.6 Enhancement D - per-cluster Step Summary in `apply-updates` (GitHub Actions + Azure DevOps)

- **`apply-updates` step now persists `apply-results.json`** to the artifact-staging dir (`./artifacts/` on GH, `$(Build.ArtifactStagingDirectory)` on ADO). Selects `ClusterName, Status, UpdateName, Duration, Message` from `Start-AzLocalClusterUpdate -PassThru` and writes UTF-8 JSON; the downstream Summary step reads it without depending on the (truncated, JSON-unfriendly) GHA step-output / ADO task-output variable stream.
- **`### Cluster Actions` per-cluster table** appended to the Step Summary on both platforms - one row per cluster handed to apply, with icon + Status + `UpdateName` + `Duration` + `Message` (truncated to 180 chars, pipes escaped, newlines folded). Sorted by Status then ClusterName. Icons: white-check-mark for Started/Success states, X for Failed/Error/NotFound, no-entry for *Blocked / NotConnected, next-track for any other Skipped/NotInAllowList outcome.
- **`### Clusters Skipped at Readiness Gate` per-cluster table** appended to the Summary on both platforms - one row per cluster filtered out by Step.6 check-readiness (`ReadyForUpdate != 'True'`). Reads `readiness-report.csv` written by the CheckReadiness stage. Surfaces Cluster, UpdateState, Health (icon + state), CurrentVersion, RecommendedUpdate, BlockingReasons. Caps at first 100 rows for very large fleets and emits a "Showing first 100 of N" footer pointing operators at the full CSV artifact.
- **Why this matters**: pre-v0.8.4 the Step.6 Summary surfaced only fleet-level counts (Succeeded / Skipped / Failed / *Blocked). For a 20+ cluster fleet, identifying which specific cluster failed or which clusters were schedule-blocked required downloading the JUnit artifact and parsing it. Enhancement D puts the per-cluster verdict directly in the Run/Build Summary that operators already open first.

### Node.js 24 opt-in across all 10 GitHub Actions yml

- **`FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true`** added to the workflow-level `env:` block of all 10 bundled GitHub Actions templates. GitHub announced Node.js 20 deprecation for JavaScript actions; this opt-in tells the runner to execute all `actions/*@v*` JavaScript actions under Node 24 before the platform-wide migration date arrives. Zero-risk - the env var is an explicit opt-in mechanism documented by GitHub and is silently ignored on older runner images.
- **Why now**: lets early-adopter operators surface any per-action Node 24 incompatibility (test-reporter, upload-artifact, etc.) on a controlled timeline against the bundled examples, rather than every workflow flipping at GitHub's enforced cutover.

### Version banner appended to every install step (GitHub Actions + Azure DevOps)

- **`_Pipeline YAML v<generated> | Module v<installed> installed (<pin>) | PSGallery latest <latestStr> | <verdict>_`** is now appended to the Step Summary (GH) / Build Summary (ADO) by every install step across both platforms: one banner per yml across all 20 bundled `Step.{0..9}.yml` templates (Step.6 ADO has 2 install steps but the second deliberately skips `##vso[task.uploadsummary]` to avoid duplicating the banner). `<pin>` is `pinned to v...` when `REQUIRED_MODULE_VERSION` is set, or `latest (fix-forward)` when blank. `<verdict>` is one of `in sync` / `YAML newer than module - check REQUIRED_MODULE_VERSION` / `YAML older than module - run Copy-AzLocalPipelineExample -Update` / `newer module available on PSGallery`.
- **Persists across both rendered Summary surfaces** (`$env:GITHUB_STEP_SUMMARY` on GH; `##vso[task.uploadsummary]` on ADO) so operators see the version triple at a glance without scrolling agent output.
- **Why this matters**: pre-v0.8.4 the install step emitted version-drift warnings via `::notice` (GH) / `##vso[task.logissue]` (ADO) which surface in annotations / per-step logs but not in the cross-pipeline Summary view that fleet operators open first. The banner makes "what version actually ran" obvious from the Summary, eliminating "the YAML in my repo is too old" / "the module on PSGallery has a fix already" investigation lag.

### RBAC custom role renamed: `Azure Stack HCI Update Operator` -> `Azure Stack HCI Update Operator (custom)`

- **The `Name` field of the bundled `azlocal-update-management-custom-role.json` role definition** is renamed from `"Azure Stack HCI Update Operator"` to `"Azure Stack HCI Update Operator (custom)"`. Rationale: the `(custom)` suffix makes the role's customer-managed status obvious in the Azure portal **Custom roles** blade, in `az role definition list` output, and in any RBAC audit / governance tooling, and pre-empts any future collision with a Microsoft built-in of the same brand name.
- **The role's `Description` field** gains a preamble: *"Customer-managed custom role - reference by roleDefinitionId (GUID) in automation rather than by name to remain stable if Microsoft later ships a built-in role with a similar display name."* The existing capability description ("Can read and apply Azure Local cluster updates, manage UpdateRing tags, ...") is preserved verbatim after the preamble. `Actions[]`, `NotActions[]`, `DataActions[]`, `AssignableScopes[]` are byte-identical to v0.8.3.
- **Documentation updated in lockstep**: section header, TOC anchor, every `az role assignment create --role "..."`, every inline JSON block, every reference paragraph, and every cross-link anchor (`#31-custom-role-azure-stack-hci-update-operator-custom`) across `Automation-Pipeline-Examples/README.md` (23 name refs + 11 anchor refs), `Automation-Pipeline-Examples/docs/appendix-pipelines.md` (8 + 1), `docs/rbac.md` (10 name refs in 3 inline JSON blocks + section header + Azure portal nav path + assignment commands + DINE policy display name), and the top-level `README.md` permissions paragraph. `CHANGELOG.md` and `docs/release-history.md` historical entries for past releases are preserved verbatim (they describe what shipped at the time).
- **Migration tip (existing tenants - no downtime, GUID preserved)**: `az role definition update --role-definition ./azlocal-update-management-custom-role.json` performs an in-place rename. The role's GUID and every existing role assignment - users, security groups, service principals, managed identities, at any scope - are preserved unchanged; only the display name shown in Azure portal / `az role definition list` / `Get-AzRoleDefinition` changes. **Pipelines see zero downtime.** Do NOT reference the role by display name in `az role assignment create --role "..."` calls used by automation - reference by `roleDefinitionId` (the GUID) instead, which is stable across renames and avoids built-in vs custom display-name collisions (Azure resolves display-name lookups against built-in roles first).

### Version pin bumped across all 20 bundled `Step.{0..9}.yml` templates

- `GENERATED_AGAINST_MODULE_VERSION` moves from `0.8.3` to `0.8.4` across all 20 bundled `Step.{0..9}.yml` files (10 GitHub Actions + 10 Azure DevOps). The install step's drift annotation continues to surface stale YAML to operators.

## [0.8.3] - 2026-06-11

Step.3 advisor accuracy + readability fixes. No public API removed; one cmdlet behaviour change (Recommend now diff-prunes against an existing Step.6 yml when `-PipelineYamlPath` is supplied). Four operator-reported defects in the Step.3 `Test-AzLocalApplyUpdatesScheduleCoverage` output are addressed.

### `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` is now a true diff (not a re-emit of the full canonical block)

- **Recommend now drops any cron expression that already exists in `-PipelineYamlPath`.** Pre-v0.8.3 the Recommend snippet was built purely from cluster `UpdateStartWindow` tags + `Convert-AzLocalUpdateWindowToCron`, so on a fleet where Step.6 already contained the recommended crons (the steady state after running Step.3 once) the advisor re-emitted the same 8-10 cron lines under an "Action required - cron coverage" header. Operators read it as "Step.3 is telling me to add these again" and pasted duplicates. Now the cmdlet reads the supplied `-PipelineYamlPath`, parses the cron entries via the same `Read-AzLocalApplyUpdatesYamlCrons` helper as Audit uses, and prunes every recommended cron whose expression matches one already present. Only the truly missing crons land in the snippet. When no crons remain post-prune AND there are no other findings, the Recommend output is empty (no false-positive "Action required" header).
- **Step.3 GH + ADO yml now pass `-PipelineYamlPath` to the Recommend invocation.** Pre-v0.8.3 the `-View Recommend ... -ExportPath $recoMd` call was always made without `-PipelineYamlPath`, so even after the cmdlet supported the diff-prune the snippet would have been the un-pruned full set. Both Step.3 templates now build `$recoArgs` and pass `PipelineYamlPath = $pipelinePath` when supplied.
- **Pre-existing crons that the parser cannot reason about (`IsComplex` / `IsValid=$false`) are NOT considered "already present".** The Unparseable section asks the operator to rewrite those, and we do NOT want to silently assume they cover the same window as a recommended cron.

### Step.3 GH + ADO yml: `pipeline_path` / `pipelinePath` is now REQUIRED

- **GitHub Actions: `pipeline_path` input is now `required: true`** (default unchanged: `.github/workflows`). The schedule-only fall-through ("Leave empty to audit ONLY the schedule_path") is removed; an empty `pipeline_path` now throws with a clear error pointing to common pipeline folders that DO exist in the repo. Without this, the diff-prune above would have no Step.6 to diff against and every Recommend run would be a false positive.
- **Azure DevOps: `pipelinePath` parameter description now says REQUIRED** (ADO `parameters:` blocks have no `required:` keyword, so validation is at runtime). Same throw + same hint message as the GitHub side.
- **`schedule_path` / `schedulePath` stays optional** - it drives the ring-file two-way diff and is independent of the cron-coverage diff.

### Step.3 yml: `### How to fix - edit ``$schedulePath``` heading reframed

- The v0.8.2 Allow-list section emitted a sub-heading `### How to fix - edit ``$schedulePath``` whenever any schedule row inherited the top-level allow-list. Operators read this as "the fix for the higher-blast-radius cron-coverage or ring-diff sections is to edit `$schedulePath`", but it was only ever about the OPTIONAL `allowedUpdateVersions:` pin (e.g. keeping Prod on the latest feature drop only). The heading is now `### Optional - pin a ring to a specific update in ``$schedulePath``` and the body explicitly says *"This is NOT a fix for the cron-coverage or ring-diff sections above - those have their own 'Action required' blocks."*

### Step.3 yml: closing fence bug fix (markdown rendering)

- Both Step.3 templates had `$md += "``````n"` in two places (after the schema-v1 migrate snippet and after the `allowedUpdateVersions:` example yaml). In PowerShell double-quoted strings, six backticks = three literal backticks but the trailing `n` becomes a literal `n` (not a newline) because the backticks all pair up before reaching it. Result: the rendered markdown showed `` ``` `` followed by a literal `n` and the subsequent paragraphs got swept into the code block. Fixed to seven backticks + `n` (= three literal backticks + newline). Four sites total (GH x2, ADO x2).

### Pester tests updated

- `Module: AzLocal.UpdateManagement / Module Load / Should have version` bumped to `0.8.3`.
- `Step.3 pipeline scaffolds - v0.8.2 Allow-list section shape` Describe block updated to assert the new reframed heading (`### Optional - pin a ring to a specific update in ``$schedulePath```) and the disclaimer line, and to ASSERT-NOT the old v0.8.2 `### How to fix - edit ``$schedulePath``` shape.
- New Pester tests added under the existing `Function: Test-AzLocalApplyUpdatesScheduleCoverage` Describe block to cover the diff-prune behaviour (recommended cron pruned when already present in supplied Step.6 yml; full set emitted when `-PipelineYamlPath` is not supplied).

### Version pin bumped across all 20 bundled `Step.{0..9}.yml` templates

- `GENERATED_AGAINST_MODULE_VERSION` moves from `0.8.2` to `0.8.3` across all 20 bundled `Step.{0..9}.yml` files (10 GitHub Actions + 10 Azure DevOps). The install step's drift annotation continues to surface stale YAML to operators.
- `$script:ModuleVersion` (psm1) == `ModuleVersion` (psd1) == `'0.8.3'` (test assertion); the drift guard introduced in v0.7.67 enforces this.

## [0.8.2] - 2026-06-10

Operator-experience release for `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend`. No public API changes; no output-shape changes that break existing scripts. Two paste-time pain points reported on v0.8.1 are fixed in the advisor's emitted snippet, plus a trimmed Step.3 Allow-list section, a richer `NoWindowTag` recommendation, and five new internal helpers that lay the foundation for the upcoming executable-YAML refactor.

### `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` paste-time pain points fixed

- **"All cron times below are UTC" comment is now embedded inside both the GH and ADO snippets.** GitHub Actions and Azure DevOps both evaluate `cron:` in UTC regardless of repo / runner / agent timezone, but operators repeatedly burned time converting from a local-time mental model and ended up with windows that fired hours offset from their intent. The advisor now prepends a `# All cron times below are UTC ...` comment line directly above `schedule:` (GH) and `schedules:` (ADO) so the snippet is self-documenting once pasted into `Step.6_apply-updates.yml`.
- **"Indent tip" callout above the snippet warns about IDE auto-indent-on-paste.** The GH snippet is intentionally at 2-space indent (so `schedule:` is a sibling of the existing `workflow_dispatch:` under `on:`). When operators paste with the cursor sitting inside the `# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` / `# END-AZLOCAL-CUSTOMIZE:schedule-triggers` comment block, VS Code (and JetBrains IDEs) silently double the indent, producing the YAML error *"All mapping items must start at the same column"*. The advisor now emits a `> **Indent tip.**` blockquote directly above the snippet explaining the cause, instructing the operator to paste at column 0 of a fresh blank line so `schedule:` lines up with `workflow_dispatch:`, and telling them how to recover (delete two leading spaces from every pasted line) if they already hit it.

### `Test-AzLocalApplyUpdatesScheduleCoverage -View Audit` `NoWindowTag` row enrichment + reordering

- **`NoWindowTag` recommendation now names the affected clusters, grouped by `UpdateRing`.** Pre-v0.8.2 the row showed a generic *"Tag clusters with UpdateStartWindow=&lt;days&gt;_&lt;HH:MM&gt;-&lt;HH:MM&gt;"* nudge that left operators cross-referencing the matrix CSV to find the offenders. The advisor now lists the first 15 cluster names grouped by their `UpdateRing` tag (or `(none)` when both tags are missing), e.g. `Prod -> hci-syd-01, hci-syd-02; Wave1 -> hci-mel-01 (+3 more) (showing first 15 of 42)`, so the audit table is actionable on its own.
- **`NoWindowTag` row issue text clarified that the tag is optional.** The runtime gate `Test-AzLocalUpdateScheduleAllowed` only enforces a maintenance window WHEN the tag is set, so untagged clusters are not a blocker - they just have no enforced window. The clarified prose tells operators why this is "informational, not failure".
- **`NoWindowTag` sort order moved from rank 7 to rank 10** (i.e. AFTER `Covered`). Since the tag is optional, sorting these rows last keeps the table readable when the rest of the fleet is `Covered` and the operator only cares about gaps.

### Step.3 Allow-list section trimmed in both GH and ADO scaffolds

- **`Allow-list coverage (schema v2)` subsection no longer emits the verbose `> Tip - per-ring overrides` paragraph + 3-row example block** that v0.8.1 produced. Inheriting the top-level allow-list IS the expected steady state for most fleets (install Latest as soon as Ready); the verbose tip was misleading operators into thinking they had to add overrides.
- **New `### How to fix - edit \`$schedulePath\`` subsection** names the schedule file directly and explains that `allowedUpdateVersions:` overrides are only needed when an operator wants to PIN a ring to a specific update (e.g. keep Prod on the latest feature drop only - YY04 / YY10 - and skip cumulative updates between feature drops). Followed by a single-row YAML example.
- **6 new Pester assertions** lock in the new shape: both Step.3 scaffolds emit the trimmed one-liner and the `How to fix - edit $schedulePath` heading, AND do NOT emit `Tip - per-ring overrides` / `Showing first 3 of` (the verbose v0.8.1 markers).

### `Azure Stack HCI Update Operator` custom-role Description rewritten to drop module-internal jargon

- The custom-role Description shipped into the Azure RBAC plane (visible in the Azure portal **Custom roles** blade, in `az role definition list` / `Get-AzRoleDefinition` output, and in any RBAC audit/governance tooling) previously read *"...read the fleet-connectivity scopes (Arc machines, edge-device NICs, Azure Resource Bridges) required by Step.4"*. `Step.4` is a module-private concept and meaningless to anyone outside `AzLocal.UpdateManagement`.
- **New Description**: *"Can read and apply Azure Local cluster updates, manage UpdateRing tags, and read the fleet-connectivity inventory (Arc-enabled machines, edge-device NICs, Azure Resource Bridges) needed to assess pre-update connectivity."*
- **Same RBAC grant** - `Actions[]`, `NotActions[]`, `DataActions[]`, `AssignableScopes[]` are byte-identical. Operators with the role already deployed need no action; the next `az role definition update --role-definition ./azlocal-update-management-custom-role.json` will refresh the Description.
- **Updated in lockstep across all 6 sites** that ship/document the role: the bundled `Automation-Pipeline-Examples/azlocal-update-management-custom-role.json` file (consumed by `az role definition create`), the two inline JSON blocks in `Automation-Pipeline-Examples/README.md` section 4.1, and the three inline JSON blocks in `docs/rbac.md` (first JSON block + Option 2 here-string + management-group-scope variant).

### Module foundations for the upcoming executable-YAML refactor

- Five new internal (Private) helpers added: `Get-AzLocalPipelineHost`, `Set-AzLocalPipelineOutput`, `Add-AzLocalPipelineStepSummary`, `Write-AzLocalPipelineNotice`, `Write-AzLocalPipelineWarning`.
- They abstract over the host-specific quirks of GitHub Actions vs Azure DevOps output channels: `$env:GITHUB_OUTPUT` vs `##vso[task.setvariable]`, `$env:GITHUB_STEP_SUMMARY` vs `##vso[task.uploadsummary]`, `::notice/::warning` vs `##vso[task.logissue]`.
- Not exported. No user-visible effect in v0.8.2 - these are foundations for the upcoming per-Step `Export-*` / `Invoke-*` cmdlets that will move inline `run: |` PowerShell out of `Step.{0..9}.yml` and into the module proper.
- 23 new Pester assertions cover the three host modes (`GitHub` via `$env:GITHUB_ACTIONS='true'`, `AzureDevOps` via `$env:TF_BUILD='True'`, `Local` fallback when both unset; `GitHub` wins when both are set) and the byte-identical contracts of each emitted logging-command syntax.

### Migration

- `Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). No code changes required.
- Re-run `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` once to pick up the new self-documenting snippet (the cron *values* are unchanged from v0.8.1; only the surrounding comment and prose changed).

### Pin and version drift

- `GENERATED_AGAINST_MODULE_VERSION` moves from `0.8.1` to `0.8.2` across all 20 bundled `Step.{0..9}.yml` templates (GH Actions + Azure DevOps).
- Drift-sync test asserts `$script:ModuleVersion` (psm1) == `ModuleVersion` (psd1) == `Should -Be '0.8.2'` (test) - any drift fails CI.

## [0.8.1] - 2026-06-09

Docs-and-snippet correctness release. No public API or output-shape changes - existing scripts and pipelines continue to work without modification.

### `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` GH-Actions snippet is now copy-paste-safe into `Step.6_apply-updates.yml`

Pre-v0.8.1 the GitHub-flavoured `-View Recommend` snippet emitted a full `on:` + `workflow_dispatch:` + `schedule:` block and the prose instructed the operator to "Replace (or merge with) the existing `on:` block". `Step.6_apply-updates.yml` already declares `workflow_dispatch:` with a rich `inputs:` block (`update_ring`, `update_name`, `dry_run`, `raise_itsm_ticket`, `itsm_config_path`, `itsm_dry_run`, `itsm_force_create`, `module_version`) that the manual `Run workflow` button depends on. Operators who pasted the snippet alongside the existing block (rather than wholesale-replacing it - and losing the inputs) ended up with two top-level `workflow_dispatch:` keys, which GitHub Actions rejects at parse time with `'workflow_dispatch' is already defined`.

- The GH snippet now emits ONLY the `schedule:` block:
  ```yaml
    schedule:
      - cron: '0 22 * * 6'
      - cron: '0 22 * * 0'
  ```
  - 2-space `schedule:` indent + 4-space cron indent match the existing nesting inside the `# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` / `# END-AZLOCAL-CUSTOMIZE:schedule-triggers` markers in `Step.6_apply-updates.yml`. Paste it as-is - operators no longer need to hand-edit the snippet to fit.
- **Updated "How to fix" prose.** The advisory now says: *"Add (or merge with) the following `schedule:` block under the existing `on:` key. Place it inside the BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers markers so it survives `Update-AzLocalPipelineExample` refreshes. Do NOT add a second `workflow_dispatch:` line - Step.6 already declares one with the `update_ring` / `dry_run` / ITSM / `module_version` inputs that the manual Run workflow button needs."* Azure DevOps snippet shape (top-level `schedules:`) is unchanged.
- **Four updated `AS7`-`AS10` Pester assertions** in `Tests/AzLocal.UpdateManagement.Tests.ps1` swap the GH-snippet detector regex from `'workflow_dispatch'` to `'(?m)^\s*schedule:\s*$'`. The singular `schedule:` key on its own line is GH-Actions-unique (ADO uses the plural `schedules:` at column 0); the swap keeps the same auto-detect / `-Platform Both` override semantics in tests while reflecting that `workflow_dispatch` is no longer emitted by the snippet.

### Migration

- For cmdlet consumers: `Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). No code changes required.
- For operators who have ALREADY pasted the v0.8.0-flavoured snippet into `Step.6_apply-updates.yml` and seen the duplicate-key error:
  1. Either `Update-AzLocalPipelineExample -Destination <path>` to refresh Step.6 from the v0.8.1 template and then re-run `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` for the new snippet shape.
  2. Or manually delete the duplicate empty `workflow_dispatch:` line from Step.6.
- For consumers of the v0.8.0 cron-coverage advisor output: re-run the advisor once on v0.8.1 to pick up the new snippet (the cron *values* haven't changed; only the surrounding YAML structure).

### Pin and version drift

- `GENERATED_AGAINST_MODULE_VERSION` moves from `0.8.0` to `0.8.1` across all 20 bundled Step.*.yml templates (GH Actions + Azure DevOps).
- Drift-sync test asserts `$script:ModuleVersion` (psm1) == `ModuleVersion` (psd1) == `Should -Be '0.8.1'` (test) - any drift fails CI.

## [0.8.0] - 2026-06-09

Patch release rolling up three follow-ups to v0.7.99 plus Step.2 UX fixes. No public API changes. `Set-AzLocalClusterUpdateRingTag -PassThru` gains two new enum values (`Action='NoChange'` and `Status='AlreadyInSync'`) to distinguish steady-state clusters from genuinely-skipped ones; existing scripts that switch on `Created`/`Updated`/`Skipped`/`Failed` continue to work, with already-in-sync clusters surfacing under the new bucket rather than spurious `Skipped`.

### Step.2 manage-updatering-tags - operator-visible UX fixes

- **`Set-AzLocalClusterUpdateRingTag` no longer logs misleading "use -Force to overwrite" warnings on clusters that are already in the desired state.** The skip branch now splits on whether the existing `UpdateRing` tag matches the target:
  - **All managed tags already match** (`UpdateRing`, `UpdateStartWindow`, `UpdateExclusionsWindow`, `UpdateExcluded`) -> `Info` log "All managed tags already match desired state - no action needed". New `Action='NoChange'` / `Status='AlreadyInSync'` row in CSV log and `-PassThru` results.
  - **`UpdateRing` differs from target** AND no schedule diff -> still emits `Warning` + "Use -Force to overwrite" hint (unchanged from prior releases). Message clarified to name both values: `Existing UpdateRing tag (value: X) differs from target (Y).`
- **`-Force` now short-circuits when all managed tags already match desired state.** Saves a redundant ARM PATCH per cluster on already-clean fleets. Logged as `Action='NoChange' / Status='AlreadyInSync'` with message `All managed tags already match desired state; -Force PATCH skipped (no-op).` Behaviour when there IS something to change is unchanged.
- **Summary section gains an `Already in sync (no change needed):` line** alongside the existing Created/Updated/Skipped/Failed tallies. The `Skipped (existing tag, no -Force):` line is now correctly named `Skipped (UpdateRing differs, no -Force):`.
- **Step.2 GitHub Actions + Azure DevOps job summaries surface the per-cluster result breakdown.** Previously the run-level summary tab only showed a 2-row settings table (`Dry Run` / `Force Overwrite`); the per-cluster `Format-Table` was only visible by drilling into the `Apply UpdateRing Tags` step's raw log. Both platforms now:
  - Capture `-PassThru` from `Set-AzLocalClusterUpdateRingTag` into a `UpdateRingTag_Results.json` artifact sidecar.
  - Emit a **result breakdown table** (Total / Created / Updated / Already in sync / Skipped / WhatIf / Failed) to the job summary.
  - Emit a collapsible `<details>` block with the full per-cluster table (Cluster / Action / Previous / New / Status / Message).
- **Four new Pester source-level assertions** (`Tests/AzLocal.UpdateManagement.Tests.ps1`, Set-AzLocalClusterUpdateRingTag context) pin the new logging / status contract, the `Force` no-op short-circuit, and the `AlreadyInSync` summary bucket.

### Step.7 monitor-updates - form-default regressions fixed (both platforms)

- **`criticalElapsedDays` form-default fixed `7` -> `3`.** The v0.7.99 release lowered the CRITICAL overall-elapsed tier from 7 to 3 days. The inline script default (`$criticalElapsedDays = 3`) and the help-text ("default 3 days") were updated correctly, but the `workflow_dispatch` input default value (GH) / pipeline-parameter default value (ADO) on the form itself was left at `'7'`. When an operator triggered the workflow and left the input untouched, the non-empty form-default `'7'` was passed in via `INPUT_CRITICAL_ELAPSED_DAYS`, the override branch fired, and the threshold silently reverted to the old 7 days - undoing the v0.7.99 behaviour change.
- **`updateRing` form-default fixed `'Wave1'` -> `''` (empty).** Aligns Step.7 with Step.8 + Step.9, which already use `default: ''`. The downstream guard `if ($scope -eq 'by-update-ring' -and $updateRing)` honours empty as "no filter", so behaviour is unchanged on the default `scope=all` path. Removes the misleading "Wave1" value that suggested a real tenant-specific default existed when the operator switched to `scope=by-update-ring`.

### Repo-hygiene guard - `Tests/Pii-Guard.Tests.ps1`

- **New Pester guard** that scans every file under `Tests/` on each run and fails the build if it finds emails, `.onmicrosoft.com` tenant UPN domains, GUIDs in identity contexts (`tenantId` / `clientId` / `objectId` / `principalId` / `applicationId`), or real public IPv4 addresses outside an explicit allow-list.
- Auto-excluded: RFC1918 / loopback / link-local / CGNAT / RFC5737 doc ranges / RFC2544 benchmarking / multicast / subnet-mask shapes / well-known public DNS (Google, Cloudflare, Quad9, OpenDNS). The trailing word-boundary on the IPv4 regex excludes version-string false-positives such as SbeVersion `4.5.6.7-RegressionMarker`.
- Allow-list seeded with the three synthetic GUID fixtures already confirmed safe (sub ID `fbaf508b...`, RunId `add1f87d...`, action-plan ID `1084e062...`).
- One inert fixture rename in `Tests/AzLocal.UpdateManagement.Tests.ps1`: `SbeVersion = '4.1.2.0'` -> `'4.1.2.0-Marker'` (the BS8 schema test only inspects property names, so the value change is a no-op).

### Publish-Module.ps1 - exclude maintainer-only `RELEASE-PROCESS.md`

- `Publish-Module.ps1` now strips `docs/RELEASE-PROCESS.md` at staging time. That file is a maintainer-facing release checklist (its own opening line states "Consumers do not need to read it") and has no runtime value to module consumers. Repo copy on GitHub remains for maintainer reference; it no longer ships inside every installed module folder.

### Pin and version drift

- `GENERATED_AGAINST_MODULE_VERSION` moves from `0.7.99` to `0.8.0` across all 20 bundled Step.*.yml templates (GH Actions + Azure DevOps).
- Drift-sync test asserts `$script:ModuleVersion` (psm1) == `ModuleVersion` (psd1) == `Should -Be '0.8.0'` (test) - any drift fails CI.

### Pester baseline

- Total: ~833 passed / 0 failed / 1 skipped (added 3 new assertions covering the Step.2 AlreadyInSync skip-branch split, summary tally bucket, and -Force no-op short-circuit, on top of the new Pii-Guard.Tests.ps1 block added in this release).

## [0.7.99] - 2026-06-09

Breaking property and Summary renames in the readiness / fleet-status cmdlets to remove a long-standing semantic ambiguity, plus a Step.7 CRITICAL elapsed-days default tightening (7 -> 3) and an artifact-naming cleanup (every pipeline zip is now prefixed with `step.X-` so operators can tell at a glance which Step.* emitted it). All 20 bundled pipeline YAMLs were updated to consume the new output shapes; the `GENERATED_AGAINST_MODULE_VERSION` pin moves to `0.7.99` on every template.

### Breaking renames - readiness / fleet-status output shape

- **`Get-AzLocalUpdateSummary`**: `AvailableUpdatesCount` -> **`ActionableUpdatesCount`**. The column only counted ACTIONABLE updates (Ready / NotReady), not the full available-updates inventory; the new name removes the ambiguity. ARM source field (`updateStateProperties.availableUpdates`) and per-cluster output are unchanged.
- **`Get-AzLocalClusterUpdateReadiness`**: `AvailableUpdates` -> **`AllAvailableUpdates`**. Property now reads clearly as "every available update, every state". Same content as before. The output object's three sites (Not-Found row, main row, Error row) all rename in lock-step.
- **`Get-AzLocalFleetStatusData`**: `AvailableUpdates` -> **`AllAvailableUpdates`** (same rationale as above, three sites).
- **`Get-AzLocalClusterUpdateReadiness` Summary: 2-bucket -> 3-bucket model.** Console output and JSON export both gain a `Up to Date` bucket distinct from `Not Ready for Update`. Previously, healthy clusters with `UpdateState in (UpToDate, AppliedSuccessfully)` and no remaining available updates were rolled into the `NotReady` total, which falsely flagged an updated fleet as needing attention. They now have their own bucket.
  - Console labels: `Ready for Update` / `Not Ready / Other State` -> `Ready for Update` / `Up to Date` (new) / `Not Ready for Update`.
  - JSON `Summary` keys: `ClustersReady` / `ClustersNotReady` -> `ClustersReadyForUpdate` / `ClustersUpToDate` (new) / `ClustersNotReadyForUpdate`.
- **No change** to the per-row `.ReadyForUpdate` boolean, the per-row `.UpdateState` field, or the cmdlet name `Get-AzLocalAvailableUpdates` (the function name is unaffected; only output properties on other cmdlets were renamed).

### Pipeline consumers updated in lock-step

- **Step.5 `assess-update-readiness.yml` (GH + ADO)**: now computes and surfaces the 3-bucket model (`Ready for Update` / `Up to Date` / `Not Ready for Update`) in both the console banner and the markdown step summary. Per-UpdateRing pivot table gains an `Up to Date` column. The `NOT_READY` step output keeps its existing meaning (`Total - ReadyForUpdate - UpToDate`).
- **Step.8 `fleet-update-status.yml` (GH + ADO)**: `readiness-status.json` `Summary` block keys renamed to `ReadyForUpdate` / `UpToDate` / `NotReadyForUpdate` to match the cmdlet. `NotReadyForUpdate` now excludes both InProgress AND UpToDate clusters. Step.8 markdown vocabulary (already `Up to Date` / `Ready for Update`) is unchanged.
- **Step.8 GH yml line 534**: `"Available Updates: $($cluster.AvailableUpdates)"` -> `"All Available Updates: $($cluster.AllAvailableUpdates)"` to consume the renamed property.
- **`Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml`** is unchanged - the `NotReady` key there maps a per-run `Status` value emitted by `Start-AzLocalClusterUpdate.ps1`, which is a separate (and stable) contract.

### Step.7 CRITICAL elapsed-days default 7 -> 3

- `criticalElapsedDays` default lowered from `7` to `3` in both `github-actions/Step.7_monitor-updates.yml` and `azure-devops/Step.7_monitor-updates.yml`. The skull (rotating-light) threshold (2x CRITICAL) consequently lowers from `14` to `6` days. Operator rationale: a 7-day update run already feels long; surface stuck runs with the CRITICAL severity tier sooner.
- Override path unchanged: pass `criticalElapsedDays: <N>` via workflow_dispatch (GH) / pipeline params (ADO) for fleets with multi-week SBE-prerequisite cascades.
- Affects three sites per template: parameter `displayName`, the in-body comment block, and the literal `$criticalElapsedDays = 3` assignment.

### Step.7 testsuite-level `time=` zeroed

- Per-testcase `time=` continues to carry real per-run elapsed seconds (v0.7.98 behaviour preserved). The suite-level wrapper now emits `time="0"` rather than summing five unrelated wall-clock ages (~88 days in a typical fleet snapshot) which was misleading and inflated GitHub Test Reporter's "ran in" timestamp.

### Artifact zip names now carry the producing Step number

- Every bundled pipeline template's `actions/upload-artifact` (GH) / `PublishBuildArtifacts@1` / `PublishPipelineArtifact@1` (ADO) artifact name moves from `azlocal-<purpose>_yyyyMMdd_HHmmss` to **`azlocal-step.X-<purpose>_yyyyMMdd_HHmmss`** where X matches the Step.* filename. Operators downloading several artifacts in one session can now tell at a glance which Step.* produced each zip without unzipping.
- 35 rename sites across 20 templates. The Step.5 markdown body's artifact-name reference (e.g. `azlocal-readiness-assessment-report_*` -> `azlocal-step.5-readiness-assessment-report_*`) was updated to match in both GH and ADO mirrors.
- The Pester guard for the artifact-name convention was upgraded from a generic `azlocal-` prefix check to require the `^azlocal-step\.\d+-` regex shape. New templates that forget the `step.X-` prefix will fail the unit test.

### Documentation refresh

- `Automation-Pipeline-Examples/README.md` section 1.1 (`Why the pipelines are named Step.N - <description>`) Step.N table gains two new columns linking directly to the GH Actions and Azure DevOps source YAML for each step.
- `Automation-Pipeline-Examples/README.md` section 9 (`Tuning throughput -ThrottleLimit`) trimmed of the stale v0.7.68 historical-removal narrative. The "where it still applies" + "throttling on the read side" guidance stays.
- `docs/cmdlet-reference.md` property table and example output reflect the property and Summary renames.
- `GENERATED_AGAINST_MODULE_VERSION` pin bumped from `0.7.98` to `0.7.99` across all 20 bundled templates (10 GH Actions + 10 Azure DevOps).

### Migration

- Re-run `Update-AzLocalPipelineExample -Destination <your-pipeline-repo>` to refresh the bundled YAMLs in your CI repo. The Step.5 / Step.7 / Step.8 templates carry the most material changes; Step.0-4 + Step.6 + Step.9 changes are limited to the artifact-name `step.X-` prefix and the version pin bump.
- If you have downstream consumers of `readiness-status.json`, update them to read `ReadyForUpdate` / `UpToDate` / `NotReadyForUpdate` instead of `Ready` / `NotReady`, and to read `Clusters[].AllAvailableUpdates` instead of `Clusters[].AvailableUpdates`. The same renames apply to direct `Get-AzLocalClusterUpdateReadiness -PassThru` consumers.
- If you have ARM-state filters keyed on the `Get-AzLocalUpdateSummary` output, rename `AvailableUpdatesCount` to `ActionableUpdatesCount`.

## [0.7.98] - 2026-06-09

Step.7 monitor-updates pipeline UX rewrite plus a JUnit `time=` fix that covers Step.7 and Step.8's Update Run History testsuite. The only files that changed are the four monitor / fleet-status pipeline templates (`github-actions/Step.7_monitor-updates.yml`, `azure-devops/Step.7_monitor-updates.yml`, `github-actions/Step.8_fleet-update-status.yml`, `azure-devops/Step.8_fleet-update-status.yml`) plus the bundled-template `GENERATED_AGAINST_MODULE_VERSION` pin bump. No public-cmdlet changes.

### Step.7 monitor-updates UX overhaul

- **Severity tiers + composite `SeverityScore` sort.** Each in-flight / unresolved-failed row is scored on `StepError severity x 1000 + RunSeverity x 100 + elapsed-hours bucket` and the job-summary table sorts highest-severity first. Stuck step errors and runs > 14 days appear at the top regardless of cluster name alphabetical order.
- **Per-cell icons (`StateIcon`, `StatusIcon`) + horizontal chip stack** (`STEP-STUCK`, `RUN-STUCK`, `UNRESOLVED`, `RECENT-FAIL`) replace the previous single-status column. Each chip is its own column-width so long flag lists do not squash the cluster name column.
- **Fleet status badge** at the top of the job summary collapses the worst row across the fleet into a single `CRITICAL / WARN / OK` line (e.g. `CRITICAL - 1 stuck step error(s), 1 run(s) > 14d, 1 step(s) > 4h`).
- **Collapsible Verbose Error block** wraps each failed step's `errorMessage` in `<details><summary>Verbose error</summary>...</details>` so the table stays readable but the full error is one click away.
- **Smoke-validated** against a synthetic 4-cluster fleet (stuck step, > 14d run, > 4h step, normal in-flight); badge wording and chip stack order match the severity cascade.

### JUnit `time=` populated (Step.7 + Step.8 Update Run History)

- Previously every `<testcase>` and `<testsuite>` element emitted `time="0"`, which caused GitHub Test Reporter / Azure DevOps Tests tab to render `"5 tests were completed in 0ms"` regardless of actual run duration.
- **Step.7**: each in-flight / unresolved-failed row now computes `RunDurationSeconds` as `end - start` for completed / failed runs and current elapsed for in-flight runs, then emits it on both the `<testsuite time="..">` (sum) and `<testcase time="..">` (per row).
- **Step.8 `Update Run History and Error Details` testsuite**: each `<testcase>` now emits `time` = `DurationMinutes * 60` (DurationMinutes comes from KQL `datetime_diff('minute', EndTime, StartTime)` via `Get-AzLocalUpdateRunFailures`).
- Other Step.8 testsuites (`FleetVersionDistribution`, `AzureLocalFleetUpdateStatus`) intentionally stay at `time="0"` - those are instantaneous snapshot projections and carrying a synthetic duration would be misleading.

### Pipeline template version pin

- All 20 bundled `Step.{0..9}.yml` templates (10 GitHub Actions + 10 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.97'` to `'0.7.98'`.

### How to consume

`Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). If you have copied the Step.7 or Step.8 YAMLs into your CI repo via `Update-AzLocalPipelineExample`, re-run it to pick up the new UX and the populated `time=` attributes.

## [0.7.97] - 2026-06-08

Documentation-only release. The three Markdown files that ship inside the published PSGallery `.nupkg` under the module folder were refreshed to mirror the v0.7.96 module behaviour. Consumers who installed v0.7.96 fresh saw stale Step.7 + Step.8 narrative in those in-package docs because they were updated AFTER `Publish-Module.ps1` ran. v0.7.97 republishes the package with the aligned docs.

**No code anywhere in the module, no inline-script changes in any Step.{0..9}.yml template** - only the `GENERATED_AGAINST_MODULE_VERSION` pin moves from `'0.7.96'` to `'0.7.97'` across all 20 bundled templates (10 GitHub Actions + 10 Azure DevOps).

### Changed

- **`Automation-Pipeline-Examples/README.md` (CI/CD runbook).** Section-1 Step.7 bullet now mentions the new `Status` + `ErrorMessage` columns, the `StepError` JUnit failure type, the always-shown Failed-runs block, portal-linked Cluster / Update Name cells, and the new `STEP_ERRORED` / `UNRESOLVED_FAILURES` `GITHUB_OUTPUT` values. Step.8 bullet now mentions `NeedsAttention` promotion into the `Update Failed` bucket, the new `Action Required` bucket for `PreparationFailed`, and `PreparationInProgress` folding into `Update In Progress`. Both bullets carry portal-linked markdown cells on Cluster Name / Update Name from v0.7.96.
- **`Automation-Pipeline-Examples/docs/appendix-pipelines.md` (per-step pipeline reference).** Step 7 and Step 8 tables refreshed: the `Purpose`, `Artefacts`, `Exit conditions`, and `Introduced` rows now describe the new columns, JUnit failure types, the bucket cascade (`Update Failed > Action Required > Health Failure > SBE Prerequisite Blocked > Update In Progress > Ready for Update > Up to Date > Needs Investigation`), the `primaryActionRequired` JUnit attribute, `ACTION_REQUIRED` output, `Summary.UpdateFailures` + `Summary.ActionRequired` JSON keys, and the portal-linked markdown cells. A duplicate `Exit conditions` row on Step 7 was removed as part of the refresh.
- **`docs/release-history.md` (canonical release history).** Current-release pointer bumped from v0.7.89 to v0.7.97; new `### What's New in v0.7.96` entry prepended (mirrors the v0.7.96 README block).
- **All 18 bundled `Step.{0..9}.yml` templates (9 GitHub Actions + 9 Azure DevOps)** bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.96'` to `'0.7.97'`. Pin-only; no inline-script content changes.

### Migration

For cmdlet consumers: `Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). No cmdlet behaviour change vs v0.7.96.

For CI/CD pipeline consumers: re-run `Update-AzLocalPipelineExample -Destination <path>` to refresh the `GENERATED_AGAINST_MODULE_VERSION` pin (pin-only short-circuit from v0.7.95 means `-Force` is not required).

## [0.7.96] - 2026-06-09

Operator-visibility release. Rolls every Azure portal Update Manager signal into the module + pipelines so operators no longer have to click into the Azure portal to triage stuck or failed runs. No breaking changes (additive fields only). Triggered by the Arizona cluster that sat 18+ days on the "Start update" step where the existing `State=InProgress` signal made it invisible to Step.7 long-running checks.

### Added

- **`Get-AzLocalUpdateRuns` now surfaces `Status`** - the 7-value `properties.progress.status` vocabulary (`Success` / `Error` / `InProgress` / `NotStarted` / `Skipped` / `Cancelled` / `Unknown`) alongside the existing `State` field (`properties.state`: `Succeeded` / `Failed` / `InProgress`). The two fields are independent: a run can be `State=InProgress` while `Status=Error` (per-step error surfaced, run not yet abandoned). The combination is the key signal that drives Step.7's new `StepError` JUnit type. Backed by a new private field on `Format-AzLocalUpdateRun` and propagated through both the multi-cluster and no-runs paths of `Get-AzLocalUpdateRuns`.
- **`Get-AzLocalUpdateRuns` now surfaces `ErrorMessage`** - the deepest non-empty `errorMessage` walked from the `properties.progress.steps[]` tree. Backed by a new `Get-DeepestErrorMessage` private helper that recurses up to depth 9, mirroring the workbook's `coalesce(e9Msg..e1Msg)` pattern, and returns the deepest text from any step with `status` in (`Error`, `Failed`). Operators see the actual portal error text directly in the pipeline CSV + markdown summary instead of having to deep-link into the cluster blade.
- **New private helper `Get-DeepestErrorMessage`** registered in `NestedModules` in the psd1 between `Get-DeepestActiveStep` and `Get-ExportFormat`. Not exported - operators consume it indirectly via the new `ErrorMessage` field.

### Changed

- **`Step.7_monitor-updates.yml` (GitHub Actions + Azure DevOps) reworked.** New JUnit failure type `StepError` fires whenever `Status=Error && State=InProgress` - this is the signal that the Arizona "Start update" 18-day stuck-step case was missing. The "Recently-failed" markdown table is replaced by "Failed runs (unresolved)" which **always** lists every cluster whose latest run is `State=Failed` (since `-Latest` already returns one row per cluster, any Failed latest run IS unresolved by definition - no age window). Recent-failure highlighting is now a `:fire: last Nh` flag column. New `Progress Status` column on the in-flight table; new `ErrorMessage` column on the failed-runs table (220-char truncated in markdown, full in CSV). TSG blockquote now links both [MS Learn](https://learn.microsoft.com/azure/azure-local/update/update-troubleshooting-23h2) and the GitHub TSG. JUnit failure-type vocabulary: `StepError`, `LongRunningStep`, `LongRunningOverall`, `RecentFailure`. New job outputs `STEP_ERRORED` / `stepErrored` and `UNRESOLVED_FAILURES` / `unresolvedFailures` for downstream consumption.
- **`Step.8_fleet-update-status.yml` (GitHub Actions + Azure DevOps) reworked.** The `properties.state` values `PreparationFailed` and `NeedsAttention` previously fell into the catch-all "Other / Needs Investigation" bucket and were invisible to operators. v0.7.96 promotes them to first-class signals (matches the Azure portal Update Manager `state` filter):
  - `NeedsAttention` joins the existing **Update Failed** bucket (terminal failure, retry path).
  - `PreparationFailed` gets its own new **Action Required** bucket (operator must remediate before the run can be re-armed).
  - `PreparationInProgress` is now counted under **Update In Progress** (was previously dropped into Other).
  - The `failures` total in the JUnit critical-health pass/fail now includes both new states, so the pipeline correctly turns RED when any of (`Failed` / `UpdateFailed` / `NeedsAttention` / `PreparationFailed`) is present.
  - New JUnit testsuite property `primaryActionRequired`; new pipeline output `ACTION_REQUIRED` (GH) / `$(collect.actionRequired)` (ADO); new "Action Required" row in the Primary Status markdown table and host summary; new "Actions Required" prose entry explaining the PreparationFailed remediation path.
  - The JUnit per-cluster `testcase failureType` is now `PreparationFailed` when applicable (vs the generic `UpdateFailure`) so downstream ITSM connectors can route the ticket differently.
  - New `Summary.UpdateFailures` and `Summary.ActionRequired` counts on the `readiness-status.json` artefact.

### Migration

Apply via `Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). Run `Update-AzLocalPipelineExample -Destination <path>` to refresh both `Step.7_monitor-updates.yml` and `Step.8_fleet-update-status.yml`. Both files sit outside any `BEGIN-AZLOCAL-CUSTOMIZE` block, so operator schedule customisations elsewhere in those pipelines are preserved.

## [0.7.95] - 2026-06-08

Quality-of-life release. Removes the recurring friction where `Update-AzLocalPipelineExample` silently skipped Step.0 / Step.1 YAMLs on every module bump. No cmdlet behaviour changes affecting other functions, no schema changes, no breaking changes.

### Fixed

- **`Update-AzLocalPipelineExample` was skipping Step.0 / Step.1 YAMLs on every release.** Step.0 (`authentication-test`) and Step.1 (`inventory-clusters`) shipped without any `# BEGIN-AZLOCAL-CUSTOMIZE` markers, but the bundled `GENERATED_AGAINST_MODULE_VERSION` pin gets mechanically bumped on every release. The cmdlet correctly treated this as "diverged from bundled sample, no markers to merge on" and refused to write without `-Force`. Customers had to either run `-Force` on every upgrade (and risk losing local hand-edits) or skip those two files indefinitely. Fixed two complementary ways - see Added below.

### Added

- **`schedule-triggers` marker blocks on all four bundled Step.0 / Step.1 YAMLs (GitHub Actions + Azure DevOps).** Step.0 markers wrap an empty schedule template with a commented-out cron example; Step.1 markers wrap the existing `cron: '0 6 * * 1'` weekly inventory schedule (and the Azure DevOps `schedules:` block with `displayName: 'Weekly Inventory'`). Operator schedule edits to either file now survive subsequent `Update-AzLocalPipelineExample` merges via the existing marker-aware branch 3f.
- **Pin-only short-circuit in `Update-AzLocalPipelineExample` branch 3c.** When BOTH files are marker-free AND the only line-level difference is the `GENERATED_AGAINST_MODULE_VERSION` pin (a release metadata field, not an operator customisation surface), the cmdlet refreshes the pin in place without `-Force` and reports a new `Action='Updated-PinOnly'` in the `-PassThru` output. The regex normalisation handles both shapes: GitHub Actions single-line `GENERATED_AGAINST_MODULE_VERSION: '0.7.95'` and Azure DevOps two-line `- name: GENERATED_AGAINST_MODULE_VERSION` + `value: '0.7.95'`. Any non-pin divergence outside markers still emits `Skipped-NeedsForce` exactly as before - the safety contract for non-trivial divergence is unchanged.
- **Two Pester regression cases** under `Describe 'Function: Update-AzLocalPipelineExample'` exercise the new branch 3c.i end-to-end via a mocked `Get-Module` that resolves the cmdlet's source folder to a fake module install under `TestDrive` containing a single marker-free synthetic YAML. One asserts the pin-only auto-bump fires (`Action='Updated-PinOnly'`, no `-Force` needed, pin rewritten in the destination); the other asserts non-pin divergence still emits `Skipped-NeedsForce` with the destination file untouched.
- **`.OUTPUTS` documentation update** in the `Update-AzLocalPipelineExample` comment-based help: the documented `Action` enum now includes `'Updated-PinOnly'`. The `Safety:` section in `.DESCRIPTION` documents the carve-out.

### Documentation

- **`Automation-Pipeline-Examples/README.md` section 1.1 pipeline-inventory table is now fully hyperlinked.** Each `Step.N` pipeline name in the at-a-glance table links to its dedicated `Step N - <description>` section in [`Automation-Pipeline-Examples/docs/appendix-pipelines.md`](Automation-Pipeline-Examples/docs/appendix-pipelines.md) (Purpose / Inputs / Trigger / Cmdlets invoked / Depends on / Artefacts / When to run / RBAC / Exit conditions). Removes the guess-and-scroll through a 2000-line README to locate what a specific Step.N pipeline does.
- **`Automation-Pipeline-Examples/README.md` section 3 RBAC restructured around the recommended assignment path.** The MG + Azure Policy `deployIfNotExists` pattern (auto-assigns the custom role on every present and future subscription under a management group) is now the default in new **section 3.2** with a 6-step summary and a cross-link to the full recipe in `docs/rbac.md`. The manual per-subscription assignment workflow has been moved to new **section 3.3** ("Manual / per-subscription alternative (legacy)") with all its existing detail (assign command, error tables, security-group delegation tip, verify-the-grant probes, PIM gotcha, migration tip, built-in-role `<details>` fallback block) preserved verbatim. Section 3.1 ("Custom role: `Azure Stack HCI Update Operator`") keeps its title verbatim to preserve the `#31-custom-role-azure-stack-hci-update-operator` anchor referenced from 8+ places across both READMEs; its content is trimmed to definition + create-only flow. The old `### 3.2 Extending to additional subscriptions` is deleted - the MG+DINE path makes a dedicated "extending" section obsolete (new subs auto-onboard) and the manual variant of that guidance is absorbed inline into 3.3.
- **Bundled `Automation-Pipeline-Examples/azlocal-update-management-custom-role.json` default `AssignableScopes` flipped to a management-group placeholder** (`/providers/Microsoft.Management/managementGroups/<your-mg-id>`) so the recommended MG + DINE path in the new section 3.2 works out of the box. The legacy per-sub path documented in section 3.3 needs one line of edit. Both the inline JSON block in section 3.1 and the Option 1 / Option 2 PowerShell snippets ("Create the role") have been updated in lockstep - the snippets now use `$mgId` and an MG `AssignableScopes` entry; commented per-sub `$subId` and `$scopes` variants are kept inline for the legacy path.
- **`Automation-Pipeline-Examples/docs/appendix-pipelines.md` enterprise-grading pass.** All 10 per-pipeline H3 sections renamed from the academic `A.N <Title>` form to the operator-facing `Step N - <Title>` form (matching the bundled `Step.N_*.yml` filenames and the workflow `name:` fields shown in the GitHub Actions sidebar / Azure DevOps Pipelines list). The **Pipeline** column header in the at-a-glance table is preserved as the column label; row labels and intra-doc anchors switch to the `Step N -` form. Each of the 10 sections gained four new rows: **Cmdlets invoked** (only AzLocal.UpdateManagement cmdlets the YAML calls directly), **Depends on** (upstream pipelines whose output is consumed or whose work must be in place before this pipeline runs), **Exit conditions** (what a non-success YAML run state means in practice), and **ITSM** (whether the bundled YAMLs ship with the opt-in ServiceNow auto-raise connector). Coverage is now explicit: Step 4 / Step 6 / Step 8 / Step 9 ship the `raise_itsm_ticket` (GH) / `raiseItsmTicket` (ADO) input + the four ITSM toggles + the `Get-AzLocalItsmConfig` post-job step; Step 0 / Step 1 / Step 2 / Step 3 / Step 5 / Step 7 do not, with a one-line rationale per section so silence is no longer ambiguous. Step 8 and Step 9 `Inputs` rows were also corrected to list the four ITSM toggles inline (previously only the `Cmdlets invoked` row hinted at ITSM support). Stale `(formerly A.7)` / `(formerly A.8)` parentheticals dropped from the Step 8 / Step 9 headings. All `Section 4.1` references corrected to `Section 3.1` (post-3.2/3.3 reorganisation). Parent README anchors in section 1.1, section 1, and the section 14 stub updated in lockstep to point at the new `#step-N---...` slugs.
- **`docs/appendix-pipelines.md` Step 5 + parent README section 8.1.1 - recommended Step.5 pre-flight schedule.** Because `Step.5_assess-update-readiness.yml` ships without a `schedule:` block (the `update_ring` input is required and no single value is universally correct), `docs/appendix-pipelines.md#step-5---assess-update-readiness` now closes with a **RECOMMENDED CUSTOMISATION** blockquote explaining the per-ring scheduling pattern + a small lead-time table (12-24h for <=10 clusters, 24-48h for 10-50, 48-72h for 50+). The parent `Automation-Pipeline-Examples/README.md` gains matching **new section 8.1.1 "Recommended Step.5 pre-flight schedule (per ring)"** with a worked GitHub Actions multi-cron snippet, an explicit cron-trigger-cannot-supply-`inputs:` callout (so the recommended pattern is one `Step.5_*.yml` per ring), and an always-green caveat (silently-empty `readiness.xml` from an `update_ring` typo never produces a red-build email - check the Tests tab / JUnit reporter). Calls out the known Step.3 audit gap (Step.3 only audits Step.6 cron-to-`UpdateStartWindow` coverage; it does not audit Step.5-to-Step.6 lead-time pairing).
- **Deleted misleading separate-tag-identity guidance.** Removed the sentence "If you run the tag-management workflow under a separate identity from the update-apply identity (recommended in regulated estates), grant that identity Tag Contributor only." from `Automation-Pipeline-Examples/README.md` section 3. All ten bundled pipelines use a single identity (one `AZURE_CLIENT_ID` for GitHub Actions, one service connection for Azure DevOps); there is no separate-identity recipe to follow, so the guidance was unimplementable as written. The rest of the Tag Contributor note (single-identity, `Microsoft.Resources/tags/default` PATCH endpoint since v0.7.65, no `microsoft.azurestackhci/clusters/write` needed for tag changes) is correct and preserved.

### Migration

The v0.7.94 -> v0.7.95 upgrade still requires `-Force` for Step.0 / Step.1 destinations that don't yet have markers - they fall into branch 3d (`src has markers, dest doesn't`) which still refuses to write without `-Force`, because synthesising marker boundaries from an unmarked file would risk losing operator content. All subsequent upgrades are smooth.

```powershell
# One-time upgrade refresh for Step.0 + Step.1 destinations:
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Force
```

All 20 bundled `Step.{0..9}.yml` templates pin-bumped to `'0.7.95'`.

## [0.7.94] - 2026-06-08

Hotfix release. Pipeline-YAML-only - no cmdlet behaviour changes, no schema changes, no breaking changes.

### Fixed

- **`Step.7_monitor-updates.yml` (GitHub Actions + Azure DevOps) - missing `-PassThru` on `Get-AzLocalUpdateRuns` caused every scheduled monitor run to report `0 in-flight / 0 long-running` even when clusters had update runs stuck `InProgress`.** Both Step.7 variants called `Get-AzLocalUpdateRuns -ClusterResourceIds $ids -Latest` (and `-ScopeByUpdateRingTag -Latest`) without `-PassThru`. In multi-cluster mode the cmdlet writes its formatted results to the host via `Format-Table | Out-Host` and only returns them to the pipeline when `-PassThru` is set, so the consuming pipelines silently received an empty `$runs` array. Symptom in the wild: a fleet with a single update run stuck `InProgress` for 19+ days (well past the 6h `long_running_threshold_hours`) rendered as `Clusters scoped: 0 / Update runs in flight: 0 / Exceeding 6h threshold: 0` with the `No update runs currently in flight` branch and a 404-byte empty CSV - completely missing the long-running run the pipeline exists to surface. Fixed by adding `-PassThru -SkipSideloadedReset` to both `Get-AzLocalUpdateRuns` invocations in each of the two `Step.7_monitor-updates.yml` files. `-SkipSideloadedReset` is included because this is a read-only observability pipeline and must not mutate cluster tags via the cmdlet's default `UpdateSideloaded` auto-reset behaviour. Verified against a 20-cluster fleet with one InProgress run: post-fix Step.7 correctly reports `Clusters scoped: 20 / Update runs in flight: 1 / Exceeding 6h threshold: 1` with the affected cluster row and its elapsed duration. No module code changes; Step.8, the smoke tests, and the Pester suite already used `-PassThru` correctly.

### Migration

`Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). Run `Update-AzLocalPipelineExample -Destination <path>` to refresh the two affected `Step.7_monitor-updates.yml` files (GitHub Actions + Azure DevOps). The fix sits outside any `BEGIN-AZLOCAL-CUSTOMIZE` block, so operator customisations elsewhere in those pipelines are preserved.

## [0.7.93] - 2026-06-05

Patch release. Pipeline-YAML and tests-only - no cmdlet behaviour changes, no schema changes, no breaking changes.

### Fixed

- **Pipeline JUnit summaries no longer render `NaNms` in the duration column.** Five of the inline JUnit XML writers under `Automation-Pipeline-Examples/{github-actions,azure-devops}/` (Step.0 authentication-test, Step.3 apply-updates-schedule-audit, Step.4 fleet-connectivity-status, Step.7 monitor-updates, Step.9 fleet-health-status) emitted `<testsuite>` and `<testcase>` elements with no `time=` attribute. `dorny/test-reporter` (and most JUnit renderers) parse a missing `time` attribute as `NaN` and print `NaNms` in the summary table's duration column, which also collapsed the Passed/Failed/Skipped column alignment. v0.7.93 adds `time="0"` to every `<testsuites>` / `<testsuite>` / `<testcase>` emission in all 12 affected files (10 inline writers across the five Steps, plus the `<testsuites>` root in Step.8 GH + ADO where the child elements already carried `time="0"`). Step.6 was unaffected - it consumes the module's `Private/Export-ResultsToJUnitXml.ps1` helper, which has always emitted `time=` correctly. No cmdlet code changes; the module helper is unchanged.

### Changed

- **`Test-AzLocalApplyUpdatesScheduleCoverage` `-RecommendFiresPerWindow` help text.** Dropped a `(pre-v0.7.92 back-compat)` parenthetical from the `.PARAMETER` block (and the matching wording in `Step.3_apply-updates-schedule-audit.yml` GH + ADO). The parameter default remains `2` and the behaviour is unchanged - this is a docstring tidy only.

### Added

- **Pester regression guard: every inline JUnit emission must carry a `time=` attribute.** A new `It` block under `Describe 'Module: AzLocal.UpdateManagement'` -> `Context 'Inline JUnit XML emitters carry a numeric time attribute (v0.7.93 NaNms regression)'` statically scans every `*.yml` under `Automation-Pipeline-Examples/` for `<testsuites>` / `<testsuite>` / `<testcase>` lines and asserts each one carries a `time=` attribute. Any future inline writer (or `Update-AzLocalPipelineExample` regression) that drops the attribute fails the suite immediately. The check is a single regex scan plus a Pester `Should -Be 0` on a list of offenders.
- **Docs: management-group `AssignableScopes` + Azure Policy DINE recipe for scaling the `Azure Stack HCI Update Operator` custom role across many subscriptions.** New section in [`docs/rbac.md`](docs/rbac.md#scaling-assignablescopes-with-management-groups--azure-policy-recommended-for-large-or-growing-estates) walks through the Azure Landing Zones-style pattern: a single MG entry in `AssignableScopes` plus an Azure Policy `deployIfNotExists` assignment at that MG that auto-creates the per-subscription role assignment for the pipeline identity (existing subs picked up by a one-time remediation task; new subs auto-remediated on creation). Includes the role definition JSON with MG scope, the DINE policy definition with nested ARM `roleAssignments` template, the system-assigned-MI grant + remediation commands, the required RBAC at each step, and a trade-offs table vs the per-subscription list. Recommended for estates of more than ~5-10 subscriptions or where new subs are provisioned regularly. The per-subscription `AssignableScopes` list remains the documented fallback for small/static estates or operators without `Owner` / `User Access Administrator` on a management group. Cross-linked from [`Automation-Pipeline-Examples/README.md`](Automation-Pipeline-Examples/README.md) sections 3.1 and 3.2.

### Migration

`Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). Run `Update-AzLocalPipelineExample -Destination <path>` to refresh the affected `Step.{0,3,4,7,8,9}_*.yml` files. The injection sites are outside any `BEGIN-AZLOCAL-CUSTOMIZE` block, so operator customisations are preserved.

## [0.7.92] - 2026-06-05

Docs/YAML-only feature release. No cmdlet behaviour changes, no schema changes, no breaking changes. The pipelines that move are `Step.9_fleet-health-status.yml`, `Step.8_fleet-update-status.yml` and `Step.7_monitor-updates.yml` (all GitHub Actions + Azure DevOps).

### Changed

- **Step.9 `Detailed Results` table is now a per-cluster `<details>` block.** Previously the section rendered as a single flat table of up to 100 (cluster x failing-check) rows, so on a fleet of 20+ unhealthy clusters the table dominated the run summary and operators had to scroll to find a specific cluster. The new layout has one collapsible block per cluster: the always-visible `<summary>` line carries the cluster name (linkified to the Azure portal blade), a severity tally in `[Critical] x N  &middot;  [Warning] x M` form (non-zero tiers only, Critical first), and the most-recent `LastOccurrence` across all that cluster's failing checks. Expanding the block reveals the existing per-failure mini-table (Severity / Failure Reason / Failure Remediation / Target Resource Name / Target Resource Type / Last Occurrence / Resource Group).
- **Cluster ordering switched to worst-affected first.** Clusters sort by `CriticalCount` desc, then `WarningCount` desc, then most-recent `LastOccurrence` desc - so the cluster with the most active critical failures rises to the top. Within each cluster, the per-failure rows sort Critical-first then `LastOccurrence` desc.
- **Pagination is now per-CLUSTER (not per-ROW).** The previous `first 100 rows` cap could silently truncate the second half of a busy cluster's failures. The new cap shows the first 100 clusters in full; the existing `fleet-health-detail.csv` artifact still carries every row for any cluster that overflows.
- **CSV / JSON artifacts unchanged.** `fleet-health-detail.csv`, `fleet-health-summary.csv`, `fleet-health-overview.csv` and their JSON twins all retain the same schema, so any downstream tooling (ITSM, dashboards, etc.) keeps working without changes.
- **`Step.7_monitor-updates.yml` ships with an active default schedule (GH Actions + Azure DevOps).** Now runs 5x/day at 20:00, 22:00, 00:00, 02:00, 04:00 UTC - every 2 hours across the typical overnight maintenance window - in addition to manual `workflow_dispatch` / queue runs. Previously the schedule block shipped commented-out and required operators to enable it per estate. The cron lives inside the existing `BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` block, so any local edits (hour-list shifts for a non-UTC maintenance window, weekends-only, sub-hour external triggers, etc.) survive `Update-AzLocalPipelineExample` refreshes. Both GH Actions and Azure DevOps interpret cron in UTC - adjust the hour list in the YAML if your maintenance window differs.
- **`Copy-AzLocalPipelineExample` now drops a starter `apply-updates-schedule.yml` by default + step-by-step README updated.** The ring-aware schedule file consumed by Step.6 (`apply-updates`) and Step.3 (`apply-updates-schedule-audit`) was previously documentation-only and operators had to remember to generate it manually before they could rely on `schedule:` triggers. v0.7.92 changes this:
  - For `-Platform GitHub|AzureDevOps`, `Copy-AzLocalPipelineExample` now copies the bundled `apply-updates-schedule.example.yml` to `apply-updates-schedule.yml` ONE LEVEL UP from `-Destination` (sibling of `.github\workflows\` for GitHub, sibling of the pipelines folder for ADO) when no file already exists at that path. Existing files are NEVER overwritten - any operator-tailored schedule is preserved verbatim. The post-copy `Next steps:` summary surfaces the dropped path in green (or *"Starter schedule preserved (existing file)"* in yellow when a file was already present) plus the explicit regenerate-from-live-fleet command `New-AzLocalApplyUpdatesScheduleConfig -OutputPath <path> -Force` because the starter ships with DEMO ring names (`Canary`, `DevTest`, `Ring1`, `Ring2`, `Prod`) that almost never match an estate's live `UpdateRing` tag values. Manual `workflow_dispatch` / queue runs of Step.6 ignore the schedule file entirely (they take `UpdateRing` verbatim from the run-form input), so the starter is safe to land even on fleets that haven't generated their real schedule yet.
  - Safe to land alongside the bundled Step.6 because Step.6 ships with every `cron:` line commented out inside the `BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` markers - it cannot fire on a `schedule:` trigger until at least one cron is uncommented, so dropping the starter cannot trigger an unintended scheduled run.
  - New `[switch] -SkipStarterSchedule` parameter on `Copy-AzLocalPipelineExample` suppresses the starter copy for callers that want pipeline YAMLs only (e.g. estates that pre-stage the schedule via separate tooling).
  - `Automation-Pipeline-Examples/README.md` sections 5.1 step 5 (GitHub Actions) and 5.2 step 6 (Azure DevOps) are rewritten to document the new default-on drop, the never-overwrite safety rail, the DEMO ring names, the `New-AzLocalApplyUpdatesScheduleConfig -OutputPath <path> -Force` regenerate cycle, and the `-SkipStarterSchedule` opt-out. Section 8 (full schema, multi-stage rollouts, weekly-cycle / ring-eligibility model, `allowedUpdateVersions` allow-list) is cross-linked for the deep dive.
  - Reverses the v0.7.69 design decision that the schedule file should always be operator-generated from live fleet. The new "starter copy + never overwrite + DEMO ring names + regenerate command in the summary" pattern is operator-friendlier without sacrificing the "real schedule must reflect live tag values" intent.
- **Pipeline step-summary hyperlinks now open in a new tab (Step.8 + Step.9, GH Actions + Azure DevOps).** Every rendered hyperlink in `Step.8_fleet-update-status.yml` and `Step.9_fleet-health-status.yml` step summaries - cluster-name cells, update-run-name cells, remediation links, and the Microsoft Learn / aka.ms references in the version section - is now emitted as HTML `<a href="..." target="_blank">` (with `rel="noopener noreferrer"` on the prose links). Clicking a link opens the Azure portal blade or docs page in a new tab so the operator stays on the pipeline run page instead of being navigated away mid-investigation. Step.4 was already plain-URL only (no rendered hyperlinks), so it needed no change. CSV / JSON / JUnit artifacts continue to carry plain URLs - no schema or data shape changes.

### Fixed

- **Step.3 schedule-audit summary metric table reconciles when `IncludeUntagged: true`.** The summary metric table at the top of the GitHub Actions + Azure DevOps `Step.3_apply-updates-schedule-audit.yml` step summary surfaced only 7 of the 8 possible `Status` buckets - the `NoWindowTag` row (clusters with no `UpdateStartWindow` tag) was missing. Result: `(Ring, Window) pairs audited` did not equal the sum of the visible bucket counts (e.g. `audited=7` but `Covered+Uncovered+... = 6`) when at least one cluster fell into `NoWindowTag`. Added a `NoWindowTag` row to the metric table in both platforms; also wired it into the `$hasIssues` calculation so the action-required Recommend block surfaces when untagged clusters are present. No change to `Test-AzLocalApplyUpdatesScheduleCoverage` itself - the bug was purely in the pipeline summary aggregation.

### Added

- **Step.3 schedule-audit Recommend tier now emits TWO crons per window by default (belt-and-braces) + new `RingMixedWindows` warning bucket.** Previously the Recommend view emitted one cron per `UpdateStartWindow` segment, firing `LeadTimeMinutes` BEFORE the window opens. On heavily-loaded GitHub Actions schedules a single cron can be skipped by jitter (~15 min) on a tight maintenance window, and a transient first-fire failure (auth, runner pool exhaustion, module install hiccup) leaves the cluster un-updated for the day with no error.
  - **New `-RecommendFiresPerWindow` parameter on `Test-AzLocalApplyUpdatesScheduleCoverage`** (default `2`, range `1-2`). When `2`, each window emits the existing opening-edge cron plus a second `(retry)` cron INSIDE the window at the lesser of the midpoint or +60 minutes after the window opens.
  - **New `fires_per_window` (GH) / `firesPerWindow` (ADO) workflow input** on `Step.3_apply-updates-schedule-audit.yml` (default `2`, choice `1`/`2`) that flows through to the cmdlet.
  - **The runtime gate (`Test-AzLocalUpdateScheduleAllowed`) plus the existing in-flight guard prevent double-triggering.** Pass `1` to disable the retry tier (back-compat for pre-v0.7.92 callers).
  - **Audit semantics ("Covered" / "Uncovered") are unchanged in either mode** - the audit only requires the opening-edge cron to be present in the YAML. Only the Recommend snippet rendered for operators changes shape.
  - **New private helper signature**: `Convert-AzLocalUpdateWindowToCron` gains a `[ValidateRange(1,2)] [int] $FiresPerWindow = 1` parameter (default `1` preserves back-compat for Audit callers and existing tests). Every returned row now carries a new `IsRetry` boolean (`$false` for opening-edge, `$true` for the belt-and-braces retry).
  - **New `RingMixedWindows` informational status** (Section: `Schedule`) emitted by the Audit view when 2+ clusters share an `UpdateRing` tag but carry DIFFERENT `UpdateStartWindow` values (follow-the-sun, regional rollouts, or tagging mistakes). Each (Ring, Window) pair still gets its own per-pair coverage row above; the runtime gate reads each cluster's own tag so updates still fire correctly. The new bucket surfaces the divergence with a 3-choice recommendation (standardise via `Set-AzLocalClusterUpdateRingTag`, split into separate rings, or accept and document). **Not counted as `Uncovered`** - the pipeline does not gate on it (`$hasIssues` ignores `RingMixedWindows`).
  - **Pester coverage**: 8 new helper tests covering opening-edge + retry across short / 3h / 4h / 6h overnight / 24h / midnight-crossing / multi-segment windows, plus 4 new cmdlet tests covering Recommend default (`2`), Recommend explicit `1`, RingMixedWindows positive detection, and RingMixedWindows negative case.

### Migration

`Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`), then run `Update-AzLocalPipelineExample -Destination <path>` to refresh the `Step.9_*.yml`, `Step.8_*.yml`, `Step.7_*.yml` and `Step.3_*.yml` files. The Step.9 changes sit outside any `BEGIN-AZLOCAL-CUSTOMIZE` block, so operator customisations elsewhere in those pipelines are preserved.

## [0.7.91] - 2026-06-05

Docs/YAML-only patch release. No cmdlet behaviour changes, no schema changes, no breaking changes. Includes one urgent pipeline parser fix (Step.7) plus three cosmetic step-summary fixes (Step.3).

### Fixed

- **Urgent: `Step.7_monitor-updates.yml` (GH Actions + Azure DevOps) - PowerShell 7 parser error breaks the pipeline.** The "No update runs currently in flight" branch contained the literal sequence `\`update-monitor.csv\`` inside a double-quoted PowerShell string. The runner is PowerShell 7, which interprets the backtick that follows the backslash as the start of a `` `u{hex} `` Unicode escape; with no `{` following, the parser throws `The Unicode escape sequence is not valid` at parse time. GitHub Actions parses the whole `run:` block before executing it, so the failure surfaces at the `Import-Module` step with no usable diagnostics. Fixed by switching to the `` `` `` literal-backtick escape already used on the same line for `` ``InProgress`` ``. Operators running v0.7.90 should upgrade or hot-patch the two `Step.7_monitor-updates.yml` files immediately.
- **`Step.3_apply-updates-schedule-audit.yml` (GH Actions + Azure DevOps) - wrong cmdlet name in the per-ring-overrides tip.** The tip text referenced `Get-AzLocalUpdate -Status Ready`, which does not exist in the module. Replaced with the real exported cmdlet `Get-AzLocalAvailableUpdates`.
- **`Step.3_apply-updates-schedule-audit.yml` (GH Actions + Azure DevOps) - bogus example version strings in the per-ring-overrides tip.** The previous example showed `10.2604.0.123;10.2610.0.456`, which does not match Azure Local's real update naming and contradicted the canonical example in `apply-updates-schedule.example.yml`. Replaced with the canonical form `Solution12.2604.1003.1005;Solution12.2610.1003.XX`.
- **`Step.3_apply-updates-schedule-audit.yml` (GH Actions + Azure DevOps) - trailing literal `n` after the closing markdown code-fence.** The PowerShell here-string used `"``````n"` (missing a backtick before `n`), so the rendered job summary showed a stray `n` immediately after the closing ` ``` `. Fixed to emit the closing fence followed by a real newline.

### Migration

- Run `Update-AzLocalPipelineExample -Destination <path>` to refresh the four affected `Step.{3,7}_*.yml` files (two for each step, one per platform). All four fixes are outside `BEGIN-AZLOCAL-CUSTOMIZE` blocks, so any operator schedule customisations are preserved.

## [0.7.90] - 2026-06-04

New `UpdateExcluded` operator-override tag + breaking tag renames: `UpdateWindow` -> `UpdateStartWindow` and `UpdateExclusions` -> `UpdateExclusionsWindow`. Pipeline renumber: new `Step.7_monitor-updates` (operational in-flight monitor) inserted between Step.6 apply-updates and the existing daily snapshot pipelines, which shift to `Step.8_fleet-update-status` and `Step.9_fleet-health-status`.

### Added

- **Step.5 (assess-update-readiness) markdown summary redesign** (GH + ADO). Re-ordered into audit-priority sections so blocking findings come first: (1) one-line **header tile** showing `[ATTENTION]` / `[OK]` plus Ready/Not-Ready/Critical counts and scope, (2) **action banner**, (3) summary counts table, (4) **Not-Ready clusters** table (review first - with new `UpdateRing` and `BlockingReasons` columns), (5) **Critical-health clusters** table (cross-linked to Step.4 and Step.9), (6) **per-UpdateRing pivot** breakdown (shown when >1 ring in scope), (7) all-clusters detail table sorted by `UpdateRing` then `ClusterName`, and (8) **cross-links** to Step.4 / Step.6 / Step.7 / Step.9. The job now always fetches `Get-AzLocalClusterInventory` to build the resource-id -> UpdateRing map.
- **Step.5 combined JUnit XML emission** (GH + ADO). The two existing per-component XMLs (`readiness.xml` + `health-blocking.xml`) are merged into a single `assess-readiness.xml` with a `<testsuites>` root wrapping both `<testsuite>` children. New publisher **"Update Readiness Assessment"** surfaces this combined view as the primary Checks/Tests entry; the existing `[JUnit Debug]` publishers remain for drill-down. Operators get one consolidated view instead of two adjacent entries.
- **6 new dedicated per-pipeline smoke-test harnesses** in `Tools/`, matching the existing `validate-arg-queries.ps1` style (PASS / PASS-EMPTY / FAIL-SCHEMA / ERROR classification, summary table, exit 1 on any failure): `smoke-test-inventory.ps1` (Step.1), `smoke-test-schedule-audit.ps1` (Step.3), `smoke-test-assess-readiness.ps1` (Step.5 - includes the v0.7.90 merged-JUnit wiring), `smoke-test-monitor-updates.ps1` (Step.7), `smoke-test-fleet-update-status.ps1` (Step.8), `smoke-test-fleet-health-status.ps1` (Step.9). Plus a new coverage matrix: `Tools/SMOKE-COVERAGE.md`.
- **New `Step.7_monitor-updates.yml` pipeline (GitHub Actions + Azure DevOps).** Operational in-flight monitor distinct from the daily Step.8 snapshot. Reports clusters whose latest update run is currently `InProgress`, with the CURRENT STEP each cluster is on, the PROGRESS (`completed/total steps`), and the ELAPSED DURATION. Long-running runs are flagged via a configurable `long_running_threshold_hours` input (default 6h). Emits `update-monitor.xml` (JUnit, one `<testcase>` per in-flight cluster; `<failure>` when the elapsed duration exceeds the threshold so the Checks/Tests tab shows stuck runs in red) + `update-monitor.csv` + a markdown step summary sorted by elapsed duration descending. Designed for ~30-minute cadence during an active wave (GitHub Actions only - ADO YAML schedules are limited to hourly). Pure pipeline composition over `Get-AzLocalUpdateRuns -Latest` - no new cmdlets required.
- **New `UpdateExcluded` Azure resource tag** (operator hard override). When set to `True`/`true`/`1` on a cluster, `Start-AzLocalClusterUpdate` skips the cluster with `Status = ExcludedByTag` **regardless of `UpdateRing` scope, `UpdateSideloaded` state, or `UpdateStartWindow` / `UpdateExclusionsWindow` schedule**. Empty/missing tag means no override. Malformed values throw (fail-closed) unless `-Force` is supplied. New gate runs BEFORE the sideloaded and schedule gates so it overrides both.
- **`Set-AzLocalClusterUpdateRingTag` always stamps `UpdateExcluded=False`** on any cluster that does not already carry the tag, so the tag is discoverable in the Azure portal and ready for an operator to flip to `True` when they need to temporarily exclude a cluster from automation. Existing `True`/`False` values are preserved unless overridden.
- **New optional parameter `-UpdateExcludedValue` on `Set-AzLocalClusterUpdateRingTag -ClusterResourceIds`** and new CSV column `UpdateExcluded` on the `-InputCsvPath` mode. Accepts `True`/`False`/`1`/`0` (case-insensitive). Mirrors the existing `UpdateStartWindow` / `UpdateExclusionsWindow` plumbing.
- **New private helpers**: `ConvertFrom-AzLocalUpdateExcluded` (strict parser) and `Test-AzLocalUpdateExcludedAllowed` (gate evaluator).
- **`Get-AzLocalClusterInventory` CSV/JSON export** now includes an `UpdateExcluded` column (positioned between `UpdateExclusionsWindow` and `UpdateSideloaded`).
- **Apply-updates pipeline summaries** (Step.6 GH Actions + Azure DevOps) now count and report `ExcludedByTag` clusters alongside `ScheduleBlocked` / `SideloadedBlocked`, with an Actions Required callout pointing operators at the tag.

### Changed

- **Pipeline renumber (BREAKING for any local automation that pins to the old filenames):** the `fleet-update-status` example pipeline becomes `Step.8_fleet-update-status.yml` (was `Step.7`) and `fleet-health-status` becomes `Step.9_fleet-health-status.yml` (was `Step.8`). Inline content of both renamed files is otherwise byte-identical with the v0.7.89 / v0.7.88 versions apart from header self-references. The new monitor pipeline takes the `Step.7` slot. Apply via `Copy-AzLocalPipelineExample -Destination <path> -Update` and then `git rm` the old files locally - the helper does not delete by name.
- **Step.8 (fleet-update-status, formerly Step.7) - "Overall Fleet Update Status (Version Distribution)" markdown table redesigned to pivot by YYMM** (operator request). The leading column is now `Version` showing the YYMM (e.g. `2511`, `2604`); a new `Update Versions` column lists each distinct full `CurrentVersion` within that YYMM as `<version> x <count>` separated by `<br>` line breaks (e.g. `12.2604.1003.1005 x 12<br>12.2604.1003.1002 x 6<br>12.2604.1003.209 x 2`). `Cluster Count` and `Percentage` are summed across all full versions in the YYMM; `Clusters (first 15 shown only)` is the de-duplicated union of cluster names. Rows are sorted by `Version` (YYMM) **ascending - oldest at top** (was: cluster count descending), with malformed/empty YYMMs grouped under `(unknown)` at the bottom. The underlying `<testsuite name="Fleet Version Distribution">` JUnit XML continues to emit one `<testcase>` per distinct full `CurrentVersion` (unchanged), so machine-readable consumers are unaffected.

### Changed (BREAKING)

- **Tag rename: `UpdateWindow` -> `UpdateStartWindow`**. The module from v0.7.90 onwards only reads `UpdateStartWindow` from cluster tags. Clusters still carrying the legacy `UpdateWindow` tag are silently ignored - their maintenance windows will no longer be honoured. Operators must re-tag (`Set-AzLocalClusterUpdateRingTag` with a CSV that has the new column name, or `az tag update --operation Merge`) before the next apply-updates run. The tag VALUE format (`<days>_<HH:MM>-<HH:MM>` in UTC, semicolon-separated) is unchanged.
- **Tag rename: `UpdateExclusions` -> `UpdateExclusionsWindow`**. Same migration story: module only reads `UpdateExclusionsWindow` from v0.7.90 onwards; clusters still carrying `UpdateExclusions` lose blackout enforcement until re-tagged. Tag VALUE format (`YYYY-MM-DD/YYYY-MM-DD`, comma-separated, `*` wildcards) is unchanged.
- **Parameter rename on `Test-AzLocalUpdateScheduleAllowed`**: `-UpdateWindow` -> `-UpdateStartWindow` and `-UpdateExclusions` -> `-UpdateExclusionsWindow`. Any caller passing an old parameter name will fail with a binding error.
- **Parameter rename on `Set-AzLocalClusterUpdateRingTag -ClusterResourceIds`**: `-UpdateWindowValue` -> `-UpdateStartWindowValue` and `-UpdateExclusionsValue` -> `-UpdateExclusionsWindowValue`. CSV column renames: `UpdateWindow` -> `UpdateStartWindow`, `UpdateExclusions` -> `UpdateExclusionsWindow`.
- **Property rename on result objects** from `Get-AzLocalClusterInventory`, `Get-AzLocalClusterUpdateReadiness`, and `Get-AzLocalFleetStatusData`: `UpdateWindow` -> `UpdateStartWindow`, `UpdateExclusions` -> `UpdateExclusionsWindow`. Downstream CSV/JSON consumers must update column names.

### Migration

- **Re-tag clusters that currently have `UpdateWindow` and/or `UpdateExclusions` set.** Legacy tag values are NOT auto-copied. Operators must mirror them onto the new tags and then delete the old ones, for example:

  ```pwsh
  az tag update --resource-id <clusterId> --operation Merge --tags UpdateStartWindow='<existing-UpdateWindow-value>' UpdateExclusionsWindow='<existing-UpdateExclusions-value>'
  az tag update --resource-id <clusterId> --operation Delete --tags UpdateWindow='<old-value>' UpdateExclusions='<old-value>'
  ```

  Or re-run `Set-AzLocalClusterUpdateRingTag -InputCsvPath <csv>` with a CSV that has the new `UpdateStartWindow` / `UpdateExclusionsWindow` columns.
- **Pipelines:** `Copy-AzLocalPipelineExample -Destination <path> -Update` to pick up the renamed CSV columns + new `ExcludedByTag` summary plumbing.
- The new `UpdateExcluded=False` default-stamp is additive - no operator action required. It just makes the tag visible in the portal so operators can flip it to `True` when they need to temporarily exclude a cluster from automation.

## [0.7.89] - 2026-05-23

### Added

- **`apply-updates-schedule.yml` schema v2 - new MANDATORY top-level `allowedUpdateVersions` allow-list field plus optional per-row override.** Customer feedback verbatim: *"if a customer only wants to install the 'Minimum number of updates', which is around 4 updates a year, with the YY04 and YY10 being mandatory feature updates, and the cumulative update before each feature update (YY03 and YY09) also sometimes being mandatory, can we have optional logic that we can define in the schema of the `apply-updates-schedule.yml` update, where we can list a specific list of updates that we only want to install, fleet wide, and/or per ring, to allow us to define an `allow list` of updates manually?"* The reserved sentinel `Latest` (case-insensitive, canonicalised to PascalCase) means "no constraint - install the latest Ready update on each cluster" (= historic v0.7.88 default). When the allow-list is set to an explicit list, Step.6 (apply-updates) will only install updates whose `.name` OR `.properties.version` is an EXACT (case-insensitive) match for one of the listed entries. If a cluster has no Ready update in the list, the cluster is **SKIPPED** with new status `NotInAllowList` (strict no-op; the picker never falls back to "latest Ready"). Format mirrors the existing `rings:` convention (semicolon-separated string). **Mixing `Latest` with explicit versions in a single field (e.g. `'Latest;10.2604.0.123'`) is REJECTED** - to combine the sentinel with explicit versions, use the cross-row UNION (see resolver semantics below).
- **`Start-AzLocalClusterUpdate -AllowedUpdateVersions [string[]]`** new parameter (optional). When set (and not equal to `Latest`), restricts the auto-pick pool BEFORE the YYMM-latest selector runs. `Latest` (case-insensitive) is treated as "no allow-list" and skips filtering (logged-Info). When BOTH `-UpdateName` and `-AllowedUpdateVersions` are supplied, the explicit `-UpdateName` wins (allow-list logged-and-ignored with a Warning). New CSV/result status `NotInAllowList` is emitted when filtering eliminates every Ready update.
- **`Resolve-AzLocalCurrentUpdateRing`** returns three new properties: `AllowedUpdateVersions [string[]]`, `AllowedUpdateVersionsValue [string]` (`;`-joined for env-var bridge), `AllowedUpdateVersionsSource ('row' | 'top-level' | 'none')`. **Precedence:** per-row OVERRIDES top-level. Multiple matching rows UNION their allow-lists; rows WITHOUT the field on a UNION day are treated as "no opinion" (not "allow nothing"). Top-level only kicks in when ZERO matching rows specify the field. **`Latest` collapse:** when the resolved UNION contains the `Latest` sentinel (from any contributing row or top-level), the effective `AllowedUpdateVersions` collapses to an empty array (= no constraint) and the picker installs the latest Ready update. The `Source` field is retained so audit logs explain WHERE the `Latest` decision came from.
- **Schema migration recipe `1 -> 2`** registered in `Private/Convert-AzLocalScheduleSchemaVersion.ps1`. Customer v1 schedule files are migrated additively: `schemaVersion: 1` -> `schemaVersion: 2`, a documented commented-out `# allowedUpdateVersions:` example block is inserted above the `# ---- Schedule entries` banner, AND an ACTIVE `allowedUpdateVersions: 'Latest'` line is inserted so the migrated file satisfies the new mandatory rule with zero behaviour change. Existing schedule rows + customer comments are preserved verbatim. The recipe is idempotent (marker-guarded with `# >>> ALLOWED-UPDATE-VERSIONS-V2 <<<`). Run via `Update-AzLocalApplyUpdatesScheduleConfig`.
- **New private helper `Test-AzLocalAllowedUpdateVersionsString`** shared between the top-level and per-row validation paths. Rejects non-strings, empty/whitespace, empty tokens after split-and-trim (e.g. `'a;;b'`), whitespace inside a token; canonicalises the `Latest` sentinel (case-insensitive) to PascalCase; rejects mixed `Latest`+explicit within a single field; deduplicates case-insensitively preserving first-occurrence order.
- **Audit pipeline (Step.3) Allow-list coverage section.** `Test-AzLocalApplyUpdatesScheduleCoverage` audit Markdown now includes a new "Allow-list coverage" section that prints (a) the top-level fleet default, (b) a per-row table of effective `allowedUpdateVersions` after row > top-level resolution, and (c) recommendation yaml snippets for the first 3 rows that inherit from top-level (helps operators decide whether each ring should keep `Latest` or pin a specific list). v1 schedules see a migration nudge pointing at `Update-AzLocalApplyUpdatesScheduleConfig -SchemaMigrate`.

### Changed

- **Validator (`Get-AzLocalApplyUpdatesScheduleConfig`)** now accepts `schemaVersion: 1` OR `2`. **v2 files MUST have a top-level `allowedUpdateVersions:` field** - omitting it on v2 is rejected with a remediation message ("Schema v2 requires a top-level `allowedUpdateVersions:` field. Set it to `'Latest'` to preserve the historic no-constraint behaviour, or to an explicit list to enforce a minimum-updates policy."). v1 files containing `allowedUpdateVersions` (top-level OR per-row) are rejected with a remediation pointing at the schema migrator. v2 field values are parsed and validated; the resulting `[string[]]` is stamped on `$cfg.AllowedUpdateVersions` (top-level) and `row.AllowedUpdateVersionsParsed` (per row).
- **Generator (`New-AzLocalApplyUpdatesScheduleConfig`)** now emits `schemaVersion: 2` with an ACTIVE top-level `allowedUpdateVersions: 'Latest'` line (default = no constraint) plus commented `# allowedUpdateVersions: '<explicit>'` example blocks at both top-level and per-row positions, plus a row-fields documentation block describing the new field.
- **`Automation-Pipeline-Examples/apply-updates-schedule.example.yml`** updated to schema v2 with the new MANDATORY top-level `Latest` default documented + a per-row override worked example on the Phase-4 production row (illustrating "Prod ring waits for feature updates"). Customer's "minimum updates" use case explicitly called out in the section header.
- **`Automation-Pipeline-Examples/README.md`** new Section 8.4 "Restrict which updates each ring installs (`allowedUpdateVersions`, schema v2)" with 5 subsections (8.4.1 model + precedence; 8.4.2 worked example yaml; 8.4.3 finding update names via `Get-AzLocalUpdate` / Azure portal; 8.4.4 v1->v2 migration via `Update-AzLocalApplyUpdatesScheduleConfig`; 8.4.5 audit pipeline support).
- **Step.6 GitHub Actions + Azure DevOps templates plumb the allow-list end-to-end:** `check-readiness` resolver now exports `RESOLVED_ALLOWED_UPDATE_VERSIONS` alongside `RESOLVED_UPDATE_RING`. The apply step consumes it, parses to `[string[]]`, and passes via `-AllowedUpdateVersions` to `Start-AzLocalClusterUpdate`. `workflow_dispatch` / non-Schedule build reasons pass empty (manual runs are not subject to the allow-list - operators get the historic behaviour). `NotInAllowList` is added to the `skipped` result-counter bucket so the per-stage summary KPIs stay correct.
- **Step.3 audit Markdown rendering: Schedule diff table gate fix.** Previously `$haveSchedule` was set inside the audit step but undefined in the summary step's scope (separate `pwsh` process), causing the Schedule diff table to silently not render even when `RingMissingFromSchedule` / `RingOrphanedInSchedule` rows were present in the audit data. `HAVE_SCHEDULE` + `SCHEDULE_PATH` are now exported via `GITHUB_OUTPUT` (GitHub) / `setvariable ... isOutput=true` (Azure DevOps) from the audit step to the summary step; the gate is also defensive (fires when `$haveSchedule -or $scheduleRowsMd.Count -gt 0`).

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.88'` to `'0.7.89'`. Inline-script content changes: `Step.6_apply-updates.yml` (both platforms) for end-to-end allow-list plumbing; `Step.3_apply-updates-schedule-audit.yml` (both platforms) for the Schedule-diff gate fix + new Allow-list coverage section. The other 14 are pin-only bumps.

### Migration

- **Module:** `Install-Module AzLocal.UpdateManagement -Force`. `Start-AzLocalClusterUpdate` gains the optional `-AllowedUpdateVersions` parameter (default = unset OR `Latest` = historic "install latest Ready update" behaviour unchanged).
- **Pipelines:** re-copy the bundled YAMLs with `Copy-AzLocalPipelineExample -Destination <path> -Update` to pick up Step.6's allow-list plumbing, Step.3's Schedule-diff + Allow-list coverage sections, and the 18-template pin bump.
- **`apply-updates-schedule.yml`:** if you have a v1 schedule file checked in, run `Update-AzLocalApplyUpdatesScheduleConfig -Path <path>` to migrate it to v2. The migrator inserts an active `allowedUpdateVersions: 'Latest'` so the migrated file satisfies the new mandatory rule with zero behaviour change. Operators can change `Latest` to an explicit list (e.g. `'10.2604.0.123;10.2610.0.456'`) at any time. Or hand-edit: bump `schemaVersion: 1` to `schemaVersion: 2` AND add `allowedUpdateVersions: 'Latest'` (or explicit) at top-level. Files left at v1 continue to work; only the new field is rejected on v1.

## [0.7.88] - 2026-05-22

### Changed

- **Step.8 `fleet-health-status` step-summary section order rearranged so that the per-cluster fleet rollup is visible above the failure breakdown.** Both the GitHub Actions and Azure DevOps Step.8 pipelines now render `### Fleet Health Overview (fleet rollup)` immediately below the KPI summary table (Total Clusters in Subscription / Healthy / Unhealthy / Total Failing Checks / Critical / Warning / Distinct Failure Reasons) and ABOVE `### Health Check Failures By Reason (most widespread first)`. The previous order placed the fleet rollup at the very end of the markdown summary, requiring operators to scroll past `Failures By Reason` and `Detailed Results (per-cluster, per-failure)` to see the at-a-glance per-cluster context (Health status, Update Status, current version, SBE version, Azure Connection state, last-check timestamp + age, node count). New order: **KPI summary table -> Fleet Health Overview (fleet rollup) -> Health Check Failures By Reason -> Detailed Results -> Reports Available**.
- **Step.8 `Fleet Health Overview` table - column rename: `Age (days)` -> `Health Check Age (days)`.** The previous label was ambiguous - it could plausibly have meant cluster age, node age, current-version age, or update-readiness age. The new label is unambiguous: it is the age in days of the cluster's last 24-hour Azure Stack HCI health-check result (sourced from `Get-AzLocalFleetHealthOverview.HealthResultsAgeDays`; the same value the `Last Checked` neighbour column derives from). Negative values continue to mean "no LastChecked timestamp at all" - i.e. the health check has not run since the cluster was Arc-onboarded.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.87'` to `'0.7.88'`. Only `Step.8_fleet-health-status.yml` had inline-script content changes; the other 17 are pin-only bumps.

### Migration

- **Module:** no public-surface changes - `Install-Module AzLocal.UpdateManagement -Force` is enough.
- **Pipelines:** the Step.8 markdown summary edit is the entire reason to refresh - re-copy the bundled YAMLs with `Copy-AzLocalPipelineExample -Destination <path> -Update` to pick up both the section reorder + column rename and the pin bump.

## [0.7.87] - 2026-05-23

### Added

- **New public function `New-AzLocalFleetConnectivityStatusSummary`** in `Public/`. A pure markdown renderer that builds the Step.4 fleet-connectivity step-summary previously inlined as a ~22 KB `pwsh` body in both pipelines. The function consumes the seven CSV reports produced earlier in the pipeline by `Get-AzLocalFleetConnectivityStatus` (or the equivalent in-memory object arrays via the `FromObjects` parameter set) plus an explicit `-Counts` hashtable of KPI totals. It is a pure renderer over already-collected data - no Azure CLI, no Resource Graph extension, no `Az.*` modules required, no re-querying Azure. Returns markdown string by default; supports `-OutputPath` (UTF-8 no-BOM) and `-PassThru` to combine both. ASCII source with Unicode emoji icons emitted via `[char]0xNNNN`.
- **Pester regression guard for the GitHub Actions 21,000-char expression-length cap.** The new `Regression v0.7.87: bundled GitHub Actions YAML run: blocks stay under GitHub 21,000-char expression cap` Describe block enumerates every `run:` (and `script:`) literal block scalar in every bundled `github-actions/Step.{0..8}.yml` template and asserts each is below 18,000 chars. The 3K headroom under the 21K cap covers future feature growth and possible future re-introduction of `${{ }}` substitutions (the cap applies to the post-substitution length of any `run:` body that contains at least one `${{ }}`). Two additional asserts verify both the GH and ADO Step.4 YAMLs CALL the new renderer function (no inline 22 KB markdown).
- **Comprehensive Pester unit-test coverage for the new renderer**: parameter-set validation, `Counts` hashtable required-key validation (and string-value coercion), markdown structure (KPI table, reconciliation table, How-to-interpret subsection, cluster+ARB table, orphan ARBs, Arc summary, non-connected machines, NIC stats, NIC issues, reports list, generated-at footer), empty-input placeholders ("No clusters returned.", "All machines are Connected.", "No physical NIC issues."), orphan-ARB section conditionality, multi-cluster-per-RG ARB matching (comma-separated `ClusterId`), `-OutputPath` writes UTF-8 no-BOM and creates parent directories, `-PassThru` semantics, CSV-based `FromCsvReports` parameter set with graceful missing-CSV handling.

### Changed

- **`github-actions/Step.4_fleet-connectivity-status.yml`**: the 283-line, 20,460-char inline pwsh markdown renderer has been replaced with a 23-line body that calls `New-AzLocalFleetConnectivityStatusSummary`. File shrunk from 863 to 603 lines. The renderer step's `run:` body is now ~1,083 chars - a 95% reduction. The renderer step continues to use the step-level `env:` pattern introduced in v0.7.86 (zero `${{ }}` substitutions in the body, so the 21K cap does not apply at all).
- **`azure-devops/Step.4_fleet-connectivity-status.yml`**: equivalent refactor against the ADO twin so both pipelines call the same module function (single source of truth). As a side-effect this fixes a pre-existing structural anomaly: the Display Summary step's pwsh literal block scalar had silently absorbed the `displayName:` + `condition:` + `env:` indented entries and the subsequent `PublishTestResults@2` task (because L713-L727 sat at indent 12-16 while the block scalar base was indent 8), so the parsed ADO pipeline used to have only 10 steps. After v0.7.87 the parsed pipeline has 11 steps, with `Display Fleet Connectivity Summary` and `Publish Fleet Connectivity JUnit Diagnostics` now real, distinct ADO tasks that actually run.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.86'` to `'0.7.87'`.

### Migration

- **Module:** run `Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). The new public function is exported automatically. No call-site changes are needed for any existing function.
- **Pipelines:** the Step.4 GH + ADO YAML refactors require the v0.7.87 module to be installed on the pipeline runner (the new `New-AzLocalFleetConnectivityStatusSummary` cmdlet must be on `Get-Command`). Re-copy the bundled YAMLs with `Copy-AzLocalPipelineExample -Destination <path> -Update` to pick up both the Step.4 refactor and the pin bump. If you stay on the v0.7.86-pinned YAMLs they will continue to work (they call into the v0.7.86 module which does not yet have the new function).

### Background

v0.7.85 added a long-form `How to interpret + act on a non-zero reconciliation` subsection to the Step.4 markdown summary. The combined `run:` body in `github-actions/Step.4_fleet-connectivity-status.yml` grew from <21K to ~23.9K chars. Because the body contained 11 `${{ steps.fleet-connectivity.outputs.X }}` substitutions, GitHub Actions parsed the whole `run:` value as a single expression and hit its 21,000-char expression-length cap at workflow-parse time (`Exceeded max expression length 21000`). v0.7.86 mitigated by moving the 11 step-output substitutions to a step-level `env:` block (the `run:` body then has zero `${{ }}` substitutions, so the cap stops applying). v0.7.87 ships the durable fix: extract the renderer into a public module function so both pipelines call one place, the renderer becomes unit-testable, and a Pester regression guard catches any future regression before it hits production parsing. The ADO structural anomaly is fixed as a side-effect of the same refactor.

## [0.7.86] - 2026-05-22

### Changed

- **`Automation-Pipeline-Examples/README.md` refreshed end-to-end** to bring the runbook in lock-step with the actual 9-step pipeline lineup (`Step.0` Authentication Test through `Step.8` Fleet Health Status). Stale counts (`seven`/`eight pipelines`, `Step.7 last`) corrected to `nine`/`Step.8 last`; section 1.1 mapping table re-rendered so `Step.4 = Fleet Connectivity Status` (the table had silently shifted off-by-one from when Step.4 was inserted in v0.7.79, mis-labelling Step.5..Step.8); section 6.6 fleet-monitoring narrative now covers all three daily steady-state pipelines (Step.4 + Step.7 + Step.8) including the v0.7.85 reconciliation enhancements and the four ARM/ARG scopes Step.4 reads (`Microsoft.ResourceGraph/resources/read`, `Microsoft.AzureStackHCI/edgeDevices/read`, `Microsoft.HybridCompute/machines/read`, `Microsoft.ResourceConnector/appliances/read`); section 13 file layout re-listed in `Step.0..Step.8` numeric order with descriptive comments + cron schedules.
- **`Automation-Pipeline-Examples/docs/appendix-pipelines.md` renumbered + extended.** Sections renumbered from `A.1..A.7` (which had silently drifted off-by-one) to `A.0..A.8` so the appendix section number always matches its `Step.N_*.yml` filename. Two new sections added: `A.0 Authentication Validation and Subscription Scope Report` (v0.7.70) and `A.4 Fleet Connectivity Status` (v0.7.79+; reconciliation enhanced in v0.7.85). The default-triggers at-a-glance table at the top now lists all 9 pipelines (added rows for `authentication-test` and `fleet-connectivity-status`). A new "Numbering convention" callout clarifies that `A.N` mirrors `Step.N` (not execution order). Stale in-file anchor links repaired (`#a4-apply-updates` -> `docs/appendix-pipelines.md#a6-apply-updates`; `#83-end-to-end-runbook-...` -> `../README.md#83-...`; `#8-scheduling-...` -> `../README.md#8-scheduling-...`).
- **`ITSM/README.md` updated to list four ITSM-wired pipelines instead of three.** Step.4 `fleet-connectivity-status` has shipped with opt-in ServiceNow ticketing since v0.7.76 (gated on `raise_itsm_ticket=true`, sourcing `./reports/fleet-connectivity-status.xml`, using the existing `Critical`/`Warning` rows in the trigger matrix), but the ITSM README was never updated when that wiring shipped - it still described Step.6 / Step.7 / Step.8 only. Section 1 "What this connector does" now lists Step.4 alongside the other three, a new v0.7.76 callout documents the Step.4 wiring (including the distinct per-resource `UpdateName` patterns Step.4 emits: `ClusterConnectivity=...`, `ArcAgent=... [<NodeName>]`, `PhysicalNic=... [<NodeName>/<NicName>]`, `ARB=... [<ArbName>]` - so the SHA256 dedupe key naturally separates a cluster-level disconnect from an individual NIC / Arc-agent / ARB failure), and the section 8 wiring table includes a Step.4 row. The header version pin also bumped from `v0.7.70` to `v0.7.86`.
- **`Automation-Pipeline-Examples/README.md` section 16 "Related documentation"** now cross-links the three top-level reference docs (`docs/concepts.md`, `docs/rbac.md`, `docs/troubleshooting.md`) directly from the CI/CD runbook. Previously these were only reachable from the top-level module README, so an operator who arrived directly at the CI/CD runbook had no obvious path to the glossary, full RBAC reference, or module-level troubleshooting matrix.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.85'` to `'0.7.86'`. **No inline-script changes** in any YAML.

### Migration

- **Module:** no action required. `Install-Module AzLocal.UpdateManagement -Force` is enough.
- **Pipelines:** content edits are limited to the human-facing README + appendix; the YAML inline scripts are unchanged. Re-copy the bundled YAMLs only if you want to refresh the `GENERATED_AGAINST_MODULE_VERSION` pin (`Copy-AzLocalPipelineExample -Destination <path> -Update`).

### Background

While reviewing PR #56 before merging v0.7.85, the `Automation-Pipeline-Examples` README and appendix were found to still describe the seven-pipeline layout from before `Step.4 Fleet Connectivity Status` was inserted (v0.7.79) and before `Step.0 Authentication Test` was added (v0.7.70). The follow-up audit also caught two related cross-doc gaps: `ITSM/README.md` had never been updated to reflect that Step.4 ships with opt-in ServiceNow ticketing (v0.7.76 Phase D extension), and the CI/CD `Automation-Pipeline-Examples/README.md` had no direct cross-link to the top-level `docs/concepts.md` / `docs/rbac.md` / `docs/troubleshooting.md` references. The bundled YAMLs themselves were correct; only the human-facing setup runbooks were stale. v0.7.86 republishes the module with the corrected docs.

## [0.7.85] - 2026-05-21

### Changed

- **`Step.4` `Node + ARB Coverage Reconciliation` table now reads as a bidirectional consistency check + offers actionable remediation** (operator feedback against v0.7.84 production output).

  - **Column rename: `Arc-joined physical nodes` -> `Arc-tagged physical nodes`.** The previous label was a misnomer: this value has never been a join against `cluster.reportedProperties.nodes`. It is the raw count of `microsoft.hybridcompute/machines` carrying `properties.detectedProperties.cloudprovider=AzSHCI` and `kind!=HCI`. The rename + the Notes column rewrite make it explicit that this value comes from a separate KQL query and can legitimately be greater or less than the cluster-reported sum.
  - **Notes column: `Cluster-reported node count (sum)`.** Fixed stale wording that still referenced the pre-v0.7.84 non-existent `nodeCount` scalar property. Now correctly describes the value as `Sum of array_length(properties.reportedProperties.nodes) across all clusters`.
  - **Notes column: `Node coverage delta`.** Rewritten with explicit BIDIRECTIONAL semantics. POSITIVE (cluster-reported > Arc-tagged) means clusters claim more nodes than Arc has, with likely causes: Arc-onboarding lag, deleted Arc resource, missing `AzSHCI` provider tag, or stale `cluster.reportedProperties.nodes` array. NEGATIVE (Arc-tagged > cluster-reported) means Arc sees AzSHCI machines that no in-scope cluster claims, with likely causes: orphan/decommissioned Arc resource, pre-staged-but-not-yet-joined node, or mis-tagged non-cluster machine.
  - **Intro paragraph rewritten** to point operators to the new `### How to interpret + act on a non-zero reconciliation` subsection below the table whenever a delta row is non-zero.

### Added

- **New `### How to interpret + act on a non-zero reconciliation` subsection** appended to the Step.4 step-summary `$md` here-string, after the reconciliation table and before the per-cluster connectivity table. Provides:

  - Per-direction remediation lists for `Node coverage delta` POSITIVE (Arc-onboarding lag -> wait + re-run; Arc resource deleted -> `azcmagent connect`; missing `AzSHCI` tag -> re-run onboarding extension; stale `cluster.reportedProperties.nodes` -> compare with `Get-ClusterNode`) and NEGATIVE (orphan/decommissioned Arc resource -> delete or re-attach; pre-staged node -> wait; mis-tagged machine -> clear tag).
  - **Inline Resource Graph query template** to enumerate the specific Arc machines causing a NEGATIVE node coverage delta (`resources | where type =~ 'microsoft.hybridcompute/machines' | where ... cloudprovider == 'azshci' | where parentClusterId notin~ (...)`).
  - Cause + remediation list for `Clusters without an ARB > 0` (ARB never deployed -> AzSHCI extension installer; ARB deleted but cluster present -> portal Connect; RP not registered -> `az provider register --namespace Microsoft.ResourceConnector`).
  - Cause + remediation list for `Orphan ARBs > 0` (cluster deleted but ARB not cleaned up; ARB in different sub/RG than the cluster it serves; ARB for a cluster excluded from the current run).

### Tests

- Existing Step.4 static-content guards (`Regression v0.7.83` block) re-checked: none keyed off any of the renamed/rewritten strings, so no test changes required for the YAML edits. Module version pin updated from `'0.7.84'` to `'0.7.85'`.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.84'` to `'0.7.85'`. Only `Step.4_fleet-connectivity-status.yml` had inline-script content changes; the other 17 are pin-only bumps.

### Migration

- **Module:** no action required. `Install-Module AzLocal.UpdateManagement -Force` is enough.
- **Pipelines:** to pick up the enhanced Step.4 step-summary in your CI, run `Copy-AzLocalPipelineExample -Destination <path> -Update` to refresh the bundled `Step.{0..8}.yml` templates.

### Background

This is a follow-up to v0.7.84 which fixed the underlying correctness bugs in `Get-AzLocalFleetConnectivityStatus`. After v0.7.84 shipped, a production operator running Step.4 against a 20-cluster fleet saw `Node coverage delta = -6` (cluster-reported = 38, Arc-tagged = 44) and asked what it meant. The label `Arc-joined physical nodes` (implying a join was computed) and the one-directional caption (which only described positive-delta causes) made it harder than necessary to interpret. v0.7.85 makes the table self-explanatory and actionable so operators can act on non-zero numbers without external context.

## [0.7.84] - 2026-05-21

### Fixed

- **HOTFIX: `Get-AzLocalFleetConnectivityStatus` (Step.4 fleet-connectivity summary): 4 correctness bugs surfaced against a real 20-cluster fleet.** Reported via a real GitHub Actions Step.4 run on 2026-05-21 (the same run that surfaced and validated the v0.7.83 hotfix). All four are pure read-path correctness fixes; no behavioural changes to writes/state.

  - **Bug A - `Nodes` column = 0 for every cluster + `Cluster-reported node count (sum)` = 0 + `Node coverage delta` = -(Arc-joined node count).** Root cause: the code read `properties.reportedProperties.nodeCount` which does NOT exist in the Azure Local cluster ARG schema. The correct property is `properties.reportedProperties.nodes` - an ARRAY of node objects. All clusters reported 0 nodes regardless of actual size; the delta math then attributed every Arc-joined node as missing cluster coverage. **Fix:** `$nodes = Get-NestedProp $r 'properties.reportedProperties.nodes'; $nodeCount = if ($nodes) { @($nodes).Count } else { 0 }`.

  - **Bug B - `Non-Connected Machines` table `ClusterName` column corrupted to a single character** (cluster `Mobile` -> `e`, `alrs-cc` -> `c`, etc.). Root cause: `CoerceStr (([string]($clusterId -split '/'))[-1])` applied the `[string]` cast to the WHOLE split ARRAY (PowerShell array-to-string coercion joins elements with single spaces), then `[-1]` indexed the resulting joined STRING and returned the last CHARACTER instead of the last array element. **Same bug class as v0.7.82/v0.7.83 [char].Trim() scalar-collapse.** Fix: drop the `[string]` cast so `[-1]` indexes the split array directly. `$clusterName = if ($clusterId) { CoerceStr (($clusterId -split '/')[-1]) } else { '' }`.

  - **Bug C - `Azure Resource Bridges` table `DaysSinceLastModified` = -1 for EVERY ARB (Running and Offline).** Two root causes:
    1. The default ARG `resources` response sometimes omitted/stripped `systemData` so `Get-NestedProp $a 'systemData.lastModifiedAt'` returned `$null` -> code fell through to the `-1` sentinel.
    2. Running ARBs were intentionally short-circuited to `-1` as an opaque "N/A" sentinel - confusing because the column header gave no indication that -1 meant "Running".

    **Fix (1):** the ARB KQL now explicitly extends the field with `| extend lastModifiedAt = tostring(systemData.lastModifiedAt)` so the column is guaranteed top-level. Read order is `$a.lastModifiedAt` first, fall back to `systemData.lastModifiedAt` if absent (defence in depth). **Fix (2):** dropped the Running short-circuit so real days is computed for ALL ARBs regardless of status. `-1` is now reserved only for genuinely missing or unparseable timestamps.

### Added

- **Cross-call ARG throttle cooldown (`Invoke-AzResourceGraphQuery`).** Complements the v0.7.68 per-page retry loop with cross-call coordination: when one call observes ARG throttling, subsequent calls voluntarily sleep out a short cooldown window on entry before issuing their first page request. This addresses the fan-out fleet-query case (e.g. `Get-AzLocalFleetConnectivityStatus` issues 5 sequential ARG calls; the v0.7.68 retry handles bursts within one call but call N+1 was starting from zero and could immediately re-hit the limiter). State is module-scope: `$script:ArgCrossCallCooldownUntil` ([DateTime]) and `$script:ArgConsecutiveThrottledCalls` (counter, capped at 5). Cooldown duration scales with the helper's `-RetryBaseSeconds` parameter (`RetryBaseSeconds * 2^(N-1)`, capped at 10s) and decays by 1 on every clean call so the window does not accumulate forever. Per-call diagnostic flag `$script:LastResourceGraphCrossCallCooldownSeconds` (read after the call) reports how long THIS call slept on entry. New `[switch]-DisableCrossCallCooldown` parameter opts out (intended for unit tests and callers with their own upstream rate-limiting). Pester `Cross-call throttle coordination (v0.7.84)` Context adds 4 tests covering: (1) cooldown set after throttle; (2) subsequent call sleeps on entry; (3) `-DisableCrossCallCooldown` bypasses the wait; (4) counter decays on clean calls.
- Pester `Regression v0.7.84` Describe block (10 tests across 3 contexts) in `Tests/AzLocal.UpdateManagement.Tests.ps1`:
  - **Static (regex on source) guards** - detect regression of each fix by string-matching the source file: `properties.reportedProperties.nodes` present; `.nodeCount` absent; `($clusterId -split '/')[-1]` present without `[string]` cast on the array; `if ($status -ieq 'Running') { [int]-1 }` short-circuit absent; `extend lastModifiedAt = tostring(systemData.lastModifiedAt)` present in ARB KQL.
  - **Execution tests with realistic ARG mock payloads** - mock `Invoke-AzResourceGraphQuery` with payloads that mimic the real fleet response (3-node `Mobile` cluster with `reportedProperties.nodes` array, Disconnected Arc machine with real ARM-ID `parentClusterResourceId`, Running + Offline ARBs with `systemData.lastModifiedAt` set 5/10 days ago) and assert: cluster NodeCount = 3 (not 0); NonConnectedMachines[0].ClusterName = `'Mobile'` (not `'e'`); Offline ARB `DaysSinceLastModified` approx 10 (not -1); Running ARB `DaysSinceLastModified` approx 5 (not -1).
  - **Negative-control** - re-executes the pre-fix `([string]($id -split '/'))[-1]` expression against `/subs/.../clusters/Mobile` and asserts the result is `'e'`. If PowerShell ever changes array-to-string coercion semantics this fires loudly.

### Changed

- **Existing v0.7.79 cluster mock fixture in `Tests/AzLocal.UpdateManagement.Tests.ps1` corrected.** The fixture used `properties.reportedProperties = @{ nodeCount = 2 }` - the WRONG property name relative to the real ARG schema - which is why unit tests passed for multiple releases despite Bug A being live in production. Fixture updated to use the realistic `nodes = @([PSCustomObject]@{ name = 'node1' }, [PSCustomObject]@{ name = 'node2' })` array shape so future schema-shape regressions are caught at test time, not production time. This is a textbook case of the recurring "mock fixtures must match real API response schema" lesson called out in user memory and the post-v0.7.76 backlog.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.83'` to `'0.7.84'`. No code changes in the YAMLs themselves.

### Migration

No action required. `Install-Module AzLocal.UpdateManagement -Force` picks up the fix. Refresh bundled Step.4 and Step.6 YAMLs (which call `Get-AzLocalFleetConnectivityStatus`) with `Copy-AzLocalPipelineExample -Destination <path> -Update` to silence the drift warning. Field semantics changed for one column: `DaysSinceLastModified` for Running ARBs now shows real days instead of `-1`. Downstream consumers parsing the ARB rows should treat `-1` exclusively as "timestamp missing / unparseable".

## [0.7.83] - 2026-05-21

### Fixed

- **HOTFIX: Step.4 fleet-connectivity ARB JUnit-XML generation crashed with `Method invocation failed because [System.Char] does not contain a method named 'Trim'`** whenever an Azure Resource Bridge failure case had a single (non-comma-separated) `ClusterId`. The buggy pattern `$clusterIdList = if ($r.ClusterId) { @(($r.ClusterId -split ',\s*') | Where-Object { $_ }) } else { @() }; $clusterIdList[0].Trim()` (introduced in v0.7.82 with the multi-cluster-RG ARB handling) hits a PowerShell collection-unwrap gotcha: when `Where-Object` yields a single scalar string, the `@()` wrap is silently undone by the if-as-expression, `$clusterIdList` collapses to a bare `[string]`, indexing returns `[char]`, and `.Trim()` throws. Multi-cluster RG ARBs (comma-separated `ClusterId`) work fine, which is why this only surfaced in production against a real customer fleet. Reported via a real GitHub Actions Step.4 run on 2026-05-21.
- Fix applied to both Step.4 YAMLs (`github-actions/Step.4_fleet-connectivity-status.yml` and `azure-devops/Step.4_fleet-connectivity-status.yml`):
  - `[string[]]$clusterIdList = if ($r.ClusterId) { ($r.ClusterId -split ',\s*') | Where-Object { $_ } } else { @() }` - the cast forces array shape regardless of element count.
  - `$primaryClusterId = if ($clusterIdList.Count -gt 0) { ([string]$clusterIdList[0]).Trim() } else { '' }` - belt-and-suspenders `[string]` cast at the indexing site so the fix survives future refactors that might drop the variable cast.
- **Defence in depth:** the same `if-@-else-@()` shape existed twice more per file in the orphan-ARB reconciliation block (the `$arbByClusterId` lookup loop and the `$orphanArbs` filter). Both used `foreach ($id in $ids) { ... $id.Trim() ... }` which is **safe-by-accident** (when `$ids` is a bare `[string]`, `foreach` iterates the whole string once as a scalar, so `$id.Trim()` works). Both call sites are now also `[string[]]`-cast so a future refactor to `$ids[0].Trim()` will not silently regress.

### Added

- Pester regression block `Regression v0.7.83: Step.4 ARB inline script handles single-cluster ClusterId without [char].Trim() bug` in `Tests/AzLocal.UpdateManagement.Tests.ps1`. Nine tests:
  - **Static (4):** regex on YAML content to confirm both YAMLs ship `[string[]]$clusterIdList`, both YAMLs ship `([string]$clusterIdList[0]).Trim()`, both YAMLs ship two `[string[]]$ids` casts (the orphan-ARB sites), and neither YAML contains the unwrapped `$clusterIdList = if (` or `$ids = if (` pattern (v0.7.82 regression guard).
  - **Dynamic (5):** re-execute the exact two-line buggy pattern against single-cluster `ClusterId`, comma-separated multi-cluster `ClusterId`, null `ClusterId`, and empty-string `ClusterId`. The single-cluster test is the direct regression guard for the v0.7.82 bug. A fifth **negative-control** dynamic test asserts that the **pre-fix** `if-@-else-@()` shape **still throws** `does not contain a method named 'Trim'` on single-cluster input - so if PowerShell's collection-unwrap semantics ever change, this test fails loudly and forces re-evaluation of the cast strategy.
- Identifies a broader test gap: Step.4 (and all Step.*.yml) inline `run: |` PowerShell scripts are tested by string-match (`Should -Match`) only, NEVER by parser/execution. The customer hit a runtime exception in YAML script body that NO existing test would have caught. Tracked as backlog item `Executable-YAML test strategy` for a future release (extract `run: |` blocks into sibling `Step.X_*.ps1` files that the YAML dot-sources, then Pester dot-sources the same `.ps1` against a mocked `$data` payload).

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.82'` to `'0.7.83'`. No code changes in any non-Step.4 YAML; the pin is drift-detection only.

### Migration

No action required. The next pipeline run that does `Install-Module AzLocal.UpdateManagement -Force` will pick up v0.7.83 from PSGallery and the fixed inline Step.4 script. Operators with a vendored copy of the pipeline-examples folder should run `Copy-AzLocalPipelineExample -Destination <path> -Update` to refresh both Step.4 YAMLs.

## [0.7.82] - 2026-05-21

### Added

- **Bundled custom-role JSON artifact.** New file `Automation-Pipeline-Examples/azlocal-update-management-custom-role.json` packages the canonical `Azure Stack HCI Update Operator` role definition (13 actions: the 12 used by current cmdlets plus `Microsoft.HybridCompute/machines/extensions/read`, reserved for future Arc-machine extension reporting so the role does not need updating again when that feature lands) so operators no longer need to copy-paste the JSON from the README. Download it directly from the repo with `curl` / `Invoke-WebRequest` against the raw.githubusercontent.com URL, or run `Copy-AzLocalPipelineExample -Destination <path>` to copy the entire pipeline-examples folder (including this file) into a target repo. Replace the `<your-subscription-id>` placeholder in `AssignableScopes` before running `az role definition create --role-definition ./azlocal-update-management-custom-role.json`. Content matches `docs/rbac.md` verbatim, including the long-form Description text covering the Step.4 fleet-connectivity scopes.

### Changed (documentation)

- `Automation-Pipeline-Examples/README.md` Section 4.1 now leads with a paragraph pointing operators at the bundled JSON file as the recommended install path (download or `Copy-AzLocalPipelineExample`), with the inline JSON code block and inline here-string retained for readers who prefer copy-paste over download.
- New callout in Section 4.1 (and the parallel section in `docs/rbac.md`) explains the difference between the **CLI / PowerShell** JSON shape (top-level `Name`, `IsCustom`, `Actions`) used by `az role definition create` / `update` and `New-AzRoleDefinition`, and the **Azure portal Edit-a-custom-role JSON tab** shape (ARM resource representation, wrapped in `properties` with `actions` nested under `permissions[0]`). Pasting the bundled file into the portal JSON tab fails with `Malformed JSON: "properties" property not present`; the callout steers operators to the Permissions tab or to `az role definition update --role-definition <file>` instead.
- The same callout also flags a **UTF-8 BOM gotcha**: `az role definition create` / `update` uses Python's `json` parser, which rejects files that start with a UTF-8 BOM and fails with `Failed to parse string as JSON ... Expecting value: line 1 column 1 (char 0)`. The shipped `azlocal-update-management-custom-role.json` is BOM-free, but re-saving it via Windows PowerShell `Out-File` / `Set-Content` / `>` redirection, or Notepad `Save As -> UTF-8`, can add a BOM. The callout shows how to verify (`'{0:X2}' -f [IO.File]::ReadAllBytes($f)[0]` should return `7B`, not `EF`), how to strip a BOM in place with `[IO.File]::WriteAllText($f, [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)), [Text.UTF8Encoding]::new($false))`, and how to download the raw file without re-encoding via `[IO.File]::WriteAllBytes($dst, (Invoke-WebRequest -Uri $rawUrl -UseBasicParsing).Content)`.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.81'` to `'0.7.82'`. No code changes in the YAMLs; the pin is drift-detection only.

### Migration

No action required. If you already created the custom role from inline JSON in the README, no rework is needed - the bundled file's content is byte-identical to the v0.7.81 inline block. For new installs, prefer the bundled file path: `(Get-Content ./azlocal-update-management-custom-role.json -Raw) -replace '<your-subscription-id>', $subId | Set-Content ./azlocal-update-management-custom-role.json -Encoding UTF8; az role definition create --role-definition ./azlocal-update-management-custom-role.json`.

## [0.7.81] - 2026-05-21

### Changed (documentation)

- **Pivoted CI/CD permission guidance to custom-role-first.** `Automation-Pipeline-Examples/README.md` previously presented the least-privilege `Azure Stack HCI Update Operator` custom role and the built-in `Azure Stack HCI Administrator` role as roughly equal "Option A / Option B" choices, with the built-in role framed as a "quick start" for labs. This biased readers toward over-granting because the built-in role grants broad cluster-management permissions well beyond what the seven pipelines actually exercise. Every permission code path in the CI/CD README now leads with the custom role for every environment (labs, PoCs, production); the built-in role is treated as a temporary fallback for tenants where the operator cannot create custom roles, hidden behind `<details>` / commented-out alternatives so the primary flow is clean.
- Sections reframed: 3.1 Step 2 (GitHub Actions OIDC SP role assignment - removed the Option A / Option B split), 3.2 (Azure DevOps service connection), 3.3 (Self-hosted runners with Managed Identity), 3.4 (Service Principal + client secret), section 4 intro (Required Azure permissions), section 4.2 (Extending to additional subscriptions), and section 11 (Security model).
- Section 4.1 migration tip expanded from a one-line `>` blockquote into a full **"Migration tip (built-in -> custom role, no downtime)"** block with a four-step procedure including the `az role assignment delete --assignee <appId> --role "Azure Stack HCI Administrator" --scope "/subscriptions/<id>"` cleanup command. The migration preserves pipeline operation because the custom role is verified working before the built-in assignment is removed.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.80'` to `'0.7.81'`. No code changes in the YAMLs; the pin is drift-detection only.

### Migration

No action required. The custom role definition itself is unchanged from v0.7.80. If you assigned the built-in `Azure Stack HCI Administrator` role following pre-v0.7.81 guidance, follow the expanded `Migration tip` at the end of section 4.1 of `Automation-Pipeline-Examples/README.md` to swap to the least-privilege custom role with no pipeline downtime.

## [0.7.80] - 2026-05-21

### Fixed (documentation)

- The documented "Azure Stack HCI Update Operator" custom role in [`docs/rbac.md`](docs/rbac.md) was missing three reads required by `Get-AzLocalFleetConnectivityStatus` (introduced in v0.7.79). Pipelines using a service principal that was granted only the v0.7.79-or-earlier custom role saw 20 clusters returned but 0 Arc agents, 0 NICs, and 0 ARBs because ARG yields an empty `.data` array for resource types the caller cannot read. Added to the role:
  - `Microsoft.HybridCompute/machines/read`
  - `Microsoft.AzureStackHCI/edgeDevices/read`
  - `Microsoft.ResourceConnector/appliances/read`
- Added an **"Updating an existing custom role (v0.7.79 -> v0.7.80)"** sub-section in `docs/rbac.md` walking through `az role definition update`. Updating the role in place preserves the role GUID and every existing role assignment - recreating the role would invalidate both.
- Expanded the **Specific Permissions Required** table in `docs/rbac.md` to list the three new actions and call out a `v0.7.80 note` paragraph explaining the silent-zero failure mode operators were hitting.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.79'` to `'0.7.80'`. No code changes in the YAMLs; the pin is drift-detection only.

### Migration

If you created the custom role against the v0.7.79-or-earlier definition in `docs/rbac.md`, refresh the JSON to the v0.7.80 definition (three new actions listed above), then run `az role definition update --role-definition ./azlocal-update-management-custom-role.json`. Permission changes propagate within a few minutes. No re-assignment needed.

## [0.7.79] - 2026-05-20

### Changed

- **Step.5 `assess-update-readiness`** (GitHub Actions + Azure DevOps) now ships with an active daily schedule at **07:00 UTC**. Previously the `schedule:` / `schedules:` block was commented out, requiring manual enablement after pipeline installation.

### Pipeline pin bumps

- Bundled `Step.{0..8}.yml` templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.78'` to `'0.7.79'`.

## [0.7.78] - 2026-05-20

> **Hotfix: Step.4 fleet-connectivity blank-field regression + ARG tabular-shape hardening**
> (GitHub Actions + Azure DevOps).

### Fixed

- **Step.4 reports no longer render blank key fields while still showing counts.**
  The regression produced rows where summary totals looked correct but
  fields such as Cluster/Machine/ARB/NIC names and status text were empty
  in markdown and JUnit output.
- `Invoke-ArgQuery` now handles both ARG payload shapes:
  - object rows: `data: [{...}]`
  - tabular rows: `columns + data: [[...]]`
  Tabular rows are normalized into `PSCustomObject` instances keyed by
  column name before downstream processing.
- Step.4 KQL projections now use `coalesce(...)` for key identity/status
  fields so the report emits stable non-empty values (`Unknown` fallback)
  instead of blank cells when providers return partial payloads.
- Step.4 JSON export depth increased from `6` to `20` to eliminate
  serialization truncation warnings for deeper objects.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure
  DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.77'` to
  `'0.7.78'`.

## [0.7.77] - 2026-05-22

> **Hotfix: Step.4 fleet-connectivity-status JSON parsing hardening**
> (GitHub Actions + Azure DevOps).

### Fixed

- **Step.4 `Collect Fleet Connectivity Data` no longer fails with**
  `ConvertFrom-Json ... Unexpected character encountered while parsing value: W`.
  Root cause was `Invoke-ArgQuery` using `2>&1` with `az graph query`, which
  merged warning text from stderr into stdout and polluted the JSON payload.
- `Invoke-ArgQuery` now executes `az graph query` with `--only-show-errors`
  and redirects stderr to a temp file (`2> $errFile`) so warnings cannot
  corrupt JSON parsing.
- On non-zero az exit, stderr is read from the temp file and surfaced in the
  thrown error for accurate diagnostics.
- az stdout is normalized with `($raw -join "`n").Trim()` before
  `ConvertFrom-Json` so the parser always receives one JSON document.

### Pipeline pin bumps

- All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure
  DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.76'` to
  `'0.7.77'`.

## [0.7.76] - 2026-05-21

> **Breaking rename + nine MODULE-REVIEW findings + bonus ARM dedup fix.**
> All exported and private cmdlets renamed from `-AzureLocal*` to `-AzLocal*`
> to align with the published module name. The module GUID is preserved, so
> `Install-Module AzLocal.UpdateManagement -Force` is the upgrade path.
> Pre-1.0 module with no published external consumers, so no deprecation
> aliases were added; downstream scripts must search-and-replace
> `-AzureLocal` -> `-AzLocal`.

### Breaking

- **Cmdlet rename: `-AzureLocal*` -> `-AzLocal*`.** Every exported function
  in `Public/` and every private helper in `Private/` was renamed to align
  with the module name (`AzLocal.UpdateManagement`) and standard PowerShell
  module-prefix convention. The module GUID and PSGallery name are
  unchanged. Callers must update any pinned script that uses the old
  cmdlet names.

### Fixed

- **P0: ARG `mv-expand` 128-element cap silently dropped >50% of fleet
  health checks in `Get-AzLocalFleetHealthFailures`.** Azure Resource
  Graph silently caps `mv-expand` at 128 expanded child rows per parent.
  The previous KQL used
  `| extend checks = properties.healthCheckResult | mv-expand hc = checks | where tostring(hc.status) =~ 'Failed'`,
  so any cluster whose `healthCheckResult` array exceeded 128 entries was
  losing every check past position 128 - including Failed ones - before
  the function ever saw them. Empirical measurement against an
  AdaptiveCloudLab subscription showed **16 of 20 clusters affected** and
  **2,711 healthCheckResult entries silently dropped fleet-wide**, with
  the worst offender (NewYorkCity, 380 entries) losing 66% of its checks
  and reporting only 4 Failed entries when ARM had additional Failed
  entries beyond the cap. `fleet-health-detail.csv` and the matching
  Summary view were therefore incomplete on every fleet of any
  appreciable size. **Fix:** the KQL no longer uses `mv-expand`. It
  projects `properties.healthCheckResult` as a raw array column and the
  function expands the array client-side in PowerShell, applying the
  `status == 'Failed'` and Severity filters in PS. Output schema is
  unchanged. ARG-side filtering (and the previous KQL `severity in~ (...)`
  clause) moved to the client. The 4 small clusters (<=128 entries) were
  unaffected, and `Test-AzLocalClusterHealth` / `Get-AzLocalClusterUpdateReadiness`
  were already safe because they project `properties` whole and expand
  client-side. Two new Pester regression cases:
  one synthesises a 200-entry `healthCheckResult` with a Failed marker at
  index 150 (well past the 128 cap) and asserts the cmdlet returns it;
  the second is a guard against the regression returning - it asserts
  the emitted KQL contains `HealthCheckResult = properties.healthCheckResult`
  and does NOT contain the string `mv-expand`.
- **Class-of-bug sweep: two more ARG `mv-expand` 128-cap instances eliminated
  in the same release.** Audit of all 36 exported cmdlets surfaced two
  additional KQL pipelines suffering the same bug class:
  - **`Get-AzLocalFleetHealthOverview`** previously used
    `mv-expand pkg = properties.packageVersions | summarize ... by ClusterResourceIdLower`
    to derive `SbeVersion`. While `packageVersions` is normally small
    (~4 entries), there is no schema-level upper bound, so the cmdlet
    was theoretically vulnerable to the same silent truncation. **Fix:**
    KQL now projects `PackageVersions = properties.packageVersions` as a
    raw array; the SBE roll-up runs client-side
    (`packageType -ieq 'SBE'` -> `version`), and the intermediate
    `PackageVersions` column is stripped from the output schema. Output
    contract is unchanged. Backward-compatible against test fixtures
    that mock the projected post-ARG schema without `PackageVersions`.
  - **`Get-AzLocalUpdateRunFailures`** previously used a 7-level nested
    `mv-expand s1..s7` chain over `progress.steps` to find the deepest
    error in an update-run tree, with a synthetic 8th level via
    `s7.steps[0]`. Every level independently capped at 128 children,
    and the truncation compounded across levels. **High-risk** because
    the cmdlet exists specifically to surface deep failure detail on
    long-running update runs, which are exactly the runs most likely
    to have wide step trees. **Fix:** KQL drops every `mv-expand` and
    projects `ProgressSteps = progressObj.steps` as a raw array. A new
    private helper `Resolve-AzLocalUpdateRunDeepestError` walks the
    tree recursively in PowerShell (MaxDepth = 16, up from the legacy
    8-level KQL ceiling), choosing the deepest `errorMessage` longer
    than the 10-char meaningful-threshold (matches legacy
    `strlen(eNMsg) > 10`). The walker also captures the first
    non-empty top-level `description` as a fallback when no
    errorMessage is found. `ErrorCategory` bucketing (SecuredCore,
    HealthCheck, CAU, RotateSecrets, ArcPrereqs, Certificates,
    PreparationTerminated, AdminBlocked, Other, Unclassified) moved
    client-side using `-match` patterns that mirror the legacy KQL
    `has` operators. `StackTracePreview` stays server-side because
    `extract()` is a scalar regex over the single capped
    progressJson string and is unaffected by `mv-expand` truncation.
    Output schema is unchanged. Backward-compatible against test
    fixtures that mock the projected post-ARG schema with
    `DeepestStepDepth/Name/Msg/ErrorCategory` pre-populated and no
    `ProgressSteps` column - those rows pass through unchanged.

  Six new Pester regression cases cover the sweep: a 200-entry
  `packageVersions` test with the SBE entry placed at index 150
  (asserts client-side roll-up surfaces it); a 200-sibling
  `progress.steps` test with the deepest error at sibling 150 (asserts
  the walker finds it); an 8-level depth test (asserts the walker
  matches or exceeds the legacy KQL ceiling); two KQL guards (asserts
  the emitted query contains neither `mv-expand` nor the bug-prone
  pattern); plus six direct unit tests of
  `Resolve-AzLocalUpdateRunDeepestError` covering null/empty/single-level
  /multi-level/description-fallback/200-sibling/threshold cases.
- **ARM `healthCheckResult` byte-identical duplicate suppression** in
  `Test-AzLocalClusterHealth` and the private `Get-HealthCheckFailureSummary`.
  ARM upstream was observed emitting two byte-identical rows for the same
  logical health-check finding on a 2-node Mobile cluster (same CheckName,
  Severity, Description, Remediation, TargetResourceName, Timestamp). The
  effect was a doubled CriticalCount and a Step.4 readiness row like
  `[Critical] Foo (NetworkIntent); [Critical] Foo (NetworkIntent)`. Dedup
  is by the COMPLETE row tuple (HashSet[string] keyed on
  ClusterName|CheckName|Severity|Description|Remediation|TargetResourceName|Timestamp
  joined by U+001F UNIT SEPARATOR), so per-node distinct findings with
  different `targetResourceName` (e.g. `UserStorage_1-Repair` vs
  `UserStorage_2-Repair`) stay separate. Three Pester cases cover the
  three permutations (identical -> 1 row, distinct target -> N rows,
  empty -> empty).
- **Finding 1 P0: row-collapse via `@(func)` wrap on a `, $arr` return.**
  `Invoke-AzResourceGraphQuery` used `return , $allRows.ToArray()` (the
  unary-comma trick that keeps the return value as a single Object[N]
  through pipeline enumeration). 24 callers wrapped the call with
  `@(Invoke-AzResourceGraphQuery ...)` which collected the function's
  pipeline output (one wrapper containing the inner array), producing
  `Object[1]` containing `Object[N]`. Downstream property access then
  did PowerShell member enumeration and returned arrays-of-strings, so
  a 136-row result collapsed into a 1-row `ClusterName_=Object[]` mess.
  Fixed by converting all 24 callers to direct assignment
  (`$x = Invoke-AzResourceGraphQuery ...`), and a warning comment was
  added at the top of the helper.
- **Step.4 fleet-connectivity-status: ARB <-> Cluster join produced
  duplicate ARB rows when one resource group hosts multiple Azure Local
  clusters.** The previous `arbKql` joined ARBs to HCI clusters with a
  plain `join kind=leftouter ... on resourceGroup`, so an RG that hosts
  N clusters produced N copies of the same ARB row (and N JUnit
  testcases for the same ARB). **Fix:** the join now wraps the cluster
  side with `summarize ... by ArbName, ArbId, ...`, collapsing all
  cluster matches in the RG into a single ARB row whose `ClusterName`,
  `ClusterId` and `ClusterStatus` columns are comma-separated lists
  (e.g. `ClusterName = "cl-a, cl-b"`). The downstream JUnit case
  builder and markdown row builder split on `, ` so the portal URL
  links the first cluster and the multi-cluster RG case is annotated
  (`(multi-cluster RG; N clusters)` in the failure-reason text). Mirror
  edit applied to the Azure DevOps twin. The smoke-test harness
  (`Tools/smoke-test-connectivity-status.ps1` - new) asserts the
  updated column shape against the live subscription.

### Changed

- **Step.4 fleet-connectivity-status markdown summary: merged the
  per-cluster Cluster Connectivity table and the per-cluster ARB Status
  table into a single per-cluster table.** Each cluster has at most
  one ARB, so the two tables had a 1:1 row relationship. The new
  "Cluster Connectivity (with ARB Status)" section is one row per
  cluster, with `ARB`, `ARB Status` and `ARB Days Since LastModified`
  columns left-joined from the ARB query by `ClusterId` (the join is
  multi-cluster-per-RG safe because it consumes the comma-separated
  `ClusterId` field produced by the new `summarize/make_set` ARB
  query). Clusters with no ARB show `_(no ARB)_`. ARB appliances whose
  resource group contains no HCI cluster in scope are surfaced
  separately as "Orphan ARBs (no matching cluster in scope)" so
  stale/zombie appliances are not silently dropped. The two
  underlying CSVs (`fleet-cluster-connectivity.csv` and
  `fleet-arb-status.csv`) are unchanged - the merge is a markdown
  presentation concern only. Mirror edit applied to the ADO twin.

- **Step.4 fleet-connectivity-status markdown summary: added "Node +
  ARB Coverage Reconciliation" cross-scope consistency table.** The
  KPI summary table's internal sums (Total = Failing + Healthy) are
  consistent by construction, but the cluster / Arc / ARB totals come
  from three different KQL queries and can legitimately diverge (Arc
  onboarding lag, deleted Arc machine, missing `provider=AzSHCI` tag,
  stale `cluster.reportedProperties.nodes` array, ARB-less cluster,
  orphan ARB). The new 8-row table sits immediately below the KPI
  summary and surfaces: clusters-in-scope, cluster-reported node count
  (sum of `properties.reportedProperties.nodeCount`), Arc-joined
  physical nodes, the node-coverage delta, ARBs-in-scope, clusters
  with/without an ARB, and orphan ARB count. Operators can confirm
  totals tie out at a glance and immediately see which scope a number
  diverged from. The `ClusterId<->ARB` and orphan-ARB lookups
  previously built inline at the merged-table and Orphan-ARBs
  sections were hoisted above the KPI summary so the reconciliation
  block and the per-cluster table share the same data. Mirror edit
  applied to the ADO twin.

### Added

- **Step.4 fleet-connectivity-status: full unfiltered NIC inventory
  alongside the existing issues-only view.** Added a second NIC ARG
  query (`nicAllKql`) modelled on the cluster-management dashboard
  "All Network Adapters" view: every NIC across every Azure Local edge
  device in scope, including Physical AND Virtual adapters and every
  `NicStatus` value, joined to the parent Arc machine so the cluster
  context is derived from `properties.parentClusterResourceId` (which
  is cluster-precise even when multiple clusters share a resource
  group). Two new artefacts:
  - `fleet-physical-nic-all.csv` / `.json` - the full unfiltered NIC
    inventory with the column set `NodeName, MachineId, ClusterName,
    ClusterId, MachineConnectivity, NicName, NicType, NicStatus,
    DriverVersion, InterfaceDescription, Ip4Address, SubnetMask,
    DefaultGateway, DnsServers, MacAddress, ResourceGroup,
    SubscriptionId`.
  - `fleet-physical-nic-stats.csv` / `.json` - a NicType+NicStatus
    histogram (one row per pair, with a `Count` column) computed
    client-side from the full inventory.

  The markdown step summary now renders a "Physical NIC Statistics"
  block (NicType x NicStatus histogram with per-row severity icons)
  before the existing "Physical NIC Issues" detail table, so reviewers
  can spot fleet-wide patterns (e.g. dozens of Physical NICs in
  `Disconnected` state across multiple clusters) at a glance and then
  drill into the filtered actionable issues.

  The existing `fleet-physical-nics.csv` artefact (Disconnected with
  non-APIPA IP) is unchanged - the unfiltered file is a new artefact,
  not a replacement.

- **`Tools/smoke-test-connectivity-status.ps1` - new live-subscription
  smoke-test harness for the Step.4 ARG queries.** Mirrors the
  `validate-arg-queries.ps1` reporting shape (PASS / PASS-EMPTY /
  FAIL-SCHEMA / ERROR rows in a final results table). Runs each of the
  five KQL queries that the GH / ADO Step.4 YAMLs execute, verifies
  the query parses + executes cleanly, and asserts the documented
  required-column set is present on the first returned row. Use this
  before shipping a Step.4 KQL edit to catch column-rename / schema-
  drift bugs against a live AdaptiveCloudLab subscription.

- **New `Step.4_fleet-connectivity-status.yml` pipeline (GitHub Actions
  and Azure DevOps).** A daily fleet-wide network connectivity audit
  that emits a JUnit-XML report covering four scopes:
  - **Cluster connectivity** - per-cluster `connectivityStatus` and
    `clusterStatus` from `microsoft.azurestackhci/clusters`, with the
    cluster `currentVersion` joined in from
    `extensibilityresources/microsoft.azurestackhci/clusters/updateSummaries`.
  - **Arc agent connection status** - both a fleet-wide summary
    histogram (one row per `AgentStatus` value) AND a detailed
    "Non-Connected Machines" table (every machine whose status is not
    `Connected`) using the Machines workbook column set: NodeName,
    MachineId, ClusterName, ClusterId, AgentStatus, OsSku, OsVersion,
    ClusterVersion, AgentVersion, LastStatusChange, ResourceGroup,
    SubscriptionId.
  - **Physical NICs** - emits a row per `networkInterfaces` child only
    when `NicStatus == "Disconnected"` AND the IP address is non-empty
    AND not an APIPA `169.254.*` address (so the report shows
    interfaces that look configured but are not carrying traffic, and
    suppresses the noise of unused / DHCP-pending adapters).
  - **Azure Resource Bridge (ARB)** - per-cluster ARB resource status
    where the resource exists.

  Outputs seven CSV/JSON pairs - `fleet-cluster-connectivity`,
  `fleet-arc-status-summary`, `fleet-arc-non-connected-machines`,
  `fleet-physical-nics` (issues only), `fleet-physical-nic-all` (full
  unfiltered inventory), `fleet-physical-nic-stats` (NicType+NicStatus
  histogram), and `fleet-arb-status` - plus a single
  `fleet-connectivity-status-junit.xml` with one suite per scope and
  cluster portal URLs in every test-case property block. Severity
  classifier flags `Disconnected | Expired | Offline | Error` as
  Critical and everything else as Warning. Both YAML files use OIDC
  via `azure/login@v3` (GitHub Actions) and `AzureCLI@2` (Azure DevOps)
  and page Azure Resource Graph at `--first 1000` with the implicit
  `$skipToken` pagination.

- **Finding 2 (test gaps):** new Pester cases covering the row-collapse
  regression, the ARM healthCheckResult dedup (identical / distinct
  target / empty), and KQL `len` arg-truncation safety.
- **Finding 5 P2 - documentation split (Section 6.3 of the review).** Main
  README trimmed from 3372 to ~600 lines. New `docs/` tree:
  - `docs/cmdlet-reference.md` (1474 lines) - all 36 exported cmdlets, with
    per-group inventory tables and full Synopsis / Description / Parameter
    / Output / Example blocks for each.
  - `docs/concepts.md` (84 lines) - cluster-update-summary + per-update
    state machines, `Using Azure CLI Directly`, the `Az.StackHCI` parity
    note, and the CI/CD design assumptions.
  - `docs/rbac.md` (130 lines) - recommended built-in roles, per-cmdlet
    permissions table, the custom least-privilege "Azure Stack HCI Update
    Operator" role definition, and `az role assignment create` recipes.
  - `docs/troubleshooting.md` (107 lines) - symptom-to-fix table for
    common failure modes (auth scope misses, RBAC gaps, ARG arg-truncation,
    healthCheckResult duplicates, cp1252 console encoding, stale ARM
    summaries).
  - `docs/release-history.md` (995 lines) - the full What's-New history
    from v0.4.0 through v0.7.74, including the v0.7.71 sub-feature
    bullets that Finding 4 had previously demoted but mis-placed.
  - `Automation-Pipeline-Examples/docs/appendix-pipelines.md` (104 lines)
    and `appendix-release-history.md` (118 lines) - extracted from the
    1925-line pipeline README, which now is 1719 lines.

### Changed

- **Pipeline renumber to make room for the new connectivity pipeline.**
  All four downstream pipeline samples shift up by one to free
  `Step.4_*` for the new fleet-connectivity-status workflow:
  - `Step.4_assess-update-readiness.yml` -> `Step.5_assess-update-readiness.yml`
  - `Step.5_apply-updates.yml` -> `Step.6_apply-updates.yml`
  - `Step.6_fleet-update-status.yml` -> `Step.7_fleet-update-status.yml`
  - `Step.7_fleet-health-status.yml` -> `Step.8_fleet-health-status.yml`

  This applies to both the GitHub Actions and Azure DevOps sample
  trees. Display names, cross-references between pipelines, the
  pipeline-examples README, the cmdlet docs, the ITSM guide, and the
  Pester regression suite were all updated in lockstep.

- **Finding 3 (service-principal secret leak):**
  `Connect-AzLocalServicePrincipal` no longer writes the SP secret to an
  environment variable. It is written to a temp file with restricted ACL,
  passed via `Get-Content` to `ConvertTo-SecureString`, and the temp file
  is removed in a `finally` block so a script crash mid-call still cleans
  up.
- **Finding 4 (README appendix demote):** older What's-New entries
  demoted from `##` to `###` (already shipped in 3f4b158 against v0.7.75);
  now fully extracted to `docs/release-history.md` by Finding 5.
- **Finding 6 (.psm1 housekeeping):** dead-code comments removed, dot-
  source loop consolidated.
- **Finding 8 (review artefact archive):** `MODULE-REVIEW-AND-RECOMMENDATIONS.md`
  moved into a gitignored `docs/` location so PSGallery / git history
  is not polluted with internal review notes.
- **Finding 9 (.psm1 rationale):** top-of-file comment block explains the
  deliberate `Set-StrictMode -Version 1.0` (instead of `Latest`) and the
  dot-source-then-export pattern.

### Migration

- `Install-Module AzLocal.UpdateManagement -Force` or `Update-Module`.
- Search-and-replace `-AzureLocal` -> `-AzLocal` in any pinned scripts.
- **Pipeline renumber:** after running
  `Update-AzLocalPipelineExample -Force` (or
  `Copy-AzLocalItsmSample`) to pick up the renumbered samples,
  manually delete the old-named yaml files from your consumer
  repository so the pipeline runner does not execute both the old and
  new copies on the same trigger. Files to delete:
  - `Step.4_assess-update-readiness.yml`
  - `Step.5_apply-updates.yml`
  - `Step.6_fleet-update-status.yml`
  - `Step.7_fleet-health-status.yml`

  The new ITSM/automation copies will appear under the new step
  numbers, plus the brand-new `Step.4_fleet-connectivity-status.yml`.
- **Pipeline pin bumps (drift-detection only).** All 18 bundled
  `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bump
  `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.75'` to `'0.7.76'`. The
  pin is a runtime drift-detection constant read by `Step.0_authentication-test.yml`
  (and the other Step.* templates) and compared to the installed module
  version from PSGallery; on mismatch the Step Summary emits a warning.
  It does NOT control which module is installed (`Install-Module -Force`
  always pulls PSGallery latest), so existing pre-v0.7.76 consumer YAMLs
  continue to function - they just emit the warning. **New in v0.7.76:**
  Step.0 itself now carries the pin (previously only `Step.{1..7}` did),
  per the 'Step.0 module-drift parity' item, so the warning fires from
  the first pipeline job. Refresh consumer YAMLs to silence the warning:
  `Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHubActions`
  and / or `-Destination .\.azure-pipelines -Platform AzureDevOps`.

## [0.7.75] - 2026-05-20

> **Backward compatible.** Hardening release on top of v0.7.74. v0.7.74 patched the `Test-AzLocalApplyUpdatesScheduleCoverage` cross-platform-noise bug at the **yml layer** by adding `-Platform GitHubActions` / `-Platform AzureDevOps` arguments to the bundled Step.3 yml templates. That fix only takes effect for consumers who refresh their yml via `Update-AzLocalPipelineExample`; consumers whose Step.3 yml is a verbatim pre-v0.7.74 copy still see both the GitHub Actions snippet AND the Azure DevOps snippet in their Step Summary because their yml does not pass `-Platform` and the cmdlet defaults to `-Platform Both`. v0.7.75 closes that gap by adding the same auto-selection at the **cmdlet layer** so stale yml self-heals at runtime.

### Fixed

- **`Test-AzLocalApplyUpdatesScheduleCoverage` auto-detects the CI host platform when `-Platform` is omitted.** When the caller does not bind `-Platform`, the cmdlet inspects the well-known CI environment variables: `$env:GITHUB_ACTIONS -eq 'true'` selects `'GitHubActions'`; `$env:TF_BUILD -eq 'True'` or any non-empty `$env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI` selects `'AzureDevOps'`. If neither is set (the interactive operator-at-workstation case), the existing default `'Both'` is preserved so the operator continues to see both platform snippets side by side. Detection is gated on `$PSBoundParameters.ContainsKey('Platform')` so an explicit caller value (including an explicit `-Platform Both`) always wins. Effect on stale yml consumers: the very next workflow run against the v0.7.75 module emits only the GH snippet on GitHub Actions runners and only the ADO snippet on Azure DevOps agents - no yml change required. Defence in depth: the v0.7.74 explicit `-Platform GitHubActions` / `-Platform AzureDevOps` arguments in the bundled yml stay in place so runs against older modules continue to behave correctly.
- **Audit confirmed scope.** Only `Test-AzLocalApplyUpdatesScheduleCoverage` had the cross-platform-noise symptom (it is the only cmdlet whose default branches its emitted snippet by platform). `Copy-AzLocalPipelineExample` and `Update-AzLocalPipelineExample` were reviewed and intentionally NOT changed: `Copy-AzLocalPipelineExample`'s default `'All'` is correct for the operator-at-workstation case (copy both platforms' samples so the operator can choose); `Update-AzLocalPipelineExample` is mandatory-no-default by design so the operator must opt into which existing destination to refresh. All other GH-vs-ADO conditional output happens **inside** the yml templates (`>> $env:GITHUB_STEP_SUMMARY`, `##vso[task.uploadsummary]`), not in cmdlets - cmdlets emit platform-neutral PowerShell that the yml then routes.

### Changed

- **Test coverage** - four new Pester tests (AS7-AS10) in the existing `Test-AzLocalApplyUpdatesScheduleCoverage` Describe verify all four auto-detect cases: (AS7) `$env:GITHUB_ACTIONS='true'` + no `-Platform` -> GH snippet only; (AS8) `$env:TF_BUILD='True'` + no `-Platform` -> ADO snippet only; (AS9) `$env:GITHUB_ACTIONS='true'` + explicit `-Platform Both` -> both snippets (explicit-wins / auto-detect suppressed); (AS10) no CI env vars + no `-Platform` -> both snippets (interactive default preserved). `BeforeEach` / `AfterEach` blocks clear `$env:GITHUB_ACTIONS`, `$env:TF_BUILD`, and `$env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI` so the new tests do not pollute or depend on the calling environment.

### Pipeline pin bumps

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.74'` to `'0.7.75'`. Refresh existing copies with:

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

### Migration notes

- **No cmdlet signature change.** `[ValidateSet('GitHubActions','AzureDevOps','Both')] [string]$Platform = 'Both'` is unchanged - the default value is still `'Both'`, the new behaviour only fires when the caller does **not** bind the parameter.
- **No yml change required** beyond the version pin bump. The v0.7.75 cmdlet fix self-heals stale Step.3 yml the next time the workflow runs against the v0.7.75 module on PSGallery. Refreshing the yml via `Update-AzLocalPipelineExample` is still recommended (gets you any other v0.7.75 changes flagged by `GENERATED_AGAINST_MODULE_VERSION`) but no longer required for this specific symptom.
- **Interactive operators**: behaviour is unchanged. Without `$env:GITHUB_ACTIONS` / `$env:TF_BUILD` set, the cmdlet still defaults to `-Platform Both` and emits both snippets so you can compare them side by side.
- **Operators who explicitly want both snippets in a CI run** (rare - e.g. one-off comparison): pass `-Platform Both` explicitly. The `$PSBoundParameters.ContainsKey('Platform')` guard ensures explicit binding always wins over auto-detect.

## [0.7.74] - 2026-05-19

> **Backward compatible.** Hot-fix on top of v0.7.73 that **(a)** fixes a regression in `Get-AzLocalFleetHealthOverview` where the v0.7.73 KQL grew past the `az graph query -q` argument-truncation threshold (~2.8 KB wire-side) and surfaced as `ParserFailure: token=<EOF>` at character 2757 on the wire, and **(b)** substantially improves the Step.3 - Apply-Updates Schedule Coverage Audit operator output so the recommendation block is a true step-by-step remediation guide rather than a sparse advisory.

### Fixed

- **`Get-AzLocalFleetHealthOverview` no longer fails with `ParserFailure: token=<EOF>`.** The v0.7.73 change introduced a `case()` mapping plus a six-line KQL `//` comment block which together pushed the wire query from `~2400` chars (v0.7.72 baseline) to `3115` chars. The Azure CLI's `az graph query -q <query>` argument layer truncates very long single-arg payloads on Windows around 2.8 KB; the truncated query lands mid-projection so the ARG parser sees an unterminated statement and returns `BadRequest / InvalidQuery / ParserFailure` with `characterPositionInLine=2757, token=<EOF>`. Symptom: `Step.7 - Fleet Health Status` failed with exit code 1 the moment the cmdlet was invoked, even though Step.7's separate "Detail" ARG query (shorter) succeeded. Verified end-to-end against the same live 20-cluster fleet: after the v0.7.74 fix the wire query is back to `2396` chars (matches the v0.7.72 baseline length), the cmdlet returns 20 cluster rows, and the normalised `HealthStatus` distribution from v0.7.73 (`10 Healthy / 7 Critical / 2 Warning / 1 In progress`) is preserved.
- **Fix:** (1) The six-line `//` KQL comment block is dropped from the here-string and re-expressed as PowerShell `#` comments above the assignment - documentation for the source reader, no wire-side bytes. (2) The `case()` projection is compacted to a single line (semantically identical). A new inline `IMPORTANT` PowerShell comment above the `$kql` here-string flags the constraint so future contributors do not re-introduce it.
- **`Test-AzLocalApplyUpdatesScheduleCoverage` Step.3 pipeline scripts no longer emit cross-platform noise.** The cmdlet's `-Platform` parameter defaults to `'Both'`, which surfaced both the GitHub Actions `schedule:` block AND the Azure DevOps `schedules:` block in every Step.3 run regardless of which CI platform was running it. Both Step.3 yml files now pin `-Platform GitHubActions` (GH) / `-Platform AzureDevOps` (ADO) on both the `Audit` and `Recommend` view calls so the Step Summary contains exactly one platform-appropriate snippet.

### Changed

- **Step.3 Apply-Updates Schedule Coverage Audit recommendation block is now a proper step-by-step remediation guide.** Previously the output was a sparse 4-section advisory with one paragraph per finding; operators reported it was "very hard to follow and understand what to do". The v0.7.74 output adds:
  - **Top-of-block "Fix-in-this-order checklist"** when 2+ action sections are emitted, with N+1 ordered bullets that name the file to edit and the consequence of skipping the step. Surfaces the order the advisor uses internally (ring diff → orphans → unparseable crons → cron coverage → re-run) so the operator does not have to derive it from the section headings.
  - **`**Why this matters.**` paragraph in every section** that names the specific runtime cmdlet that depends on the configuration being fixed (`Resolve-AzLocalCurrentUpdateRing`, `Test-AzLocalUpdateScheduleAllowed`) and the silent-skip failure mode the operator avoids by following the fix.
  - **"How to fix" subsection in the missing-rings section** with a full `apply-updates-schedule.yml` skeleton snippet showing the existing `schedule:` block AND a placeholder row PER missing ring (`TODO:` markers on `weeksInCycle`, `daysOfWeek`, `notes`). The snippet is annotated with the cluster count for each missing ring and an `AzLocal.UpdateManagement v<version> advisor: add row(s) like these <<<` header so it is unambiguous where the operator-edited content begins.
  - **Ready-to-paste (uncommented) cron block in the cron-coverage section.** Replaces the prior `# commented` form (which operators were copy-pasting verbatim including the `# ` prefixes). The snippet is now a real `on:` (GitHub Actions) or `schedules:` (Azure DevOps) block, with one cron line per UpdateWindow plus a trailing yaml `#` annotation showing the rings and cluster count served by that cron. The block honors `-Platform` so single-platform callers see exactly one snippet.
  - **Action wording is platform-aware** - the recommendation text names the exact pipeline file (`.github/workflows/Step.5_apply-updates.yml` vs `.azuredevops/Step.5_apply-updates.yml`) and the exact schedule file (`.github/apply-updates-schedule.yml` vs `.azuredevops/apply-updates-schedule.yml`) when `-Platform` is pinned to a single platform.
  - **Two-choice fix tables for orphaned rings** spell out both options - retag a cluster onto the ring (via `Set-AzLocalClusterUpdateRingTag`) OR remove the ring from the schedule file - so operators do not default to deletion when they actually wanted to bring a cluster onto the ring.

### Pipeline pin bumps

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.73'` to `'0.7.74'`. Refresh existing copies with:

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

### Migration notes

- **No cmdlet signature change.** `Get-AzLocalFleetHealthOverview` returns the same shape and the same normalised `HealthStatus` vocabulary it returned in v0.7.73 - only the underlying wire query is shorter so it no longer trips the truncation.
- **No mandatory yml change** beyond the version pin bump. The v0.7.74 Step.3 yml changes (adding `-Platform GitHubActions` / `-Platform AzureDevOps`) are recommended-but-not-required - the cmdlet still works against the v0.7.73 yml; you just continue to see the cross-platform noise until the yml is refreshed.

## [0.7.73] - 2026-05-19

> **Backward compatible.** Bug-fix release on top of v0.7.72. The `Get-AzLocalFleetHealthOverview` cmdlet's `HealthStatus` column was passing the raw Azure Resource Graph `properties.healthState` values (`Success` / `Failure` / `Warning` / `InProgress` / `NotKnown`) through unchanged, even though the cmdlet's own doc comment, the downstream Step.7 pipeline filter, and the Step.7 Fleet Health Overview rendering switch all expected the operator-friendly vocabulary `Healthy` / `Critical` / `Warning` / `In progress` / `Unknown`. Symptom: `Step.7 - Fleet Health Status` reported `Healthy Clusters = 0` against any fleet (verified against a live 20-cluster fleet: 10 Success / 8 Failure / 2 Warning); the Fleet Health Overview markdown table rendered the `[Success]` / `[Failure]` default-bracket fallback instead of the intended icon labels. The KQL projection now normalises in `case()`: `Success -> Healthy`, `Failure -> Critical`, `InProgress -> In progress`, `NotKnown -> Unknown`, empty -> Unknown; `Warning` is passed through unchanged; any future raw value also passes through so it stays visible (rather than being silently bucketed as `Unknown`). After the fix, Step.7 reports `Healthy Clusters = 10` for the same live fleet and the overview table renders the intended icons. **No filter or switch changes required in the pipeline samples** - the v0.7.72 pin already used the correct vocabulary; the v0.7.73 module simply emits values that match. Pipeline pin bumps to `'0.7.73'`; refresh existing copies with `Update-AzLocalPipelineExample`.

### Fixed

- **`Get-AzLocalFleetHealthOverview` HealthStatus column now matches its documented contract** (`Healthy` / `Critical` / `Warning` / `In progress` / `Unknown`) instead of leaking the raw ARG `properties.healthState` enum (`Success` / `Failure` / `Warning` / `InProgress` / `NotKnown`). Root cause: the KQL projection was `HealthStatus = iif(isempty(HealthState), 'Unknown', HealthState)` - a passthrough. Fix: replaced with a `case()` mapping (`Success -> Healthy`, `Failure -> Critical`, `InProgress -> In progress`, `NotKnown -> Unknown`, empty -> Unknown; `Warning` and any future-added platform value pass through unchanged). Verified against a live 20-cluster fleet (10 Success / 8 Failure / 2 Warning): after the fix, ARG returns the normalised values directly, Step.7's `Where-Object { $_.HealthStatus -eq 'Healthy' }` filter matches 10 rows (was 0), Step.7's `HEALTHY_CLUSTERS` GitHub-output step writes `10` (was `0`), and the Fleet Health Overview table's `switch ($o.HealthStatus)` block hits the intended `Healthy` / `Critical` / `Warning` arms (rendering `✅ Healthy` / `❌ Critical` / `⚠️ Warning`) instead of the default-bracket fallback (rendering `[Success]` / `[Failure]`). The cmdlet's doc comment is also corrected to describe the normalised vocabulary and to spell out the raw -> normalised mapping for future-proof clarity. Cross-checks against the Step.6 panel for the same fleet confirm internal consistency: Step.6 reports `Up to Date = 10` (UpdateState-driven) and `Critical Health Status: 12 passed / 8 failed` (matches the 8 Failure clusters); Step.7 now reports `Healthy Clusters = 10` (matches the 10 Success clusters); the 2 Warning clusters surface as `⚠️ Warning` in the overview table without being counted as either Healthy or Critical.

### Pipeline pin bumps

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.72'` to `'0.7.73'`. The Step.0 authentication validation workflow does not pin a module version. Refresh existing copies with:

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

### Migration notes

- **No cmdlet signature change.** The `HealthStatus` column type (`string`) and column position (third column, after `ClusterName` and `ClusterPortalUrl`) are unchanged - only the value set narrows from the raw ARG enum to the documented operator-friendly vocabulary. Operators who built custom downstream automation that explicitly filtered for the **raw** `Success` / `Failure` / `InProgress` / `NotKnown` strings against the v0.7.70 - v0.7.72 builds must update those filters to the new `Healthy` / `Critical` / `In progress` / `Unknown` vocabulary (or pull the raw value back via a separate ARG call on `updateSummaries.properties.healthState` if they specifically need the platform enum). All in-tree pipeline samples (Step.7 GH + ADO) already used the normalised vocabulary in their filter and renderer, so they receive the fix with **no YAML change** - only the pipeline pin bump.
- **No README setup change.** v0.7.73 is scoped to the `Get-AzLocalFleetHealthOverview` KQL projection + a doc-comment correction + the 14 pin bumps. No PSGallery secrets, federated-identity setup, or RBAC change.

## [0.7.72] - 2026-05-19

> **Backward compatible.** Pipeline-samples hotfix release. Two issues observed when operators ran the v0.7.71 GitHub Actions samples in production: (1) the Step.1 / Step.2 / Step.5 `Summary` blocks rendered as an empty GitHub Actions Summary panel (`Write-Host "text" >> $env:GITHUB_STEP_SUMMARY` is a no-op because `Write-Host` writes to the information/host stream, not stdout, so the `>>` redirect appended nothing); (2) `AZURE_TENANT_ID` was stored as a Secret on the same rationale as `AZURE_SUBSCRIPTION_ID` (public ARM/AAD identifier, not a credential). Both are fixed. Pipeline pin bumps to `'0.7.72'`; refresh existing copies with `Update-AzLocalPipelineExample`.

### Fixed

- **Step.1 / Step.2 / Step.5 GitHub Actions `Summary` steps now render content.** Across these three workflows, 62 `Write-Host "<markdown>" >> $env:GITHUB_STEP_SUMMARY` lines were silently no-ops because `Write-Host` emits to the PowerShell information/host stream (6), not stdout (1), so the file-redirect operator `>>` only ever appended an empty stream to `$env:GITHUB_STEP_SUMMARY`. The job log printed the markdown to the runner console (where operators do not normally look) but the GitHub Actions Summary panel - the canonical post-run report surface - rendered blank. All 62 lines now use the bare-string-to-stdout form (`"<markdown>" >> $env:GITHUB_STEP_SUMMARY`), so the totals/tables/actions-required block coded in v0.7.71 finally surface. Affected: Step.1 cluster-inventory totals + UpdateRing distribution; Step.2 UpdateRing tag-management settings + dry-run notice; Step.5 update-application readiness/results matrix + actions-required block + `no-clusters-ready` job summary. ADO pipelines were unaffected (they use the `##vso[task.uploadsummary]` mechanism, not stdout redirection). No PowerShell source files modified.

### Changed (pipeline samples)

- **`AZURE_TENANT_ID` secret -> variable migration (GitHub Actions only).** All 8 GitHub Actions `Step.*.yml` workflows now read the Entra ID tenant id from `vars.AZURE_TENANT_ID` (Variable) instead of `secrets.AZURE_TENANT_ID` (Secret). Rationale matches v0.7.71's `AZURE_SUBSCRIPTION_ID` treatment: the value is a public ARM/AAD identifier (it is rendered in workflow telemetry on every `azure/login@v3` run, present in the OIDC token issuer URL, and visible to anyone with read access to the App Registration) - not a credential. It is consumed in exactly one place: the `tenant-id:` input to `azure/login@v3`, which exchanges the OIDC token for an Azure AD token in the named tenant. It is NOT used to scope ARG queries and NOT interpolated into portal URLs. Treating it as a Variable surfaces the value as plaintext in workflow logs (matching its non-sensitive nature) and removes the need for a separate Secret rotation in tenants that already track it as a Variable. The commented-out legacy `Client Secret` `azure/login@v3` `creds:` JSON line in Step.1, Step.2, Step.5 also moves `"tenantId"` to `vars.*`. Setup docs in `AzLocal.UpdateManagement/README.md` + `Automation-Pipeline-Examples/README.md` updated (steady-state is now **one repo-level Secret** [`AZURE_CLIENT_ID`] + **two repo-level Variables** [`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`]). Azure DevOps pipelines were already authenticating via a service connection and need no change.
- **Pipeline pin bumps.** All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.71'` to `'0.7.72'`. The Step.0 authentication validation workflow does not pin a module version.

### Migration notes

- **GitHub Actions operators:** add `AZURE_TENANT_ID` as a repository Variable (`gh variable set AZURE_TENANT_ID --body <tenantId>`) and delete the existing `AZURE_TENANT_ID` Secret to avoid drift between the two values. The old `secrets.AZURE_TENANT_ID` will continue to work in existing operator-modified copies until they are refreshed via `Update-AzLocalPipelineExample`. The setup walkthrough in `Automation-Pipeline-Examples/README.md` ("What success looks like" + steady-state narrative) has been rewritten to reflect the new single-Secret + two-Variables baseline.
- **No cmdlet signature changes.** All v0.7.72 changes are scoped to pipeline-sample YAML files and Markdown docs. No PowerShell source files modified.

## [0.7.71] - 2026-05-19

> **Backward compatible.** Bug-fix + UX polish release on top of v0.7.70. Highlights: fixes the `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -ExportPath *.md` outer-fence bug that caused every markdown element appended after the recommend block in Step.3's pipeline summary to render as a single grey monospace block; fixes the Step.4 critical-count under-reporting bug (`-Sum` over the `CriticalCount` property of per-cluster summary objects instead of filtering for a non-existent `Severity` property); surfaces unparseable cron lines as a new `## Action required - simplify unparseable cron expression(s)` section in `-View Recommend`; renders Cluster Name as a portal hyperlink and Verbose Error Details as an inline `<details>` block in the Step.6 Update Run History table; and migrates the GitHub Actions samples from `secrets.AZURE_SUBSCRIPTION_ID` to `vars.AZURE_SUBSCRIPTION_ID` (the value is consumed only by `azure/login@v3` to set the default `az account` context - it is NOT used to scope ARG queries or to build portal URLs). Pipeline pin bumps to `'0.7.71'`; refresh existing copies with `Update-AzLocalPipelineExample`.

### Fixed

- `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -ExportPath *.md` no longer wraps the multi-section snippet inside an outer ```yaml ... ``` fence. The snippet already carries its own inner ```yaml ... ``` around the cron block, so the outer wrap caused the inner closing ``` to close the outer fence and the outer closing ``` to open a new fence that was never closed. Step.3's pipeline summary (`### Audit Detail - Cron coverage` table, `### Reports Available` list, timestamp) was rendering as a single grey monospace code block downstream of the recommend snippet. The snippet is now emitted verbatim and the inner fence stays balanced.
- `Step.4_assess-update-readiness.yml` (GH + ADO) Critical health failure count under-reported ("0 Critical findings" while the JUnit XML showed 46). `Test-AzLocalClusterHealth -PassThru` returns per-cluster summary objects with `CriticalCount` / `WarningCount` / `Failures` (nested array), NOT flat finding rows with a `Severity` property. The pipeline now aggregates the total via `Measure-Object -Property CriticalCount -Sum` and counts affected clusters via `Where-Object { [int]$_.CriticalCount -gt 0 }`.

### Added

- `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` emits a new `## Action required - simplify unparseable cron expression(s)` section between the schedule-fix sections and the cron-coverage section when one or more YAML cron lines failed to parse. Lists every offending cron with its source `file:line` and the parser's error message so the operator can rewrite the line directly from the Step Summary. Sequenced before the cron-coverage section so the operator fixes parser-blind crons BEFORE accepting the cron-coverage recommendation (which may otherwise over-suggest entries that duplicate an already-correct-but-unparseable line). When only one action overall applies, the `(N of M)` numbering prefix is dropped (existing behaviour, extended to include the new section in the count).
- `Get-AzLocalUpdateRunFailures` projects a new `ClusterPortalUrl` property (`https://portal.azure.com/#@/resource{ClusterResourceId}`) on every output row, alongside the existing `UpdateRunPortalUrl`. Consumed by Step.6 to render Cluster Name as a deep link, and available to any other consumer that wants to render a cluster portal link without rebuilding the URL.

### Changed (pipeline samples)

- **Step.6 Update Run History markdown table**: Cluster Name renders as `[ClusterName](ClusterPortalUrl)` (per-row, from the projection above). Verbose Error Details now renders inside an inline `<details><summary>Show error</summary><br><code>...</code></details>` block so the full parser/orchestrator stack is preserved (no more 250-char truncation) but the table stays scannable - rows expand on click. HTML-special chars (`<`, `>`, `&`) are escaped to keep the renderer honest; newlines collapse to `<br>` so multi-line stack traces remain readable inside the collapsible block; pipes are escaped so the table row stays intact. Applies to both GH and ADO.
- **`Step.3_apply-updates-schedule-audit.yml` (GH + ADO)**: drops the `(v0.7.69)` suffix from its summary heading - the `GENERATED_AGAINST_MODULE_VERSION` pin is authoritative.
- **All 8 GitHub Actions `Step.*.yml` workflows** read the Azure subscription id from `vars.AZURE_SUBSCRIPTION_ID` (Variable) instead of `secrets.AZURE_SUBSCRIPTION_ID` (Secret). Rationale: the value is consumed ONLY by `azure/login@v3` to set the default `az account` context for cmdlets that REQUIRE a subscription. It is NOT used to scope ARG queries (the helpers omit `--subscriptions` so the query runs fleet-wide against every subscription the federated identity can read) and it is NOT interpolated into portal URLs (each row carries its own ARG-projected `subscriptionId` from which deep-links are built per row). Treating it as a Variable also means the value appears plaintext in workflow logs, matching its public non-sensitive nature, and removes the need for an extra Secret rotation in tenants where the value already lives in a Variable. Azure DevOps pipelines were already authenticating via a service connection and need no change. Setup docs in `AzLocal.UpdateManagement/README.md` + `Automation-Pipeline-Examples/README.md` updated to walk through the Variable setup.

### Pipeline pin bumps

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.70'` to `'0.7.71'`. The Step.0 authentication validation workflow does not pin a module version (it only validates Azure auth + RBAC + ARG scope and does not install the module from PSGallery). Refresh existing copies with:

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

## [0.7.70] - 2026-05-19

> **Backward compatible.** All v0.7.70 changes are additive over v0.7.69: a recurring **Step.0 Authentication Validation and Subscription Scope Report** (replacing the one-shot smoke test framing), two new exported cmdlets (`Get-AzLocalFleetHealthOverview` and `Get-AzLocalLatestSolutionVersion`), a new "Update Run History and Error Details" section in Step.6, a new manifest-anchored rolling 6-month YYMM support window in Step.6 (queries `aka.ms/AzureEdgeUpdates`), a new `Section` column on the Step.3 audit rows (defaults to `Cron`), new `TargetResourceName` / `TargetResourceType` / `ClusterPortalUrl` / `AffectedClusterPortalUrls` properties on `Get-AzLocalFleetHealthFailures` output, and richer Step.3 + Step.7 pipeline summaries. No behaviour change for callers that don't read the new columns. Pipeline pin bumps to `'0.7.70'`; refresh existing copies with `Update-AzLocalPipelineExample`.

### Added

- **New cmdlet `Get-AzLocalFleetHealthOverview`** - one row per cluster, ARG-first fleet health summary built via a single Azure Resource Graph batch read for fleet-scale performance. Joins `microsoft.azurestackhci/clusters` with the cluster's `updateSummaries` extensibility resource via a single Resource Graph query. Output columns (12 in order): `ClusterName`, `ClusterPortalUrl`, `HealthStatus`, `UpdateStatus`, `CurrentVersion`, `SbeVersion`, `AzureConnection`, `LastChecked`, `HealthResultsAgeDays` (`datetime_diff('day', now(), LastChecked)`), `ResourceGroup`, `NodeCount`, `SubscriptionId`. Sort: `HealthResultsAgeDays desc, ClusterName asc`. Supports `-SubscriptionId`, `-UpdateRingTag` (incl. wildcard `***` + semicolon-list), `-ExportPath`, `-PassThru`.
- **New cmdlet `Get-AzLocalLatestSolutionVersion`** - queries the Microsoft Azure Local public solution-update catalog at `https://aka.ms/AzureEdgeUpdates` (unauthenticated) and returns the latest released solution version plus the rolling 6-month YYMM support window calendar-stepped from that release (year rollover honoured). Output PSCustomObject: `LatestYYMM`, `LatestVersion`, `SupportedYYMMs[]` (length = `-SupportWindowMonths`, default 6, configurable 1-24), `AllReleases[]`, `ManifestUrl`, `ManifestFetchedAt` (UTC), `SupportWindowMonths`, `Source = 'aka.ms/AzureEdgeUpdates'`. Tolerant of both XML shapes the manifest exposes (`ApplicableUpdate/UpdateInfo` and `PackageMetadata/ServicesUpdates/Update/UpdateInfo`). Used by Step.6 to anchor the SupportStatus column on the upstream catalog instead of fleet-observed values, so older releases fall out of support automatically as soon as Microsoft publishes a newer YYMM.

### Changed (cmdlets)

- **`Test-AzLocalApplyUpdatesScheduleCoverage` Audit rows now carry a `Section` discriminator.** `Schedule` is set on `RingMissingFromSchedule` / `RingOrphanedInSchedule` rows (the ring is the unit of work) and the row's `UpdateWindow` / `RequiredCronUTC` columns are intentionally empty for those rows. `Cron` is set on the existing ring/window coverage rows. Default sort is now Schedule-section first, then cron coverage. Callers that don't filter on `Section` see no behavioural change.
- **`Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` now emits a multi-section markdown report.** When `RingMissingFromSchedule` rows are present, an "Action required - add these rings to apply-updates-schedule.yml" section is emitted FIRST. An "Action required - cron coverage (paste into Step.5_apply-updates.yml)" section is emitted SECOND with the cron entries. When `-SchedulePath` is omitted only the cron section is emitted (back-compat for v0.7.68 callers).
- **`Get-AzLocalFleetHealthFailures` Summary now sorts Critical-first.** Sort is Severity (Critical, then Warning, then everything else), then `ClusterCount` desc, then `FailureCount` desc. A Critical failure affecting 1 cluster ranks above a Warning affecting many clusters.
- **`Get-AzLocalFleetHealthFailures` Detail rows gain three properties.** `TargetResourceName`, `TargetResourceType` (sub-resource that emitted the check failure - e.g. the NIC name and `Microsoft.Compute/virtualMachines/networkInterfaces`), and `ClusterPortalUrl` (`https://portal.azure.com/#@/resource{ClusterResourceId}` deep-link).
- **`Get-AzLocalFleetHealthFailures` Summary rows gain `AffectedClusterPortalUrls`** aligned with `AffectedClusters`. Same element count, same order, joined with the `'; '` separator (semicolon-space). Step.7 zips the two lists into `[ClusterName](portalUrl)` markdown links in the run summary.

### Changed (pipeline samples)

- **`Step.0_authentication-test.yml` (GH + ADO) - repositioned as a recurring audit.** Renamed from "Authentication Validation Test" to **"Step.0 - Authentication Validation and Subscription Scope Report"**. Pipeline now emits a JUnit XML report (`auth-report.xml`) with three testsuites - Authentication / Subscription Scope (one testcase per accessible subscription plus a count testcase) / Resource Graph Reachability - rendered in the GitHub Checks UI via `dorny/test-reporter@v3` and the Azure DevOps **Tests** tab via `PublishTestResults@2`. Adds a markdown summary at the top of every run with `Count of subscriptions = N` and a per-subscription detail table (Name / SubscriptionId / TenantId / State) written to `$GITHUB_STEP_SUMMARY` (GH) or uploaded via `##vso[task.uploadsummary]` (ADO), and an `auth-report` pipeline artifact (XML + `subscriptions.json` + `subscriptions.csv`). Operator guidance updated: re-run monthly (or after any RBAC / federated-credential / subscription change) instead of deleting the file after the first green run - drift in subscription scope is the earliest signal that downstream fleet reports are about to silently under- or over-count clusters.
- **`Step.6_fleet-update-status.yml` (GH + ADO) - new "Update Run History and Error Details" section.** A new `<testsuite name="Update Run History and Error Details">` testsuite in the JUnit XML and a matching `### Update Run History and Error Details` markdown table in the run summary surface up to 25 of the most recent unresolved Failed update runs across the fleet (last 30 days). Each row links to the Azure portal `SingleInstanceHistoryDetails` deep-link and includes Status / CurrentStep / Duration / LastUpdated / DeepestErrMsg for at-a-glance triage. Sourced from `Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved` (ARG-first, fleet-scale).
- **`Step.6_fleet-update-status.yml` (GH + ADO) - new "Overall Fleet Update Status (Version Distribution)" section.** A new `<testsuite name="Fleet Version Distribution">` is emitted as the **first** child of `<testsuites>` (before `AzureLocalFleetUpdateStatus`) and a matching `### Overall Fleet Update Status (Version Distribution)` markdown section is prepended to the run summary (above `### Critical Health Status`). One row per distinct `CurrentVersion` reported by `Get-AzLocalClusterUpdateReadiness`, sorted by cluster count descending, with columns: Version / YYMM / SupportStatus / Cluster Count / Percentage / Clusters. `SupportStatus` uses a **rolling 6-month YYMM window anchored on the Microsoft public catalog** when reachable (preferred), and falls back to a fleet-observed top-6 YYMM heuristic when the manifest is unreachable from the runner (see new cmdlet `Get-AzLocalLatestSolutionVersion` below). **Supported** = YYMM is inside the manifest-anchored or fleet-observed window; **Unsupported** = older parseable YYMM; **Unknown** = empty / malformed `CurrentVersion`. The markdown section includes inline links to the Microsoft Azure Local [lifecycle cadence](https://learn.microsoft.com/azure/azure-local/update/about-updates-23h2#lifecycle-cadence) and [release information](https://learn.microsoft.com/azure/azure-local/release-information-23h2#about-azure-local-releases) docs as the operator cross-check. No external query (other than the unauthenticated manifest probe) and no `<failure>` tags - the testsuite is informational and never breaks the build.
- **`Step.6_fleet-update-status.yml` (GH + ADO) - manifest-anchored rolling support window.** The SupportStatus block now invokes the new `Get-AzLocalLatestSolutionVersion` cmdlet to query the Microsoft public catalog at `https://aka.ms/AzureEdgeUpdates` (unauthenticated). When the manifest is reachable, the latest released solution version's YYMM seeds a calendar-stepped 6-month window (e.g. latest YYMM = `2604` -> `2604,2603,2602,2601,2512,2511`) so as soon as Microsoft publishes any release with a newer YYMM, the window slides forward and the oldest in-window YYMM (e.g. `2510`) falls out automatically - independent of what is installed in the fleet. The JUnit testsuite gains `supportSource` / `latestReleasedYymm` / `latestReleasedVersion` / `manifestUrl` / `manifestFetchedAt` properties; the markdown summary annotates which anchor source was used and (on success) the latest released YYMM + version. When the manifest is unreachable from the runner the pipeline emits a non-fatal warning (`::warning::` on GH, `##vso[task.logissue type=warning]` on ADO) and falls back to the existing fleet-observed top-6 YYMM heuristic so Step.6 still reports.
- **`Step.3_apply-updates-schedule-audit.yml` (GH + ADO) - dual JUnit, dual Audit Detail, inline Recommend when issues exist.** The YAML now emits TWO JUnit `<testsuite>` blocks (`ScheduleCoverage` + `CronCoverage`) and TWO Audit Detail markdown tables (one per section) with conditional headings. When `$hasIssues -and $reco`, the Recommend cmdlet output is prepended above the detail tables so operators see the fix before scrolling. The zero-row JUnit placeholder text is now centralised via the `Write-Suite -EmptyPlaceholderName 'No tagged clusters found - nothing to audit'` helper (GH parity with ADO since v0.7.67 is preserved).
- **`Step.7_fleet-health-status.yml` (GH + ADO) - cluster portal hyperlinks + 3 new detailed columns + new Fleet Health Overview section.** The Summary and Detailed Results tables now render cluster cells as `[ClusterName](portalUrl)` markdown links (capped at first 10 in the Summary, then `... (+N more)`). Detailed Results adds three columns: Failure Remediation (auto-renders as `[link](url)` when the value starts with `https://`), Target Resource Name, and Target Resource Type. A new "### Fleet Health Overview (fleet rollup)" section calls `Get-AzLocalFleetHealthOverview` and publishes `fleet-health-overview.csv` / `.json` to the Reports list alongside the failures table.
- **Pipeline pin bumps.** All 14 `Step.*.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.69'` to `'0.7.70'`.

## [0.7.69] - 2026-05-18

> **Hard break vs v0.7.68.** Schema `schemaVersion: 1` for the new `apply-updates-schedule.yml` is the first stable version of this file. There are no v0 -> v1 migration recipes shipped (the framework is in place; the recipes table is intentionally empty). If you were running an experimental schedule from earlier development builds, regenerate via `New-AzLocalApplyUpdatesScheduleConfig`.

### Added

- **Ring-aware apply-updates schedule (5 new cmdlets).** Day-grain `apply-updates-schedule.yml` (schema v1) is now the single source of truth for "which `UpdateRing` is eligible on a given UTC date". Three independent layers control "what runs when":
  1. **This file (day-grain)** says WHICH `UpdateRing` tag values are eligible TODAY.
  2. **The Step.5 cron schedule (intra-day-grain)** says HOW OFTEN the apply-updates job wakes up.
  3. **The per-cluster `UpdateWindow` tag (minute-grain)** says WHEN, during an eligible day, the actual update is allowed to start.
- `Get-AzLocalApplyUpdatesScheduleConfig` - parses + validates a schedule file. **Hard-fails with `'schedule:' list is empty - at least one row is required`** when the schedule has no active rows; this is the safety gate the apply-updates pipeline depends on (see the strawman generator below).
- `Resolve-AzLocalApplyUpdatesScheduleRing` - maps a UTC date to the matching `UpdateRing(s)` using cycle-week math anchored at `cycleAnchorISOWeek` / `cycleAnchorYear`. **Union semantics**: when multiple rows match, the resolver concatenates their `rings` columns with `;` and passes the deduplicated result to `-UpdateRingValue`.
- `Get-AzLocalApplyUpdatesScheduleNextFirings` - previews the next N days of resolved firings so operators can sanity-check the rotation before committing.
- `New-AzLocalApplyUpdatesScheduleConfig` - generates a **STRAWMAN** schedule from the live fleet's `UpdateRing` tag values (or from `-Rings` for offline use). Every generated schedule row is emitted **commented out by design**, so the apply-updates pipeline hard-stops at the reader until the operator reviews and uncomments at least one row. Output mirrors the bundled `apply-updates-schedule.example.yml` instructional comments verbatim, including the Wikipedia ISO-week link and the 3-layer key concept; the worked example anchor is computed dynamically (`ISO Week 1 of <year> began on Monday, <date>`) but the actual anchor is the current ISO week so "week 1 of the cycle = the week you ran the generator".
- `Update-AzLocalApplyUpdatesScheduleConfig` - idempotent migrator that walks an existing schedule through registered migration recipes. v0.7.69 ships the recipes table empty (no migrations needed yet); the framework is in place for future schema bumps.
- **`Test-AzLocalApplyUpdatesScheduleCoverage` gained `-SchedulePath`** (two-way ring diff). When supplied, the audit emits two new status rows: `RingMissingFromSchedule` (fleet ring with no schedule row) and `RingOrphanedInSchedule` (schedule ring no cluster carries). Both are surfaced in the summary table, the JUnit XML failure list, and the Markdown summary at the top of the Step.3 run page.

### Changed (pipeline samples)

- **`Step.5_apply-updates.yml` (GH + ADO)** now resolves the `UpdateRing` value from `apply-updates-schedule.yml` on every **scheduled** firing. Manual `workflow_dispatch` (GH) / non-`Schedule` `Build.Reason` (ADO) runs still honour the operator-supplied `-UpdateRingValue` input verbatim, so back-compat for ad-hoc maintenance is preserved.
- **Concurrency:** Step.5 gained a workflow-level `concurrency:` block on GitHub Actions to prevent overlapping cron firings. Azure DevOps has no first-class YAML concurrency primitive; the ADO version documents the equivalent **Pipeline Settings -> Triggers -> Limit concurrent runs** option in a banner comment.
- **`Step.3_apply-updates-schedule-audit.yml` (GH + ADO)** gained a `schedule_path` / `schedulePath` input (defaulted to the standard layout), a `debug` toggle for self-service triage (`$VerbosePreference=Continue`, `$DebugPreference=Continue`, plus a one-shot environment snapshot), and surfaces the new `RingMissingFromSchedule` / `RingOrphanedInSchedule` counts in the summary table + JUnit failure list. When `pipeline_path` is empty and `schedule_path` is set, the audit runs schedule-file-only (no cron-vs-tags audit).
- **`apply-updates-schedule.example.yml`** ships as documentation only; pipeline-deployment cmdlets (`Copy-AzLocalPipelineExample` / `Update-AzLocalPipelineExample`) do **not** touch it. Operators run `New-AzLocalApplyUpdatesScheduleConfig` to generate a strawman starting from their live fleet's `UpdateRing` tag values.

### Migration

For a fleet that has already been tagged via `Set-AzLocalClusterUpdateRingTag`:

```powershell
# 1. Generate a strawman schedule (all rows commented out by design)
New-AzLocalApplyUpdatesScheduleConfig -OutputPath .\.github\apply-updates-schedule.yml

# 2. Open the file, REVIEW each strawman row, then UNCOMMENT the rows
#    that match your change-control policy. Edit weeksInCycle /
#    daysOfWeek / rings / notes as needed.

# 3. Preview the rotation BEFORE committing
Get-AzLocalApplyUpdatesScheduleNextFirings `
  -Schedule (Get-AzLocalApplyUpdatesScheduleConfig -Path .\.github\apply-updates-schedule.yml)

# 4. Refresh the pipeline YAMLs so they pick up the v0.7.69 resolver wiring
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps

# 5. Audit the fleet against the schedule (two-way ring diff)
Test-AzLocalApplyUpdatesScheduleCoverage `
  -PipelineYamlPath .\.github\workflows\Step.5_apply-updates.yml `
  -SchedulePath     .\.github\apply-updates-schedule.yml `
  -View Audit
```

Without an active (uncommented) row the apply-updates pipeline will hard-fail at the reader step with the exact remediation message; this is the v0.7.69 safety gate, not a regression.

## [0.7.68] - 2026-05-18

### Added

- **New cmdlet `Update-AzLocalPipelineExample`.** Marker-aware merge tool that refreshes a customer's copy of any bundled pipeline YAML to the version shipped with the current module **while preserving operator edits inside `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` marker pairs**. Customer-side cron schedules in `schedule-triggers` and ITSM secret bindings in `itsm-secrets` (Step.5 only) survive a module upgrade; everything outside the markers is replaced with the new bundled content. Supports `-WhatIf` for preview, `-Force` for non-interactive runs, and `-PassThru` for a per-file change manifest. This is the operator-friendly upgrade path that complements `Copy-AzLocalPipelineExample` (which remains the clean-overwrite tool).
- **New cmdlet `Get-AzLocalUpdateRunFailures`.** ARG-only deep-error extraction (9 levels deep into the `properties.state.progress` tree of `microsoft.azurestackhci/clusters/updates/updateRuns`) returns verbose error information at fleet scale without per-cluster Az SDK or REST shell-outs. Two views: `-View Summary` (one row per failed update run) and `-View Detail` (one row per leaf failure with the full breadcrumb to the failed step). Useful in `Step.5_apply-updates.yml` post-mortem reports and as a follow-up call after `Get-AzLocalFleetProgress` reports failures.
- **`Invoke-AzResourceGraphQuery` now retries on HTTP 429 (throttle).** The helper inspects the `Retry-After` response header when present and otherwise applies bounded exponential backoff (capped at the documented Azure Resource Graph throttling envelope). Large fleet sweeps (Get-AzLocalFleetProgress, Get-AzLocalFleetStatusData, the schedule-audit pipeline) no longer fall over at the throttling boundary; the existing happy-path latency is unchanged.
- **Cmdlet inventory and design table (`docs/Cmdlet-Inventory-And-Design.md`).** Documents which cmdlets read vs write, which back-end they use (ARG vs Az SDK vs az CLI), and the design rules that keep read paths ARG-first (no `-ThrottleLimit`, no per-cluster Get-AzResource fan-out). Removes ambiguity about which path a new cmdlet should take.
- **Layer 1 AZLOCAL-CUSTOMIZE marker pairs in 7 pipeline YAMLs.** Two named regions (`schedule-triggers` and, on `Step.5_apply-updates.yml` only, `itsm-secrets`) mark the YAML areas that operators commonly customise: cron schedules, ITSM secret bindings. Markers are pure YAML comments and have no runtime effect; they are scaffolding for the forthcoming `Update-AzLocalPipelineExample` cmdlet that will preserve operator edits inside these regions across module upgrades. Documented in `Automation-Pipeline-Examples/README.md`.

### Changed (ARG-first refactor)

- **The following cmdlets are now ARG-first single-batch reads.** `-ThrottleLimit` is removed (it was a no-op against ARG and merely signalled "this cmdlet does a fan-out"):
  - `Get-AzLocalUpdateSummary`
  - `Get-AzLocalAvailableUpdates`
  - `Get-AzLocalClusterUpdateReadiness`
  - `Test-AzLocalClusterHealth`
  - `Get-AzLocalFleetProgress`
  - `Get-AzLocalFleetStatusData`
  - `New-AzLocalFleetStatusHtmlReport`

  All shipped pipeline YAMLs were updated to stop passing `-ThrottleLimit`. The aggregated effect on the cluster API is a 5-10x reduction in subscription-level Azure Resource Manager calls for the common fleet-status pipelines.
- **`Get-AzLocalFleetProgress` no longer silently returns stale state on empty ARG result rows.** The previous code-path treated an empty ARG response as "no change" and returned the last cached state; consumers (including the `Step.6_fleet-update-status.yml` JUnit emitter) therefore reported "everything green" on fleets that had been completely de-tagged or that hit a transient ARG error. The cmdlet now surfaces the empty-fleet condition explicitly so the operator can act on it.
- **`Invoke-AzResourceGraphQuery` hardened against `az.cmd` CR/LF stdout truncation.** A latent bug in `az.cmd` (Windows runners only) could chop the JSON payload at the first chunked-write boundary when stdout was piped through PowerShell, producing the N-row collapse where a 27-cluster fleet would surface as 24 rows. The helper now reads stdout via `[Console]::OpenStandardOutput()` redirect into a `MemoryStream` (or equivalent: a `2>&1 | Out-String` capture with explicit `[System.Text.Encoding]::UTF8` decoding) so the full payload arrives intact. Existing Pester unit tests pin the regression.

### Changed (pipeline samples - renames and Step.X_ prefix)

- **All 16 bundled pipeline YAMLs renamed with a `Step.X_` ordering prefix** so they sort by execution order in a customer's repo:
  - `Step.0_authentication-test.yml`            (was `auth-smoke-test.yml`)
  - `Step.1_inventory-clusters.yml`
  - `Step.2_manage-updatering-tags.yml`
  - `Step.3_apply-updates-schedule-audit.yml`
  - `Step.4_assess-update-readiness.yml`
  - `Step.5_apply-updates.yml`
  - `Step.6_fleet-update-status.yml`
  - `Step.7_fleet-health-status.yml`

  Both platforms (GitHub Actions and Azure DevOps). The rename plus the `Step.0` -> `Step.7` numbering matches the documented operator runbook order and lets a fresh `Copy-AzLocalPipelineExample` lay the pipelines out so that an alphabetic listing in the consumer's IDE / repo browser tells the story end-to-end.
- **Backwards compatibility for already-deployed consumers:** `Read-AzLocalApplyUpdatesYamlCrons` (the schedule-audit scanner) glob list expanded to match both new (`Step.5_apply-updates*.yml`) and legacy (`apply-updates*.yml`) names. A customer who upgrades the module but has not yet re-run `Copy-AzLocalPipelineExample` will still see correct schedule-coverage audits.

### Changed (pipeline display ordering)

- **Each shipped pipeline YAML now carries the `Step.N - ` prefix in the workflow display name, not just the filename.** GitHub Actions: the top-level `name:` field in each of the 8 workflows reads `Step.N - <description>` (e.g. `Step.0 - Auth Smoke Test`, `Step.7 - Fleet Health Status`); the Actions sidebar sorts alphabetically by this field, so the 8 workflows now list in execution order. Azure DevOps: the leading title comment in each of the 8 YAMLs reads `# Step.N - <description>`, which is the value the import wizard prefills as the pipeline's definition name. New section 1.1 in `Automation-Pipeline-Examples/README.md` documents the convention and explains the GH-Actions-vs-ADO behavioural difference.

### Fixed

- **Latent single-element-array unwrap bug in `Get-AzLocalUpdateRuns` and `Get-AzLocalClusterUpdateReadiness`.** Both cmdlets group ARG rows into a `Hashtable<string, List[object]>` and then look up the per-cluster bucket with the pattern `$x = if ($h.ContainsKey($key)) { @($h[$key]) } else { @() }`. Under PowerShell 5.1 the `if` block's pipeline return unwraps a single-element `Object[]` to its bare element, and `PSCustomObject.Count` is empty (not 1) under strict mode, so any cluster having **exactly one** update run / one available update would be silently treated as having zero items - `Get-AzLocalUpdateRuns` would print `No Runs` against that cluster, and `Get-AzLocalClusterUpdateReadiness` would emit a degraded "no updates available" row. The fix replaces the brittle ternary with an explicit `$x = @(); if (...) { $x = @($h[$key]) }` assignment that preserves Object[] semantics. New Pester guards (`Get-AzLocalUpdateRuns parallel dispatch` + `Get-AzLocalClusterUpdateReadiness (ARG-batch dispatch)`) pin the regression with mock data that returns exactly one row per cluster.

### Tests

- **All five `Describe` blocks that were `-Skip`-marked in the v0.7.68 ARG-first refactor have been un-skipped and rewritten against `Invoke-AzResourceGraphQuery` mocks.** 10 tests now pass (FleetProgress: 2, UpdateSummary: 2, ClusterUpdateReadiness multi-cluster: 1, ClusterUpdateReadiness readiness gates: 4, Get-AzLocalUpdateRuns parallel dispatch: 1). The new mock pattern uses `InModuleScope` + a `function global:az { ... }` shim + `Mock Test-AzCliAvailable` / `Mock Install-AzGraphExtension` / `Mock Invoke-AzResourceGraphQuery` returning rows shaped per each cmdlet's KQL `project` clause (`ClusterResourceId_`, `properties` bag matching the ARM REST shape). Plus +4 new throttle-handling tests against `Invoke-AzResourceGraphQuery` (retry-then-succeed on 429, max-retries-exhausted, no-retry on non-throttle errors, diagnostic flags reset per call) and +3 `Get-AzLocalFleetStatusData` schema-contract tests (top-level shape + types, `ValidateNotNullOrEmpty` on `-ClusterResourceIds`, `ModuleVersion` field tracks the module-scope constant). Full suite: **Passed=511, Failed=0, Skipped=0**.

If you have copied any of the bundled workflows into your repo, refresh them via:

```powershell
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
```

This brings in the new file names *and* the Layer 1 marker scaffolding. Operator-customised cron schedules and ITSM secret bindings between `BEGIN-AZLOCAL-CUSTOMIZE` / `END-AZLOCAL-CUSTOMIZE` markers in your already-deployed YAMLs are intentionally **not** preserved by `Copy-AzLocalPipelineExample` (it is a clean overwrite tool); the forthcoming `Update-AzLocalPipelineExample` cmdlet will do the marker-aware merge.

## [0.7.67] - 2026-05-18

### Added (CI/CD parity and documentation)

- **GitHub Actions schedule-audit pipeline now emits a passing testcase when the fleet has no tagged clusters.** `apply-updates-schedule-audit.yml` (GitHub Actions) previously wrote an empty `<testsuite>` to `schedule-coverage-audit.xml` whenever there were no `(UpdateRing, UpdateWindow)` rows to evaluate. `dorny/test-reporter` then surfaced the run as "no tests found", which is indistinguishable from a misconfigured reporter step. The pipeline now writes `<testcase classname="ScheduleCoverage" name="No tagged clusters found - nothing to audit" />` for the zero-row case, matching the existing Azure DevOps behaviour. Operators get a clean "passed (1/1)" reading in the Tests tab regardless of whether the fleet has any tagged clusters yet, which removes the daily false-alarm during onboarding (no clusters tagged) and after fleet-wide tag clean-ups.

- **Schedule-audit summary now surfaces ready-to-paste cron entries at the top when coverage drift exists.** Both `apply-updates-schedule-audit.yml` (GitHub Actions and Azure DevOps) previously emitted the recommended cron block at the bottom of the run summary, after the audit detail table. When the audit reported any `Uncovered`, `PartiallyCovered`, `MalformedTag`, or `UnparseableCron` rows the operator had to scroll past the detail table to find the actionable fix. The pipelines now compute `$hasIssues` from those four counts and, when true, render an `### Action required - paste these cron entries into apply-updates.yml` section immediately below the counts table - before the detail rows. When the fleet is fully covered the recommendation block remains at the bottom as a reference, so the all-green case is visually unchanged. A new Pester guard (`v0.7.67 schedule-audit summary - cron fixes first when issues exist`) asserts that both YAMLs carry the conditional structure and that the "Action required" header appears textually before the "Audit Detail" header in the script body, so any future edit that reverses the ordering will fail in CI.

- **Pipeline README now includes an artifact-handoff map of the end-to-end runbook.** `Automation-Pipeline-Examples/README.md` section 6 carried a phase-oriented flow diagram (Inventory -> Tag -> Rollout -> Steady-state). The new "Artifact handoffs at a glance" subsection adds an explicit data-flow diagram showing which artifact each pipeline emits and which downstream pipeline consumes it (e.g. `cluster-inventory.csv` from Inventory feeds the manual tagging edit and the manage-tags pipeline; `cluster-readiness.csv` from Assess feeds Apply via its `ClusterResourceId` column; `schedule-coverage-recommend.md` from the audit is the only artifact intended to be pasted by hand). The accompanying bullet list calls out the four artifacts operators most commonly trip on (the operator-edited CSV, the readiness handoff that Apply consumes verbatim, the JUnit XML that drives the Tests tab, and the recommendation file that must be pasted into `apply-updates.yml`).

- **New maintainer doc: [`docs/RELEASE-PROCESS.md`](docs/RELEASE-PROCESS.md).** Documents the staged unlisted-release flow the module uses (publish -> immediately unlist -> validate against a test repo with `REQUIRED_MODULE_VERSION` exact-pinned to the candidate -> list after validation passes), the verification commands for each stage, and the Pester guardrails that the release flow relies on. This puts the release rules in the repo rather than in tribal knowledge / chat history. Pipeline consumers do not need this doc; module maintainers do.

- **`Automation-Pipeline-Examples/README.md` section 11 (Security model) now documents per-job `permissions:` blocks as an intentional security feature.** Every shipped GitHub Actions workflow declares its own job-level `permissions:` block (`id-token: write`, `contents: read`, `checks: write` only where needed). The new bullet calls out that consumers should not lift those blocks to a top-level `permissions:` block when copying samples, and explains how the per-job shape (a) limits token scope to exactly the job that needs the write and (b) lets you keep `id-token: write` off read-only summary jobs. Also documents that the samples are compatible with the recommended *Settings -> Actions -> General -> Workflow permissions = Read repository contents and packages permissions* hardening, because every job that needs a write already declares it explicitly.

### Changed (consistency)

- **All Azure DevOps sample pipelines now use the same `azureSubscription:` placeholder.** Four files (`assess-update-readiness.yml`, `fleet-health-status.yml`, `fleet-update-status.yml`, `apply-updates-schedule-audit.yml`) previously used `'YOUR-SERVICE-CONNECTION-NAME'` while the other four ADO YAMLs (`apply-updates.yml`, `manage-updatering-tags.yml`, `inventory-clusters.yml`, `auth-smoke-test.yml`) used `'AzureLocal-ServiceConnection'` with an `# Update with your service connection name` comment. All eight ADO pipelines now use `'AzureLocal-ServiceConnection'` + comment - the placeholder matches the value documented in section 3.2 of the pipeline README (and matches the `New-AzureServiceConnection` example name), so an operator who follows the auth setup verbatim no longer has to find-and-replace anything in the YAMLs. Consumers who keep an existing service connection with a different name override at copy time.

### Fixed (in-depth module review - batch 3)

This batch addresses the six findings from the post-batch-2 module review. None are user-visible behaviour changes for the happy path; all are defence-in-depth.

- **`$script:ModuleVersion` constant in `AzLocal.UpdateManagement.psm1` is now bumped in lock-step with the `.psd1` manifest, and a new Pester guard fails any future drift.** The script-scope constant is what `Start-AzLocalClusterUpdate` writes into its run-log header and what `Get-AzLocalFleetStatusData` writes into the `ModuleVersion` field of the fleet-state JSON. It had been stuck at `'0.7.66'` while the manifest moved to `'0.7.67'`, so every v0.7.67 run-log and every v0.7.67 fleet-state file misreported the producing module version - which is the exact field operators use to triage CI vs local-runner discrepancies. New test `Module version constants are in sync between .psm1 and .psd1` asserts `(Import-PowerShellDataFile ...).ModuleVersion -eq InModuleScope { $script:ModuleVersion }` so the next forgotten bump is caught at build time.

- **New private helper `Invoke-AzCliJson` for the `az <subcommand>` calls that need JSON parsing but cannot go through `Invoke-AzRestJson`.** The cp1252 stderr-warning regression that v0.7.66 fixed in `Invoke-AzRestJson` (and v0.7.67 batch-1 backported into `Invoke-AzResourceGraphQuery`) had three remaining ambush sites where the unsafe `az ... 2>&1 | ConvertFrom-Json` pattern was still in use: `Get-AzLocalClusterInventory` resolving subscription display names via `az account show`, `Invoke-AzLocalSideloadedAutoResetForCluster` reading the cluster tags via `az rest`, and `Set-AzLocalClusterTagsMerge` reading the tags-subresource via `az rest`. The two `az rest` callers now go through the existing `Invoke-AzRestJson`. The third (`az account show`) goes through the new `Invoke-AzCliJson` helper, which applies the same stream-split-by-element-type pattern, auto-appends `--only-show-errors`, sets `PYTHONIOENCODING=utf-8` as defence-in-depth (and restores it in `finally`), and returns `[PSCustomObject]@{ Ok; Data; Error }` so callers no longer have to inspect `$LASTEXITCODE` manually. Seven new Pester tests cover the helper (clean JSON, cp1252 stderr warning ignored, non-zero exit code surfaces a scrubbed error, empty stdout, non-JSON stdout, `--only-show-errors` appended, `PYTHONIOENCODING` restored).

- **`ConvertFrom-AzLocalCronExpression` now accepts cron step syntax (`*/N`, `<a>-<b>/N`, `<a>/N`).** The schedule advisor was falsely flagging crons such as `*/15 * * * *` (every fifteen minutes), `0 */6 * * 1` (every six hours on Mondays), and `0 9-17/2 * * 1-5` (every two hours between 9 and 17 on weekdays) as `UnparseableCron` - even though both GitHub Actions and Azure DevOps schedule them correctly. The parser now expands `*/N` over the field's full range, `<a>-<b>/N` over the explicit `[a,b]` range, and `<a>/N` over `[a, max]` (the standard "anchor and stride" cron semantics). Step values must be positive integers; out-of-bounds bases still throw with the existing bounds messages. Three new positive tests cover `*/15`, `9-17/2`, and `5/15`; the previously-existing test that asserted `*/15` was *rejected* has been flipped to assert the 672-fires-per-week expansion is correct; a new negative test covers `*/0`.

- **`Reset-AzLocalSideloadedTag` now warns when a `-ClusterResourceIds` entry does not match the expected `/clusters/<name>$` pattern.** The `ByResourceId` resolver previously dropped malformed entries (typos, trailing slash, wrong provider, truncated string) silently - the operator would see "no matching clusters" without any indication that one of their inputs had been excluded. The resolver now emits `Write-Log -Level Warning` for each malformed input naming the exact ResourceId it skipped. The other resolvers (`ByName`, `ByTag`) already warned on lookup failure; this just brings `ByResourceId` to parity. New Pester test asserts the warning fires for `/this/is/not/a/cluster/resource/id`.

- **`Tests/Invoke-Tests.ps1` HTML footer is no longer susceptible to `Get-Module` returning an array.** When nested modules are loaded (which is the default for this module - every Private/*.ps1 is a nested module), `Get-Module AzLocal.UpdateManagement` returns one entry per loaded version, and `.Version` on that array surfaces as `Object[]` whose `ToString()` is the literal string `"System.Object[]"`. The HTML report footer was therefore intermittently printing `Module Version: System.Object[]`. The test runner now selects the newest loaded version via `Sort-Object Version -Descending | Select-Object -First 1` before reading `.Version`.

- **`Import-AzLocalFleetState` now refuses any input file larger than 50 MB before reading it.** The helper previously called `Get-Content -Raw | ConvertFrom-Json` with no size check; pointing it at a multi-GB file (typo, mis-glob, malicious symlink) would have OOMed the runner. Real fleet-state files (`Export-AzLocalFleetState` output) are tens of KB at most, so a 50 MB ceiling is ~3 orders of magnitude above any plausible legitimate input. The cap message names the actual file size in MB and explains what valid input looks like, so the operator can either widen the cap deliberately or fix the path. Two new Pester tests cover the cap (Get-Item mocked to report 60 MB throws) and the happy path (normal-sized fleet-state file loads).

### Pipeline migration

If you have copied any of the bundled workflows into your repo, refresh them via:

```powershell
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
```

## [0.7.66] - 2026-05-18

### Fixed (critical)

- **`Get-AzLocalFleetHealthFailures` failed JSON parsing on hosted Windows runners when the Azure CLI emitted a cp1252 encoding warning.** Any call into `Invoke-AzResourceGraphQuery` (currently used by `Get-AzLocalFleetHealthFailures` and indirectly by every consumer of the `fleet-health-status.yml` pipeline) on a `windows-latest` GitHub Actions runner (or any ADO Windows agent whose console code page is `cp1252`) could surface the following stderr line from the Azure CLI's underlying Python layer:

  ```
  WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded.
  ```

  The helper captured `& az graph query ... 2>&1` as a single merged stream and passed the entire thing to `ConvertFrom-Json`, so the WARNING line got prepended to the JSON body and the cmdlet threw:

  ```
  Conversion from JSON failed with error: Unexpected character encountered while parsing value: W. Path '', line 0, position 0.; raw: WARNING: Unable to encode the output with cp1252 encoding. ...
  ```

  This was the same class of bug that the v0.7.2 hardening of `Invoke-AzRestJson` already handled - the fix never made it into `Invoke-AzResourceGraphQuery` when that helper was split out. The helper has now been updated to:
  1. **The actual fix:** split the merged `2>&1` stream by element type after capture. Stderr lines surface as `[System.Management.Automation.ErrorRecord]` objects when captured via `2>&1`; stdout lines surface as strings. Only the string stream is fed to `ConvertFrom-Json`. The error-throwing path likewise renders the stderr stream separately so token-scrubbing still applies. (`--only-show-errors` was already passed by this helper since v0.7.2, but in some non-cp1252 character paths the encode warning still leaks through, hence the belt-and-braces stream split.)
  2. **Cosmetic defence-in-depth:** set `$env:PYTHONIOENCODING = 'utf-8'` for the duration of the call (previous value restored in a `finally` block). **Note: this is a structural no-op for stock `az.cmd`** - it launches Python with the `-I` (isolated) flag which implies `-E` and causes Python to ignore every `PYTHON*` env var, per [Azure/azure-cli#28497](https://github.com/Azure/azure-cli/issues/28497) and the v0.7.2 root-cause analysis. The assignment only takes effect if the host has manually patched `az.cmd` to remove `-I`. It is retained purely so that those (rare) hosts get the same UTF-8 behaviour as the stream-split path.

  No public surface change. Every fleet-health-status pipeline run on a Windows runner is now resilient to this stderr warning regardless of the runner's console code page.

- **`apply-updates-schedule-audit.yml` (both GitHub Actions and Azure DevOps) shipped with a default `pipeline_path` of `AzLocal.UpdateManagement/Automation-Pipeline-Examples` - a path that only exists in *this* module's source repo, never in a consumer repo.** Every default-trigger run of the schedule audit therefore failed with:

  ```
  PipelineYamlPath 'AzLocal.UpdateManagement/Automation-Pipeline-Examples' does not exist on the runner.
  Either commit the folder to the repo or pass a different -pipeline_path via workflow_dispatch.
  ```

  before the schedule advisor could write its JUnit XML. The next step (`dorny/test-reporter` on GH, `PublishTestResults@2` on ADO) then failed with `Error: No test report files were found matching the pattern 'reports/schedule-coverage-audit.xml'`, making the entire job red. Both YAMLs now default to the standard consumer layout:
  - GitHub Actions: `.github/workflows` (the folder where consumers paste the bundled `apply-updates.yml` sample).
  - Azure DevOps: `.azure-pipelines` (the convention recommended by the ADO docs; consumers who keep apply-updates.yml elsewhere can still override via the `pipelinePath` parameter at queue time).

  When the resolved path still does not exist on the runner (operator override pointed at a missing folder, etc.) the audit step now lists which common pipeline folders **do** exist in the checked-out repo (`.github/workflows`, `.azure-pipelines`, `pipelines`, repo root) so the operator immediately knows what value to pass.

### Added (UX + capability)

- **Status emojis in the Fleet Update Status summary.** `fleet-update-status.yml` (GitHub Actions and Azure DevOps) now renders the `Critical Health` and `Primary Status` summary tables with the same visual language operators already use to read JUnit dashboards: a green tick for "no failures / ready / passing", a red cross for "failed / in error", a refresh glyph for "running / in progress", a yellow circle for "blocked / waiting", and an info glyph for everything else. The legacy `[ok] / [fail] / [ready] / [running] / [blocked] / [info]` bracket markers are gone. The summary block is plain markdown so it renders identically on the GH Actions step summary, the ADO pipeline run extension, and any markdown viewer (no JS, no images).

- **Generation timestamp in the Fleet Update Status summary heading.** Both `fleet-update-status.yml` files now render the H2 heading as `## Fleet Update Status Summary  _(generated 2026-MM-DD HH:MM:SS UTC)_` so downstream consumers can tell at a glance when the data was collected. The timestamp is computed with `(Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')` to keep GitHub Actions and Azure DevOps in sync.

- **Failed clusters now appear before passing clusters in the JUnit per-cluster block.** The per-cluster `<testcase>` entries emitted by both `fleet-update-status.yml` files used to be emitted in arrival order (i.e. ARG response order). They are now bucketed into a `$failedClusters` collection vs a `$passedClusters` collection, each sorted alphabetically by `ClusterName`, then concatenated with failed-first into `$orderedClusters` and emitted in that order. Failing clusters are therefore the first things operators see in the dorny/test-reporter view (GitHub) and the Tests tab (Azure DevOps).

- **Every downloadable pipeline artifact now carries a UTC timestamp suffix.** All `actions/upload-artifact` steps (GitHub Actions) and all `PublishBuildArtifacts@1` / `PublishPipelineArtifact@1` tasks (Azure DevOps) now declare `name:` / `ArtifactName:` of the form `azlocal-<purpose>_yyyyMMdd_HHmmss`. The timestamp is computed once per job in a dedicated `Compute Artifact Timestamp` step (GH: `id: artifact-stamp` writing `timestamp=...` to `$GITHUB_OUTPUT`; ADO: `name: stamp` writing `##vso[task.setvariable variable=artifactStamp;isOutput=true]...`). Two runs of the same pipeline on the same day now produce distinct zip downloads (`azlocal-fleet-update-status-report_20260518_140000.zip` vs `azlocal-fleet-update-status-report_20260518_180000.zip`) instead of clobbering each other in the operator's downloads folder. Renamed artifacts: `fleet-status-reports` -> `azlocal-fleet-update-status-report`, `fleet-health-reports` -> `azlocal-fleet-health-status-report`, `cluster-inventory` -> `azlocal-cluster-inventory`, `updatering-tag-logs` -> `azlocal-updatering-tag-logs`, `schedule-coverage-reports` / `ScheduleCoverageReports` -> `azlocal-apply-updates-schedule-audit-report`, `readiness-report` -> `azlocal-apply-updates-readiness-report`, `readiness-assessment` -> `azlocal-readiness-assessment-report`, `update-logs` -> `azlocal-apply-updates-logs`, `itsm-results` -> `azlocal-apply-updates-itsm-results`.

- **Pipeline `UpdateRing` inputs now accept a single value, a semicolon-delimited list, or the literal `***` wildcard for ALL tagged clusters.** Every pipeline that exposes `update_ring:` (GH workflow_dispatch) or `updateRing:` (ADO parameters) is updated:
  - Single value (unchanged): `Wave1`
  - Multiple rings: `Prod;Ring2` (semicolon separator; whitespace around each ring is trimmed)
  - Wildcard: `***` (three stars, deliberate gesture) matches every cluster that **has** a non-empty `UpdateRing` tag. Untagged clusters are excluded so the wildcard preserves the existing opt-in gate. **A single `*`, double `**`, or quadruple `****` are all REJECTED by the cmdlet's `[ValidatePattern]`** - a one-character typo can no longer accidentally scope a fleet-wide write.

  The ADO `apply-updates.yml` lost its closed `values:` enum (it kept `type: string` so users still get a free-text editor in the ADO run dialog).

- **`ValidatePattern` tightened on 15 cmdlets.** The 14 cmdlets that take `-UpdateRingValue` and the 1 cmdlet that takes `-UpdateRingTag` (`Get-AzLocalFleetHealthFailures`) now share the regex `^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$`. Each individual ring segment still has the same 1-64 character `[A-Za-z0-9_-]` policy as v0.7.65; the changes are (a) `;`-separated lists are now accepted, and (b) **only the exact three-character `***` token is accepted as a wildcard** (single/double/quad stars are rejected). Hostile/malformed inputs (spaces, embedded quotes, `<script>`, leading/trailing `;`) are still rejected at the parameter binder before any Azure call is made.

- **New private helper `ConvertTo-AzLocalUpdateRingKqlFilter`.** Centralises the KQL clause construction for the three forms above. Returns `| where isnotempty(tags['UpdateRing'])` for `***` (matches only tagged clusters), a `| where tags['UpdateRing'] =~ 'single'` clause for a single value, and a `| where tags['UpdateRing'] in~ ('a','b')` clause for a list. Embedded single quotes are doubled (KQL string-literal escape). The 10 ARG-query call sites and the 2 here-string KQL call sites (`Get-AzLocalFleetHealthFailures`, `Reset-AzLocalSideloadedTag`) all now go through this helper, eliminating 12 copies of nearly-identical interpolation logic.

- **Pester regression coverage** for every v0.7.66 feature: a new `Describe 'v0.7.66 UpdateRing ValidatePattern accepts list & wildcard forms'` that reflects on every cmdlet's `ValidatePatternAttribute` and asserts both the acceptance set (`Wave1`, `Prod;Ring2`, `***`, ...) **and the rejection set including the easy-to-mistype `*` / `**` / `****` / `*Wave1` variants**, plus the existing hostile inputs (`Foo bar`, `abc'def`, `<script>`, empty, leading/trailing `;`); a `Describe 'v0.7.66 ConvertTo-AzLocalUpdateRingKqlFilter helper'` exercising every branch including the new `***` -> `isnotempty(...)` path (both default `tags['UpdateRing']` and `tostring(tags['UpdateRing'])` accessors); a `Describe 'v0.7.66 Artifact download names carry a UTC timestamp suffix'` that scans every `Automation-Pipeline-Examples/**/*.yml` and fails if any upload step is missing the `azlocal-` prefix or the `<timestamp>` token (plus four guards against the legacy non-stamped names regressing); a `Describe 'v0.7.66 Fleet Update Status summary uses status emojis and groups failures first'` that asserts the U+2705 and U+274C glyphs are present and that the legacy `[ok]/[fail]` markers are gone, that the `_(generated $generatedUtc)_` heading is present, and that the `$failedClusters` / `$passedClusters` / `$orderedClusters` bucketing tokens all appear; and a `Describe 'v0.7.66 Pipeline update_ring inputs document multi-value and wildcard support'` that asserts every input description mentions both `Prod;Ring2` and `'***'`.

### Pipeline migration

If you have copied any of the bundled workflows into your repo, refresh them via:

```powershell
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
```

## [0.7.65] - 2026-05-17

### Added

- **New function `Get-AzLocalFleetHealthFailures`** - queries Azure Resource Graph for every cluster the caller can read and surfaces the 24-hour system health-check entries with `status == 'Failed'`. Two views are supported: `-View Detail` returns one row per (cluster, failing check) and `-View Summary` aggregates by failure reason so administrators can see "what should I fix first?" at a fleet-wide level. `-Severity` filters at the ARG side to `Critical`, `Warning`, or `All` (Informational entries are always excluded). `-UpdateRingTag` narrows the report to a specific wave. The function reuses the module's existing `Invoke-AzResourceGraphQuery` helper for paginated CLI shell-out and inherits the same skip-token / error-scrubbing behaviour as every other fleet-wide query in the module. The 24-hour health checks run on Azure Local clusters independently of update activity, which means clusters that are already "up to date" can still surface Critical or Warning issues that need triage - this function is the dedicated entry point for that workflow.

- **New "Fleet Health Status" pipeline samples** (`Automation-Pipeline-Examples/github-actions/fleet-health-status.yml` and `Automation-Pipeline-Examples/azure-devops/fleet-health-status.yml`). The GitHub Actions variant runs daily at 07:00 UTC (offset from `fleet-update-status` at 06:00) and the ADO variant uses the same schedule. Both pipelines call `Get-AzLocalFleetHealthFailures -View Detail` once, aggregate the summary in-process, and emit:
  - A markdown step summary (top failure reasons pivoted by cluster impact + a per-cluster "Detailed Results" table mirroring the data shown in the "24 Hour System Health Checks - Detailed Results" view).
  - JUnit XML (`fleet-health-status.xml`) with one `<testcase>` per (cluster, failing check) grouped under `Critical Health Failures` / `Warning Health Failures` testsuites for two-level drill-down in dorny/test-reporter (GitHub) and PublishTestResults@2 (Azure DevOps).
  - CSV exports (`fleet-health-detail.csv`, `fleet-health-summary.csv`) for spreadsheet workflows and ITSM hand-off.
  Together with `fleet-update-status.yml`, administrators now have two dedicated pipelines: one for "is each cluster up-to-date" (Update Status) and one for "do clusters have actionable health issues even when up-to-date" (Health Status).

- **New Pester guardrail: pipeline YAML version pin matches the module manifest.** A new `Context 'Pipeline YAML version pin (v0.7.65)'` test in `Tests/AzLocal.UpdateManagement.Tests.ps1` discovers every `*.yml` file under `Automation-Pipeline-Examples/` that installs `AzLocal.UpdateManagement` from PSGallery and asserts that the `GENERATED_AGAINST_MODULE_VERSION` constant in that YAML matches the manifest version. Supports both the inline GitHub Actions shape and the two-line Azure DevOps shape. This prevents the version-drift class of bug where the manifest is bumped but one or more sample YAMLs are forgotten.

- **`Automation-Pipeline-Examples/README.md` now documents the default triggers and schedules for all seven shipped pipelines.** A new "Default triggers and schedules (at a glance)" table at the top of Appendix A lists the GitHub Actions and Azure DevOps trigger / cron for every pipeline (`inventory-clusters`, `manage-updatering-tags`, `assess-update-readiness`, `apply-updates`, `fleet-update-status`, `fleet-health-status`, `apply-updates-schedule-audit`). Each of the per-pipeline appendix entries (A.1 - A.7) now also has a dedicated **Trigger** row. **A.6 (Fleet Health Status)** and **A.7 (Apply-Updates Schedule Coverage Audit)** are added in this release. **Apply Updates (A.4) and section 8 now include a mandatory-customisation callout**: the cluster `UpdateWindow` / `UpdateExclusions` tags only *gate* updates while the pipeline is already running; they do **not** start the pipeline. If `apply-updates.yml` is left with `workflow_dispatch` only (GH) / `trigger: none` (ADO) and you rely on `UpdateWindow` tags, no updates will ever be applied automatically. Section 8 includes worked GH / ADO cron examples for typical `UpdateWindow` values **and a new end-to-end runbook (section 8.3)** that walks operators through tag-a-ring -> see-drift -> copy-recommended-cron -> verify -> let-the-weekly-audit-catch-future-drift.

- **New function `Test-AzLocalApplyUpdatesScheduleCoverage`** - read-only schedule-coverage advisor. Compares the cron schedule(s) declared in `apply-updates.yml` (GitHub Actions and/or Azure DevOps) to the `UpdateWindow` tag values present on the fleet and flags every `(UpdateRing, UpdateWindow)` pair that no cron will ever reach. Three views: `-View Audit` (one row per `(Ring, Window)` pair with `Covered` / `Uncovered` / `PartiallyCovered` / `MalformedTag` / `UnparseableCron` status + `Recommendation` column), `-View Matrix` (every distinct `(Ring, Window)` pair with its required cron), `-View Recommend` (ready-to-paste GH Actions + Azure DevOps cron blocks that cover every distinct `UpdateWindow` value in the fleet). Per-segment cron generation handles multi-window tag values (`Sat-Sun_02:00-06:00;Mon-Fri_22:00-04:00`), day ranges including wrap-around (`Fri-Mon`), and a configurable `-LeadTimeMinutes` (default 5, range 0-60) buffer so the cron fires before the window opens. Cron parser supports the 5-field standard (`M H DoM Month DoW`), single values, comma lists, day ranges, and `*` wildcards; rejects `/N` step values and complex DoM/Month patterns (returns `IsComplex=true`). Pipeline YAML pre-scan uses a regex (no `powershell-yaml` dependency) and infers `Platform` from the `github-actions/` / `azure-devops/` parent folder. Never edits cluster tags or pipeline YAML. Read-only RBAC: `Reader` on the cluster scope plus `Microsoft.ResourceGraph/resources/read`.

- **New "Apply-Updates Schedule Coverage Audit" pipeline samples** (`Automation-Pipeline-Examples/github-actions/apply-updates-schedule-audit.yml` and `Automation-Pipeline-Examples/azure-devops/apply-updates-schedule-audit.yml`). Both pipelines are scheduled weekly on Mondays at 05:00 UTC (`cron '0 5 * * 1'`) - deliberately before the daily `fleet-update-status` (06:00 UTC) and `fleet-health-status` (07:00 UTC) pipelines so drift annotations land at the top of the Monday-morning operator queue. Each run produces:
  - **JUnit XML** (`schedule-coverage-audit.xml`) with one `<testcase>` per `(UpdateRing, UpdateWindow)` pair - uncovered / partially covered / malformed pairs become `<failure>` so the Tests tab surfaces the regression.
  - **CSV exports** (`schedule-coverage-audit.csv`, `schedule-coverage-matrix.csv`) for spreadsheet / dashboard workflows.
  - **Markdown** (`schedule-coverage-recommend.md`) - ready-to-paste GH Actions + Azure DevOps cron blocks covering every distinct `UpdateWindow` in the fleet.
  - **Markdown step summary** with the headline counts, the audit detail (uncovered first), and the recommended cron block.

### Fixed

- **`Set-AzLocalClusterUpdateRingTag` now uses the dedicated `Microsoft.Resources/tags/default` PATCH endpoint instead of `PATCH`-ing the cluster resource.** The previous code issued `PATCH https://management.azure.com/<clusterId>?api-version=2025-10-01` with `{ "tags": {...} }`, which Azure RBAC routes through the `microsoft.azurestackhci/clusters/write` action - i.e. full cluster Contributor. CI/CD service principals scoped to **Tag Contributor** (only `Microsoft.Resources/tags/*` actions) therefore failed with `AuthorizationFailed: action 'microsoft.azurestackhci/clusters/write'` even though they should have been able to write tags. The function now `PATCH`es `https://management.azure.com/<clusterId>/providers/Microsoft.Resources/tags/default?api-version=2021-04-01` with `{ "operation": "Merge", "properties": { "tags": { "UpdateRing": "..." } } }`, which Azure routes through `Microsoft.Resources/tags/write` only. The `Merge` operation preserves all other existing tags on the cluster without us having to re-send them. Aligns with the v0.7.62 fix that already moved internal tag writes (`Set-AzLocalClusterTagsMerge`) to the same endpoint.

- **"Fleet Update Status" pipeline summary now reconciles with the JUnit pass/fail counts.** Two related bugs in both `fleet-update-status.yml` samples (GitHub Actions and Azure DevOps) produced summary tables that did not add up to `Total Clusters`:
  1. `Up to Date` only counted `UpdateState -eq "UpToDate"` and missed clusters reporting the (equally healthy) `AppliedSuccessfully` state. Both states now count as "Up to Date".
  2. The bucket counters were not mutually exclusive and there was no catch-all, so a fleet of 12 healthy + 8 failed clusters could render as `Up to Date: 0`, `Health Failures: 8`, with the remaining 12 unaccounted for. Each cluster is now assigned to **exactly one** primary status using a priority cascade (`Update Failed` -> `Health Failure` -> `SBE Prerequisite Blocked` -> `Update In Progress` -> `Ready for Update` -> `Up to Date` -> `Needs Investigation`), so the rows always sum to `Total Clusters`.

### Changed

- **JUnit / step-summary ordering is now: Summary FIRST, Test Results SECOND.** Both `fleet-update-status.yml` and `fleet-health-status.yml` samples for GitHub Actions and Azure DevOps now create the markdown step summary before publishing the JUnit XML, so the run-extensions / job-summary view leads with the operator-facing numbers rather than the raw test list. The GitHub Actions dorny/test-reporter step now uses `list-suites: failed` + `list-tests: failed` so the published Test Reporter section is collapsed by default and only expands the failures.
- **Fleet Update Status failure message now reads "UpdateState: ..., Health: ..." (was "Health: ..., UpdateState: ...").** The Update Status is the primary signal for that pipeline, so it now leads in both the JUnit `<failure>` message and the markdown summary.
- **`Set-AzLocalClusterUpdateRingTag` help and the Automation-Pipeline-Examples RBAC guidance now both recommend the built-in `Tag Contributor` role for tag-management automation.** If you scoped your tag-management SP to "Contributor" purely to work around the old write-the-whole-cluster behaviour, you can now safely scope it to **Tag Contributor** on the cluster (or the resource group).

### Module-version pin bumped to 0.7.65 in all 13 sample workflow YAMLs (10 pre-existing + 3 new in v0.7.65)

Refresh your copy via:

```powershell
Copy-AzLocalPipelineExample -Destination <path> -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination <path> -Platform AzureDevOps -Update
```

## [0.7.64] - 2026-05-17

### Fixed (critical)

- **Pipeline-sample YAMLs (10 files across GitHub Actions and Azure DevOps) had accumulated cp1252 mojibake from previous emoji-edit round-trips.** One of the multi-byte sequences in `manage-updatering-tags.yml` contained a YAML 1.2 forbidden C1 control character (U+008F), which caused GitHub Actions to reject the workflow at recent commits with **`Invalid workflow file`** / generic YAML syntax error and the affected step never ran. The root cause was UTF-8 emoji bytes (e.g. `F0 9F 93 84` = `[document]`) being misread as cp1252 by a previous editor session, then re-saved as UTF-8 - producing `C3 B0 C2 9F C2 93 C2 84`, which contains `C2 8F` -> U+008F. YAML 1.2 disallows raw C1 control characters U+0080-U+009F (except U+0085 NEL) in scalar content. **All non-ASCII bytes have been stripped from every sample workflow** (`[^\x09\x0A\x0D\x20-\x7E]`), the affected Markdown step-summary sections restored with plain-ASCII status labels (`[info]`, `[ok]`, `[running]`, `[ready]`, `[blocked]`, `[fail]`), and the YAMLs verified to round-trip cleanly through the GitHub Actions and Azure DevOps validators. No module code paths are affected; only the sample YAMLs.

### Security hardening (Medium)

- **`Connect-AzLocalServicePrincipal` now scrubs `$loginResult` through `ConvertTo-ScrubbedCliOutput` before writing the failure message to `Write-Error`.** A stray `refresh_token` / `access_token` / cookie that the `az` CLI might emit on a failed `az login --service-principal` call can no longer reach the host logs verbatim.
- **Six additional direct callers of `az rest` / `az account set` now route raw CLI output through `ConvertTo-ScrubbedCliOutput` before logging/throwing.** Sites: `Set-AzLocalClusterTagsMerge` (3), `Invoke-AzLocalSideloadedAutoResetForCluster`, `Invoke-AzLocalUpdateApply`, `Set-AzLocalClusterUpdateRingTag`, `Start-AzLocalClusterUpdate` (subscription-set and validate). This closes the same Bearer-token leak class that was already handled inside `Invoke-AzRestJson` / `Invoke-AzResourceGraphQuery` but missed by the direct `az rest` call sites.
- **Documentation: `README.md` and [`ITSM/README.md`](ITSM/README.md) now carry explicit security notes about** (a) the `az login --service-principal --password <secret>` command-line exposure on the SP+secret authentication path (visible to `Win32_Process.CommandLine` for the duration of the call), and (b) the unavoidable plaintext `[string]` residency of ITSM secrets in memory during ServiceNow OAuth `client_credentials` grants (the ServiceNow REST surface requires plaintext POST bodies, so `[SecureString]` round-tripping is impossible at this layer).

### Fixed (Low)

- **`Invoke-AzLocalUpdateApply` previously evaluated `$result -match "202"` against the `string[]` returned by `az rest`**, which is array-filter semantics, not regex-match semantics: the test was returning the matching array elements (truthy) rather than the boolean intended. The comparison is now done against `($result | Out-String).Trim()` and combined into a single regex (`202|Accepted`); the `Write-Verbose` path is also scrubbed.
- **`Invoke-AzLocalItsmHttp` `throw` on non-retryable HTTP failure now uses `$redactedUri` instead of `$Uri`.** The redaction (`(client_secret|access_token|password)=[^&]+` -> `$1=***`) was already applied to the `Write-Verbose` log line; the `throw` message bypassed it. With this fix, a non-retryable 4xx response from ServiceNow can no longer surface a secret-bearing query string into the exception chain.
- **Two Pester tests (`ScheduleBlocked` and `SideloadedBlocked` JUnit XML coverage) wrote to fixed temp filenames** (`pester-junit-schedule-test.xml`, `pester-junit-sideloaded-test.xml`) that would collide if the test suite is run in parallel or back-to-back. Filenames now append a per-invocation `[Guid]::NewGuid()`.

### Module-version pin bumped to 0.7.64 in all 10 sample workflow YAMLs

Refresh your copy via:

```powershell
Copy-AzLocalPipelineExample -Destination <path> -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination <path> -Platform AzureDevOps -Update
```

## [0.7.63] - 2026-05-16

### Fixed (critical)

- **`fleet-update-status.yml` (both [GitHub Actions](Automation-Pipeline-Examples/github-actions/fleet-update-status.yml) and [Azure DevOps](Automation-Pipeline-Examples/azure-devops/fleet-update-status.yml) samples) failed on the *Create Status Summary* step under PowerShell 7** with `ParserError: The Unicode escape sequence is not valid. A valid sequence is \`u{ followed by one to six hex digits and a closing '}'`. GitHub-hosted Windows runners default to `pwsh` 7 for `shell:` in `run:` steps, so the YAMLs render on PS 7 even though the module itself targets PS 5.1+. Inside the PS double-quoted here-string that builds the Markdown step summary, Markdown code-span backticks before file names like `` `update-summaries.csv` `` and `` `update-runs.csv` `` were interpreted by the PS 7 parser as the new `` `u{xxxx} `` Unicode escape (added in PS 6.2, which expects `{` immediately after `` `u ``). PS 5.1 had silently consumed the backtick; PS 7 hard-errors. Latent corruption also affected `` `readiness-status.csv` `` (`` `r `` -> carriage return), `` `available-updates.csv` `` (`` `a `` -> BEL `0x07`), and `` `cluster-inventory.csv` `` (`` `c `` -> backtick dropped) - producing rendered job summaries with stray control characters and missing code-span formatting even on PS 5.1. All Markdown code-span backticks in the affected here-strings have been doubled (`` `` `` ); under both PS 5.1 and PS 7, two consecutive backticks in a double-quoted string is documented to produce exactly one literal backtick, and Markdown renders single and doubled-backtick code spans identically. The fix is portable across both shell versions and matches the pre-existing doubled-backtick pattern already in use on the same files (e.g. for `` `available-updates.csv` `` in the GH Actions readiness section). No module code paths are affected; only the pipeline-sample YAMLs.

### Pipeline migration

If you have copied `fleet-update-status.yml` into your repo, refresh both sample files via:

```powershell
Copy-AzLocalPipelineExample -Destination <path> -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination <path> -Platform AzureDevOps -Update
```

## [0.7.62] - 2026-05-15

### Fixed (critical)

- **`Start-AzLocalClusterUpdate` Step 3b critical-health gate was being silently bypassed.** The caller invoked [`Test-AzLocalClusterHealth`](Public/Test-AzLocalClusterHealth.ps1) without `-PassThru`; without that switch the function writes all output via `Write-Log` to the host stream and returns `$null`, so the predicate `$healthResults[0].CriticalCount -gt 0` always evaluated false even when the function had just logged `BLOCKED (N critical)`. Apply would then write *"No critical health issues found - cluster is eligible for update"* and proceed to PATCH the update despite critical health failures. Two additional call sites in [`Get-AzLocalUpdateRuns`](Public/Get-AzLocalUpdateRuns.ps1) (failed-run health detail and affected-cluster health detail) had the same omission. All three now pass `-PassThru`.
- **[`Set-AzLocalClusterTagsMerge`](Private/Set-AzLocalClusterTagsMerge.ps1) rewritten to use the ARM tags subresource** (`PATCH .../providers/Microsoft.Resources/tags/default?api-version=2021-04-01`) instead of patching the full cluster resource. This narrows the required RBAC from `microsoft.azurestackhci/clusters/write` to `Microsoft.Resources/tags/write` (the built-in **Tag Contributor** role), matching the documented behaviour. The function emits up to 2 PATCHes per call: one with `operation=Merge` for keys being set, one with `operation=Delete` for keys whose input value is `$null`. Idempotent: skips keys whose value already matches and Delete keys that are not present.
- **`Export-ResultsToJUnitXml` Status mapping fixed.** Status values `NotReady`, `NotConnected`, `NoUpdatesAvailable`, and `NoReadyUpdates` previously fell through to `<system-out>` (rendered as passed in `dorny/test-reporter`), producing misleading "all green" CI summaries when apply had actually skipped clusters. They now render as `<skipped>`. `UpdateNotFound` now renders as `<error type="UpdateNotFound">` instead of `<system-out>`. The summary `<testsuite tests/failures/errors/skipped/>` counts and the per-testcase element now agree.
- **[`Get-HealthCheckFailureSummary`](Private/Get-HealthCheckFailureSummary.ps1) now sorts `Critical`-severity entries ahead of `Warning` before applying the top-5 truncation.** This private helper feeds both the `HealthCheckFailures` column of the readiness CSV and the readiness gate's `-match '\[Critical\]'` check inside [`Get-AzLocalClusterUpdateReadiness`](Public/Get-AzLocalClusterUpdateReadiness.ps1) and [`Get-AzLocalFleetStatusData`](Public/Get-AzLocalFleetStatusData.ps1). Prior to this fix the function appended failures in the order ARM returned them and then truncated to the first 5; a cluster that returned 5 or more `Warning`-severity failures before a `Critical` one would have its `Critical` entry dropped during truncation, and the readiness gate would silently fail to downgrade `ReadyForUpdate`. The function now buckets by severity and concatenates `Critical`-first then `Warning`, preserving insertion order within each bucket. `Informational` entries continue to be excluded entirely (they never block updates - only `Critical` does, and `Warning` is included in the summary for operator visibility). Net effect: the readiness gate is reliable regardless of ARM's ordering, and the `HealthCheckFailures` column always shows the highest-priority entries first.

### Changed

- **`apply-updates` pipeline samples (GitHub Actions + Azure DevOps) now consume the readiness CSV** from the `check-readiness` job instead of re-discovering clusters by `UpdateRing` tag. The apply step downloads the `readiness-report` artifact, filters rows where `ReadyForUpdate=True`, and invokes `Start-AzLocalClusterUpdate -ClusterResourceIds @(...)` against that exact list. Apply still re-validates each cluster (Step 1b connectivity, Step 3b health, Step 3c schedule, Step 3b1 sideloaded) as defence in depth. This guarantees the readiness gate's decision is **enforced** rather than advisory: a cluster flagged Blocked in readiness will not be touched by apply even if its tag still matches the ring.
- **`Get-AzLocalClusterUpdateReadiness` output (and the readiness CSV) gains a `ClusterResourceId` column** containing the full ARM resource ID, so the apply step can pass it straight to `Start-AzLocalClusterUpdate -ClusterResourceIds` without a second Resource Graph query. Populated on every row, including `NotFound`/`Error` rows (set from the input cluster's `ResourceId` where known).

### Pipeline migration

If you have copied `apply-updates.yml` into your repo, refresh both sample files via:

```powershell
Copy-AzLocalPipelineExample -Destination <path> -Platform GitHub     -Update
Copy-AzLocalPipelineExample -Destination <path> -Platform AzureDevOps -Update
```

The pipeline install step's drift detector will also emit a `::notice`/warning log pointing at this once you bump `REQUIRED_MODULE_VERSION` to `0.7.62`.

## [0.7.61] - 2026-05-15

### Changed

- **Readiness assessment now applies two new gates that downgrade `ReadyForUpdate` to `False` even when Azure Resource Manager (ARM) reports a Ready update for the cluster.** Both [`Get-AzLocalClusterUpdateReadiness`](Public/Get-AzLocalClusterUpdateReadiness.ps1) and [`Get-AzLocalFleetStatusData`](Public/Get-AzLocalFleetStatusData.ps1) (used by `New-AzLocalFleetStatusHtmlReport`) now block readiness when either of these is true:
  - **Connectivity:** `ClusterState` is not `'ConnectedRecently'` (e.g. `NotConnectedRecently`, `Disconnected`). ARM cannot reliably push an update to a cluster it has not heard from recently.
  - **Critical health:** `HealthCheckFailures` contains at least one `[Critical]` severity entry. Critical-severity health checks must be cleared before any solution upgrade is started.

  A new **`BlockingReasons`** column on the readiness CSV lists the gate(s) that triggered the downgrade. Values are semicolon-joined - for example `CriticalHealthCheck` or `CriticalHealthCheck; NotConnectedRecently`. Clusters that pass both gates have an empty `BlockingReasons` value, exactly as in v0.7.60.

  The per-cluster console output now shows **`Blocked (<reasons>)`** in red for any cluster held back by these gates, and the summary footer now reports **`Blocked by Readiness Gate: N`** alongside the existing `Blocked by SBE Prereq` count.

- **`Start-AzLocalClusterUpdate` gains a defence-in-depth connectivity gate (`Step 1b`).** Immediately after cluster lookup, clusters whose `properties.status` is not `'ConnectedRecently'` are skipped before any update is attempted. The cluster is recorded in `Update_Skipped.csv` with the message *"Update not started - cluster status is '\<status\>' (ARM cannot reach the cluster)"*, and the in-process `$results` collection gets a `Status='NotConnected'` row. Complements the existing `Step 3b` critical-health gate.

### Fixed

- **JUnit XML export from `Get-AzLocalClusterUpdateReadiness` was emitting `Status='Skipped'` for every Ready cluster** due to a long-standing boolean-vs-string comparison bug at the JUnit transform step: `$_.ReadyForUpdate -eq 'Yes'` was tested against the `[bool]` value `$true`, which is always `$false`. JUnit `Status` now correctly reports `'Ready'`, `'Blocked'`, `'Failed'`, or `'Skipped'`. The CSV `ReadyForUpdate` column (a real `[bool]`) was unaffected; only the JUnit XML readability of CI/CD test summaries was wrong.

## [0.7.60] - 2026-05-15

### Changed

- **GitHub Actions sample workflows refreshed for Node 24.** All five workflow YAMLs under [`Automation-Pipeline-Examples/github-actions/`](Automation-Pipeline-Examples/github-actions) now pin Node 24-compatible major versions of the third-party actions they use. This removes the "Node.js 20 actions are deprecated" warning banner that started appearing on `workflow_dispatch` runs after the GitHub Actions runner began surfacing the upcoming September 16 2026 Node.js 20 hard-removal. No input/output surface changes for any of the bumped actions, so refreshed pipelines continue to work without any other edits:
  - `actions/checkout` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`@v4` -> `@v5` &nbsp;(Node 24 default since v5.0.0, released Aug 2025)
  - `actions/upload-artifact` &nbsp;`@v4` -> `@v6` &nbsp;(v6 = Node 24 default; v5 still defaulted to Node 20)
  - `azure/login` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`@v2` -> `@v3` &nbsp;(v3.0.0 = Node 24)
  - `dorny/test-reporter` &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;`@v1` -> `@v3` &nbsp;(v3 = Node 24)

  Already-deployed pipelines will continue working on the older majors until the Sept 16 2026 hard-removal date. Running `Copy-AzLocalPipelineExample -Update` after upgrading to v0.7.60 pulls the refreshed YAMLs into your existing `.github\workflows\` folder.

### Fixed

- **`apply-updates.yml` (GitHub Actions sample): `dorny/test-reporter` could not publish Check Run results on `workflow_dispatch` runs.** Both jobs (`check-readiness` and `apply-updates`) only granted `id-token: write` + `contents: read` in their `permissions:` block, missing the `checks: write` permission that `dorny/test-reporter@v3` (and earlier) needs to create the Check Run that publishes JUnit results. Symptom: the test-reporter step failed with `HttpError: Resource not accessible by integration` (HTTP 403) on every run triggered by `workflow_dispatch`, because `workflow_dispatch` contexts have no PR check-run context to write back to by default. The run itself was unaffected - the readiness assessment and any subsequent apply still completed - this only restored the Check Run summary surface so the JUnit XML actually shows up in the GitHub UI. Sibling workflows (`assess-update-readiness.yml`, `fleet-update-status.yml`) already declared `checks: write` from v0.7.50; only `apply-updates.yml` was missing the permission. Refresh via `Copy-AzLocalPipelineExample -Update -Platform GitHub` after upgrading.

## [0.7.50] - 2026-05-15

### Added

- **`Copy-AzLocalItsmSample` (new convenience function)**: copies the bundled ITSM connector sample (`azurelocal-itsm.yml` + `templates/incident-body.md`) out of the module install location into a user-chosen destination. Default `-Destination` is `.\.itsm` - the exact relative path that both `apply-updates.yml` workflows default `itsm_config_path` / `itsmConfigPath` to (resolved relative to the repo root at job runtime). Same overwrite semantics as `Copy-AzLocalPipelineExample`: refuses to overwrite by default, `-Update` opts into per-file `ShouldContinue` prompts (`Y` / `A` / `N` / `L` / `S` / `?`) with `Yes-to-All` / `No-to-All` flags that survive across iterations, `-Confirm:$false` bypasses the prompts for unattended use, `-WhatIf` overrides everything and only prints what would change, `-PassThru` returns the destination `[DirectoryInfo]`. Closes the gap where running `Copy-AzLocalPipelineExample -Platform GitHub` (or `-Platform AzureDevOps`) deliberately did not bring the `.itsm/` sample along - the two functions now compose for a one-paragraph setup: pipelines into `.github\workflows\` (or your `pipelines/` folder), ITSM sample into `.itsm\`. The ITSM YAML itself is CI-platform-agnostic; both GitHub Actions and Azure DevOps consume it identically, only the secret source differs (repo / environment secrets vs. variable group).

### Changed

- **`Copy-AzLocalPipelineExample` - simpler, safer copy semantics.** First real-world run of the v0.7.4 surface revealed two issues with the GitHub Actions path: (1) `-Platform GitHub -Flatten` left an intermediate `github-actions\` subfolder, so workflows landed at `.github\workflows\github-actions\*.yml` where the GitHub Actions runner cannot see them (the runner only scans `.github/workflows/*.yml`, non-recursively); (2) the `-Force` flag's directory-level pre-flight refused to copy whenever `.github\workflows\` contained any unrelated user workflow, effectively making `-Force` mandatory and meaningless. Both flags have been removed and the function reshaped around the user's actual intent:
  - `-Platform GitHub` now copies ONLY the `*.yml` workflow files from the source `github-actions/` folder directly into `-Destination` (flat - no wrapper folder, no README, no `.itsm/`). The canonical call is `Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub`.
  - `-Platform AzureDevOps` behaves the same way against the source `azure-devops/` folder (flat into `-Destination`, no README, no `.itsm/`).
  - `-Platform All` (the default) is unchanged - copies the full source tree under a `.\Automation-Pipeline-Examples\` child folder for browsing.
  - **Controlled refresh via `-Update`** (new in v0.7.50): the function still refuses to overwrite by default and lists every conflict in the error message - but the error now points at the `-Update` switch instead of asking the user to `Remove-Item` first. With `-Update` the function emits a per-file `ShouldContinue` prompt (`Y` / `A` / `N` / `L` / `S` / `?`) before each overwrite; `Yes-to-All` and `No-to-All` survive across iterations. Pair with `-Confirm:$false` to suppress the prompts entirely (the documented automation / CI bypass). `-WhatIf` overrides everything and only prints what would change. Pipeline files are expected to live under git source control so `git diff` is the second safety net after `ShouldContinue`. There is **deliberately no `-Force`**: that flag's previous semantics were too broad and it had been removed mid-v0.7.50 development - `-Update` is the narrower, more explicit replacement.
  - Pre-existing unrelated files in `-Destination` (e.g. your repo's own `build.yml`, `codeql.yml`) are now left untouched; the function only writes the files it is bringing over from the source tree.
  - **Next-steps output** is now platform-aware and detects when `-Destination` is already `.github\workflows\` ("you're done, commit and push") vs. somewhere else ("move the YAMLs into `.github\workflows\`"). For both platform-specific values the output now points at `auth-smoke-test.yml` as the recommended first run (see sections 5.1 and 5.2 of the Automation-Pipeline-Examples README) so the user validates the auth chain before wiring the other five workflows.

  Note: this is **not** marked as a breaking change because the v0.7.4 surface had not been adopted by any consumer at the time of removal (the feature shipped on 2026-05-13 and was found broken on first real-world use).

## [0.7.41] - 2026-05-13

### Fixed

- **HIGH**: every fleet read function dispatched through `Invoke-FleetJobsInParallel` (`Get-AzLocalUpdateRuns`, `Get-AzLocalUpdateSummary`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalFleetProgress`, `Invoke-AzLocalFleetOperation`, `Test-AzLocalClusterHealth`, `Start-AzLocalClusterUpdate`'s parallel path) failed for every cluster when invoked with `-ThrottleLimit` greater than 1 against the PSGallery-installed module, returning `State = Error` with the message: *"Cannot use '&' to invoke in the context of module 'Invoke-FleetJobsInParallel' because it is not imported. Import the module 'Invoke-FleetJobsInParallel' and try the operation again."* Inline (`-ThrottleLimit 1`) execution was unaffected. Root cause: the v0.7.3 refactor that split the monolithic `.psm1` into `NestedModules` changed the meaning of `$PSCommandPath` inside `Invoke-FleetJobsInParallel.ps1`. It now resolves to the helper's own `.ps1` file (because it is loaded as a nested module), not to the root `AzLocal.UpdateManagement.psd1`. The helper was passing that nested-helper path to each per-batch `Start-Job` scriptblock as `$ModulePath`; the scriptblocks then ran `Import-Module $ModulePath -Force -PassThru` in the fresh child runspace, which loaded only the single `.ps1` file as a transient module named `Invoke-FleetJobsInParallel`. Every subsequent `& $mod { Get-AzLocalClusterUpdateRuns ... }` resolved against that transient module's session state, which contained none of the private helpers. Reported against a 9-cluster Prod fleet immediately after installing v0.7.4 from PSGallery; reproduces 100% on `-ThrottleLimit 10` and on the default `-ThrottleLimit 4` once the cluster count exceeds the throttle.
- **HIGH**: `New-AzLocalFleetStatusHtmlReport -ThrottleLimit` greater than 1 (which routes through `Get-AzLocalFleetStatusData`) threw at start-up: *"Parallel collection requires module path 'C:\Program Files\WindowsPowerShell\Modules\AzLocal.UpdateManagement\\<ver\>\Public\AzLocal.UpdateManagement.psm1' to be reachable by background jobs, but it does not exist."* Same regression class as the `Invoke-FleetJobsInParallel` bug but a separate code path: `Get-AzLocalFleetStatusData` computes the module path itself for its inline `Start-Job` dispatcher and was using `Join-Path -Path $PSScriptRoot -ChildPath 'AzLocal.UpdateManagement.psm1'`. After v0.7.3, `$PSScriptRoot` resolves to the `Public/` subfolder, not the module root, so the computed path was one level too deep on PSGallery-installed layouts. `New-AzLocalFleetStatusHtmlReport`'s manifest-fallback footer had the same flaw.
- **Centralised** module-root manifest resolution in a new private helper [`Private/Get-AzLocalModuleRootManifestPath.ps1`](AzLocal.UpdateManagement/Private/Get-AzLocalModuleRootManifestPath.ps1) so we have ONE place that knows the post-v0.7.3 layout. The helper prefers the loaded module's `.Path` (preferring `.psd1` over `.psm1`) and falls back to walking up from the caller's `$PSCommandPath`, so it is correct from any `Public/` or `Private/` file. `Invoke-FleetJobsInParallel`, `Get-AzLocalFleetStatusData`, and `New-AzLocalFleetStatusHtmlReport` all delegate to it. Future `Public/`/`Private/` additions won't reintroduce the same "`$PSScriptRoot` is module root" assumption.
- Added a Pester regression test (`Should pass the root module manifest path (not the helper .ps1) as the trailing ModulePath argument`) under `Internal Helper: Invoke-FleetJobsInParallel`. Existing tests only exercised the inline `-ThrottleLimit 1` fast-path, which never touched the broken Start-Job code path and so silently masked the regression in v0.7.4.

## [0.7.4] - 2026-05-13

### Added

- **ITSM Connector - Phase 1 (ServiceNow).** New optional ticketing surface that lets `apply-updates` and `fleet-update-status` pipelines open ServiceNow incidents when a cluster needs operator action that the module's own retries cannot resolve. Disabled by default; opt-in via the pipeline input `raise_itsm_ticket=true` plus a `./.itsm/azurelocal-itsm.yml` config file. Setup walkthrough in `ITSM/README.md`; full design captured in `ITSM/ITSM-Connector-Plan.md`.
- **New public functions** (Phase 1):
  - `Get-AzLocalItsmConfig` - loads and validates the YAML/JSON trigger matrix; returns a strongly typed config object so pipelines can fail-fast on misconfiguration before any HTTP call.
  - `Test-AzLocalItsmConnection` - dry-run probe of the configured ITSM endpoint and any enabled notification adapters; verifies auth, custom-field presence, and rate-limit headroom.
  - `New-AzLocalIncident` - consumes a JUnit results file (and optional readiness CSV), evaluates each cluster row against the trigger matrix, opens or de-duplicates ServiceNow incidents via SHA256 of `{ClusterResourceId}|{UpdateName}|{TriggerCategory}`, and returns one row per cluster considered with `Action`, `TicketId`, `TicketUrl`, `Severity`.
- **New internal helpers**: `Resolve-AzLocalItsmSecret` (Key Vault first, `env://` fallback), `Get-AzLocalItsmDedupeKey`, `Get-AzLocalItsmTriggerDecision`, `Format-AzLocalIncidentBody` (Mustache-style template rendering with HTML-escape), `Invoke-AzLocalItsmHttp` (TLS 1.2+, `Retry-After` honour, exponential backoff capped at 3 attempts), `Invoke-AzLocalServiceNowAdapter` (OAuth 2.0 client credentials, token cache, dedupe GET, POST incident, attach file).
- **New documentation**: top-level `ITSM/` folder with a setup-and-configure `README.md` landing page (Key Vault prep, ServiceNow OAuth app, custom fields, secret references, dry-run, troubleshooting), `ITSM/ITSM-Config-Reference.md` (full schema reference with every field documented), and `Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml` working example config plus `templates/incident-body.md` ticket-body template.
- Phase 2 (`Sync-AzLocalIncident` lifecycle close-out) and Phase 3 (Teams / Slack mirror adapters) are **deferred to a future release**; the Phase 1 surface is feature-complete on its own and ships ServiceNow-only as planned. The full three-phase design remains documented in `ITSM/ITSM-Connector-Plan.md` for forward reference.
- **`Copy-AzLocalPipelineExample` (convenience function)**: copies the bundled `Automation-Pipeline-Examples/` folder out of the module install location into a user-chosen destination (default: `$PWD`). Supports `-Platform GitHub | AzureDevOps | All`, `-Flatten` (drop contents into the destination directly, no parent folder), `-Force` (overwrite existing files), `-PassThru` (return the destination `[DirectoryInfo]`), `-WhatIf` and `-Confirm`. Always prints a short "next steps" summary pointing at the copied README and the platform-specific YAML location. Saves users from hunting through `$module.ModuleBase` for the YAML samples after `Install-Module`.

### Security

- All ITSM credentials referenced through Azure Key Vault (`kv://<vault>/<secret>`, recommended) or native CI secrets (`env://<NAME>`, fallback). No raw secret is ever written to YAML or to disk. Pipeline service principal needs `Key Vault Secrets User` on the configured vault; no other new RBAC.
- All free-text fields (cluster names, tag values, error summaries) are HTML-escaped when rendered into ticket descriptions to defend against ITSM-side HTML injection. CSV-injection sanitisation on inputs is unchanged (already present from v0.7.0).

## [0.7.3] - 2026-05-13

### Renamed

- **Module renamed from `AzStackHci.ManageUpdates` to `AzLocal.UpdateManagement`** to align with the Azure Local product name (Microsoft retired the `Azure Stack HCI` brand in late 2024). The module **GUID is preserved** across the rename so PowerShell tooling still sees this as the same module identity.
  - **Migration command for existing users**:
    ```powershell
    Uninstall-Module AzStackHci.ManageUpdates -AllVersions
    Install-Module AzLocal.UpdateManagement
    ```
  - **PSGallery**: all `AzStackHci.ManageUpdates` versions (≤ 0.7.2) have been **unlisted**. A transitional `AzStackHci.ManageUpdates` v0.7.3 stub is published once for users who have automation that runs `Install-Module AzStackHci.ManageUpdates`; importing it emits a `Write-Warning` pointing to the new name and exports no functions.
  - **Default log folder**: `C:\ProgramData\AzStackHci.ManageUpdates\` -> `C:\ProgramData\AzLocal.UpdateManagement\`. The old folder is not migrated; remove it manually after upgrading if desired.
  - **Repository folder**: `AzStackHci.ManageUpdates/` -> `AzLocal.UpdateManagement/`. Pipeline YAML examples (`apply-updates.yml`, `assess-update-readiness.yml`, `fleet-update-status.yml`, `inventory-clusters.yml`, `manage-updatering-tags.yml`) and all `Import-Module` paths updated.
  - **Tests / `InModuleScope`**: every `InModuleScope AzStackHci.ManageUpdates { ... }` and `Get-Module AzStackHci.ManageUpdates` reference updated to the new name.
  - **`u_azlocal_source` ITSM custom field default**: changed from `AzStackHci.ManageUpdates` to `AzLocal.UpdateManagement` in the ITSM Connector design doc (no runtime effect yet; ITSM connector lands in v0.7.4).

### Refactored (carried forward from the in-development branch, included here)

- The monolithic 11,679-line `.psm1` is split into Public/Private dot-sourced files, matching the layout of `AzLocal.DeploymentAutomation` in this repo. 20 exported functions live under `Public/`, 40 internal helpers under `Private/`. The manifest enumerates every file in `NestedModules` (Private first, then Public, alphabetical within each). No functional change; the full Pester suite (299 tests) remains green.
- 22 inter-function `$script:*` declarations that were declared between function definitions in the monolithic file (`UpdateWindowTagName`, `UpdateExclusionsTagName`, `UpdateSideloadedTagName`, `UpdateVersionInProgressTagName`, `DayMap`, `DayAbbreviations`, `FleetOperationState`) are now hoisted into the `.psm1` prologue with a banner comment. They must initialise before any function body that references them; this is enforced by the manifest's `NestedModules` load order.
- `Tools/Split-AzStackHciModule.ps1` is retained verbatim as a historical audit artefact of the refactor. The script is not runnable against the renamed layout and is kept only for reference.

## [0.7.2] - 2026-05-05

### Fixed

- **`Get-AzLocalUpdateRuns` / `Get-AzLocalUpdateSummary` / `Get-AzLocalClusterUpdateReadiness` failed for every cluster when run with `-ThrottleLimit` greater than 1.** The per-cluster scriptblock dispatched via `Start-Job` called module-private helpers (`Invoke-AzRestJson`, `Get-AzLocalClusterUpdateRuns`, `Format-AzLocalUpdateRun`, `Get-LatestUpdateByYYMM`, `ConvertTo-AzLocalAdditionalProperties`, `Get-HealthCheckFailureSummary`, `Get-TagValue`) by name. Because those helpers are filtered out by `Export-ModuleMember`, after `Import-Module` in the child runspace they were not visible at script command-resolution scope, so every cluster reported `The term 'Get-AzLocalClusterUpdateRuns' is not recognized...` (or the equivalent for the other helpers). Inline (`-ThrottleLimit 1`) execution was unaffected because that path runs inside the parent module's session state. Fix: each affected scriptblock now captures a reference to the loaded module (using `Import-Module -PassThru` when not already loaded) and either invokes the helper via `& $module { ... }` or rebinds the helper's bound scriptblock into the local function scope, so calls execute against the module's own session state and resolve all transitive private references. Reported against a 9-cluster Prod fleet.
- **cp1252 encoding warnings leaking into JSON parsing on inline (`-ThrottleLimit 1`) path.** On Windows hosts where the console code page is `cp1252` (the English-US default), `az rest` and `az graph query` emitted `WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded.` whenever ARM responses contained non-cp1252 characters (smart quotes, accented cluster tags, localised health-check messages, etc.). Captured via `2>&1`, that warning was being prepended to the JSON body and breaking `ConvertFrom-Json`, silently dropping update runs and available updates for affected clusters. `Invoke-AzRestJson` set `$env:PYTHONIOENCODING = 'utf-8'` transiently per-call (v0.7.0+), but this is structurally ineffective: `az.cmd` launches Python with the `-I` (isolated) flag, which implies `-E` and so causes Python to ignore all `PYTHON*` environment variables - confirmed in [Azure/azure-cli#28497](https://github.com/Azure/azure-cli/issues/28497). The actual fix is to pass `--only-show-errors` to every `az rest` and `az graph query` invocation (Azure CLI maintainer's recommended workaround per [Azure/azure-cli#14426](https://github.com/Azure/azure-cli/issues/14426)); this suppresses the encode warning at source. Applied to: `Invoke-AzRestJson`, `Invoke-AzResourceGraphQuery`, the resource-validation `az rest GET` call in cluster-resolution, the apply `az rest POST` call in `Start-AzLocalClusterUpdate`, and all four direct `az rest` calls in `Set-AzLocalClusterTagsMerge` / sideloaded-tag reset paths. The module-load `PYTHONIOENCODING` assignment is retained as harmless defence-in-depth for environments that have manually patched `az.cmd` to remove `-I`.

## [0.7.1] - 2026-05-04

### Added
- **Sideloaded payload workflow.** Two cluster tags now coordinate human-driven sideloaded update payloads with the module:
  - **`UpdateSideloaded`** (operator-set, accepts `True`/`False`/`1`/`0`, case-insensitive). When `False`/`0`, `Start-AzLocalClusterUpdate` skips the cluster with `Status = "SideloadedBlocked"` (CSV/JUnit/HTML reports surface this as a new skipped reason). Empty/missing tag means "no sideloaded gate" and updates proceed normally. Malformed values throw - use `-Force` to bypass at your own risk.
  - **`UpdateVersionInProgress`** (module-set, **never** set by operators). Written automatically when an update kicks off, holds the update name (e.g. `Solution12.2604.1003.209`).
- **New public function `Reset-AzLocalSideloadedTag`** with parameter sets `ByName` / `ByResourceId` / `ByTag`. Explicit scope is required (no implicit `-AllClusters`). Default behaviour reads the latest run for each cluster, and only resets `UpdateSideloaded` -> `False` and clears `UpdateVersionInProgress` when the latest run is `Succeeded` **and** its update name matches `UpdateVersionInProgress`. Use `-Force` to bypass the match check (escape hatch for stuck tags).
- **Auto-reset in `Get-AzLocalUpdateRuns`** (default ON; opt out with `-SkipSideloadedReset`). After fetching runs, the latest run per cluster is inspected; if `Succeeded` and the update name matches `UpdateVersionInProgress`, both tags are flipped to `False` / cleared in a single PATCH. Failures are logged as `Warning` and never abort the read path.
- New status enum value `SideloadedBlocked` in CSV log, JUnit XML, and HTML report skipped tallies.
- New `UpdateSideloaded` and `UpdateVersionInProgress` columns on `Get-AzLocalClusterInventory` CSV/JSON exports (appended after `UpdateExclusions`, before `ResourceId`).
- No new RBAC permissions required - the existing `Microsoft.Resources/tags/read` and `/write` rights already documented for the v0.6.5 schedule-tag workflow are sufficient.

### Changed
- `Set-AzLocalClusterTagsMerge` is now idempotent: when the requested tag merge produces no actual change against the cluster's current tags, the PATCH is skipped entirely. Avoids redundant ARM writes from overlapping fleet-pipeline runs and from auto-reset against already-clean clusters.
- `Invoke-AzLocalSideloadedAutoResetForCluster` now distinguishes `Action = NoRuns` (cluster has no update history) from `RunNotSucceeded` (latest run is InProgress / Failed). Operators can tell "never updated" apart from "current run still running" in the auto-reset summary.
- `Invoke-AzLocalSideloadedAutoResetForCluster` now also surfaces `Action = OrphanCleared`. If a cluster has no `UpdateSideloaded` tag (opted out of the workflow) but a leftover `UpdateVersionInProgress` tag exists from an earlier in-module update, **and** the latest run is `Succeeded` and its name matches that tag, the orphan tag is cleared on a best-effort basis. `UpdateSideloaded` is **never** written in this path - the cluster has explicitly opted out, we only clean up our own breadcrumb.
- The sideloaded gate in `Start-AzLocalClusterUpdate` and the auto-reset path now both read tags via the shape-agnostic `Get-TagValue` helper (handles both `[PSCustomObject]` and `[IDictionary]` tag containers consistently).

### CI/CD pipeline examples (v0.7.1)
- `apply-updates.yml` (Azure DevOps + GitHub Actions): summary now reports `SideloadedBlocked` count, and the "Actions Required" section calls out the operator step (stage payload, flip tag) when any cluster is sideloaded-blocked.
- `inventory-clusters.yml` (Azure DevOps + GitHub Actions): file header documents the new `UpdateSideloaded` / `UpdateVersionInProgress` columns and which is operator-set vs module-managed.

### Enterprise-readiness review fixes (v0.7.1)
- **Security**: `Write-UpdateCsvLog` (the diagnostic CSV path used during apply runs) now sanitises every field through `ConvertTo-SafeCsvField` before quote-escaping. Aligns the interim `Update_Skipped.csv` / `Update_Started.csv` log path with the OWASP CSV-injection protection already applied to the final exported results path. Hostile cluster names / ARM error messages starting with `=`, `+`, `-`, `@`, or containing CR/LF can no longer trigger formula evaluation when an operator opens these logs in Excel.
- **Operational**: parallel `Get-AzLocalFleetStatusData` job dispatch now treats `Stopped` and `Disconnected` job states as failures alongside `Failed`. Previously these terminal states fell through into `Receive-Job` and were misdiagnosed as "no output" rather than "job crashed", obscuring root cause for `Stop-Job` / `Ctrl-C` and remoting-disconnect scenarios.
- **Performance**: `Get-AzLocalUpdateSummary`, `Get-AzLocalClusterUpdateReadiness`, `Start-AzLocalClusterUpdate`, `Get-AzLocalUpdateRuns`, and the private `Get-AzLocalClusterUpdateRuns` helper now accumulate per-cluster results in a `[System.Collections.Generic.List[object]]` (O(1) amortised `.Add()`) instead of an `Object[]` with `+=` (O(n) per append, O(n^2) total). Inner accumulators (`$results`, `$formattedRuns`, `$allFormattedRuns`, `$allRuns`) all converted. Measurable speed-up at fleet scale (1000+ clusters) for both the post-shard merge step and the per-cluster apply loop in `Start-AzLocalClusterUpdate`; no API surface change - the functions still return arrays.

### Added (EndTime feature)
- New `EndTime` column on `Get-AzLocalUpdateRuns` table output. For each per-attempt row, EndTime is sourced from `properties.progress.endTimeUtc` (the most accurate "work finished" timestamp), falling back to `properties.lastUpdatedTime` for older runs that pre-date the `progress.endTimeUtc` field. Blank for `InProgress` runs.
- New `End Time` column in the HTML fleet report's `Recent Update Run History` section. For the aggregated multi-attempt row, EndTime reflects the **latest attempt's** end time (StartTime continues to reflect the earliest attempt's start, so the row still reads "first started X, finally ended Y, total active duration Z").
- JUnit XML test bodies (success `<system-out>` and `<failure>`) now include `Start Time:` and `End Time:` lines for each cluster testcase. The JUnit `time=` attribute is unchanged - still numeric seconds, as required by CI tooling.
- New private helper `Get-AzLocalRunEndTime` centralises the EndTime resolution rule (priority: `progress.endTimeUtc` -> `lastUpdatedTime` -> `$null`) so the per-run formatter and the fleet aggregator never drift.

### Changed
- `Format-AzLocalUpdateRun` now prefers `properties.duration` (ARM-reported ISO-8601 timespan, e.g. `PT8H37M58S`) for per-run duration when present, falling back to `EndTime - StartTime`. Authoritative and immune to clock skew.

## [0.7.0] - 2026-04-24

The jump from `0.6.5` to `0.7.0` reflects the scope of this release: correctness fixes for large fleets (1500+ clusters), a shift to true parallel execution across all per-cluster read/write paths, HTML report performance improvements, and a round of bug and security hardening driven by a deep review of the module. No breaking public-surface changes; all new helpers are private. Az CLI is retained as the ARM transport; a native `Invoke-RestMethod` port is deliberately deferred to a future major release.

### Fixed (Phase 1 - Critical correctness at scale)
- **HIGH**: Azure Resource Graph queries used by `Get-AzLocalClusterInventory` (and sibling functions that scope clusters by `-AllClusters` or `-ScopeByUpdateRingTag`) were hardcoded to `az graph query --first 1000`. At 1500 clusters, 500 clusters were silently dropped from the result set - no error, no warning. Introduced a private `Invoke-AzResourceGraphQuery` helper that loops on the ARG continuation `$skipToken` until exhausted, emitting a verbose line per page and an `Info` log whenever the total exceeds 1000.
- **HIGH**: `Invoke-AzLocalFleetOperation -ThrottleLimit` previously only affected retry-backoff math; the per-cluster loop was fully sequential. At 1500 clusters that meant 4+ hour runs and CI/CD pipeline timeouts. Extracted the parallel `Start-Job` batch pattern already proven in `Get-AzLocalFleetStatusData` into a shared private helper `Invoke-FleetJobsInParallel` and rerouted `Invoke-AzLocalFleetOperation`, `Get-AzLocalFleetProgress`, and `Test-AzLocalFleetHealthGate -WaitForCompletion` through it. `-ThrottleLimit` now controls concurrent API calls (default 4, range 1-16). PowerShell 5.1 compatibility preserved - `ForEach-Object -Parallel` is deliberately not used.

### Changed (Phase 2 - Performance)
- Per-cluster read and write functions now run in parallel batches via the shared helper: `Get-AzLocalClusterUpdateReadiness`, `Test-AzLocalClusterHealth`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Set-AzLocalClusterUpdateRingTag`. Expected 5-10x speedup for 1500-cluster runs (e.g. readiness check from 10 min to 1-2 min).
- `New-AzLocalFleetStatusHtmlReport` renderer rewritten for O(n) scaling:
  - Pre-indexed `$latestRuns` and `$clusterDetails` hashtables replace two `Where-Object` filters inside the main cluster-row loop (was O(n^2): 2.25M scalar compares at 1500 clusters).
  - HTML encoding moved to collection time in `Get-AzLocalFleetStatusData`, eliminating ~20,000 `HttpUtility::HtmlEncode` calls at render time.
  - Per-cluster Azure portal URLs precomputed once and reused across the status table and update-run table.
  - Roughly 60% faster HTML render at 1500 clusters.
- HTML report output now written with UTF-8 **without BOM** via `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`. Was previously writing with BOM via `Out-File -Encoding UTF8` on Windows PowerShell 5.1.
- New opt-in pass-through parameters on state-changing functions (`-UpdateSummary`, `-AvailableUpdates`) so pre-fetched data can be reused across a pipeline, avoiding redundant ARM reads.

### Fixed (Phase 3 - Bugs and strict-mode hardening)
- All remaining `| ConvertFrom-Json` call sites outside `Invoke-AzRestJson` were audited and either rerouted through the helper or explicitly null-guarded. Previously, any ARM response that was not valid JSON (e.g. HTTP 204, error HTML, stray `az` CLI warning text on stdout) would throw uncaught under strict mode.
- Empty-pipeline guards added to the health failures and latest-run aggregation paths to prevent silent `$null` results.
- Update-name sort is now deterministic: secondary sort key on `$_.name` with a `Warning` logged whenever an update has an unparseable YYMM component, instead of silently grouping all unparseables at position 0.
- Parallel CSV log writes: each `Start-Job` worker now writes to a per-job CSV; the coordinator merges fragments at the end of the run. Eliminates line interleaving and header corruption that `Add-Content` cannot protect against.
- Tag property access is now robust to both `Hashtable` and `PSCustomObject` tag shapes returned by different ARM endpoints, replacing the fragile dynamic-property lookup `$tags.$TagName`.
- `UpdateWindow` and `UpdateExclusions` tag values that fail to parse are now treated as blocking (update skipped with an `Error`-level log) unless `-Force` is specified. Was previously logged as a warning and the update proceeded.

### Security (Phase 4)
- `-UpdateRingValue` is whitelist-validated against `^[a-zA-Z0-9._-]+$` before KQL interpolation in Azure Resource Graph queries. The prior `-replace "'", "''"` escaping was fragile against KQL regex semantics.
- New private helper `ConvertTo-SafeCsvField` prefixes formula-leader characters (`=`, `+`, `-`, `@`, tab) with a single quote and strips embedded CR/LF. Applied uniformly to every field written by the CSV loggers. Prevents formula injection when a CSV (e.g. containing an attacker-controlled cluster name or error message) is opened in Excel.
- User-supplied output paths (`-OutputPath`, `-ExportResultsPath`, `-LogFolderPath`, `-StateFilePath`) are now resolved to absolute form via `[IO.Path]::GetFullPath()`, length-capped at 248 chars, and rejected if they contain `..\` traversal sequences when a relative root was expected.
- Az CLI error output is scrubbed before being written to error logs: any accidental `--password <value>` or `--secret <value>` echo is masked, as are token-shaped substrings (36-char patterns, `accessToken:` prefixes).
- `Invoke-AzRestJson` now handles mid-run token expiry: on HTTP 401 it runs `az account get-access-token` once, refreshes, and retries the original request. Logs an `Info` when a refresh happens. Previously, long fleet operations crossing the 1-hour token boundary would fail partway through.
- `Stop-AzLocalFleetUpdate` now supports `ShouldProcess`: `-WhatIf` and `-Confirm` are honored before the operation is marked for stop and before any state file is written. `ConfirmImpact = Medium`.
- `New-AzLocalFleetStatusHtmlReport` now supports `ShouldProcess`: `-WhatIf` and `-Confirm` are honored before the HTML report is written to disk. Under `-WhatIf`, the composed HTML string is still returned to the pipeline so it can be inspected or piped to email/log without touching the filesystem. `ConfirmImpact = Low`.

### Changed (Phase 5 - UX & schema refinements)
- **Maintenance window tag separator changed from `:` to `_`** between the day-spec and the time range (e.g. `Mon-Fri_22:00-02:00` replaces `Mon-Fri:22:00-02:00`). Makes the tag readable at a glance without ambiguity against the `HH:MM` components. Multi-window `;` and day-range `-` are unchanged. Breaking for pre-release consumers only; `ConvertFrom-AzLocalUpdateWindow` now throws on the old format and, combined with fail-closed schedule evaluation, any cluster still on the old tag value has its updates blocked until re-tagged.
- **Schedule tag evaluation is now genuinely fail-closed.** `Test-AzLocalUpdateScheduleAllowed` previously swallowed parser errors and returned `Allowed=$true`, which defeated the "block on malformed tag" intent added earlier in this release. Parser errors now re-throw so the caller (`Start-AzLocalClusterUpdate`) reaches its existing `try/catch` that blocks the update unless `-Force` is specified.
- **Fleet HTML report "Recent Update Run History"** now shows **one row per cluster** (the most-recently-started update) and aggregates attempts within that update:
  - `Duration` uses fixed-width `HH:MM:SS` format (survives multi-day and summed totals), replacing the fractional `N.N hours`.
  - New **Update Attempts** column (shown only when at least one cluster has >1 attempt) gives the retry count.
  - `StartTime` reflects the earliest attempt; `State`, `Progress`, `Current Step` reflect the latest attempt. Re-runs after failure no longer hide earlier time spent.
- **Fleet HTML report "Cluster Information"** now includes a **Current SBE Version** column. Extracted from `additionalProperties.SBEVersion` on the most recent applied SBE update. Propagated through `Get-AzLocalFleetStatusData` and both GitHub Actions and Azure DevOps fleet-status pipeline YAMLs.
- **`Start-AzLocalClusterUpdate -WhatIf`** output is no longer polluted by internal `Write-Log` / `Write-UpdateCsvLog` / `Env:` cleanup / log-folder creation side effects. Previously each internal housekeeping line produced a `What if:` row. Now only the ARM `POST apply/action` call appears in the `-WhatIf` preview.
- **`Start-AzLocalClusterUpdate` final summary** now distinguishes **WouldUpdate** (dry-run or `ShouldProcess`-declined) from `Started` / `Skipped` / `Failed`, making fleet-scale `-WhatIf` runs auditable.

### Added (Phase 5)
- Private helper `Format-AzLocalDurationHuman` — central duration renderer; accepts `[TimeSpan]`, numeric seconds, or `HH:MM:SS` string and emits `"1 hour 23 minutes"` style. Used by `Get-AzLocalUpdateRuns` per-run output. The fleet HTML report uses its own `HH:MM:SS` formatter because it sums across attempts.

### Notes
- No breaking changes to exported functions or parameter sets. All new helpers are private.
- Pester test suite target: >= 239 passing (the 0.6.5 baseline), plus new coverage for ARG pagination, parallel speedup ratios, CSV sanitization, and path validation.
- Az CLI is retained as the ARM transport for v0.7.0. A native `Invoke-RestMethod` port (with its own token cache, MSAL/device-flow handling, and proxy/TLS surface) is deferred to a future major release where it can get dedicated test coverage.
- Deliberate version jump: the volume of fixes and the behavior change from "sequential, silently truncated" to "parallel, paginated" warrants a minor-version bump rather than a patch.

## [0.6.5] - 2026-04-23

### Fixed
- **HIGH**: `Set-AzLocalClusterUpdateRingTag` silently ignored the `UpdateWindow` and `UpdateExclusions` columns from a CSV produced by `Get-AzLocalClusterInventory`. Inside the `foreach ($clusterEntry in $clustersToTag)` processing loop, four references used an undefined variable `$cluster` instead of the actual loop variable `$clusterEntry`. Because `Set-StrictMode` was not enforced at module scope, the typo silently returned `$null`, with two user-visible effects:
  - Clusters with an existing `UpdateRing` tag were skipped even when the CSV changed `UpdateWindow`/`UpdateExclusions` (the "has new schedule tags" detection always evaluated to `$false`).
  - On new or `-Force`d writes, the PATCH body contained only `UpdateRing`; `UpdateWindow`/`UpdateExclusions` columns from the CSV were never sent to Azure.
- Round-trip `Get-AzLocalClusterInventory -ExportPath <csv>` -> edit CSV -> `Set-AzLocalClusterUpdateRingTag -InputCsvPath <csv>` now correctly preserves all three tag columns.

### Added
- `Set-AzLocalClusterUpdateRingTag -ClusterResourceIds` now accepts optional `-UpdateWindowValue` and `-UpdateExclusionsValue` parameters. Direct-invocation mode is now symmetrical with CSV mode and can set all three schedule tags in a single PATCH. Both values are echoed into the operations log.
- `Set-StrictMode -Version 1.0` is now enforced at module scope. This catches references to uninitialized variables (the class of bug above) at runtime instead of silently returning `$null`. All 239 Pester tests pass unchanged. `-Version Latest` was deliberately not selected: ARM REST responses legitimately omit optional properties (e.g. `additionalProperties.SBEPublisher`, `tags.UpdateRing`) and Latest would throw on every such dot-notation access.

### Changed
- No breaking changes. No API, JSON schema, or exported-function-count changes.

## [0.6.4] - 2026-04-16

### Security & Code Quality (2026-04-17 revision)
- **SECURITY**: `Connect-AzLocalServicePrincipal` now accepts `-ServicePrincipalSecret` as either `[string]` or `[SecureString]`. When a plaintext `[string]` is passed, a warning is emitted because the secret can be visible in the process command line to other users on the host. SecureString or the `AZURE_CLIENT_SECRET` environment variable are preferred. The plaintext copy is zeroed in memory via `Marshal.ZeroFreeBSTR` in a `finally` block immediately after `az login` returns.
- **NEW internal helper `Invoke-AzRestJson`**: centralises `az rest` invocation, stderr capture (`2>&1`), `$LASTEXITCODE` handling, and safe `ConvertFrom-Json` parsing. Returns a uniform `{Ok, Data, Error}` object so callers no longer have to duplicate guard logic and a malformed JSON response cannot throw an uncaught exception under Strict Mode. Body is written to a temp file and cleaned up in `finally`.
- **NEW internal helper `ConvertTo-AzLocalAdditionalProperties`**: safely normalises the ARM `additionalProperties` field (which may be a JSON string or a deserialised object). All 5 previous call sites now route through this helper, so a single cluster returning malformed SBE metadata no longer silently loses its HasPrerequisite/SBE dependency info and instead logs a `-Verbose` parse warning.
- **FIXED**: `Get-AzLocalFleetStatusData` parallel `Start-Job` path:
  - Module path (`$PSScriptRoot\AzStackHci.ManageUpdates.psm1`) is now validated with `Test-Path` before dispatching jobs; if it is not reachable, the function throws a clear error instead of every job failing silently with an `Import-Module` error.
  - Result accumulators (`Readiness`, `ClusterDetails`, `LatestRuns`, `HealthResults`, `$jobs`) switched from `@() + $item` (O(n²), pipeline-fragile) to `System.Collections.Generic.List[object]` with explicit `.Add()` calls.
  - Failed jobs, empty job output, and `ConvertFrom-Json` parse failures now surface each affected cluster (resource ID + reason) in a new `FailedClusters` property of the return object so no cluster is silently dropped from fleet reports.
- **IMPROVED**: `Connect-AzLocalServicePrincipal`, `Test-AzCliAvailable`, and the MSI installer path now use `Write-Log` instead of `Write-Host` for durable, timestamped, CI-friendly output. Aligns with repository conventions in `.github/copilot-instructions.md`.
- **IMPROVED**: `Test-AzCliAvailable` MSI install no longer blocks indefinitely. `Start-Process msiexec.exe -Wait` was replaced with `Start-Process ... -PassThru` plus `WaitForExit(1800000)` (30 minute cap) with a kill-and-throw on timeout to prevent indefinite hangs in automation environments.
- **FIXED**: Confusing ternary in `Test-AzLocalUpdateScheduleAllowed` final return: `ExclusionActive = if ($null -eq $exclusionActive) { $null } else { $false }` (which looked like it could never return `$true`) simplified to `ExclusionActive = $exclusionActive`. Behaviour is identical because the `$true` branch already returns early.
- **DOCS**: Azure REST API calls that parse response bodies are now safer under `Set-StrictMode -Version Latest`; `Invoke-AzRestJson` is available for future migrations of the remaining `az rest ... | ConvertFrom-Json` call sites.

### Inter-Function & Fleet-Scale Fixes (2026-04-17 revision)
- **FIXED**: `Test-AzLocalUpdateScheduleAllowed` and `Test-AzLocalUpdateWindow` now normalise a non-UTC `-TestTime` (Local/Unspecified `DateTimeKind`) to UTC with a `Write-Verbose` note. Previously a caller passing `Get-Date` (local time) could silently evaluate the wrong maintenance-window hour/day, causing fleet updates to run outside their intended windows.
- **FIXED**: `Get-LatestUpdateByYYMM` emits a `Write-Verbose` warning when no input update name matches the expected `Solution<XX>.<YYMM>.<build>.<rev>` pattern. Previously, when every input failed to parse, all entries mapped to YYMM=0 and the first element of a stable sort was returned as the "latest" — technically arbitrary. Callers under `-Verbose` now see the mismatch.
- **IMPROVED**: `Get-AzLocalAvailableUpdates -ClusterResourceId` (SingleCluster mode) now prints the same banner/Summary/Format-Table UX as the multi-cluster paths when `-Raw` is not specified. `-Raw` preserves the legacy silent behaviour for internal callers (`Start-AzLocalClusterUpdate`, `Get-AzLocalUpdateRuns`, `Get-AzLocalClusterUpdateReadiness`).
- **KNOWN (not changed)**: `$script:LogFilePath` and `$script:FleetOperationState` are module-scope script variables. Sequential calls to multiple logging functions in the same session will overwrite the log path. Concurrent fleet operations in the same PowerShell session are not supported (use separate runspaces/processes). This is a logging-infrastructure design decision deferred to a future refactor.

### Added - Azure CLI Availability Check & Auto-Install
- **New internal function `Test-AzCliAvailable`**: Checks if Azure CLI (az) is installed before any az invocation
- When az CLI is not found in interactive sessions, prompts the user to download and install from `https://aka.ms/installazurecliwindowsx64`
- In non-interactive environments (CI/CD pipelines), throws immediately with clear installation instructions
- All exported functions and SingleCluster code paths now call `Test-AzCliAvailable` before first az CLI usage

### Added - Fleet Status Data Collection
- **New function `Get-AzLocalFleetStatusData`**: Single-pass data collection with parallel `Start-Job` support
- `-ThrottleLimit` parameter (default: 4, max: 8) splits cluster list into parallel batches
- `-ExportPath` exports fleet data as JSON artifact for CI/CD pipeline job passing
- `-StatusData` parameter on `New-AzLocalFleetStatusHtmlReport` accepts pre-collected data to skip API calls
- Stable JSON schema (v1.0) with SchemaVersion, Timestamp, ModuleVersion, Scope, Readiness, ClusterDetails, LatestRuns, HealthResults

### Improved - Update State Alignment
- All per-update state filters now use module-level constants (`$script:ReadyStates`, `$script:PrereqStates`) aligned with current ARM API states
- `ReadyToInstall` state is now recognized alongside `Ready` across all functions: `Start-AzLocalClusterUpdate`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalFleetStatusData`, `Get-AzLocalUpdateSummary`
- Update summary state checks include `ReadyToInstall` for accurate "Update Available" counting

### Improved - HasPrerequisite & SBE Dependency Awareness
- **`Get-AzLocalAvailableUpdates`**: Multi-cluster mode now shows HasPrerequisite/AdditionalContentRequired counts alongside Ready counts in console output
- **`Get-AzLocalAvailableUpdates`**: Result objects include new `PackageType` and `SBEDependency` properties for updates blocked by SBE prerequisites
- **`Get-AzLocalAvailableUpdates`**: Summary section shows clusters blocked by SBE prerequisites with vendor dependency details (Publisher, Family, ReleaseNotes)
- **`Start-AzLocalClusterUpdate`**: Provides detailed SBE dependency info when updates are blocked by HasPrerequisite/AdditionalContentRequired state, with guidance to install the SBE from the hardware vendor
- **`Get-AzLocalClusterUpdateReadiness`**: Surfaces `HasPrerequisiteUpdates` and `SBEDependency` in result objects for downstream consumption
- **`Get-AzLocalClusterUpdateReadiness`**: Console output shows "Has Prerequisite (SBE update required)" for clusters with only prerequisite-blocked updates
- **`Get-AzLocalClusterUpdateReadiness`**: Summary section includes count of clusters blocked by SBE prerequisites with vendor-specific guidance
- **`Get-AzLocalFleetStatusData`**: Sequential collection now extracts HasPrerequisite and SBE dependency info into readiness data
- **`Get-AzLocalFleetStatusData`**: Status output shows "Has Prerequisite" for clusters with only prerequisite-blocked updates
- Aligned with current ARM API update state handling: Ready, ReadyToInstall, AdditionalContentRequired, HasPrerequisite, HealthCheckFailed, Downloading, Preparing, HealthChecking

### Added - Maintenance Schedule Tag Support
- **New exported function `Test-AzLocalUpdateScheduleAllowed`**: Master gate evaluating `UpdateWindow` and `UpdateExclusions` Azure resource tags
- **New internal function `ConvertFrom-AzLocalUpdateWindow`**: Parses maintenance window tag syntax (`<days>_<HH:MM>-<HH:MM>`) with day ranges, wildcards, and overnight windows
- **New internal function `ConvertFrom-AzLocalUpdateExclusion`**: Parses exclusion/blackout period tag syntax (`YYYY-MM-DD/YYYY-MM-DD`) with wildcard year support
- `Start-AzLocalClusterUpdate` checks schedule tags before applying updates; returns `ScheduleBlocked` status when outside maintenance windows or during exclusion periods
- Exclusion periods take priority over maintenance windows

### Performance
- `New-AzLocalFleetStatusHtmlReport` now uses single-pass data collection instead of calling 6 separate module functions
- Reduced Azure REST API calls from ~230 to ~85 for 21 clusters (~63% reduction)
- ByTag scope resolves resource IDs upfront via single ARG query instead of each downstream function querying independently
- Update summary, available updates, and health check data fetched once per cluster and reused
- Update run queries reuse already-fetched update list instead of re-fetching via `Get-AzLocalAvailableUpdates`
- Progress counter shows `[N/M]` per cluster during data collection for better visibility

### Fixed
- `Get-AzLocalClusterInfo`, `Invoke-AzLocalUpdateApply`, and SingleCluster paths in `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalUpdateRuns` had no az CLI availability check - previously threw unhelpful `CommandNotFoundException`
- Existing auth check catch blocks now differentiate 'az not installed' from 'az not logged in' with distinct error messages
- 'Up to Date' counter now recognizes `AppliedSuccessfully` state from ARM API (was showing 0 for completed clusters)
- Recommended Update no longer shows the version a cluster is already on when state is `AppliedSuccessfully`/`UpToDate`

### Improved - CI/CD Pipeline Reporting
- Apply Updates pipeline summaries now include `ScheduleBlocked` count and "Actions Required" section with remediation guidance
- Fleet Update Status JUnit XML now marks HasPrerequisite clusters as `Failed (HasPrerequisite)` instead of passing silently
- Fleet Status JSON summary includes `HasPrerequisite` as a distinct count (previously lumped into `NotReady`)
- Fleet Status dashboard summaries show `SBE Prerequisite Blocked` row and "Actions Required" section
- `Get-AzLocalClusterUpdateReadiness` and `Get-AzLocalFleetStatusData` result objects now include `UpdateWindow` and `UpdateExclusions` tag values

### Improved - Tag Management Workflow
- `Get-AzLocalClusterInventory` now includes `UpdateWindow` and `UpdateExclusions` columns in CSV/JSON output
- `Set-AzLocalClusterUpdateRingTag` now reads optional `UpdateWindow` and `UpdateExclusions` columns from CSV and sets them alongside `UpdateRing` in a single PATCH operation

## [0.6.3] - 2026-04-15

### Fixed
- `-PassThru` parameter correctly added to `Get-AzLocalUpdateSummary` param block (was in function body but missing from declaration)
- `-OutputPath` now pre-validated upfront (drive existence, `.html` extension) to fail fast before API calls

### Security
- Portal URLs in HTML report `href` attributes now HTML-encoded to prevent attribute injection
- `UpdateRingValue` in ARG KQL queries now escapes single quotes to prevent KQL injection (all 6 query locations)
- All dynamic HTML values consistently HTML-encoded: summary card numbers, timestamps, severity labels, readyText, collapse headers

### Improved
- `Get-CurrentStepPath` now has `MaxDepth=20` safety limit to prevent stack overflow on malformed step data
- `Get-LatestUpdateByYYMM` now guards against empty/null input array
- Cluster name matching uses exact last-segment comparison (`-split '/'`)[-1]`) instead of `-like` suffix pattern
- `$otherCount` in progress bar clamped to 0 minimum to prevent negative values
- Module version fallback reads from `.psd1` manifest via `Import-PowerShellDataFile` instead of hardcoded string
- `Resolve-Path` for file URI wrapped in `try/catch` for robustness when file write fails

## [0.6.2] - 2026-04-15

### Added - Fleet Status HTML Report
- **New function `New-AzLocalFleetStatusHtmlReport`**: Generates self-contained HTML reports for fleet update status
  - Collects data from `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalUpdateRuns`, and `Test-AzLocalClusterHealth`
  - Executive summary cards: Total Clusters, Up to Date, In Progress, Ready for Update, Health Failures
  - Stacked progress bar showing fleet-wide update adoption percentages
  - Cluster Information section: cluster name, current version, node count, resource group, resource ID (top for <=10 clusters, appendix for >10)
  - Cluster Status Details with Active Update column (in-progress/failed update with badge) and Recommended Update (shows N/A when active update exists)
  - Recent Update Run History with recursive Current Step traversal (up to 8+ levels) including error messages for health-check-blocked updates
  - Health Check Failures with severity filter checkboxes (Critical/Warning checked, Informational unchecked by default)
  - Collapsible per-cluster health check groups for multi-cluster reports (2+ clusters) with severity summary and top issue in collapsed view
  - `-AllClusters` switch discovers all clusters via Azure Resource Graph (limited to 100)
  - Auto-generated title: single cluster = `"<ClusterName> - Update Status Report"`, multiple = `"Azure Local Fleet Update Status Report"`
  - Azure Local purple gradient header with embedded Azure Local instance SVG logo
  - Supports all input methods: `-ClusterResourceIds`, `-ClusterNames`, `-ScopeByUpdateRingTag`, `-AllClusters`
  - `-PassThru` returns HTML string for use as email body or further processing
  - Self-contained inline CSS and minimal JavaScript (severity filter), no external dependencies
  - XSS-safe via `System.Web.HttpUtility::HtmlEncode` on all dynamic values

### Fixed - RecommendedUpdate YYMM Sort
- `Get-AzLocalClusterUpdateReadiness` now correctly selects the latest update by YYMM version (was using `Select-Object -First 1` without sorting, could select older update)
- Extracted shared `Get-LatestUpdateByYYMM` private helper used by both `Get-AzLocalClusterUpdateReadiness` and `Start-AzLocalClusterUpdate`

### Added - Recursive Update Step Traversal
- New `Get-CurrentStepPath` private helper recursively walks update run step hierarchy (up to 8+ levels deep) to find the deepest InProgress or Failed step
- `Get-AzLocalUpdateRuns` now returns `CurrentStepDetail` property with full step path (e.g., "PreUpdate > ScanForUpdates > DownloadUpdates")
- HTML report shows Current Step column in Update Run History table

### Improved - Performance: Resolve-Once Pattern for `-ClusterNames`
- All functions that accept `-ClusterNames` now resolve names to resource IDs **once upfront** instead of deferring to per-cluster loops
- Eliminates redundant `Get-AzLocalClusterInfo` API calls when multiple functions are called sequentially with the same cluster names
- Functions affected: `Start-AzLocalClusterUpdate`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalUpdateRuns`, `Test-AzLocalClusterHealth`
- `New-AzLocalFleetStatusHtmlReport` resolves names once and passes `-ClusterResourceIds` to all 6 downstream calls (reduces API calls from 6N to N for N clusters)
- `Test-AzLocalClusterHealth` now accepts `-UpdateSummary` parameter to skip redundant summary fetch when called from `Start-AzLocalClusterUpdate`

### Improved - CI/CD Pipeline Performance
- `fleet-update-status.yml` (GitHub Actions and Azure DevOps): Steps 4a/4b/4c now use `-ClusterResourceIds` from inventory instead of `-ClusterNames` or tag-based re-queries
- Eliminates redundant name-to-ID resolution and duplicate scope queries in pipeline data collection steps
- For a 100-cluster fleet: reduces API calls from ~800-900 to ~300

### Fixed - Missing `-PassThru` Parameter
- Added `-PassThru` parameter to `Get-AzLocalUpdateSummary` and `Get-AzLocalAvailableUpdates` (parameter was used in function body but missing from declaration)

### Fixed - `CurrentStepDetail` Not Propagated
- `CurrentStepDetail` property now correctly included in multi-cluster update run output (was missing from PSCustomObject re-mapping)
- Added `CurrentStepDetail` to all 3 fallback PSCustomObject blocks (Cluster Not Found, No Runs, Error)

## [0.6.1] - 2026-04-10

### Added - Pre-Update Health Check Validation
- **New function `Test-AzLocalClusterHealth`**: Queries cluster health check results from ARM to identify Critical, Warning, and Informational failures before applying updates
  - Supports all input methods: `-ClusterResourceIds`, `-ClusterNames`, `-ScopeByUpdateRingTag`
  - `-BlockingOnly` switch to show only Critical severity failures (the ones that block updates)
  - Export results to CSV, JSON, or JUnit XML
  - Returns pass/fail result per cluster (pass = no Critical failures)

### Improved - Pre-Update Health Gate in `Start-AzLocalClusterUpdate`
- Added automatic Step 3b health validation before attempting to apply an update
- If Critical health check failures are detected, the cluster is skipped with detailed failure information
- Failure details include check name, description, and remediation guidance
- Skipped clusters are logged to the Update_Skipped CSV with health check failure details

### Improved - Health Check Diagnostics in `Get-AzLocalUpdateRuns`
- When the latest update run failed with "health check failure" in the CurrentStep, the function now automatically queries and displays the Critical health failures blocking the update
- Shows remediation steps for each blocking failure

### Changed - `-PassThru` Required for Object Output
- Functions now suppress object output by default to avoid console noise (e.g., list-format dump of all update runs)
- Use `-PassThru` to return objects for pipeline/variable capture: `$results = Get-AzLocalUpdateRuns ... -PassThru`
- Functions affected: `Start-AzLocalClusterUpdate`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalUpdateRuns`, `Get-AzLocalClusterUpdateReadiness`, `Set-AzLocalClusterUpdateRingTag`, `Test-AzLocalClusterHealth`
- CI/CD pipeline examples updated to use `-PassThru` where return values are captured
- `HealthCheckBlocked` status added to JUnit XML failure mapping and CI/CD result counting

### Improved - Node-Level Health Failure Reporting
- Health check failures now display the physical node name (`TargetResourceName`) where the failure occurred
- Node name shown in console output, CSV skip logs, JUnit XML exports, and JSON exports
- Example: `[Critical] Test PowerShell Module Version (Node: SEA-NODE1): ...`

### Improved - Console Output Formatting
- `Get-AzLocalUpdateRuns` latest run detail view now uses tab-indented `Format-List` with spacing for readability
- Removed non-ASCII Unicode characters (checkmark/cross) from fleet operation output for cross-system encoding compatibility

## [0.6.0] - 2026-04-09

### Fixed - Cumulative Update Auto-Selection
- **Fixed YYMM sort bug**: The auto-selection of the latest cumulative update was incorrectly picking an older update due to a PowerShell 5.1 `$Matches` variable scope issue inside `Sort-Object` scriptblocks. The `$Matches` state leaked between iterations, causing unpredictable sort order.
- **Fix**: Replaced `$Matches`-based extraction with `-split '.'` to extract the YYMM portion, which is self-contained per iteration with no shared state.
- Example: With updates `Solution12.2602.1002.501` and `Solution12.2603.1002.500` both in Ready state, the module now correctly selects `2603` (March 2026) instead of `2602` (February 2026).

## [0.5.9] - 2026-04-08

### Improved - Subscription & Resource Validation for `-ClusterResourceIds`
- **Subscription pre-validation**: When using `-ClusterResourceIds`, the module now extracts the subscription ID from the resource ID and runs `az account set --subscription` before making REST calls. This catches inaccessible subscriptions early with a clear error message instead of a cryptic `az rest` failure.
- **Specific error messages**: Validation errors are now split into distinct, actionable messages:
  - **Subscription not found**: Advises the user to verify they are logged into the correct Azure tenant (`az login --tenant <tenantId>`)
  - **Resource group not found**: Names the specific resource group and subscription, suggests the resource may have been deleted
  - **Cluster not found**: Names the specific cluster and resource group, suggests the cluster may have been deleted or the name is incorrect

### Improved - Auto-Selection of Latest Cumulative Update
- When `-UpdateName` is not specified, the module now **selects the latest update by YYMM version** from the update name (e.g., `Solution12.2603.1002.15` = March 2026) instead of taking the first item from the API response
- This ensures cumulative updates are handled correctly - earlier months are safely skipped when a newer cumulative update is available
- Update names follow the format `SolutionXX.YYMM.XXXX.XX`, where YYMM represents the year and month

## [0.5.7] - 2026-01-29

### Added
- **JSON Export for `Get-AzLocalClusterInventory`**: The function now supports exporting inventory to JSON format in addition to CSV
  - Format is auto-detected from file extension (`.json` or `.csv`)
  - JSON export is ideal for CI/CD pipelines, API integrations, and CMDB systems
  - CSV remains the default for Excel-based tag management workflows

### Example
```powershell
# Export to JSON for CI/CD pipelines
Get-AzLocalClusterInventory -ExportPath "C:\Reports\inventory.json"

# Export to CSV for Excel editing (unchanged)
Get-AzLocalClusterInventory -ExportPath "C:\Reports\inventory.csv"
```

## [0.5.6] - 2026-01-29

### Added - Fleet-Scale Operations
New functions for managing updates across fleets of 1000-3000+ clusters:

- **`Invoke-AzLocalFleetOperation`** - Orchestrates fleet-wide operations with:
  - Configurable batch processing (default: 50 clusters per batch)
  - Throttling and rate limiting (default: 10 parallel operations)
  - Automatic retry with exponential backoff (default: 3 retries)
  - State checkpointing for resume capability
  - Operations: ApplyUpdate, CheckReadiness, GetStatus

- **`Get-AzLocalFleetProgress`** - Real-time progress tracking:
  - Total, completed, in-progress, failed, pending counts
  - Success/failure percentages
  - Per-cluster status details (with -Detailed switch)

- **`Test-AzLocalFleetHealthGate`** - CI/CD health gate for safe wave deployments:
  - Maximum failure percentage threshold (default: 5%)
  - Minimum success percentage threshold (default: 90%)
  - Wait for completion option with timeout
  - Returns Pass/Fail for pipeline decisions

- **`Export-AzLocalFleetState`** - Save operation state for resume:
  - JSON format with full cluster tracking
  - Includes run ID, timestamps, and per-cluster status

- **`Resume-AzLocalFleetUpdate`** - Resume interrupted operations:
  - Load state from file or object
  - Option to retry failed clusters
  - Continues from last checkpoint

- **`Stop-AzLocalFleetUpdate`** - Graceful stop with state save:
  - Saves current progress
  - Does not cancel in-progress cluster updates

### Use Cases
- **Enterprise Scale**: Process 1000-3000+ clusters with batching
- **CI/CD Safety**: Health gates prevent cascading failures
- **Resilience**: Resume capability after pipeline timeouts or interruptions
- **Visibility**: Real-time progress tracking during long operations

## [0.5.5] - 2026-01-29

### Added
- **Fleet-Wide Tag Support for All Query Functions**: Three functions now support multi-cluster queries:
  - `Get-AzLocalUpdateSummary` - Query update summaries across fleet
  - `Get-AzLocalAvailableUpdates` - List available updates across fleet
  - `Get-AzLocalUpdateRuns` - Get update run history across fleet
- **New Parameters for Multi-Cluster Queries**:
  - `-ClusterNames` - Query multiple clusters by name
  - `-ClusterResourceIds` - Query multiple clusters by resource ID
  - `-ScopeByUpdateRingTag` + `-UpdateRingValue` - Query clusters by UpdateRing tag
  - `-ExportPath` - Export results to CSV, JSON, or JUnit XML format
- **Fleet Update Status Pipeline**: New `fleet-update-status.yml` CI/CD pipeline for monitoring update status across entire cluster fleet
  - Available for both GitHub Actions and Azure DevOps
  - Generates JUnit XML reports for CI/CD dashboard integration
  - Each cluster appears as a test case (passed=healthy, failed=issues)
  - Multiple output formats: CSV, JSON, and JUnit XML
  - Scheduled daily checks at 6 AM UTC (configurable)
  - Flexible scope: all clusters or filter by UpdateRing tag
- **Dashboard Integration**: JUnit XML results display in GitHub Actions Tests tab and Azure DevOps Tests tab with trend analytics

### Improved
- **Consistent Logging**: All functions now use `Write-Log` for consistent, timestamped, colored console output
- **File Logging Support**: When `$script:LogFilePath` is configured, all functions write to log files
- **Better Progress Visibility**: Users can see exactly what API operations are happening during function execution
- **Severity-Based Coloring**: Messages use appropriate levels (Info=White, Warning=Yellow, Error=Red, Success=Green, Header=Cyan)
- All fleet query functions provide consistent fleet-wide reporting with summaries
- Export support includes CSV, JSON, and JUnit XML for CI/CD integration
- **Backward Compatibility**: Single-cluster parameter sets remain unchanged for existing scripts

## [0.5.0] - 2026-01-29

### Security
- Added comprehensive OpenID Connect (OIDC) documentation for secretless CI/CD authentication
- Documented authentication methods ranked by security: OIDC (recommended) > Managed Identity > Client Secret
- GitHub Actions workflows now default to OIDC authentication with `id-token: write` permission
- Added Azure DevOps Workload Identity Federation setup instructions

### Documentation
- Added authentication method comparison table with security ratings
- Updated Quick Start guide with OIDC examples for GitHub Actions
- Added links to Microsoft documentation for federated credentials setup
- Documented subject claim patterns for GitHub Actions (branch, PR, environment, tag)
- Added warning that client secrets are legacy/not recommended

## [0.4.2] - 2026-01-29

### Documentation
- Verified and documented that all functions work with three authentication methods:
  1. **Interactive** - Standard user login via `az login`
  2. **Service Principal** - CI/CD automation using `Connect-AzLocalServicePrincipal`
  3. **Managed Identity (MSI)** - Azure-hosted agents using `Connect-AzLocalServicePrincipal -UseManagedIdentity`

## [0.4.1] - 2026-01-29

### Added
- Managed Identity (MSI) authentication support in `Connect-AzLocalServicePrincipal` with `-UseManagedIdentity` switch
- `-ManagedIdentityClientId` parameter for user-assigned managed identities
- `-PassThru` switch for `Get-AzLocalClusterInventory` to return objects even when exporting to CSV (useful for CI/CD pipelines)

### Fixed
- **CRITICAL**: Azure Resource Graph queries in `Get-AzLocalClusterInventory`, `Start-AzLocalClusterUpdate`, and `Get-AzLocalClusterUpdateReadiness` were returning incorrect resource types (mixed resources like networkInterfaces, virtualHardDisks, extensions instead of clusters only). The root cause was HERE-STRING query format (`@"..."@`) causing malformed az CLI commands. Changed all ARG queries to single-line string format.
- **CRITICAL**: `Set-AzLocalClusterUpdateRingTag` failing with JSON deserialization errors when applying tags. PowerShell/cmd.exe was mangling JSON quotes when passed to `az rest --body`. Now uses temp file with `@file` syntax to avoid escaping issues.
- **CRITICAL**: `Set-AzLocalClusterUpdateRingTag` including PowerShell hashtable internal properties (`Keys`, `Values`) in JSON body. Now uses `[PSCustomObject]` with filtered `NoteProperty` members only.

### Changed
- `Get-AzLocalClusterInventory` no longer dumps objects to console when using `-ExportPath` (cleaner output)

## [0.4.0] - 2026-01-29

### Added
- `Get-AzLocalClusterInventory` function to query all clusters and their UpdateRing tag status
- CSV-based workflow for managing UpdateRing tags (export inventory, edit in Excel, import back)
- `Set-AzLocalClusterUpdateRingTag` now accepts `-InputCsvPath` parameter for bulk tag operations
- JUnit XML export for CI/CD pipeline integration (Azure DevOps, GitHub Actions, Jenkins, GitLab CI)
- CI/CD automation pipeline examples for GitHub Actions and Azure DevOps

### Changed
- Renamed `-ScopeByTagName` to `-ScopeByUpdateRingTag` for clarity (now a switch parameter)
- Renamed `-TagValue` to `-UpdateRingValue` for consistency
- UpdateRing tag queries now use hardcoded 'UpdateRing' tag name for consistency
- `-ExportResultsPath` and `-ExportPath` now support `.xml` extension for JUnit format

### Fixed
- PSScriptAnalyzer warnings (empty catch blocks, unused variables)

## [0.3.0] - 2026-01-28

### Added
- `Connect-AzLocalServicePrincipal` function for CI/CD automation (GitHub Actions, Azure DevOps)
- Service Principal authentication via parameters or environment variables (`AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`)

### Changed
- All functions now have `[OutputType()]` attributes for better IntelliSense
- Centralized API version constant for consistency
- Renamed internal function to use approved verb (`Install-AzGraphExtension`)
- `Write-Log` is now internal only (not exported)
- Added `#Requires -Version 5.1` statement
- Added LicenseUri to manifest for PowerShell Gallery compliance
- Added 'Automation' and 'CICD' tags for discoverability

## [0.2.0] - 2026-01-27

### Added
- `Set-AzLocalClusterUpdateRingTag` function to manage UpdateRing tags on clusters
- Auto-install Azure CLI resource-graph extension for pipeline/automation scenarios
- Tag-based cluster filtering using `-ScopeByUpdateRingTag` and `-UpdateRingValue` parameters
- `-Force` parameter support for tag operations to overwrite existing tags
- Comprehensive logging for all tag operations with CSV output

### Changed
- Health check filtering now shows only Critical and Warning severities (not Informational)
- Enhanced CSV diagnostics with health check failures and update run error details
- `Get-AzLocalClusterUpdateReadiness` now supports tag-based scoping

### Fixed
- Corrected API path for querying update run errors

## [0.1.0] - 2026-01-26

### Added
- Initial release
- `Start-AzLocalClusterUpdate`: Start updates on one or more Azure Local clusters
- `Get-AzLocalClusterUpdateReadiness`: Assess update readiness with diagnostics
- `Get-AzLocalClusterInfo`: Retrieve cluster information
- `Get-AzLocalUpdateSummary`: Get update summary for a cluster
- `Get-AzLocalAvailableUpdates`: List available updates for a cluster
- `Get-AzLocalUpdateRuns`: Monitor update progress
- Comprehensive logging with transcript support
- Export results to JSON/CSV
