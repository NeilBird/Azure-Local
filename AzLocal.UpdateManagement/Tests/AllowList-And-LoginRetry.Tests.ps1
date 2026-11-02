#Requires -Module Pester
<#
.SYNOPSIS
    v0.9.1 feature tests: (1) the apply-updates schedule allowedUpdateVersions
    allow-list override in the readiness assessment, and (2) the transient
    azure/login (GHA) + AzureCLI@2 (ADO) OIDC login retry wiring across the
    automation pipeline examples.

.NOTES
    These tests are intentionally isolated in their own file so the synthetic
    Azure Resource Graph mocks for Get-AzLocalClusterUpdateReadiness do not
    bleed into the large parameter-validation suite. The default code path
    (no -SchedulePath / -AllowedUpdateVersions) is unaffected.
#>

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:PipelineRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\Automation-Pipeline-Examples'
}

AfterAll {
    Remove-Module AzLocal.UpdateManagement -Force -ErrorAction SilentlyContinue
}

Describe 'v0.9.40: Exact runtime module selection' {
    It 'persists and imports the exact resolved runtime throughout <Platform> templates' -ForEach @(
        @{ Platform = 'github-actions' }
        @{ Platform = 'azure-devops' }
    ) {
        $files = @(Get-ChildItem (Join-Path $script:PipelineRoot $Platform) -Filter '*.yml')
        $files.Count | Should -Be 10
        foreach ($file in $files) {
            $text = Get-Content $file.FullName -Raw
            $imports = [regex]::Matches($text, '(?m)^ +Import-Module AzLocal\.UpdateManagement[^\r\n]*')
            $imports.Count | Should -BeGreaterThan 0
            foreach ($moduleImport in $imports) {
                $moduleImport.Value | Should -Match '-RequiredVersion \$env:AZLOCAL_RUN_MODULE_VERSION -ErrorAction Stop' -Because $file.Name
            }
            $installCount = [regex]::Matches($text, '(?m)^ +Install-Module @installArgs\r?$').Count
            [regex]::Matches($text, '(?m)^ +\$env:AZLOCAL_RUN_MODULE_VERSION = \[string\]\$installArgs.RequiredVersion').Count | Should -Be $installCount
            [regex]::Matches($text, 'Find-Module -Name AzLocal.UpdateManagement -Repository PSGallery -ErrorAction Stop').Count | Should -Be $installCount
            if ($Platform -eq 'github-actions') {
                [regex]::Matches($text, 'AZLOCAL_RUN_MODULE_VERSION=\$env:AZLOCAL_RUN_MODULE_VERSION" \| Out-File -FilePath \$env:GITHUB_ENV').Count | Should -Be $installCount
            }
            else {
                [regex]::Matches($text, 'task.setvariable variable=AZLOCAL_RUN_MODULE_VERSION').Count | Should -Be $installCount
            }
        }
    }

    It 'Rejects a banner that claims a different pinned version' {
        { Add-AzLocalPipelineVersionBanner -GeneratedAgainstVersion '0.9.40' -PinnedVersion '0.0.1' -SkipPSGalleryQuery } |
            Should -Throw '*does not match requested version*'
    }
}

