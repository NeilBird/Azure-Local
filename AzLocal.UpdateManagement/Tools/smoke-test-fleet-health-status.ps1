# ---------------------------------------------------------------------------
# Smoke test for the Step.9 fleet-health-status pipeline.
#
# Executes the two cmdlets Step.9 reads:
#   1. Get-AzLocalFleetHealthOverview              (one row per cluster - KPI source)
#   2. Get-AzLocalFleetHealthFailures -View Detail (one row per failing check)
#
# Important: as of v0.7.76 Get-AzLocalFleetHealthFailures uses
# `array_length(properties.healthCheckResult)` rather than `mv-expand` to
# work around the ARG 128-row mv-expand cap. This smoke test exercises
# the cmdlet end-to-end and validates the documented schema is intact.
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

# 1. Overview (one row per cluster)
Test-Cmdlet -Name 'Get-AzLocalFleetHealthOverview' `
    -Invoke { Get-AzLocalFleetHealthOverview } `
    -RequiredColumns @('ClusterName','ClusterPortalUrl','HealthStatus','UpdateStatus','CurrentVersion','SbeVersion','AzureConnection','LastChecked','HealthResultsAgeDays')

# 2. Failures detail (one row per failing check; validates the v0.7.76 array_length fix)
Test-Cmdlet -Name 'Get-AzLocalFleetHealthFailures -View Detail' `
    -Invoke { Get-AzLocalFleetHealthFailures -View Detail } `
    -RequiredColumns @('ClusterName','ClusterPortalUrl','FailureName','FailureReason','Severity')

# 3. Export round-trip (Step.9 writes both as CSV artifacts)
$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "smoke-step9-$(Get-Random)") -Force
try {
    $overviewCsv = Join-Path $tmpDir.FullName 'overview.csv'
    $detailCsv   = Join-Path $tmpDir.FullName 'detail.csv'
    Test-Cmdlet -Name 'Get-AzLocalFleetHealthOverview -ExportPath csv' `
        -Invoke {
            Get-AzLocalFleetHealthOverview -ExportPath $overviewCsv -PassThru | Out-Null
            if (-not (Test-Path $overviewCsv)) { throw "Overview CSV not written to $overviewCsv" }
            Import-Csv -Path $overviewCsv
        } `
        -RequiredColumns @('ClusterName','HealthStatus')
    Test-Cmdlet -Name 'Get-AzLocalFleetHealthFailures -View Detail -ExportPath csv' `
        -Invoke {
            Get-AzLocalFleetHealthFailures -View Detail -ExportPath $detailCsv -PassThru | Out-Null
            if (-not (Test-Path $detailCsv)) { throw "Detail CSV not written to $detailCsv" }
            Import-Csv -Path $detailCsv
        } `
        -RequiredColumns @('ClusterName','FailureName','Severity')
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
