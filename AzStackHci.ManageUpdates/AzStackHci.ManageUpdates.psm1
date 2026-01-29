#Requires -Version 5.1
<#
.SYNOPSIS
    AzStackHci.ManageUpdates module for automating updates on Azure Local (Azure Stack HCI) clusters.

.DESCRIPTION
    This module queries Azure Local clusters by name or resource ID, checks their update status,
    and starts specified updates on clusters that are in "Ready" state with "UpdatesAvailable".
    
    It uses the Azure REST API directly via az rest to call the Update Manager API.
    
    Includes comprehensive logging capabilities with timestamped log files, 
    transcript support, and result export to JSON/CSV.
    
    Supports Service Principal authentication for CI/CD automation scenarios
    (GitHub Actions, Azure DevOps Pipelines).

.PARAMETER ClusterNames
    An array of Azure Local cluster names to update. Use this OR ClusterResourceIds.

.PARAMETER ClusterResourceIds
    An array of full Azure Resource IDs for the clusters to update. Use this when clusters
    are in different resource groups or subscriptions. Use this OR ClusterNames.
    
    The Resource IDs are validated before processing to ensure:
    - The format is correct (must match Azure Stack HCI cluster resource pattern)
    - The resource exists in Azure
    - You have the required permissions to access the resource
    
    Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"

.PARAMETER ScopeByUpdateRingTag
    Uses the "UpdateRing" tag to find clusters via Azure Resource Graph.
    Must be used together with -UpdateRingValue. This enables updating clusters at scale
    using the UpdateRing tagging strategy. Works across multiple subscriptions.
    
    Requires the Azure CLI 'resource-graph' extension (automatically installed if missing).

.PARAMETER UpdateRingValue
    The value of the UpdateRing tag to match when using -ScopeByUpdateRingTag. Only clusters 
    where the UpdateRing tag equals this value will be selected for updates.
    Common values: "Ring1", "Ring2", "Ring3", "Production"

.PARAMETER ResourceGroupName
    The resource group containing the clusters. If not specified, the function will 
    search for the cluster across all resource groups in the subscription.
    Only used with -ClusterNames parameter.

.PARAMETER SubscriptionId
    The Azure subscription ID. If not specified, uses the current az CLI subscription.
    Only used with -ClusterNames parameter.

.PARAMETER UpdateName
    The specific update name to apply. If not specified, the function will list 
    available updates and prompt for selection or apply the latest available update.

.PARAMETER ApiVersion
    The API version to use. Defaults to "2025-10-01".

.PARAMETER LogFolderPath
    Path to the folder where log files will be created. If not specified, defaults to:
    C:\ProgramData\AzStackHci.ManageUpdates\
    
    This default location is accessible across different user profiles.
    The folder is automatically created if it doesn't exist.

.PARAMETER EnableTranscript
    Enables PowerShell transcript recording to capture all console output.

.PARAMETER ExportResultsPath
    Path to export results. Supports multiple formats based on file extension:
    - .json = JSON format with summary statistics
    - .csv  = Standard CSV format
    - .xml  = JUnit XML format for CI/CD pipeline integration
    
    JUnit XML is compatible with:
    - Azure DevOps (Publish Test Results task)
    - GitHub Actions (dorny/test-reporter or similar)
    - Jenkins (JUnit plugin)
    - GitLab CI (native support)
    - TeamCity (built-in)
    
    If no extension is provided, defaults to JSON.

.PARAMETER WhatIf
    Shows what would happen if the cmdlet runs. The cmdlet is not run.

.EXAMPLE
    # Start update on a single cluster with logging
    Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG" -LogPath "C:\Logs\update.log"

.EXAMPLE
    # Start updates on multiple clusters with transcript and JSON export
    Start-AzureLocalClusterUpdate -ClusterNames @("Cluster01", "Cluster02") -EnableTranscript -ExportResultsPath "C:\Logs\results.json"

.EXAMPLE
    # Start a specific update with full logging
    Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -UpdateName "Solution12.2601.1002.38" -LogPath "C:\Logs\update.log" -EnableTranscript

.EXAMPLE
    # Start updates on clusters in different resource groups using Resource IDs
    $resourceIds = @(
        "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
        "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
    )
    Start-AzureLocalClusterUpdate -ClusterResourceIds $resourceIds -Force

.EXAMPLE
    # Start updates on all clusters tagged with "UpdateRing" = "Ring1" (across all subscriptions)
    Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Ring1" -Force

.EXAMPLE
    # Start updates on production ring clusters
    Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Production" -UpdateName "Solution12.2601.1002.38" -Force

.EXAMPLE
    # Export results to JUnit XML for CI/CD pipeline integration (Azure DevOps, GitHub Actions, Jenkins)
    Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Ring1" -Force -ExportResultsPath "C:\Logs\update-results.xml"

.NOTES
    Version: 0.4.0
    Author: Neil Bird, Microsoft.
    Requires: Azure CLI (az) installed and authenticated
    API Reference: https://github.com/Azure/azure-rest-api-specs/blob/main/specification/azurestackhci/resource-manager/Microsoft.AzureStackHCI/StackHCI/stable/2025-10-01/hci.json
#>

# Module constants
$script:ModuleVersion = '0.4.0'
$script:DefaultApiVersion = '2025-10-01'
$script:DefaultLogFolder = Join-Path -Path $env:ProgramData -ChildPath 'AzStackHci.ManageUpdates'

# Script-level variables for logging
$script:LogFilePath = $null
$script:ErrorLogPath = $null
$script:UpdateSkippedLogPath = $null
$script:UpdateStartedLogPath = $null

# Service Principal authentication state
$script:ServicePrincipalAuthenticated = $false

function Connect-AzureLocalServicePrincipal {
    <#
    .SYNOPSIS
        Authenticates to Azure using a Service Principal for CI/CD automation.
    
    .DESCRIPTION
        Logs into Azure CLI using Service Principal credentials, enabling automated
        operations in GitHub Actions, Azure DevOps Pipelines, or other CI/CD systems.
        
        Credentials can be provided via parameters or environment variables:
        - Parameters: -ServicePrincipalId, -ServicePrincipalSecret, -TenantId
        - Environment variables: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID
        
        If already authenticated (interactively or via SP), this function will skip login
        unless -Force is specified.
    
    .PARAMETER ServicePrincipalId
        The Application (client) ID of the Service Principal. 
        Can also be set via AZURE_CLIENT_ID environment variable.
    
    .PARAMETER ServicePrincipalSecret
        The client secret for the Service Principal.
        Can also be set via AZURE_CLIENT_SECRET environment variable.
        For security, prefer using environment variables in CI/CD.
    
    .PARAMETER TenantId
        The Azure AD tenant ID.
        Can also be set via AZURE_TENANT_ID environment variable.
    
    .PARAMETER Force
        Force re-authentication even if already logged in.
    
    .OUTPUTS
        Returns $true if authentication succeeded, $false otherwise.
    
    .EXAMPLE
        # Using parameters (not recommended for CI/CD - use env vars instead)
        Connect-AzureLocalServicePrincipal -ServicePrincipalId $appId -ServicePrincipalSecret $secret -TenantId $tenant
    
    .EXAMPLE
        # Using environment variables (recommended for CI/CD)
        $env:AZURE_CLIENT_ID = 'your-app-id'
        $env:AZURE_CLIENT_SECRET = 'your-secret'
        $env:AZURE_TENANT_ID = 'your-tenant-id'
        Connect-AzureLocalServicePrincipal
    
    .EXAMPLE
        # GitHub Actions workflow - credentials from secrets
        # env:
        #   AZURE_CLIENT_ID: ${{ secrets.AZURE_CLIENT_ID }}
        #   AZURE_CLIENT_SECRET: ${{ secrets.AZURE_CLIENT_SECRET }}
        #   AZURE_TENANT_ID: ${{ secrets.AZURE_TENANT_ID }}
        Connect-AzureLocalServicePrincipal
    
    .NOTES
        The Service Principal requires the following permissions:
        - Microsoft.AzureStackHCI/clusters/read
        - Microsoft.AzureStackHCI/clusters/updates/read
        - Microsoft.AzureStackHCI/clusters/updates/apply/action
        - Microsoft.AzureStackHCI/clusters/updateSummaries/read
        - Microsoft.AzureStackHCI/clusters/updateRuns/read
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$ServicePrincipalId,

        [Parameter(Mandatory = $false)]
        [string]$ServicePrincipalSecret,

        [Parameter(Mandatory = $false)]
        [string]$TenantId,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # Check for existing authentication unless Force is specified
    if (-not $Force) {
        try {
            $accountInfo = az account show 2>$null | ConvertFrom-Json
            if ($LASTEXITCODE -eq 0 -and $accountInfo) {
                Write-Verbose "Already authenticated as: $($accountInfo.user.name) (Type: $($accountInfo.user.type))"
                return $true
            }
        }
        catch {
            # Not authenticated, continue with SP login - this is expected behavior
            Write-Verbose "No existing Azure CLI session, proceeding with Service Principal authentication"
        }
    }

    # Get credentials from parameters or environment variables
    $clientId = if ($ServicePrincipalId) { $ServicePrincipalId } else { $env:AZURE_CLIENT_ID }
    $clientSecret = if ($ServicePrincipalSecret) { $ServicePrincipalSecret } else { $env:AZURE_CLIENT_SECRET }
    $tenant = if ($TenantId) { $TenantId } else { $env:AZURE_TENANT_ID }

    # Validate required credentials
    if (-not $clientId) {
        Write-Error "Service Principal ID not provided. Set -ServicePrincipalId parameter or AZURE_CLIENT_ID environment variable."
        return $false
    }
    if (-not $clientSecret) {
        Write-Error "Service Principal Secret not provided. Set -ServicePrincipalSecret parameter or AZURE_CLIENT_SECRET environment variable."
        return $false
    }
    if (-not $tenant) {
        Write-Error "Tenant ID not provided. Set -TenantId parameter or AZURE_TENANT_ID environment variable."
        return $false
    }

    Write-Host "Authenticating with Service Principal..." -ForegroundColor Yellow
    
    try {
        # Login using Service Principal
        $loginResult = az login --service-principal `
            --username $clientId `
            --password $clientSecret `
            --tenant $tenant `
            --output none 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Service Principal authentication failed: $loginResult"
            return $false
        }

        # Verify authentication
        $accountInfo = az account show 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and $accountInfo) {
            Write-Host "Successfully authenticated as Service Principal: $($accountInfo.user.name)" -ForegroundColor Green
            Write-Host "Subscription: $($accountInfo.name) ($($accountInfo.id))" -ForegroundColor Gray
            $script:ServicePrincipalAuthenticated = $true
            return $true
        }
        else {
            Write-Error "Authentication succeeded but account verification failed."
            return $false
        }
    }
    catch {
        Write-Error "Service Principal authentication error: $($_.Exception.Message)"
        return $false
    }
}

function Install-AzGraphExtension {
    <#
    .SYNOPSIS
        Installs the Azure CLI resource-graph extension if not present.
    
    .DESCRIPTION
        Checks if the Azure CLI 'resource-graph' extension is installed.
        If not installed, automatically installs it to enable Azure Resource Graph queries.
        This enables non-interactive pipeline/automation scenarios.
    
    .OUTPUTS
        Returns $true if the extension is available (already installed or successfully installed).
        Returns $false if installation failed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        # Check if extension is already installed
        $extensions = az extension list --query "[?name=='resource-graph'].name" -o tsv 2>$null
        
        if ($extensions -and $extensions.Trim() -eq 'resource-graph') {
            Write-Verbose "Azure CLI 'resource-graph' extension is already installed."
            return $true
        }
        
        # Extension not found, install it
        Write-Host "Installing Azure CLI 'resource-graph' extension..." -ForegroundColor Yellow
        $installResult = az extension add --name resource-graph --yes 2>&1
        
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to install 'resource-graph' extension: $installResult"
            return $false
        }
        
        Write-Host "Azure CLI 'resource-graph' extension installed successfully." -ForegroundColor Green
        return $true
    }
    catch {
        Write-Warning "Error checking/installing resource-graph extension: $_"
        return $false
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to console and optionally to file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Message = "",

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Verbose', 'Header')]
        [string]$Level = 'Info',

        [Parameter(Mandatory = $false)]
        [string]$ForegroundColor
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Determine color based on level if not specified
    if (-not $ForegroundColor) {
        $ForegroundColor = switch ($Level) {
            'Info'    { 'White' }
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
            'Success' { 'Green' }
            'Verbose' { 'Gray' }
            'Header'  { 'Cyan' }
            default   { 'White' }
        }
    }

    # Write to console
    Write-Host $logEntry -ForegroundColor $ForegroundColor

    # Write to log file if path is set
    if ($script:LogFilePath) {
        try {
            Add-Content -Path $script:LogFilePath -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # Log file write failure is non-critical - continue silently to not disrupt main operation
            Write-Verbose "Failed to write to log file: $($_.Exception.Message)"
        }
    }

    # Write errors to separate error log
    if ($Level -eq 'Error' -and $script:ErrorLogPath) {
        try {
            Add-Content -Path $script:ErrorLogPath -Value $logEntry -ErrorAction SilentlyContinue
        }
        catch {
            # Error log write failure is non-critical - continue silently
            Write-Verbose "Failed to write to error log file: $($_.Exception.Message)"
        }
    }
}

