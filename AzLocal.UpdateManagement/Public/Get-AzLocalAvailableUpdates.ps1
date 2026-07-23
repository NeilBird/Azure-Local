function Get-AzLocalAvailableUpdates {
    <#
    .SYNOPSIS
        Gets the list of available updates for one or more Azure Local clusters.
    
    .DESCRIPTION
        Retrieves all updates that are available to install on the specified Azure Local cluster(s).
        Returns update objects containing details such as update name, version, 
        description, and state.
        
        Supports multiple input methods:
        - Single cluster by resource ID (original behavior, returns raw API objects)
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
        The API version to use. Defaults to "2025-10-01".
    
    .PARAMETER ExportPath
        Path to export the results. Format is auto-detected from extension (.csv, .json, .xml) unless -ExportFormat is specified.
    
    .PARAMETER ExportFormat
        Export format: Auto (default - detect from extension), Csv, Json, or JUnitXml.
    
    .OUTPUTS
        Returns an array of PSCustomObjects representing available updates.
    
    .EXAMPLE
        # Single cluster (original behavior)
        Get-AzLocalAvailableUpdates -ClusterResourceId "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"
    
    .EXAMPLE
        # Multiple clusters by tag
        Get-AzLocalAvailableUpdates -ScopeByUpdateRingTag -UpdateRingValue "Wave1"
    
    .EXAMPLE
        # Export to CSV
        Get-AzLocalAvailableUpdates -ScopeByUpdateRingTag -UpdateRingValue "Production" -ExportPath "C:\Reports\updates.csv"
    #>
    [CmdletBinding(DefaultParameterSetName = 'SingleCluster')]
    [OutputType([PSCustomObject[]])]
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
        [switch]$PassThru,

        [Parameter(Mandatory = $false, ParameterSetName = 'SingleCluster')]
        [switch]$Raw
    )

    # Pre-flight: Validate export path is writable before expensive operations
    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { Write-Warning $_.Exception.Message; return }
    }

    # Original single-cluster behavior
    if ($PSCmdlet.ParameterSetName -eq 'SingleCluster') {
        Test-AzCliAvailable | Out-Null
        $uri = "https://management.azure.com$ClusterResourceId/updates?api-version=$ApiVersion"
        
        Write-Verbose "Getting available updates from: $uri"
        
        $result = (Invoke-AzRestJson -Uri $uri).Data
        if ($LASTEXITCODE -ne 0 -or -not $result.value) {
            if (-not $Raw) {
                Write-Log -Message "No updates returned for cluster '$(($ClusterResourceId -split '/')[-1])'." -Level Warning
            }
            return @()
        }

        # -Raw returns the unprocessed ARM API objects (used by internal callers)
        if ($Raw) {
            return $result.value
        }

        # Default: return enriched objects with SBE dependency info
        $clusterName = ($ClusterResourceId -split '/')[-1]
        $rgName = ($ClusterResourceId -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
        $subId = ($ClusterResourceId -split '/subscriptions/')[1] -split '/' | Select-Object -First 1

        # Header banner (matches multi-cluster output style)
        Write-Log -Message "" -Level Info
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Available Updates" -Level Header
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Cluster:        $clusterName" -Level Info
        Write-Log -Message "Resource Group: $rgName" -Level Info
        Write-Log -Message "Subscription:   $subId" -Level Info

        $enriched = @()
        foreach ($update in $result.value) {
            $props = $update.properties
            $state = if ($props.PSObject.Properties['state'] -and $props.state) { $props.state } else { "Unknown" }
            $packageType = if ($props.PSObject.Properties['packageType'] -and $props.packageType) { $props.packageType } else { "" }
            $sbeDependency = ""
            if ($state -in @("HasPrerequisite", "AdditionalContentRequired") -and $packageType -eq "SBE") {
                $addlRaw = if ($props.PSObject.Properties['additionalProperties']) { $props.additionalProperties } else { $null }
                $additionalProps = ConvertTo-AzLocalAdditionalProperties -InputObject $addlRaw
                $sbeParts = @()
                if ($additionalProps -and $additionalProps.SBEPublisher) { $sbeParts += "Publisher: $($additionalProps.SBEPublisher)" }
                if ($additionalProps -and $additionalProps.SBEFamily) { $sbeParts += "Family: $($additionalProps.SBEFamily)" }
                if ($additionalProps -and $additionalProps.SBEReleaseLink) { $sbeParts += "ReleaseNotes: $($additionalProps.SBEReleaseLink)" }
                if ($sbeParts.Count -gt 0) { $sbeDependency = $sbeParts -join '; ' }
            }
            $enriched += [PSCustomObject]@{
                ClusterName      = $clusterName
                ResourceGroup    = $rgName
                SubscriptionId   = $subId
                UpdateName       = $update.name
                UpdateState      = $state
                Version          = if ($props.version) { $props.version } else { "" }
                PackageType      = $packageType
                SBEDependency    = $sbeDependency
                Description      = if ($props.description) { $props.description.Substring(0, [Math]::Min(100, $props.description.Length)) } else { "" }
            }
        }

        # Summary block (matches multi-cluster output style)
        $readyCount = @($enriched | Where-Object { $_.UpdateState -in $script:ReadyStates }).Count
        $prereqCount = @($enriched | Where-Object { $_.UpdateState -in $script:PrereqStates }).Count
        $otherCount = $enriched.Count - $readyCount - $prereqCount

        Write-Log -Message "" -Level Info
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Summary" -Level Header
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Total Updates:           $($enriched.Count)" -Level Info
        Write-Log -Message "Ready to Install:        $readyCount" -Level $(if ($readyCount -gt 0) { "Success" } else { "Info" })
        Write-Log -Message "Has Prerequisite (SBE):  $prereqCount" -Level $(if ($prereqCount -gt 0) { "Warning" } else { "Info" })
        if ($otherCount -gt 0) {
            Write-Log -Message "Other States:            $otherCount" -Level Info
        }

        if ($prereqCount -gt 0) {
            Write-Log -Message "" -Level Info
            Write-Log -Message "Updates blocked by SBE prerequisites:" -Level Warning
            foreach ($u in ($enriched | Where-Object { $_.UpdateState -in $script:PrereqStates })) {
                $msg = "  - $($u.UpdateName): $($u.UpdateState)"
                if ($u.SBEDependency) { $msg += " ($($u.SBEDependency))" }
                Write-Log -Message $msg -Level Warning
            }
            Write-Log -Message "Install the required SBE (Solution Builder Extension) update from your hardware vendor before these updates can proceed." -Level Warning
        }

        Write-Log -Message "" -Level Info
        Write-Log -Message "Detailed Results:" -Level Header
        $enriched | Format-Table UpdateName, UpdateState, Version, PackageType, SBEDependency -AutoSize | Out-String | Write-Host

        return $enriched
    }

    # Multi-cluster mode
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local Available Updates" -Level Header
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
    Write-Log -Message "Querying available updates for $($clustersToProcess.Count) cluster(s)..." -Level Info

    # Collect results
    $results = @()
    $updateVersionCounts = @{}

    # v0.7.68: Replaced per-cluster ARM REST fan-out (parallel + serial paths
    # via Invoke-FleetJobsInParallel) with a SINGLE Azure Resource Graph query
    # against the `extensibilityresources` namespace
    # (microsoft.azurestackhci/clusters/updates). One round-trip returns every
    # available-update record across the entire cluster list - typically
    # sub-second for fleets of hundreds of clusters - replacing the previous
    # design which made one /updates ARM REST call per cluster (and optionally
    # batched them across Start-Job runspaces). The `properties` bag returned
    # by ARG is identical in shape to the ARM REST /updates response, with one
    # minor field gap: ARG snapshots do not expose `description`, so we fall
    # back to `displayName` when description is unavailable.

    $idListKql = ($clustersToProcess | ForEach-Object { "'$($_.ResourceId.ToLower())'" }) -join ','
    $updatesKql = "extensibilityresources | where type =~ 'microsoft.azurestackhci/clusters/updates' | extend ids = split(id, '/') | extend ClusterName_ = tostring(ids[8]), UpdateName_ = tostring(ids[10]) | extend ClusterResourceId_ = tolower(strcat('/subscriptions/', tostring(ids[2]), '/resourceGroups/', tostring(ids[4]), '/providers/Microsoft.AzureStackHCI/clusters/', ClusterName_)) | where ClusterResourceId_ in~ ($idListKql) | project id, name, type, location, properties, ClusterName_, ClusterResourceId_, UpdateName_"

    try {
        $argParams = @{ Query = $updatesKql }
        if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
        $allUpdatesRaw = Invoke-AzResourceGraphQuery @argParams
    }
    catch {
        Write-Log -Message "Azure Resource Graph query for available updates failed: $($_.Exception.Message)" -Level Error
        return
    }

    Write-Log -Message "Returned $($allUpdatesRaw.Count) available-update record(s) across $($clustersToProcess.Count) cluster(s) via Azure Resource Graph" -Level Success

    # Index updates by lowercased cluster resource id.
    $updatesByCluster = @{}
    foreach ($row in $allUpdatesRaw) {
        $key = [string]$row.ClusterResourceId_
        if (-not $updatesByCluster.ContainsKey($key)) { $updatesByCluster[$key] = [System.Collections.Generic.List[object]]::new() }
        $updatesByCluster[$key].Add($row) | Out-Null
    }

    # Build per-cluster output rows in input order so display + export are
    # deterministic. Mirrors the legacy per-cluster colourised "X update(s)
    # (Y ready, Z prereq)" header line.
    foreach ($cluster in $clustersToProcess) {
        $clusterName = $cluster.Name
        Write-Host "  Checking: $clusterName..." -ForegroundColor Gray -NoNewline
        $key = $cluster.ResourceId.ToLower()
        $clusterUpdates = if ($updatesByCluster.ContainsKey($key)) { @($updatesByCluster[$key]) } else { @() }

        if ($clusterUpdates.Count -eq 0) {
            Write-Host " No updates available" -ForegroundColor Gray
            $results += [PSCustomObject]@{
                ClusterName      = $clusterName
                ResourceGroup    = $cluster.ResourceGroup
                SubscriptionId   = $cluster.SubscriptionId
                UpdateName       = "None"
                UpdateState      = "No Updates"
                Version          = ""
                PackageType      = ""
                SBEDependency    = ""
                Description      = ""
            }
            continue
        }

        $readyCount = @($clusterUpdates | Where-Object { $_.properties.state -in $script:ReadyStates }).Count
        $prereqCount = @($clusterUpdates | Where-Object { $_.properties.state -in $script:PrereqStates }).Count

        $statusParts = @("$readyCount ready")
        if ($prereqCount -gt 0) { $statusParts += "$prereqCount has prerequisite" }
        $statusText = $statusParts -join ', '
        $statusColor = if ($readyCount -gt 0) { "Green" } elseif ($prereqCount -gt 0) { "Yellow" } else { "Yellow" }
        Write-Host " $($clusterUpdates.Count) update(s) ($statusText)" -ForegroundColor $statusColor

        foreach ($update in $clusterUpdates) {
            $props = $update.properties
            $state = if ($props.state) { [string]$props.state } else { "Unknown" }

            # Track update versions
            if ($state -in $script:ReadyStates) {
                $updateName = [string]$update.UpdateName_
                if ($updateVersionCounts.ContainsKey($updateName)) {
                    $updateVersionCounts[$updateName]++
                }
                else {
                    $updateVersionCounts[$updateName] = 1
                }
            }

            # Extract SBE dependency info for HasPrerequisite/AdditionalContentRequired updates
            $packageType = if ($props.packageType) { [string]$props.packageType } else { "" }
            $sbeDependency = ""
            if ($state -in @("HasPrerequisite", "AdditionalContentRequired") -and $packageType -eq "SBE") {
                $additionalProps = ConvertTo-AzLocalAdditionalProperties -InputObject $props.additionalProperties
                $sbePublisher = if ($additionalProps -and $additionalProps.SBEPublisher) { $additionalProps.SBEPublisher } else { "" }
                $sbeFamily = if ($additionalProps -and $additionalProps.SBEFamily) { $additionalProps.SBEFamily } else { "" }
                $sbeReleaseLink = if ($additionalProps -and $additionalProps.SBEReleaseLink) { $additionalProps.SBEReleaseLink } else { "" }
                $sbeParts = @()
                if ($sbePublisher) { $sbeParts += "Publisher: $sbePublisher" }
                if ($sbeFamily) { $sbeParts += "Family: $sbeFamily" }
                if ($sbeReleaseLink) { $sbeParts += "ReleaseNotes: $sbeReleaseLink" }
                if ($sbeParts.Count -gt 0) { $sbeDependency = $sbeParts -join '; ' }
            }

            # Description fallback: ARG does not surface `description`; use
            # `displayName` when description is unavailable.
            $descSource = if ($props.description) { $props.description } elseif ($props.displayName) { $props.displayName } else { "" }
            $descTrimmed = if ($descSource) { ([string]$descSource).Substring(0, [Math]::Min(100, ([string]$descSource).Length)) } else { "" }

            $results += [PSCustomObject]@{
                ClusterName      = $clusterName
                ResourceGroup    = $cluster.ResourceGroup
                SubscriptionId   = $cluster.SubscriptionId
                UpdateName       = [string]$update.UpdateName_
                UpdateState      = $state
                Version          = if ($props.version) { [string]$props.version } else { "" }
                PackageType      = $packageType
                SBEDependency    = $sbeDependency
                Description      = $descTrimmed
            }
        }
    }

    # Display Summary
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Summary" -Level Header
    Write-Log -Message "========================================" -Level Header
    
    $totalClusters = $clustersToProcess.Count
    $clustersWithUpdates = @($results | Where-Object { $_.UpdateName -notin @("N/A", "None", "Error") } | Select-Object -ExpandProperty ClusterName -Unique).Count
    $clustersWithReadyUpdates = @($results | Where-Object { $_.UpdateState -in $script:ReadyStates } | Select-Object -ExpandProperty ClusterName -Unique).Count
    $clustersWithPrereqUpdates = @($results | Where-Object { $_.UpdateState -in $script:PrereqStates } | Select-Object -ExpandProperty ClusterName -Unique).Count
    $totalUpdates = @($results | Where-Object { $_.UpdateName -notin @("N/A", "None", "Error") }).Count

    Write-Log -Message "" -Level Info
    Write-Log -Message "Total Clusters:              $totalClusters" -Level Info
    Write-Log -Message "Clusters with Updates:       $clustersWithUpdates" -Level $(if ($clustersWithUpdates -gt 0) { "Warning" } else { "Info" })
    Write-Log -Message "Clusters with Ready Updates: $clustersWithReadyUpdates" -Level $(if ($clustersWithReadyUpdates -gt 0) { "Success" } else { "Info" })
    if ($clustersWithPrereqUpdates -gt 0) {
        Write-Log -Message "Clusters with Prerequisite:  $clustersWithPrereqUpdates (SBE update required first)" -Level Warning
    }
    Write-Log -Message "Total Updates Found:         $totalUpdates" -Level Info

    # Show SBE dependency details for HasPrerequisite/AdditionalContentRequired updates
    $prereqUpdates = @($results | Where-Object { $_.UpdateState -in @("HasPrerequisite", "AdditionalContentRequired") -and $_.SBEDependency })
    if ($prereqUpdates.Count -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Updates Blocked by SBE Prerequisites:" -Level Warning
        foreach ($pu in $prereqUpdates) {
            Write-Log -Message "  $($pu.ClusterName) - $($pu.UpdateName): $($pu.SBEDependency)" -Level Warning
        }
    }

    # Show most common update versions
    if ($updateVersionCounts.Count -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Ready Update Versions:" -Level Header
        $sortedVersions = $updateVersionCounts.GetEnumerator() | Sort-Object -Property Value -Descending
        foreach ($version in $sortedVersions) {
            Write-Log -Message "  $($version.Key): $($version.Value) cluster(s)" -Level Info
        }
    }

    # Display results table
    Write-Log -Message "" -Level Info
    Write-Log -Message "Detailed Results:" -Level Header
    $results | Format-Table ClusterName, UpdateName, UpdateState, Version, PackageType -AutoSize | Out-Host

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
                        Timestamp             = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        TotalClusters         = $totalClusters
                        ClustersWithUpdates   = $clustersWithUpdates
                        UpdateVersionSummary  = $updateVersionCounts
                        Results               = $results
                    }
                    Write-Utf8NoBomFile -Path $ExportPath -Content ($exportData | ConvertTo-Json -Depth 10)
                    Write-Log -Message "Results exported to JSON: $ExportPath" -Level Success
                }
                'JUnitXml' {
                    $junitResults = $results | ForEach-Object {
                        [PSCustomObject]@{
                            ClusterName  = $_.ClusterName
                            Status       = if ($_.UpdateState -in $script:ReadyStates) { "Ready" } elseif ($_.UpdateState -eq "Error") { "Failed" } else { "Skipped" }
                            Message      = "Update: $($_.UpdateName), State: $($_.UpdateState), Version: $($_.Version)"
                            UpdateName   = $_.UpdateName
                            CurrentState = $_.UpdateState
                        }
                    }
                    Export-ResultsToJUnitXml -Results $junitResults -OutputPath $ExportPath `
                        -TestSuiteName "AzureLocalAvailableUpdates" -OperationType "AvailableUpdates"
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
