# AzLocal.UpdateManagement Release History

> **What you will find here:** A chronological record of every released version, in newest-first order. Each entry describes user-visible behaviour changes, bug fixes, and migration steps. The most recent release's full What's-New is also mirrored in the main [README.md](../README.md) under `What's New in v<latest>`.
>
> **For older releases**, this is the canonical reference; the main README intentionally stays slim so the most recent block is easy to find.
>
> **For v0.8.75 (the current release)**, see the main [README.md](../README.md#whats-new-in-v0875) `What's New in v0.8.75` section.

---

### What's New in v0.8.74

v0.8.74 makes the "Up to Date" cluster classification consistent across the Step.5 readiness report, the Step.7 readiness gate, and the Step.9 fleet update-status report. It also corrects the `Progress` column in the Step.7 in-flight monitor and the standalone HTML report's "Recent Update Run History" table, both of which had been reporting a near-constant `1/2 steps` for the whole multi-hour run, and drops the dead `target="_blank"` portal-link attributes that GitHub Actions / Azure DevOps step-summary sanitisers were stripping anyway (replaced with an explicit Ctrl/Cmd/middle-click tip above each affected table). No public API or export-count change (still 60).

**Fully-patched clusters were mis-classified as "not ready".** A cluster that had successfully installed every required update showed `0` in the Step.5 (`Export-AzLocalClusterUpdateReadinessReport`) "Up to date" summary count and appeared in its "Not-Ready clusters (review first)" table; Step.7 (`Export-AzLocalClusterReadinessGateReport`) rendered it with a no-entry icon in the binary `Ready?` column - both implying failure. The root cause was that the "Up to Date" determination required the `AllAvailableUpdates` collection to be empty, but a cluster that has installed all updates still lists those (now-Installed) package names there. Step.9 already classified these clusters correctly via its priority cascade.

**`Progress` column always reported the top-level wrapper.** The Step.7 in-flight monitor (`Export-AzLocalUpdateRunMonitorReport`) and the standalone HTML report's `Recent Update Run History` table (`New-AzLocalFleetStatusHtmlReport`, fed by `Get-AzLocalFleetStatusData`) both rendered `Progress` from the top level of `properties.progress.steps`. Azure Local only exposes two coarse wrapper steps there - `Prepare update` (Success) and `Start update` (InProgress for the whole run) - so the column always read `1/2 steps` for ~150-leaf solution updates regardless of real progress. Both paths now walk the full nested step tree via a new private helper (`Get-AzLocalUpdateRunStepStats`) and report leaf-step completion as `M/N steps (P%)` (optionally suffixed with `, K failed`), matching how `CurrentStep` already walks the tree via `Get-DeepestActiveStep`.

**Portal hyperlinks `target="_blank"` was being silently stripped.** The Cluster / Update hyperlinks rendered in Step.7 (`Export-AzLocalUpdateRunMonitorReport`) in-flight + failed-runs tables, Step.8 (`Export-AzLocalFleetUpdateStatusReport`) Update Run History table, and Step.10 (`Export-AzLocalFleetHealthStatusReport`) Fleet Health Overview / By-Reason / Detailed Results tables always opened in the current tab even though the markdown source set `target="_blank"`. GitHub's GFM sanitiser (and the ADO equivalent) drops the `target` attribute entirely and forces `rel="nofollow"` - confirmed in the rendered HTML of a real GitHub Actions job summary, and documented in [Stack Overflow: open link in new tab with github markdown using target="_blank"](https://stackoverflow.com/questions/41915571/open-link-in-new-tab-with-github-markdown-using-target-blank). The dead attributes are now removed (so the emitted markdown matches the rendered DOM), and each affected table is preceded by an explicit tip: *"Hold `Ctrl` (or `Cmd` on macOS) when clicking - or middle-click - Cluster or Update links to open them in a new tab. (GitHub markdown strips `target="_blank"`.)"* The standalone HTML report (`New-AzLocalFleetStatusHtmlReport`) is unaffected; it is written as a raw `.html` artifact (not a step-summary), so its `target="_blank"` already works as intended in any browser.

**New shared classifier.** A new private helper, `Get-AzLocalClusterReadinessStatus`, is the single source of truth for the readiness priority cascade (UpdateFailed > ActionRequired > HealthFailure > SbeBlocked > InProgress > ReadyForUpdate > UpToDate > NeedsInvestigation). Step.5, Step.7 and Step.9 (`Export-AzLocalFleetUpdateStatusReport`) now classify clusters identically through this helper; previously each report re-implemented the logic inline and the definitions had drifted.

**Step.7 reporting changes.** The per-cluster table replaces its binary `Ready?` column with a readable `Status` column (`Ready`, `Up to Date`, `In Progress`, `SBE Prerequisite`, `Health Failure`, `Update Failed`, `Action Required`, `Needs Investigation`), the header line shows a distinct `Up to Date` count, and a new additive `UP_TO_DATE_COUNT` / `UpToDateCount` step output is emitted (`-PassThru` returns `UpToDateCount`). The existing `READY_COUNT` gate semantics are unchanged.

**Step.5 reporting changes.** The "All clusters detail" table replaces its `Ready` boolean column with the same readable `Status` label, and the "Not-Ready clusters (review first)" table now excludes both Up-to-Date and Ready clusters.

**Step.7 "No Clusters Ready" summary now explains why.** `Add-AzLocalNoReadyClustersStepSummary` takes new `-UpToDateCount` / `-NotReadyCount` parameters and renders an Up-to-Date vs Not-Ready breakdown table, so an idle apply-updates run makes clear that already-patched clusters are a healthy steady state (and logs an informational notice instead of a warning when every cluster is up to date) and points to the per-cluster `Status` / `Blocking Reasons` detail. Both the GitHub Actions and Azure DevOps `apply-updates` templates wire the two counts through from the readiness gate.

`GENERATED_AGAINST_MODULE_VERSION` bumped from `0.8.73` to `0.8.74` across all bundled pipeline templates.

---

### What's New in v0.8.2

v0.8.2 is an operator-experience release for `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend`. No public API changes; no output-shape changes that break existing scripts.

**Paste-time pain points fixed in the `-View Recommend` snippet.** Two reports on v0.8.1 are addressed:

1. The advisor's emitted snippet now embeds a `# All cron times below are UTC ...` comment directly above `schedule:` (GH) and `schedules:` (ADO). Both platforms evaluate `cron:` in UTC regardless of repo / runner / agent timezone, but operators repeatedly burned time converting from a local-time mental model and ended up firing windows hours offset from their intent. The comment makes the snippet self-documenting once pasted into `Step.6_apply-updates.yml`.
2. The advisor now emits a `> **Indent tip.**` blockquote directly above the snippet. The GH snippet is intentionally at 2-space indent (so `schedule:` is a sibling of the existing `workflow_dispatch:` under `on:`); operators who pasted with the cursor sitting inside the `# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` comment block saw VS Code (and JetBrains IDEs) silently double the indent, producing the YAML error *"All mapping items must start at the same column"*. The blockquote explains the cause, instructs the operator to paste at column 0 of a fresh blank line so `schedule:` lines up with `workflow_dispatch:`, and tells them how to recover (delete two leading spaces from every pasted line) if they already hit it.

**Module foundations for the upcoming executable-YAML refactor.** Five new internal (Private) helpers - `Get-AzLocalPipelineHost`, `Set-AzLocalPipelineOutput`, `Add-AzLocalPipelineStepSummary`, `Write-AzLocalPipelineNotice`, `Write-AzLocalPipelineWarning` - abstract over the host-specific quirks of GitHub Actions vs Azure DevOps output channels (`$env:GITHUB_OUTPUT` vs `##vso[task.setvariable]`, `$env:GITHUB_STEP_SUMMARY` vs `##vso[task.uploadsummary]`, `::notice`/`::warning` vs `##vso[task.logissue]`). Not exported and no user-visible effect in v0.8.2 - they are foundations for the upcoming per-Step `Export-*` / `Invoke-*` cmdlets that will move inline `run: |` PowerShell out of the `Step.{0..9}.yml` files and into the module proper. 23 new Pester assertions cover the three host modes (GitHub auto-detect, Azure DevOps via `$env:TF_BUILD`, Local fallback) and the byte-identical contracts of each emitted logging-command syntax.

**`-View Audit` `NoWindowTag` row is now actionable on its own.** Pre-v0.8.2 the row showed a generic *"Tag clusters with UpdateStartWindow=&lt;days&gt;_&lt;HH:MM&gt;-&lt;HH:MM&gt;"* nudge that left operators cross-referencing the matrix CSV to find the offenders. The advisor now names the first 15 affected cluster names grouped by their `UpdateRing` tag (or `(none)` when both tags are missing), e.g. `Prod -> hci-syd-01, hci-syd-02; Wave1 -> hci-mel-01 (+3 more) (showing first 15 of 42)`. The row's issue text is clarified to say the tag is *optional* (the runtime gate only enforces a window when it is set), and the row sorts AFTER `Covered` (rank 10 instead of 7) so it is treated as informational cleanup rather than a blocker.

**Step.3 Allow-list section trimmed in both GH and ADO scaffolds.** The `Allow-list coverage (schema v2)` subsection no longer emits the verbose `> Tip - per-ring overrides` paragraph + 3-row example block that v0.8.1 produced. Inheriting the top-level allow-list IS the expected steady state for most fleets (install Latest as soon as Ready); the verbose tip was misleading operators into thinking they had to add overrides. The new shape is a one-line steady-state confirmation plus a dedicated `### How to fix - edit $schedulePath` subsection (naming the schedule file) and a single-row YAML example showing how to PIN a ring to a specific update (e.g. keep Prod on the latest feature drop only - YY04 / YY10 - and skip cumulative updates between feature drops).

**`Azure Stack HCI Update Operator` custom-role Description rewritten to drop module-internal jargon.** The custom-role Description shipped into the Azure RBAC plane (visible in the Azure portal **Custom roles** blade, in `az role definition list` / `Get-AzRoleDefinition` output, and in any RBAC audit/governance tooling) previously read *"...read the fleet-connectivity scopes (Arc machines, edge-device NICs, Azure Resource Bridges) required by Step.4"* - `Step.4` is a module-private concept and meaningless to anyone outside `AzLocal.UpdateManagement`. The new Description reads *"Can read and apply Azure Local cluster updates, manage UpdateRing tags, and read the fleet-connectivity inventory (Arc-enabled machines, edge-device NICs, Azure Resource Bridges) needed to assess pre-update connectivity."* Same RBAC grant - `Actions[]`, `NotActions[]`, `DataActions[]`, `AssignableScopes[]` are byte-identical, so operators with the role already deployed need no action; the next `az role definition update` will refresh the Description. Updated in lockstep across all 6 sites that ship/document the role: the bundled JSON file plus the inline JSON blocks in `Automation-Pipeline-Examples/README.md` and `docs/rbac.md`.

**Migration:** `Install-Module AzLocal.UpdateManagement -Force` (or `Update-Module`). Re-run `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` once to pick up the new self-documenting snippet (the cron *values* are unchanged from v0.8.1; only the surrounding comment and prose changed).

**All 20 bundled `Step.{0..9}.yml` templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.1'` to `'0.8.2'`.

See [CHANGELOG.md](../CHANGELOG.md#082---2026-06-10) for the full v0.8.2 entry.

### What's New in v0.8.1

v0.8.1 is a docs-and-snippet correctness release. No public API or output-shape changes - existing scripts and pipelines continue to work without modification.

**`Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` GH-Actions snippet is now copy-paste-safe into `Step.6_apply-updates.yml`.** Pre-v0.8.1 the GitHub-flavoured snippet emitted a full `on:` + `workflow_dispatch:` + `schedule:` block and instructed the operator to "Replace (or merge with) the existing `on:` block". `Step.6_apply-updates.yml` already declares `workflow_dispatch:` with a rich `inputs:` block (`update_ring`, `update_name`, `dry_run`, `raise_itsm_ticket`, `itsm_config_path`, `itsm_dry_run`, `itsm_force_create`, `module_version`) that the manual `Run workflow` button depends on. Operators who pasted the snippet alongside the existing block ended up with two top-level `workflow_dispatch:` keys, which GitHub Actions rejects at parse time (`'workflow_dispatch' is already defined`). The GH snippet now emits ONLY the `schedule:` block (2-space `schedule:` indent + 4-space cron indent) so it pastes as-is under the existing `on:` key, inside the `# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` / `# END-AZLOCAL-CUSTOMIZE:schedule-triggers` markers. Azure DevOps snippet shape (top-level `schedules:`) is unchanged.

**Updated "How to fix" prose** explicitly tells operators to add (not replace) the `schedule:` block under the existing `on:` key, place it inside the BEGIN/END-AZLOCAL-CUSTOMIZE markers so it survives `Update-AzLocalPipelineExample` refreshes, and explicitly NOT to add a second `workflow_dispatch:` line.

**Four updated `AS7`-`AS10` Pester assertions** in `Tests/AzLocal.UpdateManagement.Tests.ps1` swap the GH-snippet detector regex from `'workflow_dispatch'` to `'(?m)^\s*schedule:\s*$'` (the singular `schedule:` key on its own line is GH-Actions-unique; ADO emits the plural `schedules:` at column 0).

**Migration:** for operators who have ALREADY pasted the v0.8.0-flavoured snippet into `Step.6_apply-updates.yml` and seen the duplicate-key error: either `Update-AzLocalPipelineExample -Destination <path>` to refresh Step.6 and re-run `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend`, or manually delete the duplicate empty `workflow_dispatch:` line from Step.6.

**All 20 bundled `Step.{0..9}.yml` templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.0'` to `'0.8.1'`.

See [CHANGELOG.md](../CHANGELOG.md#081---2026-06-09) for the full v0.8.1 entry.

### What's New in v0.8.0

v0.8.0 is a patch release rolling up three follow-ups to v0.7.99 plus Step.2 UX fixes. No public API changes. `Set-AzLocalClusterUpdateRingTag -PassThru` gains two new enum values (`Action='NoChange'` and `Status='AlreadyInSync'`) to distinguish steady-state clusters from genuinely-skipped ones; existing scripts that switch on `Created`/`Updated`/`Skipped`/`Failed` continue to work, with already-in-sync clusters now surfacing under the new bucket rather than spurious `Skipped`.

**Step.2 `Set-AzLocalClusterUpdateRingTag` UX cleanup.** Three operator-visible fixes:
- The skip branch no longer logs a misleading `Warning` + "use -Force to overwrite" hint for clusters that are already in the desired state. Steady-state clusters now log an `Info` line (`All managed tags already match desired state - no action needed`) and are tallied separately as `Already in sync (no change needed):`. The `Warning` path is preserved for the genuine case (`UpdateRing` differs from target AND no schedule diff).
- `-Force` short-circuits when all managed tags already match desired state - saves a redundant ARM PATCH per cluster on already-clean fleets. Behaviour when there IS something to change is unchanged.
- Step.2 GitHub Actions + Azure DevOps job summaries now include a per-cluster result breakdown (counts table + collapsible per-cluster details), at parity with Step.3/5/6/8. Previously the run-level summary only showed the 2-row settings table.

**Step.7 `criticalElapsedDays` form-default fixed `7` -> `3`.** The v0.7.99 release lowered the CRITICAL overall-elapsed tier from 7 to 3 days. The inline script default (`$criticalElapsedDays = 3`) and the help-text ("default 3 days") were updated correctly, but the `workflow_dispatch` input default value (GH) / pipeline-parameter default value (ADO) on the form itself was left at `'7'`. When an operator triggered the workflow and left the input untouched, the non-empty form-default `'7'` was passed in via `INPUT_CRITICAL_ELAPSED_DAYS`, the override branch fired, and the threshold silently reverted to the old 7 days - undoing the v0.7.99 behaviour change.

**Step.7 `updateRing` form-default fixed `'Wave1'` -> `''` (empty).** Aligns Step.7 with Step.8 + Step.9, which already use `default: ''`. The downstream guard `if ($scope -eq 'by-update-ring' -and $updateRing)` honours empty as "no filter", so behaviour is unchanged on the default `scope=all` path. Removes the misleading "Wave1" value that suggested a real tenant-specific default existed when the operator switched to `scope=by-update-ring`.

**New `Tests/Pii-Guard.Tests.ps1` repo-hygiene guard.** Pester now scans every file under `Tests/` on each run and fails the build if it finds emails, `.onmicrosoft.com` tenant UPN domains, GUIDs in identity contexts (`tenantId` / `clientId` / `objectId` / `principalId` / `applicationId`), or real public IPv4 addresses outside an explicit allow-list. RFC1918 / loopback / link-local / CGNAT / RFC5737 doc / multicast / subnet-mask shapes / well-known public DNS are auto-excluded. Catches accidental PII commits to a public repo at PR time rather than after-the-fact.

**`Publish-Module.ps1` excludes `docs/RELEASE-PROCESS.md` from the published `.nupkg`.** That file is a maintainer-only release checklist (its own opening line states "Consumers do not need to read it") and has no runtime value. Repo copy on GitHub stays for maintainer reference; consumers no longer ship it inside every installed module folder.

**All 20 bundled `Step.{0..9}.yml` templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.99'` to `'0.8.0'`.

See [CHANGELOG.md](../CHANGELOG.md#080---2026-06-09) for the full v0.8.0 entry.

### What's New in v0.7.99

v0.7.99 is a breaking-rename release for the readiness / fleet-status cmdlets plus a Step.7 default tightening and an artifact-naming cleanup. All 20 bundled pipeline YAMLs were updated to consume the new output shapes.

**Property renames.** `Get-AzLocalUpdateSummary.AvailableUpdatesCount` -> `ActionableUpdatesCount` (the column only ever counted Ready + NotReady, not the full inventory). `Get-AzLocalClusterUpdateReadiness.AvailableUpdates` -> `AllAvailableUpdates`. `Get-AzLocalFleetStatusData.AvailableUpdates` -> `AllAvailableUpdates`. Same content, clearer names. The cmdlet name `Get-AzLocalAvailableUpdates` is unchanged.

**Readiness Summary: 2-bucket -> 3-bucket model.** `Get-AzLocalClusterUpdateReadiness`'s console block and JSON export both gain a `Up to Date` bucket distinct from `Not Ready for Update`. Previously clusters with `UpdateState in (UpToDate, AppliedSuccessfully)` and no remaining available updates were rolled into the `NotReady` total, which falsely flagged a healthy fleet as needing attention. Console labels: `Ready for Update` / `Up to Date` (new) / `Not Ready for Update`. JSON `Summary` keys: `ClustersReadyForUpdate` / `ClustersUpToDate` (new) / `ClustersNotReadyForUpdate`.

**Step.5 + Step.8 pipelines updated** (both GH Actions and Azure DevOps) to compute and surface the 3-bucket model and to consume the renamed `AllAvailableUpdates` property. `readiness-status.json` `Summary` keys move to `ReadyForUpdate` / `UpToDate` / `NotReadyForUpdate`. `Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml` is unchanged - the `NotReady` key there maps a per-run `Status` value from `Start-AzLocalClusterUpdate.ps1`, which is a separate (and stable) contract.

**Step.7 CRITICAL elapsed-days default 7 -> 3.** Skull (rotating-light) threshold (2x CRITICAL) consequently lowers from 14 to 6 days. Override via `criticalElapsedDays: <N>` workflow_dispatch / pipeline param.

**Step.7 testsuite-level `time=` zeroed.** Per-testcase `time=` continues to carry real per-run elapsed seconds (v0.7.98 behaviour preserved). The suite-level wrapper now emits `time="0"` rather than summing five unrelated wall-clock ages.

**Artifact zip names now carry the producing Step number.** Every bundled template's artifact zip moves from `azlocal-<purpose>_yyyyMMdd_HHmmss` to `azlocal-step.X-<purpose>_yyyyMMdd_HHmmss`. The Pester guard for the artifact-name convention now requires the `^azlocal-step\.\d+-` regex shape.

**Docs.** `Automation-Pipeline-Examples/README.md` section 1.1 Step.N table gains direct GH Actions + Azure DevOps YAML column links; section 9 (ThrottleLimit) trimmed of stale v0.7.68 historical narrative. `docs/cmdlet-reference.md` reflects the property and Summary renames.

**All 20 bundled `Step.{0..9}.yml` templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.98'` to `'0.7.99'`.

See [CHANGELOG.md](../CHANGELOG.md#0799---2026-06-09) for the full v0.7.99 entry.

### What's New in v0.7.98

v0.7.98 is a pipeline-template UX release. The Step.7 in-flight update monitor pipelines (`Step.7_monitor-updates.yml` in both `github-actions/` and `azure-devops/`) get a UX overhaul so stuck and critical runs surface immediately, and the Step.7 + Step.8 JUnit emitters now populate `time=` with real run elapsed seconds. No public-cmdlet changes.

**Step.7 UX overhaul.** Each row is now scored on a composite `SeverityScore` (`StepError severity x 1000 + RunSeverity x 100 + elapsed-hours bucket`), the job summary opens with a single `CRITICAL / WARN / OK` fleet status badge (e.g. `CRITICAL - 1 stuck step error(s), 1 run(s) > 14d, 1 step(s) > 4h`), each row carries per-cell `StateIcon` + `StatusIcon` icons and a horizontal chip stack of flags (`STEP-STUCK`, `RUN-STUCK`, `UNRESOLVED`, `RECENT-FAIL`), and each failed step's `errorMessage` is wrapped in a collapsible `<details><summary>Verbose error</summary>...</details>` block.

**JUnit `time=` populated (Step.7 + Step.8).** Previously every `<testcase>` and `<testsuite>` emitted `time="0"`, which made GitHub Test Reporter render `"5 tests were completed in 0ms"`. Step.7 now computes per-run elapsed seconds (`end - start` for completed / failed, current elapsed for in-flight). Step.8's `Update Run History and Error Details` testsuite now emits `time` = `DurationMinutes * 60` per row. Other Step.8 testsuites (`FleetVersionDistribution`, `AzureLocalFleetUpdateStatus`) intentionally stay at `time="0"` - they are instantaneous snapshot projections.

**All 20 bundled `Step.{0..9}.yml` templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.97'` to `'0.7.98'`.

See [CHANGELOG.md](../CHANGELOG.md#0798---2026-06-09) for the full v0.7.98 entry.

### What's New in v0.7.97

v0.7.97 is a documentation-only follow-up to v0.7.96. The three Markdown files that ship inside the published PSGallery `.nupkg` under the module folder were refreshed to mirror the v0.7.96 module behaviour. Consumers who installed v0.7.96 fresh saw stale Step.7 + Step.8 narrative in those in-package docs because they were updated AFTER `Publish-Module.ps1` ran. v0.7.97 republishes the package with the aligned docs.

**No code anywhere in the module, no inline-script changes in any Step.{0..9}.yml template.** Only the `GENERATED_AGAINST_MODULE_VERSION` pin moves from `'0.7.96'` to `'0.7.97'` across all 20 bundled templates (10 GitHub Actions + 10 Azure DevOps).

- **`Automation-Pipeline-Examples/README.md` (CI/CD runbook):** section-1 Step.7 bullet now mentions the new `Status` + `ErrorMessage` columns, the `StepError` JUnit failure type, the always-shown Failed-runs block, portal-linked Cluster / Update Name cells, and the new `STEP_ERRORED` / `UNRESOLVED_FAILURES` `GITHUB_OUTPUT` values. Step.8 bullet now mentions `NeedsAttention` promotion into the `Update Failed` bucket, the new `Action Required` bucket for `PreparationFailed`, and `PreparationInProgress` folding into `Update In Progress`.
- **`Automation-Pipeline-Examples/docs/appendix-pipelines.md` (per-step pipeline reference):** Step 7 and Step 8 tables refreshed: the `Purpose`, `Artefacts`, `Exit conditions`, and `Introduced` rows now describe the new columns, JUnit failure types, the bucket cascade, the `primaryActionRequired` JUnit attribute, `ACTION_REQUIRED` output, `Summary.UpdateFailures` + `Summary.ActionRequired` JSON keys, and the portal-linked markdown cells. A duplicate `Exit conditions` row on Step 7 was removed.
- **`docs/release-history.md` (this file):** current-release pointer bumped from v0.7.89 to v0.7.97; the v0.7.96 entry was already prepended in PR #66 (commit `c395ed3`).
- **All 18 bundled `Step.{0..9}.yml` templates** bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.96'` to `'0.7.97'`. Pin-only; no inline-script content changes.

This release also closes a process gap: the in-package docs (the three files listed above) ship inside the PSGallery `.nupkg` because `Publish-Module.ps1` only strips `Tests/`, `Tools/`, `Module-reviews/`, and root-level non-README `*.md`. The `Automation-Pipeline-Examples/` tree and the `docs/` folder ride along with the manifest, so any time their content is updated AFTER a publish, a republish is required for consumers to see the aligned narrative. v0.7.97 also adds this verification to the maintainer-facing `docs/RELEASE-PROCESS.md` and the version-bump checklist.

---

### What's New in v0.7.96

v0.7.96 is a focused operator-visibility release driven by a side-by-side comparison of the bundled Step.7 + Step.8 pipelines against the Azure portal Update Manager view used by the Azure Local product team. Three gaps were closed in lock-step: the in-flight monitor (`Step.7 monitor-updates`) now surfaces the `Status` column and the deepest nested `errorMessage` for every in-flight run, plus a new `StepError` JUnit failure type that fires on stuck-but-still-fresh runs (the Arizona-shaped case where a step has been in `Status='Error'` for 19+ days but the run's overall elapsed time is still under `long_running_threshold_hours`); the daily snapshot (`Step.8 fleet-update-status`) reworks the Primary Status bucket cascade to align with the Azure portal Update Manager `state` filter by promoting `NeedsAttention` into the `Update Failed` bucket, adding a new `Action Required` bucket for `PreparationFailed` (with its own actionable guidance because the run never started so re-arming is required), and folding `PreparationInProgress` into `Update In Progress`; and both pipelines now render Cluster Name and Update Name cells in their markdown summaries as `<a href="https://portal.azure.com/...">` deep-links to the cluster's Updates blade and the single-instance update-run history view, matching the Azure portal's hyperlink behaviour.

**New `Status` + `ErrorMessage` columns on every update run.** `Format-AzLocalUpdateRun` now emits both columns derived from `properties.progress.status` and the deepest `errorMessage` walked from the nested `properties.progress.steps[]` tree (uses a `coalesce(e9Msg..e1Msg)` recursion via the new private `Get-DeepestErrorMessage` helper that walks all 9 nesting levels of the ARM steps tree). The columns appear in `update-monitor.csv`, the in-flight markdown table, the always-shown Failed-runs block, and the `update-runs.csv` artefact emitted by Step 8.

**Step.7 new `StepError` JUnit failure type.** Runs whose deepest step status is `Error` but whose overall elapsed time is below `long_running_threshold_hours` (default 6h) now generate a JUnit `<failure failureType='StepError'>` entry so they surface in the Checks tab WITHOUT needing the long-running threshold to fire. Two new `GITHUB_OUTPUT` values support this: `STEP_ERRORED` (count of runs that hit a step error inside the threshold) and `UNRESOLVED_FAILURES` (count of Failed runs surfaced from `Get-AzLocalUpdateRunFailures`). The always-shown Failed-runs block in the Step.7 markdown summary carries an MS Learn TSG link.

**Step.8 new `Action Required` Primary Status bucket.** The Primary Status bucket cascade is now `Update Failed > Action Required > Health Failure > SBE Prerequisite Blocked > Update In Progress > Ready for Update > Up to Date > Needs Investigation`. `PreparationFailed` lands in the new `Action Required` row with separate actionable prose. Surfaces via: (1) new `<property name="primaryActionRequired" value="$stActionRequired"/>` JUnit attribute on the primary testsuite; (2) per-testcase `failureType='PreparationFailed'` instead of the generic `UpdateFailure`; (3) new `ACTION_REQUIRED` `GITHUB_OUTPUT` (`actionRequired` pipeline variable in ADO); (4) `Summary.UpdateFailures` + `Summary.ActionRequired` rolled-up bucket counts in `readiness-status.json`; (5) new "Action Required (PreparationFailed)" row in the Primary Status markdown table with its own callout.

**Portal deep-links in both Step.7 and Step.8 markdown tables.** Cluster Name cells render as `<a href="https://portal.azure.com/#@/resource{ClusterResourceId}/updates">ClusterName</a>` and Update Name cells render as `<a href="https://portal.azure.com/#view/Microsoft_AzureStackHCI_PortalExtension/SingleInstanceHistoryDetails.ReactView/resourceId/{enc}/updateName/{name}/updateRunName/{runId}/refresh~/false">UpdateName</a>`. Verified working in the Arizona + Orlando smoke tests this release cycle.

8 new Pester tests added (4 covering `Format-AzLocalUpdateRun` Status + ErrorMessage emission, 4 covering `Get-DeepestErrorMessage` recursive walk semantics including the L3-deepest case used in production). Full suite green at 794 / 0 / 1. All 18 bundled `Step.{0..8}.yml` templates bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.95'` to `'0.7.96'`; the GH Step.8 `run:` block measures 17,877 chars (under the repo's 18,000-char ceiling guard).

---

### What's New in v0.7.88

v0.7.88 was a focused Step.8 step-summary readability polish. The bundled `Step.8 fleet-health-status` GitHub Actions and Azure DevOps pipelines now render the per-cluster fleet rollup right below the KPI summary - above the failure breakdown - so an operator triaging unhealthy clusters sees Health status, Update Status, current version, SBE version, Azure Connection state, last-check timestamp + age and node count at a glance, then dives into `Health Check Failures By Reason` and `Detailed Results` for context. The fleet-rollup column that used to be labelled `Age (days)` was renamed to `Health Check Age (days)`, which is unambiguous next to the `Last Checked` timestamp column - the value is the age in days of the cluster's last 24-hour Azure Stack HCI health-check result (sourced from `Get-AzLocalFleetHealthOverview.HealthResultsAgeDays`), with negative values continuing to mean "no LastChecked timestamp at all".

**Step.8 markdown section order.** Both GH + ADO pipelines now emit: **KPI summary table -> `### Fleet Health Overview (fleet rollup)` -> `### Health Check Failures By Reason (most widespread first)` -> `### Detailed Results (per-cluster, per-failure)` -> `### Reports Available`**. Previously the fleet rollup sat at the very end of the summary, requiring operators to scroll past every failure row to reach the per-cluster overview.

**Step.8 fleet-rollup column rename.** `Age (days)` -> `Health Check Age (days)`. The previous label was ambiguous (could plausibly mean cluster age, node age, current-version age, or update-readiness age); the new label is unambiguous and matches the underlying `Get-AzLocalFleetHealthOverview.HealthResultsAgeDays` data source.

All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.87'` to `'0.7.88'`. Only `Step.8_fleet-health-status.yml` had inline-script content changes; the other 17 were pin-only bumps.

---

### What's New in v0.7.87

v0.7.87 shipped a focused architectural hardening of the `Step.4 Fleet Connectivity Status` pipeline. The 285-line markdown renderer that previously lived inline as a ~22 KB `pwsh` `run:` body in both the GitHub Actions and Azure DevOps Step.4 YAML templates was extracted into a new public module function. This gave both pipelines a single source of truth, made the markdown layout unit-testable in Pester, and kept every bundled `run:` body comfortably below the GitHub Actions 21,000-char expression-length cap. A new Pester regression test enforces an 18,000-char ceiling on every `run:` (and `script:`) block in every bundled GitHub Actions YAML so any future regrowth is caught in CI before it can hit production parsing.

**New public function `New-AzLocalFleetConnectivityStatusSummary`.** A pure markdown renderer that consumes the seven CSV reports produced earlier in the Step.4 pipeline by `Get-AzLocalFleetConnectivityStatus` (or the equivalent in-memory object arrays via the `FromObjects` parameter set) plus an explicit `-Counts` hashtable of KPI totals. It is a pure renderer over already-collected data - no Azure CLI, no Resource Graph extension, no `Az.*` modules required, no re-querying Azure. Returns the markdown string by default; `-OutputPath` writes UTF-8 no-BOM and `-PassThru` lets you combine both. ASCII source with Unicode emoji icons emitted via `[char]0xNNNN`. The function shipped with comprehensive Pester unit-test coverage (parameter validation, required-key validation on `-Counts`, markdown structure, empty-input placeholders, orphan-ARB section conditionality, multi-cluster-per-RG ARB matching, output-path semantics, CSV-based input with graceful missing-CSV handling).

**Step.4 GH + ADO YAML refactor.** The 283-line, 20,460-char inline renderer in `github-actions/Step.4_fleet-connectivity-status.yml` was replaced with a 23-line body that calls `New-AzLocalFleetConnectivityStatusSummary`. The file shrunk from 863 to 603 lines and the renderer step's `run:` body became ~1,083 chars - a 95% reduction. The Azure DevOps twin (`azure-devops/Step.4_fleet-connectivity-status.yml`) got the equivalent refactor so both pipelines call the same module function. As a side-effect this fixed a pre-existing structural anomaly in the ADO YAML: the Display Summary step's `pwsh` literal block scalar had silently absorbed the trailing `displayName:` / `condition:` / `env:` keys AND the subsequent `PublishTestResults@2` task (because those lines sat at indent 12-16 while the block scalar base indent was 8). The parsed ADO pipeline used to have only 10 steps; in v0.7.87 it had 11 steps, with `Display Fleet Connectivity Summary` and `Publish Fleet Connectivity JUnit Diagnostics` now real, distinct ADO tasks that actually run.

**21K-cap regression guard in Pester.** A new `Regression v0.7.87: bundled GitHub Actions YAML run: blocks stay under GitHub 21,000-char expression cap` Describe block enumerates every `run:` and `script:` literal block scalar in every bundled `github-actions/Step.{0..8}.yml` template and asserts each is below 18,000 chars. The 3K headroom under the 21K cap covers future feature growth and possible future re-introduction of `${{ }}` substitutions (the cap applies to the post-substitution length of any `run:` body that contains at least one `${{ }}`). Two additional asserts verify both the GH and ADO Step.4 YAMLs CALL the new renderer function and do NOT inline the `## Fleet Connectivity Status Summary` heading.

All 18 bundled `Step.{0..8}.yml` templates (9 GitHub Actions + 9 Azure DevOps) bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.86'` to `'0.7.87'`.

---

### What's New in v0.7.86

v0.7.86 was a **documentation follow-up** to v0.7.85 - no code changes anywhere in the module, no YAML inline-script changes. While reviewing PR #56 before merging v0.7.85, the `Automation-Pipeline-Examples` README + appendix were found to still describe the seven-pipeline layout from before `Step.4 Fleet Connectivity Status` was inserted in v0.7.79 (and before `Step.0 Authentication Test` was added in v0.7.70). The follow-up audit also caught two related cross-doc gaps: the `ITSM/README.md` setup guide had never been updated when Step.4 shipped opt-in ServiceNow ticketing in v0.7.76, and the CI/CD `Automation-Pipeline-Examples/README.md` had no direct cross-link to the top-level `docs/concepts.md` / `docs/rbac.md` / `docs/troubleshooting.md` references. The bundled YAMLs themselves were correct; only the human-facing setup runbooks were stale. v0.7.86 republished the module with the corrected docs: section 1.1 mapping table re-rendered so `Step.4 = Fleet Connectivity Status` (off-by-one row labels corrected for Step.5..Step.8); section 6.6 fleet-monitoring narrative now covers all three daily steady-state pipelines (Step.4 + Step.7 + Step.8) including the v0.7.85 reconciliation enhancements and the four ARM/ARG scopes Step.4 reads; section 13 file layout re-listed in `Step.0..Step.8` numeric order with descriptive comments + cron schedules; `Automation-Pipeline-Examples/docs/appendix-pipelines.md` renumbered from `A.1..A.7` to `A.0..A.8` so the appendix section number always matches its `Step.N_*.yml` filename, with two new sections added (`A.0 Authentication Validation and Subscription Scope Report` and `A.4 Fleet Connectivity Status`); `ITSM/README.md` updated to list four ITSM-wired pipelines (Step.4 alongside Step.6/Step.7/Step.8) including a v0.7.76 callout documenting the Step.4 wiring and per-resource `UpdateName` patterns. All 18 bundled `Step.{0..8}.yml` templates bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.85'` to `'0.7.86'` (pin-only; no inline-script changes).

---

### What's New in v0.7.85

v0.7.85 was a **documentation enhancement** for the Step.4 fleet-connectivity step-summary - no code changes in `Get-AzLocalFleetConnectivityStatus` itself. After v0.7.84 fixed the underlying correctness bugs, a production operator running Step.4 against a 20-cluster fleet saw `Node coverage delta = -6` (cluster-reported = 38, Arc-tagged = 44) and asked what it meant. The previous label `Arc-joined physical nodes` (implying a join was computed) plus a one-directional caption (which only described positive-delta causes) made it harder than necessary to interpret. v0.7.85 made the table self-explanatory and actionable so operators could act on non-zero numbers without external context.

**Column rename + Notes column rewrites in the `Node + ARB Coverage Reconciliation` table.** `Arc-joined physical nodes` -> `Arc-tagged physical nodes`. The previous label was a misnomer: this value has never been a join against `cluster.reportedProperties.nodes` - it is the raw count of `microsoft.hybridcompute/machines` carrying `properties.detectedProperties.cloudprovider=AzSHCI` and `kind!=HCI`. The Notes column now explicitly calls out that the two counts come from independent KQL queries and can legitimately disagree in EITHER direction. Stale wording on `Cluster-reported node count (sum)` that still referenced the pre-v0.7.84 non-existent `nodeCount` scalar has been replaced with the correct `Sum of array_length(properties.reportedProperties.nodes) across all clusters`. The `Node coverage delta` Notes are now BIDIRECTIONAL: POSITIVE = clusters claim more nodes than Arc has (Arc-onboarding lag / deleted Arc resource / missing `AzSHCI` provider tag / stale `cluster.reportedProperties.nodes` array); NEGATIVE = Arc has more `AzSHCI`-tagged machines than clusters claim (orphan/decommissioned Arc resource / pre-staged-but-not-yet-joined node / mis-tagged non-cluster machine).

**New `### How to interpret + act on a non-zero reconciliation` subsection appended after the table.** Per-direction remediation lists for `Node coverage delta` POSITIVE (Arc-onboarding lag -> wait + re-run; Arc resource deleted -> `azcmagent connect`; missing `AzSHCI` tag -> re-run onboarding extension; stale `cluster.reportedProperties.nodes` -> compare against `Get-ClusterNode`) and NEGATIVE (orphan/decommissioned Arc resource -> delete or re-attach; pre-staged node -> wait for commissioning; mis-tagged machine -> clear the tag). Includes an inline Resource Graph query template to enumerate the specific Arc machines causing a NEGATIVE node coverage delta. Also documents `Clusters without an ARB > 0` causes (ARB never deployed / ARB deleted but cluster present / RP not registered) and `Orphan ARBs > 0` causes (cluster deleted but ARB not cleaned up / scope-list drift / ARB for an excluded cluster).

Applied identically to both bundled Step.4 YAMLs (`Automation-Pipeline-Examples/github-actions/Step.4_fleet-connectivity-status.yml` and `Automation-Pipeline-Examples/azure-devops/Step.4_fleet-connectivity-status.yml`); all 18 bundled `Step.{0..8}.yml` templates bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.84'` to `'0.7.85'`. Only Step.4 had inline-script content changes; the other 17 were pin-only bumps.

---

### What's New in v0.7.84

v0.7.84 was a **HOTFIX** for 3 read-path correctness bugs in `Get-AzLocalFleetConnectivityStatus` (the cmdlet that powers the Step.4 fleet-connectivity summary), surfaced against a real 20-cluster fleet via the same GitHub Actions Step.4 run on 2026-05-21 that validated the v0.7.83 hotfix. **Bug A** - the cluster `Nodes` column was 0 for every cluster (and `Node coverage delta` therefore equalled `-(Arc-joined node count)`) because the code read `properties.reportedProperties.nodeCount` which does NOT exist in the Azure Local cluster ARG schema; the correct property is the `properties.reportedProperties.nodes` ARRAY. **Bug B** - the `Non-Connected Machines` table `ClusterName` column was corrupted to a single character (cluster `Mobile` -> `e`, `alrs-cc` -> `c`, etc.) because `[string]($clusterId -split '/')` joined the array elements with spaces and `[-1]` then returned the last CHARACTER of that joined string instead of the last array element (same scalar-collapse bug class as v0.7.82/v0.7.83). **Bug C** - the `Azure Resource Bridges` table `DaysSinceLastModified` was `-1` for EVERY ARB because (1) ARG's default `resources` response often stripped `systemData` (the KQL now explicitly extends `lastModifiedAt`) and (2) Running ARBs were short-circuited to `-1` as an opaque sentinel (the short-circuit was dropped so real days is shown for all ARBs; `-1` is now reserved only for genuinely missing/unparseable timestamps). A new Pester `Regression v0.7.84` Describe block added 10 tests across 3 contexts: static regex guards on the source file detect regression of any of the three fixes, execution tests mock realistic ARG payloads (3-node `Mobile` cluster, Disconnected Arc machine with real ARM-ID `parentClusterResourceId`, Running + Offline ARBs with `systemData.lastModifiedAt` set 5/10 days ago), and a negative-control test re-executes the pre-fix `[string](array)[-1]` shape and proves it still returns `'e'` for cluster `Mobile`. Also new: **cross-call ARG throttle cooldown in `Invoke-AzResourceGraphQuery`** - complements the v0.7.68 per-page retry loop with cross-call coordination so a throttle event observed in one call causes subsequent calls to voluntarily sleep out a short cooldown window on entry. Cooldown duration scales with `-RetryBaseSeconds` (capped at 10s) and the consecutive-throttle counter decays by 1 on every clean call. New `$script:LastResourceGraphCrossCallCooldownSeconds` diagnostic and `-DisableCrossCallCooldown` switch; Pester `Cross-call throttle coordination (v0.7.84)` Context added 4 tests. The existing v0.7.79 cluster mock fixture used the wrong-named scalar `nodeCount = 2` and had silently masked Bug A in unit tests for multiple releases; corrected to the realistic `nodes = @(...)` array shape. All 18 bundled `Step.{0..8}.yml` templates bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.83'` to `'0.7.84'` (no inline-script changes outside the cmdlet itself). **Known follow-up** (v0.7.85): production review of the corrected v0.7.84 Step.4 output revealed that the `Node + ARB Coverage Reconciliation` table Notes column described the delta as one-directional and labelled the Arc count as `Arc-joined physical nodes` (implying a join was computed). v0.7.85 reworded the table to be bidirectional and added a `### How to interpret + act on a non-zero reconciliation` subsection - see v0.7.85 release notes.

---

### What's New in v0.7.83

v0.7.83 was a **HOTFIX** for a runtime crash in the Step.4 fleet-connectivity ARB JUnit-XML generation that shipped in v0.7.82. When an Azure Resource Bridge failure case had a single (non-comma-separated) `ClusterId`, the inline script blew up with `Method invocation failed because [System.Char] does not contain a method named 'Trim'`. The buggy two-line pattern `$clusterIdList = if ($r.ClusterId) { @(($r.ClusterId -split ',\s*') | Where-Object { $_ }) } else { @() }; $clusterIdList[0].Trim()` hit a PowerShell collection-unwrap gotcha: when `Where-Object` yielded a single scalar, the `@()` wrap was silently undone by the `if`-as-expression, `$clusterIdList` collapsed to a bare `[string]`, indexing returned `[char]`, and `.Trim()` threw at runtime. Multi-cluster RG ARBs (comma-separated `ClusterId`) were unaffected, which is why this only surfaced in production against a real customer fleet. Fixed in both Step.4 YAMLs by adding a `[string[]]` cast on `$clusterIdList` (which forces array shape regardless of element count) plus a defence-in-depth `[string]` cast at the `[0]` indexing site. The same `if-@-else-@()` shape existed twice more per file in the orphan-ARB reconciliation block; both call sites were also `[string[]]`-cast. A new Pester regression block `Regression v0.7.83: Step.4 ARB inline script handles single-cluster ClusterId without [char].Trim() bug` (9 tests) re-executed the exact buggy pattern against single-cluster, multi-cluster, null, and empty `ClusterId` payloads, plus a negative-control test that proved the pre-fix shape still threw. All 18 bundled `Step.{0..8}.yml` templates bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.82'` to `'0.7.83'` (no code changes outside Step.4). **Known issue** (fixed in v0.7.84): production validation of the v0.7.83 hotfix surfaced 4 additional read-path correctness bugs in `Get-AzLocalFleetConnectivityStatus` - see v0.7.84 release notes for details.

---

### What's New in v0.7.82

v0.7.82 packaged the custom RBAC role definition as a **bundled JSON file** so operators no longer needed to copy-paste from the README. The new file `Automation-Pipeline-Examples/azlocal-update-management-custom-role.json` contains the canonical `Azure Stack HCI Update Operator` role definition (13 actions: the 12 used by current cmdlets plus `Microsoft.HybridCompute/machines/extensions/read` reserved for future Arc-machine extension reporting). `Automation-Pipeline-Examples/README.md` Section 4.1 was updated to point at the bundled file as the first install path. A new callout in Section 4.1 and `docs/rbac.md` flagged the JSON-shape difference between the **CLI / PowerShell** format (`az role definition create`, `New-AzRoleDefinition`) and the **Azure portal Edit-a-custom-role JSON tab** format (ARM resource representation wrapped in `properties`), so operators do not hit `Malformed JSON: "properties" property not present` when pasting into the portal. The same callout also flagged a **UTF-8 BOM gotcha**: `az`'s Python JSON parser rejects BOM-prefixed files with `Expecting value: line 1 column 1 (char 0)`; the shipped file was BOM-free. All 18 bundled `Step.{0..8}.yml` templates bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.81'` to `'0.7.82'`. **Known issue** (fixed in v0.7.83): the multi-cluster-RG ARB handling added to Step.4 in v0.7.82 introduced a `[System.Char] does not contain a method named 'Trim'` crash on single-cluster ARBs - see v0.7.83 release notes for details.

---

### What's New in v0.7.81

v0.7.81 was a documentation-only release focused on the CI/CD permission guidance. The previous `Automation-Pipeline-Examples/README.md` presented the least-privilege custom role (`Azure Stack HCI Update Operator`) and the built-in `Azure Stack HCI Administrator` role as roughly equal "Option A / Option B" choices, biasing readers toward the over-permissive built-in role for labs. v0.7.81 pivoted every permission code path to custom-role-first for every environment; the built-in role was framed as a temporary fallback for tenants where the operator cannot create custom roles, hidden behind `<details>` / commented-out alternatives. Sections 3.1 Step 2, 3.2 (ADO), 3.3 (Managed Identity), 3.4 (SP+secret), section 4 intro, section 4.2 and section 11 were reframed; section 4.1 gained an expanded `Migration tip (built-in -> custom role, no downtime)` block including the `az role assignment delete` cleanup command. All 18 bundled `Step.{0..8}.yml` templates bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.80'` to `'0.7.81'`. No module code changes.

### What's New in v0.7.80

v0.7.80 was a documentation-fix release. The custom RBAC role definition in [`docs/rbac.md`](rbac.md) (used by Step.4 pipeline service principals) was missing three reads that `Get-AzLocalFleetConnectivityStatus` (added in v0.7.79) needs: `Microsoft.HybridCompute/machines/read`, `Microsoft.AzureStackHCI/edgeDevices/read`, and `Microsoft.ResourceConnector/appliances/read`. Without them the cmdlet still returns the cluster connectivity section but every other section (Arc agents, physical NICs, Azure Resource Bridges) silently returned zero rows because ARG yields an empty `.data` array for resource types the caller cannot read. The doc also gained an "Updating an existing custom role" sub-section so an `az role definition update` keeps the existing role GUID and assignments. No module code changes; pipeline pin bumped from `'0.7.79'` to `'0.7.80'`.

### What's New in v0.7.79

v0.7.79 enabled the **Step.5 daily readiness check** out of the box. The `schedule:` cron block in `Step.5_assess-update-readiness.yml` (GitHub Actions and Azure DevOps) was previously commented out; it is now active at **07:00 UTC daily**. v0.7.79 also introduced `Get-AzLocalFleetConnectivityStatus`, a module cmdlet that replaces the inline ARG queries previously embedded in Step.4 YAMLs and returns a single `[PSCustomObject]` with the seven fleet-connectivity scopes (ClusterRows, ArcSummary, NonConnectedMachines, NicIssues, NicAll, NicStats, ArbRows). No module code changes for the schedule itself; pipeline pin bumped from `'0.7.78'` to `'0.7.79'`.

### What's New in v0.7.78

v0.7.78 is a **targeted hotfix** release focused on Step.4 fleet-connectivity data-shape resilience. This fixes the regression where totals were populated but key fields rendered blank in markdown and JUnit (`ClusterName`, `AgentStatus`, `NicName`, `ArbName`). `Invoke-ArgQuery` now normalizes both ARG response shapes (object rows and tabular `columns + data` rows), Step.4 projections use `coalesce(...)` for non-empty key fields, and JSON export depth is raised to reduce truncation warnings.

### What's New in v0.7.77

v0.7.77 was a small pin-bump release. The bundled `Step.{0..8}.yml` templates (18 files: 9 GitHub Actions + 9 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.76'` to `'0.7.77'`. The pin is drift-detection only; `Install-Module -Force` still installs PSGallery latest at runtime.

### What's New in v0.7.76

v0.7.76 renamed every exported function and private helper from `-AzureLocal*` to `-AzLocal*` to align with the module name and the standard PowerShell module-prefix convention. There are no deprecation aliases (the module is pre-1.0 and has no published external consumers). Search-and-replace `-AzureLocal` -> `-AzLocal` in any pinned scripts.

#### Fixed: Finding 1 P0 - row-collapse via `@(func)` wrap on a `, $arr` return

`Invoke-AzResourceGraphQuery` used `return , $allRows.ToArray()` (the unary-comma trick that keeps the return shape as a single `Object[N]` through pipeline enumeration). 24 callers wrapped the call with `@(Invoke-AzResourceGraphQuery ...)` which collected the function's pipeline output (one wrapper containing the inner array), producing `Object[1]` containing `Object[N]`. Downstream property access then did PowerShell member enumeration and returned arrays-of-strings, so a 136-row update-run result collapsed into a 1-row `ClusterName_=Object[]` mess. Fixed by converting all 24 callers to direct assignment (`$x = Invoke-AzResourceGraphQuery ...`).

#### Fixed: ARM healthCheckResult byte-identical duplicates (bonus)

`Test-AzLocalClusterHealth` and the private `Get-HealthCheckFailureSummary` now dedup byte-identical ARM `healthCheckResult` rows. ARM upstream was observed emitting two byte-identical rows for the same logical health-check finding (same CheckName, Severity, Description, Remediation, TargetResourceName, Timestamp), doubling the displayed CriticalCount. Dedup is by the COMPLETE row tuple (HashSet[string] keyed on `ClusterName | CheckName | Severity | Description | Remediation | TargetResourceName | Timestamp` joined by U+001F UNIT SEPARATOR), so per-node distinct findings with different `targetResourceName` (e.g. `UserStorage_1-Repair` vs `UserStorage_2-Repair`) stay separate.

#### Other findings addressed

- **Finding 2 (test gaps):** new Pester cases for row-collapse, ARM dedup (identical / distinct target / empty), KQL arg-length safety.
- **Finding 3 (SP secret leak):** `Connect-AzLocalServicePrincipal` writes the secret to a temp file with restricted ACL, passes via `Get-Content`, removes it in a `finally` block.
- **Finding 4 + 5 (docs):** main README cut from 3372 to ~600 lines; new `docs/` tree: [`cmdlet-reference.md`](../docs/cmdlet-reference.md), [`concepts.md`](../docs/concepts.md), [`rbac.md`](../docs/rbac.md), [`troubleshooting.md`](../docs/troubleshooting.md), [`release-history.md`](../docs/release-history.md). Pipeline README appendices also extracted to [`Automation-Pipeline-Examples/docs/`](../Automation-Pipeline-Examples/docs/).
- **Finding 6 + 9 (.psm1):** dead-code removed; deliberate `Set-StrictMode -Version 1.0` documented at top of file.
- **Finding 8 (review archive):** internal review notes moved into a gitignored `docs/` location.

#### Documentation conventions (new in v0.7.76)

1. The main README is the entry point; cmdlet / RBAC / release deep-dives live under [`docs/`](../docs/).
2. Only the **current version**'s What's-New stays inline; older entries live in [`docs/release-history.md`](../docs/release-history.md).
3. Each release tag MUST run the demote-to-history step.
4. Day-2 pipeline operators land on [`Automation-Pipeline-Examples/README.md`](../Automation-Pipeline-Examples/README.md); depth lives in [`Automation-Pipeline-Examples/docs/`](../Automation-Pipeline-Examples/docs/).
5. ITSM has its own README under [`ITSM/`](../ITSM/).

### What's New in v0.7.75

v0.7.75 was a **hardening** release on top of v0.7.74. v0.7.74 patched the `Test-AzLocalApplyUpdatesScheduleCoverage` cross-platform-noise bug at the **yml layer** by adding `-Platform GitHubActions` / `-Platform AzureDevOps` arguments to the bundled Step.3 yml templates - but that fix only took effect for consumers who refreshed their yml via `Update-AzLocalPipelineExample`. Consumers whose Step.3 yml was a verbatim pre-v0.7.74 copy still saw both the GitHub Actions snippet AND the Azure DevOps snippet in their Step Summary, because their yml did not pass `-Platform` and the cmdlet's default was `-Platform Both`. v0.7.75 closed that gap by adding the same auto-selection at the **cmdlet layer** so stale yml self-heals at runtime. Pipeline pin bumps to `'0.7.75'`; refresh existing copies via `Update-AzLocalPipelineExample`.

#### Test-AzLocalApplyUpdatesScheduleCoverage auto-detects the CI host platform when -Platform is omitted

When the caller does **not** bind `-Platform`, the cmdlet inspects the well-known CI environment variables and self-selects:

- `$env:GITHUB_ACTIONS -eq 'true'` -> `-Platform GitHubActions` (emit only the GitHub Actions snippet)
- `$env:TF_BUILD -eq 'True'` OR any non-empty `$env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI` -> `-Platform AzureDevOps` (emit only the Azure DevOps snippet)
- Neither set (interactive operator-at-workstation) -> existing `-Platform Both` default preserved (emit both side by side)

Detection is gated on `$PSBoundParameters.ContainsKey('Platform')` so an **explicit** caller value (including an explicit `-Platform Both`) always wins over the auto-detect.

#### Test coverage

Four new Pester tests (AS7-AS10) in the existing `Test-AzLocalApplyUpdatesScheduleCoverage` Describe verify all four auto-detect cases: GH-only when `$env:GITHUB_ACTIONS='true'` + no `-Platform`; ADO-only when `$env:TF_BUILD='True'` + no `-Platform`; both-when-explicit `-Platform Both` overrides auto-detect; both-when-no-env-vars preserves the interactive default. `BeforeEach` / `AfterEach` blocks clear the CI env vars so the tests are hermetic.

#### Pipeline pin bumps + migration

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bumped `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.74'` to `'0.7.75'`. Refresh via:

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

All v0.7.75 changes were backward compatible.

---

### What's New in v0.7.74

v0.7.74 is a **bug-fix + UX** release on top of v0.7.73. It addresses **two distinct findings** raised against v0.7.73 against the same live 20-cluster fleet: **(1)** `Get-AzLocalFleetHealthOverview` started failing with a KQL `ParserFailure: token=<EOF>` at character `2757` because the v0.7.73 query growth crossed the `az graph query -q` argument-truncation threshold (~2.8 KB wire-side); **(2)** the `Step.3 - Apply-Updates Schedule Coverage Audit` recommendation block was reported as "very hard to follow and understand what to do" - it was a four-section advisory but lacked an explicit fix-in-this-order checklist, did not explain *why* each finding mattered, did not include a before/after YAML snippet for missing rings, and shipped a commented-out cron block that operators were copy-pasting verbatim including the `# ` prefixes. Both are fixed. Pipeline pin bumps to `'0.7.74'`; refresh existing copies via `Update-AzLocalPipelineExample`.

### Get-AzLocalFleetHealthOverview `ParserFailure: token=<EOF>` at char 2757 - fixed

The v0.7.73 change (HealthStatus normalisation via `case()`) added ~250 chars of KQL projection, and the v0.7.73 commit also added a six-line `//` KQL comment block above the projection (~470 chars). The combined wire query grew from `~2400` chars (v0.7.72 baseline) to `3115` chars. On Windows the Azure CLI's `az graph query -q <query>` argument layer truncates very long single-arg payloads around the 2.8 KB mark; the truncated query lands mid-projection, so ARG returns:

```json
{
  "error": {
    "code": "BadRequest",
    "details": [
      { "code": "InvalidQuery", "message": "Query is invalid." },
      { "code": "ParserFailure",
        "message": "... characterPositionInLine=2757 token=<EOF> ..." }
    ]
  }
}
```

Symptom: `Step.7 - Fleet Health Status` failed with exit code 1 the moment the cmdlet was invoked. Step.7's separate, shorter "Detail" ARG query (rendered after Overview) was unaffected, which made the failure look like a HealthStatus-projection bug rather than an arg-length bug.

**Fix:** (1) the six `//` KQL comment lines are removed from the here-string and re-expressed as PowerShell `#` source comments above the `$kql` assignment - documentation for the source reader, no wire-side bytes. (2) The `case()` projection is compacted to one line (semantically identical). The wire query is now `2396` chars, back below the v0.7.72 baseline. A new inline `IMPORTANT` source comment above `$kql` flags the constraint so future contributors do not re-introduce it.

Verified end-to-end against the same live 20-cluster fleet: 20 cluster rows returned; HealthStatus distribution preserved from v0.7.73 (`10 Healthy / 7 Critical / 2 Warning / 1 In progress`); Step.7 `HEALTHY_CLUSTERS` output still writes `10` and the Fleet Health Overview table still renders the intended icons.

### Step.3 recommendation block rewritten as a step-by-step remediation guide

Operators reported the v0.7.73 Step.3 output was "very hard to follow and understand what to do, it needs much more detail and step by step for exactly what the operator needs to do to 'fix' the Apply Updates schedules, across the CRON jump for Step 5 and the Config YML file." v0.7.74 adds:

- **Top-of-block "Fix-in-this-order checklist"** when 2+ action sections are emitted, with N+1 ordered bullets that name the file to edit AND the silent-skip consequence of skipping that step (e.g. `Resolve-AzLocalCurrentUpdateRing` returns nothing for missing rings so Step.5 silently skips them; `Test-AzLocalUpdateScheduleAllowed` never opens the gate for uncovered UpdateWindows). The checklist surfaces the order the advisor uses internally (ring diff -> orphans -> unparseable crons -> cron coverage -> re-run) so the operator does not have to derive it from the section headings.
- **`**Why this matters.**` paragraph in every section** that names the specific runtime cmdlet that depends on the configuration being fixed (`Resolve-AzLocalCurrentUpdateRing`, `Test-AzLocalUpdateScheduleAllowed`) and the silent-skip failure mode the operator avoids by following the fix.
- **"How to fix - edit `<file>`" subsection in the missing-rings section** with a full `apply-updates-schedule.yml` skeleton snippet showing the existing `schedule:` block AND a placeholder row PER missing ring (`TODO:` markers on `weeksInCycle`, `daysOfWeek`, `notes`, annotated with the cluster count for the missing ring). The snippet carries an `AzLocal.UpdateManagement v<version> advisor: add row(s) like these <<<` header so it is unambiguous where the operator-edited content begins.
- **Ready-to-paste (uncommented) cron block** in the cron-coverage section. Replaces the prior `# commented` form (which operators were copy-pasting verbatim including the `# ` prefixes). The snippet is now a real `on:` (GitHub Actions) / `schedules:` (Azure DevOps) block, with one cron line per UpdateWindow plus a trailing yaml-`#` annotation showing the rings and cluster count served by each cron.
- **Platform-aware file labels.** When `-Platform` is pinned to a single platform, the text names the exact pipeline file (`.github/workflows/Step.5_apply-updates.yml` vs `.azuredevops/Step.5_apply-updates.yml`) and the exact schedule file (`.github/apply-updates-schedule.yml` vs `.azuredevops/apply-updates-schedule.yml`).
- **Two-choice fix tables for orphaned rings** spell out both options (retag a cluster onto the ring via `Set-AzLocalClusterUpdateRingTag`, OR remove the ring from the schedule file) so operators do not default to deletion when they actually wanted to bring a cluster onto the ring.

### Step.3 pipeline scripts pin `-Platform` so cross-platform noise is gone

`Test-AzLocalApplyUpdatesScheduleCoverage` defaults to `-Platform Both`, which surfaced both the GitHub Actions `schedule:` block AND the Azure DevOps `schedules:` block in every Step.3 run regardless of which CI platform was running it. Both Step.3 yml files now pin `-Platform GitHubActions` (GH) / `-Platform AzureDevOps` (ADO) on both `-View Audit` and `-View Recommend` calls so the Step Summary contains exactly one platform-appropriate snippet.

### Pipeline pin bumps + migration

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.73'` to `'0.7.74'`. Refresh existing copies via the marker-aware merge (preserves operator edits inside `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` marker pairs):

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

### Compatibility

All v0.7.74 changes are backward compatible. `Get-AzLocalFleetHealthOverview` returns the same shape and the same normalised `HealthStatus` vocabulary it returned in v0.7.73 - only the underlying wire query is shorter so it no longer trips the truncation. The v0.7.74 Step.3 yml changes (adding `-Platform GitHubActions` / `-Platform AzureDevOps`) are recommended-but-not-required - the cmdlet still works against the v0.7.73 yml; you just continue to see the cross-platform noise until the yml is refreshed.

### What's New in v0.7.73

v0.7.73 is a **bug-fix** release on top of v0.7.72. `Get-AzLocalFleetHealthOverview` (the cmdlet that powers `Step.7 - Fleet Health Status`) was emitting the raw Azure Resource Graph `properties.healthState` enum values (`Success` / `Failure` / `Warning` / `InProgress` / `NotKnown`) on the `HealthStatus` column, but the cmdlet's own doc comment, the Step.7 pipeline filter `Where-Object { $_.HealthStatus -eq 'Healthy' }`, and the Step.7 Fleet Health Overview rendering `switch ($o.HealthStatus)` all expected the operator-friendly vocabulary `Healthy` / `Critical` / `Warning` / `In progress` / `Unknown`. Symptom: Step.7 reported `Healthy Clusters = 0` against any fleet (live-verified against a 20-cluster fleet: 10 Success / 8 Failure / 2 Warning) and the overview table rendered the `[Success]` / `[Failure]` default-bracket fallback instead of the intended `✅ Healthy` / `❌ Critical` icons. The KQL projection in the cmdlet now normalises in a `case()` clause so the `HealthStatus` column matches the documented contract; no pipeline-sample YAML change is required (the v0.7.72 pin already used the correct vocabulary). Pipeline pin bumps to `'0.7.73'`; refresh existing copies via `Update-AzLocalPipelineExample`.

### Step.7 "Healthy Clusters = 0" against any fleet - fixed

`Get-AzLocalFleetHealthOverview.HealthStatus` is documented (and consumed) as one of `Healthy` / `Critical` / `Warning` / `In progress` / `Unknown`. The KQL projection joining `microsoft.azurestackhci/clusters` with the `updateSummaries` extensibility resource was, however, a one-line passthrough:

```kusto
HealthStatus = iif(isempty(HealthState), 'Unknown', HealthState),
```

The upstream ARG field `properties.healthState` emits the raw ARM enum values `Success` / `Failure` / `Warning` / `InProgress` / `NotKnown`, so `Healthy` / `Critical` / `In progress` literally never appeared on any row. The pipeline filter `Where-Object { $_.HealthStatus -eq 'Healthy' }` therefore matched zero rows and the `HEALTHY_CLUSTERS` GitHub Actions output was always `0`; the rendering switch fell through to the default arm and rendered `[Success]` / `[Failure]` instead of `✅ Healthy` / `❌ Critical`. The projection is now:

```kusto
HealthStatus = case(
    isempty(HealthState),         'Unknown',
    HealthState =~ 'Success',     'Healthy',
    HealthState =~ 'Failure',     'Critical',
    HealthState =~ 'InProgress',  'In progress',
    HealthState =~ 'NotKnown',    'Unknown',
    HealthState
),
```

`Warning` is passed through unchanged, and any unrecognised future state also passes through (rather than being silently bucketed as `Unknown`) so a platform addition stays visible. Verified end-to-end against a live 20-cluster fleet (10 Success / 8 Failure / 2 Warning): after the fix, Step.7 reports `Healthy Clusters = 10`, the Fleet Health Overview table renders the intended icons, and the Step.7 numbers are internally consistent with the Step.6 panel for the same fleet (Step.6 reports `Up to Date = 10` and `Critical Health Status: 12 passed / 8 failed`; the 2 Warning clusters surface as `⚠️ Warning` in the overview without being counted as either Healthy or Critical). The cmdlet's doc comment is also corrected to describe the normalised vocabulary and to spell out the raw-to-normalised mapping for future-proof clarity.

### Pipeline pin bumps + migration

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.72'` to `'0.7.73'`. The Step.0 authentication validation workflow does not pin a module version. **No filter or switch changes required in the pipeline samples** - the v0.7.72 pin already used the correct vocabulary; the v0.7.73 module simply emits values that match. Refresh existing copies via the marker-aware merge (preserves operator edits inside `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` marker pairs):

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

### Compatibility

All v0.7.73 changes are backward compatible. The `HealthStatus` column type (`string`) and column position (third column, after `ClusterName` and `ClusterPortalUrl`) are unchanged - only the value set narrows from the raw ARG enum to the documented operator-friendly vocabulary. Operators who built custom downstream automation that explicitly filtered for the **raw** `Success` / `Failure` / `InProgress` / `NotKnown` strings against the v0.7.70 - v0.7.72 builds must update those filters to the new `Healthy` / `Critical` / `In progress` / `Unknown` vocabulary (or pull the raw value back via a separate ARG call on `updateSummaries.properties.healthState` if they specifically need the platform enum).

### What's New in v0.7.72

v0.7.72 is a **pipeline-samples hotfix** release on top of v0.7.71. Two issues observed when operators ran the v0.7.71 GitHub Actions samples in production: (1) the Step.1 / Step.2 / Step.5 GitHub Actions `Summary` panels rendered empty because the workflows used `Write-Host "<markdown>" >> $env:GITHUB_STEP_SUMMARY` - `Write-Host` writes to the PowerShell information/host stream (6), not stdout (1), so the `>>` redirect appended nothing to the summary file; (2) `AZURE_TENANT_ID` was stored as a GitHub Secret on the same rationale as the v0.7.71 `AZURE_SUBSCRIPTION_ID` treatment - a public ARM/AAD identifier, not a credential. Both are fixed. **No PowerShell source files changed** - this release is scoped to pipeline-sample YAMLs and Markdown docs. Refresh existing copies via `Update-AzLocalPipelineExample`.

### Step.1 / Step.2 / Step.5 GitHub Actions `Summary` blocks now render content (was blank)

Across these three workflows, 62 `Write-Host "<markdown>" >> $env:GITHUB_STEP_SUMMARY` lines were silent no-ops because `Write-Host` emits to PowerShell's information stream (stream 6), not stdout (stream 1). The file-redirect operator `>>` only attaches to stdout, so the GitHub Actions Summary file received an empty append on every line. The job log printed the markdown to the runner console (where operators do not normally look) but the GitHub Actions Summary panel - the canonical post-run report surface - rendered blank. All 62 lines now use the bare-string-to-stdout form (`"<markdown>" >> $env:GITHUB_STEP_SUMMARY`), so the totals/tables/actions-required block coded in v0.7.71 finally surface in the GitHub Actions UI. Affected:

- **Step.1**: cluster-inventory totals + UpdateRing distribution.
- **Step.2**: UpdateRing tag-management settings + dry-run notice.
- **Step.5**: update-application readiness/results matrix + actions-required block + `no-clusters-ready` job summary.

ADO pipelines were unaffected (they use the `##vso[task.uploadsummary]` mechanism, not stdout redirection).

### GitHub Actions: AZURE_TENANT_ID is now a Variable, not a Secret

All 8 GitHub Actions `Step.*.yml` workflows (including the four commented-out legacy `azure/login@v3` `creds:` JSON examples in Step.1 / Step.2 / Step.5) now read the Entra ID tenant id from `vars.AZURE_TENANT_ID` instead of `secrets.AZURE_TENANT_ID`. Rationale matches the v0.7.71 `AZURE_SUBSCRIPTION_ID` switch: the tenant id is a public ARM/AAD identifier - it is rendered in workflow telemetry on every `azure/login@v3` run, present in the OIDC token issuer URL, and visible to anyone with read access to the App Registration - not a credential. It is consumed in exactly one place: the `tenant-id:` input to `azure/login@v3`, which exchanges the OIDC token for an Azure AD token in the named tenant. It is **NOT** used to scope Azure Resource Graph queries and is **NOT** interpolated into portal deep-link URLs. Treating it as a Variable also means it appears plaintext in workflow logs (matching its non-sensitive nature) and removes the need for an extra Secret rotation in tenants that already track it as a Variable. Steady-state setup is now **one repo-level Secret** (`AZURE_CLIENT_ID`) and **two repo-level Variables** (`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`); see updated docs in `Automation-Pipeline-Examples/README.md`. Azure DevOps pipelines authenticate via a service connection and need no change (the connection itself stores `tenantId`).

### Pipeline pin bumps + migration

All 14 `Step.{1..7}.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.71'` to `'0.7.72'`. The Step.0 authentication validation workflow does not pin a module version. Refresh existing copies via the marker-aware merge (preserves operator edits inside `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` marker pairs):

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

GitHub Actions operators must also create `AZURE_TENANT_ID` as a **repository Variable** (`gh variable set AZURE_TENANT_ID --body <tenantId>`) and delete the existing `AZURE_TENANT_ID` **Secret** to avoid drift between the two values.

### Compatibility

All v0.7.72 changes are backward compatible. No cmdlet signatures or output shapes change. The Variable migration is a per-tenant setup change (GitHub Actions only).


### What's New in v0.7.71

v0.7.71 is a **bug-fix + UX polish** release on top of v0.7.70. Two render-correctness fixes (Step.3 markdown rendering as a code block, Step.4 critical-count under-reporting as 0), one new action-required section in `Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend` for unparseable cron expressions, hyperlinked Cluster Name + collapsible Verbose Error in the Step.6 Update Run History table, and the AZURE_SUBSCRIPTION_ID Secret -> Variable migration for GitHub Actions samples. All changes are additive over v0.7.70; no behaviour change for callers that don't read the new columns.

### Step.3 markdown render fix (was rendering as one grey code block)

`Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -ExportPath *.md` was wrapping the multi-section snippet inside an outer ```yaml ... ``` fence. From v0.7.69 onwards the snippet itself carries markdown headings, action-required tables, AND its own **inner** ```yaml ... ``` fence around just the cron block. CommonMark fence-matching is by triple-backtick count: the outer ```yaml opened fence A; the inner ``` closed fence A; the outer ``` then **opened a new fence that was never closed**. Result: every markdown element the Step.3 pipeline appended after the recommend block (`### Audit Detail - Cron coverage` table, `### Reports Available` list, timestamp) was swallowed into the unclosed fence and rendered as a single grey monospace code block. The cmdlet now emits the snippet verbatim - the inner pair stays balanced, and downstream content renders as proper markdown again.

### Step.4 critical-count under-reporting fix (was 0, should be N)

`Step.4_assess-update-readiness.yml` (GH + ADO) was reporting `Critical health failures: 0` in the markdown summary while the JUnit XML showed 46 critical findings. Root cause: the pipeline was filtering `$health | Where-Object { $_.Severity -eq 'Critical' }`, but `Test-AzLocalClusterHealth -PassThru` returns **per-cluster summary objects** (`ClusterName`, `HealthState`, `Passed`, `CriticalCount`, `WarningCount`, `Failures` (nested array)), NOT flat finding rows. `Severity` lives on items inside the nested `Failures` array; the outer summary has `CriticalCount` instead. The pipeline now aggregates correctly via `($health | Measure-Object -Property CriticalCount -Sum).Sum` and counts affected clusters via `@($health | Where-Object { [int]$_.CriticalCount -gt 0 }).Count`.

### Step.3 `-View Recommend` - new "Action required - simplify unparseable cron expression(s)" section

When one or more YAML cron lines used syntax the advisor cannot evaluate (DayOfMonth restrictions, step values, named day-of-week tokens), the Audit view surfaced them as `UnparseableCron` rows but the Recommend view ignored them - the operator had to cross-reference the Audit Detail table to find each one. `-View Recommend` now emits a new `## Action required - simplify unparseable cron expression(s)` section between the schedule-fix sections (`add these rings`, `prune orphaned rings`) and the cron-coverage section. The table lists every offending cron with its source `file:line` and the parser's error message so the operator can rewrite the line directly from the Step Summary. Sequenced **before** cron coverage so parser-blind crons are fixed BEFORE the operator accepts the cron-coverage recommendation (which may otherwise over-suggest entries that duplicate what an already-correct-but-unparseable line is doing). When only one action overall applies the `(N of M)` numbering prefix is still dropped.

### Step.6 Update Run History table - Cluster portal link + collapsible Verbose Error

The `### Update Run History and Error Details` markdown table in the Step.6 pipeline summary gains two UX upgrades:
- **Cluster Name** renders as a `[ClusterName](portalUrl)` markdown link so the operator can jump straight to the Azure portal cluster blade. The per-row `ClusterPortalUrl` is now projected directly by `Get-AzLocalUpdateRunFailures` (new property in v0.7.71, see below) so the link is fleet-wide accurate (each row carries its own subscriptionId-bearing resource id).
- **Verbose Error Details** renders inside an inline `<details><summary>Show error</summary><br><code>...</code></details>` block so the full parser/orchestrator stack is preserved (no more 250-char truncation) but the table stays scannable - rows expand on click. HTML-special chars (`<`, `>`, `&`) are escaped to keep the renderer honest; newlines collapse to `<br>` so multi-line stack traces remain readable inside the collapsible block; pipes are escaped so the table row stays intact.

Both changes apply to GH Actions and Azure DevOps twins.

### `Get-AzLocalUpdateRunFailures` - new `ClusterPortalUrl` property

Every output row now carries a `ClusterPortalUrl` property (`https://portal.azure.com/#@/resource{ClusterResourceId}`) alongside the existing `UpdateRunPortalUrl`. Consumed by Step.6 to render Cluster Name as a deep link, and available to any other consumer that wants a cluster portal link without rebuilding the URL.

### GitHub Actions: AZURE_SUBSCRIPTION_ID is now a Variable, not a Secret

All 8 GitHub Actions `Step.*.yml` workflows now read the Azure subscription id from `vars.AZURE_SUBSCRIPTION_ID` instead of `secrets.AZURE_SUBSCRIPTION_ID`. The value is consumed **ONLY** by `azure/login@v3` to set the default `az account` context for the small subset of cmdlets that REQUIRE a single-subscription default. It is **NOT** used to scope Azure Resource Graph queries (the module's `Invoke-AzResourceGraphQuery` helper omits `--subscriptions` when no `-SubscriptionId` is supplied, so ARG runs fleet-wide against every subscription the federated identity can read) and it is **NOT** interpolated into portal URLs (every cmdlet projects `subscriptionId` per-row from ARG and builds portal deep-links from that, so each link points to the cluster's actual subscription regardless of the workflow's default context). Treating the id as a Variable also means it appears plaintext in workflow logs, matching its public non-sensitive nature, and removes the need for an extra Secret rotation in tenants where the value already lives in a tenant-scope Variable. Azure DevOps pipelines were already authenticating via a service connection and need no change.

### Pipeline pin bumps + migration

All 16 `Step.*.yml` files (8 GitHub Actions + 8 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.70'` to `'0.7.71'`. Refresh existing copies via the marker-aware merge (preserves operator edits inside `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` marker pairs):

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

### Compatibility

All v0.7.71 changes are backward compatible. The new `ClusterPortalUrl` property on `Get-AzLocalUpdateRunFailures` is additive; the new `## Action required - simplify unparseable cron expression(s)` section in `-View Recommend` only renders when unparseable cron lines exist; the GH Variable switch is a per-tenant setup change (see updated docs in `Automation-Pipeline-Examples/README.md`).

### What's New in v0.7.70

v0.7.70 is the **Step.0 recurring authentication audit + Step.6 Update Run History section + Step.6 manifest-anchored rolling support window + Step.3 dual-section UX + Step.7 fleet-health hyperlinks** release, plus two new exported cmdlets - `Get-AzLocalFleetHealthOverview` (ARG-first fleet-scale view of cluster health and update status) and `Get-AzLocalLatestSolutionVersion` (unauthenticated probe of the Microsoft Azure Local public solution-update catalog at `aka.ms/AzureEdgeUpdates`, used by Step.6 to anchor the SupportStatus column on the upstream release calendar). All changes are additive over v0.7.69; no behaviour change for callers that don't read the new columns.


### Step.0 repositioned as a recurring audit: Authentication Validation and Subscription Scope Report

`Step.0_authentication-test.yml` (GitHub Actions + Azure DevOps twins) is renamed from "Authentication Validation Test" to **"Step.0 - Authentication Validation and Subscription Scope Report"** and repositioned from a one-shot smoke test into a **recurring audit** intended to be re-run monthly (or after any RBAC change in the tenant). The pipeline now emits:
- A **JUnit XML** report (`auth-report.xml`) with three testsuites - **Authentication**, **Subscription Scope** (one testcase per accessible subscription, plus a count testcase), and **Resource Graph Reachability** (cluster count visible to the pipeline identity). Rendered in the GitHub Checks UI via `dorny/test-reporter@v3` and in the Azure DevOps **Tests** tab via `PublishTestResults@2`.
- A **markdown summary** at the top of every run with `Count of subscriptions = N` and a per-subscription detail table (Name / SubscriptionId / TenantId / State). Written to `$GITHUB_STEP_SUMMARY` on GitHub Actions and uploaded via `##vso[task.uploadsummary]` on Azure DevOps.
- A `auth-report` artifact (XML + `subscriptions.json` + `subscriptions.csv`) for ITSM / dashboard ingest.

Drift in the subscription scope visible to the pipeline identity is the earliest signal that downstream fleet reports are about to silently under- or over-count clusters, which is why the cadence is recurring rather than one-shot.

### Step.6 Fleet Update Status pipeline - new "Update Run History and Error Details" section

A new `<testsuite name="Update Run History and Error Details">` testsuite in the Step.6 JUnit XML and a matching `### Update Run History and Error Details` markdown table in the run summary surface up to 25 of the most recent unresolved Failed update runs across the fleet (last 30 days). Each row links to the Azure portal `SingleInstanceHistoryDetails` deep-link and includes Status / CurrentStep / Duration / LastUpdated / DeepestErrMsg for at-a-glance triage. Sourced from `Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved` (ARG-first, fleet-scale).

### Step.6 Fleet Update Status pipeline - new "Overall Fleet Update Status (Version Distribution)" section with manifest-anchored rolling support window

A new `<testsuite name="Fleet Version Distribution">` testsuite is emitted as the **first** child of `<testsuites>` (before `AzureLocalFleetUpdateStatus`) and a matching `### Overall Fleet Update Status (Version Distribution)` markdown section is prepended to the run summary (above `### Critical Health Status`). One row per distinct `CurrentVersion` reported by `Get-AzLocalClusterUpdateReadiness`, sorted by cluster count descending, with columns: Version / YYMM / SupportStatus / Cluster Count / Percentage / Clusters.

`SupportStatus` uses a **rolling 6-month YYMM window anchored on the Microsoft public catalog** when reachable. The Step.6 step calls the new `Get-AzLocalLatestSolutionVersion` cmdlet (see below) to fetch the latest released solution version's YYMM from `https://aka.ms/AzureEdgeUpdates` and seeds a calendar-stepped 6-month window from it (e.g. latest YYMM `2604` -> `2604,2603,2602,2601,2512,2511`). As soon as Microsoft publishes any release with a newer YYMM, the window slides forward and the oldest in-window YYMM falls out automatically - independent of what is installed in the fleet. The JUnit testsuite carries `supportSource` / `latestReleasedYymm` / `latestReleasedVersion` / `manifestUrl` / `manifestFetchedAt` properties; the markdown summary annotates which anchor source was used and (on success) prints the latest released YYMM + version.

When the manifest is unreachable from the runner the pipeline emits a non-fatal warning (`::warning::` on GitHub Actions, `##vso[task.logissue type=warning]` on Azure DevOps) and falls back to a **fleet-observed top-6 YYMM heuristic** so Step.6 still reports (`supportSource='fleet-observed'`). **Supported** = cluster's YYMM is inside the anchor window; **Unsupported** = older parseable YYMM; **Unknown** = empty / malformed `CurrentVersion`. The markdown section includes inline links to the Microsoft Azure Local [lifecycle cadence](https://learn.microsoft.com/azure/azure-local/update/about-updates-23h2#lifecycle-cadence) and [release information](https://learn.microsoft.com/azure/azure-local/release-information-23h2#about-azure-local-releases) docs as the operator cross-check. No `<failure>` tags - the testsuite is informational and never breaks the build.

### New cmdlet: `Get-AzLocalLatestSolutionVersion`

Unauthenticated probe of the Microsoft Azure Local public solution-update catalog at `https://aka.ms/AzureEdgeUpdates`. Returns the latest released solution version plus the rolling YYMM support window calendar-stepped from it (year-rollover honoured). Used by Step.6 to anchor the SupportStatus column on the upstream catalog instead of fleet-observed values, so older releases drop out of support automatically as soon as Microsoft publishes a newer YYMM.

Output PSCustomObject: `LatestYYMM`, `LatestVersion`, `SupportedYYMMs[]` (length = `-SupportWindowMonths`, default 6, configurable 1-24), `AllReleases[]`, `ManifestUrl`, `ManifestFetchedAt` (UTC), `SupportWindowMonths`, `Source = 'aka.ms/AzureEdgeUpdates'`. Tolerant of both XML shapes the manifest exposes (`ApplicableUpdate/UpdateInfo` and `PackageMetadata/ServicesUpdates/Update/UpdateInfo`).

```powershell
# Default - latest released YYMM + 6-month rolling window
Get-AzLocalLatestSolutionVersion | Format-List LatestYYMM, LatestVersion, SupportedYYMMs

# 12-month rolling window (e.g. for slower-moving regulated fleets)
Get-AzLocalLatestSolutionVersion -SupportWindowMonths 12

# Pin to a private mirror of the manifest (must be http(s))
Get-AzLocalLatestSolutionVersion -ManifestUrl 'https://internal.example.com/AzureEdgeUpdates.xml' -TimeoutSeconds 60
```

### New cmdlet: `Get-AzLocalFleetHealthOverview`

ARG-first fleet health summary. One row per cluster, joining `microsoft.azurestackhci/clusters` with the cluster's `updateSummaries` extensibility resource via a single Azure Resource Graph batch read. 12 columns in fixed order: `ClusterName`, `ClusterPortalUrl`, `HealthStatus`, `UpdateStatus`, `CurrentVersion`, `SbeVersion`, `AzureConnection`, `LastChecked`, `HealthResultsAgeDays` (computed as `datetime_diff('day', now(), LastChecked)`), `ResourceGroup`, `NodeCount`, `SubscriptionId`. Sort: `HealthResultsAgeDays desc, ClusterName asc` so the most-stale clusters surface first.

```powershell
# Whole-fleet rollup
Get-AzLocalFleetHealthOverview -SubscriptionId <subId> | Format-Table

# Filter to a ring (wildcard '***' = every cluster carrying ANY UpdateRing tag)
Get-AzLocalFleetHealthOverview -UpdateRingTag '***' -SubscriptionId <subId>

# Export to CSV for ITSM / dashboard ingest
Get-AzLocalFleetHealthOverview -SubscriptionId <subId> -ExportPath .\fleet-health-overview.csv -PassThru
```

### Step.3 audit pipeline - dual-section UX

The `Test-AzLocalApplyUpdatesScheduleCoverage` cmdlet's Audit rows now carry a `Section` discriminator that splits the audit into two conceptually distinct concerns:

| `Section` | Status values | Unit of work |
|---|---|---|
| `Schedule` | `RingMissingFromSchedule`, `RingOrphanedInSchedule` | The ring (`UpdateWindow` / `RequiredCronUTC` deliberately empty - these are about ring mapping, not window mapping) |
| `Cron` | `Covered`, `PartiallyCovered`, `Uncovered`, `MalformedTag`, `UnparseableCron` | The `(ring, UpdateWindow)` pair vs the Step.5 cron entries |

Audit rows now sort `Schedule`-first, then `Cron`. `-View Recommend` is now a multi-section markdown report: an "Action required - add these rings to apply-updates-schedule.yml" block when `RingMissingFromSchedule` rows exist (emitted FIRST), followed by an "Action required - cron coverage (paste into Step.5_apply-updates.yml)" block. When `-SchedulePath` is omitted, only the cron section is emitted (back-compat for v0.7.68 callers).

The `Step.3_apply-updates-schedule-audit.yml` pipeline YAMLs (GH + ADO) mirror this in their summary:
- Two JUnit `<testsuite>` blocks (`ScheduleCoverage` + `CronCoverage`) so the Tests tab shows per-section pass/fail counts.
- Two Audit Detail markdown tables (one per section) with conditional headings - empty sections still emit a placeholder row so the operator can see the section was evaluated.
- When `$hasIssues -and $reco`, the `-View Recommend` cmdlet output is prepended above the detail tables so operators see the fix before scrolling.
- The zero-row JUnit placeholder text is centralised via a new `Write-Suite -EmptyPlaceholderName 'No tagged clusters found - nothing to audit'` helper (GH-vs-ADO parity preserved since v0.7.67).

### Step.7 fleet-health pipeline - cluster portal hyperlinks + 3 new detailed columns + new Fleet Health Overview section

`Get-AzLocalFleetHealthFailures` (the v0.7.65 cmdlet) gains three deep-link / target-resource properties on Detail rows - `TargetResourceName` (the sub-resource that emitted the check failure, e.g. the NIC name), `TargetResourceType` (e.g. `Microsoft.Compute/virtualMachines/networkInterfaces`), and `ClusterPortalUrl` (`https://portal.azure.com/#@/resource{ClusterResourceId}` deep-link). Summary rows gain `AffectedClusterPortalUrls` aligned with `AffectedClusters` (same element count, same order, joined with `'; '`). The Summary now sorts **Critical-first**: Severity (Critical, then Warning, then everything else), then `ClusterCount` desc, then `FailureCount` desc - a Critical failure on 1 cluster ranks above a Warning affecting many clusters.

The `Step.7_fleet-health-status.yml` pipeline YAMLs (GH + ADO) consume these in three places:
- **Summary and Detailed Results cluster cells** render as `[ClusterName](portalUrl)` markdown links. The Summary caps at the first 10 then renders `... (+N more)`; the Detail tables link every cell.
- **Three new Detailed Results columns**: Failure Remediation (auto-renders as `[link](url)` when the value starts with `https://`, otherwise plain text), Target Resource Name, Target Resource Type.
- **New `### Fleet Health Overview (fleet rollup)` section** calls the new `Get-AzLocalFleetHealthOverview` cmdlet and surfaces the per-cluster 9-column rollup alongside the failures table. The mapping `OK` / `Critical` / `Warning` / `In progress` / `Failed` is rendered with bracketed labels (`[OK]`, `[Critical]`, etc.) so the at-a-glance summary is greppable. New report artifacts: `fleet-health-overview.csv` and `fleet-health-overview.json`.

### Pipeline pin bumps + migration

All 14 `Step.*.yml` files (7 GitHub Actions + 7 Azure DevOps) bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.7.69'` to `'0.7.70'`. The recommended upgrade path is the marker-aware merge (preserves operator edits inside `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` marker pairs):

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

### Compatibility

All v0.7.70 changes are backward compatible. The `Section` column defaults to `Cron` for downstream filters that don't know about the discriminator; new `TargetResource*` / `ClusterPortalUrl` / `AffectedClusterPortalUrls` properties are additive (existing pipeline summaries that read only the v0.7.69 schema keep working).

### Pester baseline

**585 passed / 0 failed / 0 skipped (unit) + 16 passed / 0 failed / 0 skipped (Live-Integration, opt-in)** - the unit suite stays hermetic and now includes a parallel, tag-gated `Tests/Live-Integration.Tests.ps1` durable suite that asserts the three v0.7.70 ARG-first cmdlets (`Get-AzLocalFleetHealthOverview`, `Get-AzLocalFleetHealthFailures`, `Get-AzLocalUpdateRunFailures`) against a real Azure Local fleet. The Live suite is **excluded by default** and safe to leave in the repo: each Describe self-skips when `az` is not installed, not logged in, or pointed at a non-target subscription. Opt in with `.\Tests\Invoke-Tests.ps1 -IncludeLive` or `-LiveOnly`. Validated end-to-end against a 20-cluster fleet (49 unresolved health failures, 9 unresolved Failed update runs) in 1m26s.

### What's New in v0.7.69

v0.7.69 introduces the **ring-aware apply-updates schedule** - a single human-readable YAML file (`apply-updates-schedule.yml`, `schemaVersion: 1`) that controls which `UpdateRing` tag value the apply-updates pipeline targets on any given UTC date. The schedule is decoupled from cron entirely: Step.5's cron only controls **how often** the pipeline wakes up, the per-cluster `UpdateWindow` tag controls **when** during an eligible day the update actually runs, and this new file controls **which ring** is eligible TODAY. Five new cmdlets (one generator + one reader + one resolver + one previewer + one migrator) plus a two-way ring diff on `Test-AzLocalApplyUpdatesScheduleCoverage` round out the feature.

### Strawman workflow (the safety gate is the whole point)

```powershell
# 1. Generate a STRAWMAN from your live fleet's UpdateRing tag values.
#    Every schedule row is emitted commented-out by design.
New-AzLocalApplyUpdatesScheduleConfig -OutputPath .\.github\apply-updates-schedule.yml

# 2. Open the file. REVIEW each strawman row, then UNCOMMENT the rows
#    that match your change-control policy.

# 3. Preview the next ~cycle of firings BEFORE committing.
Get-AzLocalApplyUpdatesScheduleNextFirings `
  -Schedule (Get-AzLocalApplyUpdatesScheduleConfig -Path .\.github\apply-updates-schedule.yml)

# 4. Refresh the Step.5 pipeline YAMLs so they pick up the v0.7.69 resolver wiring.
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub

# 5. Audit the fleet against the schedule (two-way ring diff).
Test-AzLocalApplyUpdatesScheduleCoverage `
  -PipelineYamlPath .\.github\workflows\Step.5_apply-updates.yml `
  -SchedulePath     .\.github\apply-updates-schedule.yml `
  -View Audit
```

> Without an active (uncommented) row, the apply-updates pipeline **hard-fails** at the reader step with `'schedule:' list is empty - at least one row is required`. This is the v0.7.69 safety gate, not a bug. It guarantees that a fresh strawman cannot accidentally start applying updates fleet-wide.

### Three independent layers - one file per layer

| Layer | File / Setting | Grain | Controls |
|---|---|---|---|
| 1 | `Step.5_apply-updates.yml` `schedule:` cron | intra-day | **HOW OFTEN** the pipeline wakes up |
| 2 | `apply-updates-schedule.yml` (NEW in v0.7.69) | day | **WHICH** `UpdateRing` is eligible on a given UTC date |
| 3 | Per-cluster `UpdateWindow` tag | minute | **WHEN** during an eligible day the update is allowed to start |

The Step.5 cron firing on a non-matching day exits 0 with the explanatory `Reason` and **does not** start an update. The cron firing on a matching day passes the resolved `UpdateRing` value to `Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue <resolved>`.

### Five new cmdlets

| Cmdlet | Role |
|---|---|
| `New-AzLocalApplyUpdatesScheduleConfig` | Generates a **strawman** schedule from the live fleet's `UpdateRing` tag values (or from `-Rings` for offline use). Every emitted schedule row is commented out by design. |
| `Get-AzLocalApplyUpdatesScheduleConfig` | Parses + validates a schedule file. Hard-fails with `'schedule:' list is empty` when no active rows are present (the safety gate). |
| `Resolve-AzLocalCurrentUpdateRing` | Maps a UTC date to the matching `UpdateRing(s)` using cycle-week math anchored at `cycleAnchorISOWeek` / `cycleAnchorYear`. Union semantics: overlapping rows merge `rings` with `;`. |
| `Get-AzLocalApplyUpdatesScheduleNextFirings` | Previews the next N days of resolved firings so operators can sanity-check the rotation BEFORE committing. |
| `Update-AzLocalApplyUpdatesScheduleConfig` | Idempotent schema-version migrator. Renames the original to `<basename>.v<oldVersion>.old.yml` on disk and writes the migrated content to the canonical path. The recipes table is intentionally empty in v0.7.69; the framework is in place for future schema bumps. |

### Two-way ring diff on `Test-AzLocalApplyUpdatesScheduleCoverage`

The existing schedule-audit cmdlet gained an optional `-SchedulePath` parameter. When supplied, the audit emits two new status rows beyond the existing cron-vs-tags audit:

| Status | Meaning |
|---|---|
| `RingMissingFromSchedule` | A fleet ring (live `UpdateRing` tag value on a cluster) has **no** matching row in the schedule file - clusters in that ring will never be updated. |
| `RingOrphanedInSchedule` | A schedule ring (a `rings:` token in the schedule file) has **no** cluster carrying that tag value - the schedule row will never fire. |

Both rows are surfaced in the Step.3 summary table, the JUnit XML failure list, and the Markdown summary at the top of the Step.3 run page.

### Step.5 / Step.3 pipeline wiring

- **Step.5 (apply-updates)** now resolves the `UpdateRing` from the schedule file on every **scheduled** firing. Manual `workflow_dispatch` (GitHub Actions) / non-`Schedule` `Build.Reason` (Azure DevOps) runs still honour the operator-supplied `-UpdateRingValue` input verbatim. A workflow-level `concurrency:` block (GitHub Actions only - Azure DevOps documents the equivalent **Settings -> Triggers -> Limit concurrent runs** option) prevents overlapping cron firings.
- **Step.3 (schedule audit)** gained a `schedule_path` / `schedulePath` input (defaulted to the standard layout), a `debug` toggle for self-service triage, and surfaces the new `RingMissingFromSchedule` / `RingOrphanedInSchedule` counts.

### What v0.7.69 does NOT touch

- `apply-updates-schedule.example.yml` ships as **documentation only**. `Copy-AzLocalPipelineExample` and `Update-AzLocalPipelineExample` do **not** copy or refresh it. Operators run `New-AzLocalApplyUpdatesScheduleConfig` to generate a strawman starting from their live fleet.
- The per-cluster `UpdateWindow` tag, the `UpdateSideloaded` workflow, and all existing cron schedules in the bundled pipeline YAMLs are unchanged.

### Breaking

- Schema `schemaVersion: 1` is a hard break vs any pre-v0.7.69 experimental schedule format. There are no v0 -> v1 migration recipes shipped (the recipes table is intentionally empty in `Update-AzLocalApplyUpdatesScheduleConfig`); if you were running an experimental schedule from earlier development builds, regenerate via `New-AzLocalApplyUpdatesScheduleConfig`.

### What's New in v0.7.68

v0.7.68 is the **ARG-first refactor** and **pipeline-rename** release. Seven fleet-scale read cmdlets were collapsed onto a single Azure Resource Graph batch read each (removing the silent `-ThrottleLimit` no-op), all 16 bundled pipeline YAMLs were renamed with a `Step.X_` ordering prefix so an alphabetic listing tells the story end-to-end, and a new `Get-AzLocalUpdateRunFailures` cmdlet exposes the deep-error breadcrumb path from update-run telemetry without per-cluster shell-outs. **Backwards-compatible** for already-deployed consumers: `Read-AzLocalApplyUpdatesYamlCrons` matches both new (`Step.X_*.yml`) and legacy filenames.

### ARG-first refactor

- **Seven cmdlets are now single-batch ARG reads with `-ThrottleLimit` removed.** `-ThrottleLimit` was a meaningless flag against the ARG batched read path; carrying it implied (incorrectly) that the cmdlet was doing a per-cluster fan-out and could be tuned for throttle. The new shape removes the parameter and collapses the call onto one ARG query, which (a) cuts subscription-level ARM call volume 5-10x on the common fleet-status pipelines and (b) lets the helper apply uniform 429/`Retry-After` retry logic in one place. Affected cmdlets: `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalClusterUpdateReadiness`, `Test-AzLocalClusterHealth`, `Get-AzLocalFleetProgress`, `Get-AzLocalFleetStatusData`, `New-AzLocalFleetStatusHtmlReport`. All bundled pipeline YAMLs were updated to stop passing `-ThrottleLimit`.

- **`Invoke-AzResourceGraphQuery` now retries on HTTP 429 (throttle).** Inspects the `Retry-After` response header when present and otherwise applies bounded exponential backoff (capped at the documented Azure Resource Graph throttling envelope). Large fleet sweeps no longer fall over at the throttling boundary; happy-path latency is unchanged.

- **`Invoke-AzResourceGraphQuery` hardened against `az.cmd` CR/LF stdout truncation.** A latent bug in `az.cmd` (Windows runners) could chop the JSON payload at the first chunked-write boundary when stdout was piped through PowerShell, producing the N-row collapse where a 27-cluster fleet would surface as 24 rows. The helper now decodes the full UTF-8 payload explicitly; existing Pester tests pin the regression.

- **`Get-AzLocalFleetProgress` no longer silently returns stale state when ARG returns zero rows.** The previous code-path treated an empty ARG response as "no change" and returned the last cached state; consumers (including the `Step.6_fleet-update-status.yml` JUnit emitter) therefore reported "everything green" on fleets that had been completely de-tagged or that hit a transient ARG error. The cmdlet now surfaces the empty-fleet condition explicitly so the operator can act on it.

### New: `Get-AzLocalUpdateRunFailures`

- **ARG-only deep-error extraction** (9 levels deep into the `properties.state.progress` tree of `microsoft.azurestackhci/clusters/updates/updateRuns`) returns verbose error information at fleet scale without per-cluster Az SDK or REST shell-outs. Two views: `-View Summary` (one row per failed update run) and `-View Detail` (one row per leaf failure with the full breadcrumb to the failed step). Useful in `Step.5_apply-updates.yml` post-mortem reports and as a follow-up call after `Get-AzLocalFleetProgress` reports failures.

### New: `Update-AzLocalPipelineExample` (marker-aware upgrade tool)

- **Marker-aware merge tool** that refreshes a customer's copy of any bundled pipeline YAML to the version shipped with the current module **while preserving operator edits inside `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` marker pairs**. Customer-side cron schedules in `schedule-triggers` and ITSM secret bindings in `itsm-secrets` (Step.5 only) survive a module upgrade; everything outside the markers is replaced with the new bundled content. Supports `-WhatIf`, `-DryRun`, multi-file batch mode, and emits a per-file change manifest so the operator can review the merge before committing. This is the operator-friendly upgrade path that `Copy-AzLocalPipelineExample` (clean overwrite) does not provide.

### Pipeline samples - `Step.X_` rename

- **All 16 bundled pipeline YAMLs renamed with a `Step.X_` ordering prefix** so they sort by execution order in a customer's repo (`Step.0_authentication-test.yml`, `Step.1_inventory-clusters.yml`, `Step.2_manage-updatering-tags.yml`, `Step.3_apply-updates-schedule-audit.yml`, `Step.4_assess-update-readiness.yml`, `Step.5_apply-updates.yml`, `Step.6_fleet-update-status.yml`, `Step.7_fleet-health-status.yml`). Both platforms (GitHub Actions + Azure DevOps). The rename matches the documented operator runbook order so an alphabetic listing in the consumer's IDE / repo browser tells the story end-to-end.

- **Backwards compatibility for already-deployed consumers:** `Read-AzLocalApplyUpdatesYamlCrons` (the schedule-audit scanner) glob list expanded to match both new (`Step.5_apply-updates*.yml`) and legacy (`apply-updates*.yml`) names. A customer who upgrades the module but has not yet re-run `Copy-AzLocalPipelineExample` will still see correct schedule-coverage audits.

- **Each YAML's workflow display name now also carries the `Step.N - ` prefix.** GitHub Actions sidebar sorts workflows alphabetically by the YAML's top-level `name:` field, so the 8 workflows now read `Step.0 - Authentication Validation and Subscription Scope Report` ... `Step.7 - Fleet Health Status` and list in execution order. For Azure DevOps the leading title comment in each YAML carries the same prefix so the import wizard prefills the suggested pipeline definition name correctly. See [`Automation-Pipeline-Examples/README.md` section 1.1](./Automation-Pipeline-Examples/README.md#11-why-the-pipelines-are-named-stepn---description) for the full convention.

### Pipeline samples - Layer 1 customisation markers (scaffolding)

- **Seven YAMLs now carry named `AZLOCAL-CUSTOMIZE` marker pairs** (6 main pipelines x `schedule-triggers`, plus `Step.5_apply-updates.yml` x `itsm-secrets`) wrapping the YAML regions operators commonly customise. Markers are pure YAML comments and have no runtime effect; they back the new `Update-AzLocalPipelineExample` cmdlet (also new in v0.7.68) that performs a marker-aware merge so operator edits inside the marker pairs survive a module upgrade. `Copy-AzLocalPipelineExample` remains the clean-overwrite tool for first-time install / forced refresh.

### Pipeline migration

If you have copied any of the bundled workflows into your repo, the recommended upgrade path is the new marker-aware merge:

```powershell
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps
```

(Add `-WhatIf` first to preview the merge before writing files; add `-Force` to skip the per-file confirm prompt for non-interactive runs.)

This brings in the new file names *and* the Layer 1 marker scaffolding **while preserving** operator-customised cron schedules and ITSM secret bindings inside `BEGIN-AZLOCAL-CUSTOMIZE` / `END-AZLOCAL-CUSTOMIZE` marker pairs in your already-deployed YAMLs.

For a clean overwrite (first-time install or forced refresh that discards local edits), keep using `Copy-AzLocalPipelineExample`:

```powershell
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
```

### Inventory & design doc

- **New `docs/Cmdlet-Inventory-And-Design.md`** documents which cmdlets read vs write, which back-end they use (ARG vs Az SDK vs az CLI), and the design rules that keep read paths ARG-first (no `-ThrottleLimit`, no per-cluster Get-AzResource fan-out). Removes ambiguity about which back-end a new cmdlet should take.

### What's New in v0.7.67

v0.7.67 lands a Phase 3/4 CI/CD-parity refresh, a new maintainer-facing release-process document, and a six-item batch of in-depth-review fixes. **No public surface change** - every pre-existing pipeline and cmdlet keeps the same contract.

#### CI/CD parity + UX

- **GitHub Actions schedule-audit pipeline now emits a passing testcase when the fleet has no tagged clusters.** Previously the GH variant of `Step.3_apply-updates-schedule-audit.yml` wrote an empty `<testsuite>` whenever there were no `(UpdateRing, UpdateWindow)` rows to evaluate; `dorny/test-reporter` then reported "no tests found", indistinguishable from a misconfigured reporter step. The pipeline now writes `<testcase classname="ScheduleCoverage" name="No tagged clusters found - nothing to audit" />` for the zero-row case, matching the long-standing Azure DevOps behaviour. The Tests tab reads cleanly as "passed (1/1)" regardless of whether the fleet has any tagged clusters yet, removing the daily false-alarm during onboarding and after fleet-wide tag clean-ups.

- **Schedule-audit summary now surfaces the cron recommendation block at the TOP when coverage drift exists.** Both `Step.3_apply-updates-schedule-audit.yml` files (GitHub Actions and Azure DevOps) previously emitted the recommended cron block at the bottom of the run summary, after the audit detail table. When the audit reported any `Uncovered` / `PartiallyCovered` / `MalformedTag` / `UnparseableCron` rows, operators had to scroll past the detail table to find the actionable fix. The pipelines now render an `### Action required - paste these cron entries into Step.5_apply-updates.yml` section immediately below the counts table when issues exist; when the fleet is fully covered, the recommendation block stays at the bottom as a reference. A new Pester guard asserts both YAMLs carry the conditional structure and the ordering.

- **Pipeline README now includes an artifact-handoff data-flow diagram.** Section 6 of [`Automation-Pipeline-Examples/README.md`](Automation-Pipeline-Examples/README.md) already carried a phase-oriented flow diagram (Inventory -> Tag -> Rollout -> Steady-state); the new "Artifact handoffs at a glance" subsection makes the data flow explicit, showing which artifact each pipeline emits and which downstream pipeline consumes it (e.g. `cluster-inventory.csv` -> manual tagging edit + manage-tags pipeline; `cluster-readiness.csv` -> apply-updates; `schedule-coverage-recommend.md` -> manual paste into `Step.5_apply-updates.yml`). Calls out the four artifacts operators most commonly trip on.

- **Pipeline README section 11 (Security model) now documents per-job `permissions:` blocks as an intentional security feature.** Every shipped GitHub Actions workflow declares its own job-level `permissions:` block (`id-token: write`, `contents: read`, `checks: write` only where needed). The new bullet calls out that consumers should not lift these blocks to a top-level `permissions:` block when copying samples, explains how the per-job shape (a) limits token scope to exactly the job that needs the write and (b) lets you keep `id-token: write` off read-only summary jobs, and documents that the samples are compatible with the recommended *Settings -> Actions -> General -> Workflow permissions = Read repository contents and packages permissions* hardening.

- **All Azure DevOps sample pipelines now share the same `azureSubscription:` placeholder.** Four files (`Step.4_assess-update-readiness.yml`, `Step.7_fleet-health-status.yml`, `Step.6_fleet-update-status.yml`, `Step.3_apply-updates-schedule-audit.yml`) previously used `'YOUR-SERVICE-CONNECTION-NAME'` while the other four ADO YAMLs used `'AzureLocal-ServiceConnection'`. All eight ADO pipelines now use `'AzureLocal-ServiceConnection'` plus a `# Update with your service connection name` comment, matching the value documented in section 3.2 of the pipeline README. An operator who follows the auth setup verbatim no longer has to find-and-replace anything in the YAMLs.

#### New maintainer doc: `docs/RELEASE-PROCESS.md`

- **Documents the staged unlisted-release flow** the module uses (publish -> immediately unlist -> validate against a test repo with `REQUIRED_MODULE_VERSION` exact-pinned to the candidate -> list after validation passes), the verification commands for each stage, and the Pester guardrails the release flow relies on. This puts the release rules in the repo rather than in tribal knowledge / chat history. Pipeline consumers do not need this doc; module maintainers do.

#### Fixed (in-depth module review - batch 3)

Six defence-in-depth fixes following the post-PR-#36 module review. **None are user-visible behaviour changes for the happy path** - every fix closes a class of silent-drift or silent-drop bug.

- **`$script:ModuleVersion` constant in `AzLocal.UpdateManagement.psm1` was stuck at `0.7.66` while the manifest moved to `0.7.67`.** The script-scope constant is the value `Start-AzLocalClusterUpdate` writes into its run-log header and the value `Get-AzLocalFleetStatusData` stamps into the `ModuleVersion` field of the exported fleet-state JSON, so every v0.7.67 run-log and every v0.7.67 fleet-state file was misreporting the producing module version - which is the exact field operators use to triage CI vs local-runner discrepancies. Bumped to `0.7.67`; a new Pester guard `Module version constants are in sync between .psm1 and .psd1` compares `(Import-PowerShellDataFile).ModuleVersion` against `InModuleScope { $script:ModuleVersion }` and fails any future drift at build time.

- **cp1252 stderr-warning regression that v0.7.66 fixed in `Invoke-AzResourceGraphQuery` had three remaining ambush sites.** The unsafe `az ... 2>&1 | ConvertFrom-Json` pattern was still live in `Get-AzLocalClusterInventory` resolving subscription display names via `az account show`, `Invoke-AzLocalSideloadedAutoResetForCluster` reading the cluster tags via `az rest`, and `Set-AzLocalClusterTagsMerge` reading the tags-subresource via `az rest`. The two `az rest` callers now route through the existing `Invoke-AzRestJson`. The `az account show` caller goes through a new private helper `Invoke-AzCliJson`, which applies the same stream-split-by-element-type pattern, auto-appends `--only-show-errors`, sets `PYTHONIOENCODING=utf-8` as defence-in-depth (restored in `finally`), and returns `[PSCustomObject]@{ Ok; Data; Error }` so callers no longer have to inspect `$LASTEXITCODE` manually. Seven new Pester tests cover the helper.

- **`ConvertFrom-AzLocalCronExpression` now accepts cron step syntax (`*/N`, `<a>-<b>/N`, `<a>/N`).** The schedule advisor was falsely flagging crons such as `*/15 * * * *` (every 15 min), `0 */6 * * 1` (every 6 hr on Mondays), and `0 9-17/2 * * 1-5` (every 2 hr between 09:00 and 17:00 on weekdays) as `UnparseableCron` - even though both GitHub Actions and Azure DevOps schedule them correctly. The parser now expands `*/N` over the field's full range, `<a>-<b>/N` over the explicit `[a,b]` range, and `<a>/N` over `[a, max]`. Step values must be positive integers; out-of-bounds bases still throw with the existing bounds messages. Four new Pester tests (3 positive + `*/0` negative); the pre-existing test asserting `*/15` was *rejected* has been flipped to assert the 672-fires-per-week expansion is correct.

- **`Reset-AzLocalSideloadedTag` now warns when a `-ClusterResourceIds` entry does not match `/clusters/<name>$`.** The `ByResourceId` resolver previously dropped malformed entries (typos, trailing slash, wrong provider, truncated string) silently - the operator would see "no matching clusters" without any indication that an input had been excluded. The resolver now emits `Write-Log -Level Warning` naming the exact `ResourceId` it skipped. This brings parity with the `ByName` / `ByTag` resolvers, which already warned on lookup failure. New regression test.

- **`Tests/Invoke-Tests.ps1` HTML footer no longer prints `Module Version: System.Object[]`.** When nested modules are loaded (the default for this module - every Private/*.ps1 is a nested module), `Get-Module AzLocal.UpdateManagement` returns one entry per loaded version, and `.Version` on that array surfaces as `Object[]`. The HTML test report footer was therefore intermittently printing `Module Version: System.Object[]`. The test runner now selects the newest loaded version via `Sort-Object Version -Descending | Select-Object -First 1` before reading `.Version`.

- **`Import-AzLocalFleetState` now caps input at 50 MB before reading.** The helper previously called `Get-Content -Raw | ConvertFrom-Json` with no size check; pointing it at a multi-GB file (typo, mis-glob, malicious symlink) would have OOMed the runner. Real fleet-state files (`Export-AzLocalFleetState` output) are tens of KB at most, so a 50 MB ceiling is ~3 orders of magnitude above any plausible legitimate input. The cap message names the actual file size in MB and explains what valid input looks like. Two new Pester tests (mocked-oversize trip + happy path).

#### Pester baseline

**485 passed / 0 failed / 0 skipped** (was 471 at v0.7.66) - the +14 new tests cover the drift guard, `Invoke-AzCliJson` (7), cron `*/N` (4), `Reset-AzLocalSideloadedTag` warning (1), and `Import-AzLocalFleetState` size guard (2).

#### Pipeline migration

If you have copied any of the bundled workflows into your repo, refresh them via:

```powershell
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
```
### What's New in v0.7.66

v0.7.66 is a CI/CD hotfix release. Two errors were observed on production runs of the `fleet-health-status` and `apply-updates-schedule-audit` pipelines on `windows-latest` GitHub Actions runners; both have a clean root cause and a minimal patch. No public surface change.

- **Fixed (critical) - `Get-AzLocalFleetHealthFailures` failed JSON parsing when the Azure CLI emitted a cp1252 encoding warning to stderr.** On `windows-latest` runners (or any ADO Windows agent whose console code page is `cp1252`), the Azure CLI's underlying Python layer can surface this stderr line:

  ```
  WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded.
  ```

  The shared `Invoke-AzResourceGraphQuery` helper was capturing `& az graph query ... 2>&1` as a single merged stream and feeding the entire thing to `ConvertFrom-Json`. The WARNING line therefore got prepended to the JSON body and the cmdlet threw `Conversion from JSON failed with error: Unexpected character encountered while parsing value: W. Path '', line 0, position 0.` This is the same class of bug that the v0.7.2 hardening of `Invoke-AzRestJson` already handled - the fix never made it into `Invoke-AzResourceGraphQuery` when that helper was split out. **The actual fix in v0.7.66** is the post-capture stream split: the helper splits the merged `2>&1` stream by element type, surfacing stderr lines as `[System.Management.Automation.ErrorRecord]` objects (which `2>&1` boxes them as) and stdout lines as strings; only the string stream is fed to `ConvertFrom-Json`. (The helper already passed `--only-show-errors` since v0.7.2, but the cp1252 encode warning can still leak through on some character paths, hence the belt-and-braces split.) The helper also sets `$env:PYTHONIOENCODING = 'utf-8'` for the duration of the call as **cosmetic defence-in-depth only** - this is a structural no-op for stock `az.cmd` because `az.cmd` launches Python with the `-I` (isolated) flag, which implies `-E` and causes Python to ignore every `PYTHON*` env var (confirmed in [Azure/azure-cli#28497](https://github.com/Azure/azure-cli/issues/28497) and the v0.7.2 root-cause analysis). The assignment only takes effect on hosts that have manually patched `az.cmd` to remove `-I`. The previous value is restored in a `finally` block. Every fleet-health-status pipeline run on a Windows runner is now resilient to this stderr warning.

- **Fixed (critical) - `Step.3_apply-updates-schedule-audit.yml` (both GitHub Actions and Azure DevOps) shipped with a default `pipeline_path` that only exists in *this* module's source repo.** The shipped default was `AzLocal.UpdateManagement/Automation-Pipeline-Examples`. In a consumer repo - where `Step.5_apply-updates.yml` lives under `.github/workflows/` (GH) or `.azure-pipelines/` (ADO) - that path does not exist and every default-trigger run failed with `PipelineYamlPath '...' does not exist on the runner` before the schedule advisor could write its JUnit XML, which then crashed `dorny/test-reporter` with `No test report files were found`. The defaults now match the standard consumer layout: `.github/workflows` on GitHub Actions, `.azure-pipelines` on Azure DevOps. When the resolved path is still missing on the runner, the audit step now lists which common pipeline folders **do** exist in the checked-out repo (`.github/workflows`, `.azure-pipelines`, `pipelines`, repo root) so the operator immediately knows what value to pass via `workflow_dispatch` / queue-time override.

#### v0.7.66 UX + capability refresh

In addition to the two hotfixes above, v0.7.66 ships a focused UX refresh of the `fleet-update-status` summary, timestamped artifact downloads across every pipeline, and multi-value / wildcard `UpdateRing` inputs on every exposed pipeline parameter and cmdlet.

- **Status emojis in the Fleet Update Status summary.** `Step.6_fleet-update-status.yml` (GitHub Actions and Azure DevOps) now renders the `Critical Health` and `Primary Status` summary tables with a green tick / red cross / refresh / yellow circle / info glyph - the same visual language operators already use to read JUnit dashboards. The legacy `[ok] / [fail] / [ready] / [running] / [blocked] / [info]` bracket markers are gone. Plain markdown, so it renders identically on the GH Actions step summary, the ADO pipeline run extension, and any markdown viewer (no JS, no images).
- **Generation timestamp in the Fleet Update Status H2 heading.** Both `Step.6_fleet-update-status.yml` files now render the H2 heading as `## Fleet Update Status Summary  _(generated YYYY-MM-DD HH:MM:SS UTC)_`. Operators no longer have to cross-reference the pipeline run start time to know when the data was collected.
- **Failed clusters appear before passing clusters in the JUnit per-cluster block.** The per-cluster `<testcase>` ordering in `Step.6_fleet-update-status.yml` (both platforms) is now bucketed: failed first (sorted alphabetically by `ClusterName`), then passed (sorted alphabetically). Failing clusters lead the dorny/test-reporter view (GitHub) and the Tests tab (Azure DevOps).
- **Every downloadable pipeline artifact now carries a UTC timestamp suffix.** All `actions/upload-artifact` steps (GH) and `PublishBuildArtifacts@1` / `PublishPipelineArtifact@1` tasks (ADO) now declare `name:` / `ArtifactName:` of the form `azlocal-<purpose>_yyyyMMdd_HHmmss`. Each job computes the timestamp once in a dedicated `Compute Artifact Timestamp` step. Two runs of the same pipeline on the same day now produce distinct zip downloads (`azlocal-fleet-update-status-report_20260518_140000.zip` vs `azlocal-fleet-update-status-report_20260518_180000.zip`) instead of clobbering each other in the operator's downloads folder.
- **Pipeline `UpdateRing` inputs accept multi-value lists and the literal `***` wildcard.** Every pipeline that exposes `update_ring:` (GH `workflow_dispatch`) or `updateRing:` (ADO `parameters:`) now accepts:
  - A single ring (unchanged): `Wave1`
  - A semicolon-delimited list: `Prod;Ring2` (whitespace around each ring is trimmed)
  - The wildcard `***` (three stars, deliberate gesture) to match every cluster that **has** a non-empty `UpdateRing` tag. **Untagged clusters are excluded**, preserving the existing opt-in gate. A single `*`, double `**`, or quadruple `****` are all REJECTED by the cmdlet's `[ValidatePattern]` so a one-character typo can no longer accidentally scope a fleet-wide write.

  The ADO `Step.5_apply-updates.yml` lost its closed `values:` enum (kept `type: string` so users still get a free-text editor in the ADO run dialog).
- **`[ValidatePattern]` tightened on 15 cmdlets** to match: `^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$`. Each individual ring segment keeps the same 1-64 character `[A-Za-z0-9_-]` policy as v0.7.65; the changes are (a) `;`-delimited lists are now accepted, and (b) **only the exact three-character `***` token is accepted as a wildcard** (single/double/quad stars are rejected). Hostile/malformed inputs (spaces, embedded quotes, `<script>`, leading/trailing `;`) are still rejected at the parameter binder before any Azure call is made.
- **New private helper `ConvertTo-AzLocalUpdateRingKqlFilter`** centralises the KQL clause construction for the three input forms above. Returns `| where isnotempty(tags['UpdateRing'])` for `***` (matches only tagged clusters), a `| where tags['UpdateRing'] =~ 'single'` clause for a single value, and a `| where tags['UpdateRing'] in~ ('a','b')` clause for a list. Embedded single quotes are doubled (KQL string-literal escape). All 12 ARG-query call sites in the public cmdlets now go through this helper.
- **Pester regression coverage** for every v0.7.66 feature: a `Describe 'v0.7.66 UpdateRing ValidatePattern accepts list & wildcard forms'` that reflects on every cmdlet's `ValidatePatternAttribute` and asserts both the acceptance set (`Wave1`, `Prod;Ring2`, `***`, ...) **and the rejection set including the easy-to-mistype `*` / `**` / `****` / `*Wave1` variants**, plus the existing hostile inputs (`Foo bar`, `abc'def`, `<script>`, empty, leading/trailing `;`); a `Describe 'v0.7.66 ConvertTo-AzLocalUpdateRingKqlFilter helper'` exercising every branch including the new `***` -> `isnotempty(...)` path (both default `tags['UpdateRing']` and `tostring(tags['UpdateRing'])` accessors); a `Describe 'v0.7.66 Artifact download names carry a UTC timestamp suffix'` that scans every `Automation-Pipeline-Examples/**/*.yml` and fails if any upload step is missing the `azlocal-` prefix or the `<timestamp>` token (plus four guards against the legacy non-stamped names regressing); a `Describe 'v0.7.66 Fleet Update Status summary uses status emojis and groups failures first'` that asserts the U+2705 and U+274C glyphs are present and that the legacy `[ok]/[fail]` markers are gone, that the `_(generated $generatedUtc)_` heading is present, and that the `$failedClusters` / `$passedClusters` / `$orderedClusters` bucketing tokens all appear; and a `Describe 'v0.7.66 Pipeline update_ring inputs document multi-value and wildcard support'` that asserts every input description mentions both `Prod;Ring2` and `'***'`.

#### v0.7.66 Pipeline migration

If you have copied any of the bundled workflows into your repo, refresh them via:

```powershell
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
```

### What's New in v0.7.65

- **New - `Get-AzLocalFleetHealthFailures` cmdlet.** Surfaces the in-flight **24-hour system health-check failures** across every Azure Local cluster the caller can read, via a single Azure Resource Graph query. The 24-hour health checks run on Azure Local clusters **independently of update activity** - which means clusters that are already "up to date" can still surface Critical or Warning issues that need triage. This cmdlet (and the new pipeline below) are the dedicated entry point for that workflow. Two views: `-View Detail` (one row per (cluster, failing check)) and `-View Summary` (aggregated by `FailureReason` + `Severity`, ordered "most widespread first" so administrators can target the highest-impact fixes). `-Severity Critical|Warning|All` filters at the ARG side; Informational entries are always excluded. `-UpdateRingTag` narrows to a specific wave. The function reuses the existing `Invoke-AzResourceGraphQuery` helper for paginated CLI shell-out, so it inherits the same skip-token / error-scrubbing behaviour as every other fleet-wide query in the module.

- **New - "Fleet Health Status" CI/CD pipeline samples** in `Automation-Pipeline-Examples/github-actions/Step.7_fleet-health-status.yml` and `Automation-Pipeline-Examples/azure-devops/Step.7_fleet-health-status.yml`. Daily 07:00 UTC schedule (offset from `fleet-update-status` at 06:00). Each run produces:
  - **Pipeline run summary**: pivoted by `FailureReason` (top failures by cluster impact), with a per-cluster "Detailed Results" table mirroring the standard "24-Hour System Health Checks - Detailed Results" view.
  - **JUnit XML**: one `<testcase>` per (cluster, failing health check), grouped under `Critical Health Failures` / `Warning Health Failures` testsuites for two-level drill-down in dorny/test-reporter (GitHub) and PublishTestResults@2 (Azure DevOps). dorny is configured `list-suites: failed` + `list-tests: failed` so the Test Reporter block is collapsed by default and only expands the failures.
  - **CSV exports**: `fleet-health-detail.csv` (per-cluster, per-failure) and `fleet-health-summary.csv` (one row per failure reason, ordered by cluster impact). Both are uploaded as build artifacts and are ready-made payloads for ITSM hand-off.
  Together with `Step.6_fleet-update-status.yml`, administrators now have **two dedicated pipelines**: one for "is each cluster up-to-date?" (Update Status) and one for "do clusters have actionable health issues even when up-to-date?" (Health Status).

- **New - Pester guardrail prevents pipeline-YAML version drift.** A new Pester `Context 'Pipeline YAML version pin (v0.7.65)'` test discovers every `*.yml` file under `Automation-Pipeline-Examples/` that installs the module from PSGallery and asserts that the `GENERATED_AGAINST_MODULE_VERSION` constant in that YAML matches the module manifest version. Supports both the inline GitHub Actions shape and the two-line Azure DevOps shape. The test fails the build if any sample YAML is forgotten when the manifest is bumped.

- **Fixed - `Set-AzLocalClusterUpdateRingTag` now uses the dedicated `Microsoft.Resources/tags/default` PATCH endpoint instead of `PATCH`-ing the cluster resource.** The previous code issued `PATCH https://management.azure.com/<clusterId>?api-version=2025-10-01` with `{ "tags": {...} }`, which Azure RBAC routes through the `microsoft.azurestackhci/clusters/write` action - i.e. full cluster Contributor. CI/CD service principals scoped to **Tag Contributor** (only `Microsoft.Resources/tags/*` actions) therefore failed with `AuthorizationFailed: action 'microsoft.azurestackhci/clusters/write'` even though they should have been able to write tags. The function now `PATCH`es `https://management.azure.com/<clusterId>/providers/Microsoft.Resources/tags/default?api-version=2021-04-01` with `{ "operation": "Merge", "properties": { "tags": { "UpdateRing": "..." } } }`, which Azure routes through `Microsoft.Resources/tags/write` only. The "Merge" operation preserves all other existing tags on the cluster without us having to re-send them. **Action**: if you scoped your tag-management SP to "Contributor" purely to work around the old behaviour, you can now safely scope it to the built-in **Tag Contributor** role on the cluster (or the resource group).

- **Fixed - "Fleet Update Status" pipeline summary now reconciles with the JUnit pass/fail counts.** Two related bugs were producing summary tables that did not add up to **Total Clusters**:
  1. `Up to Date` only counted `UpdateState -eq "UpToDate"` and missed clusters reporting the (equally healthy) `AppliedSuccessfully` state. Both states now count as "Up to Date".
  2. The bucket counters were not mutually exclusive and there was no catch-all, so a fleet of 20 healthy + 8 failed clusters could render as `Up to Date: 0`, `Health Failures: 8`, with the remaining 12 unaccounted for. Each cluster is now assigned to **exactly one** primary status using a priority cascade (`Update Failed` -> `Health Failure` -> `SBE Prerequisite Blocked` -> `Update In Progress` -> `Ready for Update` -> `Up to Date` -> `Needs Investigation`), so the rows always sum to `Total Clusters`.

- **Changed - JUnit / step-summary ordering is now: Summary FIRST, Test Results SECOND** in both `Step.6_fleet-update-status.yml` and `Step.7_fleet-health-status.yml` (GitHub + Azure DevOps). The markdown step summary is created before the JUnit XML is published, so the run-extensions / job-summary view leads with the operator-facing numbers rather than the raw test list.

- **Changed - "Fleet Update Status" failure message now reads `UpdateState: ..., Health: ...`** (was `Health: ..., UpdateState: ...`) so the Update Status leads in both the JUnit `<failure>` message and the markdown summary. The Update Status is the primary signal for that pipeline.

- **Documentation - `Set-AzLocalClusterUpdateRingTag` help and the Automation-Pipeline-Examples RBAC guidance now both recommend the built-in `Tag Contributor` role for tag-management automation.**

- **New - `Test-AzLocalApplyUpdatesScheduleCoverage` cmdlet + matching CI/CD pipeline samples.** Read-only schedule-coverage advisor that compares the cron schedule(s) in your `Step.5_apply-updates.yml` pipeline to the `UpdateWindow` tag values present on your clusters and flags any `(UpdateRing, UpdateWindow)` pair that no cron will ever reach. Three views: `-View Audit` (one row per `(Ring, Window)` pair with `Covered` / `Uncovered` / `PartiallyCovered` / `MalformedTag` / `UnparseableCron` plus a `Recommendation` column), `-View Matrix` (every distinct `(Ring, Window)` pair with the cron expression the advisor would generate for it), `-View Recommend` (ready-to-paste GH Actions and Azure DevOps cron blocks that cover every distinct `UpdateWindow` in the fleet). Per-segment cron generation handles multi-window tag values (`Sat-Sun_02:00-06:00;Mon-Fri_22:00-04:00`), day ranges (`Fri-Mon`), and configurable lead-time via `-LeadTimeMinutes` (default 5, 0-60). Pipeline samples ship at `Automation-Pipeline-Examples/github-actions/Step.3_apply-updates-schedule-audit.yml` and `Automation-Pipeline-Examples/azure-devops/Step.3_apply-updates-schedule-audit.yml`, scheduled weekly Mondays at 05:00 UTC (before the daily fleet pipelines) so drift annotations land at the top of the Monday-morning operator queue. Each run produces a JUnit XML (one `<testcase>` per `(Ring, Window)` pair), three CSV/MD exports (`schedule-coverage-audit.csv`, `schedule-coverage-matrix.csv`, `schedule-coverage-recommend.md`), and a markdown step summary. Full end-to-end runbook (tag a ring -> see drift -> copy recommended cron -> verify) in [`Automation-Pipeline-Examples/README.md` section 8.3](Automation-Pipeline-Examples/README.md#83-end-to-end-runbook-apply-updates-schedule-coverage-audit).

- **Module version pin bumped to 0.7.65 in all 13 sample workflow YAMLs** (11 pre-existing + the two new `Step.3_apply-updates-schedule-audit.yml` files). Run `Copy-AzLocalPipelineExample -Update` after upgrading to refresh the samples in your repo.

### What's New in v0.7.64

- **Fixed (critical) - pipeline-sample YAMLs (10 files across GitHub Actions and Azure DevOps) had accumulated cp1252 mojibake from previous emoji-edit round-trips.** One of the multi-byte sequences in `Step.2_manage-updatering-tags.yml` contained a YAML 1.2 forbidden C1 control character (U+008F), which caused GitHub Actions to reject the workflow at recent commits with `Invalid workflow file` / generic YAML syntax error and the affected step never ran. The root cause was UTF-8 emoji bytes (e.g. `F0 9F 93 84` = `[document]`) being misread as cp1252 by a previous editor session, then re-saved as UTF-8 - producing `C3 B0 C2 9F C2 93 C2 84`, which contains `C2 8F` -> U+008F. YAML 1.2 disallows raw C1 control characters U+0080-U+009F (except U+0085 NEL) in scalar content. **All non-ASCII bytes have been stripped from every sample workflow** (`[^\x09\x0A\x0D\x20-\x7E]`), the affected Markdown step-summary sections restored with plain-ASCII status labels (`[info]`, `[ok]`, `[running]`, `[ready]`, `[blocked]`, `[fail]`), and the YAMLs verified to round-trip cleanly through the GitHub Actions and Azure DevOps validators. No module code paths are affected; only the sample YAMLs.

- **Security hardening (Medium) - `Connect-AzLocalServicePrincipal` and six additional direct `az rest` callers now scrub raw CLI output through `ConvertTo-ScrubbedCliOutput` before logging or throwing.** A stray `refresh_token` / `access_token` / cookie that the `az` CLI might emit on a failure can no longer reach the host logs verbatim. Sites: `Set-AzLocalClusterTagsMerge` (3 throw paths), `Invoke-AzLocalSideloadedAutoResetForCluster`, `Invoke-AzLocalUpdateApply` (verbose), `Set-AzLocalClusterUpdateRingTag` (failure path), `Start-AzLocalClusterUpdate` (subscription-set and validate paths), and `Connect-AzLocalServicePrincipal`. This closes the same Bearer-token leak class that was already handled inside `Invoke-AzRestJson` / `Invoke-AzResourceGraphQuery` but missed by the seven sites that call `az rest` / `az account set` directly.

- **Documentation: `README.md` and [`ITSM/README.md`](ITSM/README.md) now carry explicit security notes about** (a) the `az login --service-principal --password <secret>` command-line exposure on the SP+secret authentication path (visible to `Win32_Process.CommandLine` and EDR for the duration of the call - prefer OIDC or Managed Identity), and (b) the unavoidable plaintext `[string]` residency of ITSM secrets in memory during ServiceNow OAuth `client_credentials` grants (the ServiceNow REST surface requires plaintext POST bodies, so `[SecureString]` round-tripping is impossible at this layer; mitigations baked in: scrubbing, URI redaction, finally-block temp-file cleanup).

- **Fixed (Low) - `Invoke-AzLocalUpdateApply` `$result -match "202"` was running against the `string[]` returned by `az rest`** which is array-filter semantics, not regex-match. The comparison is now done against `($result | Out-String).Trim()` against the single regex `'202|Accepted'`; `Write-Verbose` path also scrubbed.

- **Fixed (Low) - `Invoke-AzLocalItsmHttp` `throw` on non-retryable HTTP failure now uses `$redactedUri` instead of `$Uri`.** The redaction (`(client_secret|access_token|password)=[^&]+` -> `$1=***`) was already applied to the `Write-Verbose` log line; the `throw` message bypassed it.

- **Fixed (Low) - two Pester tests (`ScheduleBlocked` and `SideloadedBlocked` JUnit XML coverage) wrote to fixed temp filenames** that would collide if the test suite is run in parallel or back-to-back. Filenames now append a per-invocation `[Guid]::NewGuid()`.

- **Module version pin bumped to 0.7.64 in all 10 sample workflow YAMLs.** Run `Copy-AzLocalPipelineExample -Update` after upgrading to refresh the samples in your repo.

### What's New in v0.7.62

- **Fixed (critical) - `Start-AzLocalClusterUpdate` Step 3b critical-health gate was being silently bypassed.** The caller invoked [`Test-AzLocalClusterHealth`](Public/Test-AzLocalClusterHealth.ps1) without `-PassThru`; the function logs to the host stream and returns `$null` without `-PassThru`, so the predicate `$healthResults[0].CriticalCount -gt 0` always evaluated false even when the function had just logged `BLOCKED (N critical)`. Apply would then write *"No critical health issues found - cluster is eligible for update"* and proceed to PATCH the update despite critical health failures. Two more call sites in [`Get-AzLocalUpdateRuns`](Public/Get-AzLocalUpdateRuns.ps1) had the same omission. All three fixed.

- **Fixed (critical) - Tag writes now use the ARM tags subresource (`Tag Contributor` RBAC, not `clusters/write`).** [`Set-AzLocalClusterTagsMerge`](Private/Set-AzLocalClusterTagsMerge.ps1) - used by `Start-AzLocalClusterUpdate` to stamp `UpdateVersionInProgress`, by `Reset-AzLocalSideloadedTag`, and by the sideloaded auto-reset path - now `PATCH`es `.../providers/Microsoft.Resources/tags/default?api-version=2021-04-01` instead of the full cluster resource. This narrows the required RBAC from `microsoft.azurestackhci/clusters/write` to `Microsoft.Resources/tags/write` (built-in **Tag Contributor**). Up to 2 PATCHes per call: one `operation=Merge` for keys being set, one `operation=Delete` for keys whose input value is `$null`. Idempotent: skips keys whose value already matches.

- **Fixed (critical) - JUnit XML `Status` mapping no longer reports skipped clusters as passed.** `Export-ResultsToJUnitXml` previously rendered `NotReady`, `NotConnected`, `NoUpdatesAvailable`, and `NoReadyUpdates` as `<system-out>` (passed in `dorny/test-reporter`), producing misleading *all green* CI summaries when apply had actually skipped clusters. They now render as `<skipped>`. `UpdateNotFound` now renders as `<error type="UpdateNotFound">` instead of `<system-out>`.

- **Changed - `apply-updates` pipeline samples now consume the readiness CSV.** Both [`Automation-Pipeline-Examples/github-actions/Step.5_apply-updates.yml`](Automation-Pipeline-Examples/github-actions/Step.5_apply-updates.yml) and [`Automation-Pipeline-Examples/azure-devops/Step.5_apply-updates.yml`](Automation-Pipeline-Examples/azure-devops/Step.5_apply-updates.yml) now download the `readiness-report` artifact from the `check-readiness` job, filter rows where `ReadyForUpdate=True`, and pass `-ClusterResourceIds @(...)` to `Start-AzLocalClusterUpdate` instead of re-discovering clusters by `UpdateRing` tag. This guarantees the readiness gate's decision is **enforced** rather than advisory: a cluster flagged Blocked in readiness will not be touched by apply even if its tag still matches the ring. Apply still re-validates each cluster (Step 1b connectivity, Step 3b health, Step 3c schedule, Step 3b1 sideloaded) as defence in depth.

- **Changed - Readiness output gains a `ClusterResourceId` column.** [`Get-AzLocalClusterUpdateReadiness`](Public/Get-AzLocalClusterUpdateReadiness.ps1) emits the full ARM resource ID on every row (including `NotFound`/`Error` rows) so the apply step can pass it straight to `Start-AzLocalClusterUpdate -ClusterResourceIds` without a second Resource Graph query. **The CSV column is additive** - existing consumers that parse by header name keep working.

- **Module version pin bumped to 0.7.62 in all 10 sample workflow YAMLs.** Run `Copy-AzLocalPipelineExample -Update` after upgrading.

**What a successful `Step.5_apply-updates.yml` run looks like** (dry-run against the Prod ring on a 9-cluster sandbox - 4 ready, 5 skipped, zero failures):

![Step.5_apply-updates.yml run Summary tab: target UpdateRing Prod, dry-run, Readiness section showing Total Clusters 9 / Ready for Update 4, Results section showing Updates Started 0 / Skipped 5 / Failed 0 / Health Blocked 0 / Schedule Blocked 0 / Sideloaded Blocked 0](docs/images/apply-updates-summary.png)

### What's New in v0.7.63

- **Fixed (critical) - `Step.6_fleet-update-status.yml` pipeline samples failed with `ParserError` under PowerShell 7.** Inside the PS double-quoted here-string that builds the Markdown step summary, Markdown code-span backticks before file names like `` `update-summaries.csv` `` were interpreted by the PS 7 parser as the new `` `u{xxxx} `` Unicode escape (which expects `{` immediately after `` `u ``). PS 5.1 had silently consumed the backtick; PS 7 hard-errors. Latent corruption also affected `` `readiness-status.csv` `` (`` `r `` -> CR), `` `available-updates.csv` `` (`` `a `` -> BEL), and `` `cluster-inventory.csv` `` (`` `c `` -> backtick dropped) - producing rendered job summaries with stray control characters and missing code-span formatting even on PS 5.1. All Markdown code-span backticks in the affected here-strings have been doubled; under both PS 5.1 and PS 7 two consecutive backticks in a double-quoted string produce exactly one literal backtick. No module code paths affected; only the pipeline-sample YAMLs.

- **Module version pin bumped to 0.7.63 in all 10 sample workflow YAMLs.**

### What's New in v0.7.61

- **Readiness now blocks `ReadyForUpdate` when the cluster is not reachable or has Critical-severity health checks.** Both [`Get-AzLocalClusterUpdateReadiness`](Public/Get-AzLocalClusterUpdateReadiness.ps1) and [`Get-AzLocalFleetStatusData`](Public/Get-AzLocalFleetStatusData.ps1) (driving the fleet HTML report) downgrade `ReadyForUpdate` to `False` and record the reason on a new **`BlockingReasons`** CSV column whenever either of these is true:
  - **Connectivity gate** - `ClusterState` is not `'ConnectedRecently'` (e.g. `NotConnectedRecently`, `Disconnected`). ARM cannot reliably push an update to a cluster that has missed its heartbeat.
  - **Critical health gate** - `HealthCheckFailures` contains at least one `[Critical]` severity entry. These must be cleared before any solution upgrade is started.

  Values on `BlockingReasons` are semicolon-joined (e.g. `CriticalHealthCheck`, `CriticalHealthCheck; NotConnectedRecently`). The per-cluster console output now shows `Blocked (<reasons>)` in red, and the summary footer reports `Blocked by Readiness Gate: N` alongside the existing `Blocked by SBE Prereq` count. **The CSV column is additive** - existing consumers that parse by header name keep working.

- **`Start-AzLocalClusterUpdate` defence-in-depth: new `Step 1b` connectivity gate.** Immediately after cluster lookup, any cluster whose `properties.status` is not `'ConnectedRecently'` is skipped before any update is attempted. A row is recorded in `Update_Skipped.csv` with the message *"Update not started - cluster status is '<status>' (ARM cannot reach the cluster)"*, and the in-process `$results` list gets a `Status='NotConnected'` row. Complements the existing `Step 3b` critical-health gate. No new flags - the gate is always on.

- **Fixed - JUnit XML `Status` column from `Get-AzLocalClusterUpdateReadiness` was always `Skipped`** for Ready clusters (long-standing bool/string comparison bug `$_.ReadyForUpdate -eq 'Yes'` against `[bool]$true`). JUnit `Status` now correctly emits `Ready`, `Blocked`, `Failed`, or `Skipped`. The CSV `ReadyForUpdate` column (a real `[bool]`) was unaffected; only JUnit XML readability in CI/CD test summaries was wrong.

- **Module version pin bumped to 0.7.61 in all 10 sample workflow YAMLs.** Run `Copy-AzLocalPipelineExample -Update` after upgrading.

### What's New in v0.7.60

- **GitHub Actions sample workflows refreshed for Node 24.** All five workflow YAMLs under [`Automation-Pipeline-Examples/github-actions/`](Automation-Pipeline-Examples/github-actions/) now pin Node 24-compatible major versions of the third-party actions they use. This removes the *"Node.js 20 actions are deprecated"* warning banner that GitHub Actions started surfacing ahead of the **Sept 16 2026 Node.js 20 hard-removal**. No input/output surface changes for any of the bumped actions - refreshed pipelines work without any other edits:
  - `actions/checkout`        `@v4` -> `@v5`  (Node 24 default since v5.0.0)
  - `actions/upload-artifact` `@v4` -> `@v6`  (v6 = Node 24 default; v5 still defaulted to Node 20)
  - `azure/login`             `@v2` -> `@v3`  (v3.0.0 = Node 24)
  - `dorny/test-reporter`     `@v1` -> `@v3`  (v3 = Node 24)

  Already-deployed pipelines continue working on the older majors until Sept 16 2026. To pull the refreshed YAMLs into your existing `.github\workflows\` folder after upgrading the module, run `Copy-AzLocalPipelineExample -Update -Platform GitHub -Destination .\.github\workflows`.

- **Fixed - `dorny/test-reporter` 403 on `Step.5_apply-updates.yml` (GitHub Actions sample).** Both jobs (`check-readiness` and `apply-updates`) only granted `id-token: write` + `contents: read` in their `permissions:` block, missing the `checks: write` permission that `dorny/test-reporter` needs to create the Check Run that publishes JUnit results. Symptom: the test-reporter step failed with `HttpError: Resource not accessible by integration` (HTTP 403) on every `workflow_dispatch` run, because `workflow_dispatch` contexts have no PR check-run context to write back to by default. The run itself was unaffected - readiness assessment and the subsequent apply still completed - this only restored the Check Run summary surface so the JUnit XML actually shows up in the GitHub UI. Sibling workflows (`Step.4_assess-update-readiness.yml`, `Step.6_fleet-update-status.yml`) already declared `checks: write` from v0.7.50; only `Step.5_apply-updates.yml` was missing it.

- **Module version pin bumped to 0.7.60 in all 10 sample workflow YAMLs.** `GENERATED_AGAINST_MODULE_VERSION` is the value the in-pipeline install step compares the actually-installed module version against, then warns if your local copy of the YAML is stale (see [Automation-Pipeline-Examples/README.md section 5.3](Automation-Pipeline-Examples/README.md#53-version-pinning--staleness-warnings)). All five GitHub Actions YAMLs and all five Azure DevOps YAMLs have been bumped in lock-step.

### What's New in v0.7.50

- **`Copy-AzLocalItsmSample` (new convenience function)**: copies the bundled ITSM connector sample (`azurelocal-itsm.yml` + `templates/incident-body.md`) out of the module install location into a user-chosen destination. Default `-Destination` is `.\.itsm` - the exact relative path that both `Step.5_apply-updates.yml` workflows default `itsm_config_path` / `itsmConfigPath` to (resolved relative to the repo root at job runtime). Same overwrite semantics as `Copy-AzLocalPipelineExample`: refuses by default, `-Update` opts into per-file `ShouldContinue` prompts (with `Yes-to-All` / `No-to-All` that survive across iterations), `-Confirm:$false` bypasses the prompts for unattended use, `-WhatIf` previews without changing anything, `-PassThru` returns the destination `[DirectoryInfo]`. Closes the gap where running `Copy-AzLocalPipelineExample -Platform GitHub` (or `-Platform AzureDevOps`) deliberately did not bring the `.itsm/` sample along - the two functions now compose for a one-paragraph setup. The ITSM YAML itself is CI-platform-agnostic; both GitHub Actions and Azure DevOps consume it identically, only the secret source differs (repo / environment secrets vs. variable group).
- **`Copy-AzLocalPipelineExample` - simpler, safer copy semantics.** First real-world run of the v0.7.4 surface exposed two issues with the GitHub Actions path: (1) `-Platform GitHub -Flatten` left an intermediate `github-actions\` subfolder, so workflows landed at `.github\workflows\github-actions\*.yml` where the GitHub Actions runner cannot see them (the runner only scans `.github/workflows/*.yml`, non-recursively); (2) the `-Force` flag's directory-level pre-flight refused to copy whenever `.github\workflows\` contained any unrelated user workflow, making `-Force` effectively mandatory and meaningless. Both flags have been removed and the function has been reshaped around the user's actual intent:
  - `-Platform GitHub` now copies ONLY the `*.yml` workflow files from the source `github-actions/` folder directly into `-Destination` (flat - no wrapper folder, no README, no `.itsm/`). Canonical call: `Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub`.
  - `-Platform AzureDevOps` behaves the same way against the source `azure-devops/` folder.
  - `-Platform All` (the default) is unchanged - copies the full source tree under a `.\Automation-Pipeline-Examples\` child folder for browsing.
  - **Controlled refresh via `-Update`** (new in v0.7.50): the function still refuses to overwrite by default and lists every conflict in the error message - but the error now points at the `-Update` switch instead of asking the user to `Remove-Item` first. With `-Update` the function emits a per-file `ShouldContinue` prompt (`Y` / `A` / `N` / `L` / `S` / `?`) before each overwrite. Pair with `-Confirm:$false` to suppress the prompts entirely (the documented automation / CI bypass), or use `-WhatIf` to preview without changing anything. Pipeline files are expected to live under git source control so `git diff` is the second safety net after `ShouldContinue`. There is **deliberately no `-Force`**: `-Update` is the narrower, more explicit replacement.
  - Pre-existing unrelated files in `-Destination` (e.g. your repo's own `build.yml`, `codeql.yml`) are now left untouched; the function only writes the files it is bringing over from the source tree.
  - **Next-steps output** is now platform-aware and detects when `-Destination` is already `.github\workflows\` ("you're done, commit and push") vs. somewhere else ("move the YAMLs into `.github\workflows\`"). For both platform-specific values the output points at `Step.0_authentication-test.yml` as the recommended first run (see sections 5.1 and 5.2 of the [Automation-Pipeline-Examples README](Automation-Pipeline-Examples/README.md)) so the user validates the auth chain before wiring the other five workflows.
  - Note: this is **not** marked as a breaking change because the v0.7.4 surface had not been adopted by any consumer at the time of removal (the feature shipped on 2026-05-13 and was found broken on first real-world use).

### What's New in v0.7.41

- **Hotfix - parallel fleet reads broken by the v0.7.3 NestedModules refactor**: v0.7.41 fixes two related regressions that surfaced on the PSGallery-installed v0.7.4 build whenever **`-ThrottleLimit > 1`** was used.
  - **Bug 1**: every fleet read dispatched through `Invoke-FleetJobsInParallel` (`Get-AzLocalUpdateRuns`, `Get-AzLocalUpdateSummary`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalFleetProgress`, `Invoke-AzLocalFleetOperation`, `Test-AzLocalClusterHealth`, and `Start-AzLocalClusterUpdate`'s parallel path) returned `State = Error` for every cluster with the message *"Cannot use '&' to invoke in the context of module 'Invoke-FleetJobsInParallel' because it is not imported."* Inline (`-ThrottleLimit 1`) execution was unaffected. Root cause: the v0.7.3 refactor that split the monolithic `.psm1` into `NestedModules` changed the meaning of `$PSCommandPath` inside `Invoke-FleetJobsInParallel.ps1` - it now resolves to that helper's own `.ps1`, **not** to the root `AzLocal.UpdateManagement.psd1`. Each per-batch `Start-Job` scriptblock then imported only that single `.ps1` in the child runspace as a transient module, so subsequent `& $module { Get-AzLocalClusterUpdateRuns ... }` calls resolved against a session state that contained none of the private helpers.
  - **Bug 2**: `New-AzLocalFleetStatusHtmlReport -ThrottleLimit > 1` (via `Get-AzLocalFleetStatusData`) threw at start-up: *"Parallel collection requires module path '...\\Public\\AzLocal.UpdateManagement.psm1' to be reachable by background jobs, but it does not exist."* Same class of regression but a separate code path: `Get-AzLocalFleetStatusData` computed its own module path using `Join-Path $PSScriptRoot 'AzLocal.UpdateManagement.psm1'`, which under the post-v0.7.3 layout resolves to the `Public/` subfolder - one level too deep. `New-AzLocalFleetStatusHtmlReport`'s footer manifest-fallback had the same flaw.
- **Centralised module-root resolution**: introduced a new private helper [`Get-AzLocalModuleRootManifestPath`](Private/Get-AzLocalModuleRootManifestPath.ps1) used by all three sites. It prefers the loaded module's `.Path` (`.psd1` over `.psm1`) and falls back to walking up from the caller's `$PSCommandPath`, so it returns the correct root manifest path from any file under `Public/` or `Private/`. Future helpers won't reintroduce the same "`$PSScriptRoot` is module root" assumption.
- **Regression coverage**: existing parallelisation tests only exercised the inline `-ThrottleLimit 1` fast-path, which reuses the parent runspace and so could not reproduce either bug. v0.7.41 adds Pester tests that (a) assert `Invoke-FleetJobsInParallel` passes the **root manifest path** (`.psd1`/`.psm1`) as the trailing `ModulePath` argument and **not** the helper's own `.ps1`, and (b) directly exercise `Get-AzLocalModuleRootManifestPath` with synthetic caller paths under `Public/` and `Private/`. Full suite: **354/354 green**.

### What's New in v0.7.4

- **ITSM Connector - Phase 1 (ServiceNow)**: new opt-in capability for opening ServiceNow incidents directly from update / fleet pipeline output. Three new exported functions - `New-AzLocalIncident`, `Get-AzLocalItsmConfig`, `Test-AzLocalItsmConnection` - plus supporting private helpers (`Resolve-AzLocalItsmSecret`, `Get-AzLocalItsmDedupeKey`, `Get-AzLocalItsmTriggerDecision`, `Format-AzLocalIncidentBody`, `Invoke-AzLocalItsmHttp`, `Invoke-AzLocalServiceNowAdapter`). `New-AzLocalIncident` reads a JUnit results artifact (and an optional readiness CSV), applies the trigger matrix from the user's [`azurelocal-itsm.yml`](Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml) config, computes a deterministic SHA256 dedupe key per `{ClusterResourceId, UpdateName, TriggerCategory}` tuple, queries ServiceNow for an existing open ticket (`u_azlocal_dedupe_key`, `stateIN1,2,3`), and either creates a new incident or returns the existing ticket - so re-running the same pipeline is idempotent. Auth is OAuth 2.0 `client_credentials` only in Phase 1; secrets resolve from Azure Key Vault (`kv://<vault>/<secret>`), environment variables (`env://NAME`), or explicit literals (`literal://...` with `-AllowLiteral`). HTTP path is TLS 1.2+, default 30s timeout, exponential backoff on 429/5xx, `Retry-After` honoured. The CSV export from `-ExportPath` is sanitised by `ConvertTo-SafeCsvCollection`, neutralising the same formula-injection class already handled elsewhere in the module. `Test-AzLocalItsmConnection` validates the config, resolves secrets, performs the OAuth token grant, and probes a one-row read against `/api/now/table/incident` (matching the least-privilege scope used by ticket creation). Full documentation under [`ITSM/`](ITSM/): [README](ITSM/README.md), [ITSM-Connector-Plan.md](ITSM/ITSM-Connector-Plan.md), [ITSM-Config-Reference.md](ITSM/ITSM-Config-Reference.md). A ready-to-copy sample config plus the Mustache ticket-body template live under [`Automation-Pipeline-Examples/.itsm/`](Automation-Pipeline-Examples/.itsm/). 33 new ITSM Pester tests; full suite green at 337/337.
- **Phase 2 and Phase 3 are not in this release.** Phase 2 (`Sync-AzLocalIncident` - close-out / work-note sweep when the underlying cluster recovers) and Phase 3 (Microsoft Teams + Slack mirror adapters) are designed in [`ITSM/ITSM-Connector-Plan.md`](ITSM/ITSM-Connector-Plan.md) and tracked for a later release. The `lifecycle` and `notifications` config sections are parsed and stored in Phase 1 but not yet acted on. A small set of Phase 1.5 follow-ups is also tracked: cmdbCi token expansion, custom-field presence check, rate-limit-headroom probe, in-module token caching, `Invoke-AzLocalItsmHttp -AllowedThumbprints` cert pinning, and `raiseAfterConsecutiveOccurrences` enforcement (requires the run-history store).
- **Code hygiene**: removed the unused username/password OAuth grant path from the ServiceNow adapter (Phase 1 is `client_credentials` only) - silences the PSScriptAnalyzer `PSAvoidUsingUsernameAndPasswordParams` Error and `PSAvoidUsingPlainTextForPassword` Warning. Tightened the ITSM config validator so `secrets.source: mixed` now requires `secrets.keyvaultName`, matching the documented behaviour. Cleaned up legacy non-ASCII characters in [`Private/Format-AzLocalUpdateRun.ps1`](Private/Format-AzLocalUpdateRun.ps1) and [`Publish-Module.ps1`](Publish-Module.ps1) divider comments. Flattened `ITSM/Docs/` into [`ITSM/`](ITSM/) (removed the stale duplicate `ITSM/Docs/ITSM-Connector-Plan.md`).
- **`Copy-AzLocalPipelineExample` (convenience)**: new exported function that copies the bundled [`Automation-Pipeline-Examples/`](Automation-Pipeline-Examples/) folder out of the module install location into a destination folder you control (default: current directory). Supports `-Platform GitHub | AzureDevOps | All`, `-Flatten` (drop contents directly into the destination), `-Force` (overwrite), `-PassThru`, `-WhatIf` and `-Confirm`. After copying, prints a short "next steps" summary pointing at the README and the platform-specific destination paths so you don't have to hunt through `$module.ModuleBase` to find the YAML samples.

### What's New in v0.7.3

- **Module renamed** from `AzStackHci.ManageUpdates` to `AzLocal.UpdateManagement`. The module GUID is preserved across the rename so PowerShell tooling sees this as the same module identity. All previously-published `AzStackHci.ManageUpdates` versions have been unlisted from PSGallery; a transitional v0.7.3 stub is published once to point legacy automation at the new name. Migration: `Uninstall-Module AzStackHci.ManageUpdates -AllVersions; Install-Module AzLocal.UpdateManagement`. Default log folder default also moved from `C:\ProgramData\AzStackHci.ManageUpdates\` to `C:\ProgramData\AzLocal.UpdateManagement\`.
- **Internal refactor**: the monolithic 11,679-line `.psm1` has been split into Public/Private dot-sourced files matching the layout of `AzLocal.DeploymentAutomation`. 20 exported functions live under `Public/`, 40 internal helpers under `Private/`. The manifest's `NestedModules` list enumerates every file. No functional change; the full Pester suite (299 tests) remains green.

### What's New in v0.7.2

- **Bug fix - fleet read paths under `-ThrottleLimit > 1`**: `Get-AzLocalUpdateRuns`, `Get-AzLocalUpdateSummary`, and `Get-AzLocalClusterUpdateReadiness` previously failed for every cluster when invoked with `-ThrottleLimit` greater than 1, reporting `The term 'Get-AzLocalClusterUpdateRuns' is not recognized...` (or the equivalent for other private helpers). The per-cluster scriptblock dispatched via `Start-Job` called module-private helpers (`Invoke-AzRestJson`, `Get-AzLocalClusterUpdateRuns`, `Format-AzLocalUpdateRun`, `Get-LatestUpdateByYYMM`, `ConvertTo-AzLocalAdditionalProperties`, `Get-HealthCheckFailureSummary`, `Get-TagValue`) by name; because those helpers are filtered out by `Export-ModuleMember`, after `Import-Module` in the child runspace they were not visible at script command-resolution scope. Inline (`-ThrottleLimit 1`) execution was unaffected. Each affected scriptblock now captures a reference to the loaded module and either invokes the helper via `& $module { ... }` or rebinds the helper's bound scriptblock into the local function scope, so calls execute against the module's own session state and resolve all transitive private references. Reported against a 9-cluster Prod fleet.
- **Bug fix - cp1252 encoding warnings leaking into JSON parsing**: On Windows hosts where the console code page is `cp1252` (the English-US default), the Azure CLI (`az rest`, `az graph query`) emitted `WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded.` whenever ARM responses contained non-cp1252 characters (smart quotes, accented characters in cluster tags, localised health-check messages, etc.). Captured via `2>&1`, that warning was prepended to the JSON body and broke `ConvertFrom-Json`, which silently dropped update runs and available updates for affected clusters. Earlier attempts to fix this via `$env:PYTHONIOENCODING = 'utf-8'` are structurally ineffective: `az.cmd` launches Python with the `-I` (isolated) flag, which implies `-E` and so causes Python to ignore all `PYTHON*` environment variables (including `PYTHONIOENCODING` and `PYTHONUTF8`) - confirmed in [Azure/azure-cli#28497](https://github.com/Azure/azure-cli/issues/28497). The actual fix is to pass `--only-show-errors` to every `az rest` and `az graph query` invocation (Azure CLI maintainer's recommended workaround per [Azure/azure-cli#14426](https://github.com/Azure/azure-cli/issues/14426)). This suppresses the encode warning at source so the captured stderr/stdout streams stay clean. Characters that fail to encode are still replaced silently inside the CLI, but for ARM cluster/update payloads (timestamps, GUIDs, status enums, resource IDs - all ASCII) this is a non-issue. Genuine errors (auth failures, 4xx/5xx ARM responses, invalid args) still surface normally.

### What's New in v0.7.1

- **Sideloaded payload workflow (new)**: opt-in two-tag protocol (`UpdateSideloaded` set by operator, `UpdateVersionInProgress` set by module) for staging out-of-band update payloads. `Start-AzLocalClusterUpdate` blocks with `Status = SideloadedBlocked` while the payload is being staged. `Get-AzLocalUpdateRuns` auto-resets the tags once the matching run succeeds. New public function [`Reset-AzLocalSideloadedTag`](#reset-azlocalsideloadedtag) for explicit / `-Force` recovery. See [section 7a](#7a-sideloaded-payload-workflow-v071) for the full flow. **No new RBAC required** - rides on the existing `Microsoft.Resources/tags/read|write` permissions.
- **EndTime column for update runs**: new `EndTime` column on `Get-AzLocalUpdateRuns` table output, sourced from `properties.progress.endTimeUtc` (most accurate "work finished" timestamp), falling back to `properties.lastUpdatedTime`. Blank for `InProgress` runs. Per-run `Duration` now prefers ARM-reported `properties.duration` (ISO-8601 timespan) over the computed `EndTime - StartTime` delta, so it is immune to clock skew. Fleet HTML report's "Recent Update Run History" gains an `End Time` column; JUnit XML test bodies include `Start Time:` / `End Time:` lines per testcase (the JUnit `time=` attribute is unchanged).
- **Idempotent tag merges**: `Set-AzLocalClusterTagsMerge` (private helper used by both `Set-AzLocalClusterUpdateRingTag` and the sideloaded workflow) now skips the PATCH when the merge produces no actual change against the cluster's current tags. Quieter logs and one less ARM write per no-op.
- **Enterprise-readiness review fixes**:
  - **Security**: `Write-UpdateCsvLog` (the diagnostic CSV path used during apply runs) now sanitises every field through `ConvertTo-SafeCsvField` before quote-escaping, closing the same Excel-formula-injection gap on the interim `Update_Skipped.csv` / `Update_Started.csv` logs that was already covered for the final exported results.
  - **Operational**: parallel `Get-AzLocalFleetStatusData` job dispatch now treats `Stopped` and `Disconnected` job states as failures alongside `Failed`. Previously these terminal states fell through into `Receive-Job` and were misdiagnosed as "no output", obscuring the real cause of `Stop-Job` / Ctrl-C / remoting-disconnect scenarios.
  - **Performance**: `Get-AzLocalUpdateSummary`, `Get-AzLocalClusterUpdateReadiness`, `Start-AzLocalClusterUpdate`, `Get-AzLocalUpdateRuns`, and the private `Get-AzLocalClusterUpdateRuns` helper now accumulate per-cluster results in a `[System.Collections.Generic.List[object]]` (O(1) amortised `.Add()`) instead of an `Object[]` with `+=` (O(n^2) total). Measurable speed-up at fleet scale (1000+ clusters); no API surface change - the functions still return arrays.

### What's New in v0.7.0

The jump from `0.6.5` to `0.7.0` is a large, fleet-scale release focused on correctness at 1500+ clusters, true parallel execution, HTML report performance, and a round of security hardening. No breaking public-surface changes.

#### Fixed - Correctness at scale
- **HIGH**: Azure Resource Graph queries were hardcoded to `az graph query --first 1000`. At 1500 clusters, 500 were silently dropped - no error, no warning. New private `Invoke-AzResourceGraphQuery` helper loops on the `$skipToken` until exhausted.
- **HIGH**: `Invoke-AzLocalFleetOperation -ThrottleLimit` previously only affected retry-backoff math; the per-cluster loop was fully sequential. At 1500 clusters that meant 4+ hour runs. Extracted the parallel `Start-Job` pattern into a shared private helper `Invoke-FleetJobsInParallel` and rerouted all fleet operations through it. `-ThrottleLimit` now controls concurrent API calls (default 4, range 1-16). PowerShell 5.1 compatibility preserved.
- **HIGH**: `Get-AzLocalClusterInventory` threw `The variable cannot be validated because the value '' is not a valid value for the UpdateRingValue variable.` whenever a cluster in the fleet was missing the `UpdateRing` tag. Root cause: the function's `[ValidatePattern]` parameter `$UpdateRingValue` collided with a loop-local `$updateRingValue` (PowerShell variable names are case-insensitive). Locals renamed to `$ringTagValue` / `$windowTagValue` / `$exclusionsTagValue`. `-AllClusters` reports now complete against real-world mixed-tag fleets.

#### Changed - Performance (parallel by default)
- These per-cluster functions now run in parallel batches via the shared helper: `Get-AzLocalClusterUpdateReadiness`, `Test-AzLocalClusterHealth`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Set-AzLocalClusterUpdateRingTag`, `Get-AzLocalUpdateRuns`. Expected 5-10x speedup on 1500-cluster runs (readiness check from ~10 min to ~1-2 min).
- `New-AzLocalFleetStatusHtmlReport` renderer rewritten for O(n) scaling: pre-indexed `LatestRuns` and `ClusterDetails` hashtables, HTML encoding moved to collection time, per-cluster portal URLs precomputed once. ~60% faster HTML render at 1500 clusters.
- HTML report output now written as UTF-8 **without BOM** via `[System.IO.File]::WriteAllText` + `UTF8Encoding($false)`.
- New opt-in pass-through parameters (`-UpdateSummary`, `-AvailableUpdates`) so pre-fetched data can be reused across a pipeline, avoiding redundant ARM reads.

#### Changed - `-AllClusters` cap removed
- `New-AzLocalFleetStatusHtmlReport -AllClusters` and `Get-AzLocalFleetStatusData -AllClusters` previously truncated at the first 100 clusters silently. **The default cap is removed - all discovered clusters are now included.** New `-MaxClusters <int>` parameter (default 0 = no cap, range 1-100000) lets callers optionally trim the slice for targeted runs or testing.

#### Fixed - Bugs and strict-mode hardening
- All `| ConvertFrom-Json` call sites outside `Invoke-AzRestJson` audited - previously any non-JSON ARM response (HTTP 204, error HTML, stray stderr on stdout) would throw uncaught under Strict Mode.
- Empty-pipeline guards added to health-failures and latest-run aggregation paths so they no longer silently return `$null`.
- Update-name sort is now deterministic (secondary sort on `$_.name`); unparseable YYMM components log a `Warning` instead of silently grouping at position 0.
- Parallel CSV log writes: each worker writes a per-job CSV; coordinator merges at the end. Eliminates line interleaving / header corruption that `Add-Content` cannot protect against.
- Tag property access is now robust to both `Hashtable` and `PSCustomObject` tag shapes returned by different ARM endpoints.
- Malformed `UpdateWindow` / `UpdateExclusions` tag values are now **blocking** by default (update skipped, `Error` logged) unless `-Force` is specified. Previously logged as a warning and the update proceeded.

#### Security
- `-UpdateRingValue` is whitelist-validated against `^[a-zA-Z0-9._-]+$` before KQL interpolation in ARG queries.
- New private helper `ConvertTo-SafeCsvField` prefixes formula-leader characters (`=`, `+`, `-`, `@`, tab) with a single quote and strips embedded CR/LF. Applied uniformly to every field written by the CSV loggers. Prevents Excel formula injection via attacker-controlled cluster name / error message.
- User-supplied output paths (`-OutputPath`, `-ExportResultsPath`, `-LogFolderPath`, `-StateFilePath`) are resolved via `[IO.Path]::GetFullPath()`, length-capped at 248 chars, and rejected if they contain `..\` traversal sequences when a relative root was expected.
- Az CLI error output is scrubbed before being written to logs: `--password <value>` / `--secret <value>` echoes masked; token-shaped substrings redacted.
- `Invoke-AzRestJson` handles mid-run token expiry: on HTTP 401 it runs `az account get-access-token` once, refreshes, and retries. Long fleet operations crossing the 1-hour token boundary no longer fail partway through.
- `Stop-AzLocalFleetUpdate` and `New-AzLocalFleetStatusHtmlReport` now support `ShouldProcess` (`-WhatIf` / `-Confirm`).

#### Changed - Maintenance window tag format
- **Breaking for pre-release consumers only (no one was using this yet)**: the `UpdateWindow` Azure resource tag now uses `_` as the separator between the day-spec and the time range, instead of `:`. This removes the ambiguity with the `HH:MM` time portion and makes the tag easier to read at a glance.
  - Old: `Mon-Fri:22:00-02:00`
  - **New: `Mon-Fri_22:00-02:00`**
  - Multi-window separator (`;`) and day-range separator (`-`) are unchanged.
  - The parser in `ConvertFrom-AzLocalUpdateWindow` will throw `Invalid window segment syntax` for the old format; combined with the fail-closed schedule-tag evaluation above, any cluster still carrying the old tag value will have its updates blocked until re-tagged. Use `Set-AzLocalClusterUpdateRingTag -UpdateWindowValue 'Mon-Fri_22:00-02:00' -Force` to migrate.

#### Changed - Fleet HTML report Recent Update Run History
- Duration now uses `HH:MM:SS` fixed-width format (was `N.N hours` fractional). Easier to read, no loss of precision, survives multi-day runs (`52:15:30` for 52h 15m).
- **Attempts are now aggregated per update**: when an update runs multiple times on a cluster (a re-run after failure), the report shows **one row** with `Update Attempts = N` and `Duration = <sum of all attempts>` instead of showing just the last attempt's duration. `StartTime` reflects the earliest attempt; `State` / `Progress` / `Current Step` reflect the latest attempt.
- New **Update Attempts** column is shown **only** when at least one cluster has >1 attempt on its current update, keeping single-attempt fleets uncluttered.
- Only the most-recently-started update per cluster is displayed (one row per cluster); historical update versions from prior cycles are no longer duplicated into separate rows.

#### Changed - Cluster Information section (HTML report)
- New **Current SBE Version** column shows the solution-builder-extension version installed on each cluster, alongside the solution update version. Extracted from the `/updates` `additionalProperties.SBEVersion` of the most recent applied SBE update and surfaced through `Get-AzLocalFleetStatusData` and the GitHub Actions / Azure DevOps fleet-status pipelines.

#### Changed - `Start-AzLocalClusterUpdate`
- `-WhatIf` output is no longer polluted by the module's own `Write-Log` / `Write-UpdateCsvLog` side effects, internal `Env:` cleanup, or log-folder creation. Previously every internal housekeeping line produced a `What if:` row. Now only the actual ARM `POST` `apply/action` call appears in the WhatIf preview.
- `-WhatIf` runs (and `ShouldProcess`-declined runs) now count as **WouldUpdate** in the final summary and are surfaced distinctly from `Started` / `Skipped` / `Failed`. Makes dry-runs at fleet scale actually auditable.

#### Added - `Format-AzLocalDurationHuman` helper (private)
- Central helper for duration rendering; accepts `[TimeSpan]`, numeric seconds, or `HH:MM:SS` string. Emits `"1 hour 23 minutes"` style for the per-run `Get-AzLocalUpdateRuns` output. The fleet HTML report uses its own `HH:MM:SS` formatter because it sums across attempts (see above).

#### Notes
- No breaking changes to exported functions or parameter sets. All new helpers are private.
- Az CLI remains the ARM transport for v0.7.0; a native `Invoke-RestMethod` port is deferred.

### What's New in v0.6.5

#### Fixed
- **`Set-AzLocalClusterUpdateRingTag` now correctly applies `UpdateWindow` and `UpdateExclusions` tags from CSV** (HIGH). Inside the processing loop, four references used an undefined variable (`$cluster`) instead of the actual loop variable (`$clusterEntry`). Because `Set-StrictMode` is not enforced at module scope, the typo silently returned `$null`, so:
  - Clusters with an existing `UpdateRing` tag were skipped even when the CSV changed `UpdateWindow`/`UpdateExclusions`.
  - On new/forced writes the PATCH body only contained `UpdateRing`; `UpdateWindow`/`UpdateExclusions` columns from the CSV were never sent to Azure.
  - Round-trip `Get-AzLocalClusterInventory` -> edit CSV -> `Set-AzLocalClusterUpdateRingTag` now correctly preserves all three tag columns.

#### Added
- **New optional parameters `-UpdateWindowValue` and `-UpdateExclusionsValue` on `Set-AzLocalClusterUpdateRingTag -ClusterResourceIds`**. Direct-invocation mode is now symmetrical with CSV mode and can set all three tags (`UpdateRing`, `UpdateWindow`, `UpdateExclusions`) in a single PATCH operation:

  ```powershell
  Set-AzLocalClusterUpdateRingTag `
      -ClusterResourceIds $ids `
      -UpdateRingValue 'Wave1' `
      -UpdateWindowValue 'Mon-Fri_22:00-02:00' `
      -UpdateExclusionsValue '2026-12-20/2026-01-05' -Force
  ```

- **`Set-StrictMode -Version 1.0` is now enforced at module scope.** Catches references to uninitialized variables (the exact class of bug fixed above) at runtime instead of silently returning `$null`. All 239 Pester tests pass unchanged. `-Version Latest` was deliberately not selected because ARM REST responses legitimately omit optional properties (e.g. `additionalProperties.SBEPublisher`, `tags.UpdateRing`) and Latest would throw on every such dot-notation access.

### What's New in v0.6.4

#### Azure CLI Availability Check & Auto-Install
- **New internal function `Test-AzCliAvailable`**: Checks if Azure CLI (`az`) is installed before any `az` invocation
- In interactive sessions, prompts the user to download and install when `az` is not found
- In non-interactive environments (CI/CD pipelines), throws immediately with clear installation instructions
- All exported functions and SingleCluster code paths now call `Test-AzCliAvailable` before first `az` CLI usage

#### Fleet Status Data Collection
- **New function `Get-AzLocalFleetStatusData`**: Single-pass data collection with parallel `Start-Job` support
- `-ThrottleLimit` parameter (default: 4, max: 8) splits cluster list into parallel batches
- `-ExportPath` exports fleet data as JSON artifact for CI/CD pipeline job passing
- `-StatusData` parameter on `New-AzLocalFleetStatusHtmlReport` accepts pre-collected data to skip API calls
- Stable JSON schema (v1.0) with SchemaVersion, Timestamp, ModuleVersion, Scope, Readiness, ClusterDetails, LatestRuns, HealthResults

#### Update State Alignment
- All per-update state filters now use module-level constants (`$script:ReadyStates`, `$script:PrereqStates`) aligned with current ARM API states
- `ReadyToInstall` state is now recognized alongside `Ready` across all functions: `Start-AzLocalClusterUpdate`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalFleetStatusData`, `Get-AzLocalUpdateSummary`
- Update summary state checks include `ReadyToInstall` for accurate "Update Available" counting

#### HasPrerequisite & SBE Dependency Awareness
- **`Get-AzLocalAvailableUpdates`**: Now shows HasPrerequisite/AdditionalContentRequired counts alongside Ready counts in console output (both single-cluster and multi-cluster modes)
- **`Get-AzLocalAvailableUpdates`**: Result objects include `PackageType` and `SBEDependency` properties for updates blocked by SBE prerequisites
- **`Get-AzLocalAvailableUpdates`**: Summary section shows clusters blocked by SBE prerequisites with vendor dependency details (Publisher, Family, ReleaseNotes)
- **`Get-AzLocalAvailableUpdates`**: New `-Raw` switch returns unprocessed ARM API objects for programmatic use (internal callers use this automatically)
- **`Start-AzLocalClusterUpdate`**: Provides detailed SBE dependency info when updates are blocked by HasPrerequisite/AdditionalContentRequired state, with guidance to install the SBE from the hardware vendor
- **`Get-AzLocalClusterUpdateReadiness`**: Surfaces `HasPrerequisiteUpdates` and `SBEDependency` in result objects for downstream consumption
- **`Get-AzLocalClusterUpdateReadiness`**: Console output shows "Has Prerequisite (SBE update required)" for clusters with only prerequisite-blocked updates
- **`Get-AzLocalClusterUpdateReadiness`**: Summary section includes count of clusters blocked by SBE prerequisites with vendor-specific guidance
- **`Get-AzLocalFleetStatusData`**: Sequential collection now extracts HasPrerequisite and SBE dependency info into readiness data
- **`Get-AzLocalFleetStatusData`**: Status output shows "Has Prerequisite" for clusters with only prerequisite-blocked updates

#### Maintenance Schedule Tag Support
- **New exported function `Test-AzLocalUpdateScheduleAllowed`**: Master gate that evaluates `UpdateWindow` and `UpdateExclusions` Azure resource tags to determine if an update should proceed
- **New internal function `ConvertFrom-AzLocalUpdateWindow`**: Parses maintenance window tag syntax (`<days>_<HH:MM>-<HH:MM>`) including day ranges, wildcards (`*`/`Daily`), and overnight windows
- **New internal function `ConvertFrom-AzLocalUpdateExclusion`**: Parses exclusion/blackout period tag syntax (`YYYY-MM-DD/YYYY-MM-DD`) with wildcard year support for recurring patterns
- `Start-AzLocalClusterUpdate` now checks schedule tags before applying updates; returns `ScheduleBlocked` status when outside maintenance windows or during exclusion periods
- Exclusion periods take priority over maintenance windows

#### Performance
- `New-AzLocalFleetStatusHtmlReport` now uses single-pass data collection instead of calling 6 separate module functions
- Reduced Azure REST API calls from ~230 to ~85 for 21 clusters (~63% reduction)
- ByTag scope resolves resource IDs upfront via single ARG query instead of each downstream function querying independently
- Update summary, available updates, and health check data fetched once per cluster and reused
- Progress counter shows `[N/M]` per cluster during data collection for better visibility

#### CI/CD Pipeline Improvements
- **Apply Updates pipelines**: Summary now includes `ScheduleBlocked` count alongside Started/Skipped/Failed/HealthBlocked; adds "Actions Required" section with remediation guidance
- **Fleet Update Status pipelines**: HasPrerequisite clusters now appear as `Failed (HasPrerequisite)` in JUnit XML instead of silently passing; SBE vendor details shown in test output
- **Fleet Status JSON**: Summary block now includes `HasPrerequisite` count as a distinct metric (previously lumped into `NotReady`)
- **Fleet Status summaries**: Both GitHub Actions and Azure DevOps summaries now show `SBE Prerequisite Blocked` row and "Actions Required" section
- **Readiness CSV/JSON**: `UpdateWindow` and `UpdateExclusions` tag values now included in readiness output, so ops teams can see which clusters have schedule restrictions

#### Fixed
- `Get-AzLocalClusterInfo`, `Invoke-AzLocalUpdateApply`, and SingleCluster paths in `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalUpdateRuns` had no `az` CLI availability check - previously threw unhelpful `CommandNotFoundException`
- Existing auth check catch blocks now differentiate 'az not installed' from 'az not logged in' with distinct error messages
- 'Up to Date' counter now recognizes `AppliedSuccessfully` state from ARM API (was showing 0 for completed clusters)
- Recommended Update no longer shows the version a cluster is already on when state is `AppliedSuccessfully`/`UpToDate`

### What's New in v0.6.3

#### Bug Fixes, Security & Code Quality
- Fixed `-PassThru` parameter on `Get-AzLocalUpdateSummary` (was missing from param declaration)
- `-OutputPath` now pre-validated upfront (drive existence, .html extension) to fail fast before API calls
- Portal URLs in HTML report now HTML-encoded to prevent attribute injection
- ARG KQL queries now escape single quotes in `UpdateRingValue` to prevent injection
- All dynamic HTML values consistently HTML-encoded
- `Get-CurrentStepPath` has MaxDepth=20 safety limit
- Cluster name matching uses exact segment comparison instead of suffix pattern

### What's New in v0.6.2

#### 📊 New: Fleet Status HTML Report
- **New function `New-AzLocalFleetStatusHtmlReport`** generates self-contained HTML reports for fleet update status
- Collects readiness, update summaries, available updates, health checks, and update run history into a single report
- Executive summary cards with color-coded progress bar showing fleet-wide update adoption
- Cluster Information section with name, current version, node count, resource group, resource ID
- Cluster Status Details with Active Update column (shows in-progress/failed update) and Recommended Update
- Recent Update Run History with recursive Current Step traversal (up to 8+ levels deep)
- Health Check Failures with severity filter (Critical/Warning/Informational) and collapsible per-cluster groups for multi-cluster reports
- Azure Local purple gradient design with embedded Azure Local instance logo
- `-AllClusters` switch discovers all clusters via ARG (v0.6.2 capped at 100; v0.7.0 removes the cap - use `-MaxClusters` to trim); auto-generates title from cluster name for single-cluster reports
- Supports all input methods: `-ClusterResourceIds`, `-ClusterNames`, `-ScopeByUpdateRingTag`, `-AllClusters`
- Use `-PassThru` to capture the HTML string for email body or further processing

```powershell
# Generate HTML report for a single cluster (auto-titles as "Seattle - Update Status Report")
New-AzLocalFleetStatusHtmlReport -ClusterNames Seattle `
    -OutputPath "C:\Reports\seattle.html" -IncludeHealthDetails -IncludeUpdateRuns

# Generate report for all clusters across the subscription (uncapped by default; use -MaxClusters to trim)
New-AzLocalFleetStatusHtmlReport -AllClusters `
    -OutputPath "C:\Reports\fleet-all.html" -IncludeHealthDetails -IncludeUpdateRuns

# Generate report for all Wave1 clusters
New-AzLocalFleetStatusHtmlReport -ScopeByUpdateRingTag -UpdateRingValue "Wave1" `
    -OutputPath "C:\Reports\wave1-status.html" -IncludeHealthDetails -IncludeUpdateRuns
```

#### ⚡ Performance: Resolve-Once Pattern
- All functions that accept `-ClusterNames` now resolve names to resource IDs **once upfront**
- Eliminates redundant API calls when multiple functions are called sequentially
- CI/CD pipelines use `-ClusterResourceIds` consistently (reduces ~800 to ~300 API calls for 100 clusters)
- `Test-AzLocalClusterHealth` accepts `-UpdateSummary` to skip redundant fetch

### What's New in v0.6.1

#### 🏥 New: Pre-Update Health Check Validation
- **New function `Test-AzLocalClusterHealth`** validates cluster health before applying updates
- Queries health check results from ARM (`updateSummaries` resource) to identify Critical, Warning, and Informational failures
- Critical failures block updates from being applied - this function shows you exactly what needs fixing
- Supports `-BlockingOnly` to show only update-blocking issues
- Export results to CSV, JSON, or JUnit XML for CI/CD integration

#### 🔒 Automatic Health Gate in `Start-AzLocalClusterUpdate`
- Before applying an update, the function now automatically checks for Critical health failures (Step 3b)
- If blocking issues are found, the cluster is skipped with detailed failure information and remediation guidance
- No more cryptic "Update is blocked due to health check failure" errors without context

#### 📈 Enhanced Diagnostics in `Get-AzLocalUpdateRuns`
- When the latest update run failed due to health check failures, the function automatically queries and displays the Critical failures
- Shows remediation steps inline so you know exactly what to fix

#### 🔇 Cleaner Console Output with `-PassThru`
- Functions no longer dump object lists to the console by default
- Formatted tables and diagnostics are still displayed — only the raw object output is suppressed
- Use `-PassThru` to return objects for pipeline/variable capture: `$results = Start-AzLocalClusterUpdate ... -PassThru`
- CI/CD pipeline examples updated accordingly

### What's New in v0.5.6 (since v0.5.0)

#### 🚀 Fleet-Scale Operations (NEW)
Six new functions for managing updates across fleets of **1000-3000+ clusters**:

| Function | Description |
|----------|-------------|
| `Invoke-AzLocalFleetOperation` | Orchestrates fleet-wide updates with batching, throttling, and retry logic |
| `Get-AzLocalFleetProgress` | Real-time progress tracking with success/failure percentages |
| `Test-AzLocalFleetHealthGate` | CI/CD health gate to prevent cascading failures between waves |
| `Export-AzLocalFleetState` | Save operation state for resume capability |
| `Resume-AzLocalFleetUpdate` | Resume interrupted operations from checkpoint |
| `Stop-AzLocalFleetUpdate` | Graceful stop with state preservation |

**Enterprise-Scale Features:**
- 📦 **Batch Processing**: Process clusters in configurable batches (default: 50)
- 🔄 **Retry Logic**: Automatic retries with exponential backoff (default: 3 retries)
- 💾 **State Management**: Checkpoint/resume capability for long-running operations
- 🚦 **Health Gates**: Configurable thresholds (default: max 5% failure, min 90% success)
- 📊 **Progress Tracking**: Real-time visibility into fleet-wide operations

**Examples:**
```powershell
# Start fleet-wide update with batching
Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Production" `
    -BatchSize 100 -ThrottleLimit 20 -Force

# Check progress during operation
Get-AzLocalFleetProgress -ScopeByUpdateRingTag -UpdateRingValue "Production" -Detailed

# CI/CD health gate between waves
$gate = Test-AzLocalFleetHealthGate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" `
    -MaxFailurePercent 2 -WaitForCompletion
if (-not $gate.Passed) { exit 1 }

# Resume after interruption
Resume-AzLocalFleetUpdate -StateFilePath "C:\Logs\fleet-state.json" -RetryFailed -Force
```

#### 🏷️ Fleet-Wide Tag Support for All Query Functions
Three functions now support tag-based filtering for fleet-wide operations:

| Function | New Capabilities |
|----------|------------------|
| `Get-AzLocalUpdateSummary` | Query summaries across fleet by tag, name, or resource ID |
| `Get-AzLocalAvailableUpdates` | List available updates across fleet by tag, name, or resource ID |
| `Get-AzLocalUpdateRuns` | Get update run history across fleet by tag, name, or resource ID |

**New Parameters for All Three Functions:**
- `-ClusterNames` / `-ClusterResourceIds` - Query multiple specific clusters
- `-ScopeByUpdateRingTag` + `-UpdateRingValue` - Query clusters by UpdateRing tag
- `-ExportPath` - Export results to CSV, JSON, or JUnit XML (format auto-detected from extension)

**Examples:**
```powershell
# Get update summaries for all Wave1 clusters
Get-AzLocalUpdateSummary -ScopeByUpdateRingTag -UpdateRingValue "Wave1"

# List available updates across Production clusters, export to CSV
Get-AzLocalAvailableUpdates -ScopeByUpdateRingTag -UpdateRingValue "Production" -ExportPath "updates.csv"

# Get latest update run from all Ring2 clusters
Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue "Ring2" -Latest
```

#### 📊 Fleet Update Status Monitoring
- **New CI/CD Pipeline**: Added `Step.6_fleet-update-status.yml` for both GitHub Actions and Azure DevOps
- **JUnit XML Reports**: Each cluster appears as a test case in CI/CD dashboards (passed=healthy, failed=issues)
- **Multiple Output Formats**: CSV, JSON, and JUnit XML exports for different use cases
- **Scheduled Monitoring**: Automated daily checks at 6 AM UTC with configurable scope
- **Dashboard Integration**: Results appear in GitHub Actions Tests tab and Azure DevOps Tests tab with analytics

#### ✅ Consistent Logging & Progress
- **Consistent Logging**: All functions now use `Write-Log` for consistent, timestamped, colored console output
- **Improved Progress Visibility**: `Get-AzLocalUpdateRuns`, `Get-AzLocalClusterUpdateReadiness`, and `Get-AzLocalClusterInventory` now show detailed progress during API operations
- **File Logging Support**: When `$script:LogFilePath` is set, all functions write to log files
- **Severity Levels**: Messages use appropriate levels (Info=White, Warning=Yellow, Error=Red, Success=Green, Header=Cyan)

---

### What's New in v0.5.0

#### 🔐 Security Improvements
- **OpenID Connect (OIDC) Documentation**: Added comprehensive guidance for secretless authentication using federated credentials
- **Authentication Best Practices**: Documented three authentication methods ranked by security (OIDC > Managed Identity > Client Secret)
- **CI/CD Pipeline Updates**: All GitHub Actions workflows now default to OIDC authentication with `id-token: write` permission
- **Azure DevOps Guidance**: Added Workload Identity Federation setup instructions

#### 📖 Documentation
- Added authentication method comparison table with security ratings
- Updated Quick Start guide with OIDC examples
- Added links to Microsoft documentation for federated credentials setup
- Documented subject claim patterns for GitHub Actions (branch, PR, environment, tag)

---

### What's New in v0.4.2

#### 📖 Documentation
- Verified and documented that **all functions work with all three authentication methods**:
  1. **Interactive** - Standard user login via `az login`
  2. **Service Principal** - For CI/CD pipelines using `Connect-AzLocalServicePrincipal`
  3. **Managed Identity (MSI)** - For Azure-hosted agents using `Connect-AzLocalServicePrincipal -UseManagedIdentity`

---

### What's New in v0.4.1

#### 🚀 New Features
- **Managed Identity (MSI) Support**: `Connect-AzLocalServicePrincipal` now supports Managed Identity authentication with `-UseManagedIdentity` switch, ideal for Azure-hosted runners, VMs, and containers

#### 🐛 Bug Fixes
- **CRITICAL**: Fixed Azure Resource Graph queries in `Get-AzLocalClusterInventory`, `Start-AzLocalClusterUpdate`, and `Get-AzLocalClusterUpdateReadiness` that were returning incorrect resource types (mixed resources like networkInterfaces, virtualHardDisks instead of clusters only). The issue was caused by HERE-STRING query format causing malformed az CLI commands. Queries now use single-line string format.
- **CRITICAL**: Fixed `Set-AzLocalClusterUpdateRingTag` failing with JSON deserialization errors when applying tags. Two issues were resolved:
  1. PowerShell/cmd.exe mangling JSON quotes when passed to `az rest --body` - now uses temp file with `@file` syntax
  2. PowerShell hashtable internal properties (`Keys`, `Values`, etc.) being included in JSON - now uses `[PSCustomObject]` with filtered `NoteProperty` members only

#### ✅ Improvements
- `Get-AzLocalClusterInventory` no longer dumps objects to console when using `-ExportPath` (cleaner output with summary and next steps)
- Added `-PassThru` switch to `Get-AzLocalClusterInventory` for CI/CD pipelines that need both CSV export AND returned objects

---

### What's New in v0.4.0

#### 🚀 New Features
- **Cluster Inventory Function**: New `Get-AzLocalClusterInventory` function queries all clusters and their UpdateRing tag status
- **CSV-Based Tag Workflow**: Export inventory to CSV, edit UpdateRing values in Excel, then import back to apply tags
- **CSV Input for Tags**: `Set-AzLocalClusterUpdateRingTag` now accepts `-InputCsvPath` for bulk tag operations
- **JUnit XML Export for CI/CD**: Export results to JUnit XML format for visualization in Azure DevOps, GitHub Actions, Jenkins, and other CI/CD tools

#### ✅ Improvements
- Renamed `-ScopeByTagName` to `-ScopeByUpdateRingTag` (now a switch parameter for clarity)
- Renamed `-TagValue` to `-UpdateRingValue` for consistency
- UpdateRing tag queries now use the standardized 'UpdateRing' tag name
- `-ExportResultsPath` and `-ExportPath` now support `.xml` extension for JUnit format
