function Get-AzLocalClusterUpdateReadiness {
    <#
    .SYNOPSIS
        Assesses update readiness across Azure Local clusters and reports available updates.

    .DESCRIPTION
        This function queries Azure Local clusters and reports their update readiness state,
        available updates, and provides summary statistics to help plan update deployments.
        
        Output includes:
        - Which clusters are in "Ready" state for updates
        - Which updates are available for each cluster
        - Summary totals showing the most common applicable update version
        
        Results are displayed on screen and optionally exported to CSV, JSON, or JUnit XML.

    .PARAMETER ClusterNames
        An array of Azure Local cluster names to assess.

    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to assess.

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
        - .csv  = Standard CSV format
        - .json = JSON format with summary statistics
        - .xml  = JUnit XML format for CI/CD pipeline integration (Azure DevOps, GitHub Actions, Jenkins, etc.)

    .PARAMETER ExportFormat
        Export format: Auto (default - detect from extension), Csv, Json, or JUnitXml.

    .EXAMPLE
        # Assess all clusters with a specific UpdateRing tag value
        Get-AzLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Wave1"

    .EXAMPLE
        # Assess specific clusters and export to CSV
        Get-AzLocalClusterUpdateReadiness -ClusterNames @("Cluster01", "Cluster02") -ExportPath "C:\Reports\readiness.csv"

    .EXAMPLE
        # Export to JUnit XML for CI/CD pipelines
        Get-AzLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -ExportPath "C:\Reports\readiness.xml"

    .EXAMPLE
        # Assess clusters by Resource ID
        Get-AzLocalClusterUpdateReadiness -ClusterResourceIds @("/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01")

    .NOTES
        Author: Neil Bird, Microsoft.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([PSCustomObject[]])]
    param(
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

        [Parameter(Mandatory = $false)]
        [string]$ExportPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Auto', 'Csv', 'Json', 'JUnitXml')]
        [string]$ExportFormat = 'Auto',

        # v0.9.1: when supplied, an apply-updates schedule (schema v2) constrains
        # which update versions each cluster's ring is allowed to install. The
        # readiness calc is recomputed using ONLY the allow-listed Ready updates
        # (per-ring 'allowedUpdateVersions' override beats the top-level fleet
        # default; 'Latest' alone means no constraint). A cluster whose Ready
        # updates are all outside its allow-list is reported as UpToDate.
        [Parameter(Mandatory = $false)]
        [string]$SchedulePath,

        # v0.9.1: direct fleet-wide allow-list (bypasses -SchedulePath / per-ring
        # resolution). Same matching semantics - 'Latest' alone disables the
        # filter. Useful for ad-hoc assessments without a schedule file.
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$AllowedUpdateVersions,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Pre-flight: Validate export path is writable before expensive operations
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

    # Ensure resource-graph extension is installed (single-callsite for all
    # parameter sets - the readiness cmdlet is fully ARG-driven from v0.7.68).
    if (-not (Install-AzGraphExtension)) {
        Write-Error "Failed to install Azure CLI 'resource-graph' extension. Please install manually: az extension add --name resource-graph"
        return
    }

    # v0.9.1: load the apply-updates schedule once (schema v2 allow-list). The
    # per-cluster effective allow-list is resolved later from each cluster's
    # UpdateRing tag via Resolve-AzLocalClusterAllowList.
    $scheduleCfg = $null
    if ($SchedulePath) {
        try {
            $scheduleCfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $SchedulePath
            Write-Log -Message "Loaded apply-updates schedule allow-list from '$SchedulePath' (schema v$($scheduleCfg.SchemaVersion))." -Level Info
        }
        catch {
            Write-Log -Message "Failed to load schedule '$SchedulePath': $($_.Exception.Message)" -Level Error
            return
        }
    }

    # Direct fleet-wide allow-list (used when -SchedulePath is not supplied).
    $flatAllowList = @()
    if ($AllowedUpdateVersions) {
        $flatAllowList = @($AllowedUpdateVersions | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    $flatIsLatest = ($flatAllowList.Count -gt 0) -and -not (@($flatAllowList | Where-Object {
        -not [string]::Equals([string]$_, 'Latest', [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0)

    # Build list of clusters to process
    $clustersToProcess = @()

    if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
        Write-Log -Message "Querying Azure Resource Graph for clusters with tag 'UpdateRing' = '$UpdateRingValue'..." -Level Info

        # Build Azure Resource Graph query - use single line to avoid escaping issues with az CLI.
        # v0.7.68: project the full `properties` bag and `tags` so the downstream
        # readiness computation can read status / connectivityStatus / tags without
        # an additional ARM REST round trip per cluster.
        $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $ringFilter | project id, name, resourceGroup, subscriptionId, tags, properties"

        try {
            $argParams = @{ Query = $argQuery }
            if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
            $clusterRows = Invoke-AzResourceGraphQuery @argParams

            if (-not $clusterRows -or $clusterRows.Count -eq 0) {
                Write-Log -Message "No clusters found with tag 'UpdateRing' = '$UpdateRingValue'" -Level Warning
                return
            }

            Write-Log -Message "Found $($clusterRows.Count) cluster(s) matching tag criteria" -Level Success
            foreach ($cluster in $clusterRows) {
                $clustersToProcess += @{
                    ResourceId     = $cluster.id
                    Name           = $cluster.name
                    ResourceGroup  = $cluster.resourceGroup
                    SubscriptionId = $cluster.subscriptionId
                    Tags           = $cluster.tags
                    Properties     = $cluster.properties
                    NotFound       = $false
                }
            }
        }
        catch {
            Write-Log -Message "Error querying Azure Resource Graph: $_" -Level Error
            return
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
        # v0.7.68: resolve every supplied ResourceId with a single ARG batch
        # lookup so we can pick up tags and properties (status / connectivityStatus)
        # in one round trip, mirroring the ByTag projection.
        $argQueryTemplate = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where tolower(id) in~ ({0}) | project id, name, resourceGroup, subscriptionId, tags, properties"
        try {
            $batchParams = @{ Value = $ClusterResourceIds; QueryTemplate = $argQueryTemplate }
            if ($SubscriptionId) { $batchParams['SubscriptionId'] = $SubscriptionId }
            $clusterRows = Invoke-AzLocalResourceGraphValueBatches @batchParams
        }
        catch {
            Write-Log -Message "Error resolving cluster resource IDs via Azure Resource Graph: $_" -Level Error
            return
        }

        $foundIds = @{}
        foreach ($cluster in @($clusterRows)) {
            $foundIds[$cluster.id.ToLower()] = $cluster
        }
        foreach ($resourceId in $ClusterResourceIds) {
            $key = $resourceId.ToLower()
            if ($foundIds.ContainsKey($key)) {
                $cluster = $foundIds[$key]
                $clustersToProcess += @{
                    ResourceId     = $cluster.id
                    Name           = $cluster.name
                    ResourceGroup  = $cluster.resourceGroup
                    SubscriptionId = $cluster.subscriptionId
                    Tags           = $cluster.tags
                    Properties     = $cluster.properties
                    NotFound       = $false
                }
            }
            else {
                $clusterRgName = ($resourceId -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                $clusterSubId = ($resourceId -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                $clustersToProcess += @{
                    ResourceId     = $resourceId
                    Name           = ($resourceId -split '/')[-1]
                    ResourceGroup  = $clusterRgName
                    SubscriptionId = $clusterSubId
                    Tags           = $null
                    Properties     = $null
                    NotFound       = $true
                }
            }
        }
    }
    else {
        # ByName - resolve names to resource IDs via a single ARG batch lookup
        # (v0.7.68). Replaces the previous per-name Get-AzLocalClusterInfo
        # ARM REST loop.
        $rgFilter = ''
        if ($ResourceGroupName) {
            $rgFilter = "| where tolower(resourceGroup) =~ '$($ResourceGroupName.ToLower())'"
        }
        $argQueryTemplate = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where tolower(name) in~ ({0}) $rgFilter | project id, name, resourceGroup, subscriptionId, tags, properties"
        try {
            $batchParams = @{ Value = $ClusterNames; QueryTemplate = $argQueryTemplate }
            if ($SubscriptionId) { $batchParams['SubscriptionId'] = $SubscriptionId }
            $clusterRows = Invoke-AzLocalResourceGraphValueBatches @batchParams
        }
        catch {
            Write-Log -Message "Error resolving cluster names via Azure Resource Graph: $_" -Level Error
            return
        }

        $foundNames = @{}
        foreach ($cluster in @($clusterRows)) {
            $foundNames[$cluster.name.ToLower()] = $cluster
        }
        foreach ($name in $ClusterNames) {
            $key = $name.ToLower()
            if ($foundNames.ContainsKey($key)) {
                $cluster = $foundNames[$key]
                $clustersToProcess += @{
                    ResourceId     = $cluster.id
                    Name           = $cluster.name
                    ResourceGroup  = $cluster.resourceGroup
                    SubscriptionId = $cluster.subscriptionId
                    Tags           = $cluster.tags
                    Properties     = $cluster.properties
                    NotFound       = $false
                }
            }
            else {
                Write-Log -Message "Cluster '$name' not found - skipping" -Level Warning
            }
        }
    }

    if (-not $clustersToProcess -or $clustersToProcess.Count -eq 0) {
        Write-Log -Message "No clusters resolved for readiness assessment." -Level Warning
        return
    }

    Write-Log -Message "" -Level Info
    Write-Log -Message "Assessing $($clustersToProcess.Count) cluster(s)..." -Level Info
    Write-Log -Message "" -Level Info

    # Collect results
    # Use Generic.List to avoid the O(n^2) cost of += array growth at fleet scale.
    $results = [System.Collections.Generic.List[object]]::new()
    $updateVersionCounts = @{}

    # Per-cluster readiness computation - v0.7.68 ARG-first design.
    #
    # The pre-0.7.68 implementation fanned out to Start-Job workers; each job
    # made three ARM REST calls per cluster (cluster GET, updateSummaries GET,
    # updates GET), yielding 3N round trips and significant runspace overhead
    # on fleets of dozens of clusters. The current design issues two batched
    # Azure Resource Graph queries (updatesummaries + updates) against every
    # input cluster in one round trip each - the cluster resource itself was
    # already pulled into $clustersToProcess during discovery - and then runs
    # the readiness/recommendation logic inline against the cached data. No
    # background jobs, no -ThrottleLimit knob.

    # ARG #1: update summaries in the effective subscription/management-group
    # scope. Do not embed every cluster ID in the KQL: at 2,000 clusters that
    # exceeds the Windows az.cmd command-line limit. Downstream indexing keeps
    # only rows for $clustersToProcess.
    $summariesKql = "extensibilityresources | where type =~ 'microsoft.azurestackhci/clusters/updatesummaries' | extend ids = split(id, '/') | extend ClusterResourceId_ = tolower(strcat('/subscriptions/', tostring(ids[2]), '/resourceGroups/', tostring(ids[4]), '/providers/Microsoft.AzureStackHCI/clusters/', tostring(ids[8]))) | project id, name, properties, ClusterResourceId_"
    try {
        $argParams = @{ Query = $summariesKql }
        if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
        $summaryRows = Invoke-AzResourceGraphQuery @argParams
    }
    catch {
        Write-Log -Message "Azure Resource Graph query for update summaries failed: $($_.Exception.Message)" -Level Error
        return
    }
    Write-Log -Message "Returned $(@($summaryRows).Count) update-summary record(s) via Azure Resource Graph" -Level Success

    # ARG #2: per-cluster available updates.
    $updatesKql = "extensibilityresources | where type =~ 'microsoft.azurestackhci/clusters/updates' | extend ids = split(id, '/') | extend ClusterName_ = tostring(ids[8]), UpdateName_ = tostring(ids[10]) | extend ClusterResourceId_ = tolower(strcat('/subscriptions/', tostring(ids[2]), '/resourceGroups/', tostring(ids[4]), '/providers/Microsoft.AzureStackHCI/clusters/', ClusterName_)) | project name, properties, ClusterResourceId_, UpdateName_"
    try {
        $argParams = @{ Query = $updatesKql }
        if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
        $updateRows = Invoke-AzResourceGraphQuery @argParams
    }
    catch {
        Write-Log -Message "Azure Resource Graph query for available updates failed: $($_.Exception.Message)" -Level Error
        return
    }
    Write-Log -Message "Returned $(@($updateRows).Count) available-update record(s) across $($clustersToProcess.Count) cluster(s) via Azure Resource Graph" -Level Success

    # Index update summaries by lowercased cluster id (one summary per cluster).
    $summaryByCluster = @{}
    foreach ($row in @($summaryRows)) {
        $summaryByCluster[[string]$row.ClusterResourceId_] = $row
    }

    # Index available-update rows by lowercased cluster id (N updates per cluster).
    $updatesByCluster = @{}
    foreach ($row in @($updateRows)) {
        $key = [string]$row.ClusterResourceId_
        if (-not $updatesByCluster.ContainsKey($key)) { $updatesByCluster[$key] = [System.Collections.Generic.List[object]]::new() }
        $updatesByCluster[$key].Add($row) | Out-Null
    }

    # Synthesise a fake ARM-shaped updateSummary object so the existing
    # Get-HealthCheckFailureSummary helper (which reads .properties.healthCheckResult)
    # keeps working without modification.
    foreach ($cluster in $clustersToProcess) {
        $clusterName = $cluster.Name
        $key = $cluster.ResourceId.ToLower()

        Write-Host "  Checking: $clusterName..." -ForegroundColor Gray -NoNewline

        if ($cluster.NotFound) {
            Write-Host ' Not Found' -ForegroundColor Red
            $results.Add([PSCustomObject]@{
                    ClusterName            = $clusterName
                    ClusterResourceId      = $cluster.ResourceId
                    ResourceGroup          = $cluster.ResourceGroup
                    SubscriptionId         = $cluster.SubscriptionId
                    UpdateRing             = ''
                    ClusterState           = 'Not Found'
                    UpdateState            = 'N/A'
                    HealthState            = 'N/A'
                    CurrentVersion         = ''
                    CurrentSbeVersion      = ''
                    SbeOemProvider         = 'Unknown'
                    ReadyForUpdate         = $false
                    AllAvailableUpdates    = ''
                    ReadyUpdates           = ''
                    HasPrerequisiteUpdates = ''
                    SBEDependency          = ''
                    RecommendedUpdate      = ''
                    HealthCheckFailures    = ''
                    BlockingReasons        = ''
                    UpdateStartWindow           = ''
                    UpdateExclusionsWindow = ''
                    LastUpdated            = ''
                    StatusLastChecked      = ''
                    AllowedUpdateVersions  = ''
                    AllowListSource        = 'None'
                    AllowListSuppressedUpdates = ''
                    AzureUpdateState       = 'N/A'
                }) | Out-Null
            continue
        }

        try {
            $clusterProps = $cluster.Properties
            $clusterTags = $cluster.Tags

            $summaryRow = if ($summaryByCluster.ContainsKey($key)) { $summaryByCluster[$key] } else { $null }
            $sumProps = if ($summaryRow) { $summaryRow.properties } else { $null }

            $availableUpdates = @()
            if ($updatesByCluster.ContainsKey($key)) { $availableUpdates = @($updatesByCluster[$key]) }

            $updateState = if ($sumProps -and $sumProps.state) { [string]$sumProps.state } else { 'Unknown' }

            $readyUpdates = @($availableUpdates | Where-Object { $_.properties.state -in $script:ReadyStates })
            $prereqUpdates = @($availableUpdates | Where-Object { $_.properties.state -in $script:PrereqStates })

            # Build legacy ARM-shaped update objects with a .name property so
            # Get-LatestUpdateByYYMM (which sorts on .name parsing) keeps working.
            $availableUpdateNames = ($availableUpdates | ForEach-Object { [string]$_.UpdateName_ }) -join '; '
            $readyUpdateNames = ($readyUpdates | ForEach-Object { [string]$_.UpdateName_ }) -join '; '
            $prereqUpdateNames = ($prereqUpdates | ForEach-Object { [string]$_.UpdateName_ }) -join '; '

            # SBE dependency surface from prereq SBE updates (unchanged business rule).
            $sbeDependencyInfo = ''
            foreach ($pu in $prereqUpdates) {
                $puProps = $pu.properties
                $puPkgType = if ($puProps.PSObject.Properties['packageType'] -and $puProps.packageType) { $puProps.packageType } else { '' }
                $puAddl = if ($puProps.PSObject.Properties['additionalProperties']) { $puProps.additionalProperties } else { $null }
                if ($puPkgType -eq 'SBE' -and $puAddl) {
                    $addProps = ConvertTo-AzLocalAdditionalProperties -InputObject $puAddl
                    if ($addProps) {
                        $sbeParts = @()
                        if ($addProps.SBEPublisher) { $sbeParts += "Publisher: $($addProps.SBEPublisher)" }
                        if ($addProps.SBEFamily) { $sbeParts += "Family: $($addProps.SBEFamily)" }
                        if ($sbeParts.Count -gt 0) { $sbeDependencyInfo = "$([string]$pu.UpdateName_): $($sbeParts -join '; ')" }
                    }
                }
            }

            # Recommended update selection - identical to legacy logic but takes
            # ARG-shaped objects. Get-LatestUpdateByYYMM accepts any object with
            # a .name property; we wrap each row so .name aligns with UpdateName_.
            $wrapForLatest = {
                param($rows)
                @($rows | ForEach-Object {
                        [PSCustomObject]@{
                            name       = [string]$_.UpdateName_
                            properties = $_.properties
                        }
                    })
            }

            # v0.9.1: allow-list override. Resolve the effective allow-list for
            # this cluster (per-ring schedule override -> top-level fleet default,
            # or the direct -AllowedUpdateVersions list), then recompute readiness
            # using ONLY the allow-listed Ready updates. The full Ready list is
            # preserved in the ReadyUpdates column; RecommendedUpdate / ReadyForUpdate
            # reflect the constrained view. A cluster whose Ready updates are all
            # outside its allow-list is reported UpToDate (no action under schedule).
            $rawUpdateState          = $updateState
            $allowListDisplay        = ''
            $allowListSource         = 'None'
            $scheduleSuppressedReady = $false
            # v0.9.19: names of the Ready updates the allow-list filtered OUT for
            # this cluster (';'-joined). Fleet-aggregated by the readiness report
            # into the "Updates filtered out by the allow-list" table so operators
            # can see which updates to add to apply-updates-schedule.yml.
            $suppressedReadyNames    = ''
            $effectiveAllowList      = @()
            if ($scheduleCfg) {
                $clusterRing = if ($clusterTags) { Get-TagValue -Tags $clusterTags -Name 'UpdateRing' } else { $null }
                $resolvedAllow = Resolve-AzLocalClusterAllowList -UpdateRing $clusterRing -Schedule $scheduleCfg
                $effectiveAllowList = @($resolvedAllow.EffectiveAllowList)
                if ($effectiveAllowList.Count -eq 0) {
                    $allowListSource = 'None'
                }
                elseif ($resolvedAllow.IsLatest) {
                    $allowListSource = 'Latest'
                }
                else {
                    $allowListSource = $resolvedAllow.Source
                }
            }
            elseif ($flatAllowList.Count -gt 0) {
                $effectiveAllowList = $flatAllowList
                $allowListSource = if ($flatIsLatest) { 'Latest' } else { 'Explicit' }
            }
            if ($effectiveAllowList.Count -gt 0) {
                $allowListDisplay = ($effectiveAllowList -join '; ')
            }

            $constraintActive = ($allowListSource -in @('RowOverride', 'TopLevel', 'Explicit'))
            if ($constraintActive -and $readyUpdates.Count -gt 0) {
                $allowSelection = Select-AzLocalNextUpdateForCluster `
                    -ReadyUpdates (& $wrapForLatest $readyUpdates) `
                    -AllowedUpdateVersions $effectiveAllowList
                $allowedNameSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($f in @($allowSelection.FilteredUpdates)) {
                    if ($f -and $f.name) { [void]$allowedNameSet.Add([string]$f.name) }
                }
                $filteredReady = @($readyUpdates | Where-Object { $allowedNameSet.Contains([string]$_.UpdateName_) })
                # v0.9.19: capture the Ready updates the allow-list removed BEFORE
                # $readyUpdates is narrowed to the allowed subset.
                $suppressedReady = @($readyUpdates |
                    Where-Object { -not $allowedNameSet.Contains([string]$_.UpdateName_) } |
                    ForEach-Object { [string]$_.UpdateName_ })
                if ($suppressedReady.Count -gt 0) { $suppressedReadyNames = ($suppressedReady -join '; ') }
                if ($filteredReady.Count -eq 0) { $scheduleSuppressedReady = $true }
                $readyUpdates = $filteredReady
            }

            $recommendedUpdate = ''
            $counted = $null
            $isUpToDateState = $updateState -in @('UpToDate', 'AppliedSuccessfully')
            $allInstalled = ($availableUpdates.Count -gt 0) -and `
                -not ($availableUpdates | Where-Object { $_.properties.state -ne 'Installed' })
            if ($readyUpdates.Count -gt 0) {
                $latestReady = Get-LatestUpdateByYYMM -Updates (& $wrapForLatest $readyUpdates)
                $recommendedUpdate = $latestReady.name
                $counted = $recommendedUpdate
            }
            elseif (-not $isUpToDateState -and -not $allInstalled -and -not $scheduleSuppressedReady -and $availableUpdates.Count -gt 0) {
                $nonInstalled = @($availableUpdates | Where-Object { $_.properties.state -ne 'Installed' })
                if ($nonInstalled.Count -gt 0) {
                    $latestAvailable = Get-LatestUpdateByYYMM -Updates (& $wrapForLatest $nonInstalled)
                    $recommendedUpdate = $latestAvailable.name
                }
            }

            $isReady = ($updateState -in (@('UpdateAvailable') + $script:ReadyStates)) -and ($readyUpdates.Count -gt 0)

            # Health state + failure summary - re-use the existing helper by
            # passing the ARG-shaped summary row (it reads .properties.healthCheckResult
            # which is identical shape via ARG).
            $healthState = if ($sumProps -and $sumProps.healthState) { [string]$sumProps.healthState } else { 'Unknown' }
            $healthCheckFailures = ''
            if ($summaryRow -and $healthState -notin @('Success', 'Unknown')) {
                $healthCheckFailures = Get-HealthCheckFailureSummary -UpdateSummary $summaryRow
            }

            # Readiness gates (unchanged).
            $blockingReasons = @()
            if ($healthCheckFailures -and ($healthCheckFailures -match '\[Critical\]')) {
                $blockingReasons += 'CriticalHealthCheck'
            }
            $clusterStatus = if ($clusterProps -and $clusterProps.PSObject.Properties['status']) { [string]$clusterProps.status } else { '' }
            if ($clusterStatus -and $clusterStatus -ne 'ConnectedRecently') {
                $blockingReasons += $clusterStatus
            }
            if ($isReady -and $blockingReasons.Count -gt 0) {
                $isReady = $false
                $counted = $null
            }

            # v0.9.1: a cluster whose Ready updates were ALL filtered out by the
            # allow-list (and is otherwise unblocked / not prereq-gated) is
            # reported UpToDate - there is no action to take under the schedule.
            # The raw Azure update-summary state is preserved in AzureUpdateState.
            $scheduleConstrainedUpToDate = $scheduleSuppressedReady -and
                ($blockingReasons.Count -eq 0) -and
                ($prereqUpdates.Count -eq 0) -and
                ($rawUpdateState -notin @('UpdateInProgress', 'PreparationInProgress', 'Failed', 'UpdateFailed', 'NeedsAttention', 'PreparationFailed'))
            $rowUpdateState = if ($scheduleConstrainedUpToDate) { 'UpToDate' } else { $updateState }

            # v0.9.20: hardware OEM provider (Dell / HPE / Lenovo / Microsoft / ...)
            # resolved from the cluster's reported node manufacturer. Monitor: 3 groups
            # the SBE version distribution by this vendor - including clusters running
            # the base placeholder SBE (2.0.0.0 / 2.1.0.0) that have no vendor SBE.
            $sbeOemProvider = 'Unknown'
            if ($clusterProps -and $clusterProps.PSObject.Properties['reportedProperties'] -and $clusterProps.reportedProperties) {
                $reportedProps = $clusterProps.reportedProperties
                if ($reportedProps.PSObject.Properties['nodes'] -and $reportedProps.nodes) {
                    $nodeManufacturers = @($reportedProps.nodes | ForEach-Object {
                        if ($_ -and $_.PSObject.Properties['manufacturer'] -and $_.manufacturer) { [string]$_.manufacturer } else { $null }
                    } | Where-Object { $_ })
                    if ($nodeManufacturers.Count -gt 0) {
                        $sbeOemProvider = Resolve-AzLocalHardwareOem -Manufacturer $nodeManufacturers[0]
                    }
                }
            }

            # Installed versions (Solution + SBE) from updateSummary.
            $currentVersion = ''
            $currentSbeVersion = ''
            # v0.8.82: most-recent packageVersions[].lastUpdated across ALL packageTypes
            # (Solution AND SBE AND services) - operator-facing "Last Updated" column.
            $lastUpdated = ''
            # v0.9.19: the updateSummary's own lastChecked timestamp - i.e. WHEN Azure
            # last scanned this cluster for update availability. This is the freshness
            # signal operators need: the readiness assessment reads Azure's cached
            # per-cluster state, so if lastChecked is stale a newly-released update
            # will NOT yet show as Ready even though the portal catalog lists it (and a
            # since-resolved SBE prerequisite may still read as blocked). ARG exposes it
            # as 'lastChecked'; the single-cluster ARM shape uses 'lastCheckedTime'.
            $statusLastChecked = ''
            if ($sumProps) {
                $rawLastChecked = if ($sumProps.PSObject.Properties['lastChecked'] -and $sumProps.lastChecked) {
                    [string]$sumProps.lastChecked
                }
                elseif ($sumProps.PSObject.Properties['lastCheckedTime'] -and $sumProps.lastCheckedTime) {
                    [string]$sumProps.lastCheckedTime
                }
                else { '' }
                if ($rawLastChecked) {
                    try { $statusLastChecked = ([datetime]$rawLastChecked).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
                    catch { $statusLastChecked = $rawLastChecked }
                }
                if ($sumProps.PSObject.Properties['currentVersion']) {
                    $currentVersion = [string]$sumProps.currentVersion
                }
                if ($sumProps.PSObject.Properties['packageVersions'] -and $sumProps.packageVersions) {
                    $sbePkgs = @($sumProps.packageVersions | Where-Object { $_.packageType -eq 'SBE' -and $_.version })
                    if ($sbePkgs.Count -gt 0) {
                        $latestSbe = $sbePkgs |
                            Sort-Object -Property @{
                                Expression = {
                                    if ($_.PSObject.Properties['lastUpdated'] -and $_.lastUpdated) {
                                        try { [datetime]$_.lastUpdated } catch { [datetime]::MinValue }
                                    } else { [datetime]::MinValue }
                                }
                            }, @{
                                Expression = {
                                    try { [version]($_.version -replace '[^0-9.]', '') } catch { [version]'0.0.0.0' }
                                }
                            } -Descending |
                            Select-Object -First 1
                        if ($latestSbe -and $latestSbe.version) {
                            $currentSbeVersion = [string]$latestSbe.version
                        }
                    }
                    # Pull the most-recent lastUpdated across every package row
                    # (Solution, SBE, services). Use ISO-8601 round-trip format
                    # so the markdown/CSV/JSON outputs are timezone-unambiguous.
                    $stamps = @($sumProps.packageVersions |
                        Where-Object { $_.PSObject.Properties['lastUpdated'] -and $_.lastUpdated } |
                        ForEach-Object {
                            try { [datetime]$_.lastUpdated } catch { $null }
                        } | Where-Object { $_ })
                    if ($stamps.Count -gt 0) {
                        $maxStamp = ($stamps | Sort-Object -Descending | Select-Object -First 1)
                        $lastUpdated = $maxStamp.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                    }
                }
            }

            # Coloured per-cluster status line.
            if ($blockingReasons.Count -gt 0) {
                Write-Host " Blocked ($($blockingReasons -join ','))" -ForegroundColor Red
            }
            elseif ($isReady) {
                Write-Host " Ready ($recommendedUpdate)" -ForegroundColor Green
            }
            elseif ($allInstalled) {
                Write-Host ' UpToDate' -ForegroundColor Gray
            }
            elseif ($scheduleConstrainedUpToDate) {
                Write-Host ' UpToDate (schedule allow-list - no allowed update ready)' -ForegroundColor Gray
            }
            elseif ($prereqUpdates.Count -gt 0 -and $readyUpdates.Count -eq 0) {
                Write-Host ' Has Prerequisite (SBE update required)' -ForegroundColor Yellow
            }
            elseif ($updateState -eq 'UpdateInProgress') {
                Write-Host ' Update In Progress' -ForegroundColor Yellow
            }
            elseif ($readyUpdates.Count -eq 0 -and $availableUpdates.Count -gt 0) {
                Write-Host ' Updates Downloading' -ForegroundColor Yellow
            }
            elseif ($healthState -in @('Failure', 'Warning')) {
                $c = if ($healthState -eq 'Failure') { 'Red' } else { 'Yellow' }
                Write-Host " $updateState ($healthState)" -ForegroundColor $c
            }
            else {
                Write-Host " $updateState" -ForegroundColor Gray
            }

            # Tally only non-blocked ready recommendations.
            if ($counted) {
                if ($updateVersionCounts.ContainsKey($counted)) { $updateVersionCounts[$counted]++ }
                else { $updateVersionCounts[$counted] = 1 }
            }

            $uw = if ($clusterTags) { Get-TagValue -Tags $clusterTags -Name $script:UpdateStartWindowTagName } else { $null }
            $ue = if ($clusterTags) { Get-TagValue -Tags $clusterTags -Name $script:UpdateExclusionsWindowTagName } else { $null }
            # v0.9.17: surface each cluster's own UpdateRing tag so the readiness
            # table / CSV can show WHICH ring a cluster belongs to (the gate can be
            # scoped to a ';'-joined multi-ring value, e.g. 'Prod;Ring2').
            $clusterUpdateRing = if ($clusterTags) { Get-TagValue -Tags $clusterTags -Name 'UpdateRing' } else { $null }

            $results.Add([PSCustomObject]@{
                    ClusterName            = $clusterName
                    ClusterResourceId      = $cluster.ResourceId
                    ResourceGroup          = $cluster.ResourceGroup
                    SubscriptionId         = $cluster.SubscriptionId
                    UpdateRing             = if ($clusterUpdateRing) { $clusterUpdateRing } else { '' }
                    ClusterState           = $clusterStatus
                    UpdateState            = $rowUpdateState
                    HealthState            = $healthState
                    CurrentVersion         = $currentVersion
                    CurrentSbeVersion      = $currentSbeVersion
                    SbeOemProvider         = $sbeOemProvider
                    ReadyForUpdate         = $isReady
                    AllAvailableUpdates    = $availableUpdateNames
                    ReadyUpdates           = $readyUpdateNames
                    HasPrerequisiteUpdates = $prereqUpdateNames
                    SBEDependency          = $sbeDependencyInfo
                    RecommendedUpdate      = $recommendedUpdate
                    HealthCheckFailures    = $healthCheckFailures
                    BlockingReasons        = ($blockingReasons -join '; ')
                    UpdateStartWindow      = if ($uw) { $uw } else { '' }
                    UpdateExclusionsWindow = if ($ue) { $ue } else { '' }
                    LastUpdated            = $lastUpdated
                    StatusLastChecked      = $statusLastChecked
                    AllowedUpdateVersions  = $allowListDisplay
                    AllowListSource        = $allowListSource
                    AllowListSuppressedUpdates = $suppressedReadyNames
                    AzureUpdateState       = $rawUpdateState
                }) | Out-Null
        }
        catch {
            Write-Host " Error: $($_.Exception.Message)" -ForegroundColor Red
            $results.Add([PSCustomObject]@{
                    ClusterName            = $clusterName
                    ClusterResourceId      = $cluster.ResourceId
                    ResourceGroup          = $cluster.ResourceGroup
                    SubscriptionId         = $cluster.SubscriptionId
                    UpdateRing             = ''
                    ClusterState           = 'Error'
                    UpdateState            = 'Error'
                    HealthState            = 'Error'
                    CurrentVersion         = ''
                    CurrentSbeVersion      = ''
                    SbeOemProvider         = 'Unknown'
                    ReadyForUpdate         = $false
                    AllAvailableUpdates    = ''
                    ReadyUpdates           = ''
                    HasPrerequisiteUpdates = ''
                    SBEDependency          = ''
                    RecommendedUpdate      = ''
                    HealthCheckFailures    = $_.Exception.Message
                    BlockingReasons        = ''
                    UpdateStartWindow      = ''
                    UpdateExclusionsWindow = ''
                    LastUpdated            = ''
                    StatusLastChecked      = ''
                    AllowedUpdateVersions  = ''
                    AllowListSource        = 'None'
                    AllowListSuppressedUpdates = ''
                    AzureUpdateState       = 'Error'
                }) | Out-Null
        }
    }

    # Display Summary
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Summary" -Level Header
    Write-Log -Message "========================================" -Level Header
    
    $totalClusters = $results.Count
    $readyForUpdateClusters = @($results | Where-Object { $_.ReadyForUpdate -eq $true }).Count
    # v0.7.99: UpToDate is now its own bucket (was previously rolled into NotReady).
    # v0.8.74: classification uses the shared Get-AzLocalClusterReadinessStatus
    # priority cascade (identical to Step.5 / Step.7 / Step.9). The previous strict
    # IsNullOrEmpty(AllAvailableUpdates) test silently returned zero because a
    # cluster that has applied all updates still lists the already-installed
    # packages in AllAvailableUpdates - so up-to-date clusters were mis-counted
    # into the catch-all NotReady total even though no action was required.
    $upToDateClusters = @($results | Where-Object { (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'UpToDate' }).Count
    $notReadyForUpdateClusters = $totalClusters - $readyForUpdateClusters - $upToDateClusters
    $inProgressClusters = @($results | Where-Object { $_.UpdateState -eq "UpdateInProgress" }).Count
    $prereqClusters = @($results | Where-Object { $_.HasPrerequisiteUpdates -ne "" }).Count
    $blockedClusters = @($results | Where-Object { $_.PSObject.Properties['BlockingReasons'] -and $_.BlockingReasons -ne "" }).Count

    Write-Log -Message "" -Level Info
    Write-Log -Message "Total Clusters Assessed:    $totalClusters" -Level Info
    Write-Log -Message "Ready for Update:           $readyForUpdateClusters" -Level Success
    Write-Log -Message "Up to Date:                 $upToDateClusters" -Level $(if ($upToDateClusters -gt 0) { 'Success' } else { 'Info' })
    Write-Log -Message "Not Ready for Update:       $notReadyForUpdateClusters" -Level $(if ($notReadyForUpdateClusters -gt 0) { "Warning" } else { "Info" })
    Write-Log -Message "Update In Progress:         $inProgressClusters" -Level $(if ($inProgressClusters -gt 0) { "Warning" } else { "Info" })
    if ($blockedClusters -gt 0) {
        Write-Log -Message "Blocked by Readiness Gate:  $blockedClusters (see BlockingReasons column)" -Level Error
    }
    if ($prereqClusters -gt 0) {
        Write-Log -Message "Blocked by SBE Prereq:     $prereqClusters" -Level Warning
    }
    
    # Show SBE dependency details for clusters with HasPrerequisite updates
    $clustersWithSBEDeps = @($results | Where-Object { $_.SBEDependency -ne "" })
    if ($clustersWithSBEDeps.Count -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Clusters Blocked by SBE Prerequisites:" -Level Warning
        Write-Log -Message "  These clusters have updates that require a Solution Builder Extension (SBE) update from the hardware vendor before they can proceed." -Level Warning
        foreach ($dep in $clustersWithSBEDeps) {
            Write-Log -Message "  $($dep.ClusterName): $($dep.SBEDependency)" -Level Warning
        }
    }

    # Show health state breakdown
    $healthFailures = @($results | Where-Object { $_.HealthState -eq "Failure" }).Count
    $healthWarnings = @($results | Where-Object { $_.HealthState -eq "Warning" }).Count
    if ($healthFailures -gt 0 -or $healthWarnings -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Health Check Issues:" -Level Header
        if ($healthFailures -gt 0) {
            Write-Log -Message "  Critical Failures:        $healthFailures" -Level Error
        }
        if ($healthWarnings -gt 0) {
            Write-Log -Message "  Warnings:                 $healthWarnings" -Level Warning
        }
    }

    # Show most common update versions
    if ($updateVersionCounts.Count -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Available Update Versions (clusters ready to install):" -Level Header
        $sortedVersions = $updateVersionCounts.GetEnumerator() | Sort-Object -Property Value -Descending
        foreach ($version in $sortedVersions) {
            if ($readyForUpdateClusters -gt 0) {
                $percentage = [math]::Round(($version.Value / $readyForUpdateClusters) * 100, 1)
                Write-Log -Message "  $($version.Key): $($version.Value) cluster(s) ($percentage%)" -Level Info
            }
            else {
                Write-Log -Message "  $($version.Key): $($version.Value) cluster(s)" -Level Info
            }
        }
        
        $mostCommonVersion = ($sortedVersions | Select-Object -First 1).Key
        Write-Log -Message "" -Level Info
        Write-Log -Message "Most Common Applicable Update: $mostCommonVersion" -Level Success
    }

    # Display results table
    Write-Log -Message "" -Level Info
    Write-Log -Message "Detailed Results:" -Level Header
    $results | Format-Table ClusterName, ResourceGroup, CurrentVersion, UpdateState, HealthState, ReadyForUpdate, RecommendedUpdate -AutoSize | Out-Host

    # v0.9.14: allow-list mismatch callout. A cluster that reports 'Up to Date'
    # while Azure DOES have Ready updates (ReadyUpdates non-empty) can ONLY be in
    # that state because an active allowedUpdateVersions allow-list filtered every
    # Ready update out. That is indistinguishable from a genuinely up-to-date
    # cluster in the table above, so surface the excluded updates explicitly -
    # the operator can copy the exact name/version straight into the YML.
    $allowListSuppressed = @($results | Where-Object {
            $_.PSObject.Properties['AllowListSource'] -and $_.AllowListSource -and $_.AllowListSource -ne 'None' -and
            $_.PSObject.Properties['ReadyUpdates'] -and $_.ReadyUpdates -and ([string]$_.ReadyUpdates).Trim() -ne '' -and
            (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'UpToDate'
        })
    if ($allowListSuppressed.Count -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Allow-list mismatches (updates available but not allow-listed):" -Level Warning
        Write-Log -Message "  These clusters report 'Up to Date' ONLY because their allowedUpdateVersions filtered out every Ready update. Add one of the listed name/version values to the YML to let them proceed." -Level Warning
        foreach ($suppressed in $allowListSuppressed) {
            $effectiveAllow = if ($suppressed.PSObject.Properties['AllowedUpdateVersions'] -and $suppressed.AllowedUpdateVersions) { [string]$suppressed.AllowedUpdateVersions } else { '(none)' }
            Write-Log -Message "  $($suppressed.ClusterName): allow-list [$effectiveAllow] excluded available Ready update(s): $($suppressed.ReadyUpdates)" -Level Warning
        }
    }

    # Show clusters with health check failures
    $clustersWithHealthIssues = @($results | Where-Object { $_.HealthCheckFailures -ne "" })
    if ($clustersWithHealthIssues.Count -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Clusters with Health Check Issues:" -Level Warning
        foreach ($cluster in $clustersWithHealthIssues) {
            $issueLevel = if ($cluster.HealthState -eq "Failure") { "Error" } else { "Warning" }
            Write-Log -Message "  $($cluster.ClusterName): $($cluster.HealthCheckFailures)" -Level $issueLevel
        }
    }

    # Export if path specified
    if ($ExportPath) {
        try {
            $ExportPath = Resolve-SafeOutputPath -Path $ExportPath
            $exportDir = Split-Path -Path $ExportPath -Parent
            if ($exportDir -and -not (Test-Path $exportDir)) {
                New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
            }
            
            $format = Get-ExportFormat -Path $ExportPath -ExportFormat $ExportFormat
            
            # Transform results for JUnit-compatible format
            $junitResults = $results | ForEach-Object {
                $statusVal = if ($_.ReadyForUpdate -eq $true) {
                    'Ready'
                } elseif ($_.PSObject.Properties['BlockingReasons'] -and $_.BlockingReasons -ne '') {
                    'Blocked'
                } elseif ($_.HealthState -eq 'Failure') {
                    'Failed'
                } else {
                    'Skipped'
                }
                [PSCustomObject]@{
                    ClusterName  = $_.ClusterName
                    Status       = $statusVal
                    Message      = "CurrentVersion: $($_.CurrentVersion), CurrentSbeVersion: $($_.CurrentSbeVersion), UpdateState: $($_.UpdateState), HealthState: $($_.HealthState), RecommendedUpdate: $($_.RecommendedUpdate), BlockingReasons: $($_.BlockingReasons)"
                    UpdateName   = $_.RecommendedUpdate
                    CurrentState = $_.UpdateState
                }
            }
            
            switch ($format) {
                'Csv' {
                    $results | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
                    Write-Log -Message "Results exported to CSV: $ExportPath" -Level Success
                }
                'Json' {
                    $exportData = @{
                        Timestamp                  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        TotalClusters              = $totalClusters
                        ClustersReadyForUpdate     = $readyForUpdateClusters
                        ClustersUpToDate           = $upToDateClusters
                        ClustersNotReadyForUpdate  = $notReadyForUpdateClusters
                        Results                    = $results
                    }
                    Write-Utf8NoBomFile -Path $ExportPath -Content ($exportData | ConvertTo-Json -Depth 10)
                    Write-Log -Message "Results exported to JSON: $ExportPath" -Level Success
                }
                'JUnitXml' {
                    Export-ResultsToJUnitXml -Results $junitResults -OutputPath $ExportPath `
                        -TestSuiteName "AzureLocalClusterReadiness" -OperationType "ReadinessCheck"
                    Write-Log -Message "Results exported to JUnit XML (CI/CD compatible): $ExportPath" -Level Success
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
