#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Publish-Module package allow-list' -Tag 'ReleaseGate' {
    BeforeAll {
        $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
        $publishScriptPath = Join-Path $moduleRoot 'Publish-Module.ps1'
        $script:PublishScriptContent = Get-Content -LiteralPath $publishScriptPath -Raw
        $script:ModuleRoot = $moduleRoot
        $script:StagingDir = 'C:\Temp\AzLocal.UpdateManagement'

        & $publishScriptPath -StageOnly *> $null
        $script:StagedManifest = Test-ModuleManifest -Path (Join-Path $script:StagingDir 'AzLocal.UpdateManagement.psd1') -ErrorAction Stop
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

    It 'publishes before automatically unlisting the exact package version' {
        $publishIndex = $script:PublishScriptContent.IndexOf('Publish-Module -Path $StagingDir')
        $unlistIndex = $script:PublishScriptContent.IndexOf('Invoke-RestMethod -Uri $unlistUri -Method Delete')

        $publishIndex | Should -BeGreaterThan -1
        $unlistIndex | Should -BeGreaterThan $publishIndex
        $script:PublishScriptContent | Should -Match 'api/v2/package/\$escapedModuleName/\$escapedVersion'
        $script:PublishScriptContent | Should -Match "'X-NuGet-ApiKey'\s*=\s*\`$apiKey"
    }

    It 'supports an explicit -List switch that bypasses automatic unlisting' {
        $command = Get-Command (Join-Path $script:ModuleRoot 'Publish-Module.ps1')

        $command.Parameters.ContainsKey('List') | Should -BeTrue
        $command.Parameters['List'].ParameterType | Should -Be ([switch])
        $script:PublishScriptContent | Should -Match 'if \(\$List\.IsPresent\)'
        $script:PublishScriptContent | Should -Match 'Version remains listed because -List was specified'
        $script:PublishScriptContent | Should -Match 'Publish to PowerShell Gallery and leave listed'
    }

    It 'publishes and unlists once by default without exposing the API key' {
        Mock Read-Host { ConvertTo-SecureString 'test-api-key' -AsPlainText -Force }
        Mock Publish-Module { }
        Mock Invoke-RestMethod { }

        & (Join-Path $script:ModuleRoot 'Publish-Module.ps1') -Confirm:$false *> $null

        Should -Invoke Publish-Module -Times 1 -Exactly -ParameterFilter {
            $Repository -eq 'PSGallery' -and $NuGetApiKey -eq 'test-api-key'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'Delete' -and
            $Uri -eq "https://www.powershellgallery.com/api/v2/package/AzLocal.UpdateManagement/$($script:StagedManifest.Version)" -and
            $Headers['X-NuGet-ApiKey'] -eq 'test-api-key'
        }
    }

    It 'publishes without unlisting when -List is specified' {
        Mock Read-Host { ConvertTo-SecureString 'test-api-key' -AsPlainText -Force }
        Mock Publish-Module { }
        Mock Invoke-RestMethod { }

        & (Join-Path $script:ModuleRoot 'Publish-Module.ps1') -List -Confirm:$false *> $null

        Should -Invoke Publish-Module -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'does not prompt for an API key or publish under -WhatIf' {
        Mock Read-Host { throw 'Read-Host must not be called under WhatIf' }
        Mock Publish-Module { }
        Mock Invoke-RestMethod { }

        { & (Join-Path $script:ModuleRoot 'Publish-Module.ps1') -WhatIf *> $null } | Should -Not -Throw

        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Publish-Module -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'throws an actionable error when publish succeeds but automatic unlisting fails' {
        Mock Read-Host { ConvertTo-SecureString 'test-api-key' -AsPlainText -Force }
        Mock Publish-Module { }
        Mock Invoke-RestMethod { throw 'simulated unlist failure' }

        { & (Join-Path $script:ModuleRoot 'Publish-Module.ps1') -Confirm:$false *> $null } |
            Should -Throw -ExpectedMessage '*Published AzLocal.UpdateManagement v*automatic unlisting failed*package may still be listed*simulated unlist failure*'
        Should -Invoke Publish-Module -Times 1 -Exactly
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly
    }

    It 'stages every executable file declared by the module manifest' {
        $sourceManifest = Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'AzLocal.UpdateManagement.psd1')
        $executablePaths = @([string]$sourceManifest.RootModule) + @($sourceManifest.NestedModules)

        foreach ($relativePath in $executablePaths) {
            Join-Path $script:StagingDir $relativePath | Should -Exist
        }

        $script:StagedManifest.Version | Should -Be ([version]$sourceManifest.ModuleVersion)
        @($script:StagedManifest.ExportedFunctions.Keys).Count | Should -Be @($sourceManifest.FunctionsToExport).Count
    }

    It 'copies complete bundled customer and ITSM trees byte-for-byte' -TestCases @(
        @{ RelativePath = 'Automation-Pipeline-Examples' }
        @{ RelativePath = 'ITSM' }
    ) {
        param($RelativePath)

        $sourceRoot = Join-Path $script:ModuleRoot $RelativePath
        $stagedRoot = Join-Path $script:StagingDir $RelativePath
        $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File | ForEach-Object {
            $_.FullName.Substring($sourceRoot.Length + 1)
        } | Sort-Object)
        $stagedFiles = @(Get-ChildItem -LiteralPath $stagedRoot -Recurse -File | ForEach-Object {
            $_.FullName.Substring($stagedRoot.Length + 1)
        } | Sort-Object)

        @(Compare-Object -ReferenceObject $sourceFiles -DifferenceObject $stagedFiles).Count | Should -Be 0
        foreach ($relativeFile in $sourceFiles) {
            $sourceHash = (Get-FileHash -LiteralPath (Join-Path $sourceRoot $relativeFile) -Algorithm SHA256).Hash
            $stagedHash = (Get-FileHash -LiteralPath (Join-Path $stagedRoot $relativeFile) -Algorithm SHA256).Hash
            $stagedHash | Should -BeExactly $sourceHash
        }
    }

    It 'includes required standalone runtime and customer assets' {
        $requiredPaths = @(
            'README.md'
            'example-update-request.json'
            'docs\cmdlet-reference.md'
            'docs\concepts.md'
            'docs\rbac.md'
            'docs\release-history.md'
            'docs\troubleshooting.md'
            'Tools\Invoke-AzLocalSideloadCopyTask.ps1'
        )

        foreach ($relativePath in $requiredPaths) {
            Join-Path $script:StagingDir $relativePath | Should -Exist
        }

        Get-Content -LiteralPath (Join-Path $script:StagingDir 'Automation-Pipeline-Examples\fleet-settings.example.yml') -Raw |
            Should -Match '(?m)^# schemaVersion: 4\r?$'
    }

    It 'excludes repository-only publishing and test content' {
        Join-Path $script:StagingDir 'Publish-Module.ps1' | Should -Not -Exist
        Join-Path $script:StagingDir 'Tests' | Should -Not -Exist
        Join-Path $script:StagingDir 'CHANGELOG.md' | Should -Not -Exist
    }
}