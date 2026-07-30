@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.9.28'

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
        'Private/Convert-AzLocalFleetSettingsSchemaVersion.ps1',
        'Private/ConvertTo-AzLocalClusterTagFilterKqlClause.ps1',
        'Private/ConvertTo-AzLocalAdditionalProperties.ps1',
        'Private/ConvertTo-AzLocalMarkdownTableCell.ps1',
        'Private/ConvertTo-SafeCsvCollection.ps1',
        'Private/ConvertTo-SafeCsvField.ps1',
        'Private/ConvertTo-ScrubbedCliOutput.ps1',
        'Private/ConvertTo-AzLocalUpdateRingKqlFilter.ps1',
        'Private/Export-ResultsToJUnitXml.ps1',
        'Private/Format-AzLocalDurationHuman.ps1',
        'Private/Format-AzLocalIncidentBody.ps1',
        'Private/Format-AzLocalUpdateRun.ps1',
        'Private/Format-AzLocalUpdateLastAttemptTagValue.ps1',
        'Private/Get-AzLocalApplyScheduleSourceBanner.ps1',
        'Private/Get-AzLocalClusterReadinessStatus.ps1',
        'Private/Get-AzLocalClusterTagFilterKqlClause.ps1',
        'Private/Get-AzLocalGlobalClusterScope.ps1',
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
        'Private/Invoke-AzLocalResourceGraphValueBatches.ps1',
        'Private/Invoke-AzResourceGraphQuery.ps1',
        'Private/Invoke-AzRestJson.ps1',
        'Private/Invoke-AzLocalUpdateApply.ps1',
        'Private/Invoke-FleetJobsInParallel.ps1',
        'Private/Invoke-FleetOpClusterAction.ps1',
        'Private/Read-AzLocalApplyUpdatesYamlCrons.ps1',
        'Private/Repair-AzLocalExcludedSubscriptionCsv.ps1',
        'Private/Resolve-AzLocalHardwareOem.ps1',
        'Private/Resolve-AzLocalItsmSecret.ps1',
        'Private/Resolve-AzLocalUpdateRunDeepestError.ps1',
        'Private/Resolve-SafeOutputPath.ps1',
        'Private/Resolve-WildcardDate.ps1',
        'Private/Resolve-WildcardDateRange.ps1',
        'Private/Test-AzLocalClusterMatchesTagFilter.ps1',
        'Private/Test-AzLocalClusterResourceInGlobalScope.ps1',
        'Private/Set-AzLocalClusterTagsMerge.ps1',
        'Private/Test-AzLocalUpdateRunsInFlight.ps1',
        'Private/Write-AzLocalUpdateLastAttemptTag.ps1',
        # On-prem solution-update sideloading automation (v0.8.7)
        'Private/Get-AzLocalSideloadAuthMap.ps1',
        'Private/Get-AzLocalSideloadCatalog.ps1',
        'Private/Convert-AzLocalSideloadCatalogSchemaVersion.ps1',
        'Private/ConvertTo-AzLocalSideloadSettingsHashtable.ps1',
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
        'Public/Get-AzLocalFleetSettings.ps1',
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
        'Public/Get-AzLocalSideloadSettings.ps1',
        # On-prem solution-update sideloading automation (v0.8.7) - planner, orchestrator, reporting
        'Public/Resolve-AzLocalSideloadPlan.ps1',
        'Public/Invoke-AzLocalSideloadUpdate.ps1',
        'Public/Export-AzLocalSideloadStatusReport.ps1',
        # Thin-YAML pipeline foundation (v0.8.5)
        'Public/Add-AzLocalPipelineVersionBanner.ps1',
        # Support-disclaimer footer (v0.9.18) - final-step banner rendered at the bottom of every pipeline summary
        'Public/Add-AzLocalPipelineSupportFooter.ps1',
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
        'Public/Invoke-AzLocalItsmTicketingFromArtifact.ps1',
        'Public/Invoke-AzLocalPipelineTimedOperation.ps1'
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
        # Support-disclaimer footer (v0.9.18) - rendered at the very bottom of every pipeline run summary via a final if:always() step
        'Add-AzLocalPipelineSupportFooter',
        # Pipeline preflight guards (v0.9.12) - fail early with a run-summary-visible message on the two most common silent-failure modes: zero accessible subscriptions and no diagnostic reports produced
        'Assert-AzLocalAzureSubscriptionAccess',
        'Assert-AzLocalPipelineReport',
        # First-class cross-task pipeline timing journal (v0.9.28)
        'Invoke-AzLocalPipelineTimedOperation',
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
        'Get-AzLocalSideloadSettings',
        'Resolve-AzLocalSideloadPlan',
        'Invoke-AzLocalSideloadUpdate',
        'Export-AzLocalSideloadStatusReport',
        'Add-AzLocalSideloadStepSummary',
        # Optional subscription-exclusion list (v0.9.1) - central ARG-query filter
        # driven by AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH / Set-AzLocalExcludedSubscription
        'Get-AzLocalExcludedSubscription',
        'Set-AzLocalExcludedSubscription',
        # Optional fleet-wide ARG scope and reporting/ITSM limits (v0.9.22)
        'Get-AzLocalFleetSettings'
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
## Version 0.9.28 - ARM recovery, retry correlation, tag-aware idle detection, and large-fleet batching. All 20 pipelines add always-on timing JSON plus opt-in transcripts with bounded ARG/ARM telemetry. Exports 71 -> 72.

