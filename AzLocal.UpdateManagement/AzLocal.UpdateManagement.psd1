@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.8.72'

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
        'Private/Get-AzLocalPipelineId.ps1',
        'Private/Get-AzLocalPipelineManifest.ps1',
        'Private/Get-AzLocalRunEndTime.ps1',
        'Private/Get-CurrentStepPath.ps1',
        'Private/Get-DeepestActiveStep.ps1',
        'Private/Get-DeepestErrorMessage.ps1',
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
        # On-prem solution-update sideloading automation (v0.8.7)
        'Private/Get-AzLocalSideloadAuthMap.ps1',
        'Private/Get-AzLocalSideloadCatalog.ps1',
        'Private/Convert-AzLocalSideloadCatalogSchemaVersion.ps1',
        'Private/Select-AzLocalNextUpdateForCluster.ps1',
        'Private/Resolve-AzLocalSideloadCredential.ps1',
        'Private/Get-AzLocalSolutionUpdateDownload.ps1',
        'Private/Get-AzLocalSideloadState.ps1',
        'Private/Resolve-AzLocalSideloadTargetPath.ps1',
        'Private/Register-AzLocalSideloadCopyTask.ps1',
        'Private/New-AzLocalPSRemotingSession.ps1',
        'Private/Test-AzLocalRemoteFileHash.ps1',
        'Private/Invoke-AzLocalRemoteSolutionImport.ps1',
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
        # Pipeline host abstraction (v0.8.2) - foundations for the upcoming executable-YAML refactor
        'Private/Get-AzLocalPipelineHost.ps1',
        'Private/Set-AzLocalPipelineOutput.ps1',
        'Private/Add-AzLocalPipelineStepSummary.ps1',
        'Private/Write-AzLocalPipelineNotice.ps1',
        'Private/Write-AzLocalPipelineWarning.ps1',
        # Generic JUnit XML emitter shared by every Public Step.* cmdlet (v0.8.5)
        'Private/New-AzLocalPipelineJUnitXml.ps1',

        # Public exported functions
        'Public/Connect-AzLocalServicePrincipal.ps1',
        'Public/Copy-AzLocalItsmSample.ps1',
        'Public/Copy-AzLocalPipelineExample.ps1',
        'Public/Export-AzLocalFleetState.ps1',
        'Public/Get-AzLocalApplyUpdatesScheduleConfig.ps1',
        'Public/Get-AzLocalApplyUpdatesScheduleCycleCalendar.ps1',
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
        'Public/New-AzLocalFleetConnectivityStatusSummary.ps1',
        # On-prem solution-update sideloading automation (v0.8.7) - catalog maintenance
        'Public/Update-AzLocalSideloadCatalog.ps1',
        # On-prem solution-update sideloading automation (v0.8.7) - planner, orchestrator, reporting
        'Public/Resolve-AzLocalSideloadPlan.ps1',
        'Public/Invoke-AzLocalSideloadUpdate.ps1',
        'Public/Export-AzLocalSideloadStatusReport.ps1',
        # Thin-YAML pipeline foundation (v0.8.5)
        'Public/Add-AzLocalPipelineVersionBanner.ps1',
        # Thin-YAML Step.0 (v0.8.5) - Authentication validation + subscription scope + cluster reachability
        'Public/Export-AzLocalAuthValidationReport.ps1',
        # Thin-YAML Step.1 (v0.8.5) - Cluster inventory + canonical CSV + operator README + step summary
        'Public/Invoke-AzLocalClusterInventory.ps1',
        # Thin-YAML Step.2 (v0.8.5) - UpdateRing tag management workload (CSV validation + apply + JSON sidecar + step summary)
        'Public/Set-AzLocalClusterUpdateRingTagFromCsv.ps1',
        # Thin-YAML Step.7 (v0.8.5) - In-flight update-run monitor (severity scoring + CSV + JUnit + step summary + 6 step outputs)
        'Public/Export-AzLocalUpdateRunMonitorReport.ps1',
        # Thin-YAML Step.8 (v0.8.5) - Fleet update status (inventory + readiness + version distribution + 3-suite JUnit XML + step summary + 22 step outputs)
        'Public/Export-AzLocalFleetUpdateStatusReport.ps1',
        # Thin-YAML Step.5 (v0.8.5) - Pre-flight Update Readiness Assessment (readiness + blocking-health JUnit + combined JUnit + 8-section markdown summary + 2 step outputs)
        'Public/Export-AzLocalClusterUpdateReadinessReport.ps1',
        # Thin-YAML Step.4 (v0.8.5) - Fleet Connectivity Status (Cluster/Arc/NIC/ARB severity classification + JUnit XML via shared helper + markdown summary + 12 step outputs)
        'Public/Export-AzLocalFleetConnectivityStatusReport.ps1',
        # Thin-YAML Step.3 (v0.8.5) - Apply-Updates Schedule Coverage Audit (Audit + Matrix + Recommend views + 2-suite JUnit XML + 12-row summary table + allow-list section + always-on cycle calendar + 12 step outputs)
        'Public/Export-AzLocalApplyUpdatesScheduleAudit.ps1',
        # Thin-YAML Step.9 (v0.8.5) - Fleet Health Status (Detail + in-process Summary + Overview + 2-suite JUnit XML + 4-section markdown + 8 step outputs; condenses ~600-line inline run: | block in Step.9_fleet-health-status.yml on both platforms)
        'Public/Export-AzLocalFleetHealthStatusReport.ps1',
        # Thin-YAML Step.6 (v0.8.5) - Apply-Updates pipeline (resolve UpdateRing from schedule + readiness gate report + readiness-gated apply + per-host apply-updates step summary + no-clusters-ready step summary + ITSM ticketing from JUnit artifact; condenses ~6 inline run: | blocks across both Step.6_apply-updates.yml pipelines into 6 testable Public cmdlets)
        'Public/Resolve-AzLocalPipelineUpdateRing.ps1',
        'Public/Export-AzLocalClusterReadinessGateReport.ps1',
        'Public/Invoke-AzLocalReadinessGatedClusterUpdate.ps1',
        'Public/Add-AzLocalApplyUpdatesStepSummary.ps1',
        'Public/Add-AzLocalNoReadyClustersStepSummary.ps1',
        'Public/Invoke-AzLocalItsmTicketingFromArtifact.ps1'
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
        # Cycle Calendar (v0.8.5) - human-readable per-day projection of the resolver for one full cycle (or any -Days horizon), variable cycle length safe, year-boundary safe, per-ring 'next eligible date' summary
        'Get-AzLocalApplyUpdatesScheduleCycleCalendar',
        # Fleet Health Overview (v0.7.70) - one row per cluster, ARG-first projection of cluster + updateSummaries (fleet-scale)
        'Get-AzLocalFleetHealthOverview',
        # Latest Released Solution Version (v0.7.70) - public manifest probe (aka.ms/AzureEdgeUpdates) that anchors the rolling YYMM support window
        'Get-AzLocalLatestSolutionVersion',
        # Fleet Connectivity Status (v0.7.79) - 4-scope connectivity audit: cluster, Arc agent, physical NIC, ARB
        'Get-AzLocalFleetConnectivityStatus',
        # Fleet Connectivity Status Summary Renderer (v0.7.87) - markdown step-summary builder used by Step.4 GH+ADO pipelines
        'New-AzLocalFleetConnectivityStatusSummary',
        # Thin-YAML pipeline foundation (v0.8.5) - install-step version banner + drift annotations + step outputs (condenses ~50-line inline block in every Step.*.yml)
        'Add-AzLocalPipelineVersionBanner',
        # Thin-YAML Step.0 (v0.8.5) - Authentication validation + subscription scope + cluster reachability (condenses ~200-line inline run: | block in Step.0_authentication-test.yml on both platforms)
        'Export-AzLocalAuthValidationReport',
        # Thin-YAML Step.1 (v0.8.5) - Cluster inventory workload (condenses the inline run: | block in Step.1_inventory-clusters.yml on both platforms; writes timestamped + canonical CSV, JSON, README, and step summary)
        'Invoke-AzLocalClusterInventory',
        # Thin-YAML Step.2 (v0.8.5) - UpdateRing tag management workload (validates CSV, applies tags via Set-AzLocalClusterUpdateRingTag, writes JSON sidecar + step summary)
        'Set-AzLocalClusterUpdateRingTagFromCsv',
        # Thin-YAML Step.7 (v0.8.5) - In-flight update-run monitor (calls Get-AzLocalUpdateRuns -Latest -PassThru, classifies by per-step + overall elapsed + progress-status, writes CSV + JUnit XML + markdown step summary + 6 step outputs)
        'Export-AzLocalUpdateRunMonitorReport',
        # Thin-YAML Step.8 (v0.8.5) - Fleet-wide Azure Local update status snapshot (inventory + readiness + Microsoft-manifest-anchored version distribution + 3-suite JUnit XML + supplementary CSVs + markdown step summary + 22 step outputs; replaces the ~830-line inline 'Collect Fleet Update Status' + 'Create Status Summary' blocks in Step.8_fleet-update-status.yml on both platforms)
        'Export-AzLocalFleetUpdateStatusReport',
        # Thin-YAML Step.5 (v0.8.5) - Pre-flight Update Readiness Assessment (calls Get-AzLocalClusterUpdateReadiness + Test-AzLocalClusterHealth -BlockingOnly, writes per-check CSV + JUnit XML, merges into combined assess-readiness.xml, emits 8-section markdown step summary + 2 step outputs; replaces the ~280-line inline 'Run readiness + blocking health checks' block in Step.5_assess-update-readiness.yml on both platforms)
        'Export-AzLocalClusterUpdateReadinessReport',
        # Thin-YAML Step.4 (v0.8.5) - Fleet Connectivity Status (calls Get-AzLocalFleetConnectivityStatus, classifies severity across Cluster/Arc/NIC/ARB scopes, emits JUnit XML via shared New-AzLocalPipelineJUnitXml helper, renders markdown via shared New-AzLocalFleetConnectivityStatusSummary, emits 12 lowercase step outputs; replaces the ~255-line inline 'Collect Fleet Connectivity Data' block in Step.4_fleet-connectivity-status.yml on both platforms)
        'Export-AzLocalFleetConnectivityStatusReport',
        # Thin-YAML Step.3 (v0.8.5) - Apply-Updates Schedule Coverage Audit (calls Test-AzLocalApplyUpdatesScheduleCoverage Audit + Matrix + Recommend, builds 2-suite JUnit XML via shared New-AzLocalPipelineJUnitXml helper, renders summary table + Schedule/Cron detail tables + allow-list coverage + always-on Cycle calendar via Get-AzLocalApplyUpdatesScheduleCycleCalendar; emits 12 lowercase step outputs; replaces the ~220-line inline 'Run Schedule Coverage Audit' + ~210-line inline 'Create Schedule Coverage Summary' blocks in Step.3_apply-updates-schedule-audit.yml on both platforms; ALWAYS renders the Cycle calendar when -SchedulePath is supplied, fixing the v0.8.4 hasIssues-gate regression that silently dropped the calendar on clean-fleet runs)
        'Export-AzLocalApplyUpdatesScheduleAudit',
        # Thin-YAML Step.9 (v0.8.5) - Fleet Health Status (calls Get-AzLocalFleetHealthFailures Detail + Get-AzLocalFleetHealthOverview, computes Summary view in-process, builds 2-suite JUnit XML via shared New-AzLocalPipelineJUnitXml helper, renders KPI / Overview / By-Reason / per-cluster collapsible markdown; emits 8 lowercase step outputs; replaces the ~600-line inline 'Collect Fleet Health Status' + 'Create Fleet Health Summary' blocks in Step.9_fleet-health-status.yml on both platforms)
        'Export-AzLocalFleetHealthStatusReport',
        # Thin-YAML Step.6 (v0.8.5) - Apply-Updates pipeline (6 cmdlets that condense ~430 lines of inline run: | blocks across both Step.6_apply-updates.yml pipelines into testable, host-aware Public cmdlets; preserves byte-for-byte parity of all markdown summaries, per-host icon literals, and ADO task.logissue warning/error lines)
        'Resolve-AzLocalPipelineUpdateRing',
        'Export-AzLocalClusterReadinessGateReport',
        'Invoke-AzLocalReadinessGatedClusterUpdate',
        'Add-AzLocalApplyUpdatesStepSummary',
        'Add-AzLocalNoReadyClustersStepSummary',
        'Invoke-AzLocalItsmTicketingFromArtifact',
        # On-prem solution-update sideloading automation (v0.8.7)
        'Update-AzLocalSideloadCatalog',
        'Resolve-AzLocalSideloadPlan',
        'Invoke-AzLocalSideloadUpdate',
        'Export-AzLocalSideloadStatusReport',
        'Add-AzLocalSideloadStepSummary'
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
## Version 0.8.72 - Patch: pipeline-template polish only. Schedule-file author guidance moved OUTSIDE the apply-updates.yml customise marker so it refreshes on existing consumers; single-digit Step.N display names zero-padded (Step.0 -> Step.00 ... Step.9 -> Step.09) so the GitHub Actions sidebar / Azure DevOps list sort in execution order. No public API or export-count change (still 60).

