#Requires -Version 5.1
<#
.SYNOPSIS
    AzLocal.UpdateManagement module for automating updates on Azure Local (formerly Azure Stack HCI) clusters.

.DESCRIPTION
    This module queries Azure Local clusters by name or resource ID, checks their update status,
    and starts specified updates on clusters that are in "Ready" state with "UpdatesAvailable".

    It uses the Azure REST API directly via az rest to call the Update Manager API.

    Includes comprehensive logging capabilities with timestamped log files,
    transcript support, and result export to JSON/CSV.

    Supports Service Principal authentication for CI/CD automation scenarios
    (GitHub Actions, Azure DevOps Pipelines).

    NOTE: Renamed from AzStackHci.ManageUpdates in v0.7.3. Module GUID is preserved
    across the rename. See CHANGELOG.md and the v0.7.3 release notes in the manifest
    for migration guidance.

.PARAMETER ClusterNames
    An array of Azure Local cluster names to update. Use this OR ClusterResourceIds.

.PARAMETER ClusterResourceIds
    An array of full Azure Resource IDs for the clusters to update. Use this when clusters
    are in different resource groups or subscriptions. Use this OR ClusterNames.
    
    The Resource IDs are validated before processing to ensure:
    - The format is correct (must match Azure Stack HCI cluster resource pattern)
    - The resource exists in Azure
    - You have the required permissions to access the resource
    
    Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"

.PARAMETER ScopeByUpdateRingTag
    Uses the "UpdateRing" tag to find clusters via Azure Resource Graph.
    Must be used together with -UpdateRingValue. This enables updating clusters at scale
    using the UpdateRing tagging strategy. Works across multiple subscriptions.
    
    Requires the Azure CLI 'resource-graph' extension (automatically installed if missing).

.PARAMETER UpdateRingValue
    The value of the UpdateRing tag to match when using -ScopeByUpdateRingTag. Only clusters 
    where the UpdateRing tag equals this value will be selected for updates.
    Common values: "Ring1", "Ring2", "Ring3", "Production"

.PARAMETER ResourceGroupName
    The resource group containing the clusters. If not specified, the function will 
    search for the cluster across all resource groups in the subscription.
    Only used with -ClusterNames parameter.

.PARAMETER SubscriptionId
    The Azure subscription ID. If not specified, uses the current az CLI subscription.
    Only used with -ClusterNames parameter.

.PARAMETER UpdateName
    The specific update name to apply. If not specified, the function will list 
    available updates and prompt for selection or apply the latest available update.

.PARAMETER ApiVersion
    The API version to use. Defaults to "2025-10-01".

.PARAMETER LogFolderPath
    Path to the folder where log files will be created. If not specified, defaults to:
    C:\ProgramData\AzLocal.UpdateManagement\
    
    This default location is accessible across different user profiles.
    The folder is automatically created if it doesn't exist.

.PARAMETER EnableTranscript
    Enables PowerShell transcript recording to capture all console output.

.PARAMETER ExportResultsPath
    Path to export results. Supports multiple formats based on file extension:
    - .json = JSON format with summary statistics
    - .csv  = Standard CSV format
    - .xml  = JUnit XML format for CI/CD pipeline integration
    
    JUnit XML is compatible with:
    - Azure DevOps (Publish Test Results task)
    - GitHub Actions (dorny/test-reporter or similar)
    - Jenkins (JUnit plugin)
    - GitLab CI (native support)
    - TeamCity (built-in)
    
    If no extension is provided, defaults to JSON.

.PARAMETER WhatIf
    Shows what would happen if the cmdlet runs. The cmdlet is not run.

.EXAMPLE
    # Start update on a single cluster with logging
    Start-AzLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG" -LogPath "C:\Logs\update.log"

.EXAMPLE
    # Start updates on multiple clusters with transcript and JSON export
    Start-AzLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") -EnableTranscript -ExportResultsPath "C:\Logs\results.json"

.EXAMPLE
    # Start a specific update with full logging
    Start-AzLocalClusterUpdate -ClusterNames "MyCluster01" -UpdateName "Solution12.2601.1002.38" -LogPath "C:\Logs\update.log" -EnableTranscript

.EXAMPLE
    # Start updates on clusters in different resource groups using Resource IDs
    $resourceIds = @(
        "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
        "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
    )
    Start-AzLocalClusterUpdate -ClusterResourceIds $resourceIds -Force

