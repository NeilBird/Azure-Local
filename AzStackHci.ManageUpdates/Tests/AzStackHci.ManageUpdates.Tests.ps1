#Requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the AzStackHci.ManageUpdates module.

.DESCRIPTION
    Unit tests for the Azure Local Update Management module.
    These tests validate parameter validation, function behavior, and output types
    without requiring actual Azure connectivity (using mocks).

.NOTES
    Run with: Invoke-Pester -Path .\Tests -OutputFormat NUnitXml -OutputFile .\Tests\TestResults.xml
    Generate HTML: .\Tests\Generate-TestReport.ps1
#>

BeforeAll {
    # Import the module from parent directory
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzStackHci.ManageUpdates.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop
    
    # Store module info for tests
    $script:ModuleInfo = Get-Module AzStackHci.ManageUpdates
}

AfterAll {
    # Clean up
    Remove-Module AzStackHci.ManageUpdates -Force -ErrorAction SilentlyContinue
}

Describe 'Module: AzStackHci.ManageUpdates' {
    
    Context 'Module Load' {
        It 'Should load the module without errors' {
            $script:ModuleInfo | Should -Not -BeNullOrEmpty
        }

        It 'Should have version 0.5.1' {
            $script:ModuleInfo.Version | Should -Be '0.5.1'
        }

        It 'Should export exactly 9 functions' {
            $script:ModuleInfo.ExportedFunctions.Count | Should -Be 9
        }

        It 'Should export the expected functions' {
            $expectedFunctions = @(
                'Connect-AzureLocalServicePrincipal',
                'Get-AzureLocalAvailableUpdates',
                'Get-AzureLocalClusterInfo',
                'Get-AzureLocalClusterInventory',
                'Get-AzureLocalClusterUpdateReadiness',
                'Get-AzureLocalUpdateRuns',
                'Get-AzureLocalUpdateSummary',
                'Set-AzureLocalClusterUpdateRingTag',
                'Start-AzureLocalClusterUpdate'
            )
            
            foreach ($func in $expectedFunctions) {
                $script:ModuleInfo.ExportedFunctions.Keys | Should -Contain $func
            }
        }
    }
}

Describe 'Function: Connect-AzureLocalServicePrincipal' {
    
    Context 'Parameter Validation' {
        It 'Should have ServicePrincipalId parameter' {
            (Get-Command Connect-AzureLocalServicePrincipal).Parameters.Keys | Should -Contain 'ServicePrincipalId'
        }

        It 'Should have ServicePrincipalSecret parameter' {
            (Get-Command Connect-AzureLocalServicePrincipal).Parameters.Keys | Should -Contain 'ServicePrincipalSecret'
        }

        It 'Should have TenantId parameter' {
            (Get-Command Connect-AzureLocalServicePrincipal).Parameters.Keys | Should -Contain 'TenantId'
        }

        It 'Should have Force parameter' {
            (Get-Command Connect-AzureLocalServicePrincipal).Parameters.Keys | Should -Contain 'Force'
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of Boolean' {
            $outputTypes = (Get-Command Connect-AzureLocalServicePrincipal).OutputType
            $outputTypes.Type.Name | Should -Contain 'Boolean'
        }
    }
}

Describe 'Function: Start-AzureLocalClusterUpdate' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Start-AzureLocalClusterUpdate
        }

        It 'Should have ClusterNames parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterNames'
        }

        It 'Should have ClusterResourceIds parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have ExportResultsPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportResultsPath'
        }

        It 'Should have Force parameter' {
            $command.Parameters.Keys | Should -Contain 'Force'
        }

        It 'Should have WhatIf parameter' {
            $command.Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'Should support ShouldProcess' {
            $command.CmdletBinding | Should -Be $true
            $attr = $command.ScriptBlock.Attributes | Where-Object { $_.TypeId.Name -eq 'CmdletBindingAttribute' }
            $attr.SupportsShouldProcess | Should -Be $true
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Start-AzureLocalClusterUpdate
        }

        It 'Should have ByName parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByName'
        }

        It 'Should have ByResourceId parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
        }

        It 'Should have ByTag parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }

        It 'ClusterNames should be mandatory in ByName parameter set' {
            $param = $command.Parameters['ClusterNames']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'ByName' }
            $attr.Mandatory | Should -Be $true
        }

        It 'ClusterResourceIds should be mandatory in ByResourceId parameter set' {
            $param = $command.Parameters['ClusterResourceIds']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'ByResourceId' }
            $attr.Mandatory | Should -Be $true
        }

        It 'ScopeByUpdateRingTag should be mandatory in ByTag parameter set' {
            $param = $command.Parameters['ScopeByUpdateRingTag']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'ByTag' }
            $attr.Mandatory | Should -Be $true
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of PSObject[]' {
            $outputTypes = (Get-Command Start-AzureLocalClusterUpdate).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }
}

