#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Publish-Module package allow-list' -Tag 'ReleaseGate' {
    BeforeAll {
        $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
        $publishScriptPath = Join-Path $moduleRoot 'Publish-Module.ps1'
        $script:PublishScriptContent = Get-Content -LiteralPath $publishScriptPath -Raw
    }

    It 'derives executable module files from the manifest' {
        $script:PublishScriptContent | Should -Match 'Import-PowerShellDataFile'
        $script:PublishScriptContent | Should -Match '\$sourceManifest\.RootModule'
        $script:PublishScriptContent | Should -Match '\$sourceManifest\.NestedModules'
        $script:PublishScriptContent | Should -Not -Match "(?m)^\s*'Public'\s*$"
        $script:PublishScriptContent | Should -Not -Match "(?m)^\s*'Private'\s*$"
    }

    It 'does not recursively copy the module source root' {
        $script:PublishScriptContent | Should -Not -Match 'Copy-Item\s+-Path\s+\$SourceDir\s+-Destination\s+\$StagingDir\s+-Recurse'
    }

    It 'includes only the required detached worker from Tools' {
        $script:PublishScriptContent | Should -Match "'Tools\\Invoke-AzLocalSideloadCopyTask\.ps1'"
        $script:PublishScriptContent | Should -Not -Match "(?m)^\s*'Tools'\s*$"
    }

    It 'supports staging validation without reaching API-key handling' {
        $stageOnlyIndex = $script:PublishScriptContent.IndexOf('if ($StageOnly)')
        $apiKeyPromptIndex = $script:PublishScriptContent.IndexOf('$secureApiKey = Read-Host')

        $stageOnlyIndex | Should -BeGreaterThan -1
        $apiKeyPromptIndex | Should -BeGreaterThan $stageOnlyIndex
        $script:PublishScriptContent.Substring($stageOnlyIndex, $apiKeyPromptIndex - $stageOnlyIndex) |
            Should -Match '(?s)if \(\$StageOnly\).*?return'
    }
}