Describe 'v0.9.40: GitHub action SHA pinning' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:GitHubTemplates = @(Get-ChildItem (Join-Path $script:PipelineRoot 'github-actions') -File -Recurse |
            Where-Object Extension -in '.yml', '.yaml')
        $script:GetActionReferences = {
            param([string]$Text)
            $workflow = ConvertFrom-Yaml $Text -ErrorAction Stop
            foreach ($job in $workflow.jobs.Values) {
                if ($job.Contains('uses')) { [string]$job.uses }
                if ($job.Contains('steps')) {
                    foreach ($step in $job.steps) {
                        if ($step.Contains('uses')) { [string]$step.uses }
                    }
                }
            }
        }
        $script:AssertActionPins = {
            param([string[]]$References)
            foreach ($reference in $References) {
                if ($reference.StartsWith('./')) { continue }
                $reference | Should -Match '^[^\s@]+/[^\s@]+@[0-9a-fA-F]{40}$'
            }
        }
    }

    It 'Rejects mutable tags, branches, and abbreviated SHAs' -ForEach @(
        @{ Reference = 'actions/checkout@v5' }
        @{ Reference = 'actions/checkout@main' }
        @{ Reference = 'actions/checkout@0123456' }
        @{ Reference = 'owner/repo/.github/workflows/build.yml@v1' }
    ) {
        { & $script:AssertActionPins @($Reference) } | Should -Throw
    }

    It 'Accepts full SHAs and distinguishes local actions and reusable workflows' {
        $fixture = @'
jobs:
  build:
    steps:
      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567
      - uses: ./local-action
      - run: 'echo uses: not-an-action@v1'
  reuse:
    uses: owner/repo/.github/workflows/build.yml@0123456789abcdef0123456789abcdef01234567
  local:
    uses: ./.github/workflows/local.yml
'@
        $references = @(& $script:GetActionReferences $fixture)
        $references | Should -HaveCount 4
        { & $script:AssertActionPins $references } | Should -Not -Throw
        $references | Should -Contain 'owner/repo/.github/workflows/build.yml@0123456789abcdef0123456789abcdef01234567'
    }

    It 'Pins every bundled active remote action and keeps action lines outside customization regions' {
        $script:GitHubTemplates.Count | Should -BeGreaterThan 0
        foreach ($file in $script:GitHubTemplates) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $references = @(& $script:GetActionReferences $text)
            $references.Count | Should -BeGreaterThan 0 -Because $file.Name
            & $script:AssertActionPins $references
            $markers = & (Get-Module AzLocal.UpdateManagement) {
                param($Text)
                Get-AzLocalPipelineCustomiseMarkers -Text $Text
            } $text
            foreach ($marker in $markers.Values) {
                $marker.Body | Should -Not -Match '(?m)^\s*(?:#\s*)?(?:-\s*)?uses:' -Because $file.Name
            }
        }
    }

    It 'Includes readable versions on active pins and commented alternatives' {
        foreach ($file in $script:GitHubTemplates) {
            foreach ($line in Get-Content -LiteralPath $file.FullName) {
                if ($line -match '^\s*(?:#\s*)?(?:-\s*)?uses:\s*(?!\./)(\S+)') {
                    & $script:AssertActionPins @($Matches[1])
                    $line | Should -Match '@[0-9a-fA-F]{40}\s+#\s+v\d+\.\d+\.\d+' -Because $file.Name
                }
            }
        }
    }

    It 'Copies pinned GitHub templates into an initial temporary repository' {
        $destination = Join-Path $TestDrive 'initial/.github/workflows'
        Copy-AzLocalPipelineExample -Destination $destination -Platform GitHub -Confirm:$false 6>$null
        $copied = @(Get-ChildItem $destination -Filter '*.yml')
        $copied.Count | Should -Be $script:GitHubTemplates.Count
        foreach ($file in $copied) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            & $script:AssertActionPins @(& $script:GetActionReferences $text)
            $text | Should -BeExactly (Get-Content (Join-Path $script:PipelineRoot "github-actions/$($file.Name)") -Raw)
        }
    }

    It 'Refreshes tag-based workflows without Force, preserves every customization body, and is idempotent' {
        $destination = Join-Path $TestDrive 'refresh/.github/workflows'
        New-Item $destination -ItemType Directory -Force | Out-Null
        $expectedBodies = @{}
        foreach ($file in $script:GitHubTemplates) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            $text = [regex]::Replace($text, '(?m)(^\s*(?:#\s*)?(?:-\s*)?uses:\s*[^\s@]+/)\S+@[^\s#]+[^\r\n]*', {
                param($match)
                ($match.Value -replace '@[^\s#]+[^\r\n]*$', '@legacy-tag')
            })
            $markers = & (Get-Module AzLocal.UpdateManagement) {
                param($Text)
                Get-AzLocalPipelineCustomiseMarkers -Text $Text
            } $text
            $expectedBodies[$file.Name] = @{}
            foreach ($entry in ($markers.GetEnumerator() | Sort-Object { $_.Value.Index } -Descending)) {
                $marker = $entry.Value
                $body = $marker.Body + "    # operator customization: $($entry.Key)`n"
                $body = $body -replace 'runs-on: [^\r\n]+', 'runs-on: [self-hosted, operator-runner]'
                $body = $body -replace "cron: '[^']+'", "cron: '17 3 * * 2'"
                $expectedBodies[$file.Name][$entry.Key] = $body
                $text = $text.Substring(0, $marker.Index) + $marker.BeginLine + $body + $marker.EndLine +
                    $text.Substring($marker.Index + $marker.Length)
            }
            [IO.File]::WriteAllText((Join-Path $destination $file.Name), $text)
        }
        $results = @(Update-AzLocalPipelineExample -Destination $destination -Platform GitHub -PassThru -Confirm:$false 6>$null)
        $workflowResults = @($results | Where-Object { $_.File -like '*.yml' -and (Split-Path $_.File -Parent) -eq $destination })
        $workflowResults.Count | Should -Be $script:GitHubTemplates.Count
        $snapshots = @{}
        foreach ($result in $workflowResults) {
            $result.Action | Should -Be 'Updated'
            $name = Split-Path $result.File -Leaf
            $text = Get-Content -LiteralPath $result.File -Raw
            & $script:AssertActionPins @(& $script:GetActionReferences $text)
            $markers = & (Get-Module AzLocal.UpdateManagement) {
                param($Text)
                Get-AzLocalPipelineCustomiseMarkers -Text $Text
            } $text
            foreach ($entry in $expectedBodies[$name].GetEnumerator()) {
                $markers[$entry.Key].Body | Should -BeExactly $entry.Value
                $result.PreservedMarkers | Should -Contain $entry.Key
            }
            $snapshots[$result.File] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($result.File))
        }
        $second = @(Update-AzLocalPipelineExample -Destination $destination -Platform GitHub -PassThru -Confirm:$false 6>$null)
        $secondWorkflows = @($second | Where-Object { $snapshots.ContainsKey($_.File) })
        $secondWorkflows.Count | Should -Be $snapshots.Count
        foreach ($result in $secondWorkflows) {
            $result.Action | Should -Be 'Unchanged'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($result.File)) | Should -BeExactly $snapshots[$result.File]
        }
    }

    It 'Keeps copy-paste documentation action references pinned' {
        $moduleRoot = Split-Path $script:PipelineRoot -Parent
        foreach ($relativePath in @('README.md', 'Automation-Pipeline-Examples/README.md', 'ITSM/ITSM-Connector-Plan.md')) {
            foreach ($line in Get-Content (Join-Path $moduleRoot $relativePath)) {
                if ($line -match '^\s*(?:#\s*)?(?:-\s*)?uses:\s*(\S+)') {
                    & $script:AssertActionPins @($Matches[1])
                }
            }
        }
    }
}

