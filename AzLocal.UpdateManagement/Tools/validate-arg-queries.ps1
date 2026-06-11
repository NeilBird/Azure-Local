# ARG-query / live-cmdlet validation harness for ALL pipeline-driver cmdlets
# in the AzLocal.UpdateManagement module. Runs each cmdlet the bundled
# Step.N pipelines call against the live AdaptiveCloudLab subscription (or
# whichever subscription `az account show` reports) and asserts the returned
# schema matches the documented shape.
#
# Per-pipeline coverage (updated v0.7.90 for the Step.N renumber):
#   Step.0 authentication-test       - covered by RUNNING the workflow itself
#                                      (inline `az graph query` + auth probes).
#   Step.1 inventory-clusters        - Get-AzLocalClusterInventory.
#   Step.2 manage-updatering-tags    - write-only (Set-AzLocalClusterUpdateRingTag);
#                                      no ARG read to smoke; out of scope here.
#   Step.3 apply-updates-schedule-audit - Test-AzLocalApplyUpdatesScheduleCoverage.
#   Step.4 fleet-connectivity-status - dedicated script `smoke-test-connectivity-status.ps1`
#                                      (Get-AzLocalFleetConnectivityStatus).
#   Step.5 assess-update-readiness   - Get-AzLocalClusterInventory,
#                                      Get-AzLocalClusterUpdateReadiness,
#                                      Test-AzLocalClusterHealth -BlockingOnly.
#   Step.6 apply-updates             - Get-AzLocalClusterUpdateReadiness
#                                      (write path Start-AzStackHciUpdate not smoked).
#   Step.7 monitor-updates (v0.7.90) - Get-AzLocalUpdateRuns -Latest +
#                                      Get-AzLocalClusterInventory.
#   Step.8 fleet-update-status       - Get-AzLocalClusterInventory,
#                                      Get-AzLocalClusterUpdateReadiness,
#                                      Get-AzLocalLatestSolutionVersion,
#                                      Get-AzLocalUpdateRunFailures,
#                                      Get-AzLocalUpdateSummary,
#                                      Get-AzLocalAvailableUpdates,
#                                      Get-AzLocalUpdateRuns -Latest.
#   Step.9 fleet-health-status       - Get-AzLocalFleetHealthFailures -View Detail,
#                                      Get-AzLocalFleetHealthOverview.
#
# Each cmdlet uses Invoke-AzResourceGraphQuery internally, which delegates
# to `az graph query` when az is on PATH. This addresses the user-mandate:
# "diligently test the ARG queries using Az CLI, to ensure the data is
# coming back correctly."
$ErrorActionPreference = 'Stop'

Get-Module AzLocal.UpdateManagement -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module 'C:\Users\nebird\Repos\Azure-Local\AzLocal.UpdateManagement\AzLocal.UpdateManagement.psd1' -Force

$results = [System.Collections.Generic.List[object]]::new()

function Test-Cmdlet {
    param(
        [string]$Name,
        [scriptblock]$Invoke,
        [string[]]$RequiredColumns
    )
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    try {
        $rows = & $Invoke
        $rowCount = @($rows).Count
        Write-Host "Returned $rowCount row(s)" -ForegroundColor Yellow
        if ($rowCount -gt 0) {
            $cols = $rows[0].PSObject.Properties.Name
            $missing = @($RequiredColumns | Where-Object { $cols -notcontains $_ })
            if ($missing.Count -eq 0) {
                Write-Host "All required columns present" -ForegroundColor Green
                $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='PASS'; Rows=$rowCount; Missing=''; Error='' })
            } else {
                Write-Host "MISSING columns: $($missing -join ', ')" -ForegroundColor Red
                $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='FAIL-SCHEMA'; Rows=$rowCount; Missing=($missing -join ','); Error='' })
            }
        } else {
            Write-Host "Returned 0 rows (still validates query parse + execution)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='PASS-EMPTY'; Rows=0; Missing=''; Error='' })
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='ERROR'; Rows=0; Missing=''; Error=$_.Exception.Message })
    }
}

# 1. Get-AzLocalClusterInventory (Step.1, Step.5, Step.7, Step.8)
# Inventory is the most basic ARG roundtrip - if this fails, every other
# pipeline is dead in the water. Validates the tag + state columns Step.1
# exports as CSV and that Step.5 / Step.7 / Step.8 hydrate fleet membership from.
# We also pin the resulting resource-id list on script scope so the per-cluster
# cmdlets below (Get-AzLocalClusterUpdateReadiness, Test-AzLocalClusterHealth,
# Get-AzLocalUpdateSummary, Get-AzLocalAvailableUpdates, Get-AzLocalUpdateRuns)
# can splat -ClusterResourceIds without prompting.
# Schema source: Get-AzLocalClusterInventory.ps1 ~L306 builds [PSCustomObject]@{ ClusterName,
# ResourceGroup, SubscriptionId, SubscriptionName, UpdateRing, HasUpdateRingTag,
# UpdateStartWindow, UpdateExclusionsWindow, UpdateExcluded, UpdateSideloaded,
# UpdateVersionInProgress, ResourceId }. The cmdlet does NOT emit Location /
# ConnectivityStatus / ClusterStatus / CurrentVersion - those columns are produced
# by Get-AzLocalClusterUpdateReadiness. Keep this list in lock-step with that builder.
Test-Cmdlet -Name 'Get-AzLocalClusterInventory' `
    -Invoke { Get-AzLocalClusterInventory -PassThru } `
    -RequiredColumns @('ClusterName','ResourceGroup','SubscriptionId','UpdateRing','HasUpdateRingTag','UpdateStartWindow','UpdateExclusionsWindow','UpdateExcluded','UpdateSideloaded','UpdateVersionInProgress','ResourceId')

