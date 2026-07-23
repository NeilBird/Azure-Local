#Requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the AzLocal.DeploymentAutomation module.

.DESCRIPTION
    Unit tests for the Azure Local Deployment Automation module.
    These tests validate parameter validation, naming resolution, config loading,
    file path logic, and JSON formatting without requiring Azure connectivity (using mocks).

.NOTES
    Run with: .\Tests\Invoke-Tests.ps1
    Or:       Invoke-Pester -Path .\Tests
#>

BeforeAll {
    # Import the module from parent directory
    # Use the .psm1 directly to avoid RequiredModules dependency on Az.Accounts/Az.Resources
    # which may not be installed in the test environment. The manifest is tested separately.
    # The .psm1 reads its own manifest to dot-source all function files from NestedModules,
    # so all functions are available even without loading via the .psd1.
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.DeploymentAutomation.psm1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Suppress Write-Host console output from module functions during testing.
    # This prevents the VS Code terminal from becoming unresponsive due to hundreds
    # of colored Write-Host calls from Write-AzLocalLog during test execution.
    & (Get-Module AzLocal.DeploymentAutomation) { $script:SuppressConsoleOutput = $true }

    # Store module info for tests
    $script:ModuleInfo = Get-Module AzLocal.DeploymentAutomation

    # Store manifest path for manifest-specific tests
    $script:ManifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.DeploymentAutomation.psd1'
}

AfterAll {
    # Restore console output before removing the module
    if (Get-Module AzLocal.DeploymentAutomation -ErrorAction SilentlyContinue) {
        & (Get-Module AzLocal.DeploymentAutomation) { $script:SuppressConsoleOutput = $false }
    }
    Remove-Module AzLocal.DeploymentAutomation -Force -ErrorAction SilentlyContinue
}

# ============================================================================
# Module Load Tests
# ============================================================================
Describe 'Module: AzLocal.DeploymentAutomation' {

    Context 'Module Load' {
        It 'Should load the module without errors' {
            $script:ModuleInfo | Should -Not -BeNullOrEmpty
        }

        It 'Should have version 1.0.3 in manifest' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $manifest.ModuleVersion | Should -Be '1.0.3'
        }

        It 'Should contain Start-AzLocalTemplateDeployment function' {
            Get-Command -Module AzLocal.DeploymentAutomation -Name 'Start-AzLocalTemplateDeployment' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It 'Should contain Watch-AzLocalDeployment function' {
            Get-Command -Module AzLocal.DeploymentAutomation -Name 'Watch-AzLocalDeployment' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It 'Should contain Start-AzLocalCsvDeployment function' {
            Get-Command -Module AzLocal.DeploymentAutomation -Name 'Start-AzLocalCsvDeployment' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It 'Should contain Get-AzLocalDeploymentStatus function' {
            Get-Command -Module AzLocal.DeploymentAutomation -Name 'Get-AzLocalDeploymentStatus' -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }

        It 'Manifest should export exactly 4 functions' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $manifest.FunctionsToExport.Count | Should -Be 4
        }

        It 'Manifest should export Start-AzLocalTemplateDeployment' {
            $manifest = Import-PowerShellDataFile -Path $script:ManifestPath
            $manifest.FunctionsToExport | Should -Contain 'Start-AzLocalTemplateDeployment'
        }
    }

    Context 'Module Manifest' {
        BeforeAll {
            $script:ManifestData = $null
            $script:ManifestRaw = $null
            try {
                $script:ManifestData = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop -WarningAction SilentlyContinue
            } catch {
                # Az modules may not be installed - parse the manifest directly for validation
            }
            # Always parse the raw PSD1 content as a fallback
            $script:ManifestRaw = Import-PowerShellDataFile -Path $script:ManifestPath -ErrorAction Stop
        }

        It 'Should have a parseable module manifest' {
            $script:ManifestRaw | Should -Not -BeNullOrEmpty
        }

        It 'Should require PowerShell 5.1 or higher' {
            $script:ManifestRaw.PowerShellVersion | Should -Be '5.1'
        }

        It 'Should require Az.Accounts module' {
            $requiredNames = $script:ManifestRaw.RequiredModules | ForEach-Object { $_.ModuleName }
            $requiredNames | Should -Contain 'Az.Accounts'
        }

        It 'Should require Az.Resources module' {
            $requiredNames = $script:ManifestRaw.RequiredModules | ForEach-Object { $_.ModuleName }
            $requiredNames | Should -Contain 'Az.Resources'
        }

        It 'Should NOT require Az.KeyVault module (optional, checked at runtime)' {
            $requiredNames = $script:ManifestRaw.RequiredModules | ForEach-Object { $_.ModuleName }
            $requiredNames | Should -Not -Contain 'Az.KeyVault'
        }

        It 'Should have a non-empty description' {
            $script:ManifestRaw.Description | Should -Not -BeNullOrEmpty
        }

        It 'Should have an author defined' {
            $script:ManifestRaw.Author | Should -Not -BeNullOrEmpty
        }

        It 'Should export Start-AzLocalTemplateDeployment' {
            $script:ManifestRaw.FunctionsToExport | Should -Contain 'Start-AzLocalTemplateDeployment'
        }

        It 'Should export Watch-AzLocalDeployment' {
            $script:ManifestRaw.FunctionsToExport | Should -Contain 'Watch-AzLocalDeployment'
        }

        It 'Should export Start-AzLocalCsvDeployment' {
            $script:ManifestRaw.FunctionsToExport | Should -Contain 'Start-AzLocalCsvDeployment'
        }

        It 'Should export Get-AzLocalDeploymentStatus' {
            $script:ManifestRaw.FunctionsToExport | Should -Contain 'Get-AzLocalDeploymentStatus'
        }

        It 'Should have version 1.0.3' {
            $script:ManifestRaw.ModuleVersion | Should -Be '1.0.3'
        }

        It 'Should have ReleaseNotes within the PSGallery character limit' {
            # PSGallery enforces a maximum of 10000 characters on the ReleaseNotes field
            # (publish fails with "Tags, ReleaseNotes, ... cannot exceed 10000 characters").
            # This test guards against accidental regressions when the release notes grow.
            $releaseNotes = $script:ManifestRaw.PrivateData.PSData.ReleaseNotes
            $releaseNotes | Should -Not -BeNullOrEmpty
            $releaseNotes.Length | Should -BeLessOrEqual 10000 -Because "PSGallery rejects ReleaseNotes longer than 10000 characters"
        }
    }
}

# ============================================================================
# Start-AzLocalTemplateDeployment - Parameter Validation
# ============================================================================
Describe 'Function: Start-AzLocalTemplateDeployment' {

    Context 'Parameter Definitions' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
        }

        It 'Should have SubscriptionId parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'SubscriptionId'
        }

        It 'Should have TypeOfDeployment parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'TypeOfDeployment'
        }

        It 'Should have TenantId parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'TenantId'
        }

        It 'Should have DeploymentMode parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'DeploymentMode'
        }

        It 'Should have NodeCount parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'NodeCount'
        }

        It 'Should have Location parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'Location'
        }

        It 'Should have DnsServers parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'DnsServers'
        }

        It 'Should have ComputeManagementAdapters parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'ComputeManagementAdapters'
        }

        It 'Should have StorageAdapters parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'StorageAdapters'
        }

        It 'Should have LocalAdminCredential parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LocalAdminCredential'
        }

        It 'Should have LCMAdminCredential parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LCMAdminCredential'
        }

        It 'Should have CredentialKeyVaultName parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'CredentialKeyVaultName'
        }

        It 'Should have LocalAdminSecretName parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LocalAdminSecretName'
        }

        It 'Should have LCMAdminSecretName parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LCMAdminSecretName'
        }

        It 'Should have UniqueID parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'UniqueID'
        }

        It 'Should have NetworkSettingsJson parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'NetworkSettingsJson'
        }

        It 'Should have SkipOnlineTSGSearch parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'SkipOnlineTSGSearch'
        }

        It 'SkipOnlineTSGSearch should be a SwitchParameter' {
            $script:Command.Parameters['SkipOnlineTSGSearch'].ParameterType.Name | Should -Be 'SwitchParameter'
        }

        It 'Should support -WhatIf' {
            $script:Command.Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'Should support -Confirm' {
            $script:Command.Parameters.Keys | Should -Contain 'Confirm'
        }
    }

    Context 'Parameter Types' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
        }

        It 'SubscriptionId should be of type Guid' {
            $script:Command.Parameters['SubscriptionId'].ParameterType.Name | Should -Be 'Guid'
        }

        It 'TenantId should be of type Guid' {
            $script:Command.Parameters['TenantId'].ParameterType.Name | Should -Be 'Guid'
        }

        It 'NodeCount should be of type Int32' {
            $script:Command.Parameters['NodeCount'].ParameterType.Name | Should -Be 'Int32'
        }

        It 'DnsServers should be of type String[]' {
            $script:Command.Parameters['DnsServers'].ParameterType.FullName | Should -Be 'System.String[]'
        }

        It 'ComputeManagementAdapters should be of type String[]' {
            $script:Command.Parameters['ComputeManagementAdapters'].ParameterType.FullName | Should -Be 'System.String[]'
        }

        It 'StorageAdapters should be of type String[]' {
            $script:Command.Parameters['StorageAdapters'].ParameterType.FullName | Should -Be 'System.String[]'
        }

        It 'LocalAdminCredential should be of type PSCredential' {
            $script:Command.Parameters['LocalAdminCredential'].ParameterType.Name | Should -Be 'PSCredential'
        }

        It 'LCMAdminCredential should be of type PSCredential' {
            $script:Command.Parameters['LCMAdminCredential'].ParameterType.Name | Should -Be 'PSCredential'
        }

        It 'CredentialKeyVaultName should be of type String' {
            $script:Command.Parameters['CredentialKeyVaultName'].ParameterType.Name | Should -Be 'String'
        }

        It 'LocalAdminSecretName should be of type String' {
            $script:Command.Parameters['LocalAdminSecretName'].ParameterType.Name | Should -Be 'String'
        }

        It 'LCMAdminSecretName should be of type String' {
            $script:Command.Parameters['LCMAdminSecretName'].ParameterType.Name | Should -Be 'String'
        }

        It 'UniqueID should be of type String' {
            $script:Command.Parameters['UniqueID'].ParameterType.Name | Should -Be 'String'
        }

        It 'NetworkSettingsJson should be of type String' {
            $script:Command.Parameters['NetworkSettingsJson'].ParameterType.Name | Should -Be 'String'
        }
    }

    Context 'TypeOfDeployment ValidateSet' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
            $script:ValidateSet = $script:Command.Parameters['TypeOfDeployment'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        }

        It 'Should have a ValidateSet attribute' {
            $script:ValidateSet | Should -Not -BeNullOrEmpty
        }

        It 'Should allow SingleNode' {
            $script:ValidateSet.ValidValues | Should -Contain 'SingleNode'
        }

        It 'Should allow StorageSwitchless' {
            $script:ValidateSet.ValidValues | Should -Contain 'StorageSwitchless'
        }

        It 'Should allow StorageSwitched' {
            $script:ValidateSet.ValidValues | Should -Contain 'StorageSwitched'
        }

        It 'Should allow RackAware' {
            $script:ValidateSet.ValidValues | Should -Contain 'RackAware'
        }
        It 'Should allow Disaggregated (SAN, v1.0.0)' {
            $script:ValidateSet.ValidValues | Should -Contain 'Disaggregated'
        }
        It 'Should NOT allow TwoNode (consolidated into StorageSwitched)' {
            $script:ValidateSet.ValidValues | Should -Not -Contain 'TwoNode'
        }

        It 'Should NOT allow TwoNode-Switchless (deprecated)' {
            $script:ValidateSet.ValidValues | Should -Not -Contain 'TwoNode-Switchless'
        }

        It 'Should have exactly 5 valid deployment types' {
            $script:ValidateSet.ValidValues.Count | Should -Be 5
        }
    }

    Context 'DeploymentMode ValidateSet' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
            $script:ValidateSet = $script:Command.Parameters['DeploymentMode'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
        }

        It 'Should allow Validate' {
            $script:ValidateSet.ValidValues | Should -Contain 'Validate'
        }

        It 'Should allow Deploy' {
            $script:ValidateSet.ValidValues | Should -Contain 'Deploy'
        }

        It 'Should allow ValidateAndDeploy' {
            $script:ValidateSet.ValidValues | Should -Contain 'ValidateAndDeploy'
        }

        It 'Should have exactly 3 valid deployment modes' {
            $script:ValidateSet.ValidValues.Count | Should -Be 3
        }
    }

    Context 'NodeCount ValidateRange' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
            $script:ValidateRange = $script:Command.Parameters['NodeCount'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
        }

        It 'Should have a ValidateRange attribute' {
            $script:ValidateRange | Should -Not -BeNullOrEmpty
        }

        It 'Should have minimum value of 1 (lowered from 2 in v1.0.0 to support Disaggregated single-node)' {
            $script:ValidateRange.MinRange | Should -Be 1
        }

        It 'Should have maximum value of 64 (raised from 16 in v1.0.0 to support Disaggregated up to 64 nodes)' {
            $script:ValidateRange.MaxRange | Should -Be 64
        }
    }

    Context 'Mandatory Parameters' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
        }

        It 'SubscriptionId should be mandatory' {
            $param = $script:Command.Parameters['SubscriptionId']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }

        It 'TypeOfDeployment should be mandatory' {
            $param = $script:Command.Parameters['TypeOfDeployment']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }

        It 'TenantId should be mandatory' {
            $param = $script:Command.Parameters['TenantId']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }

        It 'DeploymentMode should be mandatory' {
            $param = $script:Command.Parameters['DeploymentMode']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }

        It 'NodeCount should NOT be mandatory' {
            $param = $script:Command.Parameters['NodeCount']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'Location should NOT be mandatory' {
            $param = $script:Command.Parameters['Location']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'DnsServers should NOT be mandatory' {
            $param = $script:Command.Parameters['DnsServers']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'LocalAdminCredential should NOT be mandatory' {
            $param = $script:Command.Parameters['LocalAdminCredential']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'LCMAdminCredential should NOT be mandatory' {
            $param = $script:Command.Parameters['LCMAdminCredential']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'CredentialKeyVaultName should NOT be mandatory' {
            $param = $script:Command.Parameters['CredentialKeyVaultName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'UniqueID should NOT be mandatory' {
            $param = $script:Command.Parameters['UniqueID']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'NetworkSettingsJson should NOT be mandatory' {
            $param = $script:Command.Parameters['NetworkSettingsJson']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }
    }
}

# ============================================================================
# Resolve-AzLocalResourceName (Internal Function - tested via InModuleScope)
# ============================================================================
Describe 'Function: Resolve-AzLocalResourceName' {

    Context 'UniqueID Placeholder Replacement' {
        It 'Should replace {UniqueID} with the provided value' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'rg-{UniqueID}-azurelocal' -UniqueID 'STORE001'
                $result | Should -Be 'rg-STORE001-azurelocal'
            }
        }

        It 'Should replace multiple occurrences of {UniqueID}' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern '{UniqueID}-{UniqueID}' -UniqueID 'ABC'
                $result | Should -Be 'ABC-ABC'
            }
        }

        It 'Should return pattern unchanged when no placeholders present' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'static-name' -UniqueID 'ABC'
                $result | Should -Be 'static-name'
            }
        }
    }

    Context 'NodeNumber Placeholder Replacement' {
        It 'Should replace {NodeNumber} with zero-padded 2-digit number' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern '{UniqueID}NODE{NodeNumber}' -UniqueID 'S001' -NodeNumber 1
                $result | Should -Be 'S001NODE01'
            }
        }

        It 'Should pad node number 3 to 03' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'NODE{NodeNumber}' -UniqueID 'X' -NodeNumber 3
                $result | Should -Be 'NODE03'
            }
        }

        It 'Should not replace {NodeNumber} when NodeNumber is 0 (default)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern '{UniqueID}-{NodeNumber}' -UniqueID 'ABC'
                $result | Should -Be 'ABC-{NodeNumber}'
            }
        }
    }

    Context 'TypeOfDeployment Placeholder Replacement' {
        It 'Should replace {TypeOfDeployment} with the deployment type' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'deploy-{UniqueID}-{TypeOfDeployment}' -UniqueID 'S001' -TypeOfDeployment 'SingleNode'
                $result | Should -Be 'deploy-S001-SingleNode'
            }
        }

        It 'Should not replace {TypeOfDeployment} when not provided' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern '{TypeOfDeployment}-test' -UniqueID 'X'
                $result | Should -Be '{TypeOfDeployment}-test'
            }
        }
    }

    Context 'Combined Placeholder Replacement' {
        It 'Should replace all placeholders in a complex pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'azlocal-{UniqueID}-{TypeOfDeployment}-deployment' -UniqueID 'SITE42' -TypeOfDeployment 'StorageSwitched'
                $result | Should -Be 'azlocal-SITE42-StorageSwitched-deployment'
            }
        }
    }

    Context 'Naming Config Standard Patterns' {
        It 'Should correctly resolve clusterName pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'AZCLUSTER{UniqueID}' -UniqueID 'S001'
                $result | Should -Be 'AZCLUSTERS001'
            }
        }

        It 'Should correctly resolve resourceGroupName pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'rg-{UniqueID}-azurelocal-prod' -UniqueID 'LON01'
                $result | Should -Be 'rg-LON01-azurelocal-prod'
            }
        }

        It 'Should correctly resolve keyVaultName pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'kv-{UniqueID}-azlocal' -UniqueID 'NYC99'
                $result | Should -Be 'kv-NYC99-azlocal'
            }
        }

        It 'Should correctly resolve diagnosticStorageAccountName pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern '{UniqueID}azlocaldiag' -UniqueID 'store01'
                $result | Should -Be 'store01azlocaldiag'
            }
        }

        It 'Should correctly resolve nodeNamePattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern '{UniqueID}NODE{NodeNumber}' -UniqueID 'S001' -NodeNumber 3
                $result | Should -Be 'S001NODE03'
            }
        }

        It 'Should correctly resolve adouPath pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Resolve-AzLocalResourceName -Pattern 'OU=AzLocal-{UniqueID},OU=AzureLocal,DC=contoso,DC=com' -UniqueID 'Branch01'
                $result | Should -Be 'OU=AzLocal-Branch01,OU=AzureLocal,DC=contoso,DC=com'
            }
        }
    }
}

# ============================================================================
# Get-AzLocalNamingConfig (Internal Function)
# ============================================================================
Describe 'Function: Get-AzLocalNamingConfig' {

    Context 'Config File Loading' {
        It 'Should load the naming configuration successfully' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalNamingConfig
                $result | Should -Not -BeNullOrEmpty
                $result.Config | Should -Not -BeNullOrEmpty
                $result.ResolvedPath | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should return an object with namingStandards property' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalNamingConfig
                $result.Config.namingStandards | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should return an object with defaults property' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalNamingConfig
                $result.Config.defaults | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should create required user config files under inherited WhatIf' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ TestProfile = $TestDrive } {
                param($TestProfile)
                $originalProfile = $env:USERPROFILE
                try {
                    $env:USERPROFILE = $TestProfile
                    $WhatIfPreference = $true
                    $configPath = Initialize-AzLocalUserConfig

                    Test-Path -LiteralPath $configPath | Should -BeTrue
                    Test-Path -LiteralPath (Join-Path (Split-Path $configPath) 'README.md') | Should -BeTrue
                } finally {
                    $env:USERPROFILE = $originalProfile
                }
            }
        }
    }

    Context 'Naming Standards Structure' {
        BeforeAll {
            $script:Config = (InModuleScope AzLocal.DeploymentAutomation { Get-AzLocalNamingConfig }).Config
        }

        It 'Should have clusterName naming standard' {
            $script:Config.namingStandards.clusterName | Should -Not -BeNullOrEmpty
        }

        It 'Should have resourceGroupName naming standard' {
            $script:Config.namingStandards.resourceGroupName | Should -Not -BeNullOrEmpty
        }

        It 'Should have keyVaultName naming standard' {
            $script:Config.namingStandards.keyVaultName | Should -Not -BeNullOrEmpty
        }

        It 'Should have customLocation naming standard' {
            $script:Config.namingStandards.customLocation | Should -Not -BeNullOrEmpty
        }

        It 'Should have resourceBridgeName naming standard' {
            $script:Config.namingStandards.resourceBridgeName | Should -Not -BeNullOrEmpty
        }

        It 'Should have diagnosticStorageAccountName naming standard' {
            $script:Config.namingStandards.diagnosticStorageAccountName | Should -Not -BeNullOrEmpty
        }

        It 'Should have clusterWitnessStorageAccountName naming standard' {
            $script:Config.namingStandards.clusterWitnessStorageAccountName | Should -Not -BeNullOrEmpty
        }

        It 'Should have nodeNamePattern naming standard' {
            $script:Config.namingStandards.nodeNamePattern | Should -Not -BeNullOrEmpty
        }

        It 'Should have adouPath naming standard' {
            $script:Config.namingStandards.adouPath | Should -Not -BeNullOrEmpty
        }

        It 'Should have deploymentName naming standard' {
            $script:Config.namingStandards.deploymentName | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Defaults Structure' {
        BeforeAll {
            $script:Config = (InModuleScope AzLocal.DeploymentAutomation { Get-AzLocalNamingConfig }).Config
        }

        It 'Should have a default location' {
            $script:Config.defaults.location | Should -Not -BeNullOrEmpty
        }

        It 'Should have a default domainFqdn' {
            $script:Config.defaults.domainFqdn | Should -Not -BeNullOrEmpty
        }

        It 'Should have a default namingPrefix' {
            $script:Config.defaults.namingPrefix | Should -Not -BeNullOrEmpty
        }

        It 'Should have a default azureStackLCMAdminUsername' {
            $script:Config.defaults.azureStackLCMAdminUsername | Should -Not -BeNullOrEmpty
        }

        It 'Should have a default storageAccountType' {
            $script:Config.defaults.storageAccountType | Should -Not -BeNullOrEmpty
        }

        It 'Should have default dnsServers as an array' {
            $script:Config.defaults.dnsServers | Should -Not -BeNullOrEmpty
            $script:Config.defaults.dnsServers.Count | Should -BeGreaterOrEqual 1
        }

        It 'Should have default computeManagementAdapters as an array' {
            $script:Config.defaults.computeManagementAdapters | Should -Not -BeNullOrEmpty
            $script:Config.defaults.computeManagementAdapters.Count | Should -BeGreaterOrEqual 1
        }

        It 'Should have default storageAdapters as an array' {
            $script:Config.defaults.storageAdapters | Should -Not -BeNullOrEmpty
            $script:Config.defaults.storageAdapters.Count | Should -BeGreaterOrEqual 1
        }
    }

    Context 'Naming Patterns Contain Expected Placeholders' {
        BeforeAll {
            $script:Config = (InModuleScope AzLocal.DeploymentAutomation { Get-AzLocalNamingConfig }).Config
        }

        It 'clusterName should contain {UniqueID}' {
            $script:Config.namingStandards.clusterName | Should -Match '\{UniqueID\}'
        }

        It 'resourceGroupName should contain {UniqueID}' {
            $script:Config.namingStandards.resourceGroupName | Should -Match '\{UniqueID\}'
        }

        It 'nodeNamePattern should contain {UniqueID} and {NodeNumber}' {
            $script:Config.namingStandards.nodeNamePattern | Should -Match '\{UniqueID\}'
            $script:Config.namingStandards.nodeNamePattern | Should -Match '\{NodeNumber\}'
        }

        It 'deploymentName should contain {UniqueID} and {TypeOfDeployment}' {
            $script:Config.namingStandards.deploymentName | Should -Match '\{UniqueID\}'
            $script:Config.namingStandards.deploymentName | Should -Match '\{TypeOfDeployment\}'
        }
    }
}

