# Changelog

All notable changes to the AzStackHci.ManageUpdates module will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.6] - 2026-01-29

### Added - Fleet-Scale Operations
New functions for managing updates across fleets of 1000-3000+ clusters:

- **`Invoke-AzureLocalFleetOperation`** - Orchestrates fleet-wide operations with:
  - Configurable batch processing (default: 50 clusters per batch)
  - Throttling and rate limiting (default: 10 parallel operations)
  - Automatic retry with exponential backoff (default: 3 retries)
  - State checkpointing for resume capability
  - Operations: ApplyUpdate, CheckReadiness, GetStatus

- **`Get-AzureLocalFleetProgress`** - Real-time progress tracking:
  - Total, completed, in-progress, failed, pending counts
  - Success/failure percentages
  - Per-cluster status details (with -Detailed switch)

- **`Test-AzureLocalFleetHealthGate`** - CI/CD health gate for safe wave deployments:
  - Maximum failure percentage threshold (default: 5%)
  - Minimum success percentage threshold (default: 90%)
  - Wait for completion option with timeout
  - Returns Pass/Fail for pipeline decisions

- **`Export-AzureLocalFleetState`** - Save operation state for resume:
  - JSON format with full cluster tracking
  - Includes run ID, timestamps, and per-cluster status

- **`Resume-AzureLocalFleetUpdate`** - Resume interrupted operations:
  - Load state from file or object
  - Option to retry failed clusters
  - Continues from last checkpoint

- **`Stop-AzureLocalFleetUpdate`** - Graceful stop with state save:
  - Saves current progress
  - Does not cancel in-progress cluster updates

### Use Cases
- **Enterprise Scale**: Process 1000-3000+ clusters with batching
- **CI/CD Safety**: Health gates prevent cascading failures
- **Resilience**: Resume capability after pipeline timeouts or interruptions
- **Visibility**: Real-time progress tracking during long operations

## [0.5.5] - 2026-01-29

### Added
- **Fleet-Wide Tag Support for All Query Functions**: Three functions now support multi-cluster queries:
  - `Get-AzureLocalUpdateSummary` - Query update summaries across fleet
  - `Get-AzureLocalAvailableUpdates` - List available updates across fleet
  - `Get-AzureLocalUpdateRuns` - Get update run history across fleet
- **New Parameters for Multi-Cluster Queries**:
  - `-ClusterNames` - Query multiple clusters by name
  - `-ClusterResourceIds` - Query multiple clusters by resource ID
  - `-ScopeByUpdateRingTag` + `-UpdateRingValue` - Query clusters by UpdateRing tag
  - `-ExportPath` - Export results to CSV, JSON, or JUnit XML format
- **Fleet Update Status Pipeline**: New `fleet-update-status.yml` CI/CD pipeline for monitoring update status across entire cluster fleet
  - Available for both GitHub Actions and Azure DevOps
  - Generates JUnit XML reports for CI/CD dashboard integration
  - Each cluster appears as a test case (passed=healthy, failed=issues)
  - Multiple output formats: CSV, JSON, and JUnit XML
  - Scheduled daily checks at 6 AM UTC (configurable)
  - Flexible scope: all clusters or filter by UpdateRing tag
- **Dashboard Integration**: JUnit XML results display in GitHub Actions Tests tab and Azure DevOps Tests tab with trend analytics

### Improved
- **Consistent Logging**: All functions now use `Write-Log` for consistent, timestamped, colored console output
- **File Logging Support**: When `$script:LogFilePath` is configured, all functions write to log files
- **Better Progress Visibility**: Users can see exactly what API operations are happening during function execution
- **Severity-Based Coloring**: Messages use appropriate levels (Info=White, Warning=Yellow, Error=Red, Success=Green, Header=Cyan)
- All fleet query functions provide consistent fleet-wide reporting with summaries
- Export support includes CSV, JSON, and JUnit XML for CI/CD integration
- **Backward Compatibility**: Single-cluster parameter sets remain unchanged for existing scripts

## [0.5.0] - 2026-01-29

### Security
- Added comprehensive OpenID Connect (OIDC) documentation for secretless CI/CD authentication
- Documented authentication methods ranked by security: OIDC (recommended) > Managed Identity > Client Secret
- GitHub Actions workflows now default to OIDC authentication with `id-token: write` permission
- Added Azure DevOps Workload Identity Federation setup instructions

### Documentation
- Added authentication method comparison table with security ratings
- Updated Quick Start guide with OIDC examples for GitHub Actions
- Added links to Microsoft documentation for federated credentials setup
- Documented subject claim patterns for GitHub Actions (branch, PR, environment, tag)
- Added warning that client secrets are legacy/not recommended

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
- `Get-AzureLocalClusterInventory` no longer dumps objects to console when using `-ExportPath` (cleaner output)

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
- `-ExportResultsPath` and `-ExportPath` now support `.xml` extension for JUnit format

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
