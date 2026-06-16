@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.8.87'

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
        'Private/ConvertFrom-AzLocalUpdateLastAttemptTagValue.ps1',
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
        'Private/Format-AzLocalUpdateLastAttemptTagValue.ps1',
        'Private/Get-AzLocalClusterReadinessStatus.ps1',
        'Private/Get-AzLocalClusterUpdateRuns.ps1',
        'Private/Get-AzLocalItsmDedupeKey.ps1',
        'Private/Get-AzLocalItsmTriggerDecision.ps1',
        'Private/Get-AzLocalModuleRootManifestPath.ps1',
        'Private/Get-AzLocalPipelineCustomiseMarkers.ps1',
        'Private/Get-AzLocalPipelineId.ps1',
        'Private/Get-AzLocalPipelineManifest.ps1',
        'Private/Get-AzLocalRunEndTime.ps1',
        'Private/Get-AzLocalUpdateRunHealthEvidence.ps1',
        'Private/Get-AzLocalUpdateRunStepStats.ps1',
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
        'Private/Write-AzLocalUpdateLastAttemptTag.ps1',
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
        # Shared step-summary helpers (v0.8.81) - host-aware status icons, cluster portal deep-links, Ctrl-click tip
        'Private/Get-AzLocalStatusIconMap.ps1',
        'Private/Get-AzLocalClusterPortalLink.ps1',
        'Private/Get-AzLocalCtrlClickTip.ps1',

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
## Version 0.8.87 - Patch: renames the "Orphan ARBs" section in the `New-AzLocalFleetConnectivityStatusSummary` (Fleet: 02 - Fleet Connectivity Status) output to "Non-Azure Local and/or Orphan ARB appliances" and adds a caveat that an Arc resource bridge with no matching in-scope Azure Local cluster is NOT necessarily orphaned - Arc resource bridge is also used by VMware vSphere and SCVMM, so a listed appliance may be a healthy bridge for a non-Azure Local platform. Adds investigate-before-acting guidance (check resource type, custom location, platform served; do not delete until confirmed orphaned). KPI note, causes list, and cluster-table cross-reference updated to match. Output text only - no public API or behavioural change. Export count unchanged (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.8.87'`.

## Version 0.8.86 - Patch: renames the three onboarding pipeline templates from `Setup: 0N` to `Config: 0N` so the GitHub Actions sidebar (and the Azure DevOps Pipelines list) sorts the onboarding / configuration workflows ahead of the `Fleet: 0N` operational workflows. Both surfaces sort alphabetically by the workflow `name:` / definition name, and `C` (Config) sorts before `F` (Fleet); the previous `Setup:` prefix sorted AFTER `Fleet:`. Only the operator-facing `name:` (GitHub Actions) / `displayName:` (Azure DevOps) fields change - filenames, `AZLOCAL-PIPELINE-ID` values, aliases, prune logic, and all cmdlet behaviour are unchanged. Bundled pipeline README + appendix docs updated to match. No public API or behavioural change. Export count unchanged (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `'0.8.85'` to `'0.8.86'`.

## Version 0.8.85 - Patch: introduces Setup/Fleet naming in bundled pipeline templates, adds merged GitHub onboarding workflow `setup-validate-and-inventory.yml`, and updates pipeline refresh tooling with optional deprecated-file pruning guarded by AZLOCAL-PIPELINE-ID verification. No public API or behavioural change. Export count unchanged (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `'0.8.84'` to `'0.8.85'`.

## Version 0.8.83 - Patch: fix-forward for v0.8.82 Item-5. The Step.08 `UpdateLastAttempt` reconciliation in `Export-AzLocalUpdateRunMonitorReport` reads `$inv.tags` from `Get-AzLocalClusterInventory`, but the v0.8.82 inventory projection did not carry the raw ARM `tags` bag - so the "Recent update attempts with no observable updateRun" section was silently always empty in production. v0.8.83 surfaces the raw `tags` bag on every inventory row (in-memory only; the CSV / JSON export keeps its explicit `$selectColumns` whitelist - new regression test asserts both). Also wires `attempts_without_run` into the GitHub Actions `monitor-updates.yml` `jobs.outputs:` block (ADO `Set-AzLocalPipelineOutput` auto-publishes so only an ADO docstring refresh needed), and corrects the `Export-AzLocalUpdateRunMonitorReport` "6 step outputs" docstring to "7 step outputs". No public API change. Export count unchanged (still 60). All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.82'` to `'0.8.83'`.

## Version 0.8.82 - Patch: four Step-summary UX polish fixes from v0.8.81 manual pipeline-run review. (1) Step.05 Summary counts table no longer duplicates labels: each row reused the shared `Get-AzLocalStatusIconMap` cell (which already includes its own label) AND appended a duplicate trailing label, producing `Ready for Update Ready for update` / `Up to Date Up to date` / `Action Required Not ready for update` / `Health Failure Clusters with Critical health failures`. Fixed by emitting the icon-map cell unmodified; the HealthFailure row keeps `(Clusters with Critical health failures)` in parentheses since it counts something different from the readiness cascade. (2) Step.05 All clusters detail table now sorts by Status priority first (`InProgress` -> `HealthFailure` -> `UpdateFailed` -> `ActionRequired` -> `SbeBlocked` -> `NeedsInvestigation` -> `ReadyForUpdate` -> `UpToDate`), then UpdateRing + ClusterName. In-flight + remediation rows surface at the top; Up-to-Date drops to the bottom. (3) Step.05 Not-Ready clusters (review first) table no longer leaves the `Blocking reasons` column as `-` for rows blocked by `UpdateFailed` / `NeedsAttention` / `InProgress` / Warning-only HealthFailure / SbeBlocked - the renderer now derives an actionable token from the Status bucket when the upstream `BlockingReasons` is empty (e.g. `UpdateInProgress (run in-flight)`, `UpdateState=NeedsAttention`, `PrerequisiteRequired (SBE update first)`, `HealthState=Failure (no Critical findings; review Warning findings)`), with `; HealthState=Warning` appended where relevant. (4) Step.10 Detailed Results Description column inline-vs-collapse threshold bumped from 120 to 280 characters, so short single-sentence descriptions render inline and only long multi-line descriptions collapse behind `<details><summary>view</summary>...</details>`. The previous 120-char cutoff put roughly half the rows inline and half collapsed on the same table, which looked broken. No public API or export-count change (still 60). All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.81'` to `'0.8.82'`.

