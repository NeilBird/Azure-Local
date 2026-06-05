@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.7.92'

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
## Version 0.7.92 - Step.9 fleet-health step summary: per-cluster collapsible details + Step.7 monitor-updates default schedule (5x/day, every 2h overnight) + pipeline step-summary hyperlinks open in a new tab + Step.3 schedule-audit belt-and-braces retry crons + `RingMixedWindows` warning

Docs/YAML-only feature release. No cmdlet behaviour changes, no schema changes, no breaking changes. The `Step.9_fleet-health-status.yml`, `Step.8_fleet-update-status.yml` and `Step.7_monitor-updates.yml` pipelines (GitHub Actions + Azure DevOps) are the only things that move.

- **Step.9 `Detailed Results` table is now a per-cluster `<details>` block.** Previously the section rendered as a single flat table of up to 100 (cluster x failing-check) rows - so on a fleet of 20+ unhealthy clusters the table dominated the run summary and operators had to scroll to find a specific cluster. The new layout has one collapsible block per cluster: the always-visible `<summary>` line carries the cluster name (linkified to the Azure portal blade), a severity tally in `[Critical] x N  -  [Warning] x M` form (non-zero tiers only, Critical first), and the most-recent `LastOccurrence` across all that cluster''s failing checks. Expanding the block reveals the existing per-failure mini-table (Severity / Failure Reason / Failure Remediation / Target Resource Name / Target Resource Type / Last Occurrence / Resource Group).
- **Cluster ordering switched to worst-affected first.** Clusters sort by `CriticalCount` desc, then `WarningCount` desc, then most-recent `LastOccurrence` desc - so the cluster with the most active critical failures rises to the top. Within each cluster, the per-failure rows sort Critical-first then `LastOccurrence` desc.
- **Pagination is now per-CLUSTER (not per-ROW).** The previous "first 100 rows" cap could silently truncate the second half of a busy cluster''s failures. The new cap shows the first 100 clusters in full; the existing `fleet-health-detail.csv` artifact still carries every row for any cluster that overflows.
- **CSV / JSON artifacts unchanged.** `fleet-health-detail.csv`, `fleet-health-summary.csv`, `fleet-health-overview.csv` and their JSON twins all retain the same schema, so any downstream tooling (ITSM, dashboards, etc.) keeps working without changes.
- **Step.7 ships with an active default schedule.** `Step.7_monitor-updates.yml` (GH + ADO) now runs 5x/day at 20:00, 22:00, 00:00, 02:00, 04:00 UTC - every 2 hours across the typical overnight maintenance window - plus manual `workflow_dispatch` / queue runs. Previously commented-out. The cron lives inside `BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers` so local edits (hour-list shifts, weekends-only, etc.) survive `Update-AzLocalPipelineExample` refreshes.
- **`Copy-AzLocalPipelineExample` now drops a starter `apply-updates-schedule.yml` by default.** For `-Platform GitHub|AzureDevOps` the bundled `apply-updates-schedule.example.yml` is copied to `apply-updates-schedule.yml` ONE LEVEL UP from `-Destination` (sibling of `.github\workflows\` for GitHub, sibling of the ADO pipelines folder) when no file already exists - existing files are NEVER overwritten. Safe alongside the bundled Step.6 which ships with every `cron:` line commented out (cannot fire on `schedule:` until a cron is uncommented). The post-copy summary reports the path and the regenerate-from-live-fleet command `New-AzLocalApplyUpdatesScheduleConfig -OutputPath <path> -Force`; manual `workflow_dispatch` / queue runs of Step.6 ignore the schedule file entirely. Pass `-SkipStarterSchedule` to suppress. Wording also inline in `Automation-Pipeline-Examples/README.md` 5.1/5.2.
- **Pipeline step-summary hyperlinks now open in a new tab.** Every rendered hyperlink in the `Step.8_fleet-update-status.yml` and `Step.9_fleet-health-status.yml` step summaries (GitHub Actions + Azure DevOps) - cluster-name cells, update-run-name cells, remediation links, and the Microsoft Learn / aka.ms references in the version section - is now emitted as HTML `<a href="..." target="_blank">` (with `rel="noopener noreferrer"` on the prose links). Clicking a link opens the Azure portal blade or docs page in a new tab and the operator stays on the pipeline run page instead of being navigated away mid-investigation. Step.4 was already plain-URL only (no rendered hyperlinks), so it needed no change. CSV / JSON / JUnit artifacts continue to carry plain URLs - no schema or data shape changes.
- **Step.3 schedule-audit summary metric table now reconciles when `-IncludeUntagged` is set.** Previously surfaced 7 of 8 `Status` buckets - the `NoWindowTag` row (clusters with no `UpdateStartWindow` tag, emitted when `IncludeUntagged: true`) was missing, so `(Ring, Window) pairs audited` did not equal the sum of visible buckets. v0.7.92 adds the `NoWindowTag` row to the metric table (both GH + ADO Step.3) and wires it into the `hasIssues` calculation so the action-required Recommend block surfaces when untagged clusters are present.
- **Step.3 schedule-audit: belt-and-braces retry crons + `RingMixedWindows` warning.** New `-RecommendFiresPerWindow` parameter on `Test-AzLocalApplyUpdatesScheduleCoverage` (default `2`) and matching `fires_per_window` (GH) / `firesPerWindow` (ADO) workflow input. When `2` (default), the Recommend snippet emits each window as TWO crons: `(open)` `LeadTimeMinutes` before the window opens, plus `(retry)` INSIDE the window at the lesser of midpoint or +60 min after open. Catches GH Actions scheduled-workflow jitter, transient first-fire failures, and long-window cases. Runtime gate + in-flight guard prevent double-triggering. Pass `1` for pre-v0.7.92 single-cron behaviour. Audit semantics ("Covered" / "Uncovered") unchanged. Also new: `RingMixedWindows` informational Audit status emitted when 2+ clusters share an `UpdateRing` tag but carry DIFFERENT `UpdateStartWindow` values; per-pair coverage rows above are unchanged.

Apply via `Update-AzLocalPipelineExample -Destination <path>` to refresh the `Step.9_*.yml`, `Step.8_*.yml`, `Step.7_*.yml` and `Step.3_*.yml` files. The Step.9 changes sit outside any `BEGIN-AZLOCAL-CUSTOMIZE` block, so operator customisations elsewhere in those pipelines are preserved.

## Version 0.7.91 - Step.7 monitor-updates parser bug + Step.3 schedule-audit step-summary cosmetic fixes

For full v0.7.91 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.90 - New `UpdateExcluded` operator-override tag + breaking rename `UpdateExclusions` -> `UpdateExclusionsWindow` + pipeline renumber + new Step.7 monitor-updates

For full v0.7.90 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

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
