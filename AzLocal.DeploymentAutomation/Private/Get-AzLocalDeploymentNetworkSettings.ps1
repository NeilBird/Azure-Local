Function Get-AzLocalDeploymentNetworkSettings {
    <#
    .SYNOPSIS

    This function retrieves the network settings for the Azure Local deployment.

    .DESCRIPTION

    This function retrieves the network settings for the Azure Local deployment. It requires the following parameters:
    - TypeOfDeployment: The type of deployment.
    - NodeCount: The number of nodes (required for StorageSwitched).

    #>

    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true,Position=0)]
        [ValidateSet("SingleNode","StorageSwitchless","StorageSwitched","RackAware","Disaggregated")]
        [string]$TypeOfDeployment,

        [Parameter(Mandatory = $false,Position=1)]
        [int]$NodeCount = 0
    )

    # Validate NodeCount for multi-node deployment types
    if ($TypeOfDeployment -ne 'SingleNode' -and $NodeCount -le 0) {
        throw "NodeCount must be greater than 0 for '$TypeOfDeployment' deployments."
    }

    # Determine the effective node count based on deployment type
    switch ($TypeOfDeployment) {
        "SingleNode"            { $effectiveNodeCount = 1 }
        "StorageSwitchless"     { $effectiveNodeCount = $NodeCount }
        "StorageSwitched"       { $effectiveNodeCount = $NodeCount }
        "RackAware"             { $effectiveNodeCount = $NodeCount }
        "Disaggregated"         { $effectiveNodeCount = $NodeCount }
    }

    # Prompt for Network Settings
    # ///// Network Settings Prompt, cast the input to System.Net.IPAddress to validate the IP address format
    try{
        [System.Net.IPAddress]$subnetMask = Read-Host "Please enter the subnet mask (e.g. 255.255.255.224)" -ErrorAction Stop
        [System.Net.IPAddress]$defaultGateway = Read-Host "`nPlease enter the default gateway (e.g. 10.224.x.x)" -ErrorAction Stop
        [System.Net.IPAddress]$startingIPAddress = Read-Host "`nPlease enter the Management Network starting IP address (e.g. 10.224.x.x)" -ErrorAction Stop
        [System.Net.IPAddress]$endingIPAddress = Read-Host "`nPlease enter the Management Network ending IP address (e.g. 10.224.x.x)" -ErrorAction Stop

    } catch {
        Write-AzLocalLog "Invalid IP address or Subnet Mask format." -Level Error
        throw "Invalid IP address or Subnet Mask format. $($_.Exception.Message)"
    }
    # ///// Network Settings Prompt

    # Prompt for each node IP address dynamically
    $nodeIPAddresses = @()
    for ($i = 1; $i -le $effectiveNodeCount; $i++) {
        $paddedNum = $i.ToString("D2")
        try {
            [System.Net.IPAddress]$nodeIP = Read-Host "`nPlease enter Node$paddedNum IP address (e.g. 10.224.x.x)" -ErrorAction Stop
            $nodeIPAddresses += $nodeIP.IPAddressToString
        } catch {
            Write-AzLocalLog "Invalid IP address format for Node$paddedNum." -Level Error
            throw "Invalid IP address format for Node$paddedNum. $($_.Exception.Message)"
        }
    }

    # For Disaggregated (SAN) deployments, also collect SAN-specific settings:
    #  - InfraVolLunId: vendor-issued LUN ID for the infrastructure volume
    #  - InfraPerfLunId: vendor-issued LUN ID for the performance volume
    #  - SanNetworkAdapterName: physical NIC used for the SAN/cluster network (e.g. "ethernet 3")
    #  - SanNetworkVlanId: VLAN tag for the SAN network (0-4095, 0 = untagged)
    #  - SanNetworkAddressPrefix: CIDR for the SAN/cluster network (e.g. 10.10.30.0/24)
    $sanSettings = $null
    if ($TypeOfDeployment -eq 'Disaggregated') {
        $infraVolLunId = Read-Host "`nPlease enter the SAN Infrastructure Volume LUN ID (e.g. PURE1234567890ABCDEF)" -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($infraVolLunId)) {
            throw "Disaggregated deployment requires a non-empty InfraVolLunId."
        }
        $infraPerfLunId = Read-Host "`nPlease enter the SAN Infrastructure Performance LUN ID (e.g. PURE0987654321MNOPQR)" -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($infraPerfLunId)) {
            throw "Disaggregated deployment requires a non-empty InfraPerfLunId."
        }
        $sanNetworkAdapterName = Read-Host "`nPlease enter the SAN cluster network physical adapter name (e.g. 'ethernet 3')" -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($sanNetworkAdapterName)) {
            throw "Disaggregated deployment requires a non-empty SAN network adapter name."
        }
        $sanVlanRaw = Read-Host "`nPlease enter the SAN network VLAN ID (0-4095, 0 = untagged)" -ErrorAction Stop
        $sanVlanId = 0
        if (-not [int]::TryParse($sanVlanRaw, [ref]$sanVlanId) -or $sanVlanId -lt 0 -or $sanVlanId -gt 4095) {
            throw "Invalid SAN network VLAN ID '$sanVlanRaw'. Must be an integer between 0 and 4095."
        }
        $sanAddressPrefix = Read-Host "`nPlease enter the SAN network address prefix in CIDR notation (e.g. 10.10.30.0/24)" -ErrorAction Stop
        if (-not (Test-AzLocalIPv4Cidr -Value $sanAddressPrefix)) {
            throw "Invalid SAN network address prefix '$sanAddressPrefix'. Must be valid CIDR notation (e.g. 10.10.30.0/24)."
        }
        $sanSettings = [PsCustomObject][Ordered]@{
            infraVolLunId           = $infraVolLunId
            infraPerfLunId          = $infraPerfLunId
            sanNetworkAdapterName   = $sanNetworkAdapterName
            sanNetworkVlanId        = $sanVlanId
            sanNetworkAddressPrefix = $sanAddressPrefix
        }
    }

    # Return the network settings as a custom object
    $networkSettings = [PsCustomObject][Ordered]@{
        subnetMask       = $subnetMask.IPAddressToString
        defaultGateway   = $defaultGateway.IPAddressToString
        startingIPAddress = $startingIPAddress.IPAddressToString
        endingIPAddress  = $endingIPAddress.IPAddressToString
        nodeIPAddresses  = $nodeIPAddresses
        sanSettings      = $sanSettings
    }

    return $networkSettings
}
