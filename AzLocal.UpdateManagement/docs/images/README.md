# Screenshots

This folder holds the screenshots referenced from the module documentation.

## Convention

- Filenames are **kebab-case**, descriptive of the surface they capture (workflow + view), e.g.:
  - `apply-updates-summary.png` - the **Summary** tab of an `apply-updates.yml` (Update: 3) GitHub Actions run
  - `auth-smoke-test-validate-oidc.png` - the **Validate OIDC + RBAC** job page of an `authentication-test.yml` (Config: 1) run
- **Prefer PNG**. Keep each file under ~250 KB; run through `pngquant` / `oxipng` before committing.
- **No secrets**. Subscription IDs, tenant IDs, principal IDs, cluster GUIDs and cluster names must be masked or redacted in the captured frame before the screenshot lands here. The screenshots in this folder are taken from the public-safe `Azure/AzLocal.UpdateManagement` sandbox repo where those values are already replaced with `***`.
- **Capture from the default GitHub dark theme** so the visual style stays consistent across the docs.
- Cap the total set at ~8-10 images. GitHub UI redesigns invalidate screenshots faster than text - keeping the set small reduces refresh effort.

## Referenced by

| File | Section | Image |
|---|---|---|
| [`../../README.md`](../../README.md) | What's New in v0.7.60 (archived in `docs/release-history.md`) | `apply-updates-summary.png` |
| [`../../README.md`](../../README.md) | What's New in v0.8.74 | `monitor-inflight-updates.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 1.1 Why the pipelines are named `Step.N - <description>` | `github-actions-10-pipelines-view.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 5.1 GitHub Actions - auth smoke test | `auth-smoke-test-validate-oidc.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 6.1 Inventory the estate | `inventory-clusters-run-output.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 6.7 Continuous fleet monitoring - monitor-updates | `monitor-inflight-updates.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 6.7 Continuous fleet monitoring - fleet-update-status | `fleet-update-status.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 6.7 Continuous fleet monitoring - fleet-health-status (failures by reason) | `fleet-health-status-part1.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 6.7 Continuous fleet monitoring - fleet-health-status (detailed results) | `fleet-health-status-part-2.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 8.3 Apply-Updates Schedule Coverage Audit - cron coverage remediation | `apply-updates-schedule-audit-part1.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 8.3 Apply-Updates Schedule Coverage Audit - NoWindowTag remediation | `apply-updates-schedule-audit-part2.png` |
| [`../../Automation-Pipeline-Examples/README.md`](../../Automation-Pipeline-Examples/README.md) | 8.3 Apply-Updates Schedule Coverage Audit - cycle calendar (enriched) | `apply-updates-schedule-audit-part3.png` |

When adding or removing an image, update this table and the consuming markdown link in the same commit.