function Get-HealthCheckFailureSummary {
    <#
    .SYNOPSIS
        Extracts health check failure reasons from an update summary object.
    .DESCRIPTION
        Analyzes the healthCheckResult property from an Azure Local update summary
        to extract critical and warning health check failures. Returns a summary
        string suitable for CSV logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object]$UpdateSummary
    )

    if (-not $UpdateSummary -or -not $UpdateSummary.properties.healthCheckResult) {
        return ""
    }

    $failures = @()
    $healthChecks = $UpdateSummary.properties.healthCheckResult

    foreach ($check in $healthChecks) {
        if ($check.status -eq "Failed") {
            $severity = if ($check.severity) { $check.severity } else { "Unknown" }
            # Only include Critical and Warning severities (skip Informational)
            if ($severity -notin @("Critical", "Warning")) {
                continue
            }
            $displayName = if ($check.displayName) { $check.displayName } elseif ($check.name) { ($check.name -split '/')[0] } else { "Unknown Check" }
            $failures += "[$severity] $displayName"
        }
    }

    if ($failures.Count -gt 0) {
        # Limit to top 5 failures to keep CSV readable
        $topFailures = $failures | Select-Object -First 5
        $summary = $topFailures -join "; "
        if ($failures.Count -gt 5) {
            $summary += " (+$($failures.Count - 5) more)"
        }
        return $summary
    }

    return ""
}

function Get-LastUpdateRunErrorSummary {
    <#
    .SYNOPSIS
        Gets the error details from the most recent failed update run for a cluster.
    .DESCRIPTION
        Queries the Azure REST API for the most recent update run for a cluster
        and extracts the error step name and message if the update failed.
        
        Note: Update runs are nested under specific updates, so we need to:
        1. List all updates for the cluster
        2. Get update runs for each update
        3. Find the most recent failed run across all updates
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2025-10-01"
    )

    try {
        # First, get all updates for this cluster
        $updatesUri = "https://management.azure.com$ClusterResourceId/updates?api-version=$ApiVersion"
        $updatesResult = az rest --method GET --uri $updatesUri 2>$null | ConvertFrom-Json
        
        if ($LASTEXITCODE -ne 0 -or -not $updatesResult.value) {
            return @{ ErrorStep = ""; ErrorMessage = "" }
        }

        # Collect all failed runs from all updates
        $allFailedRuns = @()
        
        foreach ($update in $updatesResult.value) {
            $updateName = $update.name
            $runsUri = "https://management.azure.com$ClusterResourceId/updates/$updateName/updateRuns?api-version=$ApiVersion"
            $runsResult = az rest --method GET --uri $runsUri 2>$null | ConvertFrom-Json
            
            if ($LASTEXITCODE -eq 0 -and $runsResult.value) {
                $failedRuns = $runsResult.value | Where-Object { $_.properties.state -eq "Failed" }
                if ($failedRuns) {
                    $allFailedRuns += $failedRuns
                }
            }
        }

        if ($allFailedRuns.Count -eq 0) {
            return @{ ErrorStep = ""; ErrorMessage = "" }
        }

        # Find the most recent failed update run across all updates
        $latestFailed = $allFailedRuns | Sort-Object { $_.properties.timeStarted } -Descending | Select-Object -First 1
        $progress = $latestFailed.properties.progress

        if (-not $progress -or -not $progress.steps) {
            return @{ ErrorStep = ""; ErrorMessage = "" }
        }

        # Recursively search for the deepest error step with an error message
        function Find-DeepestError {
            param($steps)
            foreach ($step in $steps) {
                if ($step.status -eq "Error" -or $step.status -eq "Failed") {
                    if ($step.errorMessage) {
                        return @{ Name = $step.name; Message = $step.errorMessage }
                    }
                }
                if ($step.steps) {
                    $nestedResult = Find-DeepestError -steps $step.steps
                    if ($nestedResult.Message) {
                        return $nestedResult
                    }
                }
            }
            return @{ Name = ""; Message = "" }
        }

        $deepestError = Find-DeepestError -steps $progress.steps
        $errorStep = $deepestError.Name
        $errorMessage = $deepestError.Message

        # Clean up error message for CSV (remove newlines and extra spaces)
        if ($errorMessage) {
            $errorMessage = $errorMessage -replace '\r?\n', ' ' -replace '\s+', ' '
            # Truncate if too long for CSV readability
            if ($errorMessage.Length -gt 500) {
                $errorMessage = $errorMessage.Substring(0, 500) + "..."
            }
        }

        return @{ ErrorStep = $errorStep; ErrorMessage = $errorMessage }
    }
    catch {
        Write-Verbose "Error getting update run details: $_"
        return @{ ErrorStep = ""; ErrorMessage = "" }
    }
}