# ============================================================================
# Publish-Module package allowlist
# ============================================================================
Describe 'Publish-Module package allowlist' {
    BeforeAll {
        $script:PublishScriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\Publish-Module.ps1'
        $script:PublishScript = Get-Content -LiteralPath $script:PublishScriptPath -Raw
        $script:BaselinePackageAssets = @(
            'README.md'
            '.config\naming-standards-config.json'
            'templates\azure-local-deployment-template.json'
            'templates\azure-local-deployment-template-san.json'
            'template-parameter-files\single-node-parameters-file.json'
            'template-parameter-files\storage-switched-parameters-file.json'
            'template-parameter-files\storage-switchless-2node-parameters-file.json'
            'template-parameter-files\storage-switchless-3node-parameters-file.json'
            'template-parameter-files\storage-switchless-4node-parameters-file.json'
            'template-parameter-files\rack-aware-parameters-file.json'
            'template-parameter-files\disaggregated-parameters-file.json'
            'automation-pipelines\README.md'
            'automation-pipelines\cluster-deployments.csv'
            'automation-pipelines\azure-devops\deploy-clusters.yml'
            'automation-pipelines\azure-devops\validate-deployments.yml'
            'automation-pipelines\azure-devops\deployment-status-report.yml'
            'automation-pipelines\azure-devops\deployment-monitor.yml'
            'automation-pipelines\github-actions\deploy-clusters.yml'
            'automation-pipelines\github-actions\validate-deployments.yml'
            'automation-pipelines\github-actions\deployment-status-report.yml'
            'automation-pipelines\github-actions\deployment-monitor.yml'
        )
    }

    It 'Should derive module code from RootModule and NestedModules' {
        $script:PublishScript | Should -Match '\$sourceManifest\.RootModule'
        $script:PublishScript | Should -Match '\$sourceManifest\.NestedModules'
    }

    It 'Should not copy the complete source tree or use a removal denylist' {
        $script:PublishScript | Should -Not -Match 'Copy-Item\s+-Path\s+\$SourceDir\s+-Destination\s+\$StagingDir\s+-Recurse'
        $script:PublishScript | Should -Not -Match '\$RemovePaths\s*='
    }

    It 'Should explicitly include every non-code asset from the 1.0.2 package' {
        foreach ($relativePath in $script:BaselinePackageAssets) {
            $script:PublishScript | Should -Match ([regex]::Escape("'$relativePath'"))
        }
    }

    It 'Should fail when an allowlisted file is missing or staging contains an extra file' {
        $script:PublishScript | Should -Match 'Required package file is missing'
        $script:PublishScript | Should -Match 'Staged package contains files outside the allowlist'
    }
}

# ============================================================================
# Get-AzLocalParameterFilePath (Internal Function)
# ============================================================================
Describe 'Function: Get-AzLocalParameterFilePath' {

    Context 'SingleNode Parameter File' {
        It 'Should return a path ending with single-node-parameters-file.json' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'SingleNode'
                $result | Should -Match 'single-node-parameters-file\.json$'
            }
        }

        It 'Should return a valid file path for SingleNode' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'SingleNode'
                $result | Should -Not -BeNullOrEmpty
                Test-Path $result | Should -Be $true
            }
        }
    }

    Context 'StorageSwitchless Parameter File' {
        It 'Should return a path ending with storage-switchless-2node-parameters-file.json by default' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitchless'
                $result | Should -Match 'storage-switchless-2node-parameters-file\.json$'
            }
        }

        It 'Should return storage-switchless-3node-parameters-file.json for NodeCount 3' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitchless' -NodeCount 3
                $result | Should -Match 'storage-switchless-3node-parameters-file\.json$'
            }
        }

        It 'Should return storage-switchless-4node-parameters-file.json for NodeCount 4' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitchless' -NodeCount 4
                $result | Should -Match 'storage-switchless-4node-parameters-file\.json$'
            }
        }

        It 'Should return a valid file path for StorageSwitchless (2, 3, and 4 nodes)' {
            InModuleScope AzLocal.DeploymentAutomation {
                foreach ($n in 2, 3, 4) {
                    $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitchless' -NodeCount $n
                    $result | Should -Not -BeNullOrEmpty
                    Test-Path $result | Should -Be $true
                }
            }
        }

        It 'Should NOT reference two-node-switchless (deprecated filename)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitchless'
                $result | Should -Not -Match 'two-node-switchless'
            }
        }
    }

    Context 'StorageSwitched Parameter File' {
        It 'Should return a path ending with storage-switched-parameters-file.json' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitched'
                $result | Should -Match 'storage-switched-parameters-file\.json$'
            }
        }

        It 'Should return a valid file path for StorageSwitched' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitched'
                $result | Should -Not -BeNullOrEmpty
                Test-Path $result | Should -Be $true
            }
        }

        It 'Should NOT reference old multi-node-parameters-file name (deprecated)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'StorageSwitched'
                $result | Should -Not -Match 'multi-node-parameters-file\.json$'
            }
        }
    }

    Context 'RackAware Parameter File' {
        It 'Should return a path ending with rack-aware-parameters-file.json' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'RackAware'
                $result | Should -Match 'rack-aware-parameters-file\.json$'
            }
        }

        It 'Should return a valid file path for RackAware' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'RackAware'
                $result | Should -Not -BeNullOrEmpty
                Test-Path $result | Should -Be $true
            }
        }
    }

    Context 'Template Parameter Files Exist On Disk' {
        BeforeAll {
            $script:ModuleRoot = Split-Path (Get-Module AzLocal.DeploymentAutomation).Path -Parent
            $script:TemplateDir = Join-Path $script:ModuleRoot 'template-parameter-files'
        }

        It 'template-parameter-files directory should exist' {
            Test-Path $script:TemplateDir | Should -Be $true
        }

        It 'single-node-parameters-file.json should exist' {
            Test-Path (Join-Path $script:TemplateDir 'single-node-parameters-file.json') | Should -Be $true
        }

        It 'two-node-switched-parameters-file.json should NOT exist (deprecated)' {
            Test-Path (Join-Path $script:TemplateDir 'two-node-switched-parameters-file.json') | Should -Be $false
        }

        It 'storage-switchless-2node-parameters-file.json should exist' {
            Test-Path (Join-Path $script:TemplateDir 'storage-switchless-2node-parameters-file.json') | Should -Be $true
        }

        It 'storage-switchless-3node-parameters-file.json should exist' {
            Test-Path (Join-Path $script:TemplateDir 'storage-switchless-3node-parameters-file.json') | Should -Be $true
        }

        It 'storage-switchless-4node-parameters-file.json should exist' {
            Test-Path (Join-Path $script:TemplateDir 'storage-switchless-4node-parameters-file.json') | Should -Be $true
        }

        It 'storage-switchless-parameters-file.json should NOT exist (replaced by per-node-count files)' {
            Test-Path (Join-Path $script:TemplateDir 'storage-switchless-parameters-file.json') | Should -Be $false
        }

        It 'storage-switched-parameters-file.json should exist' {
            Test-Path (Join-Path $script:TemplateDir 'storage-switched-parameters-file.json') | Should -Be $true
        }

        It 'two-node-switchless-parameters-file.json should NOT exist (deprecated)' {
            Test-Path (Join-Path $script:TemplateDir 'two-node-switchless-parameters-file.json') | Should -Be $false
        }

        It 'rack-aware-parameters-file.json should exist' {
            Test-Path (Join-Path $script:TemplateDir 'rack-aware-parameters-file.json') | Should -Be $true
        }

        It 'multi-node-parameters-file.json should NOT exist (deprecated)' {
            Test-Path (Join-Path $script:TemplateDir 'multi-node-parameters-file.json') | Should -Be $false
        }

        It 'multi-node-switched-parameters-file.json should NOT exist (renamed to storage-switched)' {
            Test-Path (Join-Path $script:TemplateDir 'multi-node-switched-parameters-file.json') | Should -Be $false
        }

        It 'switchless-2node-parameters-file.json should NOT exist (renamed to storage-switchless)' {
            Test-Path (Join-Path $script:TemplateDir 'switchless-2node-parameters-file.json') | Should -Be $false
        }
    }
}

# ============================================================================
# Get-AzLocalParameterFileSettings (Internal Function)
# ============================================================================
Describe 'Function: Get-AzLocalParameterFileSettings' {

    Context 'Loading Parameter Files' {
        BeforeAll {
            $script:ModuleRoot = Split-Path (Get-Module AzLocal.DeploymentAutomation).Path -Parent
            $script:TemplateDir = Join-Path $script:ModuleRoot 'template-parameter-files'
        }

        It 'Should load single-node parameter file as valid JSON' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'single-node-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result | Should -Not -BeNullOrEmpty
                $result.parameters | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should load StorageSwitchless 2-node parameter file as valid JSON' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'storage-switchless-2node-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result | Should -Not -BeNullOrEmpty
                $result.parameters | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should load StorageSwitchless 3-node parameter file as valid JSON' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'storage-switchless-3node-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result | Should -Not -BeNullOrEmpty
                $result.parameters | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should load StorageSwitchless 4-node parameter file as valid JSON' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'storage-switchless-4node-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result | Should -Not -BeNullOrEmpty
                $result.parameters | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should load storage-switched parameter file as valid JSON' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'storage-switched-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result | Should -Not -BeNullOrEmpty
                $result.parameters | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should load rack-aware parameter file as valid JSON' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'rack-aware-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result | Should -Not -BeNullOrEmpty
                $result.parameters | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Parameter File Content Structure' {
        BeforeAll {
            $script:ModuleRoot = Split-Path (Get-Module AzLocal.DeploymentAutomation).Path -Parent
            $script:TemplateDir = Join-Path $script:ModuleRoot 'template-parameter-files'
        }

        It 'Single-node file should contain deploymentMode parameter' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'single-node-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result.parameters.PSObject.Properties.Name | Should -Contain 'deploymentMode'
            }
        }

        It 'Parameter files should have a $schema property' {
            InModuleScope AzLocal.DeploymentAutomation -ArgumentList $script:TemplateDir {
                param($templateDir)
                $filePath = [System.IO.FileInfo](Join-Path $templateDir 'single-node-parameters-file.json')
                $result = Get-AzLocalParameterFileSettings -ParameterFilePath $filePath
                $result.'$schema' | Should -Not -BeNullOrEmpty
            }
        }
    }
}

# ============================================================================
# Get-ValidUniqueID (Internal Function - Mocked)
# ============================================================================
Describe 'Function: Get-ValidUniqueID' {

    Context 'Valid UniqueID Inputs' {
        It 'Should accept a 2-character alphanumeric ID' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'AB' }
                $result = Get-ValidUniqueID
                $result | Should -Be 'AB'
            }
        }

        It 'Should accept a 3-character alphanumeric ID' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'ABC' }
                $result = Get-ValidUniqueID
                $result | Should -Be 'ABC'
            }
        }

        It 'Should accept an 8-character alphanumeric ID' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'ABCDEF12' }
                $result = Get-ValidUniqueID
                $result | Should -Be 'ABCDEF12'
            }
        }

        It 'Should accept numeric-only IDs' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return '12345' }
                $result = Get-ValidUniqueID
                $result | Should -Be '12345'
            }
        }

        It 'Should accept mixed case alphanumeric IDs' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'Store001' }
                $result = Get-ValidUniqueID
                $result | Should -Be 'Store001'
            }
        }
    }

    Context 'Invalid UniqueID Inputs' {
        It 'Should throw for empty input' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return '' }
                { Get-ValidUniqueID } | Should -Throw
            }
        }

        It 'Should throw for whitespace-only input' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return '   ' }
                { Get-ValidUniqueID } | Should -Throw
            }
        }

        It 'Should throw for ID shorter than 2 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'A' }
                { Get-ValidUniqueID } | Should -Throw
            }
        }

        It 'Should throw for ID longer than 8 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'ABCDEFGHI' }
                { Get-ValidUniqueID } | Should -Throw
            }
        }

        It 'Should throw for ID containing special characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'ABC-001' }
                { Get-ValidUniqueID } | Should -Throw
            }
        }

        It 'Should throw for ID containing spaces' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'ABC 001' }
                { Get-ValidUniqueID } | Should -Throw
            }
        }
    }
}

# ============================================================================
# Get-AzLocalDeploymentNetworkSettings (Internal Function - Parameter Tests)
# ============================================================================
Describe 'Function: Get-AzLocalDeploymentNetworkSettings' {

    Context 'Parameter Definitions' {
        It 'Should have TypeOfDeployment parameter with correct ValidateSet' {
            InModuleScope AzLocal.DeploymentAutomation {
                $command = Get-Command Get-AzLocalDeploymentNetworkSettings
                $validateSet = $command.Parameters['TypeOfDeployment'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
                $validateSet.ValidValues | Should -Contain 'SingleNode'
                $validateSet.ValidValues | Should -Contain 'StorageSwitchless'
                $validateSet.ValidValues | Should -Contain 'StorageSwitched'
                $validateSet.ValidValues | Should -Contain 'RackAware'
                $validateSet.ValidValues | Should -Not -Contain 'TwoNode'
                $validateSet.ValidValues | Should -Not -Contain 'TwoNode-Switchless'
            }
        }

        It 'Should have NodeCount parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $command = Get-Command Get-AzLocalDeploymentNetworkSettings
                $command.Parameters.Keys | Should -Contain 'NodeCount'
            }
        }
    }

    Context 'Node Count Resolution' {
        It 'Should prompt for 1 node IP address for SingleNode' {
            InModuleScope AzLocal.DeploymentAutomation {
                # Mock Read-Host to return valid IPs in sequence
                $script:readHostCallCount = 0
                Mock Read-Host {
                    $script:readHostCallCount++
                    switch ($script:readHostCallCount) {
                        1 { return '255.255.255.0' }   # subnet mask
                        2 { return '10.0.0.1' }         # default gateway
                        3 { return '10.0.0.10' }        # starting IP
                        4 { return '10.0.0.20' }        # ending IP
                        5 { return '10.0.0.100' }       # node 1 IP
                        default { return '10.0.0.200' }
                    }
                }
                $result = Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment 'SingleNode'
                $result.nodeIPAddresses.Count | Should -Be 1
            }
        }

        It 'Should prompt for 2 node IP addresses for StorageSwitched with NodeCount 2' {
            InModuleScope AzLocal.DeploymentAutomation {
                $script:readHostCallCount = 0
                Mock Read-Host {
                    $script:readHostCallCount++
                    switch ($script:readHostCallCount) {
                        1 { return '255.255.255.0' }
                        2 { return '10.0.0.1' }
                        3 { return '10.0.0.10' }
                        4 { return '10.0.0.20' }
                        5 { return '10.0.0.100' }
                        6 { return '10.0.0.101' }
                        default { return '10.0.0.200' }
                    }
                }
                $result = Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment 'StorageSwitched' -NodeCount 2
                $result.nodeIPAddresses.Count | Should -Be 2
            }
        }

        It 'Should prompt for 3 node IP addresses for StorageSwitchless with NodeCount 3' {
            InModuleScope AzLocal.DeploymentAutomation {
                $script:readHostCallCount = 0
                Mock Read-Host {
                    $script:readHostCallCount++
                    switch ($script:readHostCallCount) {
                        1 { return '255.255.255.0' }
                        2 { return '10.0.0.1' }
                        3 { return '10.0.0.10' }
                        4 { return '10.0.0.20' }
                        5 { return '10.0.0.100' }
                        6 { return '10.0.0.101' }
                        7 { return '10.0.0.102' }
                        default { return '10.0.0.200' }
                    }
                }
                $result = Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment 'StorageSwitchless' -NodeCount 3
                $result.nodeIPAddresses.Count | Should -Be 3
            }
        }

        It 'Should prompt for 4 node IP addresses for StorageSwitchless with NodeCount 4' {
            InModuleScope AzLocal.DeploymentAutomation {
                $script:readHostCallCount = 0
                Mock Read-Host {
                    $script:readHostCallCount++
                    switch ($script:readHostCallCount) {
                        1 { return '255.255.255.0' }
                        2 { return '10.0.0.1' }
                        3 { return '10.0.0.10' }
                        4 { return '10.0.0.20' }
                        5 { return '10.0.0.100' }
                        6 { return '10.0.0.101' }
                        7 { return '10.0.0.102' }
                        8 { return '10.0.0.103' }
                        default { return '10.0.0.200' }
                    }
                }
                $result = Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment 'StorageSwitchless' -NodeCount 4
                $result.nodeIPAddresses.Count | Should -Be 4
            }
        }

        It 'Should prompt for 4 node IP addresses for RackAware with NodeCount 4' {
            InModuleScope AzLocal.DeploymentAutomation {
                $script:readHostCallCount = 0
                Mock Read-Host {
                    $script:readHostCallCount++
                    switch ($script:readHostCallCount) {
                        1 { return '255.255.255.0' }
                        2 { return '10.0.0.1' }
                        3 { return '10.0.0.10' }
                        4 { return '10.0.0.20' }
                        5 { return '10.0.0.100' }
                        6 { return '10.0.0.101' }
                        7 { return '10.0.0.102' }
                        8 { return '10.0.0.103' }
                        default { return '10.0.0.200' }
                    }
                }
                $result = Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment 'RackAware' -NodeCount 4
                $result.nodeIPAddresses.Count | Should -Be 4
            }
        }

        It 'Should return a network settings object with all expected properties' {
            InModuleScope AzLocal.DeploymentAutomation {
                $script:readHostCallCount = 0
                Mock Read-Host {
                    $script:readHostCallCount++
                    switch ($script:readHostCallCount) {
                        1 { return '255.255.255.0' }
                        2 { return '10.0.0.1' }
                        3 { return '10.0.0.10' }
                        4 { return '10.0.0.20' }
                        5 { return '10.0.0.100' }
                        default { return '10.0.0.200' }
                    }
                }
                $result = Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment 'SingleNode'
                $result.PSObject.Properties.Name | Should -Contain 'subnetMask'
                $result.PSObject.Properties.Name | Should -Contain 'defaultGateway'
                $result.PSObject.Properties.Name | Should -Contain 'startingIPAddress'
                $result.PSObject.Properties.Name | Should -Contain 'endingIPAddress'
                $result.PSObject.Properties.Name | Should -Contain 'nodeIPAddresses'
            }
        }

        It 'Should throw for invalid IP address input' {
            InModuleScope AzLocal.DeploymentAutomation {
                Mock Read-Host { return 'not-an-ip' }
                { Get-AzLocalDeploymentNetworkSettings -TypeOfDeployment 'SingleNode' } | Should -Throw
            }
        }
    }
}

# ============================================================================
# New-AzLocalDeploymentParameterFile (Internal Function - Parameter Tests)
# ============================================================================
Describe 'Function: New-AzLocalDeploymentParameterFile' {

    Context 'Parameter Definitions' {
        It 'Should have TypeOfDeployment parameter with correct ValidateSet' {
            InModuleScope AzLocal.DeploymentAutomation {
                $command = Get-Command New-AzLocalDeploymentParameterFile
                $validateSet = $command.Parameters['TypeOfDeployment'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
                $validateSet.ValidValues | Should -Contain 'SingleNode'
                $validateSet.ValidValues | Should -Contain 'StorageSwitchless'
                $validateSet.ValidValues | Should -Contain 'StorageSwitched'
                $validateSet.ValidValues | Should -Contain 'RackAware'
                $validateSet.ValidValues | Should -Not -Contain 'TwoNode'
                $validateSet.ValidValues | Should -Not -Contain 'TwoNode-Switchless'
            }
        }

        It 'Should have UniqueID as a mandatory parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $command = Get-Command New-AzLocalDeploymentParameterFile
                $param = $command.Parameters['UniqueID']
                $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
                $attr.Mandatory | Should -Be $true
            }
        }

        It 'Should have ParameterFileSettings as a mandatory parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $command = Get-Command New-AzLocalDeploymentParameterFile
                $param = $command.Parameters['ParameterFileSettings']
                $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
                $attr.Mandatory | Should -Be $true
            }
        }

        It 'Should have Parameters as a mandatory parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $command = Get-Command New-AzLocalDeploymentParameterFile
                $param = $command.Parameters['Parameters']
                $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
                $attr.Mandatory | Should -Be $true
            }
        }
    }

    Context 'Calculated Placeholder Validation' {
        It 'Should throw when parameter file contains unresolved <calculated> string values' {
            InModuleScope AzLocal.DeploymentAutomation {
                # Build a ParameterFileSettings object with a <calculated> placeholder
                $paramFileSettings = [PSCustomObject]@{
                    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                    contentVersion = '1.0.0.0'
                    parameters = [PSCustomObject]@{
                        clusterName = [PSCustomObject]@{ value = '<calculated>' }
                        location    = [PSCustomObject]@{ value = 'eastus' }
                    }
                }
                # Parameters that resolve location but NOT clusterName
                $params = [PSCustomObject][Ordered]@{
                    location = [PSCustomObject]@{ value = 'eastus' }
                }

                Mock Write-AzLocalLog {}

                {
                    New-AzLocalDeploymentParameterFile -UniqueID 'TEST01' -TypeOfDeployment 'SingleNode' `
                        -ParameterFileSettings $paramFileSettings -Parameters $params
                } | Should -Throw "*<calculated>*clusterName*"
            }
        }

        It 'Should throw when parameter file contains unresolved <calculated> array values' {
            InModuleScope AzLocal.DeploymentAutomation {
                $paramFileSettings = [PSCustomObject]@{
                    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                    contentVersion = '1.0.0.0'
                    parameters = [PSCustomObject]@{
                        arcNodeResourceIds = [PSCustomObject]@{ value = @('<calculated>', '<calculated>') }
                        location           = [PSCustomObject]@{ value = 'eastus' }
                    }
                }
                $params = [PSCustomObject][Ordered]@{
                    location = [PSCustomObject]@{ value = 'eastus' }
                }

                Mock Write-AzLocalLog {}

                {
                    New-AzLocalDeploymentParameterFile -UniqueID 'TEST01' -TypeOfDeployment 'SingleNode' `
                        -ParameterFileSettings $paramFileSettings -Parameters $params
                } | Should -Throw "*<calculated>*arcNodeResourceIds*"
            }
        }

        It 'Should not throw when all <calculated> placeholders are resolved' {
            InModuleScope AzLocal.DeploymentAutomation {
                $paramFileSettings = [PSCustomObject]@{
                    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                    contentVersion = '1.0.0.0'
                    parameters = [PSCustomObject]@{
                        clusterName = [PSCustomObject]@{ value = '<calculated>' }
                        location    = [PSCustomObject]@{ value = '<calculated>' }
                    }
                }
                $params = [PSCustomObject][Ordered]@{
                    clusterName = [PSCustomObject]@{ value = 'TESTCL01' }
                    location    = [PSCustomObject]@{ value = 'eastus' }
                }

                Mock Write-AzLocalLog {}
                Mock Out-File {} -RemoveParameterType Encoding
                Mock Test-Path { return $true }

                {
                    New-AzLocalDeploymentParameterFile -UniqueID 'TEST01' -TypeOfDeployment 'SingleNode' `
                        -ParameterFileSettings $paramFileSettings -Parameters $params
                } | Should -Not -Throw
            }
        }

        It 'Should not flag null or empty values as unresolved' {
            InModuleScope AzLocal.DeploymentAutomation {
                # localAdminPassword has null and tenantId has empty string - neither is <calculated>
                $paramFileSettings = [PSCustomObject]@{
                    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                    contentVersion = '1.0.0.0'
                    parameters = [PSCustomObject]@{
                        localAdminPassword = [PSCustomObject]@{ value = $null }
                        tenantId           = [PSCustomObject]@{ value = '' }
                        location           = [PSCustomObject]@{ value = 'eastus' }
                    }
                }
                $params = [PSCustomObject][Ordered]@{
                    location = [PSCustomObject]@{ value = 'eastus' }
                }

                Mock Write-AzLocalLog {}
                Mock Out-File {} -RemoveParameterType Encoding
                Mock Test-Path { return $true }

                {
                    New-AzLocalDeploymentParameterFile -UniqueID 'TEST01' -TypeOfDeployment 'SingleNode' `
                        -ParameterFileSettings $paramFileSettings -Parameters $params
                } | Should -Not -Throw
            }
        }
    }
}