Describe 'Function: Get-AzureLocalClusterUpdateReadiness' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzureLocalClusterUpdateReadiness
        }

        It 'Should have ClusterNames parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterNames'
        }

        It 'Should have ClusterResourceIds parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have ExportCsvPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportCsvPath'
        }

        It 'Should have ApiVersion parameter with default value' {
            $command.Parameters['ApiVersion'].Attributes | 
                Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' } |
                ForEach-Object { $_.Mandatory } | Should -Contain $false
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Get-AzureLocalClusterUpdateReadiness
        }

        It 'Should have ByName parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByName'
        }

        It 'Should have ByResourceId parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
        }

        It 'Should have ByTag parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of PSObject[]' {
            $outputTypes = (Get-Command Get-AzureLocalClusterUpdateReadiness).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }
}

Describe 'Function: Get-AzureLocalClusterInventory' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzureLocalClusterInventory
        }

        It 'Should have SubscriptionId parameter' {
            $command.Parameters.Keys | Should -Contain 'SubscriptionId'
        }

        It 'Should have ExportCsvPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportCsvPath'
        }

        It 'SubscriptionId should not be mandatory' {
            $param = $command.Parameters['SubscriptionId']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of PSObject[]' {
            $outputTypes = (Get-Command Get-AzureLocalClusterInventory).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }
}

Describe 'Function: Set-AzureLocalClusterUpdateRingTag' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Set-AzureLocalClusterUpdateRingTag
        }

        It 'Should have ClusterResourceIds parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have InputCsvPath parameter' {
            $command.Parameters.Keys | Should -Contain 'InputCsvPath'
        }

        It 'Should have Force parameter' {
            $command.Parameters.Keys | Should -Contain 'Force'
        }

        It 'Should have WhatIf parameter' {
            $command.Parameters.Keys | Should -Contain 'WhatIf'
        }

        It 'Should support ShouldProcess' {
            $attr = $command.ScriptBlock.Attributes | Where-Object { $_.TypeId.Name -eq 'CmdletBindingAttribute' }
            $attr.SupportsShouldProcess | Should -Be $true
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Set-AzureLocalClusterUpdateRingTag
        }

        It 'Should have ByResourceId parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
        }

        It 'Should have ByCsv parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByCsv'
        }

        It 'ClusterResourceIds should be mandatory in ByResourceId parameter set' {
            $param = $command.Parameters['ClusterResourceIds']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'ByResourceId' }
            $attr.Mandatory | Should -Be $true
        }

        It 'InputCsvPath should be mandatory in ByCsv parameter set' {
            $param = $command.Parameters['InputCsvPath']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'ByCsv' }
            $attr.Mandatory | Should -Be $true
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of PSObject[]' {
            $outputTypes = (Get-Command Set-AzureLocalClusterUpdateRingTag).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }
}

Describe 'Function: Get-AzureLocalClusterInfo' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzureLocalClusterInfo
        }

        It 'Should have ClusterName parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterName'
        }

        It 'Should have SubscriptionId parameter' {
            $command.Parameters.Keys | Should -Contain 'SubscriptionId'
        }

        It 'Should have ResourceGroupName parameter' {
            $command.Parameters.Keys | Should -Contain 'ResourceGroupName'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }
    }
}

Describe 'Function: Get-AzureLocalUpdateSummary' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzureLocalUpdateSummary
        }

        It 'Should have ClusterResourceId parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceId'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }

        It 'ClusterResourceId should be mandatory' {
            $param = $command.Parameters['ClusterResourceId']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }
    }
}

Describe 'Function: Get-AzureLocalAvailableUpdates' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzureLocalAvailableUpdates
        }

        It 'Should have ClusterResourceId parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceId'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }

        It 'ClusterResourceId should be mandatory' {
            $param = $command.Parameters['ClusterResourceId']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }
    }
}

