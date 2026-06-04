# Smoke-test Coverage Matrix

This document maps each bundled `Step.N_*.yml` pipeline to the smoke-test
script(s) that validate its underlying ARG queries and cmdlet wiring against
a live subscription. Smoke tests run the **same cmdlet calls** the pipelines
make and assert the returned schema matches the documented shape - so any
ARG-query regression, column rename, or cmdlet signature drift is caught
locally (or in a manual CI run) **before** the pipeline-driver YAML is
exercised in a real GHA / ADO run.

## Coverage table

| Pipeline | Cmdlets invoked | Unified harness | Dedicated harness |
|---|---|---|---|
| `Step.0_authentication-test.yml` | (workflow-self - probes `az graph query` + auth) | n/a | covered by running the workflow |
| `Step.1_inventory-clusters.yml` | `Get-AzLocalClusterInventory` | [validate-arg-queries.ps1](validate-arg-queries.ps1) | [smoke-test-inventory.ps1](smoke-test-inventory.ps1) |
| `Step.2_manage-updatering-tags.yml` | `Set-AzLocalClusterUpdateRingTag` (write-only) | n/a | n/a (write path; out of scope) |
| `Step.3_apply-updates-schedule-audit.yml` | `Test-AzLocalApplyUpdatesScheduleCoverage` | [validate-arg-queries.ps1](validate-arg-queries.ps1) | [smoke-test-schedule-audit.ps1](smoke-test-schedule-audit.ps1) |
| `Step.4_fleet-connectivity-status.yml` | `Get-AzLocalFleetConnectivityStatus` | [validate-arg-queries.ps1](validate-arg-queries.ps1) | [smoke-test-connectivity-status.ps1](smoke-test-connectivity-status.ps1) |
| `Step.5_assess-update-readiness.yml` | `Get-AzLocalClusterInventory`, `Get-AzLocalClusterUpdateReadiness`, `Test-AzLocalClusterHealth -BlockingOnly` | [validate-arg-queries.ps1](validate-arg-queries.ps1) | [smoke-test-assess-readiness.ps1](smoke-test-assess-readiness.ps1) |
| `Step.6_apply-updates.yml` | `Get-AzLocalClusterUpdateReadiness` (read), `Start-AzStackHciUpdate` (write) | [validate-arg-queries.ps1](validate-arg-queries.ps1) covers the read | n/a (write path; readiness already covered) |
| `Step.7_monitor-updates.yml` (v0.7.90) | `Get-AzLocalClusterInventory`, `Get-AzLocalUpdateRuns -Latest` | [validate-arg-queries.ps1](validate-arg-queries.ps1) | [smoke-test-monitor-updates.ps1](smoke-test-monitor-updates.ps1) |
| `Step.8_fleet-update-status.yml` | `Get-AzLocalClusterInventory`, `Get-AzLocalClusterUpdateReadiness`, `Get-AzLocalLatestSolutionVersion`, `Get-AzLocalUpdateRunFailures`, `Get-AzLocalUpdateSummary`, `Get-AzLocalAvailableUpdates`, `Get-AzLocalUpdateRuns -Latest` | [validate-arg-queries.ps1](validate-arg-queries.ps1) | [smoke-test-fleet-update-status.ps1](smoke-test-fleet-update-status.ps1) |
| `Step.9_fleet-health-status.yml` | `Get-AzLocalFleetHealthOverview`, `Get-AzLocalFleetHealthFailures -View Detail` | [validate-arg-queries.ps1](validate-arg-queries.ps1) | [smoke-test-fleet-health-status.ps1](smoke-test-fleet-health-status.ps1) |
| `ITSM/*.yml` connector | `Send-AzLocalUpdateNotification` + downstream connector | n/a (covered by `ITSM/Tests/` Pester) | n/a (mock-only - no live target) |

## Two harness families

- **Unified harness** ([validate-arg-queries.ps1](validate-arg-queries.ps1))
  exercises every pipeline-driver cmdlet in a single pass. Use it as the
  first check after every cmdlet change: one run validates the whole
  pipeline fleet. Output: row counts + PASS/PASS-EMPTY/FAIL-SCHEMA/ERROR
  per cmdlet, plus a final summary table. Exit non-zero if any fails.

- **Dedicated per-pipeline harnesses** (`smoke-test-*.ps1`) exercise the
  cmdlets a specific pipeline calls **in the exact sequence the YAML
  executes**. Use these when working on a single pipeline (faster, more
  focused output) or to reproduce a pipeline-specific failure mode that
  the unified harness can't surface (for example: cmdlet output piped into
  a second cmdlet's `-ClusterResourceIds`).

Both styles use the same classification taxonomy:

| Status | Meaning |
|---|---|
| `PASS` | Cmdlet returned rows and every required column is present |
| `PASS-EMPTY` | Cmdlet returned 0 rows but did not error (query parsed and executed) |
| `FAIL-SCHEMA` | Cmdlet returned rows but one or more required columns are missing |
| `ERROR` | Cmdlet threw - inspect the captured exception message |

Exit code is `1` if any section is `FAIL-SCHEMA` or `ERROR`, `0` otherwise.

## Prerequisites

- Azure CLI on PATH and signed in (`az login`)
- Signed-in identity has at least `Reader` on the target subscription(s)
- Pass `-SubscriptionId` to override the default subscription (or use
  `az account set --subscription <id>` beforehand)

## Adding a new pipeline

When introducing a new `Step.N_*.yml` pipeline:

1. Add the cmdlet(s) it calls to [validate-arg-queries.ps1](validate-arg-queries.ps1).
2. If the pipeline composes cmdlets in a non-trivial way (output of one
   feeds into another, multi-stage scoping, ring filtering), create a
   dedicated `smoke-test-<pipeline-suffix>.ps1` that mirrors the YAML's
   sequence. Follow the section pattern in
   [smoke-test-connectivity-status.ps1](smoke-test-connectivity-status.ps1).
3. Add a row to the coverage table above.