- **FIX**: `apply-updates.yml` (GitHub Actions + Azure DevOps) - the schedule-file author guidance comments were trapped INSIDE the `# BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers` block. Because `Update-AzLocalPipelineExample` preserves the marker body verbatim from the consumer's file, any correction to that guidance (e.g. the v0.8.71 `.github` -> `config` schedule-path fix) could never reach an already-deployed consumer. All author guidance is now ABOVE the marker; the marker body holds only the trigger directive (placeholder comment on GH, `trigger: none` on ADO).
- **CHANGE (display only)**: single-digit pipeline step numbers zero-padded to two digits in all display names / titles - GitHub Actions workflow `name:` fields, Azure DevOps `name:` / stage `displayName:` labels, and the `# Step.N - ` header comments (`Step.0` -> `Step.00` ... `Step.9` -> `Step.09`; `Step.10` unchanged). The GitHub Actions sidebar and Azure DevOps pipelines list sort alphabetically by display name, so `Step.10` previously sorted between `Step.1` and `Step.2`. Functional identifiers (artifact names `azlocal-step.N-*`) and cross-reference prose are unchanged.
- **All bundled pipeline templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.71'` to `'0.8.72'`.

## Version 0.8.71 - Patch: JUnit export strict-mode crash fix + sideload schedule-path default corrected + pipeline doc-string filenames de-numbered. No public API or export-count change (still 60).

