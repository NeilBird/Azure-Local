function Get-AzLocalClusterInventory {
    <#
    .SYNOPSIS
        Gets an inventory of Azure Local clusters with their UpdateRing tag status.

    .DESCRIPTION
        Queries Azure Local (Azure Stack HCI) clusters and returns cluster details
        including the value of the 'UpdateRing' tag (or indicates if the tag doesn't exist).
        
        Supports multiple input methods:
        - All clusters via Azure Resource Graph (default)
        - Specific clusters by Resource ID
        - Specific clusters by name
        - Clusters matching an UpdateRing tag value
        
        The output can be exported to CSV for use with Excel to plan and populate
        UpdateRing tag values, then used as input for Set-AzLocalClusterUpdateRingTag.

    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to inventory.
        Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"

    .PARAMETER ClusterNames
        An array of Azure Local cluster names to inventory.

    .PARAMETER ScopeByUpdateRingTag
        When specified, finds clusters by the 'UpdateRing' tag via Azure Resource Graph.
        Must be used together with -UpdateRingValue.

    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.

    .PARAMETER ResourceGroupName
        The resource group containing the clusters (only used with -ClusterNames).

    .PARAMETER SubscriptionId
        Optional. Limit the query to a specific Azure subscription ID.
        If not specified, queries across all accessible subscriptions (default mode)
        or uses the current subscription (for -ClusterNames).

    .PARAMETER ExportPath
        Optional. Path to export the inventory. Supports CSV and JSON formats.
        Format is auto-detected from file extension (.csv or .json).
        CSV is useful for editing in Excel; JSON for CI/CD and API integrations.

    .PARAMETER IncludeSideloadColumns
        Optional. When set, adds the numeric 'UpdateAuthAccountId' tag value as
        an extra column (placed just before ResourceId) in both the returned
        objects and the CSV/JSON export. Used by the opt-in on-prem sideload
        workflow (Step.6) so Step.1 / Step.2 can round-trip the per-cluster
        auth-map account id. When NOT set, the column is omitted entirely and
        the output is byte-identical to prior versions.

    .EXAMPLE
        # Get inventory of all clusters across all subscriptions
        Get-AzLocalClusterInventory

    .EXAMPLE
        # Get inventory for specific clusters by Resource ID
        Get-AzLocalClusterInventory -ClusterResourceIds @("/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01")

    .EXAMPLE
        # Get inventory for clusters by name
        Get-AzLocalClusterInventory -ClusterNames @("Cluster01", "Cluster02") -ResourceGroupName "MyRG"

    .EXAMPLE
        # Get inventory for clusters in a specific UpdateRing
        Get-AzLocalClusterInventory -ScopeByUpdateRingTag -UpdateRingValue "Wave1"

    .EXAMPLE
        # Get inventory and export to CSV for editing in Excel
        Get-AzLocalClusterInventory -ExportPath "C:\Temp\ClusterInventory.csv"

    .EXAMPLE
        # Get inventory and export to JSON for CI/CD pipelines
        Get-AzLocalClusterInventory -ExportPath "C:\Temp\ClusterInventory.json"

    .EXAMPLE
        # Get inventory for a specific subscription
        Get-AzLocalClusterInventory -SubscriptionId "12345678-1234-1234-1234-123456789012"

    .EXAMPLE
        # Pipeline workflow: Get inventory, edit CSV, then apply tags
        Get-AzLocalClusterInventory -ExportPath "C:\Temp\Inventory.csv"
        # Edit the CSV in Excel to populate UpdateRing values
        Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\Inventory.csv"

    .EXAMPLE
        # CI/CD pipeline: Export to CSV AND return objects for processing
        $inventory = Get-AzLocalClusterInventory -ExportPath "C:\Temp\Inventory.csv" -PassThru
        Write-Host "Found $($inventory.Count) clusters"

    .NOTES
        Author: Neil Bird, Microsoft.
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string[]]$ClusterNames,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [switch]$ScopeByUpdateRingTag,

        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false, ParameterSetName = 'All')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ExportPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeSideloadColumns
    )

    # Pre-flight: Validate export path is writable before expensive operations
    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { Write-Warning $_.Exception.Message; return }
    }

    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local Cluster Inventory" -Level Header
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "" -Level Info

    # Verify Azure CLI is installed and logged in
    Test-AzCliAvailable | Out-Null
    try {
        $null = az account show 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI is not logged in. Please run 'az login' first."
        }
        Write-Log -Message "Azure CLI authentication verified" -Level Success
    }
    catch {
        Write-Log -Message "Azure CLI is not logged in. Please run 'az login' first." -Level Error
        return
    }

    # Ensure resource-graph extension is installed (needed for All and ByTag modes)
    if ($PSCmdlet.ParameterSetName -in @('All', 'ByTag')) {
        if (-not (Install-AzGraphExtension)) {
            Write-Log -Message "Failed to install Azure CLI 'resource-graph' extension. Please install manually: az extension add --name resource-graph" -Level Error
            return
        }
    }

    # Build cluster data based on parameter set
    $clusterData = @()

    if ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
        # Direct REST lookup for each Resource ID
        Write-Log -Message "Looking up $($ClusterResourceIds.Count) cluster(s) by Resource ID..." -Level Info
        $apiVer = $script:DefaultApiVersion
        foreach ($resourceId in $ClusterResourceIds) {
            $clusterName = ($resourceId -split '/')[-1]
            Write-Host "  Checking: $clusterName..." -ForegroundColor Gray -NoNewline
            try {
                $uri = "https://management.azure.com${resourceId}?api-version=$apiVer"
                $clusterInfo = (Invoke-AzRestJson -Uri $uri).Data
                if ($LASTEXITCODE -eq 0 -and $clusterInfo) {
                    $rgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $subId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                    $clusterData += [PSCustomObject]@{
                        id             = $clusterInfo.id
                        name           = $clusterInfo.name
                        resourceGroup  = $rgName
                        subscriptionId = $subId
                        tags           = $clusterInfo.tags
                    }
                    Write-Host " Found" -ForegroundColor Green
                }
                else {
                    Write-Host " Not Found" -ForegroundColor Red
                    Write-Log -Message "Cluster not found: $resourceId" -Level Warning
                }
            }
            catch {
                Write-Host " Error" -ForegroundColor Red
                Write-Log -Message "Error looking up '$resourceId': $($_.Exception.Message)" -Level Warning
            }
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByName') {
        # Look up clusters by name
        if (-not $SubscriptionId) {
            $SubscriptionId = (az account show --query id -o tsv)
        }
        Write-Log -Message "Looking up $($ClusterNames.Count) cluster(s) by name..." -Level Info
        foreach ($name in $ClusterNames) {
            Write-Host "  Checking: $name..." -ForegroundColor Gray -NoNewline
            $clusterInfo = Get-AzLocalClusterInfo -ClusterName $name `
                -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId
            if ($clusterInfo) {
                $rgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                $subId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                $clusterData += [PSCustomObject]@{
                    id             = $clusterInfo.id
                    name           = $clusterInfo.name
                    resourceGroup  = $rgName
                    subscriptionId = $subId
                    tags           = $clusterInfo.tags
                }
                Write-Host " Found" -ForegroundColor Green
            }
            else {
                Write-Host " Not Found" -ForegroundColor Red
                Write-Log -Message "Cluster '$name' not found - skipping" -Level Warning
            }
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByTag') {
        # Query by UpdateRing tag via ARG
        Write-Log -Message "Querying Azure Resource Graph for clusters with tag 'UpdateRing' = '$UpdateRingValue'..." -Level Info
        $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $ringFilter | project id, name, resourceGroup, subscriptionId, tags | order by name asc"
        try {
            $clusters = Invoke-AzResourceGraphQuery -Query $argQuery
            if (-not $clusters -or $clusters.Count -eq 0) {
                Write-Log -Message "No clusters found with tag 'UpdateRing' = '$UpdateRingValue'" -Level Warning
                return @()
            }
            Write-Log -Message "Found $($clusters.Count) cluster(s) matching tag criteria" -Level Success
            $clusterData = $clusters
        }
        catch {
            Write-Log -Message "Error querying Azure Resource Graph: $_" -Level Error
            return
        }
    }
    else {
        # Default: All clusters via ARG
        Write-Log -Message "Querying Azure Resource Graph for all Azure Local clusters..." -Level Info

        # Build Azure Resource Graph query - use single line to avoid escaping issues with az CLI
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | project id, name, resourceGroup, subscriptionId, tags | order by name asc"

        try {
            if ($SubscriptionId) {
                Write-Log -Message "  Filtering to subscription: $SubscriptionId" -Level Verbose
                $clusterData = Invoke-AzResourceGraphQuery -Query $argQuery -SubscriptionId $SubscriptionId
            }
            else {
                Write-Log -Message "  Querying across all accessible subscriptions" -Level Verbose
                $clusterData = Invoke-AzResourceGraphQuery -Query $argQuery
            }

            if (-not $clusterData -or $clusterData.Count -eq 0) {
                Write-Log -Message "No Azure Local clusters found." -Level Warning
                return @()
            }
        }
        catch {
            Write-Log -Message "Error querying Azure Resource Graph: $($_.Exception.Message)" -Level Error
            return @()
        }
    }

    if ($clusterData.Count -eq 0) {
        Write-Log -Message "No clusters to inventory." -Level Warning
        return @()
    }

    try {
        # Get subscription names for better readability
        Write-Log -Message "Retrieving subscription details..." -Level Info
        $subscriptionMap = @{}
        $uniqueSubIds = $clusterData | Select-Object -ExpandProperty subscriptionId -Unique
        
        foreach ($subId in $uniqueSubIds) {
            # v0.7.67: use the stream-split Invoke-AzCliJson helper instead of
            # piping `az account show ... 2>&1` directly to ConvertFrom-Json.
            # The merged-stream pipe would silently corrupt JSON whenever the
            # CLI emitted a stderr warning (e.g. the cp1252 encode warning on
            # non-UTF-8 Windows runners), losing the subscription name even
            # when the lookup itself succeeded.
            $sub = Invoke-AzCliJson -Arguments @('account', 'show', '--subscription', $subId)
            if ($sub.Ok -and $sub.Data -and $sub.Data.name) {
                $subscriptionMap[$subId] = $sub.Data.name
            }
            else {
                $subscriptionMap[$subId] = "(Unable to retrieve name)"
            }
        }

        # Build inventory results
        $inventory = @()
        foreach ($cluster in $clusterData) {
            # Read tag values via container-shape-agnostic helper so both
            # [PSCustomObject] and [Hashtable] tag shapes are handled.
            # NOTE: Do NOT name this local 'updateRingValue' - PowerShell is
            # case-insensitive on variable names, so that would alias the
            # function's [ValidatePattern(...)] $UpdateRingValue parameter
            # and throw a validation error for any cluster missing the tag.
            $ringTagValue = Get-TagValue -Tags $cluster.tags -Name 'UpdateRing'
            $windowTagValue = Get-TagValue -Tags $cluster.tags -Name $script:UpdateStartWindowTagName
            $exclusionsTagValue = Get-TagValue -Tags $cluster.tags -Name $script:UpdateExclusionsWindowTagName
            $excludedTagValue = Get-TagValue -Tags $cluster.tags -Name $script:UpdateExcludedTagName
            $sideloadedTagValue = Get-TagValue -Tags $cluster.tags -Name $script:UpdateSideloadedTagName
            $versionInProgressTagValue = Get-TagValue -Tags $cluster.tags -Name $script:UpdateVersionInProgressTagName

            # Build the per-cluster inventory item via an ordered hashtable so the
            # optional sideload UpdateAuthAccountId column can be inserted just
            # before ResourceId without disturbing the column order/output of the
            # default (sideload-off) path - which must remain byte-identical.
            $itemProps = [ordered]@{
                ClusterName             = $cluster.name
                ResourceGroup           = $cluster.resourceGroup
                SubscriptionId          = $cluster.subscriptionId
                SubscriptionName        = $subscriptionMap[$cluster.subscriptionId]
                UpdateRing              = if ($ringTagValue) { $ringTagValue } else { "" }
                HasUpdateRingTag        = if ($ringTagValue) { "Yes" } else { "No" }
                UpdateStartWindow       = if ($windowTagValue) { $windowTagValue } else { "" }
                UpdateExclusionsWindow  = if ($exclusionsTagValue) { $exclusionsTagValue } else { "" }
                UpdateExcluded          = if ($excludedTagValue) { $excludedTagValue } else { "" }
                UpdateSideloaded        = if ($sideloadedTagValue) { $sideloadedTagValue } else { "" }
                UpdateVersionInProgress = if ($versionInProgressTagValue) { $versionInProgressTagValue } else { "" }
            }
            if ($IncludeSideloadColumns) {
                $authIdTagValue = Get-TagValue -Tags $cluster.tags -Name $script:UpdateAuthAccountIdTagName
                $itemProps['UpdateAuthAccountId'] = if ($authIdTagValue) { $authIdTagValue } else { "" }
            }
            $itemProps['ResourceId'] = $cluster.id
            # Preserve raw ARM tag bag so downstream consumers can read tags this projection does not explicitly surface (CSV/JSON export below uses an explicit $selectColumns list so this field is excluded from on-disk artefacts).
            $itemProps['tags'] = $cluster.tags
            $inventoryItem = [PSCustomObject]$itemProps
            $inventory += $inventoryItem
        }

        # Calculate summary statistics
        $clustersWithTag = @($inventory | Where-Object { $_.HasUpdateRingTag -eq "Yes" }).Count
        $clustersWithoutTag = $inventory.Count - $clustersWithTag
        $ringGroups = @($inventory | Where-Object { $_.UpdateRing -ne "" } | Group-Object -Property UpdateRing)

        # Export if path specified
        if ($ExportPath) {
            try {
                # Ensure directory exists
                $ExportPath = Resolve-SafeOutputPath -Path $ExportPath
                $exportDir = Split-Path -Path $ExportPath -Parent
                if ($exportDir -and -not (Test-Path -Path $exportDir)) {
                    $null = New-Item -ItemType Directory -Path $exportDir -Force
                }

                # Determine export format from file extension
                $extension = [System.IO.Path]::GetExtension($ExportPath).ToLower()
                $selectColumns = @('ClusterName', 'ResourceGroup', 'SubscriptionId', 'SubscriptionName', 'UpdateRing', 'HasUpdateRingTag', 'UpdateStartWindow', 'UpdateExclusionsWindow', 'UpdateExcluded', 'UpdateSideloaded', 'UpdateVersionInProgress')
                if ($IncludeSideloadColumns) { $selectColumns += 'UpdateAuthAccountId' }
                $selectColumns += 'ResourceId'
                $exportData = $inventory | Select-Object $selectColumns
                
                switch ($extension) {
                    '.json' {
                        Write-Utf8NoBomFile -Path $ExportPath -Content ($exportData | ConvertTo-Json -Depth 10)
                        Write-Log -Message "Inventory exported to JSON: $ExportPath" -Level Success
                    }
                    default {
                        # Default to CSV for .csv or any other extension
                        $exportData | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Force
                        Write-Log -Message "Inventory exported to CSV: $ExportPath" -Level Success
                    }
                }
            }
            catch {
                Write-Log -Message "Failed to export inventory: $($_.Exception.Message)" -Level Error
            }
        }

        # Display summary at the end
        Write-Log -Message "" -Level Info
        Write-Log -Message "Inventory Summary:" -Level Header
        Write-Log -Message "  Total Clusters: $($inventory.Count)" -Level Info
        Write-Log -Message "  Clusters with UpdateRing tag: $clustersWithTag" -Level $(if ($clustersWithTag -gt 0) { "Success" } else { "Verbose" })
        Write-Log -Message "  Clusters without UpdateRing tag: $clustersWithoutTag" -Level $(if ($clustersWithoutTag -gt 0) { "Warning" } else { "Verbose" })

        # Group by UpdateRing value
        if ($ringGroups.Count -gt 0) {
            Write-Log -Message "" -Level Info
            Write-Log -Message "  UpdateRing Distribution:" -Level Info
            foreach ($group in $ringGroups | Sort-Object Name) {
                Write-Log -Message "    $($group.Name): $($group.Count) cluster(s)" -Level Success
            }
        }

        # Show next steps if file was exported
        if ($ExportPath -and (Test-Path -Path $ExportPath)) {
            $extension = [System.IO.Path]::GetExtension($ExportPath).ToLower()
            Write-Log -Message "" -Level Info
            if ($extension -eq '.json') {
                Write-Log -Message "Next Steps (JSON export):" -Level Header
                Write-Log -Message "  - Use the JSON file for CI/CD pipelines, API integrations, or CMDB systems" -Level Info
                Write-Log -Message "  - To apply tags, export to CSV format instead" -Level Info
            }
            else {
                Write-Log -Message "Next Steps (CSV export):" -Level Header
                Write-Log -Message "  1. Open the CSV in Excel" -Level Info
                Write-Log -Message "  2. Populate the 'UpdateRing' column with values (e.g., 'Wave1', 'Wave2', 'Pilot')" -Level Info
                Write-Log -Message "  3. Save the CSV file" -Level Info
                Write-Log -Message "  4. Run: Set-AzLocalClusterUpdateRingTag -InputCsvPath '$ExportPath'" -Level Info
            }
        }

        Write-Log -Message "" -Level Info
        
        # Return inventory if: no CSV export, OR PassThru is specified
        # This allows CI/CD pipelines to use -PassThru to get objects for processing
        if (-not $ExportPath -or $PassThru) {
            return $inventory
        }
    }
    catch {
        Write-Log -Message "Error querying Azure Resource Graph: $($_.Exception.Message)" -Level Error
        return @()
    }
}
