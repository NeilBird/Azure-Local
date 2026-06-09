function Set-AzLocalClusterUpdateRingTag {
    <#
    .SYNOPSIS
        Sets or updates the "UpdateRing" tag on Azure Local clusters for update ring management.
    
    .DESCRIPTION
        This function allows users to assign "UpdateRing" tags to Azure Local clusters
        for organizing update deployment waves. It can accept cluster Resource IDs directly
        or import them from a CSV file (typically exported from Get-AzLocalClusterInventory).
        
        The function will:
        - Verify each Resource ID is a valid microsoft.azurestackhci/clusters resource
        - Check if the cluster already has an "UpdateRing" tag
        - If tag exists: Show warning and skip unless -Force is specified
        - If -Force: Update the tag and log the previous value
        - If no tag exists: Create the new tag
        - Log all operations to a CSV file
    
    .PARAMETER InputCsvPath
        Path to a CSV file containing cluster information. The CSV should have columns:
        - ResourceId: The full Azure Resource ID of the cluster
        - UpdateRing: The value to assign to the UpdateRing tag
        This CSV format is compatible with the output from Get-AzLocalClusterInventory.
        Only rows with a non-empty UpdateRing value will be processed.
    
    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to tag.
        Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"
    
    .PARAMETER UpdateRingValue
        The value to assign to the "UpdateRing" tag (e.g., "Ring1", "Ring2", "Wave1", "Production").
        Required when using -ClusterResourceIds. Not used with -InputCsvPath (values come from CSV).
    
    .PARAMETER UpdateStartWindowValue
        Optional. Value to assign to the "UpdateStartWindow" tag when using -ClusterResourceIds.
        Format: "<days>_<HH:MM>-<HH:MM>" (e.g. "Mon-Fri_22:00-02:00"). See Test-AzLocalUpdateScheduleAllowed
        for syntax details. Not used with -InputCsvPath (values come from the UpdateStartWindow column).
    
    .PARAMETER UpdateExclusionsWindowValue
        Optional. Value to assign to the "UpdateExclusionsWindow" tag when using -ClusterResourceIds.
        Format: "YYYY-MM-DD/YYYY-MM-DD[,...]" (e.g. "2026-12-20/2026-01-05"). Not used with
        -InputCsvPath (values come from the UpdateExclusionsWindow column).
        Renamed from -UpdateExclusionsValue in v0.7.90 (breaking change).

    .PARAMETER UpdateExcludedValue
        Optional. Value to assign to the "UpdateExcluded" operator-override tag when using
        -ClusterResourceIds. Accepts 'True', 'False', '1', '0' (case-insensitive). When 'True',
        Start-AzLocalClusterUpdate will skip the cluster regardless of UpdateRing scope,
        UpdateSideloaded state, or UpdateStartWindow / UpdateExclusionsWindow schedule.
        Not used with -InputCsvPath (values come from the UpdateExcluded column).
        New in v0.7.90.

        Note: regardless of whether this parameter is supplied, this function ALWAYS stamps
        UpdateExcluded='False' on any cluster that does not already carry the tag, so the
        tag is discoverable in the Azure portal and ready for an operator to flip to 'True'.
    
    .PARAMETER Force
        If specified, will overwrite existing "UpdateRing" tags. Without this switch,
        clusters with existing tags will be skipped with a warning.
    
    .PARAMETER LogFolderPath
        Path to the folder where log files will be created. If not specified, defaults to:
        C:\ProgramData\AzLocal.UpdateManagement\
    
    .PARAMETER WhatIf
        Shows what would happen if the cmdlet runs. The cmdlet is not run.
    
    .EXAMPLE
        # Import tags from a CSV file (from Get-AzLocalClusterInventory)
        Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"
    
    .EXAMPLE
        # Set UpdateRing tag on multiple clusters
        $resourceIds = @(
            "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
            "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
        )
        Set-AzLocalClusterUpdateRingTag -ClusterResourceIds $resourceIds -UpdateRingValue "Ring1"
    
    .EXAMPLE
        # Set UpdateRing, UpdateStartWindow, and UpdateExclusionsWindow on clusters in one call
        Set-AzLocalClusterUpdateRingTag -ClusterResourceIds $resourceIds `
            -UpdateRingValue "Wave1" `
            -UpdateStartWindowValue "Mon-Fri_22:00-02:00" `
            -UpdateExclusionsWindowValue "2026-12-20/2026-01-05" -Force
    
    .EXAMPLE
        # Force update existing tags from CSV
        Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -Force
    
    .EXAMPLE
        # Preview changes without applying (from CSV)
        Set-AzLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -WhatIf
    
    .OUTPUTS
        Returns an array of PSCustomObjects with the results for each cluster.
    
    .NOTES
        Requires: Azure CLI (az) installed and authenticated.

        Required RBAC: built-in 'Tag Contributor' role on each cluster (or on
        the resource group / subscription scope that contains the clusters).
        The function writes tags via the dedicated
        Microsoft.Resources/tags/default PATCH endpoint, so only the
        'Microsoft.Resources/tags/write' action is required - NOT the broader
        'microsoft.azurestackhci/clusters/write' (full cluster Contributor).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByResourceId')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByCsv')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$InputCsvPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByResourceId')]
        [string]$UpdateStartWindowValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByResourceId')]
        [string]$UpdateExclusionsWindowValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByResourceId')]
        [ValidateSet('True', 'False', '1', '0', 'true', 'false', '', IgnoreCase = $true)]
        [string]$UpdateExcludedValue,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$LogFolderPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Set default log folder
    if (-not $LogFolderPath) {
        $LogFolderPath = "C:\ProgramData\AzLocal.UpdateManagement"
    }

    # Create log folder if it doesn't exist
    if (-not (Test-Path $LogFolderPath)) {
        New-Item -ItemType Directory -Path $LogFolderPath -Force -WhatIf:$false | Out-Null
    }

    # Create timestamped log file paths
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFilePath = Join-Path $LogFolderPath "UpdateRingTag_$timestamp.log"
    $csvLogPath = Join-Path $LogFolderPath "UpdateRingTag_$timestamp.csv"

    # Initialize CSV with headers
    $csvHeader = '"ClusterName","ResourceGroup","SubscriptionId","ResourceId","Action","PreviousTagValue","NewTagValue","Status","Message"'
    Write-Utf8NoBomFile -Path $csvLogPath -Content ($csvHeader + [Environment]::NewLine)

    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local Cluster UpdateRing Tag Management" -Level Header
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Log file: $($script:LogFilePath)" -Level Info
    Write-Log -Message "CSV log: $csvLogPath" -Level Info

    # Process input based on parameter set
    $clustersToTag = @()
    
    if ($PSCmdlet.ParameterSetName -eq 'ByCsv') {
        Write-Log -Message "Input mode: CSV file" -Level Info
        Write-Log -Message "CSV path: $InputCsvPath" -Level Info
        
        try {
            $csvData = Import-Csv -Path $InputCsvPath
            
            # Validate CSV has required columns
            $requiredColumns = @('ResourceId', 'UpdateRing')
            $csvColumns = $csvData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            
            foreach ($col in $requiredColumns) {
                if ($col -notin $csvColumns) {
                    Write-Log -Message "CSV is missing required column: $col" -Level Error
                    Write-Log -Message "Required columns: $($requiredColumns -join ', ')" -Level Error
                    return
                }
            }
            
            # Filter rows that have both ResourceId and UpdateRing values
            $validRows = @($csvData | Where-Object { 
                $_.ResourceId -and $_.ResourceId.Trim() -ne '' -and 
                $_.UpdateRing -and $_.UpdateRing.Trim() -ne '' 
            })
            
            if ($validRows.Count -eq 0) {
                Write-Log -Message "No valid rows found in CSV (rows must have both ResourceId and UpdateRing values)" -Level Warning
                return
            }
            
            Write-Log -Message "Found $($validRows.Count) row(s) with UpdateRing values to process" -Level Info
            
            # Check for optional UpdateStartWindow, UpdateExclusionsWindow, and UpdateExcluded columns
            $hasUpdateStartWindowCol = 'UpdateStartWindow' -in $csvColumns
            $hasUpdateExclusionsWindowCol = 'UpdateExclusionsWindow' -in $csvColumns
            $hasUpdateExcludedCol = 'UpdateExcluded' -in $csvColumns
            if ($hasUpdateStartWindowCol -or $hasUpdateExclusionsWindowCol -or $hasUpdateExcludedCol) {
                $scheduleColumns = @()
                if ($hasUpdateStartWindowCol) { $scheduleColumns += 'UpdateStartWindow' }
                if ($hasUpdateExclusionsWindowCol) { $scheduleColumns += 'UpdateExclusionsWindow' }
                if ($hasUpdateExcludedCol) { $scheduleColumns += 'UpdateExcluded' }
                Write-Log -Message "CSV includes schedule tag columns: $($scheduleColumns -join ', ')" -Level Info
            }
            
            foreach ($row in $validRows) {
                $entry = @{
                    ResourceId      = $row.ResourceId.Trim()
                    UpdateRingValue = $row.UpdateRing.Trim()
                }
                # Include schedule tag values if columns exist and have values
                if ($hasUpdateStartWindowCol -and $row.UpdateStartWindow -and $row.UpdateStartWindow.Trim() -ne '') {
                    $entry['UpdateStartWindowValue'] = $row.UpdateStartWindow.Trim()
                }
                if ($hasUpdateExclusionsWindowCol -and $row.UpdateExclusionsWindow -and $row.UpdateExclusionsWindow.Trim() -ne '') {
                    $entry['UpdateExclusionsWindowValue'] = $row.UpdateExclusionsWindow.Trim()
                }
                if ($hasUpdateExcludedCol -and $row.UpdateExcluded -and $row.UpdateExcluded.Trim() -ne '') {
                    $entry['UpdateExcludedValue'] = $row.UpdateExcluded.Trim()
                }
                $clustersToTag += $entry
            }
        }
        catch {
            Write-Log -Message "Failed to read CSV file: $($_.Exception.Message)" -Level Error
            return
        }
    }
    else {
        # ByResourceId parameter set
        Write-Log -Message "Input mode: Resource IDs" -Level Info
        Write-Log -Message "UpdateRing value to set: $UpdateRingValue" -Level Info
        if ($UpdateStartWindowValue) {
            Write-Log -Message "UpdateStartWindow value to set: $UpdateStartWindowValue" -Level Info
        }
        if ($UpdateExclusionsWindowValue) {
            Write-Log -Message "UpdateExclusionsWindow value to set: $UpdateExclusionsWindowValue" -Level Info
        }
        if ($UpdateExcludedValue) {
            Write-Log -Message "UpdateExcluded value to set: $UpdateExcludedValue" -Level Info
        }
        
        foreach ($resourceId in $ClusterResourceIds) {
            $entry = @{
                ResourceId      = $resourceId
                UpdateRingValue = $UpdateRingValue
            }
            if ($UpdateStartWindowValue) {
                $entry['UpdateStartWindowValue'] = $UpdateStartWindowValue
            }
            if ($UpdateExclusionsWindowValue) {
                $entry['UpdateExclusionsWindowValue'] = $UpdateExclusionsWindowValue
            }
            if ($UpdateExcludedValue) {
                $entry['UpdateExcludedValue'] = $UpdateExcludedValue
            }
            $clustersToTag += $entry
        }
    }

    Write-Log -Message "Force mode: $Force" -Level Info
    Write-Log -Message "Clusters to process: $($clustersToTag.Count)" -Level Info
    Write-Log -Message "" -Level Info

    # Verify Azure CLI authentication
    Test-AzCliAvailable | Out-Null
    try {
        $null = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message "Azure CLI is not authenticated. Please run 'az login' first." -Level Error
            return
        }
        Write-Log -Message "Azure CLI authentication verified" -Level Success
    }
    catch {
        Write-Log -Message "Azure CLI is not logged in. Please run 'az login' first." -Level Error
        return
    }

    $results = @()

    foreach ($clusterEntry in $clustersToTag) {
        $resourceId = $clusterEntry.ResourceId
        $currentUpdateRingValue = $clusterEntry.UpdateRingValue

        # Derive the cluster short-name from the resource ID for the header line.
        # The full ARM Resource ID is logged separately so operators see both the
        # friendly name (matches the cluster in the Azure portal) and the fully
        # qualified path used for the API call.
        $headerClusterName = ($resourceId -split '/')[-1]
        if ([string]::IsNullOrWhiteSpace($headerClusterName)) { $headerClusterName = $resourceId }

        Write-Log -Message "" -Level Info
        Write-Log -Message "----------------------------------------" -Level Info
        Write-Log -Message "Processing: $headerClusterName" -Level Info
        Write-Log -Message "ARM Resource ID: $resourceId" -Level Info
        Write-Log -Message "Target UpdateRing: $currentUpdateRingValue" -Level Info
        Write-Log -Message "----------------------------------------" -Level Info

        $clusterName = ""
        $resourceGroup = ""
        $subscriptionId = ""
        $previousTagValue = ""
        $action = ""
        $status = ""
        $message = ""

        try {
            # Parse the Resource ID to extract components
            if ($resourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/([^/]+)/([^/]+)/([^/]+)') {
                $subscriptionId = $matches[1]
                $resourceGroup = $matches[2]
                $providerNamespace = $matches[3]
                $resourceType = $matches[4]
                $clusterName = $matches[5]

                # Validate this is an Azure Stack HCI cluster
                $actualType = "$providerNamespace/$resourceType"
                
                if ($actualType -notlike "Microsoft.AzureStackHCI/clusters" -and $actualType -notlike "microsoft.azurestackhci/clusters") {
                    Write-Log -Message "Resource is not an Azure Local cluster. Type: $actualType" -Level Error
                    $action = "Skipped"
                    $status = "Failed"
                    $message = "Invalid resource type: $actualType (expected Microsoft.AzureStackHCI/clusters)"
                    
                    # Write to CSV
                    $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                    Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false
                    
                    $results += [PSCustomObject]@{
                        ClusterName      = $clusterName
                        ResourceGroup    = $resourceGroup
                        SubscriptionId   = $subscriptionId
                        ResourceId       = $resourceId
                        Action           = $action
                        PreviousTagValue = $previousTagValue
                        NewTagValue      = $currentUpdateRingValue
                        Status           = $status
                        Message          = $message
                    }
                    continue
                }
            }
            else {
                Write-Log -Message "Invalid Resource ID format: $resourceId" -Level Error
                $action = "Skipped"
                $status = "Failed"
                $message = "Invalid Resource ID format"
                
                # Write to CSV
                $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false
                
                $results += [PSCustomObject]@{
                    ClusterName      = $clusterName
                    ResourceGroup    = $resourceGroup
                    SubscriptionId   = $subscriptionId
                    ResourceId       = $resourceId
                    Action           = $action
                    PreviousTagValue = $previousTagValue
                    NewTagValue      = $currentUpdateRingValue
                    Status           = $status
                    Message          = $message
                }
                continue
            }

            Write-Log -Message "Cluster: $clusterName" -Level Info
            Write-Log -Message "Resource Group: $resourceGroup" -Level Info
            Write-Log -Message "Subscription: $subscriptionId" -Level Info

            # Get current resource to verify it exists and get current tags
            Write-Log -Message "Verifying cluster exists and retrieving current tags..." -Level Info
            $uri = "https://management.azure.com$resourceId`?api-version=2025-10-01"
            $clusterInfo = (Invoke-AzRestJson -Uri $uri).Data

            if ($LASTEXITCODE -ne 0 -or -not $clusterInfo) {
                Write-Log -Message "Failed to retrieve cluster. It may not exist or you don't have access." -Level Error
                $action = "Skipped"
                $status = "Failed"
                $message = "Cluster not found or access denied"
                
                # Write to CSV
                $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false
                
                $results += [PSCustomObject]@{
                    ClusterName      = $clusterName
                    ResourceGroup    = $resourceGroup
                    SubscriptionId   = $subscriptionId
                    ResourceId       = $resourceId
                    Action           = $action
                    PreviousTagValue = $previousTagValue
                    NewTagValue      = $currentUpdateRingValue
                    Status           = $status
                    Message          = $message
                }
                continue
            }

            # Verify the resource type from the API response
            if ($clusterInfo.type -notlike "Microsoft.AzureStackHCI/clusters" -and $clusterInfo.type -notlike "microsoft.azurestackhci/clusters") {
                Write-Log -Message "Resource type mismatch. Expected Azure Local cluster, got: $($clusterInfo.type)" -Level Error
                $action = "Skipped"
                $status = "Failed"
                $message = "Resource type mismatch: $($clusterInfo.type)"
                
                # Write to CSV
                $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false
                
                $results += [PSCustomObject]@{
                    ClusterName      = $clusterName
                    ResourceGroup    = $resourceGroup
                    SubscriptionId   = $subscriptionId
                    ResourceId       = $resourceId
                    Action           = $action
                    PreviousTagValue = $previousTagValue
                    NewTagValue      = $currentUpdateRingValue
                    Status           = $status
                    Message          = $message
                }
                continue
            }

            Write-Log -Message "Cluster verified: $($clusterInfo.name)" -Level Success

            # Get current tags
            $currentTags = @{}
            if ($clusterInfo.tags) {
                $currentTags = $clusterInfo.tags
                Write-Log -Message "Current tags: $($currentTags | ConvertTo-Json -Compress)" -Level Verbose
            }
            else {
                Write-Log -Message "No existing tags on cluster" -Level Verbose
            }

            # Check if UpdateRing tag already exists
            if ($currentTags.PSObject.Properties.Name -contains "UpdateRing") {
                $previousTagValue = $currentTags.UpdateRing
                # Only escalate to Warning when the existing tag value differs from
                # the desired value in the CSV. If the tag is already correct,
                # this is normal steady-state and should not be flagged as a
                # warning - we still continue so that adjacent schedule tags
                # (UpdateStartWindow, UpdateExclusionsWindow, UpdateExcluded) can be reconciled.
                if ($previousTagValue -eq $currentUpdateRingValue) {
                    Write-Log -Message "Existing UpdateRing tag found with value: '$previousTagValue' (matches target)" -Level Info
                }
                else {
                    Write-Log -Message "Existing UpdateRing tag found with value: '$previousTagValue' (differs from target '$currentUpdateRingValue')" -Level Warning
                }

                # Determine if we have new schedule tags to set (even if UpdateRing is unchanged)
                # Includes UpdateExcluded default-stamping: if the tag is absent on the cluster
                # and no override is supplied, we still need to stamp 'False' so the tag is
                # discoverable in the portal.
                $needsExcludedDefaultStamp = (-not $currentTags.PSObject.Properties[$script:UpdateExcludedTagName]) -and (-not $clusterEntry.UpdateExcludedValue)
                $hasNewScheduleTags = ($clusterEntry.UpdateStartWindowValue -and (-not $currentTags.PSObject.Properties[$script:UpdateStartWindowTagName] -or $currentTags.$($script:UpdateStartWindowTagName) -ne $clusterEntry.UpdateStartWindowValue)) -or
                                     ($clusterEntry.UpdateExclusionsWindowValue -and (-not $currentTags.PSObject.Properties[$script:UpdateExclusionsWindowTagName] -or $currentTags.$($script:UpdateExclusionsWindowTagName) -ne $clusterEntry.UpdateExclusionsWindowValue)) -or
                                     ($clusterEntry.UpdateExcludedValue -and (-not $currentTags.PSObject.Properties[$script:UpdateExcludedTagName] -or $currentTags.$($script:UpdateExcludedTagName) -ne $clusterEntry.UpdateExcludedValue)) -or
                                     $needsExcludedDefaultStamp

                if (-not $Force -and -not $hasNewScheduleTags) {
                    # Two distinct steady-state paths:
                    #   (a) UpdateRing matches AND no schedule diff -> truly nothing to do; Info, not Warning.
                    #   (b) UpdateRing differs AND no schedule diff -> overwrite blocked; Warning + -Force hint.
                    if ($previousTagValue -eq $currentUpdateRingValue) {
                        Write-Log -Message "All managed tags already match desired state - no action needed" -Level Info
                        $action = "NoChange"
                        $status = "AlreadyInSync"
                        $message = "All managed tags (UpdateRing, UpdateStartWindow, UpdateExclusionsWindow, UpdateExcluded) already match desired state."
                    }
                    else {
                        Write-Log -Message "Skipping cluster - UpdateRing differs from target; use -Force to overwrite existing tag" -Level Warning
                        $action = "Skipped"
                        $status = "Skipped"
                        $message = "Existing UpdateRing tag (value: $previousTagValue) differs from target ($currentUpdateRingValue). Use -Force to overwrite."
                    }

                    # Write to CSV
                    $escapedMessage = $message -replace '"', '""'
                    $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$escapedMessage`""
                    Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false

                    $results += [PSCustomObject]@{
                        ClusterName      = $clusterName
                        ResourceGroup    = $resourceGroup
                        SubscriptionId   = $subscriptionId
                        ResourceId       = $resourceId
                        Action           = $action
                        PreviousTagValue = $previousTagValue
                        NewTagValue      = $currentUpdateRingValue
                        Status           = $status
                        Message          = $message
                    }
                    continue
                }
                elseif (-not $Force -and $hasNewScheduleTags) {
                    Write-Log -Message "UpdateRing unchanged but new schedule tags to apply - proceeding" -Level Info
                    $action = "Updated"
                }
                else {
                    # Force mode. Still short-circuit when there is literally nothing to write -
                    # UpdateRing already matches AND no schedule diff AND no missing default-stamp.
                    # Saves a redundant ARM PATCH per cluster on already-clean fleets.
                    if ($previousTagValue -eq $currentUpdateRingValue -and -not $hasNewScheduleTags) {
                        Write-Log -Message "Force mode enabled but all managed tags already match desired state - no PATCH needed" -Level Info
                        $action = "NoChange"
                        $status = "AlreadyInSync"
                        $message = "All managed tags already match desired state; -Force PATCH skipped (no-op)."

                        # Write to CSV
                        $escapedMessage = $message -replace '"', '""'
                        $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$escapedMessage`""
                        Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false

                        $results += [PSCustomObject]@{
                            ClusterName      = $clusterName
                            ResourceGroup    = $resourceGroup
                            SubscriptionId   = $subscriptionId
                            ResourceId       = $resourceId
                            Action           = $action
                            PreviousTagValue = $previousTagValue
                            NewTagValue      = $currentUpdateRingValue
                            Status           = $status
                            Message          = $message
                        }
                        continue
                    }

                    Write-Log -Message "Force mode enabled - will update existing tag" -Level Info
                    $action = "Updated"
                }
            }
            else {
                Write-Log -Message "No existing UpdateRing tag - will create new tag" -Level Info
                $action = "Created"
            }

            # Build the set of tags we want to write (Merge semantics: only send
            # keys whose value should be set/updated). The dedicated
            # Microsoft.Resources/tags/default endpoint preserves all other
            # existing tags on the cluster without us having to re-send them,
            # so we only include the keys this function manages.
            $tagsToMerge = [ordered]@{
                UpdateRing = $currentUpdateRingValue
            }

            # Also set UpdateStartWindow, UpdateExclusionsWindow, UpdateExcluded if provided
            # (from CSV or parameters). Additionally: if UpdateExcluded is absent on the
            # cluster AND no override is supplied, default-stamp 'False' so the tag is
            # discoverable in the Azure portal and ready for an operator to flip to 'True'
            # when they need to temporarily exclude a cluster from automation.
            if ($clusterEntry.UpdateStartWindowValue) {
                $tagsToMerge[$script:UpdateStartWindowTagName] = $clusterEntry.UpdateStartWindowValue
                Write-Log -Message "  Will also set $($script:UpdateStartWindowTagName) tag: $($clusterEntry.UpdateStartWindowValue)" -Level Info
            }
            if ($clusterEntry.UpdateExclusionsWindowValue) {
                $tagsToMerge[$script:UpdateExclusionsWindowTagName] = $clusterEntry.UpdateExclusionsWindowValue
                Write-Log -Message "  Will also set $($script:UpdateExclusionsWindowTagName) tag: $($clusterEntry.UpdateExclusionsWindowValue)" -Level Info
            }
            if ($clusterEntry.UpdateExcludedValue) {
                $tagsToMerge[$script:UpdateExcludedTagName] = $clusterEntry.UpdateExcludedValue
                Write-Log -Message "  Will also set $($script:UpdateExcludedTagName) tag: $($clusterEntry.UpdateExcludedValue)" -Level Info
            }
            elseif (-not $currentTags.PSObject.Properties[$script:UpdateExcludedTagName]) {
                $tagsToMerge[$script:UpdateExcludedTagName] = 'False'
                Write-Log -Message "  Will default-stamp $($script:UpdateExcludedTagName) tag: 'False' (tag absent on cluster)" -Level Info
            }

            # Apply the tag using PATCH against the dedicated tags subresource.
            # Using /providers/Microsoft.Resources/tags/default (api-version 2021-04-01)
            # narrows the required RBAC from `microsoft.azurestackhci/clusters/write`
            # (full cluster Contributor) to `Microsoft.Resources/tags/write`
            # (built-in Tag Contributor). The "Merge" operation preserves all
            # other existing tags on the resource.
            if ($PSCmdlet.ShouldProcess($resourceId, "Set UpdateRing tag to '$currentUpdateRingValue'")) {
                Write-Log -Message "Applying UpdateRing tag with value: '$currentUpdateRingValue'..." -Level Info

                # Tags REST API: PATCH {scope}/providers/Microsoft.Resources/tags/default
                # https://learn.microsoft.com/en-us/rest/api/resources/tags/update-at-scope
                $tagsUri = "https://management.azure.com$resourceId/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"

                $patchBodyObj = [PSCustomObject]@{
                    operation  = 'Merge'
                    properties = [PSCustomObject]@{
                        tags = [PSCustomObject]$tagsToMerge
                    }
                }
                $patchBody = $patchBodyObj | ConvertTo-Json -Compress -Depth 10

                # Write body to temp file to avoid PowerShell/cmd JSON escaping issues
                $tempFile = [System.IO.Path]::GetTempFileName()
                try {
                    Write-Utf8NoBomFile -Path $tempFile -Content $patchBody

                    # Use az rest with @file syntax to avoid escaping issues
                    $result = az rest --method PATCH --uri $tagsUri --body "@$tempFile" --headers "Content-Type=application/json" --only-show-errors 2>&1

                    if ($LASTEXITCODE -eq 0) {
                        Write-Log -Message "Successfully $($action.ToLower()) UpdateRing tag" -Level Success
                        $status = "Success"
                        $message = "UpdateRing tag $($action.ToLower()) successfully"
                    }
                    else {
                        $scrubbed = ConvertTo-ScrubbedCliOutput -Text ($result | Out-String).Trim()
                        Write-Log -Message "Failed to apply tag: $scrubbed" -Level Error
                        $status = "Failed"
                        $message = "Failed to apply tag: $scrubbed"
                    }
                }
                finally {
                    # Clean up temp file
                    if (Test-Path $tempFile) {
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue -WhatIf:$false
                    }
                }
            }
            else {
                $status = "WhatIf"
                $message = "Would $($action.ToLower()) UpdateRing tag"
            }

            # Write to CSV
            $escapedMessage = $message -replace '"', '""'
            $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$escapedMessage`""
            Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false

            $results += [PSCustomObject]@{
                ClusterName      = $clusterName
                ResourceGroup    = $resourceGroup
                SubscriptionId   = $subscriptionId
                ResourceId       = $resourceId
                Action           = $action
                PreviousTagValue = $previousTagValue
                NewTagValue      = $currentUpdateRingValue
                Status           = $status
                Message          = $message
            }
        }
        catch {
            Write-Log -Message "Error processing cluster: $($_.Exception.Message)" -Level Error
            $status = "Failed"
            $message = $_.Exception.Message -replace '"', '""'
            
            # Write to CSV
            $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"Error`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
            Add-Content -Path $csvLogPath -Value $csvLine -WhatIf:$false
            
            $results += [PSCustomObject]@{
                ClusterName      = $clusterName
                ResourceGroup    = $resourceGroup
                SubscriptionId   = $subscriptionId
                ResourceId       = $resourceId
                Action           = "Error"
                PreviousTagValue = $previousTagValue
                NewTagValue      = $currentUpdateRingValue
                Status           = $status
                Message          = $_.Exception.Message
            }
        }
    }

    # Summary
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Summary" -Level Header
    Write-Log -Message "========================================" -Level Header
    
    $created = @($results | Where-Object { $_.Action -eq "Created" -and $_.Status -eq "Success" }).Count
    $updated = @($results | Where-Object { $_.Action -eq "Updated" -and $_.Status -eq "Success" }).Count
    $alreadyInSync = @($results | Where-Object { $_.Status -eq "AlreadyInSync" }).Count
    $skipped = @($results | Where-Object { $_.Status -eq "Skipped" }).Count
    $failed = @($results | Where-Object { $_.Status -eq "Failed" }).Count

    Write-Log -Message "Total clusters processed: $($results.Count)" -Level Info
    Write-Log -Message "Tags created: $created" -Level $(if ($created -gt 0) { "Success" } else { "Info" })
    Write-Log -Message "Tags updated: $updated" -Level $(if ($updated -gt 0) { "Success" } else { "Info" })
    Write-Log -Message "Already in sync (no change needed): $alreadyInSync" -Level Info
    Write-Log -Message "Skipped (UpdateRing differs, no -Force): $skipped" -Level $(if ($skipped -gt 0) { "Warning" } else { "Info" })
    Write-Log -Message "Failed: $failed" -Level $(if ($failed -gt 0) { "Error" } else { "Info" })
    Write-Log -Message "" -Level Info
    Write-Log -Message "CSV log saved to: $csvLogPath" -Level Info
    Write-Log -Message "========================================" -Level Header

    # Display results table
    Write-Host ""
    $results | Format-Table ClusterName, Action, PreviousTagValue, NewTagValue, Status -AutoSize
    
    if ($PassThru) {
        return $results
    }
}
