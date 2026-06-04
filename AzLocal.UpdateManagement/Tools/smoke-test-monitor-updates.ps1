# ---------------------------------------------------------------------------
# Smoke test for the Step.7 monitor-updates pipeline (v0.7.90 NEW).
#
# Executes the cmdlet sequence Step.7 runs in both scope modes:
#   Scope = by-update-ring : Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue X -Latest
#   Scope = all-clusters   : Get-AzLocalClusterInventory + Get-AzLocalUpdateRuns -ClusterResourceIds -Latest
#
# Step.7 is an in-flight monitor that emits per-cluster InProgress / Failed
# status as JUnit XML; this smoke test validates the underlying ARG queries
# work and return the expected schema.
#
# Requires: `az login`; signed-in identity has Reader on the target subscription.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ModulePath,
    [string]$UpdateRingValue = 'Wave1'
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
    } catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Cmdlet=$Name; Status='ERROR'; Rows=0; Missing=''; Error=$_.Exception.Message })
    }
}

$runsShape = @('ClusterName','UpdateName','State','StartTime','EndTime')

# 1. Scope = all-clusters path (inventory then per-cluster runs)
Test-Cmdlet -Name 'Get-AzLocalClusterInventory (Step.7 all-clusters scope)' `
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

Test-Cmdlet -Name 'Get-AzLocalUpdateRuns -ClusterResourceIds -Latest -PassThru' `
    -Invoke { Get-AzLocalUpdateRuns -ClusterResourceIds $fleetResourceIds -Latest -PassThru } `
    -RequiredColumns $runsShape

# 2. Scope = by-update-ring path - validates the ARG ring-tag filter
Test-Cmdlet -Name "Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue $UpdateRingValue -Latest" `
    -Invoke { Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue $UpdateRingValue -Latest } `
    -RequiredColumns $runsShape

Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
$results | Format-Table Cmdlet, Status, Rows, Missing, Error -AutoSize | Out-String -Width 200 | Write-Host
$failures = @($results | Where-Object { $_.Status -in 'FAIL-SCHEMA','ERROR' })
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) cmdlet(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All $(@($results).Count) cmdlet(s) PASSED" -ForegroundColor Green
exit 0