Describe 'v0.9.40: Azure DevOps approved task gate' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:ApprovedAdoTasks = @(
            'PowerShell@2', 'AzureCLI@2', 'PublishPipelineArtifact@1',
            'DownloadPipelineArtifact@2', 'PublishBuildArtifacts@1', 'PublishTestResults@2'
        )
        $script:AssertAdoSteps = {
            param($Steps)
            foreach ($step in $Steps) {
                $step -is [System.Collections.IDictionary] | Should -BeTrue
                if ($step.Contains('task')) {
                    $script:ApprovedAdoTasks | Should -Contain ([string]$step.task)
                    [string]$step.task
                }
                elseif ($step.Contains('pwsh')) { 'PowerShell@2' }
                elseif ($step.Contains('checkout')) {
                    @('self', 'none') | Should -Contain ([string]$step.checkout)
                }
                else {
                    foreach ($key in $step.Keys) {
                        [string]$key | Should -Match '^\$\{\{.+\}\}$'
                        & $script:AssertAdoSteps $step[$key]
                    }
                    $step.Count | Should -BeGreaterThan 0
                }
            }
        }
        $script:GetApprovedAdoTasks = {
            param($Node)
            if ($Node -is [System.Collections.IDictionary]) {
                foreach ($key in $Node.Keys) {
                    [string]$key | Should -Not -BeIn @('template', 'extends')
                    if ($key -eq 'steps') { & $script:AssertAdoSteps $Node[$key] }
                    else { & $script:GetApprovedAdoTasks $Node[$key] }
                }
            }
            elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
                foreach ($child in $Node) { & $script:GetApprovedAdoTasks $child }
            }
        }
    }

    It 'Accepts approved tasks and pwsh in jobs, stages, deployment hooks and conditional steps' {
        $fixture = @'
stages:
- stage: verify
  jobs:
  - job: build
    steps:
    - checkout: self
    - task: AzureCLI@2
    - pwsh: |
        Write-Output 'task: Unapproved@1'
  - deployment: deploy
    strategy:
      runOnce:
        deploy:
          steps:
          - ${{ if true }}:
            - task: PublishTestResults@2
'@
        $references = @(& $script:GetApprovedAdoTasks (ConvertFrom-Yaml $fixture))
        $references | Should -HaveCount 3
        $references | Should -Contain 'PowerShell@2'
        $references | Should -Contain 'PublishTestResults@2'
    }

    It 'Rejects unreviewed task identities, versions and step shortcuts: <Step>' -ForEach @(
        @{ Step = 'task: Marketplace.Task@1' }
        @{ Step = 'task: PowerShell@3' }
        @{ Step = 'task: PowerShell@2.999.0' }
        @{ Step = 'task: 00000000-0000-0000-0000-000000000000@2' }
        @{ Step = 'task: "${{ parameters.task }}"' }
        @{ Step = 'bash: echo unreviewed' }
        @{ Step = 'powershell: Write-Output unreviewed' }
        @{ Step = 'script: echo unreviewed' }
        @{ Step = 'template: external.yml@otherRepo' }
        @{ Step = 'publish: artifact' }
        @{ Step = 'download: current' }
    ) {
        $workflow = ConvertFrom-Yaml "steps:`n- $Step"
        { & $script:GetApprovedAdoTasks $workflow } | Should -Throw
    }

    It 'Rejects template dependencies outside steps: <Pipeline>' -ForEach @(
        @{ Pipeline = "extends:`n  template: external.yml@otherRepo" }
        @{ Pipeline = "stages:`n- stage: test`n  jobs:`n  - template: jobs.yml" }
    ) {
        $workflow = ConvertFrom-Yaml $Pipeline
        { & $script:GetApprovedAdoTasks $workflow } | Should -Throw
    }

    It 'Checks every bundled Azure DevOps template against the approved task set' {
        $templates = @(Get-ChildItem (Join-Path $script:PipelineRoot 'azure-devops') -File -Recurse |
            Where-Object Extension -in '.yml', '.yaml')
        $templates.Count | Should -Be 10
        $references = foreach ($file in $templates) {
            $workflow = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Yaml -ErrorAction Stop
            $tasks = @(& $script:GetApprovedAdoTasks $workflow)
            $tasks.Count | Should -BeGreaterThan 0 -Because $file.Name
            $tasks
        }
        @($references | Sort-Object -Unique).Count | Should -Be $script:ApprovedAdoTasks.Count
    }
}

Describe 'v0.9.38: Collapsed GitHub JUnit report details' {
    It 'Keeps all 17 publishers collapsed with explanatory titles and XML inputs' {
        Import-Module powershell-yaml -ErrorAction Stop
        $publisherCount = 0
        foreach ($file in Get-ChildItem (Join-Path $script:PipelineRoot 'github-actions') -Filter '*.yml') {
            $workflow = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Yaml
            foreach ($job in $workflow.jobs.Values) {
                foreach ($step in $job.steps) {
                    if ($step.uses -like 'dorny/test-reporter@*') {
                        $publisherCount++
                        $step.with.collapsed | Should -Be 'always' -Because $file.Name
                        $step.with.'report-title' | Should -Be 'Expand to view JUnit report details'
                        $step.with.reporter | Should -Be 'java-junit'
                        $step.with.path | Should -Not -BeNullOrEmpty
                    }
                }
            }
        }
        $publisherCount | Should -Be 17
    }
}

