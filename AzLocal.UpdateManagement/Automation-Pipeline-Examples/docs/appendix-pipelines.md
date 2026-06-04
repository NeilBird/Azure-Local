# Pipeline reference (Appendix A)

> **What you will find here:** A one-row-per-pipeline reference index for every bundled `Step.*.yml` workflow (GitHub Actions + Azure DevOps twins), with a one-line summary of the job, its triggers, the cmdlets it invokes, and the artefacts it produces. Use this as the at-a-glance index after you have read the per-step runbook in the main pipeline [README.md](../README.md).

---

## Appendix A: Pipeline reference

This appendix summarises each pipeline's inputs and outputs without duplicating the YAML.

### Default triggers and schedules (at a glance)

The table below is the ground truth for what each shipped YAML does **out of the box**. Four of the nine pipelines (`fleet-connectivity-status`, `fleet-update-status`, `fleet-health-status`, `apply-updates-schedule-audit`) and one optional (`inventory-clusters` weekly) are pre-wired with `schedule:` (GH) / `schedules:` (ADO) blocks. The remaining four (`authentication-test`, `manage-updatering-tags`, `assess-update-readiness`, `apply-updates`) are manual-only by design.

| Pipeline | GitHub Actions trigger | Azure DevOps trigger | Notes |
|---|---|---|---|
| `authentication-test` (v0.7.70) | `workflow_dispatch` only | `trigger: none` (manual only) | Run on initial wiring + after every RBAC / federated-credential / subscription change. Recommended monthly cadence; add your own `schedule:` block if you want it automated. |
| `inventory-clusters` | `workflow_dispatch` + `schedule: cron '0 6 * * 1'` (Mondays 06:00 UTC) | `trigger: none` + `schedules: cron '0 6 * * 1'` | Weekly drift detection. Edit the cron to change cadence. |
| `manage-updatering-tags` | `workflow_dispatch` only | `trigger: none` (manual only) | Runs on-demand whenever you edit the CSV. |
| `apply-updates-schedule-audit` (v0.7.65) | `workflow_dispatch` + `schedule: cron '0 5 * * 1'` (Mondays 05:00 UTC) | `trigger: none` + `schedules: cron '0 5 * * 1'` | Weekly read-only drift advisor: compares apply-updates cron(s) to `UpdateStartWindow` tags. Runs before the daily fleet pipelines so its annotations are first on Monday mornings. |
| `fleet-connectivity-status` (v0.7.79+; reconciliation enhanced in v0.7.85) | `workflow_dispatch` + `schedule: cron '30 5 * * *'` (daily 05:30 UTC) | `trigger: none` + `schedules: cron '30 5 * * *'` | Daily fleet connectivity / Arc / NIC / Resource Bridge snapshot with bidirectional node-coverage reconciliation. Runs 30 min before `fleet-update-status` so connectivity issues are visible upstream of update reporting. |
| `assess-update-readiness` | `workflow_dispatch` only | `trigger: none` (manual only) | Run on demand before each Apply Updates window, or wire your own schedule. |
| `apply-updates` | `workflow_dispatch` only | `trigger: none` (manual only) | **No schedule shipped** - see the warning in A.6 below. The cluster `UpdateStartWindow` / `UpdateExclusions` tags only gate updates *while the pipeline is running*; they do **not** start the pipeline. |
| `fleet-update-status` | `workflow_dispatch` + `schedule: cron '0 6 * * *'` (daily 06:00 UTC) | `trigger: none` + `schedules: cron '0 6 * * *'` | Daily fleet update snapshot. |
| `fleet-health-status` (v0.7.65) | `workflow_dispatch` + `schedule: cron '0 7 * * *'` (daily 07:00 UTC) | `trigger: none` + `schedules: cron '0 7 * * *'` | Daily 24-hour health-check snapshot. Offset by one hour from `fleet-update-status` to avoid contention. |

> **All times are UTC.** GitHub Actions and Azure DevOps schedules both run on UTC; convert from your local timezone when picking cron values. Both platforms can delay scheduled runs by several minutes during high-load periods - do not rely on second-precision alignment.
>
> **GitHub Actions only**: scheduled workflows are **automatically disabled after 60 days of repository inactivity** (no commits, PRs, or issue activity). Re-enable them via the Actions UI or run any push. Azure DevOps schedules do not have this auto-disable behaviour.