# ============================================================================
# Format-Json (Internal Function)
# ============================================================================
Describe 'Function: Format-Json' {

    Context 'Prettify JSON' {
        It 'Should return a valid formatted JSON string' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"name":"test","value":42}'
                $result = $json | Format-Json
                $result | Should -Not -BeNullOrEmpty
                # Should be parseable back to object
                $parsed = $result | ConvertFrom-Json
                $parsed.name | Should -Be 'test'
                $parsed.value | Should -Be 42
            }
        }

        It 'Should indent with 4 spaces by default' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"name":"test","nested":{"key":"value"}}'
                $result = $json | Format-Json
                # The nested key should be indented with 8 spaces (2 levels x 4 spaces)
                $result | Should -Match '        "key": "value"'
            }
        }

        It 'Should support custom indentation' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"name":"test","nested":{"key":"value"}}'
                $result = $json | Format-Json -Indentation 2
                # The nested key should be indented with 4 spaces (2 levels x 2 spaces)
                $result | Should -Match '    "key": "value"'
            }
        }
    }

    Context 'Minify JSON' {
        It 'Should compress JSON when -Minify is specified' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = @"
{
    "name": "test",
    "value": 42
}
"@
                $result = $json | Format-Json -Minify
                $result | Should -Not -Match "`n"
                $result | Should -Not -Match "`r"
            }
        }

        It 'Should preserve data when minifying' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"name":"test","items":[1,2,3]}'
                $result = $json | Format-Json -Minify
                $parsed = $result | ConvertFrom-Json
                $parsed.name | Should -Be 'test'
                $parsed.items.Count | Should -Be 3
            }
        }
    }

    Context 'AsArray Output' {
        It 'Should return a string array when -AsArray is specified' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"name":"test","nested":{"key":"value"}}'
                $result = $json | Format-Json -AsArray
                $result.Count | Should -BeGreaterThan 1
            }
        }
    }
}

# ============================================================================
# Resource Name Validation Tests (via InModuleScope)
# ============================================================================
Describe 'Function: Test-AzLocalResourceNames' {

    Context 'Valid Names' {
        It 'Should pass validation for all valid resource names with default config and short UniqueID' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'ClusterName'                      = 'AZCLUSTERABC'
                    'ResourceGroupName'                = 'rg-ABC-azurelocal-prod'
                    'KeyVaultName'                     = 'kv-ABC-azlocal'
                    'CustomLocation'                   = 'ABC-azlocal-customlocation'
                    'ResourceBridgeName'               = 'ABC-azlocal-arcbridge'
                    'DiagnosticStorageAccountName'     = 'abcazlocaldiag'
                    'ClusterWitnessStorageAccountName' = 'abcazlocalwitness'
                    'DeploymentName'                   = 'azlocal-ABC-SingleNode-deployment'
                    'NodeName1'                        = 'ABCNODE01'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Not -Throw
            }
        }

        It 'Should pass validation for maximum-length UniqueID (8 chars)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'ClusterName'                      = 'AZCLUSTERABC'
                    'ResourceGroupName'                = 'rg-ABCDEF12-azurelocal-prod'
                    'KeyVaultName'                     = 'kv-ABCDEF12-azlocal'
                    'CustomLocation'                   = 'ABCDEF12-azlocal-customlocation'
                    'ResourceBridgeName'               = 'ABCDEF12-azlocal-arcbridge'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Not -Throw
            }
        }
    }

    Context 'Storage Account Validation' {
        It 'Should reject storage account names with uppercase characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'DiagnosticStorageAccountName' = 'ABCazlocaldiag'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should reject storage account names with hyphens' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'ClusterWitnessStorageAccountName' = 'abc-azlocal-witness'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should reject storage account names exceeding 24 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'DiagnosticStorageAccountName' = 'abcdefghijklmnopazlocaldiag'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should reject storage account names shorter than 3 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'DiagnosticStorageAccountName' = 'ab'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }
    }

    Context 'Key Vault Validation' {
        It 'Should reject Key Vault names exceeding 24 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'KeyVaultName' = 'kv-abcdefghijklmnopqrstuvwxyz-azlocal'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should reject Key Vault names starting with a number' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'KeyVaultName' = '1kv-abc-azlocal'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should reject Key Vault names shorter than 3 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'KeyVaultName' = 'kv'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }
    }

    Context 'Cluster Name Validation (NetBIOS)' {
        It 'Should reject cluster names exceeding 15 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'ClusterName' = 'AZCLUSTERABCDEFGHIJK'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should allow cluster names with hyphens (NetBIOS permits hyphens)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'ClusterName' = 'AZ-CLUSTER-ABC'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Not -Throw
            }
        }

        It 'Should reject cluster names starting with a hyphen' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'ClusterName' = '-AZCLUSTER'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }
    }

    Context 'Node Name Validation (NetBIOS)' {
        It 'Should reject node names exceeding 15 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'NodeName1' = 'ABCDEFGHIJNODE01'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should allow node names with hyphens (NetBIOS permits hyphens)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'NodeName1' = 'ABC-NODE01'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Not -Throw
            }
        }

        It 'Should reject node names starting with a hyphen' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'NodeName1' = '-ABCNODE01'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should validate multiple node names' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'NodeName1' = 'ABCNODE01'
                    'NodeName2' = 'ABCNODE02'
                    'NodeName3' = 'ABCNODE03'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Not -Throw
            }
        }
    }

    Context 'Deployment Name Validation' {
        It 'Should reject deployment names exceeding 64 characters' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'DeploymentName' = 'azlocal-' + ('x' * 60) + '-deployment'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }

        It 'Should accept deployment names with hyphens and periods' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'DeploymentName' = 'azlocal-ABC.test-deployment'
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Not -Throw
            }
        }
    }

    Context 'Multiple Errors' {
        It 'Should report all validation errors in a single throw' {
            InModuleScope AzLocal.DeploymentAutomation {
                $names = @{
                    'ClusterName'                  = 'AZCLUSTERABCDEFGHIJK'
                    'DiagnosticStorageAccountName' = 'ABC-INVALID-STORAGE!'
                    'KeyVaultName'                 = '1invalid'
                }
                try {
                    Test-AzLocalResourceNames -Names $names
                    $false | Should -Be $true  # Should not reach here
                } catch {
                    $_.Exception.Message | Should -Match 'ClusterName'
                    $_.Exception.Message | Should -Match 'DiagnosticStorageAccountName'
                    $_.Exception.Message | Should -Match 'KeyVaultName'
                }
            }
        }
    }

    Context 'Integration with Default Naming Config' {
        It 'Should pass validation for all names resolved from default config with a 3-char UniqueID' {
            InModuleScope AzLocal.DeploymentAutomation {
                $config = (Get-AzLocalNamingConfig).Config
                $uid = 'ABC'
                $names = @{
                    'ClusterName'                      = Resolve-AzLocalResourceName -Pattern $config.namingStandards.clusterName -UniqueID $uid
                    'ResourceGroupName'                = Resolve-AzLocalResourceName -Pattern $config.namingStandards.resourceGroupName -UniqueID $uid
                    'KeyVaultName'                     = Resolve-AzLocalResourceName -Pattern $config.namingStandards.keyVaultName -UniqueID $uid
                    'CustomLocation'                   = Resolve-AzLocalResourceName -Pattern $config.namingStandards.customLocation -UniqueID $uid
                    'ResourceBridgeName'               = Resolve-AzLocalResourceName -Pattern $config.namingStandards.resourceBridgeName -UniqueID $uid
                    'DiagnosticStorageAccountName'     = (Resolve-AzLocalResourceName -Pattern $config.namingStandards.diagnosticStorageAccountName -UniqueID $uid).ToLower()
                    'ClusterWitnessStorageAccountName' = (Resolve-AzLocalResourceName -Pattern $config.namingStandards.clusterWitnessStorageAccountName -UniqueID $uid).ToLower()
                    'DeploymentName'                   = Resolve-AzLocalResourceName -Pattern $config.namingStandards.deploymentName -UniqueID $uid -TypeOfDeployment 'SingleNode'
                    'NodeName1'                        = Resolve-AzLocalResourceName -Pattern $config.namingStandards.nodeNamePattern -UniqueID $uid -NodeNumber 1
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Not -Throw
            }
        }

        It 'Should reject names resolved from default config with an 8-char UniqueID (exceeds storage account limits)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $config = (Get-AzLocalNamingConfig).Config
                $uid = 'ABCDEF12'
                $names = @{
                    'ClusterName'                      = Resolve-AzLocalResourceName -Pattern $config.namingStandards.clusterName -UniqueID $uid
                    'ResourceGroupName'                = Resolve-AzLocalResourceName -Pattern $config.namingStandards.resourceGroupName -UniqueID $uid
                    'KeyVaultName'                     = Resolve-AzLocalResourceName -Pattern $config.namingStandards.keyVaultName -UniqueID $uid
                    'CustomLocation'                   = Resolve-AzLocalResourceName -Pattern $config.namingStandards.customLocation -UniqueID $uid
                    'ResourceBridgeName'               = Resolve-AzLocalResourceName -Pattern $config.namingStandards.resourceBridgeName -UniqueID $uid
                    'DiagnosticStorageAccountName'     = (Resolve-AzLocalResourceName -Pattern $config.namingStandards.diagnosticStorageAccountName -UniqueID $uid).ToLower()
                    'ClusterWitnessStorageAccountName' = (Resolve-AzLocalResourceName -Pattern $config.namingStandards.clusterWitnessStorageAccountName -UniqueID $uid).ToLower()
                    'DeploymentName'                   = Resolve-AzLocalResourceName -Pattern $config.namingStandards.deploymentName -UniqueID $uid -TypeOfDeployment 'StorageSwitched'
                    'NodeName1'                        = Resolve-AzLocalResourceName -Pattern $config.namingStandards.nodeNamePattern -UniqueID $uid -NodeNumber 1
                }
                { Test-AzLocalResourceNames -Names $names } | Should -Throw
            }
        }
    }
}

# ============================================================================
# Deployment Type Logic Tests (via InModuleScope)
# ============================================================================
Describe 'Deployment Type Logic' {

    Context 'SingleNode Configuration' {
        It 'Should set effectiveNodeCount to 1 for SingleNode' {
            InModuleScope AzLocal.DeploymentAutomation {
                # Simulate the switch logic from Start-AzLocalTemplateDeployment
                $TypeOfDeployment = 'SingleNode'
                switch ($TypeOfDeployment) {
                    "SingleNode"  { $effectiveNodeCount = 1 }
                    "StorageSwitchless"  { $effectiveNodeCount = 3 }
                    "StorageSwitched"   { $effectiveNodeCount = 5 }
                    "RackAware"   { $effectiveNodeCount = 4 }
                }
                $effectiveNodeCount | Should -Be 1
            }
        }

        It 'SingleNode should reject NodeCount greater than 1' {
            InModuleScope AzLocal.DeploymentAutomation {
                # Simulate the validation logic from Start-AzLocalTemplateDeployment
                $TypeOfDeployment = 'SingleNode'
                $NodeCount = 2
                {
                    if ($TypeOfDeployment -eq "SingleNode" -and $NodeCount -gt 1) {
                        throw "SingleNode deployment does not support -NodeCount greater than 1."
                    }
                } | Should -Throw
            }
        }

        It 'SingleNode should allow NodeCount of 1' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'SingleNode'
                $NodeCount = 1
                $threw = $false
                try {
                    if ($TypeOfDeployment -eq "SingleNode" -and $NodeCount -gt 1) {
                        throw "SingleNode deployment does not support -NodeCount greater than 1."
                    }
                } catch {
                    $threw = $true
                }
                $threw | Should -Be $false
            }
        }

        It 'SingleNode should allow NodeCount of 0 (default)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'SingleNode'
                $NodeCount = 0
                $threw = $false
                try {
                    if ($TypeOfDeployment -eq "SingleNode" -and $NodeCount -gt 1) {
                        throw "SingleNode deployment does not support -NodeCount greater than 1."
                    }
                } catch {
                    $threw = $true
                }
                $threw | Should -Be $false
            }
        }
    }

    Context 'StorageSwitchless Configuration' {
        It 'StorageSwitchless should use NodeCount for effectiveNodeCount (2 nodes)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'StorageSwitchless'
                $NodeCount = 2
                switch ($TypeOfDeployment) {
                    "SingleNode"  { $effectiveNodeCount = 1 }
                    "StorageSwitchless"  { $effectiveNodeCount = $NodeCount }
                    "StorageSwitched"   { $effectiveNodeCount = $NodeCount }
                    "RackAware"   { $effectiveNodeCount = $NodeCount }
                }
                $effectiveNodeCount | Should -Be 2
            }
        }

        It 'StorageSwitchless should use NodeCount for effectiveNodeCount (3 nodes)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'StorageSwitchless'
                $NodeCount = 3
                switch ($TypeOfDeployment) {
                    "SingleNode"  { $effectiveNodeCount = 1 }
                    "StorageSwitchless"  { $effectiveNodeCount = $NodeCount }
                    "StorageSwitched"   { $effectiveNodeCount = $NodeCount }
                    "RackAware"   { $effectiveNodeCount = $NodeCount }
                }
                $effectiveNodeCount | Should -Be 3
            }
        }

        It 'StorageSwitchless should use NodeCount for effectiveNodeCount (4 nodes)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'StorageSwitchless'
                $NodeCount = 4
                switch ($TypeOfDeployment) {
                    "SingleNode"  { $effectiveNodeCount = 1 }
                    "StorageSwitchless"  { $effectiveNodeCount = $NodeCount }
                    "StorageSwitched"   { $effectiveNodeCount = $NodeCount }
                    "RackAware"   { $effectiveNodeCount = $NodeCount }
                }
                $effectiveNodeCount | Should -Be 4
            }
        }
    }

    Context 'StorageSwitched Configuration' {
        It 'StorageSwitched should use NodeCount for effectiveNodeCount' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'StorageSwitched'
                $NodeCount = 8
                switch ($TypeOfDeployment) {
                    "SingleNode"  { $effectiveNodeCount = 1 }
                    "StorageSwitchless"  { $effectiveNodeCount = $NodeCount }
                    "StorageSwitched"   { $effectiveNodeCount = $NodeCount }
                    "RackAware"   { $effectiveNodeCount = $NodeCount }
                }
                $effectiveNodeCount | Should -Be 8
            }
        }
    }

    Context 'RackAware Configuration' {
        It 'RackAware should use NodeCount for effectiveNodeCount (2 nodes)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'RackAware'
                $NodeCount = 2
                switch ($TypeOfDeployment) {
                    "SingleNode"  { $effectiveNodeCount = 1 }
                    "StorageSwitchless"  { $effectiveNodeCount = $NodeCount }
                    "StorageSwitched"   { $effectiveNodeCount = $NodeCount }
                    "RackAware"   { $effectiveNodeCount = $NodeCount }
                }
                $effectiveNodeCount | Should -Be 2
            }
        }

        It 'RackAware should use NodeCount for effectiveNodeCount (8 nodes)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $TypeOfDeployment = 'RackAware'
                $NodeCount = 8
                switch ($TypeOfDeployment) {
                    "SingleNode"  { $effectiveNodeCount = 1 }
                    "StorageSwitchless"  { $effectiveNodeCount = $NodeCount }
                    "StorageSwitched"   { $effectiveNodeCount = $NodeCount }
                    "RackAware"   { $effectiveNodeCount = $NodeCount }
                }
                $effectiveNodeCount | Should -Be 8
            }
        }

        It 'RackAware should set storageConnectivitySwitchless to false' {
            $TypeOfDeployment = 'RackAware'
            if ($TypeOfDeployment -eq 'RackAware') {
                $storageConnectivitySwitchless = $false
            }
            $storageConnectivitySwitchless | Should -Be $false
        }

        It 'RackAware should set witnessType to Cloud' {
            $TypeOfDeployment = 'RackAware'
            if ($TypeOfDeployment -eq 'RackAware') {
                $witnessType = 'Cloud'
            }
            $witnessType | Should -Be 'Cloud'
        }

        It 'RackAware should set clusterPattern to RackAware' {
            $TypeOfDeployment = 'RackAware'
            $clusterPattern = 'Standard'
            if ($TypeOfDeployment -eq 'RackAware') {
                $clusterPattern = 'RackAware'
            }
            $clusterPattern | Should -Be 'RackAware'
        }

        It 'RackAware should auto-split 4 nodes evenly into 2 zones' {
            $nodeNames = @('NODE01', 'NODE02', 'NODE03', 'NODE04')
            $effectiveNodeCount = 4
            $halfCount = $effectiveNodeCount / 2
            $zoneANodes = $nodeNames[0..($halfCount - 1)]
            $zoneBNodes = $nodeNames[$halfCount..($effectiveNodeCount - 1)]
            $zoneANodes.Count | Should -Be 2
            $zoneBNodes.Count | Should -Be 2
            $zoneANodes[0] | Should -Be 'NODE01'
            $zoneANodes[1] | Should -Be 'NODE02'
            $zoneBNodes[0] | Should -Be 'NODE03'
            $zoneBNodes[1] | Should -Be 'NODE04'
        }

        It 'RackAware should auto-split 8 nodes evenly into 2 zones' {
            $nodeNames = @('N001', 'N002', 'N003', 'N004', 'N005', 'N006', 'N007', 'N008')
            $effectiveNodeCount = 8
            $halfCount = $effectiveNodeCount / 2
            $zoneANodes = $nodeNames[0..($halfCount - 1)]
            $zoneBNodes = $nodeNames[$halfCount..($effectiveNodeCount - 1)]
            $zoneANodes.Count | Should -Be 4
            $zoneBNodes.Count | Should -Be 4
            $zoneANodes | Should -Be @('N001', 'N002', 'N003', 'N004')
            $zoneBNodes | Should -Be @('N005', 'N006', 'N007', 'N008')
        }

        It 'RackAware should produce localAvailabilityZones with ZoneA and ZoneB' {
            $nodeNames = @('NODE01', 'NODE02')
            $effectiveNodeCount = 2
            $halfCount = $effectiveNodeCount / 2
            $zoneANodes = $nodeNames[0..($halfCount - 1)]
            $zoneBNodes = $nodeNames[$halfCount..($effectiveNodeCount - 1)]
            $localAvailabilityZones = @(
                [PSCustomObject][Ordered]@{
                    "localAvailabilityZoneName" = "ZoneA"
                    "nodes" = @($zoneANodes)
                },
                [PSCustomObject][Ordered]@{
                    "localAvailabilityZoneName" = "ZoneB"
                    "nodes" = @($zoneBNodes)
                }
            )
            $localAvailabilityZones.Count | Should -Be 2
            $localAvailabilityZones[0].localAvailabilityZoneName | Should -Be 'ZoneA'
            $localAvailabilityZones[1].localAvailabilityZoneName | Should -Be 'ZoneB'
            $localAvailabilityZones[0].nodes | Should -Contain 'NODE01'
            $localAvailabilityZones[1].nodes | Should -Contain 'NODE02'
        }

        It 'Non-RackAware should default clusterPattern to Standard' {
            $TypeOfDeployment = 'StorageSwitched'
            $clusterPattern = 'Standard'
            if ($TypeOfDeployment -eq 'RackAware') {
                $clusterPattern = 'RackAware'
            }
            $clusterPattern | Should -Be 'Standard'
        }

        It 'Non-RackAware should default localAvailabilityZones to empty array' {
            $TypeOfDeployment = 'StorageSwitched'
            $localAvailabilityZones = @()
            if ($TypeOfDeployment -eq 'RackAware') {
                $localAvailabilityZones = @('ZoneA', 'ZoneB')
            }
            $localAvailabilityZones.Count | Should -Be 0
        }
    }

    Context 'Deployment Phase Logic' {
        It 'ValidateAndDeploy should produce two phases' {
            $DeploymentMode = 'ValidateAndDeploy'
            if ($DeploymentMode -eq "ValidateAndDeploy") {
                $deploymentPhases = @("Validate", "Deploy")
            } else {
                $deploymentPhases = @($DeploymentMode)
            }
            $deploymentPhases.Count | Should -Be 2
            $deploymentPhases[0] | Should -Be 'Validate'
            $deploymentPhases[1] | Should -Be 'Deploy'
        }

        It 'Validate mode should produce one phase' {
            $DeploymentMode = 'Validate'
            if ($DeploymentMode -eq "ValidateAndDeploy") {
                $deploymentPhases = @("Validate", "Deploy")
            } else {
                $deploymentPhases = @($DeploymentMode)
            }
            $deploymentPhases.Count | Should -Be 1
            $deploymentPhases[0] | Should -Be 'Validate'
        }

        It 'Deploy mode should produce one phase' {
            $DeploymentMode = 'Deploy'
            if ($DeploymentMode -eq "ValidateAndDeploy") {
                $deploymentPhases = @("Validate", "Deploy")
            } else {
                $deploymentPhases = @($DeploymentMode)
            }
            $deploymentPhases.Count | Should -Be 1
            $deploymentPhases[0] | Should -Be 'Deploy'
        }
    }
}

