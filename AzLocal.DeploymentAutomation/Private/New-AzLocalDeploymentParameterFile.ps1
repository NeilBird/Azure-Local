Function New-AzLocalDeploymentParameterFile {
    <#
    .SYNOPSIS

    This function updates the parameters for the Azure Local deployment and saves them to a file.

    .DESCRIPTION

    This function updates the parameters for the Azure Local deployment. It requires the following parameters:
    - UniqueID: The unique identifier for the deployment.
    - TypeOfDeployment: The type of deployment to perform (e.g., SingleNode, StorageSwitched, StorageSwitchless, RackAware).
    - ParameterFileSettings: The settings for the parameter file.
    - Parameters: The parameters for the deployment.

    #>
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true,Position=0)]
        [string]$UniqueID,

        [Parameter(Mandatory = $true,Position=1)]
        [ValidateSet("SingleNode","StorageSwitchless","StorageSwitched","RackAware","Disaggregated")]
        [string]$TypeOfDeployment,

        [Parameter(Mandatory = $true,Position=2)]
        [PsCustomObject]$ParameterFileSettings,

        [Parameter(Mandatory = $true,Position=3)]
        [PsCustomObject]$Parameters,

        [Parameter(Mandatory = $false,Position=4)]
        [ValidateRange(1,64)]
        [int]$NodeCount = 2
    )

    
    # Parameter file path
    $OutputDirectory = Join-Path $script:ModuleRoot "deployment-parameter-files"

    # StorageSwitchless deployments have a per-node-count template (2x(N-1) storage networks)
    $switchlessFileMap = @{
        2 = 'storage-switchless-2node-parameters-file.json'
        3 = 'storage-switchless-3node-parameters-file.json'
        4 = 'storage-switchless-4node-parameters-file.json'
    }

    # Validate NodeCount for StorageSwitchless (only 2-4 nodes have parameter file templates)
    if ($TypeOfDeployment -eq 'StorageSwitchless' -and $NodeCount -notin 2,3,4) {
        throw "StorageSwitchless deployments support 2-4 nodes only. NodeCount '$NodeCount' is not valid."
    }

    # Validate NodeCount for Disaggregated (SAN) deployments (1-64 nodes)
    if ($TypeOfDeployment -eq 'Disaggregated' -and ($NodeCount -lt 1 -or $NodeCount -gt 64)) {
        throw "Disaggregated deployments support 1-64 nodes only. NodeCount '$NodeCount' is not valid."
    }

    $parameterFileMap = @{
        'SingleNode'          = 'single-node-parameters-file.json'
        'StorageSwitchless'   = $switchlessFileMap[$NodeCount]
        'StorageSwitched'     = 'storage-switched-parameters-file.json'
        'RackAware'           = 'rack-aware-parameters-file.json'
        'Disaggregated'       = 'disaggregated-parameters-file.json'
    }
    $DeploymentParameterFilePath = Join-Path $OutputDirectory "$($UniqueID)-$($parameterFileMap[$TypeOfDeployment])"
    # Check if the directory exists, if not create it
    if(-not(Test-Path $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force -WhatIf:$false | Out-Null
    }

    # Update $ParameterFileSettings with the new values from $Parameters
    # Loop through the parameters in the parameter file settings
    ForEach($DeploymentParameter in $ParameterFileSettings.parameters) {

        ForEach ($property in ($DeploymentParameter.PSObject.Properties)) {

            # Check if the property name matches an entry in the parameters variable
            # If it does, update the value in the parameter file settings
            # Use PSObject.Properties to safely check existence (avoids StrictMode errors)
            if($Parameters.PSObject.Properties[$property.Name]) {
                Write-Debug "Updating $($property.Name) value to parameter value = $($Parameters.PSObject.Properties[$property.Name].Value)"
                $property.Value = $Parameters.PSObject.Properties[$property.Name].Value
            } else {
                # no match, do nothing
                Write-Debug "No match for $($property.Name) in parameters variable."
            }
        }
    }

    # Validate that no <calculated> placeholders remain in the parameter file
    # These indicate parameters that were not matched/replaced - the deployment would fail with invalid values
    $unresolvedParameters = @()
    ForEach($DeploymentParameter in $ParameterFileSettings.parameters) {
        ForEach ($property in ($DeploymentParameter.PSObject.Properties)) {
            $propValue = $property.Value
            # Check the 'value' property of each parameter object
            if ($propValue -is [PSCustomObject] -or $propValue -is [System.Collections.Specialized.OrderedDictionary]) {
                $innerValue = $null
                if ($propValue.PSObject.Properties['value']) {
                    $innerValue = $propValue.value
                }
                if ($innerValue -is [string] -and $innerValue -eq '<calculated>') {
                    $unresolvedParameters += $property.Name
                } elseif ($innerValue -is [array]) {
                    foreach ($item in $innerValue) {
                        if ($item -is [string] -and $item -eq '<calculated>') {
                            $unresolvedParameters += $property.Name
                            break
                        }
                    }
                }
            }
        }
    }

    if ($unresolvedParameters.Count -gt 0) {
        $paramList = ($unresolvedParameters | Sort-Object -Unique) -join ', '
        Write-AzLocalLog "Unresolved '<calculated>' placeholders found in parameter file for: $paramList" -Level Error
        Write-AzLocalLog "This indicates a bug in parameter matching - these values were not replaced with computed values." -Level Error
        throw "Parameter file contains unresolved '<calculated>' placeholders for: $paramList. Deployment would fail with invalid parameter values."
    }

    # Convert the updated parameter file settings back to JSON
    $UpdateParameterFileJSON = $ParameterFileSettings | ConvertTo-Json -Depth 100 | Format-Json

    # Save the updated JSON to the specified file
    try{
        $UpdateParameterFileJSON | Out-File -FilePath $DeploymentParameterFilePath -Encoding utf8 -ErrorAction Stop -Force -WhatIf:$false
        Write-AzLocalLog "Deployment parameter file created at $DeploymentParameterFilePath" -Level Success
    } catch {
        Write-AzLocalLog "Error writing to file: $DeploymentParameterFilePath" -Level Error
        throw "Failed to write deployment parameter file '$DeploymentParameterFilePath'. $($_.Exception.Message)"
    }

    return $DeploymentParameterFilePath
}