- **FIX (production)**: `Export-ResultsToJUnitXml` no longer throws `The property 'CurrentState' cannot be found on this object` under `Set-StrictMode -Version Latest` when an apply run emits an `UpdateStarted` success row that lacks `CurrentState`/`Progress`. All bare property reads are now guarded with `PSObject.Properties[...]`.
- **FIX**: GitHub Actions `sideload-updates.yml` `APPLY_UPDATES_SCHEDULE_PATH` default corrected from `./.github/apply-updates-schedule.yml` to `./config/apply-updates-schedule.yml`, so it matches where `Copy-AzLocalPipelineExample` drops the starter (alongside the auth-map + catalog).
- **FIX**: De-numbered stale `Step.N_*.yml` filename references in pipeline header comments / input descriptions (apply-updates-schedule-audit, assess-update-readiness, authentication-test, and the schedule starter example). The files were renamed in v0.8.7; these doc strings now name the current files (`apply-updates.yml`, `authentication-test.yml`, etc.).
- **All bundled pipeline templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.7'` to `'0.8.71'`.

## Version 0.8.7 - On-prem solution-update sideloading automation (new Step.6 pipeline + 5 new Public cmdlets) + pipeline filenames de-numbered (rename-aware Update) + breaking display-step renumber. Module export count grows 55 -> 60.