Describe 'v0.9.1 Private helper: Resolve-AzLocalClusterAllowList' {

    BeforeAll {
        # A typed schedule-config-shaped object mirroring the surface
        # Get-AzLocalApplyUpdatesScheduleConfig exposes: a top-level
        # AllowedUpdateVersions [string[]] and Schedule rows each with .rings
        # (';'-separated) and .AllowedUpdateVersionsParsed [string[]] (or $null).
        $script:NewSchedule = {
            param($TopLevel, $Rows)
            [PSCustomObject]@{
                SchemaVersion         = 2
                AllowedUpdateVersions = $TopLevel
                Schedule              = $Rows
            }
        }
        $script:NewRow = {
            param($Rings, $Override)
            [PSCustomObject]@{
                rings                       = $Rings
                AllowedUpdateVersionsParsed = $Override
            }
        }
    }

    It 'Returns Source=TopLevel and IsLatest when only the top-level list is Latest' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('Latest')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Canary'; AllowedUpdateVersionsParsed = $null }
                )
            }
            $r = Resolve-AzLocalClusterAllowList -UpdateRing 'Canary' -Schedule $sched
            $r.Source                 | Should -Be 'TopLevel'
            $r.IsLatest               | Should -BeTrue
            @($r.EffectiveAllowList)  | Should -HaveCount 1
            $r.EffectiveAllowList[0]  | Should -Be 'Latest'
        }
    }

    It 'Per-ring override beats the top-level default' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.123')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Canary'; AllowedUpdateVersionsParsed = $null },
                    [PSCustomObject]@{ rings = 'Prod';   AllowedUpdateVersionsParsed = @('10.2610.0.456') }
                )
            }
            $r = Resolve-AzLocalClusterAllowList -UpdateRing 'Prod' -Schedule $sched
            $r.Source                | Should -Be 'RowOverride'
            $r.MatchedRing           | Should -Be 'Prod'
            $r.IsLatest              | Should -BeFalse
            $r.EffectiveAllowList[0] | Should -Be '10.2610.0.456'
        }
    }

    It "A row whose rings cell is the '***' wildcard supplies the override for any ring" {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.123')
                Schedule              = @(
                    [PSCustomObject]@{ rings = '***'; AllowedUpdateVersionsParsed = @('10.2699.0.999') }
                )
            }
            $r = Resolve-AzLocalClusterAllowList -UpdateRing 'AnyRing' -Schedule $sched
            $r.Source                | Should -Be 'RowOverride'
            $r.EffectiveAllowList[0] | Should -Be '10.2699.0.999'
        }
    }

    It 'An untagged cluster (no UpdateRing) falls back to the top-level default' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.123')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Prod'; AllowedUpdateVersionsParsed = @('10.2610.0.456') }
                )
            }
            $r = Resolve-AzLocalClusterAllowList -UpdateRing '' -Schedule $sched
            $r.Source                | Should -Be 'TopLevel'
            $r.MatchedRing           | Should -Be ''
            $r.EffectiveAllowList[0] | Should -Be '10.2604.0.123'
        }
    }

    It 'Returns Source=None when neither a row override nor a top-level list is present' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @()
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Canary'; AllowedUpdateVersionsParsed = $null }
                )
            }
            $r = Resolve-AzLocalClusterAllowList -UpdateRing 'Canary' -Schedule $sched
            $r.Source                | Should -Be 'None'
            $r.IsLatest              | Should -BeFalse
            @($r.EffectiveAllowList) | Should -HaveCount 0
        }
    }

    It 'Ring match is case-insensitive' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('top.1.2.3')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Production'; AllowedUpdateVersionsParsed = @('row.4.5.6') }
                )
            }
            $r = Resolve-AzLocalClusterAllowList -UpdateRing 'production' -Schedule $sched
            $r.Source                | Should -Be 'RowOverride'
            $r.EffectiveAllowList[0] | Should -Be 'row.4.5.6'
        }
    }
}

