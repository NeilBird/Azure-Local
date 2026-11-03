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

    It 'uses an automation key without prompting and preserves caller ownership' {
        Mock Read-Host { throw 'Automation must not prompt.' }
        Mock Publish-Module { }
        Mock Invoke-RestMethod { }
        $automationKey = ConvertTo-SecureString 'test-automation-key' -AsPlainText -Force
        try {
            & (Join-Path $script:ModuleRoot 'Publish-Module.ps1') -NuGetApiKey $automationKey -Confirm:$false *> $null

            Should -Invoke Read-Host -Times 0 -Exactly
            Should -Invoke Publish-Module -Times 1 -Exactly -ParameterFilter {
                $Repository -eq 'PSGallery' -and $NuGetApiKey -eq 'test-automation-key'
            }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Delete' }
            $automationKey.Length | Should -Be 19
        }
        finally {
            $automationKey.Dispose()
        }
    }

    It 'rejects an empty automation key without prompting or publishing' {
        Mock Read-Host { throw 'Automation must not prompt.' }
        Mock Publish-Module { }
        $automationKey = [System.Security.SecureString]::new()
        try {
            { & (Join-Path $script:ModuleRoot 'Publish-Module.ps1') -NuGetApiKey $automationKey -Confirm:$false *> $null } |
                Should -Throw -ExpectedMessage '*API key cannot be empty*'
            Should -Invoke Read-Host -Times 0 -Exactly
            Should -Invoke Publish-Module -Times 0 -Exactly
        }
        finally {
            $automationKey.Dispose()
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
            Should -Match '(?m)^# schemaVersion: 6\r?$'
    }

    It 'excludes repository-only publishing and test content' {
        Join-Path $script:StagingDir 'Publish-Module.ps1' | Should -Not -Exist
        Join-Path $script:StagingDir 'Tests' | Should -Not -Exist
        Join-Path $script:StagingDir 'CHANGELOG.md' | Should -Not -Exist
    }
}

