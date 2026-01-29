#Requires -Module Pester
<#
.SYNOPSIS
    Runs Pester tests and generates HTML report for the AzStackHci.ManageUpdates module.

.DESCRIPTION
    This script runs all Pester tests in the Tests folder and generates:
    - NUnit XML output for CI/CD integration
    - HTML report for human-readable results

.PARAMETER OutputPath
    Path where test results will be saved. Default: .\Tests\TestResults

.PARAMETER OpenReport
    If specified, opens the HTML report in the default browser after generation.

.PARAMETER Verbosity
    Pester output verbosity level. Default: Normal
    - None: No output
    - Normal: Summary and failed tests only (recommended for VS Code)
    - Detailed: All test names and results (may cause VS Code terminal to hang)
    - Diagnostic: Maximum verbosity for debugging

.EXAMPLE
    .\Tests\Invoke-Tests.ps1

.EXAMPLE
    .\Tests\Invoke-Tests.ps1 -OpenReport

.EXAMPLE
    .\Tests\Invoke-Tests.ps1 -OutputPath "C:\TestResults"

.EXAMPLE
    .\Tests\Invoke-Tests.ps1 -Verbosity Detailed

.NOTES
    Requires Pester v5.0 or higher.
    Optionally requires ReportUnit for HTML generation (will be installed if missing).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path -Path $PSScriptRoot -ChildPath 'TestResults'),

    [Parameter(Mandatory = $false)]
    [switch]$OpenReport,

    [Parameter(Mandatory = $false)]
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Verbosity = 'Normal'
)

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$nunitPath = Join-Path -Path $OutputPath -ChildPath "TestResults_$timestamp.xml"
$htmlPath = Join-Path -Path $OutputPath -ChildPath "TestResults_$timestamp.html"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "AzStackHci.ManageUpdates - Pester Tests" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check Pester version
$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester -or $pester.Version -lt [Version]'5.0.0') {
    Write-Host "Installing Pester v5..." -ForegroundColor Yellow
    Install-Module Pester -Force -SkipPublisherCheck -Scope CurrentUser
}

Import-Module Pester -MinimumVersion 5.0.0

# Load System.Web assembly for HtmlEncode
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# Configure Pester
$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = $nunitPath
$config.TestResult.OutputFormat = 'NUnitXml'
$config.Output.Verbosity = $Verbosity  # Default 'Normal' to prevent VS Code terminal from hanging; use -Verbosity Detailed for more info
$config.CodeCoverage.Enabled = $false  # Can enable if needed

Write-Host "Running tests..." -ForegroundColor Cyan
Write-Host "Test Path: $PSScriptRoot" -ForegroundColor Gray
Write-Host "Output Path: $OutputPath" -ForegroundColor Gray
Write-Host ""

# Run tests
$results = Invoke-Pester -Configuration $config

# Generate HTML report
Write-Host ""
Write-Host "Generating HTML report..." -ForegroundColor Cyan

