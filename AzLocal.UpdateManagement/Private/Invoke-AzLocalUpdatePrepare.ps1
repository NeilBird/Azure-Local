function Invoke-AzLocalUpdatePrepare {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $true)]
        [string]$UpdateName
    )

    if (-not (Test-AzLocalClusterResourceInGlobalScope -ClusterResourceId $ClusterResourceId)) {
        throw "GlobalFilterMismatch: cluster '$ClusterResourceId' does not match the configured scope.clusterTagFilters policy. No update preparation was started."
    }

    Test-AzCliAvailable | Out-Null

    $uri = "https://management.azure.com$ClusterResourceId/updates/$UpdateName/prepare?api-version=2026-04-30"
    Write-Verbose "Preparing update via POST to: $uri"

    # The prepare action has no request body.
    $result = az rest --method POST --uri $uri --only-show-errors 2>&1
    $resultText = ($result | Out-String).Trim()

    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    elseif ($resultText -match '202|Accepted') {
        return $true
    }

    Write-Verbose "Prepare result: $(ConvertTo-ScrubbedCliOutput -Text $resultText)"
    return $false
}