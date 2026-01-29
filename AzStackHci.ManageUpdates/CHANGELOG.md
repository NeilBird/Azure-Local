# Changelog

All notable changes to the AzStackHci.ManageUpdates module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.2] - 2026-01-29

### Documentation
- Verified and documented that all functions work with three authentication methods:
  1. **Interactive** - Standard user login via `az login`
  2. **Service Principal** - CI/CD automation using `Connect-AzureLocalServicePrincipal`
  3. **Managed Identity (MSI)** - Azure-hosted agents using `Connect-AzureLocalServicePrincipal -UseManagedIdentity`

## [0.4.1] - 2026-01-29

### Added
- Managed Identity (MSI) authentication support in `Connect-AzureLocalServicePrincipal` with `-UseManagedIdentity` switch
- `-ManagedIdentityClientId` parameter for user-assigned managed identities
- `-PassThru` switch for `Get-AzureLocalClusterInventory` to return objects even when exporting to CSV (useful for CI/CD pipelines)

### Fixed
- **CRITICAL**: Azure Resource Graph queries in `Get-AzureLocalClusterInventory`, `Start-AzureLocalClusterUpdate`, and `Get-AzureLocalClusterUpdateReadiness` were returning incorrect resource types (mixed resources like networkInterfaces, virtualHardDisks, extensions instead of clusters only). The root cause was HERE-STRING query format (`@"..."@`) causing malformed az CLI commands. Changed all ARG queries to single-line string format.
- **CRITICAL**: `Set-AzureLocalClusterUpdateRingTag` failing with JSON deserialization errors when applying tags. PowerShell/cmd.exe was mangling JSON quotes when passed to `az rest --body`. Now uses temp file with `@file` syntax to avoid escaping issues.
- **CRITICAL**: `Set-AzureLocalClusterUpdateRingTag` including PowerShell hashtable internal properties (`Keys`, `Values`) in JSON body. Now uses `[PSCustomObject]` with filtered `NoteProperty` members only.

### Changed
- `Get-AzureLocalClusterInventory` no longer dumps objects to console when using `-ExportCsvPath` (cleaner output)

## [0.4.0] - 2026-01-29

### Added
- `Get-AzureLocalClusterInventory` function to query all clusters and their UpdateRing tag status
- CSV-based workflow for managing UpdateRing tags (export inventory, edit in Excel, import back)
- `Set-AzureLocalClusterUpdateRingTag` now accepts `-InputCsvPath` parameter for bulk tag operations
- JUnit XML export for CI/CD pipeline integration (Azure DevOps, GitHub Actions, Jenkins, GitLab CI)
- CI/CD automation pipeline examples for GitHub Actions and Azure DevOps

### Changed
- Renamed `-ScopeByTagName` to `-ScopeByUpdateRingTag` for clarity (now a switch parameter)
- Renamed `-TagValue` to `-UpdateRingValue` for consistency
- UpdateRing tag queries now use hardcoded 'UpdateRing' tag name for consistency
- `-ExportResultsPath` and `-ExportCsvPath` now support `.xml` extension for JUnit format

### Fixed
- PSScriptAnalyzer warnings (empty catch blocks, unused variables)

## [0.3.0] - 2026-01-28

### Added
- `Connect-AzureLocalServicePrincipal` function for CI/CD automation (GitHub Actions, Azure DevOps)
- Service Principal authentication via parameters or environment variables (`AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `AZURE_TENANT_ID`)

### Changed
- All functions now have `[OutputType()]` attributes for better IntelliSense
- Centralized API version constant for consistency
- Renamed internal function to use approved verb (`Install-AzGraphExtension`)
- `Write-Log` is now internal only (not exported)
- Added `#Requires -Version 5.1` statement
- Added LicenseUri to manifest for PowerShell Gallery compliance
- Added 'Automation' and 'CICD' tags for discoverability

## [0.2.0] - 2026-01-27

### Added
- `Set-AzureLocalClusterUpdateRingTag` function to manage UpdateRing tags on clusters
- Auto-install Azure CLI resource-graph extension for pipeline/automation scenarios
- Tag-based cluster filtering using `-ScopeByUpdateRingTag` and `-UpdateRingValue` parameters
- `-Force` parameter support for tag operations to overwrite existing tags
- Comprehensive logging for all tag operations with CSV output

### Changed
- Health check filtering now shows only Critical and Warning severities (not Informational)
- Enhanced CSV diagnostics with health check failures and update run error details
- `Get-AzureLocalClusterUpdateReadiness` now supports tag-based scoping

### Fixed
- Corrected API path for querying update run errors

## [0.1.0] - 2026-01-26

### Added
- Initial release
- `Start-AzureLocalClusterUpdate`: Start updates on one or more Azure Local clusters
- `Get-AzureLocalClusterUpdateReadiness`: Assess update readiness with diagnostics
- `Get-AzureLocalClusterInfo`: Retrieve cluster information
- `Get-AzureLocalUpdateSummary`: Get update summary for a cluster
- `Get-AzureLocalAvailableUpdates`: List available updates for a cluster
- `Get-AzureLocalUpdateRuns`: Monitor update progress
- Comprehensive logging with transcript support
- Export results to JSON/CSV