# Create a simple HTML report using StringBuilder for efficiency
$htmlBuilder = [System.Text.StringBuilder]::new()
[void]$htmlBuilder.Append(@"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AzStackHci.ManageUpdates - Test Results</title>
    <style>
        :root {
            --success-color: #28a745;
            --failure-color: #dc3545;
            --skipped-color: #ffc107;
            --pending-color: #6c757d;
            --bg-color: #f8f9fa;
            --card-bg: #ffffff;
            --text-color: #212529;
            --border-color: #dee2e6;
        }
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-color);
            line-height: 1.6;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        header {
            background: linear-gradient(135deg, #0078d4, #005a9e);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        header h1 {
            font-size: 2em;
            margin-bottom: 10px;
        }
        header p {
            opacity: 0.9;
        }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }
        .summary-card {
            background: var(--card-bg);
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            border-left: 4px solid var(--border-color);
        }
        .summary-card.passed { border-left-color: var(--success-color); }
        .summary-card.failed { border-left-color: var(--failure-color); }
        .summary-card.skipped { border-left-color: var(--skipped-color); }
        .summary-card.total { border-left-color: #0078d4; }
        .summary-card .number {
            font-size: 2.5em;
            font-weight: bold;
            display: block;
        }
        .summary-card.passed .number { color: var(--success-color); }
        .summary-card.failed .number { color: var(--failure-color); }
        .summary-card.skipped .number { color: var(--skipped-color); }
        .summary-card.total .number { color: #0078d4; }
        .summary-card .label {
            text-transform: uppercase;
            font-size: 0.85em;
            color: #6c757d;
            letter-spacing: 1px;
        }
        .progress-bar {
            background: var(--card-bg);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .progress-bar h3 {
            margin-bottom: 10px;
        }
        .progress {
            height: 30px;
            background: #e9ecef;
            border-radius: 15px;
            overflow: hidden;
            display: flex;
        }
        .progress-passed {
            background: var(--success-color);
            transition: width 0.5s ease;
        }
        .progress-failed {
            background: var(--failure-color);
            transition: width 0.5s ease;
        }
        .progress-skipped {
            background: var(--skipped-color);
            transition: width 0.5s ease;
        }
        .test-results {
            background: var(--card-bg);
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            overflow: hidden;
        }
        .test-results h2 {
            background: #f1f3f5;
            padding: 15px 20px;
            border-bottom: 1px solid var(--border-color);
        }
        .test-container {
            padding: 0;
        }
        .test-group {
            border-bottom: 1px solid var(--border-color);
        }
        .test-group:last-child {
            border-bottom: none;
        }
        .test-group-header {
            padding: 15px 20px;
            background: #f8f9fa;
            cursor: pointer;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .test-group-header:hover {
            background: #e9ecef;
        }
        .test-group-name {
            font-weight: 600;
        }
        .test-group-stats {
            display: flex;
            gap: 15px;
            font-size: 0.9em;
        }
        .stat-passed { color: var(--success-color); }
        .stat-failed { color: var(--failure-color); }
        .stat-skipped { color: var(--skipped-color); }
        .test-list {
            display: none;
            padding: 0;
            background: white;
        }
        .test-group.expanded .test-list {
            display: block;
        }
        .test-item {
            padding: 12px 20px 12px 40px;
            border-top: 1px solid #f1f3f5;
            display: flex;
            align-items: center;
            gap: 10px;
        }
        .test-item:hover {
            background: #f8f9fa;
        }
        .test-status {
            width: 20px;
            height: 20px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 12px;
            color: white;
            flex-shrink: 0;
        }
        .test-status.passed { background: var(--success-color); }
        .test-status.failed { background: var(--failure-color); }
        .test-status.skipped { background: var(--skipped-color); }
        .test-status::before {
            font-family: 'Segoe UI Symbol', sans-serif;
        }
        .test-status.passed::before { content: '\2713'; }
        .test-status.failed::before { content: '\2717'; }
        .test-status.skipped::before { content: '\2212'; }
        .test-name {
            flex-grow: 1;
        }
        .test-duration {
            color: #6c757d;
            font-size: 0.85em;
        }
        footer {
            text-align: center;
            padding: 20px;
            color: #6c757d;
            font-size: 0.9em;
        }
        .expand-icon {
            transition: transform 0.2s;
        }
        .test-group.expanded .expand-icon {
            transform: rotate(90deg);
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>&#x1F9EA; AzStackHci.ManageUpdates</h1>
            <p>Pester Test Results - Generated $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")</p>
        </header>

        <div class="summary">
            <div class="summary-card total">
                <span class="number">$($results.TotalCount)</span>
                <span class="label">Total Tests</span>
            </div>
            <div class="summary-card passed">
                <span class="number">$($results.PassedCount)</span>
                <span class="label">Passed</span>
            </div>
            <div class="summary-card failed">
                <span class="number">$($results.FailedCount)</span>
                <span class="label">Failed</span>
            </div>
            <div class="summary-card skipped">
                <span class="number">$($results.SkippedCount)</span>
                <span class="label">Skipped</span>
            </div>
        </div>

        <div class="progress-bar">
            <h3>Test Execution Progress</h3>
            <div class="progress">
"@)

# Calculate percentages
$total = $results.TotalCount
if ($total -gt 0) {
    $passedPct = [math]::Round(($results.PassedCount / $total) * 100, 1)
    $failedPct = [math]::Round(($results.FailedCount / $total) * 100, 1)
    $skippedPct = [math]::Round(($results.SkippedCount / $total) * 100, 1)
} else {
    $passedPct = 0
    $failedPct = 0
    $skippedPct = 0
}

[void]$htmlBuilder.Append(@"
                <div class="progress-passed" style="width: $passedPct%"></div>
                <div class="progress-failed" style="width: $failedPct%"></div>
                <div class="progress-skipped" style="width: $skippedPct%"></div>
            </div>
            <p style="margin-top: 10px; font-size: 0.9em; color: #6c757d;">
                Pass Rate: <strong>$passedPct%</strong> | 
                Duration: <strong>$([math]::Round($results.Duration.TotalSeconds, 2))s</strong>
            </p>
        </div>

        <div class="test-results">
            <h2>&#x1F4CB; Test Details</h2>
            <div class="test-container">
"@)

# Group tests by Describe block
$testsByDescribe = $results.Tests | Group-Object { $_.Block.Name }

foreach ($group in $testsByDescribe) {
    $groupPassed = ($group.Group | Where-Object { $_.Result -eq 'Passed' }).Count
    $groupFailed = ($group.Group | Where-Object { $_.Result -eq 'Failed' }).Count
    $groupSkipped = ($group.Group | Where-Object { $_.Result -eq 'Skipped' }).Count
    $groupNameEncoded = if ($group.Name) { [System.Web.HttpUtility]::HtmlEncode($group.Name) } else { "(No Name)" }
    
    [void]$htmlBuilder.Append(@"
                <div class="test-group" onclick="this.classList.toggle('expanded')">
                    <div class="test-group-header">
                        <span class="test-group-name">
                            <span class="expand-icon">&#x25B6;</span> $groupNameEncoded
                        </span>
                        <span class="test-group-stats">
                            <span class="stat-passed">&#x2713; $groupPassed</span>
                            <span class="stat-failed">&#x2717; $groupFailed</span>
                            <span class="stat-skipped">&#x2212; $groupSkipped</span>
                        </span>
                    </div>
                    <div class="test-list">
"@)
    
    foreach ($test in $group.Group) {
        $statusClass = switch ($test.Result) {
            'Passed' { 'passed' }
            'Failed' { 'failed' }
            'Skipped' { 'skipped' }
            default { 'pending' }
        }
        $duration = if ($test.Duration) { "$([math]::Round($test.Duration.TotalMilliseconds, 0))ms" } else { "-" }
        $testName = if ($test.Name) { [System.Web.HttpUtility]::HtmlEncode($test.Name) } else { "(No Name)" }
        
        [void]$htmlBuilder.Append(@"
                        <div class="test-item">
                            <span class="test-status $statusClass"></span>
                            <span class="test-name">$testName</span>
                            <span class="test-duration">$duration</span>
                        </div>
"@)
    }
    
    [void]$htmlBuilder.Append(@"
                    </div>
                </div>
"@)
}

$moduleVersion = (Get-Module AzStackHci.ManageUpdates -ErrorAction SilentlyContinue).Version
[void]$htmlBuilder.Append(@"
            </div>
        </div>

        <footer>
            <p>Generated by AzStackHci.ManageUpdates Pester Tests</p>
            <p>Module Version: $moduleVersion</p>
        </footer>
    </div>
</body>
</html>
"@)

# Write HTML file
$htmlBuilder.ToString() | Out-File -FilePath $htmlPath -Encoding UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Test Results Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Total:   $($results.TotalCount)" -ForegroundColor White
Write-Host "Passed:  $($results.PassedCount)" -ForegroundColor Green
Write-Host "Failed:  $($results.FailedCount)" -ForegroundColor $(if ($results.FailedCount -gt 0) { 'Red' } else { 'White' })
Write-Host "Skipped: $($results.SkippedCount)" -ForegroundColor Yellow
Write-Host ""
Write-Host "Duration: $([math]::Round($results.Duration.TotalSeconds, 2)) seconds" -ForegroundColor Gray
Write-Host ""
Write-Host "Output Files:" -ForegroundColor Cyan
Write-Host "  NUnit XML: $nunitPath" -ForegroundColor Gray
Write-Host "  HTML Report: $htmlPath" -ForegroundColor Gray
Write-Host ""

if ($OpenReport) {
    Write-Host "Opening HTML report..." -ForegroundColor Cyan
    Start-Process $htmlPath
}

# Return results for pipeline use
return $results