## Version 0.8.81 - Step summary polish across Steps 05-10. Step.10 fixes the KPI bug where Healthy + Unhealthy did not sum to Total (splits into Cluster Counts + Failing Checks Breakdown tables, adds `OtherClusters` step output; Detailed Results gains Title, raw FailureName and collapsible Description columns surfacing drive/volume detail e.g. file paths from `...FileSystem.Corruption.Correctable`). Steps 05-09 adopt three shared private helpers: `Get-AzLocalStatusIconMap` (host-aware GitHub Unicode vs Azure DevOps shortcodes), `Get-AzLocalClusterPortalLink` (portal deep-link wrapper) and `Get-AzLocalCtrlClickTip` (single-source Ctrl-click banner). Fixes literal shortcode text (`:white_check_mark:` etc.) rendering on Azure DevOps step summaries in Step.08 monitor + Step.09 fleet-update-status. No public API change (still 60 exports). All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.80'` to `'0.8.81'`.

## Version 0.8.80 - Minor: three additive pipeline failure-rendering improvements across Step.05 / Step.08 / Step.09 / Step.10 step summaries. Q1 - Step.09 `Get-AzLocalUpdateRunFailures` attaches a `HealthCheckEvidence` array column (same-cluster Critical health-check entries within +/-2h) to HealthCheck-category rows; new private helper `Get-AzLocalUpdateRunHealthEvidence`; `-EnrichWithHealthEvidence` opt-out. Q2 - Step.05 `Test-AzLocalClusterHealth` and Step.10 `Get-AzLocalFleetHealthFailures` add per-check `Title` + full `TargetResourceID`; `Export-AzLocalFleetHealthStatusReport` wraps TargetResourceName in a portal hyperlink. Q3 - both deepest-error walkers capture step `description` alongside `errorMessage`; new `DeepestStepDescription` / `ErrorDescription` fields on `Get-AzLocalUpdateRunFailures` / `Format-AzLocalUpdateRun` / `Get-AzLocalUpdateRuns -PassThru`; Step.08 + Step.09 renderers combine the two in markdown failure cells and JUnit bodies. No new exports (still 60). `GENERATED_AGAINST_MODULE_VERSION` bumped from `'0.8.79'` to `'0.8.80'`. See CHANGELOG.md for the full v0.8.80 entry.

## Version 0.8.79 - Patch: operator break-glass override for Step.07. Adds `Force Immediate Update` to `Invoke-AzLocalReadinessGatedClusterUpdate` (`-ForceImmediateUpdate`) and `Start-AzLocalClusterUpdate` (`-IgnoreScheduleTags`), plus matching pipeline parameters `force_immediate_update` (GitHub Actions `workflow_dispatch` input) / `forceImmediateUpdate` (Azure DevOps `parameters:` boolean) both defaulting to `false`. When enabled, the per-cluster Step 3c maintenance-window gate (`UpdateStartWindow` / `UpdateExclusionsWindow` tags) is bypassed and updates start regardless of the current UTC time. Intended for emergency / out-of-window patching driven by an on-call operator. The override is UNREACHABLE from the apply-updates-schedule.yml configuration file - GHA wiring collapses the flag to `'false'` for any non-`workflow_dispatch` trigger (`${{ github.event_name == 'workflow_dispatch' && github.event.inputs.force_immediate_update || 'false' }}`), and ADO rechecks `$(Build.Reason) -eq 'Manual'` at runtime before honouring the parameter. A `WARNING:` GUI label is prepended on both pipeline hosts and a high-visibility `::warning::` (GHA) / `##vso[task.logissue type=warning]` (ADO) banner is emitted into the run log when the override fires. No new exports (still 60). All bundled pipeline templates bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.78'` to `'0.8.79'`.

- **CHANGE (`Start-AzLocalClusterUpdate`)**: new `[switch]$IgnoreScheduleTags` parameter; when set, the Step 3c maintenance-window block is skipped and a per-cluster `Warning` is logged with the bypassed tag values. Does NOT bypass any other readiness gate.
- **CHANGE (`Invoke-AzLocalReadinessGatedClusterUpdate`)**: new `[switch]$ForceImmediateUpdate` parameter; forwards `-IgnoreScheduleTags` per cluster and emits a host-aware warning banner at the top of the apply.
- **CHANGE (`apply-updates.yml`)**: new `force_immediate_update` GHA choice / `forceImmediateUpdate` ADO boolean parameter; both enforce the manual-only constraint at the YAML layer so a scheduled cron firing can never honour the flag.

## Version 0.8.78 - Patch: pipeline-summary UX polish (`ScheduleBlocked` / `SideloadedBlocked` / `ExcludedByTag` now JUnit `<skipped>`; `Add-AzLocalApplyUpdatesStepSummary` gains `-UpToDateCount` / `-NotReadyCount`; `actions/download-artifact@v6` -> `@v7`). See CHANGELOG.md / docs/release-history.md.

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
