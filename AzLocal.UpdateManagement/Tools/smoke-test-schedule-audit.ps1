# ---------------------------------------------------------------------------
# Smoke test for the Step.3 apply-updates-schedule-audit pipeline.
#
# Runs Test-AzLocalApplyUpdatesScheduleCoverage in the three view modes
# the pipeline emits (default audit, -View Matrix, -View Recommend) using
# the bundled schedule-coverage-example.json file as input. Validates the
# audit summary returns without erroring and that exported files are
# created.
#
# Step.3 also peeks at Get-AzLocalApplyUpdatesScheduleConfig for its
# inline schedule diagnostics; covered as a 4th section here.
#
# Requires: `az login` (downstream cmdlets occasionally hit ARG for cluster
# membership), signed-in identity has Reader on the target subscription.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ModulePath,
    [string]$SchedulePath
)
$ErrorActionPreference = 'Stop'

if (-not $ModulePath) {
    $ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
}
if (-not (Test-Path $ModulePath)) { throw "Module manifest not found at: $ModulePath" }
if (-not $SchedulePath) {
    $SchedulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\Automation-Pipeline-Examples\apply-updates-schedule.example.yml'
}
if (-not (Test-Path $SchedulePath)) {
    throw "Schedule example file not found at: $SchedulePath - pass -SchedulePath to override"
}

Write-Host "Importing module: $ModulePath" -ForegroundColor Cyan
Get-Module AzLocal.UpdateManagement -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module $ModulePath -Force -ErrorAction Stop
$moduleVersion = (Get-Module AzLocal.UpdateManagement | Sort-Object Version -Descending | Select-Object -First 1).Version
Write-Host "Module version: $moduleVersion" -ForegroundColor Cyan
Write-Host "Schedule file : $SchedulePath" -ForegroundColor Cyan

try { $null = Get-Command az -ErrorAction Stop }
catch { Write-Warning 'az CLI not on PATH; schedule audit will run without live cluster correlation.' }
if (Get-Command az -ErrorAction SilentlyContinue) {
    $accountJson = & az account show -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and $accountJson) {
        $account = $accountJson | ConvertFrom-Json
        Write-Host "Signed-in subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan
        if ($SubscriptionId -and ($account.id -ne $SubscriptionId)) {
            Write-Host "Switching to subscription $SubscriptionId ..." -ForegroundColor Yellow
            & az account set --subscription $SubscriptionId
        }
    } else {
        Write-Warning 'az account show failed; schedule audit will skip live cluster lookups.'
    }
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

# 1. Default audit (no view selector) - the primary pipeline call
Test-Cmdlet -Name 'Test-AzLocalApplyUpdatesScheduleCoverage (default)' `
    -Invoke { Test-AzLocalApplyUpdatesScheduleCoverage -SchedulePath $SchedulePath } `
    -RequiredColumns @()