function Export-ResultsToJUnitXml {
    <#
    .SYNOPSIS
        Exports update results to JUnit XML format for CI/CD pipeline integration.
    .DESCRIPTION
        Converts update operation results to JUnit XML format, which is the de facto
        standard for test results in CI/CD tools. Each cluster update is represented
        as a test case, with success/failure/skipped mapped to JUnit test outcomes.
        
        Supported CI/CD tools:
        - Azure DevOps (Publish Test Results task)
        - GitHub Actions (dorny/test-reporter or similar)
        - Jenkins (JUnit plugin)
        - GitLab CI (native support)
        - TeamCity (built-in)
    .PARAMETER Results
        Array of result objects from update operations.
    .PARAMETER OutputPath
        Path to write the JUnit XML file.
    .PARAMETER TestSuiteName
        Name of the test suite (default: "AzureLocalClusterUpdates").
    .PARAMETER OperationType
        Type of operation being reported (e.g., "Update", "Watch", "TagUpdate").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Results,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [string]$TestSuiteName = "AzureLocalClusterUpdates",

        [Parameter(Mandatory = $false)]
        [string]$OperationType = "Update"
    )

    # Calculate summary statistics
    $totalTests = $Results.Count
    $failures = @($Results | Where-Object { $_.Status -in @("Failed", "Error") }).Count
    $skipped = @($Results | Where-Object { $_.Status -eq "Skipped" }).Count
    $errors = @($Results | Where-Object { $_.Status -eq "NotFound" }).Count
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    
    # Calculate total time if Duration is available
    $totalTime = 0
    foreach ($result in $Results) {
        if ($result.Duration -and $result.Duration -is [TimeSpan]) {
            $totalTime += $result.Duration.TotalSeconds
        }
        elseif ($result.Duration -and $result.Duration -match '^\d+') {
            # Try to parse duration string
            $totalTime += [double]($result.Duration -replace '[^\d.]', '')
        }
    }

    # Helper function to XML-escape strings
    function ConvertTo-XmlSafeString {
        param([string]$Text)
        if (-not $Text) { return "" }
        return $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&apos;'
    }

    # Build XML content
    $xmlBuilder = [System.Text.StringBuilder]::new()
    [void]$xmlBuilder.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$xmlBuilder.AppendLine("<testsuites>")
    [void]$xmlBuilder.AppendLine("  <testsuite name=`"$(ConvertTo-XmlSafeString $TestSuiteName)`" tests=`"$totalTests`" failures=`"$failures`" errors=`"$errors`" skipped=`"$skipped`" time=`"$totalTime`" timestamp=`"$timestamp`">")

    foreach ($result in $Results) {
        $clusterName = ConvertTo-XmlSafeString ($result.ClusterName)
        $testName = "$OperationType-$clusterName"
        
        # Calculate test time
        $testTime = 0
        if ($result.Duration -and $result.Duration -is [TimeSpan]) {
            $testTime = $result.Duration.TotalSeconds
        }
        elseif ($result.Duration -and $result.Duration -match '^\d+') {
            $testTime = [double]($result.Duration -replace '[^\d.]', '')
        }

        [void]$xmlBuilder.AppendLine("    <testcase name=`"$(ConvertTo-XmlSafeString $testName)`" classname=`"$TestSuiteName.$OperationType`" time=`"$testTime`">")

        switch ($result.Status) {
            { $_ -in @("Failed", "Error") } {
                $message = ConvertTo-XmlSafeString ($result.Message)
                $errorType = if ($result.Status -eq "Error") { "Error" } else { "AssertionError" }
                [void]$xmlBuilder.AppendLine("      <failure message=`"$message`" type=`"$errorType`">")
                [void]$xmlBuilder.AppendLine("Cluster: $clusterName")
                [void]$xmlBuilder.AppendLine("Status: $($result.Status)")
                [void]$xmlBuilder.AppendLine("Message: $message")
                if ($result.UpdateName) {
                    [void]$xmlBuilder.AppendLine("Update: $(ConvertTo-XmlSafeString $result.UpdateName)")
                }
                if ($result.CurrentState) {
                    [void]$xmlBuilder.AppendLine("Current State: $(ConvertTo-XmlSafeString $result.CurrentState)")
                }
                if ($result.Progress) {
                    [void]$xmlBuilder.AppendLine("Progress: $($result.Progress)")
                }
                [void]$xmlBuilder.AppendLine("      </failure>")
            }
            "NotFound" {
                $message = ConvertTo-XmlSafeString ($result.Message)
                [void]$xmlBuilder.AppendLine("      <error message=`"$message`" type=`"ResourceNotFound`">")
                [void]$xmlBuilder.AppendLine("Cluster: $clusterName")
                [void]$xmlBuilder.AppendLine("Message: $message")
                [void]$xmlBuilder.AppendLine("      </error>")
            }
            "Skipped" {
                $message = ConvertTo-XmlSafeString ($result.Message)
                [void]$xmlBuilder.AppendLine("      <skipped message=`"$message`" />")
            }
            default {
                # Success case - add system-out with details
                [void]$xmlBuilder.AppendLine("      <system-out>")
                [void]$xmlBuilder.AppendLine("Cluster: $clusterName")
                [void]$xmlBuilder.AppendLine("Status: $($result.Status)")
                if ($result.Message) {
                    [void]$xmlBuilder.AppendLine("Message: $(ConvertTo-XmlSafeString $result.Message)")
                }
                if ($result.UpdateName) {
                    [void]$xmlBuilder.AppendLine("Update: $(ConvertTo-XmlSafeString $result.UpdateName)")
                }
                if ($result.CurrentState) {
                    [void]$xmlBuilder.AppendLine("Final State: $(ConvertTo-XmlSafeString $result.CurrentState)")
                }
                if ($result.Progress) {
                    [void]$xmlBuilder.AppendLine("Progress: $($result.Progress)")
                }
                [void]$xmlBuilder.AppendLine("      </system-out>")
            }
        }

        [void]$xmlBuilder.AppendLine("    </testcase>")
    }

    [void]$xmlBuilder.AppendLine("  </testsuite>")
    [void]$xmlBuilder.AppendLine("</testsuites>")

    # Write to file
    $xmlBuilder.ToString() | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
}

function Write-UpdateCsvLog {
    <#
    .SYNOPSIS
        Writes a CSV entry to the Update_Skipped or Update_Started log file.
    .DESCRIPTION
        Writes detailed information about skipped or started updates to CSV files.
        For skipped clusters, includes additional diagnostic information such as
        health check failures and update run error details.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Skipped', 'Started')]
        [string]$LogType,

        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroup = "",

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId = "",

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$UpdateState = "",

        [Parameter(Mandatory = $false)]
        [string]$HealthState = "",

        [Parameter(Mandatory = $false)]
        [string]$HealthCheckFailures = "",

        [Parameter(Mandatory = $false)]
        [string]$LastUpdateErrorStep = "",

        [Parameter(Mandatory = $false)]
        [string]$LastUpdateErrorMessage = ""
    )

    # Escape quotes in values for CSV
    $escapedClusterName = $ClusterName -replace '"', '""'
    $escapedResourceGroup = $ResourceGroup -replace '"', '""'
    $escapedSubscriptionId = $SubscriptionId -replace '"', '""'
    $escapedMessage = $Message -replace '"', '""'
    $escapedUpdateState = $UpdateState -replace '"', '""'
    $escapedHealthState = $HealthState -replace '"', '""'
    $escapedHealthCheckFailures = $HealthCheckFailures -replace '"', '""'
    $escapedLastUpdateErrorStep = $LastUpdateErrorStep -replace '"', '""'
    $escapedLastUpdateErrorMessage = $LastUpdateErrorMessage -replace '"', '""'

    if ($LogType -eq 'Skipped') {
        # Extended format for skipped clusters with diagnostic columns
        $csvLine = "`"$escapedClusterName`",`"$escapedResourceGroup`",`"$escapedSubscriptionId`",`"$escapedMessage`",`"$escapedUpdateState`",`"$escapedHealthState`",`"$escapedHealthCheckFailures`",`"$escapedLastUpdateErrorStep`",`"$escapedLastUpdateErrorMessage`""
        $logPath = $script:UpdateSkippedLogPath
    }
    else {
        # Simple format for started clusters
        $csvLine = "`"$escapedClusterName`",`"$escapedResourceGroup`",`"$escapedSubscriptionId`",`"$escapedMessage`""
        $logPath = $script:UpdateStartedLogPath
    }
    
    if ($logPath) {
        try {
            Add-Content -Path $logPath -Value $csvLine -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch {
            # CSV log write failure is non-critical - continue silently
            Write-Verbose "Failed to write to CSV log: $($_.Exception.Message)"
        }
    }
}

function Start-AzureLocalClusterUpdate {
    <#
    .SYNOPSIS
        Starts updates on one or more Azure Local clusters.
    .DESCRIPTION
        Initiates the update process on Azure Local (Azure Stack HCI) clusters. Supports multiple
        methods for specifying clusters: by name, by Resource ID, or by UpdateRing tag. The function
        validates cluster readiness, checks for available updates, and starts the update process.
        Includes comprehensive logging, CSV export of results, and support for CI/CD automation.
    .PARAMETER ClusterNames
        Array of cluster names to update. Use this OR -ClusterResourceIds OR -ScopeByUpdateRingTag.
    .PARAMETER ClusterResourceIds
        Array of full Azure Resource IDs for clusters. Use when clusters are in different resource groups.
    .PARAMETER ScopeByUpdateRingTag
        Switch to find clusters by their 'UpdateRing' tag value via Azure Resource Graph.
    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.
    .PARAMETER ResourceGroupName
        Resource group containing the clusters (only used with -ClusterNames).
    .PARAMETER SubscriptionId
        Azure subscription ID (defaults to current subscription).
    .PARAMETER UpdateName
        Specific update name to apply. If not specified, applies the latest ready update.
    .PARAMETER ApiVersion
        Azure REST API version to use. Default: "2025-10-01".
    .PARAMETER Force
        Skip confirmation prompts.
    .PARAMETER LogFolderPath
        Folder path for log files. Default: C:\ProgramData\AzStackHci.ManageUpdates\
    .PARAMETER EnableTranscript
        Enable PowerShell transcript recording.
    .PARAMETER ExportResultsPath
        Export results to JSON (.json), CSV (.csv), or JUnit XML (.xml) file.
    .OUTPUTS
        PSCustomObject[] - Array of result objects with cluster name, status, and message.
    .EXAMPLE
        Start-AzureLocalClusterUpdate -ClusterNames "MyCluster01" -ResourceGroupName "MyRG" -Force
        Starts update on a single cluster without confirmation prompt.
    .EXAMPLE
        Start-AzureLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -Force
        Starts updates on all clusters tagged with UpdateRing=Wave1.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByName')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string[]]$ClusterNames,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [switch]$ScopeByUpdateRingTag,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$LogFolderPath,

        [Parameter(Mandatory = $false)]
        [switch]$EnableTranscript,

        [Parameter(Mandatory = $false)]
        [string]$ExportResultsPath
    )

    begin {
        # Initialize logging
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        
        # Determine log directory: parameter > default location
        $defaultLogDir = Join-Path -Path $env:ProgramData -ChildPath "AzStackHci.ManageUpdates"
        $logDir = if ($LogFolderPath) { $LogFolderPath } else { $defaultLogDir }
        
        # Ensure log directory exists
        if (-not (Test-Path $logDir)) {
            try {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }
            catch {
                # Fall back to current directory if we can't create the log folder
                Write-Warning "Unable to create log directory '$logDir'. Using current directory instead."
                $logDir = Get-Location
            }
        }
        
        # Set log file path
        $script:LogFilePath = Join-Path -Path $logDir -ChildPath "AzureLocalUpdate_$timestamp.log"
        
        # Create error log path (same location, different suffix)
        $logName = [System.IO.Path]::GetFileNameWithoutExtension($script:LogFilePath)
        $script:ErrorLogPath = Join-Path -Path $logDir -ChildPath "${logName}_errors.log"
        
        # Create CSV summary log paths
        $script:UpdateSkippedLogPath = Join-Path -Path $logDir -ChildPath "${logName}_Update_Skipped.csv"
        $script:UpdateStartedLogPath = Join-Path -Path $logDir -ChildPath "${logName}_Update_Started.csv"

        # Ensure log directory exists
        if ($logDir -and -not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }

        # Start transcript if enabled
        $transcriptPath = $null
        if ($EnableTranscript) {
            $transcriptPath = Join-Path -Path $logDir -ChildPath "${logName}_transcript.log"
            try {
                Start-Transcript -Path $transcriptPath -Force | Out-Null
                Write-Log -Message "Transcript started: $transcriptPath" -Level Info
            }
            catch {
                Write-Log -Message "Failed to start transcript: $_" -Level Warning
            }
        }

        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Cluster Update - Started" -Level Header
        Write-Log -Message "Module Version: $($script:ModuleVersion)" -Level Header
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Log file: $($script:LogFilePath)" -Level Info
        Write-Log -Message "Error log: $($script:ErrorLogPath)" -Level Info
        Write-Log -Message "Update Skipped CSV: $($script:UpdateSkippedLogPath)" -Level Info
        Write-Log -Message "Update Started CSV: $($script:UpdateStartedLogPath)" -Level Info
        
        # Initialize CSV files with headers (extended headers for skipped to include diagnostic info)
        $csvHeadersSkipped = '"ClusterName","ResourceGroup","SubscriptionId","Message","UpdateState","HealthState","HealthCheckFailures","LastUpdateErrorStep","LastUpdateErrorMessage"'
        $csvHeadersStarted = '"ClusterName","ResourceGroup","SubscriptionId","Message"'
        $csvHeadersSkipped | Out-File -FilePath $script:UpdateSkippedLogPath -Encoding UTF8 -Force
        $csvHeadersStarted | Out-File -FilePath $script:UpdateStartedLogPath -Encoding UTF8 -Force
        
        # Build list of clusters to process
        $clustersToProcess = @()
        if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
            Write-Log -Message "Querying Azure Resource Graph for clusters with tag 'UpdateRing' = '$UpdateRingValue'..." -Level Info
            
            # Ensure resource-graph extension is installed (for pipeline/automation scenarios)
            if (-not (Install-AzGraphExtension)) {
                throw "Failed to ensure Azure CLI 'resource-graph' extension is available. Please install manually: az extension add --name resource-graph"
            }
            
            # Build Azure Resource Graph query to find clusters by tag - use single line to avoid escaping issues with az CLI
            $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where tags['UpdateRing'] =~ '$UpdateRingValue' | project id, name, resourceGroup, subscriptionId, tags"
            
            Write-Verbose "ARG Query: $argQuery"
            
            try {
                # Run Azure Resource Graph query across all accessible subscriptions
                $argResult = az graph query -q $argQuery --first 1000 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $errorMessage = $argResult | Out-String
                    Write-Log -Message "Azure Resource Graph query failed: $errorMessage" -Level Error
                    throw "Failed to query Azure Resource Graph. Ensure you have the 'az graph' extension installed (az extension add --name resource-graph)"
                }
                
                $clusters = $argResult | ConvertFrom-Json
                
                if (-not $clusters.data -or $clusters.data.Count -eq 0) {
                    Write-Log -Message "No clusters found with tag 'UpdateRing' = '$UpdateRingValue'" -Level Warning
                    throw "No Azure Local clusters found with tag 'UpdateRing' = '$UpdateRingValue'. Please verify the tag value."
                }
                
                Write-Log -Message "Found $($clusters.data.Count) cluster(s) matching tag criteria:" -Level Success
                foreach ($cluster in $clusters.data) {
                    Write-Log -Message "  - $($cluster.name) (RG: $($cluster.resourceGroup), Sub: $($cluster.subscriptionId))" -Level Info
                    $clustersToProcess += @{ 
                        ResourceId = $cluster.id
                        Name = $cluster.name 
                    }
                }
            }
            catch {
                if ($_.Exception.Message -match "No Azure Local clusters found") {
                    throw
                }
                Write-Log -Message "Error querying Azure Resource Graph: $_" -Level Error
                throw "Failed to query Azure Resource Graph: $_"
            }
        }
        elseif ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
            Write-Log -Message "Validating Cluster Resource IDs: $($ClusterResourceIds.Count)" -Level Info
            foreach ($resourceId in $ClusterResourceIds) {
                Write-Log -Message "  Validating: $resourceId" -Level Info
                
                # Validate ResourceId format
                $resourceIdPattern = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.AzureStackHCI/clusters/[^/]+$'
                if ($resourceId -notmatch $resourceIdPattern) {
                    Write-Log -Message "    Invalid Resource ID format. Expected: /subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}" -Level Error
                    throw "Invalid Resource ID format: $resourceId"
                }
                
                # Validate resource exists and user has access
                $validateUri = "https://management.azure.com$resourceId`?api-version=$ApiVersion"
                Write-Verbose "Validating resource at: $validateUri"
                try {
                    $validateResult = az rest --method GET --uri $validateUri 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $errorMessage = $validateResult | Out-String
                        if ($errorMessage -match "ResourceNotFound|ResourceGroupNotFound") {
                            Write-Log -Message "    Resource not found: $resourceId" -Level Error
                            throw "Resource not found: $resourceId. Please verify the Resource ID is correct."
                        }
                        elseif ($errorMessage -match "AuthorizationFailed|Forbidden") {
                            Write-Log -Message "    Access denied: You do not have permission to access $resourceId" -Level Error
                            throw "Access denied: You do not have permission to access $resourceId. Please verify you have the required RBAC permissions."
                        }
                        else {
                            Write-Log -Message "    Failed to validate resource: $errorMessage" -Level Error
                            throw "Failed to validate resource: $resourceId. Error: $errorMessage"
                        }
                    }
                    Write-Log -Message "    Validated successfully" -Level Success
                }
                catch {
                    if ($_.Exception.Message -match "Resource not found|Access denied|Failed to validate") {
                        throw
                    }
                    Write-Log -Message "    Failed to validate resource: $_" -Level Error
                    throw "Failed to validate resource: $resourceId. Error: $_"
                }
                
                $clustersToProcess += @{ ResourceId = $resourceId; Name = ($resourceId -split '/')[-1] }
            }
            Write-Log -Message "All Resource IDs validated successfully" -Level Success
        }
        else {
            Write-Log -Message "Clusters to process: $($ClusterNames -join ', ')" -Level Info
            foreach ($name in $ClusterNames) {
                $clustersToProcess += @{ ResourceId = $null; Name = $name }
            }
        }

        # Verify Azure CLI is installed and logged in
        try {
            $null = az account show 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI is not logged in. Please run 'az login' first."
            }
            Write-Log -Message "Azure CLI authentication verified" -Level Success
        }
        catch {
            Write-Log -Message "Azure CLI is not installed or not logged in. Please install Azure CLI and run 'az login'." -Level Error
            throw
        }

        # Get subscription ID if not provided (only needed for ByName parameter set)
        if ($PSCmdlet.ParameterSetName -eq 'ByName' -and -not $SubscriptionId) {
            $SubscriptionId = (az account show --query id -o tsv)
            Write-Log -Message "Using current subscription: $SubscriptionId" -Level Info
        }

        # Results collection
        $results = @()
    }

    process {
        foreach ($cluster in $clustersToProcess) {
            $clusterName = $cluster.Name
            $clusterResourceId = $cluster.ResourceId

            Write-Log -Message "" -Level Info
            Write-Log -Message "========================================" -Level Header
            Write-Log -Message "Processing cluster: $clusterName" -Level Header
            Write-Log -Message "========================================" -Level Header

            $clusterStartTime = Get-Date

            try {
                # Step 1: Get cluster resource ID (or use provided ResourceId)
                Write-Log -Message "Step 1: Looking up cluster resource..." -Level Info
                
                if ($clusterResourceId) {
                    # ResourceId was provided directly - fetch cluster info using the ResourceId
                    $uri = "https://management.azure.com$clusterResourceId`?api-version=$ApiVersion"
                    Write-Verbose "Getting cluster info from: $uri"
                    $clusterInfo = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
                    if ($LASTEXITCODE -ne 0) {
                        $clusterInfo = $null
                    }
                }
                else {
                    # Look up by name
                    $clusterInfo = Get-AzureLocalClusterInfo -ClusterName $clusterName `
                        -ResourceGroupName $ResourceGroupName `
                        -SubscriptionId $SubscriptionId `
                        -ApiVersion $ApiVersion
                }

                if (-not $clusterInfo) {
                    Write-Log -Message "Cluster '$clusterName' not found." -Level Warning
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotFound"
                        Message       = "Cluster not found"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                Write-Log -Message "Found cluster: $($clusterInfo.id)" -Level Success
                Write-Log -Message "Cluster Status: $($clusterInfo.properties.status)" -Level Info

                # Step 2: Get update summaries to check if updates are available
                Write-Log -Message "Step 2: Retrieving update summary..." -Level Info
                $updateSummary = Get-AzureLocalUpdateSummary -ClusterResourceId $clusterInfo.id `
                    -ApiVersion $ApiVersion

                if (-not $updateSummary) {
                    Write-Log -Message "Unable to retrieve update summary for cluster '$clusterName'." -Level Warning
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "Error"
                        Message       = "Unable to retrieve update summary"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                Write-Log -Message "Update State: $($updateSummary.properties.state)" -Level Info

                # Step 3: Check if cluster is ready for updates
                Write-Log -Message "Step 3: Validating cluster state for updates..." -Level Info
                $validStates = @("UpdateAvailable", "Ready")
                if ($updateSummary.properties.state -notin $validStates) {
                    Write-Log -Message "Cluster '$clusterName' is not in a valid state for updates. Current state: $($updateSummary.properties.state)" -Level Warning
                    
                    # Parse Resource Group and Subscription ID from cluster resource ID
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                    
                    # Get health check failure details
                    $healthCheckFailures = Get-HealthCheckFailureSummary -UpdateSummary $updateSummary
                    $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
                    
                    # Get last update run error details if the cluster is in a failed/needs attention state
                    $lastErrorDetails = @{ ErrorStep = ""; ErrorMessage = "" }
                    if ($updateSummary.properties.state -in @("NeedsAttention", "UpdateFailed", "PreparationFailed")) {
                        Write-Log -Message "Retrieving last update run error details..." -Level Verbose
                        $lastErrorDetails = Get-LastUpdateRunErrorSummary -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
                    }
                    
                    Write-UpdateCsvLog -LogType Skipped `
                        -ClusterName $clusterName `
                        -ResourceGroup $clusterRgName `
                        -SubscriptionId $clusterSubId `
                        -Message "Update Not started as Cluster NOT in Ready state (Current state: $($updateSummary.properties.state))" `
                        -UpdateState $updateSummary.properties.state `
                        -HealthState $healthState `
                        -HealthCheckFailures $healthCheckFailures `
                        -LastUpdateErrorStep $lastErrorDetails.ErrorStep `
                        -LastUpdateErrorMessage $lastErrorDetails.ErrorMessage
                    
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NotReady"
                        Message       = "Cluster state: $($updateSummary.properties.state)"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                # Step 4: List available updates
                Write-Log -Message "Step 4: Listing available updates..." -Level Info
                $availableUpdates = Get-AzureLocalAvailableUpdates -ClusterResourceId $clusterInfo.id `
                    -ApiVersion $ApiVersion

                if (-not $availableUpdates -or $availableUpdates.Count -eq 0) {
                    Write-Log -Message "No updates available for cluster '$clusterName'." -Level Warning
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NoUpdatesAvailable"
                        Message       = "No updates available"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                # Filter updates that are in "Ready" state
                $readyUpdates = $availableUpdates | Where-Object { $_.properties.state -eq "Ready" }
                
                if (-not $readyUpdates -or $readyUpdates.Count -eq 0) {
                    Write-Log -Message "No updates in 'Ready' state for cluster '$clusterName'." -Level Warning
                    Write-Log -Message "Available updates and their states:" -Level Info
                    foreach ($update in $availableUpdates) {
                        Write-Log -Message "  - $($update.name): $($update.properties.state)" -Level Verbose
                    }
                    
                    # Parse Resource Group and Subscription ID from cluster resource ID
                    $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                    $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                    $updateStatesList = ($availableUpdates | ForEach-Object { "$($_.name): $($_.properties.state)" }) -join '; '
                    
                    # Get health check failure details
                    $healthCheckFailures = Get-HealthCheckFailureSummary -UpdateSummary $updateSummary
                    $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
                    
                    # Get last update run error details - might have failed updates
                    $lastErrorDetails = Get-LastUpdateRunErrorSummary -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
                    
                    Write-UpdateCsvLog -LogType Skipped `
                        -ClusterName $clusterName `
                        -ResourceGroup $clusterRgName `
                        -SubscriptionId $clusterSubId `
                        -Message "Update Not started as no updates in Ready state. Available: $updateStatesList" `
                        -UpdateState $updateSummary.properties.state `
                        -HealthState $healthState `
                        -HealthCheckFailures $healthCheckFailures `
                        -LastUpdateErrorStep $lastErrorDetails.ErrorStep `
                        -LastUpdateErrorMessage $lastErrorDetails.ErrorMessage
                    
                    $results += [PSCustomObject]@{
                        ClusterName   = $clusterName
                        Status        = "NoReadyUpdates"
                        Message       = "No updates in Ready state"
                        UpdateName    = $null
                        StartTime     = $clusterStartTime
                        EndTime       = Get-Date
                        Duration      = $null
                    }
                    continue
                }

                Write-Log -Message "Available updates in 'Ready' state:" -Level Success
                foreach ($update in $readyUpdates) {
                    Write-Log -Message "  - $($update.name) (Version: $($update.properties.version), State: $($update.properties.state))" -Level Info
                }

                # Step 5: Select update to apply
                Write-Log -Message "Step 5: Selecting update to apply..." -Level Info
                $selectedUpdate = $null
                if ($UpdateName) {
                    $selectedUpdate = $readyUpdates | Where-Object { $_.name -eq $UpdateName }
                    if (-not $selectedUpdate) {
                        Write-Log -Message "Specified update '$UpdateName' not found or not in Ready state for cluster '$clusterName'." -Level Warning
                        $results += [PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "UpdateNotFound"
                            Message       = "Specified update '$UpdateName' not found or not ready"
                            UpdateName    = $UpdateName
                            StartTime     = $clusterStartTime
                            EndTime       = Get-Date
                            Duration      = $null
                        }
                        continue
                    }
                }
                else {
                    # Select the first ready update (typically the latest)
                    $selectedUpdate = $readyUpdates | Select-Object -First 1
                    Write-Log -Message "Auto-selecting update: $($selectedUpdate.name)" -Level Info
                }

                # Step 6: Apply the update
                Write-Log -Message "Step 6: Applying update..." -Level Info
                if ($PSCmdlet.ShouldProcess("$clusterName", "Apply update '$($selectedUpdate.name)'")) {
                    if (-not $Force) {
                        $confirmation = Read-Host "  Do you want to start update '$($selectedUpdate.name)' on cluster '$clusterName'? (Y/N)"
                        if ($confirmation -notmatch '^[Yy]') {
                            Write-Log -Message "Update skipped by user." -Level Warning
                            
                            # Parse Resource Group and Subscription ID from cluster resource ID
                            $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                            $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                            $healthState = if ($updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
                            
                            Write-UpdateCsvLog -LogType Skipped `
                                -ClusterName $clusterName `
                                -ResourceGroup $clusterRgName `
                                -SubscriptionId $clusterSubId `
                                -Message "Update skipped by user" `
                                -UpdateState $updateSummary.properties.state `
                                -HealthState $healthState
                            
                            $results += [PSCustomObject]@{
                                ClusterName   = $clusterName
                                Status        = "Skipped"
                                Message       = "Update skipped by user"
                                UpdateName    = $selectedUpdate.name
                                StartTime     = $clusterStartTime
                                EndTime       = Get-Date
                                Duration      = $null
                            }
                            continue
                        }
                    }

                    Write-Log -Message "Initiating update '$($selectedUpdate.name)' on cluster '$clusterName'..." -Level Info
                    $applyResult = Invoke-AzureLocalUpdateApply -ClusterResourceId $clusterInfo.id `
                        -UpdateName $selectedUpdate.name `
                        -ApiVersion $ApiVersion

                    $endTime = Get-Date
                    $duration = $endTime - $clusterStartTime

                    if ($applyResult) {
                        Write-Log -Message "Update started successfully!" -Level Success
                        Write-Log -Message "Monitor progress using: Get-AzureLocalUpdateRuns -ClusterName '$clusterName'" -Level Info
                        
                        # Parse Resource Group and Subscription ID from cluster resource ID
                        $clusterRgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
                        $clusterSubId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
                        Write-UpdateCsvLog -LogType Started -ClusterName $clusterName -ResourceGroup $clusterRgName -SubscriptionId $clusterSubId -Message "Update Started: $($selectedUpdate.name)"
                        
                        $results += [PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "UpdateStarted"
                            Message       = "Update initiated successfully"
                            UpdateName    = $selectedUpdate.name
                            StartTime     = $clusterStartTime
                            EndTime       = $endTime
                            Duration      = $duration.ToString("hh\:mm\:ss")
                        }
                    }
                    else {
                        Write-Log -Message "Failed to start update on cluster '$clusterName'." -Level Error
                        $results += [PSCustomObject]@{
                            ClusterName   = $clusterName
                            Status        = "Failed"
                            Message       = "Failed to start update"
                            UpdateName    = $selectedUpdate.name
                            StartTime     = $clusterStartTime
                            EndTime       = $endTime
                            Duration      = $duration.ToString("hh\:mm\:ss")
                        }
                    }
                }
            }
            catch {
                $endTime = Get-Date
                $duration = $endTime - $clusterStartTime
                Write-Log -Message "Error processing cluster '$clusterName': $($_.Exception.Message)" -Level Error
                Write-Log -Message "Stack trace: $($_.ScriptStackTrace)" -Level Error
                $results += [PSCustomObject]@{
                    ClusterName   = $clusterName
                    Status        = "Error"
                    Message       = $_.Exception.Message
                    UpdateName    = $null
                    StartTime     = $clusterStartTime
                    EndTime       = $endTime
                    Duration      = $duration.ToString("hh\:mm\:ss")
                }
            }
        }
    }

    end {
        Write-Log -Message "" -Level Info
        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Summary" -Level Header
        Write-Log -Message "========================================" -Level Header
        
        # Display summary statistics
        $totalClusters = $results.Count
        $succeeded = ($results | Where-Object { $_.Status -eq "UpdateStarted" }).Count
        $failed = ($results | Where-Object { $_.Status -in @("Failed", "Error") }).Count
        $skipped = ($results | Where-Object { $_.Status -in @("Skipped", "NotReady", "NoUpdatesAvailable", "NoReadyUpdates", "NotFound", "UpdateNotFound") }).Count

        Write-Log -Message "Total clusters processed: $totalClusters" -Level Info
        Write-Log -Message "Updates started: $succeeded" -Level Success
        if ($failed -gt 0) {
            Write-Log -Message "Failed: $failed" -Level Error
        } else {
            Write-Log -Message "Failed: $failed" -Level Info
        }
        if ($skipped -gt 0) {
            Write-Log -Message "Skipped/Not Ready: $skipped" -Level Warning
        } else {
            Write-Log -Message "Skipped/Not Ready: $skipped" -Level Info
        }

        # Display results table
        Write-Log -Message "" -Level Info
        Write-Log -Message "Detailed Results:" -Level Info
        $results | Format-Table ClusterName, Status, UpdateName, Duration, Message -AutoSize | Out-String -Stream | ForEach-Object { 
            if ($_ -ne "") { Write-Log -Message $_ -Level Info }
        }

        # Export results if path specified
        if ($ExportResultsPath) {
            try {
                $exportDir = Split-Path -Path $ExportResultsPath -Parent
                if ($exportDir -and -not (Test-Path $exportDir)) {
                    New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
                }

                $extension = [System.IO.Path]::GetExtension($ExportResultsPath).ToLower()
                
                switch ($extension) {
                    '.json' {
                        $exportData = @{
                            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            TotalClusters = $totalClusters
                            Succeeded     = $succeeded
                            Failed        = $failed
                            Skipped       = $skipped
                            Results       = $results
                        }
                        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ExportResultsPath -Encoding UTF8
                        Write-Log -Message "Results exported to JSON: $ExportResultsPath" -Level Success
                    }
                    '.csv' {
                        $results | Export-Csv -Path $ExportResultsPath -NoTypeInformation -Encoding UTF8
                        Write-Log -Message "Results exported to CSV: $ExportResultsPath" -Level Success
                    }
                    '.xml' {
                        # Export to JUnit XML format for CI/CD integration
                        Export-ResultsToJUnitXml -Results $results -OutputPath $ExportResultsPath `
                            -TestSuiteName "AzureLocalClusterUpdates" -OperationType "StartUpdate"
                        Write-Log -Message "Results exported to JUnit XML (CI/CD compatible): $ExportResultsPath" -Level Success
                    }
                    default {
                        # Default to JSON
                        $jsonPath = $ExportResultsPath + ".json"
                        $exportData = @{
                            Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            TotalClusters = $totalClusters
                            Succeeded     = $succeeded
                            Failed        = $failed
                            Skipped       = $skipped
                            Results       = $results
                        }
                        $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
                        Write-Log -Message "Results exported to JSON: $jsonPath" -Level Success
                    }
                }
            }
            catch {
                Write-Log -Message "Failed to export results: $($_.Exception.Message)" -Level Error
            }
        }

        Write-Log -Message "" -Level Info
        Write-Log -Message "Log file saved to: $($script:LogFilePath)" -Level Info
        if ($script:ErrorLogPath -and (Test-Path $script:ErrorLogPath)) {
            $errorContent = Get-Content $script:ErrorLogPath -ErrorAction SilentlyContinue
            if ($errorContent) {
                Write-Log -Message "Error log saved to: $($script:ErrorLogPath)" -Level Warning
            }
        }
        
        # Report CSV summary files
        if ($script:UpdateSkippedLogPath -and (Test-Path $script:UpdateSkippedLogPath)) {
            $skippedCount = ((Get-Content $script:UpdateSkippedLogPath | Measure-Object).Count - 1)  # Subtract header
            if ($skippedCount -gt 0) {
                Write-Log -Message "Update Skipped CSV ($skippedCount entries): $($script:UpdateSkippedLogPath)" -Level Warning
            }
        }
        if ($script:UpdateStartedLogPath -and (Test-Path $script:UpdateStartedLogPath)) {
            $startedCount = ((Get-Content $script:UpdateStartedLogPath | Measure-Object).Count - 1)  # Subtract header
            if ($startedCount -gt 0) {
                Write-Log -Message "Update Started CSV ($startedCount entries): $($script:UpdateStartedLogPath)" -Level Success
            }
        }

        # Stop transcript if it was started
        if ($EnableTranscript) {
            try {
                Stop-Transcript | Out-Null
                Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Info] Transcript saved to: $transcriptPath" -ForegroundColor Cyan
            }
            catch {
                # Transcript may not have been started successfully - non-critical
                Write-Verbose "Note: Transcript stop failed (may not have been started): $($_.Exception.Message)"
            }
        }

        Write-Log -Message "========================================" -Level Header
        Write-Log -Message "Azure Local Cluster Update - Completed" -Level Header
        Write-Log -Message "========================================" -Level Header

        return $results
    }
}

function Get-AzureLocalClusterInfo {
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
        Get-AzureLocalClusterInfo -ClusterName "MyCluster" -SubscriptionId "12345-abcd-6789"
        
        Searches for the cluster named "MyCluster" across all resource groups in the specified subscription.
    
    .EXAMPLE
        Get-AzureLocalClusterInfo -ClusterName "MyCluster" -ResourceGroupName "MyRG" -SubscriptionId "12345-abcd-6789"
        
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

    if ($ResourceGroupName) {
        # Direct lookup if resource group is known
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.AzureStackHCI/clusters/${ClusterName}?api-version=$ApiVersion"
        
        Write-Verbose "Getting cluster info from: $uri"
        
        $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0) {
            return $result
        }
    }
    else {
        # Search across all resource groups
        $uri = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.AzureStackHCI/clusters?api-version=$ApiVersion"
        
        Write-Verbose "Searching for cluster across subscription: $uri"
        
        $allClusters = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
        if ($LASTEXITCODE -eq 0 -and $allClusters.value) {
            $cluster = $allClusters.value | Where-Object { $_.name -eq $ClusterName }
            if ($cluster) {
                return $cluster
            }
        }
    }

    return $null
}

