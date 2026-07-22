#Requires -Module Pester

Describe 'Sideload self-hosted workflow prerequisites' -Tag 'ReleaseGate' {
    BeforeAll {
        $examplesRoot = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples'
        $script:WorkflowPaths = @(
            Join-Path $examplesRoot 'github-actions\sideload-updates.yml'
            Join-Path $examplesRoot 'azure-devops\sideload-updates.yml'
        )
    }

    It 'installs every PowerShell module used by the self-hosted sideload job' -ForEach @(
        @{ Platform = 'GitHub Actions'; Index = 0 }
        @{ Platform = 'Azure DevOps'; Index = 1 }
    ) {
        $workflow = Get-Content -LiteralPath $script:WorkflowPaths[$Index] -Raw

        $workflow | Should -Match 'Install-Module Az\.Accounts -Scope CurrentUser -Force -AllowClobber'
        $workflow | Should -Match 'Install-Module Az\.KeyVault -Scope CurrentUser -Force -AllowClobber'
        $workflow | Should -Match 'Install-Module powershell-yaml -Scope CurrentUser -Force -AllowClobber'
        $workflow | Should -Match 'Install-Module @installArgs'
    }

    It 'installs Az.Accounts before GitHub Azure Login enables an Az PowerShell session' {
        $workflow = Get-Content -LiteralPath $script:WorkflowPaths[0] -Raw
        $accountsInstallIndex = $workflow.IndexOf('Install-Module Az.Accounts')
        $azureLoginIndex = $workflow.IndexOf('uses: azure/login@v3')

        $accountsInstallIndex | Should -BeGreaterThan -1
        $azureLoginIndex | Should -BeGreaterThan $accountsInstallIndex
    }

    It 'serializes GitHub runs and batches the Azure DevOps schedule' {
        $githubWorkflow = Get-Content -LiteralPath $script:WorkflowPaths[0] -Raw
        $adoWorkflow = Get-Content -LiteralPath $script:WorkflowPaths[1] -Raw

        $githubWorkflow | Should -Match '(?m)^concurrency:\r?$'
        $githubWorkflow | Should -Match ([regex]::Escape('group: sideload-updates-${{ github.workflow }}'))
        $githubWorkflow | Should -Match '(?m)^\s+cancel-in-progress: false\r?$'
        $adoWorkflow | Should -Match "(?m)^#\s+batch: true\s+# never overlap scheduled reconciliation runs\r?$"
    }

    It 'documents runner affinity, centralized logs, HA boundaries, and 100-cluster sizing' {
        $guidePath = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples\docs\sideload.md'
        $guide = Get-Content -LiteralPath $guidePath -Raw

        $guide | Should -Match 'Scaling considerations for the self-hosted runner pool'
        $guide | Should -Match '100 due clusters'
        $guide | Should -Match 'Runner-local task affinity and failover'
        $guide | Should -Match 'active/passive runner pool'
        $guide | Should -Match 'logs\\\*\.robocopy\.log'
        $guide | Should -Match 'does \*\*not\*\* automatically purge'
    }
}