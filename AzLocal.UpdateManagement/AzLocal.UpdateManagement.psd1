@{
    # Script module or binary module file associated with this manifest.
    RootModule = 'AzLocal.UpdateManagement.psm1'

    # Version number of this module.
    ModuleVersion = '0.8.3'

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
## Version 0.8.3 - Test-AzLocalApplyUpdatesScheduleCoverage Step.3 advisor accuracy + readability fixes: -View Recommend now diff-prunes against `-PipelineYamlPath` (no more false-positive "Action required - cron coverage" on steady-state fleets); Step.3 GH/ADO yml `pipeline_path`/`pipelinePath` now REQUIRED (silent schedule-only fall-through removed); Step.3 yml now passes `-PipelineYamlPath` to the Recommend invocation; Allow-list "How to fix - edit `$schedulePath`" heading reframed to "Optional - pin a ring to a specific update" + explicit disclaimer; closing-fence typo `"``````n"` -> `"```````n"` fixed at four sites across GH+ADO

Step.3 advisor accuracy + readability fixes. No public API removed. One cmdlet behaviour change: `-View Recommend` now diff-prunes against an existing Step.6 yml when `-PipelineYamlPath` is supplied.

- **Recommend now drops any cron expression that already exists in `-PipelineYamlPath`.** Pre-v0.8.3 the snippet was built purely from cluster tags + `Convert-AzLocalUpdateWindowToCron`, so steady-state fleets received an "Action required - cron coverage" header that re-emitted the same cron lines already present in Step.6_apply-updates.yml, and operators pasted duplicates. The cmdlet now reads the supplied `-PipelineYamlPath`, parses cron entries via `Read-AzLocalApplyUpdatesYamlCrons` (same helper as Audit), and prunes every recommended cron whose expression matches one already present. Only the truly missing crons land in the snippet.
- **Step.3 GH + ADO yml: `pipeline_path` / `pipelinePath` is now REQUIRED.** GitHub Actions input gets `required: true`; Azure DevOps adds a runtime throw with a clear error pointing to common pipeline folders that DO exist in the repo. The silent schedule-only fall-through is gone - without it the diff-prune would have no Step.6 to diff against and every Recommend run would be a false positive. `schedule_path` / `schedulePath` stays optional.
- **Step.3 yml now passes `-PipelineYamlPath` to the Recommend invocation.** Pre-v0.8.3 the `-View Recommend` call was always made without `-PipelineYamlPath`, so even after the cmdlet supported the diff-prune the snippet would still have been the un-pruned full set. Both Step.3 templates now build a `$recoArgs` splat that includes `PipelineYamlPath = $pipelinePath`.
- **Step.3 yml `### How to fix - edit `$schedulePath`` heading reframed** to `### Optional - pin a ring to a specific update in `$schedulePath``. The v0.8.2 heading sounded like "the fix for the higher-blast-radius cron-coverage or ring-diff sections is to edit `$schedulePath`", but it was only ever about the OPTIONAL `allowedUpdateVersions:` pin (e.g. keeping Prod on the latest feature drop only). Body now says explicitly *"This is NOT a fix for the cron-coverage or ring-diff sections above - those have their own 'Action required' blocks."*
- **Closing-fence typo fix.** Both Step.3 templates had `$md += "``````n"` in two places (after the schema-v1 migrate snippet and after the `allowedUpdateVersions:` example yaml). In PowerShell double-quoted strings, six backticks = three literal backticks but the trailing `n` becomes a literal `n` (not a newline) because the backticks all pair up before reaching it. Result: the rendered markdown showed `` ``` `` followed by a literal `n` and the subsequent paragraphs got swept into the code block. Fixed to seven backticks + `n` at all four sites (GH x2, ADO x2).
- **Pester suite updates**: drift-sync test bumped to `Should -Be '0.8.3'`; the v0.8.2 Allow-list heading-shape test rewritten to assert the new reframed heading + disclaimer and to ASSERT-NOT the old `### How to fix - edit `$schedulePath`` shape; new tests added to cover Recommend diff-prune behaviour against synthetic Step.6 yml fixtures.
- **All 20 bundled `Step.{0..9}.yml` templates** bump `GENERATED_AGAINST_MODULE_VERSION` from `'0.8.2'` to `'0.8.3'`.

## Version 0.8.2 - Test-AzLocalApplyUpdatesScheduleCoverage operator-UX release: -View Recommend snippet embeds `# All cron times below are UTC` comment + `Indent tip` blockquote; -View Audit `NoWindowTag` row now names affected clusters grouped by `UpdateRing` + sorts AFTER Covered; Step.3 GH/ADO Allow-list section trimmed; five new internal pipeline-host helpers (Get/Set/Add/Write-AzLocalPipeline*) laid down as foundations for the upcoming executable-YAML refactor

For full v0.8.2 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.8.1 - Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend GH snippet emits ONLY the `schedule:` block (no `on:` / `workflow_dispatch:` lines) so it can be pasted straight into Step.6_apply-updates.yml without producing a duplicate-key YAML error

For full v0.8.1 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.8.0 - Step.7 form-default regressions fixed (criticalElapsedDays 7->3, updateRing Wave1->empty) + Pii-Guard.Tests.ps1 (repo-hygiene guard) + Publish-Module.ps1 excludes maintainer-only RELEASE-PROCESS.md

For full v0.8.0 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Version 0.7.99 - Property/Summary renames (AvailableUpdates -> AllAvailableUpdates, AvailableUpdatesCount -> ActionableUpdatesCount, Ready/NotReady Summary -> ReadyForUpdate/UpToDate/NotReadyForUpdate) + Step.7 CRITICAL elapsed-days 7->3 + artifact zip names prefixed with step.X-

For full v0.7.99 release notes see:
https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/CHANGELOG.md

## Versions 0.7.72 - 0.7.98 (cumulative)

Step.7 monitor-updates UX overhaul - severity tiers, chip stacks, fleet badge, per-cell icons + Step.7/Step.8 JUnit `time=` populated (0.7.98); in-package documentation follow-up to v0.7.96 (0.7.97); portal-parity - Status field, ErrorMessage column, StepError JUnit type, always-show unresolved Failed, Step.8 ActionRequired bucket (0.7.96); Update-AzLocalPipelineExample pin-only short-circuit + Step.0/Step.1 marker blocks (0.7.95); Step.7 monitor-updates hotfix - missing -PassThru caused silent "0 in-flight" snapshots (0.7.94); pipeline JUnit summaries - fix NaNms in duration column + Pester regression guard (0.7.93); Step.9 fleet-health step summary per-cluster collapsible details + Step.7 default schedule (5x/day) + Step.3 belt-and-braces retry crons + `RingMixedWindows` warning (0.7.92); Step.7 monitor-updates parser bug + Step.3 schedule-audit cosmetic fixes (0.7.91); new `UpdateExcluded` operator-override tag + breaking rename `UpdateExclusions` -> `UpdateExclusionsWindow` + pipeline renumber + new Step.7 monitor-updates (0.7.90); apply-updates schedule schema v2 - mandatory `allowedUpdateVersions` allow-list with `Latest` sentinel (0.7.89); Step.8 fleet-health step-summary readability polish (0.7.88); extract Step.4 fleet-connectivity summary renderer to module function + 21K-cap Pester regression guard (0.7.87); Automation-Pipeline-Examples README + appendix refreshed for 9-step pipeline set (0.7.86); Step.4 reconciliation table bidirectional interpretation (0.7.85); Get-AzLocalFleetConnectivityStatus hotfix - 3 bugs + ARG throttle cooldown (0.7.84); Step.4 ARB [char].Trim() hotfix on single-cluster ClusterId (0.7.83); bundled custom-role JSON artifact (0.7.82); pipeline RBAC guidance - custom role first (0.7.81); RBAC custom role fleet-connectivity reads (0.7.80); Step.5 default schedule enabled (0.7.79); Step.4 blank-field regression fix (0.7.78); Step.4 fleet-connectivity hotfix (0.7.77); module rename to `-AzLocal*` + quality hardening (0.7.76); Test-AzLocalApplyUpdatesScheduleCoverage CI host auto-detect (0.7.75); Get-AzLocalFleetHealthOverview KQL fix + Step.3 recommendation UX rewrite (0.7.74); Get-AzLocalFleetHealthOverview HealthState normalisation (0.7.73); pipeline samples hotfix - Step.1/2/5 GH Actions summary panels + AZURE_TENANT_ID secret->variable (0.7.72). Full per-version notes:
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
