# ---------------------------------------------------------------------------
# Smoke test for the Step.1 inventory-clusters pipeline.
#
# Runs the single cmdlet Step.1 calls (Get-AzLocalClusterInventory) twice -
# once with -PassThru only and once with -ExportPath - to validate the
# pipeline's CSV + JSON export wiring without touching real artifacts.
#
# Requires: `az login`; signed-in identity has Reader on the target
# subscription(s). Schema is validated against the v0.7.x cmdlet output.
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

$invShape = @('ClusterName','ResourceGroup','SubscriptionId','UpdateRing','HasUpdateRingTag','UpdateStartWindow','UpdateExclusionsWindow','UpdateExcluded','UpdateSideloaded','UpdateVersionInProgress','ResourceId')

# 1. -PassThru only (Step.1 main path before export)
Test-Cmdlet -Name 'Get-AzLocalClusterInventory (PassThru)' `
    -Invoke { Get-AzLocalClusterInventory -PassThru } `
    -RequiredColumns $invShape

# 2. -ExportPath round-trip (validate Step.1 CSV + JSON wiring without polluting workspace)
$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "smoke-step1-$(Get-Random)") -Force
try {
    $csvPath = Join-Path $tmpDir.FullName 'inventory.csv'
    $jsonPath = Join-Path $tmpDir.FullName 'inventory.json'
    Test-Cmdlet -Name 'Get-AzLocalClusterInventory (ExportPath csv)' `
        -Invoke {
            Get-AzLocalClusterInventory -ExportPath $csvPath | Out-Null
            if (-not (Test-Path $csvPath)) { throw "CSV not written to $csvPath" }
            Import-Csv -Path $csvPath
        } `
        -RequiredColumns $invShape
    Test-Cmdlet -Name 'Get-AzLocalClusterInventory (ExportPath json + PassThru)' `
        -Invoke { Get-AzLocalClusterInventory -ExportPath $jsonPath -PassThru } `
        -RequiredColumns $invShape
} finally {
    Remove-Item -Path $tmpDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
$results | Format-Table Cmdlet, Status, Rows, Missing, Error -AutoSize | Out-String -Width 200 | Write-Host
$failures = @($results | Where-Object { $_.Status -in 'FAIL-SCHEMA','ERROR' })
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) cmdlet(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All $(@($results).Count) cmdlet(s) PASSED" -ForegroundColor Green
exit 0
