# ---------------------------------------------------------------------------
# Smoke test for the Step.5 assess-update-readiness pipeline.
#
# Executes the exact cmdlet sequence Step.5 runs:
#   1. Get-AzLocalClusterInventory                  (build resource-id list)
#   2. Get-AzLocalClusterUpdateReadiness            (readiness audit)
#   3. Test-AzLocalClusterHealth -BlockingOnly      (blocking-health audit)
#
# Validates schema on each output and asserts the merged-JUnit-XML wiring
# (introduced in v0.7.90) by exercising both -ExportPath .csv and .xml paths.
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

# 1. Inventory (Step.5 fetches this unconditionally in v0.7.90+ for the ring-pivot map)
Test-Cmdlet -Name 'Get-AzLocalClusterInventory' `
    -Invoke { Get-AzLocalClusterInventory -PassThru } `
    -RequiredColumns @('ClusterName','ResourceId','UpdateRing')

$inventoryRows = @(Get-AzLocalClusterInventory -PassThru)
if ($inventoryRows.Count -eq 0) {
    Write-Warning 'No clusters in inventory - downstream sections will all be PASS-EMPTY.'
    $fleetResourceIds = @()
} else {
    $fleetResourceIds = @($inventoryRows | Select-Object -ExpandProperty ResourceId)
    Write-Host "Fleet has $($fleetResourceIds.Count) cluster(s) - reusing for per-cluster cmdlets." -ForegroundColor DarkGray
}

$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "smoke-step5-$(Get-Random)") -Force
try {
    $readinessCsv = Join-Path $tmpDir.FullName 'readiness.csv'
    $readinessXml = Join-Path $tmpDir.FullName 'readiness.xml'
    $healthCsv    = Join-Path $tmpDir.FullName 'health-blocking.csv'
    $healthXml    = Join-Path $tmpDir.FullName 'health-blocking.xml'

    # 2. Readiness audit - CSV + PassThru
    Test-Cmdlet -Name 'Get-AzLocalClusterUpdateReadiness (CSV + PassThru)' `
        -Invoke { Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $fleetResourceIds -ExportPath $readinessCsv -PassThru } `
        -RequiredColumns @('ClusterName','ClusterResourceId','ReadyForUpdate','HealthState','CurrentVersion','UpdateState','BlockingReasons','RecommendedUpdate')

    # 3. Readiness audit - JUnit XML emission (validates the .xml ExportPath branch)
    Test-Cmdlet -Name 'Get-AzLocalClusterUpdateReadiness (JUnit XML)' `
        -Invoke {
            $null = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $fleetResourceIds -ExportPath $readinessXml
            if (-not (Test-Path $readinessXml)) { throw "JUnit XML not written to $readinessXml" }
            [xml](Get-Content -LiteralPath $readinessXml -Raw)
        } `
        -RequiredColumns @()

    # 4. Blocking health - per-cluster summary (-PassThru)
    Test-Cmdlet -Name 'Test-AzLocalClusterHealth -BlockingOnly (CSV + PassThru)' `
        -Invoke { Test-AzLocalClusterHealth -ClusterResourceIds $fleetResourceIds -BlockingOnly -ExportPath $healthCsv -PassThru } `
        -RequiredColumns @('ClusterName','HealthState','CriticalCount','WarningCount')

    # 5. Blocking health - JUnit XML emission
    Test-Cmdlet -Name 'Test-AzLocalClusterHealth -BlockingOnly (JUnit XML)' `
        -Invoke {
            $null = Test-AzLocalClusterHealth -ClusterResourceIds $fleetResourceIds -BlockingOnly -ExportPath $healthXml
            if (-not (Test-Path $healthXml)) { throw "JUnit XML not written to $healthXml" }
            [xml](Get-Content -LiteralPath $healthXml -Raw)
        } `
        -RequiredColumns @()

    # 6. Merged JUnit XML wiring (v0.7.90 - validates the combined-publisher emit logic)
    Test-Cmdlet -Name 'Merged JUnit XML build (v0.7.90 wiring)' `
        -Invoke {
            $combinedXml = Join-Path $tmpDir.FullName 'assess-readiness.xml'
            $readinessDoc = [xml](Get-Content -LiteralPath $readinessXml -Raw)
            $healthDoc    = [xml](Get-Content -LiteralPath $healthXml -Raw)
            $combinedDoc  = New-Object System.Xml.XmlDocument
            $combinedDoc.AppendChild($combinedDoc.CreateXmlDeclaration('1.0','utf-8',$null)) | Out-Null
            $root = $combinedDoc.CreateElement('testsuites')
            $root.SetAttribute('name','Update Readiness Assessment')
            $combinedDoc.AppendChild($root) | Out-Null
            foreach ($srcDoc in @($readinessDoc,$healthDoc)) {
                $suites = if ($srcDoc.DocumentElement.LocalName -eq 'testsuites') {
                    $srcDoc.DocumentElement.SelectNodes('testsuite')
                } else { ,$srcDoc.DocumentElement }
                foreach ($suite in $suites) {
                    $imported = $combinedDoc.ImportNode($suite,$true)
                    $root.AppendChild($imported) | Out-Null
                }
            }
            $combinedDoc.Save($combinedXml)
            if (-not (Test-Path $combinedXml)) { throw "Combined XML not written" }
            $verify = [xml](Get-Content -LiteralPath $combinedXml -Raw)
            $suiteCount = @($verify.testsuites.testsuite).Count
            if ($suiteCount -lt 2) { throw "Combined XML has $suiteCount suite(s); expected at least 2" }
            ,(@($verify.testsuites.testsuite))
        } `
        -RequiredColumns @()
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
