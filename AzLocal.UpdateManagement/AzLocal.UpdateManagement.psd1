@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.9.1'

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
## Version 0.9.1 - Four changes in this release. (1) READINESS ALLOW-LIST OVERRIDE: `Get-AzLocalClusterUpdateReadiness` / `Export-AzLocalClusterUpdateReadinessReport` gain an opt-in `-SchedulePath` (apply-updates schedule, schema v2) and direct `-AllowedUpdateVersions` parameter. When a constraint is supplied and a cluster is NOT pinned to the `Latest` sentinel, readiness is recomputed using ONLY the allow-listed updates: a cluster whose Ready updates all fall outside its allow-list is reported `UpdateState = UpToDate` / `ReadyForUpdate = $false` (no action under the schedule), while the raw Azure update-summary state is preserved in a new `AzureUpdateState` column alongside `AllowedUpdateVersions` and `AllowListSource` (`None`/`Latest`/`Explicit`/`TopLevel`/`RowOverride`). Per-ring overrides beat the top-level fleet default via the new private resolver `Resolve-AzLocalClusterAllowList` (a `***` rings cell is the all-rings wildcard; an untagged cluster falls back to the top-level default). The default code path (neither parameter supplied) is unchanged. The assess-update-readiness GitHub Actions + Azure DevOps examples opt in automatically when a `./config/apply-updates-schedule.yml` file is present. (2) TRANSIENT LOGIN RETRY: every read-only/idempotent task across the GitHub Actions and Azure DevOps pipeline examples now retries the transient `azure/login` / `az` OIDC token-exchange failure ("Error: JSON is invalid: Expecting value...") once - GitHub workflows pair a `continue-on-error` primary login (`id: azure_login`) with an `if: steps.azure_login.outcome == 'failure'` retry step (12 guards across 10 workflows); Azure DevOps tasks use the native `retryCountOnTaskFailure: 2` (14 across 10 pipelines). Mutating tasks (Apply Updates, Retry Failed Updates, Raise ITSM tickets) are deliberately excluded to avoid duplicate-apply / duplicate-ticket risk. (3) BUG FIX: dry-run (`-WhatIf`) pipeline runs now render their step summary + outputs. When a pipeline step ran in WhatIf / dry-run mode (e.g. "Config: 2 - Manage UpdateRing Tags" with dry-run = true), `$WhatIfPreference` cascaded from the workload cmdlet into the reporting helpers and silently suppressed their `Out-File` writes (`Out-File` itself supports ShouldProcess), so the run produced ZERO step summary and ZERO step outputs - operators had to dig through the raw runner log to see what WOULD change. The pipeline reporting/artifact writes (`Add-AzLocalPipelineStepSummary`, `Set-AzLocalPipelineOutput`, and `Set-AzLocalClusterUpdateRingTagFromCsv`'s artifact-directory + JSON sidecar) now pass `-WhatIf:$false`, so a dry run always emits its full preview - the "Dry Run | True" settings row, the per-cluster "would change" detail, and the "This was a dry run. No changes were applied." footer - straight to the run Summary, while the actual Azure tag PATCH remains correctly suppressed by ShouldProcess. Additive + bug-fix - the actual Azure tag PATCH remains correctly suppressed by ShouldProcess. (4) OPTIONAL SUBSCRIPTION-EXCLUSION LIST: a new opt-in CSV lets operators exclude entire subscriptions from EVERY AzLocal.UpdateManagement Azure Resource Graph query without editing the individual KQL. Point `AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH` (pipeline/env variable) at a repo-relative CSV (columns `Subscription IDs,Subscription Name,Comment / Notes`; only the first read, each value GUID-validated, invalid rows skipped with a warning) and every query centrally appends `| where id !startswith '/subscriptions/<id>/'` via new private helpers injected once in `Invoke-AzResourceGraphQuery`. Two new public cmdlets `Get-AzLocalExcludedSubscription` / `Set-AzLocalExcludedSubscription` (`-Path`/`-SubscriptionId`/`-Clear`) inspect/override the list; a header-only CSV warns and excludes nothing; the default (unset, no explicit call) is a no-op. All 20 pipeline examples declare the variable and Copy/Update drop an inert header-only `config/Excluded-Subscription-Ids.csv` skeleton (never overwriting). Export count 64 -> 66; otherwise additive. `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.1'`.

