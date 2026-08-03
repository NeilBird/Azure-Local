function Invoke-AzLocalResourceGraphValueBatches {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$QueryTemplate,

        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 100)]
        [int]$BatchSize = 40,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ExactResourceIdProperty,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [int]$LargeFleetThreshold = 200
    )

    if (-not $QueryTemplate.Contains('{0}')) {
        throw 'Invoke-AzLocalResourceGraphValueBatches: QueryTemplate must contain a {0} value-list placeholder.'
    }

    $normalizedValues = @($Value | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) {
            ([string]$_).Trim().ToLowerInvariant()
        }
    } | Where-Object { $_ } | Select-Object -Unique)

    $allRows = [System.Collections.Generic.List[object]]::new()
    if ($ExactResourceIdProperty -and $normalizedValues.Count -gt $LargeFleetThreshold) {
        $resourceIdFilterClause = "| where $ExactResourceIdProperty in~ ({0})"
        if (-not $QueryTemplate.Contains($resourceIdFilterClause)) {
            throw "Invoke-AzLocalResourceGraphValueBatches: QueryTemplate must contain '$resourceIdFilterClause' when ExactResourceIdProperty is supplied."
        }

        $admittedResourceIds = @{}
        $derivedSubscriptionIds = [System.Collections.Generic.List[string]]::new()
        foreach ($resourceId in $normalizedValues) {
            $admittedResourceIds[$resourceId] = $true
            if ($resourceId -match '^/subscriptions/([^/]+)/') {
                $derivedSubscriptionIds.Add($Matches[1]) | Out-Null
            }
        }
        $querySubscriptionIds = @(if ($SubscriptionId) {
            $SubscriptionId | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { ([string]$_).Trim() } | Select-Object -Unique
        }
        else {
            $derivedSubscriptionIds | Select-Object -Unique
        })
        if ($querySubscriptionIds.Count -eq 0) {
            throw 'Invoke-AzLocalResourceGraphValueBatches: no subscription IDs could be resolved for the large-fleet query.'
        }

        $largeFleetQuery = $QueryTemplate.Replace($resourceIdFilterClause, '')
        Write-Verbose ("Large fleet ({0} resource IDs across {1} subscription(s)); querying represented subscriptions in batches of {2} with exact client-side filtering." -f $normalizedValues.Count, $querySubscriptionIds.Count, $BatchSize)
        for ($offset = 0; $offset -lt $querySubscriptionIds.Count; $offset += $BatchSize) {
            $lastIndex = [Math]::Min($offset + $BatchSize - 1, $querySubscriptionIds.Count - 1)
            $subscriptionBatch = @($querySubscriptionIds[$offset..$lastIndex])
            $candidateRows = Invoke-AzResourceGraphQuery -Query $largeFleetQuery -SubscriptionId $subscriptionBatch
            foreach ($row in $candidateRows) {
                $candidateResourceId = if ($null -ne $row -and $row.PSObject.Properties[$ExactResourceIdProperty]) { [string]$row.$ExactResourceIdProperty } else { '' }
                if ($candidateResourceId -and $admittedResourceIds.ContainsKey($candidateResourceId.ToLowerInvariant())) {
                    [void]$allRows.Add($row)
                }
            }
        }
        return $allRows.ToArray()
    }

    for ($offset = 0; $offset -lt $normalizedValues.Count; $offset += $BatchSize) {
        $lastIndex = [Math]::Min($offset + $BatchSize - 1, $normalizedValues.Count - 1)
        $batchValues = @($normalizedValues[$offset..$lastIndex])
        $valueListKql = ($batchValues | ForEach-Object {
            "'$($_.Replace("'", "''"))'"
        }) -join ','
        $query = $QueryTemplate.Replace('{0}', $valueListKql)
        $queryParams = @{ Query = $query }
        if ($SubscriptionId) {
            $queryParams['SubscriptionId'] = $SubscriptionId
        }
        $batchRows = Invoke-AzResourceGraphQuery @queryParams
        foreach ($row in $batchRows) {
            [void]$allRows.Add($row)
        }
    }

    return $allRows.ToArray()
}