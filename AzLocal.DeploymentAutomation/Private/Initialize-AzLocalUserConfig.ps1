Function Initialize-AzLocalUserConfig {
    ########################################
    <#
    .SYNOPSIS
        Copies the naming configuration file to the user's profile for persistent customisation.

    .DESCRIPTION
        Creates a .AzLocalDeploymentAutomation directory under $env:USERPROFILE and copies the
        default naming-standards-config.json from the module installation path. This allows
        users to customise naming standards without editing files inside the module directory,
        and ensures customisations survive module updates via Update-Module.

        If the user config directory already exists, only missing files are copied.
        Existing files are not overwritten.

    .NOTES
        Author:  Neil Bird, MSFT
        Version: 1.0
        Created: March 27th 2026
    #>
    ########################################

    [OutputType([string])]
    param()

    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        throw "USERPROFILE environment variable is not set. Cannot initialise user configuration directory."
    }

    $userConfigDir  = Join-Path $env:USERPROFILE '.AzLocalDeploymentAutomation'
    $userConfigFile = Join-Path $userConfigDir 'naming-standards-config.json'
    $sourceConfigFile = Join-Path $script:ModuleRoot '.config\naming-standards-config.json'

    # Create the user config directory if it doesn't exist
    if (-not (Test-Path $userConfigDir)) {
        try {
            New-Item -Path $userConfigDir -ItemType Directory -Force -ErrorAction Stop -WhatIf:$false | Out-Null
            Write-AzLocalLog "Created user configuration directory: $userConfigDir" -Level Success
        } catch {
            throw "Failed to create user configuration directory '$userConfigDir'. $($_.Exception.Message)"
        }
    }

    # Copy the naming config if it doesn't already exist in the user directory
    if (-not (Test-Path $userConfigFile)) {
        if (-not (Test-Path $sourceConfigFile)) {
            throw "Module naming configuration file not found at '$sourceConfigFile'. Module installation may be corrupt."
        }
        try {
            Copy-Item -Path $sourceConfigFile -Destination $userConfigFile -Force -ErrorAction Stop -WhatIf:$false
            Write-AzLocalLog "Copied default naming configuration to: $userConfigFile" -Level Success
        } catch {
            throw "Failed to copy naming configuration to '$userConfigFile'. $($_.Exception.Message)"
        }
    }

    # Create a README in the user config directory explaining the files
    $userReadmePath = Join-Path $userConfigDir 'README.md'
    if (-not (Test-Path $userReadmePath)) {
        $readmeContent = @"
# AzLocal.DeploymentAutomation - User Configuration

This directory contains your personalised naming configuration for Azure Local deployments.

## Files

- **naming-standards-config.json** - Naming standards, defaults, and environment settings.
  Edit this file to customise resource naming patterns, default values, and tenant-specific settings.

## How It Works

When you run deployment functions (e.g., ``Start-AzLocalTemplateDeployment``), the module loads
the naming configuration from this directory instead of the module installation path. This ensures
your customisations survive module updates via ``Update-Module``.

## Resetting to Defaults

To reset to the module's default configuration, delete ``naming-standards-config.json`` from this
directory and run any deployment function. The module will automatically copy a fresh default
configuration from the installed module.

## Override Per-Invocation

You can specify a custom config file path per-invocation using the ``-NamingConfigPath`` parameter:

``````powershell
Start-AzLocalTemplateDeployment -NamingConfigPath 'C:\MyConfigs\site-1-config.json' ...
``````
"@
        Set-Content -Path $userReadmePath -Value $readmeContent -Encoding UTF8 -WhatIf:$false
        Write-AzLocalLog "Created README at: $userReadmePath" -Level Info
    }

    Write-AzLocalLog "User configuration directory: $userConfigDir" -Level Info
    Write-AzLocalLog "Edit '$userConfigFile' to customise naming standards and environment settings." -Level Info

    return $userConfigFile
}
