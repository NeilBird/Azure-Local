#Requires -Module Pester

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop
}

AfterAll {
    Remove-Module AzLocal.UpdateManagement -Force -ErrorAction SilentlyContinue
}

Describe 'v0.9.29 Export-AzLocalClusterInventoryDriftReport' {
    BeforeEach {
        $script:driftOutputDirectory = Join-Path $env:TEMP "cluster-drift-$([guid]::NewGuid())"
        $script:driftSummaryName = "cluster-drift-summary-$([guid]::NewGuid()).md"
        $script:driftSummaryPath = Join-Path $env:TEMP $script:driftSummaryName
        New-Item -ItemType Directory -Path $script:driftOutputDirectory -Force | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:driftOutputDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:driftSummaryPath -Force -ErrorAction SilentlyContinue
    }

    It 'classifies live-only, source-only, managed-tag drift, and matching clusters' {
        $sourcePath = Join-Path $script:driftOutputDirectory 'ClusterUpdateRings.csv'
        @(
            [pscustomobject]@{ ClusterName = 'alpha'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/alpha'; UpdateRing = 'Canary'; UpdateStartWindow = 'Sat_22:00-02:00'; UpdateExclusionsWindow = ''; UpdateExcluded = 'False' }
            [pscustomobject]@{ ClusterName = 'charlie'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/charlie'; UpdateRing = 'Prod'; UpdateStartWindow = ''; UpdateExclusionsWindow = ''; UpdateExcluded = 'False' }
            [pscustomobject]@{ ClusterName = 'delta'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/delta'; UpdateRing = 'Prod'; UpdateStartWindow = ''; UpdateExclusionsWindow = ''; UpdateExcluded = 'False' }
        ) | Export-Csv -LiteralPath $sourcePath -NoTypeInformation -Encoding UTF8

        $live = @(
            [pscustomobject]@{ ClusterName = 'alpha'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/alpha'; UpdateRing = 'Pilot'; UpdateStartWindow = 'Sat_22:00-02:00'; UpdateExclusionsWindow = ''; UpdateExcluded = 'False' }
            [pscustomobject]@{ ClusterName = 'bravo'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/bravo'; UpdateRing = ''; UpdateStartWindow = ''; UpdateExclusionsWindow = ''; UpdateExcluded = '' }
            [pscustomobject]@{ ClusterName = 'delta'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/delta'; UpdateRing = 'Prod'; UpdateStartWindow = ''; UpdateExclusionsWindow = ''; UpdateExcluded = 'False' }
        )

        $result = Export-AzLocalClusterInventoryDriftReport -LiveInventory $live -SourceCsvPath $sourcePath -OutputDirectory $script:driftOutputDirectory -SummaryFileName $script:driftSummaryName -Timestamp ([datetime]'2026-07-30T12:00:00Z') -PassThru 3>$null

        $result.Status | Should -Be 'Drift'
        $result.LiveClusterCount | Should -Be 3
        $result.SourceClusterCount | Should -Be 3
        $result.MatchingClusterCount | Should -Be 1
        $result.LiveOnlyCount | Should -Be 1
        $result.SourceOnlyCount | Should -Be 1
        $result.TagMismatchClusterCount | Should -Be 1
        $result.FieldDiscrepancyCount | Should -Be 1
        @($result.Rows).Count | Should -Be 3
        @($result.Rows | Where-Object Status -eq 'TagMismatch')[0].Field | Should -Be 'UpdateRing'
        Test-Path -LiteralPath $result.CsvPath | Should -BeTrue
        Test-Path -LiteralPath $result.JsonPath | Should -BeTrue
        Test-Path -LiteralPath $result.XmlPath | Should -BeTrue
        $junit = [xml](Get-Content -LiteralPath $result.XmlPath -Raw)
        ($junit.testsuites.testsuite | Measure-Object -Property failures -Sum).Sum | Should -Be 2
        $summary = Get-Content -LiteralPath $script:driftSummaryPath -Raw
        $summary | Should -Match 'Status: DRIFT'
        $summary | Should -Match 'New live clusters missing from source control \| 1'
        $summary | Should -Match 'Clusters with managed-tag drift \| 1'
    }

    It 'reports a missing source CSV as a successful onboarding state' {
        $missingPath = Join-Path $script:driftOutputDirectory 'missing.csv'
        $live = @(
            [pscustomobject]@{ ClusterName = 'alpha'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/alpha'; UpdateRing = '' }
        )

        $result = Export-AzLocalClusterInventoryDriftReport -LiveInventory $live -SourceCsvPath $missingPath -OutputDirectory $script:driftOutputDirectory -SummaryFileName $script:driftSummaryName -PassThru

        $result.Status | Should -Be 'NotConfigured'
        $result.DriftCount | Should -Be 0
        Test-Path -LiteralPath $result.CsvPath | Should -BeTrue
        $junit = [xml](Get-Content -LiteralPath $result.XmlPath -Raw)
        ($junit.testsuites.testsuite | Measure-Object -Property skipped -Sum).Sum | Should -Be 2
        (Get-Content -LiteralPath $script:driftSummaryPath -Raw) | Should -Match 'Status: NOT CONFIGURED'
    }

    It 'reports clean state when membership and managed tags match' {
        $sourcePath = Join-Path $script:driftOutputDirectory 'ClusterUpdateRings.csv'
        $source = [pscustomobject]@{ ClusterName = 'alpha'; ResourceId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/alpha'; UpdateRing = 'Canary' }
        @($source) | Export-Csv -LiteralPath $sourcePath -NoTypeInformation -Encoding UTF8

        $result = Export-AzLocalClusterInventoryDriftReport -LiveInventory @($source) -SourceCsvPath $sourcePath -OutputDirectory $script:driftOutputDirectory -SummaryFileName $script:driftSummaryName -PassThru

        $result.Status | Should -Be 'Clean'
        $result.MatchingClusterCount | Should -Be 1
        $result.DriftCount | Should -Be 0
        $junit = [xml](Get-Content -LiteralPath $result.XmlPath -Raw)
        ($junit.testsuites.testsuite | Measure-Object -Property failures -Sum).Sum | Should -Be 0
    }
}

Describe 'v0.9.29 Config: 1 weekly inventory drift pipeline wiring' {
    BeforeAll {
        $pipelineRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\Automation-Pipeline-Examples'
        $githubYaml = Get-Content -LiteralPath (Join-Path $pipelineRoot 'github-actions\setup-validate-and-inventory.yml') -Raw
        $adoYaml = Get-Content -LiteralPath (Join-Path $pipelineRoot 'azure-devops\setup-validate-and-inventory.yml') -Raw
    }

    It 'keeps the weekly Sunday 08:17 UTC schedule on both platforms' {
        $githubYaml | Should -Match "cron:\s*'17 8 \* \* 0'"
        $adoYaml | Should -Match "cron:\s*'17 8 \* \* 0'"
    }

    It 'compares generated live inventory with config/ClusterUpdateRings.csv on both platforms' {
        $githubYaml | Should -Match "Import-Csv -LiteralPath './artifacts/ClusterUpdateRings\.csv'"
        $githubYaml | Should -Match "Export-AzLocalClusterInventoryDriftReport"
        $githubYaml | Should -Match "-SourceCsvPath\s+'\./config/ClusterUpdateRings\.csv'"
        $adoYaml | Should -Match "Import-Csv -LiteralPath '\$\(Build\.ArtifactStagingDirectory\)/ClusterUpdateRings\.csv'"
        $adoYaml | Should -Match "Export-AzLocalClusterInventoryDriftReport"
        $adoYaml | Should -Match "-SourceCsvPath\s+'\$\(Build\.SourcesDirectory\)/config/ClusterUpdateRings\.csv'"
    }

    It 'publishes drift JUnit without failing the pipeline on detected drift' {
        $githubYaml | Should -Match 'path:\s*\./artifacts/cluster-inventory-drift\.xml'
        $githubYaml | Should -Match 'fail-on-error:\s*false'
        $adoYaml | Should -Match "testResultsFiles:\s*'\$\(Build\.ArtifactStagingDirectory\)/cluster-inventory-drift\.xml'"
        $adoYaml | Should -Match 'failTaskOnFailedTests:\s*false'
        $githubYaml | Should -Match '\./artifacts/\*\.xml'
    }
}