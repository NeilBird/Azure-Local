@{

    # Script module file associated with this manifest.
    RootModule = 'AzLocal.DeploymentAutomation.psm1'

    # Version number of this module.
    ModuleVersion = '1.0.3'

    # ID used to uniquely identify this module
    GUID = 'a3e4b8c1-6f2d-4e5a-9b1c-7d8e3f0a2b4c'

    # Author of this module
    Author = 'Neil Bird, MSFT'

    # Company or vendor of this module
    CompanyName = 'Microsoft'

    # Copyright statement for this module
    Copyright = '(c) Neil Bird. Published using MIT License, See LICENSE file for details.'

    # Description of the functionality provided by this module
    Description = 'AzLocal.DeploymentAutomation module for deploying Azure Local using ARM templates and parameter files using PowerShell. Supports SingleNode, StorageSwitched (2-16 nodes with storage network switch), StorageSwitchless (2-4 nodes), RackAware (2, 4, 6, 8 nodes), and Disaggregated/SAN (1-64 nodes, SAN-backed storage with infraVolLunId/infraPerfLunId) deployments. Resource naming standards are configurable via .config/naming-standards-config.json.'

    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules = @(
        @{ ModuleName = 'Az.Accounts'; ModuleVersion = '2.0.0' },
        @{ ModuleName = 'Az.Resources'; ModuleVersion = '6.0.0' }
        # Az.KeyVault (v4.0.0+) is optional — only required when using -CredentialKeyVaultName.
        # The module checks for Az.KeyVault at runtime and provides a clear error if it is needed but not installed.
    )
    
    # Modules to import as nested modules of the module specified in RootModule/ModuleToProcess.
    # .ps1 files listed here are dot-sourced into the root module's session state, so they share
    # $script: scope with the root module. Only files explicitly listed here are loaded — any
    # unauthorised .ps1 file placed in these directories will be ignored.
    NestedModules = @(
        # Private (internal) functions
        'Private\Format-Json.ps1'
        'Private\Get-AzLocalArmResource.ps1'
        'Private\Get-AzLocalDeploymentNetworkSettings.ps1'
        'Private\Get-AzLocalNamingConfig.ps1'
        'Private\Get-AzLocalNetworkSettingsFromJson.ps1'
        'Private\Initialize-AzLocalUserConfig.ps1'
        'Private\Get-AzLocalParameterFilePath.ps1'
        'Private\Get-AzLocalParameterFileSettings.ps1'
        'Private\Get-AzLocalValidationTroubleshootingHints.ps1'
        'Private\Get-ValidUniqueID.ps1'
        'Private\Import-AzLocalDeploymentCsv.ps1'
        'Private\Initialize-AzLocalLogFile.ps1'
        'Private\New-AzLocalDeploymentParameterFile.ps1'
        'Private\New-AzLocalDeploymentReport.ps1'
        'Private\New-AzLocalJUnitXml.ps1'
        'Private\Resolve-AzLocalResourceName.ps1'
        'Private\Test-AzLocalAzurePrerequisites.ps1'
        'Private\Test-AzLocalClusterPreFlight.ps1'
        'Private\Test-AzLocalIPv4Cidr.ps1'
        'Private\Test-AzLocalNamingConfigDefaults.ps1'
        'Private\Test-AzLocalNotFoundError.ps1'
        'Private\Test-AzLocalResourceNames.ps1'
        'Private\Write-AzLocalLog.ps1'

        # Public (exported) functions
        'Public\Get-AzLocalDeploymentStatus.ps1'
        'Public\Start-AzLocalCsvDeployment.ps1'
        'Public\Start-AzLocalTemplateDeployment.ps1'
        'Public\Watch-AzLocalDeployment.ps1'
    )

    # Functions to export from this module
    FunctionsToExport = @(
        'Start-AzLocalTemplateDeployment',
        'Watch-AzLocalDeployment',
        'Start-AzLocalCsvDeployment',
        'Get-AzLocalDeploymentStatus'
    )

    # Cmdlets to export from this module
    CmdletsToExport = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport = @()

    # Private data to pass to the module specified in RootModule
    PrivateData = @{
        PSData = @{
            # Tags applied to this module for discoverability
            Tags = @('Azure', 'AzureLocal', 'AzureStackHCI', 'Deployment', 'ARM', 'Template')

            # A URL to the license for this module.
            LicenseUri = 'https://github.com/NeilBird/Azure-Local/blob/main/LICENSE'

            # A URL to the main website for this project.
            ProjectUri = 'https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.DeploymentAutomation/README.md'

            # Release notes for this version
            ReleaseNotes = @'
## v1.0.3 - July 2026

### Reliability and diagnostic hardening
- Azure resource, resource-group, and deployment lookups now distinguish genuine not-found responses from authentication, RBAC, context, API-version, and transport failures instead of masking every lookup failure as an absent resource.
- Resource-provider registration now waits for completion with a bounded timeout before deployment continues.
- Strict-mode-safe handling was added for optional ARM error, duration, detail, and troubleshooting-hint properties.
- User configuration, logs, parameter files, JUnit output, and deployment reports are written reliably when diagnostic/scaffolding helpers inherit `-WhatIf` from a parent deployment cmdlet.

### Validation, reporting, and performance
- Ready CSV rows now require complete non-interactive deployment values, with semantic DNS and IPv4 CIDR validation; draft rows can remain incomplete.
- SAN address prefixes now require a valid IPv4 network and prefix length from 0 through 32.
- JUnit generation now uses invariant numeric formatting, safely handles arbitrary error text and sparse result objects, and no longer mixes XML content with file-output pipeline results.
- HTML and Markdown reports classify all `*Error` outcomes as failures and surface report-generation dependency errors clearly.
- Fleet result accumulation now uses linear-time generic lists while preserving object-array output.

### Safer publishing
- `Publish-Module.ps1` now builds the package from an explicit file allowlist derived from the manifest plus approved assets. The staged package matches every functional file in the published 1.0.2 package and adds only the two new validation helpers.
- Publishing fails closed when a required allowlisted file is missing, an unexpected file appears in staging, or the existing secret scan detects sensitive content.

## v1.0.2 - June 2026

### Hardened Azure resource existence checks (fixes misleading "Arc node not found")
Existence checks used `Get-AzResource -ErrorAction SilentlyContinue`, which swallowed ALL errors (HTTP 400 unsupported api-version, auth, RBAC, transport) and returned `$null`, so callers misreported the resource as missing.

- New private helper `Get-AzLocalArmResource` returns `$null` only for a genuine 404 and throws on real failures. It self-heals an unsupported auto-negotiated api-version by parsing ARM's supported-versions list and retrying with the newest stable version.
- All four existence-check call sites now use the helper (`Start-AzLocalTemplateDeployment`, `Test-AzLocalClusterPreFlight`, `Get-AzLocalDeploymentStatus`). Arc node lookups default to the GA `Microsoft.HybridCompute/machines` api-version `2025-01-13`.
- `Start-AzLocalTemplateDeployment` now pins context via `Set-AzContext -SubscriptionId -TenantId` on the direct path (multi-subscription tenants could otherwise default to the wrong subscription).

## v1.0.1 - May 2026
- Added an optional validated `dnsServers` array to `-NetworkSettingsJson` for per-deployment DNS overrides.
- DNS precedence is explicit parameter, JSON payload, then naming-config defaults. Existing payloads remain compatible.

## v1.0.0 - April 2026
- Added first-class Disaggregated/SAN deployments for 1-64 nodes, including dedicated ARM and parameter templates, SAN network and LUN settings, CSV/JSON/interactive inputs, and topology validation.
- Existing SingleNode, StorageSwitched, StorageSwitchless, and RackAware workflows remain compatible.

## v0.9.81 - April 2026
- Fixed bug in Start-AzLocalTemplateDeployment where $_ was shadowed by a nested catch block, causing ARM deployment error details to be silently lost
- Fixed credential SecureString disposal gap: moved try/finally to wrap all post-credential code so credentials are always disposed even if pre-deployment checks throw
- Fixed Invoke-RestMethod -UseBasicParsing invalid parameter in Get-AzLocalValidationTroubleshootingHints (PS 5.1 does not support this parameter on Invoke-RestMethod) - online TSG search was silently broken
- Fixed [regex]::Unescape() in Format-Json corrupting legitimate escape sequences (UNC paths, literal backslashes) in JSON output
- Added NodeCount validation for StorageSwitchless in Get-AzLocalParameterFilePath and New-AzLocalDeploymentParameterFile - now throws a clear error instead of silently producing an invalid path
- Added NodeCount > 0 validation for multi-node deployment types in Get-AzLocalDeploymentNetworkSettings
- Added consecutive failure counter (limit 10) to Watch-AzLocalDeployment polling loop with error message logging - prevents unbounded silent retry on persistent failures
- Fixed IDisposable resource leak in New-AzLocalJUnitXml: XmlWriter and StringWriter now wrapped in try/finally
- Replaced non-ASCII emoji characters in New-AzLocalDeploymentReport with ASCII-compatible text markers to comply with encoding convention
- Fixed version mismatch between .NOTES and HTML footer in New-AzLocalDeploymentReport

## Earlier versions (v0.9.8 and below)
For full release history of v0.9.8 (user profile config workflow, -NamingConfigPath, Test-AzLocalNamingConfigDefaults), v0.9.7 (Watch-AzLocalDeployment no-timeout default), v0.9.6 (RDMA / inbox driver / RP registration troubleshooting hints), v0.9.5 (GitHub Actions injection fix, Get-AzLocalValidationTroubleshootingHints + -SkipOnlineTSGSearch), v0.9.4 (Write-AzLocalLog + rich exceptions), v0.9.3 (TypeOfDeployment rename: MultiNode->StorageSwitched, Switchless->StorageSwitchless), v0.9.2 (Test-AzLocalAzurePrerequisites: RP + RBAC checks), v0.9.1 (per-node-count switchless templates, -NodeCount parameter), and v0.9.0 (CI/CD CSV-driven multi-cluster deployments + Start-AzLocalCsvDeployment + Get-AzLocalDeploymentStatus), see the GitHub repository: https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.DeploymentAutomation/README.md
'@
        }
    }
}
