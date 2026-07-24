function Get-AzLocalClusterInfo {
    <#
    .SYNOPSIS
        Gets detailed information about an Azure Local cluster.
    
    .DESCRIPTION
        Retrieves cluster information from Azure Resource Manager for a specified Azure Local
        (Azure Stack HCI) cluster. Can search by cluster name within a specific resource group
        or across all resource groups in a subscription.
    
    .PARAMETER ClusterName
        The name of the Azure Local cluster to retrieve information for.
    
    .PARAMETER ResourceGroupName
        The resource group containing the cluster. If not specified, searches across all
        resource groups in the subscription.
    
    .PARAMETER SubscriptionId
        The Azure subscription ID containing the cluster.
    
    .PARAMETER ApiVersion
        The API version to use for the Azure REST call. Defaults to the module's default API version.
    
    .EXAMPLE
        Get-AzLocalClusterInfo -ClusterName "MyCluster" -SubscriptionId "12345-abcd-6789"
        
        Searches for the cluster named "MyCluster" across all resource groups in the specified subscription.
    
    .EXAMPLE
        Get-AzLocalClusterInfo -ClusterName "MyCluster" -ResourceGroupName "MyRG" -SubscriptionId "12345-abcd-6789"
        
        Gets cluster information directly from the specified resource group.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    # Ensure Azure CLI is available
    Test-AzCliAvailable | Out-Null

    if ($ResourceGroupName) {
        # Direct lookup if resource group is known
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/clusters/${ClusterName}?api-version=$ApiVersion"
        
        Write-Verbose "Getting cluster info from: $uri"
        
        $result = (Invoke-AzRestJson -Uri $uri).Data
        if ($LASTEXITCODE -eq 0) {
            return $result
        }
    }
    else {
        # Search across all resource groups
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.AzureStackHCI/clusters?api-version=$ApiVersion"
        
        Write-Verbose "Searching for cluster across subscription: $uri"
        
        $allClusters = (Invoke-AzRestJson -Uri $uri).Data
        if ($LASTEXITCODE -eq 0 -and $allClusters.value) {
            $cluster = $allClusters.value | Where-Object { $null -ne $_ -and $_.name -eq $ClusterName }
            if ($cluster) {
                return $cluster
            }
        }
    }

    return $null
}
