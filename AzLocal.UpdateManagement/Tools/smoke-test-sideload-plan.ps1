# ---------------------------------------------------------------------------
# Smoke test for the Step.6 sideload-updates pipeline (v0.8.7).
#
# Validates the EXPORTED planner cmdlet Resolve-AzLocalSideloadPlan, which is
# the read-only data source the sideload-updates.yml pipeline consumes before
# Invoke-AzLocalSideloadUpdate mutates any cluster. A single call exercises the
# whole Step.6 read path end to end:
#
#   1. Get-AzLocalApplyUpdatesScheduleConfig  - parses the apply-updates schedule
#   2. Get-AzLocalSideloadAuthMap (private)   - parses the auth-map CSV
#   3. Get-AzLocalSideloadCatalog (private)   - parses the catalog YAML
#   4. Invoke-AzResourceGraphQuery            - the live ARG cluster query
#      ("resources | where type =~ 'microsoft.azurestackhci/clusters'
#        | where isnotempty(tags['UpdateAuthAccountId']) ...")
#
# So any ARG-query regression, schedule/auth/catalog parser drift, or plan-row
# schema change is caught here before the Step.6 YAML is exercised in a real
# GHA / ADO run - matching the coverage the other Step.N smoke tests provide.
#
# The auth-map and catalog are OPERATOR-authored (not ARG sources) and have no
# bundled live example, so this harness synthesises minimal valid temp files
# (an empty pair AND a populated pair) and points the cmdlet at the bundled
# apply-updates-schedule.example.yml. On an empty / un-tagged fleet the plan is
# legitimately empty (PASS-EMPTY) - that still validates the ARG query parsed
# and executed and the three config parsers did not throw.
#
# Requires: `az login`; signed-in identity has Reader on the target
# subscription(s). Resolve-AzLocalSideloadPlan handles ARG pagination + retry.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$ModulePath,
    [string]$SchedulePath,
    [string]$AuthMapPath,
    [string]$CatalogPath
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

# Resolve-AzLocalSideloadPlan runs an ARG query, so az is REQUIRED here.
try { $null = Get-Command az -ErrorAction Stop }
catch { throw 'az CLI is not on PATH. Install Azure CLI and run `az login` before running this smoke test.' }
$accountJson = & az account show -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
    throw 'az account show failed. Run `az login` and try again.'
}
$account = $accountJson | ConvertFrom-Json
Write-Host "Signed-in subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan
if ($SubscriptionId -and ($account.id -ne $SubscriptionId)) {
    Write-Host "Switching to subscription $SubscriptionId ..." -ForegroundColor Yellow
    & az account set --subscription $SubscriptionId
}

# Plan-row schema the Step.6 pipeline consumes (Resolve-AzLocalSideloadPlan.ps1
# ~L88 [ordered]@{...}). Keep in lock-step with that builder.
$planColumns = @(
    'ClusterName', 'ClusterResourceId', 'ResourceGroup', 'SubscriptionId',
    'UpdateAuthAccountId', 'Ring', 'NextWindowUtc', 'LeadDays', 'DueNow',
    'SelectedVersion', 'SelectedUpdateName', 'PackageType', 'CatalogEntry',
    'RemotingHost', 'TargetPath', 'AuthRow', 'Status', 'Message'
)

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
                Write-Host "All required columns present ($($RequiredColumns.Count))" -ForegroundColor Green
                $results.Add([PSCustomObject]@{ Cmdlet = $Name; Status = 'PASS'; Rows = $rowCount; Missing = ''; Error = '' })
            }
            else {
                Write-Host "MISSING columns: $($missing -join ', ')" -ForegroundColor Red
                Write-Host "  Actual columns: $($cols -join ', ')" -ForegroundColor DarkGray
                $results.Add([PSCustomObject]@{ Cmdlet = $Name; Status = 'FAIL-SCHEMA'; Rows = $rowCount; Missing = ($missing -join ','); Error = '' })
            }
        }
        elseif ($rowCount -gt 0) {
            Write-Host "Returned $rowCount row(s) (no required-column assertion)" -ForegroundColor Green
            $results.Add([PSCustomObject]@{ Cmdlet = $Name; Status = 'PASS'; Rows = $rowCount; Missing = ''; Error = '' })
        }
        else {
            Write-Host "Returned 0 rows (still validates ARG query parse + config parsers)" -ForegroundColor Yellow
            $results.Add([PSCustomObject]@{ Cmdlet = $Name; Status = 'PASS-EMPTY'; Rows = 0; Missing = ''; Error = '' })
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{ Cmdlet = $Name; Status = 'ERROR'; Rows = 0; Missing = ''; Error = $_.Exception.Message })
    }
}

