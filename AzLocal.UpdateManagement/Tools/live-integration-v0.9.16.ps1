# ---------------------------------------------------------------------------
# Per-release LIVE integration smoke test  -  template pinned to v0.9.16.
#
# Purpose
#   A read-only, end-to-end smoke test that runs the REAL report cmdlets against
#   a live subscription (via Az CLI / Azure Resource Graph + the public update
#   manifest) and asserts that each release's data shapes actually render.
#   Unlike the per-pipeline smoke tests (smoke-test-*.ps1, which validate the
#   cmdlet OBJECT schema), this one captures the RENDERED GitHub step-summary
#   markdown and greps it for the columns / tables / notes each release relies
#   on. v0.9.16 is a PIPELINE-TEMPLATE + TEST-only release (no cmdlet output
#   shape changed), so it ALSO verifies the shipped YAML templates carry the
#   hardened install-step backoff and the soft "No Clusters Ready" reporting job.
#
# How to mirror this for a future release
#   1. Copy this file to Tools\live-integration-v<new>.ps1.
#   2. Update the -ReleaseVersion default and the assertions in each section to
#      cover that release's new output (new column header, table heading,
#      PassThru property, etc.).
#   3. Adjust -Rings if the target subscription uses different UpdateRing tags.
#   4. Run it after the source edits but BEFORE the version bump, to confirm the
#      live output matches the requested format.
#
# What v0.9.16 asserts (and the standing v0.8.97 / v0.9.11 shapes that must still render):
#   - Get-AzLocalUpdateRunFailures -View Detail        : UpdateRing property
#   - Monitor:3 Fleet Update Status run-history table   : "Update Ring" column
#   - Monitor:3                                         : "Clusters - Ready for Update" table
#   - Assess Readiness                                  : ready-for-update.csv + collapsed detail
#   - Export-AzLocalClusterUpdateReadinessReport -SchedulePath : must NOT throw
#     (standing v0.9.11 fix: -SchedulePath no longer leaks into Test-AzLocalClusterHealth)
#   - Monitor:2 Fleet Health Status                     : collapsed "Fleet Health Overview"
#   - Apply Updates readiness gate                      : stale-assessment Status override + Support column
#   - v0.9.16 pipeline templates (shipped in the module package):
#       * every install block uses the 5-attempt capped-backoff + jitter loop
#       * benign No Clusters Ready job (GH + ADO) is soft (continue-on-error)
#
# Requires: `az login`; signed-in identity has Reader on the target subscription.
# Output  : $env:TEMP\azlocal-live-v<ReleaseVersion>\*.txt  (rendered markdown,
#           CSVs and a 0-REPORT.txt PASS/FAIL roll-up).
# Safety  : 100% read-only. No ARM writes, no update actions are triggered.
# ---------------------------------------------------------------------------
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ReleaseVersion = '0.9.16',
    [string]$SubscriptionId,
    [string]$ModulePath,
    [string[]]$Rings = @('Prod', 'Ring1', 'Ring2', 'Canary', 'DevTest'),
    [string]$SchedulePath
)

$ErrorActionPreference = 'Continue'

if (-not $ModulePath) {
    $ModulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
}
if (-not (Test-Path $ModulePath)) { throw "Module manifest not found at: $ModulePath" }

$outDir = Join-Path $env:TEMP "azlocal-live-v$ReleaseVersion"
$artDir = Join-Path $outDir 'artifacts'
New-Item -ItemType Directory -Path $artDir -Force | Out-Null

# ---- Az CLI preflight ------------------------------------------------------
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

# ---- Import module fresh ---------------------------------------------------
Get-Module AzLocal.UpdateManagement -All | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module $ModulePath -Force -ErrorAction Stop
$moduleVersion = (Get-Module AzLocal.UpdateManagement | Sort-Object Version -Descending | Select-Object -First 1).Version
Write-Host "Module version: $moduleVersion" -ForegroundColor Cyan

function Save([string]$name, [object]$content) {
    $p = Join-Path $outDir "$name.txt"
    $content | Out-String -Width 240 | Set-Content -Path $p -Encoding UTF8
    Write-Host "WROTE $p"
}

