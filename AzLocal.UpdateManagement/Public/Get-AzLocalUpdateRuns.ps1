function Get-AzLocalUpdateRuns {
    <#
    .SYNOPSIS
        Gets update run history and status for one or more Azure Local clusters.
    .DESCRIPTION
        Retrieves update run information for Azure Local (Azure Stack HCI) clusters.
        Update runs contain the history and status of update operations including
        start time, end time, progress, and any errors that occurred.

        Supports multiple input methods:
        - Single cluster by name (uses ARM REST against the cluster's /updateRuns endpoint)
        - Multiple clusters by name or resource ID (single ARG query)
        - All clusters matching an UpdateRing tag value (single ARG query)

        In multi-cluster mode (v0.7.68+) all update runs are returned by ONE
        Azure Resource Graph query against the `extensibilityresources`
        namespace (microsoft.azurestackhci/clusters/updates/updateruns) -
        typically completes in under 10 seconds for hundreds of clusters,
        replacing the previous per-cluster ARM REST fan-out which took
        minutes for moderately-sized fleets.

        Returns clean, human-readable objects with key information extracted from the API response.
    .PARAMETER ClusterName
        The name of a single Azure Local cluster (original behavior).
    .PARAMETER ClusterNames
        An array of Azure Local cluster names to query. In v0.7.68+ these are
        resolved cross-subscription via a single ARG batch lookup (no per-name
        ARM REST calls).
    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to query.
    .PARAMETER ScopeByUpdateRingTag
        When specified, finds clusters by the 'UpdateRing' tag via Azure Resource Graph.
        Must be used together with -UpdateRingValue.
    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.
    .PARAMETER ResourceGroupName
        The resource group containing the cluster. If not specified, searches all resource groups.
    .PARAMETER SubscriptionId
        Optional. The Azure subscription ID to scope queries to. When omitted,
        the multi-cluster mode queries every subscription the caller can read
        via Azure Resource Graph (cross-subscription default since v0.7.68).
    .PARAMETER UpdateName
        Optional. The specific update name to get runs for. If not specified, returns runs for all updates.
    .PARAMETER Latest
        Optional. Return only the most recent update run per cluster.
    .PARAMETER Raw
        Optional. Return the raw API response objects instead of formatted output.
        Only applies to the single-cluster mode.
    .PARAMETER ApiVersion
        The Azure REST API version to use. Default is the module's default API version.
        Only used by the single-cluster mode; the multi-cluster mode uses ARG.
    .PARAMETER ExportPath
        Path to export the results. Supports .csv, .json, and .xml (JUnit format) extensions.
    .OUTPUTS
        PSCustomObject[] - Array of update run objects with the following properties:
        - ClusterName: The cluster name (in multi-cluster mode)
        - UpdateName: The update package name (e.g., "Solution12.2601.1002.38")
        - RunId: The unique GUID for this update run
        - State: Current state (InProgress, Succeeded, Failed, etc.)
        - StartTime: When the update run started
        - Duration: How long the update has been running or took to complete
        - Progress: Step completion progress (e.g., "3/5 steps")
        - CurrentStep: The currently executing or failed step name
        - Location: Azure region
    .EXAMPLE
        # Single cluster (original behavior)
        Get-AzLocalUpdateRuns -ClusterName "MyCluster" -ResourceGroupName "MyRG"
    .EXAMPLE
        # Multiple clusters by tag
        Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Latest
    .EXAMPLE
        # Export to CSV
        Get-AzLocalUpdateRuns -ScopeByUpdateRingTag -UpdateRingValue "Production" -Latest -ExportPath "C:\Reports\runs.csv"
    .EXAMPLE
        Get-AzLocalUpdateRuns -ClusterName "MyCluster" -Raw
        Gets raw API response for programmatic processing.
    #>
    [CmdletBinding(DefaultParameterSetName = 'SingleCluster')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'SingleCluster')]
        [string]$ClusterName,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string[]]$ClusterNames,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [switch]$ScopeByUpdateRingTag,

        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'SingleCluster')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [switch]$Latest,

        [Parameter(Mandatory = $false)]
        [switch]$Raw,

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

        # v0.7.1: when omitted (default), Get-AzLocalUpdateRuns will auto-reset
        # the UpdateSideloaded tag (True->False) and clear UpdateVersionInProgress
        # for any cluster whose latest update run is Succeeded AND whose
        # UpdateVersionInProgress tag matches the run's update name. Pass this
        # switch on read-only audit pipelines that must not mutate cluster tags.
        [Parameter(Mandatory = $false)]
        [switch]$SkipSideloadedReset
    )

    # Pre-flight: Validate export path is writable before expensive operations
    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { Write-Warning $_.Exception.Message; return }
    }

    # Original single-cluster behavior
    if ($PSCmdlet.ParameterSetName -eq 'SingleCluster') {
        Test-AzCliAvailable | Out-Null
        Write-Log -Message "" -Level Info
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Cluster Update Runs" -Level Header
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Cluster: $ClusterName" -Level Info

        if (-not $SubscriptionId) {
            $SubscriptionId = (az account show --query id -o tsv)
            Write-Log -Message "Using current subscription: $SubscriptionId" -Level Info
        }

        Write-Log -Message "Looking up cluster resource..." -Level Info
        $clusterInfo = Get-AzLocalClusterInfo -ClusterName $ClusterName `
            -ResourceGroupName $ResourceGroupName `
            -SubscriptionId $SubscriptionId `
            -ApiVersion $ApiVersion

        if (-not $clusterInfo) {
            Write-Log -Message "Cluster '$ClusterName' not found." -Level Error
            return $null
        }
        Write-Log -Message "Found cluster: $($clusterInfo.id)" -Level Success

        Write-Log -Message "Querying update runs..." -Level Info
        $allRuns = Get-AzLocalClusterUpdateRuns -resourceId $clusterInfo.id -updateNameFilter $UpdateName -apiVer $ApiVersion
        Write-Log -Message "Found $($allRuns.Count) update run(s)" -Level $(if ($allRuns.Count -gt 0) { "Success" } else { "Warning" })

        if ($Raw) {
            if ($Latest) {
                return $allRuns | Sort-Object { $_.properties.timeStarted } -Descending | Select-Object -First 1
            }
            return $allRuns
        }

        # Format runs
        $formattedRuns = [System.Collections.Generic.List[object]]::new()
        foreach ($run in $allRuns) {
            $formattedRuns.Add((Format-AzLocalUpdateRun -run $run -clusterName $ClusterName -clusterResourceId $clusterInfo.id)) | Out-Null
        }

        $formattedRuns = @($formattedRuns | Sort-Object StartTime -Descending)

        if ($Latest) {
            $formattedRuns = @($formattedRuns | Select-Object -First 1)
        }

        if ($formattedRuns.Count -gt 0) {
            Write-Log -Message "" -Level Info
            Write-Log -Message "Update Runs for Cluster: $ClusterName" -Level Header
            Write-Log -Message ("=" * 60) -Level Header
            $formattedRuns | Format-Table -AutoSize | Out-String | Write-Host

            # If the latest run failed due to health check, show blocking health failures
            $latestRun = $formattedRuns | Select-Object -First 1
            if ($latestRun.State -eq "Failed" -and $latestRun.CurrentStep -match "health check") {
                Write-Log -Message "The latest update run was blocked by health check failures." -Level Warning
                Write-Log -Message "Querying current health check status..." -Level Info
                # -PassThru is required to receive the [PSCustomObject] result rows;
                # without it Test-AzLocalClusterHealth logs to the host only and
                # returns $null (v0.7.62 fix).
                $healthResults = Test-AzLocalClusterHealth -ClusterResourceIds @($clusterInfo.id) -BlockingOnly -PassThru
                if ($healthResults -and $healthResults[0].CriticalCount -gt 0) {
                    Write-Log -Message "" -Level Info
                    Write-Log -Message "The following critical health issues must be resolved before this update can proceed:" -Level Error
                    foreach ($failure in $healthResults[0].Failures) {
                        $nodeInfo = if ($failure.TargetResourceName) { " (Node: $($failure.TargetResourceName))" } else { "" }
                        Write-Log -Message "  [Critical] $($failure.CheckName)$nodeInfo`: $($failure.Description)" -Level Error
                        if ($failure.Remediation) {
                            Write-Log -Message "    Remediation: $($failure.Remediation)" -Level Warning
                        }
                    }
                }
            }
        }
        else {
            Write-Log -Message "" -Level Info
            Write-Log -Message "No update runs found for cluster '$ClusterName'" -Level Warning
        }

        # Display latest run details
        if ($formattedRuns.Count -gt 0) {
            Write-Log -Message "" -Level Info
            Write-Log -Message "Latest Update Run:" -Level Header
            Write-Host ""
            $formattedRuns | Select-Object -First 1 | Format-List | Out-String -Stream | ForEach-Object {
                if ($_ -ne "") { Write-Host "`t$_" }
            }
            Write-Host ""
        }

        # v0.7.1: Sideloaded auto-reset (default ON; -SkipSideloadedReset to disable).
        if (-not $SkipSideloadedReset -and $formattedRuns.Count -gt 0) {
            try {
                [void](Invoke-AzLocalSideloadedAutoReset -FormattedRuns $formattedRuns -ApiVersion $ApiVersion)
            }
            catch {
                Write-Log -Message "Sideloaded auto-reset failed: $($_.Exception.Message)" -Level Warning
            }
        }

        if ($PassThru) {
            return $formattedRuns
        }
        return
    }

    # Multi-cluster mode
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local Update Runs (Fleet)" -Level Header
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
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $ringFilter | project id, name, resourceGroup, subscriptionId, tags"

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
        $nameQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where name in~ ($nameListKql) | project id, name, resourceGroup, subscriptionId"
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
    Write-Log -Message "Querying update runs for $($clustersToProcess.Count) cluster(s)..." -Level Info

    # Collect results
    $allFormattedRuns = [System.Collections.Generic.List[object]]::new()
    $stateCounts = @{}

    # v0.7.68: Replaced per-cluster ARM REST fan-out with a SINGLE Azure
    # Resource Graph query against the `extensibilityresources` namespace
    # (microsoft.azurestackhci/clusters/updates/updateruns). One round-trip
    # returns every update run for the entire cluster list - typically in
    # <10 seconds for hundreds of clusters - replacing the previous design
    # which made one ARM REST call per update per cluster (251s for 9
    # clusters in the smoke test). The `properties` bag returned by ARG is
    # identical in shape to the ARM REST /updateRuns response, so we can
    # reuse Format-AzLocalUpdateRun unchanged.

    # Build the KQL `in~()` literal: cluster IDs are lowercased to match the
    # `tolower(...)` projection inside the query. PowerShell single-quoted
    # strings in the join are valid KQL string literals because cluster IDs
    # cannot contain apostrophes.
    $idListKql = ($clustersToProcess | ForEach-Object { "'$($_.ResourceId.ToLower())'" }) -join ','
    $updateNameClause = if ($UpdateName) { "| where UpdateName_ =~ '$UpdateName'" } else { '' }

    $runsKql = @"
