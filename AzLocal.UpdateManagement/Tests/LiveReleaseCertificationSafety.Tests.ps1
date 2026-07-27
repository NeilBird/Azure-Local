#Requires -Module Pester

Describe 'Live release certification safety' -Tag 'ReleaseGate' {
    BeforeAll {
        $scriptPath = Join-Path $PSScriptRoot '..\Tools\live-release-certification.ps1'
        $tokens = $null
        $parseErrors = $null
        $script:CertificationAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'suppresses automatic Check for Updates on every readiness report call' {
        $readinessCalls = @($script:CertificationAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst] -and
                    $node.GetCommandName() -eq 'Export-AzLocalClusterUpdateReadinessReport'
                }, $true))

        $readinessCalls | Should -HaveCount 2
        foreach ($call in $readinessCalls) {
            $call.Extent.Text | Should -Match '(?<!\w)-SkipStaleAssessmentScan(?!\w)'
        }
    }
}