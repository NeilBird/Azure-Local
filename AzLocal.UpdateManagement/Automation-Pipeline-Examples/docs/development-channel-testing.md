# Development-channel testing

Use the development channel to validate an exact `AzLocal.UpdateManagement` PowerShell Gallery version before it becomes the latest listed release. The workflow applies the same version to local pipeline templates and the pipeline runtime pin, so tests exercise one coherent candidate.

This is a release-validation mechanism, not a permanent production pin. For long-lived version pinning, see [Module version pinning](appendix-module-version-pinning.md).

## Prerequisites

- Run from a pipeline repository populated by `Copy-AzLocalPipelineExample` or `Update-AzLocalPipelineExample`.
- Confirm that the repo root contains `DevChannel\Apply-ModuleDevelopmentChannel.ps1` and `Update-Module-And-Pipelines.ps1`.
- Publish the candidate to PowerShell Gallery. It may be unlisted, but exact `-RequiredVersion` lookup must resolve it.
- Authenticate GitHub CLI with permission to manage Actions repository variables when using GitHub.
- For Azure DevOps, know the ID of the variable group linked to the pipelines and authenticate Azure CLI before running the printed command.
- Start with a clean worktree. Unless `-NoPush` is used, the updater commits and pushes refreshed pipeline files.

Verify the candidate first:

```powershell
Find-Module -Name AzLocal.UpdateManagement -RequiredVersion <candidate> -Repository PSGallery
```

## Enable the channel

From the pipeline repository root:

```powershell
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion <candidate>
```

The helper performs these operations in order:

1. Validates that PowerShell Gallery resolves the exact candidate.
2. Calls `Update-Module-And-Pipelines.ps1 -RequiredVersion <candidate>`.
3. Installs and imports that exact module version, refreshes the pipeline YAMLs from its bundled templates, and commits and pushes changed managed files.
4. Applies the runtime pin only after the local refresh succeeds.

For GitHub, step 4 creates or updates the non-secret repository variable `REQUIRED_MODULE_VERSION` through `gh`. For Azure DevOps, the helper prints the variable-group create and update commands; replace `<group-id>` and run the applicable command.

`-Platform Auto` selects GitHub when `.github\workflows` exists at the repo root and Azure DevOps otherwise. Override mixed or unusual layouts explicitly:

```powershell
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion <candidate> -Platform GitHub
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion <candidate> -Platform AzureDevOps
```

Use `-NoPush` to leave refreshed files uncommitted for review. The platform pin is still changed after a successful local refresh, so commit and push the reviewed files before starting pipeline validation.

## Validate the candidate

Queue the complete platform validation matrix after both the refreshed YAMLs and runtime pin are present:

- authentication smoke test
- inventory collection
- update-ring tag dry run and committed write
- update-readiness assessment
- apply-updates dry run, plus live execution only on an approved non-production cluster
- fleet update status
- fleet health status
- apply-updates schedule audit

Inspect every run summary, JUnit report, `pipeline-timings.json`, and any requested diagnostic transcript. Confirm the installed module version reported by each pipeline equals the candidate.

## Disable and roll back

After the candidate is listed, or when testing must stop, run:

```powershell
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -Disable
```

Disable uses the reverse safety order:

1. Resolves and imports the latest listed Gallery version without falling back to a possibly unlisted installed version.
2. Preflights pipeline rollback with that target module before changing files or uninstalling newer versions.
3. Refreshes and commits the latest-listed templates.
4. Removes the GitHub runtime pin, or prints the Azure DevOps variable-group delete command.

This ordering ensures a failed rollback leaves the candidate pin in place instead of running older templates with a newer unlisted module.

### Newer installed versions

PowerShell can auto-load the highest installed version in a fresh session. During `-Disable`, each installed version newer than the latest listed release therefore requires confirmation before uninstalling.

Use `-KeepNewerVersions` only when side-by-side retention is intentional:

```powershell
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -Disable -KeepNewerVersions
```

Fresh sessions may still auto-load a retained candidate unless every import uses `-RequiredVersion`.

### Rollback marker preflight

An older template may not contain an `AZLOCAL-CUSTOMIZE` section introduced by the candidate. The updater preserves markers shared by both versions, but stops before rollback when a destination-only marker would be removed. The error lists each file and marker, and no pipeline files or newer installed module versions are changed by that blocked preflight.

Review the named marker bodies and the target template. Approve only the reported rollback-specific removals with:

```powershell
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -Disable -AllowRollbackMarkerRemoval
```

This switch does not permit unrelated overwrites and does not weaken preservation of marker names present in both template versions.

## Recovery paths

### Candidate lookup fails

Wait for PowerShell Gallery propagation and rerun the exact `Find-Module` command. `-SkipGalleryValidation` bypasses the helper's first lookup but the updater still requires the exact version, so use it only to diagnose propagation behavior.

### Local refresh fails before pinning

Fix the reported install, template, git, or push failure and rerun the enable command. The platform runtime pin has not changed.

### Local refresh succeeds but GitHub pinning fails

The repository contains candidate templates but pipelines still resolve their previous runtime version. Correct `gh auth status`, repository permissions, or the `-Repository owner/name` value, then rerun with `-SkipPipelineRefresh`:

```powershell
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion <candidate> -Repository <owner>/<repo> -SkipPipelineRefresh
```

### Azure DevOps command is not applied

The local refresh is complete, but no remote change occurs until an operator runs the printed `az pipelines variable-group variable create` or `update` command. Apply it, then verify `REQUIRED_MODULE_VERSION` in the linked variable group before queuing tests.

### Disable preflight reports marker loss

Do not remove the runtime pin first. Review the reported marker bodies, then rerun disable with `-AllowRollbackMarkerRemoval` only when their removal is expected.

### Disable is cancelled at module cleanup

The runtime pin remains in place. Rerun and approve removal, or explicitly accept side-by-side auto-loading risk with `-KeepNewerVersions`.

### Templates are already restored but the pin remains

Use `-Disable -SkipPipelineRefresh` to remove only the stale GitHub pin or print the Azure DevOps delete command:

```powershell
.\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -Disable -SkipPipelineRefresh
```

Use this recovery override only after verifying the checked-in pipeline templates are already generated from the desired latest-listed module.

## Managed-file behavior

Copy and Update place the helper at `DevChannel\Apply-ModuleDevelopmentChannel.ps1`. A higher bundled `AZLOCAL-DEVELOPMENT-CHANNEL-VERSION` refreshes an older managed helper. An existing markerless file is operator-owned and is never overwritten. Pass `-SkipDevelopmentChannelHelper` to Copy or Update when the repository must not receive this helper.
