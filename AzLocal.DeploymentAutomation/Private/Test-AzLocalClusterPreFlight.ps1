Function Test-AzLocalClusterPreFlight {
    <#
    .SYNOPSIS

    Runs pre-flight checks for a single cluster deployment.

    .DESCRIPTION

    Validates that a cluster is ready for deployment by checking:
    1. Resource names pass Azure naming validation (Test-AzLocalResourceNames)
    2. Resource group exists in the target subscription
    3. Azure prerequisites: required resource providers are registered (auto-registers
       missing ones) and RBAC role assignments are present (advisory)
    4. All expected Arc node resources (Microsoft.HybridCompute/machines) are registered
    5. No ARM deployment is currently in-progress for this cluster
    6. The cluster resource does not already exist (already deployed)

    Returns a result object with Status (Passed/Failed/Skipped) and diagnostic Messages.

    .PARAMETER ClusterRow
    A PSCustomObject from the CSV representing one cluster deployment.

    .PARAMETER NamingConfig
    The naming configuration object from Get-AzLocalNamingConfig.

    .PARAMETER DeploymentMode
    The deployment mode (Validate or Deploy) to check for in-progress deployments.

    #>

    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [PSCustomObject]$ClusterRow,

        [Parameter(Mandatory = $true, Position = 1)]
        [PSCustomObject]$NamingConfig,

        [Parameter(Mandatory = $true, Position = 2)]
        [ValidateSet("Validate", "Deploy")]
        [string]$DeploymentMode
    )

    $uniqueID = $ClusterRow.UniqueID
    $messages = @()
    $status = 'Passed'
    $startTime = Get-Date

    Write-AzLocalLog "Pre-flight check: $uniqueID" -Level Info

    # Resolve resource names
    $resourceGroupName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.resourceGroupName -UniqueID $uniqueID
    $clusterName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.clusterName -UniqueID $uniqueID
    $deploymentName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.deploymentName -UniqueID $uniqueID -TypeOfDeployment $ClusterRow.TypeOfDeployment
    $keyVaultName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.keyVaultName -UniqueID $uniqueID
    $customLocation = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.customLocation -UniqueID $uniqueID
    $resourceBridgeName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.resourceBridgeName -UniqueID $uniqueID
    $diagnosticStorageAccountName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.diagnosticStorageAccountName -UniqueID $uniqueID
    $clusterWitnessStorageAccountName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.clusterWitnessStorageAccountName -UniqueID $uniqueID

    # Determine effective node count
    $nodeCount = [int]$ClusterRow.NodeCount
    if ($ClusterRow.TypeOfDeployment -eq 'SingleNode') { $effectiveNodeCount = 1 } else { $effectiveNodeCount = $nodeCount }

    # Build node names
    $nodeNames = @()
    for ($i = 1; $i -le $effectiveNodeCount; $i++) {
        $nodeNames += Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.nodeNamePattern -UniqueID $uniqueID -NodeNumber $i
    }

    # 1. Validate resource names
    try {
        $namesToValidate = @{
            'ClusterName'                      = $clusterName
            'ResourceGroupName'                = $resourceGroupName
            'KeyVaultName'                     = $keyVaultName
            'CustomLocation'                   = $customLocation
            'ResourceBridgeName'               = $resourceBridgeName
            'DiagnosticStorageAccountName'     = $diagnosticStorageAccountName
            'ClusterWitnessStorageAccountName' = $clusterWitnessStorageAccountName
            'DeploymentName'                   = $deploymentName
        }
        # Add node names
        for ($i = 0; $i -lt $nodeNames.Count; $i++) {
            $namesToValidate["NodeName$($i + 1)"] = $nodeNames[$i]
        }
        Test-AzLocalResourceNames -Names $namesToValidate
        $messages += "Resource name validation: PASSED"
    } catch {
        $status = 'Failed'
        $messages += "Resource name validation: FAILED - $($_.Exception.Message)"
        # Return early - no point checking Azure if names are invalid
        $duration = ((Get-Date) - $startTime).TotalSeconds
        return [PSCustomObject]@{
            UniqueID          = $uniqueID
            ClusterName       = $clusterName
            ResourceGroupName = $resourceGroupName
            DeploymentName    = $deploymentName
            Status            = $status
            Messages          = $messages
            Duration          = [math]::Round($duration, 2)
        }
    }

    # 2. Check resource group exists
    $rg = $null
    try {
        $rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction Stop
    } catch {
        if (-not (Test-AzLocalNotFoundError -ErrorRecord $_ -ErrorCode @('ResourceGroupNotFound', 'ResourceNotFound'))) {
            $status = 'Failed'
            $messages += "Resource group '$resourceGroupName': ERROR checking existence - $($_.Exception.Message)"
            $duration = ((Get-Date) - $startTime).TotalSeconds
            return [PSCustomObject]@{
                UniqueID          = $uniqueID
                ClusterName       = $clusterName
                ResourceGroupName = $resourceGroupName
                DeploymentName    = $deploymentName
                Status            = $status
                Messages          = $messages
                Duration          = [math]::Round($duration, 2)
            }
        }
    }
    if (-not $rg) {
        $status = 'Failed'
        $messages += "Resource group '$resourceGroupName': NOT FOUND"
        $duration = ((Get-Date) - $startTime).TotalSeconds
        return [PSCustomObject]@{
            UniqueID          = $uniqueID
            ClusterName       = $clusterName
            ResourceGroupName = $resourceGroupName
            DeploymentName    = $deploymentName
            Status            = $status
            Messages          = $messages
            Duration          = [math]::Round($duration, 2)
        }
    }
    $messages += "Resource group '$resourceGroupName': EXISTS"

    # 3. Check Azure prerequisites (resource providers and RBAC)
    $prereqResult = Test-AzLocalAzurePrerequisites -SubscriptionId $ClusterRow.SubscriptionId -ResourceGroupName $resourceGroupName
    $messages += $prereqResult.Messages
    if ($prereqResult.Status -eq 'Failed') {
        $status = 'Failed'
        $messages += "Azure prerequisite checks: FAILED"
        $duration = ((Get-Date) - $startTime).TotalSeconds
        return [PSCustomObject]@{
            UniqueID          = $uniqueID
            ClusterName       = $clusterName
            ResourceGroupName = $resourceGroupName
            DeploymentName    = $deploymentName
            Status            = $status
            Messages          = $messages
            Duration          = [math]::Round($duration, 2)
        }
    }
    $messages += "Azure prerequisite checks: PASSED"

    # 4. Check all Arc nodes are registered
    $allNodesPresent = $true
    # Default to the GA api-version for Microsoft.HybridCompute/machines; the helper
    # self-heals (parses ARM's supported-versions list and retries) if it is rejected.
    $arcMachineApiVersion = '2025-01-13'
    foreach ($nodeName in $nodeNames) {
        $arcResourceId = "/subscriptions/$($ClusterRow.SubscriptionId)/resourceGroups/$resourceGroupName/providers/Microsoft.HybridCompute/machines/$nodeName"
        try {
            # Existence-aware lookup: $null means genuinely absent; a real failure
            # (unsupported api-version, auth, RBAC, transport) throws with the real reason
            # instead of being masked as "NOT FOUND".
            $arcNode = Get-AzLocalArmResource -ResourceId $arcResourceId -ResourceKind 'Arc node' -ApiVersion $arcMachineApiVersion
        } catch {
            $allNodesPresent = $false
            $messages += "Arc node '$nodeName': ERROR checking registration - $($_.Exception.Message)"
            continue
        }
        if ($arcNode) {
            $messages += "Arc node '$nodeName': REGISTERED"
        } else {
            $allNodesPresent = $false
            $messages += "Arc node '$nodeName': NOT FOUND"
        }
    }
    if (-not $allNodesPresent) {
        $status = 'Failed'
        $messages += "Pre-flight FAILED: Not all Arc nodes are registered."
        $duration = ((Get-Date) - $startTime).TotalSeconds
        return [PSCustomObject]@{
            UniqueID          = $uniqueID
            ClusterName       = $clusterName
            ResourceGroupName = $resourceGroupName
            DeploymentName    = $deploymentName
            Status            = $status
            Messages          = $messages
            Duration          = [math]::Round($duration, 2)
        }
    }

    # 5. Check for existing cluster resource (already deployed)
    $clusterResourceId = "/subscriptions/$($ClusterRow.SubscriptionId)/resourceGroups/$resourceGroupName/providers/Microsoft.AzureStackHCI/clusters/$clusterName"
    $existingCluster = $null
    try {
        # Existence-aware lookup: $null means genuinely absent; a real failure throws
        # with the real reason instead of being masked as "does not exist".
        $existingCluster = Get-AzLocalArmResource -ResourceId $clusterResourceId -ResourceKind 'cluster'
    } catch {
        $status = 'Failed'
        $messages += "Cluster '$clusterName': ERROR checking existence - $($_.Exception.Message)"
        $duration = ((Get-Date) - $startTime).TotalSeconds
        return [PSCustomObject]@{
            UniqueID          = $uniqueID
            ClusterName       = $clusterName
            ResourceGroupName = $resourceGroupName
            DeploymentName    = $deploymentName
            Status            = $status
            Messages          = $messages
            Duration          = [math]::Round($duration, 2)
        }
    }
    if ($existingCluster) {
        $status = 'Skipped'
        $messages += "Cluster '$clusterName' already exists in resource group. Skipping."
        $duration = ((Get-Date) - $startTime).TotalSeconds
        return [PSCustomObject]@{
            UniqueID          = $uniqueID
            ClusterName       = $clusterName
            ResourceGroupName = $resourceGroupName
            DeploymentName    = $deploymentName
            Status            = $status
            Messages          = $messages
            Duration          = [math]::Round($duration, 2)
        }
    }
    $messages += "Cluster '$clusterName': Not yet deployed (eligible)"

    # 6. Check for in-progress deployment
    $existingDeployment = $null
    try {
        $existingDeployment = Get-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -Name $deploymentName -ErrorAction Stop
    } catch {
        if (-not (Test-AzLocalNotFoundError -ErrorRecord $_ -ErrorCode @('ResourceGroupDeploymentNotFound', 'DeploymentNotFound', 'ResourceNotFound'))) {
            $status = 'Failed'
            $messages += "Deployment '$deploymentName': ERROR checking status - $($_.Exception.Message)"
        }
    }
    if ($existingDeployment) {
        $provState = $existingDeployment.ProvisioningState
        if ($provState -eq 'Running' -or $provState -eq 'Accepted') {
            $status = 'Skipped'
            $messages += "Deployment '$deploymentName' is already in-progress (State: $provState). Skipping."
        } elseif ($provState -eq 'Succeeded' -and $DeploymentMode -eq 'Validate') {
            $status = 'Skipped'
            $messages += "Validation deployment '$deploymentName' already succeeded. Skipping."
        } elseif ($provState -eq 'Failed') {
            $messages += "Previous deployment '$deploymentName' failed (can be retried)."
        } else {
            $messages += "Existing deployment '$deploymentName' state: $provState"
        }
    } else {
        $messages += "No existing deployment '$deploymentName' found (new deployment)."
    }

    $duration = ((Get-Date) - $startTime).TotalSeconds
    return [PSCustomObject]@{
        UniqueID          = $uniqueID
        ClusterName       = $clusterName
        ResourceGroupName = $resourceGroupName
        DeploymentName    = $deploymentName
        Status            = $status
        Messages          = $messages
        Duration          = [math]::Round($duration, 2)
    }
}
