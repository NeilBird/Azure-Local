function Get-AzLocalUpdateRingClusterRead {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][string]$ResourceId,
        [Parameter(Mandatory = $true)][hashtable]$Context
    )

    $uri = "https://management.azure.com$ResourceId`?api-version=2025-10-01"
    if ($ResourceId -notmatch '^/subscriptions/([^/]+)/resourceGroups/[^/]+/providers/Microsoft\.AzureStackHCI/clusters/[^/?#]+$') {
        return [PSCustomObject]@{ Ok = $false; Data = $null; Error = 'Invalid cluster resource ID for direct ARM read.' }
    }
    $subscriptionId = $Matches[1]
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $headers = $null
    $tokenResponse = $null
    $rawToken = $null
    $cacheKey = $null
    try {
        if (-not $Context.ContainsKey('Accounts')) {
            $Context.Accounts = @{}
            $Context.Tokens = @{}
            $Context.DirectReads = 0
            $Context.FallbackReads = 0
            $Context.TokenRequests = 0
            $Context.ReadMilliseconds = 0L
            $rawAccounts = & az account list --output json --only-show-errors 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'Account discovery failed.' }
            $accounts = ($rawAccounts -join "`n") | ConvertFrom-Json -ErrorAction Stop
            foreach ($account in $accounts) {
                if ($account.id -and $account.tenantId -and $account.user.name -and $account.user.type) {
                    $accountKey = '{0}|{1}|{2}' -f $account.tenantId, $account.user.type, $account.user.name
                    if ($Context.Accounts.ContainsKey([string]$account.id)) {
                        $Context.Accounts[[string]$account.id] = $null
                    }
                    else { $Context.Accounts[[string]$account.id] = $accountKey }
                }
            }
        }
        $cacheKey = $Context.Accounts[$subscriptionId]
        if (-not $cacheKey) { throw 'No unambiguous account context available.' }
        $cached = $Context.Tokens[$cacheKey]
        if (-not $cached -or $cached.ExpiresUtc -le [DateTimeOffset]::UtcNow.AddMinutes(2)) {
            $Context.TokenRequests++
            $rawToken = & az account get-access-token --subscription $subscriptionId --resource 'https://management.azure.com/' --output json --only-show-errors 2>$null
            if ($LASTEXITCODE -ne 0) { throw 'Token acquisition failed.' }
            $tokenResponse = ($rawToken -join "`n") | ConvertFrom-Json -ErrorAction Stop
            if (-not $tokenResponse.accessToken -or -not $tokenResponse.expires_on -or
                [string]$tokenResponse.subscription -ne $subscriptionId -or
                [string]$tokenResponse.tenant -ne ($cacheKey -split '\|')[0]) { throw 'Token metadata unavailable or inconsistent.' }
            $expiresUtc = [DateTimeOffset]::FromUnixTimeSeconds([long]$tokenResponse.expires_on)
            if ($expiresUtc -le [DateTimeOffset]::UtcNow.AddMinutes(2)) { throw 'Token expiry is too near.' }
            $cached = @{ AccessToken = [string]$tokenResponse.accessToken; ExpiresUtc = $expiresUtc }
            $Context.Tokens[$cacheKey] = $cached
        }
        $headers = @{ Authorization = 'Bearer ' + $cached.AccessToken }
        $data = Invoke-RestMethod -Uri $uri -Method Get -Headers $headers -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction Stop -Verbose:$false -Debug:$false
        if (-not $data -or [string]$data.id -ne $ResourceId) { throw 'Unexpected ARM resource response.' }
        $Context.DirectReads++
        return [PSCustomObject]@{ Ok = $true; Data = $data; Error = $null }
    }
    catch {
        if ($headers) { $headers.Clear() }
        if ($cacheKey -and $Context.ContainsKey('Tokens')) {
            if ($Context.Tokens[$cacheKey]) { $Context.Tokens[$cacheKey].Clear() }
            $Context.Tokens.Remove($cacheKey)
        }
        $Context.FallbackReads++
        Write-Verbose 'Direct ARM read unavailable; using the existing Azure CLI read and authentication recovery path.'
        return Invoke-AzRestJson -Uri $uri
    }
    finally {
        if ($headers) { $headers.Clear() }
        $cached = $null
        $rawToken = $null
        $tokenResponse = $null
        $timer.Stop()
        $Context.ReadMilliseconds += $timer.ElapsedMilliseconds
        Write-Verbose ("Config-2 cluster read completed: durationMs={0}; directReads={1}; fallbackReads={2}; tokenRequests={3}." -f $timer.ElapsedMilliseconds, $Context.DirectReads, $Context.FallbackReads, $Context.TokenRequests)
    }
}