# 2. -View Matrix - pipeline exports as CSV
$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "smoke-step3-$(Get-Random)") -Force
try {
    $matrixCsv = Join-Path $tmpDir.FullName 'matrix.csv'
    Test-Cmdlet -Name 'Test-AzLocalApplyUpdatesScheduleCoverage -View Matrix (export)' `
        -Invoke {
            Test-AzLocalApplyUpdatesScheduleCoverage -SchedulePath $SchedulePath -View Matrix -LeadTimeMinutes 60 -ExportPath $matrixCsv | Out-Null
            if (-not (Test-Path $matrixCsv)) { throw "Matrix CSV not written to $matrixCsv" }
            Import-Csv -Path $matrixCsv
        } `
        -RequiredColumns @()

    # 3. -View Recommend - pipeline exports as markdown
    $recoMd = Join-Path $tmpDir.FullName 'reco.md'
    Test-Cmdlet -Name 'Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend (export)' `
        -Invoke {
            Test-AzLocalApplyUpdatesScheduleCoverage -SchedulePath $SchedulePath -View Recommend -LeadTimeMinutes 60 -Platform GitHubActions -ExportPath $recoMd | Out-Null
            if (-not (Test-Path $recoMd)) { throw "Recommend MD not written to $recoMd" }
            ,(@(Get-Content -LiteralPath $recoMd))
        } `
        -RequiredColumns @()

    # 3a (v0.7.92): -View Recommend with default -RecommendFiresPerWindow=2 (belt-and-braces)
    #     - every window should emit TWO crons (an `(open)` and a `(retry)`)
    Test-Cmdlet -Name 'Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -RecommendFiresPerWindow 2 (belt-and-braces, default)' `
        -Invoke {
            $rows = Test-AzLocalApplyUpdatesScheduleCoverage -SchedulePath $SchedulePath -View Recommend -LeadTimeMinutes 60 -Platform GitHubActions -PassThru
            if (-not $rows) { return @() }
            $rows = @($rows)
            $openCount  = @($rows | Where-Object { $_.Snippet -match '\(open\)' }).Count
            $retryCount = @($rows | Where-Object { $_.Snippet -match '\(retry\)' }).Count
            Write-Host "  Recommend rows: $($rows.Count) (open snippets: $openCount, retry snippets: $retryCount)" -ForegroundColor Gray
            if ($rows.Count -gt 0 -and $retryCount -lt 1) {
                throw "Expected at least one (retry) cron in Recommend snippet when -RecommendFiresPerWindow defaults to 2; saw $retryCount"
            }
            $rows
        } `
        -RequiredColumns @()

    # 3b (v0.7.92): -View Recommend with -RecommendFiresPerWindow 1 (back-compat)
    #     - every window should emit ONLY the opening-edge cron (no `(retry)` snippet)
    Test-Cmdlet -Name 'Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -RecommendFiresPerWindow 1 (back-compat)' `
        -Invoke {
            $rows = Test-AzLocalApplyUpdatesScheduleCoverage -SchedulePath $SchedulePath -View Recommend -RecommendFiresPerWindow 1 -LeadTimeMinutes 60 -Platform GitHubActions -PassThru
            if (-not $rows) { return @() }
            $rows = @($rows)
            $retryCount = @($rows | Where-Object { $_.Snippet -match '\(retry\)' }).Count
            Write-Host "  Recommend rows: $($rows.Count) (retry snippets: $retryCount - should be 0)" -ForegroundColor Gray
            if ($retryCount -gt 0) {
                throw "Expected zero (retry) crons when -RecommendFiresPerWindow 1; saw $retryCount"
            }
            $rows
        } `
        -RequiredColumns @()
} finally {
    Remove-Item -Path $tmpDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

# 4. Schedule-config parser (Step.3 reads it for its inline schedule-diagnostics block)
Test-Cmdlet -Name 'Get-AzLocalApplyUpdatesScheduleConfig (parse example)' `
    -Invoke { Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath } `
    -RequiredColumns @()

# 5 (v0.7.92): default audit also surfaces RingMixedWindows row when the live
#     fleet has 2+ clusters in the same UpdateRing carrying different
#     UpdateStartWindow values. The bucket is informational (not gated), so
#     PASS-EMPTY is acceptable; we only verify the code path runs without
#     erroring and any emitted RingMixedWindows row carries the expected
#     shape (joined UpdateStartWindow values with ' | ' separator).
Test-Cmdlet -Name 'Test-AzLocalApplyUpdatesScheduleCoverage default audit - RingMixedWindows shape (live)' `
    -Invoke {
        $rows = @(Test-AzLocalApplyUpdatesScheduleCoverage -SchedulePath $SchedulePath -PassThru)
        $mixed = @($rows | Where-Object Status -eq 'RingMixedWindows')
        Write-Host "  Audit rows: $($rows.Count) (RingMixedWindows: $($mixed.Count))" -ForegroundColor Gray
        foreach ($m in $mixed) {
            if (-not $m.UpdateRing)   { throw "RingMixedWindows row missing UpdateRing" }
            if (-not $m.ClusterCount) { throw "RingMixedWindows row missing ClusterCount" }
            if ($m.UpdateStartWindow -notmatch ' \| ') {
                throw "RingMixedWindows row UpdateStartWindow '$($m.UpdateStartWindow)' missing expected ' | ' separator"
            }
            Write-Host "    Ring='$($m.UpdateRing)' Clusters=$($m.ClusterCount) Windows='$($m.UpdateStartWindow)'" -ForegroundColor Yellow
        }
        $rows
    } `
    -RequiredColumns @()

Write-Host "`n========== Summary ==========" -ForegroundColor Cyan
$results | Format-Table Cmdlet, Status, Rows, Missing, Error -AutoSize | Out-String -Width 200 | Write-Host
$failures = @($results | Where-Object { $_.Status -in 'FAIL-SCHEMA','ERROR' })
if ($failures.Count -gt 0) {
    Write-Host "$($failures.Count) cmdlet(s) FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All $(@($results).Count) cmdlet(s) PASSED" -ForegroundColor Green
exit 0