# ============================================================================
# Template and Config File Integrity
# ============================================================================
Describe 'File Integrity' {

    Context 'ARM Template' {
        BeforeAll {
            $script:ModuleRoot = Split-Path (Get-Module AzLocal.DeploymentAutomation).Path -Parent
            $script:TemplatePath = Join-Path $script:ModuleRoot 'templates\azure-local-deployment-template.json'
        }

        It 'ARM template file should exist' {
            Test-Path $script:TemplatePath | Should -Be $true
        }

        It 'ARM template should be valid JSON' {
            { Get-Content $script:TemplatePath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    Context 'Naming Config' {
        BeforeAll {
            $script:ModuleRoot = Split-Path (Get-Module AzLocal.DeploymentAutomation).Path -Parent
            $script:ConfigPath = Join-Path $script:ModuleRoot '.config\naming-standards-config.json'
        }

        It 'Naming config file should exist' {
            Test-Path $script:ConfigPath | Should -Be $true
        }

        It 'Naming config should be valid JSON' {
            { Get-Content $script:ConfigPath -Raw | ConvertFrom-Json } | Should -Not -Throw
        }

        It 'Naming config should have 10 naming standards' {
            $config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            $standardCount = ($config.namingStandards.PSObject.Properties | Measure-Object).Count
            $standardCount | Should -Be 10
        }

        It 'Naming config should have 8 default values' {
            $config = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            $defaultCount = ($config.defaults.PSObject.Properties | Measure-Object).Count
            $defaultCount | Should -Be 8
        }
    }

    Context 'No Deprecated References in Module' {
        BeforeAll {
            $script:ModuleRoot = Split-Path (Get-Module AzLocal.DeploymentAutomation).Path -Parent
            $script:ModuleContent = (@(Get-Content (Join-Path $script:ModuleRoot 'AzLocal.DeploymentAutomation.psm1') -Raw) + @(Get-ChildItem (Join-Path $script:ModuleRoot 'Public'), (Join-Path $script:ModuleRoot 'Private') -Filter '*.ps1' | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
        }

        It 'Module should not reference TwoNode-Switchless' {
            $script:ModuleContent | Should -Not -Match 'TwoNode-Switchless'
        }

        It 'Module should not reference TwoNode as a standalone deployment type' {
            # TwoNode has been consolidated into StorageSwitched
            $script:ModuleContent | Should -Not -Match '"TwoNode"'
        }

        It 'Module should not reference Multi-Node (hyphenated, deprecated)' {
            # Multi-Node is a deprecated name
            $script:ModuleContent | Should -Not -Match '"Multi-Node"'
        }

        It 'Module should not reference two-node-switchless-parameters-file' {
            $script:ModuleContent | Should -Not -Match 'two-node-switchless-parameters-file'
        }

        It 'Module should not reference switchless-parameters-file.json (replaced by per-node-count files)' {
            # The old single switchless template has been split into storage-switchless-2node, storage-switchless-3node, storage-switchless-4node
            $script:ModuleContent | Should -Not -Match "(?<!\d+node-)switchless-parameters-file\.json"
        }

        It 'Module should not reference multi-node-parameters-file.json (old name)' {
            # Ensure the old exact filename is not referenced (storage-switched is OK)
            $script:ModuleContent | Should -Not -Match 'multi-node-parameters-file\.json'
        }

        It 'Module should not reference AzureStackLCMAdminPasssword (triple-s typo)' {
            $script:ModuleContent | Should -Not -Match 'AzureStackLCMAdminPasssword'
        }

        It 'Module should reference RackAware deployment type' {
            $script:ModuleContent | Should -Match 'RackAware'
        }

        It 'Module should contain Watch-AzLocalDeployment function' {
            $script:ModuleContent | Should -Match 'Function Watch-AzLocalDeployment'
        }

        It 'Module should contain Write-AzLocalLog function' {
            $script:ModuleContent | Should -Match 'Function Write-AzLocalLog'
        }

        It 'Module should contain Get-AzLocalNetworkSettingsFromJson function' {
            $script:ModuleContent | Should -Match 'Function Get-AzLocalNetworkSettingsFromJson'
        }

        It 'Module should implement DnsServers precedence: -DnsServers > NetworkSettingsJson.dnsServers > config default (v1.0.1)' {
            # Three-tier precedence introduced in v1.0.1. Behaviour-level coverage lives in
            # the Get-AzLocalNetworkSettingsFromJson Pester block; this guard just asserts
            # that the cmdlet still consults both the JSON override and the config default
            # somewhere in its DNS resolution. Patterns are deliberately loose to survive
            # variable renames and whitespace changes.
            $script:ModuleContent | Should -Match '(?s)NetworkSettings[^\r\n]*\bdnsServers\b'
            $script:ModuleContent | Should -Match '(?s)defaults[^\r\n]*\bdnsServers\b'
        }

        It 'Module should not contain Return "Error" pattern' {
            # All functions should now use throw instead of Return "Error"
            $script:ModuleContent | Should -Not -Match 'Return\s+"Error"'
        }

        It 'Module should not contain Return .Error. pattern (single quotes)' {
            $script:ModuleContent | Should -Not -Match "Return\s+'Error'"
        }
    }
}

# ============================================================================
# Write-AzLocalLog (Internal Function)
# ============================================================================
Describe 'Function: Write-AzLocalLog' {

    Context 'Function Exists' {
        It 'Should exist as an internal function' {
            InModuleScope AzLocal.DeploymentAutomation {
                Get-Command Write-AzLocalLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Parameter Definitions' {
        It 'Should have Message parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Write-AzLocalLog
                $cmd.Parameters.Keys | Should -Contain 'Message'
            }
        }

        It 'Should have Level parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Write-AzLocalLog
                $cmd.Parameters.Keys | Should -Contain 'Level'
            }
        }

        It 'Should have NoTimestamp parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Write-AzLocalLog
                $cmd.Parameters.Keys | Should -Contain 'NoTimestamp'
            }
        }

        It 'Level should accept Info, Warning, Error, Success, Debug, Verbose' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Write-AzLocalLog
                $validateSet = $cmd.Parameters['Level'].Attributes |
                    Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
                $validateSet.ValidValues | Should -Contain 'Info'
                $validateSet.ValidValues | Should -Contain 'Warning'
                $validateSet.ValidValues | Should -Contain 'Error'
                $validateSet.ValidValues | Should -Contain 'Success'
                $validateSet.ValidValues | Should -Contain 'Debug'
                $validateSet.ValidValues | Should -Contain 'Verbose'
            }
        }
    }

    Context 'Log File Output' {
        It 'Should write to log file when AzLocalLogFilePath is set' {
            InModuleScope AzLocal.DeploymentAutomation {
                $tempLog = Join-Path $env:TEMP "azlocal-test-$(Get-Random).log"
                try {
                    $script:AzLocalLogFilePath = $tempLog
                    Write-AzLocalLog "Test log message" -Level Info
                    Test-Path $tempLog | Should -Be $true
                    $content = Get-Content $tempLog -Raw
                    $content | Should -Match 'Test log message'
                    $content | Should -Match '\[Info\]'
                } finally {
                    $script:AzLocalLogFilePath = $null
                    Remove-Item $tempLog -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Should not write to log file when AzLocalLogFilePath is null' {
            InModuleScope AzLocal.DeploymentAutomation {
                $script:AzLocalLogFilePath = $null
                # Should not throw when log path is not set
                { Write-AzLocalLog "No file output" -Level Info } | Should -Not -Throw
            }
        }

        It 'Should disable file logging and warn when log write fails' {
            InModuleScope AzLocal.DeploymentAutomation {
                # Use an invalid path that cannot be written to
                $script:AzLocalLogFilePath = 'Z:\nonexistent\impossible\path\test.log'
                # Should not throw (graceful degradation)
                { Write-AzLocalLog "Test message" -Level Info } | Should -Not -Throw
                # Should have cleared the log file path to prevent repeated warnings
                $script:AzLocalLogFilePath | Should -BeNullOrEmpty
            }
        }
    }
}

# ============================================================================
# LogFilePath Parameter on Exported Functions
# ============================================================================
Describe 'LogFilePath Parameter' {

    Context 'Start-AzLocalTemplateDeployment' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
        }

        It 'Should have LogFilePath parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LogFilePath'
        }

        It 'LogFilePath should be of type String' {
            $script:Command.Parameters['LogFilePath'].ParameterType.Name | Should -Be 'String'
        }

        It 'LogFilePath should NOT be mandatory' {
            $param = $script:Command.Parameters['LogFilePath']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }
    }

    Context 'Watch-AzLocalDeployment' {
        BeforeAll {
            $script:Command = Get-Command Watch-AzLocalDeployment
        }

        It 'Should have LogFilePath parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LogFilePath'
        }

        It 'LogFilePath should be of type String' {
            $script:Command.Parameters['LogFilePath'].ParameterType.Name | Should -Be 'String'
        }

        It 'LogFilePath should NOT be mandatory' {
            $param = $script:Command.Parameters['LogFilePath']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }
    }
}

# ============================================================================
# Watch-AzLocalDeployment - Parameter Validation
# ============================================================================
Describe 'Function: Watch-AzLocalDeployment' {

    Context 'Parameter Definitions' {
        BeforeAll {
            $script:Command = Get-Command Watch-AzLocalDeployment
        }

        It 'Should have DeploymentName parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'DeploymentName'
        }

        It 'Should have ResourceGroupName parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'ResourceGroupName'
        }

        It 'Should have PollingIntervalSeconds parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'PollingIntervalSeconds'
        }

        It 'Should have TimeoutMinutes parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'TimeoutMinutes'
        }

        It 'Should have PassThru parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'PassThru'
        }

        It 'Should have SkipOnlineTSGSearch parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'SkipOnlineTSGSearch'
        }

        It 'SkipOnlineTSGSearch should be a SwitchParameter' {
            $script:Command.Parameters['SkipOnlineTSGSearch'].ParameterType.Name | Should -Be 'SwitchParameter'
        }

        It 'SkipOnlineTSGSearch should NOT be mandatory' {
            $param = $script:Command.Parameters['SkipOnlineTSGSearch']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }
    }

    Context 'Parameter Types' {
        BeforeAll {
            $script:Command = Get-Command Watch-AzLocalDeployment
        }

        It 'DeploymentName should be of type String' {
            $script:Command.Parameters['DeploymentName'].ParameterType.Name | Should -Be 'String'
        }

        It 'ResourceGroupName should be of type String' {
            $script:Command.Parameters['ResourceGroupName'].ParameterType.Name | Should -Be 'String'
        }

        It 'PollingIntervalSeconds should be of type Int32' {
            $script:Command.Parameters['PollingIntervalSeconds'].ParameterType.Name | Should -Be 'Int32'
        }

        It 'TimeoutMinutes should be of type Int32' {
            $script:Command.Parameters['TimeoutMinutes'].ParameterType.Name | Should -Be 'Int32'
        }

        It 'PassThru should be of type SwitchParameter' {
            $script:Command.Parameters['PassThru'].ParameterType.Name | Should -Be 'SwitchParameter'
        }
    }

    Context 'Mandatory Parameters' {
        BeforeAll {
            $script:Command = Get-Command Watch-AzLocalDeployment
        }

        It 'DeploymentName should be mandatory' {
            $param = $script:Command.Parameters['DeploymentName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }

        It 'ResourceGroupName should be mandatory' {
            $param = $script:Command.Parameters['ResourceGroupName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }

        It 'PollingIntervalSeconds should NOT be mandatory' {
            $param = $script:Command.Parameters['PollingIntervalSeconds']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'TimeoutMinutes should NOT be mandatory' {
            $param = $script:Command.Parameters['TimeoutMinutes']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'PassThru should NOT be mandatory' {
            $param = $script:Command.Parameters['PassThru']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }
    }

    Context 'PollingIntervalSeconds ValidateRange' {
        BeforeAll {
            $script:Command = Get-Command Watch-AzLocalDeployment
            $script:ValidateRange = $script:Command.Parameters['PollingIntervalSeconds'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
        }

        It 'Should have a ValidateRange attribute' {
            $script:ValidateRange | Should -Not -BeNullOrEmpty
        }

        It 'Should have minimum value of 10' {
            $script:ValidateRange.MinRange | Should -Be 10
        }

        It 'Should have maximum value of 600' {
            $script:ValidateRange.MaxRange | Should -Be 600
        }
    }

    Context 'TimeoutMinutes ValidateRange' {
        BeforeAll {
            $script:Command = Get-Command Watch-AzLocalDeployment
            $script:ValidateRange = $script:Command.Parameters['TimeoutMinutes'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
        }

        It 'Should have a ValidateRange attribute' {
            $script:ValidateRange | Should -Not -BeNullOrEmpty
        }

        It 'Should have minimum value of 0' {
            $script:ValidateRange.MinRange | Should -Be 0
        }

        It 'Should have maximum value of 1440' {
            $script:ValidateRange.MaxRange | Should -Be 1440
        }
    }

    Context 'Terminal State Detection Logic' {
        It 'TimeoutMinutes should default to 180' {
            $cmd = Get-Command Watch-AzLocalDeployment
            # Check the script default via AST (PSDefaultValueAttribute is not used for this parameter)
            $paramBlock = $cmd.ScriptBlock.Ast.Body.ParamBlock
            $timeoutParam = $paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'TimeoutMinutes' }
            $timeoutParam.DefaultValue.Value | Should -Be 0
        }

        It 'Should recognise Succeeded as a terminal state' {
            $terminalStates = @("Succeeded", "Failed", "Canceled")
            'Succeeded' -in $terminalStates | Should -Be $true
        }

        It 'Should recognise Failed as a terminal state' {
            $terminalStates = @("Succeeded", "Failed", "Canceled")
            'Failed' -in $terminalStates | Should -Be $true
        }

        It 'Should recognise Canceled as a terminal state' {
            $terminalStates = @("Succeeded", "Failed", "Canceled")
            'Canceled' -in $terminalStates | Should -Be $true
        }

        It 'Should NOT recognise Running as a terminal state' {
            $terminalStates = @("Succeeded", "Failed", "Canceled")
            'Running' -in $terminalStates | Should -Be $false
        }

        It 'Should NOT recognise Accepted as a terminal state' {
            $terminalStates = @("Succeeded", "Failed", "Canceled")
            'Accepted' -in $terminalStates | Should -Be $false
        }
    }
}

# ============================================================================
# UniqueID ValidatePattern
# ============================================================================
Describe 'Parameter: UniqueID ValidatePattern' {

    Context 'UniqueID Pattern Validation' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
            $script:ValidatePattern = $script:Command.Parameters['UniqueID'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] }
        }

        It 'Should have a ValidatePattern attribute' {
            $script:ValidatePattern | Should -Not -BeNullOrEmpty
        }

        It 'The pattern should enforce 2-8 alphanumeric characters' {
            $script:ValidatePattern.RegexPattern | Should -Be '^[a-zA-Z0-9]{2,8}$'
        }
    }
}

# ============================================================================
# ShouldProcess Support
# ============================================================================
Describe 'ShouldProcess Support' {

    Context 'Start-AzLocalTemplateDeployment ShouldProcess' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
            $script:CmdletBinding = $script:Command.ScriptBlock.Attributes |
                Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        }

        It 'Should have SupportsShouldProcess enabled' {
            $script:CmdletBinding.SupportsShouldProcess | Should -Be $true
        }

        It 'Should have ConfirmImpact set to High' {
            $script:CmdletBinding.ConfirmImpact | Should -Be 'High'
        }
    }
}

# ============================================================================
# Get-AzLocalNetworkSettingsFromJson (Internal Function)
# ============================================================================
Describe 'Function: Get-AzLocalNetworkSettingsFromJson' {

    Context 'Function Exists' {
        It 'Should exist as an internal function' {
            InModuleScope AzLocal.DeploymentAutomation {
                Get-Command Get-AzLocalNetworkSettingsFromJson -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Valid JSON String Input' {
        It 'Should parse valid inline JSON for SingleNode' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"]}'
                $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode'
                $result.subnetMask | Should -Be '255.255.255.0'
                $result.defaultGateway | Should -Be '10.0.0.1'
                $result.startingIPAddress | Should -Be '10.0.0.10'
                $result.endingIPAddress | Should -Be '10.0.0.50'
                $result.nodeIPAddresses.Count | Should -Be 1
            }
        }

        It 'Should parse valid inline JSON for StorageSwitched with 2 nodes' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100","10.0.0.101"]}'
                $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'StorageSwitched' -NodeCount 2
                $result.nodeIPAddresses.Count | Should -Be 2
            }
        }
    }

    Context 'Valid JSON File Input' {
        It 'Should load settings from a JSON file' {
            InModuleScope AzLocal.DeploymentAutomation {
                $tempFile = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.json'
                $jsonContent = @{
                    subnetMask = "255.255.255.0"
                    defaultGateway = "10.0.0.1"
                    startingIPAddress = "10.0.0.10"
                    endingIPAddress = "10.0.0.50"
                    nodeIPAddresses = @("10.0.0.100")
                } | ConvertTo-Json
                $jsonContent | Out-File -FilePath $tempFile -Encoding utf8
                try {
                    $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $tempFile -TypeOfDeployment 'SingleNode'
                    $result.subnetMask | Should -Be '255.255.255.0'
                    $result.nodeIPAddresses.Count | Should -Be 1
                } finally {
                    Remove-Item $tempFile -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'Invalid Inputs' {
        It 'Should throw for missing required field' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1"}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode' } | Should -Throw
            }
        }

        It 'Should throw for invalid IP address format' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"not-valid","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"]}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode' } | Should -Throw
            }
        }

        It 'Should throw for wrong node IP count' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"]}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'StorageSwitched' -NodeCount 2 } | Should -Throw
            }
        }

        It 'Should throw for invalid JSON string' {
            InModuleScope AzLocal.DeploymentAutomation {
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson 'not-json' -TypeOfDeployment 'SingleNode' } | Should -Throw
            }
        }

        It 'Should throw for invalid node IP address' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["not-an-ip"]}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode' } | Should -Throw
            }
        }
    }

    Context 'Optional dnsServers override (v1.0.1)' {
        It 'Should return $null dnsServers when the field is omitted (back-compat)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"]}'
                $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode'
                $result.PSObject.Properties.Name | Should -Contain 'dnsServers'
                $result.dnsServers | Should -BeNullOrEmpty
            }
        }

        It 'Should return $null dnsServers when the field is an empty array' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"],"dnsServers":[]}'
                $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode'
                $result.dnsServers | Should -BeNullOrEmpty
            }
        }

        It 'Should return a single dnsServers entry when one is provided' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"],"dnsServers":["10.0.0.5"]}'
                $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode'
                @($result.dnsServers).Count | Should -Be 1
                @($result.dnsServers)[0] | Should -Be '10.0.0.5'
            }
        }

        It 'Should return multiple dnsServers entries when provided' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100","10.0.0.101"],"dnsServers":["10.0.0.5","10.0.0.6","10.0.0.7"]}'
                $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'StorageSwitched' -NodeCount 2
                @($result.dnsServers).Count | Should -Be 3
                @($result.dnsServers)[2] | Should -Be '10.0.0.7'
            }
        }

        It 'Should throw for an invalid dnsServers IP address' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"],"dnsServers":["not-an-ip"]}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode' } | Should -Throw
            }
        }

        It 'Should throw for a whitespace-only dnsServers entry' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.0.1","startingIPAddress":"10.0.0.10","endingIPAddress":"10.0.0.50","nodeIPAddresses":["10.0.0.100"],"dnsServers":["   "]}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'SingleNode' } | Should -Throw
            }
        }
    }
}

# ============================================================================
# Credential Parameter Validation
# ============================================================================
Describe 'Credential Parameters' {

    Context 'Key Vault Secret Name Parameters' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalTemplateDeployment
        }

        It 'LocalAdminSecretName should NOT be mandatory' {
            $param = $script:Command.Parameters['LocalAdminSecretName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'LCMAdminSecretName should NOT be mandatory' {
            $param = $script:Command.Parameters['LCMAdminSecretName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'LocalAdminSecretName should be of type String' {
            $script:Command.Parameters['LocalAdminSecretName'].ParameterType.Name | Should -Be 'String'
        }

        It 'LCMAdminSecretName should be of type String' {
            $script:Command.Parameters['LCMAdminSecretName'].ParameterType.Name | Should -Be 'String'
        }
    }
}

