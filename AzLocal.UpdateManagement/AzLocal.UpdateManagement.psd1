@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.9.15'

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
    Description = 'PowerShell module to manage Azure Local (formerly Azure Stack HCI) cluster updates using Azure Update Manager APIs. Provides functions to start updates, check update status, list available updates, and monitor update runs.'

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
        'Private/Get-AzLocalReadyForUpdateRows.ps1',
        'Private/Get-AzLocalReadmeTemplateVersion.ps1',
        'Private/Get-AzLocalReadyForUpdateTableMarkdown.ps1',
        'Private/Get-AzLocalRunEndTime.ps1',
        'Private/Get-AzLocalUpdateRunHealthEvidence.ps1',
        'Private/Get-AzLocalUpdateRunStepStats.ps1',
        'Private/Get-AzLocalUpdaterScriptVersion.ps1',
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
        'Private/Repair-AzLocalExcludedSubscriptionCsv.ps1',
        'Private/Resolve-AzLocalItsmSecret.ps1',
        'Private/Resolve-AzLocalUpdateRunDeepestError.ps1',
        'Private/Resolve-SafeOutputPath.ps1',
        'Private/Resolve-WildcardDate.ps1',
        'Private/Resolve-WildcardDateRange.ps1',
        'Private/Set-AzLocalClusterTagsMerge.ps1',
        'Private/Test-AzLocalUpdateRunsInFlight.ps1',
        'Private/Write-AzLocalUpdateLastAttemptTag.ps1',
        # On-prem solution-update sideloading automation (v0.8.7)
        'Private/Get-AzLocalSideloadAuthMap.ps1',
        'Private/Get-AzLocalSideloadCatalog.ps1',
        'Private/Convert-AzLocalSideloadCatalogSchemaVersion.ps1',
        'Private/Select-AzLocalNextUpdateForCluster.ps1',
        # Readiness allow-list override (v0.9.1) - per-ring/global precedence resolver
        'Private/Resolve-AzLocalClusterAllowList.ps1',
        # Force (break-glass) allow-list resolver (v0.9.15) - honors the
        # allowedUpdateVersions allow-list on ForceImmediateUpdate runs
        'Private/Resolve-AzLocalForceAllowList.ps1',
        # Optional subscription-exclusion list (v0.9.1) - central ARG injection
        'Private/Resolve-AzLocalExcludedSubscriptionId.ps1',
        'Private/Get-AzLocalExcludedSubscriptionId.ps1',
        'Private/New-AzLocalSubscriptionExclusionKqlClause.ps1',
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
        'Private/Test-AzLocalReadmeReplaceable.ps1',
        'Private/Test-AzLocalUpdateAssessmentStale.ps1',
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
        'Private/Write-AzLocalPipelineError.ps1',
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
        'Public/Get-AzLocalExcludedSubscription.ps1',
        'Public/Set-AzLocalExcludedSubscription.ps1',
        'Public/Invoke-AzLocalFleetOperation.ps1',
        'Public/New-AzLocalApplyUpdatesScheduleConfig.ps1',
        'Public/New-AzLocalFleetStatusHtmlReport.ps1',
        'Public/New-AzLocalIncident.ps1',
        'Public/Reset-AzLocalSideloadedTag.ps1',
        'Public/Resolve-AzLocalCurrentUpdateRing.ps1',
        'Public/Resume-AzLocalFleetUpdate.ps1',
        'Public/Set-AzLocalClusterUpdateRingTag.ps1',
        'Public/Start-AzLocalClusterUpdate.ps1',
        # Guarded one-time retry of a FAILED update (v0.8.95) - re-applies the same
        # updates/{name}/apply action the portal 'Try again' button uses
        'Public/Invoke-AzLocalFailedUpdateRetry.ps1',
        'Public/Stop-AzLocalFleetUpdate.ps1',
        'Public/Sync-AzLocalClusterUpdateSummary.ps1',
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
        # Pipeline preflight guards (v0.9.12) - meaningful, run-summary-visible failures for the two most common silent-failure modes
        'Public/Assert-AzLocalAzureSubscriptionAccess.ps1',
        'Public/Assert-AzLocalPipelineReport.ps1',
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
        'Public/Invoke-AzLocalReadinessGatedFailedUpdateRetry.ps1',
        'Public/Add-AzLocalFailedUpdateRetryHintSummary.ps1',
        'Public/Add-AzLocalApplyUpdatesStepSummary.ps1',
        'Public/Add-AzLocalNoReadyClustersStepSummary.ps1',
        'Public/Invoke-AzLocalItsmTicketingFromArtifact.ps1'
    )

    FunctionsToExport = @(
        'Connect-AzLocalServicePrincipal',
        'Start-AzLocalClusterUpdate',
        # Guarded one-time retry of a FAILED update (v0.8.95)
        'Invoke-AzLocalFailedUpdateRetry',
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
        # Check for Updates (v0.8.88) - triggers the updateSummaries/default/checkUpdates ARM action to refresh a cluster's (potentially stale) update assessment; opt-in -Wait polls the refreshed summary
        'Sync-AzLocalClusterUpdateSummary',
        # Fleet Connectivity Status (v0.7.79) - 4-scope connectivity audit: cluster, Arc agent, physical NIC, ARB
        'Get-AzLocalFleetConnectivityStatus',
        # Fleet Connectivity Status Summary Renderer (v0.7.87) - markdown step-summary builder used by Step.4 GH+ADO pipelines
        'New-AzLocalFleetConnectivityStatusSummary',
        # Thin-YAML pipeline foundation (v0.8.5) - install-step version banner + drift annotations + step outputs (condenses ~50-line inline block in every Step.*.yml)
        'Add-AzLocalPipelineVersionBanner',
        # Pipeline preflight guards (v0.9.12) - fail early with a run-summary-visible message on the two most common silent-failure modes: zero accessible subscriptions and no diagnostic reports produced
        'Assert-AzLocalAzureSubscriptionAccess',
        'Assert-AzLocalPipelineReport',
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
        'Invoke-AzLocalReadinessGatedFailedUpdateRetry',
        'Add-AzLocalFailedUpdateRetryHintSummary',
        'Add-AzLocalApplyUpdatesStepSummary',
        'Add-AzLocalNoReadyClustersStepSummary',
        'Invoke-AzLocalItsmTicketingFromArtifact',
        # On-prem solution-update sideloading automation (v0.8.7)
        'Update-AzLocalSideloadCatalog',
        'Resolve-AzLocalSideloadPlan',
        'Invoke-AzLocalSideloadUpdate',
        'Export-AzLocalSideloadStatusReport',
        'Add-AzLocalSideloadStepSummary',
        # Optional subscription-exclusion list (v0.9.1) - central ARG-query filter
        # driven by AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH / Set-AzLocalExcludedSubscription
        'Get-AzLocalExcludedSubscription',
        'Set-AzLocalExcludedSubscription'
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
## Version 0.9.15 - Update: 1 - Assess Update Readiness surfaces two operator-guidance improvements. (1) Clusters that are 'Up to Date' ONLY because the `allowedUpdateVersions` allow-list held back every Ready update now get their own dedicated VISIBLE table ("Up to date - Ready update held by allow-list") plus a labelled "of which held by allow-list" sub-count in the Summary counts - so operators no longer have to expand "All clusters detail" to find them and copy the exact update name/version into `apply-updates-schedule.yml`. New PassThru property `AllowListHeldCount` (a labelled subset of `UpToDateCount`). (2) SBE-prerequisite Not-Ready clusters now carry a manual-action knowledge note explaining that an SBE update is a prerequisite the pipeline cannot apply automatically - operators must review their Hardware OEM provider's documentation and sideload the SBE update onto the cluster. Fixed: Update: 2 - FORCE (break-glass) runs now HONOUR the `allowedUpdateVersions` allow-list. A forced apply on the manual path (`update_ring` supplied, `use_schedule_file=false`) previously resolved an EMPTY allow-list and installed the latest Ready update, silently overriding an operator's per-ring or fleet-wide global version allow-list. `Resolve-AzLocalPipelineUpdateRing` gains a `-ForceImmediateUpdate` switch (new Private helper `Resolve-AzLocalForceAllowList`) that resolves the ring-scoped allow-list (per-ring override beats the global default; `Latest`/no allow-list still means "install the latest Ready update"), so a FORCE run now bypasses ONLY the schedule WINDOW - never the version allow-list - and never changes the operator-selected ring (degrades to latest Ready update with no throw when no schedule file is present). Both `apply-updates` templates forward the existing `force_immediate_update`/`forceImmediateUpdate` input into the resolve-ring step under the same workflow_dispatch / Build.Reason=Manual gating already used by the apply step. Fixed: `docs/cmdlet-reference.md` claimed `Stop-AzLocalFleetUpdate` calls `POST .../updateRuns/{id}/cancel` and `Resume-AzLocalFleetUpdate` calls `POST .../updateRuns/{id}/retry` - both fabricated. `Stop-AzLocalFleetUpdate` makes no Azure call (local state file + in-memory stop flag) and does not cancel in-flight update runs; `Resume-AzLocalFleetUpdate` re-drives clusters via `Invoke-AzLocalFleetOperation` (`PUT .../updateRuns/{id}`). No public function, parameter or export-count change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.15'`.

## Version 0.9.14 - Surface allow-list-suppressed Ready updates in Update: 1 - Assess Update Readiness. When an `allowedUpdateVersions` allow-list filters out every Ready update on a cluster, `Export-AzLocalClusterUpdateReadinessReport` now makes that visible: the "All clusters detail" table adds an `Available Ready updates` column (a lone Ready update renders inline; 2+ collapse behind a `<details>` expander) and the affected row's Status is marked `Up to Date *` with a conditional footnote explaining the cluster is up to date ONLY because the allow-list excluded every Ready update. `Get-AzLocalClusterUpdateReadiness` also emits an allow-list-mismatch console warning per suppressed cluster listing the exact excluded update name/version to copy into the schedule YML. The Select-AzLocalNextUpdateForCluster matcher accepts BOTH the full update `name` and the bare `properties.version`. Pipeline hardening: the shared "Install AzLocal.UpdateManagement from PSGallery" step in all 20 GitHub Actions + Azure DevOps templates now wraps `Install-Module` in a 3-attempt exponential-backoff (10s, 20s) retry so a transient PSGallery lookup blip ("No match was found ... 'AzLocal.UpdateManagement'") no longer fails the run on the first hit. Docs: added a vendor/platform-named OEM SBE example and standardised the `Solution`/`SBE` name form. No public function, parameter or export-count change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.14'`.

## Version 0.9.13 - Bug fix: Monitor: 3 - Fleet Update Status (`Export-AzLocalFleetUpdateStatusReport`) no longer crashes on a failed update run that carries a short deepest-error message. The truncation guard `[string]$f.DeepestErrMsg.Length` parses as `[string]($f.DeepestErrMsg.Length)` (member access binds tighter than the cast), so it stringified the LENGTH and then LEXICALLY compared it to 4000 - "50" -gt 4000 is TRUE - pushing a short string into `.Substring(0,4000)` and throwing "Index and length must refer to a location within the string". The message is now cast to a string once (`$deepMsg = [string]$f.DeepestErrMsg`) before the integer length check. Pre-existing since v0.8.5; surfaced on a real fleet-update-status run #40. No public function, parameter or export-count change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.13'`.

## Version 0.9.12 - Pipeline preflight guards: fail meaningfully (and visibly in the run summary) on zero subscriptions or missing reports. Two new Public cmdlets turn two confusing failure cascades into one clear, actionable message. (1) `Assert-AzLocalAzureSubscriptionAccess` counts the Enabled subscriptions visible to the authenticated identity (`az account list`); with none it writes a remediation block to the run summary (assign Reader/RBAC, confirm tenant/client id), sets `subscription_count`=0, and throws - replacing the cryptic "No subscriptions found for ***". (2) `Assert-AzLocalPipelineReport` verifies the collect step produced its report file(s) BEFORE the publish step fires its misleading "No test report files were found" warning; on zero output it points at the real upstream cause and throws. Both are wired into ALL 10 GitHub Actions and ALL 10 Azure DevOps templates (publish steps now skip on upstream failure). New Private helper `Write-AzLocalPipelineError`. Also: Monitor: 2 - Fleet Health Status (`Export-AzLocalFleetHealthStatusReport`) now adds an operator "Knowledge" note (shown only when >=1 health check is reported) reminding operators to re-run the system health checks (`Invoke-SolutionUpdatePrecheck -SystemHealth`) after remediating a failure so the ARM-stored health results refresh (per Step 7 of the update-troubleshooting docs). Export count 66 -> 68. `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.12'`.

## Version 0.9.11 - Readiness allow-list scope-leak fix + monitor default tuning. Bug fix: `Export-AzLocalClusterUpdateReadinessReport` leaked the opt-in `-SchedulePath` value into the shared `$scopeParams` hashtable, which was then reused for `Test-AzLocalClusterHealth` (a cmdlet with no `SchedulePath` parameter) - so the v0.9.1 assess-update-readiness pipeline died at the health step. Readiness now clones `$scopeParams` into a dedicated `$readinessParams` for the allow-list call and keeps the health calls on the clean `$scopeParams`. Behaviour change: `Export-AzLocalApplyUpdatesScheduleAudit` monitor-recommendation defaults tightened to reduce over-polling - `-MonitorTrailingDays` 3 -> 1 and `-MonitorInFlightHours` 6 -> 2 (cmdlet + GitHub/ADO `apply-updates-schedule-audit.yml` inputs; these defaults also apply to scheduled, not just manual, runs). No public function or export-count change (still 66). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.11'`.

For full release notes see:
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