function Invoke-AzLocalUpdateRingTagPlanBatch {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][object[]]$Batch,
        [Parameter(Mandatory = $true)]$Options
    )

    $readContext = @{ DirectReads = 0; FallbackReads = 0; TokenRequests = 0; ReadMilliseconds = 0L }
    $batchTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($item in $Batch) {
            New-AzLocalUpdateRingTagPlan -ClusterEntry $item -ClusterTagFilters @($Options.ClusterTagFilters) `
                -Force ([bool]$Options.Force) -CaptureVerbose ([bool]$Options.CaptureVerbose) -ReadContext $readContext
        }
    }
    finally {
        $batchTimer.Stop()
        try {
            Write-Verbose ("Config-2 planning batch completed: clusters={0}; durationMs={1}; directReads={2}; fallbackReads={3}; tokenRequests={4}; readDurationMs={5}." -f $Batch.Count, $batchTimer.ElapsedMilliseconds, $readContext.DirectReads, $readContext.FallbackReads, $readContext.TokenRequests, $readContext.ReadMilliseconds)
        }
        finally {
            if ($readContext.ContainsKey('Tokens')) {
                foreach ($token in $readContext.Tokens.Values) { $token.Clear() }
                $readContext.Tokens.Clear()
            }
            $readContext.Clear()
        }
    }
}

function New-AzLocalUpdateRingTagPlan {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $ClusterEntry,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object[]]$ClusterTagFilters,

        [Parameter(Mandatory = $false)]
        [bool]$Force = $false,

        [Parameter(Mandatory = $false)]
        [bool]$CaptureVerbose = $false,

        [Parameter(Mandatory = $false)]
        [hashtable]$ReadContext
    )

    $logEntries = [System.Collections.Generic.List[object]]::new()
    $verboseMessages = [System.Collections.Generic.List[string]]::new()

    if ($ClusterEntry -is [System.Collections.IDictionary]) {
        $ClusterEntry = [PSCustomObject]$ClusterEntry
    }

    $inputIndex = if ($ClusterEntry.PSObject.Properties['InputIndex']) { [int]$ClusterEntry.InputIndex } else { 0 }
    $resourceId = if ($ClusterEntry.PSObject.Properties['ResourceId']) { [string]$ClusterEntry.ResourceId } else { '' }
    $currentUpdateRingValue = if ($ClusterEntry.PSObject.Properties['UpdateRingValue']) { [string]$ClusterEntry.UpdateRingValue } else { '' }
    $updateStartWindowValue = if ($ClusterEntry.PSObject.Properties['UpdateStartWindowValue']) { [string]$ClusterEntry.UpdateStartWindowValue } else { '' }
    $updateExclusionsWindowValue = if ($ClusterEntry.PSObject.Properties['UpdateExclusionsWindowValue']) { [string]$ClusterEntry.UpdateExclusionsWindowValue } else { '' }
    $updateExcludedValue = if ($ClusterEntry.PSObject.Properties['UpdateExcludedValue']) { [string]$ClusterEntry.UpdateExcludedValue } else { '' }
    $updateAuthAccountIdValue = if ($ClusterEntry.PSObject.Properties['UpdateAuthAccountIdValue']) { [string]$ClusterEntry.UpdateAuthAccountIdValue } else { '' }

    $headerClusterName = ($resourceId -split '/')[-1]
    if ([string]::IsNullOrWhiteSpace($headerClusterName)) { $headerClusterName = $resourceId }

    [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = '' })
    [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = '----------------------------------------' })
    [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "Processing: $headerClusterName" })
    [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "ARM Resource ID: $resourceId" })
    [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "Target UpdateRing: $currentUpdateRingValue" })
    [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = '----------------------------------------' })

    $clusterName = ''
    $resourceGroup = ''
    $subscriptionId = ''
    $previousTagValue = ''

    $newResult = {
        param(
            [string]$Action,
            [string]$Status,
            [string]$Message
        )
        [PSCustomObject]@{
            ClusterName      = $clusterName
            ResourceGroup    = $resourceGroup
            SubscriptionId   = $subscriptionId
            ResourceId       = $resourceId
            Action           = $Action
            PreviousTagValue = $previousTagValue
            NewTagValue      = $currentUpdateRingValue
            Status           = $Status
            Message          = $Message
        }
    }

    $newEnvelope = {
        param($Result, $Plan)
        [PSCustomObject]@{
            InputIndex      = $inputIndex
            ResourceId      = $resourceId
            Result          = $Result
            Plan            = $Plan
            LogEntries      = $logEntries.ToArray()
            VerboseMessages = $verboseMessages.ToArray()
        }
    }

    try {
        if ($resourceId -notmatch '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/([^/]+)/([^/]+)/([^/]+)') {
            $message = 'Invalid Resource ID format'
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Error'; Message = "Invalid Resource ID format: $resourceId" })
            return & $newEnvelope (& $newResult 'Skipped' 'Failed' $message) $null
        }

        $subscriptionId = $Matches[1]
        $resourceGroup = $Matches[2]
        $providerNamespace = $Matches[3]
        $resourceType = $Matches[4]
        $clusterName = $Matches[5]
        $actualType = "$providerNamespace/$resourceType"

        if ($actualType -notlike 'Microsoft.AzureStackHCI/clusters') {
            $message = "Invalid resource type: $actualType (expected Microsoft.AzureStackHCI/clusters)"
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Error'; Message = "Resource is not an Azure Local cluster. Type: $actualType" })
            return & $newEnvelope (& $newResult 'Skipped' 'Failed' $message) $null
        }

        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "Cluster: $clusterName" })
        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "Resource Group: $resourceGroup" })
        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "Subscription: $subscriptionId" })
        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = 'Verifying cluster exists and retrieving current tags...' })

        $uri = "https://management.azure.com$resourceId`?api-version=2025-10-01"
        $restOutput = if ($null -ne $ReadContext) {
            @(Get-AzLocalUpdateRingClusterRead -ResourceId $resourceId -Context $ReadContext -Verbose:$CaptureVerbose 4>&1)
        }
        else {
            @(Invoke-AzRestJson -Uri $uri -Verbose:$CaptureVerbose 4>&1)
        }
        $clusterResponse = $null
        foreach ($outputItem in $restOutput) {
            if ($outputItem -is [System.Management.Automation.VerboseRecord]) {
                [void]$verboseMessages.Add([string]$outputItem.Message)
            }
            elseif ($outputItem -and $outputItem.PSObject.Properties['Ok']) {
                $clusterResponse = $outputItem
            }
        }

        if (-not $clusterResponse -or -not $clusterResponse.Ok -or -not $clusterResponse.Data) {
            $detail = if ($clusterResponse -and $clusterResponse.Error) { ": $($clusterResponse.Error)" } else { '' }
            $message = "Cluster not found or access denied$detail"
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Error'; Message = "Failed to retrieve cluster. It may not exist or you don't have access.$detail" })
            return & $newEnvelope (& $newResult 'Skipped' 'Failed' $message) $null
        }
        $clusterInfo = $clusterResponse.Data

        if (-not (Test-AzLocalClusterMatchesTagFilter -Tags $clusterInfo.tags -ClusterTagFilters $ClusterTagFilters)) {
            $message = 'Cluster does not match the configured scope.clusterTagFilters policy. No tags were changed.'
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Warning'; Message = "$message ResourceId: $resourceId" })
            return & $newEnvelope (& $newResult 'Skipped' 'GlobalFilterMismatch' $message) $null
        }

        if ($clusterInfo.type -notlike 'Microsoft.AzureStackHCI/clusters') {
            $message = "Resource type mismatch: $($clusterInfo.type)"
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Error'; Message = "Resource type mismatch. Expected Azure Local cluster, got: $($clusterInfo.type)" })
            return & $newEnvelope (& $newResult 'Skipped' 'Failed' $message) $null
        }

        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Success'; Message = "Cluster verified: $($clusterInfo.name)" })

        $currentTags = if ($clusterInfo.tags) { $clusterInfo.tags } else { [PSCustomObject]@{} }
        if ($currentTags -is [System.Collections.IDictionary]) {
            $currentTags = [PSCustomObject]$currentTags
        }

        $action = ''
        $hasUpdateRing = [bool]$currentTags.PSObject.Properties['UpdateRing']
        if ($hasUpdateRing) {
            $previousTagValue = [string]$currentTags.UpdateRing
            if ($previousTagValue -eq $currentUpdateRingValue) {
                [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "Existing UpdateRing tag found with value: '$previousTagValue' (matches target)" })
            }
            else {
                [void]$logEntries.Add([PSCustomObject]@{ Level = 'Warning'; Message = "Existing UpdateRing tag found with value: '$previousTagValue' (differs from target '$currentUpdateRingValue')" })
            }

            $needsExcludedDefaultStamp = (-not $currentTags.PSObject.Properties[$script:UpdateExcludedTagName]) -and (-not $updateExcludedValue)
            $hasNewScheduleTags = ($updateStartWindowValue -and (-not $currentTags.PSObject.Properties[$script:UpdateStartWindowTagName] -or $currentTags.$($script:UpdateStartWindowTagName) -ne $updateStartWindowValue)) -or
                                  ($updateExclusionsWindowValue -and (-not $currentTags.PSObject.Properties[$script:UpdateExclusionsWindowTagName] -or $currentTags.$($script:UpdateExclusionsWindowTagName) -ne $updateExclusionsWindowValue)) -or
                                  ($updateExcludedValue -and (-not $currentTags.PSObject.Properties[$script:UpdateExcludedTagName] -or $currentTags.$($script:UpdateExcludedTagName) -ne $updateExcludedValue)) -or
                                  ($updateAuthAccountIdValue -and (-not $currentTags.PSObject.Properties[$script:UpdateAuthAccountIdTagName] -or $currentTags.$($script:UpdateAuthAccountIdTagName) -ne $updateAuthAccountIdValue)) -or
                                  $needsExcludedDefaultStamp

            if (-not $Force -and -not $hasNewScheduleTags) {
                if ($previousTagValue -eq $currentUpdateRingValue) {
                    $message = 'All managed tags (UpdateRing, UpdateStartWindow, UpdateExclusionsWindow, UpdateExcluded) already match desired state.'
                    [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = 'All managed tags already match desired state - no action needed' })
                    return & $newEnvelope (& $newResult 'NoChange' 'AlreadyInSync' $message) $null
                }

                $message = "Existing UpdateRing tag (value: $previousTagValue) differs from target ($currentUpdateRingValue). Use -Force to overwrite."
                [void]$logEntries.Add([PSCustomObject]@{ Level = 'Warning'; Message = 'Skipping cluster - UpdateRing differs from target; use -Force to overwrite existing tag' })
                return & $newEnvelope (& $newResult 'Skipped' 'Skipped' $message) $null
            }

            if (-not $Force) {
                [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = 'UpdateRing unchanged but new schedule tags to apply - proceeding' })
                $action = 'Updated'
            }
            elseif ($previousTagValue -eq $currentUpdateRingValue -and -not $hasNewScheduleTags) {
                $message = 'All managed tags already match desired state; -Force PATCH skipped (no-op).'
                [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = 'Force mode enabled but all managed tags already match desired state - no PATCH needed' })
                return & $newEnvelope (& $newResult 'NoChange' 'AlreadyInSync' $message) $null
            }
            else {
                [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = 'Force mode enabled - will update existing tag' })
                $action = 'Updated'
            }
        }
        else {
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = 'No existing UpdateRing tag - will create new tag' })
            $action = 'Created'
        }

        $tagsToMerge = [ordered]@{ UpdateRing = $currentUpdateRingValue }
        if ($updateStartWindowValue) {
            $tagsToMerge[$script:UpdateStartWindowTagName] = $updateStartWindowValue
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "  Will also set $($script:UpdateStartWindowTagName) tag: $updateStartWindowValue" })
        }
        if ($updateExclusionsWindowValue) {
            $tagsToMerge[$script:UpdateExclusionsWindowTagName] = $updateExclusionsWindowValue
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "  Will also set $($script:UpdateExclusionsWindowTagName) tag: $updateExclusionsWindowValue" })
        }
        if ($updateExcludedValue) {
            $tagsToMerge[$script:UpdateExcludedTagName] = $updateExcludedValue
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "  Will also set $($script:UpdateExcludedTagName) tag: $updateExcludedValue" })
        }
        elseif (-not $currentTags.PSObject.Properties[$script:UpdateExcludedTagName]) {
            $tagsToMerge[$script:UpdateExcludedTagName] = 'False'
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "  Will default-stamp $($script:UpdateExcludedTagName) tag: 'False' (tag absent on cluster)" })
        }

        if ($updateAuthAccountIdValue) {
            $authIdToWrite = $updateAuthAccountIdValue.Trim()
            if ($authIdToWrite -notmatch '^\d{1,3}$') {
                throw "Invalid UpdateAuthAccountId '$authIdToWrite' for cluster '$clusterName' - must be numeric (1-3 digits, e.g. 001)."
            }
            $tagsToMerge[$script:UpdateAuthAccountIdTagName] = $authIdToWrite
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "  Will also set $($script:UpdateAuthAccountIdTagName) tag: $authIdToWrite" })
        }

        $tagDeltas = [System.Collections.Generic.List[string]]::new()
        foreach ($tagName in $tagsToMerge.Keys) {
            $newValue = [string]$tagsToMerge[$tagName]
            $oldValue = if ($currentTags.PSObject.Properties[$tagName]) { [string]$currentTags.$tagName } else { '<absent>' }
            if ($oldValue -ne $newValue) {
                [void]$tagDeltas.Add(("{0}: '{1}' -> '{2}'" -f $tagName, $oldValue, $newValue))
            }
        }

        $patchBodyObject = [PSCustomObject]@{
            operation  = 'Merge'
            properties = [PSCustomObject]@{ tags = [PSCustomObject]$tagsToMerge }
        }
        $successMessage = if ($tagDeltas.Count -gt 0) {
            "Tags $($action.ToLower()): " + ($tagDeltas -join '; ')
        }
        else {
            "UpdateRing tag $($action.ToLower()) successfully"
        }
        $whatIfMessage = if ($tagDeltas.Count -gt 0) {
            "Would $($action.ToLower()) tags: " + ($tagDeltas -join '; ')
        }
        else {
            "Would $($action.ToLower()) UpdateRing tag"
        }

        $plan = [PSCustomObject]@{
            InputIndex       = $inputIndex
            ClusterName      = $clusterName
            ResourceGroup    = $resourceGroup
            SubscriptionId   = $subscriptionId
            ResourceId       = $resourceId
            Action           = $action
            PreviousTagValue = $previousTagValue
            NewTagValue      = $currentUpdateRingValue
            PatchBody        = ($patchBodyObject | ConvertTo-Json -Compress -Depth 10)
            SuccessMessage   = $successMessage
            WhatIfMessage    = $whatIfMessage
        }
        return & $newEnvelope $null $plan
    }
    catch {
        $message = $_.Exception.Message
        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Error'; Message = "Error processing cluster: $message" })
        return & $newEnvelope (& $newResult 'Error' 'Failed' $message) $null
    }
}

