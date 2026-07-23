Function Start-AzLocalCsvDeployment {
    <#
    .SYNOPSIS

    Drives Azure Local cluster deployments from a CSV file for CI/CD pipelines.

    .DESCRIPTION

    Reads a CSV file containing cluster deployment definitions, runs pre-flight checks
    (Arc node registration, resource group existence, naming validation, existing deployment
    detection), and then calls Start-AzLocalTemplateDeployment for each eligible cluster.

    Only clusters with ReadyToDeploy = TRUE are processed. Clusters that are already deployed,
    have deployments in-progress, or fail pre-flight checks are skipped with detailed reporting.

    Generates JUnit XML output for CI/CD pipeline test result visualization.

    .PARAMETER CsvFilePath
    Path to the cluster deployments CSV file.

    .PARAMETER DeploymentMode
    The ARM deployment mode: Validate (validate only) or Deploy (deploy only).
    Use separate pipeline stages for Validate then Deploy.

    .PARAMETER JUnitOutputPath
    Optional. Path to write JUnit XML test results.

    .PARAMETER LogFilePath
    Optional. Path to a log file for diagnostic output.

    .EXAMPLE
    Start-AzLocalCsvDeployment -CsvFilePath './automation-pipelines/cluster-deployments.csv' -DeploymentMode Validate

    .EXAMPLE
    Start-AzLocalCsvDeployment -CsvFilePath './automation-pipelines/cluster-deployments.csv' -DeploymentMode Deploy -JUnitOutputPath './reports/deploy-results.xml'

    #>

    [OutputType([PSCustomObject[]])]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$CsvFilePath,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet("Validate", "Deploy")]
        [string]$DeploymentMode,

        [Parameter(Mandatory = $false)]
        [string]$JUnitOutputPath = "",

        [Parameter(Mandatory = $false)]
        [string]$LogFilePath = "",

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
    Write-AzLocalLog "  CSV-Driven Deployment: $DeploymentMode" -Level Info -NoTimestamp
    Write-AzLocalLog "  CSV File: $CsvFilePath" -Level Info -NoTimestamp
    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp

    # Load naming configuration (user profile, explicit path, or module default)
    $configResult = Get-AzLocalNamingConfig -Path $NamingConfigPath
    $NamingConfig = $configResult.Config
    $resolvedConfigPath = $configResult.ResolvedPath

    # Validate the config has been customised from shipped defaults
    Test-AzLocalNamingConfigDefaults -Config $NamingConfig -ConfigFilePath $resolvedConfigPath

    # Import and validate CSV (ReadyToDeploy = TRUE only)
    # Wrap in @() to ensure array even for single-row CSV (PS 5.1 + StrictMode compatibility)
    $clusters = @(Import-AzLocalDeploymentCsv -CsvFilePath $CsvFilePath -ReadyOnly)

    if ($clusters.Count -eq 0) {
        Write-AzLocalLog "No clusters with ReadyToDeploy = TRUE found in CSV." -Level Warning
        $emptyResult = @([PSCustomObject]@{
            TestName  = 'NoClustersReady'
            ClassName = 'AzLocalDeploymentAutomation.PreFlight'
            Status    = 'Skipped'
            Message   = 'No clusters with ReadyToDeploy = TRUE in CSV file.'
            Duration  = 0
        })
        if (-not [string]::IsNullOrWhiteSpace($JUnitOutputPath)) {
            New-AzLocalJUnitXml -TestResults $emptyResult -SuiteName "AzLocalDeployment-$DeploymentMode" -OutputPath $JUnitOutputPath
        }
        return $emptyResult
    }

    Write-AzLocalLog "Processing $($clusters.Count) cluster(s) with ReadyToDeploy = TRUE." -Level Success

    $allResults = New-Object 'System.Collections.Generic.List[object]'

    foreach ($cluster in $clusters) {
        $uniqueID = $cluster.UniqueID
        Write-AzLocalLog "--------------------------------------------------------" -Level Info -NoTimestamp
        Write-AzLocalLog "  Processing: $uniqueID ($($cluster.TypeOfDeployment))" -Level Info -NoTimestamp
        Write-AzLocalLog "--------------------------------------------------------" -Level Info -NoTimestamp

        # Set subscription context
        try {
            Set-AzContext -SubscriptionId $cluster.SubscriptionId -TenantId $cluster.TenantId -ErrorAction Stop | Out-Null
            Write-AzLocalLog "Azure context set to subscription '$($cluster.SubscriptionId)'." -Level Success
        } catch {
            Write-AzLocalLog "Failed to set Azure context for ${uniqueID}: $($_.Exception.Message)" -Level Error
            $allResults.Add([PSCustomObject]@{
                TestName  = "PreFlight-$uniqueID"
                ClassName = "AzLocalDeploymentAutomation.PreFlight"
                Status    = 'Failed'
                Message   = "Failed to set Azure context: $($_.Exception.Message)"
                Duration  = 0
            }) | Out-Null
            continue
        }

        # Run pre-flight checks
        $preFlightResult = Test-AzLocalClusterPreFlight -ClusterRow $cluster -NamingConfig $NamingConfig -DeploymentMode $DeploymentMode

        # Record pre-flight result
        $allResults.Add([PSCustomObject]@{
            TestName  = "PreFlight-$uniqueID"
            ClassName = "AzLocalDeploymentAutomation.PreFlight"
            Status    = $preFlightResult.Status
            Message   = ($preFlightResult.Messages -join "`n")
            Duration  = $preFlightResult.Duration
        }) | Out-Null

        # Only proceed to deployment if pre-flight passed
        if ($preFlightResult.Status -ne 'Passed') {
            Write-AzLocalLog "Pre-flight $($preFlightResult.Status) for $uniqueID. Skipping deployment." -Level Warning
            continue
        }

        Write-AzLocalLog "Pre-flight PASSED for $uniqueID. Starting $DeploymentMode deployment..." -Level Success

        # Build network settings JSON from CSV columns
        $nodeIPs = @($cluster.NodeIPAddresses -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        $networkHash = @{
            subnetMask        = $cluster.SubnetMask
            defaultGateway    = $cluster.DefaultGateway
            startingIPAddress = $cluster.StartingIPAddress
            endingIPAddress   = $cluster.EndingIPAddress
            nodeIPAddresses   = $nodeIPs
        }
        # Disaggregated: include sanSettings block from CSV columns
        if ($cluster.TypeOfDeployment -eq 'Disaggregated') {
            $sanVlan = 0
            [void][int]::TryParse($cluster.SanNetworkVlanId, [ref]$sanVlan)
            $networkHash['sanSettings'] = @{
                infraVolLunId           = $cluster.InfraVolLunId
                infraPerfLunId          = $cluster.InfraPerfLunId
                sanNetworkAdapterName   = $cluster.SanNetworkAdapterName
                sanNetworkVlanId        = $sanVlan
                sanNetworkAddressPrefix = $cluster.SanNetworkAddressPrefix
            }
        }
        $networkJson = $networkHash | ConvertTo-Json -Compress -Depth 5

        # Build deployment parameters
        $deployParams = @{
            SubscriptionId       = $cluster.SubscriptionId
            TypeOfDeployment     = $cluster.TypeOfDeployment
            TenantId             = $cluster.TenantId
            DeploymentMode       = $DeploymentMode
            UniqueID             = $uniqueID
            NetworkSettingsJson  = $networkJson
            CredentialKeyVaultName = $cluster.CredentialKeyVaultName
            SkipPreFlightChecks  = $true
            Confirm              = $false
        }

        # Optional parameters from CSV
        $nodeCount = [int]$cluster.NodeCount
        if ($nodeCount -gt 0) { $deployParams['NodeCount'] = $nodeCount }

        if ($cluster.PSObject.Properties['Location'] -and -not [string]::IsNullOrWhiteSpace($cluster.Location)) {
            $deployParams['Location'] = $cluster.Location
        }

        if ($cluster.PSObject.Properties['DnsServers'] -and -not [string]::IsNullOrWhiteSpace($cluster.DnsServers)) {
            $deployParams['DnsServers'] = @($cluster.DnsServers -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        }

        if ($cluster.PSObject.Properties['LocalAdminSecretName'] -and -not [string]::IsNullOrWhiteSpace($cluster.LocalAdminSecretName)) {
            $deployParams['LocalAdminSecretName'] = $cluster.LocalAdminSecretName
        }

        if ($cluster.PSObject.Properties['LCMAdminSecretName'] -and -not [string]::IsNullOrWhiteSpace($cluster.LCMAdminSecretName)) {
            $deployParams['LCMAdminSecretName'] = $cluster.LCMAdminSecretName
        }

        if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
            $deployParams['LogFilePath'] = $LogFilePath
        }

        # Always forward the resolved config path so template deployment skips re-resolution
        $deployParams['NamingConfigPath'] = $resolvedConfigPath

        # Execute deployment
        $deployStartTime = Get-Date
        try {
            if ($PSCmdlet.ShouldProcess("Cluster '$uniqueID'", "$DeploymentMode deployment")) {
                $deploymentResult = Start-AzLocalTemplateDeployment @deployParams
                $deployDuration = ((Get-Date) - $deployStartTime).TotalSeconds

                if ($deploymentResult -and $deploymentResult.ProvisioningState -eq 'Succeeded') {
                    $allResults.Add([PSCustomObject]@{
                        TestName  = "$DeploymentMode-$uniqueID"
                        ClassName = "AzLocalDeploymentAutomation.$DeploymentMode"
                        Status    = 'Passed'
                        Message   = "$DeploymentMode succeeded for cluster '$uniqueID'. Duration: $($deploymentResult.Duration)"
                        Duration  = [math]::Round($deployDuration, 2)
                    }) | Out-Null
                    Write-AzLocalLog "$DeploymentMode SUCCEEDED for $uniqueID." -Level Success
                } else {
                    $provState = if ($deploymentResult) { $deploymentResult.ProvisioningState } else { "Unknown" }
                    $allResults.Add([PSCustomObject]@{
                        TestName  = "$DeploymentMode-$uniqueID"
                        ClassName = "AzLocalDeploymentAutomation.$DeploymentMode"
                        Status    = 'Failed'
                        Message   = "$DeploymentMode failed for cluster '$uniqueID'. ProvisioningState: $provState"
                        Duration  = [math]::Round($deployDuration, 2)
                    }) | Out-Null
                    Write-AzLocalLog "$DeploymentMode FAILED for $uniqueID (State: $provState)." -Level Error
                }
            } else {
                $allResults.Add([PSCustomObject]@{
                    TestName  = "$DeploymentMode-$uniqueID"
                    ClassName = "AzLocalDeploymentAutomation.$DeploymentMode"
                    Status    = 'Skipped'
                    Message   = "$DeploymentMode skipped by user (WhatIf/Confirm)."
                    Duration  = 0
                }) | Out-Null
            }
        } catch {
            $deployDuration = ((Get-Date) - $deployStartTime).TotalSeconds
            $allResults.Add([PSCustomObject]@{
                TestName  = "$DeploymentMode-$uniqueID"
                ClassName = "AzLocalDeploymentAutomation.$DeploymentMode"
                Status    = 'Failed'
                Message   = "$DeploymentMode failed for cluster '$uniqueID': $($_.Exception.Message)"
                Duration  = [math]::Round($deployDuration, 2)
            }) | Out-Null
            Write-AzLocalLog "$DeploymentMode FAILED for ${uniqueID}: $($_.Exception.Message)" -Level Error
        }
    }

    # Generate JUnit XML report
    if (-not [string]::IsNullOrWhiteSpace($JUnitOutputPath)) {
        New-AzLocalJUnitXml -TestResults $allResults -SuiteName "AzLocalDeployment-$DeploymentMode" -OutputPath $JUnitOutputPath
    }

    # Summary
    $passed = @($allResults | Where-Object { $_.Status -eq 'Passed' }).Count
    $failed = @($allResults | Where-Object { $_.Status -eq 'Failed' }).Count
    $skipped = @($allResults | Where-Object { $_.Status -eq 'Skipped' }).Count

    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
    Write-AzLocalLog "  $DeploymentMode Summary" -Level Info -NoTimestamp
    Write-AzLocalLog "  Passed: $passed | Failed: $failed | Skipped: $skipped" -Level Info -NoTimestamp
    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp

    return $allResults.ToArray()
}