.EXAMPLE
    # Start updates on all clusters tagged with "UpdateRing" = "Ring1" (across all subscriptions)
    Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Ring1" -Force

.EXAMPLE
    # Start updates on production ring clusters
    Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Production" -UpdateName "Solution12.2601.1002.38" -Force

.EXAMPLE
    # Export results to JUnit XML for CI/CD pipeline integration (Azure DevOps, GitHub Actions, Jenkins)
    Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Ring1" -Force -ExportResultsPath "C:\Logs\update-results.xml"

.NOTES
    Author: Neil Bird, Microsoft. 
    Requires: Azure CLI (az) installed and authenticated
    API Reference: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/stable/2026-02-01/hci.json

    Strict mode: This module sets `Set-StrictMode -Version 1.0` at module
    load (NOT `-Version Latest`). Version 1.0 catches the most common
    correctness bug class - references to uninitialized variables (e.g.
    `$cluster` vs `$clusterEntry` typos) - without breaking on the dozens
    of Azure ARM REST dot-notation property accesses that legitimately
    return $null when a property is omitted (e.g.
    `additionalProperties.SBEPublisher`, `tags.UpdateRing`). Hardening
    every such site to satisfy `-Version Latest` is tracked as a future
    refactor; see comment block immediately above the `Set-StrictMode`
    call in this file, and Finding 9 of v0.7.76 module review.
#>

# Enforce defensive coding at module scope.
# Version 1.0 catches references to uninitialized variables (e.g. $cluster vs $clusterEntry typos).
# Deliberately NOT -Version Latest: Azure ARM REST responses legitimately omit optional
# properties (e.g. additionalProperties.SBEPublisher, tags.UpdateRing), and Latest would
# throw on every such dot-notation access. Hardening those sites is tracked separately.
Set-StrictMode -Version 1.0

# Module constants
# IMPORTANT: $script:ModuleVersion must match ModuleVersion in AzLocal.UpdateManagement.psd1.
# The Pester guard 'Module version constants are in sync' enforces this every test run so
# bumps to one but not the other are caught before release. Two consumers:
#   - Start-AzLocalClusterUpdate emits this in the run log header.
#   - Get-AzLocalFleetStatusData stamps it into exported fleet-state JSON.
$script:ModuleVersion = '0.7.99'
$script:DefaultApiVersion = '2025-10-01'
$script:DefaultLogFolder = Join-Path -Path $env:ProgramData -ChildPath 'AzLocal.UpdateManagement'

# Best-effort default for PYTHONIOENCODING. az.cmd launches python with the -I
# (isolated) flag which implies -E and so causes python to IGNORE all PYTHON*
# environment variables - meaning this assignment alone is NOT sufficient to
# stop the cp1252 encode warning. The actual fixes live in two helpers:
#   1. Invoke-AzRestJson passes --only-show-errors to every az invocation
#      (v0.7.2 hardening) so warning lines stay out of stdout.
#   2. Invoke-AzResourceGraphQuery splits the merged 2>&1 capture by element
#      type after capture (v0.7.66): stderr surfaces as ErrorRecord objects
#      and only the string stdout is fed to ConvertFrom-Json.
# This module-load assignment is retained as harmless defence-in-depth for
# the case where the user has manually patched az.cmd to remove -I, or is
# running in an environment that respects the env var. See:
# https://github.com/Azure/azure-cli/issues/14426 (recommended workaround),
# https://github.com/Azure/azure-cli/issues/28497 (-I behaviour confirmation).
if (-not $env:PYTHONIOENCODING) {
    $env:PYTHONIOENCODING = 'utf-8'
}

# Update state constants aligned with Azure Resource Graph queries against the cluster updateSummaries resource
# States that indicate an update is installable (ready to apply)
$script:ReadyStates = @('Ready', 'ReadyToInstall')
# States that indicate an update is blocked by a prerequisite
$script:PrereqStates = @('HasPrerequisite', 'AdditionalContentRequired')
# States that indicate an update failed health validation
$script:HealthCheckFailedStates = @('HealthCheckFailed')
# States that indicate an update is in a transitional phase
$script:TransitionalStates = @('Downloading', 'Preparing', 'HealthChecking')

# Script-level variables for logging
$script:LogFilePath = $null
$script:ErrorLogPath = $null
$script:UpdateSkippedLogPath = $null
$script:UpdateStartedLogPath = $null

# Service Principal authentication state
$script:ServicePrincipalAuthenticated = $false