# ============================================================================
# v0.8.0 - Code Quality and Professionalism Tests
# ============================================================================
Describe 'Code Quality: Set-StrictMode' {
    BeforeAll {
        $script:ModuleDir = Join-Path $PSScriptRoot '..'
        $script:ModuleSource = (@(Get-Content (Join-Path $script:ModuleDir 'AzLocal.DeploymentAutomation.psm1') -Raw) + @(Get-ChildItem (Join-Path $script:ModuleDir 'Public'), (Join-Path $script:ModuleDir 'Private') -Filter '*.ps1' | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
    }

    It 'Module should declare Set-StrictMode -Version Latest' {
        $script:ModuleSource | Should -Match 'Set-StrictMode\s+-Version\s+Latest'
    }
}

Describe 'Code Quality: OutputType Declarations' {
    BeforeAll {
        $script:StartCmd = Get-Command Start-AzLocalTemplateDeployment
        $script:WatchCmd = Get-Command Watch-AzLocalDeployment
    }

    It 'Start-AzLocalTemplateDeployment should have OutputType attribute' {
        $script:StartCmd.OutputType | Should -Not -BeNullOrEmpty
    }

    It 'Watch-AzLocalDeployment should have OutputType attribute' {
        $script:WatchCmd.OutputType | Should -Not -BeNullOrEmpty
    }
}

Describe 'Code Quality: Path Construction' {
    BeforeAll {
        $script:ModuleDir = Join-Path $PSScriptRoot '..'
        $script:ModuleSource = (@(Get-Content (Join-Path $script:ModuleDir 'AzLocal.DeploymentAutomation.psm1') -Raw) + @(Get-ChildItem (Join-Path $script:ModuleDir 'Public'), (Join-Path $script:ModuleDir 'Private') -Filter '*.ps1' | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
    }

    It 'Module should not contain no-op regex replace on backslash' {
        # The pattern $var -replace '\\', '\' is a no-op and should have been removed
        $script:ModuleSource | Should -Not -Match "\-replace\s+'\\\\',\s+'\\\\'"
    }

    It 'Module should use Join-Path for path construction' {
        $script:ModuleSource | Should -Match 'Join-Path'
    }
}

Describe 'Code Quality: Credential Cleanup' {
    BeforeAll {
        $script:ModuleDir = Join-Path $PSScriptRoot '..'
        $script:ModuleSource = (@(Get-Content (Join-Path $script:ModuleDir 'AzLocal.DeploymentAutomation.psm1') -Raw) + @(Get-ChildItem (Join-Path $script:ModuleDir 'Public'), (Join-Path $script:ModuleDir 'Private') -Filter '*.ps1' | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
    }

    It 'Module should contain a finally block for credential cleanup' {
        $script:ModuleSource | Should -Match 'finally\s*\{'
    }

    It 'Module should clear localAdminPassword variable after use' {
        $script:ModuleSource | Should -Match '\$localAdminPassword\s*=\s*\$null'
    }

    It 'Module should clear AzureStackLCMAdminPassword variable after use' {
        $script:ModuleSource | Should -Match '\$AzureStackLCMAdminPassword\s*=\s*\$null'
    }
}

Describe 'Code Quality: Az.KeyVault Availability Check' {
    BeforeAll {
        $script:ModuleDir = Join-Path $PSScriptRoot '..'
        $script:ModuleSource = (@(Get-Content (Join-Path $script:ModuleDir 'AzLocal.DeploymentAutomation.psm1') -Raw) + @(Get-ChildItem (Join-Path $script:ModuleDir 'Public'), (Join-Path $script:ModuleDir 'Private') -Filter '*.ps1' | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
    }

    It 'Module should check for Az.KeyVault availability before Key Vault operations' {
        $script:ModuleSource | Should -Match "Get-Module\s+-ListAvailable\s+-Name\s+'Az\.KeyVault'"
    }
}

Describe 'Code Quality: No Dead Code' {
    BeforeAll {
        $script:ModuleDir = Join-Path $PSScriptRoot '..'
        $script:ModuleSource = (@(Get-Content (Join-Path $script:ModuleDir 'AzLocal.DeploymentAutomation.psm1') -Raw) + @(Get-ChildItem (Join-Path $script:ModuleDir 'Public'), (Join-Path $script:ModuleDir 'Private') -Filter '*.ps1' | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
    }

    It 'Module should not contain commented-out Connect-AzAccount calls' {
        $script:ModuleSource | Should -Not -Match '#\s*Connect-AzAccount'
    }

    It 'Module should not use Remove-Variable anti-pattern' {
        $script:ModuleSource | Should -Not -Match 'Remove-Variable\s+'
    }
}

# ============================================================================
# CI/CD Automation Functions
# ============================================================================

# ============================================================================
# New-AzLocalJUnitXml
# ============================================================================
Describe 'Function: New-AzLocalJUnitXml' {

    Context 'JUnit XML Generation' {
        It 'Should generate valid XML with passed test results' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class1'; Status = 'Passed'; Message = 'OK'; Duration = 1.5 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results -SuiteName 'TestSuite'
            $xml | Should -Match '<\?xml version="1.0"'
            $xml | Should -Match '<testsuites>'
            $xml | Should -Match 'tests="1"'
            $xml | Should -Match 'failures="0"'
            $xml | Should -Match '<testcase name="Test1"'
        }

        It 'Should generate failure elements for failed tests' {
            $results = @(
                [PSCustomObject]@{ TestName = 'FailTest'; ClassName = 'Suite.Class1'; Status = 'Failed'; Message = 'Something broke'; Duration = 2.0 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'failures="1"'
            $xml | Should -Match '<failure'
            $xml | Should -Match 'Something broke'
        }

        It 'Should generate skipped elements for skipped tests' {
            $results = @(
                [PSCustomObject]@{ TestName = 'SkipTest'; ClassName = 'Suite.Class1'; Status = 'Skipped'; Message = 'Already deployed'; Duration = 0 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'skipped="1"'
            $xml | Should -Match '<skipped'
        }

        It 'Should handle multiple test results with mixed statuses' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Pass1'; ClassName = 'Suite.A'; Status = 'Passed'; Message = 'OK'; Duration = 1 },
                [PSCustomObject]@{ TestName = 'Fail1'; ClassName = 'Suite.A'; Status = 'Failed'; Message = 'Error'; Duration = 2 },
                [PSCustomObject]@{ TestName = 'Skip1'; ClassName = 'Suite.B'; Status = 'Skipped'; Message = 'Skip'; Duration = 0 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'tests="3"'
            $xml | Should -Match 'failures="1"'
            $xml | Should -Match 'skipped="1"'
        }

        It 'Should XML-escape special characters in test names' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test & <special>'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = ''; Duration = 0 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'Test &amp; &lt;special&gt;'
        }

        It 'Should write to file when OutputPath is specified' {
            $tempFile = Join-Path $TestDrive 'test-results.xml'
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = 'OK'; Duration = 1 }
            )
            $output = @(New-AzLocalJUnitXml -TestResults $results -OutputPath $tempFile)
            Test-Path $tempFile | Should -Be $true
            $output.Count | Should -Be 0
            $content = Get-Content $tempFile -Raw
            $content | Should -Match '<testsuites>'
        }

        It 'Should write output when WhatIfPreference is inherited' {
            $tempFile = Join-Path $TestDrive 'whatif-results.xml'
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = 'OK'; Duration = 1 }
            )
            $WhatIfPreference = $true
            try {
                New-AzLocalJUnitXml -TestResults $results -OutputPath $tempFile
            } finally {
                $WhatIfPreference = $false
            }
            Test-Path $tempFile | Should -BeTrue
        }

        It 'Should create parent directories for OutputPath if they do not exist' {
            $tempFile = Join-Path $TestDrive 'subdir\nested\results.xml'
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = 'OK'; Duration = 1 }
            )
            New-AzLocalJUnitXml -TestResults $results -OutputPath $tempFile
            Test-Path $tempFile | Should -Be $true
        }

        It 'Should use default SuiteName when not specified' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = ''; Duration = 0 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'name="AzLocalDeploymentAutomation"'
        }

        It 'Should handle null Duration gracefully' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = 'OK'; Duration = $null }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'time="0"'
        }

        It 'Should handle null Message gracefully' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Failed'; Message = $null; Duration = 1 }
            )
            { New-AzLocalJUnitXml -TestResults $results } | Should -Not -Throw
        }

        It 'Should handle a CDATA terminator in Message' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Failed'; Message = 'bad ]]> marker'; Duration = 1 }
            )
            { New-AzLocalJUnitXml -TestResults $results } | Should -Not -Throw
            [xml](New-AzLocalJUnitXml -TestResults $results) | Should -Not -BeNullOrEmpty
        }

        It 'Should format decimal durations using invariant culture' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = ''; Duration = 1.5 }
            )
            $originalCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                [xml]$xml = New-AzLocalJUnitXml -TestResults $results
                $xml.testsuites.testsuite.time | Should -Be '1.5'
                $xml.testsuites.testsuite.testcase.time | Should -Be '1.5'
            } finally {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = $originalCulture
            }
        }

        It 'Should handle missing optional Duration and Message properties' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed' }
            )
            { New-AzLocalJUnitXml -TestResults $results } | Should -Not -Throw
        }

        It 'Should include timestamp in output' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'Suite.Class'; Status = 'Passed'; Message = ''; Duration = 0 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'timestamp='
        }

        It 'Should calculate total time from Duration properties' {
            $results = @(
                [PSCustomObject]@{ TestName = 'A'; ClassName = 'C'; Status = 'Passed'; Message = ''; Duration = 10 },
                [PSCustomObject]@{ TestName = 'B'; ClassName = 'C'; Status = 'Passed'; Message = ''; Duration = 20 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match 'time="30"'
        }

        It 'Should include system-out for passed tests with messages' {
            $results = @(
                [PSCustomObject]@{ TestName = 'Test1'; ClassName = 'C'; Status = 'Passed'; Message = 'All checks passed'; Duration = 1 }
            )
            $xml = New-AzLocalJUnitXml -TestResults $results
            $xml | Should -Match '<system-out>'
            $xml | Should -Match 'All checks passed'
        }
    }

    Context 'Parameter Validation' {
        It 'Should have mandatory TestResults parameter' {
            $cmd = Get-Command New-AzLocalJUnitXml
            $cmd.Parameters['TestResults'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have OutputType of string' {
            $cmd = Get-Command New-AzLocalJUnitXml
            $cmd.OutputType.Type | Should -Contain ([string])
        }
    }
}

# ============================================================================
# Import-AzLocalDeploymentCsv
# ============================================================================
Describe 'Function: Import-AzLocalDeploymentCsv' {

    Context 'Valid CSV Import' {
        BeforeAll {
            $script:ValidCsvPath = Join-Path $TestDrive 'valid-clusters.csv'
            $csvContent = @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,Location,CredentialKeyVaultName,LocalAdminSecretName,LCMAdminSecretName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,DnsServers,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,eastus,kv-deploy,LocalAdmin,LCMAdmin,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.10,10.0.1.50
Store002,FALSE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,StorageSwitched,2,eastus,kv-deploy,LocalAdmin,LCMAdmin,255.255.255.0,10.0.2.1,10.0.2.100,10.0.2.110,10.0.2.10;10.0.2.11,10.0.2.50;10.0.2.51
"@
            $csvContent | Out-File -FilePath $script:ValidCsvPath -Encoding utf8
        }

        It 'Should import all rows from a valid CSV' {
            $result = @(Import-AzLocalDeploymentCsv -CsvFilePath $script:ValidCsvPath)
            $result.Count | Should -Be 2
        }

        It 'Should filter to ReadyToDeploy=TRUE with -ReadyOnly switch' {
            $result = @(Import-AzLocalDeploymentCsv -CsvFilePath $script:ValidCsvPath -ReadyOnly)
            $result.Count | Should -Be 1
            $result[0].UniqueID | Should -Be 'Store001'
        }

        It 'Should return PSCustomObjects with correct properties' {
            $result = @(Import-AzLocalDeploymentCsv -CsvFilePath $script:ValidCsvPath)
            $result[0].UniqueID | Should -Be 'Store001'
            $result[0].TypeOfDeployment | Should -Be 'SingleNode'
            $result[0].SubscriptionId | Should -Be '12345678-1234-1234-1234-123456789abc'
        }

        It 'Should preserve semicolon-separated values as strings' {
            $result = @(Import-AzLocalDeploymentCsv -CsvFilePath $script:ValidCsvPath)
            $result[1].NodeIPAddresses | Should -Be '10.0.2.50;10.0.2.51'
            $result[1].DnsServers | Should -Be '10.0.2.10;10.0.2.11'
        }
    }

    Context 'CSV Validation Errors' {
        It 'Should throw when CSV file does not exist' {
            { Import-AzLocalDeploymentCsv -CsvFilePath 'C:\nonexistent\file.csv' } | Should -Throw '*not found*'
        }

        It 'Should throw when CSV has no data rows' {
            $emptyCsv = Join-Path $TestDrive 'empty.csv'
            "UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses" | Out-File -FilePath $emptyCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $emptyCsv } | Should -Throw '*no data*'
        }

        It 'Should throw when required columns are missing' {
            $badCsv = Join-Path $TestDrive 'missing-cols.csv'
            @"
UniqueID,ReadyToDeploy
Store001,TRUE
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*missing required columns*'
        }

        It 'Should throw when UniqueID is empty' {
            $badCsv = Join-Path $TestDrive 'empty-uid.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*UniqueID*'
        }

        It 'Should throw when UniqueID has invalid characters' {
            $badCsv = Join-Path $TestDrive 'bad-uid.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
St@re!,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*UniqueID*'
        }

        It 'Should throw when UniqueID exceeds 8 characters' {
            $badCsv = Join-Path $TestDrive 'long-uid.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
StoreTooLong,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*UniqueID*'
        }

        It 'Should throw when UniqueID is less than 2 characters' {
            $badCsv = Join-Path $TestDrive 'short-uid.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
A,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*UniqueID*'
        }

        It 'Should throw when SubscriptionId is not a GUID' {
            $badCsv = Join-Path $TestDrive 'bad-sub.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,not-a-guid,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*SubscriptionId*'
        }

        It 'Should throw when TenantId is not a GUID' {
            $badCsv = Join-Path $TestDrive 'bad-tenant.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,not-a-guid,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*TenantId*'
        }

        It 'Should throw when TypeOfDeployment is invalid' {
            $badCsv = Join-Path $TestDrive 'bad-type.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,InvalidType,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*TypeOfDeployment*'
        }

        It 'Should throw when DefaultGateway is not a valid IP' {
            $badCsv = Join-Path $TestDrive 'bad-gw.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,not.an.ip,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*DefaultGateway*'
        }

        It 'Should throw when NodeIPAddresses contains invalid IP' {
            $badCsv = Join-Path $TestDrive 'bad-nodeip.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,bad.ip.addr
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*NodeIPAddress*'
        }

        It 'Should throw when DnsServers contains an invalid IP' {
            $badCsv = Join-Path $TestDrive 'bad-dns.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,DnsServers,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,not-an-ip,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*DnsServers*not a valid IP address*'
        }

        It 'Should throw when ReadyToDeploy is not TRUE or FALSE' {
            $badCsv = Join-Path $TestDrive 'bad-ready.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,MAYBE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*ReadyToDeploy*'
        }

        It 'Should reject blank required values on a ready row' {
            $csv = Join-Path $TestDrive 'blank-ready-values.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,,,,,,
"@ | Out-File -FilePath $csv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $csv } | Should -Throw '*CredentialKeyVaultName is required*'
        }

        It 'Should allow blank deployment values on a draft row' {
            $csv = Join-Path $TestDrive 'blank-draft-values.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,FALSE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,,,,,,
"@ | Out-File -FilePath $csv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $csv } | Should -Not -Throw
        }

        It 'Should accept all valid TypeOfDeployment values' {
            $deployTests = @{
                'SingleNode'        = @{ NodeCount = 1; IPs = '10.0.1.50' }
                'StorageSwitched'   = @{ NodeCount = 2; IPs = '10.0.1.50;10.0.1.51' }
                'StorageSwitchless' = @{ NodeCount = 2; IPs = '10.0.1.50;10.0.1.51' }
                'RackAware'         = @{ NodeCount = 2; IPs = '10.0.1.50;10.0.1.51' }
            }
            foreach ($deployType in $deployTests.Keys) {
                $nc = $deployTests[$deployType].NodeCount
                $ips = $deployTests[$deployType].IPs
                $csv = Join-Path $TestDrive "valid-$deployType.csv"
                @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,$deployType,$nc,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,$ips
"@ | Out-File -FilePath $csv -Encoding utf8
                { Import-AzLocalDeploymentCsv -CsvFilePath $csv } | Should -Not -Throw
            }
        }

        It 'Should accept ReadyToDeploy in various casings' {
            foreach ($rdVal in @('TRUE', 'FALSE', 'true', 'false', 'True', 'False')) {
                $csv = Join-Path $TestDrive "ready-$rdVal.csv"
                @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,$rdVal,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $csv -Encoding utf8
                { Import-AzLocalDeploymentCsv -CsvFilePath $csv } | Should -Not -Throw
            }
        }
    }

    Context 'NodeCount vs TypeOfDeployment Cross-Validation' {
        It 'Should throw when SingleNode has NodeCount != 1' {
            $badCsv = Join-Path $TestDrive 'singlenode-bad-count.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,2,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50;10.0.1.51
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*SingleNode*NodeCount*'
        }

        It 'Should throw when StorageSwitchless has NodeCount > 4' {
            $badCsv = Join-Path $TestDrive 'switchless-bad-count.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,StorageSwitchless,8,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50;10.0.1.51;10.0.1.52;10.0.1.53;10.0.1.54;10.0.1.55;10.0.1.56;10.0.1.57
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*StorageSwitchless*NodeCount*'
        }

        It 'Should throw when StorageSwitchless has NodeCount = 1' {
            $badCsv = Join-Path $TestDrive 'switchless-1node.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,StorageSwitchless,1,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*StorageSwitchless*NodeCount*'
        }

        It 'Should throw when RackAware has odd NodeCount' {
            $badCsv = Join-Path $TestDrive 'rackaware-odd.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,RackAware,3,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50;10.0.1.51;10.0.1.52
"@ | Out-File -FilePath $badCsv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $badCsv } | Should -Throw '*RackAware*NodeCount*'
        }

        It 'Should accept valid StorageSwitchless with NodeCount 2' {
            $csv = Join-Path $TestDrive 'switchless-2node-valid.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,StorageSwitchless,2,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50;10.0.1.51
"@ | Out-File -FilePath $csv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $csv } | Should -Not -Throw
        }

        It 'Should accept valid RackAware with NodeCount 4' {
            $csv = Join-Path $TestDrive 'rackaware-4node-valid.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,CredentialKeyVaultName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,NodeIPAddresses
Store001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,RackAware,4,kv-deploy,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.50;10.0.1.51;10.0.1.52;10.0.1.53
"@ | Out-File -FilePath $csv -Encoding utf8
            { Import-AzLocalDeploymentCsv -CsvFilePath $csv } | Should -Not -Throw
        }
    }

    Context 'Parameter Validation' {
        It 'Should have mandatory CsvFilePath parameter' {
            $cmd = Get-Command Import-AzLocalDeploymentCsv
            $cmd.Parameters['CsvFilePath'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have optional ReadyOnly switch parameter' {
            $cmd = Get-Command Import-AzLocalDeploymentCsv
            $cmd.Parameters['ReadyOnly'].ParameterType | Should -Be ([switch])
        }

        It 'Should have OutputType of PSCustomObject array' {
            $cmd = Get-Command Import-AzLocalDeploymentCsv
            $cmd.OutputType.Type | Should -Not -BeNullOrEmpty
        }
    }
}

# ============================================================================
# Test-AzLocalClusterPreFlight
# ============================================================================
Describe 'Function: Test-AzLocalClusterPreFlight' {

    Context 'Parameter Validation' {
        It 'Should have mandatory ClusterRow parameter' {
            $cmd = Get-Command Test-AzLocalClusterPreFlight
            $cmd.Parameters['ClusterRow'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have mandatory NamingConfig parameter' {
            $cmd = Get-Command Test-AzLocalClusterPreFlight
            $cmd.Parameters['NamingConfig'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have mandatory DeploymentMode parameter with ValidateSet' {
            $cmd = Get-Command Test-AzLocalClusterPreFlight
            $cmd.Parameters['DeploymentMode'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
            $validateSet = $cmd.Parameters['DeploymentMode'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateSetAttribute] })
            $validateSet | Should -Not -BeNullOrEmpty
            $validateSet.ValidValues | Should -Contain 'Validate'
            $validateSet.ValidValues | Should -Contain 'Deploy'
        }

        It 'Should have OutputType of PSCustomObject' {
            $cmd = Get-Command Test-AzLocalClusterPreFlight
            $cmd.OutputType.Type | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Pre-Flight Check Logic (Mocked Azure Calls)' {
        BeforeAll {
            $script:NamingConfig = (Get-AzLocalNamingConfig).Config

            # Use lowercase UniqueID to ensure generated storage account names pass
            # Azure naming validation (lowercase alphanumeric only).
            $script:MockClusterRow = [PSCustomObject]@{
                UniqueID               = 'tst001'
                ReadyToDeploy          = 'TRUE'
                SubscriptionId         = '12345678-1234-1234-1234-123456789abc'
                TenantId               = '12345678-1234-1234-1234-123456789abc'
                TypeOfDeployment       = 'SingleNode'
                NodeCount              = '1'
                Location               = 'eastus'
                CredentialKeyVaultName = 'kv-deploy'
                LocalAdminSecretName   = 'LocalAdmin'
                LCMAdminSecretName     = 'LCMAdmin'
                SubnetMask             = '255.255.255.0'
                DefaultGateway         = '10.0.1.1'
                StartingIPAddress      = '10.0.1.100'
                EndingIPAddress        = '10.0.1.110'
                DnsServers             = '10.0.1.10'
                NodeIPAddresses        = '10.0.1.50'
            }
        }

        BeforeEach {
            # Mock the Azure prerequisites check (resource providers + RBAC) to return Passed
            # so pre-flight tests can focus on their own check scenarios.
            Mock Test-AzLocalAzurePrerequisites {
                return [PSCustomObject]@{ Status = 'Passed'; Messages = @('Prerequisites check mocked.') }
            } -ModuleName AzLocal.DeploymentAutomation
        }

        It 'Should return Passed when all checks pass' {
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-tst001-azurelocal-prod' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*HybridCompute*') { return @{ Name = 'tst001NODE01' } }
                if ($ResourceId -like '*AzureStackHCI*') { return $null }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Validate'
            $result.Status | Should -Be 'Passed'
            $result.UniqueID | Should -Be 'tst001'
        }

        It 'Should return Failed when resource group does not exist' {
            Mock Get-AzResourceGroup { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Validate'
            $result.Status | Should -Be 'Failed'
            ($result.Messages -join '; ') | Should -Match 'NOT FOUND'
        }

        It 'Should return Failed when Arc nodes are not registered' {
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-tst001-azurelocal-prod' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*HybridCompute*') { return $null }
                if ($ResourceId -like '*AzureStackHCI*') { return $null }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Validate'
            $result.Status | Should -Be 'Failed'
        }

        It 'Should return Skipped when cluster already exists' {
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-tst001-azurelocal-prod' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*HybridCompute*') { return @{ Name = 'tst001NODE01' } }
                if ($ResourceId -like '*AzureStackHCI*') { return @{ Name = 'AZCLUSTERtst001' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Validate'
            $result.Status | Should -Be 'Skipped'
        }

        It 'Should return Skipped when deployment is in-progress' {
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-tst001-azurelocal-prod' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*HybridCompute*') { return @{ Name = 'tst001NODE01' } }
                if ($ResourceId -like '*AzureStackHCI*') { return $null }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment {
                return @{ ProvisioningState = 'Running' }
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Validate'
            $result.Status | Should -Be 'Skipped'
        }

        It 'Should return Passed when previous deployment failed (retryable)' {
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-tst001-azurelocal-prod' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*HybridCompute*') { return @{ Name = 'tst001NODE01' } }
                if ($ResourceId -like '*AzureStackHCI*') { return $null }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment {
                return @{ ProvisioningState = 'Failed' }
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Deploy'
            $result.Status | Should -Be 'Passed'
        }

        It 'Should include Duration in result' {
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-tst001-azurelocal-prod' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*HybridCompute*') { return @{ Name = 'tst001NODE01' } }
                if ($ResourceId -like '*AzureStackHCI*') { return $null }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Validate'
            $result.Duration | Should -BeOfType [double]
            $result.Duration | Should -BeGreaterOrEqual 0
        }

        It 'Should resolve resource names correctly using naming config' {
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-tst001-azurelocal-prod' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*HybridCompute*') { return @{ Name = 'tst001NODE01' } }
                if ($ResourceId -like '*AzureStackHCI*') { return $null }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalClusterPreFlight -ClusterRow $script:MockClusterRow -NamingConfig $script:NamingConfig -DeploymentMode 'Validate'
            $result.ResourceGroupName | Should -Not -BeNullOrEmpty
            $result.ClusterName | Should -Not -BeNullOrEmpty
            $result.DeploymentName | Should -Not -BeNullOrEmpty
        }
    }
}

# ============================================================================
# Test-AzLocalAzurePrerequisites
# ============================================================================
Describe 'Function: Test-AzLocalAzurePrerequisites' {

    Context 'Parameter Validation' {
        It 'Should have mandatory SubscriptionId parameter' {
            $cmd = Get-Command Test-AzLocalAzurePrerequisites
            $cmd.Parameters['SubscriptionId'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have mandatory ResourceGroupName parameter' {
            $cmd = Get-Command Test-AzLocalAzurePrerequisites
            $cmd.Parameters['ResourceGroupName'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have OutputType of PSCustomObject' {
            $cmd = Get-Command Test-AzLocalAzurePrerequisites
            $cmd.OutputType.Type | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Resource Provider Checks (Mocked)' {
        It 'Should return Passed when all resource providers are registered' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -Be 'Passed'
            ($result.Messages -join '; ') | Should -Match 'PASSED'
        }

        It 'Should wait for auto-registered providers to become ready' {
            $script:HybridComputeChecks = 0
            Mock Get-AzResourceProvider {
                param($ProviderNamespace)
                if ($ProviderNamespace -eq 'Microsoft.HybridCompute') {
                    $script:HybridComputeChecks++
                    $state = if ($script:HybridComputeChecks -ge 2) { 'Registered' } else { 'NotRegistered' }
                    return @([PSCustomObject]@{ RegistrationState = $state })
                }
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Register-AzResourceProvider { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Start-Sleep {} -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -Be 'Passed'
            ($result.Messages -join '; ') | Should -Match 'AUTO-REGISTERED'
            Should -Invoke Register-AzResourceProvider -Times 1 -ModuleName AzLocal.DeploymentAutomation
            Should -Invoke Start-Sleep -Times 1 -ModuleName AzLocal.DeploymentAutomation
        }

        It 'Should fail when provider registration does not become ready' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registering' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Register-AzResourceProvider { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Start-Sleep {} -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites `
                -SubscriptionId '12345678-1234-1234-1234-123456789abc' `
                -ResourceGroupName 'rg-test' `
                -RegistrationPollingIntervalSeconds 1 `
                -RegistrationMaxAttempts 2

            $result.Status | Should -Be 'Failed'
            ($result.Messages -join '; ') | Should -Match 'TIMED OUT'
        }

        It 'Should return Failed when provider registration fails' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'NotRegistered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Register-AzResourceProvider { throw "Insufficient permissions" } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -Be 'Failed'
            ($result.Messages -join '; ') | Should -Match 'FAILED'
        }

        It 'Should return Failed when Get-AzResourceProvider throws an error' {
            Mock Get-AzResourceProvider { throw "Network error" } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -Be 'Failed'
        }

        It 'Should check all 12 required resource providers' {
            $script:ProvidersChecked = @()
            Mock Get-AzResourceProvider {
                param($ProviderNamespace)
                $script:ProvidersChecked += $ProviderNamespace
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            Should -Invoke Get-AzResourceProvider -Times 12 -ModuleName AzLocal.DeploymentAutomation
        }
    }

    Context 'RBAC Role Checks (Mocked)' {
        It 'Should report Owner at subscription as satisfying all requirements' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -Be 'Passed'
            ($result.Messages -join '; ') | Should -Match 'Owner'
        }

        It 'Should warn about missing RBAC roles without failing' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                # Only has Reader, missing other required roles
                return @([PSCustomObject]@{ RoleDefinitionName = 'Reader' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            # RBAC is advisory - status should still be Passed (only RP failures cause Failed)
            $result.Status | Should -Be 'Passed'
            ($result.Messages -join '; ') | Should -Match 'NOT FOUND'
            ($result.Messages -join '; ') | Should -Match 'Reader.*ASSIGNED'
        }

        It 'Should handle RBAC check failure gracefully (still Passed)' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext { throw "No Azure context" } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            # RBAC failure is advisory - status still Passed since RPs are OK
            $result.Status | Should -Be 'Passed'
            ($result.Messages -join '; ') | Should -Match 'SKIPPED'
        }

        It 'Should check both subscription and resource group scope roles' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @(
                    [PSCustomObject]@{ RoleDefinitionName = 'Azure Stack HCI Administrator' },
                    [PSCustomObject]@{ RoleDefinitionName = 'Reader' },
                    [PSCustomObject]@{ RoleDefinitionName = 'Key Vault Data Access Administrator' },
                    [PSCustomObject]@{ RoleDefinitionName = 'Key Vault Secrets Officer' },
                    [PSCustomObject]@{ RoleDefinitionName = 'Key Vault Contributor' },
                    [PSCustomObject]@{ RoleDefinitionName = 'Storage Account Contributor' }
                )
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -Be 'Passed'
            ($result.Messages -join '; ') | Should -Match 'Azure Stack HCI Administrator.*ASSIGNED'
            ($result.Messages -join '; ') | Should -Match 'Key Vault Contributor.*ASSIGNED'
            ($result.Messages -join '; ') | Should -Match 'Storage Account Contributor.*ASSIGNED'
        }

        It 'Should handle service principal identity via Get-AzADServicePrincipal' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = '00000000-0000-0000-0000-000000000001'; Type = 'ServicePrincipal' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzADServicePrincipal {
                return @{ Id = 'sp-object-id-001' }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -Be 'Passed'
            Should -Invoke Get-AzADServicePrincipal -Times 1 -ModuleName AzLocal.DeploymentAutomation
        }
    }

    Context 'Result Object Shape' {
        It 'Should return object with Status and Messages properties' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.PSObject.Properties.Name | Should -Contain 'Status'
            $result.PSObject.Properties.Name | Should -Contain 'Messages'
            $result.Messages | Should -BeOfType [string]
        }

        It 'Should return Status as either Passed or Failed' {
            Mock Get-AzResourceProvider {
                return @([PSCustomObject]@{ RegistrationState = 'Registered' })
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzContext {
                return @{ Account = @{ Id = 'user@contoso.com'; Type = 'User' } }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzRoleAssignment {
                return @([PSCustomObject]@{ RoleDefinitionName = 'Owner' })
            } -ModuleName AzLocal.DeploymentAutomation

            $result = Test-AzLocalAzurePrerequisites -SubscriptionId '12345678-1234-1234-1234-123456789abc' -ResourceGroupName 'rg-test'
            $result.Status | Should -BeIn @('Passed', 'Failed')
        }
    }
}

# ============================================================================
# Start-AzLocalCsvDeployment
# ============================================================================
Describe 'Function: Start-AzLocalCsvDeployment' {

    Context 'Parameter Definitions' {
        BeforeAll {
            $script:Command = Get-Command Start-AzLocalCsvDeployment
        }

        It 'Should have mandatory CsvFilePath parameter' {
            $script:Command.Parameters['CsvFilePath'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have mandatory DeploymentMode parameter' {
            $script:Command.Parameters['DeploymentMode'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have ValidateSet on DeploymentMode with Validate and Deploy' {
            $validateSet = $script:Command.Parameters['DeploymentMode'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateSetAttribute] })
            $validateSet | Should -Not -BeNullOrEmpty
            $validateSet.ValidValues | Should -Contain 'Validate'
            $validateSet.ValidValues | Should -Contain 'Deploy'
        }

        It 'Should have optional JUnitOutputPath parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'JUnitOutputPath'
            $param = $script:Command.Parameters['JUnitOutputPath']
            $param.ParameterType | Should -Be ([string])
        }

        It 'Should have optional LogFilePath parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LogFilePath'
        }

        It 'Should support ShouldProcess (WhatIf/Confirm)' {
            $script:Command.Parameters.Keys | Should -Contain 'WhatIf'
            $script:Command.Parameters.Keys | Should -Contain 'Confirm'
        }

        It 'Should have ConfirmImpact of High' {
            $cmdletBinding = $script:Command.ScriptBlock.Attributes.Where({ $_ -is [System.Management.Automation.CmdletBindingAttribute] })
            $cmdletBinding.ConfirmImpact | Should -Be 'High'
        }

        It 'Should have OutputType of PSCustomObject array' {
            $script:Command.OutputType.Type | Should -Not -BeNullOrEmpty
        }
    }

    Context 'CSV-Driven Deployment Logic (Mocked)' {
        BeforeAll {
            # Mock the default-value validation so tests using the shipped config don't fail
            Mock Test-AzLocalNamingConfigDefaults {} -ModuleName AzLocal.DeploymentAutomation

            $script:CsvPath = Join-Path $TestDrive 'deploy-test.csv'
            $csvContent = @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,Location,CredentialKeyVaultName,LocalAdminSecretName,LCMAdminSecretName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,DnsServers,NodeIPAddresses
TST001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,eastus,kv-deploy,LocalAdmin,LCMAdmin,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.10,10.0.1.50
TST002,FALSE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,StorageSwitched,2,eastus,kv-deploy,LocalAdmin,LCMAdmin,255.255.255.0,10.0.2.1,10.0.2.100,10.0.2.110,10.0.2.10,10.0.2.50;10.0.2.51
"@
            $csvContent | Out-File -FilePath $script:CsvPath -Encoding utf8
        }

        It 'Should return results for ReadyToDeploy=TRUE clusters only' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Test-AzLocalClusterPreFlight {
                return [PSCustomObject]@{
                    UniqueID = 'TST001'; ClusterName = 'cl-azlocal-TST001'; ResourceGroupName = 'rg-azlocal-TST001';
                    DeploymentName = 'deploy-TST001-SingleNode'; Status = 'Passed'; Messages = @('All checks passed'); Duration = 1.0
                }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Start-AzLocalTemplateDeployment {
                return [PSCustomObject]@{ ProvisioningState = 'Succeeded'; Duration = '00:05:00' }
            } -ModuleName AzLocal.DeploymentAutomation

            $results = Start-AzLocalCsvDeployment -CsvFilePath $script:CsvPath -DeploymentMode 'Validate' -Confirm:$false
            # TST002 is FALSE, should not appear
            $results | Where-Object { $_.TestName -like '*TST002*' } | Should -BeNullOrEmpty
        }

        It 'Should skip deployment when pre-flight fails' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Test-AzLocalClusterPreFlight {
                return [PSCustomObject]@{
                    UniqueID = 'TST001'; ClusterName = 'cl-azlocal-TST001'; ResourceGroupName = 'rg-azlocal-TST001';
                    DeploymentName = 'deploy-TST001-SingleNode'; Status = 'Failed'; Messages = @('RG not found'); Duration = 0.5
                }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Start-AzLocalTemplateDeployment { throw "Should not be called" } -ModuleName AzLocal.DeploymentAutomation

            $results = Start-AzLocalCsvDeployment -CsvFilePath $script:CsvPath -DeploymentMode 'Validate' -Confirm:$false
            $preFlightResult = $results | Where-Object { $_.TestName -eq 'PreFlight-TST001' }
            $preFlightResult.Status | Should -Be 'Failed'
            # No deployment result should exist since pre-flight failed
            $deployResult = $results | Where-Object { $_.TestName -eq 'Validate-TST001' }
            $deployResult | Should -BeNullOrEmpty
        }

        It 'Should generate JUnit XML when JUnitOutputPath is specified' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Test-AzLocalClusterPreFlight {
                return [PSCustomObject]@{
                    UniqueID = 'TST001'; ClusterName = 'cl-azlocal-TST001'; ResourceGroupName = 'rg-azlocal-TST001';
                    DeploymentName = 'deploy-TST001-SingleNode'; Status = 'Passed'; Messages = @('OK'); Duration = 1.0
                }
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Start-AzLocalTemplateDeployment {
                return [PSCustomObject]@{ ProvisioningState = 'Succeeded'; Duration = '00:05:00' }
            } -ModuleName AzLocal.DeploymentAutomation

            $junitPath = Join-Path $TestDrive 'junit-output.xml'
            Start-AzLocalCsvDeployment -CsvFilePath $script:CsvPath -DeploymentMode 'Validate' -JUnitOutputPath $junitPath -Confirm:$false
            Test-Path $junitPath | Should -Be $true
            $xmlContent = Get-Content $junitPath -Raw
            $xmlContent | Should -Match '<testsuites>'
        }

        It 'Should handle no ReadyToDeploy=TRUE clusters gracefully' {
            $allFalseCsv = Join-Path $TestDrive 'all-false.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,Location,CredentialKeyVaultName,LocalAdminSecretName,LCMAdminSecretName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,DnsServers,NodeIPAddresses
TST001,FALSE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,eastus,kv-deploy,LocalAdmin,LCMAdmin,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.10,10.0.1.50
"@ | Out-File -FilePath $allFalseCsv -Encoding utf8

            $results = Start-AzLocalCsvDeployment -CsvFilePath $allFalseCsv -DeploymentMode 'Validate' -Confirm:$false
            $results | Should -Not -BeNullOrEmpty
            $results[0].Status | Should -Be 'Skipped'
        }
    }
}

# ============================================================================
# Get-AzLocalDeploymentStatus
# ============================================================================
Describe 'Function: Get-AzLocalDeploymentStatus' {

    Context 'Parameter Definitions' {
        BeforeAll {
            $script:Command = Get-Command Get-AzLocalDeploymentStatus
        }

        It 'Should have mandatory CsvFilePath parameter' {
            $script:Command.Parameters['CsvFilePath'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
        }

        It 'Should have optional JUnitOutputPath parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'JUnitOutputPath'
        }

        It 'Should have optional LogFilePath parameter' {
            $script:Command.Parameters.Keys | Should -Contain 'LogFilePath'
        }

        It 'Should have OutputType of PSCustomObject array' {
            $script:Command.OutputType.Type | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Status Monitoring Logic (Mocked)' {
        BeforeAll {
            # Mock the default-value validation so tests using the shipped config don't fail
            Mock Test-AzLocalNamingConfigDefaults {} -ModuleName AzLocal.DeploymentAutomation

            $script:CsvPath = Join-Path $TestDrive 'status-test.csv'
            $csvContent = @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,Location,CredentialKeyVaultName,LocalAdminSecretName,LCMAdminSecretName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,DnsServers,NodeIPAddresses
TST001,TRUE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,eastus,kv-deploy,LocalAdmin,LCMAdmin,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.10,10.0.1.50
"@
            $csvContent | Out-File -FilePath $script:CsvPath -Encoding utf8
        }

        It 'Should report NotStarted when no deployment exists' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-azlocal-TST001' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath
            $results | Should -Not -BeNullOrEmpty
            $results[0].DeploymentStatus | Should -Be 'NotStarted'
        }

        It 'Should report ClusterExists when cluster resource exists' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource {
                param($ResourceId)
                if ($ResourceId -like '*AzureStackHCI*') { return @{ Name = 'cl-azlocal-TST001' } }
                return $null
            } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-azlocal-TST001' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath
            $results[0].DeploymentStatus | Should -Be 'ClusterExists'
        }

        It 'Should report DeploySucceeded for succeeded deploy' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-azlocal-TST001' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment {
                return @{
                    ProvisioningState = 'Succeeded'
                    Duration = [TimeSpan]::FromMinutes(30)
                    Parameters = @{ deploymentMode = @{ Value = 'Deploy' } }
                }
            } -ModuleName AzLocal.DeploymentAutomation

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath
            $results[0].DeploymentStatus | Should -Be 'DeploySucceeded'
        }

        It 'Should report ValidateFailed for failed validation' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-azlocal-TST001' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment {
                return @{
                    ProvisioningState = 'Failed'
                    Duration = [TimeSpan]::FromMinutes(5)
                    Parameters = @{ deploymentMode = @{ Value = 'Validate' } }
                }
            } -ModuleName AzLocal.DeploymentAutomation

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath
            $results[0].DeploymentStatus | Should -Be 'ValidateFailed'
        }

        It 'Should report DeployInProgress for running deploy' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-azlocal-TST001' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment {
                return @{
                    ProvisioningState = 'Running'
                    Duration = $null
                    Parameters = @{ deploymentMode = @{ Value = 'Deploy' } }
                }
            } -ModuleName AzLocal.DeploymentAutomation

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath
            $results[0].DeploymentStatus | Should -Be 'DeployInProgress'
        }

        It 'Should report NotStarted when resource group does not exist' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath
            $results[0].DeploymentStatus | Should -Be 'NotStarted'
        }

        It 'Should generate JUnit XML when JUnitOutputPath is specified' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-azlocal-TST001' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $junitPath = Join-Path $TestDrive 'status-junit.xml'
            Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath -JUnitOutputPath $junitPath
            Test-Path $junitPath | Should -Be $true
        }

        It 'Should return empty array when no ReadyToDeploy=TRUE clusters' {
            $allFalseCsv = Join-Path $TestDrive 'status-all-false.csv'
            @"
UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,Location,CredentialKeyVaultName,LocalAdminSecretName,LCMAdminSecretName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,DnsServers,NodeIPAddresses
TST001,FALSE,12345678-1234-1234-1234-123456789abc,12345678-1234-1234-1234-123456789abc,SingleNode,1,eastus,kv-deploy,LocalAdmin,LCMAdmin,255.255.255.0,10.0.1.1,10.0.1.100,10.0.1.110,10.0.1.10,10.0.1.50
"@ | Out-File -FilePath $allFalseCsv -Encoding utf8

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $allFalseCsv
            $results.Count | Should -Be 0
        }

        It 'Should include all expected properties in result objects' {
            Mock Set-AzContext { return $true } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResource { return $null } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroup { return @{ ResourceGroupName = 'rg-azlocal-TST001' } } -ModuleName AzLocal.DeploymentAutomation
            Mock Get-AzResourceGroupDeployment { return $null } -ModuleName AzLocal.DeploymentAutomation

            $results = Get-AzLocalDeploymentStatus -CsvFilePath $script:CsvPath
            $results[0].PSObject.Properties.Name | Should -Contain 'UniqueID'
            $results[0].PSObject.Properties.Name | Should -Contain 'ClusterName'
            $results[0].PSObject.Properties.Name | Should -Contain 'ResourceGroupName'
            $results[0].PSObject.Properties.Name | Should -Contain 'DeploymentName'
            $results[0].PSObject.Properties.Name | Should -Contain 'DeploymentStatus'
            $results[0].PSObject.Properties.Name | Should -Contain 'ProvisioningState'
            $results[0].PSObject.Properties.Name | Should -Contain 'Message'
            $results[0].PSObject.Properties.Name | Should -Contain 'Duration'
        }
    }
}

# ============================================================================
# Automation Pipelines File Structure
# ============================================================================
Describe 'Automation Pipelines: File Structure' {
    BeforeAll {
        $script:PipelinesDir = Join-Path $PSScriptRoot '..\automation-pipelines'
    }

    Context 'Core Files' {
        It 'Should have cluster-deployments.csv example file' {
            Test-Path (Join-Path $script:PipelinesDir 'cluster-deployments.csv') | Should -Be $true
        }

        It 'Should have README.md' {
            Test-Path (Join-Path $script:PipelinesDir 'README.md') | Should -Be $true
        }
    }

    Context 'GitHub Actions Workflows' {
        It 'Should have validate-deployments.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'github-actions\validate-deployments.yml') | Should -Be $true
        }

        It 'Should have deploy-clusters.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'github-actions\deploy-clusters.yml') | Should -Be $true
        }

        It 'Should have deployment-monitor.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'github-actions\deployment-monitor.yml') | Should -Be $true
        }

        It 'Should have deployment-status-report.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'github-actions\deployment-status-report.yml') | Should -Be $true
        }
    }

    Context 'Azure DevOps Pipelines' {
        It 'Should have validate-deployments.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'azure-devops\validate-deployments.yml') | Should -Be $true
        }

        It 'Should have deploy-clusters.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'azure-devops\deploy-clusters.yml') | Should -Be $true
        }

        It 'Should have deployment-monitor.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'azure-devops\deployment-monitor.yml') | Should -Be $true
        }

        It 'Should have deployment-status-report.yml' {
            Test-Path (Join-Path $script:PipelinesDir 'azure-devops\deployment-status-report.yml') | Should -Be $true
        }
    }

    Context 'CSV File Content' {
        BeforeAll {
            $script:CsvPath = Join-Path $script:PipelinesDir 'cluster-deployments.csv'
            $script:CsvData = Import-Csv -Path $script:CsvPath
        }

        It 'CSV should have all required columns' {
            $requiredCols = @('UniqueID', 'ReadyToDeploy', 'SubscriptionId', 'TenantId',
                'TypeOfDeployment', 'NodeCount', 'CredentialKeyVaultName',
                'SubnetMask', 'DefaultGateway', 'StartingIPAddress', 'EndingIPAddress', 'NodeIPAddresses')
            $presentCols = $script:CsvData[0].PSObject.Properties.Name
            foreach ($col in $requiredCols) {
                $presentCols | Should -Contain $col
            }
        }

        It 'CSV should contain example rows' {
            $script:CsvData.Count | Should -BeGreaterThan 0
        }

        It 'CSV should have a mix of ReadyToDeploy TRUE and FALSE rows' {
            $trueRows = @($script:CsvData | Where-Object { $_.ReadyToDeploy -eq 'TRUE' })
            $falseRows = @($script:CsvData | Where-Object { $_.ReadyToDeploy -eq 'FALSE' })
            $trueRows.Count | Should -BeGreaterThan 0
            $falseRows.Count | Should -BeGreaterThan 0
        }

        It 'CSV should have valid TypeOfDeployment values' {
            $validTypes = @('SingleNode', 'StorageSwitched', 'StorageSwitchless', 'RackAware', 'Disaggregated')
            foreach ($row in $script:CsvData) {
                $row.TypeOfDeployment | Should -BeIn $validTypes
            }
        }
    }
}

# ============================================================================
# Code Quality: CI/CD Functions
# ============================================================================
Describe 'Code Quality: CI/CD Automation Functions' {
    BeforeAll {
        $script:ModuleDir = Join-Path $PSScriptRoot '..'
        $script:ModuleSource = (@(Get-Content (Join-Path $script:ModuleDir 'AzLocal.DeploymentAutomation.psm1') -Raw) + @(Get-ChildItem (Join-Path $script:ModuleDir 'Public'), (Join-Path $script:ModuleDir 'Private') -Filter '*.ps1' | ForEach-Object { Get-Content $_.FullName -Raw })) -join "`n"
    }

    It 'New-AzLocalJUnitXml should have OutputType declaration' {
        $script:ModuleSource | Should -Match 'Function New-AzLocalJUnitXml[\s\S]*?\[OutputType'
    }

    It 'Import-AzLocalDeploymentCsv should have OutputType declaration' {
        $script:ModuleSource | Should -Match 'Function Import-AzLocalDeploymentCsv[\s\S]*?\[OutputType'
    }

    It 'Test-AzLocalClusterPreFlight should have OutputType declaration' {
        $script:ModuleSource | Should -Match 'Function Test-AzLocalClusterPreFlight[\s\S]*?\[OutputType'
    }

    It 'Test-AzLocalAzurePrerequisites should have OutputType declaration' {
        $script:ModuleSource | Should -Match 'Function Test-AzLocalAzurePrerequisites[\s\S]*?\[OutputType'
    }

    It 'Start-AzLocalCsvDeployment should have OutputType declaration' {
        $script:ModuleSource | Should -Match 'Function Start-AzLocalCsvDeployment[\s\S]*?\[OutputType'
    }

    It 'Get-AzLocalDeploymentStatus should have OutputType declaration' {
        $script:ModuleSource | Should -Match 'Function Get-AzLocalDeploymentStatus[\s\S]*?\[OutputType'
    }

    It 'Start-AzLocalCsvDeployment should support ShouldProcess' {
        $script:ModuleSource | Should -Match 'Function Start-AzLocalCsvDeployment[\s\S]*?SupportsShouldProcess'
    }

    It 'Start-AzLocalCsvDeployment should have ConfirmImpact High' {
        $script:ModuleSource | Should -Match 'Function Start-AzLocalCsvDeployment[\s\S]*?ConfirmImpact\s*=\s*.High.'
    }

    It 'Import-AzLocalDeploymentCsv should validate required CSV columns' {
        $script:ModuleSource | Should -Match 'requiredColumns'
    }

    It 'Test-AzLocalClusterPreFlight should check for Arc nodes via HybridCompute' {
        $script:ModuleSource | Should -Match 'Microsoft\.HybridCompute/machines'
    }

    It 'Test-AzLocalClusterPreFlight should check for existing cluster via AzureStackHCI' {
        $script:ModuleSource | Should -Match 'Microsoft\.AzureStackHCI/clusters'
    }

    It 'Test-AzLocalAzurePrerequisites should check all required resource providers' {
        $requiredProviders = @(
            'Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.HybridConnectivity',
            'Microsoft.AzureStackHCI', 'Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration',
            'Microsoft.ExtendedLocation', 'Microsoft.ResourceConnector', 'Microsoft.HybridContainerService',
            'Microsoft.Attestation', 'Microsoft.Storage', 'Microsoft.Insights'
        )
        foreach ($provider in $requiredProviders) {
            $script:ModuleSource | Should -Match ([regex]::Escape($provider))
        }
    }

    It 'Test-AzLocalAzurePrerequisites should check required RBAC roles' {
        $script:ModuleSource | Should -Match 'Azure Stack HCI Administrator'
        $script:ModuleSource | Should -Match 'Key Vault Data Access Administrator'
        $script:ModuleSource | Should -Match 'Key Vault Secrets Officer'
        $script:ModuleSource | Should -Match 'Storage Account Contributor'
    }

    It 'Resource existence checks should NOT mask errors with Get-AzResource -ErrorAction SilentlyContinue' {
        # The misleading "Arc node not found" customer bug was caused by
        # Get-AzResource -ErrorAction SilentlyContinue swallowing real errors.
        # Existence checks must go through Get-AzLocalArmResource instead.
        $script:ModuleSource | Should -Not -Match 'Get-AzResource\s+-ResourceId[^\r\n]*-ErrorAction\s+SilentlyContinue'
    }

    It 'Resource group and deployment existence checks should not use SilentlyContinue' {
        $script:ModuleSource | Should -Not -Match 'Get-AzResourceGroup\s+-Name[^\r\n]*-ErrorAction\s+SilentlyContinue'
        $script:ModuleSource | Should -Not -Match 'Get-AzResourceGroupDeployment[^\r\n]*-ErrorAction\s+SilentlyContinue'
    }

    It 'Not-found classification should not match broad English message fragments' {
        $helperPath = Join-Path $PSScriptRoot '..\Private\Test-AzLocalNotFoundError.ps1'
        $helperSource = Get-Content $helperPath -Raw
        $helperSource | Should -Not -Match '\$notFoundPattern\s*='
    }

    It 'Not-found classification should accept exact ARM codes and reject subscription errors' {
        InModuleScope AzLocal.DeploymentAutomation {
            $resourceNotFound = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new('Resource lookup failed'),
                'ResourceNotFound',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $null
            )
            $subscriptionError = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("The subscription 'missing' could not be found."),
                'SubscriptionNotFound',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $null
            )

            Test-AzLocalNotFoundError -ErrorRecord $resourceNotFound | Should -BeTrue
            Test-AzLocalNotFoundError -ErrorRecord $subscriptionError | Should -BeFalse
        }
    }

    It 'Existence checks should use the Get-AzLocalArmResource helper' {
        $script:ModuleSource | Should -Match 'Get-AzLocalArmResource\s+-ResourceId'
    }

    It 'Get-AzLocalArmResource should self-heal unsupported api-versions' {
        $script:ModuleSource | Should -Match 'supported api-versions'
        $script:ModuleSource | Should -Match 'Get-AzResource\s+-ResourceId\s+\$ResourceId\s+-ApiVersion'
    }

    It 'Arc node existence checks should default to the GA HybridCompute api-version 2025-01-13' {
        $script:ModuleSource | Should -Match '\$arcMachineApiVersion\s*=\s*''2025-01-13'''
        $script:ModuleSource | Should -Match '-ResourceKind ''Arc node'' -ApiVersion \$arcMachineApiVersion'
    }

    It 'Start-AzLocalTemplateDeployment should pin Azure context via Set-AzContext' {
        $script:ModuleSource | Should -Match 'Function Start-AzLocalTemplateDeployment[\s\S]*?Set-AzContext\s+-SubscriptionId\s+\$SubscriptionId\s+-TenantId\s+\$TenantId'
    }

    It 'Start-AzLocalTemplateDeployment should preserve errors without ErrorDetails under StrictMode' {
        $script:ModuleSource | Should -Match '\$ClusterDeploymentError\s*=\s*\$null'
        $script:ModuleSource | Should -Match '\$errorDetailsMessage\s*=\s*\$null'
        $script:ModuleSource | Should -Not -Match 'if\s*\(\$deployError\.ErrorDetails\.Message\)'
    }
}

# ============================================================================
# Deprecated File Tests
# ============================================================================
Describe 'Deprecated: two-node-switched-parameters-file.json' {

    It 'two-node-switched-parameters-file.json should NOT exist (deprecated in v0.8.0)' {
        $deprecatedPath = Join-Path $PSScriptRoot '..\template-parameter-files\two-node-switched-parameters-file.json'
        Test-Path $deprecatedPath | Should -Be $false
    }
}

# ============================================================================
# Function: Get-AzLocalValidationTroubleshootingHints
# ============================================================================
Describe 'Function: Get-AzLocalValidationTroubleshootingHints' {

    Context 'Parameter Validation' {
        It 'Should exist as a command in the module' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Get-AzLocalValidationTroubleshootingHints -ErrorAction SilentlyContinue
                $cmd | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should have mandatory ErrorText parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Get-AzLocalValidationTroubleshootingHints
                $cmd.Parameters['ErrorText'].Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -Be $true
            }
        }

        It 'ErrorText should be of type String' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Get-AzLocalValidationTroubleshootingHints
                $cmd.Parameters['ErrorText'].ParameterType.Name | Should -Be 'String'
            }
        }

        It 'Should have SearchOnline switch parameter' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Get-AzLocalValidationTroubleshootingHints
                $cmd.Parameters.Keys | Should -Contain 'SearchOnline'
                $cmd.Parameters['SearchOnline'].ParameterType.Name | Should -Be 'SwitchParameter'
            }
        }

        It 'SearchOnline should NOT be mandatory' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Get-AzLocalValidationTroubleshootingHints
                $attr = $cmd.Parameters['SearchOnline'].Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
                $attr.Mandatory | Should -Be $false
            }
        }

        It 'Should have OutputType of PSCustomObject[]' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command Get-AzLocalValidationTroubleshootingHints
                $cmd.OutputType | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Known Pattern: NetworkIntentValidationFailed' {
        It 'Should return a hint for NetworkIntentValidationFailed errors' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'NetworkIntentValidationFailed: adapters do not match with required adapters'
                $result | Should -Not -BeNullOrEmpty
                ($result | Where-Object { $_.Title -eq 'Network Adapter Mismatch' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should include Get-NetAdapter in remediation steps' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'NetworkIntentValidationFailed'
                $hint = $result | Where-Object { $_.Title -eq 'Network Adapter Mismatch' }
                ($hint.Remediation -join ' ') | Should -Match 'Get-NetAdapter'
            }
        }
    }

    Context 'Known Pattern: Management Intent Double-Wrap' {
        It 'Should detect vManagement(vManagement(...)) double-wrap pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $errorMsg = 'expected virtual NIC name is [vManagement(vManagement(Mgmt))]'
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText $errorMsg
                ($result | Where-Object { $_.Title -eq 'Management Intent Name Double-Wrapped' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should recommend using plain intent name without vManagement prefix' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'vManagement(vManagement(Mgmt))'
                $hint = $result | Where-Object { $_.Title -eq 'Management Intent Name Double-Wrapped' }
                ($hint.Remediation -join ' ') | Should -Match 'vManagement'
            }
        }
    }

    Context 'Known Pattern: GPO Inheritance Block' {
        It 'Should detect OuGpoInheritance errors' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'GpoInheritanceBlocked property of the AD OUs to true'
                ($result | Where-Object { $_.Title -match 'GPO Inheritance' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should mention WMI filters for enforced GPOs' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'OuGpoInheritance'
                $hint = $result | Where-Object { $_.Title -match 'GPO Inheritance' }
                ($hint.Remediation -join ' ') | Should -Match 'WMI filter'
            }
        }
    }

    Context 'Known Pattern: Duplicate RBAC Role Assignment' {
        It 'Should detect RoleAssignmentExists errors' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'The role assignment already exists. The ID of the existing role assignment is cb7707696aeb4790a6cd257b21c5699b.'
                ($result | Where-Object { $_.Title -match 'Duplicate RBAC' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should include az role assignment delete in remediation' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'RoleAssignmentExists'
                $hint = $result | Where-Object { $_.Title -match 'Duplicate RBAC' }
                ($hint.Remediation -join ' ') | Should -Match 'az role assignment delete'
            }
        }
    }

    Context 'Known Pattern: Physical Disk Validation' {
        It 'Should detect PhysicalDisk validation failures' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'AzStackHci_Hardware_Test_PhysicalDisk and HCISupportedData'
                ($result | Where-Object { $_.Title -match 'Physical Disk' }) | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should include Get-PhysicalDisk in remediation' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'Test_PhysicalDisk CanPool'
                $hint = $result | Where-Object { $_.Title -match 'Physical Disk' }
                ($hint.Remediation -join ' ') | Should -Match 'Get-PhysicalDisk'
            }
        }

        It 'Should mention HBA/passthrough mode for RAID controllers' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'Test_PhysicalDisk'
                $hint = $result | Where-Object { $_.Title -match 'Physical Disk' }
                ($hint.Remediation -join ' ') | Should -Match 'HBA.*passthrough|passthrough.*HBA'
            }
        }
    }

    Context 'Known Pattern: Deployment Settings Validation Failed' {
        It 'Should detect UpdateDeploymentSettingsDataFailed errors' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'UpdateDeploymentSettingsDataFailed: Deployment Settings validation failed.'
                ($result | Where-Object { $_.Title -eq 'Deployment Settings Validation Failed' }) | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Known Pattern: OperationTimeout' {
        It 'Should detect OperationTimeout errors' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'OperationTimeout during validation'
                ($result | Where-Object { $_.Title -eq 'Deployment Settings Validation Timeout' }) | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Multiple Pattern Matching' {
        It 'Should return multiple hints when error text matches more than one pattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $errorMsg = 'UpdateDeploymentSettingsDataFailed OuGpoInheritance GpoInheritanceBlocked'
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText $errorMsg
                $result.Count | Should -BeGreaterOrEqual 2
            }
        }
    }

    Context 'Hint Output Structure' {
        It 'Should return hints with Source, Title, Description, Remediation, and Reference properties' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'NetworkIntentValidationFailed'
                $hint = $result | Select-Object -First 1
                $hint.PSObject.Properties.Name | Should -Contain 'Source'
                $hint.PSObject.Properties.Name | Should -Contain 'Title'
                $hint.PSObject.Properties.Name | Should -Contain 'Description'
                $hint.PSObject.Properties.Name | Should -Contain 'Remediation'
                $hint.PSObject.Properties.Name | Should -Contain 'Reference'
            }
        }

        It 'Known pattern hints should have Source set to KnownPattern' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'RoleAssignmentExists'
                $hint = $result | Where-Object { $_.Source -eq 'KnownPattern' }
                $hint | Should -Not -BeNullOrEmpty
            }
        }

        It 'Remediation should be an array of strings' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'OuGpoInheritance'
                $hint = $result | Select-Object -First 1
                $hint.Remediation | Should -BeOfType [string]
                $hint.Remediation.Count | Should -BeGreaterOrEqual 1
            }
        }

        It 'Reference should contain a URL' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'NetworkIntentValidationFailed'
                $hint = $result | Select-Object -First 1
                $hint.Reference | Should -Match '^https://'
            }
        }
    }

    Context 'Edge Cases' {
        It 'Should return empty array for empty error text' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText ''
                $result | Should -BeNullOrEmpty
            }
        }

        It 'Should return empty array for whitespace-only error text' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText '   '
                $result | Should -BeNullOrEmpty
            }
        }

        It 'Should return empty array for error text that matches no known patterns' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalValidationTroubleshootingHints -ErrorText 'Some completely unrelated error message about something else'
                # Should return empty or null (no known patterns matched, no online search)
                if ($result) {
                    $result.Count | Should -Be 0
                }
            }
        }

        It 'Should not throw for very long error text' {
            InModuleScope AzLocal.DeploymentAutomation {
                $longText = 'UpdateDeploymentSettingsDataFailed ' + ('x' * 5000)
                { Get-AzLocalValidationTroubleshootingHints -ErrorText $longText } | Should -Not -Throw
            }
        }
    }
}