> **Numbering convention:** the A.N sub-sections below mirror the `Step.N_*.yml` filenames 1:1 (e.g. A.4 = `Step.4_fleet-connectivity-status.yml`). The execution order in the [end-to-end runbook](../README.md#6-end-to-end-runbook-bring-an-estate-online) is operational, not numerical - read it for the recommended sequence.

### A.0 Authentication Validation and Subscription Scope Report (v0.7.70)

| Aspect | Value |
|---|---|
| **Purpose** | End-to-end probe of the federated identity, the Azure RBAC role assignment, and the subscriptions the pipeline identity can read. Emits a JUnit-rendered Authentication / Subscription Scope / Resource Graph Reachability report and the full subscription set (`subscriptions.csv` + `subscriptions.json`) so you can detect silent scope drift (a new tenant SP suddenly seeing more or fewer subscriptions than yesterday) before downstream fleet reports under- or over-count clusters. |
| **Inputs** | `environment` (optional - GitHub Actions only; leave blank to test the branch-scoped federated credential), `module_version` (optional). |
| **Trigger** | Manual only (`workflow_dispatch` / **Run pipeline** button). No schedule shipped - run it on initial wiring, after every RBAC / federated-credential / subscription change, and on a recommended monthly cadence. Add your own `schedule:` / `schedules:` block if you want it automated. |
| **Artefacts** | `auth-report.xml` (JUnit, one `<testcase>` per probe), `subscriptions.json`, `subscriptions.csv`, markdown step / run summary with the subscription detail table. |
| **When to run** | First, before importing any of the other eight pipelines. Re-run after every RBAC change, federated-credential change, service-connection change, or subscription move. Re-run monthly as a baseline scope-drift check. |
| **RBAC** | Whatever the pipeline identity has - the probe itself is read-only and intentionally surfaces both over- and under-grants. |

### A.1 Inventory Clusters

| Aspect | Value |
|---|---|
| **Purpose** | Enumerate every Azure Local cluster the identity can see and export to CSV. |
| **Inputs** | None. |
| **Trigger** | Manual (`workflow_dispatch` / **Run pipeline** button) **plus** weekly scheduled run on Mondays at 06:00 UTC (`cron '0 6 * * 1'`). Edit the cron in the YAML to change the day / time. |
| **Artefacts** | `cluster-inventory.csv` (one row per cluster, includes current `UpdateRing` / `UpdateStartWindow` / `UpdateExclusions` and sideloaded-workflow tags). |
| **When to run** | First run of a new estate; periodically (default weekly) to detect new clusters or tag drift. |

### A.2 Manage UpdateRing Tags

| Aspect | Value |
|---|---|
| **Purpose** | Bulk-apply `UpdateRing`, `UpdateStartWindow`, `UpdateExclusions` tags from a CSV. |
| **Inputs** | `csv_path` (required). |
| **Trigger** | Manual only (`workflow_dispatch` / **Run pipeline** button). No schedule shipped - this is a deliberate change-controlled operation that should follow a CSV edit + review. Add a `schedule:` / `schedules:` block if your CSV is auto-generated and you want periodic re-application. |
| **Artefacts** | Pipeline log with added / updated / unchanged counts per cluster. |
| **When to run** | After editing the inventory CSV; whenever ring membership or maintenance windows change. |

### A.3 Apply-Updates Schedule Coverage Audit (v0.7.65)

| Aspect | Value |
|---|---|
| **Purpose** | Read-only advisor that compares the cron schedule(s) in your `Step.6_apply-updates.yml` to the `UpdateStartWindow` tag values present on your clusters, and flags any `(UpdateRing, UpdateStartWindow)` pair that no cron in `Step.6_apply-updates.yml` will ever reach. Never edits tags or YAML. Calls the [`Test-AzLocalApplyUpdatesScheduleCoverage`](../README.md#test-azlocalapplyupdatesschedulecoverage) cmdlet under the covers. |
| **Inputs** | `pipeline_path` (file or folder; default `.github/workflows` on GitHub Actions, `.azure-pipelines` on Azure DevOps - the standard consumer locations for the bundled `Step.6_apply-updates.yml` sample), `lead_time_minutes` (0-60, default 5), `include_untagged` (default false), `module_version` (optional). |
| **Trigger** | Manual (`workflow_dispatch` / **Run pipeline** button) **plus** scheduled weekly on Mondays at 05:00 UTC (`cron '0 5 * * 1'`). Deliberately runs before the daily `fleet-connectivity-status` (05:30 UTC), `fleet-update-status` (06:00 UTC), and `fleet-health-status` (07:00 UTC) pipelines so its drift annotations land at the top of the operator's Monday-morning inbox. Edit the cron in the YAML to change cadence. |
| **Artefacts** | `schedule-coverage-audit.xml` (JUnit, one `<testcase>` per `(UpdateRing, UpdateStartWindow)` pair, uncovered = `<failure>`), `schedule-coverage-audit.csv` (full Audit view with `Status` / `Recommendation` columns), `schedule-coverage-matrix.csv` (every distinct `(Ring, Window)` pair with its required cron), `schedule-coverage-recommend.md` (ready-to-paste GH Actions + Azure DevOps cron blocks), markdown step summary. |
| **When to run** | Hands-off scheduled. Trigger manually whenever you have just tagged a new ring or changed a maintenance window - see the [end-to-end runbook in section 8.3](../README.md#83-end-to-end-runbook-apply-updates-schedule-coverage-audit). |
| **RBAC** | Read-only - same as A.1 (`Reader` on the cluster scope plus `Microsoft.ResourceGraph/resources/read`). No write actions are ever taken. |

### A.4 Fleet Connectivity Status (v0.7.79+; reconciliation enhanced in v0.7.85)

| Aspect | Value |
|---|---|
| **Purpose** | Daily fleet-wide read-only snapshot of Arc agent connectivity, physical NIC inventory + status histogram, Azure Resource Bridge reachability, and a **bidirectional node-coverage reconciliation** between each cluster's `reportedProperties.nodes` and the Arc-tagged physical machines visible in Resource Graph. The v0.7.85 release added the *"How to interpret + act on a non-zero reconciliation"* subsection in the pipeline summary with per-direction remediation lists (positive delta = Arc has more machines than the cluster reports; negative delta = cluster reports more nodes than Arc can see) and an inline Resource Graph query template for triage. Calls the [`Get-AzLocalFleetConnectivityStatus`](../../README.md#get-azlocalfleetconnectivitystatus) cmdlet under the covers. |
| **Inputs** | `subscription_ids` (optional - comma-separated; defaults to every subscription the federated identity can read), `module_version` (optional). v0.7.4-style ITSM toggles are also exposed: `raise_itsm_ticket`, `itsm_config_path`, `itsm_dry_run`, `itsm_force_create` (all optional, default off). |
| **Trigger** | Manual (`workflow_dispatch` / **Run pipeline** button) **plus** scheduled daily at 05:30 UTC (`cron '30 5 * * *'`). Deliberately runs 30 minutes before `fleet-update-status` (06:00 UTC) so connectivity issues are visible upstream of update reporting. Edit the cron in the YAML to change cadence. |
| **Artefacts** | `fleet-connectivity-status.xml` (JUnit, one `<testcase>` per cluster), `fleet-cluster-connectivity.csv` (per-cluster reconciliation), `fleet-arc-status-summary.csv` (per-cluster Arc agent counts), `fleet-arc-non-connected-machines.csv` (per-machine triage list), `fleet-physical-nics.csv` (NIC issues only), `fleet-physical-nic-all.csv` (full NIC inventory), `fleet-physical-nic-stats.csv` (histogram by `NicType` + `NicStatus`), `fleet-arb-status.csv` (Azure Resource Bridge state), markdown job summary including the *"How to interpret + act on a non-zero reconciliation"* guidance subsection. |
| **When to run** | Hands-off scheduled. Trigger manually whenever the apply-updates chain returns "zero ready clusters" or the fleet count drops unexpectedly - Step.4 is the upstream "can we see the fleet at all?" probe. |
| **RBAC** | Read-only - `Reader` plus `Microsoft.ResourceGraph/resources/read`, `Microsoft.AzureStackHCI/edgeDevices/read`, `Microsoft.HybridCompute/machines/read`, and `Microsoft.ResourceConnector/appliances/read`. All four already live in the **`Azure Stack HCI Update Operator`** custom role definition shipped in [section 4.1](../README.md#41-custom-role-azure-stack-hci-update-operator). |

### A.5 Assess Update Readiness

| Aspect | Value |
|---|---|
| **Purpose** | Pre-flight, report-only readiness + blocking-health snapshot for a single `UpdateRing`. **Always succeeds** - per-cluster failures show up as JUnit test failures. |
| **Inputs** | `update_ring` (required), `throttle_limit` (optional). |
| **Trigger** | Manual only (`workflow_dispatch` / **Run pipeline** button). No schedule shipped. To run automatically (e.g. 24-48 hours ahead of every Apply Updates window), add a `schedule:` / `schedules:` block to the YAML - for example `cron '0 6 * * 5'` to run every Friday at 06:00 UTC ahead of weekend maintenance windows. |
| **Artefacts** | `readiness.xml`, `readiness.csv`, `health-blocking.xml`, `health-blocking.csv`. |
| **When to run** | Before an Apply Updates run; or on a schedule a day or two ahead of the maintenance window. |

### A.6 Apply Updates

| Aspect | Value |
|---|---|
| **Purpose** | Apply updates to clusters filtered by `UpdateRing` tag value. |
| **Inputs** | `update_ring` (required), `update_name` (optional - leave blank for latest), `dry_run` (optional), `throttle_limit` (optional). **v0.7.4 adds** `raise_itsm_ticket`, `itsm_config_path`, `itsm_dry_run`, `itsm_force_create` (all optional, defaults preserve existing behaviour). |
| **Trigger** | **Manual only by default** (`workflow_dispatch` / **Run pipeline** button). **No schedule is shipped** - you must add one. See the **mandatory customisation note below** and the schedule-alignment guidance in [section 8](../README.md#8-scheduling-maintenance-windows-and-change-freeze-periods). |
| **Artefacts** | `update-results.xml` (JUnit, one cluster per test), `update-logs/*` (CSV + detail). When ITSM is enabled: `itsm-results.csv`, `itsm-results.xml`. |
| **When to run** | During the maintenance window for each ring, after the readiness assessment is reviewed. |

> **MANDATORY CUSTOMISATION: the Apply Updates pipeline does not ship with a schedule.** The cluster `UpdateStartWindow` / `UpdateExclusions` tags **only gate updates *while the pipeline is already running***; they do **not** start the pipeline. If you (a) use `UpdateStartWindow` tags to define when updates may be installed and (b) leave the shipped `Step.6_apply-updates.yml` with `workflow_dispatch` only (GH) / `trigger: none` (ADO), **no updates will ever be applied automatically** - the pipeline will simply never start during the window.
>
> Add a `schedule:` (GitHub Actions) / `schedules:` (Azure DevOps) block to `Step.6_apply-updates.yml` that fires at (or a few minutes before) the start of every `UpdateStartWindow` you have tagged. One cron entry per distinct window value. Worked examples and the per-cluster scheduling model are in [section 8](../README.md#8-scheduling-maintenance-windows-and-change-freeze-periods).

### A.7 Fleet Update Status

| Aspect | Value |
|---|---|
| **Purpose** | Daily fleet-wide snapshot of cluster update state. Read-only. |
| **Inputs** | Scope (`-AllClusters` or `-ScopeByUpdateRingTag`), `throttle_limit` (optional). |
| **Trigger** | Manual (`workflow_dispatch` / **Run pipeline** button) **plus** scheduled daily at 06:00 UTC (`cron '0 6 * * *'`). Edit the cron in the YAML to change cadence. |
| **Artefacts** | `readiness-status.xml` / `.csv` / `.json`, `cluster-inventory.csv`, `update-summaries.csv`, `available-updates.csv`, `update-runs.csv`. |
| **When to run** | Hands-off scheduled. Trigger manually for ad-hoc reporting. |

### A.8 Fleet Health Status (v0.7.65)

| Aspect | Value |
|---|---|
| **Purpose** | Daily fleet-wide snapshot of **24-hour system health-check failures** surfaced by every Azure Local cluster the identity can see. **Independent of update activity** - clusters that are "up to date" can still surface Critical / Warning issues that need operator triage. Read-only. |
| **Inputs** | `severity` (optional - `Critical`, `Warning`, or `All`; default `All`), `update_ring_tag` (optional - narrow to one wave), `throttle_limit` (optional). |
| **Trigger** | Manual (`workflow_dispatch` / **Run pipeline** button) **plus** scheduled daily at 07:00 UTC (`cron '0 7 * * *'`). Deliberately offset by one hour from `fleet-update-status` (06:00 UTC) to avoid agent and ARM contention. Edit the cron in the YAML to change cadence. |
| **Artefacts** | `fleet-health-status.xml` (JUnit, one `<testcase>` per failing check, grouped under `Critical Health Failures` / `Warning Health Failures` testsuites), `fleet-health-detail.csv` (one row per failing check), `fleet-health-summary.csv` (aggregated by `FailureReason` + `Severity`), markdown job summary. |
| **When to run** | Hands-off scheduled. Trigger manually for ad-hoc fleet-wide health triage outside the daily schedule, especially after operational events (capacity changes, network maintenance, certificate rotations) where health-check failures are expected to spike. |

---
