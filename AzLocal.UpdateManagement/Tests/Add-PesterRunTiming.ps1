# ---------------------------------------------------------------------------
# Add-PesterRunTiming - shared helper that appends one wall-clock timing row
# to the git-tracked Tests/test-run-timings.csv ledger.
#
# Called by BOTH the canonical runner (Invoke-Tests.ps1) and the safe detached
# summary runner used from the VS Code chat harness, so every full-suite run we
# do is recorded in source control. Tracking the numbers in git lets us spot
# wall-clock regressions over time and decide whether the eventual test-file
# split for parallelism is worth it (see Tools/SMOKE-COVERAGE.md discussion).
#
# The ledger is intentionally a flat CSV (one row per run) so it diffs cleanly
# and can be charted with Import-Csv | ... in a one-liner. ASCII, no BOM, to
# satisfy the repo's encoding convention.
# ---------------------------------------------------------------------------
[CmdletBinding()]
param(
    # The Pester run result object ([Pester.Run]) from Invoke-Pester -PassThru.
    [Parameter(Mandatory = $true)]
    $Result,

    # Total wall-clock seconds for the run as measured by the CALLER (module
    # import + discovery + execution + teardown), not just Pester's own timer.
    [Parameter(Mandatory = $true)]
    [double]$WallClockSeconds,

    # Short label identifying which harness produced the row, e.g.
    # 'Invoke-Tests.ps1' or 'chat-detached'.
    [Parameter(Mandatory = $true)]
    [string]$Runner,

    # Optional override for the ledger path. Defaults to the CSV next to this
    # script (Tests/test-run-timings.csv).
    [Parameter(Mandatory = $false)]
    [string]$TimingsPath = (Join-Path -Path $PSScriptRoot -ChildPath 'test-run-timings.csv'),

    # Optional explicit module version (falls back to the loaded module).
    [Parameter(Mandatory = $false)]
    [string]$ModuleVersion
)

if (-not $ModuleVersion) {
    $ModuleVersion = (Get-Module AzLocal.UpdateManagement -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1).Version
}
# Fallback: after Invoke-Pester completes the module may no longer be visible
# via Get-Module at this scope (it was imported inside Pester's container), so
# read ModuleVersion straight from the manifest next to the Tests folder.
if (-not $ModuleVersion) {
    $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
    if (Test-Path -LiteralPath $manifestPath) {
        try {
            $ModuleVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
        }
        catch { }
    }
}

# Pester v5 exposes both the test-execution Duration and a separate
# DiscoveryDuration; record each so we can see how much of the wall clock is
# discovery (the part a file-split would parallelise).
$pesterSeconds = 0.0
$discoverySeconds = 0.0
if ($Result.Duration) { $pesterSeconds = [math]::Round($Result.Duration.TotalSeconds, 2) }
if ($Result.PSObject.Properties.Name -contains 'DiscoveryDuration' -and $Result.DiscoveryDuration) {
    $discoverySeconds = [math]::Round($Result.DiscoveryDuration.TotalSeconds, 2)
}

$row = [PSCustomObject][ordered]@{
    TimestampUtc          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    ModuleVersion         = [string]$ModuleVersion
    Total                 = [int]$Result.TotalCount
    Passed                = [int]$Result.PassedCount
    Failed                = [int]$Result.FailedCount
    Skipped               = [int]$Result.SkippedCount
    WallClockSeconds      = [math]::Round($WallClockSeconds, 2)
    PesterDurationSeconds = $pesterSeconds
    DiscoverySeconds      = $discoverySeconds
    Runner                = $Runner
    PSVersion             = $PSVersionTable.PSVersion.ToString()
}

# Export-Csv -Append writes the header automatically only when the file does
# not yet exist; on subsequent runs it appends data rows without a duplicate
# header. -Encoding ASCII keeps the file BOM-free.
$row | Export-Csv -Path $TimingsPath -Append -NoTypeInformation -Encoding ASCII

return $row
