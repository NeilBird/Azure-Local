function Get-AzLocalClusterUpdateRuns {
    [CmdletBinding()]
    [OutputType([object[]])]
    param($resourceId, $updateNameFilter, $apiVer)

    $allRuns = [System.Collections.Generic.List[object]]::new()

    $updateNames = if ($updateNameFilter) { @($updateNameFilter) } else {
        @(Get-AzLocalAvailableUpdates -ClusterResourceId $resourceId -ApiVersion $apiVer -Raw | ForEach-Object { $_.name })
    }
    foreach ($updateName in $updateNames) {
        $uri = "https://management.azure.com$resourceId/updates/$updateName/updateRuns?api-version=$apiVer"
        $initialUri = [Uri]$uri
        $visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        while ($uri) {
            $pageUri = $null
            if (-not [Uri]::TryCreate($uri, [UriKind]::Absolute, [ref]$pageUri) -or
                $pageUri.Scheme -ne 'https' -or $pageUri.Authority -ne $initialUri.Authority -or
                $pageUri.AbsolutePath -ne $initialUri.AbsolutePath -or $pageUri.UserInfo -or $pageUri.Fragment) {
                throw 'ARM update-run continuation URL is outside the requested resource.'
            }
            if ($visited.Count -ge 1000 -or -not $visited.Add($pageUri.AbsoluteUri)) {
                throw 'ARM update-run pagination repeated a page or exceeded 1000 pages.'
            }
            $response = Invoke-AzRestJson -Uri $uri
            if (-not $response.Ok) {
                throw "ARM update-run read failed for '$resourceId' update '$updateName': $($response.Error)"
            }
            $runs = $response.Data
            if ($runs.value) {
                foreach ($run in @($runs.value)) {
                    if ($null -eq $run) { continue }
                    $allRuns.Add($run) | Out-Null
                }
            }
            $uri = if ($runs -and $runs.PSObject.Properties['nextLink']) { [string]$runs.nextLink } else { $null }
        }
    }

    return $allRuns
}
