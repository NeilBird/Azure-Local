Function Test-AzLocalAzurePrerequisites {
    <#
    .SYNOPSIS

    Checks Azure prerequisites for Azure Local deployment.

    .DESCRIPTION

    Validates that required Azure resource providers are registered and that the
    deploying identity has the required RBAC role assignments.

    Resource providers that are not registered will be automatically registered
    with a warning message. Registration may take a few minutes to propagate.

    RBAC role assignments are checked on a best-effort basis and reported as
    warnings (advisory) rather than hard failures, because roles may be inherited
    through Azure AD group membership or custom role definitions that cannot be
    reliably detected.

    Reference: https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions

    .PARAMETER SubscriptionId
    The Azure subscription ID to check resource provider registrations against.

    .PARAMETER ResourceGroupName
    The resource group name to check for RBAC role assignments.

    #>

    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 300)]
        [int]$RegistrationPollingIntervalSeconds = 15,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 120)]
        [int]$RegistrationMaxAttempts = 60
    )

    $messages = @()
    $status = 'Passed'

    Write-AzLocalLog "Checking Azure prerequisites (resource providers and RBAC roles)..." -Level Info

    # ---------------------------------------------------------------
    # 1. Resource Provider Registration
    # Reference: https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions
    # ---------------------------------------------------------------
    $requiredProviders = @(
        'Microsoft.HybridCompute',
        'Microsoft.GuestConfiguration',
        'Microsoft.HybridConnectivity',
        'Microsoft.AzureStackHCI',
        'Microsoft.Kubernetes',
        'Microsoft.KubernetesConfiguration',
        'Microsoft.ExtendedLocation',
        'Microsoft.ResourceConnector',
        'Microsoft.HybridContainerService',
        'Microsoft.Attestation',
        'Microsoft.Storage',
        'Microsoft.Insights'
    )

    Write-AzLocalLog "Checking $($requiredProviders.Count) required resource providers..." -Level Info

    $rpFailed = $false
    foreach ($provider in $requiredProviders) {
        try {
            $rp = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
            $regState = $rp[0].RegistrationState

            if ($regState -eq 'Registered') {
                $messages += "Resource provider '$provider': REGISTERED"
                Write-AzLocalLog "Resource provider '$provider': Registered" -Level Success
            } else {
                # Auto-register the missing provider
                Write-AzLocalLog "Resource provider '$provider' is '$regState'. Attempting auto-registration..." -Level Warning
                try {
                    Register-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop | Out-Null
                    Write-AzLocalLog "Resource provider '$provider': Registration requested. Waiting for state 'Registered'..." -Level Warning

                    $registered = $false
                    for ($attempt = 1; $attempt -le $RegistrationMaxAttempts; $attempt++) {
                        Start-Sleep -Seconds $RegistrationPollingIntervalSeconds
                        $rp = Get-AzResourceProvider -ProviderNamespace $provider -ErrorAction Stop
                        $regState = $rp[0].RegistrationState
                        if ($regState -eq 'Registered') {
                            $registered = $true
                            break
                        }
                        Write-Verbose "Resource provider '$provider' registration state is '$regState' (attempt $attempt of $RegistrationMaxAttempts)."
                    }

                    if ($registered) {
                        $messages += "Resource provider '$provider': AUTO-REGISTERED (was not registered)"
                        Write-AzLocalLog "Resource provider '$provider': Registered." -Level Success
                    } else {
                        $messages += "Resource provider '$provider': REGISTRATION TIMED OUT - last state '$regState'"
                        Write-AzLocalLog "Resource provider '$provider': Registration did not reach 'Registered' after $RegistrationMaxAttempts attempts." -Level Error
                        $rpFailed = $true
                    }
                } catch {
                    $messages += "Resource provider '$provider': FAILED TO REGISTER - $($_.Exception.Message)"
                    Write-AzLocalLog "Resource provider '$provider': Failed to register - $($_.Exception.Message)" -Level Error
                    $rpFailed = $true
                }
            }
        } catch {
            $messages += "Resource provider '$provider': ERROR checking status - $($_.Exception.Message)"
            Write-AzLocalLog "Resource provider '$provider': Error checking status - $($_.Exception.Message)" -Level Error
            $rpFailed = $true
        }
    }

    if ($rpFailed) {
        $status = 'Failed'
        $messages += "Resource provider check: FAILED - one or more providers could not be registered."
        Write-AzLocalLog "Resource provider checks FAILED." -Level Error
    } else {
        $messages += "Resource provider check: PASSED - all $($requiredProviders.Count) providers registered."
        Write-AzLocalLog "All $($requiredProviders.Count) required resource providers are registered." -Level Success
    }

    # ---------------------------------------------------------------
    # 2. RBAC Role Assignment Checks (advisory)
    # Reference: https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions
    # ---------------------------------------------------------------
    $subscriptionScope = "/subscriptions/$SubscriptionId"
    $rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"

    $requiredSubRoles = @('Azure Stack HCI Administrator', 'Reader')
    $requiredRgRoles = @(
        'Key Vault Data Access Administrator',
        'Key Vault Secrets Officer',
        'Key Vault Contributor',
        'Storage Account Contributor'
    )

    Write-AzLocalLog "Checking RBAC role assignments for the current identity..." -Level Info

    try {
        $context = Get-AzContext
        $accountId = $context.Account.Id
        $accountType = $context.Account.Type

        Write-AzLocalLog "Current identity: $accountId (Type: $accountType)" -Level Info

        # Get role assignments based on account type
        $subAssignments = @()
        $rgAssignments = @()

        if ($accountType -eq 'User') {
            $subAssignments = @(Get-AzRoleAssignment -SignInName $accountId -Scope $subscriptionScope -ErrorAction Stop)
            $rgAssignments = @(Get-AzRoleAssignment -SignInName $accountId -Scope $rgScope -ErrorAction Stop)
        } else {
            # Service Principal or Managed Identity - resolve Object ID from Application ID
            $sp = Get-AzADServicePrincipal -ApplicationId $accountId -ErrorAction Stop
            if ($sp) {
                $subAssignments = @(Get-AzRoleAssignment -ObjectId $sp.Id -Scope $subscriptionScope -ErrorAction Stop)
                $rgAssignments = @(Get-AzRoleAssignment -ObjectId $sp.Id -Scope $rgScope -ErrorAction Stop)
            }
        }

        $subRoleNames = @($subAssignments | Select-Object -ExpandProperty RoleDefinitionName -Unique)
        $rgRoleNames = @($rgAssignments | Select-Object -ExpandProperty RoleDefinitionName -Unique)

        # Check for Owner (covers all permissions at all child scopes)
        if ($subRoleNames -contains 'Owner') {
            $messages += "RBAC: Identity has 'Owner' at subscription scope (all role requirements satisfied)."
            Write-AzLocalLog "Identity has 'Owner' at subscription scope - all RBAC requirements satisfied." -Level Success
        } else {
            # Check subscription-level roles
            foreach ($role in $requiredSubRoles) {
                if ($subRoleNames -contains $role) {
                    $messages += "RBAC subscription role '$role': ASSIGNED"
                    Write-AzLocalLog "RBAC subscription role '$role': Assigned" -Level Success
                } else {
                    $messages += "RBAC subscription role '$role': NOT FOUND (required for deployment)"
                    Write-AzLocalLog "RBAC subscription role '$role': Not found - required for Azure Local deployment." -Level Warning
                }
            }

            # Check resource-group-level roles (rgAssignments includes inherited from subscription)
            foreach ($role in $requiredRgRoles) {
                if ($rgRoleNames -contains $role) {
                    $messages += "RBAC resource group role '$role': ASSIGNED"
                    Write-AzLocalLog "RBAC resource group role '$role': Assigned" -Level Success
                } else {
                    $messages += "RBAC resource group role '$role': NOT FOUND (required for deployment)"
                    Write-AzLocalLog "RBAC resource group role '$role': Not found - required for Azure Local deployment." -Level Warning
                }
            }
        }

        $messages += "RBAC check: COMPLETE (advisory - see warnings above for any missing roles)."
        Write-AzLocalLog "RBAC role assignment check complete. See above for results." -Level Info
    } catch {
        $messages += "RBAC check: SKIPPED - unable to retrieve role assignments ($($_.Exception.Message)). Verify manually."
        Write-AzLocalLog "Unable to retrieve RBAC role assignments: $($_.Exception.Message). Verify permissions manually." -Level Warning
        Write-AzLocalLog "Reference: https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions" -Level Warning
    }

    return [PSCustomObject]@{
        Status   = $status
        Messages = $messages
    }
}