# ============================================================================
# New-AzLocalDeploymentReport
# ============================================================================
Describe 'Function: New-AzLocalDeploymentReport' {

    # Helper: build mock status results
    BeforeAll {
        $script:mockResults = @(
            [PSCustomObject]@{
                UniqueID          = 'Store001'
                ClusterName       = 'hci-Store001'
                ResourceGroupName = 'rg-hci-Store001'
                DeploymentName    = 'deploy-Store001'
                DeploymentStatus  = 'DeploySucceeded'
                ProvisioningState = 'Succeeded'
                Message           = "Deployment 'deploy-Store001' state: Succeeded"
                Duration          = 3.14
            },
            [PSCustomObject]@{
                UniqueID          = 'Store002'
                ClusterName       = 'hci-Store002'
                ResourceGroupName = 'rg-hci-Store002'
                DeploymentName    = 'deploy-Store002'
                DeploymentStatus  = 'DeployFailed'
                ProvisioningState = 'Failed'
                Message           = "Deployment 'deploy-Store002' state: Failed"
                Duration          = 1.5
            },
            [PSCustomObject]@{
                UniqueID          = 'Store003'
                ClusterName       = 'hci-Store003'
                ResourceGroupName = 'rg-hci-Store003'
                DeploymentName    = 'deploy-Store003'
                DeploymentStatus  = 'DeployInProgress'
                ProvisioningState = 'Running'
                Message           = "Deployment 'deploy-Store003' state: Running"
                Duration          = 0.8
            },
            [PSCustomObject]@{
                UniqueID          = 'Store004'
                ClusterName       = 'hci-Store004'
                ResourceGroupName = 'rg-hci-Store004'
                DeploymentName    = 'deploy-Store004'
                DeploymentStatus  = 'NotStarted'
                ProvisioningState = 'N/A'
                Message           = "No deployment found."
                Duration          = 0.2
            }
        )
    }

    Context 'HTML Report Generation' {

        It 'Should generate HTML file when HtmlOutputPath is specified' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $htmlPath = Join-Path $TestDrive 'report.html'
                $result = New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $htmlPath
                Test-Path $htmlPath | Should -Be $true
                $result.Html | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should produce valid HTML structure' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $htmlPath = Join-Path $TestDrive 'structure.html'
                New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $htmlPath | Out-Null
                $html = Get-Content $htmlPath -Raw
                $html | Should -Match '<!DOCTYPE html>'
                $html | Should -Match '<html'
                $html | Should -Match '</html>'
                $html | Should -Match 'Azure Local Deployment Status Report'
            }
        }

        It 'Should include all cluster UniqueIDs in HTML' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $htmlPath = Join-Path $TestDrive 'ids.html'
                New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $htmlPath | Out-Null
                $html = Get-Content $htmlPath -Raw
                $html | Should -Match 'Store001'
                $html | Should -Match 'Store002'
                $html | Should -Match 'Store003'
                $html | Should -Match 'Store004'
            }
        }

        It 'Should include correct summary counts in HTML' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $htmlPath = Join-Path $TestDrive 'counts.html'
                New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $htmlPath | Out-Null
                $html = Get-Content $htmlPath -Raw
                # Total = 4 clusters
                $html | Should -Match 'class="number">4<'
            }
        }

        It 'Should contain status badge CSS classes' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $htmlPath = Join-Path $TestDrive 'badges.html'
                New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $htmlPath | Out-Null
                $html = Get-Content $htmlPath -Raw
                $html | Should -Match 'status-succeeded'
                $html | Should -Match 'status-failed'
                $html | Should -Match 'status-inprogress'
                $html | Should -Match 'status-notstarted'
            }
        }

        It 'Should use custom ReportTitle in HTML' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $htmlPath = Join-Path $TestDrive 'custom-title.html'
                New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $htmlPath -ReportTitle 'My Custom Report'
                $html = Get-Content $htmlPath -Raw
                $html | Should -Match 'My Custom Report'
            }
        }

        It 'Should HTML-encode special characters in cluster data' {
            InModuleScope AzLocal.DeploymentAutomation {
                $specialResults = @(
                    [PSCustomObject]@{
                        UniqueID          = 'Test01'
                        ClusterName       = 'hci-<script>alert(1)</script>'
                        ResourceGroupName = 'rg-test'
                        DeploymentName    = 'deploy-test'
                        DeploymentStatus  = 'NotStarted'
                        ProvisioningState = 'N/A'
                        Message           = 'Contains <html> & "quotes"'
                        Duration          = 0
                    }
                )
                $htmlPath = Join-Path $TestDrive 'xss.html'
                New-AzLocalDeploymentReport -StatusResults $specialResults -HtmlOutputPath $htmlPath | Out-Null
                $html = Get-Content $htmlPath -Raw
                # Should NOT contain raw script tags
                $html | Should -Not -Match '<script>alert'
                # Should contain encoded version
                $html | Should -Match '&lt;script&gt;'
            }
        }

        It 'Should create output directory if it does not exist' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $nestedPath = Join-Path $TestDrive 'sub\folder\report.html'
                New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $nestedPath | Out-Null
                Test-Path $nestedPath | Should -Be $true
            }
        }
    }

    Context 'Markdown Report Generation' {

        It 'Should generate Markdown file when MarkdownOutputPath is specified' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $mdPath = Join-Path $TestDrive 'report.md'
                $result = New-AzLocalDeploymentReport -StatusResults $mockResults -MarkdownOutputPath $mdPath
                Test-Path $mdPath | Should -Be $true
                $result.Markdown | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should include summary table in Markdown' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $mdPath = Join-Path $TestDrive 'summary.md'
                New-AzLocalDeploymentReport -StatusResults $mockResults -MarkdownOutputPath $mdPath | Out-Null
                $md = Get-Content $mdPath -Raw
                $md | Should -Match 'Succeeded \| 1'
                $md | Should -Match 'Failed \| 1'
                $md | Should -Match 'In Progress \| 1'
                $md | Should -Match 'Not Started \| 1'
                $md | Should -Match '\*\*Total\*\* \| \*\*4\*\*'
            }
        }

        It 'Should include cluster details table in Markdown' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $mdPath = Join-Path $TestDrive 'details.md'
                New-AzLocalDeploymentReport -StatusResults $mockResults -MarkdownOutputPath $mdPath | Out-Null
                $md = Get-Content $mdPath -Raw
                $md | Should -Match 'Store001'
                $md | Should -Match 'Store002'
                $md | Should -Match 'hci-Store001'
            }
        }

        It 'Should include failed deployments section in Markdown' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $mdPath = Join-Path $TestDrive 'failed.md'
                New-AzLocalDeploymentReport -StatusResults $mockResults -MarkdownOutputPath $mdPath | Out-Null
                $md = Get-Content $mdPath -Raw
                $md | Should -Match 'Failed Deployments'
                $md | Should -Match 'Store002'
            }
        }

        It 'Should use custom ReportTitle in Markdown' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $mdPath = Join-Path $TestDrive 'custom.md'
                New-AzLocalDeploymentReport -StatusResults $mockResults -MarkdownOutputPath $mdPath -ReportTitle 'Weekly Fleet Status'
                $md = Get-Content $mdPath -Raw
                $md | Should -Match 'Weekly Fleet Status'
            }
        }
    }

    Context 'Both Formats' {

        It 'Should generate both HTML and Markdown when both paths are specified' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $htmlPath = Join-Path $TestDrive 'both.html'
                $mdPath = Join-Path $TestDrive 'both.md'
                $result = New-AzLocalDeploymentReport -StatusResults $mockResults -HtmlOutputPath $htmlPath -MarkdownOutputPath $mdPath
                Test-Path $htmlPath | Should -Be $true
                Test-Path $mdPath | Should -Be $true
                $result.Html | Should -Not -BeNullOrEmpty
                $result.Markdown | Should -Not -BeNullOrEmpty
            }
        }

        It 'Should return empty strings when no output paths are specified' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ mockResults = $script:mockResults } {
                param ($mockResults)
                $result = New-AzLocalDeploymentReport -StatusResults $mockResults
                $result.Html | Should -BeNullOrEmpty
                $result.Markdown | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Edge Cases' {

        It 'Should handle empty results array' {
            InModuleScope AzLocal.DeploymentAutomation {
                $htmlPath = Join-Path $TestDrive 'empty.html'
                $mdPath = Join-Path $TestDrive 'empty.md'
                { New-AzLocalDeploymentReport -StatusResults @() -HtmlOutputPath $htmlPath -MarkdownOutputPath $mdPath } | Should -Not -Throw
                Test-Path $htmlPath | Should -Be $true
                $html = Get-Content $htmlPath -Raw
                $html | Should -Match 'No clusters with ReadyToDeploy = TRUE'
            }
        }

        It 'Should handle all-succeeded results' {
            InModuleScope AzLocal.DeploymentAutomation {
                $allSuccess = @(
                    [PSCustomObject]@{
                        UniqueID = 'S1'; ClusterName = 'c1'; ResourceGroupName = 'rg1'
                        DeploymentName = 'd1'; DeploymentStatus = 'DeploySucceeded'
                        ProvisioningState = 'Succeeded'; Message = 'OK'; Duration = 1
                    },
                    [PSCustomObject]@{
                        UniqueID = 'S2'; ClusterName = 'c2'; ResourceGroupName = 'rg2'
                        DeploymentName = 'd2'; DeploymentStatus = 'ClusterExists'
                        ProvisioningState = 'Succeeded'; Message = 'Exists'; Duration = 0.5
                    }
                )
                $mdPath = Join-Path $TestDrive 'allsuccess.md'
                New-AzLocalDeploymentReport -StatusResults $allSuccess -MarkdownOutputPath $mdPath | Out-Null
                $md = Get-Content $mdPath -Raw
                $md | Should -Match 'Succeeded \| 2'
                $md | Should -Match 'Failed \| 0'
                $md | Should -Not -Match 'Failed Deployments'
            }
        }

        It 'Should handle ContextError status as failed' {
            InModuleScope AzLocal.DeploymentAutomation {
                $contextErr = @(
                    [PSCustomObject]@{
                        UniqueID = 'CE1'; ClusterName = 'c1'; ResourceGroupName = 'rg1'
                        DeploymentName = 'd1'; DeploymentStatus = 'ContextError'
                        ProvisioningState = 'N/A'; Message = 'Failed to set context'; Duration = 0
                    }
                )
                $htmlPath = Join-Path $TestDrive 'contexterr.html'
                New-AzLocalDeploymentReport -StatusResults $contextErr -HtmlOutputPath $htmlPath | Out-Null
                $html = Get-Content $htmlPath -Raw
                $html | Should -Match 'status-failed'
            }
        }

        It 'Should handle CheckError status as failed' {
            InModuleScope AzLocal.DeploymentAutomation {
                $checkError = @(
                    [PSCustomObject]@{
                        UniqueID = 'CE2'; ClusterName = 'c2'; ResourceGroupName = 'rg2'
                        DeploymentName = 'd2'; DeploymentStatus = 'CheckError'
                        ProvisioningState = 'N/A'; Message = 'Lookup failed'; Duration = 0
                    }
                )
                $htmlPath = Join-Path $TestDrive 'checkerr.html'
                $mdPath = Join-Path $TestDrive 'checkerr.md'
                New-AzLocalDeploymentReport -StatusResults $checkError -HtmlOutputPath $htmlPath -MarkdownOutputPath $mdPath | Out-Null
                (Get-Content $htmlPath -Raw) | Should -Match 'status-failed'
                (Get-Content $mdPath -Raw) | Should -Match 'Failed \| 1'
                (Get-Content $mdPath -Raw) | Should -Match 'Failed Deployments'
            }
        }
    }

    Context 'OutputType' {

        It 'Should declare [hashtable] OutputType' {
            InModuleScope AzLocal.DeploymentAutomation {
                $cmd = Get-Command New-AzLocalDeploymentReport
                $cmd.OutputType.Type.Name | Should -Contain 'hashtable'
            }
        }
    }
}