Describe 'v0.9.15 Private helper: Resolve-AzLocalForceAllowList' {
    # The FORCE (break-glass) allow-list resolver. Unlike the single-cluster
    # Resolve-AzLocalClusterAllowList, this generalises to the operator's manual
    # UpdateRing input (single ring, ';'-joined list, or the '***' wildcard) and
    # returns the UNION of per-ring overrides across every covered row (per-ring
    # override beats the fleet-wide global default; 'Latest' => no constraint).

    It 'Per-ring override beats the global default for a single target ring' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.1')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Canary'; AllowedUpdateVersionsParsed = $null },
                    [PSCustomObject]@{ rings = 'Prod';   AllowedUpdateVersionsParsed = @('10.2610.0.9') }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'Prod' -Schedule $sched
            $r.Source                     | Should -Be 'RowOverride'
            $r.IsLatest                   | Should -BeFalse
            $r.AllowedUpdateVersionsValue | Should -Be '10.2610.0.9'
            @($r.EffectiveAllowList)      | Should -HaveCount 1
        }
    }

    It 'Falls back to the global default when the target ring has no per-ring override' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.1')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Prod'; AllowedUpdateVersionsParsed = @('10.2610.0.9') }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'Canary' -Schedule $sched
            $r.Source                     | Should -Be 'TopLevel'
            $r.AllowedUpdateVersionsValue | Should -Be '10.2604.0.1'
        }
    }

    It 'Unions per-ring overrides across a multi-ring (Prod;Ring2) input' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.1')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Prod';  AllowedUpdateVersionsParsed = @('10.2610.0.9') },
                    [PSCustomObject]@{ rings = 'Ring2'; AllowedUpdateVersionsParsed = @('10.2611.0.3') }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'Prod;Ring2' -Schedule $sched
            $r.Source                     | Should -Be 'RowOverride'
            $r.AllowedUpdateVersionsValue | Should -Be '10.2610.0.9;10.2611.0.3'
            @($r.EffectiveAllowList)      | Should -HaveCount 2
        }
    }

    It "A '***' target ring unions every row override across the whole fleet" {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.1')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Prod';  AllowedUpdateVersionsParsed = @('10.2610.0.9') },
                    [PSCustomObject]@{ rings = 'Ring2'; AllowedUpdateVersionsParsed = @('10.2611.0.3') }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing '***' -Schedule $sched
            $r.Source                     | Should -Be 'RowOverride'
            $r.AllowedUpdateVersionsValue | Should -Be '10.2610.0.9;10.2611.0.3'
        }
    }

    It "A row whose rings cell is '***' supplies the override for any target ring" {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('10.2604.0.1')
                Schedule              = @(
                    [PSCustomObject]@{ rings = '***'; AllowedUpdateVersionsParsed = @('10.2699.0.999') }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'AnyRing' -Schedule $sched
            $r.Source                     | Should -Be 'RowOverride'
            $r.AllowedUpdateVersionsValue | Should -Be '10.2699.0.999'
        }
    }

    It "The 'Latest' sentinel collapses to no constraint (empty list, IsLatest=true)" {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('Latest')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Prod'; AllowedUpdateVersionsParsed = $null }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'Prod' -Schedule $sched
            $r.Source                     | Should -Be 'TopLevel'
            $r.IsLatest                   | Should -BeTrue
            $r.AllowedUpdateVersionsValue | Should -Be ''
            @($r.EffectiveAllowList)      | Should -HaveCount 0
        }
    }

    It 'Returns Source=None with an empty list when neither a row override nor a global default is set' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @()
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Prod'; AllowedUpdateVersionsParsed = $null }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'Prod' -Schedule $sched
            $r.Source                     | Should -Be 'None'
            $r.IsLatest                   | Should -BeFalse
            $r.AllowedUpdateVersionsValue | Should -Be ''
            @($r.EffectiveAllowList)      | Should -HaveCount 0
        }
    }

    It 'Ring match is case-insensitive' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @('top.1.2.3')
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Production'; AllowedUpdateVersionsParsed = @('row.4.5.6') }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'production' -Schedule $sched
            $r.Source                     | Should -Be 'RowOverride'
            $r.AllowedUpdateVersionsValue | Should -Be 'row.4.5.6'
        }
    }

    It 'Deduplicates identical versions unioned from multiple covered rows' {
        InModuleScope AzLocal.UpdateManagement {
            $sched = [PSCustomObject]@{
                AllowedUpdateVersions = @()
                Schedule              = @(
                    [PSCustomObject]@{ rings = 'Prod';  AllowedUpdateVersionsParsed = @('10.2610.0.9') },
                    [PSCustomObject]@{ rings = 'Ring2'; AllowedUpdateVersionsParsed = @('10.2610.0.9') }
                )
            }
            $r = Resolve-AzLocalForceAllowList -UpdateRing 'Prod;Ring2' -Schedule $sched
            $r.Source                     | Should -Be 'RowOverride'
            $r.AllowedUpdateVersionsValue | Should -Be '10.2610.0.9'
            @($r.EffectiveAllowList)      | Should -HaveCount 1
        }
    }
}

