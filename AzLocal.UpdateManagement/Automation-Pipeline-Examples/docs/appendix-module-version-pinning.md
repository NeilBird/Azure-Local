# Appendix: Pinning the module version (optional, not recommended)

> This is an **optional** appendix to [section 5 of the CI/CD README](../README.md#5-wire-the-pipeline-files-into-your-repo). The default (install the latest module on each run) is recommended for most estates - read this only if your change-control process requires pinning a specific module version, or you need the YAML-refresh / drift-notice reference.

Every example pipeline installs `AzLocal.UpdateManagement` from PSGallery at runtime instead of importing a vendored copy from the repo. By default the install step pulls the **latest** version on each run - this is the recommended "fix-forward" posture: bug fixes and new safety gates land on your fleet without you having to touch the YAML again.

If your change-control process requires you to pin the module version (so a release on PSGallery cannot change what runs in production without an explicit promotion), set `REQUIRED_MODULE_VERSION`. The install step pins to that exact version when set, and falls back to "latest" when empty.

For temporary validation of an exact listed or unlisted release candidate, use the managed helper and follow the [development-channel testing runbook](development-channel-testing.md). It keeps template refresh, runtime pinning, rollback preflight, and recovery in one ordered workflow.

**Note**: Pinning shifts ongoing maintenance onto you. With a pin in place you are responsible for: (1) periodically checking PowerShell Gallery for new `AzLocal.UpdateManagement` releases; (2) refreshing the pipeline YAMLs in your repository when a new version ships (run `Copy-AzLocalPipelineExample -Update` - see further below); and (3) bumping `REQUIRED_MODULE_VERSION` to match the version those refreshed YAMLs were generated against. If the three drift apart, the drift-notice warnings (see below) lose most of their value.

**GitHub Actions** - resolution order (first non-empty wins):

1. Manual `workflow_dispatch` input `module_version` (per-run override).
2. Repository variable `REQUIRED_MODULE_VERSION` (estate-wide default).
3. Empty (install latest).

```bash
# Set an estate-wide pin (applies to every scheduled / event-triggered run):
gh variable set REQUIRED_MODULE_VERSION --body '0.7.60' --repo <owner>/<repo>

# Override for a single manual run, leaving the estate-wide pin untouched:
gh workflow run fleet-update-status.yml -f module_version=0.7.60

# Clear the estate-wide pin to return to latest:
gh variable delete REQUIRED_MODULE_VERSION --repo <owner>/<repo>
```

**Azure DevOps** - resolution order (first non-empty wins):

1. Queue-time override of the `moduleVersion` pipeline parameter.
2. The pipeline parameter's default (defaults to empty / latest in the shipped YAMLs).

To set an estate-wide pin in ADO, either change the `moduleVersion` parameter default in each YAML, or wrap it in a variable group / template parameter and reference it from each pipeline.

**Drift notices.** Each install step compares three versions and emits a warning annotation (`::notice` in GitHub Actions, `##vso[task.logissue type=warning]` in Azure DevOps) when:

| Situation | What you see | What it means |
|---|---|---|
| `installed > generated` | "Pipeline YAML was generated against AzLocal.UpdateManagement v<X> but the agent installed v<Y>." | Your committed YAML is older than the module on the agent. Pipeline steps may have been improved since - re-run `Update-AzLocalPipelineExample` (with the `-Platform GitHub` / `-Platform AzureDevOps` flag the v0.8.75 annotation now prints for you) to refresh while preserving your `AZLOCAL-CUSTOMIZE` markers. |
| `latest > installed` | "AzLocal.UpdateManagement v<L> is available on PSGallery; this run installed v<I>." | A newer module is on PSGallery than the one the pipeline pinned to. Review the [module CHANGELOG](../../CHANGELOG.md) before bumping `REQUIRED_MODULE_VERSION` (or clear the pin to install the latest automatically). |

Both annotations are warnings, not failures - your pipeline still passes.

**Refreshing pipeline YAMLs after a module upgrade.** When the drift notice fires (or you want to pick up new pipeline features that ship in a module release), re-run the copy command with `-Update`:

```powershell
# Interactive (prompts per file with Y / A / N / L / S / ? options):
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Update

# Unattended (for automation - overwrites every file without prompting):
Copy-AzLocalPipelineExample -Destination .\pipelines -Platform AzureDevOps -Update -Confirm:$false

# Preview which files would change without writing anything:
Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Update -WhatIf
```

The destination folders are under git, so `git diff` after the refresh shows exactly which lines changed - giving you a final review gate before commit. `Copy-AzLocalPipelineExample` deliberately does not expose a `-Force` switch; `-Update` (with optional `-Confirm:$false`) is the only path to overwrite, and git remains the rollback.

**Preserving operator edits across upgrades (v0.7.68+).** For estates that have edited the bundled YAMLs to add custom cron schedules, ITSM secret bindings, or environment-specific tweaks, the marker-aware `Update-AzLocalPipelineExample` is the preferred refresh path. It replaces everything **outside** the documented customisation regions (paired `BEGIN-AZLOCAL-CUSTOMIZE:<region>` / `END-AZLOCAL-CUSTOMIZE:<region>` comments around `schedule-triggers` and ITSM secrets) and **preserves** everything inside them, so a module bump no longer wipes your customer-specific cron lines or secret name mappings:

```powershell
# Preview the marker-aware merge (writes nothing, prints a per-file change manifest):
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -WhatIf

# Interactive merge (prompts per file):
Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub

# Unattended merge:
Update-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Force

# Capture the per-file change manifest:
$report = Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Force -PassThru
```

Use `Copy-AzLocalPipelineExample -Update` when you want a clean overwrite (no operator edits to preserve, or you have intentionally chosen to discard them); use `Update-AzLocalPipelineExample` when you have customised the bundled YAMLs and want to keep those edits.