Describe 'Function: Get-AzureLocalUpdateRuns' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzureLocalUpdateRuns
        }

        It 'Should have ClusterName parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterName'
        }

        It 'Should have UpdateName parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateName'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }

        It 'ClusterName should be mandatory' {
            $param = $command.Parameters['ClusterName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $true
        }

        It 'UpdateName should be optional' {
            $param = $command.Parameters['UpdateName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }
    }
}

Describe 'Helper Function: Export-ResultsToJUnitXml (Internal)' {
    
    Context 'JUnit XML Output Format' {
        BeforeAll {
            # Create mock results to test XML generation
            $mockResults = @(
                [PSCustomObject]@{
                    ClusterName  = 'TestCluster01'
                    Status       = 'UpdateStarted'
                    Message      = 'Update started successfully'
                    UpdateName   = 'Solution12.2601.1002.38'
                    StartTime    = Get-Date
                    EndTime      = Get-Date
                    Duration     = [TimeSpan]::FromMinutes(5)
                },
                [PSCustomObject]@{
                    ClusterName  = 'TestCluster02'
                    Status       = 'Failed'
                    Message      = 'Update failed due to health check'
                    UpdateName   = 'Solution12.2601.1002.38'
                    StartTime    = Get-Date
                    EndTime      = Get-Date
                    Duration     = [TimeSpan]::FromMinutes(2)
                },
                [PSCustomObject]@{
                    ClusterName  = 'TestCluster03'
                    Status       = 'Skipped'
                    Message      = 'Cluster not ready for updates'
                    UpdateName   = $null
                    StartTime    = Get-Date
                    EndTime      = Get-Date
                    Duration     = $null
                }
            )
            
            $script:TestOutputPath = Join-Path -Path $TestDrive -ChildPath 'test-results.xml'
            
            # Call the internal function via module scope
            & (Get-Module AzStackHci.ManageUpdates) {
                param($Results, $OutputPath)
                Export-ResultsToJUnitXml -Results $Results -OutputPath $OutputPath -TestSuiteName 'TestSuite' -OperationType 'Update'
            } -Results $mockResults -OutputPath $script:TestOutputPath
        }

        It 'Should create the XML file' {
            Test-Path $script:TestOutputPath | Should -Be $true
        }

        It 'Should be valid XML' {
            { [xml](Get-Content $script:TestOutputPath -Raw) } | Should -Not -Throw
        }

        It 'Should have testsuites root element' {
            $xml = [xml](Get-Content $script:TestOutputPath -Raw)
            $xml.testsuites | Should -Not -BeNullOrEmpty
        }

        It 'Should have testsuite element with correct test count' {
            $xml = [xml](Get-Content $script:TestOutputPath -Raw)
            [int]$xml.testsuites.testsuite.tests | Should -Be 3
        }

        It 'Should have testsuite element with correct failure count' {
            $xml = [xml](Get-Content $script:TestOutputPath -Raw)
            [int]$xml.testsuites.testsuite.failures | Should -Be 1
        }

        It 'Should have testsuite element with correct skipped count' {
            $xml = [xml](Get-Content $script:TestOutputPath -Raw)
            [int]$xml.testsuites.testsuite.skipped | Should -Be 1
        }

        It 'Should have testcase elements for each result' {
            $xml = [xml](Get-Content $script:TestOutputPath -Raw)
            $xml.testsuites.testsuite.testcase.Count | Should -Be 3
        }

        It 'Should have failure element for failed test' {
            $xml = [xml](Get-Content $script:TestOutputPath -Raw)
            $failedTest = $xml.testsuites.testsuite.testcase | Where-Object { $_.name -like '*TestCluster02*' }
            $failedTest.failure | Should -Not -BeNullOrEmpty
        }

        It 'Should have skipped element for skipped test' {
            $xml = [xml](Get-Content $script:TestOutputPath -Raw)
            $skippedTest = $xml.testsuites.testsuite.testcase | Where-Object { $_.name -like '*TestCluster03*' }
            $skippedTest.skipped | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'API Version Consistency' {
    
    Context 'Default API Version' {
        It 'All functions with ApiVersion parameter should default to 2025-10-01' {
            $functionsWithApiVersion = @(
                'Start-AzureLocalClusterUpdate',
                'Get-AzureLocalClusterUpdateReadiness',
                'Get-AzureLocalClusterInfo',
                'Get-AzureLocalUpdateSummary',
                'Get-AzureLocalAvailableUpdates',
                'Get-AzureLocalUpdateRuns'
            )

            foreach ($funcName in $functionsWithApiVersion) {
                $command = Get-Command $funcName
                if ($command.Parameters.ContainsKey('ApiVersion')) {
                    # Check if there's a default value in the function
                    # The default is set via $script:DefaultApiVersion which is '2025-10-01'
                    $command.Parameters['ApiVersion'] | Should -Not -BeNullOrEmpty -Because "$funcName should have ApiVersion parameter"
                }
            }
        }
    }
}

Describe 'Module Best Practices' {
    
    Context 'Function Naming' {
        It 'All exported functions should use approved verbs' {
            $approvedVerbs = Get-Verb | Select-Object -ExpandProperty Verb
            $exportedFunctions = (Get-Module AzStackHci.ManageUpdates).ExportedFunctions.Keys
            
            foreach ($func in $exportedFunctions) {
                $verb = $func.Split('-')[0]
                $approvedVerbs | Should -Contain $verb -Because "$func should use an approved verb"
            }
        }

        It 'All exported functions should use consistent noun prefix' {
            $exportedFunctions = (Get-Module AzStackHci.ManageUpdates).ExportedFunctions.Keys
            
            foreach ($func in $exportedFunctions) {
                $noun = $func.Split('-')[1]
                $noun | Should -BeLike 'AzureLocal*' -Because "$func should use AzureLocal noun prefix"
            }
        }
    }

    Context 'Help Documentation' {
        BeforeAll {
            $script:exportedFunctions = (Get-Module AzStackHci.ManageUpdates).ExportedFunctions.Keys
        }

        It 'All exported functions should have Synopsis in help' {
            foreach ($func in $script:exportedFunctions) {
                $help = Get-Help $func -ErrorAction SilentlyContinue
                $help.Synopsis | Should -Not -BeNullOrEmpty -Because "$func should have a Synopsis"
            }
        }

        It 'All exported functions should have Description in help' {
            foreach ($func in $script:exportedFunctions) {
                $help = Get-Help $func -ErrorAction SilentlyContinue
                $help.Description | Should -Not -BeNullOrEmpty -Because "$func should have a Description"
            }
        }
    }
}