function Invoke-AzLocalUpdateRingTagPatch {
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Plan,

        [Parameter(Mandatory = $false)]
        [bool]$CaptureVerbose = $false
    )

    if ($Plan -is [System.Collections.IDictionary]) {
        $Plan = [PSCustomObject]$Plan
    }

    $logEntries = [System.Collections.Generic.List[object]]::new()
    $verboseMessages = [System.Collections.Generic.List[string]]::new()
    $result = $null

    try {
        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Info'; Message = "Applying UpdateRing tag with value: '$($Plan.NewTagValue)'..." })
        $tagsUri = "https://management.azure.com$($Plan.ResourceId)/providers/Microsoft.Resources/tags/default?api-version=2021-04-01"
        $restOutput = @(Invoke-AzRestJson -Uri $tagsUri -Method PATCH -Body ([string]$Plan.PatchBody) -Headers @('Content-Type=application/json') -Verbose:$CaptureVerbose 4>&1)
        $patchResponse = $null
        foreach ($outputItem in $restOutput) {
            if ($outputItem -is [System.Management.Automation.VerboseRecord]) {
                [void]$verboseMessages.Add([string]$outputItem.Message)
            }
            elseif ($outputItem -and $outputItem.PSObject.Properties['Ok']) {
                $patchResponse = $outputItem
            }
        }

        if ($patchResponse -and $patchResponse.Ok) {
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Success'; Message = "Successfully $(([string]$Plan.Action).ToLower()) UpdateRing tag" })
            $result = [PSCustomObject]@{
                ClusterName      = [string]$Plan.ClusterName
                ResourceGroup    = [string]$Plan.ResourceGroup
                SubscriptionId   = [string]$Plan.SubscriptionId
                ResourceId       = [string]$Plan.ResourceId
                Action           = [string]$Plan.Action
                PreviousTagValue = [string]$Plan.PreviousTagValue
                NewTagValue      = [string]$Plan.NewTagValue
                Status           = 'Success'
                Message          = [string]$Plan.SuccessMessage
            }
        }
        else {
            $errorMessage = if ($patchResponse -and $patchResponse.Error) { [string]$patchResponse.Error } else { 'No response returned by ARM.' }
            [void]$logEntries.Add([PSCustomObject]@{ Level = 'Error'; Message = "Failed to apply tag: $errorMessage" })
            $result = [PSCustomObject]@{
                ClusterName      = [string]$Plan.ClusterName
                ResourceGroup    = [string]$Plan.ResourceGroup
                SubscriptionId   = [string]$Plan.SubscriptionId
                ResourceId       = [string]$Plan.ResourceId
                Action           = [string]$Plan.Action
                PreviousTagValue = [string]$Plan.PreviousTagValue
                NewTagValue      = [string]$Plan.NewTagValue
                Status           = 'Failed'
                Message          = "Failed to apply tag: $errorMessage"
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        [void]$logEntries.Add([PSCustomObject]@{ Level = 'Error'; Message = "Error applying tag: $message" })
        $result = [PSCustomObject]@{
            ClusterName      = [string]$Plan.ClusterName
            ResourceGroup    = [string]$Plan.ResourceGroup
            SubscriptionId   = [string]$Plan.SubscriptionId
            ResourceId       = [string]$Plan.ResourceId
            Action           = 'Error'
            PreviousTagValue = [string]$Plan.PreviousTagValue
            NewTagValue      = [string]$Plan.NewTagValue
            Status           = 'Failed'
            Message          = $message
        }
    }

    return [PSCustomObject]@{
        InputIndex      = [int]$Plan.InputIndex
        ResourceId      = [string]$Plan.ResourceId
        Result          = $result
        LogEntries      = $logEntries.ToArray()
        VerboseMessages = $verboseMessages.ToArray()
    }
}
