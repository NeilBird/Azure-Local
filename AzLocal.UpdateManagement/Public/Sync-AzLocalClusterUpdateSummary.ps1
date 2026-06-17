function Sync-AzLocalClusterUpdateSummary {
    <#
    .SYNOPSIS
        Triggers a fresh "Check for updates" scan on one or more Azure Local clusters.

    .DESCRIPTION
        Forces Azure Local (Azure Stack HCI) clusters to re-evaluate their update
        availability by POSTing to the cluster's
        `updateSummaries/default/checkUpdates` ARM action - the programmatic
        equivalent of the Azure portal "Check for updates" button.

        This is the remediation for a STALE update assessment: a cluster can report
        `state = AppliedSuccessfully` / "Up to date" while a newer solution version is
        actually available, because its cached assessment has not been refreshed. The
        checkUpdates action makes the cluster re-scan and (when a newer build exists)
        flip to `UpdateAvailable`, surfacing the recommended update.

        The action is asynchronous on the ARM side (returns 202 Accepted and runs a
        long-running operation on the cluster):

          - Default (fire-and-forget): the cmdlet POSTs checkUpdates and returns
            immediately with a `Triggered` result per cluster. This is the safe
            default for fleet use - an offline or busy cluster cannot stall the run.

          - -Wait: after triggering, the cmdlet polls the cluster's
            `updateSummaries/default` until `properties.lastChecked` advances past the
            pre-trigger baseline (or -TimeoutSeconds elapses), then stores the
            refreshed summary payload on the returned object (UpdateState,
            CurrentVersion, LastChecked, AvailableUpdateCount, and the raw
            UpdateSummary object).

        Clusters are selected by name, by Resource ID, or by their 'UpdateRing' tag,
        mirroring Start-AzLocalClusterUpdate / Get-AzLocalUpdateSummary.

    .PARAMETER ClusterNames
        Array of cluster names to scan. Use this OR -ClusterResourceIds OR -ScopeByUpdateRingTag.

    .PARAMETER ClusterResourceIds
        Array of full Azure Resource IDs for clusters. Use when clusters are in different
        resource groups, or when the caller has already resolved the IDs.

    .PARAMETER ScopeByUpdateRingTag
        Switch to find clusters by their 'UpdateRing' tag value via Azure Resource Graph.

    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.

    .PARAMETER ResourceGroupName
        Resource group containing the clusters (only used with -ClusterNames).

    .PARAMETER SubscriptionId
        Azure subscription ID (defaults to the current az CLI subscription).

    .PARAMETER ApiVersion
        Azure REST API version for both the checkUpdates POST and the updateSummaries
        poll. Defaults to "2026-03-01-preview" - the checkUpdates action is only exposed
        on the preview API surface.

    .PARAMETER Wait
        Opt-in. After triggering, poll the cluster's updateSummaries until the scan
        completes (lastChecked advances) or -TimeoutSeconds elapses, and attach the
        refreshed summary data to the result object.

    .PARAMETER TimeoutSeconds
        Maximum seconds to wait per cluster when -Wait is set. Default 300.

    .PARAMETER PollIntervalSeconds
        Seconds between updateSummaries polls when -Wait is set. Default 15.

    .PARAMETER Force
        Skip the confirmation prompt (checkUpdates is a state-changing action).

    .PARAMETER PassThru
        Emit a result object per cluster to the pipeline.

    .OUTPUTS
        PSCustomObject[] - One result per cluster: ClusterName, ClusterResourceId,
        ResourceGroup, SubscriptionId, Triggered, Status, Message. When -Wait completed
        a poll, also: PreviousLastChecked, LastChecked, UpdateState, CurrentVersion,
        AvailableUpdateCount, WaitedSeconds, UpdateSummary (raw refreshed payload).

    .EXAMPLE
        Sync-AzLocalClusterUpdateSummary -ClusterNames "Sydney" -ResourceGroupName "Prod-RG" -Force
        Fire-and-forget: triggers a fresh update scan on one cluster.

    .EXAMPLE
        Sync-AzLocalClusterUpdateSummary -ClusterNames "Sydney" -Wait -PassThru
        Triggers the scan and waits for it to finish, returning the refreshed summary.

    .EXAMPLE
        Sync-AzLocalClusterUpdateSummary -ScopeByUpdateRingTag -UpdateRingValue "Production" -Force
        Triggers a fresh scan on every cluster tagged UpdateRing=Production.

    .NOTES
        Author: Neil Bird, Microsoft.
        ARM action: POST {clusterId}/updateSummaries/default/checkUpdates?api-version=2026-03-01-preview
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'ByName')]
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
        [string]$ApiVersion = '2026-03-01-preview',

        [Parameter(Mandatory = $false)]
        [switch]$Wait,

        [Parameter(Mandatory = $false)]
        [ValidateRange(30, 3600)]
        [int]$TimeoutSeconds = 300,

        [Parameter(Mandatory = $false)]
        [ValidateRange(5, 300)]
        [int]$PollIntervalSeconds = 15,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # If -Force is supplied, suppress the per-cluster ShouldProcess confirmation
    # prompt (matches Start-AzLocalClusterUpdate semantics).
    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) {
        $ConfirmPreference = 'None'
    }

    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local - Check for Updates (refresh assessment)" -Level Header
    Write-Log -Message "========================================" -Level Header

    # Verify Azure CLI is installed and logged in.
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

    # Build list of clusters to process: each entry is @{ Name; ResourceId; ResourceGroup; SubscriptionId; NotFound }
    $clustersToProcess = [System.Collections.Generic.List[object]]::new()

    if ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
        # Trust caller-supplied Resource IDs directly (no ARG round trip). This is
        # the path the readiness auto-scan uses - IDs are already resolved.
        foreach ($resourceId in $ClusterResourceIds) {
            $clusterRgName = ($resourceId -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
            $clusterSubId = ($resourceId -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
            $clustersToProcess.Add([pscustomobject]@{
                    Name           = ($resourceId -split '/')[-1]
                    ResourceId     = $resourceId
                    ResourceGroup  = $clusterRgName
                    SubscriptionId = $clusterSubId
                    NotFound       = $false
                }) | Out-Null
        }
    }
    else {
        # ByName / ByTag both resolve through Azure Resource Graph.
        if (-not (Install-AzGraphExtension)) {
            Write-Log -Message "Failed to install Azure CLI 'resource-graph' extension." -Level Error
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
            Write-Log -Message "Querying Azure Resource Graph for clusters with tag 'UpdateRing' = '$UpdateRingValue'..." -Level Info
            $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
            $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $ringFilter | project id, name, resourceGroup, subscriptionId"
        }
        else {
            $nameListKql = ($ClusterNames | ForEach-Object { "'$($_.ToLower())'" }) -join ','
            $rgFilter = ''
            if ($ResourceGroupName) {
                $rgFilter = "| where tolower(resourceGroup) =~ '$($ResourceGroupName.ToLower())'"
            }
            $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where tolower(name) in~ ($nameListKql) $rgFilter | project id, name, resourceGroup, subscriptionId"
        }

        try {
            $argParams = @{ Query = $argQuery }
            if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
            $clusterRows = Invoke-AzResourceGraphQuery @argParams
        }
        catch {
            Write-Log -Message "Error resolving clusters via Azure Resource Graph: $($_.Exception.Message)" -Level Error
            return
        }

        if (-not $clusterRows -or @($clusterRows).Count -eq 0) {
            Write-Log -Message "No clusters resolved for the supplied selection." -Level Warning
            return
        }

        if ($PSCmdlet.ParameterSetName -eq 'ByName') {
            $foundNames = @{}
            foreach ($cluster in @($clusterRows)) { $foundNames[$cluster.name.ToLower()] = $cluster }
            foreach ($name in $ClusterNames) {
                if ($foundNames.ContainsKey($name.ToLower())) {
                    $cluster = $foundNames[$name.ToLower()]
                    $clustersToProcess.Add([pscustomobject]@{
                            Name           = $cluster.name
                            ResourceId     = $cluster.id
                            ResourceGroup  = $cluster.resourceGroup
                            SubscriptionId = $cluster.subscriptionId
                            NotFound       = $false
                        }) | Out-Null
                }
                else {
                    Write-Log -Message "Cluster '$name' not found in Azure Resource Graph - skipping" -Level Warning
                }
            }
        }
        else {
            foreach ($cluster in @($clusterRows)) {
                $clustersToProcess.Add([pscustomobject]@{
                        Name           = $cluster.name
                        ResourceId     = $cluster.id
                        ResourceGroup  = $cluster.resourceGroup
                        SubscriptionId = $cluster.subscriptionId
                        NotFound       = $false
                    }) | Out-Null
            }
        }
    }

    if ($clustersToProcess.Count -eq 0) {
        Write-Log -Message "No clusters resolved - nothing to do." -Level Warning
        return
    }

    Write-Log -Message "" -Level Info
    Write-Log -Message "Triggering 'Check for updates' on $($clustersToProcess.Count) cluster(s)..." -Level Info
    Write-Log -Message "" -Level Info

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($cluster in $clustersToProcess) {
        $clusterName = $cluster.Name
        $resourceId = $cluster.ResourceId

        # Base result row; -Wait fields are filled in only when a poll completes.
        $row = [ordered]@{
            ClusterName          = $clusterName
            ClusterResourceId    = $resourceId
            ResourceGroup        = $cluster.ResourceGroup
            SubscriptionId       = $cluster.SubscriptionId
            Triggered            = $false
            Status               = 'NotAttempted'
            Message              = ''
            PreviousLastChecked  = $null
            LastChecked          = $null
            UpdateState          = $null
            CurrentVersion       = $null
            AvailableUpdateCount = $null
            WaitedSeconds        = $null
            UpdateSummary        = $null
        }

        $target = "$clusterName ($resourceId)"
        if (-not $PSCmdlet.ShouldProcess($target, "Trigger 'Check for updates' (refresh update assessment)")) {
            $row.Status = 'Skipped'
            $row.Message = 'Skipped (ShouldProcess / WhatIf)'
            $results.Add([pscustomobject]$row) | Out-Null
            continue
        }

        $summaryUri = "https://management.azure.com$resourceId/updateSummaries/default?api-version=$ApiVersion"

        # Capture the pre-trigger lastChecked baseline only when we intend to wait.
        $baselineLastChecked = $null
        if ($Wait) {
            $baselineResp = Invoke-AzRestJson -Uri $summaryUri -Method GET
            if ($baselineResp.Ok -and $baselineResp.Data -and $baselineResp.Data.PSObject.Properties['properties']) {
                $baselineProps = $baselineResp.Data.properties
                if ($baselineProps.PSObject.Properties['lastChecked'] -and $baselineProps.lastChecked) {
                    try { $baselineLastChecked = [datetime]$baselineProps.lastChecked } catch { $baselineLastChecked = $null }
                }
                $row.PreviousLastChecked = if ($baselineProps.PSObject.Properties['lastChecked']) { [string]$baselineProps.lastChecked } else { $null }
            }
        }

        # Fire the checkUpdates action (empty body POST -> 202 Accepted / async LRO).
        $checkUri = "https://management.azure.com$resourceId/updateSummaries/default/checkUpdates?api-version=$ApiVersion"
        Write-Log -Message "  $clusterName : POST checkUpdates" -Level Info
        $postResp = Invoke-AzRestJson -Uri $checkUri -Method POST

        if (-not $postResp.Ok) {
            $errorText = [string]$postResp.Error
            $row.Status = 'Failed'
            $row.Message = "checkUpdates POST failed: $errorText"
            # Always echo the raw error (which, for an RBAC denial, contains the
            # exact 'Action' string and scope) so it is captured in the pipeline
            # console log even on the fire-and-forget auto-scan path.
            Write-Log -Message "  $clusterName : FAILED - $errorText" -Level Error

            # Make an authorization / 403 denial unmistakable. The least-privilege
            # custom role 'Azure Stack HCI Update Operator (custom)' does NOT yet
            # authorize checkUpdates (the preview action is absent from the
            # Microsoft.AzureStackHCI provider operations catalog, so it cannot be
            # added to a custom role today). Use 'Azure Stack HCI Administrator' or
            # 'Contributor' until checkUpdates GAs, then add the action surfaced in
            # the error below to the custom role.
            if ($errorText -match 'AuthorizationFailed|does not have authorization|Forbidden|\b403\b') {
                $row.Status = 'AuthorizationFailed'
                Write-Log -Message "  $clusterName : AUTHORIZATION ERROR - the signed-in identity is not permitted to run 'Check for updates' (checkUpdates). Copy the exact 'Action' name and scope from the error line above; grant that action (or assign 'Azure Stack HCI Administrator' / 'Contributor'). The least-privilege custom role does not yet include the preview checkUpdates action." -Level Warning
            }

            $results.Add([pscustomobject]$row) | Out-Null
            continue
        }

        $row.Triggered = $true
        $row.Status = 'Triggered'
        $row.Message = 'checkUpdates accepted; assessment refresh in progress.'
        Write-Log -Message "  $clusterName : triggered" -Level Success

        if (-not $Wait) {
            $results.Add([pscustomobject]$row) | Out-Null
            continue
        }

        # -Wait: poll updateSummaries until lastChecked advances past the baseline
        # (scan completed) or the timeout elapses.
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $completed = $false
        $lastSummaryData = $null
        while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            Start-Sleep -Seconds $PollIntervalSeconds
            $pollResp = Invoke-AzRestJson -Uri $summaryUri -Method GET
            if (-not $pollResp.Ok -or -not $pollResp.Data) { continue }
            $lastSummaryData = $pollResp.Data
            $pollProps = if ($pollResp.Data.PSObject.Properties['properties']) { $pollResp.Data.properties } else { $null }
            if (-not $pollProps) { continue }

            $pollLastChecked = $null
            if ($pollProps.PSObject.Properties['lastChecked'] -and $pollProps.lastChecked) {
                try { $pollLastChecked = [datetime]$pollProps.lastChecked } catch { $pollLastChecked = $null }
            }

            $advanced = $false
            if ($null -ne $pollLastChecked) {
                if ($null -eq $baselineLastChecked) { $advanced = $true }
                elseif ($pollLastChecked -gt $baselineLastChecked) { $advanced = $true }
            }

            if ($advanced) {
                $completed = $true
                break
            }
        }
        $stopwatch.Stop()
        $row.WaitedSeconds = [int]$stopwatch.Elapsed.TotalSeconds

        if ($lastSummaryData) {
            $row.UpdateSummary = $lastSummaryData
            $finalProps = if ($lastSummaryData.PSObject.Properties['properties']) { $lastSummaryData.properties } else { $null }
            if ($finalProps) {
                if ($finalProps.PSObject.Properties['state']) { $row.UpdateState = [string]$finalProps.state }
                if ($finalProps.PSObject.Properties['currentVersion']) { $row.CurrentVersion = [string]$finalProps.currentVersion }
                if ($finalProps.PSObject.Properties['lastChecked']) { $row.LastChecked = [string]$finalProps.lastChecked }
            }
        }

        if ($completed) {
            $row.Status = 'Completed'
            $row.Message = "Assessment refreshed (lastChecked advanced). State: $($row.UpdateState)."
            Write-Log -Message "  $clusterName : refresh completed (state: $($row.UpdateState))" -Level Success
        }
        else {
            $row.Status = 'TimedOut'
            $row.Message = "Triggered, but lastChecked did not advance within $TimeoutSeconds s. Re-check later."
            Write-Log -Message "  $clusterName : wait timed out after $TimeoutSeconds s (scan may still be running)" -Level Warning
        }

        $results.Add([pscustomobject]$row) | Out-Null
    }

    Write-Log -Message "" -Level Info
    $triggeredCount = @($results | Where-Object { $_.Triggered }).Count
    Write-Log -Message "Check for updates: triggered on $triggeredCount of $($clustersToProcess.Count) cluster(s)." -Level Info

    if ($PassThru) {
        return $results.ToArray()
    }
}