Adds opt-in, off-by-default on-prem sideloading for Azure Local clusters that cannot pull solution updates from Azure directly. A new self-hosted Step.6 pipeline (`sideload-updates.yml`) robocopies update media to each cluster's import share, verifies the SHA256 over WinRM, runs Add-SolutionUpdate, and flips `UpdateSideloaded=True` for the downstream apply. It is driven as a re-entrant state machine on a frequent CRON; the multi-hour copy runs in a detached Windows Scheduled Task so no single pipeline run is long-lived.

- **NEW Public cmdlets (5)**: `Update-AzLocalSideloadCatalog`, `Resolve-AzLocalSideloadPlan`, `Invoke-AzLocalSideloadUpdate`, `Export-AzLocalSideloadStatusReport`, `Add-AzLocalSideloadStepSummary`. Export count grows 55 -> 60.
- **NEW Step.6 sideload pipeline** (`sideload-updates.yml`, GitHub Actions + Azure DevOps), opt-in via the `SIDELOAD_UPDATES` repository variable; targets a self-hosted runner (GH) / self-hosted agent pool (ADO) labelled `azlocal-sideload`. Catalog (Solution + OEM SBE packageType), shared-UNC state, Key Vault-sourced AD credential for WinRM, and robocopy throttling are documented in Automation-Pipeline-Examples/docs/sideload.md + sideload-robocopy.md.
- **BREAKING - pipeline files de-numbered.** The `Step.N_` filename prefix is removed (e.g. `Step.7_apply-updates.yml` -> `apply-updates.yml`); the in-pipeline `Step.N - ` display names are unchanged. Stable filenames mean future reorders are pure display-name edits. `Update-AzLocalPipelineExample` now matches each destination pipeline by a stable logical id (embedded `# AZLOCAL-PIPELINE-ID:` marker, with legacy-filename aliases) and AUTO-RENAMES any older `Step.N_*.yml` to the new name while preserving your `BEGIN/END-AZLOCAL-CUSTOMIZE` CRON edits (emits a `RenamedFrom` result + a GH/ADO required-check warning).
- **BREAKING - display-step renumber** to make room for sideload at Step.6: apply-updates 6->7, monitor-updates 7->8, fleet-update-status 8->9, fleet-health-status 9->10.
- **Step.1 / Step.2 sideload-aware**: inventory can emit the `UpdateAuthAccountId` column (`-IncludeSideloadColumns`, auto-enabled from `SIDELOAD_UPDATES`); tag management can set `UpdateAuthAccountId` from CSV. Byte-identical output when sideload is off.
- **Step.3 advisor** can emit a recommended sideload CRON (apply window minus `SIDELOAD_LEAD_DAYS`) when sideloading is enabled.
- **All bundled pipeline templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.6'` to `'0.8.7'`.

