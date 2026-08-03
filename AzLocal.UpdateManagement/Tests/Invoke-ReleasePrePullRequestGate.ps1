#Requires -Version 5.1
#Requires -Module Pester
<#
.SYNOPSIS
    Certifies an AzLocal.UpdateManagement release commit before PR creation.
.DESCRIPTION
    Requires a clean committed candidate, runs the complete hermetic Pester
    suite with Live excluded, then runs every live-Azure shard through
    Invoke-LiveTestsParallel.ps1. Any hermetic failure, live failure, live
    skip, or inconclusive live test blocks certification.

    A successful run writes a JSON receipt under the repository git directory.
    The receipt records the exact commit, module version, test counts, and UTC
    completion time without changing the worktree.
.PARAMETER ThrottleLimit
    Maximum concurrent live-Azure jobs. Defaults to 3.
.PARAMETER OutputPath
    Optional test-output directory. Defaults to a timestamped temp directory.
.OUTPUTS
    PSCustomObject certification receipt.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 8)]
    [int]$ThrottleLimit = 3,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $env:TEMP ("azlocal-release-prepr-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Path $PSScriptRoot -Parent
$repoRoot = (Resolve-Path (Join-Path $moduleRoot '..')).Path
$manifestPath = Join-Path $moduleRoot 'AzLocal.UpdateManagement.psd1'
$liveRunnerPath = Join-Path $PSScriptRoot 'Invoke-LiveTestsParallel.ps1'

foreach ($requiredPath in @($manifestPath, $liveRunnerPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required release-gate file not found: $requiredPath"
    }
}

Push-Location $repoRoot
try {
    $branch = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $branch) { throw 'Unable to resolve the current git branch.' }
    if ($branch -eq 'main') { throw 'Release pull requests must be created from a release branch, not main.' }

    $status = @(& git status --porcelain --untracked-files=all -- AzLocal.UpdateManagement .github)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the release worktree.' }
    if ($status.Count -gt 0) {
        throw "Release candidate is not fully committed. Commit all AzLocal.UpdateManagement and .github changes before certification:`n$($status -join [Environment]::NewLine)"
    }

    $commit = (& git rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $commit) { throw 'Unable to resolve HEAD.' }
    $upstreamCommit = (& git rev-parse '@{upstream}').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $upstreamCommit) {
        throw 'The release branch has no upstream. Push the complete candidate before certification.'
    }
    if ($upstreamCommit -ne $commit) {
        throw "HEAD $commit has not been pushed to the upstream branch. Push it before certification."
    }
    $gitDir = (& git rev-parse --git-dir).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $gitDir) { throw 'Unable to resolve the git metadata directory.' }
    if (-not [System.IO.Path]::IsPathRooted($gitDir)) { $gitDir = Join-Path $repoRoot $gitDir }
}
finally {
    Pop-Location
}

$manifest = Import-PowerShellDataFile -Path $manifestPath
$moduleVersion = [string]$manifest.ModuleVersion
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

$hermeticLogPath = Join-Path $OutputPath 'hermetic-pester.log'
$hermeticXmlPath = Join-Path $OutputPath 'hermetic-pester.xml'
Import-Module Pester -MinimumVersion 5.0.0 -Force
$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Filter.ExcludeTag = @('Live')
$config.Output.Verbosity = 'None'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = $hermeticXmlPath
$config.TestResult.OutputFormat = 'NUnitXml'

Write-Host "Running complete hermetic Pester suite for $commit..." -ForegroundColor Cyan
$hermeticResult = $null
. { $hermeticResult = Invoke-Pester -Configuration $config } *> $hermeticLogPath
if ($hermeticResult.FailedCount -gt 0) {
    throw "Hermetic release tests failed: passed=$($hermeticResult.PassedCount), failed=$($hermeticResult.FailedCount), skipped=$($hermeticResult.SkippedCount). Log: $hermeticLogPath"
}
Write-Host "Hermetic suite passed: $($hermeticResult.PassedCount) passed, $($hermeticResult.SkippedCount) skipped." -ForegroundColor Green

$liveOutputPath = Join-Path $OutputPath 'live'
$liveRunnerLogPath = Join-Path $OutputPath 'live-runner.log'
Write-Host "Running all live-Azure shards with throttle $ThrottleLimit..." -ForegroundColor Cyan
. { & $liveRunnerPath -ThrottleLimit $ThrottleLimit -OutputPath $liveOutputPath } *> $liveRunnerLogPath
$liveAggregatePath = Join-Path $liveOutputPath 'aggregate-result.json'
if (-not (Test-Path -LiteralPath $liveAggregatePath -PathType Leaf)) {
    throw "Live runner did not produce its aggregate result. Log: $liveRunnerLogPath"
}
$liveResult = Get-Content -LiteralPath $liveAggregatePath -Raw | ConvertFrom-Json
if ($liveResult.Failed -gt 0 -or $liveResult.Skipped -gt 0 -or $liveResult.Inconclusive -gt 0) {
    throw "Live release tests did not pass cleanly: passed=$($liveResult.Passed), failed=$($liveResult.Failed), skipped=$($liveResult.Skipped), inconclusive=$($liveResult.Inconclusive). Log: $liveRunnerLogPath"
}
Write-Host "Live suite passed: $($liveResult.Passed) passed across $($liveResult.ShardCount) shards." -ForegroundColor Green

Push-Location $repoRoot
try {
    $commitAfterTests = (& git rev-parse HEAD).Trim()
    $statusAfterTests = @(& git status --porcelain --untracked-files=all -- AzLocal.UpdateManagement .github)
}
finally {
    Pop-Location
}
if ($commitAfterTests -ne $commit -or $statusAfterTests.Count -gt 0) {
    throw 'The release commit or worktree changed during certification. Commit the final state and rerun the gate.'
}

$receipt = [pscustomobject]@{
    SchemaVersion   = 1
    Module          = 'AzLocal.UpdateManagement'
    ModuleVersion   = $moduleVersion
    Branch          = $branch
    Commit          = $commit
    CompletedUtc    = [datetime]::UtcNow.ToString('o')
    HermeticTotal   = $hermeticResult.TotalCount
    HermeticPassed  = $hermeticResult.PassedCount
    HermeticFailed  = $hermeticResult.FailedCount
    HermeticSkipped = $hermeticResult.SkippedCount
    LiveShards      = $liveResult.ShardCount
    LiveExecuted    = $liveResult.Executed
    LivePassed      = $liveResult.Passed
    LiveFailed      = $liveResult.Failed
    LiveSkipped     = $liveResult.Skipped
    OutputPath      = $OutputPath
}
$receiptDir = Join-Path $gitDir 'azlocal-release-gates'
New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
$receiptPath = Join-Path $receiptDir "$commit.json"
$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host "Pre-PR release certification passed. Receipt: $receiptPath" -ForegroundColor Green
return $receipt