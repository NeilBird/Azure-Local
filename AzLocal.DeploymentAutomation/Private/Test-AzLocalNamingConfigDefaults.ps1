Function Test-AzLocalNamingConfigDefaults {
    ########################################
    <#
    .SYNOPSIS
        Validates that the naming configuration has been customised from shipped defaults.

    .DESCRIPTION
        Checks the naming configuration object for placeholder/example values that ship with
        the module. These defaults (contoso.com, xxxxxxxx tenant ID) will never work in a real
        deployment, so this function provides a clear early failure with actionable guidance.

        Called by public deployment functions before any ARM operations are attempted.

    .PARAMETER Config
        The naming configuration object returned by Get-AzLocalNamingConfig.

    .PARAMETER ConfigFilePath
        The file path the configuration was loaded from, for error message context.

    .NOTES
        Author:  Neil Bird, MSFT
        Version: 1.0
        Created: March 27th 2026
    #>
    ########################################

    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Config,

        [Parameter(Mandatory = $false)]
        [string]$ConfigFilePath = ""
    )

    $configErrors = @()

    # Check environment section and tenant-specific values.
    if ($null -eq $Config.PSObject.Properties['environment'] -or $null -eq $Config.environment) {
        $configErrors += "environment section is missing from the configuration file."
    } else {
        if ($null -eq $Config.environment.PSObject.Properties['tenantId'] -or
            [string]::IsNullOrWhiteSpace([string]$Config.environment.tenantId)) {
            $configErrors += "environment.tenantId is missing or empty. Set it to your Entra ID tenant GUID."
        } elseif ($Config.environment.tenantId -eq 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx') {
            $configErrors += "environment.tenantId is still the placeholder value. Set it to your Entra ID tenant GUID. Find it with: (Get-AzContext).Tenant.Id"
        } else {
            [guid]$parsedTenantId = [guid]::Empty
            if (-not [guid]::TryParse([string]$Config.environment.tenantId, [ref]$parsedTenantId)) {
                $configErrors += "environment.tenantId must be a valid GUID."
            }
        }

        if ($Config.environment.PSObject.Properties['hciResourceProviderObjectID'] -and
            -not [string]::IsNullOrWhiteSpace([string]$Config.environment.hciResourceProviderObjectID)) {
            [guid]$parsedObjectId = [guid]::Empty
            if (-not [guid]::TryParse([string]$Config.environment.hciResourceProviderObjectID, [ref]$parsedObjectId)) {
                $configErrors += "environment.hciResourceProviderObjectID must be a valid GUID when specified."
            }
        }
    }

    # Check every default consumed by Start-AzLocalTemplateDeployment.
    if ($null -eq $Config.PSObject.Properties['defaults'] -or $null -eq $Config.defaults) {
        $configErrors += "defaults section is missing from the configuration file."
    } else {
        foreach ($propertyName in @('domainFqdn', 'namingPrefix', 'azureStackLCMAdminUsername', 'location', 'storageAccountType')) {
            if ($null -eq $Config.defaults.PSObject.Properties[$propertyName] -or
                [string]::IsNullOrWhiteSpace([string]$Config.defaults.$propertyName)) {
                $configErrors += "defaults.$propertyName is missing or empty."
            }
        }

        foreach ($propertyName in @('dnsServers', 'computeManagementAdapters', 'storageAdapters')) {
            if ($null -eq $Config.defaults.PSObject.Properties[$propertyName] -or
                @($Config.defaults.$propertyName).Count -eq 0 -or
                @($Config.defaults.$propertyName | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
                $configErrors += "defaults.$propertyName must contain at least one non-empty value."
            }
        }

        if ($Config.defaults.PSObject.Properties['dnsServers']) {
            foreach ($dnsServer in @($Config.defaults.dnsServers)) {
                if ([string]::IsNullOrWhiteSpace([string]$dnsServer)) { continue }
                [System.Net.IPAddress]$parsedAddress = $null
                if (-not [System.Net.IPAddress]::TryParse([string]$dnsServer, [ref]$parsedAddress)) {
                    $configErrors += "defaults.dnsServers contains invalid IP address '$dnsServer'."
                }
            }
        }

        if ($Config.defaults.PSObject.Properties['domainFqdn'] -and $Config.defaults.domainFqdn -eq 'contoso.com') {
            $configErrors += "defaults.domainFqdn is still the example value 'contoso.com'. Set it to your Active Directory domain FQDN."
        }
    }

    # Check every naming pattern consumed by deployment and monitoring functions.
    if ($null -eq $Config.PSObject.Properties['namingStandards'] -or $null -eq $Config.namingStandards) {
        $configErrors += "namingStandards section is missing from the configuration file."
    } else {
        $requiredNamingStandards = @(
            'clusterName',
            'resourceGroupName',
            'keyVaultName',
            'customLocation',
            'resourceBridgeName',
            'diagnosticStorageAccountName',
            'clusterWitnessStorageAccountName',
            'nodeNamePattern',
            'adouPath',
            'deploymentName'
        )
        foreach ($propertyName in $requiredNamingStandards) {
            if ($null -eq $Config.namingStandards.PSObject.Properties[$propertyName] -or
                [string]::IsNullOrWhiteSpace([string]$Config.namingStandards.$propertyName)) {
                $configErrors += "namingStandards.$propertyName is missing or empty."
            }
        }

        if ($Config.namingStandards.PSObject.Properties['adouPath'] -and
            $Config.namingStandards.adouPath -match 'DC=contoso,DC=com') {
            $configErrors += "namingStandards.adouPath still references 'DC=contoso,DC=com'. Update the OU path to match your Active Directory structure."
        }
    }

    if ($configErrors.Count -gt 0) {
        Write-AzLocalLog "Naming configuration file has not been customised for your environment." -Level Error
        if (-not [string]::IsNullOrWhiteSpace($ConfigFilePath)) {
            Write-AzLocalLog "Config file: $ConfigFilePath" -Level Error
        }
        foreach ($err in $configErrors) {
            Write-AzLocalLog "  - $err" -Level Error
        }
        Write-AzLocalLog "Edit the configuration file and update the values above before running a deployment." -Level Error
        $pathHint = if (-not [string]::IsNullOrWhiteSpace($ConfigFilePath)) { " at '$ConfigFilePath'" } else { "" }
        throw "Naming configuration${pathHint} is invalid: $($configErrors -join ' ')"
    }
}
