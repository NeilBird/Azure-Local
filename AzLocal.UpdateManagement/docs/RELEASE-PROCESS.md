# AzLocal.UpdateManagement - Release Process

This document is the maintainer-facing release checklist. Consumers do not need to read it.

The module ships through a **staged unlisted-release flow** that allows end-to-end validation against the real PowerShell Gallery resolver before the candidate becomes the default install. The flow is intentional - leaving `REQUIRED_MODULE_VERSION` empty in pipeline YAMLs installs the latest **listed** version, so an unlisted candidate is invisible to the default install path. Pinning the unlisted candidate explicitly is how the maintainer reproduces what consumers will see once the version is listed.

In the steps below, `<candidate>` is the version being released (for example `1.2.3`).

## Staged unlisted-release flow

```text
 1. Land all work for the candidate version on a feature branch / PR.
 2. Bump ModuleVersion in AzLocal.UpdateManagement.psd1.
 3. Bump GENERATED_AGAINST_MODULE_VERSION in every production pipeline YAML
    under Automation-Pipeline-Examples/ to match the new module version.
    (A Pester guardrail in Tests/AzLocal.UpdateManagement.Tests.ps1
    enforces this; see "Pester guardrails" below.)
 4. Update CHANGELOG.md with a new entry for <candidate>.
 4a. REFRESH IN-PACKAGE DOCS BEFORE PUBLISH. The following Markdown files
    ship inside the published PSGallery .nupkg (Publish-Module.ps1 only
    strips Tests/, Tools/, Publish-Module.ps1, and root-level non-README
    *.md - everything else under the module folder is retained). Any time
    a candidate changes pipeline behaviour, refresh:
      - docs/release-history.md  (current-release pointer + new entry)
      - Automation-Pipeline-Examples/README.md  (section-1 step bullets,
        section 13 file layout, scheduled-triggers paragraph)
      - Automation-Pipeline-Examples/docs/appendix-pipelines.md  (per-step
        Purpose / Inputs / Artefacts / Exit conditions / Introduced rows)
      - ITSM/README.md  (only if ITSM wiring changed)
    Skipping this step ships consumer-visible stale docs that can only be
    corrected by a follow-up republish - see the v0.7.97 release entry
    for the case study.
 5. Run the full Pester suite. Must be green before publish.
 6. Publish to PowerShell Gallery: .\Publish-Module.ps1
   The script immediately unlists the exact published version by default.
   Use -List only when intentionally publishing a version that must become
   the default Gallery install immediately, without staged validation.
 7. Verify the candidate is unlisted in PowerShell Gallery. The version remains
   resolvable by exact pin (-RequiredVersion), but is invisible to Find-Module
   without -AllVersions / -RequiredVersion. If automatic unlisting failed,
   stop and unlist it in Manage Package before continuing.
 8. Verify exact-pin lookup resolves on a clean runner:
        Find-Module    -Name AzLocal.UpdateManagement -RequiredVersion <candidate> -Repository PSGallery
        Install-Module -Name AzLocal.UpdateManagement -RequiredVersion <candidate> -Scope CurrentUser -Force
 9. Copy the bundled pipelines into a separate test repo:
        Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
        Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
10. From the test repo root, run the helper dropped by Copy/Update:
    .\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion <candidate>
  Follow the full [development-channel testing runbook](../Automation-Pipeline-Examples/docs/development-channel-testing.md)
  for the enable, validation, disable, and recovery procedure.
  The helper validates the exact Gallery version and detects GitHub when
  .github\workflows exists. For GitHub it creates or updates the
  REQUIRED_MODULE_VERSION repository variable. For Azure DevOps it prints
  the exact variable-group create/update commands; run the applicable command.
  Use -Platform GitHub or -Platform AzureDevOps to override auto-detection in
  an unusual mixed-layout repository.
    Without this pin, the auto-install step at job start will resolve
    to the previous LISTED version, NOT the candidate - the runtime
    drift warning emitted by the YAML preamble (the
    "installed module older than YAML generated-against" guard) will
    flag this if it slips through.
11. Run the full validation matrix in the test repo:
      - auth-smoke-test               (OIDC + Service Principal paths)
      - inventory-clusters            (read-only ARG)
      - manage-updatering-tags        (dry-run AND committed write)
      - assess-update-readiness       (gating evaluation)
      - apply-updates                 (dry-run; live only on a non-prod cluster)
      - fleet-update-status           (read-only summary)
      - fleet-health-status           (read-only summary)
      - apply-updates-schedule-audit  (read-only schedule advisor)
12. Inspect every JUnit XML and step summary. Failing testcases must
    be triaged before listing.
13. Once validation is clean, LIST the candidate version in PowerShell
    Gallery (Manage Package -> Re-list). The version is now the default
    install for consumers with empty REQUIRED_MODULE_VERSION.
  Remove the test-repo development channel so future runs exercise
  latest-listed resolution:
    .\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -Disable
  Disable restores and preflights the latest-listed templates before removing
  the runtime pin. Do not manually remove the pin first.
  For GitHub the helper deletes the repository variable. For Azure DevOps it
  prints the variable-group delete command; run that command.
14. Tag the git commit (e.g. git tag v<candidate>) and push the tag.
```