function Get-AzureLocalUpdateSummary {
    <#
    .SYNOPSIS
        Gets the update summary for an Azure Local cluster.
    .DESCRIPTION
        Retrieves the update summary for an Azure Local (Azure Stack HCI) cluster.
        The summary includes the current update state, available updates count,
        health check results, and other update-related status information.
    .PARAMETER ClusterResourceId
        The full Azure Resource ID of the cluster.
        Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"
    .PARAMETER ApiVersion
        The Azure REST API version to use. Default is the module's default API version.
    .OUTPUTS
        PSCustomObject - Update summary object containing state, healthCheckResult, and other properties.
    .EXAMPLE
        $summary = Get-AzureLocalUpdateSummary -ClusterResourceId $cluster.id
        Write-Host "Update State: $($summary.properties.state)"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    $uri = "https://management.azure.com$ClusterResourceId/updateSummaries/default?api-version=$ApiVersion"
    
    Write-Verbose "Getting update summary from: $uri"
    
    $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0) {
        return $result
    }

    return $null
}

function Get-AzureLocalAvailableUpdates {
    <#
    .SYNOPSIS
        Gets the list of available updates for an Azure Local cluster.
    
    .DESCRIPTION
        Retrieves all updates that are available to install on the specified Azure Local cluster.
        Returns an array of update objects containing details such as update name, version, 
        description, and state.
    
    .PARAMETER ClusterResourceId
        The full Azure Resource ID of the cluster.
        Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"
    
    .PARAMETER ApiVersion
        The API version to use. Defaults to "2025-10-01".
    
    .OUTPUTS
        Returns an array of PSCustomObjects representing available updates, or empty array if none found.
    
    .EXAMPLE
        Get-AzureLocalAvailableUpdates -ClusterResourceId "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    $uri = "https://management.azure.com$ClusterResourceId/updates?api-version=$ApiVersion"
    
    Write-Verbose "Getting available updates from: $uri"
    
    $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and $result.value) {
        return $result.value
    }

    return @()
}

