function Get-AzLocalFleetStatusData {
    <#
    .SYNOPSIS
        Collects comprehensive fleet status data from Azure Local clusters with optional parallelism.
    
    .DESCRIPTION
        Performs a single-pass data collection across Azure Local clusters, making only 3 core API
        calls per cluster (cluster info, update summary, available updates) plus update run queries.
        
        Returns a structured PSCustomObject containing readiness, cluster details, update runs,
        and health check data. This object can be:
        - Exported to JSON for CI/CD pipeline artifact passing between jobs
        - Passed to New-AzLocalFleetStatusHtmlReport via -StatusData to avoid redundant API calls
        - Used directly for custom reporting or analysis
        
        Data collection is sequential (one cluster at a time). The previous -ThrottleLimit
        parallel-batch dispatcher was removed in v0.7.68 as part of the Azure Resource Graph
        consolidation; ARG-first read cmdlets no longer need per-cluster ARM REST fan-out.
    
    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to collect data for.
    
    .PARAMETER ClusterNames
        An array of Azure Local cluster names to collect data for.
    
    .PARAMETER ScopeByUpdateRingTag
        Find clusters by their 'UpdateRing' tag value via Azure Resource Graph.
    
    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.
    
    .PARAMETER AllClusters
        Discovers all Azure Local clusters via Azure Resource Graph (limited to 100).
    
    .PARAMETER ResourceGroupName
        Resource group containing the clusters (only used with -ClusterNames).
    
    .PARAMETER SubscriptionId
        Azure subscription ID (defaults to current subscription).
    
    .PARAMETER IncludeUpdateRuns
        Collect latest update run history per cluster.
    
    .PARAMETER IncludeHealthDetails
        Collect detailed health check failure data per cluster.
    
    .PARAMETER ExportPath
        Path to export the collected data as JSON. This JSON artifact can be passed
        between CI/CD pipeline jobs to avoid redundant API calls.
    
    .OUTPUTS
        PSCustomObject with properties: SchemaVersion, Timestamp, ModuleVersion, Scope,
        Readiness, ClusterDetails, LatestRuns, HealthResults.
    
    .EXAMPLE
        # Collect data for all clusters
        $data = Get-AzLocalFleetStatusData -AllClusters -IncludeUpdateRuns -IncludeHealthDetails
    
    .EXAMPLE
        # Export to JSON artifact for CI/CD pipeline
        Get-AzLocalFleetStatusData -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -ExportPath "fleet-data.json"
    
    .EXAMPLE
        # Collect data then generate HTML report (no redundant API calls)
        $data = Get-AzLocalFleetStatusData -AllClusters -IncludeUpdateRuns -IncludeHealthDetails
        New-AzLocalFleetStatusHtmlReport -StatusData $data -OutputPath "report.html"
    
    .EXAMPLE
        # Collect data for a specific set of clusters
        $data = Get-AzLocalFleetStatusData -ClusterResourceIds $ids
    #>
    [CmdletBinding(DefaultParameterSetName = 'All')]
    [OutputType([PSCustomObject])]
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

        [Parameter(Mandatory = $false, ParameterSetName = 'All')]
        [switch]$AllClusters,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeUpdateRuns,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeHealthDetails,

        # Optional cap on clusters returned by -AllClusters discovery.
        # Default: 0 (no cap, returns all discovered clusters). Set to a positive integer
        # to limit the number of clusters included (e.g. for testing or targeted runs).
        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100000)]
        [int]$MaxClusters = 0,

        [Parameter(Mandatory = $false)]
        [string]$ExportPath
    )

    # Pre-flight: Validate export path is writable before expensive operations
    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { Write-Warning $_.Exception.Message; return }
    }

    # Verify Azure CLI
    Test-AzCliAvailable | Out-Null
    try {
        $null = az account show 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Not logged in" }
    }
    catch {
        Write-Log -Message "Azure CLI is not logged in. Please run 'az login' first." -Level Error
        return $null
    }

    # Resolve scope to resource IDs
    $allResourceIds = @()
    $scopeDescription = ""

    switch ($PSCmdlet.ParameterSetName) {
        'ByTag' {
            if (-not (Install-AzGraphExtension)) {
                Write-Log -Message "Failed to install 'resource-graph' extension." -Level Error
                return $null
            }
            $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
            $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $ringFilter | project id"
            try {
                $tagData = Invoke-AzResourceGraphQuery -Query $argQuery
            }
            catch {
                Write-Log -Message "ARG query failed: $($_.Exception.Message)" -Level Error
                return $null
            }
            if (-not $tagData -or $tagData.Count -eq 0) { Write-Log -Message "No clusters found with UpdateRing = '$UpdateRingValue'" -Level Warning; return $null }
            $allResourceIds = @($tagData | Select-Object -ExpandProperty id)
            $scopeDescription = "UpdateRing = $UpdateRingValue"
        }
        'ByResourceId' {
            $allResourceIds = $ClusterResourceIds
            $scopeDescription = "$($ClusterResourceIds.Count) cluster(s) by Resource ID"
        }
        'ByName' {
            if (-not $SubscriptionId) { $SubscriptionId = (az account show --query id -o tsv) }
            foreach ($name in $ClusterNames) {
                $infoParams = @{ ClusterName = $name; SubscriptionId = $SubscriptionId }
                if ($ResourceGroupName) { $infoParams['ResourceGroupName'] = $ResourceGroupName }
                $ci = Get-AzLocalClusterInfo @infoParams
                if ($ci -and $ci.id) { $allResourceIds += $ci.id }
                else { Write-Log -Message "Cluster '$name' not found - skipping" -Level Warning }
            }
            $scopeDescription = "$($ClusterNames.Count) cluster(s) by name"
        }
        'All' {
            $inventory = @(Get-AzLocalClusterInventory -PassThru)
            if (-not $inventory -or $inventory.Count -eq 0) { Write-Log -Message "No clusters found." -Level Warning; return $null }
            if ($MaxClusters -gt 0 -and $inventory.Count -gt $MaxClusters) {
                Write-Log -Message "Discovered $($inventory.Count) clusters; trimming to first $MaxClusters (-MaxClusters)." -Level Warning
                $inventory = $inventory | Select-Object -First $MaxClusters
            }
            $allResourceIds = @($inventory | Select-Object -ExpandProperty ResourceId)
            $scopeDescription = "All clusters ($($allResourceIds.Count))"
        }
    }

    if ($allResourceIds.Count -eq 0) {
        Write-Log -Message "No cluster resource IDs resolved." -Level Warning
        return $null
    }

    Write-Log -Message "Collecting fleet status data for $($allResourceIds.Count) cluster(s)..." -Level Info
    $readiness = [System.Collections.Generic.List[object]]::new()
    $clusterDetails = [System.Collections.Generic.List[object]]::new()
    $latestRuns = [System.Collections.Generic.List[object]]::new()
    $healthResults = [System.Collections.Generic.List[object]]::new()
    # Track clusters whose data could not be collected (failed job / parse error)
    $failedClusters = [System.Collections.Generic.List[object]]::new()

    #--- Sequential per-cluster ARM REST collection ---
    $apiVer = $script:DefaultApiVersion
    $clusterIndex = 0
    $totalToProcess = $allResourceIds.Count

    foreach ($rid in $allResourceIds) {
        $clusterIndex++
        $clusterName = ($rid -split '/')[-1]
        $rgName = ($rid -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
        $subId = ($rid -split '/subscriptions/')[1] -split '/' | Select-Object -First 1

        Write-Host "  [$clusterIndex/$totalToProcess] $clusterName..." -ForegroundColor Gray -NoNewline

        try {
            # API Call 1/3: GET cluster info
            $clusterInfoUri = "https://management.azure.com${rid}?api-version=$apiVer"
            $clusterInfo = (Invoke-AzRestJson -Uri $clusterInfoUri).Data
            if ($LASTEXITCODE -ne 0 -or $null -eq $clusterInfo) {
                Write-Host " Not Found" -ForegroundColor Red
                $readiness.Add([PSCustomObject]@{
                    ClusterName = $clusterName; ResourceGroup = $rgName; SubscriptionId = $subId
                    ClusterState = "Not Found"; UpdateState = "N/A"; HealthState = "N/A"
                    ReadyForUpdate = $false; AllAvailableUpdates = ""; ReadyUpdates = ""
                    HasPrerequisiteUpdates = ""; SBEDependency = ""
                    RecommendedUpdate = ""; HealthCheckFailures = ""
                    BlockingReasons = ""
                    UpdateStartWindow = ""; UpdateExclusionsWindow = ""
                }) | Out-Null
                $clusterDetails.Add([PSCustomObject]@{
                    ClusterName = $clusterName; ResourceGroup = $rgName
                    CurrentVersion = "N/A"; CurrentSbeVersion = "N/A"; NodeCount = "N/A"; ResourceId = $rid
                }) | Out-Null
                continue
            }

            $clusterState = $clusterInfo.properties.status
            $nodeCount = "N/A"
            if ($clusterInfo.properties.reportedProperties.nodes) {
                $nodeCount = $clusterInfo.properties.reportedProperties.nodes.Count
            }

            # API Call 2/3: GET update summary
            $summaryUri = "https://management.azure.com${rid}/updateSummaries/default?api-version=$apiVer"
            $updateSummary = (Invoke-AzRestJson -Uri $summaryUri).Data
            $hasSummary = ($LASTEXITCODE -eq 0 -and $null -ne $updateSummary -and $null -ne $updateSummary.properties)

            $updateState = if ($hasSummary -and $updateSummary.properties.state) { $updateSummary.properties.state } else { "Unknown" }
            $healthState = if ($hasSummary -and $updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
            $currentVersion = if ($hasSummary -and $updateSummary.properties.currentVersion) { $updateSummary.properties.currentVersion } else { "N/A" }

            # SBE version lives inside properties.packageVersions[] where
            # packageType == 'SBE'; pick the newest by lastUpdated then [version].
            $currentSbeVersion = "N/A"
            if ($hasSummary -and $updateSummary.properties.PSObject.Properties['packageVersions'] -and $updateSummary.properties.packageVersions) {
                $sbePkgs = @($updateSummary.properties.packageVersions | Where-Object { $_.packageType -eq 'SBE' -and $_.version })
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
                    if ($latestSbe -and $latestSbe.version) { $currentSbeVersion = [string]$latestSbe.version }
                }
            }

            # API Call 3/3: GET available updates
            $updatesUri = "https://management.azure.com${rid}/updates?api-version=$apiVer"
            $updatesResponse = (Invoke-AzRestJson -Uri $updatesUri).Data
            $hasUpdates = ($LASTEXITCODE -eq 0 -and $null -ne $updatesResponse -and $null -ne $updatesResponse.value)
            $availableUpdates = if ($hasUpdates) { @($updatesResponse.value) } else { @() }
            $readyUpdates = @($availableUpdates | Where-Object { $_.properties.state -in $script:ReadyStates })
            $prereqUpdates = @($availableUpdates | Where-Object { $_.properties.state -in $script:PrereqStates })

            $availableUpdateNames = ($availableUpdates | ForEach-Object { $_.name }) -join "; "
            $readyUpdateNames = ($readyUpdates | ForEach-Object { $_.name }) -join "; "
            $prereqUpdateNames = ($prereqUpdates | ForEach-Object { $_.name }) -join "; "

            # Extract SBE dependency info for HasPrerequisite/AdditionalContentRequired updates
            $sbeDependencyInfo = ""
            foreach ($pu in $prereqUpdates) {
                $puProps = $pu.properties
                if ($puProps.packageType -eq "SBE" -and $puProps.additionalProperties) {
                    $addProps = ConvertTo-AzLocalAdditionalProperties -InputObject $puProps.additionalProperties
                    if ($addProps) {
                        $sbeParts = @()
                        if ($addProps.SBEPublisher) { $sbeParts += "Publisher: $($addProps.SBEPublisher)" }
                        if ($addProps.SBEFamily) { $sbeParts += "Family: $($addProps.SBEFamily)" }
                        if ($sbeParts.Count -gt 0) { $sbeDependencyInfo = "$($pu.name): $($sbeParts -join '; ')" }
                    }
                }
            }

            $recommendedUpdate = ""
            $isUpToDateState = $updateState -in @("UpToDate", "AppliedSuccessfully")
            if ($readyUpdates.Count -gt 0) {
                $latestReady = Get-LatestUpdateByYYMM -Updates $readyUpdates
                $recommendedUpdate = $latestReady.name
            }
            elseif (-not $isUpToDateState -and $availableUpdates.Count -gt 0) {
                $latestAvailable = Get-LatestUpdateByYYMM -Updates $availableUpdates
                $recommendedUpdate = $latestAvailable.name
            }
            $isReady = ($updateState -in (@("UpdateAvailable") + $script:ReadyStates)) -and ($readyUpdates.Count -gt 0)

            $healthCheckFailures = ""
            if ($hasSummary -and $healthState -notin @("Success", "Unknown")) {
                $healthCheckFailures = Get-HealthCheckFailureSummary -UpdateSummary $updateSummary
            }

            # Apply readiness gates (mirror Get-AzLocalClusterUpdateReadiness).
            $blockingReasons = @()
            if ($healthCheckFailures -and ($healthCheckFailures -match '\[Critical\]')) {
                $blockingReasons += 'CriticalHealthCheck'
            }
            if ($clusterState -and $clusterState -ne 'ConnectedRecently') {
                $blockingReasons += $clusterState
            }
            if ($isReady -and $blockingReasons.Count -gt 0) {
                $isReady = $false
            }

            $readiness.Add([PSCustomObject]@{
                ClusterName = $clusterName; ResourceGroup = $rgName; SubscriptionId = $subId
                ClusterState = $clusterState; UpdateState = $updateState; HealthState = $healthState
                ReadyForUpdate = $isReady; AllAvailableUpdates = $availableUpdateNames
                ReadyUpdates = $readyUpdateNames; HasPrerequisiteUpdates = $prereqUpdateNames
                SBEDependency = $sbeDependencyInfo; RecommendedUpdate = $recommendedUpdate
                HealthCheckFailures = $healthCheckFailures
                BlockingReasons = ($blockingReasons -join '; ')
                UpdateStartWindow = if ($clusterInfo.tags -and $clusterInfo.tags.$($script:UpdateStartWindowTagName)) { $clusterInfo.tags.$($script:UpdateStartWindowTagName) } else { "" }
                UpdateExclusionsWindow = if ($clusterInfo.tags -and $clusterInfo.tags.$($script:UpdateExclusionsWindowTagName)) { $clusterInfo.tags.$($script:UpdateExclusionsWindowTagName) } else { "" }
            }) | Out-Null
            $clusterDetails.Add([PSCustomObject]@{
                ClusterName = $clusterName; ResourceGroup = $rgName
                CurrentVersion = $currentVersion; CurrentSbeVersion = $currentSbeVersion
                NodeCount = $nodeCount; ResourceId = $rid
            }) | Out-Null

            # Update runs (reuse already-fetched update list).
            # Collect ALL runs across all available updates and group them by UpdateName so the
            # reporting row for each update version reflects the TOTAL elapsed time across all
            # attempts (re-runs after failures), not just the most recent attempt.
            if ($IncludeUpdateRuns) {
                $allRunsForCluster = [System.Collections.Generic.List[object]]::new()
                foreach ($update in $availableUpdates) {
                    $runsUri = "https://management.azure.com${rid}/updates/$($update.name)/updateRuns?api-version=$apiVer"
                    $runsResult = (Invoke-AzRestJson -Uri $runsUri).Data
                    if ($LASTEXITCODE -eq 0 -and $runsResult.value) {
                        foreach ($run in $runsResult.value) { [void]$allRunsForCluster.Add($run) }
                    }
                }
                if ($allRunsForCluster.Count -gt 0) {
                    # Group by update name extracted from run.id
                    $runsByUpdate = @{}
                    foreach ($r in $allRunsForCluster) {
                        $uName = ''
                        if ($r.id -match '/updates/([^/]+)/updateRuns/([^/]+)$') { $uName = $matches[1] }
                        elseif ($r.name) { $uName = $r.name }
                        if (-not $runsByUpdate.ContainsKey($uName)) { $runsByUpdate[$uName] = [System.Collections.Generic.List[object]]::new() }
                        [void]$runsByUpdate[$uName].Add($r)
                    }
                    # Pick ONLY the most-recently-started update (one row per cluster) so the
                    # report isn't cluttered with historical update versions. Attempts within
                    # that latest update version are still aggregated below.
                    $latestUpdateName = $null
                    $latestUpdateStart = [datetime]::MinValue
                    foreach ($k in $runsByUpdate.Keys) {
                        foreach ($r in $runsByUpdate[$k]) {
                            if ($r.properties.timeStarted) {
                                $ts = [datetime]$r.properties.timeStarted
                                if ($ts -gt $latestUpdateStart) { $latestUpdateStart = $ts; $latestUpdateName = $k }
                            }
                        }
                    }
                    if ($latestUpdateName) {
                        $uName = $latestUpdateName
                        $attempts = @($runsByUpdate[$uName])
                        # Sort attempts by timeStarted descending; [0] = latest, [-1] = earliest
                        $sorted = @($attempts | Sort-Object { if ($_.properties.timeStarted) { [datetime]$_.properties.timeStarted } else { [datetime]::MinValue } } -Descending)
                        $latestRun = $sorted[0]
                        $earliestRun = $sorted[-1]
                        $latestProps = $latestRun.properties
                        # Sum durations across all attempts. For InProgress attempts, use "now" as end.
                        $totalSpan = [TimeSpan]::Zero
                        $hasInProgress = $false
                        foreach ($a in $attempts) {
                            $ap = $a.properties
                            if (-not $ap.timeStarted) { continue }
                            $aStart = [datetime]$ap.timeStarted
                            if ($ap.lastUpdatedTime) {
                                $totalSpan = $totalSpan.Add(([datetime]$ap.lastUpdatedTime) - $aStart)
                            }
                            elseif ($ap.state -eq 'InProgress') {
                                $totalSpan = $totalSpan.Add((Get-Date) - $aStart)
                                $hasInProgress = $true
                            }
                        }
                        $runDuration = ''
                        if ($totalSpan.TotalSeconds -ge 1) {
                            # HH:MM:SS (total hours as left component so 25h+ stays readable)
                            $fmt = '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($totalSpan.TotalHours), $totalSpan.Minutes, $totalSpan.Seconds
                            $runDuration = if ($hasInProgress) { "$fmt (running)" } else { $fmt }
                        }
                        $currentStep = ''; $currentStepDetail = ''; $runProgress = ''
                        if ($latestProps.progress -and $latestProps.progress.steps) {
                            $steps = $latestProps.progress.steps
                            $runProgress = "$(@($steps | Where-Object { $_.status -eq 'Success' }).Count)/$(@($steps).Count) steps"
                            # Walk to the deepest InProgress/Error/Failed step rather than the
                            # coarse top-level wrapper (e.g. "Start update"), so CurrentStep stays
                            # consistent with CurrentStepDetail / the standard update-progress output.
                            $deepestActive = Get-DeepestActiveStep -Steps $steps
                            if ($deepestActive) {
                                if ($deepestActive.status -in @('Error','Failed')) { $currentStep = "$($deepestActive.name) (FAILED)" }
                                else { $currentStep = $deepestActive.name }
                            }
                            $currentStepDetail = Get-CurrentStepPath -Steps $steps -IncludeErrorMessage
                            if ([string]::IsNullOrWhiteSpace($currentStepDetail)) { $currentStepDetail = $currentStep }
                        }
                        $runId = ''
                        if ($latestRun.id -match '/updates/([^/]+)/updateRuns/([^/]+)$') { $runId = $matches[2] } else { $runId = $latestRun.name }
                        # StartTime reflects when work FIRST began on this update (earliest attempt)
                        $firstStartDisplay = if ($earliestRun.properties.timeStarted) { ([datetime]$earliestRun.properties.timeStarted).ToString('yyyy-MM-dd HH:mm') } else { '' }
                        # EndTime reflects when the LATEST attempt finished (or blank if still running).
                        # Uses the central Get-AzLocalRunEndTime helper so this path can't drift from
                        # the per-run formatter.
                        $latestEndDt = Get-AzLocalRunEndTime -props $latestProps
                        $latestEndDisplay = if ($latestEndDt) { $latestEndDt.ToString('yyyy-MM-dd HH:mm') } else { '' }
                        $latestRuns.Add([PSCustomObject]@{
                            ClusterName = $clusterName; UpdateName = $uName; RunId = $runId
                            State = $latestProps.state
                            StartTime = $firstStartDisplay
                            EndTime = $latestEndDisplay
                            Duration = $runDuration; Progress = $runProgress
                            CurrentStep = $currentStep; CurrentStepDetail = $currentStepDetail
                            Location = $latestProps.location
                            Attempts = $attempts.Count
                        }) | Out-Null
                    }
                }
            }

            # Health details (from already-fetched update summary)
            if ($IncludeHealthDetails) {
                $failures = @()
                if ($hasSummary -and $updateSummary.properties.healthCheckResult) {
                    foreach ($check in $updateSummary.properties.healthCheckResult) {
                        if ($check.status -eq "Failed") {
                            $sev = if ($check.severity) { $check.severity } else { "Unknown" }
                            $displayName = if ($check.displayName) { $check.displayName } elseif ($check.name) { ($check.name -split '/')[0] } else { "Unknown" }
                            $failures += [PSCustomObject]@{
                                ClusterName = $clusterName; CheckName = $displayName; Severity = $sev
                                Description = if ($check.description) { $check.description } else { "" }
                                Remediation = if ($check.remediation) { $check.remediation } else { "" }
                                TargetResourceName = if ($check.targetResourceName) { $check.targetResourceName } else { "" }
                                Timestamp = if ($check.timestamp) { $check.timestamp } else { "" }
                            }
                        }
                    }
                }
                $critCount = @($failures | Where-Object { $_.Severity -eq "Critical" }).Count
                $warnCount = @($failures | Where-Object { $_.Severity -eq "Warning" }).Count
                $infoCount = @($failures | Where-Object { $_.Severity -eq "Informational" }).Count
                $healthResults.Add([PSCustomObject]@{
                    ClusterName = $clusterName; HealthState = $healthState; Passed = ($critCount -eq 0)
                    CriticalCount = $critCount; WarningCount = $warnCount; InfoCount = $infoCount
                    Failures = $failures
                }) | Out-Null
            }

            # Status output
            if ($isReady) { Write-Host " Ready" -ForegroundColor Green }
            elseif ($prereqUpdates.Count -gt 0 -and $readyUpdates.Count -eq 0) { Write-Host " Has Prerequisite" -ForegroundColor Yellow }
            elseif ($updateState -eq "UpdateInProgress") { Write-Host " In Progress" -ForegroundColor Yellow }
            elseif ($updateState -in @("UpToDate", "AppliedSuccessfully")) { Write-Host " Up to Date" -ForegroundColor Green }
            elseif ($healthState -eq "Failure") { Write-Host " Health Failure" -ForegroundColor Red }
            else { Write-Host " $updateState" -ForegroundColor Gray }
        }
        catch {
            Write-Host " Error: $($_.Exception.Message)" -ForegroundColor Red
            $readiness.Add([PSCustomObject]@{
                ClusterName = $clusterName; ResourceGroup = $rgName; SubscriptionId = $subId
                ClusterState = "Error"; UpdateState = "Error"; HealthState = "Error"
                ReadyForUpdate = $false; AllAvailableUpdates = ""; ReadyUpdates = ""
                HasPrerequisiteUpdates = ""; SBEDependency = ""
                RecommendedUpdate = ""; HealthCheckFailures = $_.Exception.Message
                BlockingReasons = ""
                UpdateStartWindow = ""; UpdateExclusionsWindow = ""
            }) | Out-Null
            $clusterDetails.Add([PSCustomObject]@{
                ClusterName = $clusterName; ResourceGroup = $rgName
                CurrentVersion = "N/A"; NodeCount = "N/A"; ResourceId = $rid
            }) | Out-Null
        }
    }

    Write-Log -Message "Sequential collection complete: $($readiness.Count) cluster(s)" -Level Success

    # Build result object with stable schema
    $result = [PSCustomObject]@{
        SchemaVersion  = "1.0"
        Timestamp      = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
        ModuleVersion  = $script:ModuleVersion
        Scope          = $scopeDescription
        TotalClusters  = $readiness.Count
        Readiness      = @($readiness)
        ClusterDetails = @($clusterDetails)
        LatestRuns     = @($latestRuns)
        HealthResults  = @($healthResults)
        FailedClusters = @($failedClusters)
    }

    # Export to JSON if path specified
    if ($ExportPath) {
        $ExportPath = Resolve-SafeOutputPath -Path $ExportPath
        $exportDir = Split-Path -Path $ExportPath -Parent
        if ($exportDir -and -not (Test-Path $exportDir)) {
            New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
        }
        Write-Utf8NoBomFile -Path $ExportPath -Content ($result | ConvertTo-Json -Depth 15)
        Write-Log -Message "Fleet status data exported to: $ExportPath" -Level Success
    }

    return $result
}
