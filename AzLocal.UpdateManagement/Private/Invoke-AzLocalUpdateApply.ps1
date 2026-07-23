function Invoke-AzLocalUpdateApply {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $true)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    if (-not (Test-AzLocalClusterResourceInGlobalScope -ClusterResourceId $ClusterResourceId)) {
        throw "GlobalFilterMismatch: cluster '$ClusterResourceId' does not match the configured scope.clusterTagFilters policy. No update was started."
    }

    # Ensure Azure CLI is available
    Test-AzCliAvailable | Out-Null

    $uri = "https://management.azure.com$ClusterResourceId/updates/$UpdateName/apply?api-version=$ApiVersion"
    
    Write-Verbose "Applying update via POST to: $uri"
    
    # The apply endpoint is a POST with empty body
    $result = az rest --method POST --uri $uri --only-show-errors 2>&1
    $resultText = ($result | Out-String).Trim()

    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    elseif ($resultText -match '202|Accepted') {
        # 202 Accepted is a valid response for long-running operations
        return $true
    }

    Write-Verbose "Apply result: $(ConvertTo-ScrubbedCliOutput -Text $resultText)"
    return $false
}