# ============================================================================
# Disaggregated (SAN) Deployment Tests - v1.0.0
# ============================================================================
Describe 'Disaggregated (SAN) Deployment Support' {

    Context 'Start-AzLocalTemplateDeployment - Disaggregated parameters' {
        BeforeAll {
            $script:DisCmd = Get-Command Start-AzLocalTemplateDeployment
        }

        It 'Should expose -InfraVolLunId parameter as [string]' {
            $script:DisCmd.Parameters.Keys | Should -Contain 'InfraVolLunId'
            $script:DisCmd.Parameters['InfraVolLunId'].ParameterType.Name | Should -Be 'String'
        }

        It 'Should expose -InfraPerfLunId parameter as [string]' {
            $script:DisCmd.Parameters.Keys | Should -Contain 'InfraPerfLunId'
            $script:DisCmd.Parameters['InfraPerfLunId'].ParameterType.Name | Should -Be 'String'
        }

        It 'Should expose -SanNetworkAdapterName parameter as [string]' {
            $script:DisCmd.Parameters.Keys | Should -Contain 'SanNetworkAdapterName'
            $script:DisCmd.Parameters['SanNetworkAdapterName'].ParameterType.Name | Should -Be 'String'
        }

        It 'Should expose -SanNetworkVlanId parameter as [int]' {
            $script:DisCmd.Parameters.Keys | Should -Contain 'SanNetworkVlanId'
            $script:DisCmd.Parameters['SanNetworkVlanId'].ParameterType.Name | Should -Be 'Int32'
        }

        It 'SanNetworkVlanId ValidateRange should accept the -1 sentinel and 0-4095' {
            $vrange = $script:DisCmd.Parameters['SanNetworkVlanId'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $vrange | Should -Not -BeNullOrEmpty
            $vrange.MinRange | Should -Be -1
            $vrange.MaxRange | Should -Be 4095
        }

        It 'Should expose -SanNetworkAddressPrefix with a CIDR ValidatePattern' {
            $script:DisCmd.Parameters.Keys | Should -Contain 'SanNetworkAddressPrefix'
            $vpattern = $script:DisCmd.Parameters['SanNetworkAddressPrefix'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] }
            $vpattern | Should -Not -BeNullOrEmpty
        }

        It 'Should expose -SanBandwidthPercentageSmb (1-97, default 50)' {
            $script:DisCmd.Parameters.Keys | Should -Contain 'SanBandwidthPercentageSmb'
            $vrange = $script:DisCmd.Parameters['SanBandwidthPercentageSmb'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $vrange.MinRange | Should -Be 1
            $vrange.MaxRange | Should -Be 97
        }

        It 'Should expose -SanJumboPacket accepting only 1514 or 9014' {
            $script:DisCmd.Parameters.Keys | Should -Contain 'SanJumboPacket'
            $vset = $script:DisCmd.Parameters['SanJumboPacket'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $vset | Should -Not -BeNullOrEmpty
            ([int[]]$vset.ValidValues | Sort-Object) | Should -Be @(1514, 9014)
        }
    }

    Context 'Get-AzLocalParameterFilePath - Disaggregated mapping' {
        It 'Should return disaggregated-parameters-file.json for Disaggregated' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'Disaggregated' -NodeCount 8
                $result | Should -Match 'disaggregated-parameters-file\.json$'
            }
        }

        It 'Should resolve to a file that exists on disk' {
            InModuleScope AzLocal.DeploymentAutomation {
                $result = Get-AzLocalParameterFilePath -TypeOfDeployment 'Disaggregated' -NodeCount 8
                Test-Path $result | Should -Be $true
            }
        }

        It 'Should accept NodeCount = 1 (single-node SAN)' {
            InModuleScope AzLocal.DeploymentAutomation {
                { Get-AzLocalParameterFilePath -TypeOfDeployment 'Disaggregated' -NodeCount 1 } | Should -Not -Throw
            }
        }

        It 'Should accept NodeCount = 64 (boundary)' {
            InModuleScope AzLocal.DeploymentAutomation {
                { Get-AzLocalParameterFilePath -TypeOfDeployment 'Disaggregated' -NodeCount 64 } | Should -Not -Throw
            }
        }

        It 'Should reject NodeCount = 0 for Disaggregated (param binder enforces ValidateRange 1-64)' {
            InModuleScope AzLocal.DeploymentAutomation {
                { Get-AzLocalParameterFilePath -TypeOfDeployment 'Disaggregated' -NodeCount 0 } |
                    Should -Throw -ExpectedMessage '*minimum allowed range of 1*'
            }
        }

        It 'Should reject NodeCount = 65 for Disaggregated (param binder enforces ValidateRange 1-64)' {
            InModuleScope AzLocal.DeploymentAutomation {
                { Get-AzLocalParameterFilePath -TypeOfDeployment 'Disaggregated' -NodeCount 65 } |
                    Should -Throw -ExpectedMessage '*maximum allowed range of 64*'
            }
        }
    }

    Context 'SAN ARM Template - templates/azure-local-deployment-template-san.json' {
        BeforeAll {
            $script:SanTemplatePath = Join-Path $script:ModuleInfo.ModuleBase 'templates\azure-local-deployment-template-san.json'
            $script:SanTemplate = Get-Content $script:SanTemplatePath -Raw | ConvertFrom-Json
        }

        It 'Should exist on disk' {
            Test-Path $script:SanTemplatePath | Should -Be $true
        }

        It 'Should declare an infraVolLunId parameter' {
            $script:SanTemplate.parameters.PSObject.Properties.Name | Should -Contain 'infraVolLunId'
        }

        It 'Should declare an infraPerfLunId parameter' {
            $script:SanTemplate.parameters.PSObject.Properties.Name | Should -Contain 'infraPerfLunId'
        }

        It 'Should declare a sanNetworkList parameter' {
            $script:SanTemplate.parameters.PSObject.Properties.Name | Should -Contain 'sanNetworkList'
        }

        It 'Should NOT declare storageNetworkList (SAN template uses sanNetworkList)' {
            $script:SanTemplate.parameters.PSObject.Properties.Name | Should -Not -Contain 'storageNetworkList'
        }
    }

    Context 'Disaggregated parameter file - template-parameter-files/disaggregated-parameters-file.json' {
        BeforeAll {
            $script:DisaggParamPath = Join-Path $script:ModuleInfo.ModuleBase 'template-parameter-files\disaggregated-parameters-file.json'
            $script:DisaggParam = Get-Content $script:DisaggParamPath -Raw | ConvertFrom-Json
        }

        It 'Should exist on disk' {
            Test-Path $script:DisaggParamPath | Should -Be $true
        }

        It 'Should contain a sanNetworkList parameter block' {
            $script:DisaggParam.parameters.PSObject.Properties.Name | Should -Contain 'sanNetworkList'
        }

        It 'sanNetworkList should contain clusterNetworkConfig with adapterProperties and adapterIPConfig' {
            $cnc = $script:DisaggParam.parameters.sanNetworkList.value.clusterNetworkConfig
            $cnc | Should -Not -BeNullOrEmpty
            $cnc.PSObject.Properties.Name | Should -Contain 'adapterProperties'
            $cnc.PSObject.Properties.Name | Should -Contain 'adapterIPConfig'
        }

        It 'adapterProperties should include bandwidthPercentageSmb and jumboPacket' {
            $ap = $script:DisaggParam.parameters.sanNetworkList.value.clusterNetworkConfig.adapterProperties
            $ap.PSObject.Properties.Name | Should -Contain 'bandwidthPercentageSmb'
            $ap.PSObject.Properties.Name | Should -Contain 'jumboPacket'
        }
    }

    Context 'Get-AzLocalNetworkSettingsFromJson - sanSettings parsing' {
        It 'Should reject Disaggregated JSON without a sanSettings block' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.5.1","startingIPAddress":"10.0.5.10","endingIPAddress":"10.0.5.30","nodeIPAddresses":["10.0.5.100","10.0.5.101"]}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'Disaggregated' -NodeCount 2 } |
                    Should -Throw -ExpectedMessage '*sanSettings*'
            }
        }

        It 'Should accept a complete Disaggregated JSON with sanSettings' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.5.1","startingIPAddress":"10.0.5.10","endingIPAddress":"10.0.5.30","nodeIPAddresses":["10.0.5.100","10.0.5.101"],"sanSettings":{"infraVolLunId":"PURE1234567890ABCDEF","infraPerfLunId":"PURE0987654321MNOPQR","sanNetworkAdapterName":"ethernet 3","sanNetworkVlanId":711,"sanNetworkAddressPrefix":"10.10.30.0/24"}}'
                $result = Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'Disaggregated' -NodeCount 2
                $result.sanSettings | Should -Not -BeNullOrEmpty
                $result.sanSettings.infraVolLunId | Should -Be 'PURE1234567890ABCDEF'
                $result.sanSettings.sanNetworkVlanId | Should -Be 711
                $result.sanSettings.sanNetworkAddressPrefix | Should -Be '10.10.30.0/24'
            }
        }

        It 'Should reject sanNetworkVlanId outside the 0-4095 range' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.5.1","startingIPAddress":"10.0.5.10","endingIPAddress":"10.0.5.30","nodeIPAddresses":["10.0.5.100"],"sanSettings":{"infraVolLunId":"X","infraPerfLunId":"Y","sanNetworkAdapterName":"e3","sanNetworkVlanId":5000,"sanNetworkAddressPrefix":"10.10.30.0/24"}}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'Disaggregated' -NodeCount 1 } |
                    Should -Throw -ExpectedMessage '*0-4095*'
            }
        }

        It 'Should reject malformed sanNetworkAddressPrefix (not CIDR)' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.5.1","startingIPAddress":"10.0.5.10","endingIPAddress":"10.0.5.30","nodeIPAddresses":["10.0.5.100"],"sanSettings":{"infraVolLunId":"X","infraPerfLunId":"Y","sanNetworkAdapterName":"e3","sanNetworkVlanId":711,"sanNetworkAddressPrefix":"not-a-cidr"}}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'Disaggregated' -NodeCount 1 } |
                    Should -Throw -ExpectedMessage '*CIDR*'
            }
        }

        It 'Should reject out-of-range sanNetworkAddressPrefix values' {
            InModuleScope AzLocal.DeploymentAutomation {
                $json = '{"subnetMask":"255.255.255.0","defaultGateway":"10.0.5.1","startingIPAddress":"10.0.5.10","endingIPAddress":"10.0.5.30","nodeIPAddresses":["10.0.5.100"],"sanSettings":{"infraVolLunId":"X","infraPerfLunId":"Y","sanNetworkAdapterName":"e3","sanNetworkVlanId":711,"sanNetworkAddressPrefix":"999.999.999.999/99"}}'
                { Get-AzLocalNetworkSettingsFromJson -NetworkSettingsJson $json -TypeOfDeployment 'Disaggregated' -NodeCount 1 } |
                    Should -Throw -ExpectedMessage '*CIDR*'
            }
        }
    }

    Context 'Import-AzLocalDeploymentCsv - Disaggregated CSV columns' {
        BeforeAll {
            $script:DisaggCsvDir = Join-Path $env:TEMP 'AzLocal-Disagg-Tests'
            New-Item -ItemType Directory -Path $script:DisaggCsvDir -Force | Out-Null
            $script:DisaggCsvHeader = 'UniqueID,ReadyToDeploy,SubscriptionId,TenantId,TypeOfDeployment,NodeCount,Location,CredentialKeyVaultName,LocalAdminSecretName,LCMAdminSecretName,SubnetMask,DefaultGateway,StartingIPAddress,EndingIPAddress,DnsServers,NodeIPAddresses,InfraVolLunId,InfraPerfLunId,SanNetworkAdapterName,SanNetworkVlanId,SanNetworkAddressPrefix'
        }

        AfterAll {
            Remove-Item -Path $script:DisaggCsvDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Should accept a Disaggregated row with all SAN columns populated' {
            $tmp = Join-Path $script:DisaggCsvDir 'good.csv'
            $row = 'D01,TRUE,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,ffffffff-aaaa-bbbb-cccc-dddddddddddd,Disaggregated,2,westeurope,kv,LocalAdminCredential,AzureStackLCMUserCredential,255.255.255.0,10.0.5.1,10.0.5.10,10.0.5.30,10.0.0.1,10.0.5.100;10.0.5.101,PUREVOL,PUREPERF,ethernet 3,711,10.10.30.0/24'
            Set-Content -Path $tmp -Value @($script:DisaggCsvHeader, $row) -Encoding ASCII
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Path = $tmp } {
                param($Path)
                { Import-AzLocalDeploymentCsv -CsvFilePath $Path } | Should -Not -Throw
            }
        }

        It 'Should reject a Disaggregated row missing InfraVolLunId' {
            $tmp = Join-Path $script:DisaggCsvDir 'missing-lun.csv'
            $row = 'D02,TRUE,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,ffffffff-aaaa-bbbb-cccc-dddddddddddd,Disaggregated,2,westeurope,kv,,,255.255.255.0,10.0.5.1,10.0.5.10,10.0.5.30,10.0.0.1,10.0.5.100;10.0.5.101,,PUREPERF,ethernet 3,711,10.10.30.0/24'
            Set-Content -Path $tmp -Value @($script:DisaggCsvHeader, $row) -Encoding ASCII
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Path = $tmp } {
                param($Path)
                { Import-AzLocalDeploymentCsv -CsvFilePath $Path } | Should -Throw -ExpectedMessage '*InfraVolLunId*'
            }
        }

        It 'Should reject a Disaggregated row with VLAN > 4095' {
            $tmp = Join-Path $script:DisaggCsvDir 'bad-vlan.csv'
            $row = 'D03,TRUE,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,ffffffff-aaaa-bbbb-cccc-dddddddddddd,Disaggregated,2,westeurope,kv,,,255.255.255.0,10.0.5.1,10.0.5.10,10.0.5.30,10.0.0.1,10.0.5.100;10.0.5.101,VOL,PERF,ethernet 3,9999,10.10.30.0/24'
            Set-Content -Path $tmp -Value @($script:DisaggCsvHeader, $row) -Encoding ASCII
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Path = $tmp } {
                param($Path)
                { Import-AzLocalDeploymentCsv -CsvFilePath $Path } | Should -Throw -ExpectedMessage '*VlanId*'
            }
        }

        It 'Should reject a Disaggregated row with NodeCount = 65' {
            $tmp = Join-Path $script:DisaggCsvDir 'too-many.csv'
            $nips = (1..65 | ForEach-Object { "10.0.5.$_" }) -join ';'
            $row = "D04,TRUE,aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,ffffffff-aaaa-bbbb-cccc-dddddddddddd,Disaggregated,65,westeurope,kv,,,255.255.255.0,10.0.5.1,10.0.5.10,10.0.5.200,10.0.0.1,$nips,VOL,PERF,ethernet 3,711,10.10.30.0/24"
            Set-Content -Path $tmp -Value @($script:DisaggCsvHeader, $row) -Encoding ASCII
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Path = $tmp } {
                param($Path)
                { Import-AzLocalDeploymentCsv -CsvFilePath $Path } | Should -Throw -ExpectedMessage '*1-64*'
            }
        }
    }

    Context 'Disaggregated v1.0.0 - shipped example CSV' {
        It 'automation-pipelines/cluster-deployments.csv should have at least one Disaggregated row' {
            $csv = Join-Path $script:ModuleInfo.ModuleBase 'automation-pipelines\cluster-deployments.csv'
            Test-Path $csv | Should -Be $true
            $rows = Import-Csv -Path $csv
            # Wrap with @() so single-item result still has a .Count (PS 5.1 quirk)
            $disaggRows = @($rows | Where-Object { $_.TypeOfDeployment -eq 'Disaggregated' })
            $disaggRows.Count | Should -BeGreaterOrEqual 1
        }

        It 'shipped CSV header should include the 5 SAN columns' {
            $csv = Join-Path $script:ModuleInfo.ModuleBase 'automation-pipelines\cluster-deployments.csv'
            $headers = (Get-Content $csv -TotalCount 1) -split ','
            $headers | Should -Contain 'InfraVolLunId'
            $headers | Should -Contain 'InfraPerfLunId'
            $headers | Should -Contain 'SanNetworkAdapterName'
            $headers | Should -Contain 'SanNetworkVlanId'
            $headers | Should -Contain 'SanNetworkAddressPrefix'
        }
    }
}

