#Requires -Module Pester

Describe 'Sideload diagnostics snapshots' {
    BeforeAll {
        $collector = Join-Path $PSScriptRoot '../Tools/Export-AzLocalSideloadDiagnostics.ps1'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
    }

    It 'compresses a bounded tail while a writer remains open and records missing or rejected logs' {
        $root = Join-Path $TestDrive 'shared'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'state'), (Join-Path $root 'logs')
        $log = Join-Path $root 'logs/copy.robocopy.log'
        [IO.File]::WriteAllText($log, '0123456789')
        foreach ($name in @('alpha', 'beta', 'gamma')) {
            $path = if ($name -eq 'gamma') { Join-Path $TestDrive 'outside.robocopy.log' } else { $log }
            @{ LogPath = $path; State = 'Copying'; OperationId = 'test'; Secret = 'must-not-collect' } |
                ConvertTo-Json | Set-Content (Join-Path $root "state/$name.json")
        }
        $writer = [IO.File]::Open($log, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $zipPath = & $collector -StateRoot $root -ClusterName alpha,beta,gamma,missing -DestinationPath (Join-Path $TestDrive 'bundle.zip') -MaxLogBytes 4 -MaxTotalLogBytes 6
            $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
            try {
                $reader = [IO.StreamReader]::new($zip.GetEntry('manifest.json').Open())
                try { $json = $reader.ReadToEnd() } finally { $reader.Dispose() }
                $manifest = $json | ConvertFrom-Json
                $manifest.CapturedLogBytes | Should -Be 6
                $manifest.Records[0].Offset | Should -Be 6
                $manifest.Records[0].Truncated | Should -BeTrue
                $manifest.Records[1].CapturedBytes | Should -Be 2
                $manifest.Records[2].Status | Should -Be 'RejectedPath'
                $manifest.Records[3].Status | Should -Be 'Unavailable'
                $json | Should -Not -Match 'must-not-collect'
                $reader = [IO.StreamReader]::new($zip.GetEntry('logs/0000.robocopy.log').Open())
                try { $reader.ReadToEnd() | Should -Be '6789' } finally { $reader.Dispose() }
            }
            finally { $zip.Dispose() }
            $writer.CanWrite | Should -BeTrue
        }
        finally { $writer.Dispose() }
        [IO.File]::ReadAllText($log) | Should -Be '0123456789'
    }

    It 'records omitted clusters and emits a manifest for an empty plan' {
        $zipPath = & $collector -StateRoot $TestDrive -ClusterName @() -DestinationPath (Join-Path $TestDrive 'empty.zip')
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $zip.Entries.Count | Should -Be 1
            $reader = [IO.StreamReader]::new($zip.GetEntry('manifest.json').Open())
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            $manifest.Records.Count | Should -Be 0
        }
        finally { $zip.Dispose() }
        $zipPath = & $collector -StateRoot $TestDrive -ClusterName one,two -MaxClusters 1 -DestinationPath (Join-Path $TestDrive 'limit.zip')
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $reader = [IO.StreamReader]::new($zip.GetEntry('manifest.json').Open())
            try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
            $manifest.OmittedClusterCount | Should -Be 1
        }
        finally { $zip.Dispose() }
    }
}