## Version 0.8.6 - Step.3 cycle-calendar enrichment (per-day CRON + UpdateStartWindow tag coverage) + six v0.8.5 pipeline regression fixes (Step.0/3/4/6/9) + new Pester static-audit guards. See CHANGELOG for the full v0.8.6 entry.

## Version 0.8.5 - New Public cmdlet `Get-AzLocalApplyUpdatesScheduleCycleCalendar` + Step.6 manual schedule-file inputs + Step.3 cycle-calendar regression fix + per-ring cluster-count column + full thin-YAML port of all 10 Step pipelines (14 new Public cmdlets). Module export count grows 35 -> 55. See CHANGELOG for the full v0.8.5 entry.

## Version 0.8.3 - Test-AzLocalApplyUpdatesScheduleCoverage Step.3 advisor accuracy + readability fixes: Recommend now diff-prunes against `-PipelineYamlPath`, Step.3 yml `pipeline_path` REQUIRED, Allow-list heading reframed, closing-fence typo fixed

## Version 0.8.2 - Test-AzLocalApplyUpdatesScheduleCoverage operator-UX release: -View Recommend snippet embeds `# All cron times below are UTC` comment + `Indent tip` blockquote; -View Audit `NoWindowTag` row now names affected clusters grouped by `UpdateRing` + sorts AFTER Covered; Step.3 GH/ADO Allow-list section trimmed; five new internal pipeline-host helpers (Get/Set/Add/Write-AzLocalPipeline*) laid down as foundations for the upcoming executable-YAML refactor

## Version 0.8.1 - Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend GH snippet emits ONLY the `schedule:` block (no `on:` / `workflow_dispatch:` lines) so it can be pasted straight into Step.6_apply-updates.yml without producing a duplicate-key YAML error

## Version 0.8.0 - Step.7 form-default regressions fixed (criticalElapsedDays 7->3, updateRing Wave1->empty) + Pii-Guard.Tests.ps1 (repo-hygiene guard) + Publish-Module.ps1 excludes maintainer-only RELEASE-PROCESS.md

## Version 0.7.99 - Property/Summary renames (AvailableUpdates -> AllAvailableUpdates, AvailableUpdatesCount -> ActionableUpdatesCount, Ready/NotReady Summary -> ReadyForUpdate/UpToDate/NotReadyForUpdate) + Step.7 CRITICAL elapsed-days 7->3 + artifact zip names prefixed with step.X-

For full v0.7.x and v0.8.x release notes see:
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