# Hydrate fleet resource-id list once for downstream per-cluster cmdlets.
$inventoryRows = @(Get-AzLocalClusterInventory -PassThru)
$script:fleetResourceIds = @($inventoryRows | ForEach-Object {
    "/subscriptions/$($_.SubscriptionId)/resourceGroups/$($_.ResourceGroup)/providers/Microsoft.AzureStackHCI/clusters/$($_.ClusterName)"
})
Write-Host "`nFleet has $($script:fleetResourceIds.Count) cluster(s) - reusing for per-cluster cmdlet validation." -ForegroundColor DarkGray

# 2. Get-AzLocalClusterUpdateReadiness (Step.5, Step.6, Step.8)
# Pre-flight readiness signal; Step.6 filters on ReadyForUpdate=true and Step.8
# pivots CurrentVersion -> YYMM cohort.
Test-Cmdlet -Name 'Get-AzLocalClusterUpdateReadiness' `
    -Invoke { Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $script:fleetResourceIds } `
    -RequiredColumns @('ClusterName','ClusterResourceId','ReadyForUpdate','HealthState','CurrentVersion','UpdateRing','UpdateStartWindow','UpdateExclusionsWindow','UpdateExcluded','SBEDependency','BlockingReasons')

# 3. Test-AzLocalClusterHealth -BlockingOnly (Step.5)
# Returns one row per cluster (-PassThru) summarising blocking-only health-check
# state plus per-cluster pass/fail counts.
Test-Cmdlet -Name 'Test-AzLocalClusterHealth -BlockingOnly' `
    -Invoke { Test-AzLocalClusterHealth -ClusterResourceIds $script:fleetResourceIds -BlockingOnly -PassThru } `
    -RequiredColumns @('ClusterName','HealthState')

# 4. Get-AzLocalUpdateRuns (Step.7 monitor-updates and Step.8 fleet-update-status)
# Multi-cluster mode requires -PassThru to receive rows on the pipeline (see
# Get-AzLocalUpdateRuns.ps1 ~L667); without it the cmdlet writes Format-Table to host
# and returns nothing. Schema is built ~L600-L615: ClusterName, UpdateName, State,
# StartTime, EndTime, Duration, Progress.
Test-Cmdlet -Name 'Get-AzLocalUpdateRuns' `
    -Invoke { Get-AzLocalUpdateRuns -ClusterResourceIds $script:fleetResourceIds -Latest -PassThru } `
    -RequiredColumns @('ClusterName','UpdateName','State','StartTime','EndTime')

# 5. Get-AzLocalUpdateSummary (Step.8)
Test-Cmdlet -Name 'Get-AzLocalUpdateSummary' `
    -Invoke { Get-AzLocalUpdateSummary -ClusterResourceIds $script:fleetResourceIds -PassThru } `
    -RequiredColumns @()

# 6. Get-AzLocalAvailableUpdates (Step.8)
Test-Cmdlet -Name 'Get-AzLocalAvailableUpdates' `
    -Invoke { Get-AzLocalAvailableUpdates -ClusterResourceIds $script:fleetResourceIds -PassThru } `
    -RequiredColumns @()

# 7. Get-AzLocalLatestSolutionVersion (Step.8 - Microsoft manifest probe used to derive YYMM support window)
# Not ARG; reads the Microsoft public manifest. Smoke-testing here keeps the whole
# Step.8 data-source set under one runnable validator.
Test-Cmdlet -Name 'Get-AzLocalLatestSolutionVersion' `
    -Invoke { Get-AzLocalLatestSolutionVersion } `
    -RequiredColumns @()

# 8. Get-AzLocalFleetStatusData (legacy fleet-status helper retained for callers)
# Returns a single summary/aggregate object (FleetUpdateState + per-cluster array), not
# per-cluster rows; we only assert the ARG query executes cleanly here.
Test-Cmdlet -Name 'Get-AzLocalFleetStatusData' `
    -Invoke { Get-AzLocalFleetStatusData } `
    -RequiredColumns @()