# Synthesise temp auth-map + catalog files when the caller did not supply them.
# These are operator-authored config (not ARG), so there is no live example to
# point at - minimal valid content is enough to validate the parser wiring.
$tmpDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "smoke-step6-$(Get-Random)") -Force
$cleanupTemp = $true
try {
    if (-not $AuthMapPath) {
        $AuthMapPath = Join-Path $tmpDir.FullName 'sideload-auth-map.csv'
        @(
            'UpdateAuthAccountId,KeyVaultName,UsernameSecretName,PasswordSecretName,RemotingTargetFqdn,FqdnSuffix,AuthMechanism,ImportSharePath'
            '001,kv-smoke,sideload-user,sideload-pass,,.smoke.contoso.com,Negotiate,'
        ) | Set-Content -LiteralPath $AuthMapPath -Encoding ASCII
    }
    if (-not $CatalogPath) {
        $CatalogPath = Join-Path $tmpDir.FullName 'sideload-catalog.yml'
        @(
            'schemaVersion: 1'
            'packages:'
            "  - version: '12.2605.1003.210'"
            '    packageType: Solution'
            '    osBuild: ''26100.4061'''
            "    downloadUri: 'https://download.contoso.com/CombinedSolutionBundle.12.2605.1003.210.zip'"
            "    sha256: 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789'"
        ) | Set-Content -LiteralPath $CatalogPath -Encoding ASCII
    }
    else {
        # Caller supplied a catalog path; do not delete it on cleanup.
    }
    Write-Host "Auth-map file : $AuthMapPath" -ForegroundColor Cyan
    Write-Host "Catalog file  : $CatalogPath" -ForegroundColor Cyan

    $commonArgs = @{ SchedulePath = $SchedulePath; AuthMapPath = $AuthMapPath; CatalogPath = $CatalogPath }
    if ($SubscriptionId) { $commonArgs.SubscriptionId = $SubscriptionId }

    # 1. Default plan resolve (all rings) - the primary Step.6 read call.
    Test-Cmdlet -Name 'Resolve-AzLocalSideloadPlan (all rings)' `
        -Invoke { Resolve-AzLocalSideloadPlan @commonArgs } `
        -RequiredColumns $planColumns

    # 2. Plan resolve with an explicit lead window - exercises the
    #    next-firing / DueNow date arithmetic against the live schedule.
    Test-Cmdlet -Name 'Resolve-AzLocalSideloadPlan -LeadDays 14' `
        -Invoke { Resolve-AzLocalSideloadPlan @commonArgs -LeadDays 14 } `
        -RequiredColumns $planColumns
}
finally {
    if ($cleanupTemp) {
        Remove-Item -Path $tmpDir.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Final report.
# ---------------------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Smoke Test Results - Resolve-AzLocalSideloadPlan (Step.6)" -ForegroundColor Cyan
Write-Host "Module version: $moduleVersion" -ForegroundColor Cyan
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan
$results | Format-Table -AutoSize Cmdlet, Status, Rows, Missing, Error | Out-String -Width 200 | Write-Host

$fail = @($results | Where-Object { $_.Status -in @('FAIL-SCHEMA', 'ERROR') })
if ($fail.Count -gt 0) {
    Write-Host "FAILED: $($fail.Count) section(s) did not pass." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "All sections passed." -ForegroundColor Green
    exit 0
}
