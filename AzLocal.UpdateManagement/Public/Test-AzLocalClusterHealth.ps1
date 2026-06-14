function Test-AzLocalClusterHealth {
    <#
    .SYNOPSIS
        Validates cluster health before applying updates by checking for blocking health check failures.
    
    .DESCRIPTION
        Queries the health check results from each cluster's update summary to identify
        Critical, Warning, and Informational failures. Critical failures block updates
        from being applied.
        
        This function can be used as a standalone pre-flight check or is called
        automatically by Start-AzLocalClusterUpdate before applying updates.
        
        Health check data is stored in ARM on the cluster's updateSummaries resource
        and is refreshed approximately every 24 hours.
    
    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to check.
    
    .PARAMETER ClusterNames
        An array of Azure Local cluster names to check.
    
    .PARAMETER ScopeByUpdateRingTag
        Find clusters by their 'UpdateRing' tag value via Azure Resource Graph.
    
    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.
    
    .PARAMETER ResourceGroupName
        Resource group containing the clusters (only used with -ClusterNames).
    
    .PARAMETER SubscriptionId
        Azure subscription ID (defaults to current subscription).
    
    .PARAMETER BlockingOnly
        Show only Critical severity failures (the ones that block updates).
    
    .PARAMETER ApiVersion
        Azure REST API version to use. Default: "2025-10-01".
    
    .PARAMETER ExportPath
        Export results to CSV (.csv), JSON (.json), or JUnit XML (.xml) file.
    
    .PARAMETER ExportFormat
        Explicit format to use when writing -ExportPath. One of: Auto, Csv, Json, JUnitXml.
        Default: Auto (resolved from the file extension of -ExportPath; unknown extensions fall back to Csv).
        Use this to write a specific format regardless of extension (e.g. a JUnit XML file with a .xml name but CI-picked parser).
    
    .PARAMETER UpdateSummary
        Pre-fetched update summary object from Get-AzLocalUpdateSummary.
        When provided, skips the internal summary fetch to avoid redundant API calls.
        Only used when checking a single cluster via -ClusterResourceIds with one ID.
    
    .OUTPUTS
        PSCustomObject[] - Array of health check results per cluster.
    
    .EXAMPLE
        Test-AzLocalClusterHealth -ClusterResourceIds @("/subscriptions/.../clusters/Seattle")
        Checks health for a single cluster by resource ID.
    
    .EXAMPLE
        Test-AzLocalClusterHealth -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -BlockingOnly
        Shows only Critical (update-blocking) health failures for all Wave1 clusters.
    
    .EXAMPLE
        Test-AzLocalClusterHealth -ClusterNames "MyCluster" -ExportPath "C:\Reports\health.csv"
        Checks health and exports results to CSV.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByResourceId')]
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

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByResourceId')]
        [Parameter(Mandatory = $false, ParameterSetName = 'ByTag')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [switch]$BlockingOnly,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false)]
        [string]$ExportPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Auto', 'Csv', 'Json', 'JUnitXml')]
        [string]$ExportFormat = 'Auto',

        [Parameter(Mandatory = $false)]
        [object]$UpdateSummary,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Pre-flight: Validate export path is writable before expensive operations
    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { Write-Warning $_.Exception.Message; return }
    }

    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local Cluster Health Validation" -Level Header
    Write-Log -Message "========================================" -Level Header

    # Verify Azure CLI
    Test-AzCliAvailable | Out-Null
    try {
        $null = az account show 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Not logged in" }
        Write-Log -Message "Azure CLI authentication verified" -Level Success
    }
    catch {
        Write-Log -Message "Azure CLI is not logged in. Please run 'az login' first." -Level Error
        return
    }

    # Ensure resource-graph extension is installed (the cmdlet is fully
    # ARG-driven from v0.7.68 - single batched updatesummaries query replaces
    # the per-cluster ARM REST fan-out).
    if (-not (Install-AzGraphExtension)) {
        Write-Error "Failed to install Azure CLI 'resource-graph' extension. Please install manually: az extension add --name resource-graph"
        return
    }

    # Build cluster list (reuse existing patterns)
    $clustersToCheck = @()

    if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
        $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' $ringFilter | project id, name, resourceGroup, subscriptionId"
        try {
            $argParams = @{ Query = $argQuery }
            if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
            $clusters = Invoke-AzResourceGraphQuery @argParams
        }
        catch {
            Write-Log -Message "Azure Resource Graph query failed: $($_.Exception.Message)" -Level Error
            return
        }
        if (-not $clusters -or $clusters.Count -eq 0) {
            Write-Log -Message "No clusters found with UpdateRing = '$UpdateRingValue'" -Level Warning
            return @()
        }
        foreach ($c in $clusters) {
            $clustersToCheck += @{ ResourceId = $c.id; Name = $c.name }
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
        foreach ($rid in $ClusterResourceIds) {
            $clustersToCheck += @{ ResourceId = $rid; Name = ($rid -split '/')[-1] }
        }
    }
    else {
        # ByName - v0.7.68: single ARG batch lookup replaces the per-name
        # Get-AzLocalClusterInfo ARM REST loop.
        $nameListKql = ($ClusterNames | ForEach-Object { "'$($_.ToLower())'" }) -join ','
        $rgFilter = ''
        if ($ResourceGroupName) { $rgFilter = "| where tolower(resourceGroup) =~ '$($ResourceGroupName.ToLower())'" }
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where tolower(name) in~ ($nameListKql) $rgFilter | project id, name, resourceGroup, subscriptionId"
        try {
            $argParams = @{ Query = $argQuery }
            if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
            $clusterRows = Invoke-AzResourceGraphQuery @argParams
        }
        catch {
            Write-Log -Message "Error resolving cluster names via Azure Resource Graph: $_" -Level Error
            return
        }
        $foundNames = @{}
        foreach ($cluster in @($clusterRows)) { $foundNames[$cluster.name.ToLower()] = $cluster }
        foreach ($name in $ClusterNames) {
            $key = $name.ToLower()
            if ($foundNames.ContainsKey($key)) {
                $cluster = $foundNames[$key]
                $clustersToCheck += @{ ResourceId = $cluster.id; Name = $cluster.name }
            }
            else {
                Write-Log -Message "Cluster '$name' not found - skipping" -Level Warning
            }
        }
    }

    if (-not $clustersToCheck -or $clustersToCheck.Count -eq 0) {
        Write-Log -Message "No clusters resolved for health validation." -Level Warning
        return @()
    }

    Write-Log -Message "Checking health for $($clustersToCheck.Count) cluster(s)..." -Level Info

    $results = @()
    $overallPassed = $true

    # v0.7.68: Batch every cluster's update summary into one Azure Resource
    # Graph query. The previous design made one ARM REST call per cluster
    # (optionally parallelised across Start-Job runspaces). ARG returns the
    # same `properties.healthCheckResult` shape as the ARM REST response, so
    # the downstream parsing logic is unchanged.
    #
    # Fast-path: when the caller pre-fetched the summary (used by
    # Start-AzLocalClusterUpdate's single-cluster invocation), skip the
    # ARG query and use the supplied object directly.
    $summaryByCluster = @{}
    if ($UpdateSummary -and $clustersToCheck.Count -eq 1) {
        $summaryByCluster[$clustersToCheck[0].ResourceId.ToLower()] = $UpdateSummary
    }
    else {
        $idListKql = ($clustersToCheck | ForEach-Object { "'$($_.ResourceId.ToLower())'" }) -join ','
        $summariesKql = "extensibilityresources | where type =~ 'microsoft.azurestackhci/clusters/updatesummaries' | extend ids = split(id, '/') | extend ClusterResourceId_ = tolower(strcat('/subscriptions/', tostring(ids[2]), '/resourceGroups/', tostring(ids[4]), '/providers/Microsoft.AzureStackHCI/clusters/', tostring(ids[8]))) | where ClusterResourceId_ in~ ($idListKql) | project id, name, properties, ClusterResourceId_"
        try {
            $argParams = @{ Query = $summariesKql }
            if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }
            $summaryRows = Invoke-AzResourceGraphQuery @argParams
        }
        catch {
            Write-Log -Message "Azure Resource Graph query for update summaries failed: $($_.Exception.Message)" -Level Error
            return
        }
        foreach ($row in @($summaryRows)) {
            $summaryByCluster[[string]$row.ClusterResourceId_] = $row
        }
        Write-Log -Message "Returned $(@($summaryRows).Count) update-summary record(s) via Azure Resource Graph" -Level Success
    }

    foreach ($cluster in $clustersToCheck) {
        $clusterName = $cluster.Name
        Write-Host "  Checking: $clusterName..." -ForegroundColor Gray -NoNewline

        try {
            $key = $cluster.ResourceId.ToLower()
            $summary = if ($summaryByCluster.ContainsKey($key)) { $summaryByCluster[$key] } else { $null }

            # v0.8.77: guard property reads with PSObject.Properties because
            # `$summary.properties.healthCheckResult` (bare access) THROWS under
            # Set-StrictMode -Version Latest when `healthCheckResult` is absent
            # on the `properties` PSCustomObject. Clusters whose ARM update
            # summary genuinely has no health-check data (typical for clusters
            # that have not had an update-readiness probe yet) were producing
            # `Checking: <ClusterName>... Error: The property 'healthCheckResult'
            # cannot be found on this object.` in Step.05/06/07 production runs,
            # which then poisoned the readiness gate (Passed=$false flagged the
            # cluster as blocked when it was simply un-probed).
            $summaryProps = if ($summary) { $summary.PSObject.Properties['properties'] } else { $null }
            $hasHCR = $summaryProps -and $summary.properties.PSObject.Properties['healthCheckResult'] -and $summary.properties.healthCheckResult
            if (-not $hasHCR) {
                Write-Host " No Health Data" -ForegroundColor Yellow
                $results += [PSCustomObject]@{
                    ClusterName = $clusterName; HealthState = "No Data"; Passed = $true
                    CriticalCount = 0; WarningCount = 0; Failures = @()
                }
                continue
            }

            $healthState = if ($summary.properties.PSObject.Properties['healthState'] -and $summary.properties.healthState) { [string]$summary.properties.healthState } else { "Unknown" }
            $healthChecks = $summary.properties.healthCheckResult

            # Extract failures (Critical and Warning only; use -BlockingOnly for Critical only)
            $failures = @()
            # Track seen rows for dedup. The ARM updateSummaries.healthCheckResult feed
            # sometimes emits byte-identical duplicate entries for the same logical
            # check (observed in v0.7.76 on a 2-node Azure Local cluster where the
            # "Test Network intent on existing cluster nodes" check emitted two
            # rows with identical CheckName/Severity/Description/Remediation/
            # TargetResourceName/Timestamp). Faithfully echoing those into the
            # operator's CSV doubled the displayed failure count and made
            # Step.5_assess-update-readiness.yml reports confusing. We dedup
            # by the COMPLETE row tuple: if every field is identical the row is
            # a duplicate; per-node distinct findings (different TargetResource
            # Name or Timestamp) stay separate.
            $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]'
            # Composite-key field separator. U+001F (UNIT SEPARATOR) is never
            # present in human-readable strings so no field value can ever
            # collide with a separator boundary. Windows PowerShell 5.1 does
            # not support the `u{XXXX} escape so we build the char explicitly.
            $usSep = [char]0x1F
            foreach ($check in $healthChecks) {
                if ($check.status -eq "Failed") {
                    $sev = if ($check.severity) { $check.severity } else { "Unknown" }
                    if ($BlockingOnly -and $sev -ne "Critical") { continue }
                    if ($sev -eq "Informational") { continue }
                    $displayName = if ($check.displayName) { $check.displayName } elseif ($check.name) { ($check.name -split '/')[0] } else { "Unknown" }
                    $description = if ($check.description) { $check.description } else { "" }
                    $remediation = if ($check.remediation) { $check.remediation } else { "" }
                    $targetResName = if ($check.targetResourceName) { $check.targetResourceName } else { "" }
                    $timestamp = if ($check.timestamp) { $check.timestamp } else { "" }
                    $key = $clusterName + $usSep + $displayName + $usSep + $sev + $usSep + $description + $usSep + $remediation + $usSep + $targetResName + $usSep + $timestamp
                    if (-not $seenKeys.Add($key)) {
                        Write-Verbose "Suppressing duplicate healthCheckResult row for cluster '$clusterName' check '$displayName' target '$targetResName' timestamp '$timestamp' (ARM upstream duplicate)."
                        continue
                    }
                    $failures += [PSCustomObject]@{
                        ClusterName        = $clusterName
                        CheckName          = $displayName
                        Severity           = $sev
                        Description        = $description
                        Remediation        = $remediation
                        TargetResourceName = $targetResName
                        Timestamp          = $timestamp
                    }
                }
            }

            $critCount = @($failures | Where-Object { $_.Severity -eq "Critical" }).Count
            $warnCount = @($failures | Where-Object { $_.Severity -eq "Warning" }).Count
            $passed = ($critCount -eq 0)
            if (-not $passed) { $overallPassed = $false }

            # Console output
            if ($passed -and $failures.Count -eq 0) {
                Write-Host " Healthy" -ForegroundColor Green
            }
            elseif ($passed) {
                Write-Host " Warnings ($warnCount)" -ForegroundColor Yellow
            }
            else {
                Write-Host " BLOCKED ($critCount critical)" -ForegroundColor Red
            }

            $results += [PSCustomObject]@{
                ClusterName   = $clusterName
                HealthState   = $healthState
                Passed        = $passed
                CriticalCount = $critCount
                WarningCount  = $warnCount
                Failures      = $failures
            }
        }
        catch {
            Write-Host " Error: $($_.Exception.Message)" -ForegroundColor Red
            $results += [PSCustomObject]@{
                ClusterName = $clusterName; HealthState = "Error"; Passed = $false
                CriticalCount = 0; WarningCount = 0; Failures = @()
            }
            $overallPassed = $false
        }
    }

    # Summary
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Health Validation Summary" -Level Header
    Write-Log -Message "========================================" -Level Header

    $totalClusters = $results.Count
    $passedCount = @($results | Where-Object { $_.Passed -eq $true }).Count
    $failedCount = $totalClusters - $passedCount

    Write-Log -Message "Total Clusters:  $totalClusters" -Level Info
    Write-Log -Message "Passed:          $passedCount (no critical failures)" -Level $(if ($passedCount -eq $totalClusters) { "Success" } else { "Info" })
    Write-Log -Message "Blocked:         $failedCount (critical failures present)" -Level $(if ($failedCount -gt 0) { "Error" } else { "Info" })

    # Display failure details
    $allFailures = @($results | ForEach-Object { $_.Failures } | Where-Object { $_ })
    if ($allFailures.Count -gt 0) {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Health Check Failures:" -Level Header
        $allFailures | Format-Table ClusterName, Severity, CheckName, TargetResourceName, Description -AutoSize -Wrap | Out-String -Stream | ForEach-Object {
            if ($_ -ne "") { Write-Log -Message $_ -Level Info }
        }

        # Show remediation for Critical failures
        $criticalFailures = @($allFailures | Where-Object { $_.Severity -eq "Critical" })
        if ($criticalFailures.Count -gt 0) {
            Write-Log -Message "" -Level Info
            Write-Log -Message "Remediation for Critical (Update-Blocking) Failures:" -Level Warning
            foreach ($f in $criticalFailures) {
                if ($f.Remediation) {
                    $nodeInfo = if ($f.TargetResourceName) { " ($($f.TargetResourceName))" } else { "" }
                    Write-Log -Message "  $($f.ClusterName) - $($f.CheckName)$nodeInfo`: $($f.Remediation)" -Level Warning
                }
            }
        }
    }
    else {
        Write-Log -Message "" -Level Info
        Write-Log -Message "No health check failures detected. All clusters are ready for updates." -Level Success
    }

    # Overall result
    Write-Log -Message "" -Level Info
    if ($overallPassed) {
        Write-Log -Message "HEALTH VALIDATION PASSED - All clusters are ready for updates" -Level Success
    }
    else {
        Write-Log -Message "HEALTH VALIDATION FAILED - Critical health issues must be resolved before updates can proceed" -Level Error
    }

    # Export if path specified
    if ($ExportPath -and $allFailures.Count -gt 0) {
        try {
            $ExportPath = Resolve-SafeOutputPath -Path $ExportPath
            $exportDir = Split-Path -Path $ExportPath -Parent
            if ($exportDir -and -not (Test-Path $exportDir)) {
                New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
            }
            # Resolve effective format: explicit -ExportFormat wins; 'Auto' falls back
            # to file-extension detection for backward compatibility.
            $effectiveFormat = $ExportFormat
            if ($effectiveFormat -eq 'Auto') {
                $extension = [System.IO.Path]::GetExtension($ExportPath).ToLower()
                $effectiveFormat = switch ($extension) {
                    '.csv'  { 'Csv' }
                    '.json' { 'Json' }
                    '.xml'  { 'JUnitXml' }
                    default { 'Csv' }
                }
            }
            switch ($effectiveFormat) {
                'Csv' {
                    $allFailures | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
                    Write-Log -Message "Results exported to CSV: $ExportPath" -Level Success
                }
                'Json' {
                    $exportData = @{
                        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        OverallPassed = $overallPassed
                        TotalClusters = $totalClusters
                        Passed = $passedCount
                        Blocked = $failedCount
                        Failures = $allFailures
                    }
                    Write-Utf8NoBomFile -Path $ExportPath -Content ($exportData | ConvertTo-Json -Depth 10)
                    Write-Log -Message "Results exported to JSON: $ExportPath" -Level Success
                }
                'JUnitXml' {
                    $junitResults = $allFailures | ForEach-Object {
                        $junitNodeInfo = if ($_.TargetResourceName) { " (Node: $($_.TargetResourceName))" } else { "" }
                        [PSCustomObject]@{
                            ClusterName = $_.ClusterName; Status = "Failed"
                            Message = "$($_.Severity): $($_.CheckName)$junitNodeInfo - $($_.Description)"
                            UpdateName = $_.CheckName; CurrentState = $_.Severity
                        }
                    }
                    Export-ResultsToJUnitXml -Results $junitResults -OutputPath $ExportPath `
                        -TestSuiteName "AzureLocalClusterHealth" -OperationType "HealthCheck"
                    Write-Log -Message "Results exported to JUnit XML: $ExportPath" -Level Success
                }
            }
        }
        catch {
            Write-Log -Message "Failed to export results: $($_.Exception.Message)" -Level Error
        }
    }

    if ($PassThru) {
        return $results
    }
}
