# AzLocal.UpdateManagement - Release Process

This document is the maintainer-facing release checklist. Consumers do not need to read it.

The module ships through a **staged unlisted-release flow** that allows end-to-end validation against the real PowerShell Gallery resolver before the candidate becomes the default install. The flow is intentional - leaving `REQUIRED_MODULE_VERSION` empty in pipeline YAMLs installs the latest **listed** version, so an unlisted candidate is invisible to the default install path. Pinning the unlisted candidate explicitly is how the maintainer reproduces what consumers will see once the version is listed.

In the steps below, `<candidate>` is the version being released (for example `1.2.3`). Release pull requests must be created through `Tools\New-AzLocalReleasePullRequest.ps1`. That command runs the complete hermetic suite and every live-Azure shard before it invokes `gh pr create`; there is no supported release path that creates the PR first.

## Staged unlisted-release flow

The module is also the distribution unit for the example pipelines and refresh
helpers. Template-only fixes require a module release to reach the normal
Gallery-based update path; publishing does not update consumer repository files.
Release communication must distinguish the local template source, committed YAML,
and runner module selection. See the [operator lifecycle guide](../Automation-Pipeline-Examples/README.md#59-pipeline-ownership-and-upgrade-lifecycle).

GitHub Actions is the primary development and validation platform; ADO examples
target the same module operations without implying equivalent end-to-end evidence.
Record validation separately for each platform and selected version combination:
offline template/module checks, live pipeline runs, and operator acceptance are
different evidence. Mark unexecuted platform scenarios as outstanding rather than
inferring success from shared PowerShell tests. This does not waive the mandatory
pre-PR certification gate or the validation matrix below. Keep platform guidance
in the setup documentation; release notes should describe the actual changes.

```text
 1. Complete all work for the candidate version on a release branch.
 1a. REVIEW EVERY GITHUB ACTION BEFORE EACH MODULE RELEASE. Read each action's
  official release notes, security advisories, and vulnerability notices since
  its currently pinned revision. Consider whether a security fix, relevant bug
  fix, runtime compatibility requirement, or deprecation justifies updating
  to a later version and verified commit SHA. Record the keep/update decision
  and evidence in the release PR; do not upgrade automatically. See
  "GitHub action pin review" below for verification and test requirements.
 1b. REVIEW ADO TASKS AND RUNTIME POWERSHELL DEPENDENCIES BEFORE EACH RELEASE.
  Record approved task references, actual resolved versions where available,
  release/advisory/retirement evidence, and keep/update decisions. Review runtime
  packages independently of tasks. Missing evidence is a review limitation,
  not a clean security result. See "Azure DevOps dependency review" below.
 2. Bump ModuleVersion in AzLocal.UpdateManagement.psd1.
 3. Bump GENERATED_AGAINST_MODULE_VERSION in every production pipeline YAML
    under Automation-Pipeline-Examples/ to match the new module version.
    (A Pester guardrail in Tests/AzLocal.UpdateManagement.Tests.ps1
    enforces this; see "Pester guardrails" below.)
 4. Update CHANGELOG.md with a new entry for <candidate>.
 4a. REFRESH IN-PACKAGE DOCS BEFORE PUBLISH. The following Markdown files
    ship inside the published PSGallery .nupkg through the explicit
    IncludePaths allowlist in Publish-Module.ps1. Tests, release tooling,
    review notes, CHANGELOG.md, and this release-process document are not
    consumer package content. Any time
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
 4b. PRESERVE RELEASE NOTES IN THE SINGLE ARCHIVE. Before replacing the main
    README's "## What's New in v<previous>" section, ensure its complete notes
    are preserved in docs/release-history.md under
    "### What's New in v<previous>". Add a missing entry or merge any missing
    details into the existing entry; never overwrite fuller archived notes.
    Keep the archive newest first with one heading per version. Mirror the
    new release there and update its current-release pointer as in step 4a.
    Keep only the current release's notes in README.md, with exactly one
    current-version H2 and TOC entry. Its Release History section and the
    previous-notes callout must link to docs/release-history.md, not duplicate
    older notes. Verify preservation BEFORE removing outgoing README text,
    then validate version coverage, ordering, and source/staged-package links.
 5. Commit and push the complete release candidate. The certification gate
    rejects uncommitted module or repository-policy changes because its result
    must describe the exact commit that will enter the PR.
 6. Create the release PR only through the mandatory wrapper:
        .\Tools\New-AzLocalReleasePullRequest.ps1 `
            -Title 'Release AzLocal.UpdateManagement v<candidate>' `
            -BodyFile <path-to-pr-body.md> `
            -ThrottleLimit 3
    Before calling `gh pr create`, the wrapper runs:
      - the complete hermetic Pester suite with Live excluded; and
      - all eight read-only live-Azure shards against the approved maintainer
        subscription through Tests\Invoke-LiveTestsParallel.ps1.
    A failed, skipped, or inconclusive live test blocks PR creation. Success
    writes a local receipt under `.git\azlocal-release-gates\<commit>.json`
    containing the exact commit, module version, UTC timestamp, and counts.
    Do not create an AzLocal.UpdateManagement release PR directly with
    `gh pr create`, the GitHub UI, or another client.
 7. After the PR is approved and merged, use the manual GitHub publishing
   workflow described below, or publish locally to PowerShell Gallery:
        .\Publish-Module.ps1
   The script immediately unlists the exact published version by default.
   Use -List only when intentionally publishing a version that must become
   the default Gallery install immediately, without staged validation.
 8. Verify the candidate is unlisted in PowerShell Gallery. The version remains
   resolvable by exact pin (-RequiredVersion), but is invisible to Find-Module
   without -AllVersions / -RequiredVersion. If automatic unlisting failed,
   stop and unlist it in Manage Package before continuing.
 9. Verify exact-pin lookup resolves on a clean runner:
        Find-Module    -Name AzLocal.UpdateManagement -RequiredVersion <candidate> -Repository PSGallery
        Install-Module -Name AzLocal.UpdateManagement -RequiredVersion <candidate> -Scope CurrentUser -Force
10. Copy the bundled pipelines into a separate test repo:
        Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub      -Update
        Copy-AzLocalPipelineExample -Destination .\.azure-pipelines  -Platform AzureDevOps -Update
11. From the test repo root, run the helper dropped by Copy/Update:
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
12. Run the full validation matrix in the test repo:
      - setup-validate-and-inventory  (authentication + read-only inventory)
      - manage-updatering-tags        (dry-run AND committed write)
      - assess-update-readiness       (gating evaluation)
      - apply-updates                 (dry-run; live only on a non-prod cluster)
      - fleet-update-status           (read-only summary)
      - fleet-health-status           (read-only summary)
      - fleet-connectivity-status     (read-only connectivity)
      - monitor-updates               (in-flight reporting)
      - apply-updates-schedule-audit  (read-only schedule advisor)
      - sideload-updates              (opt-in; requires a fabric-connected
        self-hosted Windows runner/agent and an approved pilot cluster;
        follow the sideload guide's acceptance checklist)
13. Inspect every JUnit XML and step summary. Failing testcases must
    be triaged before listing.
14. Once validation is clean, LIST the candidate version in PowerShell
    Gallery (Manage Package -> Re-list). The version is now the default
    install for consumers with empty REQUIRED_MODULE_VERSION.
  Remove the test-repo development channel so future runs exercise
  latest-listed resolution:
    .\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -Disable
  Disable restores and preflights the latest-listed templates before removing
  the runtime pin. Do not manually remove the pin first.
  For GitHub the helper deletes the repository variable. For Azure DevOps it
  prints the variable-group delete command; run that command.
15. Tag the merged release commit (e.g. `git tag v<candidate>`) and push the tag.
16. Create the public GitHub Release from the pushed tag:
    gh release create v<candidate> `
      --verify-tag `
      --title 'AzLocal.UpdateManagement v<candidate>' `
      --generate-notes
  Review the generated notes before publishing and ensure they contain no
  customer names, resource names, email addresses, or other PII. Confirm the
  release targets the same merged commit that was tagged in step 15.
```

## Manual GitHub packaging and publishing

The [Package and Publish workflow](../../.github/workflows/AzLocal.UpdateManagement-publish.yml)
runs only on manual dispatch from `main` in `NeilBird/Azure-Local`. It builds from
the exact dispatch commit, not a moving branch tip. Forks, pull requests, and
other branches cannot run its jobs. No API key is accepted as a workflow input:
dispatch inputs are not secret storage, and this repository's logs and artifacts
must be treated as public.

### One-time publishing setup

Before enabling publishing, a repository administrator must:

1. Create a GitHub environment named `psgallery` under **Settings > Environments**.
2. Restrict its deployment branches to the selected branch `main`. Configure
  required reviewers, prevent self-review, and disable administrator bypass
  where available. Do not rely only on the YAML branch condition: someone with
  workflow-editing rights could change that condition on another branch.
3. Add `PSGALLERY_API_KEY` as an **environment secret**, not a repository variable,
  workflow input, committed file, or command-line literal. Create a short-lived
  Gallery key restricted to `AzLocal.UpdateManagement`, with only the permissions
  needed to push new versions and unlist that package. Rotate or revoke it when
  no longer required. Never paste the key into chat or logs.
4. Protect `main` with required review, including review of workflow, publishing
  script, and packaged source changes. Reviewers approving the environment must
  verify the requested version, dispatch SHA, release certification, and listing
  choice. YAML cannot configure these GitHub protection rules; creating an
  environment without them does not establish an approval gate.

GitHub encrypts the stored secret and releases it to the publishing job after
environment approval. Only the final publish step receives it as an environment
variable. The script takes a `SecureString`, avoids writing the key to disk, and
clears its references afterward. The Gallery client still needs plaintext in
process memory to authenticate; neither masking nor `SecureString` makes executing
untrusted code with the key safe. Keep Actions debug logging disabled for releases.

### Run and download

Open **Actions > AzLocal.UpdateManagement - Package and Publish > Run workflow**,
select `main`, and supply:

| Input | Default | Behaviour |
| --- | --- | --- |
| Operation | `Stage only` | Build and validate the downloadable package without Gallery credentials or publishing. `Publish` also starts the protected publishing job. |
| Expected version | Required | Must exactly match the module manifest; does not change or bump it. |
| Listing | `Unlisted` | Immediately unlist after publishing. `Listed` intentionally leaves the new version public. Ignored for stage-only runs. |

The packaging job uses the existing allow-list in `Publish-Module.ps1`, validates
the staged manifest, and uploads only the staged module tree. Download the artifact
named `AzLocal.UpdateManagement-<version>-<commit>` from the run's **Artifacts**
section. GitHub provides a **single ZIP**, not a ZIP nested inside another ZIP:

```text
AzLocal.UpdateManagement/
  <version>/
   AzLocal.UpdateManagement.psd1
   AzLocal.UpdateManagement.psm1
   ...allow-listed module content...
```

Extract it to a PowerShell module search path, or import the extracted manifest by
path. It is an installable source tree, not a NuGet `.nupkg`. Artifacts expire after
seven days. Stage-only runs do not require the `psgallery` environment or its secret.
The packaging allow-list includes complete approved asset directories; keep those
directories free of credentials, private configuration, and unrelated files.

For `Publish`, the protected job checks out the same immutable commit and rebuilds
the package from source; it does not execute or publish downloaded artifacts. It
verifies official Gallery repository endpoints before exposing the API key. The
workflow uses read-only repository permissions, SHA-pinned actions, ephemeral
GitHub-hosted Windows runners, and no persisted checkout credentials. Concurrent
runs are serialized without automatically cancelling an active publication.

This is intended to take a few minutes, excluding runner queues and approval time;
each job has a ten-minute timeout. It does **not** rerun or replace the mandatory
pre-PR hermetic/live certification or the post-publish consumer validation matrix.
Stage-only success verifies packaging, not runtime acceptance.

Unlisted publishing still briefly creates a listed package before unlisting it.
Cancellation, timeout, or unlisting failure can leave it listed: inspect the Gallery
and unlist manually before continuing. Never blindly retry a partially successful
publish: Gallery versions cannot be overwritten. After consumer acceptance, relist
the existing version through **Manage Package**; do not rerun publishing with
`Listed` to promote an already published version.

## Azure DevOps dependency review

Before every module release, inventory the bundled ADO YAML, including script
shorthand and runtime package installs. The current approved task set is
`PowerShell@2`, `AzureCLI@2`, `PublishPipelineArtifact@1`,
`DownloadPipelineArtifact@2`, `PublishBuildArtifacts@1`, and
`PublishTestResults@2`; `pwsh:` resolves to the PowerShell task. Keep/update
decisions must be explicit even when references remain unchanged.

For each task and runtime PowerShell dependency, record in the release PR:

- Review date, publisher, task/package identity, selected major or package
  constraint, and the actual version from an authorized run or package inventory
  when available. Do not equate the current upstream source version with the
  version deployed in a consumer organization.
- Official release notes, security advisories, vulnerability notices, retirement
  deadlines, and links reviewed since the previous release. Start with the
  [Microsoft task source and releases](https://github.com/microsoft/azure-pipelines-tasks),
  its [security advisories](https://github.com/microsoft/azure-pipelines-tasks/security/advisories),
  and [task retirement guidance](https://learn.microsoft.com/azure/devops/pipelines/tasks/task-retirement).
  Follow each package's official project links from PowerShell Gallery as well.
- Applicability, keep/update decision, rationale, and compatibility/test evidence
  for changes. Include `AzLocal.UpdateManagement`, `powershell-yaml`, `Az.Accounts`,
  and `Az.KeyVault`, and any newly discovered direct or transitive dependency.
  Record unavailable evidence and unresolved findings for maintainer disposition.

The YAML-aware `v0.9.40: Azure DevOps approved task gate` tests in
`Tests/AllowList-And-LoginRetry.Tests.ps1` enforce reviewed explicit references and
step shortcuts across the bundled templates. Run these with the GitHub pinning,
copy/refresh, module metadata, and package tests before the complete hermetic
suite and the mandatory pre-PR certification gate. A new task or version requires
both dependency review and a deliberate test allow-list change; do not merely
weaken the test to make a new dependency pass.

This is repository regression coverage, not an ADO organization policy, script
audit, vulnerability scanner, or immutable dependency lock. Major-only tasks
continue receiving minor updates, and runtime installs are unchanged. Review
material advisories between module releases too. Exact task-version locking and
package integrity controls require separate availability, compatibility, and
security-update planning. See [task version semantics](https://learn.microsoft.com/azure/devops/pipelines/process/tasks#task-versions).

For 0.9.40, the template inventory confirms only the six built-in task references
above, with no task-version or authentication change. The new gate and the
[administrator checklist](../Automation-Pipeline-Examples/README.md#58-azure-devops-dependency-governance)
do not establish that consumer settings or runtime versions have been audited.

### 0.9.40 task and runtime review record

Reviewed on **2026-11-02**. Microsoft task definitions and package manifests were
read at [source commit a2bcfcaf8ed5d990ca12523cd556f2639580e505](https://github.com/microsoft/azure-pipelines-tasks/tree/a2bcfcaf8ed5d990ca12523cd556f2639580e505/Tasks).
These are upstream source versions, NOT versions observed in a consumer
organization; source can be ahead of deployed task releases.

| Template reference | Upstream source version | Decision and rationale |
|---|---|---|
| PowerShell@2 | 2.281.0 | Keep major 2; v281 includes dependency-security remediation. |
| AzureCLI@2 | 2.282.2 | Keep major 2; v279-v281 include argument sanitization, Windows quoting, certificate cleanup, and batch percent-expansion fixes within the selected major. |
| PublishPipelineArtifact@1 | 1.279.0 | Keep major 1; executes through the agent plugin, not a task-local Node package. Validate the consuming agent version. |
| DownloadPipelineArtifact@2 | 2.279.0 | Keep major 2; executes through the agent plugin. This is not the retired DownloadPipelineArtifact@0. |
| PublishBuildArtifacts@1 | 1.281.0 | Keep major 1; v281 includes dependency-security remediation. |
| PublishTestResults@2 | 2.282.0 | Keep major 2; retain current result-publishing behavior and validate against the organization's resolved task version. |

Reviewed [v277](https://github.com/microsoft/azure-pipelines-tasks/releases/tag/v277),
[v278](https://github.com/microsoft/azure-pipelines-tasks/releases/tag/v278),
[v279](https://github.com/microsoft/azure-pipelines-tasks/releases/tag/v279),
[v280](https://github.com/microsoft/azure-pipelines-tasks/releases/tag/v280), and
[v281](https://github.com/microsoft/azure-pipelines-tasks/releases/tag/v281).
The public repository advisory endpoint returned no entries, but the release
notes explicitly identify security fixes; an empty advisory list is not a clean
security bill. Confirm those fixes are deployed in the consuming organization.
None of the six selected majors appears in the
[November 24, 2026 retirement / March 15, 2027 removal list](https://learn.microsoft.com/azure/devops/pipelines/tasks/task-retirement).
Node handler and agent compatibility still require actual platform acceptance.

Gallery metadata was read without installing or upgrading packages:

| Runtime package | Gallery version observed | Decision and evidence |
|---|---|---|
| AzLocal.UpdateManagement | 0.9.39 listed; 0.9.40 local candidate | Retain latest-listed default or explicit pin, with exact imports per job. Do not claim the unpublished candidate is available from Gallery. |
| powershell-yaml | 0.4.12 | Keep existing install behavior. [0.4.12 release notes](https://github.com/cloudbase/powershell-yaml/releases/tag/v0.4.12) fix assembly loading; the offline suites used this version. No Gallery module dependencies are declared. |
| Az.Accounts | 5.5.3 | Keep existing install behavior. [Package notes](https://www.powershellgallery.com/packages/Az.Accounts/5.5.3) improve Get-AzSubscription errors for an MSI tenant mismatch. Local inventory was 5.5.1, so it is not acceptance evidence for 5.5.3. |
| Az.KeyVault | 6.6.1 | Keep existing install behavior. [Package notes](https://www.powershellgallery.com/packages/Az.KeyVault/6.6.1) move the control-plane API to 2026-02-01 ahead of the February 27, 2027 retirement. Declares Az.Accounts >=5.5.3. No local installation or live Key Vault acceptance is claimed. |

The [Azure PowerShell](https://github.com/Azure/azure-powershell/security/advisories)
and [powershell-yaml](https://github.com/cloudbase/powershell-yaml/security/advisories)
public advisory endpoints returned no entries. Task package manifests also expose
dependencies such as azure-pipelines-task-lib, utility-common, azure-arm-rest,
azure-devops-node-api, typed-rest-client, and uuid. Those ranges, bundled SDK/YAML
assemblies, agent plugins, and runtime downloads are not an immutable lock or a
complete transitive vulnerability scan. The keep decision preserves current
resolution behavior; it does not certify every version those ranges can resolve.
Actual ADO task versions, installed package/agent/CLI versions, organization
policy acceptance, and the sideload Key Vault flow remain deployment acceptance
evidence to collect before production promotion. No live ADO acceptance is
claimed by this source review.

## GitHub action pin review

Action revisions are approved centrally in the module templates. Review upstream
releases and security advisories monthly **and as part of every module release**,
accelerating material fixes and runtime compatibility deadlines. For each action,
review official release notes, security advisories, and vulnerability notices
since the pinned revision. Assess applicability of security fixes and relevant
bug fixes, runner/runtime compatibility, deprecations, and breaking changes.
Record the review date, source links, current version/SHA, keep/update decision,
and rationale in the release PR, including when a pin stays unchanged. If updating,
also record the proposed exact version and SHA and the compatibility/test evidence.
Missing or inaccessible advisory information is an explicit review limitation,
not evidence that no vulnerabilities exist. Not every release requires adoption;
do not update solely because a newer tag exists. Resolve selected
tags in the official repository, dereference annotated tags to commits, verify the
commit endpoint there, and record the exact-version tag only when it points to that
same commit. Update SHA and version comment together in active references,
commented alternatives, and executable documentation examples. Keep pins outside
`AZLOCAL-CUSTOMIZE` regions and preserve action inputs and permissions unless a
separate reviewed change requires otherwise.

Run the existing offline Pester template/copy/refresh tests and YAML parser, then
the complete hermetic suite. After the candidate is committed and pushed with
approval, the mandatory pre-PR wrapper must still pass all read-only live-Azure
shards with no failures, skips, or inconclusive results. Offline success is not a
release-gate receipt. Follow the staged publication procedure above; do not bypass
the gate or publish because a pin-only change appears low risk.

Consumers must install/import the approved module and refresh, review, and commit
their workflow files. Module installation alone does not update committed pins.
No moving-tag resolution runs during copy, refresh, or workflow execution.
Pinning stops automatic fixes from moving tags and does not freeze dependencies
or resources an action downloads at runtime. No bot or additional maintenance
automation is introduced by this release.

### 0.9.40 provenance

**Primary release category: Security hardening.** Full commit pins give explicit
control over action revisions and prevent moving-tag changes from silently
altering executed action code. This is not a claim of a specific vulnerability
fix, complete dependency immutability, or organization-policy acceptance.

Verified on **2026-11-02** using authenticated `gh api` against each official
repository. The original moving tags below were resolved, not upgraded. For
annotated refs, `GET /repos/{owner}/{repo}/git/tags/{sha}` was followed until the
object type was `commit`. Each resulting commit was verified using
`GET /repos/{owner}/{repo}/commits/{sha}`; exact versions were matched against the
repository's paginated `tags` endpoint by commit SHA. Links below retain the
original resolution source and the selected immutable commit.

| Action / original tag | Exact version at commit | Verified full commit SHA | Resolution source |
|---|---|---|---|
| actions/checkout v5 | v5.1.0 | [fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09](https://github.com/actions/checkout/commit/fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09) | [v5 ref](https://api.github.com/repos/actions/checkout/git/ref/tags/v5) |
| azure/login v3 | v3.1.0 | [a641126d1b8aa4d1fa005f4f92df94a3a4c4c906](https://github.com/Azure/login/commit/a641126d1b8aa4d1fa005f4f92df94a3a4c4c906) | [v3 ref, annotated](https://api.github.com/repos/azure/login/git/ref/tags/v3) |
| actions/upload-artifact v6 | v6.0.0 | [b7c566a772e6b6bfb58ed0dc250532a479d7789f](https://github.com/actions/upload-artifact/commit/b7c566a772e6b6bfb58ed0dc250532a479d7789f) | [v6 ref](https://api.github.com/repos/actions/upload-artifact/git/ref/tags/v6) |
| actions/download-artifact v7 | v7.0.0 | [37930b1c2abaa49bbe596cd826c3c89aef350131](https://github.com/actions/download-artifact/commit/37930b1c2abaa49bbe596cd826c3c89aef350131) | [v7 ref](https://api.github.com/repos/actions/download-artifact/git/ref/tags/v7) |
| dorny/test-reporter v3 | v3.2.0 | [d1b5dff021aa968b288b02285a8bf47471c5928a](https://github.com/dorny/test-reporter/commit/d1b5dff021aa968b288b02285a8bf47471c5928a) | [v3 ref, annotated](https://api.github.com/repos/dorny/test-reporter/git/ref/tags/v3) |

Executable documentation-only examples retain their original majors too:

| Action / original tag | Exact version at commit | Verified full commit SHA | Resolution source |
|---|---|---|---|
| azure/login v2 | v2.3.1 | [7184910d9eb2b1c5e48f7073824a90609bb9b6d6](https://github.com/Azure/login/commit/7184910d9eb2b1c5e48f7073824a90609bb9b6d6) | [v2 ref, annotated](https://api.github.com/repos/azure/login/git/ref/tags/v2) |
| actions/upload-artifact v4 | v4.6.2 | [ea165f8d65b6e75b540449e92b4886f43607fa02](https://github.com/actions/upload-artifact/commit/ea165f8d65b6e75b540449e92b4886f43607fa02) | [v4 ref](https://api.github.com/repos/actions/upload-artifact/git/ref/tags/v4) |
| dorny/test-reporter v1 | No matching exact-version tag found; labelled resolved v1 | [3eeb9fc888e82e8be2fb356bbeec2750231672bc](https://github.com/dorny/test-reporter/commit/3eeb9fc888e82e8be2fb356bbeec2750231672bc) | [v1 ref](https://api.github.com/repos/dorny/test-reporter/git/ref/tags/v1) |

The legacy ITSM design examples remain historical/deferred examples, not upgrades
to the production workflow action majors. Historical changelog entries and prose
version mentions are not rewritten.

### 0.9.40 action review record

Reviewed on **2026-11-02** using each official repository's paginated `releases`
and public `security-advisories` endpoints. The current version/SHA pairs are in
the provenance tables above. The implementation decision is to retain those
revisions for this behavior-preserving pinning release; it is not approval of a
future action upgrade or evidence that these revisions have no vulnerabilities.
Carry this record and its limitations into the release PR for maintainer review.

| Action | Release/advisory evidence | Keep/update decision and follow-up |
|---|---|---|
| actions/checkout | [v5.1.0](https://github.com/actions/checkout/releases/tag/v5.1.0) already contains the safer PR-checkout backport. [v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1) adds fixes; intervening majors change credential storage and module packaging. | Keep v5.1.0, matching the original v5 resolution. Evaluate a later major separately against runner and credential behavior. |
| azure/login | [v3.1.0](https://github.com/Azure/login/releases/tag/v3.1.0) was the latest published release returned and includes dependency updates. | Keep v3.1.0; no newer published release was returned by this review. |
| actions/upload-artifact | [v7.0.0](https://github.com/actions/upload-artifact/releases/tag/v7.0.0) adds direct-file uploads and ESM packaging; [v7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2) updates the artifact dependency and retry behavior. | Keep v6.0.0 for this pin-only change. Consider the later major with artifact compatibility and retry validation. |
| actions/download-artifact | [v8.0.0](https://github.com/actions/download-artifact/releases/tag/v8.0.0) makes digest mismatches fail by default and changes decompression behavior; [v8.0.2](https://github.com/actions/download-artifact/releases/tag/v8.0.2) improves retries. [GHSA-cxww-7g56-2vh6](https://github.com/actions/download-artifact/security/advisories/GHSA-cxww-7g56-2vh6) lists an affected range of >=4.0.0 and <4.1.3, which excludes v7.0.0. | Keep v7.0.0 to preserve behavior. Prioritize a separately reviewed upgrade for enforced digest checking, with explicit artifact compatibility and failure-path tests. |
| dorny/test-reporter | The releases API has no v3.2.0 release object, but the [changelog at the verified commit](https://github.com/dorny/test-reporter/blob/d1b5dff021aa968b288b02285a8bf47471c5928a/CHANGELOG.md) documents v3.2.0 TRX outcome/aborted-run and nested JUnit fixes, plus v3.1.0 dependency-security updates and parsing/escaping fixes. | Keep v3.2.0. The source changelog supplies the missing change evidence; retain Node 24 runner compatibility and validate actual result publishing during platform acceptance. |

The public advisory endpoints returned no entries for checkout, login,
upload-artifact, or test-reporter. This is a bounded repository-advisory check,
not an exhaustive vulnerability or transitive-dependency audit. A source changelog
does not replace platform acceptance. The documentation-only legacy pins
retain their original majors; they are not newly certified deployment choices.
No action upgrade or live action compatibility test was performed during this
review. Publication and the remaining acceptance gates below remain separate.

### Outstanding rollout gates

- A clean, pushed candidate and the mandatory exact-commit pre-PR certification
  receipt are required before PR creation. Neither authorizes publication.
- After approved publication and consumer refresh, validate checkout, Azure
  authentication, artifact upload, artifact download, and test reporting in an
  authorized non-production environment. Cover all five distinct action types;
  do not trigger cluster updates or other state-changing workflows merely to test
  pins. Record workflow/run IDs and results as live acceptance evidence.
- Confirm the consuming organization's policy accepts the refreshed workflows.
  YAML parsing and offline tests do not establish that acceptance or an enforcement
  date. Record consumer refresh and policy acceptance evidence in the appropriate
  tracking system. Keep private repository names, issue links, and operational
  details out of public release documentation and pull requests.

## Verification commands

During step 9 (post-unlist, pre-validation):

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

After step 14 (post-relist):

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
- Publishing and unlisting are separate Gallery operations, not an atomic
  staging transaction. A candidate is briefly listed after publish; unlisting
  can fail and leave it listed. Latest-listed consumers can select it during
  that window. Explicit runtime pins and controlled rollout windows are needed
  when that exposure is unacceptable. Verify the default Gallery lookup after
  unlisting; do not assume the script completed both operations successfully.
- After successful unlisting, default Gallery resolution skips the candidate.
  The v0.9.40 templates resolve latest-listed once per job and import that exact
  version throughout the job, so a newer installed but unlisted copy cannot
  override the selection. Earlier templates must be refreshed to gain this fix.

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
- **Canonical release-history retention** - `docs/release-history.md` retains
  non-empty, uniquely headed entries in newest-first order, including releases
  from v0.9.37 onward recorded in CHANGELOG.md and older entries recovered from
  the README. The README links to that archive and keeps only its current
  `What's New` section. Review the outgoing notes against the archive as well:
  structural tests do not establish that every historical detail was preserved.

## Publish-Module.ps1 behaviour

- Stages a clean copy of the module to `C:\Temp\AzLocal.UpdateManagement`.
- Copies only the explicit `IncludePaths` allowlist. New consumer documentation
  outside an included directory must be added to that list deliberately.
  `Tools/Invoke-AzLocalSideloadCopyTask.ps1` is included for runtime use.
- Includes the README, selected reference documents, pipeline examples, and ITSM
  content. Tests, review notes, this document, and CHANGELOG.md are excluded.
- `-StageOnly` stages and validates without prompting for a key or publishing.
- Validates the manifest, prompts for the NuGet API key, and publishes to
  PSGallery.

Validate links against both the source tree and the staged package. Link from
consumer documentation to the repository URL for intentionally excluded files.

## After release

- Tag and push the release commit (step 15 above).
- Create and review the GitHub Release from that tag (step 16 above).
- Open the tracking issue / feature branch for the next release.
- Confirm the listed version on PSGallery matches `<candidate>` and that
  `Find-Module -Name AzLocal.UpdateManagement -Repository PSGallery`
  resolves to it on a clean runner.
