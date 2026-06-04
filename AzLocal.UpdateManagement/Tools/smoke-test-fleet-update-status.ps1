# ---------------------------------------------------------------------------
# Smoke test for the Step.8 fleet-update-status pipeline.
#
# Executes the full data-source set Step.8 reads, in the order the YAML runs:
#   1. Get-AzLocalClusterInventory
#   2. Get-AzLocalClusterUpdateReadiness          (CurrentVersion -> YYMM cohort)
#   3. Get-AzLocalLatestSolutionVersion           (Microsoft manifest probe)
#   4. Get-AzLocalUpdateRunFailures               (failed-runs detail view)
#   5. Get-AzLocalUpdateSummary                   (per-cluster update summary)
#   6. Get-AzLocalAvailableUpdates                (per-cluster available list)
#   7. Get-AzLocalUpdateRuns -Latest              (latest-run history)
#
# Requires: `az login`; signed-in identity has Reader on the target subscription.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ModulePath
)
$ErrorActionPreference = 'Stop'

if (-not $ModulePath) {
    $ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
}
if (-not (Test-Path $ModulePath)) { throw "Module manifest not found at: $ModulePath" }

Write-Host "Importing module: $ModulePath" -ForegroundColor Cyan
Get-Module AzLocal.UpdateManagement -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module $ModulePath -Force -ErrorAction Stop
$moduleVersion = (Get-Module AzLocal.UpdateManagement | Sort-Object Version -Descending | Select-Object -First 1).Version
Write-Host "Module version: $moduleVersion" -ForegroundColor Cyan

try { $null = Get-Command az -ErrorAction Stop }
catch { throw 'az CLI is not on PATH. Install Azure CLI and run `az login` before running this smoke test.' }
$accountJson = & az account show -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $accountJson) { throw 'az account show failed. Run `az login` and try again.' }
$account = $accountJson | ConvertFrom-Json
Write-Host "Signed-in subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan
if ($SubscriptionId -and ($account.id -ne $SubscriptionId)) {
    Write-Host "Switching to subscription $SubscriptionId ..." -ForegroundColor Yellow
    & az account set --subscription $SubscriptionId
}

$results = [System.Collections.Generic.List[object]]::new()
function Test-Cmdlet {
    param([string]$Name, [scriptblock]$Invoke, [string[]]$RequiredColumns)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    try {
        $rows = & $Invoke
        $rowCount = @($rows).Count
        Write-Host "Returned $rowCount row(s)" -ForegroundColor Yellow
        if ($rowCount -gt 0 -and $RequiredColumns -and $RequiredColumns.Count -gt 0) {
            $cols = $rows[0].PSObject.Properties.Name
            $missing = @($RequiredColumns | Where-Object { $cols -notcontains $_ })
            if ($missing.Count -eq 0) {
                Write-Host "All required columns present" -ForegroundColor Green
                $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='PASS'; Rows=$rowCount; Missing=''; Error='' })
            } else {
                Write-Host "MISSING columns: $($missing -join ', ')" -ForegroundColor Red
                $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='FAIL-SCHEMA'; Rows=$rowCount; Missing=($missing -join ','); Error='' })
            }
        } elseif ($rowCount -gt 0) {
            Write-Host "Returned $rowCount row(s) (no required-column assertion)" -ForegroundColor Green
            $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='PASS'; Rows=$rowCount; Missing=''; Error='' })
        } else {
            Write-Host "Returned 0 rows (still validates query parse + execution)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='PASS-EMPTY'; Rows=0; Missing=''; Error='' })
        }
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='ERROR'; Rows=0; Missing=''; Error=$_.Exception.Message })
    }
}

# 1. Inventory
Test-Cmdlet -Name 'Get-AzLocalClusterInventory' `
    -Invoke { Get-AzLocalClusterInventory -PassThru } `
    -RequiredColumns @('ClusterName','ResourceId')

$inventoryRows = @(Get-AzLocalClusterInventory -PassThru)
if ($inventoryRows.Count -eq 0) {
    Write-Warning 'No clusters in inventory - per-cluster sections will be PASS-EMPTY.'
    $fleetResourceIds = @()
} else {
    $fleetResourceIds = @($inventoryRows | Select-Object -ExpandProperty ResourceId)
    Write-Host "Fleet has $($fleetResourceIds.Count) cluster(s)." -ForegroundColor DarkGray
}

# 2. Readiness (Step.8 uses for YYMM cohort pivot)
Test-Cmdlet -Name 'Get-AzLocalClusterUpdateReadiness' `
    -Invoke { Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $fleetResourceIds -PassThru } `
    -RequiredColumns @('ClusterName','CurrentVersion','ReadyForUpdate')

# 3. Microsoft manifest probe (no params)
Test-Cmdlet -Name 'Get-AzLocalLatestSolutionVersion' `
    -Invoke { Get-AzLocalLatestSolutionVersion } `
    -RequiredColumns @()

# 4. Failed run history (last 30 days, unresolved)
Test-Cmdlet -Name 'Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since 30d' `
    -Invoke { Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since (Get-Date).AddDays(-30) } `
    -RequiredColumns @('ClusterName','UpdateName','State','Status','CurrentStep','Duration','LastUpdated','UpdateRunPortalUrl','DeepestErrMsg')

# 5. Per-cluster update summary
Test-Cmdlet -Name 'Get-AzLocalUpdateSummary' `
    -Invoke { Get-AzLocalUpdateSummary -ClusterResourceIds $fleetResourceIds -PassThru } `
    -RequiredColumns @()

# 6. Per-cluster available updates
Test-Cmdlet -Name 'Get-AzLocalAvailableUpdates' `
    -Invoke { Get-AzLocalAvailableUpdates -ClusterResourceIds $fleetResourceIds -PassThru } `
    -RequiredColumns @()

# 7. Latest update run per cluster
Test-Cmdlet -Name 'Get-AzLocalUpdateRuns -Latest' `
    -Invoke { Get-AzLocalUpdateRuns -ClusterResourceIds $fleetResourceIds -Latest -PassThru } `
    -RequiredColumns @('ClusterName','UpdateName','State','StartTime','EndTime')

Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
$results | Format-Table Cmdlet, Status, Rows, Missing, Error -AutoSize | Out-String -Width 200 | Write-Host
$failures = @($results | Where-Object { $_.Status -in 'FAIL-SCHEMA','ERROR' })
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) cmdlet(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All $(@($results).Count) cmdlet(s) PASSED" -ForegroundColor Green
exit 0
