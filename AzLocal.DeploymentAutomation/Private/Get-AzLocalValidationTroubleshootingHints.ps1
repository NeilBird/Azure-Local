Function Get-AzLocalValidationTroubleshootingHints {
    <#
    .SYNOPSIS

    Analyzes deployment or validation error text and provides actionable troubleshooting hints.

    .DESCRIPTION

    Checks error codes and messages against a library of known Azure Local deployment failure
    patterns and returns targeted remediation guidance. When -SearchOnline is specified, also
    searches the Azure Local Supportability TSG repository on GitHub for matching
    troubleshooting guides.

    Known patterns cover:
    - Network adapter mismatches (NetworkIntentValidationFailed)
    - RDMA operational status failures (NetAdapter_RDMA_Operational)
    - Inbox NIC driver detection (InboxDriver / DriverProvider Microsoft)
    - Management intent naming issues (vManagement double-wrap)
    - GPO inheritance block requirements (OuGpoInheritance)
    - Duplicate RBAC role assignments (RoleAssignmentExists / Conflict)
    - Physical disk / Storage Spaces Direct validation failures
    - Resource Provider registration failures (MandatoryRPRegistration / ValidateArcIntegration)
    - Deployment settings validation timeout (OperationTimeout)
    - General deployment settings validation failures (UpdateDeploymentSettingsDataFailed)

    .PARAMETER ErrorText
    The combined error code(s) and message(s) to analyze. Typically the concatenation of
    the ARM error code, message, and any inner error details.

    .PARAMETER SearchOnline
    When specified, searches the Azure Local Supportability GitHub repository
    (https://github.com/Azure/AzureLocal-Supportability) for troubleshooting guides
    whose filenames match keywords extracted from the error text.
    Requires internet connectivity; fails gracefully if unavailable.

    .OUTPUTS
    [PSCustomObject[]] - Array of hint objects with Source, Title, Description, Remediation, and Reference properties.
    Also writes formatted hints to the console via Write-AzLocalLog.

    .EXAMPLE
    Get-AzLocalValidationTroubleshootingHints -ErrorText "NetworkIntentValidationFailed: adapters do not match"

    .EXAMPLE
    Get-AzLocalValidationTroubleshootingHints -ErrorText $errorMessage -SearchOnline

    #>

    [OutputType([PSCustomObject[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ErrorText,

        [Parameter(Mandatory = $false)]
        [switch]$SearchOnline
    )

    if ([string]::IsNullOrWhiteSpace($ErrorText)) {
        return @()
    }

    [System.Collections.ArrayList]$allHints = @()

    # ===================================================================
    # Known error patterns with built-in remediation guidance
    # ===================================================================
    # Each pattern is checked against the combined error text using regex.
    # Patterns are ordered from most specific to most general.
    $knownPatterns = @(
        [PSCustomObject]@{
            Pattern     = 'NetworkIntentValidationFailed'
            Title       = 'Network Adapter Mismatch'
            Description = 'Network adapters specified in the deployment parameters do not match the adapters found on the node(s).'
            Remediation = @(
                "Compare the adapter names in your deployment parameters with the actual adapters on each node."
                "Run on each node: Get-NetAdapter | Format-Table Name, InterfaceDescription, Status"
                "Ensure every adapter name referenced in the network intents (Compute, Management, Storage) exists on every node."
                "Check for adapters that are disabled, not installed, or have a different name than expected."
                "If an adapter was recently replaced, the new adapter may have a different name."
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template'
        },
        [PSCustomObject]@{
            Pattern     = 'NetAdapter_RDMA_Operational|RDMA setting on adapters are invalid|NetworkDirect.*RDMA not supported'
            Title       = 'Network Adapter RDMA Operational Status Failure'
            Description = 'RDMA is not operational or not supported on one or more network adapters used by network intents.'
            Remediation = @(
                "Ensure the correct vendor-specific (non-inbox) NIC drivers are installed - inbox Microsoft drivers typically do not support RDMA."
                "Run on each node: Get-NetAdapterRdma | Format-Table Name, InterfaceDescription, Enabled, Operational"
                "If RDMA is not supported by the adapter hardware, configure the network intent with OverrideAdapterProperty to disable NetworkDirect."
                "Check all network intents (Mgmt, Compute, Storage) - each intent's adapters must have consistent RDMA support."
                "After installing updated NIC drivers, restart the network adapters or reboot the node before retrying validation."
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template'
        },
        [PSCustomObject]@{
            Pattern     = 'InboxDriver|inbox.drivers|DriverProvider.*(Microsoft|Windows).*adapters'
            Title       = 'Network Adapters Using Inbox Drivers'
            Description = 'One or more network adapters are using inbox (Microsoft/Windows) drivers instead of vendor-specific drivers. Inbox drivers lack features required for Azure Local deployment such as RDMA support.'
            Remediation = @(
                "Install the correct vendor-specific NIC drivers from your hardware manufacturer (Dell, HPE, Lenovo, etc.)."
                "Run on each node: Get-NetAdapter | Select-Object Name, DriverProvider, DriverVersion | Format-Table"
                "Adapters showing DriverProvider 'Microsoft' or 'Windows' are using inbox drivers and must be updated."
                "Download the correct drivers from your hardware vendor's support site for the specific NIC model."
                "After installing drivers, verify with Get-NetAdapter that DriverProvider shows the NIC vendor (e.g., Intel, Mellanox, Broadcom)."
                "Reference: https://aka.ms/azurelocal/envvalidator/InboxDrivers"
            )
            Reference   = 'https://aka.ms/azurelocal/envvalidator/InboxDrivers'
        },
        [PSCustomObject]@{
            Pattern     = 'vManagement\(vManagement\(|expected virtual NIC name is \[vManagement\(vManagement'
            Title       = 'Management Intent Name Double-Wrapped'
            Description = 'The management intent name includes the vManagement() prefix, causing a double-wrapped virtual NIC name.'
            Remediation = @(
                "In your deployment parameters, set the management intent name to just the plain intent name (e.g., 'Mgmt')."
                "Do NOT include the 'vManagement()' prefix in the intent name - the system applies it automatically."
                "Example: To produce a virtual NIC named 'vManagement(Mgmt)', set the intent name to 'Mgmt', not 'vManagement(Mgmt)'."
                "Check the 'intentList' section of your deployment parameters for the management intent name value."
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template'
        },
        [PSCustomObject]@{
            Pattern     = 'OuGpoInheritance|GpoInheritanceBlocked|GpoInheritance'
            Title       = 'GPO Inheritance Block Required on AD Organizational Unit'
            Description = 'Group Policy inheritance is not blocked on the Active Directory OU used for the Azure Local machine accounts.'
            Remediation = @(
                "Block GPO inheritance on the OU containing the Azure Local computer objects."
                "In Group Policy Management (gpmc.msc), right-click the OU and select 'Block Inheritance'."
                "If parent GPOs have 'Enforced' enabled, blocking inheritance alone is not sufficient."
                "For enforced GPOs, add WMI filters to prevent those GPOs from applying to Azure Local node OS."
                "Re-run the deployment validation after applying the inheritance block and/or WMI filters."
            )
            Reference   = 'https://aka.ms/hci-envch'
        },
        [PSCustomObject]@{
            Pattern     = 'RoleAssignmentExists|role assignment already exists'
            Title       = 'Duplicate RBAC Role Assignment (Conflict)'
            Description = 'A role assignment required by the ARM template already exists from a previous deployment attempt.'
            Remediation = @(
                "This commonly occurs when a previous deployment attempt (or portal-based deployment) already created the role assignment."
                "Extract the role assignment ID from the error message."
                "View the existing assignment:  az role assignment show --id {role-assignment-id}"
                "Delete the duplicate assignment: az role assignment delete --ids {role-assignment-id}"
                "Verify deletion: az role assignment list --resource-group {resource-group-name} --output table"
                "Re-run the deployment after removing the duplicate assignment."
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template#role-assignment-already-exists'
        },
        [PSCustomObject]@{
            Pattern     = 'Test_PhysicalDisk|PhysicalDisk.*CanPool|CannotPoolReason|HCISupportedData'
            Title       = 'Physical Disk / Storage Validation Failure'
            Description = 'Data disks do not meet Storage Spaces Direct (S2D) requirements for Azure Local deployment.'
            Remediation = @(
                "Run on each node: Get-PhysicalDisk | Format-Table FriendlyName, PhysicalLocation, UniqueId, CanPool, CannotPoolReason, BusType, MediaType, Size -AutoSize"
                "Verify all expected data disks are visible to the OS (not hidden behind a RAID controller)."
                "If disks are behind a hardware RAID controller, switch it to HBA/passthrough/JBOD mode."
                "Ensure CanPool is True for all data disks. If False, check the CannotPoolReason column."
                "Data disk BusType must be SAS, SATA, NVMe, or SCM. MediaType must be HDD, SSD, or SCM."
                "If disks were previously in a Storage Pool, reset them before deployment:"
                "  Get-StoragePool | Where-Object IsPrimordial -eq `$false | Remove-StoragePool -Confirm:`$false"
                "  Get-PhysicalDisk | Reset-PhysicalDisk"
                "  Ref: https://learn.microsoft.com/troubleshoot/windows-server/backup-and-storage/delete-s2d-storage-pool-reuse-disks"
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template'
        },
        [PSCustomObject]@{
            Pattern     = 'MandatoryRPRegistration|ValidateArcIntegration.*RPRegistration|Resource Providers are registered'
            Title       = 'Required Resource Providers Not Registered'
            Description = 'One or more Azure Resource Providers required for Azure Local deployment are not registered in the subscription.'
            Remediation = @(
                "Register all required Resource Providers in the subscription used for deployment."
                "Required RPs: Microsoft.HybridCompute, Microsoft.GuestConfiguration, Microsoft.HybridConnectivity,"
                "  Microsoft.AzureStackHCI, Microsoft.Kubernetes, Microsoft.KubernetesConfiguration,"
                "  Microsoft.ExtendedLocation, Microsoft.ResourceConnector, Microsoft.HybridContainerService,"
                "  Microsoft.Attestation, Microsoft.Storage, Microsoft.Insights"
                "Register via CLI:  az provider register --namespace <ProviderNamespace> --wait"
                "Register via PowerShell:  Register-AzResourceProvider -ProviderNamespace <ProviderNamespace>"
                "Check status:  Get-AzResourceProvider -ProviderNamespace <ProviderNamespace> | Select-Object ProviderNamespace, RegistrationState"
                "Registration can take several minutes. Wait until the state shows 'Registered' before retrying."
                "Ref: https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions#azure-prerequisites"
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-arc-register-server-permissions#azure-prerequisites'
        },
        [PSCustomObject]@{
            Pattern     = 'OperationTimeout|deployment settings validation call results in.*timeout'
            Title       = 'Deployment Settings Validation Timeout'
            Description = 'The deployment settings validation timed out during one or more environment checker steps.'
            Remediation = @(
                "Verify network connectivity from all nodes to the required Azure endpoints."
                "Ensure the LCM (Lifecycle Manager) extension is healthy on all nodes."
                "Check that DNS resolution is working correctly on all nodes."
                "Retry the validation - transient timeouts can sometimes resolve on a subsequent attempt."
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template'
        },
        [PSCustomObject]@{
            Pattern     = 'UpdateDeploymentSettingsDataFailed'
            Title       = 'Deployment Settings Validation Failed'
            Description = 'One or more environment validation steps failed during the deployment settings update.'
            Remediation = @(
                "Review the error details for 'Status=Error' entries to identify which validation step failed."
                "Common validation step failures and what to check:"
                "  - Remote Management: WinRM connectivity between nodes (Test-WSMan)"
                "  - Connectivity: Outbound access to required Azure endpoints"
                "  - External Active Directory: OU structure and GPO inheritance blocks"
                "  - Hardware: Physical disk availability, NIC configuration, BIOS/firmware"
                "  - Network: Adapter naming, IP configuration, LLDP"
                "  - SBE Health: Solution Builder Extension health"
                "Look for the 'AdditionalData' section in the error for step-specific remediation guidance."
            )
            Reference   = 'https://learn.microsoft.com/azure/azure-local/deploy/deployment-azure-resource-manager-template'
        }
    )

    # Check each known pattern against the error text
    foreach ($kp in $knownPatterns) {
        if ($ErrorText -match $kp.Pattern) {
            $hint = [PSCustomObject]@{
                Source      = 'KnownPattern'
                Title       = $kp.Title
                Description = $kp.Description
                Remediation = $kp.Remediation
                Reference   = $kp.Reference
            }
            $allHints.Add($hint) | Out-Null
        }
    }

    # ===================================================================
    # Online search: Azure Local Supportability TSG repository
    # https://github.com/Azure/AzureLocal-Supportability/tree/main/TSG/Deployment
    # ===================================================================
    if ($SearchOnline) {
        Write-Verbose "Searching Azure Local Supportability TSG repository for matching troubleshooting guides..."

        try {
            # Fetch the TSG/Deployment directory listing from the GitHub API (public, no auth required)
            $apiUrl = 'https://api.github.com/repos/Azure/AzureLocal-Supportability/contents/TSG/Deployment'
            $headers = @{
                'Accept'     = 'application/vnd.github.v3+json'
                'User-Agent' = 'AzLocal.DeploymentAutomation'
            }
            $tsgFiles = @(Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 15 -ErrorAction Stop)

            # Build search keywords from the error text
            [System.Collections.ArrayList]$searchTerms = @()

            # Extract PascalCase identifiers (4+ chars) and split compound words
            $identifiers = [regex]::Matches($ErrorText, '\b[A-Z][a-zA-Z]{4,}\b')
            foreach ($id in $identifiers) {
                $words = [regex]::Split($id.Value, '(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])')
                foreach ($w in $words) {
                    if ($w.Length -ge 4) { $searchTerms.Add($w.ToLower()) | Out-Null }
                }
            }

            # Extract underscore-separated identifiers (common in environment checker output)
            $underscoreIds = [regex]::Matches($ErrorText, '\b[A-Za-z]{2,}(?:_[A-Za-z]{2,}){1,}\b')
            foreach ($uid in $underscoreIds) {
                $parts = $uid.Value -split '_'
                foreach ($p in $parts) {
                    if ($p.Length -ge 4) { $searchTerms.Add($p.ToLower()) | Out-Null }
                }
            }

            # Also look for specific component names that appear in error messages and TSG filenames
            $componentKeywords = @(
                'Hardware', 'Firewall', 'Timeout', 'PhysicalDisk', 'CloudCommon',
                'MocArb', 'Bitlocker', 'BitLocker', 'EncryptCluster', 'OperationTimeout',
                'DeployPreRequisites', 'ArcIntegration', 'SPN', 'Pip'
            )
            foreach ($kw in $componentKeywords) {
                if ($ErrorText -match [regex]::Escape($kw)) {
                    $searchTerms.Add($kw.ToLower()) | Out-Null
                }
            }

            # Remove generic terms that would produce false-positive matches against TSG filenames
            $stopTerms = @(
                'error', 'failed', 'message', 'status', 'value', 'name', 'type',
                'validation', 'deployment', 'settings', 'azure', 'stack', 'check',
                'description', 'exception', 'requirements', 'steps', 'null',
                'test', 'true', 'false', 'date', 'with', 'from', 'that', 'this',
                'microsoft', 'providers', 'resources', 'subscriptions', 'resource'
            )
            [System.Collections.ArrayList]$searchTerms = @($searchTerms | Where-Object { $_ -notin $stopTerms } | Select-Object -Unique)

            if ($searchTerms.Count -gt 0) {
                # Build a single regex alternation from all search terms
                $keywordPattern = ($searchTerms | ForEach-Object { [regex]::Escape($_) }) -join '|'

                foreach ($file in $tsgFiles) {
                    if ($file.name -match '\.md$' -and $file.name -ne 'README.md') {
                        # Normalise hyphen-separated filename for matching
                        $fileNameNormalized = ($file.name -replace '-', ' ' -replace '\.md$', '').ToLower()
                        if ($fileNameNormalized -match $keywordPattern) {
                            $displayTitle = $file.name -replace '-', ' ' -replace '\.md$', ''
                            $hint = [PSCustomObject]@{
                                Source      = 'OnlineTSG'
                                Title       = $displayTitle
                                Description = 'Matching troubleshooting guide found in the Azure Local Supportability repository.'
                                Remediation = @("Review the troubleshooting guide for detailed remediation steps.")
                                Reference   = $file.html_url
                            }
                            $allHints.Add($hint) | Out-Null
                        }
                    }
                }
            }
        } catch {
            Write-Verbose "Unable to search online TSG repository: $($_.Exception.Message)"
        }
    }

    # ===================================================================
    # Display formatted hints in the console
    # ===================================================================
    if ($allHints.Count -gt 0) {
        $knownHints  = @($allHints | Where-Object { $_.Source -eq 'KnownPattern' })
        $onlineHints = @($allHints | Where-Object { $_.Source -eq 'OnlineTSG' })

        Write-AzLocalLog "" -Level Info -NoTimestamp
        Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
        Write-AzLocalLog "  Troubleshooting Hints" -Level Info -NoTimestamp
        Write-AzLocalLog "========================================================" -Level Info -NoTimestamp

        $hintNumber = 0
        foreach ($hint in $knownHints) {
            $hintNumber++
            Write-AzLocalLog "" -Level Info -NoTimestamp
            Write-AzLocalLog "  [$hintNumber] $($hint.Title)" -Level Warning -NoTimestamp
            Write-AzLocalLog "      $($hint.Description)" -Level Info -NoTimestamp
            Write-AzLocalLog "" -Level Info -NoTimestamp
            Write-AzLocalLog "      Recommended actions:" -Level Info -NoTimestamp
            foreach ($step in $hint.Remediation) {
                Write-AzLocalLog "        - $step" -Level Info -NoTimestamp
            }
            if ($hint.PSObject.Properties['Reference'] -and $hint.Reference) {
                Write-AzLocalLog "" -Level Info -NoTimestamp
                Write-AzLocalLog "      Reference: $($hint.Reference)" -Level Info -NoTimestamp
            }
        }

        if ($onlineHints.Count -gt 0) {
            Write-AzLocalLog "" -Level Info -NoTimestamp
            Write-AzLocalLog "  Online Troubleshooting Guides (Azure Local Supportability):" -Level Warning -NoTimestamp
            foreach ($hint in $onlineHints) {
                Write-AzLocalLog "    - $($hint.Title)" -Level Info -NoTimestamp
                Write-AzLocalLog "      $($hint.Reference)" -Level Info -NoTimestamp
            }
        }

        Write-AzLocalLog "" -Level Info -NoTimestamp
        Write-AzLocalLog "  Full TSG index: https://github.com/Azure/AzureLocal-Supportability/blob/main/TSG/Deployment/README.md" -Level Info -NoTimestamp
        Write-AzLocalLog "========================================================" -Level Info -NoTimestamp
    }

    return ,$allHints
}
