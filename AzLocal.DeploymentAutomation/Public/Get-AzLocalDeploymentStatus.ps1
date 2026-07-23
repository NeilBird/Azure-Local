Function Get-AzLocalDeploymentStatus {
    <#
    .SYNOPSIS

    Checks deployment status for all clusters defined in a CSV file.

    .DESCRIPTION

    Reads a cluster deployment CSV file and checks the current ARM deployment status
    for each cluster with ReadyToDeploy = TRUE. Reports the status of each cluster
    and generates JUnit XML output for CI/CD pipeline visibility.

    Designed to be called by a monitoring pipeline on a schedule (e.g., every 15 minutes)
    to track the progress of long-running Azure Local deployments.

    Status categories:
    - NotStarted: No deployment found for this cluster
    - ValidateInProgress: Validation deployment is running
    - ValidateSucceeded: Validation completed successfully (ready for Deploy)
    - ValidateFailed: Validation failed
    - DeployInProgress: Deploy deployment is running
    - DeploySucceeded: Deployment completed successfully
    - DeployFailed: Deployment failed
    - ClusterExists: Cluster resource already exists

    .PARAMETER CsvFilePath
    Path to the cluster deployments CSV file.

    .PARAMETER JUnitOutputPath
    Optional. Path to write JUnit XML test results.

    .PARAMETER LogFilePath
    Optional. Path to a log file for diagnostic output.

    .PARAMETER HtmlOutputPath
    Optional. Path to write an HTML deployment status report.

    .PARAMETER MarkdownOutputPath
    Optional. Path to write a Markdown deployment status report (for GitHub Step Summary or Azure DevOps).

    .PARAMETER ReportTitle
    Optional. Title displayed in the HTML/Markdown report header.
    Default: 'Azure Local Deployment Status Report'.

    .EXAMPLE
    Get-AzLocalDeploymentStatus -CsvFilePath './automation-pipelines/cluster-deployments.csv'

    .EXAMPLE
    Get-AzLocalDeploymentStatus -CsvFilePath './automation-pipelines/cluster-deployments.csv' -JUnitOutputPath './reports/status.xml'

    .EXAMPLE
    Get-AzLocalDeploymentStatus -CsvFilePath './automation-pipelines/cluster-deployments.csv' -HtmlOutputPath './reports/status.html' -MarkdownOutputPath './reports/status.md'

    #>

    [OutputType([PSCustomObject[]])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$CsvFilePath,

        [Parameter(Mandatory = $false)]
        [string]$JUnitOutputPath = "",

        [Parameter(Mandatory = $false)]
        [string]$LogFilePath = "",

        [Parameter(Mandatory = $false)]
        [string]$HtmlOutputPath = "",

        [Parameter(Mandatory = $false)]
        [string]$MarkdownOutputPath = "",

        [Parameter(Mandatory = $false)]
        [string]$ReportTitle = "Azure Local Deployment Status Report",

        # --- Optional: path to a custom naming-standards-config.json file ---
        # (Overrides the default user profile and module config file resolution)
        [Parameter(Mandatory = $false)]
        [string]$NamingConfigPath = ""
    )

    # Reset module-scoped log path (prevents bleed-over from previous function calls)
    $script:AzLocalLogFilePath = $null

    # Initialise log file if specified
    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        Initialize-AzLocalLogFile -LogFilePath $LogFilePath
    }

    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
    Write-AzLocalLog "  Deployment Status Monitor" -Level Info -NoTimestamp
    Write-AzLocalLog "  CSV File: $CsvFilePath" -Level Info -NoTimestamp
    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp

    # Load naming configuration (user profile, explicit path, or module default)
    $configResult = Get-AzLocalNamingConfig -Path $NamingConfigPath
    $NamingConfig = $configResult.Config
    $resolvedConfigPath = $configResult.ResolvedPath

    # Validate the config has been customised from shipped defaults
    Test-AzLocalNamingConfigDefaults -Config $NamingConfig -ConfigFilePath $resolvedConfigPath

    # Import CSV (ReadyToDeploy = TRUE only)
    # Wrap in @() to ensure array even for single-row CSV (PS 5.1 + StrictMode compatibility)
    $clusters = @(Import-AzLocalDeploymentCsv -CsvFilePath $CsvFilePath -ReadyOnly)

    if ($clusters.Count -eq 0) {
        Write-AzLocalLog "No clusters with ReadyToDeploy = TRUE found in CSV." -Level Warning
        return @()
    }

    Write-AzLocalLog "Checking status for $($clusters.Count) cluster(s)." -Level Info

    $allResults = New-Object 'System.Collections.Generic.List[object]'

    foreach ($cluster in $clusters) {
        $uniqueID = $cluster.UniqueID
        $startTime = Get-Date

        # Resolve resource names
        $resourceGroupName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.resourceGroupName -UniqueID $uniqueID
        $clusterName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.clusterName -UniqueID $uniqueID
        $deploymentName = Resolve-AzLocalResourceName -Pattern $NamingConfig.namingStandards.deploymentName -UniqueID $uniqueID -TypeOfDeployment $cluster.TypeOfDeployment

        Write-AzLocalLog "Checking: $uniqueID (RG: $resourceGroupName, Deployment: $deploymentName)" -Level Info

        # Set subscription context
        try {
            Set-AzContext -SubscriptionId $cluster.SubscriptionId -TenantId $cluster.TenantId -ErrorAction Stop | Out-Null
        } catch {
            $allResults.Add([PSCustomObject]@{
                UniqueID          = $uniqueID
                ClusterName       = $clusterName
                ResourceGroupName = $resourceGroupName
                DeploymentName    = $deploymentName
                DeploymentStatus  = 'ContextError'
                ProvisioningState = 'N/A'
                Message           = "Failed to set Azure context: $($_.Exception.Message)"
                Duration          = 0
            }) | Out-Null
            continue
        }

        # Check if cluster already exists
        $clusterResourceId = "/subscriptions/$($cluster.SubscriptionId)/resourceGroups/$resourceGroupName/providers/Microsoft.AzureStackHCI/clusters/$clusterName"
        $existingCluster = $null
        try {
            # Existence-aware lookup: $null means genuinely absent; a real failure
            # (unsupported api-version, auth, RBAC, transport) throws with the real
            # reason instead of being masked as "does not exist".
            $existingCluster = Get-AzLocalArmResource -ResourceId $clusterResourceId -ResourceKind 'cluster'
        } catch {
            $duration = ((Get-Date) - $startTime).TotalSeconds
            Write-AzLocalLog "  ${uniqueID}: Error checking cluster existence - $($_.Exception.Message)" -Level Error
            $allResults.Add([PSCustomObject]@{
                UniqueID          = $uniqueID
                ClusterName       = $clusterName
                ResourceGroupName = $resourceGroupName
                DeploymentName    = $deploymentName
                DeploymentStatus  = 'CheckError'
                ProvisioningState = 'N/A'
                Message           = "Failed to check cluster existence: $($_.Exception.Message)"
                Duration          = [math]::Round($duration, 2)
            }) | Out-Null
            continue
        }
        if ($existingCluster) {
            $duration = ((Get-Date) - $startTime).TotalSeconds
            Write-AzLocalLog "  ${uniqueID}: Cluster already exists." -Level Success
            $allResults.Add([PSCustomObject]@{
                UniqueID          = $uniqueID
                ClusterName       = $clusterName
                ResourceGroupName = $resourceGroupName
                DeploymentName    = $deploymentName
                DeploymentStatus  = 'ClusterExists'
                ProvisioningState = 'Succeeded'
                Message           = "Cluster '$clusterName' exists in resource group '$resourceGroupName'."
                Duration          = [math]::Round($duration, 2)
            }) | Out-Null
            continue
        }

        # Check resource group exists
        $rg = $null
        try {
            $rg = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction Stop
        } catch {
            if (-not (Test-AzLocalNotFoundError -ErrorRecord $_ -ErrorCode @('ResourceGroupNotFound', 'ResourceNotFound'))) {
                $duration = ((Get-Date) - $startTime).TotalSeconds
                Write-AzLocalLog "  ${uniqueID}: Error checking resource group - $($_.Exception.Message)" -Level Error
                $allResults.Add([PSCustomObject]@{
                    UniqueID          = $uniqueID
                    ClusterName       = $clusterName
                    ResourceGroupName = $resourceGroupName
                    DeploymentName    = $deploymentName
                    DeploymentStatus  = 'CheckError'
                    ProvisioningState = 'N/A'
                    Message           = "Failed to check resource group existence: $($_.Exception.Message)"
                    Duration          = [math]::Round($duration, 2)
                }) | Out-Null
                continue
            }
        }
        if (-not $rg) {
            $duration = ((Get-Date) - $startTime).TotalSeconds
            Write-AzLocalLog "  ${uniqueID}: Resource group not found." -Level Warning
            $allResults.Add([PSCustomObject]@{
                UniqueID          = $uniqueID
                ClusterName       = $clusterName
                ResourceGroupName = $resourceGroupName
                DeploymentName    = $deploymentName
                DeploymentStatus  = 'NotStarted'
                ProvisioningState = 'N/A'
                Message           = "Resource group '$resourceGroupName' does not exist."
                Duration          = [math]::Round($duration, 2)
            }) | Out-Null
            continue
        }

        # Check deployment status
        $deployment = $null
        try {
            $deployment = Get-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName -Name $deploymentName -ErrorAction Stop
        } catch {
            if (-not (Test-AzLocalNotFoundError -ErrorRecord $_ -ErrorCode @('ResourceGroupDeploymentNotFound', 'DeploymentNotFound', 'ResourceNotFound'))) {
                $duration = ((Get-Date) - $startTime).TotalSeconds
                Write-AzLocalLog "  ${uniqueID}: Error checking deployment status - $($_.Exception.Message)" -Level Error
                $allResults.Add([PSCustomObject]@{
                    UniqueID          = $uniqueID
                    ClusterName       = $clusterName
                    ResourceGroupName = $resourceGroupName
                    DeploymentName    = $deploymentName
                    DeploymentStatus  = 'CheckError'
                    ProvisioningState = 'N/A'
                    Message           = "Failed to check deployment status: $($_.Exception.Message)"
                    Duration          = [math]::Round($duration, 2)
                }) | Out-Null
                continue
            }
        }
        $duration = ((Get-Date) - $startTime).TotalSeconds

        if (-not $deployment) {
            Write-AzLocalLog "  ${uniqueID}: No deployment found." -Level Info
            $allResults.Add([PSCustomObject]@{
                UniqueID          = $uniqueID
                ClusterName       = $clusterName
                ResourceGroupName = $resourceGroupName
                DeploymentName    = $deploymentName
                DeploymentStatus  = 'NotStarted'
                ProvisioningState = 'N/A'
                Message           = "No deployment '$deploymentName' found."
                Duration          = [math]::Round($duration, 2)
            }) | Out-Null
            continue
        }

        $provState = $deployment.ProvisioningState
        $deploymentDuration = if ($deployment.PSObject.Properties['Duration'] -and $deployment.Duration) { $deployment.Duration.ToString() } else { "N/A" }

        # Determine deployment status category
        # Check the deploymentMode parameter in the deployment to know if it was a Validate or Deploy
        $deployedMode = 'Unknown'
        try {
            $modeParam = $deployment.Parameters['deploymentMode']
            if ($modeParam) { $deployedMode = $modeParam.Value }
        } catch { }

        $statusCategory = switch ($provState) {
            'Running'   { if ($deployedMode -eq 'Deploy') { 'DeployInProgress' } else { 'ValidateInProgress' } }
            'Accepted'  { if ($deployedMode -eq 'Deploy') { 'DeployInProgress' } else { 'ValidateInProgress' } }
            'Succeeded' { if ($deployedMode -eq 'Deploy') { 'DeploySucceeded' }  else { 'ValidateSucceeded' } }
            'Failed'    { if ($deployedMode -eq 'Deploy') { 'DeployFailed' }     else { 'ValidateFailed' } }
            'Canceled'  { if ($deployedMode -eq 'Deploy') { 'DeployCanceled' }   else { 'ValidateCanceled' } }
            default     { $provState }
        }

        $levelColour = switch ($statusCategory) {
            'ValidateSucceeded' { 'Success' }
            'DeploySucceeded'   { 'Success' }
            'ValidateInProgress' { 'Warning' }
            'DeployInProgress'  { 'Warning' }
            default             { 'Error' }
        }

        Write-AzLocalLog "  ${uniqueID}: $statusCategory (ARM Duration: $deploymentDuration)" -Level $levelColour

        $allResults.Add([PSCustomObject]@{
            UniqueID          = $uniqueID
            ClusterName       = $clusterName
            ResourceGroupName = $resourceGroupName
            DeploymentName    = $deploymentName
            DeploymentStatus  = $statusCategory
            ProvisioningState = $provState
            Message           = "Deployment '$deploymentName' state: $provState (Mode: $deployedMode, Duration: $deploymentDuration)"
            Duration          = [math]::Round($duration, 2)
        }) | Out-Null
    }

    # Generate JUnit XML report
    if (-not [string]::IsNullOrWhiteSpace($JUnitOutputPath)) {
        $junitResults = foreach ($r in $allResults) {
            $testStatus = switch ($r.DeploymentStatus) {
                'DeploySucceeded'    { 'Passed' }
                'ValidateSucceeded'  { 'Passed' }
                'ClusterExists'      { 'Passed' }
                'NotStarted'         { 'Skipped' }
                'ValidateInProgress' { 'Skipped' }
                'DeployInProgress'   { 'Skipped' }
                default              { 'Failed' }
            }
            [PSCustomObject]@{
                TestName  = "Status-$($r.UniqueID)"
                ClassName = "AzLocalDeploymentAutomation.Monitor"
                Status    = $testStatus
                Message   = $r.Message
                Duration  = $r.Duration
            }
        }
        New-AzLocalJUnitXml -TestResults $junitResults -SuiteName 'AzLocalDeployment-Monitor' -OutputPath $JUnitOutputPath
    }

    # Generate HTML / Markdown reports
    if (-not [string]::IsNullOrWhiteSpace($HtmlOutputPath) -or -not [string]::IsNullOrWhiteSpace($MarkdownOutputPath)) {
        New-AzLocalDeploymentReport -StatusResults $allResults `
            -HtmlOutputPath $HtmlOutputPath `
            -MarkdownOutputPath $MarkdownOutputPath `
            -ReportTitle $ReportTitle | Out-Null
    }

    # Summary
    $statusGroups = $allResults | Group-Object -Property DeploymentStatus
    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
    Write-AzLocalLog "  Deployment Status Summary" -Level Info -NoTimestamp
    foreach ($group in $statusGroups) {
        Write-AzLocalLog "  $($group.Name): $($group.Count)" -Level Info -NoTimestamp
    }
    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp

    return $allResults.ToArray()
}