Describe 'v0.9.1 Get-AzLocalClusterUpdateReadiness: allow-list override' {

    BeforeAll {
        $script:Rid = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/c1'

        # Shared ARG mock: one Ready update (Solution10.2509.0.100 / version
        # 10.2509.0.100) on a single connected, healthy cluster. The summary
        # state is UpdateAvailable so the cluster is Ready in the default path.
        $script:InvokeArgMock = {
            param($Query, $SubscriptionId)
            if ($Query -match 'updatesummaries') {
                return @([PSCustomObject]@{
                        id                 = "$script:Rid/updateSummaries/default"
                        name               = 'default'
                        properties         = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Success'; lastChecked = '2026-07-07T11:53:06Z' }
                        ClusterResourceId_ = $script:Rid.ToLower()
                    })
            }
            elseif ($Query -match "clusters/updates'") {
                return @([PSCustomObject]@{
                        name               = 'Solution10.2509.0.100'
                        properties         = [PSCustomObject]@{ state = 'Ready'; version = '10.2509.0.100' }
                        ClusterResourceId_ = $script:Rid.ToLower()
                        UpdateName_        = 'Solution10.2509.0.100'
                    })
            }
            else {
                # Cluster discovery row.
                return @([PSCustomObject]@{
                        id             = $script:Rid
                        name           = 'c1'
                        resourceGroup  = 'r'
                        subscriptionId = 's'
                        tags           = @{ UpdateRing = 'Prod' }
                        properties     = [PSCustomObject]@{ status = 'ConnectedRecently' }
                    })
            }
        }
    }

    It 'Default path (no allow-list) reports the cluster Ready and AllowListSource=None' {
        InModuleScope AzLocal.UpdateManagement -Parameters @{ Rid = $script:Rid; ArgMock = $script:InvokeArgMock } {
            param($Rid, $ArgMock)
            function global:az { $global:LASTEXITCODE = 0; return '{}' }
            Mock Test-AzCliAvailable      { return $true }
            Mock Install-AzGraphExtension { return $true }
            Mock Invoke-AzResourceGraphQuery $ArgMock

            $row = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds @($Rid) -PassThru 6>$null |
                Where-Object ClusterName -eq 'c1'

            $row.ReadyForUpdate    | Should -BeTrue
            $row.RecommendedUpdate | Should -Be 'Solution10.2509.0.100'
            $row.AllowListSource   | Should -Be 'None'
            $row.UpdateState       | Should -Be 'UpdateAvailable'
            $row.AzureUpdateState  | Should -Be 'UpdateAvailable'
            # v0.9.19: the updateSummary lastChecked timestamp is surfaced (normalised to ISO-8601 UTC).
            $row.StatusLastChecked | Should -Be '2026-07-07T11:53:06Z'
        }
    }

    It 'An allow-list that matches the Ready update keeps the cluster Ready (AllowListSource=Explicit)' {
        InModuleScope AzLocal.UpdateManagement -Parameters @{ Rid = $script:Rid; ArgMock = $script:InvokeArgMock } {
            param($Rid, $ArgMock)
            function global:az { $global:LASTEXITCODE = 0; return '{}' }
            Mock Test-AzCliAvailable      { return $true }
            Mock Install-AzGraphExtension { return $true }
            Mock Invoke-AzResourceGraphQuery $ArgMock

            $row = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds @($Rid) `
                -AllowedUpdateVersions @('10.2509.0.100') -PassThru 6>$null |
                Where-Object ClusterName -eq 'c1'

            $row.ReadyForUpdate    | Should -BeTrue
            $row.RecommendedUpdate | Should -Be 'Solution10.2509.0.100'
            $row.AllowListSource   | Should -Be 'Explicit'
            $row.AllowedUpdateVersions | Should -Be '10.2509.0.100'
        }
    }

    It 'An allow-list with no matching Ready update suppresses the update and reports UpToDate (raw state preserved)' {
        InModuleScope AzLocal.UpdateManagement -Parameters @{ Rid = $script:Rid; ArgMock = $script:InvokeArgMock } {
            param($Rid, $ArgMock)
            function global:az { $global:LASTEXITCODE = 0; return '{}' }
            Mock Test-AzCliAvailable      { return $true }
            Mock Install-AzGraphExtension { return $true }
            Mock Invoke-AzResourceGraphQuery $ArgMock

            $row = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds @($Rid) `
                -AllowedUpdateVersions @('99.9999.0.999') -PassThru 6>$null |
                Where-Object ClusterName -eq 'c1'

            $row.ReadyForUpdate   | Should -BeFalse
            $row.UpdateState      | Should -Be 'UpToDate'
            $row.AzureUpdateState | Should -Be 'UpdateAvailable' -Because 'the raw Azure update-summary state must be preserved for diagnostics'
            $row.AllowListSource  | Should -Be 'Explicit'
            # v0.9.19: the filtered-out Ready update is surfaced for the fleet
            # aggregate "Updates filtered out by the allow-list" table.
            $row.AllowListSuppressedUpdates | Should -Be 'Solution10.2509.0.100'
        }
    }

    It "The 'Latest' sentinel applies no constraint (cluster stays Ready, AllowListSource=Latest)" {
        InModuleScope AzLocal.UpdateManagement -Parameters @{ Rid = $script:Rid; ArgMock = $script:InvokeArgMock } {
            param($Rid, $ArgMock)
            function global:az { $global:LASTEXITCODE = 0; return '{}' }
            Mock Test-AzCliAvailable      { return $true }
            Mock Install-AzGraphExtension { return $true }
            Mock Invoke-AzResourceGraphQuery $ArgMock

            $row = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds @($Rid) `
                -AllowedUpdateVersions @('Latest') -PassThru 6>$null |
                Where-Object ClusterName -eq 'c1'

            $row.ReadyForUpdate    | Should -BeTrue
            $row.RecommendedUpdate | Should -Be 'Solution10.2509.0.100'
            $row.AllowListSource   | Should -Be 'Latest'
        }
    }
}

Describe 'v0.9.1 readiness cmdlet exposes allow-list surface parameters' {
    BeforeAll { $script:cmd = Get-Command Get-AzLocalClusterUpdateReadiness }

    It 'Has a SchedulePath parameter' {
        $script:cmd.Parameters.Keys | Should -Contain 'SchedulePath'
    }

    It 'Has an AllowedUpdateVersions parameter typed [string[]]' {
        $script:cmd.Parameters.Keys | Should -Contain 'AllowedUpdateVersions'
        $script:cmd.Parameters['AllowedUpdateVersions'].ParameterType.FullName | Should -Be 'System.String[]'
    }

    It 'Export-AzLocalClusterUpdateReadinessReport forwards a SchedulePath parameter' {
        (Get-Command Export-AzLocalClusterUpdateReadinessReport).Parameters.Keys |
            Should -Contain 'SchedulePath'
    }

    It 'Test-AzLocalClusterHealth has no -SchedulePath (so it must not be reused with the readiness params clone)' {
        # Regression guard for the v0.9.10 leak: SchedulePath was added to the
        # shared $scopeParams and then splatted into Test-AzLocalClusterHealth,
        # which has no -SchedulePath, failing the whole assess pipeline. The
        # health call must use $scopeParams while SchedulePath is added only to
        # a readiness-only clone ($readinessParams).
        (Get-Command Test-AzLocalClusterHealth).Parameters.Keys | Should -Not -Contain 'SchedulePath'

        $src = (Get-Command Export-AzLocalClusterUpdateReadinessReport).ScriptBlock.ToString()
        $src | Should -Match '\$readinessParams\[''SchedulePath''\]\s*=\s*\$SchedulePath'
        $src | Should -Not -Match '\$scopeParams\[''SchedulePath''\]'
        $src | Should -Match 'Test-AzLocalClusterHealth @scopeParams'
    }
}

Describe 'v0.9.1 pipeline login-retry wiring' {

    It 'All Azure DevOps read-only tasks declare retryCountOnTaskFailure: 2 (26 total)' {
        $adoFiles = Get-ChildItem -Path (Join-Path $script:PipelineRoot 'azure-devops') -Filter '*.yml' -File
        $total = 0
        foreach ($f in $adoFiles) {
            $content = Get-Content -Raw -LiteralPath $f.FullName
            $total += ([regex]::Matches($content, 'retryCountOnTaskFailure:\s*2')).Count
        }
        $total | Should -Be 26
    }

    It 'Mutating Azure DevOps tasks are NOT given a retry (no retry near Apply/Retry Failed/Raise ITSM displayNames)' {
        # The state-changing tasks must never auto-retry (duplicate apply /
        # duplicate ITSM ticket risk). Assert the retry directive does not
        # immediately follow any of these mutating displayName lines.
        $adoFiles = Get-ChildItem -Path (Join-Path $script:PipelineRoot 'azure-devops') -Filter '*.yml' -File
        $mutatingPattern = "displayName:\s*'(Apply Updates|Retry Failed Updates|Raise ITSM tickets)'[^\n]*\n(\s*#[^\n]*\n)*\s*retryCountOnTaskFailure"
        foreach ($f in $adoFiles) {
            $content = Get-Content -Raw -LiteralPath $f.FullName
            [regex]::IsMatch($content, $mutatingPattern) |
                Should -BeFalse -Because "$($f.Name) must not auto-retry a mutating task"
        }
    }

    It 'All GitHub Actions workflows declare the azure/login failure-retry guard (12 total)' {
        $ghaFiles = Get-ChildItem -Path (Join-Path $script:PipelineRoot 'github-actions') -Filter '*.yml' -File
        $total = 0
        foreach ($f in $ghaFiles) {
            $content = Get-Content -Raw -LiteralPath $f.FullName
            $total += ([regex]::Matches($content, "outcome == 'failure'")).Count
        }
        $total | Should -Be 12
    }

    It 'Each GitHub Actions login-retry guard pairs with a continue-on-error primary login (azure_login id)' {
        $ghaFiles = Get-ChildItem -Path (Join-Path $script:PipelineRoot 'github-actions') -Filter '*.yml' -File
        foreach ($f in $ghaFiles) {
            $content = Get-Content -Raw -LiteralPath $f.FullName
            $retryCount = ([regex]::Matches($content, "steps\.azure_login\.outcome == 'failure'")).Count
            if ($retryCount -gt 0) {
                $content | Should -Match 'id:\s*azure_login' -Because "$($f.Name) references steps.azure_login but never defines that id"
                $content | Should -Match 'continue-on-error:\s*true' -Because "$($f.Name) primary login must continue-on-error so the retry can run"
            }
        }
    }
}

Describe 'v0.9.1 pipeline schedule allow-list wiring (assess pipelines)' {

    It 'GitHub Actions assess-update-readiness wires APPLY_UPDATES_SCHEDULE_PATH into SchedulePath' {
        $content = Get-Content -Raw -LiteralPath (Join-Path $script:PipelineRoot 'github-actions/assess-update-readiness.yml')
        $content | Should -Match 'APPLY_UPDATES_SCHEDULE_PATH'
        $content | Should -Match "\`$params\['SchedulePath'\]"
        $content | Should -Match 'Test-Path -LiteralPath'
    }

    It 'Azure DevOps assess-update-readiness wires APPLY_UPDATES_SCHEDULE_PATH into SchedulePath' {
        $content = Get-Content -Raw -LiteralPath (Join-Path $script:PipelineRoot 'azure-devops/assess-update-readiness.yml')
        $content | Should -Match 'APPLY_UPDATES_SCHEDULE_PATH'
        $content | Should -Match "\`$params\['SchedulePath'\]"
        $content | Should -Match 'Test-Path -LiteralPath'
    }
}

Describe 'v0.9.14 PSGallery install-step transient retry wiring' {

    # v0.9.14: the shared "Install AzLocal.UpdateManagement from PSGallery" step
    # in every pipeline (GitHub Actions and Azure DevOps) wraps the actual
    # Install-Module call in a capped exponential-backoff + jitter retry loop so a
    # transient PSGallery search/propagation blip ("No match was found for the
    # specified search criteria and module name 'AzLocal.UpdateManagement'") no
    # longer fails the whole run. Attempt history: 3 (v0.9.14) -> 5 (v0.9.16) ->
    # 25 (v0.9.17) after a customer + internal fleet hit a >2.5-min PSGallery
    # outage. v0.9.17 uses ONE uniform mechanism on BOTH platforms - 25 in-run
    # attempts (~25 min single run) - deliberately NOT a self-re-queue, to keep
    # GitHub Actions and Azure DevOps behaviour identical and avoid needing
    # 'actions: write' / ADO's Queue-builds permission. The retry MUST be an inline
    # pwsh loop (not a module cmdlet) because it runs BEFORE the module is
    # installed, and NOT the native ADO retryCountOnTaskFailure (no configurable
    # backoff; would disturb the counted login-retry assertions above).

    It 'Every pipeline YAML that installs the module wraps Install-Module in the 25-attempt retry loop' {
        $ymlFiles = Get-ChildItem -Path $script:PipelineRoot -Recurse -Filter '*.yml' -File
        $ymlFiles.Count | Should -BeGreaterThan 0

        $issues = New-Object System.Collections.Generic.List[string]
        foreach ($yml in $ymlFiles) {
            $content = Get-Content -Raw -LiteralPath $yml.FullName
            $installCount = ([regex]::Matches($content, [regex]::Escape('Install-Module @installArgs'))).Count
            if ($installCount -eq 0) { continue }

            $retryCount = ([regex]::Matches($content, [regex]::Escape('$installMaxAttempts = 25'))).Count
            $sleepCount = ([regex]::Matches($content, [regex]::Escape('Start-Sleep -Seconds $installRetryDelay'))).Count

            $relPath = $yml.FullName.Substring($script:PipelineRoot.Length).TrimStart('\', '/')
            if ($retryCount -ne $installCount) {
                $issues.Add("${relPath}: has $installCount install call(s) but $retryCount retry loop opener(s) (`$installMaxAttempts = 25)")
            }
            if ($sleepCount -ne $installCount) {
                $issues.Add("${relPath}: has $installCount install call(s) but $sleepCount backoff Start-Sleep call(s)")
            }
        }

        $detail = if ($issues.Count -gt 0) { ($issues -join [Environment]::NewLine) } else { '(no findings)' }
        $issues.Count | Should -Be 0 -Because "every install step must wrap Install-Module in the retry loop. Findings:$([Environment]::NewLine)$detail"
    }

    It 'Retry loop count matches the total install-call count across all pipelines (26 each)' {
        $ymlFiles = Get-ChildItem -Path $script:PipelineRoot -Recurse -Filter '*.yml' -File
        $installTotal = 0
        $retryTotal   = 0
        foreach ($yml in $ymlFiles) {
            $content = Get-Content -Raw -LiteralPath $yml.FullName
            $installTotal += ([regex]::Matches($content, [regex]::Escape('Install-Module @installArgs'))).Count
            $retryTotal   += ([regex]::Matches($content, [regex]::Escape('$installMaxAttempts = 25'))).Count
        }
        $installTotal | Should -Be 26
        $retryTotal   | Should -Be $installTotal
    }

    It 'v0.9.17: both platforms use the same 25-attempt single-run mechanism (no self-re-queue)' {
        $ymlFiles = Get-ChildItem -Path $script:PipelineRoot -Recurse -Filter '*.yml' -File
        foreach ($yml in $ymlFiles) {
            $content = Get-Content -Raw -LiteralPath $yml.FullName
            if (([regex]::Matches($content, [regex]::Escape('Install-Module @installArgs'))).Count -eq 0) { continue }
            $content | Should -Not -Match 'Re-queue on transient PSGallery install failure' -Because "$($yml.Name) must use the uniform 25-attempt single-run coverage, not a self-re-queue"
            $content | Should -Not -Match 'install_retry_attempt' -Because "$($yml.Name) must not carry the abandoned re-queue counter input"
        }
    }

    It 'Every retry loop uses a capped exponential backoff with jitter (v0.9.16)' {
        $ymlFiles = Get-ChildItem -Path $script:PipelineRoot -Recurse -Filter '*.yml' -File
        foreach ($yml in $ymlFiles) {
            $content = Get-Content -Raw -LiteralPath $yml.FullName
            $installCount = ([regex]::Matches($content, [regex]::Escape('Install-Module @installArgs'))).Count
            if ($installCount -eq 0) { continue }
            $capCount    = ([regex]::Matches($content, [regex]::Escape('[math]::Min(60, 10 * [math]::Pow(2, $installAttempt - 1))'))).Count
            $jitterCount = ([regex]::Matches($content, [regex]::Escape('Get-Random -Minimum 0 -Maximum 5'))).Count
            $capCount    | Should -Be $installCount -Because "$($yml.Name) every backoff must be capped at 60s via [math]::Min"
            $jitterCount | Should -Be $installCount -Because "$($yml.Name) every backoff must add Get-Random jitter to avoid lockstep fleet retries"
        }
    }

    It 'The retry loop re-throws on the final attempt so a persistent failure still fails the job' {
        $ymlFiles = Get-ChildItem -Path $script:PipelineRoot -Recurse -Filter '*.yml' -File
        foreach ($yml in $ymlFiles) {
            $content = Get-Content -Raw -LiteralPath $yml.FullName
            if (($content -notmatch [regex]::Escape('Install-Module @installArgs'))) { continue }
            $content | Should -Match '\$installAttempt -ge \$installMaxAttempts' -Because "$($yml.Name) retry loop must stop and re-throw once max attempts are reached"
            $content | Should -Match '(?m)^\s*throw\s*$' -Because "$($yml.Name) retry loop must re-throw the last error so the job fails"
        }
    }

    # v0.9.16: the benign "No Clusters Ready" reporting job in apply-updates
    # (GH job no-clusters-ready / ADO stage NoClustersReady) only annotates a
    # nothing-to-apply outcome. A persistent PSGallery install blip there must
    # NOT turn a healthy no-op run red, so its install + report steps are soft
    # (continue-on-error / continueOnError). The hardened retry loop still
    # absorbs the common transient case; this just prevents a misleading red.
    It 'GitHub Actions no-clusters-ready reporting job is soft (continue-on-error)' {
        $content = Get-Content -Raw -LiteralPath (Join-Path $script:PipelineRoot 'github-actions/apply-updates.yml')
        $content | Should -Match 'no-clusters-ready:'
        ([regex]::Matches($content, [regex]::Escape('continue-on-error: true'))).Count |
            Should -BeGreaterOrEqual 2 -Because 'the no-clusters-ready install + report steps must both be continue-on-error'
    }

    It 'Azure DevOps NoClustersReady reporting stage is soft (continueOnError)' {
        $content = Get-Content -Raw -LiteralPath (Join-Path $script:PipelineRoot 'azure-devops/apply-updates.yml')
        $content | Should -Match 'NoClustersReady'
        ([regex]::Matches($content, [regex]::Escape('continueOnError: true'))).Count |
            Should -BeGreaterOrEqual 2 -Because 'the ReportNoReadyClusters install + report tasks must both be continueOnError'
    }
}