## Version 0.9.27 - Minute-17 schedules, seven-minute Apply lead, and job timeouts. Schema v4 adds strict UpdateStartWindow allowances and backed-up v1/v2/v3 migration. No export change (71).

## Version 0.9.26 - Update: 1 scopes and batches ARG reads, preserves Ready solutions beside prerequisite SBE, reconciles stale ARG rows, and emits clean-run JUnit. No export change (71).

## Version 0.9.25 - Fixes large readiness summaries, normalizes Markdown cells, and expands Config: 3 remediation. No export change (71).

## Version 0.9.24 - Adds grouped fleet tag admission, null-safe cloud payload handling, and 2,000-row reporting limits. No export change (71).

## Version 0.9.23 - Adds global cluster tag admission across read and mutation boundaries with backed-up schema migration. No export change (71).

## Version 0.9.22 - ARG payload hardening. The shared query helper recovers from ResponsePayloadTooLarge by halving --first and retaining the smaller size across skip-token pages. Monitor: 2 starts health-result paging at 50 rows; Monitor: 1 projects only consumed fields. No public/export change (69). Pipeline pins bumped to 0.9.22.

## Version 0.9.21 - Monitor: 2 - Fleet Health Status: the "Cluster Counts" summary table now counts each cluster ONCE by its HIGHEST failing-check severity. The single "Unhealthy Clusters (with failing checks)" row (previously stamped with the Critical icon even when it also contained warning-only clusters) is split into a Critical row and a Warning-only row; a cluster with BOTH Critical and Warning failing checks is counted in the Critical row only. The "Other" bucket is renamed to make clear it holds clusters whose health check is In progress / Unknown with no failing detail rows. Count-table rows now use bare-glyph icons (check / cross / warning / info) so the severity word is no longer duplicated (previously rendered "Critical Critical" / "Critical Unhealthy..."). New step outputs critical_clusters + warning_only_clusters and new PassThru properties CriticalClusters + WarningOnlyClusters. Monitor: 1 - Fleet Connectivity Status: each row of the "Fleet Connectivity Status Summary" KPI table is now prefixed with a bare-glyph status indicator (green tick / red cross) for visual consistency with the other pipeline step-summary tables. No public function or export-count change (still 69). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.21'`.

## Version 0.9.20 - Monitor: 3 - Fleet Update Status: the "Fleet - SBE Version(s) Distribution" table is reworked to group by hardware OEM provider and read the correct YYMM. Solution Builder Extension (SBE) packages are vendor-specific, so the table now leads with an "OEM Provider" first column and groups clusters PRIMARILY by hardware OEM (Dell / HPE / Lenovo / Microsoft / ...) then by SBE YYMM. The OEM is resolved from each cluster's reported node manufacturer (properties.reportedProperties.nodes[].manufacturer) via the new private helper Resolve-AzLocalHardwareOem; a new readiness-row field SbeOemProvider carries it (also in readiness-status.csv). SBE YYMM is now read from the THIRD version octet (<major>.<minor>.<YYMM>.<build>, e.g. 5.0.2605.1000 -> 2605, 5.0.2603.1522 -> 2603); v0.9.19 incorrectly used the second octet. Clusters with no vendor SBE (the base placeholders 2.0.0.0 / 2.1.0.0 and any cluster with no SBE package) now show "N/A - No SBE Installed" for YYMM (genuinely not present, not "unknown") while still grouping under their hardware OEM. Export count unchanged at 69 (Resolve-AzLocalHardwareOem is private). Renders identically on GitHub Actions and Azure DevOps. `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.20'`.