# ---------------------------------------------------------------------------
# Module-scope state hoisted from between function definitions during refactor.
# These declarations must run BEFORE any function body that references them.
# ---------------------------------------------------------------------------
$script:UpdateStartWindowTagName = 'UpdateStartWindow'

# v0.7.90: renamed from 'UpdateExclusions' to 'UpdateExclusionsWindow' for naming
# consistency with the new UpdateExcluded operator-override gate and the
# companion UpdateStartWindow tag. Breaking change - clusters with the legacy
# 'UpdateExclusions' tag are ignored from v0.7.90 onwards; operators must
# re-tag with 'UpdateExclusionsWindow'.
$script:UpdateExclusionsWindowTagName = 'UpdateExclusionsWindow'

# v0.7.90: operator-set hard override. When 'True'/'1' (case-insensitive) the
# cluster is skipped by Start-AzLocalClusterUpdate regardless of UpdateRing
# scope, UpdateSideloaded state, or UpdateStartWindow / UpdateExclusionsWindow
# schedule. Set-AzLocalClusterUpdateRingTag stamps the tag with 'False' on
# any cluster that does not already carry it, so the tag is discoverable in
# the Azure portal and ready for an operator to flip.
$script:UpdateExcludedTagName = 'UpdateExcluded'

$script:UpdateSideloadedTagName = 'UpdateSideloaded'

$script:UpdateVersionInProgressTagName = 'UpdateVersionInProgress'

# Current apply-updates-schedule.yml schema version produced + consumed by
# this module. Incremented when a non-additive change to the schedule file
# format ships. Customer files on a LOWER version are auto-migrated by
# Update-AzLocalPipelineExample via the per-hop recipes registered in
# Private/Convert-AzLocalScheduleSchemaVersion.ps1. Customer files on a
# HIGHER version cause the migrator to refuse with a remediation message
# pointing at PSGallery.
#
# v1 -> v2 (shipped in v0.7.89): adds the optional `allowedUpdateVersions`
# field (top-level fleet default + per-row override) for operators who want
# to install only an explicit set of Azure Local solution-update version
# strings ('minimum updates' style: YY04 + YY10 feature updates +
# preceding cumulative updates) instead of the cmdlet's default 'latest
# Ready update' behaviour. v1 files remain readable; the additive field is
# silently absent.
$script:ScheduleSchemaCurrentVersion = 2

$script:DayMap = [ordered]@{
    'Mon' = [DayOfWeek]::Monday
    'Tue' = [DayOfWeek]::Tuesday
    'Wed' = [DayOfWeek]::Wednesday
    'Thu' = [DayOfWeek]::Thursday
    'Fri' = [DayOfWeek]::Friday
    'Sat' = [DayOfWeek]::Saturday
    'Sun' = [DayOfWeek]::Sunday
}

$script:DayAbbreviations = @('Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun')

$script:FleetOperationState = $null

# ---------------------------------------------------------------------------
# Function loading.
# All Public/* and Private/* function files are listed in the manifest's
# NestedModules and are imported by PowerShell at module load time. No
# dot-source loop is needed here. Removing the loop (v0.7.76, Finding 6)
# eliminates a duplicate parse of every script when the module is loaded
# via its .psd1 (the supported path), shaving a measurable amount off cold
# start. If you load this file directly (e.g. some Pester scenarios that
# Import-Module the .psm1 path), import the .psd1 instead so NestedModules
# is honoured.
# ---------------------------------------------------------------------------
Export-ModuleMember -Function @(
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
    # Update Schedule Tag Helpers (v0.6.5)
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
    # Fleet Health Overview (v0.7.70) - one row per cluster, ARG-first projection of cluster + updateSummaries
    'Get-AzLocalFleetHealthOverview',
    # Latest Released Solution Version (v0.7.70 Phase E) - public manifest probe (aka.ms/AzureEdgeUpdates) that anchors the rolling YYMM support window in Step.6
    'Get-AzLocalLatestSolutionVersion',
    # Fleet Connectivity Status (v0.7.79) - 4-scope connectivity audit: cluster, Arc agent, physical NIC, ARB
    'Get-AzLocalFleetConnectivityStatus',
    # Fleet Connectivity Status Summary Renderer (v0.7.87) - markdown step-summary builder used by Step.4 GH+ADO pipelines
    'New-AzLocalFleetConnectivityStatusSummary'
)