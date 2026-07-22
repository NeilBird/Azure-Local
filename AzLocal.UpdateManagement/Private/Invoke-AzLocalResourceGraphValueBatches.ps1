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
        [int]$BatchSize = 40
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