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
}