Describe 'Sideload native argument quoting' {
    BeforeAll {
        $path = Join-Path $PSScriptRoot '../Tools/Invoke-AzLocalSideloadCopyTask.ps1'
        $tokens = $null
        $parseErrors = $null
        $workerAst = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $workerAst.Find({ param($Node) $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq 'ConvertTo-AzLocalNativeArgument' }, $true)
        . ([scriptblock]::Create($functionAst.Extent.Text))
    }

    It 'preserves paths and detailed logging with rate limiting in a real local copy' {
        $source = Join-Path $TestDrive 'source folder'
        $target = Join-Path $TestDrive 'target folder'
        $log = Join-Path $TestDrive 'copy log.txt'
        $null = New-Item -ItemType Directory -Path $source, $target
        Set-Content -LiteralPath (Join-Path $source 'bundle file.zip') -Value 'synthetic payload' -Encoding ASCII
        $arguments = @(($source + '\'), ($target + '\'), 'bundle file.zip', '/R:0', '/W:0', '/V', '/TS', '/FP', '/BYTES', "/LOG:$log")
        $helpText = (& robocopy.exe /? 2>&1) -join [Environment]::NewLine
        if ($helpText -match '(?i)/IORATE\b') { $arguments += '/IORATE:10485760' }
        $commandLine = ($arguments | ForEach-Object { ConvertTo-AzLocalNativeArgument -Value $_ }) -join ' '
        $process = Start-Process robocopy.exe -ArgumentList $commandLine -PassThru -RedirectStandardOutput (Join-Path $TestDrive 'stdout.txt') -RedirectStandardError (Join-Path $TestDrive 'stderr.txt')
        try {
            $process.WaitForExit()
            $process.ExitCode | Should -BeLessThan 8
            Get-Content -LiteralPath (Join-Path $target 'bundle file.zip') | Should -Be 'synthetic payload'
            Test-Path -LiteralPath $log | Should -BeTrue
            Get-Content -LiteralPath $log -Raw | Should -Match ([regex]::Escape('bundle file.zip'))
        }
        finally { $process.Dispose() }
    }
}

Describe 'Sideload self-hosted workflow prerequisites' -Tag 'ReleaseGate' {
    BeforeAll {
        $examplesRoot = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples'
        $script:WorkflowPaths = @(
            Join-Path $examplesRoot 'github-actions\sideload-updates.yml'
            Join-Path $examplesRoot 'azure-devops\sideload-updates.yml'
        )
    }

    It 'allows a complete manual pilot with fleet disabled and rejects incomplete or scheduled pilots for <Platform>' -ForEach @(
        @{ Platform = 'GitHub'; Index = 0; TriggerVariable = 'GITHUB_EVENT_NAME'; ManualTrigger = 'workflow_dispatch' },
        @{ Platform = 'AzureDevOps'; Index = 1; TriggerVariable = 'BUILD_REASON'; ManualTrigger = 'Manual' }
    ) {
        $workflow = Get-Content -LiteralPath $script:WorkflowPaths[$Index] -Raw
        $gate = [regex]::Match($workflow, '(?ms)^\s*\$pilotRequested = .*?^\s*\$(enabled|gateOn) = \[bool\]\$settings\.enabled -or \$pilotRequested')
        $gate.Success | Should -BeTrue
        $saved = @{}
        foreach ($name in @('INPUT_SINGLE_CLUSTER_VALIDATION', 'INPUT_CLUSTER_RESOURCE_ID', 'INPUT_VALIDATION_UPDATE_NAME', $TriggerVariable)) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $settings = @{ enabled = $false }
            $env:INPUT_SINGLE_CLUSTER_VALIDATION = 'true'
            $env:INPUT_CLUSTER_RESOURCE_ID = '/subscriptions/test/resourceGroups/test/providers/Microsoft.AzureStackHCI/clusters/pilot'
            $env:INPUT_VALIDATION_UPDATE_NAME = 'Solution12.2608.1003.9'
            [Environment]::SetEnvironmentVariable($TriggerVariable, $ManualTrigger)
            . ([scriptblock]::Create($gate.Value))
            (Get-Variable -Name $gate.Groups[1].Value -ValueOnly) | Should -BeTrue
            $settings.enabled | Should -BeFalse
            $env:INPUT_CLUSTER_RESOURCE_ID = ''
            { . ([scriptblock]::Create($gate.Value)) } | Should -Throw '*exact cluster resource ID*'
            $env:INPUT_CLUSTER_RESOURCE_ID = '/subscriptions/test/resourceGroups/test/providers/Microsoft.AzureStackHCI/clusters/pilot'
            [Environment]::SetEnvironmentVariable($TriggerVariable, 'schedule')
            { . ([scriptblock]::Create($gate.Value)) } | Should -Throw '*manual run*'
            $env:INPUT_SINGLE_CLUSTER_VALIDATION = 'false'
            $env:INPUT_VALIDATION_UPDATE_NAME = ''
            . ([scriptblock]::Create($gate.Value))
            (Get-Variable -Name $gate.Groups[1].Value -ValueOnly) | Should -BeFalse
        }
        finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }

    It 'keeps preview enabled and passes exact pilot inputs without inline script interpolation' {
        Import-Module powershell-yaml -ErrorAction Stop
        $github = ConvertFrom-Yaml (Get-Content $script:WorkflowPaths[0] -Raw)
        $ado = ConvertFrom-Yaml (Get-Content $script:WorkflowPaths[1] -Raw)
        $github.on.workflow_dispatch.inputs.dry_run.default | Should -Be 'true'
        ($ado.parameters | Where-Object name -eq 'dryRun').default | Should -BeTrue
        $github.on.workflow_dispatch.inputs.single_cluster_validation.default | Should -BeFalse
        ($ado.parameters | Where-Object name -eq 'singleClusterValidation').default | Should -BeFalse
        foreach ($path in $script:WorkflowPaths) {
            $workflow = Get-Content $path -Raw
            $workflow | Should -Match ([regex]::Escape('$planParams[''ClusterResourceId''] = $env:INPUT_CLUSTER_RESOURCE_ID'))
            $workflow | Should -Match ([regex]::Escape('$planParams[''SingleClusterValidation''] = $pilotRequested'))
            $workflow | Should -Match ([regex]::Escape('$planParams[''ValidationUpdateName''] = $env:INPUT_VALIDATION_UPDATE_NAME'))
        }
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
        $workflow | Should -Match 'MaxConcurrentCopiesPerRunner = \[int\]\$settings\.Reconciliation\.maxConcurrentCopiesPerRunner'
    }

    It 'builds bounded rate and detailed logging arguments for <Platform>' -ForEach @(
        @{ Platform = 'GitHub'; Index = 0 }
        @{ Platform = 'AzureDevOps'; Index = 1 }
    ) {
        $workflow = Get-Content -LiteralPath $script:WorkflowPaths[$Index] -Raw
        $settings = [pscustomobject]@{ Copy = @{
            defaultProfile = 'test'
            profiles = @{ test = @{
                retryCount = 5; waitSeconds = 30; interPacketGapMilliseconds = 0
                restartable = $true; unbuffered = $false
                ioRateBytesPerSecond = 10485760; detailedLogging = $true
            } }
        } }
        $applyParams = @{}
        $builder = [regex]::Match($workflow, '(?ms)^\s*\$profile = .*?^\s*\$applyParams\[''RobocopySwitches''\] = [^\r\n]+')
        $builder.Success | Should -BeTrue
        . ([scriptblock]::Create($builder.Value))
        $applyParams.RobocopySwitches | Should -Be '/R:5 /W:30 /Z /IORATE:10485760 /V /TS /FP /BYTES'
        $settings.Copy.profiles.test.ioRateBytesPerSecond = 0
        $settings.Copy.profiles.test.detailedLogging = $false
        . ([scriptblock]::Create($builder.Value))
        $applyParams.RobocopySwitches | Should -Be '/R:5 /W:30 /Z'
    }

    It 'installs Az.Accounts before GitHub Azure Login enables an Az PowerShell session' {
        $workflow = Get-Content -LiteralPath $script:WorkflowPaths[0] -Raw
        $accountsInstallIndex = $workflow.IndexOf('Install-Module Az.Accounts')
        $azureLoginIndex = $workflow.IndexOf('uses: azure/login@v3')

        $accountsInstallIndex | Should -BeGreaterThan -1
        $azureLoginIndex | Should -BeGreaterThan $accountsInstallIndex
    }

    It 'collects optional copy diagnostics in finally and clears old ZIPs for <Platform>' -ForEach @(
        @{ Platform = 'GitHub'; Index = 0 }
        @{ Platform = 'AzureDevOps'; Index = 1 }
    ) {
        $workflow = Get-Content -LiteralPath $script:WorkflowPaths[$Index] -Raw
        $workflow | Should -Match 'Remove-Item -LiteralPath \$copyDiagnosticsPath -Force'
        $workflow | Should -Match '(?s)finally\s*\{\s*try\s*\{\s*if \(\$(env:DEBUG_VERBOSE -eq ''true''|diagnosticsEnabled) -and \$settings\).*?& \$collector -StateRoot'
        $workflow | Should -Match '-ClusterName @\(\$plan \| ForEach-Object \{ \$_\.ClusterName \}\)'
        $workflow | Should -Match 'sideload-copy-diagnostics.zip'
        if ($Index -eq 0) {
            $workflow | Should -Match ([regex]::Escape('copy-${{ github.run_id }}-${{ github.run_attempt }}/sideload-copy-diagnostics.zip'))
        }
        $packaging = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Publish-Module.ps1') -Raw
        $packaging | Should -Match 'Tools\\Export-AzLocalSideloadDiagnostics.ps1'
    }

    It 'serializes GitHub runs and batches the Azure DevOps schedule' {
        $githubWorkflow = Get-Content -LiteralPath $script:WorkflowPaths[0] -Raw
        $adoWorkflow = Get-Content -LiteralPath $script:WorkflowPaths[1] -Raw

        $githubWorkflow | Should -Match '(?m)^concurrency:\r?$'
        $githubWorkflow | Should -Match ([regex]::Escape('group: sideload-updates-${{ github.workflow }}'))
        $githubWorkflow | Should -Match '(?m)^\s+cancel-in-progress: false\r?$'
        $adoWorkflow | Should -Match "(?m)^#\s+batch: true(?:\s+#.*)?\r?$"
    }

    It 'documents pilot acceptance and unverified end-to-end boundaries' {
        $guide = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Automation-Pipeline-Examples/docs/sideload.md') -Raw
        $guide | Should -Match 'has not yet been validated end to end'
        $guide | Should -Match '### 8.2 Pilot acceptance checklist'
        $guide | Should -Match 'TCP 445'
        $guide | Should -Match 'TCP 5986'
        $guide | Should -Match 'second-hop'
        $guide | Should -Match 'Uncommenting cron alone is'
        $guide | Should -Not -Match 'Re-running is \*\*always safe\*\*'
    }

    It 'documents artifact boundaries and validates the rate-limited YAML example' {
        Import-Module powershell-yaml -ErrorAction Stop
        $guide = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Automation-Pipeline-Examples/docs/sideload-robocopy.md') -Raw
        $examples = [regex]::Matches($guide, '(?s)```yaml\s*(.*?)```')
        $rateExample = @($examples | Where-Object { $_.Groups[1].Value -match 'ioRateBytesPerSecond' })
        $rateExample.Count | Should -Be 1
        $example = ConvertFrom-Yaml -Yaml $rateExample[0].Groups[1].Value
        $profile = $example.copy.profiles[$example.copy.defaultProfile]
        $profile.ioRateBytesPerSecond | Should -Be 10485760
        $profile.interPacketGapMilliseconds | Should -Be 0
        $profile.detailedLogging | Should -BeTrue
        $guide | Should -Match 'sideload-copy-diagnostics.zip'
        $guide | Should -Match '50 MiB total log data'
        $guide | Should -Match 'Prefer `ioRateBytesPerSecond`'
        $guide | Should -Match 'service `_diag` logs'
    }

    It 'documents runner affinity, centralized logs, HA boundaries, and 100-cluster sizing' {
        $guidePath = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples\docs\sideload.md'
        $guide = Get-Content -LiteralPath $guidePath -Raw

        $guide | Should -Match 'Scaling considerations for the self-hosted runner pool'
        $guide | Should -Match '100 due clusters'
        $guide | Should -Match 'Runner-local task affinity and failover'
        $guide | Should -Match 'active/passive runner pool'
        $guide | Should -Match 'maxConcurrentCopiesPerRunner: 10'
        $guide | Should -Match 'PowerShell remoting between pool members'
        $guide | Should -Match 'logs\\\*\.robocopy\.log'
        $guide | Should -Match 'does \*\*not\*\* automatically purge'
    }
}