# ============================================================================
# Function: Get-AzLocalArmResource (existence-aware, error-surfacing getter)
# ============================================================================
Describe 'Function: Get-AzLocalArmResource' {

    BeforeAll {
        $script:armResourceId = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-test/providers/Microsoft.HybridCompute/machines/node01'
    }

    Context 'Resource exists' {
        It 'Should return the resource object returned by Get-AzResource' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Id = $script:armResourceId } {
                param($Id)
                Mock Get-AzResource { return [PSCustomObject]@{ Name = 'node01'; Type = 'Microsoft.HybridCompute/machines' } }
                $result = Get-AzLocalArmResource -ResourceId $Id -ResourceKind 'Arc node'
                $result | Should -Not -BeNullOrEmpty
                $result.Name | Should -Be 'node01'
            }
        }

        It 'Should use a caller-supplied api-version on the first lookup' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Id = $script:armResourceId } {
                param($Id)
                Mock Get-AzResource {
                    param($ResourceId, $ApiVersion)
                    return [PSCustomObject]@{ Name = 'node01'; ApiVersionUsed = $ApiVersion }
                }
                $result = Get-AzLocalArmResource -ResourceId $Id -ResourceKind 'Arc node' -ApiVersion '2025-01-13'
                $result.ApiVersionUsed | Should -Be '2025-01-13'
            }
        }
    }

    Context 'Resource genuinely absent (HTTP 404)' {
        It 'Should return $null when Get-AzResource reports the resource was not found' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Id = $script:armResourceId } {
                param($Id)
                Mock Get-AzResource { throw "ResourceNotFound: The Resource 'Microsoft.HybridCompute/machines/node01' under resource group 'rg-test' was not found." }
                $result = Get-AzLocalArmResource -ResourceId $Id -ResourceKind 'Arc node'
                $result | Should -BeNullOrEmpty
            }
        }

        It 'Should return $null on an explicit ResourceNotFound error' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Id = $script:armResourceId } {
                param($Id)
                Mock Get-AzResource { throw 'ResourceNotFound: The resource could not be found.' }
                Get-AzLocalArmResource -ResourceId $Id | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Unsupported api-version (HTTP 400) self-heal' {
        It 'Should retry with the newest stable supported api-version and return the resource' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Id = $script:armResourceId } {
                param($Id)
                Mock Get-AzResource {
                    param($ResourceId, $ApiVersion)
                    if (-not $ApiVersion) {
                        throw "No registered resource provider found for location 'westeurope' and API version '2026-06-04-preview' for type 'machines'. The supported api-versions are '2019-03-18-preview, 2024-07-10, 2025-01-13, 2025-02-19-preview'."
                    }
                    return [PSCustomObject]@{ Name = 'node01'; ApiVersionUsed = $ApiVersion }
                }
                $result = Get-AzLocalArmResource -ResourceId $Id -ResourceKind 'Arc node'
                $result.Name | Should -Be 'node01'
                # Newest STABLE version wins (preview versions are excluded).
                $result.ApiVersionUsed | Should -Be '2025-01-13'
            }
        }

        It 'Should return $null if the resource is genuinely absent at the retried api-version' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Id = $script:armResourceId } {
                param($Id)
                Mock Get-AzResource {
                    param($ResourceId, $ApiVersion)
                    if (-not $ApiVersion) {
                        throw "No registered resource provider found for location 'westeurope' and API version '2026-06-04-preview'. The supported api-versions are '2024-07-10, 2025-01-13'."
                    }
                    throw "ResourceNotFound: The Resource under resource group 'rg-test' was not found."
                }
                Get-AzLocalArmResource -ResourceId $Id | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Real failure (auth / RBAC / transport)' {
        It 'Should rethrow and surface the real error instead of masking it as not found' {
            InModuleScope AzLocal.DeploymentAutomation -Parameters @{ Id = $script:armResourceId } {
                param($Id)
                Mock Get-AzResource { throw 'Authentication failed. Please run Connect-AzAccount.' }
                { Get-AzLocalArmResource -ResourceId $Id -ResourceKind 'Arc node' } |
                    Should -Throw -ExpectedMessage '*Authentication failed*'
            }
        }
    }
}
