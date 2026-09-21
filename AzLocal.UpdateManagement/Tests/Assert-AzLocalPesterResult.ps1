function Assert-AzLocalPesterResult {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Result,
        [switch]$AllowSkipped
    )

    if ($null -eq $Result) { throw 'Pester produced no result.' }
    foreach ($property in @('Result', 'PassedCount', 'FailedCount', 'SkippedCount', 'InconclusiveCount', 'FailedContainersCount', 'FailedBlocksCount')) {
        if (-not $Result.PSObject.Properties[$property]) { throw "Pester result is missing $property." }
    }
    if ($Result.Result -ne 'Passed' -or $Result.PassedCount -le 0 -or
        $Result.FailedCount -gt 0 -or $Result.FailedContainersCount -gt 0 -or
        $Result.FailedBlocksCount -gt 0 -or $Result.InconclusiveCount -gt 0 -or
        (-not $AllowSkipped -and $Result.SkippedCount -gt 0)) {
        throw "Pester did not pass cleanly: result=$($Result.Result), passed=$($Result.PassedCount), failed=$($Result.FailedCount), containers=$($Result.FailedContainersCount), blocks=$($Result.FailedBlocksCount), skipped=$($Result.SkippedCount), inconclusive=$($Result.InconclusiveCount)."
    }
}