# 9. Get-AzLocalFleetHealthFailures (Step.9; v0.7.70 added ClusterPortalUrl)
Test-Cmdlet -Name 'Get-AzLocalFleetHealthFailures' `
    -Invoke { Get-AzLocalFleetHealthFailures -View Detail } `
    -RequiredColumns @('ClusterName','ClusterPortalUrl','FailureName','FailureReason','Severity')

# 10. Get-AzLocalFleetHealthOverview (Step.9; v0.7.70 NEW cmdlet)
Test-Cmdlet -Name 'Get-AzLocalFleetHealthOverview' `
    -Invoke { Get-AzLocalFleetHealthOverview } `
    -RequiredColumns @('ClusterName','ClusterPortalUrl','HealthStatus','UpdateStatus','CurrentVersion','SbeVersion','AzureConnection','LastChecked','HealthResultsAgeDays')

# 11. Get-AzLocalUpdateRunFailures (Step.8; v0.7.70 fleet-scale failure-detail columns)
Test-Cmdlet -Name 'Get-AzLocalUpdateRunFailures' `
    -Invoke { Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since (Get-Date).AddDays(-60) } `
    -RequiredColumns @('ClusterName','UpdateName','State','Status','CurrentStep','Duration','LastUpdated','UpdateRunPortalUrl','DeepestErrMsg')

# 12. Test-AzLocalApplyUpdatesScheduleCoverage (Step.3; v0.7.69 touched, smoke-tested in v0.7.70 cycle)
Test-Cmdlet -Name 'Test-AzLocalApplyUpdatesScheduleCoverage' `
    -Invoke {
        $scheduleFile = 'C:\Users\nebird\Repos\Azure-Local\AzLocal.UpdateManagement\Automation-Pipeline-Examples\schedule-coverage-example.json'
        if (Test-Path $scheduleFile) {
            Test-AzLocalApplyUpdatesScheduleCoverage -SchedulePath $scheduleFile
        } else {
            Write-Host "  (no example schedule file; skipping)" -ForegroundColor DarkYellow
            return @()
        }
    } `
    -RequiredColumns @()

# 13. Resolve-AzLocalSideloadPlan (Step.6 sideload-updates; v0.8.7 NEW)
# Read-only planner. Its ARG query selects clusters carrying an
# UpdateAuthAccountId tag; the auth-map + catalog are operator-authored config
# with no bundled live example, so we synthesise minimal valid temp files. On a
# fleet with no UpdateAuthAccountId-tagged clusters the plan is legitimately
# empty (PASS-EMPTY) - that still validates the ARG query parsed/executed and
# the schedule/auth/catalog parsers did not throw. Dedicated, sequence-faithful
# coverage lives in Tools/smoke-test-sideload-plan.ps1.
Test-Cmdlet -Name 'Resolve-AzLocalSideloadPlan' `
    -Invoke {
        $scheduleFile = 'C:\Users\nebird\Repos\Azure-Local\AzLocal.UpdateManagement\Automation-Pipeline-Examples\apply-updates-schedule.example.yml'
        if (-not (Test-Path $scheduleFile)) {
            Write-Host "  (no example schedule file; skipping)" -ForegroundColor DarkYellow
            return @()
        }
        $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "argv-step6-$(Get-Random)") -Force
        try {
            $authMap = Join-Path $tmp.FullName 'sideload-auth-map.csv'
            @(
                'UpdateAuthAccountId,KeyVaultName,UsernameSecretName,PasswordSecretName,RemotingTargetFqdn,FqdnSuffix,AuthMechanism,ImportSharePath'
                '001,kv-smoke,sideload-user,sideload-pass,,.smoke.contoso.com,Negotiate,'
            ) | Set-Content -LiteralPath $authMap -Encoding ASCII
            $catalog = Join-Path $tmp.FullName 'sideload-catalog.yml'
            @(
                'schemaVersion: 1'
                'packages:'
                "  - version: '12.2605.1003.210'"
                '    packageType: Solution'
                "    downloadUri: 'https://download.contoso.com/CombinedSolutionBundle.12.2605.1003.210.zip'"
                "    sha256: 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789'"
            ) | Set-Content -LiteralPath $catalog -Encoding ASCII
            Resolve-AzLocalSideloadPlan -SchedulePath $scheduleFile -AuthMapPath $authMap -CatalogPath $catalog
        }
        finally {
            Remove-Item -Path $tmp.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    } `
    -RequiredColumns @('ClusterName','ClusterResourceId','UpdateAuthAccountId','Ring','DueNow','SelectedVersion','PackageType','RemotingHost','TargetPath','Status','Message')

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " ARG / Pipeline-driver Validation Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$fail = @($results | Where-Object { $_.Status -in @('FAIL-SCHEMA','ERROR') })
if ($fail.Count -eq 0) { Write-Host "`nAll pipeline-driver ARG queries validated against live fleet." -ForegroundColor Green }
else { Write-Host "`n$($fail.Count) cmdlet(s) failed validation." -ForegroundColor Red; exit 1 }
