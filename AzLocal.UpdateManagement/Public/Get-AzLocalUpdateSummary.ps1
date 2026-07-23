function Get-AzLocalUpdateSummary {
    <#
    .SYNOPSIS
        Gets the update summary for one or more Azure Local clusters.
    .DESCRIPTION
        Retrieves the update summary for Azure Local (Azure Stack HCI) clusters.
        The summary includes the current update state, actionable updates count,
        health check results, and other update-related status information.
        
        Supports multiple input methods:
        - Single cluster by resource ID (original behavior, returns raw API object)
        - Multiple clusters by name or resource ID
        - All clusters matching an UpdateRing tag value
        
        When querying multiple clusters, returns formatted results with export options.
    .PARAMETER ClusterResourceId
        The full Azure Resource ID of a single cluster (original behavior).
        Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"
    .PARAMETER ClusterNames
        An array of Azure Local cluster names to query.
    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to query.
    .PARAMETER ScopeByUpdateRingTag
        When specified, finds clusters by the 'UpdateRing' tag via Azure Resource Graph.
        Must be used together with -UpdateRingValue.
    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.
    .PARAMETER ResourceGroupName
        The resource group containing the clusters (only used with -ClusterNames).
    .PARAMETER SubscriptionId
        The Azure subscription ID. If not specified, uses the current az CLI subscription.
    .PARAMETER ApiVersion
        The Azure REST API version to use. Default is the module's default API version.
    .PARAMETER ExportPath
        Path to export the results. Supports .csv, .json, and .xml (JUnit format) extensions.
    .OUTPUTS
        PSCustomObject - Single update summary when using -ClusterResourceId
        PSCustomObject[] - Array of formatted summaries when using multi-cluster parameters
    .EXAMPLE
        # Single cluster (original behavior)
        $summary = Get-AzLocalUpdateSummary -ClusterResourceId $cluster.id
        Write-Host "Update State: $($summary.properties.state)"
    .EXAMPLE
        # Multiple clusters by tag
        Get-AzLocalUpdateSummary -ScopeByUpdateRingTag -UpdateRingValue "Wave1"
    .EXAMPLE
        # Export to CSV
        Get-AzLocalUpdateSummary -ScopeByUpdateRingTag -UpdateRingValue "Production" -ExportPath "C:\Reports\summaries.csv"
    #>
    [CmdletBinding(DefaultParameterSetName = 'SingleCluster')]
    [OutputType([PSCustomObject], [PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'SingleCluster')]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string[]]$ClusterNames,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [switch]$ScopeByUpdateRingTag,

        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByResourceId')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByTag')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByResourceId')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByTag')]
        [string]$ExportPath,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByResourceId')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByTag')]
        [ValidateSet('Auto', 'Csv', 'Json', 'JUnitXml')]
        [string]$ExportFormat = 'Auto',

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Pre-flight: Validate export path is writable before expensive operations
    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { Write-Warning $_.Exception.Message; return }
    }

    # Original single-cluster behavior
    if ($PSCmdlet.ParameterSetName -eq 'SingleCluster') {
        Test-AzCliAvailable | Out-Null
        $uri = "https://management.azure.com$ClusterResourceId/updateSummaries/default?api-version=$ApiVersion"
        
        Write-Verbose "Getting update summary from: $uri"
        
        $result = (Invoke-AzRestJson -Uri $uri).Data
        if ($LASTEXITCODE -eq 0) {
            return $result
        }
        return $null
    }

    # Multi-cluster mode
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local Cluster Update Summaries" -Level Header
    Write-Log -Message "========================================" -Level Header

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

    # v0.7.68: Multi-cluster mode is now ARG-only. Ensure the resource-graph
    # extension is present before any param-set branch runs (was previously
    # only checked in the ByTag branch).
    if (-not (Install-AzGraphExtension)) {
        Write-Log -Message "Failed to install Azure CLI 'resource-graph' extension." -Level Error
        return
    }

    # Build list of clusters to process
    $clustersToProcess = @()

    if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
        Write-Log -Message "Querying Azure Resource Graph for clusters with tag 'UpdateRing' = '$UpdateRingValue'..." -Level Info

        $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
        $globalTagFilter = Get-AzLocalClusterTagFilterKqlClause
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $globalTagFilter $ringFilter | project id, name, resourceGroup, subscriptionId, tags"

        try {
            $argParams = @{ Query = $argQuery }
            if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
            $clusterRows = Invoke-AzResourceGraphQuery @argParams

            if (-not $clusterRows -or $clusterRows.Count -eq 0) {
                Write-Log -Message "No clusters found with tag 'UpdateRing' = '$UpdateRingValue'" -Level Warning
                return @()
            }

            Write-Log -Message "Found $($clusterRows.Count) cluster(s) matching tag criteria" -Level Success
            foreach ($cluster in $clusterRows) {
                $clustersToProcess += @{
                    ResourceId = $cluster.id
                    Name = $cluster.name
                    ResourceGroup = $cluster.resourceGroup
                    SubscriptionId = $cluster.subscriptionId
                }
            }
        }
        catch {
            Write-Log -Message "Error querying Azure Resource Graph: $_" -Level Error
            return
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
        foreach ($resourceId in $ClusterResourceIds) {
            $clusterRgName = ($resourceId -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
            $clusterSubId = ($resourceId -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
            $clustersToProcess += @{
                ResourceId = $resourceId
                Name = ($resourceId -split '/')[-1]
                ResourceGroup = $clusterRgName
                SubscriptionId = $clusterSubId
            }
        }
    }
    else {
        # ByName - v0.7.68: resolve all names in a SINGLE ARG batch lookup
        # instead of one ARM REST call per cluster. Works cross-subscription
        # when -SubscriptionId is not passed.
        $nameListKql = ($ClusterNames | ForEach-Object { "'$_'" }) -join ','
        $globalTagFilter = Get-AzLocalClusterTagFilterKqlClause
        $nameQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $globalTagFilter | where name in~ ($nameListKql) | project id, name, resourceGroup, subscriptionId"
        try {
            $argParams = @{ Query = $nameQuery }
            if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
            $clusterRows = Invoke-AzResourceGraphQuery @argParams
        }
        catch {
            Write-Log -Message "Azure Resource Graph cluster lookup failed: $($_.Exception.Message)" -Level Error
            return
        }

        $foundNames = @($clusterRows | Select-Object -ExpandProperty name)
        Write-Log -Message "Resolved $($foundNames.Count) of $($ClusterNames.Count) cluster name(s) via Azure Resource Graph" -Level $(if ($foundNames.Count -eq $ClusterNames.Count) { 'Success' } else { 'Warning' })
        foreach ($name in $ClusterNames) {
            $match = $clusterRows | Where-Object { $_.name -ieq $name } | Select-Object -First 1
            if ($match) {
                $clustersToProcess += @{
                    ResourceId = $match.id
                    Name = $match.name
                    ResourceGroup = $match.resourceGroup
                    SubscriptionId = $match.subscriptionId
                }
            }
            else {
                Write-Log -Message "Cluster '$name' not found in Azure Resource Graph (subscription scope: $(if ($SubscriptionId) { $SubscriptionId } else { 'all readable' })) - skipping" -Level Warning
            }
        }
        if ($ResourceGroupName) {
            $clustersToProcess = @($clustersToProcess | Where-Object { $_.ResourceGroup -ieq $ResourceGroupName })
        }
    }

    if ($clustersToProcess.Count -eq 0) {
        Write-Log -Message "No clusters resolved for query - nothing to do." -Level Warning
        return @()
    }

    Write-Log -Message "" -Level Info
    Write-Log -Message "Querying update summaries for $($clustersToProcess.Count) cluster(s)..." -Level Info

    # v0.7.68: Replaced per-cluster ARM REST fan-out (Start-Job +
    # Invoke-FleetJobsInParallel) with a SINGLE Azure Resource Graph
    # query against the `extensibilityresources` namespace
    # (microsoft.azurestackhci/clusters/updatesummaries). One round-trip
    # returns every updateSummaries/default record for the entire cluster
    # list - typically sub-second for fleets of hundreds of clusters -
    # replacing the previous design which made one ARM REST call per
    # cluster. The `properties` bag returned by ARG is identical in shape
    # to the ARM REST /updateSummaries/default response with one minor
    # field-name drift: ARG snapshots use `lastUpdated`/`lastChecked`
    # whereas older ARM responses used `lastUpdatedTime`/`lastCheckedTime`;
    # both are handled defensively below.

    $idListKql = ($clustersToProcess | ForEach-Object { "'$($_.ResourceId.ToLower())'" }) -join ','
    $summariesKql = "extensibilityresources | where type =~ 'microsoft.azurestackhci/clusters/updatesummaries' | extend ids = split(id, '/') | extend ClusterName_ = tostring(ids[8]) | extend ClusterResourceId_ = tolower(strcat('/subscriptions/', tostring(ids[2]), '/resourceGroups/', tostring(ids[4]), '/providers/Microsoft.AzureStackHCI/clusters/', ClusterName_)) | where ClusterResourceId_ in~ ($idListKql) | project id, name, type, location, properties, ClusterName_, ClusterResourceId_"

    try {
        $argParams = @{ Query = $summariesKql }
        if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
        $allSummariesRaw = Invoke-AzResourceGraphQuery @argParams
    }
    catch {
        Write-Log -Message "Azure Resource Graph query for update summaries failed: $($_.Exception.Message)" -Level Error
        return
    }

    Write-Log -Message "Returned $($allSummariesRaw.Count) update summary record(s) across $($clustersToProcess.Count) cluster(s) via Azure Resource Graph" -Level Success

    # Index summaries by lowercased cluster resource id for O(1) lookup.
    $summaryByCluster = @{}
    foreach ($row in $allSummariesRaw) {
        $key = [string]$row.ClusterResourceId_
        $summaryByCluster[$key] = $row
    }

    # Build per-cluster output rows in input order so display + export are
    # deterministic. Uses System.Collections.Generic.List for O(n) growth.
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($cluster in $clustersToProcess) {
        Write-Host "  Checking: $($cluster.Name)..." -ForegroundColor Gray -NoNewline
        $key = $cluster.ResourceId.ToLower()
        $summary = $summaryByCluster[$key]

        if (-not $summary) {
            # No updateSummaries/default record exists for this cluster yet
            # (e.g. cluster not provisioned or not surfaced to ARG yet).
            Write-Host ' No Summary' -ForegroundColor Gray
            $results.Add([PSCustomObject]@{
                ClusterName           = $cluster.Name
                ResourceGroup         = $cluster.ResourceGroup
                SubscriptionId        = $cluster.SubscriptionId
                UpdateState           = 'No Summary'
                HealthState           = 'Unknown'
                CurrentVersion        = ''
                LastUpdated           = ''
                LastChecked           = ''
                ActionableUpdatesCount = 0
            }) | Out-Null
            continue
        }

        $props = $summary.properties
        $state = if ($props.PSObject.Properties['state'] -and $props.state) { [string]$props.state } else { 'Unknown' }
        $healthState = if ($props.PSObject.Properties['healthState'] -and $props.healthState) { [string]$props.healthState } else { 'Unknown' }

        # Field-name compatibility: ARG returns `lastUpdated`/`lastChecked`,
        # while older ARM REST shapes used `lastUpdatedTime`/`lastCheckedTime`.
        # v0.9.18: exactly ONE of each pair is present, so the bare read of the
        # absent sibling THROWS under Set-StrictMode -Version Latest - guard both.
        $lastUpdatedRaw = if ($props.PSObject.Properties['lastUpdated'] -and $props.lastUpdated) { $props.lastUpdated } elseif ($props.PSObject.Properties['lastUpdatedTime'] -and $props.lastUpdatedTime) { $props.lastUpdatedTime } else { $null }
        $lastCheckedRaw = if ($props.PSObject.Properties['lastChecked'] -and $props.lastChecked) { $props.lastChecked } elseif ($props.PSObject.Properties['lastCheckedTime'] -and $props.lastCheckedTime) { $props.lastCheckedTime } else { $null }
        $lastUpdatedFmt = if ($lastUpdatedRaw) { ([datetime]$lastUpdatedRaw).ToString('yyyy-MM-dd HH:mm') } else { '' }
        $lastCheckedFmt = if ($lastCheckedRaw) { ([datetime]$lastCheckedRaw).ToString('yyyy-MM-dd HH:mm') } else { '' }
        $availableUpdates = if ($props.PSObject.Properties['updateStateProperties'] -and $props.updateStateProperties -and $props.updateStateProperties.PSObject.Properties['availableUpdates'] -and $props.updateStateProperties.availableUpdates) { $props.updateStateProperties.availableUpdates } else { 0 }

        $row = [PSCustomObject]@{
            ClusterName           = $cluster.Name
            ResourceGroup         = $cluster.ResourceGroup
            SubscriptionId        = $cluster.SubscriptionId
            UpdateState           = $state
            HealthState           = $healthState
            CurrentVersion        = if ($props.currentVersion) { [string]$props.currentVersion } else { '' }
            LastUpdated           = $lastUpdatedFmt
            LastChecked           = $lastCheckedFmt
            ActionableUpdatesCount = $availableUpdates
        }

        if ($state -eq 'UpdateAvailable' -or $state -eq 'Ready') {
            Write-Host " $state" -ForegroundColor Green
        }
        elseif ($state -eq 'UpdateInProgress') {
            Write-Host " $state" -ForegroundColor Yellow
        }
        elseif ($healthState -eq 'Failure') {
            Write-Host " $state ($healthState)" -ForegroundColor Red
        }
        else {
            Write-Host " $state" -ForegroundColor Gray
        }

        $results.Add($row) | Out-Null
    }

    # Display Summary
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Summary" -Level Header
    Write-Log -Message "========================================" -Level Header
    
    $totalClusters = $results.Count
    $upToDate = @($results | Where-Object { $_.UpdateState -in @("UpToDate", "AppliedSuccessfully") }).Count
    $updateAvailable = @($results | Where-Object { $_.UpdateState -in (@("UpdateAvailable") + $script:ReadyStates) }).Count
    $inProgress = @($results | Where-Object { $_.UpdateState -eq "UpdateInProgress" }).Count
    $healthFailures = @($results | Where-Object { $_.HealthState -eq "Failure" }).Count

    Write-Log -Message "" -Level Info
    Write-Log -Message "Total Clusters:       $totalClusters" -Level Info
    Write-Log -Message "Up to Date:           $upToDate" -Level $(if ($upToDate -gt 0) { "Success" } else { "Info" })
    Write-Log -Message "Update Available:     $updateAvailable" -Level $(if ($updateAvailable -gt 0) { "Warning" } else { "Info" })
    Write-Log -Message "Update In Progress:   $inProgress" -Level $(if ($inProgress -gt 0) { "Warning" } else { "Info" })
    Write-Log -Message "Health Failures:      $healthFailures" -Level $(if ($healthFailures -gt 0) { "Error" } else { "Info" })

    # Display results table
    Write-Log -Message "" -Level Info
    Write-Log -Message "Detailed Results:" -Level Header
    $results | Format-Table ClusterName, ResourceGroup, UpdateState, HealthState, CurrentVersion, ActionableUpdatesCount -AutoSize | Out-Host

    # Export if path specified
    if ($ExportPath) {
        try {
            $ExportPath = Resolve-SafeOutputPath -Path $ExportPath
            $exportDir = Split-Path -Path $ExportPath -Parent
            if ($exportDir -and -not (Test-Path $exportDir)) {
                New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
            }
            
            $format = Get-ExportFormat -Path $ExportPath -ExportFormat $ExportFormat
            
            switch ($format) {
                'Csv' {
                    $results | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
                    Write-Log -Message "Results exported to CSV: $ExportPath" -Level Success
                }
                'Json' {
                    $exportData = @{
                        Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        TotalClusters = $totalClusters
                        Summary       = @{
                            UpToDate        = $upToDate
                            UpdateAvailable = $updateAvailable
                            InProgress      = $inProgress
                            HealthFailures  = $healthFailures
                        }
                        Results       = $results
                    }
                    Write-Utf8NoBomFile -Path $ExportPath -Content ($exportData | ConvertTo-Json -Depth 10)
                    Write-Log -Message "Results exported to JSON: $ExportPath" -Level Success
                }
                'JUnitXml' {
                    $junitResults = $results | ForEach-Object {
                        [PSCustomObject]@{
                            ClusterName  = $_.ClusterName
                            Status       = if ($_.HealthState -eq "Failure") { "Failed" } elseif ($_.UpdateState -in @("UpToDate", "AppliedSuccessfully")) { "Passed" } else { "Skipped" }
                            Message      = "UpdateState: $($_.UpdateState), HealthState: $($_.HealthState), CurrentVersion: $($_.CurrentVersion)"
                            UpdateName   = $_.CurrentVersion
                            CurrentState = $_.UpdateState
                        }
                    }
                    Export-ResultsToJUnitXml -Results $junitResults -OutputPath $ExportPath `
                        -TestSuiteName "AzureLocalUpdateSummary" -OperationType "UpdateSummary"
                    Write-Log -Message "Results exported to JUnit XML: $ExportPath" -Level Success
                }
            }
        }
        catch {
            Write-Log -Message "Failed to export results: $($_.Exception.Message)" -Level Error
        }
    }

    Write-Log -Message "" -Level Info
    if ($PassThru) {
        return $results
    }
}