## Version 0.9.0 - Managed repo README auto-drop. `Copy-AzLocalPipelineExample` and `Update-AzLocalPipelineExample` now also drop a lightweight, link-first `README.md` into the customer REPO ROOT (alongside the workflow folder, `config`, and the turnkey updater script), so a freshly set-up pipelines repo explains itself: what it is, how to refresh after a module release (`.\Update-Module-And-Pipelines.ps1`), and where the docs live (links to https://aka.ms/AzLocal.UpdateManagement and its CI/CD runbook). Operator content is never destroyed: the README is written only when the repo has NO usable README - missing, whitespace-only, or a GitHub "Add a README" default stub (an H1 matching the repo name plus at most a one-line description). A README already carrying the new hidden `<!-- AZLOCAL-README-VERSION: x.y.z -->` marker (invisible in rendered Markdown) is version-gate refreshed IN PLACE only when the bundled template is newer; any other non-empty README is treated as operator-owned and left untouched (remove the marker line to freeze a managed README as your own). The drop is default-on for `-Platform GitHub|AzureDevOps`, suppressed by the new `-SkipReadme` switch, and skipped for `-Platform All` (its content references the turnkey script + `config` that only exist in the single-platform layouts). The turnkey `Update-Module-And-Pipelines.ps1` template is bumped `1.1.0` -> `1.2.0` to also stage the managed README in its scoped `git add` - but ONLY when the README carries the marker, so an operator-owned README is never swept into the automated commit. Two new private helpers (`Get-AzLocalReadmeTemplateVersion`, `Test-AzLocalReadmeReplaceable`) back the drop, with full Pester coverage. Additive - no public function, parameter-removal or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.9.0'`.

## Version 0.8.99 - Follow-up to v0.8.98's turnkey updater: the dropped `Update-Module-And-Pipelines.ps1` now also stages ITSELF. When the module ships an improved updater template, `Update-AzLocalPipelineExample` (called inside the script) version-refreshes the dropped script IN PLACE - but in v0.8.98 the script's scoped `git add` staged only the workflow folder + `config`, so that self-refresh was left as an uncommitted working-tree change the operator had to spot and commit by hand. The template now resolves its own repo-relative path from `$PSCommandPath` (only when it actually lives inside the repo) and appends it to the staged paths, so the self-update is committed and pushed alongside the regenerated YAMLs. The bundled template's `# AZLOCAL-UPDATER-VERSION` marker is bumped `1.0.0` -> `1.1.0`, so a customer who already has the v1.0.0 script dropped gets this fix auto-applied on their next run (version-gated refresh). Bootstrap caveat: the single transition run that upgrades a v1.0.0 drop to v1.1.0 executes the OLD body, so that one refresh is not self-staged - the operator commits the refreshed script once, and every run thereafter self-stages. Template + tests only - no public function, parameter or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.8.99'`.

## Version 0.8.98 - Turnkey "refresh after every release" updater for the customer repo. `Copy-AzLocalPipelineExample` now also drops a self-contained `Update-Module-And-Pipelines.ps1` into the customer's REPO ROOT (alongside the existing workflow + config starter files), with the chosen devops platform (`GitHub`/`AzureDevOps`) and the resolved workflow subpath baked in at drop time. After each module release the operator just runs that one script: it `Find-Module`s the latest `AzLocal.UpdateManagement`, installs it ONLY when newer (no uninstall churn), re-imports it, calls `Update-AzLocalPipelineExample` to regenerate the pipeline YAMLs, then stages ONLY the workflow folder + `config` (`git -C $RepoRoot add -A -- $gitPaths`, never a blanket `git add .`), and commits + pushes under ShouldProcess (`-WhatIf`/`-NoPush` supported). The drop is default-on for the two single-platform modes, suppressed by the new `-SkipStarterUpdater` switch, and skipped for `-Platform All`; the template is BOM-less and verified to parse. Existing repos get it too: `Update-AzLocalPipelineExample` now drops the same script at the repo root when absent (also gated by `-SkipStarterUpdater`), since pre-v0.8.98 customers upgrade via Update not Copy. The dropped script is version-stamped (`# AZLOCAL-UPDATER-VERSION: X.Y.Z`, a dedicated template semver from `1.0.0`, independent of the module version): when the module ships an improved template, both Copy and Update re-render it IN PLACE only when the existing marker is strictly older (logged `Updated`); an up-to-date or markerless operator-owned file is preserved, never clobbered. Separately, the `Test-Pipelines.ps1` helper was renamed to `Tools/Update-Module-And-Pipelines.ps1` (Tools/ is stripped from the published package, fixing a prior leak of the maintainer script into the PSGallery nupkg). Additive - no public function, parameter-removal or export-count change (still 64). `GENERATED_AGAINST_MODULE_VERSION` bumped to `'0.8.98'`.

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
