#Requires -Version 5.1
#Requires -Module Pester
<#
.SYNOPSIS
    Runs the read-only live-Azure Pester suite in bounded parallel jobs.
.DESCRIPTION
    Splits Live-Integration.Tests.ps1 into independent tag shards and runs each
    shard in an isolated Start-Job process. Each job receives unique GitHub
    summary/output files, NUnit XML, and a redirected log so report cmdlets do
    not race over shared output or overwhelm the calling terminal.

    Any failed or skipped live test fails the aggregate run. A skip means the
    Azure CLI safety gate did not confirm the approved maintainer subscription.
.PARAMETER ThrottleLimit
    Maximum concurrent jobs. Defaults to 3 to reduce Azure Resource Graph
    throttling while still parallelizing independent fleet reads.
.PARAMETER OutputPath
    Directory for shard logs, NUnit XML files, summaries, and aggregate JSON.
    Defaults to a timestamped directory under the current user's temp folder.
.OUTPUTS
    PSCustomObject aggregate result.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 8)]
    [int]$ThrottleLimit = 3,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $env:TEMP ("azlocal-live-parallel-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')))
)

$ErrorActionPreference = 'Stop'
$testPath = Join-Path $PSScriptRoot 'Live-Integration.Tests.ps1'
if (-not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
    throw "Live integration test file not found: $testPath"
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

$shards = @(
    [pscustomobject]@{ Name = 'foundation'; Tag = 'LiveFoundation' },
    [pscustomobject]@{ Name = 'health'; Tag = 'LiveHealth' },
    [pscustomobject]@{ Name = 'updates'; Tag = 'LiveUpdates' },
    [pscustomobject]@{ Name = 'connectivity'; Tag = 'LiveConnectivity' },
    [pscustomobject]@{ Name = 'report-config'; Tag = 'LiveReportConfig' },
    [pscustomobject]@{ Name = 'report-schedule'; Tag = 'LiveReportSchedule' },
    [pscustomobject]@{ Name = 'report-fleet'; Tag = 'LiveReportFleet' },
    [pscustomobject]@{ Name = 'report-updates'; Tag = 'LiveReportUpdates' }
)

$jobScript = {
    param($TestPath, $ShardName, $Tag, $ShardOutputPath)

    $ErrorActionPreference = 'Stop'
    $logPath = Join-Path $ShardOutputPath "$ShardName.log"
    $xmlPath = Join-Path $ShardOutputPath "$ShardName.xml"
    $summaryPath = Join-Path $ShardOutputPath "$ShardName-summary.md"
    $githubOutputPath = Join-Path $ShardOutputPath "$ShardName-github-output.txt"
    $resultPath = Join-Path $ShardOutputPath "$ShardName-result.json"

    $env:GITHUB_ACTIONS = 'true'
    $env:GITHUB_STEP_SUMMARY = $summaryPath
    $env:GITHUB_OUTPUT = $githubOutputPath
    Set-Content -LiteralPath $summaryPath -Value '' -Encoding UTF8
    Set-Content -LiteralPath $githubOutputPath -Value '' -Encoding UTF8

    Import-Module Pester -MinimumVersion 5.0.0 -Force
    $config = New-PesterConfiguration
    $config.Run.Path = $TestPath
    $config.Run.PassThru = $true
    $config.Filter.Tag = @($Tag)
    $config.Output.Verbosity = 'None'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = $xmlPath
    $config.TestResult.OutputFormat = 'NUnitXml'

    $result = $null
    . { $result = Invoke-Pester -Configuration $config } *> $logPath
    $executedCount = $result.PassedCount + $result.FailedCount + $result.SkippedCount + $result.InconclusiveCount
    $summary = [pscustomobject]@{
        Name         = $ShardName
        Tag          = $Tag
        Executed     = $executedCount
        Passed       = $result.PassedCount
        Failed       = $result.FailedCount
        Skipped      = $result.SkippedCount
        Inconclusive = $result.InconclusiveCount
        DurationMs   = [math]::Round($result.Duration.TotalMilliseconds)
        LogPath      = $logPath
        XmlPath      = $xmlPath
    }
    $summary | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    $summary
}

$pending = New-Object 'System.Collections.Generic.Queue[object]'
foreach ($shard in $shards) { $pending.Enqueue($shard) }
$running = @()
$completed = @()

try {
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $ThrottleLimit) {
            $shard = $pending.Dequeue()
            Write-Host ("Starting live shard '{0}' ({1})..." -f $shard.Name, $shard.Tag)
            $job = Start-Job -Name $shard.Name -ScriptBlock $jobScript -ArgumentList $testPath, $shard.Name, $shard.Tag, $OutputPath
            $running = @($running) + $job
        }

        $finished = Wait-Job -Job $running -Any
        $jobOutput = @(Receive-Job -Job $finished *>&1)
        $summary = @($jobOutput | Where-Object { $_.PSObject.Properties['Tag'] } | Select-Object -Last 1)
        if ($summary.Count -eq 0) {
            $resultPath = Join-Path $OutputPath "$($finished.Name)-result.json"
            if (Test-Path -LiteralPath $resultPath) {
                $summary = @(Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
            }
        }
        if ($summary.Count -eq 0) {
            $summary = @([pscustomobject]@{
                    Name = $finished.Name; Tag = ''; Executed = 0; Passed = 0
                    Failed = 1; Skipped = 0; Inconclusive = 0; DurationMs = 0
                    LogPath = (Join-Path $OutputPath "$($finished.Name).log"); XmlPath = ''
                })
        }
        $completed = @($completed) + ($summary[0] | Select-Object Name, Tag, Executed, Passed, Failed, Skipped, Inconclusive, DurationMs, LogPath, XmlPath)
        Write-Host ("Completed live shard '{0}': passed={1}, failed={2}, skipped={3}, duration={4:N1}s" -f $summary[0].Name, $summary[0].Passed, $summary[0].Failed, $summary[0].Skipped, ($summary[0].DurationMs / 1000))
        $running = @($running | Where-Object { $_.Id -ne $finished.Id })
        Remove-Job -Job $finished -Force
    }
}
finally {
    if ($running.Count -gt 0) {
        $running | Stop-Job -ErrorAction SilentlyContinue
        $running | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

$aggregate = [pscustomobject]@{
    ShardCount    = $completed.Count
    Executed      = [int](($completed | Measure-Object -Property Executed -Sum).Sum)
    Passed        = [int](($completed | Measure-Object -Property Passed -Sum).Sum)
    Failed        = [int](($completed | Measure-Object -Property Failed -Sum).Sum)
    Skipped       = [int](($completed | Measure-Object -Property Skipped -Sum).Sum)
    Inconclusive  = [int](($completed | Measure-Object -Property Inconclusive -Sum).Sum)
    OutputPath    = $OutputPath
    Shards        = @($completed | Sort-Object Name)
}
$aggregate | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath 'aggregate-result.json') -Encoding UTF8
$aggregate | Format-List ShardCount, Executed, Passed, Failed, Skipped, Inconclusive, OutputPath

if ($aggregate.Failed -gt 0 -or $aggregate.Skipped -gt 0 -or $aggregate.Inconclusive -gt 0) {
    throw "Parallel live integration failed: passed=$($aggregate.Passed), failed=$($aggregate.Failed), skipped=$($aggregate.Skipped), inconclusive=$($aggregate.Inconclusive). Results: $OutputPath"
}

return $aggregate