## Version 0.9.19 - Update: 1 - Assess Update Readiness fixes an SBE-prerequisite mis-classification, surfaces which updates the allowedUpdateVersions allow-list is filtering out, and Monitor: 3 - Fleet Update Status gains two new tables. FIX: a cluster with a genuinely-Ready update is no longer mislabelled "SBE Prerequisite / Not-Ready" just because it also carries a HasPrerequisite SBE update - the shared classifier Get-AzLocalClusterReadinessStatus (Update: 1 / Apply-Updates readiness gate / Monitor: 3) tested SbeBlocked before ReadyForUpdate; it is now gated on there being no Ready update, so a cluster with a Ready feature update AND a HasPrerequisite SBE classifies as ReadyForUpdate (only a cluster whose sole available update is the prereq item stays SbeBlocked). Assess Update Readiness adds an "Updates filtered out by the allow-list" table: when the allow-list removes updates Azure reports as Ready, this fleet-wide aggregate (not per cluster) lists each filtered-out update, whether the rule is Global (top-level) or Per-Ring (row override), the affected ring(s), and a distinct cluster count - so operators can see which update names to add to apply-updates-schedule.yml (new step output allowlist_filtered_updates + PassThru AllowListFilteredUpdateCount). Assess Update Readiness also adds a "Status checked (UTC)" column (the updateSummary lastChecked - when Azure last scanned the cluster for updates) to the Not-Ready + detail tables (new row field StatusLastChecked); a stale value explains why a portal-visible update is not yet Ready, with a note to refresh via Sync-AzLocalClusterUpdateSummary before re-running. Monitor: 3 - Fleet Update Status adds (1) a "Fleet - SBE Version(s) Distribution" table pivoting each cluster's installed SBE version (vendor.YYMM.x.x); base placeholders 2.0.0.0 / 2.1.0.0 and clusters with no SBE content show as "No SBE Installed" (YYMM column kept, no Support column - SBE has no Microsoft support window); and (2) an "Updates - Recent Successful Updates" table listing runs that reached Succeeded in the last 48h with Cluster + Update portal deep-links. Headers renamed: "Fleet Version Distribution" -> "Fleet - Solution Update(s) Version Distribution"; "Update Run History and Error Details" -> "Updates - Recent Failed Update Attempts". Supporting: Get-AzLocalUpdateRuns rows carry a raw EndTimeUtc [datetime]; Step 4c collects the full run set (no -Latest). New step outputs sbe_version_dist_count, recently_completed_48h. Export count unchanged at 69. `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.19'`.

## Version 0.9.18 - Follow-up strict-mode hardening after v0.9.17. A live re-run of Update: 3 - Apply Updates showed the failed-update single-retry STILL crashed on one cluster with "The property 'steps' cannot be found on this object". v0.9.17 guarded only the TOP-LEVEL progress.steps read in Format-AzLocalUpdateRun; the recursive step-tree walkers it calls (Get-DeepestActiveStep, Get-CurrentStepPath, Get-DeepestErrorMessage, Find-DeepestError) still read $step.steps/status/name/errorMessage BARE and threw under Set-StrictMode -Version Latest on a LEAF step omitting `steps`. All walker reads are now guarded; a broader strict-mode audit hardened more optional-field bare reads across Get-AzLocalUpdateSummary, Get-AzLocalAvailableUpdates, Get-AzLocalClusterUpdateReadiness, Get-AzLocalFleetStatusData, Get-AzLocalUpdateRunHealthEvidence and Get-AzLocalFleetHealthFailures. Also new: a Support disclaimer footer (new exported helper Add-AzLocalPipelineSupportFooter, wired as a final if:always() step in all 20 templates) renders at the bottom of every pipeline run summary, plus a caveat line on the install-step version banner. Export count 68 -> 69. `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.18'`.

## Version 0.9.17 - PSGallery install-step retry hardened to survive a PROLONGED search-index outage. After a customer hit a PSGallery blip that outlasted the v0.9.16 5-attempt / ~2.5-min window (all 5 attempts failed with "No match was found ... 'AzLocal.UpdateManagement'"), the shared install step in all 20 GitHub Actions + Azure DevOps templates (26 install blocks) now retries up to 25 attempts (~25 min) with the same capped exponential backoff + jitter (10s, 20s, 40s, then a 60s cap). This is ONE uniform mechanism on BOTH platforms - a single long-retry run - deliberately chosen over a self-re-queue so GitHub Actions and Azure DevOps behave identically and no extra permissions (GH 'actions: write' / ADO Queue-builds) are required. ~25 min stays under the ADO 60-min hosted-agent job cap; GitHub-hosted runners have a 6-hour cap. Normal-path behaviour is unchanged (a healthy install returns on the first attempt) and the latest module version is still installed. ALSO in this release: the Update: 3 - Apply Updates step summaries (readiness gate + apply) now open, on scheduled/cron runs, with a banner making it explicit that the targeted UpdateRing(s) are derived from the operator's own apply-updates-schedule.yml (path + current cycle day + matched rings), with the Apply banner recommending Config: 3 - Apply-Updates Schedule Coverage Audit for the full per-day cycle (new Private helper Get-AzLocalApplyScheduleSourceBanner; renders nothing on manual runs); the Apply-Updates "Cluster Readiness" table gains an UpdateRing column after Cluster (plus a matching UpdateRing field on every readiness row / readiness-report.csv); and a Set-StrictMode -Version Latest crash retrying a failed update whose ARM run omits `location` or `progress.steps` (Format-AzLocalUpdateRun, also hardened in Get-AzLocalFleetStatusData + Get-LastUpdateRunErrorSummary) is fixed with PSObject.Properties guards. No public function or export-count change (still 68). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.17'`.

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