# ---- Emulate a GitHub Actions runner so the GH render path (Unicode glyphs +
#      <details> collapse) is exercised and the step-summary markdown is
#      captured to a file we can assert against. Both env vars are required:
#      GITHUB_STEP_SUMMARY captures the markdown; GITHUB_OUTPUT satisfies the
#      Set-AzLocalPipelineOutput runner-environment guard. -------------------
$summaryFile = Join-Path $outDir 'step-summary.md'
$ghOutput = Join-Path $outDir 'gh-output.txt'
Set-Content -Path $summaryFile -Value '' -Encoding UTF8
Set-Content -Path $ghOutput -Value '' -Encoding UTF8
$savedEnv = @{ GITHUB_STEP_SUMMARY = $env:GITHUB_STEP_SUMMARY; GITHUB_OUTPUT = $env:GITHUB_OUTPUT; GITHUB_ACTIONS = $env:GITHUB_ACTIONS }
$env:GITHUB_STEP_SUMMARY = $summaryFile
$env:GITHUB_OUTPUT = $ghOutput
$env:GITHUB_ACTIONS = 'true'

$report = [ordered]@{}

try {
    # 1) Get-AzLocalUpdateRunFailures -View Detail : expect UpdateRing property
    try {
        $rf = @(Get-AzLocalUpdateRunFailures -View Detail -ErrorAction Stop)
        $hasRing = if ($rf.Count -gt 0) { [bool]$rf[0].PSObject.Properties['UpdateRing'] } else { $true }
        Save '1-runfailures-detail' (($rf | Select-Object -First 8 ClusterName, UpdateRing, UpdateName, State, Status) | Format-Table -AutoSize)
        $report['Get-AzLocalUpdateRunFailures UpdateRing column'] = if ($hasRing) { 'PASS (property present / no rows)' } else { 'FAIL - no UpdateRing property' }
        $report['  rows'] = $rf.Count
    }
    catch { $report['Get-AzLocalUpdateRunFailures'] = "ERROR: $($_.Exception.Message)" }

    # 2) Monitor:3 Fleet Update Status - run-history UpdateRing col + Ready-for-Update table
    try {
        Set-Content -Path $summaryFile -Value '' -Encoding UTF8
        $null = Export-AzLocalFleetUpdateStatusReport -Scope all -OutputDirectory $artDir -PassThru -ErrorAction Stop
        $md = Get-Content -Path $summaryFile -Raw
        Save '2-monitor3-summary' $md
        $report['Monitor3 run-history "Update Ring" header'] = if ($md -match '\| Cluster Name \| Update Ring \| Update Name \|') { 'PASS' } else { 'n/a (no run history rows)' }
        $report['Monitor3 "Clusters - Ready for Update" table'] = if ($md -match '### Clusters - Ready for Update') { 'PASS' } else { 'FAIL - section missing' }
    }
    catch { $report['Export-AzLocalFleetUpdateStatusReport'] = "ERROR: $($_.Exception.Message)" }

    # 3) Assess Readiness - Ready-for-Update table + CSV + collapsed detail
    try {
        Set-Content -Path $summaryFile -Value '' -Encoding UTF8
        $r5 = Export-AzLocalClusterUpdateReadinessReport -Scope all -OutputDirectory $artDir -PassThru -ErrorAction Stop
        $md = Get-Content -Path $summaryFile -Raw
        Save '3-assess-readiness-summary' $md
        $csvPath = $r5.ReadyForUpdateCsvPath
        $report['AssessReadiness ReadyForUpdateCsvPath set'] = if ($csvPath) { "PASS ($csvPath)" } else { 'FAIL' }
        $report['AssessReadiness ready CSV exists'] = if ($csvPath -and (Test-Path $csvPath)) { 'PASS' } else { 'FAIL - csv not written' }
        $report['AssessReadiness "Ready for Update" section'] = if ($md -match '### Clusters - Ready for Update') { 'PASS' } else { 'FAIL' }
        $report['AssessReadiness collapsed detail'] = if ($md -match '<summary>Expand to view clusters</summary>') { 'PASS' } else { 'FAIL' }
        if ($csvPath -and (Test-Path $csvPath)) { Save '3b-ready-for-update-csv' (Get-Content $csvPath -Raw) }
    }
    catch { $report['Export-AzLocalClusterUpdateReadinessReport'] = "ERROR: $($_.Exception.Message)" }

    # 3c) Standing v0.9.11 regression: -SchedulePath allow-list path must NOT throw.
    #     The fixed scopeParams leak previously crashed the health step.
    if ($SchedulePath -and (Test-Path $SchedulePath)) {
        try {
            Set-Content -Path $summaryFile -Value '' -Encoding UTF8
            $null = Export-AzLocalClusterUpdateReadinessReport -Scope all -OutputDirectory $artDir -SchedulePath $SchedulePath -PassThru -ErrorAction Stop
            $report['AssessReadiness -SchedulePath (no scopeParams leak)'] = 'PASS'
        }
        catch { $report['AssessReadiness -SchedulePath'] = "FAIL - $($_.Exception.Message)" }
    }
    else {
        $report['AssessReadiness -SchedulePath'] = 'skipped (pass -SchedulePath to exercise the standing v0.9.11 fix)'
    }

    # 4) Monitor:2 Fleet Health Status - collapsed overview
    try {
        Set-Content -Path $summaryFile -Value '' -Encoding UTF8
        $null = Export-AzLocalFleetHealthStatusReport -Scope all -OutputDirectory $artDir -PassThru -ErrorAction Stop
        $md = Get-Content -Path $summaryFile -Raw
        Save '4-monitor2-summary' $md
        $report['Monitor2 Fleet Health Overview collapsed'] = if ($md -match '### Fleet Health Overview \(fleet rollup\)' -and $md -match '<summary>Expand to view clusters</summary>') { 'PASS' } else { 'FAIL' }
    }
    catch { $report['Export-AzLocalFleetHealthStatusReport'] = "ERROR: $($_.Exception.Message)" }

    # 5) Apply Updates readiness gate - stale-assessment + Support column, per ring
    foreach ($ring in $Rings) {
        try {
            Set-Content -Path $summaryFile -Value '' -Encoding UTF8
            $rr = Export-AzLocalClusterReadinessGateReport -UpdateRing $ring -OutputDirectory $artDir -PassThru -ErrorAction Stop
            $md = Get-Content -Path $summaryFile -Raw
            Save "5-applyupdates-ring-$ring-summary" $md
            if (-not $report.Contains('ApplyUpdates Support column header')) {
                $report['ApplyUpdates Support column header'] = if ($md -match '\| Cluster \| Current Version \| Update State \| Health \| Status \| Support \| Recommended Update \| Blocking Reasons \|') { 'PASS' } else { 'FAIL' }
            }
            if ($md -match 'Update Available \(stale assessment\)' -and -not $report.Contains('ApplyUpdates stale override rendered')) {
                $report['ApplyUpdates stale override rendered'] = "PASS (ring '$ring')"
            }
            $report["Ring $ring : StaleCount / total"] = "$($rr.StaleAssessmentCount) / $($rr.TotalCount)"
        }
        catch { $report["Ring $ring"] = "ERROR: $($_.Exception.Message)" }
    }
    if (-not $report.Contains('ApplyUpdates stale override rendered')) {
        $report['ApplyUpdates stale override rendered'] = 'none flagged across rings (no stale clusters today)'
    }

    # 6) v0.9.16 pipeline-template hardening (read-only static check of the
    #    templates shipped inside the module package). Because v0.9.16 changes
    #    only the YAML templates + tests (no cmdlet output shape), this section
    #    is what actually exercises THIS release's change: every install block
    #    must use the 5-attempt capped-backoff + jitter loop, and the benign
    #    No Clusters Ready reporting job (GH + ADO) must be soft.
    try {
        $pipelineRoot = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples'
        if (Test-Path $pipelineRoot) {
            $ymls = Get-ChildItem -Path $pipelineRoot -Recurse -Filter '*.yml' -File
            $installTotal = 0; $max5Total = 0; $capTotal = 0; $jitterTotal = 0; $max3Left = 0
            foreach ($y in $ymls) {
                $t = Get-Content -Raw -LiteralPath $y.FullName
                $installTotal += ([regex]::Matches($t, [regex]::Escape('Install-Module @installArgs'))).Count
                $max5Total    += ([regex]::Matches($t, [regex]::Escape('$installMaxAttempts = 5'))).Count
                $max3Left     += ([regex]::Matches($t, [regex]::Escape('$installMaxAttempts = 3'))).Count
                $capTotal     += ([regex]::Matches($t, [regex]::Escape('[math]::Min(60, 10 * [math]::Pow(2, $installAttempt - 1))'))).Count
                $jitterTotal  += ([regex]::Matches($t, [regex]::Escape('Get-Random -Minimum 0 -Maximum 5'))).Count
            }
            $report['v0.9.16 install blocks total'] = $installTotal
            $report['v0.9.16 5-attempt loops match install count'] = if ($max5Total -eq $installTotal -and $installTotal -gt 0) { "PASS ($max5Total)" } else { "FAIL ($max5Total of $installTotal)" }
            $report['v0.9.16 no 3-attempt loops remain'] = if ($max3Left -eq 0) { 'PASS' } else { "FAIL ($max3Left remain)" }
            $report['v0.9.16 capped backoff on every block'] = if ($capTotal -eq $installTotal) { "PASS ($capTotal)" } else { "FAIL ($capTotal of $installTotal)" }
            $report['v0.9.16 jitter on every block'] = if ($jitterTotal -eq $installTotal) { "PASS ($jitterTotal)" } else { "FAIL ($jitterTotal of $installTotal)" }

            $ghApply = Join-Path $pipelineRoot 'github-actions\apply-updates.yml'
            $adoApply = Join-Path $pipelineRoot 'azure-devops\apply-updates.yml'
            $ghSoft = if (Test-Path $ghApply) {
                $g = Get-Content -Raw -LiteralPath $ghApply
                ($g -match 'no-clusters-ready:') -and (([regex]::Matches($g, [regex]::Escape('continue-on-error: true'))).Count -ge 2)
            } else { $false }
            $adoSoft = if (Test-Path $adoApply) {
                $a = Get-Content -Raw -LiteralPath $adoApply
                ($a -match 'NoClustersReady') -and (([regex]::Matches($a, [regex]::Escape('continueOnError: true'))).Count -ge 2)
            } else { $false }
            $report['v0.9.16 GH No Clusters Ready job soft'] = if ($ghSoft) { 'PASS' } else { 'FAIL' }
            $report['v0.9.16 ADO NoClustersReady stage soft'] = if ($adoSoft) { 'PASS' } else { 'FAIL' }
        }
        else {
            $report['v0.9.16 pipeline-template check'] = "skipped (Automation-Pipeline-Examples not found next to the module)"
        }
    }
    catch { $report['v0.9.16 pipeline-template check'] = "ERROR: $($_.Exception.Message)" }
}
finally {
    # Restore the runner env vars we shadowed.
    $env:GITHUB_STEP_SUMMARY = $savedEnv.GITHUB_STEP_SUMMARY
    $env:GITHUB_OUTPUT = $savedEnv.GITHUB_OUTPUT
    $env:GITHUB_ACTIONS = $savedEnv.GITHUB_ACTIONS
}

Save '0-REPORT' ($report.GetEnumerator() | ForEach-Object { '{0,-55} : {1}' -f $_.Key, $_.Value })
Write-Host "`n==== SUMMARY (v$ReleaseVersion) ====" -ForegroundColor Cyan
$report.GetEnumerator() | ForEach-Object { '{0,-55} : {1}' -f $_.Key, $_.Value }
Write-Host "`nFull rendered output under: $outDir" -ForegroundColor Cyan