function Invoke-AzureLocalUpdateApply {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $true)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    $uri = "https://management.azure.com$ClusterResourceId/updates/$UpdateName/apply?api-version=$ApiVersion"
    
    Write-Verbose "Applying update via POST to: $uri"
    
    # The apply endpoint is a POST with empty body
    $result = az rest --method POST --uri $uri 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    elseif ($result -match "202" -or $result -match "Accepted") {
        # 202 Accepted is a valid response for long-running operations
        return $true
    }
    
    Write-Verbose "Apply result: $result"
    return $false
}

function Get-AzureLocalUpdateRuns {
    <#
    .SYNOPSIS
        Gets update run history and status for an Azure Local cluster.
    .DESCRIPTION
        Retrieves update run information for an Azure Local (Azure Stack HCI) cluster.
        Update runs contain the history and status of update operations including
        start time, end time, progress, and any errors that occurred.
    .PARAMETER ClusterName
        The name of the Azure Local cluster.
    .PARAMETER ResourceGroupName
        The resource group containing the cluster. If not specified, searches all resource groups.
    .PARAMETER SubscriptionId
        The Azure subscription ID. If not specified, uses the current subscription context.
    .PARAMETER UpdateName
        Optional. The specific update name to get runs for. If not specified, returns runs for all updates.
    .PARAMETER ApiVersion
        The Azure REST API version to use. Default is the module's default API version.
    .OUTPUTS
        PSCustomObject[] - Array of update run objects with properties including state, timeStarted, progress, etc.
    .EXAMPLE
        Get-AzureLocalUpdateRuns -ClusterName "MyCluster" -ResourceGroupName "MyRG"
        Gets all update runs for the specified cluster.
    .EXAMPLE
        Get-AzureLocalUpdateRuns -ClusterName "MyCluster" -UpdateName "Solution12.2601.1002.38"
        Gets update runs for a specific update version.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $false)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    # Get subscription ID if not provided
    if (-not $SubscriptionId) {
        $SubscriptionId = (az account show --query id -o tsv)
    }

    # Get cluster info
    $clusterInfo = Get-AzureLocalClusterInfo -ClusterName $ClusterName `
        -ResourceGroupName $ResourceGroupName `
        -SubscriptionId $SubscriptionId `
        -ApiVersion $ApiVersion

    if (-not $clusterInfo) {
        Write-Error "Cluster '$ClusterName' not found."
        return $null
    }

    if ($UpdateName) {
        $uri = "https://management.azure.com$($clusterInfo.id)/updates/$UpdateName/updateRuns?api-version=$ApiVersion"
    }
    else {
        # Get all updates first, then get runs for each
        $updates = Get-AzureLocalAvailableUpdates -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
        $allRuns = @()
        
        foreach ($update in $updates) {
            $uri = "https://management.azure.com$($clusterInfo.id)/updates/$($update.name)/updateRuns?api-version=$ApiVersion"
            $runs = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
            if ($runs.value) {
                $allRuns += $runs.value
            }
        }
        
        return $allRuns
    }

    $result = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0 -and $result.value) {
        return $result.value
    }

    return @()
}

function Get-AzureLocalClusterUpdateReadiness {
    <#
    .SYNOPSIS
        Assesses update readiness across Azure Local clusters and reports available updates.

    .DESCRIPTION
        This function queries Azure Local clusters and reports their update readiness state,
        available updates, and provides summary statistics to help plan update deployments.
        
        Output includes:
        - Which clusters are in "Ready" state for updates
        - Which updates are available for each cluster
        - Summary totals showing the most common applicable update version
        
        Results are displayed on screen and optionally exported to CSV, JSON, or JUnit XML.

    .PARAMETER ClusterNames
        An array of Azure Local cluster names to assess.

    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to assess.

    .PARAMETER ScopeByUpdateRingTag
        When specified, finds clusters by the 'UpdateRing' tag via Azure Resource Graph.
        Must be used together with -UpdateRingValue.

    .PARAMETER UpdateRingValue
        The value of the 'UpdateRing' tag to match when using -ScopeByUpdateRingTag.

    .PARAMETER ResourceGroupName
        The resource group containing the clusters (only used with -ClusterNames).

    .PARAMETER SubscriptionId
        The Azure subscription ID. If not specified, uses the current az CLI subscription.

    .PARAMETER ApiVersion
        The API version to use. Defaults to "2025-10-01".

    .PARAMETER ExportCsvPath
        Path to export the results. Supports .csv, .json, and .xml (JUnit format for CI/CD) extensions.
        The export format is determined by the file extension:
        - .csv  = Standard CSV format
        - .json = JSON format with summary statistics
        - .xml  = JUnit XML format for CI/CD pipeline integration (Azure DevOps, GitHub Actions, Jenkins, etc.)

    .EXAMPLE
        # Assess all clusters with a specific UpdateRing tag value
        Get-AzureLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Wave1"

    .EXAMPLE
        # Assess specific clusters and export to CSV
        Get-AzureLocalClusterUpdateReadiness -ClusterNames @("Cluster01", "Cluster02") -ExportCsvPath "C:\Reports\readiness.csv"

    .EXAMPLE
        # Export to JUnit XML for CI/CD pipelines
        Get-AzureLocalClusterUpdateReadiness -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -ExportCsvPath "C:\Reports\readiness.xml"

    .EXAMPLE
        # Assess clusters by Resource ID
        Get-AzureLocalClusterUpdateReadiness -ClusterResourceIds @("/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01")

    .NOTES
        Version: 0.4.0
        Author: Neil Bird, Microsoft.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string[]]$ClusterNames,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [switch]$ScopeByUpdateRingTag,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false)]
        [string]$ExportCsvPath
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Azure Local Cluster Update Readiness Assessment" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Verify Azure CLI is installed and logged in
    try {
        $null = az account show 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI is not logged in. Please run 'az login' first."
        }
    }
    catch {
        Write-Error "Azure CLI is not installed or not logged in. Please install Azure CLI and run 'az login'."
        return
    }

    # Build list of clusters to process
    $clustersToProcess = @()
    
    if ($PSCmdlet.ParameterSetName -eq 'ByTag') {
        # Ensure resource-graph extension is installed (for pipeline/automation scenarios)
        if (-not (Install-AzGraphExtension)) {
            Write-Error "Failed to install Azure CLI 'resource-graph' extension. Please install manually: az extension add --name resource-graph"
            return
        }
        
        Write-Host "Querying Azure Resource Graph for clusters with tag 'UpdateRing' = '$UpdateRingValue'..." -ForegroundColor Yellow
        
        # Build Azure Resource Graph query - use single line to avoid escaping issues with az CLI
        $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | where tags['UpdateRing'] =~ '$UpdateRingValue' | project id, name, resourceGroup, subscriptionId, tags"
        
        try {
            $argResult = az graph query -q $argQuery --first 1000 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Azure Resource Graph query failed. Ensure you have the 'az graph' extension installed."
                return
            }
            
            $clusters = $argResult | ConvertFrom-Json
            
            if (-not $clusters.data -or $clusters.data.Count -eq 0) {
                Write-Warning "No clusters found with tag 'UpdateRing' = '$UpdateRingValue'"
                return
            }
            
            Write-Host "Found $($clusters.data.Count) cluster(s) matching tag criteria" -ForegroundColor Green
            foreach ($cluster in $clusters.data) {
                $clustersToProcess += @{ 
                    ResourceId = $cluster.id
                    Name = $cluster.name 
                    ResourceGroup = $cluster.resourceGroup
                    SubscriptionId = $cluster.subscriptionId
                }
            }
        }
        catch {
            Write-Error "Error querying Azure Resource Graph: $_"
            return
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'ByResourceId') {
        foreach ($resourceId in $ClusterResourceIds) {
            $clusterRgName = ($resourceId -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
            $clusterSubId = ($resourceId -split '/subscriptions/')[1] -split '/' | Select-Object -First 1
            $clustersToProcess += @{ 
                ResourceId = $resourceId
                Name = ($resourceId -split '/')[-1]
                ResourceGroup = $clusterRgName
                SubscriptionId = $clusterSubId
            }
        }
    }
    else {
        # ByName
        if (-not $SubscriptionId) {
            $SubscriptionId = (az account show --query id -o tsv)
        }
        foreach ($name in $ClusterNames) {
            $clustersToProcess += @{ 
                ResourceId = $null
                Name = $name
                ResourceGroup = $ResourceGroupName
                SubscriptionId = $SubscriptionId
            }
        }
    }

    Write-Host ""
    Write-Host "Assessing $($clustersToProcess.Count) cluster(s)..." -ForegroundColor Yellow
    Write-Host ""

    # Collect results
    $results = @()
    $updateVersionCounts = @{}

    foreach ($cluster in $clustersToProcess) {
        $clusterName = $cluster.Name
        Write-Host "  Checking: $clusterName..." -ForegroundColor Gray -NoNewline

        try {
            # Get cluster info
            if ($cluster.ResourceId) {
                $uri = "https://management.azure.com$($cluster.ResourceId)?api-version=$ApiVersion"
                $clusterInfo = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json
            }
            else {
                $clusterInfo = Get-AzureLocalClusterInfo -ClusterName $clusterName `
                    -ResourceGroupName $cluster.ResourceGroup `
                    -SubscriptionId $cluster.SubscriptionId `
                    -ApiVersion $ApiVersion
            }

            if (-not $clusterInfo) {
                Write-Host " Not Found" -ForegroundColor Red
                $results += [PSCustomObject]@{
                    ClusterName         = $clusterName
                    ResourceGroup       = $cluster.ResourceGroup
                    SubscriptionId      = $cluster.SubscriptionId
                    ClusterState        = "Not Found"
                    UpdateState         = "N/A"
                    HealthState         = "N/A"
                    ReadyForUpdate      = $false
                    AvailableUpdates    = ""
                    ReadyUpdates        = ""
                    RecommendedUpdate   = ""
                    HealthCheckFailures = ""
                }
                continue
            }

            # Parse RG and Sub from cluster info if not already set
            $rgName = ($clusterInfo.id -split '/resourceGroups/')[1] -split '/' | Select-Object -First 1
            $subId = ($clusterInfo.id -split '/subscriptions/')[1] -split '/' | Select-Object -First 1

            # Get update summary
            $updateSummary = Get-AzureLocalUpdateSummary -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
            $updateState = if ($updateSummary) { $updateSummary.properties.state } else { "Unknown" }

            # Get available updates
            $availableUpdates = Get-AzureLocalAvailableUpdates -ClusterResourceId $clusterInfo.id -ApiVersion $ApiVersion
            $readyUpdates = $availableUpdates | Where-Object { $_.properties.state -eq "Ready" }
            
            $availableUpdateNames = ($availableUpdates | ForEach-Object { $_.name }) -join "; "
            $readyUpdateNames = ($readyUpdates | ForEach-Object { $_.name }) -join "; "
            
            # Determine recommended update (latest ready update)
            $recommendedUpdate = ""
            if ($readyUpdates -and $readyUpdates.Count -gt 0) {
                $recommendedUpdate = ($readyUpdates | Select-Object -First 1).name
                
                # Track update version counts
                if ($updateVersionCounts.ContainsKey($recommendedUpdate)) {
                    $updateVersionCounts[$recommendedUpdate]++
                }
                else {
                    $updateVersionCounts[$recommendedUpdate] = 1
                }
            }

            # Determine if ready for update
            $isReady = ($updateState -in @("UpdateAvailable", "Ready")) -and ($readyUpdates.Count -gt 0)
            
            # Get health state and check failures
            $healthState = if ($updateSummary -and $updateSummary.properties.healthState) { $updateSummary.properties.healthState } else { "Unknown" }
            $healthCheckFailures = ""
            if ($updateSummary -and $healthState -notin @("Success", "Unknown")) {
                $healthCheckFailures = Get-HealthCheckFailureSummary -UpdateSummary $updateSummary
            }
            
            if ($isReady) {
                Write-Host " Ready ($recommendedUpdate)" -ForegroundColor Green
            }
            elseif ($updateState -eq "UpdateInProgress") {
                Write-Host " Update In Progress" -ForegroundColor Yellow
            }
            elseif ($readyUpdates.Count -eq 0 -and $availableUpdates.Count -gt 0) {
                Write-Host " Updates Downloading" -ForegroundColor Yellow
            }
            elseif ($healthState -in @("Failure", "Warning")) {
                Write-Host " $updateState ($healthState)" -ForegroundColor $(if ($healthState -eq "Failure") { "Red" } else { "Yellow" })
            }
            else {
                Write-Host " $updateState" -ForegroundColor Gray
            }

            $results += [PSCustomObject]@{
                ClusterName         = $clusterName
                ResourceGroup       = $rgName
                SubscriptionId      = $subId
                ClusterState        = $clusterInfo.properties.status
                UpdateState         = $updateState
                HealthState         = $healthState
                ReadyForUpdate      = $isReady
                AvailableUpdates    = $availableUpdateNames
                ReadyUpdates        = $readyUpdateNames
                RecommendedUpdate   = $recommendedUpdate
                HealthCheckFailures = $healthCheckFailures
            }
        }
        catch {
            Write-Host " Error: $($_.Exception.Message)" -ForegroundColor Red
            $results += [PSCustomObject]@{
                ClusterName         = $clusterName
                ResourceGroup       = $cluster.ResourceGroup
                SubscriptionId      = $cluster.SubscriptionId
                ClusterState        = "Error"
                UpdateState         = "Error"
                HealthState         = "Error"
                ReadyForUpdate      = $false
                AvailableUpdates    = ""
                ReadyUpdates        = ""
                RecommendedUpdate   = ""
                HealthCheckFailures = $_.Exception.Message
            }
        }
    }

    # Display Summary
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    $totalClusters = $results.Count
    $readyClusters = ($results | Where-Object { $_.ReadyForUpdate -eq $true }).Count
    $notReadyClusters = $totalClusters - $readyClusters
    $inProgressClusters = ($results | Where-Object { $_.UpdateState -eq "UpdateInProgress" }).Count

    Write-Host ""
    Write-Host "Total Clusters Assessed:    $totalClusters" -ForegroundColor White
    Write-Host "Ready for Update:           $readyClusters" -ForegroundColor Green
    Write-Host "Not Ready / Other State:    $notReadyClusters" -ForegroundColor $(if ($notReadyClusters -gt 0) { "Yellow" } else { "White" })
    Write-Host "Update In Progress:         $inProgressClusters" -ForegroundColor $(if ($inProgressClusters -gt 0) { "Yellow" } else { "White" })
    
    # Show health state breakdown
    $healthFailures = ($results | Where-Object { $_.HealthState -eq "Failure" }).Count
    $healthWarnings = ($results | Where-Object { $_.HealthState -eq "Warning" }).Count
    if ($healthFailures -gt 0 -or $healthWarnings -gt 0) {
        Write-Host ""
        Write-Host "Health Check Issues:" -ForegroundColor Cyan
        if ($healthFailures -gt 0) {
            Write-Host "  Critical Failures:        $healthFailures" -ForegroundColor Red
        }
        if ($healthWarnings -gt 0) {
            Write-Host "  Warnings:                 $healthWarnings" -ForegroundColor Yellow
        }
    }

    # Show most common update versions
    if ($updateVersionCounts.Count -gt 0) {
        Write-Host ""
        Write-Host "Available Update Versions (clusters ready to install):" -ForegroundColor Cyan
        $sortedVersions = $updateVersionCounts.GetEnumerator() | Sort-Object -Property Value -Descending
        foreach ($version in $sortedVersions) {
            $percentage = [math]::Round(($version.Value / $readyClusters) * 100, 1)
            Write-Host "  $($version.Key): $($version.Value) cluster(s) ($percentage%)" -ForegroundColor White
        }
        
        $mostCommonVersion = ($sortedVersions | Select-Object -First 1).Key
        Write-Host ""
        Write-Host "Most Common Applicable Update: " -NoNewline -ForegroundColor White
        Write-Host "$mostCommonVersion" -ForegroundColor Green
    }

    # Display results table
    Write-Host ""
    Write-Host "Detailed Results:" -ForegroundColor Cyan
    $results | Format-Table ClusterName, ResourceGroup, UpdateState, HealthState, ReadyForUpdate, RecommendedUpdate -AutoSize
    
    # Show clusters with health check failures
    $clustersWithHealthIssues = $results | Where-Object { $_.HealthCheckFailures -ne "" }
    if ($clustersWithHealthIssues.Count -gt 0) {
        Write-Host ""
        Write-Host "Clusters with Health Check Issues:" -ForegroundColor Yellow
        foreach ($cluster in $clustersWithHealthIssues) {
            Write-Host "  $($cluster.ClusterName): " -ForegroundColor White -NoNewline
            Write-Host "$($cluster.HealthCheckFailures)" -ForegroundColor $(if ($cluster.HealthState -eq "Failure") { "Red" } else { "Yellow" })
        }
    }

    # Export to CSV if path specified
    if ($ExportCsvPath) {
        try {
            $exportDir = Split-Path -Path $ExportCsvPath -Parent
            if ($exportDir -and -not (Test-Path $exportDir)) {
                New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
            }
            
            $extension = [System.IO.Path]::GetExtension($ExportCsvPath).ToLower()
            
            # Transform results for JUnit-compatible format
            $junitResults = $results | ForEach-Object {
                [PSCustomObject]@{
                    ClusterName  = $_.ClusterName
                    Status       = if ($_.ReadyForUpdate -eq "Yes") { "Ready" } elseif ($_.HealthState -eq "Failure") { "Failed" } else { "Skipped" }
                    Message      = "UpdateState: $($_.UpdateState), HealthState: $($_.HealthState), RecommendedUpdate: $($_.RecommendedUpdate)"
                    UpdateName   = $_.RecommendedUpdate
                    CurrentState = $_.UpdateState
                }
            }
            
            switch ($extension) {
                '.csv' {
                    $results | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8
                    Write-Host "Results exported to CSV: $ExportCsvPath" -ForegroundColor Green
                }
                '.json' {
                    $exportData = @{
                        Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        TotalClusters   = $totalClusters
                        ClustersReady   = $readyClusters
                        ClustersNotReady = $notReadyClusters
                        Results         = $results
                    }
                    $exportData | ConvertTo-Json -Depth 10 | Out-File -FilePath $ExportCsvPath -Encoding UTF8
                    Write-Host "Results exported to JSON: $ExportCsvPath" -ForegroundColor Green
                }
                '.xml' {
                    Export-ResultsToJUnitXml -Results $junitResults -OutputPath $ExportCsvPath `
                        -TestSuiteName "AzureLocalClusterReadiness" -OperationType "ReadinessCheck"
                    Write-Host "Results exported to JUnit XML (CI/CD compatible): $ExportCsvPath" -ForegroundColor Green
                }
                default {
                    # Default to CSV for backward compatibility
                    $results | Export-Csv -Path $ExportCsvPath -NoTypeInformation -Encoding UTF8
                    Write-Host "Results exported to CSV: $ExportCsvPath" -ForegroundColor Green
                }
            }
        }
        catch {
            Write-Error "Failed to export results: $($_.Exception.Message)"
        }
    }

    Write-Host ""
    return $results
}

function Get-AzureLocalClusterInventory {
    <#
    .SYNOPSIS
        Gets an inventory of all Azure Local clusters with their UpdateRing tag status.

    .DESCRIPTION
        Uses Azure Resource Graph to query all Azure Local (Azure Stack HCI) clusters
        across all accessible subscriptions. Returns cluster details including the 
        value of the 'UpdateRing' tag (or indicates if the tag doesn't exist).
        
        The output can be exported to CSV for use with Excel to plan and populate
        UpdateRing tag values, then used as input for Set-AzureLocalClusterUpdateRingTag.

    .PARAMETER SubscriptionId
        Optional. Limit the query to a specific Azure subscription ID.
        If not specified, queries across all accessible subscriptions.

    .PARAMETER ExportCsvPath
        Optional. Path to export the inventory as a CSV file.
        Useful for editing in Excel and then importing back.

    .EXAMPLE
        # Get inventory of all clusters across all subscriptions
        Get-AzureLocalClusterInventory

    .EXAMPLE
        # Get inventory and export to CSV for editing
        Get-AzureLocalClusterInventory -ExportCsvPath "C:\Temp\ClusterInventory.csv"

    .EXAMPLE
        # Get inventory for a specific subscription
        Get-AzureLocalClusterInventory -SubscriptionId "12345678-1234-1234-1234-123456789012"

    .EXAMPLE
        # Pipeline workflow: Get inventory, edit CSV, then apply tags
        Get-AzureLocalClusterInventory -ExportCsvPath "C:\Temp\Inventory.csv"
        # Edit the CSV in Excel to populate UpdateRing values
        Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\Inventory.csv"

    .EXAMPLE
        # CI/CD pipeline: Export to CSV AND return objects for processing
        $inventory = Get-AzureLocalClusterInventory -ExportCsvPath "C:\Temp\Inventory.csv" -PassThru
        Write-Host "Found $($inventory.Count) clusters"

    .NOTES
        Version: 0.4.1
        Author: Neil Bird, Microsoft.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ExportCsvPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Azure Local Cluster Inventory" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    # Verify Azure CLI is installed and logged in
    try {
        $null = az account show 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI is not logged in. Please run 'az login' first."
        }
    }
    catch {
        Write-Error "Azure CLI is not installed or not logged in. Please install Azure CLI and run 'az login'."
        return
    }

    # Ensure resource-graph extension is installed
    if (-not (Install-AzGraphExtension)) {
        Write-Error "Failed to install Azure CLI 'resource-graph' extension. Please install manually: az extension add --name resource-graph"
        return
    }

    Write-Host "Querying Azure Resource Graph for all Azure Local clusters..." -ForegroundColor Yellow

    # Build Azure Resource Graph query - use single line to avoid escaping issues with az CLI
    $argQuery = "resources | where type =~ 'microsoft.azurestackhci/clusters' | project id, name, resourceGroup, subscriptionId, tags | order by name asc"

    try {
        # Build the command with optional subscription filter
        if ($SubscriptionId) {
            Write-Host "  Filtering to subscription: $SubscriptionId" -ForegroundColor Gray
            $argResult = az graph query -q $argQuery --subscriptions $SubscriptionId --first 1000 2>&1
        }
        else {
            Write-Host "  Querying across all accessible subscriptions" -ForegroundColor Gray
            $argResult = az graph query -q $argQuery --first 1000 2>&1
        }

        if ($LASTEXITCODE -ne 0) {
            $errorMessage = $argResult | Out-String
            Write-Error "Azure Resource Graph query failed: $errorMessage"
            return
        }

        $clusters = $argResult | ConvertFrom-Json

        if (-not $clusters.data -or $clusters.data.Count -eq 0) {
            Write-Warning "No Azure Local clusters found."
            return @()
        }

        # Get subscription names for better readability
        Write-Host "Retrieving subscription details..." -ForegroundColor Yellow
        $subscriptionMap = @{}
        $uniqueSubIds = $clusters.data | Select-Object -ExpandProperty subscriptionId -Unique
        
        foreach ($subId in $uniqueSubIds) {
            try {
                $subInfo = az account show --subscription $subId 2>&1 | ConvertFrom-Json
                if ($LASTEXITCODE -eq 0 -and $subInfo.name) {
                    $subscriptionMap[$subId] = $subInfo.name
                }
                else {
                    $subscriptionMap[$subId] = "(Unable to retrieve name)"
                }
            }
            catch {
                $subscriptionMap[$subId] = "(Unable to retrieve name)"
            }
        }

        # Build inventory results
        $inventory = @()
        foreach ($cluster in $clusters.data) {
            # Get UpdateRing tag value
            $updateRingValue = $null
            if ($cluster.tags -and $cluster.tags.PSObject.Properties['UpdateRing']) {
                $updateRingValue = $cluster.tags.UpdateRing
            }

            $inventoryItem = [PSCustomObject]@{
                ClusterName      = $cluster.name
                ResourceGroup    = $cluster.resourceGroup
                SubscriptionId   = $cluster.subscriptionId
                SubscriptionName = $subscriptionMap[$cluster.subscriptionId]
                UpdateRing       = if ($updateRingValue) { $updateRingValue } else { "" }
                HasUpdateRingTag = if ($updateRingValue) { "Yes" } else { "No" }
                ResourceId       = $cluster.id
            }
            $inventory += $inventoryItem
        }

        # Calculate summary statistics
        $clustersWithTag = ($inventory | Where-Object { $_.HasUpdateRingTag -eq "Yes" }).Count
        $clustersWithoutTag = $inventory.Count - $clustersWithTag
        $ringGroups = $inventory | Where-Object { $_.UpdateRing -ne "" } | Group-Object -Property UpdateRing

        # Export to CSV if path specified
        if ($ExportCsvPath) {
            try {
                # Ensure directory exists
                $exportDir = Split-Path -Path $ExportCsvPath -Parent
                if ($exportDir -and -not (Test-Path -Path $exportDir)) {
                    $null = New-Item -ItemType Directory -Path $exportDir -Force
                }

                # Export inventory (without HasUpdateRingTag column for cleaner CSV)
                $inventory | Select-Object ClusterName, ResourceGroup, SubscriptionId, SubscriptionName, UpdateRing, ResourceId | 
                    Export-Csv -Path $ExportCsvPath -NoTypeInformation -Force
            }
            catch {
                Write-Error "Failed to export inventory: $($_.Exception.Message)"
            }
        }

        # Display summary at the end
        Write-Host ""
        Write-Host "Inventory Summary:" -ForegroundColor Cyan
        Write-Host "  Total Clusters: $($inventory.Count)" -ForegroundColor White
        Write-Host "  Clusters with UpdateRing tag: $clustersWithTag" -ForegroundColor $(if ($clustersWithTag -gt 0) { "Green" } else { "Gray" })
        Write-Host "  Clusters without UpdateRing tag: $clustersWithoutTag" -ForegroundColor $(if ($clustersWithoutTag -gt 0) { "Yellow" } else { "Gray" })

        # Group by UpdateRing value
        if ($ringGroups.Count -gt 0) {
            Write-Host ""
            Write-Host "  UpdateRing Distribution:" -ForegroundColor White
            foreach ($group in $ringGroups | Sort-Object Name) {
                Write-Host "    $($group.Name): $($group.Count) cluster(s)" -ForegroundColor Green
            }
        }

        # Show export path and next steps if CSV was exported
        if ($ExportCsvPath -and (Test-Path -Path $ExportCsvPath)) {
            Write-Host ""
            Write-Host "Inventory exported to: $ExportCsvPath" -ForegroundColor Green
            Write-Host ""
            Write-Host "Next Steps:" -ForegroundColor Cyan
            Write-Host "  1. Open the CSV in Excel" -ForegroundColor White
            Write-Host "  2. Populate the 'UpdateRing' column with values (e.g., 'Wave1', 'Wave2', 'Pilot')" -ForegroundColor White
            Write-Host "  3. Save the CSV file" -ForegroundColor White
            Write-Host "  4. Run: Set-AzureLocalClusterUpdateRingTag -InputCsvPath '$ExportCsvPath'" -ForegroundColor Yellow
        }

        Write-Host ""
        
        # Return inventory if: no CSV export, OR PassThru is specified
        # This allows CI/CD pipelines to use -PassThru to get objects for processing
        if (-not $ExportCsvPath -or $PassThru) {
            return $inventory
        }
    }
    catch {
        Write-Error "Error querying Azure Resource Graph: $($_.Exception.Message)"
        return @()
    }
}

function Set-AzureLocalClusterUpdateRingTag {
    <#
    .SYNOPSIS
        Sets or updates the "UpdateRing" tag on Azure Local clusters for update ring management.
    
    .DESCRIPTION
        This function allows users to assign "UpdateRing" tags to Azure Local clusters
        for organizing update deployment waves. It can accept cluster Resource IDs directly
        or import them from a CSV file (typically exported from Get-AzureLocalClusterInventory).
        
        The function will:
        - Verify each Resource ID is a valid microsoft.azurestackhci/clusters resource
        - Check if the cluster already has an "UpdateRing" tag
        - If tag exists: Show warning and skip unless -Force is specified
        - If -Force: Update the tag and log the previous value
        - If no tag exists: Create the new tag
        - Log all operations to a CSV file
    
    .PARAMETER InputCsvPath
        Path to a CSV file containing cluster information. The CSV should have columns:
        - ResourceId: The full Azure Resource ID of the cluster
        - UpdateRing: The value to assign to the UpdateRing tag
        This CSV format is compatible with the output from Get-AzureLocalClusterInventory.
        Only rows with a non-empty UpdateRing value will be processed.
    
    .PARAMETER ClusterResourceIds
        An array of full Azure Resource IDs for the clusters to tag.
        Example: "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01"
    
    .PARAMETER UpdateRingValue
        The value to assign to the "UpdateRing" tag (e.g., "Ring1", "Ring2", "Wave1", "Production").
        Required when using -ClusterResourceIds. Not used with -InputCsvPath (values come from CSV).
    
    .PARAMETER Force
        If specified, will overwrite existing "UpdateRing" tags. Without this switch,
        clusters with existing tags will be skipped with a warning.
    
    .PARAMETER LogFolderPath
        Path to the folder where log files will be created. If not specified, defaults to:
        C:\ProgramData\AzStackHci.ManageUpdates\
    
    .PARAMETER WhatIf
        Shows what would happen if the cmdlet runs. The cmdlet is not run.
    
    .EXAMPLE
        # Import tags from a CSV file (from Get-AzureLocalClusterInventory)
        Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv"
    
    .EXAMPLE
        # Set UpdateRing tag on multiple clusters
        $resourceIds = @(
            "/subscriptions/xxx/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01",
            "/subscriptions/xxx/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02"
        )
        Set-AzureLocalClusterUpdateRingTag -ClusterResourceIds $resourceIds -UpdateRingValue "Ring1"
    
    .EXAMPLE
        # Force update existing tags from CSV
        Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -Force
    
    .EXAMPLE
        # Preview changes without applying (from CSV)
        Set-AzureLocalClusterUpdateRingTag -InputCsvPath "C:\Temp\ClusterInventory.csv" -WhatIf
    
    .OUTPUTS
        Returns an array of PSCustomObjects with the results for each cluster.
    
    .NOTES
        Requires: Azure CLI (az) installed and authenticated
    #>
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'ByResourceId')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByCsv')]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$InputCsvPath,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false)]
        [switch]$Force,

        [Parameter(Mandatory = $false)]
        [string]$LogFolderPath
    )

    # Set default log folder
    if (-not $LogFolderPath) {
        $LogFolderPath = "C:\ProgramData\AzStackHci.ManageUpdates"
    }

    # Create log folder if it doesn't exist
    if (-not (Test-Path $LogFolderPath)) {
        New-Item -ItemType Directory -Path $LogFolderPath -Force | Out-Null
    }

    # Create timestamped log file paths
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFilePath = Join-Path $LogFolderPath "UpdateRingTag_$timestamp.log"
    $csvLogPath = Join-Path $LogFolderPath "UpdateRingTag_$timestamp.csv"

    # Initialize CSV with headers
    $csvHeader = '"ClusterName","ResourceGroup","SubscriptionId","ResourceId","Action","PreviousTagValue","NewTagValue","Status","Message"'
    $csvHeader | Out-File -FilePath $csvLogPath -Encoding UTF8

    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Azure Local Cluster UpdateRing Tag Management" -Level Header
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Log file: $($script:LogFilePath)" -Level Info
    Write-Log -Message "CSV log: $csvLogPath" -Level Info

    # Process input based on parameter set
    $clustersToTag = @()
    
    if ($PSCmdlet.ParameterSetName -eq 'ByCsv') {
        Write-Log -Message "Input mode: CSV file" -Level Info
        Write-Log -Message "CSV path: $InputCsvPath" -Level Info
        
        try {
            $csvData = Import-Csv -Path $InputCsvPath
            
            # Validate CSV has required columns
            $requiredColumns = @('ResourceId', 'UpdateRing')
            $csvColumns = $csvData | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
            
            foreach ($col in $requiredColumns) {
                if ($col -notin $csvColumns) {
                    Write-Log -Message "CSV is missing required column: $col" -Level Error
                    Write-Log -Message "Required columns: $($requiredColumns -join ', ')" -Level Error
                    return
                }
            }
            
            # Filter rows that have both ResourceId and UpdateRing values
            $validRows = $csvData | Where-Object { 
                $_.ResourceId -and $_.ResourceId.Trim() -ne '' -and 
                $_.UpdateRing -and $_.UpdateRing.Trim() -ne '' 
            }
            
            if ($validRows.Count -eq 0) {
                Write-Log -Message "No valid rows found in CSV (rows must have both ResourceId and UpdateRing values)" -Level Warning
                return
            }
            
            Write-Log -Message "Found $($validRows.Count) row(s) with UpdateRing values to process" -Level Info
            
            foreach ($row in $validRows) {
                $clustersToTag += @{
                    ResourceId     = $row.ResourceId.Trim()
                    UpdateRingValue = $row.UpdateRing.Trim()
                }
            }
        }
        catch {
            Write-Log -Message "Failed to read CSV file: $($_.Exception.Message)" -Level Error
            return
        }
    }
    else {
        # ByResourceId parameter set
        Write-Log -Message "Input mode: Resource IDs" -Level Info
        Write-Log -Message "UpdateRing value to set: $UpdateRingValue" -Level Info
        
        foreach ($resourceId in $ClusterResourceIds) {
            $clustersToTag += @{
                ResourceId      = $resourceId
                UpdateRingValue = $UpdateRingValue
            }
        }
    }

    Write-Log -Message "Force mode: $Force" -Level Info
    Write-Log -Message "Clusters to process: $($clustersToTag.Count)" -Level Info
    Write-Log -Message "" -Level Info

    # Verify Azure CLI authentication
    try {
        $null = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message "Azure CLI is not authenticated. Please run 'az login' first." -Level Error
            return
        }
        Write-Log -Message "Azure CLI authentication verified" -Level Success
    }
    catch {
        Write-Log -Message "Failed to verify Azure CLI authentication: $_" -Level Error
        return
    }

    $results = @()

    foreach ($clusterEntry in $clustersToTag) {
        $resourceId = $clusterEntry.ResourceId
        $currentUpdateRingValue = $clusterEntry.UpdateRingValue
        
        Write-Log -Message "" -Level Info
        Write-Log -Message "----------------------------------------" -Level Info
        Write-Log -Message "Processing: $resourceId" -Level Info
        Write-Log -Message "Target UpdateRing: $currentUpdateRingValue" -Level Info
        Write-Log -Message "----------------------------------------" -Level Info

        $clusterName = ""
        $resourceGroup = ""
        $subscriptionId = ""
        $previousTagValue = ""
        $action = ""
        $status = ""
        $message = ""

        try {
            # Parse the Resource ID to extract components
            if ($resourceId -match '/subscriptions/([^/]+)/resourceGroups/([^/]+)/providers/([^/]+)/([^/]+)/([^/]+)') {
                $subscriptionId = $matches[1]
                $resourceGroup = $matches[2]
                $providerNamespace = $matches[3]
                $resourceType = $matches[4]
                $clusterName = $matches[5]

                # Validate this is an Azure Stack HCI cluster
                $actualType = "$providerNamespace/$resourceType"
                
                if ($actualType -notlike "Microsoft.AzureStackHCI/clusters" -and $actualType -notlike "microsoft.azurestackhci/clusters") {
                    Write-Log -Message "Resource is not an Azure Local cluster. Type: $actualType" -Level Error
                    $action = "Skipped"
                    $status = "Failed"
                    $message = "Invalid resource type: $actualType (expected Microsoft.AzureStackHCI/clusters)"
                    
                    # Write to CSV
                    $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                    Add-Content -Path $csvLogPath -Value $csvLine
                    
                    $results += [PSCustomObject]@{
                        ClusterName      = $clusterName
                        ResourceGroup    = $resourceGroup
                        SubscriptionId   = $subscriptionId
                        ResourceId       = $resourceId
                        Action           = $action
                        PreviousTagValue = $previousTagValue
                        NewTagValue      = $currentUpdateRingValue
                        Status           = $status
                        Message          = $message
                    }
                    continue
                }
            }
            else {
                Write-Log -Message "Invalid Resource ID format: $resourceId" -Level Error
                $action = "Skipped"
                $status = "Failed"
                $message = "Invalid Resource ID format"
                
                # Write to CSV
                $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                Add-Content -Path $csvLogPath -Value $csvLine
                
                $results += [PSCustomObject]@{
                    ClusterName      = $clusterName
                    ResourceGroup    = $resourceGroup
                    SubscriptionId   = $subscriptionId
                    ResourceId       = $resourceId
                    Action           = $action
                    PreviousTagValue = $previousTagValue
                    NewTagValue      = $currentUpdateRingValue
                    Status           = $status
                    Message          = $message
                }
                continue
            }

            Write-Log -Message "Cluster: $clusterName" -Level Info
            Write-Log -Message "Resource Group: $resourceGroup" -Level Info
            Write-Log -Message "Subscription: $subscriptionId" -Level Info

            # Get current resource to verify it exists and get current tags
            Write-Log -Message "Verifying cluster exists and retrieving current tags..." -Level Info
            $uri = "https://management.azure.com$resourceId`?api-version=2025-10-01"
            $clusterInfo = az rest --method GET --uri $uri 2>$null | ConvertFrom-Json

            if ($LASTEXITCODE -ne 0 -or -not $clusterInfo) {
                Write-Log -Message "Failed to retrieve cluster. It may not exist or you don't have access." -Level Error
                $action = "Skipped"
                $status = "Failed"
                $message = "Cluster not found or access denied"
                
                # Write to CSV
                $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                Add-Content -Path $csvLogPath -Value $csvLine
                
                $results += [PSCustomObject]@{
                    ClusterName      = $clusterName
                    ResourceGroup    = $resourceGroup
                    SubscriptionId   = $subscriptionId
                    ResourceId       = $resourceId
                    Action           = $action
                    PreviousTagValue = $previousTagValue
                    NewTagValue      = $currentUpdateRingValue
                    Status           = $status
                    Message          = $message
                }
                continue
            }

            # Verify the resource type from the API response
            if ($clusterInfo.type -notlike "Microsoft.AzureStackHCI/clusters" -and $clusterInfo.type -notlike "microsoft.azurestackhci/clusters") {
                Write-Log -Message "Resource type mismatch. Expected Azure Local cluster, got: $($clusterInfo.type)" -Level Error
                $action = "Skipped"
                $status = "Failed"
                $message = "Resource type mismatch: $($clusterInfo.type)"
                
                # Write to CSV
                $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                Add-Content -Path $csvLogPath -Value $csvLine
                
                $results += [PSCustomObject]@{
                    ClusterName      = $clusterName
                    ResourceGroup    = $resourceGroup
                    SubscriptionId   = $subscriptionId
                    ResourceId       = $resourceId
                    Action           = $action
                    PreviousTagValue = $previousTagValue
                    NewTagValue      = $currentUpdateRingValue
                    Status           = $status
                    Message          = $message
                }
                continue
            }

            Write-Log -Message "Cluster verified: $($clusterInfo.name)" -Level Success

            # Get current tags
            $currentTags = @{}
            if ($clusterInfo.tags) {
                $currentTags = $clusterInfo.tags
                Write-Log -Message "Current tags: $($currentTags | ConvertTo-Json -Compress)" -Level Verbose
            }
            else {
                Write-Log -Message "No existing tags on cluster" -Level Verbose
            }

            # Check if UpdateRing tag already exists
            if ($currentTags.PSObject.Properties.Name -contains "UpdateRing") {
                $previousTagValue = $currentTags.UpdateRing
                Write-Log -Message "Existing UpdateRing tag found with value: '$previousTagValue'" -Level Warning

                if (-not $Force) {
                    Write-Log -Message "Skipping cluster - use -Force to overwrite existing tag" -Level Warning
                    $action = "Skipped"
                    $status = "Skipped"
                    $message = "Existing UpdateRing tag present (value: $previousTagValue). Use -Force to overwrite."
                    
                    # Write to CSV
                    $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
                    Add-Content -Path $csvLogPath -Value $csvLine
                    
                    $results += [PSCustomObject]@{
                        ClusterName      = $clusterName
                        ResourceGroup    = $resourceGroup
                        SubscriptionId   = $subscriptionId
                        ResourceId       = $resourceId
                        Action           = $action
                        PreviousTagValue = $previousTagValue
                        NewTagValue      = $currentUpdateRingValue
                        Status           = $status
                        Message          = $message
                    }
                    continue
                }
                else {
                    Write-Log -Message "Force mode enabled - will update existing tag" -Level Info
                    $action = "Updated"
                }
            }
            else {
                Write-Log -Message "No existing UpdateRing tag - will create new tag" -Level Info
                $action = "Created"
            }

            # Build the new tags object (preserve existing tags and add/update UpdateRing)
            # Use ordered hashtable and convert to PSCustomObject for clean JSON serialization
            $newTags = [ordered]@{}
            if ($currentTags -and $currentTags.PSObject.Properties.Name.Count -gt 0) {
                # Copy existing tags (only actual tag properties, not PSObject internals)
                foreach ($prop in $currentTags.PSObject.Properties) {
                    # Skip PowerShell internal properties
                    if ($prop.MemberType -eq 'NoteProperty') {
                        $newTags[$prop.Name] = $prop.Value
                    }
                }
            }
            $newTags["UpdateRing"] = $currentUpdateRingValue

            # Apply the tag using PATCH
            if ($PSCmdlet.ShouldProcess($resourceId, "Set UpdateRing tag to '$currentUpdateRingValue'")) {
                Write-Log -Message "Applying UpdateRing tag with value: '$currentUpdateRingValue'..." -Level Info
                
                # Create a clean PSCustomObject for JSON serialization
                $patchBodyObj = [PSCustomObject]@{
                    tags = [PSCustomObject]$newTags
                }
                $patchBody = $patchBodyObj | ConvertTo-Json -Compress -Depth 10

                # Write body to temp file to avoid PowerShell/cmd JSON escaping issues
                $tempFile = [System.IO.Path]::GetTempFileName()
                try {
                    $patchBody | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
                    
                    # Use az rest with @file syntax to avoid escaping issues
                    $result = az rest --method PATCH --uri $uri --body "@$tempFile" --headers "Content-Type=application/json" 2>&1
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log -Message "Successfully $($action.ToLower()) UpdateRing tag" -Level Success
                        $status = "Success"
                        $message = "UpdateRing tag $($action.ToLower()) successfully"
                    }
                    else {
                        Write-Log -Message "Failed to apply tag: $result" -Level Error
                        $status = "Failed"
                        $message = "Failed to apply tag: $result"
                    }
                }
                finally {
                    # Clean up temp file
                    if (Test-Path $tempFile) {
                        Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            else {
                $status = "WhatIf"
                $message = "Would $($action.ToLower()) UpdateRing tag"
            }

            # Write to CSV
            $escapedMessage = $message -replace '"', '""'
            $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"$action`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$escapedMessage`""
            Add-Content -Path $csvLogPath -Value $csvLine

            $results += [PSCustomObject]@{
                ClusterName      = $clusterName
                ResourceGroup    = $resourceGroup
                SubscriptionId   = $subscriptionId
                ResourceId       = $resourceId
                Action           = $action
                PreviousTagValue = $previousTagValue
                NewTagValue      = $currentUpdateRingValue
                Status           = $status
                Message          = $message
            }
        }
        catch {
            Write-Log -Message "Error processing cluster: $($_.Exception.Message)" -Level Error
            $status = "Failed"
            $message = $_.Exception.Message -replace '"', '""'
            
            # Write to CSV
            $csvLine = "`"$clusterName`",`"$resourceGroup`",`"$subscriptionId`",`"$resourceId`",`"Error`",`"$previousTagValue`",`"$currentUpdateRingValue`",`"$status`",`"$message`""
            Add-Content -Path $csvLogPath -Value $csvLine
            
            $results += [PSCustomObject]@{
                ClusterName      = $clusterName
                ResourceGroup    = $resourceGroup
                SubscriptionId   = $subscriptionId
                ResourceId       = $resourceId
                Action           = "Error"
                PreviousTagValue = $previousTagValue
                NewTagValue      = $currentUpdateRingValue
                Status           = $status
                Message          = $_.Exception.Message
            }
        }
    }

    # Summary
    Write-Log -Message "" -Level Info
    Write-Log -Message "========================================" -Level Header
    Write-Log -Message "Summary" -Level Header
    Write-Log -Message "========================================" -Level Header
    
    $created = ($results | Where-Object { $_.Action -eq "Created" -and $_.Status -eq "Success" }).Count
    $updated = ($results | Where-Object { $_.Action -eq "Updated" -and $_.Status -eq "Success" }).Count
    $skipped = ($results | Where-Object { $_.Status -eq "Skipped" }).Count
    $failed = ($results | Where-Object { $_.Status -eq "Failed" }).Count
    
    Write-Log -Message "Total clusters processed: $($results.Count)" -Level Info
    Write-Log -Message "Tags created: $created" -Level $(if ($created -gt 0) { "Success" } else { "Info" })
    Write-Log -Message "Tags updated: $updated" -Level $(if ($updated -gt 0) { "Success" } else { "Info" })
    Write-Log -Message "Skipped (existing tag, no -Force): $skipped" -Level $(if ($skipped -gt 0) { "Warning" } else { "Info" })
    Write-Log -Message "Failed: $failed" -Level $(if ($failed -gt 0) { "Error" } else { "Info" })
    Write-Log -Message "" -Level Info
    Write-Log -Message "CSV log saved to: $csvLogPath" -Level Info
    Write-Log -Message "========================================" -Level Header

    # Display results table
    Write-Host ""
    $results | Format-Table ClusterName, Action, PreviousTagValue, NewTagValue, Status -AutoSize
    
    return $results
}

# Export module members (public functions only)
Export-ModuleMember -Function @(
    'Connect-AzureLocalServicePrincipal',
    'Start-AzureLocalClusterUpdate',
    'Get-AzureLocalClusterUpdateReadiness',
    'Get-AzureLocalClusterInventory',
    'Get-AzureLocalClusterInfo',
    'Get-AzureLocalUpdateSummary',
    'Get-AzureLocalAvailableUpdates',
    'Get-AzureLocalUpdateRuns',
    'Set-AzureLocalClusterUpdateRingTag'
)