Describe 'Manual Gallery publishing workflow' -Tag 'ReleaseGate' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:RepositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $workflowPath = Join-Path $script:RepositoryRoot '.github/workflows/AzLocal.UpdateManagement-publish.yml'
        $script:PublishWorkflow = ConvertFrom-Yaml (Get-Content -LiteralPath $workflowPath -Raw)
        $script:StageStep = $script:PublishWorkflow.jobs.package.steps | Where-Object { $_.id -eq 'package' }
    }

    It 'only permits manual main-branch runs in the source repository with read-only permissions' {
        @($script:PublishWorkflow.on.Keys) | Should -Be @('workflow_dispatch')
        @($script:PublishWorkflow.permissions.Keys) | Should -Be @('contents')
        $script:PublishWorkflow.permissions.contents | Should -Be 'read'
        foreach ($job in $script:PublishWorkflow.jobs.Values) {
            $job.if | Should -Match "github.repository == 'NeilBird/Azure-Local'"
            $job.if | Should -Match "github.ref == 'refs/heads/main'"
            $job.'timeout-minutes' | Should -Be 10
        }
        $script:PublishWorkflow.concurrency.'cancel-in-progress' | Should -BeFalse
    }

    It 'defaults to stage-only and unlisted without accepting a secret input' {
        $inputs = $script:PublishWorkflow.on.workflow_dispatch.inputs
        @($inputs.Keys | Sort-Object) | Should -Be @('expected_version', 'listing', 'operation')
        $inputs.operation.type | Should -Be 'choice'
        $inputs.operation.default | Should -Be 'Stage only'
        $inputs.listing.type | Should -Be 'choice'
        $inputs.listing.default | Should -Be 'Unlisted'
        $inputs.expected_version.required | Should -BeTrue
        $script:PublishWorkflow.jobs.package.Contains('environment') | Should -BeFalse
    }

    It 'pins actions and checks out the same immutable commit without persisting credentials' {
        foreach ($job in $script:PublishWorkflow.jobs.Values) {
            foreach ($step in $job.steps) {
                if ($step.Contains('uses')) {
                    $step.uses | Should -Match '@[a-f0-9]{40}$'
                }
                if ($step.uses -like 'actions/checkout@*') {
                    $step.with.ref | Should -BeExactly '${{ github.sha }}'
                    $step.with.'persist-credentials' | Should -BeFalse
                }
            }
        }
    }

    It 'requires package success and environment scoping before exposing the key only to the publish step' {
        $publish = $script:PublishWorkflow.jobs.publish
        $publish.needs | Should -Be 'package'
        $publish.environment | Should -Be 'psgallery'
        $publish.if | Should -Match "inputs.operation == 'Publish'"
        $secretSteps = @($script:PublishWorkflow.jobs.Values.steps | Where-Object {
            $_.Contains('env') -and $_.env.Contains('PSGALLERY_API_KEY')
        })
        $secretSteps.Count | Should -Be 1
        $secretSteps[0].env.PSGALLERY_API_KEY | Should -BeExactly '${{ secrets.PSGALLERY_API_KEY }}'
        $secretSteps[0].run | Should -Match 'finally'
        $secretSteps[0].run | Should -Match 'Remove-Item Env:PSGALLERY_API_KEY'
        $secretSteps[0].run | Should -Match '-NuGetApiKey \$secureKey'
    }

    It 'never interpolates dispatch inputs or secrets directly into executable scripts' {
        foreach ($job in $script:PublishWorkflow.jobs.Values) {
            foreach ($step in $job.steps) {
                if ($step.Contains('run')) {
                    $step.run | Should -Not -Match '\$\{\{'
                }
            }
        }
    }

    It 'handles <Scenario> without leaving the key in the process environment' -TestCases @(
        @{ Scenario = 'missing secret'; Key = ''; Listing = 'Unlisted'; Failure = '*Configure PSGALLERY_API_KEY*'; PublishCount = 0; UnlistCount = 0; FailPublish = $false }
        @{ Scenario = 'unlisted publishing'; Key = 'test-workflow-key'; Listing = 'Unlisted'; Failure = ''; PublishCount = 1; UnlistCount = 1; FailPublish = $false }
        @{ Scenario = 'listed publishing'; Key = 'test-workflow-key'; Listing = 'Listed'; Failure = ''; PublishCount = 1; UnlistCount = 0; FailPublish = $false }
        @{ Scenario = 'publish failure'; Key = 'test-workflow-key'; Listing = 'Unlisted'; Failure = '*simulated publish failure*'; PublishCount = 1; UnlistCount = 0; FailPublish = $true }
    ) {
        param($Scenario, $Key, $Listing, $Failure, $PublishCount, $UnlistCount, $FailPublish)

        $publishStep = $script:PublishWorkflow.jobs.publish.steps | Where-Object {
            $_.Contains('env') -and $_.env.Contains('PSGALLERY_API_KEY')
        }
        $names = @('GITHUB_WORKSPACE', 'GITHUB_STEP_SUMMARY', 'PSGALLERY_API_KEY', 'RELEASE_LISTING')
        $savedEnvironment = @{}
        foreach ($name in $names) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
        Mock Publish-Module { }
        Mock Invoke-RestMethod { }
        Mock Read-Host { throw 'Workflow must not prompt.' }
        if ($FailPublish) { Mock Publish-Module { throw 'simulated publish failure' } }
        try {
            $env:GITHUB_WORKSPACE = $script:RepositoryRoot
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'publish-summary.md'
            $env:PSGALLERY_API_KEY = $Key
            $env:RELEASE_LISTING = $Listing
            if ($Failure) {
                { & ([scriptblock]::Create($publishStep.run)) *> $null } | Should -Throw -ExpectedMessage $Failure
            }
            else {
                & ([scriptblock]::Create($publishStep.run)) *> $null
            }
            [Environment]::GetEnvironmentVariable('PSGALLERY_API_KEY') | Should -BeNullOrEmpty
            Should -Invoke Publish-Module -Times $PublishCount -Exactly
            Should -Invoke Invoke-RestMethod -Times $UnlistCount -Exactly
            Should -Invoke Read-Host -Times 0 -Exactly
        }
        finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
        }
    }

    It 'uploads only the staged module tree as a downloadable artifact' {
        $upload = $script:PublishWorkflow.jobs.package.steps | Where-Object { $_.uses -like 'actions/upload-artifact@*' }
        $upload.with.path | Should -BeExactly '${{ runner.temp }}/azlocal-package/'
        $upload.with.'if-no-files-found' | Should -Be 'error'
        $upload.with.'include-hidden-files' | Should -BeFalse
        $upload.with.'retention-days' | Should -Be 7
    }

    It 'builds an importable versioned download without invoking Gallery publishing' {
        $names = @('GITHUB_WORKSPACE', 'RUNNER_TEMP', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'GITHUB_SHA', 'EXPECTED_VERSION', 'RELEASE_OPERATION', 'RELEASE_LISTING')
        $savedEnvironment = @{}
        foreach ($name in $names) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
        Mock Publish-Module { throw 'Stage only must never publish.' }
        try {
            $env:GITHUB_WORKSPACE = $script:RepositoryRoot
            $env:RUNNER_TEMP = $TestDrive
            $env:GITHUB_OUTPUT = Join-Path $TestDrive 'outputs.txt'
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive 'summary.md'
            $env:GITHUB_SHA = '0123456789012345678901234567890123456789'
            $manifestPath = Join-Path $script:RepositoryRoot 'AzLocal.UpdateManagement/AzLocal.UpdateManagement.psd1'
            $env:EXPECTED_VERSION = [string](Import-PowerShellDataFile $manifestPath).ModuleVersion
            $env:RELEASE_OPERATION = 'Stage only'
            $env:RELEASE_LISTING = 'Unlisted'
            & ([scriptblock]::Create($script:StageStep.run)) *> $null
            $packageRoot = Join-Path $TestDrive 'azlocal-package'
            $downloadManifest = Join-Path $packageRoot "AzLocal.UpdateManagement/$env:EXPECTED_VERSION/AzLocal.UpdateManagement.psd1"
            (Test-ModuleManifest $downloadManifest -ErrorAction Stop).Version.ToString() | Should -Be $env:EXPECTED_VERSION
            $sourceFiles = @(Get-ChildItem 'C:/Temp/AzLocal.UpdateManagement' -Recurse -File)
            $downloadFiles = @(Get-ChildItem $packageRoot -Recurse -File)
            $downloadFiles.Count | Should -Be $sourceFiles.Count
            foreach ($file in $sourceFiles) {
                $relativePath = $file.FullName.Substring('C:\Temp\AzLocal.UpdateManagement\'.Length)
                $downloadFile = Join-Path (Split-Path $downloadManifest -Parent) $relativePath
                (Get-FileHash $downloadFile).Hash | Should -Be (Get-FileHash $file.FullName).Hash
            }
            Get-Content $env:GITHUB_OUTPUT -Raw | Should -Match "version=$([regex]::Escape($env:EXPECTED_VERSION))"
            Should -Invoke Publish-Module -Times 0 -Exactly
            $env:EXPECTED_VERSION = '0.0.0'
            { & ([scriptblock]::Create($script:StageStep.run)) *> $null } | Should -Throw '*does not match expected version*'
        }
        finally {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
        }
    }
}