## Verification commands

During step 8 (post-unlist, pre-validation):

```powershell
# Exact-pin lookup must resolve to <candidate>.
Find-Module -Name AzLocal.UpdateManagement -RequiredVersion <candidate> -Repository PSGallery

# Default lookup must still show the PREVIOUS listed version (proves the
# candidate is correctly hidden from the default install path).
Find-Module -Name AzLocal.UpdateManagement -Repository PSGallery

# Optionally refresh a local test repo from the unlisted candidate's bundled
# templates without committing or pushing the result.
.\Update-Module-And-Pipelines.ps1 -RequiredVersion <candidate> -NoPush
```

After step 13 (post-relist):

```powershell
# Default lookup must now resolve to <candidate>.
Find-Module -Name AzLocal.UpdateManagement -Repository PSGallery
```

## Why the staged flow matters

- A live publish is irreversible. PowerShell Gallery does not allow re-publishing
  the same version, so if a candidate is broken the only forward path is a new
  version. The staged validation gate must catch issues before consumers hit them.
- An unlisted candidate is still installable via `-RequiredVersion`, so the
  validation runs against the **real** PowerShell Gallery resolver (network,
  signing, dependency probe) - not against a local PSResourceRepo.
- Consumers using `REQUIRED_MODULE_VERSION=''` (the documented "always latest"
  posture) are never exposed to an unlisted candidate. This is by design: the
  runtime drift guard in every production YAML specifically calls out the case
  where the installed module is older than the YAML's generated-against version,
  but firing only on listed versions means an unlisted candidate is silently
  skipped by default-install consumers.

## Pester guardrails that the release flow relies on

The Pester suite in `Tests/AzLocal.UpdateManagement.Tests.ps1` enforces several
release-time invariants. If any of these fail, do not publish.

- **Pipeline YAML version pin** - every production YAML's
  `GENERATED_AGAINST_MODULE_VERSION` matches `ModuleVersion` in the manifest.
  Forces step 3 to happen before step 6.
- **Pipeline YAML installed-older-than-generated guard** - every YAML that
  installs the module from PSGallery contains the warning that fires when
  the installed module is older than the YAML's generated-against version.
- **Schedule-audit pipeline_path default is consumer-friendly** - the
  schedule-audit YAMLs default to `.github/workflows` / `.azure-pipelines`,
  not the in-source `Automation-Pipeline-Examples` path (which would only
  resolve in this repo, not in a consumer's repo).
- **Schedule-audit zero-row JUnit parity** - both schedule-audit YAMLs emit
  the same zero-row testcase so the run renders identically on GitHub
  Actions and Azure DevOps.
- **Doc drift (UpdateRing regex)** - consumer-facing READMEs do not document
  the older strict-single-token UpdateRing regex; only CHANGELOG historical
  entries may reference it.

## Publish-Module.ps1 behaviour

- Stages a clean copy of the module to `C:\Temp\AzLocal.UpdateManagement`.
- Removes `Tests/`, `Publish-Module.ps1`, and `Tools/` from the staging
  copy (repo-only artefacts).
- Strips root-level `*.md` files except `README.md` from the staging copy.
  Subfolder markdown (`ITSM/*.md`, `docs/*.md`,
  `Automation-Pipeline-Examples/README.md`) is retained because consumers
  expect those at the installed footprint.
- Validates the manifest, prompts for the NuGet API key, and publishes to
  PSGallery.

This is why CHANGELOG.md, ad-hoc design notes, and any in-progress
review/action plans can live at the module root without leaking into the
published package: only `README.md` is preserved at the root by the
staging step.

## After release

- Tag and push the release commit (step 14 above).
- Open the tracking issue / feature branch for the next release.
- Confirm the listed version on PSGallery matches `<candidate>` and that
  `Find-Module -Name AzLocal.UpdateManagement -Repository PSGallery`
  resolves to it on a clean runner.
