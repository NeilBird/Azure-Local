function Get-AzLocalClusterUpdateRuns {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($resourceId, $updateNameFilter, $apiVer)

    $allRuns = [System.Collections.Generic.List[object]]::new()

    if ($updateNameFilter) {
        $uri = "https://management.azure.com$resourceId/updates/$updateNameFilter/updateRuns?api-version=$apiVer"
        $result = (Invoke-AzRestJson -Uri $uri).Data
        if ($LASTEXITCODE -eq 0 -and $result.value) {
            foreach ($_run in @($result.value)) {
                if ($null -eq $_run) { continue }
                $allRuns.Add($_run) | Out-Null
            }
        }
    }
    else {
        $updates = @(Get-AzLocalAvailableUpdates -ClusterResourceId $resourceId -ApiVersion $apiVer -Raw)
        foreach ($update in $updates) {
            $uri = "https://management.azure.com$resourceId/updates/$($update.name)/updateRuns?api-version=$apiVer"
            $runs = (Invoke-AzRestJson -Uri $uri).Data
            if ($runs.value) {
                foreach ($_run in @($runs.value)) {
                    if ($null -eq $_run) { continue }
                    $allRuns.Add($_run) | Out-Null
                }
            }
        }
    }

    return $allRuns
}
