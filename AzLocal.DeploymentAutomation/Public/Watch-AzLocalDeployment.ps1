Function Watch-AzLocalDeployment {
    <#
    .SYNOPSIS

    Monitors an Azure Local ARM deployment by polling for status changes.

    .DESCRIPTION

    Periodically polls an Azure Resource Group deployment and displays status transitions
    with timestamps. Useful for monitoring long-running Azure Local cluster validation or
    deployment operations from the same or a separate PowerShell session.

    The function will poll until the deployment reaches a terminal state (Succeeded, Failed,
    or Canceled), or until the optional -TimeoutMinutes limit is reached.

    When used with -PassThru, returns the final deployment object which can be inspected
    or passed to subsequent commands.

    .PARAMETER DeploymentName
    The name of the ARM deployment to monitor.

    .PARAMETER ResourceGroupName
    The name of the resource group containing the deployment.

    .PARAMETER PollingIntervalSeconds
    How often (in seconds) to poll for status changes. Default: 30 seconds.

    .PARAMETER TimeoutMinutes
    Optional. Maximum time (in minutes) to monitor before stopping. Default: 0 (no timeout).

    .PARAMETER PassThru
    If specified, returns the final deployment object when monitoring completes.

    .PARAMETER LogFilePath
    Optional. Path to a log file for debug/diagnostic output.

    .EXAMPLE
    Watch-AzLocalDeployment -DeploymentName "deploy-S001-SingleNode" -ResourceGroupName "rg-S001-azurelocal-prod"

    .EXAMPLE
    Watch-AzLocalDeployment -DeploymentName "deploy-S001-SingleNode" -ResourceGroupName "rg-S001-azurelocal-prod" -PollingIntervalSeconds 60 -TimeoutMinutes 120

    .EXAMPLE
    $deployment = Watch-AzLocalDeployment -DeploymentName "deploy-S001-SingleNode" -ResourceGroupName "rg-S001-azurelocal-prod" -PassThru

    #>

    [OutputType('Microsoft.Azure.Commands.ResourceManager.Cmdlets.SdkModels.PSResourceGroupDeployment')]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$DeploymentName,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [ValidateRange(10, 600)]
        [int]$PollingIntervalSeconds = 30,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 1440)]
        [int]$TimeoutMinutes = 0,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru,

        # Skip searching the Azure Local Supportability TSG repository on failure
        # (Online TSG search is enabled by default; use this switch to disable it)
        [Parameter(Mandatory = $false)]
        [switch]$SkipOnlineTSGSearch,

        [Parameter(Mandatory = $false)]
        [string]$LogFilePath = ""
    )

    # Reset module-scoped log path (prevents bleed-over from previous function calls)
    $script:AzLocalLogFilePath = $null

    # Initialise log file if specified
    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        Initialize-AzLocalLogFile -LogFilePath $LogFilePath
    }

    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
    Write-AzLocalLog "  Monitoring Deployment: $DeploymentName" -Level Info -NoTimestamp
    Write-AzLocalLog "  Resource Group: $ResourceGroupName" -Level Info -NoTimestamp
    Write-AzLocalLog "  Polling Interval: ${PollingIntervalSeconds}s" -Level Info -NoTimestamp
    if ($TimeoutMinutes -gt 0) {
        Write-AzLocalLog "  Timeout: ${TimeoutMinutes} minutes" -Level Info -NoTimestamp
    }
    Write-AzLocalLog "========================================================" -Level Info -NoTimestamp

    $terminalStates = @("Succeeded", "Failed", "Canceled")
    $previousStatus = ""
    $startTime = Get-Date
    $statusHistory = @()

    # Initial deployment lookup
    try {
        $deployment = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $DeploymentName -ErrorAction Stop
    } catch {
        Write-AzLocalLog "Unable to find deployment '$DeploymentName' in resource group '$ResourceGroupName'." -Level Error
        Write-AzLocalLog "$($_.Exception.Message)" -Level Error
        throw "Deployment '$DeploymentName' not found in resource group '$ResourceGroupName'. $($_.Exception.Message)"
    }

    Write-AzLocalLog "Deployment found. Current state: $($deployment.ProvisioningState)" -Level Success
    $previousStatus = $deployment.ProvisioningState
    $statusHistory += [PSCustomObject]@{
        Timestamp = Get-Date
        Status    = $deployment.ProvisioningState
    }

    # Check if the deployment is already in a terminal state
    if ($deployment.ProvisioningState -in $terminalStates) {
        Write-AzLocalLog "Deployment is already in terminal state: $($deployment.ProvisioningState)" -Level Warning
        if ($deployment.PSObject.Properties['Duration'] -and $deployment.Duration) {
            Write-AzLocalLog "  Duration: $($deployment.Duration)" -Level Verbose
        }

        if ($PassThru) { return $deployment }
        return
    }

    Write-AzLocalLog "Polling every $PollingIntervalSeconds seconds. Press Ctrl+C to stop monitoring." -Level Verbose

    # Polling loop
    $consecutiveFailures = 0
    while ($true) {

        # Check timeout
        if ($TimeoutMinutes -gt 0) {
            $elapsed = (Get-Date) - $startTime
            if ($elapsed.TotalMinutes -ge $TimeoutMinutes) {
                Write-AzLocalLog "Timeout reached after $TimeoutMinutes minutes. Stopping monitor." -Level Warning
                Write-AzLocalLog "  Last known state: $previousStatus" -Level Warning
                break
            }
        }

        # Wait before next poll
        Start-Sleep -Seconds $PollingIntervalSeconds

        # Poll deployment status
        try {
            $deployment = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $DeploymentName -ErrorAction Stop
            $consecutiveFailures = 0
        } catch {
            $consecutiveFailures++
            Write-AzLocalLog "Failed to poll deployment status (attempt $consecutiveFailures): $($_.Exception.Message)" -Level Warning
            if ($consecutiveFailures -ge 10) {
                Write-AzLocalLog "Polling failed 10 consecutive times. Stopping monitor." -Level Error
                throw "Deployment polling failed after 10 consecutive attempts. Last error: $($_.Exception.Message)"
            }
            continue
        }

        $currentStatus = $deployment.ProvisioningState
        $elapsedTime = (Get-Date) - $startTime

        # Display status change or heartbeat
        if ($currentStatus -ne $previousStatus) {
            # Status changed
            Write-AzLocalLog "Status changed: $previousStatus -> $currentStatus (elapsed: $($elapsedTime.ToString('hh\:mm\:ss')))" -Level Info
            $statusHistory += [PSCustomObject]@{
                Timestamp = Get-Date
                Status    = $currentStatus
            }
            $previousStatus = $currentStatus
        } else {
            # No change - heartbeat
            Write-AzLocalLog "Status: $currentStatus (elapsed: $($elapsedTime.ToString('hh\:mm\:ss')))" -Level Verbose
        }

        # Check for terminal state
        if ($currentStatus -in $terminalStates) {

            $totalElapsed = (Get-Date) - $startTime

            $finalLevel = if ($currentStatus -eq 'Succeeded') { 'Success' } elseif ($currentStatus -eq 'Failed') { 'Error' } else { 'Warning' }

            Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
            Write-AzLocalLog "  Deployment Complete" -Level Info -NoTimestamp
            Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
            Write-AzLocalLog "  Deployment: $DeploymentName" -Level Info -NoTimestamp
            Write-AzLocalLog "  Final State: $currentStatus" -Level $finalLevel -NoTimestamp
            Write-AzLocalLog "  Total Monitoring Time: $($totalElapsed.ToString('hh\:mm\:ss'))" -Level Info -NoTimestamp
            if ($deployment.PSObject.Properties['Duration'] -and $deployment.Duration) {
                Write-AzLocalLog "  ARM Deployment Duration: $($deployment.Duration)" -Level Info -NoTimestamp
            }

            # Show status history
            Write-AzLocalLog "  Status History:" -Level Verbose
            foreach ($entry in $statusHistory) {
                Write-AzLocalLog "    [$($entry.Timestamp.ToString('HH:mm:ss'))] $($entry.Status)" -Level Verbose
            }

            if ($currentStatus -eq "Succeeded") {
                Write-AzLocalLog "Deployment succeeded. If this was a Validate phase, you can now re-submit with deploymentMode set to 'Deploy'." -Level Success
                Write-Verbose "Ref: https://learn.microsoft.com/en-us/azure/azure-local/deploy/deployment-azure-resource-manager-template"
            } elseif ($currentStatus -eq "Failed") {
                Write-AzLocalLog "Deployment failed. Check the Azure Portal for detailed error information." -Level Error
                # Attempt to display error details if available
                $troubleshootErrorText = ""
                if ($deployment.PSObject.Properties['Error'] -and $deployment.Error) {
                    Write-AzLocalLog "  Error Code: $($deployment.Error.Code)" -Level Error -NoTimestamp
                    Write-AzLocalLog "  Error Message: $($deployment.Error.Message)" -Level Error -NoTimestamp
                    $troubleshootErrorText = "$($deployment.Error.Code) $($deployment.Error.Message)"
                    if ($deployment.Error.PSObject.Properties['Details'] -and $deployment.Error.Details) {
                        foreach ($errDetail in $deployment.Error.Details) {
                            $troubleshootErrorText += " $($errDetail.Code) $($errDetail.Message)"
                        }
                    }
                }
                # Provide troubleshooting hints for common validation/deployment failures
                if (-not [string]::IsNullOrWhiteSpace($troubleshootErrorText)) {
                    $troubleshootParams = @{ ErrorText = $troubleshootErrorText }
                    if (-not $SkipOnlineTSGSearch) { $troubleshootParams['SearchOnline'] = $true }
                    Get-AzLocalValidationTroubleshootingHints @troubleshootParams
                }
            }

            break
        }
    }

    if ($PassThru) { return $deployment }
}
