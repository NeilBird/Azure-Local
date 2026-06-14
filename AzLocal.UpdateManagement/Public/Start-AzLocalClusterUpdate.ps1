function Start-AzLocalClusterUpdate {
    <#
    .SYNOPSIS
        Starts updates on one or more Azure Local clusters.
    .DESCRIPTION
        Initiates the update process on Azure Local (Azure Stack HCI) clusters. Supports multiple
        methods for specifying clusters: by name, by Resource ID, or by UpdateRing tag. The function
        validates cluster readiness, checks for available updates, and starts the update process.
        Includes comprehensive logging, CSV export of results, and support for CI/CD automation.
    .PARAMETER ClusterNames
        Array of cluster names to update. Use this OR -ClusterResourceIds OR -ScopeByUpdateRingTag.
    .PARAMETER ClusterResourceIds
        Array of full Azure Resource IDs for clusters. Use when clusters are in different resource groups.
    .PARAMETER ScopeByUpdateRingTag
        Switch to find clusters by their 'UpdateRing' tag value via Azure Resource Graph.
    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.
    .PARAMETER ResourceGroupName
        Resource group containing the clusters (only used with -ClusterNames).
    .PARAMETER SubscriptionId
        Azure subscription ID (defaults to current subscription).
    .PARAMETER UpdateName
        Specific update name to apply. If not specified, applies the latest ready update.
        Takes precedence over -AllowedUpdateVersions: when both are set, the explicit
        update is used and the allow-list is logged-and-ignored (with a Warning).
    .PARAMETER AllowedUpdateVersions
        Optional allow-list of Azure Local solution-update names or version strings.
        When set, the cmdlet's automatic "pick the latest Ready update" behaviour is
        constrained to only those updates whose 'name' OR 'properties.version' is an
        EXACT (case-insensitive) match for one of the supplied entries. If no Ready
        update on a cluster matches the allow-list, that cluster is SKIPPED with
        status 'NotInAllowList' (CSV + result row) and the next cluster proceeds -
        this is a strict no-op, never falls back to "latest". Typical use: install
        only the YY04 + YY10 feature updates plus the preceding cumulative updates
        each year (the 'minimum updates' policy).

        Reserved sentinel: passing the single value 'Latest' (case-insensitive)
        explicitly disables the allow-list filter and keeps the default
        "install latest Ready update" behaviour. The pipeline resolver emits
        empty (no -AllowedUpdateVersions argument) when the schedule file's
        effective list resolves to 'Latest', but operators may also pass
        -AllowedUpdateVersions Latest manually.

        In pipeline scenarios, the Step.6 YAML resolves this list from the
        apply-updates-schedule.yml file's (schema v2) 'allowedUpdateVersions'
        field via Resolve-AzLocalCurrentUpdateRing.
    .PARAMETER ApiVersion
        Azure REST API version to use. Default: "2025-10-01".
    .PARAMETER Force
        Skip confirmation prompts.
    .PARAMETER IgnoreScheduleTags
        v0.8.79 break-glass override. When set, the per-cluster Step 3c maintenance-schedule
        gate is BYPASSED entirely - both the `UpdateStartWindow` (allowed window) and the
        `UpdateExclusionsWindow` (deny window) tags are ignored and the cluster proceeds
        directly to the apply call regardless of the current UTC time. A `Warning` is logged
        per cluster so the override is visible in the run log + transcript. This switch does
        NOT bypass any of the other readiness gates (cluster connectivity, health, sideload,
        UpdateExcluded operator hard-override). Intended for emergency / out-of-window
        patching driven by an on-call operator from a manual pipeline run; the bundled
        pipeline YAMLs only expose this through `workflow_dispatch` (GHA) / `Manual` queue
        (ADO) - schedule-triggered runs never honour it.
    .PARAMETER LogFolderPath
        Folder path for log files. Default: C:\ProgramData\AzLocal.UpdateManagement\
    .PARAMETER EnableTranscript
        Enable PowerShell transcript recording.
    .PARAMETER ExportResultsPath
        Export results to JSON (.json), CSV (.csv), or JUnit XML (.xml) file.
    .PARAMETER PrefetchedUpdateSummaries
        Optional hashtable of pre-fetched update summary objects keyed by cluster
        Resource ID (case-insensitive). When a matching key is present the internal
        Get-AzLocalUpdateSummary call for that cluster is skipped. Intended for
        fleet callers that have already fetched summaries in a parallel pass.
        No freshness (TTL) check is performed; callers are responsible for ensuring
        cached data is recent enough for their scenario.
    .PARAMETER PrefetchedAvailableUpdates
        Optional hashtable of pre-fetched available-updates arrays keyed by cluster
        Resource ID (case-insensitive). When a matching key is present the internal
        Get-AzLocalAvailableUpdates call for that cluster is skipped.
    .OUTPUTS
        PSCustomObject[] - Array of result objects with cluster name, status, and message.
    .EXAMPLE
        Start-AzLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG" -Force
        Starts update on a single cluster without confirmation prompt.
    .EXAMPLE
        Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
        Starts updates on all clusters tagged with UpdateRing=Wave1.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByName')]
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
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string[]]$AllowedUpdateVersions,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$IgnoreScheduleTags,

        [Parameter(Mandatory = $false)]
        [string]$LogFolderPath,

        [Parameter(Mandatory = $false)]
        [switch]$EnableTranscript,

        [Parameter(Mandatory = $false)]
        [string]$ExportResultsPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        # Opt-in pass-through caches keyed by cluster ResourceId (case-insensitive).
        # When a key is present for the current cluster, the corresponding internal
        # ARM fetch is skipped. Intended for callers who have already obtained the
        # data via Get-AzLocalUpdateSummary / Get-AzLocalAvailableUpdates so
        # large fleet pipelines do not re-read the same records per cluster.
        # Callers must ensure the cached data is fresh enough for their scenario;
        # no TTL is applied.
        [Parameter(Mandatory = $false)]
        [hashtable]$PrefetchedUpdateSummaries,

        [Parameter(Mandatory = $false)]
        [hashtable]$PrefetchedAvailableUpdates,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 16)]
        [int]$ThrottleLimit = 1
    )

    begin {
        # Pre-flight: Validate export path is writable before expensive operations
        if ($ExportResultsPath) {
            try { Test-ExportPathWritable -Path $ExportResultsPath | Out-Null }
            catch { Write-Warning $_.Exception.Message; return }
        }

        # Initialize logging
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        
        # Determine log directory: parameter > default location
        $defaultLogDir = Join-Path -Path $env:ProgramData -ChildPath "AzLocal.UpdateManagement"
        $logDir = if ($LogFolderPath) { $LogFolderPath } else { $defaultLogDir }
        
        # Ensure log directory exists
        if (-not (Test-Path $logDir)) {
            try {
                New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null
            }
            catch {
                # Fall back to current directory if we can't create the log folder
                Write-Warning "Unable to create log directory '$logDir'. Using current directory instead."
                $logDir = Get-Location
            }
        }
        
        # Set log file path
        $script:LogFilePath = Join-Path -Path $logDir -ChildPath "AzureLocalUpdate_$timestamp.log"
        
        # Create error log path (same location, different suffix)
        $logName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogFilePath)
        $script:ErrorLogPath = Join-Path -Path $logDir -ChildPath "${logName}_errors.log"
        
        # Create CSV summary log paths
        $script:UpdateSkippedLogPath = Join-Path -Path $logDir -ChildPath "${logName}_Update_Skipped.csv"
        $script:UpdateStartedLogPath = Join-Path -Path $logDir -ChildPath "${logName}_Update_Started.csv"

        # Ensure log directory exists
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force -WhatIf:$false | Out-Null
        }

        # Start transcript if enabled
        $transcriptPath = $null
        if ($EnableTranscript) {
            $transcriptPath = Join-Path -Path $logDir -ChildPath "${logName}_transcript.log"
            try {
                Start-Transcript -Path $transcriptPath -Force | Out-Null
                Write-Log -Message "Transcript started: $transcriptPath" -Level Info
            }
            catch {
                Write-Log -Message "Failed to start transcript: $_" -Level Warning
            }
        }

        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Cluster Update - Started" -Level Header
        Write-Log -Message "Module Version: $($script:ModuleVersion)" -Level Header
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Log file: $($script:LogFilePath)" -Level Info
        Write-Log -Message "Error log: $($script:ErrorLogPath)" -Level Info
        Write-Log -Message "Update Skipped CSV: $($script:UpdateSkippedLogPath)" -Level Info
        Write-Log -Message "Update Started CSV: $($script:UpdateStartedLogPath)" -Level Info
        
        # Initialize CSV files with headers (extended headers for skipped to include diagnostic info)
        $csvHeadersSkipped = '"ClusterName","ResourceGroup","SubscriptionId","Message","UpdateState","HealthState","HealthCheckFailures","LastUpdateErrorStep","LastUpdateErrorMessage"'
        $csvHeadersStarted = '"ClusterName","ResourceGroup","SubscriptionId","Message"'
        Write-Utf8NoBomFile -Path $script:UpdateSkippedLogPath -Content ($csvHeadersSkipped + [Environment]::NewLine)
        Write-Utf8NoBomFile -Path $script:UpdateStartedLogPath -Content ($csvHeadersStarted + [Environment]::NewLine)
        
        # Build list of clusters to process
        $clustersToProcess = @()
        if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
            Write-Log -Message "Querying Azure Resource Graph for clusters with tag 'UpdateRing' = '$UpdateRingValue'..." -Level Info
            
            # Ensure resource-graph extension is installed (for pipeline/automation scenarios)
            if (-not (Install-AzGraphExtension)) {
                throw "Failed to ensure Azure CLI 'resource-graph' extension is available. Please install manually: az extension add --name resource-graph"
            }
            
            # Build Azure Resource Graph query to find clusters by tag - use single line to avoid escaping issues with az CLI
            $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
            $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $ringFilter | project id, name, resourceGroup, subscriptionId, tags"
            
            Write-Verbose "ARG Query: $argQuery"
            
            try {
                # Run Azure Resource Graph query across all accessible subscriptions,
                # following skip_token pagination so fleets > 1000 clusters are not truncated.
                $clusterRows = Invoke-AzResourceGraphQuery -Query $argQuery

                if (-not $clusterRows -or $clusterRows.Count -eq 0) {
                    Write-Log -Message "No clusters found with tag 'UpdateRing' = '$UpdateRingValue'" -Level Warning
                    throw "No Azure Local clusters found with tag 'UpdateRing' = '$UpdateRingValue'. Please verify the tag value."
                }
                
                Write-Log -Message "Found $($clusterRows.Count) cluster(s) matching tag criteria:" -Level Success
                foreach ($cluster in $clusterRows) {
                    Write-Log -Message "  - $($cluster.name) (RG: $($cluster.resourceGroup), Sub: $($cluster.subscriptionId))" -Level Info
                    $clustersToProcess += @{ 
                        ResourceId = $cluster.id
                        Name = $cluster.name 
                    }
                }
            }
            catch {
                if ($_.Exception.Message -match "No Azure Local clusters found") {
                    throw
                }
                Write-Log -Message "Error querying Azure Resource Graph: $_" -Level Error
                throw "Failed to query Azure Resource Graph: $_"
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
            Write-Log -Message "Validating Cluster Resource IDs: $($ClusterResourceIds.Count)" -Level Info
            foreach ($resourceId in $ClusterResourceIds) {
                Write-Log -Message "  Validating: $resourceId" -Level Info
                
                # Validate ResourceId format
                $resourceIdPattern = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.AzureStackHCI/clusters/[^/]+$'
                if ($resourceId -notmatch $resourceIdPattern) {
                    Write-Log -Message "    Invalid Resource ID format. Expected: /subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}" -Level Error
                    throw "Invalid Resource ID format: $resourceId"
                }
                
                # Extract subscription ID from resource ID and validate it is accessible
                $subId = ($resourceId -split '/')[2]
                $setSubResult = az account set --subscription $subId 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $setSubError = ConvertTo-ScrubbedCliOutput -Text (($setSubResult | Out-String).Trim())
                    Write-Log -Message "    Subscription '$subId' not found or not accessible in the current Azure CLI context. Ensure you are logged in to the correct Azure tenant (az login --tenant <tenantId>) and have access to this subscription." -Level Error
                    throw "Subscription '$subId' not found or not accessible. Ensure you are logged in to the correct Azure tenant and have access to this subscription. Error: $setSubError"
                }

                # Validate resource exists and user has access
                $validateUri = "https://management.azure.com$resourceId`?api-version=$ApiVersion"
                Write-Verbose "Validating resource at: $validateUri"
                try {
                    # --only-show-errors mutes the cp1252 encode warning emitted by az.cmd's
                    # python (-I isolated mode ignores PYTHONIOENCODING). See Invoke-AzRestJson.
                    $validateResult = az rest --method GET --uri $validateUri --only-show-errors 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $errorMessage = ConvertTo-ScrubbedCliOutput -Text (($validateResult | Out-String).Trim())
                        if ($errorMessage -match "ResourceGroupNotFound") {
                            $rgName = ($resourceId -split '/')[4]
                            Write-Log -Message "    Resource group '$rgName' not found in subscription '$subId'. Verify the resource group name and that the resource has not been deleted." -Level Error
                            throw "Resource group '$rgName' not found in subscription '$subId'. Verify the resource group name and that the resource has not been deleted."
                        }
                        elseif ($errorMessage -match "ResourceNotFound") {
                            $clusterName = ($resourceId -split '/')[-1]
                            $rgName = ($resourceId -split '/')[4]
                            Write-Log -Message "    Cluster '$clusterName' not found in resource group '$rgName'. The cluster may have been deleted or the name may be incorrect." -Level Error
                            throw "Cluster '$clusterName' not found in resource group '$rgName'. The cluster may have been deleted or the name may be incorrect."
                        }
                        elseif ($errorMessage -match "AuthorizationFailed|Forbidden") {
                            Write-Log -Message "    Access denied: You do not have permission to access $resourceId" -Level Error
                            throw "Access denied: You do not have permission to access $resourceId. Please verify you have the required RBAC permissions."
                        }
                        else {
                            Write-Log -Message "    Failed to validate resource: $errorMessage" -Level Error
                            throw "Failed to validate resource: $resourceId. Error: $errorMessage"
                        }
                    }
                    Write-Log -Message "    Validated successfully" -Level Success
                }
                catch {
                    if ($_.Exception.Message -match "Subscription.*not found|not found in|Access denied|Failed to validate") {
                        throw
                    }
                    Write-Log -Message "    Failed to validate resource: $_" -Level Error
                    throw "Failed to validate resource: $resourceId. Error: $_"
                }
                
                $clustersToProcess += @{ ResourceId = $resourceId; Name = ($resourceId -split '/')[-1] }
            }
            Write-Log -Message "All Resource IDs validated successfully" -Level Success
        }
        else {
            Write-Log -Message "Clusters to process: $($ClusterNames -join ', ')" -Level Info
            # Resolve names to resource IDs upfront to avoid per-cluster lookups
            if (-not $SubscriptionId) {
                $SubscriptionId = (az account show --query id -o tsv)
            }
            foreach ($name in $ClusterNames) {
                $clusterInfo = Get-AzLocalClusterInfo -ClusterName $name `
                    -ResourceGroupName $ResourceGroupName -SubscriptionId $SubscriptionId -ApiVersion $ApiVersion
                if ($clusterInfo) {
                    $clustersToProcess += @{ ResourceId = $clusterInfo.id; Name = $clusterInfo.name }
                    Write-Log -Message "  Resolved '$name' -> $($clusterInfo.id)" -Level Success
                }
                else {
                    Write-Log -Message "  Cluster '$name' not found - skipping" -Level Warning
                }
            }
        }

        # Verify Azure CLI is installed and logged in
        Test-AzCliAvailable | Out-Null
        try {
            $null = az account show 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI is not logged in. Please run 'az login' first."
            }
            Write-Log -Message "Azure CLI authentication verified" -Level Success
        }
        catch [System.Management.Automation.CommandNotFoundException] {
            Write-Log -Message "Azure CLI (az) is not installed. Install from https://aka.ms/installazurecliwindowsx64" -Level Error
            throw
        }
        catch {
            Write-Log -Message "Azure CLI is not logged in. Please run 'az login' first." -Level Error
            throw
        }

        # Get subscription ID if not provided (only needed for ByName parameter set)
        if ($PSCmdlet.ParameterSetName -eq 'ByName' -and -not $SubscriptionId) {
            $SubscriptionId = (az account show --query id -o tsv)
            Write-Log -Message "Using current subscription: $SubscriptionId" -Level Info
        }

        # Results collection
        $results = [System.Collections.Generic.List[object]]::new()

        # Parallel prefetch (v0.7.0+): when -ThrottleLimit > 1 and caller did not already
        # provide cached data, fan out the read-heavy Get-AzLocalUpdateSummary +
        # Get-AzLocalAvailableUpdates calls across background jobs and populate the
        # existing $PrefetchedUpdateSummaries / $PrefetchedAvailableUpdates hashtables
        # (keyed by ResourceId). The main per-cluster foreach below then hits the cache
        # and the apply path stays serial so CSV logs + health checks remain coherent.
        if ($ThrottleLimit -gt 1 -and $clustersToProcess.Count -gt 1) {
            $needSummary = -not $PrefetchedUpdateSummaries
            $needAvailable = -not $PrefetchedAvailableUpdates
            if ($needSummary -or $needAvailable) {
                Write-Log -Message "Prefetching update data for $($clustersToProcess.Count) cluster(s) using $ThrottleLimit parallel worker(s)..." -Level Info
                if ($needSummary) { $PrefetchedUpdateSummaries = @{} }
                if ($needAvailable) { $PrefetchedAvailableUpdates = @{} }
                $resourceIds = @($clustersToProcess | ForEach-Object { $_.ResourceId } | Where-Object { $_ })
                $prefetchScript = {
                    param([object[]]$Batch, [string]$ApiVersionArg, [bool]$WantSummary, [bool]$WantAvailable, [string]$ModulePath)
                    Import-Module $ModulePath -Force
                    $out = @()
                    foreach ($rid in $Batch) {
                        $row = @{ ResourceId = $rid; Summary = $null; Available = $null }
                        if ($WantSummary) {
                            try { $row.Summary = Get-AzLocalUpdateSummary -ClusterResourceId $rid -ApiVersion $ApiVersionArg -ErrorAction Stop } catch { $row.Summary = $null }
                        }
                        if ($WantAvailable) {
                            try { $row.Available = Get-AzLocalAvailableUpdates -ClusterResourceId $rid -ApiVersion $ApiVersionArg -Raw -ErrorAction Stop } catch { $row.Available = @() }
                        }
                        $out += [PSCustomObject]$row
                    }
                    $out
                }
                try {
                    $prefetchResults = Invoke-FleetJobsInParallel `
                        -InputItems $resourceIds `
                        -ScriptBlock $prefetchScript `
                        -ThrottleLimit $ThrottleLimit `
                        -ArgumentList @($ApiVersion, [bool]$needSummary, [bool]$needAvailable) `
                        -ActivityName 'UpdatePrefetch'
                    foreach ($br in $prefetchResults) {
                        if ($br.Failed) {
                            Write-Log -Message "  Prefetch batch $($br.BatchIndex) failed: $($br.Error). Per-cluster fetch will run serially." -Level Warning
                            continue
                        }
                        foreach ($row in @($br.Output)) {
                            if (-not $row -or -not $row.ResourceId) { continue }
                            if ($needSummary -and $row.Summary) { $PrefetchedUpdateSummaries[$row.ResourceId] = $row.Summary }
                            if ($needAvailable -and $null -ne $row.Available) { $PrefetchedAvailableUpdates[$row.ResourceId] = $row.Available }
                        }
                    }
                    Write-Log -Message "Prefetch complete: $($PrefetchedUpdateSummaries.Count) summaries, $($PrefetchedAvailableUpdates.Count) available-update sets cached." -Level Success
                }
                catch {
                    Write-Log -Message "Parallel prefetch failed: $($_.Exception.Message). Continuing with serial per-cluster fetch." -Level Warning
                }
            }
        }
    }

    process {
        foreach ($cluster in $clustersToProcess) {
            $clusterName = $cluster.Name
            $clusterResourceId = $cluster.ResourceId

            Write-Log -Message "" -Level Info
            Write-Log -Message "========================================" -Level Header
            Write-Log -Message "Processing cluster: $clusterName" -Level Header
            Write-Log -Message "========================================" -Level Header

            $clusterStartTime = Get-Date

            try {
                # Step 1: Get cluster resource ID (or use provided ResourceId)
                Write-Log -Message "Step 1: Looking up cluster resource..." -Level Info
                
                if ($clusterResourceId) {
                    # ResourceId was provided directly - fetch cluster info using the ResourceId
                    $uri = "https://management.azure.com$clusterResourceId`?api-version=$ApiVersion"
                    Write-Verbose "Getting cluster info from: $uri"
                    $clusterInfo = (Invoke-AzRestJson -Uri $uri).Data
                    if ($LASTEXITCODE -ne 0) {
                        $clusterInfo = $null
                    }
                }
                else {
                    # Look up by name
                    $clusterInfo = Get-AzLocalClusterInfo -ClusterName $clusterName `
                        -ResourceGroupName $ResourceGroupName `
                        -SubscriptionId $SubscriptionId `
                        -ApiVersion $ApiVersion
                }

                if (-not $clusterInfo) {
                    Write-Log -Message "Cluster '$clusterName' not found." -Level Warning
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotFound"
                        Message       = "Cluster not found"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }

                Write-Log -Message "Found cluster: $($clusterInfo.id)" -Level Success
                Write-Log -Message "Cluster Status: $($clusterInfo.properties.status)" -Level Info

                # Step 1b: Connectivity gate
                # ARM cannot reliably push an update to a cluster it has not heard from
                # recently. Skip any cluster whose properties.status is not
                # 'ConnectedRecently' (e.g. NotConnectedRecently, Disconnected) and log
                # to Update_Skipped.csv so an operator can chase the heartbeat first.
                $clusterStatus = if ($clusterInfo.properties.PSObject.Properties['status']) { [string]$clusterInfo.properties.status } else { '' }
                if ($clusterStatus -and $clusterStatus -ne 'ConnectedRecently') {
                    Write-Log -Message "Cluster '$clusterName' is not connected to Azure (status: $clusterStatus). Skipping update - restore the Arc-enabled cluster heartbeat first." -Level Error
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                    Write-UpdateCsvLog -LogType Skipped `
                        -ClusterName $clusterName `
                        -ResourceGroup $clusterRgName `
                        -SubscriptionId $clusterSubId `
                        -Message "Update not started - cluster status is '$clusterStatus' (ARM cannot reach the cluster)" `
                        -UpdateState 'Unknown' `
                        -HealthState 'Unknown' `
                        -HealthCheckFailures '' `
                        -LastUpdateErrorStep '' `
                        -LastUpdateErrorMessage ''
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotConnected"
                        Message       = "Cluster status: $clusterStatus"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }

                # Step 2: Get update summaries to check if updates are available
                Write-Log -Message "Step 2: Retrieving update summary..." -Level Info
                $updateSummary = $null
                if ($PrefetchedUpdateSummaries -and $clusterInfo.id) {
                    # Hashtable lookup is case-insensitive by default when keys were
                    # added with their native casing; normalise on lookup regardless.
                    foreach ($k in $PrefetchedUpdateSummaries.Keys) {
                        if ($k -and ([string]$k).Equals([string]$clusterInfo.id, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $updateSummary = $PrefetchedUpdateSummaries[$k]
                            Write-Log -Message "  Using pre-fetched update summary (PrefetchedUpdateSummaries cache hit)" -Level Verbose
                            break
                        }
                    }
                }
                if (-not $updateSummary) {
                    $updateSummary = Get-AzLocalUpdateSummary -ClusterResourceId $clusterInfo.id `
                        -ApiVersion $ApiVersion
                }

                if (-not $updateSummary) {
                    Write-Log -Message "Unable to retrieve update summary for cluster '$clusterName'." -Level Warning
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "Error"
                        Message       = "Unable to retrieve update summary"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }

                Write-Log -Message "Update State: $($updateSummary.properties.state)" -Level Info

                # Step 3: Check if cluster is ready for updates
                Write-Log -Message "Step 3: Validating cluster state for updates..." -Level Info
                $validStates = @("UpdateAvailable") + $script:ReadyStates
                if ($updateSummary.properties.state -notin $validStates) {
                    Write-Log -Message "Cluster '$clusterName' is not in a valid state for updates. Current state: $($updateSummary.properties.state)" -Level Warning
                    
                    # Parse Resource Group and Subscription ID from cluster resource ID
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                    
                    # Get health check failure details
                    $healthCheckFailures = Get-HealthCheckFailureSummary -UpdateSummary $updateSummary
                    $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
                    
                    # Get last update run error details if the cluster is in a failed/needs attention state
                    $lastErrorDetails = @{ ErrorStep = ""; ErrorMessage = "" }
                    if ($updateSummary.properties.state -in @("NeedsAttention", "UpdateFailed", "PreparationFailed")) {
                        Write-Log -Message "Retrieving last update run error details..." -Level Verbose
                        $lastErrorDetails = Get-LastUpdateRunErrorSummary -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
                    }
                    
                    Write-UpdateCsvLog -LogType Skipped `
                        -ClusterName $clusterName `
                        -ResourceGroup $clusterRgName `
                        -SubscriptionId $clusterSubId `
                        -Message "Update Not started as Cluster NOT in Ready state (Current state: $($updateSummary.properties.state))" `
                        -UpdateState $updateSummary.properties.state `
                        -HealthState $healthState `
                        -HealthCheckFailures $healthCheckFailures `
                        -LastUpdateErrorStep $lastErrorDetails.ErrorStep `
                        -LastUpdateErrorMessage $lastErrorDetails.ErrorMessage
                    
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotReady"
                        Message       = "Cluster state: $($updateSummary.properties.state)"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }

                # Step 3b: Pre-update health validation - check for Critical health failures.
                # CRITICAL: Test-AzLocalClusterHealth only returns its [PSCustomObject]
                # result rows when -PassThru is supplied; without it the function logs to
                # the host stream only and returns $null. Omitting -PassThru here caused
                # the gate to be silently bypassed in v0.7.61 and earlier - the "BLOCKED"
                # log line would appear but the predicate below would short-circuit on
                # $null, falling through to the apply path. Fixed in v0.7.62.
                Write-Log -Message "Step 3b: Checking cluster health for update-blocking issues..." -Level Info
                $healthResults = Test-AzLocalClusterHealth -ClusterResourceIds @($clusterInfo.id) -BlockingOnly -UpdateSummary $updateSummary -PassThru
                if ($healthResults -and $healthResults.Count -gt 0 -and $healthResults[0].CriticalCount -gt 0) {
                    $critFailures = $healthResults[0].Failures | Where-Object { $_.Severity -eq "Critical" }
                    Write-Log -Message "Cluster '$clusterName' has $($healthResults[0].CriticalCount) critical health check failure(s) that will block the update:" -Level Error
                    foreach ($failure in $critFailures) {
                        $nodeInfo = if ($failure.TargetResourceName) { " (Node: $($failure.TargetResourceName))" } else { "" }
                        Write-Log -Message "  [Critical] $($failure.CheckName)$nodeInfo`: $($failure.Description)" -Level Error
                        if ($failure.Remediation) {
                            Write-Log -Message "    Remediation: $($failure.Remediation)" -Level Warning
                        }
                    }
                    
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                    $critSummary = ($critFailures | ForEach-Object { $_.CheckName }) -join '; '
                    
                    Write-UpdateCsvLog -LogType Skipped `
                        -ClusterName $clusterName `
                        -ResourceGroup $clusterRgName `
                        -SubscriptionId $clusterSubId `
                        -Message "Update blocked by critical health check failures: $critSummary" `
                        -UpdateState $updateSummary.properties.state `
                        -HealthState "Failure" `
                        -HealthCheckFailures $critSummary
                    
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "HealthCheckBlocked"
                        Message       = "Critical health failures: $critSummary"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }
                Write-Log -Message "No critical health issues found - cluster is eligible for update" -Level Success

                # Step 3b0: UpdateExcluded operator-override gate (v0.7.90)
                # Hard override: when UpdateExcluded=True/1 (case-insensitive) on
                # the cluster resource, skip the cluster regardless of UpdateRing
                # scope, UpdateSideloaded state, or UpdateStartWindow / UpdateExclusionsWindow
                # schedule. This is evaluated BEFORE the sideloaded and schedule
                # gates so it can override both. Empty/missing tag means no
                # override (proceed to downstream gates). Malformed values are
                # fail-closed unless -Force is supplied, matching the
                # SideloadedBlocked / ScheduleBlocked tag-parse policy.
                $clusterTags = $clusterInfo.tags
                $excludedTagValue = Get-TagValue -Tags $clusterTags -Name $script:UpdateExcludedTagName

                if ($excludedTagValue) {
                    Write-Log -Message "Step 3b0: Checking UpdateExcluded tag..." -Level Info
                    Write-Log -Message "  UpdateExcluded tag: $excludedTagValue" -Level Info

                    try {
                        $excludedResult = Test-AzLocalUpdateExcludedAllowed -UpdateExcluded $excludedTagValue

                        if (-not $excludedResult.Allowed) {
                            Write-Log -Message "Cluster '$clusterName' is blocked by UpdateExcluded tag: $($excludedResult.Reason)" -Level Warning
                            Write-Log -Message "  Details: $($excludedResult.Details)" -Level Warning

                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }

                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update blocked by UpdateExcluded tag: $($excludedResult.Reason). $($excludedResult.Details)" `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState

                            $results.Add([PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "ExcludedByTag"
                                Message       = "$($excludedResult.Reason): $($excludedResult.Details)"
                                UpdateName    = $null
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }) | Out-Null
                            continue
                        }

                        Write-Log -Message "UpdateExcluded check passed: $($excludedResult.Reason)" -Level Success
                    }
                    catch {
                        if ($Force) {
                            Write-Log -Message "Warning: Failed to parse UpdateExcluded tag '$excludedTagValue': $($_.Exception.Message)" -Level Warning
                            Write-Log -Message "  -Force is set; proceeding with update despite malformed UpdateExcluded tag." -Level Warning
                        }
                        else {
                            Write-Log -Message "Failed to parse UpdateExcluded tag for '$clusterName': $($_.Exception.Message)" -Level Error
                            Write-Log -Message "  Update blocked because the tag could not be evaluated. Re-run with -Force to override." -Level Error

                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }

                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update blocked: malformed UpdateExcluded tag value '$excludedTagValue' ($($_.Exception.Message)). Re-run with -Force to override." `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState

                            $results.Add([PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "ExcludedByTag"
                                Message       = "Malformed UpdateExcluded tag value '$excludedTagValue': $($_.Exception.Message). Re-run with -Force to override."
                                UpdateName    = $null
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }) | Out-Null
                            continue
                        }
                    }
                }

                # Step 3b1: Sideloaded-payload gate (v0.7.1)
                # Honour the UpdateSideloaded tag if present. When set to False/0 the
                # operator is signalling that no sideloaded content is staged on the
                # cluster (or it has already been consumed) and the update MUST be
                # blocked. Mirrors the ScheduleBlocked pattern used below.
                # Use Get-TagValue (shape-agnostic, handles PSCustomObject + IDictionary
                # tag containers) for consistency with the rest of the module.
                $clusterTags = $clusterInfo.tags
                $sideloadedTagValue = Get-TagValue -Tags $clusterTags -Name $script:UpdateSideloadedTagName

                if ($sideloadedTagValue) {
                    Write-Log -Message "Step 3b1: Checking UpdateSideloaded tag..." -Level Info
                    Write-Log -Message "  UpdateSideloaded tag: $sideloadedTagValue" -Level Info

                    try {
                        $sideloadedResult = Test-AzLocalUpdateSideloadedAllowed -UpdateSideloaded $sideloadedTagValue

                        if (-not $sideloadedResult.Allowed) {
                            Write-Log -Message "Cluster '$clusterName' is blocked by UpdateSideloaded tag: $($sideloadedResult.Reason)" -Level Warning
                            Write-Log -Message "  Details: $($sideloadedResult.Details)" -Level Warning

                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }

                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update blocked by UpdateSideloaded tag: $($sideloadedResult.Reason). $($sideloadedResult.Details)" `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState

                            $results.Add([PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "SideloadedBlocked"
                                Message       = "$($sideloadedResult.Reason): $($sideloadedResult.Details)"
                                UpdateName    = $null
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }) | Out-Null
                            continue
                        }

                        Write-Log -Message "UpdateSideloaded check passed: $($sideloadedResult.Reason)" -Level Success
                    }
                    catch {
                        # Malformed UpdateSideloaded tag value. Fail-closed unless -Force,
                        # matching the v0.7.0 schedule-tag policy: a typo in the tag must
                        # not silently bypass the operator's intended gate.
                        if ($Force) {
                            Write-Log -Message "Warning: Failed to parse UpdateSideloaded tag '$sideloadedTagValue': $($_.Exception.Message)" -Level Warning
                            Write-Log -Message "  -Force is set; proceeding with update despite malformed UpdateSideloaded tag." -Level Warning
                        }
                        else {
                            Write-Log -Message "Failed to parse UpdateSideloaded tag for '$clusterName': $($_.Exception.Message)" -Level Error
                            Write-Log -Message "  Update blocked because the tag could not be evaluated. Re-run with -Force to override." -Level Error

                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }

                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update blocked: malformed UpdateSideloaded tag value '$sideloadedTagValue' ($($_.Exception.Message)). Re-run with -Force to override." `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState

                            $results.Add([PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "SideloadedBlocked"
                                Message       = "Malformed UpdateSideloaded tag value '$sideloadedTagValue': $($_.Exception.Message). Re-run with -Force to override."
                                UpdateName    = $null
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }) | Out-Null
                            continue
                        }
                    }
                }

                # Step 3c: Schedule/maintenance window validation
                # Check UpdateStartWindow and UpdateExclusionsWindow tags if present on the cluster resource.
                # v0.8.77: tag absence MUST be treated as "no window restriction" (any time eligible).
                # Bare $clusterTags.<tagName> reads THROW under Set-StrictMode -Version Latest when the
                # property is absent on a PSCustomObject (clusterInfo.tags from Invoke-AzRestJson).
                # Guard with PSObject.Properties so missing tags resolve to $null rather than blowing up
                # the entire Start-AzLocalClusterUpdate call for that cluster.
                $clusterTags       = $clusterInfo.tags
                $windowTagValue    = $null
                $exclusionTagValue = $null
                if ($clusterTags) {
                    if ($clusterTags -is [System.Collections.IDictionary]) {
                        if ($clusterTags.Contains($script:UpdateStartWindowTagName))      { $windowTagValue    = $clusterTags[$script:UpdateStartWindowTagName] }
                        if ($clusterTags.Contains($script:UpdateExclusionsWindowTagName)) { $exclusionTagValue = $clusterTags[$script:UpdateExclusionsWindowTagName] }
                    } else {
                        if ($clusterTags.PSObject.Properties[$script:UpdateStartWindowTagName])      { $windowTagValue    = $clusterTags.$($script:UpdateStartWindowTagName) }
                        if ($clusterTags.PSObject.Properties[$script:UpdateExclusionsWindowTagName]) { $exclusionTagValue = $clusterTags.$($script:UpdateExclusionsWindowTagName) }
                    }
                }

                if ($IgnoreScheduleTags) {
                    # v0.8.79 break-glass override (-IgnoreScheduleTags / pipeline force_immediate_update=true).
                    # Skip Step 3c entirely - apply regardless of UpdateStartWindow / UpdateExclusionsWindow.
                    # Log a Warning per cluster so the override is visible in the transcript + step summary.
                    Write-Log -Message "Step 3c: BYPASSED for '$clusterName' (-IgnoreScheduleTags). UpdateStartWindow='$windowTagValue', UpdateExclusionsWindow='$exclusionTagValue' will NOT be evaluated." -Level Warning
                }
                elseif ($windowTagValue -or $exclusionTagValue) {
                    Write-Log -Message "Step 3c: Checking maintenance schedule tags..." -Level Info
                    if ($windowTagValue) { Write-Log -Message "  UpdateStartWindow tag: $windowTagValue" -Level Info }
                    if ($exclusionTagValue) { Write-Log -Message "  UpdateExclusionsWindow tag: $exclusionTagValue" -Level Info }

                    try {
                        $scheduleResult = Test-AzLocalUpdateScheduleAllowed `
                            -UpdateStartWindow $windowTagValue `
                            -UpdateExclusionsWindow $exclusionTagValue

                        if (-not $scheduleResult.Allowed) {
                            Write-Log -Message "Cluster '$clusterName' is outside its maintenance schedule: $($scheduleResult.Reason)" -Level Warning
                            Write-Log -Message "  Details: $($scheduleResult.Details)" -Level Warning

                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }

                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update blocked by maintenance schedule: $($scheduleResult.Reason). $($scheduleResult.Details)" `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState

                            $results.Add([PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "ScheduleBlocked"
                                Message       = "$($scheduleResult.Reason): $($scheduleResult.Details)"
                                UpdateName    = $null
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }) | Out-Null
                            continue
                        }

                        Write-Log -Message "Maintenance schedule check passed: $($scheduleResult.Reason)" -Level Success
                    }
                    catch {
                        # v0.7.0: malformed UpdateStartWindow / UpdateExclusionsWindow tags
                        # now block the update (fail-closed) unless -Force is
                        # specified. The previous behaviour (always proceed on
                        # parse failure) could cause fleet-wide updates to bypass
                        # the operator's configured maintenance windows when a
                        # single tag had a typo.
                        if ($Force) {
                            Write-Log -Message "Warning: Failed to evaluate maintenance schedule tags: $($_.Exception.Message)" -Level Warning
                            Write-Log -Message "  -Force is set; proceeding with update despite unparseable schedule tags." -Level Warning
                        }
                        else {
                            Write-Log -Message "Failed to evaluate maintenance schedule tags for '$clusterName': $($_.Exception.Message)" -Level Error
                            Write-Log -Message "  Update blocked because the schedule could not be evaluated. Re-run with -Force to override." -Level Error

                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }

                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update blocked: unparseable maintenance schedule tags ($($_.Exception.Message)). Re-run with -Force to override." `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState

                            $results.Add([PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "ScheduleBlocked"
                                Message       = "Unparseable schedule tags: $($_.Exception.Message). Re-run with -Force to override."
                                UpdateName    = $null
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }) | Out-Null
                            continue
                        }
                    }
                }
                else {
                    Write-Log -Message "Step 3c: No maintenance schedule tags defined - no schedule restrictions" -Level Info
                }

                # Step 4: List available updates
                Write-Log -Message "Step 4: Listing available updates..." -Level Info
                $availableUpdates = $null
                if ($PrefetchedAvailableUpdates -and $clusterInfo.id) {
                    foreach ($k in $PrefetchedAvailableUpdates.Keys) {
                        if ($k -and ([string]$k).Equals([string]$clusterInfo.id, [System.StringComparison]::OrdinalIgnoreCase)) {
                            $availableUpdates = $PrefetchedAvailableUpdates[$k]
                            Write-Log -Message "  Using pre-fetched available updates (PrefetchedAvailableUpdates cache hit)" -Level Verbose
                            break
                        }
                    }
                }
                if (-not $availableUpdates) {
                    $availableUpdates = Get-AzLocalAvailableUpdates -ClusterResourceId $clusterInfo.id `
                        -ApiVersion $ApiVersion -Raw
                }

                if (-not $availableUpdates -or $availableUpdates.Count -eq 0) {
                    Write-Log -Message "No updates available for cluster '$clusterName'." -Level Warning
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NoUpdatesAvailable"
                        Message       = "No updates available"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }

                # Filter updates that are in a ready state (Ready or ReadyToInstall)
                $readyUpdates = $availableUpdates | Where-Object { $_.properties.state -in $script:ReadyStates }
                
                if (-not $readyUpdates -or $readyUpdates.Count -eq 0) {
                    Write-Log -Message "No updates in ready state for cluster '$clusterName'." -Level Warning

                    # Check for HasPrerequisite/AdditionalContentRequired updates and surface SBE dependency info
                    $prereqUpdates = @($availableUpdates | Where-Object { $_.properties.state -in @("HasPrerequisite", "AdditionalContentRequired") })
                    if ($prereqUpdates.Count -gt 0) {
                        Write-Log -Message "Updates blocked by SBE prerequisites:" -Level Warning
                        foreach ($pu in $prereqUpdates) {
                            $puProps = $pu.properties
                            $puMsg = "  - $($pu.name): $($puProps.state)"
                            if ($puProps.packageType -eq "SBE" -and $puProps.additionalProperties) {
                                $addProps = ConvertTo-AzLocalAdditionalProperties -InputObject $puProps.additionalProperties
                                if ($addProps) {
                                    $sbeParts = @()
                                    if ($addProps.SBEPublisher) { $sbeParts += "Publisher: $($addProps.SBEPublisher)" }
                                    if ($addProps.SBEFamily) { $sbeParts += "Family: $($addProps.SBEFamily)" }
                                    if ($addProps.SBEReleaseLink) { $sbeParts += "Release Notes: $($addProps.SBEReleaseLink)" }
                                    if ($sbeParts.Count -gt 0) { $puMsg += " ($($sbeParts -join '; '))" }
                                }
                            }
                            Write-Log -Message $puMsg -Level Warning
                        }
                        Write-Log -Message "Install the required SBE (Solution Builder Extension) update from your hardware vendor before this update can proceed." -Level Warning
                    }

                    Write-Log -Message "Available updates and their states:" -Level Info
                    foreach ($update in $availableUpdates) {
                        Write-Log -Message "  - $($update.name): $($update.properties.state)" -Level Verbose
                    }
                    
                    # Parse Resource Group and Subscription ID from cluster resource ID
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                    $updateStatesList = ($availableUpdates | ForEach-Object { "$($_.name): $($_.properties.state)" }) -join '; '
                    
                    # Get health check failure details
                    $healthCheckFailures = Get-HealthCheckFailureSummary -UpdateSummary $updateSummary
                    $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
                    
                    # Get last update run error details - might have failed updates
                    $lastErrorDetails = Get-LastUpdateRunErrorSummary -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
                    
                    Write-UpdateCsvLog -LogType Skipped `
                        -ClusterName $clusterName `
                        -ResourceGroup $clusterRgName `
                        -SubscriptionId $clusterSubId `
                        -Message "Update Not started as no updates in Ready state. Available: $updateStatesList" `
                        -UpdateState $updateSummary.properties.state `
                        -HealthState $healthState `
                        -HealthCheckFailures $healthCheckFailures `
                        -LastUpdateErrorStep $lastErrorDetails.ErrorStep `
                        -LastUpdateErrorMessage $lastErrorDetails.ErrorMessage
                    
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NoReadyUpdates"
                        Message       = "No updates in Ready state"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }

                Write-Log -Message "Available updates in 'Ready' state:" -Level Success
                foreach ($update in $readyUpdates) {
                    Write-Log -Message "  - $($update.name) (Version: $($update.properties.version), State: $($update.properties.state))" -Level Info
                }

                # Step 4b (v0.7.89): AllowedUpdateVersions allow-list filter
                # ---------------------------------------------------------
                # When -AllowedUpdateVersions is set AND -UpdateName is NOT
                # set, restrict the auto-pick pool to Ready updates whose
                # 'name' OR 'properties.version' is an EXACT
                # (case-insensitive) match for one of the supplied entries.
                # If the filter empties the pool, this cluster is SKIPPED
                # with status 'NotInAllowList' - strict no-op, never falls
                # back to "latest Ready".
                # When -UpdateName is set, the explicit operator choice
                # wins over the policy allow-list. Warn loudly so audit
                # logs surface the override.
                # 'Latest' sentinel: if the supplied allow-list contains
                # ONLY 'Latest' (case-insensitive), the filter is skipped
                # entirely - 'Latest' means "no constraint, install the
                # latest Ready update". The pipeline resolver normally
                # strips 'Latest' before calling this cmdlet (emits empty
                # to the env var), but be defensive in case an operator
                # invokes -AllowedUpdateVersions Latest manually.
                #
                # v0.8.7: the allow-list filter + latest-by-YYMM auto-pick is
                # centralised in the Private helper Select-AzLocalNextUpdateForCluster
                # so the on-prem sideloading automation resolves the SAME "next
                # update". All logging / CSV / result-object side effects below
                # are preserved byte-for-byte from the original inline block.
                $selection = Select-AzLocalNextUpdateForCluster -ReadyUpdates $readyUpdates -AllowedUpdateVersions $AllowedUpdateVersions -UpdateName $UpdateName

                if ($selection.AllowOnlyLatest) {
                    Write-Log -Message "AllowedUpdateVersions = 'Latest' (no-constraint sentinel) - skipping allow-list filter for cluster '$clusterName'; will install the latest Ready update." -Level Info
                }
                $allowListActive = ($selection.AllowListEffective.Count -gt 0 -and -not $selection.AllowOnlyLatest)
                if ($allowListActive -and $UpdateName) {
                    Write-Log -Message ("Both -UpdateName ('$UpdateName') and -AllowedUpdateVersions ({0} entries) were supplied for cluster '$clusterName'. -UpdateName takes precedence; allow-list is logged-and-ignored for this cluster." -f @($AllowedUpdateVersions).Count) -Level Warning
                }

                if ($selection.Reason -eq 'NotInAllowList') {
                    $allowDisplay = $selection.AllowDisplay
                    $readyDisplay = $selection.ReadyDisplay
                    Write-Log -Message "Cluster '$clusterName': none of the $($readyUpdates.Count) Ready update(s) match the AllowedUpdateVersions allow-list. Allow-list: [$allowDisplay]. Available Ready: [$readyDisplay]. Skipping cluster (status='NotInAllowList')." -Level Warning

                    # Parse Resource Group and Subscription ID from cluster resource ID
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $clusterSubId  = ($clusterInfo.id -split '/subscriptions/')[1]  -split '/' | Select-Object -First 1
                    $healthState   = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
                    Write-UpdateCsvLog -LogType Skipped `
                        -ClusterName $clusterName `
                        -ResourceGroup $clusterRgName `
                        -SubscriptionId $clusterSubId `
                        -Message "Update skipped - no Ready update matches AllowedUpdateVersions allow-list [$allowDisplay]. Available Ready: $readyDisplay" `
                        -UpdateState $updateSummary.properties.state `
                        -HealthState $healthState

                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotInAllowList"
                        Message       = "No Ready update matches AllowedUpdateVersions allow-list [$allowDisplay]"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }

                if ($allowListActive -and -not $UpdateName) {
                    Write-Log -Message "AllowedUpdateVersions filter kept $($selection.FilteredUpdates.Count)/$($readyUpdates.Count) Ready update(s) for cluster '$clusterName'. Allow-list: [$($selection.AllowDisplay)]." -Level Info
                }

                # Step 5: Select update to apply
                Write-Log -Message "Step 5: Selecting update to apply..." -Level Info
                if ($selection.Reason -eq 'UpdateNotFound') {
                    Write-Log -Message "Specified update '$UpdateName' not found or not in Ready state for cluster '$clusterName'." -Level Warning
                    $results.Add([PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "UpdateNotFound"
                        Message       = "Specified update '$UpdateName' not found or not ready"
                        UpdateName    = $UpdateName
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }) | Out-Null
                    continue
                }
                $selectedUpdate = $selection.SelectedUpdate
                if (-not $UpdateName) {
                    # Select the latest ready update by YYMM version from the update name
                    Write-Log -Message "Auto-selected latest update: $($selectedUpdate.name)" -Level Info
                }

                # Step 6: Apply the update
                Write-Log -Message "Step 6: Applying update..." -Level Info
                if ($PSCmdlet.ShouldProcess("$clusterName", "Apply update '$($selectedUpdate.name)'")) {
                    if (-not $Force) {
                        $confirmation = Read-Host "  Do you want to start update '$($selectedUpdate.name)' on cluster '$clusterName'? (Y/N)"
                        if ($confirmation -notmatch '^[Yy]') {
                            Write-Log -Message "Update skipped by user." -Level Warning
                            
                            # Parse Resource Group and Subscription ID from cluster resource ID
                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
                            
                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update skipped by user" `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState
                            
                            $results.Add([PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "Skipped"
                                Message       = "Update skipped by user"
                                UpdateName    = $selectedUpdate.name
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }) | Out-Null
                            continue
                        }
                    }

                    Write-Log -Message "Initiating update '$($selectedUpdate.name)' on cluster '$clusterName'..." -Level Info
                    $applyResult = Invoke-AzLocalUpdateApply -ClusterResourceId $clusterInfo.id `
                        -UpdateName $selectedUpdate.name `
                        -ApiVersion $ApiVersion

                    $endTime = Get-Date
                    $duration = $endTime - $clusterStartTime

                    if ($applyResult) {
                        Write-Log -Message "Update started successfully!" -Level Success
                        Write-Log -Message "Monitor progress using: Get-AzLocalUpdateRuns -ClusterName '$clusterName'" -Level Info
                        
                        # Parse Resource Group and Subscription ID from cluster resource ID
                        $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                        $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                        Write-UpdateCsvLog -LogType Started -ClusterName $clusterName -ResourceGroup $clusterRgName -SubscriptionId $clusterSubId -Message "Update Started: $($selectedUpdate.name)"

                        # v0.7.1: Always write UpdateVersionInProgress tag after successful apply.
                        # This is the audit/correlation tag used by the auto-reset path in
                        # Get-AzLocalUpdateRuns to verify a Succeeded run corresponds to
                        # the staged sideloaded payload before flipping UpdateSideloaded=False.
                        # Failure to write the tag is non-fatal: the update has already been
                        # initiated; degraded auto-reset metadata only.
                        try {
                            [void](Set-AzLocalClusterTagsMerge `
                                -ClusterResourceId $clusterInfo.id `
                                -Tags @{ $script:UpdateVersionInProgressTagName = $selectedUpdate.name } `
                                -ApiVersion $ApiVersion)
                            Write-Log -Message "Set $($script:UpdateVersionInProgressTagName) tag to '$($selectedUpdate.name)'" -Level Verbose
                        }
                        catch {
                            Write-Log -Message "Warning: failed to write $($script:UpdateVersionInProgressTagName) tag on '$clusterName': $($_.Exception.Message)" -Level Warning
                            Write-Log -Message "  Update has been initiated successfully; only auto-reset correlation metadata is affected." -Level Warning
                        }

                        $results.Add([PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "UpdateStarted"
                            Message       = "Update initiated successfully"
                            UpdateName    = $selectedUpdate.name
                            StartTime     = $clusterStartTime
                            EndTime       = $endTime
                            Duration      = $duration.ToString("hh\:mm\:ss")
                        }) | Out-Null
                    }
                    else {
                        Write-Log -Message "Failed to start update on cluster '$clusterName'." -Level Error
                        $results.Add([PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "Failed"
                            Message       = "Failed to start update"
                            UpdateName    = $selectedUpdate.name
                            StartTime     = $clusterStartTime
                            EndTime       = $endTime
                            Duration      = $duration.ToString("hh\:mm\:ss")
                        }) | Out-Null
                    }
                }
                elseif ($WhatIfPreference) {
                    # Under -WhatIf: ShouldProcess returned $false. Emit a WouldUpdate row
                    # so the end-of-run Summary lists which clusters would have had an
                    # update started. Matches the normal 'UpdateStarted' shape.
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    Write-Log -Message "[WhatIf] Would start update '$($selectedUpdate.name)' on cluster '$clusterName' (RG: $clusterRgName)" -Level Info
                    $results.Add([PSCustomObject]@{
                        ClusterName = $clusterName
                        Status      = "WouldUpdate"
                        Message     = "WhatIf: would start update '$($selectedUpdate.name)'"
                        UpdateName  = $selectedUpdate.name
                        StartTime   = $clusterStartTime
                        EndTime     = Get-Date
                        Duration    = $null
                    }) | Out-Null
                }
            }
            catch {
                $endTime = Get-Date
                $duration = $endTime - $clusterStartTime
                Write-Log -Message "Error processing cluster '$clusterName': $($_.Exception.Message)" -Level Error
                Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level Error
                $results.Add([PSCustomObject]@{
                    ClusterName   = $clusterName
                    Status        = "Error"
                    Message       = $_.Exception.Message
                    UpdateName    = $null
                    StartTime     = $clusterStartTime
                    EndTime       = $endTime
                    Duration      = $duration.ToString("hh\:mm\:ss")
                }) | Out-Null
            }
        }
    }

    end {
        Write-Log -Message "" -Level Info
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Summary" -Level Header
        Write-Log -Message "========================================" -Level Header
        
        # Display summary statistics
        $totalClusters = $results.Count
        $succeeded = @($results | Where-Object { $_.Status -eq "UpdateStarted" }).Count
        $wouldUpdate = @($results | Where-Object { $_.Status -eq "WouldUpdate" }).Count
        $failed = @($results | Where-Object { $_.Status -in @("Failed", "Error") }).Count
        $skipped = @($results | Where-Object { $_.Status -in @("Skipped", "NotReady", "NoUpdatesAvailable", "NoReadyUpdates", "NotFound", "UpdateNotFound", "HealthCheckBlocked", "ScheduleBlocked", "SideloadedBlocked", "ExcludedByTag") }).Count

        Write-Log -Message "Total clusters processed: $totalClusters" -Level Info
        if ($WhatIfPreference) {
            Write-Log -Message "Would start updates on: $wouldUpdate cluster(s) (WhatIf mode - no changes made)" -Level Success
        }
        else {
            Write-Log -Message "Updates started: $succeeded" -Level Success
        }
        if ($failed -gt 0) {
            Write-Log -Message "Failed: $failed" -Level Error
        } else {
            Write-Log -Message "Failed: $failed" -Level Info
        }
        if ($skipped -gt 0) {
            Write-Log -Message "Skipped/Not Ready: $skipped" -Level Warning
        } else {
            Write-Log -Message "Skipped/Not Ready: $skipped" -Level Info
        }

        # Display results table
        Write-Log -Message "" -Level Info
        Write-Log -Message "Detailed Results:" -Level Info
        $results | Format-Table ClusterName, Status, UpdateName, Duration, Message -AutoSize | Out-String -Stream | ForEach-Object { 
            if ($_ -ne "") { Write-Log -Message $_ -Level Info }
        }

        # Export results if path specified
        if ($ExportResultsPath) {
            try {
                $ExportResultsPath = Resolve-SafeOutputPath -Path $ExportResultsPath
                $exportDir = Split-Path -Path $ExportResultsPath -Parent
                if ($exportDir -and -not (Test-Path $exportDir)) {
                    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
                }

                $extension = [System.IO.Path]::GetExtension($ExportResultsPath).ToLower()
                
                switch ($extension) {
                    '.json' {
                        $exportData = @{
                            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            TotalClusters = $totalClusters
                            Succeeded     = $succeeded
                            Failed        = $failed
                            Skipped       = $skipped
                            Results       = $results
                        }
                        Write-Utf8NoBomFile -Path $ExportResultsPath -Content ($exportData | ConvertTo-Json -Depth 10)
                        Write-Log -Message "Results exported to JSON: $ExportResultsPath" -Level Success
                    }
                    '.csv' {
                        $results | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportResultsPath -NoTypeInformation -Encoding UTF8
                        Write-Log -Message "Results exported to CSV: $ExportResultsPath" -Level Success
                    }
                    '.xml' {
                        # Export to JUnit XML format for CI/CD integration
                        Export-ResultsToJUnitXml -Results $results -OutputPath $ExportResultsPath `
                            -TestSuiteName "AzureLocalClusterUpdates" -OperationType "StartUpdate"
                        Write-Log -Message "Results exported to JUnit XML (CI/CD compatible): $ExportResultsPath" -Level Success
                    }
                    default {
                        # Default to JSON
                        $jsonPath = $ExportResultsPath + ".json"
                        $exportData = @{
                            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            TotalClusters = $totalClusters
                            Succeeded     = $succeeded
                            Failed        = $failed
                            Skipped       = $skipped
                            Results       = $results
                        }
                        Write-Utf8NoBomFile -Path $jsonPath -Content ($exportData | ConvertTo-Json -Depth 10)
                        Write-Log -Message "Results exported to JSON: $jsonPath" -Level Success
                    }
                }
            }
            catch {
                Write-Log -Message "Failed to export results: $($_.Exception.Message)" -Level Error
            }
        }

        Write-Log -Message "" -Level Info
        Write-Log -Message "Log file saved to: $($script:LogFilePath)" -Level Info
        if ($script:ErrorLogPath -and (Test-Path $script:ErrorLogPath)) {
            $errorContent = Get-Content $script:ErrorLogPath -ErrorAction SilentlyContinue
            if ($errorContent) {
                Write-Log -Message "Error log saved to: $($script:ErrorLogPath)" -Level Warning
            }
        }
        
        # Report CSV summary files
        if ($script:UpdateSkippedLogPath -and (Test-Path $script:UpdateSkippedLogPath)) {
            $skippedCount = ((Get-Content $script:UpdateSkippedLogPath | Measure-Object).Count - 1)  # Subtract header
            if ($skippedCount -gt 0) {
                Write-Log -Message "Update Skipped CSV ($skippedCount entries): $($script:UpdateSkippedLogPath)" -Level Warning
            }
        }
        if ($script:UpdateStartedLogPath -and (Test-Path $script:UpdateStartedLogPath)) {
            $startedCount = ((Get-Content $script:UpdateStartedLogPath | Measure-Object).Count - 1)  # Subtract header
            if ($startedCount -gt 0) {
                Write-Log -Message "Update Started CSV ($startedCount entries): $($script:UpdateStartedLogPath)" -Level Success
            }
        }

        # Stop transcript if it was started
        if ($EnableTranscript) {
            try {
                Stop-Transcript | Out-Null
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] Transcript saved to: $transcriptPath" -ForegroundColor Cyan
            }
            catch {
                # Transcript may not have been started successfully - non-critical
                Write-Verbose "Note: Transcript stop failed (may not have been started): $($_.Exception.Message)"
            }
        }

        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Cluster Update - Completed" -Level Header
        Write-Log -Message "========================================" -Level Header

        if ($PassThru) {
            return $results
        }
    }
}
