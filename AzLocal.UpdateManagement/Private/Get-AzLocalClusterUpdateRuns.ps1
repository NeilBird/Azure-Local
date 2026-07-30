function Get-AzLocalClusterUpdateRuns {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($resourceId, $updateNameFilter, $apiVer)

    $allRuns = [System.Collections.Generic.List[object]]::new()

    if ($updateNameFilter) {
        $uri = "https://management.azure.com$resourceId/updates/$updateNameFilter/updateRuns?api-version=$apiVer"
        $response = Invoke-AzRestJson -Uri $uri
        if (-not $response.Ok) {
            throw "ARM update-run read failed for '$resourceId' update '$updateNameFilter': $($response.Error)"
        }
        $result = $response.Data
        if ($result.value) {
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
            $response = Invoke-AzRestJson -Uri $uri
            if (-not $response.Ok) {
                throw "ARM update-run read failed for '$resourceId' update '$($update.name)': $($response.Error)"
            }
            $runs = $response.Data
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
