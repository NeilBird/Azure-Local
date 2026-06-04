@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.7.90'

    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')

    # ID used to uniquely identify this module
    GUID = 'a8b9c0d1-e2f3-4a5b-6c7d-8e9f0a1b2c3d'

    # Author of this module
    Author = 'Neil Bird, Microsoft'

    # Company or vendor of this module
    CompanyName = 'Microsoft'

    # Copyright statement for this module
    Copyright = '(c) Microsoft. All rights reserved.'

    # Description of the functionality provided by this module
    Description = 'PowerShell module to manage Azure Local (formerly Azure Stack HCI) cluster updates using Azure Update Manager APIs. Provides functions to start updates, check update status, list available updates, and monitor update runs. Renamed from AzStackHci.ManageUpdates in v0.7.3 to align with the Azure Local product name.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
    NestedModules = @(
        # Private helpers (loaded first)
        'Private/Convert-AzLocalUpdateWindowToCron.ps1',
        'Private/ConvertFrom-AzLocalCronExpression.ps1',
        'Private/ConvertFrom-AzLocalUpdateExclusion.ps1',
        'Private/ConvertFrom-AzLocalScheduleYaml.ps1',
        'Private/ConvertFrom-AzLocalUpdateExcluded.ps1',
        'Private/ConvertFrom-AzLocalUpdateSideloaded.ps1',
        'Private/ConvertFrom-AzLocalUpdateWindow.ps1',
        'Private/Convert-AzLocalScheduleSchemaVersion.ps1',
        'Private/ConvertTo-AzLocalAdditionalProperties.ps1',
        'Private/ConvertTo-SafeCsvCollection.ps1',
        'Private/ConvertTo-SafeCsvField.ps1',
        'Private/ConvertTo-ScrubbedCliOutput.ps1',
        'Private/ConvertTo-AzLocalUpdateRingKqlFilter.ps1',
        'Private/Export-ResultsToJUnitXml.ps1',
        'Private/Format-AzLocalDurationHuman.ps1',
        'Private/Format-AzLocalIncidentBody.ps1',
        'Private/Format-AzLocalUpdateRun.ps1',
        'Private/Get-AzLocalClusterUpdateRuns.ps1',
        'Private/Get-AzLocalItsmDedupeKey.ps1',
        'Private/Get-AzLocalItsmTriggerDecision.ps1',
        'Private/Get-AzLocalModuleRootManifestPath.ps1',
        'Private/Get-AzLocalPipelineCustomiseMarkers.ps1',
        'Private/Get-AzLocalRunEndTime.ps1',
        'Private/Get-CurrentStepPath.ps1',
        'Private/Get-ExportFormat.ps1',
        'Private/Get-HealthCheckFailureSummary.ps1',
        'Private/Get-LastUpdateRunErrorSummary.ps1',
        'Private/Get-LatestUpdateByYYMM.ps1',
        'Private/Get-TagValue.ps1',
        'Private/Import-AzLocalFleetState.ps1',
        'Private/Install-AzGraphExtension.ps1',
        'Private/Invoke-AzCliJson.ps1',
        'Private/Invoke-AzLocalSideloadedAutoReset.ps1',
        'Private/Invoke-AzLocalSideloadedAutoResetForCluster.ps1',
        'Private/Invoke-AzLocalItsmHttp.ps1',
        'Private/Invoke-AzLocalServiceNowAdapter.ps1',
        'Private/Invoke-AzResourceGraphQuery.ps1',
        'Private/Invoke-AzRestJson.ps1',
        'Private/Invoke-AzLocalUpdateApply.ps1',
        'Private/Invoke-FleetJobsInParallel.ps1',
        'Private/Invoke-FleetOpClusterAction.ps1',
        'Private/Read-AzLocalApplyUpdatesYamlCrons.ps1',
        'Private/Resolve-AzLocalItsmSecret.ps1',
        'Private/Resolve-AzLocalUpdateRunDeepestError.ps1',
        'Private/Resolve-SafeOutputPath.ps1',
        'Private/Resolve-WildcardDate.ps1',
        'Private/Resolve-WildcardDateRange.ps1',
        'Private/Set-AzLocalClusterTagsMerge.ps1',
        'Private/Test-AzCliAvailable.ps1',
        'Private/Test-AzLocalAllowedUpdateVersionsString.ps1',
        'Private/Test-AzLocalUpdateExclusion.ps1',
        'Private/Test-AzLocalUpdateExcludedAllowed.ps1',
        'Private/Test-AzLocalUpdateSideloadedAllowed.ps1',
        'Private/Test-AzLocalUpdateVersionInProgressMatch.ps1',
        'Private/Test-AzLocalUpdateWindow.ps1',
        'Private/Test-ExportPathWritable.ps1',
        'Private/Write-Log.ps1',
        'Private/Write-UpdateCsvLog.ps1',
        'Private/Write-Utf8NoBomFile.ps1',

        # Public exported functions
        'Public/Connect-AzLocalServicePrincipal.ps1',
        'Public/Copy-AzLocalItsmSample.ps1',
        'Public/Copy-AzLocalPipelineExample.ps1',
        'Public/Export-AzLocalFleetState.ps1',
        'Public/Get-AzLocalApplyUpdatesScheduleConfig.ps1',
        'Public/Get-AzLocalApplyUpdatesScheduleNextFirings.ps1',
        'Public/Get-AzLocalAvailableUpdates.ps1',
        'Public/Get-AzLocalClusterInfo.ps1',
        'Public/Get-AzLocalClusterInventory.ps1',
        'Public/Get-AzLocalClusterUpdateReadiness.ps1',
        'Public/Get-AzLocalFleetProgress.ps1',
        'Public/Get-AzLocalFleetStatusData.ps1',
        'Public/Get-AzLocalFleetHealthFailures.ps1',
        'Public/Get-AzLocalFleetHealthOverview.ps1',
        'Public/Get-AzLocalItsmConfig.ps1',
        'Public/Get-AzLocalLatestSolutionVersion.ps1',
        'Public/Get-AzLocalUpdateRunFailures.ps1',
        'Public/Get-AzLocalUpdateRuns.ps1',
        'Public/Get-AzLocalUpdateSummary.ps1',
        'Public/Invoke-AzLocalFleetOperation.ps1',
        'Public/New-AzLocalApplyUpdatesScheduleConfig.ps1',
        'Public/New-AzLocalFleetStatusHtmlReport.ps1',
        'Public/New-AzLocalIncident.ps1',
        'Public/Reset-AzLocalSideloadedTag.ps1',
        'Public/Resolve-AzLocalCurrentUpdateRing.ps1',
        'Public/Resume-AzLocalFleetUpdate.ps1',
        'Public/Set-AzLocalClusterUpdateRingTag.ps1',
        'Public/Start-AzLocalClusterUpdate.ps1',
        'Public/Stop-AzLocalFleetUpdate.ps1',
        'Public/Test-AzLocalApplyUpdatesScheduleCoverage.ps1',
        'Public/Test-AzLocalClusterHealth.ps1',
        'Public/Test-AzLocalFleetHealthGate.ps1',
        'Public/Test-AzLocalItsmConnection.ps1',
        'Public/Test-AzLocalUpdateScheduleAllowed.ps1',
        'Public/Update-AzLocalApplyUpdatesScheduleConfig.ps1',
        'Public/Update-AzLocalPipelineExample.ps1',
        'Public/Get-AzLocalFleetConnectivityStatus.ps1',
        'Public/New-AzLocalFleetConnectivityStatusSummary.ps1'
    )

    FunctionsToExport = @(
        'Connect-AzLocalServicePrincipal',
        'Start-AzLocalClusterUpdate',
        'Get-AzLocalClusterUpdateReadiness',
        'Get-AzLocalClusterInventory',
        'Get-AzLocalClusterInfo',
        'Get-AzLocalUpdateSummary',
        'Get-AzLocalAvailableUpdates',
        'Get-AzLocalUpdateRuns',
        'Set-AzLocalClusterUpdateRingTag',
        # Fleet-Scale Operations (v0.5.6)
        'Invoke-AzLocalFleetOperation',
        'Get-AzLocalFleetProgress',
        'Test-AzLocalFleetHealthGate',
        'Export-AzLocalFleetState',
        'Resume-AzLocalFleetUpdate',
        'Stop-AzLocalFleetUpdate',
        # Pre-Update Health Validation (v0.6.1)
        'Test-AzLocalClusterHealth',
        # Fleet Status Data Collection & Reporting (v0.6.4)
        'Get-AzLocalFleetStatusData',
        'New-AzLocalFleetStatusHtmlReport',
        # Update Schedule Tag Helpers (v0.6.4)
        'Test-AzLocalUpdateScheduleAllowed',
        # Sideloaded Payload Workflow (v0.7.1)
        'Reset-AzLocalSideloadedTag',
        # ITSM Connector Phase 1 (v0.7.4)
        'Get-AzLocalItsmConfig',
        'Test-AzLocalItsmConnection',
        'New-AzLocalIncident',
        # Pipeline-Examples Convenience (v0.7.4 / Update added v0.7.68)
        'Copy-AzLocalPipelineExample',
        'Update-AzLocalPipelineExample',
        # ITSM Sample Convenience (v0.7.50)
        'Copy-AzLocalItsmSample',
        # Fleet Health Failures (v0.7.65) - 24-hour system health-check failures across the fleet
        'Get-AzLocalFleetHealthFailures',
        # Apply-Updates Schedule Coverage Advisor (v0.7.65) - compares apply-updates YAML cron(s) to UpdateStartWindow tags
        'Test-AzLocalApplyUpdatesScheduleCoverage',
        # Update Run Failures (v0.7.68) - ARG-only deep-error extraction (9 levels deep) for fleet-scale verbose error information
        'Get-AzLocalUpdateRunFailures',
        # Ring-Aware Apply-Updates Schedule (v0.7.69) - human-readable schedule file + cycle-based resolver
        'Get-AzLocalApplyUpdatesScheduleConfig',
        'Resolve-AzLocalCurrentUpdateRing',
        'Get-AzLocalApplyUpdatesScheduleNextFirings',
        'New-AzLocalApplyUpdatesScheduleConfig',
        'Update-AzLocalApplyUpdatesScheduleConfig',
        # Fleet Health Overview (v0.7.70) - one row per cluster, ARG-first projection of cluster + updateSummaries (fleet-scale)
        'Get-AzLocalFleetHealthOverview',
        # Latest Released Solution Version (v0.7.70) - public manifest probe (aka.ms/AzureEdgeUpdates) that anchors the rolling YYMM support window
        'Get-AzLocalLatestSolutionVersion',
        # Fleet Connectivity Status (v0.7.79) - 4-scope connectivity audit: cluster, Arc agent, physical NIC, ARB
        'Get-AzLocalFleetConnectivityStatus',
        # Fleet Connectivity Status Summary Renderer (v0.7.87) - markdown step-summary builder used by Step.4 GH+ADO pipelines
        'New-AzLocalFleetConnectivityStatusSummary'
    )

    # Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
    PrivateData = @{
        PSData = @{
            # Tags applied to this module. These help with module discovery in online galleries.
            Tags = @('Azure', 'AzureLocal', 'AzureStackHCI', 'Updates', 'UpdateManager', 'HCI', 'Automation', 'CICD', 'Pipeline', 'ServiceNow', 'ITSM', 'Incident')

            # A URL to the license for this module.
            LicenseUri = 'https://github.com/NeilBird/Azure-Local/blob/main/LICENSE'

            # A URL to the main website for this project.
            ProjectUri = 'https://github.com/NeilBird/Azure-Local'

            # A URL to an icon representing this module.
            IconUri = ''

            # ReleaseNotes of this module
            ReleaseNotes = @'
## Version 0.7.90 - New `UpdateExcluded` operator-override tag + breaking rename `UpdateExclusions` -> `UpdateExclusionsWindow` + pipeline renumber + new Step.7 monitor-updates

### Added

- **Step.5 (assess-readiness) UX polish (GH + ADO)**: audit-order markdown layout (header tile, blocking-findings tables first, per-UpdateRing pivot, cross-links to Step.4/6/7/9), and merged JUnit XML (`assess-readiness.xml` with both readiness + blocking-health suites) published as the new primary "Update Readiness Assessment" Checks/Tests entry.
- **6 new per-pipeline smoke-test harnesses + `Tools/SMOKE-COVERAGE.md`** for Step.1/3/5/7/8/9, matching the PASS / PASS-EMPTY / FAIL-SCHEMA / ERROR style of `validate-arg-queries.ps1`.
- **New `Step.7_monitor-updates.yml` pipeline (GitHub Actions + Azure DevOps).** Operational in-flight monitor distinct from the daily Step.8 snapshot. Reports clusters whose latest update run is currently `InProgress`, with the CURRENT STEP each cluster is on, the PROGRESS (`completed/total steps`), and the ELAPSED DURATION. Long-running runs are flagged via a configurable `long_running_threshold_hours` input (default 6h). Emits `update-monitor.xml` (JUnit, one `<testcase>` per in-flight cluster; `<failure>` when the elapsed duration exceeds the threshold) + `update-monitor.csv` + a markdown summary sorted by elapsed duration descending. Designed for ~30-min cadence during an active wave (GitHub Actions only - ADO YAML schedules are limited to hourly). Pure pipeline composition over `Get-AzLocalUpdateRuns -Latest` - no new cmdlets required.
- **New `UpdateExcluded` Azure resource tag** (operator hard override). When set to `True`/`true`/`1` on a cluster, `Start-AzLocalClusterUpdate` skips the cluster with `Status = ExcludedByTag` **regardless of `UpdateRing` scope, `UpdateSideloaded` state, or `UpdateStartWindow` / `UpdateExclusionsWindow` schedule**. Empty/missing tag means no override. Malformed values throw (fail-closed) unless `-Force` is supplied. New gate runs BEFORE the sideloaded and schedule gates so it overrides both.
- **`Set-AzLocalClusterUpdateRingTag` always stamps `UpdateExcluded=False`** on any cluster that does not already carry the tag, so the tag is discoverable in the Azure portal and ready for an operator to flip to `True` when they need to temporarily exclude a cluster from automation. Existing `True`/`False` values are preserved unless overridden.
- **New optional parameter `-UpdateExcludedValue` on `Set-AzLocalClusterUpdateRingTag -ClusterResourceIds`** and new CSV column `UpdateExcluded` on the `-InputCsvPath` mode. Accepts `True`/`False`/`1`/`0` (case-insensitive). Mirrors the existing `UpdateStartWindow` / `UpdateExclusionsWindow` plumbing.
- **New private helpers**: `ConvertFrom-AzLocalUpdateExcluded` (strict parser) and `Test-AzLocalUpdateExcludedAllowed` (gate evaluator).
- **`Get-AzLocalClusterInventory` CSV/JSON export** now includes an `UpdateExcluded` column (positioned between `UpdateExclusionsWindow` and `UpdateSideloaded`).
- **Apply-updates pipeline summaries** (Step.6 GH Actions + Azure DevOps) now count and report `ExcludedByTag` clusters alongside `ScheduleBlocked` / `SideloadedBlocked`, with an Actions Required callout pointing operators at the tag.

### Changed

- **Pipeline renumber (BREAKING for any local automation that pins to the old filenames):** `fleet-update-status` becomes `Step.8_fleet-update-status.yml` (was `Step.7`) and `fleet-health-status` becomes `Step.9_fleet-health-status.yml` (was `Step.8`). Inline content is otherwise byte-identical apart from header self-references. The new Step.7 slot is taken by the new monitor pipeline. Apply via `Copy-AzLocalPipelineExample -Destination <path> -Update`, then `git rm` the old files locally.
- **Step.8 (fleet-update-status, formerly Step.7) "Version Distribution" markdown table pivoted by YYMM.** Leading column is now `Version` (YYMM e.g. `2511`, `2604`). New `Update Versions` column lists each full version in that YYMM as `<version> x <count>` separated by `<br>`. `Cluster Count` / `Percentage` are summed; `Clusters (first 15 shown only)` is the de-duplicated union. Sorted ascending by YYMM (oldest at top); previously sorted by cluster count descending. The underlying `<testsuite name="Fleet Version Distribution">` JUnit XML remains one `<testcase>` per distinct full `CurrentVersion` (unchanged).

### Changed (BREAKING)

- **Tag rename: `UpdateExclusions` -> `UpdateExclusionsWindow`**. The module from v0.7.90 onwards only reads `UpdateExclusionsWindow` from cluster tags. Clusters still carrying the legacy `UpdateExclusions` tag are silently ignored - their blackout periods will no longer be honoured. Operators must re-tag (`Set-AzLocalClusterUpdateRingTag` with a CSV that has the new column name, or `az tag update --operation Merge`) before the next apply-updates run. The tag VALUE format (`YYYY-MM-DD/YYYY-MM-DD`, comma-separated, `*` wildcards) is unchanged.
- **Parameter rename on `Test-AzLocalUpdateScheduleAllowed`**: `-UpdateExclusions` -> `-UpdateExclusionsWindow`. Any caller passing the old parameter name will fail with a binding error.
- **Parameter rename on `Set-AzLocalClusterUpdateRingTag -ClusterResourceIds`**: `-UpdateExclusionsValue` -> `-UpdateExclusionsWindowValue`. CSV column rename: `UpdateExclusions` -> `UpdateExclusionsWindow`.
- **Property rename on result objects** from `Get-AzLocalClusterInventory`, `Get-AzLocalClusterUpdateReadiness`, and `Get-AzLocalFleetStatusData`: `UpdateExclusions` -> `UpdateExclusionsWindow`. Downstream CSV/JSON consumers must update column names.

### Migration

- **Re-tag clusters that currently have `UpdateExclusions` set.** The legacy tag value is NOT auto-copied. Operators must mirror it onto the new tag and then delete the old one, for example:
  ```
  az tag update --resource-id <clusterId> --operation Merge --tags UpdateExclusionsWindow='<existing-value>'
  az tag update --resource-id <clusterId> --operation Delete --tags UpdateExclusions='<existing-value>'
  ```
  Or re-run `Set-AzLocalClusterUpdateRingTag -InputCsvPath <csv>` with a CSV that has the new `UpdateExclusionsWindow` column.
- **Pipelines:** `Copy-AzLocalPipelineExample -Destination <path> -Update` to pick up the renamed CSV column + new `ExcludedByTag` summary plumbing.
- The new `UpdateExcluded=False` default-stamp is additive - no operator action required. It just makes the tag visible in the portal so operators can flip it to `True` when they need to temporarily exclude a cluster from automation.

## Version 0.7.89 - Apply-updates schedule schema v2: mandatory `allowedUpdateVersions` allow-list with `Latest` sentinel

For full v0.7.89 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.88 - Step.8 fleet-health step-summary readability polish (section reorder + column rename)

For full v0.7.88 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.87 - Extract Step.4 fleet-connectivity summary renderer to module function + 21K-cap Pester regression guard

For full v0.7.87 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.86 - Documentation follow-up: Automation-Pipeline-Examples README + appendix refreshed for the 9-step pipeline set

For full v0.7.86 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.85 - Step.4 reconciliation table: bidirectional interpretation + actionable guidance

For full v0.7.85 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.84 - HOTFIX: Get-AzLocalFleetConnectivityStatus correctness (3 bugs) + cross-call ARG throttle cooldown

For full v0.7.84 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.83 - HOTFIX: Step.4 ARB [char].Trim() bug on single-cluster ClusterId

For full v0.7.83 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.82 - Bundled custom-role JSON artifact

For full v0.7.82 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.81 - Pipeline RBAC guidance: custom role first

For full v0.7.81 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.80 - RBAC custom role: fleet-connectivity reads

For full v0.7.80 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Versions 0.7.72 - 0.7.79 (cumulative)

Step.5 default schedule enabled (0.7.79); Step.4 blank-field regression fix (0.7.78); Step.4 fleet-connectivity hotfix (0.7.77); module rename to `-AzLocal*` + quality hardening (0.7.76); `Test-AzLocalApplyUpdatesScheduleCoverage` CI host auto-detect (0.7.75); `Get-AzLocalFleetHealthOverview` KQL fix + Step.3 recommendation UX rewrite (0.7.74); `Get-AzLocalFleetHealthOverview` HealthState normalisation (0.7.73); pipeline samples hotfix - Step.1/2/5 GH Actions summary panels, `AZURE_TENANT_ID` secret->variable (0.7.72). Full per-version notes:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Older releases

For release notes covering v0.7.71 and earlier, see the CHANGELOG:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

'@

            # Prerelease string of this module
            # Prerelease = ''

            # Flag to indicate whether the module requires explicit user acceptance for install/update/save
            # RequireLicenseAcceptance = $false

            # External dependent modules of this module
            # ExternalModuleDependencies = @()
        }
    }

    # HelpInfo URI of this module
    # HelpInfoURI = ''

    # Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
    # DefaultCommandPrefix = ''
}