extensibilityresources
| where type =~ 'microsoft.azurestackhci/clusters/updates/updateruns'
| extend ids = split(id, '/')
| extend ClusterName_ = tostring(ids[8]), UpdateName_ = tostring(ids[10])
| extend ClusterResourceId_ = tolower(strcat('/subscriptions/', tostring(ids[2]), '/resourceGroups/', tostring(ids[4]), '/providers/Microsoft.AzureStackHCI/clusters/', ClusterName_))
| where ClusterResourceId_ in~ ($idListKql)
$updateNameClause
| project id, name, type, location, properties, ClusterName_, ClusterResourceId_, UpdateName_, ts = todatetime(properties.timeStarted)
| order by ts desc
"@

    try {
        $argParams = @{ Query = $runsKql }
        if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
        $allRunsRaw = Invoke-AzResourceGraphQuery @argParams
    }
    catch {
        Write-Log -Message "Azure Resource Graph query for update runs failed: $($_.Exception.Message)" -Level Error
        return
    }

    Write-Log -Message "Returned $($allRunsRaw.Count) update run(s) across $($clustersToProcess.Count) cluster(s) via Azure Resource Graph" -Level Success

    # Group rows by ClusterResourceId (lowercased) and build the per-cluster
    # entry table that the downstream UX loop expects. The shape mirrors the
    # legacy parallel-jobs output: { ClusterName, DisplayTag, LatestState,
    # RunCount, Rows[] } where Rows[] is the Format-AzLocalUpdateRun output.
    $runsByCluster = @{}
    foreach ($row in $allRunsRaw) {
        $key = [string]$row.ClusterResourceId_
        if (-not $runsByCluster.ContainsKey($key)) { $runsByCluster[$key] = [System.Collections.Generic.List[object]]::new() }
        $runsByCluster[$key].Add($row) | Out-Null
    }

    $perCluster = @{}
    foreach ($cluster in $clustersToProcess) {
        $key = $cluster.ResourceId.ToLower()
        # NOTE: Do not use `$x = if (...) { @($h[$key]) } else { @() }` here -
        # the `if` block's pipeline return unwraps single-element Object[] to
        # the bare element under PowerShell 5.1, and PSCustomObject.Count is
        # empty (not 1), which would silently mask any cluster having exactly
        # one update run. Assign default then overwrite to preserve array.
        $clusterRuns = @()
        if ($runsByCluster.ContainsKey($key)) { $clusterRuns = @($runsByCluster[$key]) }

        if ($clusterRuns.Count -gt 0) {
            # ARG ordering is already StartTime desc but re-sort defensively
            # in case Resource Graph re-orders rows during pagination.
            $sorted = @($clusterRuns | Sort-Object { $_.properties.timeStarted } -Descending)
            $latestRun = $sorted[0]
            $latestState = [string]$latestRun.properties.state
            $runsToFormat = if ($Latest) { @($latestRun) } else { $sorted }

            $rows = foreach ($run in $runsToFormat) {
                $formatted = Format-AzLocalUpdateRun -run $run -clusterName $cluster.Name -clusterResourceId $cluster.ResourceId
                [PSCustomObject]@{
                    ClusterName       = $cluster.Name
                    ClusterResourceId = $cluster.ResourceId
                    UpdateName        = $formatted.UpdateName
                    RunId             = $formatted.RunId
                    RunResourceId     = $formatted.RunResourceId
                    State             = $formatted.State
                    Status            = $formatted.Status
                    StartTime         = $formatted.StartTime
                    EndTime           = $formatted.EndTime
                    EndTimeUtc        = $formatted.EndTimeUtc
                    LastUpdatedTime   = $formatted.LastUpdatedTime
                    Duration          = $formatted.Duration
                    Progress          = $formatted.Progress
                    CurrentStep       = $formatted.CurrentStep
                    CurrentStepDetail = $formatted.CurrentStepDetail
                    StepStartTime     = $formatted.StepStartTime
                    StepElapsed       = $formatted.StepElapsed
                    ErrorMessage      = $formatted.ErrorMessage
                    ErrorDescription  = if ($formatted.PSObject.Properties['ErrorDescription']) { [string]$formatted.ErrorDescription } else { '' }
                    Location          = $formatted.Location
                }
            }

            $perCluster[$cluster.Name] = [PSCustomObject]@{
                ClusterName = $cluster.Name
                DisplayTag  = 'Runs'
                LatestState = $latestState
                RunCount    = $clusterRuns.Count
                Rows        = @($rows)
            }
        }
        else {
            $perCluster[$cluster.Name] = [PSCustomObject]@{
                ClusterName = $cluster.Name
                DisplayTag  = 'NoRuns'
                LatestState = $null
                RunCount    = 0
                Rows        = @([PSCustomObject]@{
                        ClusterName       = $cluster.Name
                        ClusterResourceId = $cluster.ResourceId
                        UpdateName        = 'None'
                        RunId             = ''
                        RunResourceId     = ''
                        State             = 'No Runs'
                        Status            = ''
                        StartTime         = ''
                        EndTime           = ''
                        EndTimeUtc        = $null
                        Duration          = ''
                        Progress          = ''
                        CurrentStep       = ''
                        CurrentStepDetail = ''
                        StepStartTime     = ''
                        StepElapsed       = ''
                        ErrorMessage      = ''
                        ErrorDescription  = ''
                        Location          = ''
                    })
            }
        }
    }

    foreach ($cluster in $clustersToProcess) {
        $entry = $perCluster[$cluster.Name]
        if (-not $entry) { continue }

        Write-Host "  Checking: $($cluster.Name)..." -ForegroundColor Gray -NoNewline
        switch -Regex ($entry.DisplayTag) {
            '^NotFound$' { Write-Host ' Not Found' -ForegroundColor Red }
            '^NoRuns$'   { Write-Host ' No runs' -ForegroundColor Gray }
            '^Error:(.*)' { Write-Host " Error: $($matches[1])" -ForegroundColor Red }
            '^Runs$' {
                $stateColor = switch ($entry.LatestState) {
                    'Succeeded'  { 'Green' }
                    'InProgress' { 'Yellow' }
                    'Failed'     { 'Red' }
                    default      { 'Gray' }
                }
                Write-Host " $($entry.RunCount) run(s), latest: $($entry.LatestState)" -ForegroundColor $stateColor

                if ($entry.LatestState) {
                    if ($stateCounts.ContainsKey($entry.LatestState)) {
                        $stateCounts[$entry.LatestState]++
                    }
                    else {
                        $stateCounts[$entry.LatestState] = 1
                    }
                }
            }
            default { Write-Host '' -ForegroundColor Gray }
        }

        foreach ($row in @($entry.Rows)) {
            $allFormattedRuns.Add($row) | Out-Null
        }
    }

    # Display Summary
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Summary" -Level Header
    Write-Log -Message "========================================" -Level Header
    
    $totalClusters = $clustersToProcess.Count
    Write-Log -Message "" -Level Info
    Write-Log -Message "Total Clusters: $totalClusters" -Level Info
    
    if ($stateCounts.Count -gt 0) {
        Write-Log -Message "Latest Run States:" -Level Header
        foreach ($state in $stateCounts.Keys | Sort-Object) {
            $level = switch ($state) {
                "Succeeded" { "Success" }
                "Failed" { "Error" }
                "InProgress" { "Warning" }
                default { "Info" }
            }
            Write-Log -Message "  $state`: $($stateCounts[$state])" -Level $level
        }
    }

    # Display results table
    Write-Log -Message "" -Level Info
    Write-Log -Message "Update Runs:" -Level Header
    $allFormattedRuns | Format-Table ClusterName, UpdateName, State, StartTime, EndTime, Duration, Progress -AutoSize | Out-Host

    # Check for health-check-blocked failures and show diagnostics
    $healthBlockedRuns = @($allFormattedRuns | Where-Object { $_.State -eq "Failed" -and $_.CurrentStep -match "health check" })
    if ($healthBlockedRuns.Count -gt 0) {
        $affectedClusters = @($healthBlockedRuns | Select-Object -ExpandProperty ClusterName -Unique)
        Write-Log -Message "" -Level Info
        Write-Log -Message "Detected $($healthBlockedRuns.Count) update run(s) blocked by health check failures." -Level Warning
        Write-Log -Message "Querying current health check status for affected cluster(s)..." -Level Info
        
        foreach ($affectedCluster in $affectedClusters) {
            # Find the resource ID for this cluster from the clusters we already processed
            $clusterEntry = $clustersToProcess | Where-Object { $_.Name -eq $affectedCluster }
            $rid = $clusterEntry.ResourceId
            if (-not $rid) { continue }
            
            # -PassThru required (v0.7.62 fix); see Step 3b in Start-AzLocalClusterUpdate.
            $healthResults = Test-AzLocalClusterHealth -ClusterResourceIds @($rid) -BlockingOnly -PassThru
            if ($healthResults -and $healthResults[0].CriticalCount -gt 0) {
                Write-Log -Message "" -Level Info
                Write-Log -Message "Critical health issues blocking updates on '$affectedCluster':" -Level Error
                foreach ($failure in $healthResults[0].Failures) {
                    $nodeInfo = if ($failure.TargetResourceName) { " (Node: $($failure.TargetResourceName))" } else { "" }
                    Write-Log -Message "  [Critical] $($failure.CheckName)$nodeInfo`: $($failure.Description)" -Level Error
                    if ($failure.Remediation) {
                        Write-Log -Message "    Remediation: $($failure.Remediation)" -Level Warning
                    }
                }
            }
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
            
            switch ($format) {
                'Csv' {
                    $allFormattedRuns | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
                    Write-Log -Message "Results exported to CSV: $ExportPath" -Level Success
                }
                'Json' {
                    $exportData = @{
                        Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        TotalClusters = $totalClusters
                        StateSummary  = $stateCounts
                        Results       = $allFormattedRuns
                    }
                    Write-Utf8NoBomFile -Path $ExportPath -Content ($exportData | ConvertTo-Json -Depth 10)
                    Write-Log -Message "Results exported to JSON: $ExportPath" -Level Success
                }
                'JUnitXml' {
                    $junitResults = $allFormattedRuns | ForEach-Object {
                        [PSCustomObject]@{
                            ClusterName  = $_.ClusterName
                            Status       = if ($_.State -eq "Succeeded") { "Passed" } elseif ($_.State -in @("Failed", "Error")) { "Failed" } else { "Skipped" }
                            Message      = "Update: $($_.UpdateName), State: $($_.State), Duration: $($_.Duration), Progress: $($_.Progress)"
                            UpdateName   = $_.UpdateName
                            CurrentState = $_.State
                            StartTime    = $_.StartTime
                            EndTime      = $_.EndTime
                            Duration     = $_.Duration
                            Progress     = $_.Progress
                        }
                    }
                    Export-ResultsToJUnitXml -Results $junitResults -OutputPath $ExportPath `
                        -TestSuiteName "AzureLocalUpdateRuns" -OperationType "UpdateRuns"
                    Write-Log -Message "Results exported to JUnit XML: $ExportPath" -Level Success
                }
            }
        }
        catch {
            Write-Log -Message "Failed to export results: $($_.Exception.Message)" -Level Error
        }
    }

    Write-Log -Message "" -Level Info

    # Display latest run details per cluster
    if ($allFormattedRuns.Count -gt 0) {
        $latestPerCluster = $allFormattedRuns | Group-Object ClusterName | ForEach-Object {
            $_.Group | Sort-Object StartTime -Descending | Select-Object -First 1
        }
        Write-Log -Message "Latest Update Run per Cluster:" -Level Header
        Write-Host ""
        $latestPerCluster | Format-List | Out-String -Stream | ForEach-Object {
            if ($_ -ne "") { Write-Host "`t$_" }
        }
        Write-Host ""
    }

    # v0.7.1: Sideloaded auto-reset (default ON; -SkipSideloadedReset to disable).
    if (-not $SkipSideloadedReset -and $allFormattedRuns.Count -gt 0) {
        try {
            [void](Invoke-AzLocalSideloadedAutoReset -FormattedRuns $allFormattedRuns -ApiVersion $ApiVersion)
        }
        catch {
            Write-Log -Message "Sideloaded auto-reset failed: $($_.Exception.Message)" -Level Warning
        }
    }

    if ($PassThru) {
        return $allFormattedRuns
    }
}
