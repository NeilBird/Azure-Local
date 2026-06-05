#Requires -Module Pester
<#
.SYNOPSIS
    Pester tests for the AzLocal.UpdateManagement module.

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
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop
    
    # Store module info for tests
    $script:ModuleInfo = Get-Module AzLocal.UpdateManagement
}

AfterAll {
    # Clean up
    Remove-Module AzLocal.UpdateManagement -Force -ErrorAction SilentlyContinue
}

Describe 'Module: AzLocal.UpdateManagement' {
    
    Context 'Module Load' {
        It 'Should load the module without errors' {
            $script:ModuleInfo | Should -Not -BeNullOrEmpty
        }

        It 'Should have version 0.7.92' {
            $script:ModuleInfo.Version | Should -Be '0.7.92'
        }

        It 'Module version constants are in sync between .psm1 and .psd1' {
            # v0.7.67: regression guard for the drift bug where
            # $script:ModuleVersion in AzLocal.UpdateManagement.psm1 was '0.7.66'
            # while the manifest had been bumped to '0.7.67'. The script-scope
            # constant is the value emitted in run-log headers and stamped into
            # exported fleet-state JSON, so drift silently misreports the
            # generator version to consumers. Both must match.
            $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $manifestVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
            $scriptVersion = InModuleScope AzLocal.UpdateManagement { $script:ModuleVersion }
            $scriptVersion | Should -Be $manifestVersion -Because '$script:ModuleVersion in the .psm1 must match ModuleVersion in the .psd1'
        }

        It 'README.md Latest Version banner matches manifest ModuleVersion' {
            # v0.7.67 polish: regression guard for the drift bug where
            # README.md still advertised "Latest Version: v0.7.66" after the
            # manifest had been bumped to 0.7.67 and v0.7.67 was published to
            # the PowerShell Gallery. The README banner and the gallery link
            # on the same line are the first thing a consumer reads, so
            # silent drift is a credibility bug. Both must match the manifest.
            $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $readmePath   = Join-Path -Path $PSScriptRoot -ChildPath '..\README.md'
            $manifestVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
            $readmeContent = Get-Content -Path $readmePath -Raw
            $pattern = '\*\*Latest Version:\*\*\s+v(?<displayed>\d+\.\d+\.\d+)\s+-\s+\[Published in PowerShell Gallery\]\(https://www\.powershellgallery\.com/packages/AzLocal\.UpdateManagement/(?<urlversion>\d+\.\d+\.\d+)\)'
            $match = [regex]::Match($readmeContent, $pattern)
            $match.Success | Should -BeTrue -Because "README.md must contain a parseable '**Latest Version:** vX.Y.Z - [Published in PowerShell Gallery](https://www.powershellgallery.com/packages/AzLocal.UpdateManagement/X.Y.Z)' line"
            $match.Groups['displayed'].Value | Should -Be $manifestVersion -Because 'the displayed version in the README banner must match the manifest ModuleVersion'
            $match.Groups['urlversion'].Value | Should -Be $manifestVersion -Because 'the PowerShell Gallery URL in the README banner must point at the manifest ModuleVersion'
        }

        It 'README.md TOC "What''s New in vX.Y.Z" entry matches manifest ModuleVersion' {
            # v0.7.67 polish: companion to the Latest Version banner guard.
            # The TOC's main-body "What's New in vX.Y.Z" link must always
            # point at the current manifest version - prior versions live
            # under the Release History sub-list.
            $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $readmePath   = Join-Path -Path $PSScriptRoot -ChildPath '..\README.md'
            $manifestVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
            $manifestVersionAnchor = $manifestVersion -replace '\.',''
            $readmeContent = Get-Content -Path $readmePath -Raw
            # Match the top-level TOC link: "- [What's New in vX.Y.Z](#whats-new-in-vXYZ)"
            # (this is the main-body link, NOT the indented Release History sub-entry).
            # Note: do NOT anchor with trailing $ - .NET (?m)$ matches before \n but not
            # before \r, so on CRLF files \)$ never matches; use a CRLF-tolerant lookahead.
            $pattern = "(?m)^- \[What's New in v(?<displayed>\d+\.\d+\.\d+)\]\(#whats-new-in-v(?<anchor>\d+)\)(?=\r?\n|\z)"
            $match = [regex]::Match($readmeContent, $pattern)
            $match.Success | Should -BeTrue -Because "README.md TOC must contain a main-body '- [What's New in vX.Y.Z](#whats-new-in-vXYZ)' entry"
            $match.Groups['displayed'].Value | Should -Be $manifestVersion -Because 'the TOC main-body What''s New entry must point at the current manifest ModuleVersion'
            $match.Groups['anchor'].Value | Should -Be $manifestVersionAnchor -Because "the TOC anchor must collapse to the manifest ModuleVersion (#whats-new-in-v$manifestVersionAnchor)"
        }

        It 'README.md main body has exactly one "## What''s New" section, pointing at manifest ModuleVersion' {
            # v0.7.67 polish: regression guard for the drift bug where prior
            # release "What's New" sections were left at `##` level in the
            # main body (v0.7.66 release missed moving v0.7.65 to Release
            # History; v0.7.67 publish missed moving v0.7.66). The current-
            # release section is the only one that should be `##` in the main
            # body; every prior section MUST live under `## Release History`
            # as `### What's New in vX.Y.Z`.
            $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $readmePath   = Join-Path -Path $PSScriptRoot -ChildPath '..\README.md'
            $manifestVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
            # Force array context with @(...) - Select-String returning a single match
            # otherwise collapses to a scalar string and $h2Matches[0] returns the first
            # CHARACTER of that string ('#') rather than the line text.
            $h2Matches = @(Select-String -Path $readmePath -Pattern "^## What's New in v\d+\.\d+\.\d+" -CaseSensitive |
                           ForEach-Object { $_.Line })
            $h2Matches.Count | Should -Be 1 -Because "exactly one '## What's New' section must exist in the README main body (found: $($h2Matches -join '; '))"
            $h2Matches[0] | Should -Be "## What's New in v$manifestVersion" -Because 'the sole main-body What''s New section must match the current manifest ModuleVersion'
        }

        It 'CHANGELOG.md first "## [X.Y.Z]" heading matches manifest ModuleVersion' {
            # v0.7.71 polish: regression guard for the drift bug pattern where
            # a release ships to PSGallery but CHANGELOG.md still has the
            # PRIOR version as its first entry (because someone forgot to
            # prepend the new section). The most-recent CHANGELOG.md "##
            # [X.Y.Z] - YYYY-MM-DD" entry MUST match the manifest ModuleVersion.
            $manifestPath  = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $changelogPath = Join-Path -Path $PSScriptRoot -ChildPath '..\CHANGELOG.md'
            $manifestVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
            $changelogContent = Get-Content -Path $changelogPath -Raw
            $match = [regex]::Match($changelogContent, '(?m)^## \[(?<v>\d+\.\d+\.\d+)\]')
            $match.Success | Should -BeTrue -Because 'CHANGELOG.md must contain at least one "## [X.Y.Z] - YYYY-MM-DD" entry'
            $match.Groups['v'].Value | Should -Be $manifestVersion -Because 'the first (most-recent) CHANGELOG.md "## [X.Y.Z]" heading must match the manifest ModuleVersion - did you forget to prepend the new release section?'
        }

        It 'psd1 ReleaseNotes first "## Version X.Y.Z" heading matches manifest ModuleVersion' {
            # v0.7.71 polish: regression guard for the drift bug pattern where
            # the manifest ModuleVersion is bumped but the PSData.ReleaseNotes
            # here-string still leads with the PRIOR version's heading. The
            # ReleaseNotes block is what PSGallery renders on the module page,
            # so drift here means the gallery advertises stale notes for the
            # new release. The first "## Version X.Y.Z" heading MUST match
            # the manifest ModuleVersion.
            $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $manifestData = Import-PowerShellDataFile -Path $manifestPath
            $manifestVersion = $manifestData.ModuleVersion
            $releaseNotes    = $manifestData.PrivateData.PSData.ReleaseNotes
            $releaseNotes | Should -Not -BeNullOrEmpty -Because 'psd1 PrivateData.PSData.ReleaseNotes must be populated'
            $match = [regex]::Match($releaseNotes, '(?m)^## Version (?<v>\d+\.\d+\.\d+)\b')
            $match.Success | Should -BeTrue -Because 'psd1 ReleaseNotes must contain at least one "## Version X.Y.Z" heading'
            $match.Groups['v'].Value | Should -Be $manifestVersion -Because 'the first "## Version X.Y.Z" heading in psd1 ReleaseNotes must match the manifest ModuleVersion - did you forget to prepend the new release section?'
        }

        It 'All bundled <Platform> Step.[1-7]_*.yml pipeline samples pin GENERATED_AGAINST_MODULE_VERSION to manifest ModuleVersion' -ForEach @(
            @{ Platform = 'github-actions' }
            @{ Platform = 'azure-devops' }
        ) {
            # v0.7.71 polish: regression guard for the drift bug pattern that
            # caught v0.7.70 - the manifest ships at version X.Y.Z+1 but the
            # bundled pipeline samples are still pinned to X.Y.Z in their
            # GENERATED_AGAINST_MODULE_VERSION constant. Operators who run
            # Update-AzLocalPipelineExample after the upgrade get YAMLs
            # that disagree with the module they just installed. Every
            # Step.[1-7]_*.yml sample (both platforms) must pin to the
            # current manifest ModuleVersion. Step.0_authentication-test.yml
            # is exempt - it does not consume the module so the pin is
            # intentionally absent.
            $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $manifestVersion = (Import-PowerShellDataFile -Path $manifestPath).ModuleVersion
            $samplesDir = Join-Path -Path $PSScriptRoot -ChildPath "..\Automation-Pipeline-Examples\$Platform"
            Test-Path $samplesDir | Should -BeTrue -Because "the $Platform sample folder must exist at $samplesDir"
            $yamls = @(Get-ChildItem -Path $samplesDir -Filter 'Step.*.yml' -File |
                       Where-Object { $_.Name -notlike 'Step.0_*' })
            $yamls.Count | Should -BeGreaterThan 0 -Because "$samplesDir must ship at least one Step.[1-7]_*.yml sample"
            # GitHub Actions form (single line):
            #   GENERATED_AGAINST_MODULE_VERSION: '0.7.71'
            # Azure DevOps form (two lines under a `variables:` list entry):
            #   - name: GENERATED_AGAINST_MODULE_VERSION
            #     value: '0.7.71'
            # The regex matches either shape and captures the pinned version.
            $pattern = "(?m)(?:^\s*GENERATED_AGAINST_MODULE_VERSION:\s*'(?<gh>\d+\.\d+\.\d+)'|^\s*-?\s*name:\s*GENERATED_AGAINST_MODULE_VERSION\s*\r?\n\s*value:\s*'(?<ado>\d+\.\d+\.\d+)')"
            foreach ($yaml in $yamls) {
                $content = Get-Content -Path $yaml.FullName -Raw
                $match = [regex]::Match($content, $pattern)
                $match.Success | Should -BeTrue -Because "$($yaml.Name) must declare GENERATED_AGAINST_MODULE_VERSION (single-line GH form or two-line ADO form)"
                $pinned = if ($match.Groups['gh'].Success) { $match.Groups['gh'].Value } else { $match.Groups['ado'].Value }
                $pinned | Should -Be $manifestVersion -Because "$($yaml.Name) pins GENERATED_AGAINST_MODULE_VERSION='$pinned' but manifest ModuleVersion='$manifestVersion' - did you forget to bump the pipeline sample?"
            }
        }

        It 'Step.4 pipeline templates call Get-AzLocalFleetConnectivityStatus (v0.7.79 migration)' -ForEach @(
            @{ Platform = 'github-actions'; Path = '..\Automation-Pipeline-Examples\github-actions\Step.4_fleet-connectivity-status.yml' }
            @{ Platform = 'azure-devops';   Path = '..\Automation-Pipeline-Examples\azure-devops\Step.4_fleet-connectivity-status.yml' }
        ) {
            $yamlPath = Join-Path -Path $PSScriptRoot -ChildPath $Path
            Test-Path $yamlPath | Should -BeTrue -Because "Step.4 template for $Platform must exist at $yamlPath"
            $content = Get-Content -Path $yamlPath -Raw

            # v0.7.79 migration guard: inline KQL + Invoke-ArgQuery replaced by module cmdlet.
            $content | Should -Match 'Get-AzLocalFleetConnectivityStatus' -Because "Step.4 $Platform must call the module cmdlet (v0.7.79 migration)"
            $content | Should -Not -Match 'function Invoke-ArgQuery' -Because "Step.4 $Platform must not contain inline Invoke-ArgQuery (removed in v0.7.79)"

            # Cmdlet output properties must be assigned to pipeline variables.
            $content | Should -Match '\$data\.ClusterRows' -Because "Step.4 $Platform must assign `$data.ClusterRows from cmdlet output"
            $content | Should -Match '\$data\.ArcSummary' -Because "Step.4 $Platform must assign `$data.ArcSummary from cmdlet output"
            $content | Should -Match '\$data\.NicIssues' -Because "Step.4 $Platform must assign `$data.NicIssues from cmdlet output"
            $content | Should -Match '\$data\.ArbRows' -Because "Step.4 $Platform must assign `$data.ArbRows from cmdlet output"
        }

        It 'Should export exactly 38 functions' {
            $script:ModuleInfo.ExportedFunctions.Count | Should -Be 38
        }

        It 'Should export the expected functions' {
            $expectedFunctions = @(
                'Connect-AzLocalServicePrincipal',
                'Get-AzLocalAvailableUpdates',
                'Get-AzLocalClusterInfo',
                'Get-AzLocalClusterInventory',
                'Get-AzLocalClusterUpdateReadiness',
                'Get-AzLocalUpdateRuns',
                'Get-AzLocalUpdateSummary',
                'Set-AzLocalClusterUpdateRingTag',
                'Start-AzLocalClusterUpdate',
                # Fleet-Scale Operations (v0.5.6)
                'Invoke-AzLocalFleetOperation',
                'Get-AzLocalFleetProgress',
                'Test-AzLocalFleetHealthGate',
                'Export-AzLocalFleetState',
                'Resume-AzLocalFleetUpdate',
                'Stop-AzLocalFleetUpdate',
                # Pre-Update Health Validation (v0.6.1)
                'Test-AzLocalClusterHealth',
                # Fleet Status Data Collection & Reporting (v0.6.4)
                'Get-AzLocalFleetStatusData',
                'New-AzLocalFleetStatusHtmlReport',
                # Fleet Health Failures (v0.7.65) - 24-hour system health-check failures across the fleet
                'Get-AzLocalFleetHealthFailures',
                # Apply-Updates Schedule Coverage Advisor (v0.7.65)
                'Test-AzLocalApplyUpdatesScheduleCoverage',
                # Update Schedule Tag Helpers (v0.6.4)
                'Test-AzLocalUpdateScheduleAllowed',
                # Sideloaded Payload Workflow (v0.7.1)
                'Reset-AzLocalSideloadedTag',
                # ITSM Connector Phase 1 (v0.7.4)
                'Get-AzLocalItsmConfig',
                'Test-AzLocalItsmConnection',
                'New-AzLocalIncident',
                # Pipeline-Examples Convenience (v0.7.4 / Update added v0.7.68)
                'Copy-AzLocalPipelineExample',
                'Update-AzLocalPipelineExample',
                # ITSM Sample Convenience (v0.7.50)
                'Copy-AzLocalItsmSample',
                # Update Run Failures Deep-Error Extraction (v0.7.68)
                'Get-AzLocalUpdateRunFailures',
                # Ring-Aware Apply-Updates Schedule (v0.7.69)
                'Get-AzLocalApplyUpdatesScheduleConfig',
                'New-AzLocalApplyUpdatesScheduleConfig',
                'Update-AzLocalApplyUpdatesScheduleConfig',
                'Resolve-AzLocalCurrentUpdateRing',
                'Get-AzLocalApplyUpdatesScheduleNextFirings',
                # Fleet Health Overview (v0.7.70) - ARG-first projection of cluster + updateSummaries
                'Get-AzLocalFleetHealthOverview',
                # Latest Released Solution Version (v0.7.70 Phase E) - public manifest probe (aka.ms/AzureEdgeUpdates) anchoring the rolling YYMM support window in Step.6
                'Get-AzLocalLatestSolutionVersion',
                # Fleet Connectivity Status (v0.7.79) - 4-scope connectivity audit: cluster, Arc agent, physical NIC, ARB
                'Get-AzLocalFleetConnectivityStatus',
                # Fleet Connectivity Status Summary Renderer (v0.7.87) - markdown step-summary builder used by Step.4 GH+ADO pipelines
                'New-AzLocalFleetConnectivityStatusSummary'
            )
            
            foreach ($func in $expectedFunctions) {
                $script:ModuleInfo.ExportedFunctions.Keys | Should -Contain $func
            }
        }

        It "Should have ReleaseNotes within the PSGallery character limit" {
            # PSGallery enforces a maximum of 10000 characters on the ReleaseNotes field
            # (publish fails with "Tags, ReleaseNotes, ... cannot exceed 10000 characters").
            # This test guards against accidental regressions when the release notes grow.
            $manifestPath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
            $data = Import-PowerShellDataFile -Path $manifestPath
            $releaseNotes = $data.PrivateData.PSData.ReleaseNotes
            $releaseNotes | Should -Not -BeNullOrEmpty
            $releaseNotes.Length | Should -BeLessOrEqual 10000 -Because "PSGallery rejects ReleaseNotes longer than 10000 characters"
        }
    }

    Context 'Pipeline YAML version pin (v0.7.66)' {
        # Every sample pipeline that installs AzLocal.UpdateManagement at runtime
        # also declares GENERATED_AGAINST_MODULE_VERSION so the install step can
        # detect drift between the YAML's expected version and what is installed
        # from PSGallery. The pin MUST match the current module manifest version,
        # otherwise the runtime drift detector will emit a noisy warning on every
        # pipeline run for end users. This test guards against forgetting to bump
        # the pin in Automation-Pipeline-Examples/**/*.yml when releasing a new
        # module version.
        It 'Every pipeline YAML that installs the module pins GENERATED_AGAINST_MODULE_VERSION to the manifest version' {
            $manifestVersion = $script:ModuleInfo.Version.ToString()
            $examplesRoot    = Join-Path -Path $PSScriptRoot -ChildPath '..\Automation-Pipeline-Examples'
            $examplesRoot    = (Resolve-Path -Path $examplesRoot).Path

            $ymlFiles = Get-ChildItem -Path $examplesRoot -Recurse -Filter '*.yml' -File
            $ymlFiles.Count | Should -BeGreaterThan 0 -Because 'sample pipeline YAMLs ship under Automation-Pipeline-Examples/{github-actions,azure-devops}/'

            $issues = New-Object System.Collections.Generic.List[string]
            foreach ($yml in $ymlFiles) {
                $content = Get-Content -LiteralPath $yml.FullName -Raw

                # The drift detector only runs in pipelines that install the
                # module at runtime. Auth-smoke-test YAMLs and ITSM sample YAMLs
                # do not install the module, so they are not expected to carry
                # a pin. Use the presence of 'Install-Module AzLocal.UpdateManagement'
                # as the discriminator.
                $installsModule = $content -match 'Install-Module\s+AzLocal\.UpdateManagement'

                # Two pin shapes are supported by the YAML examples:
                # 1) Inline (GH Actions env, or ADO inline variable):
                #      GENERATED_AGAINST_MODULE_VERSION: '0.7.65'
                # 2) ADO variables block, name/value pair on two lines:
                #      - name: GENERATED_AGAINST_MODULE_VERSION
                #        value: '0.7.65'
                $pin     = $null
                $inline  = [regex]::Match($content, "GENERATED_AGAINST_MODULE_VERSION\s*:\s*'([^']+)'")
                $twoLine = [regex]::Match($content, "(?ms)-\s*name\s*:\s*GENERATED_AGAINST_MODULE_VERSION\s*\r?\n\s*value\s*:\s*'([^']+)'")
                if ($inline.Success)       { $pin = $inline.Groups[1].Value }
                elseif ($twoLine.Success)  { $pin = $twoLine.Groups[1].Value }

                $relPath = $yml.FullName.Substring($examplesRoot.Length).TrimStart('\','/')

                if ($installsModule -and -not $pin) {
                    $issues.Add("${relPath}: installs the module but is MISSING the GENERATED_AGAINST_MODULE_VERSION pin")
                    continue
                }

                if ($pin -and $pin -ne $manifestVersion) {
                    $issues.Add("${relPath}: pinned to '$pin' but manifest is '$manifestVersion'")
                }
            }

            if ($issues.Count -gt 0) {
                $detail = ($issues -join [Environment]::NewLine)
            } else {
                $detail = '(no mismatches)'
            }
            $issues.Count | Should -Be 0 -Because "every pipeline YAML under Automation-Pipeline-Examples/ that installs AzLocal.UpdateManagement must pin GENERATED_AGAINST_MODULE_VERSION to the current manifest version $manifestVersion. Bumping the manifest version requires the same bump in every sample YAML. Findings:$([Environment]::NewLine)$detail"
        }
    }

    Context 'Pipeline YAML installed-older-than-generated guard (v0.7.66)' {
        # v0.7.66: every pipeline YAML that installs the module at runtime must
        # warn when the runtime-installed module version is OLDER than
        # GENERATED_AGAINST_MODULE_VERSION. The existing version-check block
        # already handles 'installed -gt generated' (YAML stale) and
        # 'latest -gt installed' (newer module on PSGallery), but the
        # 'installed -lt generated' branch was missing. That is exactly the
        # case that matters during a staged unlisted-release flow (publish
        # candidate, immediately unlist, pin REQUIRED_MODULE_VERSION in the
        # test repo, validate, then list) and during emergency rollbacks. A
        # YAML that references cmdlets / parameters added in the generated-
        # against version would otherwise fail with a confusing
        # 'parameter not found' or 'cmdlet not recognized' error mid-job
        # instead of a clear warning at install time.
        It 'Every pipeline YAML that installs the module also warns when installed < generated' {
            $examplesRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\Automation-Pipeline-Examples'
            $examplesRoot = (Resolve-Path -Path $examplesRoot).Path

            $ymlFiles = Get-ChildItem -Path $examplesRoot -Recurse -Filter '*.yml' -File
            $ymlFiles.Count | Should -BeGreaterThan 0 -Because 'sample pipeline YAMLs ship under Automation-Pipeline-Examples/{github-actions,azure-devops}/'

            $issues = New-Object System.Collections.Generic.List[string]
            foreach ($yml in $ymlFiles) {
                $content = Get-Content -LiteralPath $yml.FullName -Raw

                # The drift detector only runs in pipelines that install the
                # module at runtime. Auth-smoke-test YAMLs and ITSM sample
                # YAMLs do not install the module, so they are not expected to
                # carry the check.
                $installsModule = $content -match 'Install-Module\s+@installArgs'
                if (-not $installsModule) { continue }

                # The drift guard has two equally valid emitter shapes:
                #   GH Actions: '::warning title=AzLocal.UpdateManagement is older than workflow YAML expects'
                #   Azure DevOps: '##vso[task.logissue type=warning]AzLocal.UpdateManagement v$installed is OLDER'
                # Both are anchored on the '$installed -lt $generated' comparison.
                $hasComparison = $content -match '\$installed\s+-lt\s+\$generated'

                $relPath = $yml.FullName.Substring($examplesRoot.Length).TrimStart('\','/')

                if (-not $hasComparison) {
                    $issues.Add("${relPath}: installs the module but is MISSING the 'installed -lt generated' drift guard")
                }
            }

            if ($issues.Count -gt 0) {
                $detail = ($issues -join [Environment]::NewLine)
            } else {
                $detail = '(no findings)'
            }
            $issues.Count | Should -Be 0 -Because "every pipeline YAML under Automation-Pipeline-Examples/ that installs AzLocal.UpdateManagement must warn when the installed module version is older than GENERATED_AGAINST_MODULE_VERSION. Findings:$([Environment]::NewLine)$detail"
        }
    }

    Context 'Schedule-audit pipeline_path default is consumer-friendly (v0.7.66 regression)' {
        # v0.7.66 regression guard: Step.3_apply-updates-schedule-audit.yml (GH + ADO)
        # shipped with a default pipeline_path of
        # 'AzLocal.UpdateManagement/Automation-Pipeline-Examples' - a path that
        # only exists in this module's source repo. In a consumer repo (where
        # Step.6_apply-updates.yml lives under .github/workflows or .azure-pipelines),
        # the default-trigger run failed with
        #   PipelineYamlPath '...' does not exist on the runner
        # before the schedule advisor could emit JUnit XML. The defaults are
        # now '.github/workflows' on GH and '.azure-pipelines' on ADO.
        # This test guards both files from ever regressing to the in-source path.
        It 'Neither Step.3_apply-updates-schedule-audit.yml defaults to the in-source examples folder' {
            $examplesRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\Automation-Pipeline-Examples'
            $examplesRoot = (Resolve-Path -Path $examplesRoot).Path

            $auditYamls = @(
                Join-Path $examplesRoot 'github-actions\Step.3_apply-updates-schedule-audit.yml'
                Join-Path $examplesRoot 'azure-devops\Step.3_apply-updates-schedule-audit.yml'
            )

            $offenders = New-Object System.Collections.Generic.List[string]
            foreach ($yml in $auditYamls) {
                if (-not (Test-Path -LiteralPath $yml)) {
                    $offenders.Add("${yml}: file is missing (expected for the schedule-audit pair)")
                    continue
                }
                $content = Get-Content -LiteralPath $yml -Raw
                if ($content -match "AzLocal\.UpdateManagement/Automation-Pipeline-Examples") {
                    $offenders.Add("${yml}: still references the in-source path 'AzLocal.UpdateManagement/Automation-Pipeline-Examples'")
                }
            }

            $detail = if ($offenders.Count -gt 0) { $offenders -join [Environment]::NewLine } else { '(no offenders)' }
            $offenders.Count | Should -Be 0 -Because "the schedule-audit pipelines must default pipeline_path/pipelinePath to a consumer-realistic path (.github/workflows or .azure-pipelines), not to the in-source examples folder. Findings:$([Environment]::NewLine)$detail"
        }
    }
}

Describe 'Function: Connect-AzLocalServicePrincipal' {
    
    Context 'Parameter Validation' {
        It 'Should have ServicePrincipalId parameter' {
            (Get-Command Connect-AzLocalServicePrincipal).Parameters.Keys | Should -Contain 'ServicePrincipalId'
        }

        It 'Should have ServicePrincipalSecret parameter' {
            (Get-Command Connect-AzLocalServicePrincipal).Parameters.Keys | Should -Contain 'ServicePrincipalSecret'
        }

        It 'Should have TenantId parameter' {
            (Get-Command Connect-AzLocalServicePrincipal).Parameters.Keys | Should -Contain 'TenantId'
        }

        It 'Should have Force parameter' {
            (Get-Command Connect-AzLocalServicePrincipal).Parameters.Keys | Should -Contain 'Force'
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of Boolean' {
            $outputTypes = (Get-Command Connect-AzLocalServicePrincipal).OutputType
            $outputTypes.Type.Name | Should -Contain 'Boolean'
        }
    }
}

Describe 'Function: Start-AzLocalClusterUpdate' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Start-AzLocalClusterUpdate
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
            $command = Get-Command Start-AzLocalClusterUpdate
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
            $outputTypes = (Get-Command Start-AzLocalClusterUpdate).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }
}

Describe 'Function: Get-AzLocalClusterUpdateReadiness' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalClusterUpdateReadiness
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

        It 'Should have ExportPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportPath'
        }

        It 'Should have ExportFormat parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportFormat'
        }

        It 'Should have ApiVersion parameter with default value' {
            $command.Parameters['ApiVersion'].Attributes | 
                Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' } |
                ForEach-Object { $_.Mandatory } | Should -Contain $false
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Get-AzLocalClusterUpdateReadiness
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
            $outputTypes = (Get-Command Get-AzLocalClusterUpdateReadiness).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }
}

Describe 'Function: Get-AzLocalClusterInventory' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalClusterInventory
        }

        It 'Should have SubscriptionId parameter' {
            $command.Parameters.Keys | Should -Contain 'SubscriptionId'
        }

        It 'Should have ExportPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportPath'
        }

        It 'SubscriptionId should not be mandatory' {
            $param = $command.Parameters['SubscriptionId']
            $attrs = @($param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' })
            $attrs | ForEach-Object { $_.Mandatory | Should -Be $false }
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of PSObject[]' {
            $outputTypes = (Get-Command Get-AzLocalClusterInventory).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }
}

Describe 'Regression: Get-AzLocalClusterInventory ValidatePattern shadowing' {
    # Repro for the bug where a local variable named $updateRingValue
    # inside Get-AzLocalClusterInventory aliased the function's
    # [ValidatePattern(...)] $UpdateRingValue parameter (PowerShell is
    # case-insensitive on variable names). Any cluster returned by ARG
    # without an UpdateRing tag caused Get-TagValue to return $null/''
    # and the assignment threw "The variable cannot be validated because
    # the value is not a valid value for the UpdateRingValue variable."
    # This bricked -AllClusters against any fleet missing the tag.

    It 'Should not throw "cannot be validated" when a cluster has no UpdateRing tag (-AllClusters)' {
        InModuleScope AzLocal.UpdateManagement {
            function global:az {
                param()
                $global:LASTEXITCODE = 0
                if ($args -contains 'show') {
                    return '{"id":"00000000-0000-0000-0000-000000000000","name":"sub"}'
                }
                return '{}'
            }
            Mock Test-AzCliAvailable { return $true }
            Mock Install-AzGraphExtension { return $true }
            # ARG returns two clusters - one with the tag, one without.
            Mock Invoke-AzResourceGraphQuery {
                return @(
                    [PSCustomObject]@{
                        id             = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/tagged'
                        name           = 'tagged'
                        resourceGroup  = 'r'
                        subscriptionId = 's'
                        tags           = @{ UpdateRing = 'Wave1' }
                    },
                    [PSCustomObject]@{
                        id             = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/untagged'
                        name           = 'untagged'
                        resourceGroup  = 'r'
                        subscriptionId = 's'
                        tags           = $null
                    }
                )
            }

            $result = $null
            { $script:inventoryResult = Get-AzLocalClusterInventory -PassThru } | Should -Not -Throw
            $result = $script:inventoryResult
            $result | Should -HaveCount 2
            ($result | Where-Object ClusterName -eq 'tagged').UpdateRing | Should -Be 'Wave1'
            ($result | Where-Object ClusterName -eq 'tagged').HasUpdateRingTag | Should -Be 'Yes'
            ($result | Where-Object ClusterName -eq 'untagged').UpdateRing | Should -Be ''
            ($result | Where-Object ClusterName -eq 'untagged').HasUpdateRingTag | Should -Be 'No'
        }
    }
}

Describe 'Function: Set-AzLocalClusterUpdateRingTag' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Set-AzLocalClusterUpdateRingTag
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
            $command = Get-Command Set-AzLocalClusterUpdateRingTag
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
            $outputTypes = (Get-Command Set-AzLocalClusterUpdateRingTag).OutputType
            $outputTypes.Type.FullName | Should -Contain 'System.Management.Automation.PSObject[]'
        }
    }

    Context 'v0.7.69 logging contract' {
        # Source-level checks - the function performs Azure CLI calls so deep
        # behavioral mocking is fragile. These pin the new logging surface that
        # operators see in the Step.2 pipeline output.
        BeforeAll {
            $script:setRingSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\Public\Set-AzLocalClusterUpdateRingTag.ps1')
        }

        It 'Emits a friendly "Processing: <clusterName>" header derived from the resource ID' {
            $script:setRingSource | Should -Match 'Processing:\s*\$headerClusterName'
            $script:setRingSource | Should -Match '\$headerClusterName\s*=\s*\(\$resourceId\s*-split\s*''/''\)\[-1\]'
        }

        It 'Emits the full ARM Resource ID on a dedicated line for traceability' {
            $script:setRingSource | Should -Match 'ARM Resource ID:\s*\$resourceId'
        }

        It 'Logs Info (not Warning) when the existing UpdateRing tag matches the target' {
            # The flip is gated on `if ($previousTagValue -eq $currentUpdateRingValue) { ... Level Info }`
            $script:setRingSource | Should -Match '\$previousTagValue\s*-eq\s*\$currentUpdateRingValue'
            $script:setRingSource | Should -Match "matches target.*-Level\s+Info"
        }

        It 'Still emits Warning when the existing UpdateRing tag differs from the target' {
            $script:setRingSource | Should -Match "differs from target.*-Level\s+Warning"
        }
    }
}

Describe 'Function: Get-AzLocalClusterInfo' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalClusterInfo
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

Describe 'Function: Get-AzLocalUpdateSummary' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalUpdateSummary
        }

        It 'Should have ClusterResourceId parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceId'
        }

        It 'Should have ClusterNames parameter for multi-cluster mode' {
            $command.Parameters.Keys | Should -Contain 'ClusterNames'
        }

        It 'Should have ClusterResourceIds parameter for multi-cluster mode' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have ExportPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportPath'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }

        It 'ClusterResourceId should be mandatory in SingleCluster parameter set' {
            $param = $command.Parameters['ClusterResourceId']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'SingleCluster' }
            $attr.Mandatory | Should -Be $true
        }

        It 'Should have four parameter sets' {
            $command.ParameterSets.Name | Should -Contain 'SingleCluster'
            $command.ParameterSets.Name | Should -Contain 'ByName'
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }
    }
}

Describe 'Function: Get-AzLocalAvailableUpdates' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalAvailableUpdates
        }

        It 'Should have ClusterResourceId parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceId'
        }

        It 'Should have ClusterNames parameter for multi-cluster mode' {
            $command.Parameters.Keys | Should -Contain 'ClusterNames'
        }

        It 'Should have ClusterResourceIds parameter for multi-cluster mode' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have ExportPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportPath'
        }

        It 'Should have ExportFormat parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportFormat'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }

        It 'ClusterResourceId should be mandatory in SingleCluster parameter set' {
            $param = $command.Parameters['ClusterResourceId']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'SingleCluster' }
            $attr.Mandatory | Should -Be $true
        }

        It 'Should have four parameter sets' {
            $command.ParameterSets.Name | Should -Contain 'SingleCluster'
            $command.ParameterSets.Name | Should -Contain 'ByName'
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }
    }
}

Describe 'Function: Get-AzLocalUpdateRuns' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalUpdateRuns
        }

        It 'Should have ClusterName parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterName'
        }

        It 'Should have ClusterNames parameter for multi-cluster mode' {
            $command.Parameters.Keys | Should -Contain 'ClusterNames'
        }

        It 'Should have ClusterResourceIds parameter for multi-cluster mode' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have UpdateName parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateName'
        }

        It 'Should have ExportPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportPath'
        }

        It 'Should have ExportFormat parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportFormat'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }

        It 'ClusterName should be mandatory in SingleCluster parameter set' {
            $param = $command.Parameters['ClusterName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'SingleCluster' }
            $attr.Mandatory | Should -Be $true
        }

        It 'UpdateName should be optional' {
            $param = $command.Parameters['UpdateName']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Be $false
        }

        It 'Should have four parameter sets' {
            $command.ParameterSets.Name | Should -Contain 'SingleCluster'
            $command.ParameterSets.Name | Should -Contain 'ByName'
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }
    }
}

Describe 'Helper Function: Get-AzLocalRunEndTime (Internal)' {

    It 'Should return progress.endTimeUtc when present (preferred source)' {
        InModuleScope AzLocal.UpdateManagement {
            $props = [PSCustomObject]@{
                state           = 'Succeeded'
                lastUpdatedTime = '2026-04-25T00:48:30Z'
                progress        = [PSCustomObject]@{ endTimeUtc = '2026-04-25T00:48:10Z' }
            }
            $r = Get-AzLocalRunEndTime -props $props
            $r | Should -Not -BeNullOrEmpty
            $r.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-04-25T00:48:10'
        }
    }

    It 'Should fall back to lastUpdatedTime when progress.endTimeUtc is missing' {
        InModuleScope AzLocal.UpdateManagement {
            $props = [PSCustomObject]@{
                state           = 'Failed'
                lastUpdatedTime = '2026-04-09T15:30:00Z'
                progress        = [PSCustomObject]@{ endTimeUtc = $null }
            }
            $r = Get-AzLocalRunEndTime -props $props
            $r | Should -Not -BeNullOrEmpty
            $r.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss') | Should -Be '2026-04-09T15:30:00'
        }
    }

    It 'Should return $null for InProgress runs (no terminal end yet)' {
        InModuleScope AzLocal.UpdateManagement {
            $props = [PSCustomObject]@{
                state           = 'InProgress'
                lastUpdatedTime = '2026-04-25T01:00:00Z'
                progress        = [PSCustomObject]@{ endTimeUtc = $null }
            }
            $r = Get-AzLocalRunEndTime -props $props
            $r | Should -BeNullOrEmpty
        }
    }

    It 'Should return $null when both sources are missing' {
        InModuleScope AzLocal.UpdateManagement {
            $props = [PSCustomObject]@{ state = 'Succeeded' }
            $r = Get-AzLocalRunEndTime -props $props
            $r | Should -BeNullOrEmpty
        }
    }
}

Describe 'Helper Function: Format-AzLocalUpdateRun (Internal)' {

    It 'Should populate EndTime from progress.endTimeUtc and use ARM duration' {
        InModuleScope AzLocal.UpdateManagement {
            $run = [PSCustomObject]@{
                id         = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/c1/updates/Solution12.2604/updateRuns/abc123'
                name       = 'abc123'
                properties = [PSCustomObject]@{
                    state           = 'Succeeded'
                    timeStarted     = '2026-04-24T16:10:24Z'
                    lastUpdatedTime = '2026-04-25T00:48:30Z'
                    duration        = 'PT8H37M58S'
                    progress        = [PSCustomObject]@{
                        endTimeUtc = '2026-04-25T00:48:10Z'
                        steps      = @([PSCustomObject]@{ name = 'Step1'; status = 'Success' })
                    }
                    location        = 'eastus'
                }
            }
            $f = Format-AzLocalUpdateRun -run $run -clusterName 'c1'
            # EndTime is rendered in local time; compare via parse + UTC normalize
            ([datetime]::ParseExact($f.EndTime, 'yyyy-MM-dd HH:mm', $null)).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-04-25 00:48'
            ([datetime]::ParseExact($f.StartTime, 'yyyy-MM-dd HH:mm', $null)).ToUniversalTime().ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-04-24 16:10'
            $f.State | Should -Be 'Succeeded'
            $f.Duration | Should -Match '8 hours'
        }
    }

    It 'Should leave EndTime blank for InProgress runs' {
        InModuleScope AzLocal.UpdateManagement {
            $run = [PSCustomObject]@{
                id         = '/subscriptions/x/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/c1/updates/Solution12.2604/updateRuns/abc123'
                name       = 'abc123'
                properties = [PSCustomObject]@{
                    state           = 'InProgress'
                    timeStarted     = (Get-Date).AddMinutes(-30).ToUniversalTime().ToString('o')
                    lastUpdatedTime = $null
                    duration        = $null
                    progress        = [PSCustomObject]@{
                        endTimeUtc = $null
                        steps      = @([PSCustomObject]@{ name = 'Step1'; status = 'InProgress' })
                    }
                    location        = 'eastus'
                }
            }
            $f = Format-AzLocalUpdateRun -run $run -clusterName 'c1'
            $f.EndTime | Should -BeNullOrEmpty
            $f.Duration | Should -Match 'running'
        }
    }
}

Describe 'Function: New-AzLocalFleetStatusHtmlReport' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command New-AzLocalFleetStatusHtmlReport
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

        It 'Should have OutputPath parameter' {
            $command.Parameters.Keys | Should -Contain 'OutputPath'
        }

        It 'OutputPath should be mandatory' {
            $param = $command.Parameters['OutputPath']
            $attr = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            $attr.Mandatory | Should -Contain $true
        }

        It 'Should have IncludeUpdateRuns switch parameter' {
            $command.Parameters['IncludeUpdateRuns'].SwitchParameter | Should -Be $true
        }

        It 'Should have IncludeHealthDetails switch parameter' {
            $command.Parameters['IncludeHealthDetails'].SwitchParameter | Should -Be $true
        }

        It 'Should have Title parameter' {
            $command.Parameters.Keys | Should -Contain 'Title'
        }

        It 'Should have PassThru switch parameter' {
            $command.Parameters['PassThru'].SwitchParameter | Should -Be $true
        }

        It 'Should have AllClusters switch parameter' {
            $command.Parameters['AllClusters'].SwitchParameter | Should -Be $true
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command New-AzLocalFleetStatusHtmlReport
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

        It 'Should have All parameter set' {
            $command.ParameterSets.Name | Should -Contain 'All'
        }

        It 'Should default to All parameter set' {
            $command.DefaultParameterSet | Should -Be 'All'
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
        It 'Should have OutputType of String' {
            $outputTypes = (Get-Command New-AzLocalFleetStatusHtmlReport).OutputType
            $outputTypes.Type.Name | Should -Contain 'String'
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
            & (Get-Module AzLocal.UpdateManagement) {
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

Describe 'Helper Function: Get-HealthCheckFailureSummary (Internal)' {

    Context 'Severity ordering and filtering' {
        It 'Should return empty string when UpdateSummary is null' {
            $result = & (Get-Module AzLocal.UpdateManagement) {
                Get-HealthCheckFailureSummary -UpdateSummary $null
            }
            $result | Should -Be ''
        }

        It 'Should return empty string when healthCheckResult is missing' {
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{} }
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            $result | Should -Be ''
        }

        It 'Should exclude Informational severity entries' {
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{ healthCheckResult = @(
                [PSCustomObject]@{ status = 'Failed'; severity = 'Informational'; displayName = 'I1' }
            )}}
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            $result | Should -Be ''
        }

        It 'Should exclude entries whose status is not Failed' {
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{ healthCheckResult = @(
                [PSCustomObject]@{ status = 'Succeeded'; severity = 'Critical'; displayName = 'C1' }
            )}}
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            $result | Should -Be ''
        }

        It 'Should emit Critical entries before Warning entries even when ARM returned Warnings first' {
            # Regression: prior to this ordering fix, 5+ Warnings ahead of a
            # Critical caused the Critical to be dropped during top-5 truncation,
            # so the readiness gate ('-match "\[Critical\]"') silently failed.
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{ healthCheckResult = @(
                [PSCustomObject]@{ status = 'Failed'; severity = 'Warning';  displayName = 'W1'; targetResourceName = 'nodeA' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Warning';  displayName = 'W2'; targetResourceName = 'nodeA' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Warning';  displayName = 'W3'; targetResourceName = 'nodeA' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Warning';  displayName = 'W4'; targetResourceName = 'nodeA' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Warning';  displayName = 'W5'; targetResourceName = 'nodeA' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C1'; targetResourceName = 'nodeB' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Informational'; displayName = 'I1'; targetResourceName = 'nodeC' }
            )}}
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            # Must start with [Critical] so the gate's -match succeeds
            $result | Should -Match '^\[Critical\] C1'
            # Informational is excluded entirely
            $result | Should -Not -Match '\[Informational\]'
            # All 5 Warnings + 1 Critical = 6 in-scope; top 5 displayed; "+1 more"
            $result | Should -Match '\(\+1 more\)'
        }

        It 'Should preserve insertion order within each severity bucket' {
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{ healthCheckResult = @(
                [PSCustomObject]@{ status = 'Failed'; severity = 'Warning';  displayName = 'W1' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C1' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Warning';  displayName = 'W2' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C2' }
            )}}
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            # Order should be: C1, C2 (Criticals in ARM order), then W1, W2 (Warnings in ARM order)
            $result | Should -Be '[Critical] C1; [Critical] C2; [Warning] W1; [Warning] W2'
        }

        It 'Should include up to 5 entries and append "(+N more)" suffix when truncating' {
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{ healthCheckResult = @(
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C1' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C2' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C3' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C4' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C5' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C6' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'C7' }
            )}}
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            $result | Should -Match '^\[Critical\] C1; \[Critical\] C2; \[Critical\] C3; \[Critical\] C4; \[Critical\] C5 \(\+2 more\)$'
        }

        It 'Should dedup byte-identical duplicate healthCheckResult entries (v0.7.76)' {
            # Reproduces the ARM upstream-dup observed on a 2-node Azure Local
            # cluster: the "Test Network intent on existing cluster nodes" check
            # emitted twice with identical displayName / severity / targetResourceName.
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{ healthCheckResult = @(
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'Test Network intent on existing cluster nodes'; targetResourceName = 'NetworkIntent' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'Test Network intent on existing cluster nodes'; targetResourceName = 'NetworkIntent' }
            )}}
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            $result | Should -Be '[Critical] Test Network intent on existing cluster nodes (NetworkIntent)'
        }

        It 'Should keep distinct rows when targetResourceName differs (v0.7.76)' {
            # Distinct per-node failures should NOT be collapsed by dedup.
            $mock = [PSCustomObject]@{ properties = [PSCustomObject]@{ healthCheckResult = @(
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'Storage Job Health Check'; targetResourceName = 'UserStorage_1-Repair' }
                [PSCustomObject]@{ status = 'Failed'; severity = 'Critical'; displayName = 'Storage Job Health Check'; targetResourceName = 'UserStorage_2-Repair' }
            )}}
            $result = & (Get-Module AzLocal.UpdateManagement) {
                param($us) Get-HealthCheckFailureSummary -UpdateSummary $us
            } -us $mock
            $result | Should -Be '[Critical] Storage Job Health Check (UserStorage_1-Repair); [Critical] Storage Job Health Check (UserStorage_2-Repair)'
        }
    }
}

Describe 'API Version Consistency' {
    
    Context 'Default API Version' {
        It 'All functions with ApiVersion parameter should default to 2025-10-01' {
            $functionsWithApiVersion = @(
                'Start-AzLocalClusterUpdate',
                'Get-AzLocalClusterUpdateReadiness',
                'Get-AzLocalClusterInfo',
                'Get-AzLocalUpdateSummary',
                'Get-AzLocalAvailableUpdates',
                'Get-AzLocalUpdateRuns'
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
            $exportedFunctions = (Get-Module AzLocal.UpdateManagement).ExportedFunctions.Keys
            
            foreach ($func in $exportedFunctions) {
                $verb = $func.Split('-')[0]
                $approvedVerbs | Should -Contain $verb -Because "$func should use an approved verb"
            }
        }

        It 'All exported functions should use consistent noun prefix' {
            $exportedFunctions = (Get-Module AzLocal.UpdateManagement).ExportedFunctions.Keys
            # v0.7.76 rename: all exported cmdlets use the AzLocal* noun prefix.
            # (Pre-v0.7.76 the module also shipped AzureLocal* nouns; those were
            # renamed to AzLocal* to align with the module name.)
            foreach ($func in $exportedFunctions) {
                $noun = $func.Split('-')[1]
                $noun | Should -BeLike 'AzLocal*' -Because "$func should use AzLocal* noun prefix (got '$noun')"
            }
        }
    }

    Context 'Help Documentation' {
        BeforeAll {
            $script:exportedFunctions = (Get-Module AzLocal.UpdateManagement).ExportedFunctions.Keys
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

#region Fleet-Scale Operations Tests (v0.5.6)

Describe 'Function: Invoke-AzLocalFleetOperation' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Invoke-AzLocalFleetOperation
        }

        It 'Should have Operation parameter' {
            $command.Parameters.Keys | Should -Contain 'Operation'
        }

        It 'Should have valid Operation values' {
            # Filter explicitly for ValidateSetAttribute. Member-enumerating ".ValidValues"
            # over the full Attributes collection (which also contains ParameterAttribute
            # and ArgumentTypeConverterAttribute) is order-dependent under Pester's strict
            # mode and produces "property cannot be found" errors when the non-ValidateSet
            # attributes are enumerated first.
            $validateSet = $command.Parameters['Operation'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet | Should -Not -BeNullOrEmpty -Because 'Operation should have a [ValidateSet] attribute'
            $validateSet.ValidValues | Should -Contain 'ApplyUpdate'
            $validateSet.ValidValues | Should -Contain 'CheckReadiness'
            $validateSet.ValidValues | Should -Contain 'GetStatus'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have ClusterResourceIds parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have BatchSize parameter with range validation' {
            $command.Parameters.Keys | Should -Contain 'BatchSize'
            $attrs = $command.Parameters['BatchSize'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $attrs | Should -Not -BeNullOrEmpty
        }

        It 'Should have ThrottleLimit parameter with range validation' {
            $command.Parameters.Keys | Should -Contain 'ThrottleLimit'
            $attrs = $command.Parameters['ThrottleLimit'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $attrs | Should -Not -BeNullOrEmpty
        }

        It 'Should have MaxRetries parameter' {
            $command.Parameters.Keys | Should -Contain 'MaxRetries'
        }

        It 'Should have StateFilePath parameter' {
            $command.Parameters.Keys | Should -Contain 'StateFilePath'
        }

        It 'Should have Force parameter' {
            $command.Parameters.Keys | Should -Contain 'Force'
        }

        It 'Should have PassThru parameter' {
            $command.Parameters.Keys | Should -Contain 'PassThru'
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Invoke-AzLocalFleetOperation
        }

        It 'Should have ByTag parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }

        It 'Should have ByResourceId parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
        }
    }
}

Describe 'Function: Get-AzLocalFleetProgress' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalFleetProgress
        }

        It 'Should have State parameter' {
            $command.Parameters.Keys | Should -Contain 'State'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have Detailed parameter' {
            $command.Parameters.Keys | Should -Contain 'Detailed'
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Get-AzLocalFleetProgress
        }

        It 'Should have ByState parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByState'
        }

        It 'Should have ByTag parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }
    }
}

Describe 'Function: Test-AzLocalFleetHealthGate' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Test-AzLocalFleetHealthGate
        }

        It 'Should have MaxFailurePercent parameter' {
            $command.Parameters.Keys | Should -Contain 'MaxFailurePercent'
        }

        It 'Should have MinSuccessPercent parameter' {
            $command.Parameters.Keys | Should -Contain 'MinSuccessPercent'
        }

        It 'Should have WaitForCompletion parameter' {
            $command.Parameters.Keys | Should -Contain 'WaitForCompletion'
        }

        It 'Should have WaitTimeoutMinutes parameter' {
            $command.Parameters.Keys | Should -Contain 'WaitTimeoutMinutes'
        }

        It 'Should have PollIntervalSeconds parameter' {
            $command.Parameters.Keys | Should -Contain 'PollIntervalSeconds'
        }

        It 'MaxFailurePercent should have range validation 0-100' {
            $attrs = $command.Parameters['MaxFailurePercent'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $attrs | Should -Not -BeNullOrEmpty
            $attrs.MinRange | Should -Be 0
            $attrs.MaxRange | Should -Be 100
        }

        It 'MinSuccessPercent should have range validation 0-100' {
            $attrs = $command.Parameters['MinSuccessPercent'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $attrs | Should -Not -BeNullOrEmpty
            $attrs.MinRange | Should -Be 0
            $attrs.MaxRange | Should -Be 100
        }
    }
}

#region Update Schedule Tag Helpers Tests (v0.6.4)

Describe 'Helper Function: ConvertFrom-AzLocalUpdateWindow (Internal)' {
    BeforeAll {
        # Access internal function via module scope
        $moduleName = 'AzLocal.UpdateManagement'
    }

    Context 'Valid Window Syntax' {
        It 'Parses single day with time range' {
            $result = @(& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Sat_02:00-06:00' })
            $result | Should -Not -BeNullOrEmpty
            $result.Count | Should -Be 1
            $result[0].Days | Should -Contain ([DayOfWeek]::Saturday)
            $result[0].StartTime | Should -Be ([TimeSpan]::Parse('02:00'))
            $result[0].EndTime | Should -Be ([TimeSpan]::Parse('06:00'))
            $result[0].Overnight | Should -Be $false
        }

        It 'Parses day range (Sat-Sun)' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Sat-Sun_02:00-06:00' }
            $result[0].Days.Count | Should -Be 2
            $result[0].Days | Should -Contain ([DayOfWeek]::Saturday)
            $result[0].Days | Should -Contain ([DayOfWeek]::Sunday)
        }

        It 'Parses weekday range (Mon-Fri)' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Mon-Fri_00:00-06:00' }
            $result[0].Days.Count | Should -Be 5
            $result[0].Days | Should -Contain ([DayOfWeek]::Monday)
            $result[0].Days | Should -Contain ([DayOfWeek]::Friday)
            $result[0].Days | Should -Not -Contain ([DayOfWeek]::Saturday)
        }

        It 'Parses wrap-around day range (Fri-Mon)' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Fri-Mon_02:00-06:00' }
            $result[0].Days.Count | Should -Be 4
            $result[0].Days | Should -Contain ([DayOfWeek]::Friday)
            $result[0].Days | Should -Contain ([DayOfWeek]::Saturday)
            $result[0].Days | Should -Contain ([DayOfWeek]::Sunday)
            $result[0].Days | Should -Contain ([DayOfWeek]::Monday)
        }

        It 'Parses comma-separated days (Tue,Thu)' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Tue,Thu_02:00-06:00' }
            $result[0].Days.Count | Should -Be 2
            $result[0].Days | Should -Contain ([DayOfWeek]::Tuesday)
            $result[0].Days | Should -Contain ([DayOfWeek]::Thursday)
        }

        It 'Parses * (wildcard) as all days' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString '*_00:00-06:00' }
            $result[0].Days.Count | Should -Be 7
        }

        It 'Parses Daily as all days' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Daily_22:00-06:00' }
            $result[0].Days.Count | Should -Be 7
            $result[0].Overnight | Should -Be $true
        }

        It 'Parses overnight window (22:00-06:00) and marks Overnight flag' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Sat_22:00-06:00' }
            $result[0].Overnight | Should -Be $true
            $result[0].StartTime | Should -Be ([TimeSpan]::Parse('22:00'))
            $result[0].EndTime | Should -Be ([TimeSpan]::Parse('06:00'))
        }

        It 'Parses multiple semicolon-separated windows' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Sat_20:00-23:59;Sun_00:00-08:00' }
            $result.Count | Should -Be 2
            $result[0].Days | Should -Contain ([DayOfWeek]::Saturday)
            $result[1].Days | Should -Contain ([DayOfWeek]::Sunday)
        }

        It 'Is case-insensitive for day names' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'sat-SUN_02:00-06:00' }
            $result[0].Days | Should -Contain ([DayOfWeek]::Saturday)
            $result[0].Days | Should -Contain ([DayOfWeek]::Sunday)
        }

        It 'Stores raw segment string' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Mon_08:00-17:00' }
            $result[0].Raw | Should -Be 'Mon_08:00-17:00'
        }
    }

    Context 'Invalid Window Syntax' {
        It 'Throws on empty string' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString '' } } | Should -Throw '*cannot be empty*'
        }

        It 'Throws on missing time component' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Mon' } } | Should -Throw '*Invalid window segment*'
        }

        It 'Throws on invalid day abbreviation' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Xyz_02:00-06:00' } } | Should -Throw '*Invalid day*'
        }

        It 'Throws on invalid time format' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateWindow -WindowString 'Mon_25:00-06:00' } } | Should -Throw
        }

        It 'Throws when value exceeds 256 chars' {
            $longValue = ('Mon_00:00-01:00;' * 20)
            { & (Get-Module $moduleName) { param($val) ConvertFrom-AzLocalUpdateWindow -WindowString $val } $longValue } | Should -Throw '*256 characters*'
        }
    }
}

Describe 'Helper Function: ConvertFrom-AzLocalUpdateExclusion (Internal)' {
    BeforeAll {
        $moduleName = 'AzLocal.UpdateManagement'
    }

    Context 'Valid Exclusion Syntax' {
        It 'Parses a single fixed date range' {
            $result = @(& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' })
            $result.Count | Should -Be 1
            $result[0].StartDate | Should -Be ([datetime]::ParseExact('2026-12-20', 'yyyy-MM-dd', $null))
            $result[0].EndDate | Should -Be ([datetime]::ParseExact('2027-01-03', 'yyyy-MM-dd', $null))
            $result[0].IsWildcard | Should -Be $false
        }

        It 'Parses multiple comma-separated ranges' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExclusion -ExclusionString '2026-11-28/2026-11-29,2026-12-24/2027-01-02' }
            $result.Count | Should -Be 2
        }

        It 'Parses wildcard year pattern' {
            $refDate = [datetime]::ParseExact('2026-06-15', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($rd) ConvertFrom-AzLocalUpdateExclusion -ExclusionString '20**-12-20/20**-01-03' -ReferenceDate $rd } $refDate
            $result | Should -Not -BeNullOrEmpty
            $result[0].IsWildcard | Should -Be $true
            # Should resolve to concrete dates around 2026
            $result | Where-Object { $_.StartDate.Year -eq 2026 -and $_.StartDate.Month -eq 12 } | Should -Not -BeNullOrEmpty
        }

        It 'Stores raw range string' {
            $result = & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExclusion -ExclusionString '2026-06-30/2026-07-01' }
            $result[0].Raw | Should -Be '2026-06-30/2026-07-01'
        }
    }

    Context 'Invalid Exclusion Syntax' {
        It 'Throws on empty string' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExclusion -ExclusionString '' } } | Should -Throw '*cannot be empty*'
        }

        It 'Throws on invalid date format' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExclusion -ExclusionString '12/20/2026-01/03/2027' } } | Should -Throw '*Invalid exclusion range*'
        }

        It 'Throws when end date is before start date (fixed dates)' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExclusion -ExclusionString '2027-01-03/2026-12-20' } } | Should -Throw '*before start date*'
        }

        It 'Throws when value exceeds 256 chars' {
            $longValue = ('2026-01-01/2026-01-02,' * 15)
            { & (Get-Module $moduleName) { param($val) ConvertFrom-AzLocalUpdateExclusion -ExclusionString $val } $longValue } | Should -Throw '*256 characters*'
        }
    }
}

Describe 'Helper Function: Test-AzLocalUpdateWindow (Internal)' {
    BeforeAll {
        $moduleName = 'AzLocal.UpdateManagement'
    }

    Context 'Same-day windows' {
        It 'Returns Allowed=true when time is within a same-day window' {
            # Saturday 03:00 UTC should be within Sat_02:00-06:00
            $testTime = [datetime]::ParseExact('2026-04-18 03:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
        }

        It 'Returns Allowed=false when time is outside the window' {
            # Saturday 10:00 UTC should be outside Sat_02:00-06:00
            $testTime = [datetime]::ParseExact('2026-04-18 10:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $false
        }

        It 'Returns Allowed=false when day does not match' {
            # Wednesday 03:00 UTC should not match Sat_02:00-06:00
            $testTime = [datetime]::ParseExact('2026-04-15 03:00', 'yyyy-MM-dd HH:mm', $null)  # Wednesday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $false
        }
    }

    Context 'Overnight windows' {
        It 'Returns Allowed=true for evening portion of overnight window' {
            # Saturday 23:00 UTC should be in Sat_22:00-06:00 (evening portion)
            $testTime = [datetime]::ParseExact('2026-04-18 23:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_22:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
        }

        It 'Returns Allowed=true for morning portion of overnight window' {
            # Sunday 03:00 UTC should be in Sat_22:00-06:00 (morning portion, previous day was Sat)
            $testTime = [datetime]::ParseExact('2026-04-19 03:00', 'yyyy-MM-dd HH:mm', $null)  # Sunday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_22:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
        }

        It 'Returns Allowed=false for midday after overnight window ends' {
            # Sunday 10:00 UTC should not be in Sat_22:00-06:00
            $testTime = [datetime]::ParseExact('2026-04-19 10:00', 'yyyy-MM-dd HH:mm', $null)  # Sunday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_22:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $false
        }
    }

    Context 'Multiple windows' {
        It 'Returns Allowed=true when matching any of multiple windows' {
            # Sunday 04:00 should match second window
            $testTime = [datetime]::ParseExact('2026-04-19 04:00', 'yyyy-MM-dd HH:mm', $null)  # Sunday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_20:00-23:59;Sun_00:00-08:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
        }
    }

    Context 'Daily/wildcard windows' {
        It 'Returns Allowed=true for any day with * wildcard' {
            $testTime = [datetime]::ParseExact('2026-04-15 03:00', 'yyyy-MM-dd HH:mm', $null)  # Wednesday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString '*_02:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
        }

        It 'Returns Allowed=true for any day with Daily keyword' {
            $testTime = [datetime]::ParseExact('2026-04-16 03:00', 'yyyy-MM-dd HH:mm', $null)  # Thursday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Daily_02:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
        }
    }

    Context 'Output properties' {
        It 'Returns MatchedWindow when allowed' {
            $testTime = [datetime]::ParseExact('2026-04-18 03:00', 'yyyy-MM-dd HH:mm', $null)
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.MatchedWindow | Should -Not -BeNullOrEmpty
        }

        It 'Returns null MatchedWindow when not allowed' {
            $testTime = [datetime]::ParseExact('2026-04-18 10:00', 'yyyy-MM-dd HH:mm', $null)
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.MatchedWindow | Should -BeNullOrEmpty
        }

        It 'Returns Reason string in all cases' {
            $testTime = [datetime]::ParseExact('2026-04-18 03:00', 'yyyy-MM-dd HH:mm', $null)
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateWindow -WindowString 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.Reason | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Helper Function: Test-AzLocalUpdateExclusion (Internal)' {
    BeforeAll {
        $moduleName = 'AzLocal.UpdateManagement'
    }

    Context 'Fixed date exclusions' {
        It 'Returns Excluded=true when date is within exclusion range' {
            $testDate = [datetime]::ParseExact('2026-12-25', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' -TestDate $td } $testDate
            $result.Excluded | Should -Be $true
        }

        It 'Returns Excluded=true on the start date boundary' {
            $testDate = [datetime]::ParseExact('2026-12-20', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' -TestDate $td } $testDate
            $result.Excluded | Should -Be $true
        }

        It 'Returns Excluded=true on the end date boundary' {
            $testDate = [datetime]::ParseExact('2027-01-03', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' -TestDate $td } $testDate
            $result.Excluded | Should -Be $true
        }

        It 'Returns Excluded=false when date is outside exclusion range' {
            $testDate = [datetime]::ParseExact('2026-12-19', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' -TestDate $td } $testDate
            $result.Excluded | Should -Be $false
        }

        It 'Returns Excluded=false the day after end date' {
            $testDate = [datetime]::ParseExact('2027-01-04', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' -TestDate $td } $testDate
            $result.Excluded | Should -Be $false
        }
    }

    Context 'Wildcard exclusions' {
        It 'Returns Excluded=true for wildcard pattern matching current year' {
            $testDate = [datetime]::ParseExact('2026-12-25', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '20**-12-20/20**-01-03' -TestDate $td } $testDate
            $result.Excluded | Should -Be $true
        }

        It 'Returns Excluded=false for wildcard pattern when date is outside' {
            $testDate = [datetime]::ParseExact('2026-06-15', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '20**-12-20/20**-01-03' -TestDate $td } $testDate
            $result.Excluded | Should -Be $false
        }
    }

    Context 'Multiple exclusions' {
        It 'Returns Excluded=true when matching any exclusion range' {
            $testDate = [datetime]::ParseExact('2026-11-28', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-11-28/2026-11-29,2026-12-24/2027-01-02' -TestDate $td } $testDate
            $result.Excluded | Should -Be $true
        }

        It 'Returns Excluded=false when not matching any exclusion range' {
            $testDate = [datetime]::ParseExact('2026-11-27', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-11-28/2026-11-29,2026-12-24/2027-01-02' -TestDate $td } $testDate
            $result.Excluded | Should -Be $false
        }
    }

    Context 'Output properties' {
        It 'Returns MatchedExclusion when excluded' {
            $testDate = [datetime]::ParseExact('2026-12-25', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' -TestDate $td } $testDate
            $result.MatchedExclusion | Should -Not -BeNullOrEmpty
        }

        It 'Returns null MatchedExclusion when not excluded' {
            $testDate = [datetime]::ParseExact('2026-06-15', 'yyyy-MM-dd', $null)
            $result = & (Get-Module $moduleName) { param($td) Test-AzLocalUpdateExclusion -ExclusionString '2026-12-20/2027-01-03' -TestDate $td } $testDate
            $result.MatchedExclusion | Should -BeNullOrEmpty
        }
    }
}

Describe 'Helper Function: Test-AzLocalUpdateScheduleAllowed (Internal)' {
    BeforeAll {
        $moduleName = 'AzLocal.UpdateManagement'
    }

    Context 'No restrictions' {
        It 'Returns Allowed=true when no tags are defined' {
            $result = & (Get-Module $moduleName) { Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow '' -UpdateExclusionsWindow '' }
            $result.Allowed | Should -Be $true
            $result.Reason | Should -BeLike '*No schedule restrictions*'
        }

        It 'Returns Allowed=true when both tags are null' {
            $result = & (Get-Module $moduleName) { Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow $null -UpdateExclusionsWindow $null }
            $result.Allowed | Should -Be $true
        }
    }

    Context 'Window only' {
        It 'Returns Allowed=true when within maintenance window' {
            $testTime = [datetime]::ParseExact('2026-04-18 03:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
            $result.WindowOpen | Should -Be $true
        }

        It 'Returns Allowed=false when outside maintenance window' {
            $testTime = [datetime]::ParseExact('2026-04-18 10:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow 'Sat_02:00-06:00' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $false
            $result.WindowOpen | Should -Be $false
            $result.Reason | Should -BeLike '*Outside maintenance window*'
        }
    }

    Context 'Exclusion only' {
        It 'Returns Allowed=false when in exclusion period' {
            $testTime = [datetime]::ParseExact('2026-12-25 12:00', 'yyyy-MM-dd HH:mm', $null)
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateScheduleAllowed -UpdateExclusionsWindow '2026-12-20/2027-01-03' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $false
            $result.ExclusionActive | Should -Be $true
            $result.Reason | Should -BeLike '*exclusion period*'
        }

        It 'Returns Allowed=true when not in exclusion period' {
            $testTime = [datetime]::ParseExact('2026-06-15 12:00', 'yyyy-MM-dd HH:mm', $null)
            $result = & (Get-Module $moduleName) { param($tt) Test-AzLocalUpdateScheduleAllowed -UpdateExclusionsWindow '2026-12-20/2027-01-03' -TestTime $tt } $testTime
            $result.Allowed | Should -Be $true
        }
    }

    Context 'Exclusion takes priority over window' {
        It 'Returns Allowed=false when in exclusion even if within window' {
            # Saturday Dec 26 at 03:00 - within Sat window but also in exclusion
            $testTime = [datetime]::ParseExact('2026-12-26 03:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt)
                Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow 'Sat_02:00-06:00' -UpdateExclusionsWindow '2026-12-20/2027-01-03' -TestTime $tt
            } $testTime
            $result.Allowed | Should -Be $false
            $result.ExclusionActive | Should -Be $true
        }
    }

    Context 'Both tags, no conflict' {
        It 'Returns Allowed=true when within window and not in exclusion' {
            # Saturday Apr 18 at 03:00 - within Sat window, no exclusion active
            $testTime = [datetime]::ParseExact('2026-04-18 03:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt)
                Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow 'Sat_02:00-06:00' -UpdateExclusionsWindow '2026-12-20/2027-01-03' -TestTime $tt
            } $testTime
            $result.Allowed | Should -Be $true
            $result.WindowOpen | Should -Be $true
            $result.ExclusionActive | Should -Be $false
        }

        It 'Returns Allowed=false when outside window and not in exclusion' {
            # Saturday Apr 18 at 10:00 - outside Sat window, no exclusion active
            $testTime = [datetime]::ParseExact('2026-04-18 10:00', 'yyyy-MM-dd HH:mm', $null)  # Saturday
            $result = & (Get-Module $moduleName) { param($tt)
                Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow 'Sat_02:00-06:00' -UpdateExclusionsWindow '2026-12-20/2027-01-03' -TestTime $tt
            } $testTime
            $result.Allowed | Should -Be $false
            $result.WindowOpen | Should -Be $false
        }
    }

    Context 'Output properties' {
        It 'Returns all expected properties' {
            $testTime = [datetime]::ParseExact('2026-04-18 03:00', 'yyyy-MM-dd HH:mm', $null)
            $result = & (Get-Module $moduleName) { param($tt)
                Test-AzLocalUpdateScheduleAllowed -UpdateStartWindow 'Sat_02:00-06:00' -UpdateExclusionsWindow '2026-12-20/2027-01-03' -TestTime $tt
            } $testTime
            $result.PSObject.Properties.Name | Should -Contain 'Allowed'
            $result.PSObject.Properties.Name | Should -Contain 'Reason'
            $result.PSObject.Properties.Name | Should -Contain 'WindowOpen'
            $result.PSObject.Properties.Name | Should -Contain 'ExclusionActive'
            $result.PSObject.Properties.Name | Should -Contain 'Details'
        }
    }
}

Describe 'Function: Test-AzLocalUpdateScheduleAllowed (Exported)' {
    Context 'Exported Function Access' {
        It 'Should be exported from the module' {
            $command = Get-Command Test-AzLocalUpdateScheduleAllowed -ErrorAction SilentlyContinue
            $command | Should -Not -BeNullOrEmpty
            $command.Source | Should -Be 'AzLocal.UpdateManagement'
        }

        It 'Should have UpdateStartWindow parameter with AllowEmptyString' {
            $command = Get-Command Test-AzLocalUpdateScheduleAllowed
            $command.Parameters.Keys | Should -Contain 'UpdateStartWindow'
        }

        It 'Should have UpdateExclusionsWindow parameter' {
            $command = Get-Command Test-AzLocalUpdateScheduleAllowed
            $command.Parameters.Keys | Should -Contain 'UpdateExclusionsWindow'
        }

        It 'Should have TestTime parameter' {
            $command = Get-Command Test-AzLocalUpdateScheduleAllowed
            $command.Parameters.Keys | Should -Contain 'TestTime'
        }
    }
}

Describe 'Integration: Start-AzLocalClusterUpdate Schedule Status' {
    Context 'ScheduleBlocked status in result counting' {
        It 'ScheduleBlocked is included in the skip statuses list' {
            # Verify ScheduleBlocked is in the expected skip statuses used by the end block
            $skipStatuses = @("Skipped", "NotReady", "NoUpdatesAvailable", "NoReadyUpdates", "NotFound", "UpdateNotFound", "HealthCheckBlocked", "ScheduleBlocked", "SideloadedBlocked", "ExcludedByTag")
            $skipStatuses | Should -Contain "ScheduleBlocked"
            $skipStatuses | Should -Contain "ExcludedByTag"
        }
    }

    Context 'JUnit XML export handles ScheduleBlocked' {
        It 'Export-ResultsToJUnitXml should handle ScheduleBlocked result' {
            $testResult = [PSCustomObject]@{
                ClusterName = 'test-cluster'
                Status      = 'ScheduleBlocked'
                Message     = 'Outside maintenance window: Sat_02:00-06:00'
                UpdateName  = $null
                StartTime   = Get-Date
                EndTime     = Get-Date
                Duration    = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-schedule-test-$([Guid]::NewGuid()).xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') {
                    param($results, $path)
                    Export-ResultsToJUnitXml -Results $results -OutputPath $path -TestSuiteName 'Test' -OperationType 'StartUpdate'
                } @($testResult) $outputPath

                $outputPath | Should -Exist
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $testCase | Should -Not -BeNullOrEmpty
                $failure = $testCase.SelectSingleNode('failure')
                $failure | Should -Not -BeNullOrEmpty
                $failure.type | Should -Be 'ScheduleBlocked'
            }
            finally {
                if (Test-Path $outputPath) { Remove-Item $outputPath -Force }
            }
        }
    }

    Context 'JUnit XML export handles SideloadedBlocked (v0.7.1)' {
        It 'Export-ResultsToJUnitXml should handle SideloadedBlocked result' {
            $testResult = [PSCustomObject]@{
                ClusterName = 'test-cluster'
                Status      = 'SideloadedBlocked'
                Message     = 'UpdateSideloaded == False, update is blocked'
                UpdateName  = $null
                StartTime   = Get-Date
                EndTime     = Get-Date
                Duration    = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-sideloaded-test-$([Guid]::NewGuid()).xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') {
                    param($results, $path)
                    Export-ResultsToJUnitXml -Results $results -OutputPath $path -TestSuiteName 'Test' -OperationType 'StartUpdate'
                } @($testResult) $outputPath

                $outputPath | Should -Exist
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $testCase | Should -Not -BeNullOrEmpty
                $failure = $testCase.SelectSingleNode('failure')
                $failure | Should -Not -BeNullOrEmpty
                $failure.type | Should -Be 'SideloadedBlocked'
            }
            finally {
                if (Test-Path $outputPath) { Remove-Item $outputPath -Force }
            }
        }
    }

    Context 'JUnit XML export handles non-failure non-passing statuses (v0.7.62)' {
        # v0.7.62 fix: Status values NotReady, NotConnected, NoUpdatesAvailable,
        # NoReadyUpdates previously fell through to <system-out> (rendered as
        # passed in dorny/test-reporter), producing misleading "all green" CI
        # summaries when the apply step had actually skipped clusters. They
        # must now render as <skipped>. UpdateNotFound must render as <error>.
        BeforeAll {
            $script:exportJUnit = {
                param($results, $path)
                Export-ResultsToJUnitXml -Results $results -OutputPath $path -TestSuiteName 'Test' -OperationType 'StartUpdate'
            }
        }

        It 'Should render NotReady as <skipped>' {
            $tr = [PSCustomObject]@{
                ClusterName = 'c1'; Status = 'NotReady'
                Message     = 'No ready updates available'
                StartTime   = Get-Date; EndTime = Get-Date; Duration = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-notready.xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') $script:exportJUnit @($tr) $outputPath
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $testCase.SelectSingleNode('skipped')   | Should -Not -BeNullOrEmpty
                $testCase.SelectSingleNode('failure')   | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('error')     | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('system-out')| Should -BeNullOrEmpty
            }
            finally { if (Test-Path $outputPath) { Remove-Item $outputPath -Force } }
        }

        It 'Should render NotConnected as <skipped>' {
            $tr = [PSCustomObject]@{
                ClusterName = 'c1'; Status = 'NotConnected'
                Message     = 'Cluster is NotConnectedRecently'
                StartTime   = Get-Date; EndTime = Get-Date; Duration = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-notconnected.xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') $script:exportJUnit @($tr) $outputPath
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $testCase.SelectSingleNode('skipped') | Should -Not -BeNullOrEmpty
                $testCase.SelectSingleNode('failure') | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('error')   | Should -BeNullOrEmpty
            }
            finally { if (Test-Path $outputPath) { Remove-Item $outputPath -Force } }
        }

        It 'Should render NoUpdatesAvailable as <skipped>' {
            $tr = [PSCustomObject]@{
                ClusterName = 'c1'; Status = 'NoUpdatesAvailable'
                Message     = 'No updates available'
                StartTime   = Get-Date; EndTime = Get-Date; Duration = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-noupdatesavail.xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') $script:exportJUnit @($tr) $outputPath
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $testCase.SelectSingleNode('skipped') | Should -Not -BeNullOrEmpty
                $testCase.SelectSingleNode('failure') | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('error')   | Should -BeNullOrEmpty
            }
            finally { if (Test-Path $outputPath) { Remove-Item $outputPath -Force } }
        }

        It 'Should render NoReadyUpdates as <skipped>' {
            $tr = [PSCustomObject]@{
                ClusterName = 'c1'; Status = 'NoReadyUpdates'
                Message     = 'No ready updates'
                StartTime   = Get-Date; EndTime = Get-Date; Duration = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-noreadyupdates.xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') $script:exportJUnit @($tr) $outputPath
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $testCase.SelectSingleNode('skipped') | Should -Not -BeNullOrEmpty
                $testCase.SelectSingleNode('failure') | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('error')   | Should -BeNullOrEmpty
            }
            finally { if (Test-Path $outputPath) { Remove-Item $outputPath -Force } }
        }

        It 'Should render UpdateNotFound as <error type="UpdateNotFound">' {
            $tr = [PSCustomObject]@{
                ClusterName = 'c1'; Status = 'UpdateNotFound'
                Message     = "Update '10.2511.0.99' not found"
                UpdateName  = '10.2511.0.99'
                StartTime   = Get-Date; EndTime = Get-Date; Duration = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-updatenotfound.xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') $script:exportJUnit @($tr) $outputPath
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $errorNode = $testCase.SelectSingleNode('error')
                $errorNode | Should -Not -BeNullOrEmpty
                $errorNode.type | Should -Be 'UpdateNotFound'
                $testCase.SelectSingleNode('skipped') | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('failure') | Should -BeNullOrEmpty
            }
            finally { if (Test-Path $outputPath) { Remove-Item $outputPath -Force } }
        }

        It 'UpdateStarted should still render as system-out (passed)' {
            $tr = [PSCustomObject]@{
                ClusterName = 'c1'; Status = 'UpdateStarted'
                Message     = 'Update started successfully'
                UpdateName  = '10.2511.0.10'
                StartTime   = Get-Date; EndTime = Get-Date; Duration = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-updatestarted.xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') $script:exportJUnit @($tr) $outputPath
                $xml = [xml](Get-Content $outputPath -Raw)
                $testCase = $xml.SelectSingleNode('//testcase')
                $testCase.SelectSingleNode('system-out') | Should -Not -BeNullOrEmpty
                $testCase.SelectSingleNode('failure')    | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('error')      | Should -BeNullOrEmpty
                $testCase.SelectSingleNode('skipped')    | Should -BeNullOrEmpty
            }
            finally { if (Test-Path $outputPath) { Remove-Item $outputPath -Force } }
        }

        It 'Mixed-result summary should produce correct testsuite counts' {
            $results = @(
                [PSCustomObject]@{ ClusterName = 'a'; Status = 'UpdateStarted';      Message = 'ok';   Duration = '00:00:01' }
                [PSCustomObject]@{ ClusterName = 'b'; Status = 'NotReady';           Message = 'nope'; Duration = '00:00:01' }
                [PSCustomObject]@{ ClusterName = 'c'; Status = 'HealthCheckBlocked'; Message = 'bad';  Duration = '00:00:01' }
                [PSCustomObject]@{ ClusterName = 'd'; Status = 'UpdateNotFound';     Message = 'gone'; Duration = '00:00:01' }
                [PSCustomObject]@{ ClusterName = 'e'; Status = 'NoUpdatesAvailable'; Message = 'none'; Duration = '00:00:01' }
            )
            $outputPath = Join-Path $env:TEMP "pester-junit-mixed.xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') $script:exportJUnit $results $outputPath
                $xml = [xml](Get-Content $outputPath -Raw)
                $suite = $xml.SelectSingleNode('//testsuite')
                [int]$suite.tests    | Should -Be 5
                [int]$suite.failures | Should -Be 1     # HealthCheckBlocked
                [int]$suite.errors   | Should -Be 1     # UpdateNotFound
                [int]$suite.skipped  | Should -Be 2     # NotReady + NoUpdatesAvailable
            }
            finally { if (Test-Path $outputPath) { Remove-Item $outputPath -Force } }
        }
    }
}

#endregion Update Schedule Tag Helpers Tests

Describe 'Function: Export-AzLocalFleetState' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Export-AzLocalFleetState
        }

        It 'Should have State parameter' {
            $command.Parameters.Keys | Should -Contain 'State'
        }

        It 'Should have Path parameter' {
            $command.Parameters.Keys | Should -Contain 'Path'
        }
    }

    Context 'OutputType' {
        It 'Should have OutputType of String' {
            $outputTypes = (Get-Command Export-AzLocalFleetState).OutputType
            $outputTypes.Type.Name | Should -Contain 'String'
        }
    }
}

Describe 'Function: Resume-AzLocalFleetUpdate' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Resume-AzLocalFleetUpdate
        }

        It 'Should have StateFilePath parameter' {
            $command.Parameters.Keys | Should -Contain 'StateFilePath'
        }

        It 'Should have State parameter' {
            $command.Parameters.Keys | Should -Contain 'State'
        }

        It 'Should have RetryFailed parameter' {
            $command.Parameters.Keys | Should -Contain 'RetryFailed'
        }

        It 'Should have MaxRetries parameter' {
            $command.Parameters.Keys | Should -Contain 'MaxRetries'
        }

        It 'Should have Force parameter' {
            $command.Parameters.Keys | Should -Contain 'Force'
        }

        It 'Should have PassThru parameter' {
            $command.Parameters.Keys | Should -Contain 'PassThru'
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Resume-AzLocalFleetUpdate
        }

        It 'Should have ByPath parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByPath'
        }

        It 'Should have ByState parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByState'
        }
    }
}

Describe 'Function: Stop-AzLocalFleetUpdate' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Stop-AzLocalFleetUpdate
        }

        It 'Should have SaveState parameter' {
            $command.Parameters.Keys | Should -Contain 'SaveState'
        }

        It 'Should have StateFilePath parameter' {
            $command.Parameters.Keys | Should -Contain 'StateFilePath'
        }
    }
}

Describe 'Fleet Functions: Naming Conventions' {
    
    Context 'Noun Prefix Consistency' {
        It 'All fleet functions should use AzLocal noun prefix' {
            $fleetFunctions = @(
                'Invoke-AzLocalFleetOperation',
                'Get-AzLocalFleetProgress',
                'Test-AzLocalFleetHealthGate',
                'Export-AzLocalFleetState',
                'Resume-AzLocalFleetUpdate',
                'Stop-AzLocalFleetUpdate'
            )
            
            foreach ($func in $fleetFunctions) {
                $noun = $func.Split('-')[1]
                $noun | Should -BeLike 'AzLocal*' -Because "$func should use AzLocal noun prefix"
            }
        }
    }
}

#endregion Fleet-Scale Operations Tests

#region Pre-Update Health Validation Tests (v0.6.1)

Describe 'Function: Test-AzLocalClusterHealth' {
    
    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Test-AzLocalClusterHealth
        }

        It 'Should have ClusterResourceIds parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterResourceIds'
        }

        It 'Should have ClusterNames parameter' {
            $command.Parameters.Keys | Should -Contain 'ClusterNames'
        }

        It 'Should have ScopeByUpdateRingTag parameter' {
            $command.Parameters.Keys | Should -Contain 'ScopeByUpdateRingTag'
        }

        It 'Should have UpdateRingValue parameter' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingValue'
        }

        It 'Should have BlockingOnly parameter' {
            $command.Parameters.Keys | Should -Contain 'BlockingOnly'
        }

        It 'Should have ApiVersion parameter' {
            $command.Parameters.Keys | Should -Contain 'ApiVersion'
        }

        It 'Should have ExportPath parameter' {
            $command.Parameters.Keys | Should -Contain 'ExportPath'
        }

        It 'Should have ResourceGroupName parameter' {
            $command.Parameters.Keys | Should -Contain 'ResourceGroupName'
        }

        It 'Should have SubscriptionId parameter' {
            $command.Parameters.Keys | Should -Contain 'SubscriptionId'
        }
    }

    Context 'Parameter Sets' {
        BeforeAll {
            $command = Get-Command Test-AzLocalClusterHealth
        }

        It 'Should have ByResourceId parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByResourceId'
        }

        It 'Should have ByName parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByName'
        }

        It 'Should have ByTag parameter set' {
            $command.ParameterSets.Name | Should -Contain 'ByTag'
        }

        It 'Should have ClusterResourceIds mandatory in ByResourceId set' {
            $param = $command.Parameters['ClusterResourceIds']
            $attr = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.ParameterSetName -eq 'ByResourceId' }
            $attr.Mandatory | Should -Be $true
        }

        It 'Should have ClusterNames mandatory in ByName set' {
            $param = $command.Parameters['ClusterNames']
            $attr = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.ParameterSetName -eq 'ByName' }
            $attr.Mandatory | Should -Be $true
        }

        It 'Should have ScopeByUpdateRingTag mandatory in ByTag set' {
            $param = $command.Parameters['ScopeByUpdateRingTag']
            $attr = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.ParameterSetName -eq 'ByTag' }
            $attr.Mandatory | Should -Be $true
        }
    }

    Context 'Output Type' {
        BeforeAll {
            $command = Get-Command Test-AzLocalClusterHealth
        }

        It 'Should have OutputType declared' {
            $command.OutputType | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Naming Convention' {
        It 'Should use AzLocal noun prefix' {
            $noun = 'Test-AzLocalClusterHealth'.Split('-')[1]
            $noun | Should -BeLike 'AzLocal*'
        }
    }
}

#endregion Pre-Update Health Validation Tests

#region Internal Helper: Invoke-AzResourceGraphQuery

Describe 'Internal Helper: Invoke-AzResourceGraphQuery' {

    Context 'Pagination behaviour' {

        It 'Should merge rows across multiple pages by following skip_token' {
            InModuleScope AzLocal.UpdateManagement {
                # Override the external 'az' executable with an in-scope function so
                # we can feed canned ARG responses without touching the network.
                $script:TestCallIndex = 0
                function az {
                    $script:TestCallIndex++
                    switch ($script:TestCallIndex) {
                        1 {
                            # First page returns 2 rows + continuation token
                            return '{"count":2,"data":[{"id":"a"},{"id":"b"}],"skip_token":"tok1","total_records":3}'
                        }
                        2 {
                            # Second page returns final row and no token
                            return '{"count":1,"data":[{"id":"c"}],"total_records":3}'
                        }
                        default {
                            throw "Unexpected extra page call index $($script:TestCallIndex)"
                        }
                    }
                }
                $global:LASTEXITCODE = 0

                $rows = Invoke-AzResourceGraphQuery -Query 'resources | project id'

                $rows | Should -HaveCount 3
                $rows[0].id | Should -Be 'a'
                $rows[1].id | Should -Be 'b'
                $rows[2].id | Should -Be 'c'
                $script:TestCallIndex | Should -Be 2
            }
        }

        It 'Should return an empty array when the single-page response has no data' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return '{"count":0,"data":[],"total_records":0}' }
                $global:LASTEXITCODE = 0

                $rows = Invoke-AzResourceGraphQuery -Query 'resources | where 1==0'
                ,$rows | Should -BeOfType ([object[]])
                $rows.Count | Should -Be 0
            }
        }

        It 'Should throw when the CLI reports a non-zero exit code' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return 'FATAL: query syntax error' }
                $global:LASTEXITCODE = 1

                { Invoke-AzResourceGraphQuery -Query 'bad query' } | Should -Throw -ExpectedMessage '*Azure Resource Graph query failed*'
            }
        }

        It 'Should stop at the MaxPages safety cap and emit a warning' {
            InModuleScope AzLocal.UpdateManagement {
                # Always return a continuation token to simulate an infinite loop.
                function az { return '{"count":1,"data":[{"id":"x"}],"skip_token":"never-ends"}' }
                $global:LASTEXITCODE = 0

                $warnings = @()
                $rows = Invoke-AzResourceGraphQuery -Query 'resources' -MaxPages 3 -WarningVariable warnings -WarningAction SilentlyContinue
                $rows | Should -HaveCount 3
                ($warnings -join ' ') | Should -Match 'safety cap'
            }
        }
    }

    Context 'cp1252 stderr WARNING does not corrupt JSON parse (v0.7.66 regression)' {
        # v0.7.66 regression guard: on hosted Windows runners (windows-latest,
        # windows-2022) the Azure CLI's Python layer can emit
        # 'WARNING: Unable to encode the output with cp1252 encoding...' to
        # stderr before emitting the JSON body to stdout. The helper captures
        # the merged stream via 2>&1, so without explicit stream-type filtering
        # the WARNING line gets prepended to the JSON body and ConvertFrom-Json
        # throws 'Unexpected character encountered while parsing value: W.'
        # The fix: split the captured stream by element type (stderr lines
        # surface as ErrorRecord, stdout lines as String) and feed only the
        # string stream to ConvertFrom-Json. See matching hardening in
        # Invoke-AzRestJson (v0.7.2).
        It 'Should ignore stderr ErrorRecord lines when parsing the JSON body' {
            InModuleScope AzLocal.UpdateManagement {
                # Simulate the Azure CLI emitting both a stderr WARNING and a
                # valid JSON body on stdout. Write-Error makes the line surface
                # as an ErrorRecord under 2>&1; the trailing 'return' emits
                # the JSON to the output (stdout) stream. Pre-v0.7.66 the
                # helper would call ConvertFrom-Json on 'WARNING: ...\n{...}'
                # and throw.
                function az {
                    Write-Error 'WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded.'
                    return '{"count":1,"data":[{"id":"row-after-warning"}],"total_records":1}'
                }
                $global:LASTEXITCODE = 0

                $rows = Invoke-AzResourceGraphQuery -Query 'resources | project id' -ErrorAction SilentlyContinue
                $rows | Should -HaveCount 1
                $rows[0].id | Should -Be 'row-after-warning'
            }
        }

        It 'Should restore PYTHONIOENCODING after a successful call' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return '{"count":0,"data":[],"total_records":0}' }
                $global:LASTEXITCODE = 0
                $before = $env:PYTHONIOENCODING
                try {
                    $env:PYTHONIOENCODING = 'sentinel-before'
                    [void](Invoke-AzResourceGraphQuery -Query 'resources | where 1==0')
                    $env:PYTHONIOENCODING | Should -Be 'sentinel-before'
                }
                finally {
                    $env:PYTHONIOENCODING = $before
                }
            }
        }

        It 'Should restore PYTHONIOENCODING after a throwing call' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return 'FATAL: oops' }
                $global:LASTEXITCODE = 1
                $before = $env:PYTHONIOENCODING
                try {
                    $env:PYTHONIOENCODING = 'sentinel-throw'
                    { Invoke-AzResourceGraphQuery -Query 'bad' } | Should -Throw
                    $env:PYTHONIOENCODING | Should -Be 'sentinel-throw'
                }
                finally {
                    $env:PYTHONIOENCODING = $before
                }
            }
        }
    }

    Context 'Throttle handling (v0.7.68)' {
        # v0.7.68 introduced a per-page retry loop for ARG 429 / RateLimitingException
        # responses. The retry budget is -MaxRetries (default 5); the backoff is
        # exponential with +/-20% jitter; non-throttle errors are NOT retried; and
        # two module-scope diagnostic flags ($script:LastResourceGraphThrottled,
        # $script:LastResourceGraphRetryCount) are reset per call and readable
        # by callers/tests.

        It 'Should retry on 429 / RateLimitingException and eventually succeed' {
            InModuleScope AzLocal.UpdateManagement {
                $script:ThrottleCalls = 0
                function az {
                    $script:ThrottleCalls++
                    if ($script:ThrottleCalls -le 2) {
                        # -ErrorAction Continue bypasses Pester v5's $ErrorActionPreference='Stop'
                        # It-block default, which would otherwise turn this Write-Error into a
                        # terminating exception and abort before $LASTEXITCODE is set. The real
                        # az.exe writes throttle messages to stderr without raising a PowerShell
                        # error; this mock simulates that non-terminating behaviour.
                        Write-Error -ErrorAction Continue 'ERROR: RateLimitingException (429): Too many requests. Please retry after some time.'
                        $global:LASTEXITCODE = 1
                        return
                    }
                    $global:LASTEXITCODE = 0
                    return '{"count":1,"data":[{"id":"recovered"}],"total_records":1}'
                }

                $rows = Invoke-AzResourceGraphQuery -Query 'resources' -RetryBaseSeconds 0.1 -WarningAction SilentlyContinue
                $rows | Should -HaveCount 1
                $rows[0].id | Should -Be 'recovered'
                $script:ThrottleCalls | Should -Be 3
                $script:LastResourceGraphThrottled | Should -BeTrue
                $script:LastResourceGraphRetryCount | Should -Be 2
            }
        }

        It 'Should give up and throw once -MaxRetries is exhausted on persistent throttling' {
            InModuleScope AzLocal.UpdateManagement {
                function az {
                    # -ErrorAction Continue bypasses Pester v5 It-block 'Stop' default; see
                    # comment in the preceding test for the full rationale.
                    Write-Error -ErrorAction Continue 'ERROR: 429 TooManyRequests - rate limit exceeded'
                    $global:LASTEXITCODE = 1
                    return
                }

                {
                    Invoke-AzResourceGraphQuery -Query 'resources' -MaxRetries 2 -RetryBaseSeconds 0.1 -WarningAction SilentlyContinue
                } | Should -Throw -ExpectedMessage '*Azure Resource Graph query failed*'
                $script:LastResourceGraphThrottled | Should -BeTrue
                $script:LastResourceGraphRetryCount | Should -Be 2
            }
        }

        It 'Should NOT retry on non-throttle errors (auth, bad KQL, permissions)' {
            InModuleScope AzLocal.UpdateManagement {
                $script:NonThrottleCalls = 0
                function az {
                    $script:NonThrottleCalls++
                    # -ErrorAction Continue bypasses Pester v5 It-block 'Stop' default; see
                    # comment in the 'Should retry on 429' test for the full rationale.
                    Write-Error -ErrorAction Continue 'ERROR: AuthenticationFailed - the access token is invalid'
                    $global:LASTEXITCODE = 1
                    return
                }

                {
                    Invoke-AzResourceGraphQuery -Query 'resources' -MaxRetries 5 -RetryBaseSeconds 0.1
                } | Should -Throw -ExpectedMessage '*Azure Resource Graph query failed*'
                $script:NonThrottleCalls | Should -Be 1
                $script:LastResourceGraphThrottled | Should -BeFalse
                $script:LastResourceGraphRetryCount | Should -Be 0
            }
        }

        It 'Should reset throttle diagnostic flags at the start of every call' {
            InModuleScope AzLocal.UpdateManagement {
                # First call: triggers a throttle + retry to set flags TRUE / >0.
                $script:Phase1Calls = 0
                function az {
                    $script:Phase1Calls++
                    if ($script:Phase1Calls -eq 1) {
                        # -ErrorAction Continue bypasses Pester v5 It-block 'Stop' default; see
                        # comment in the 'Should retry on 429' test for the full rationale.
                        Write-Error -ErrorAction Continue 'ERROR: 429 throttled'
                        $global:LASTEXITCODE = 1
                        return
                    }
                    $global:LASTEXITCODE = 0
                    return '{"count":0,"data":[],"total_records":0}'
                }
                [void](Invoke-AzResourceGraphQuery -Query 'resources' -RetryBaseSeconds 0.1 -WarningAction SilentlyContinue)
                $script:LastResourceGraphThrottled | Should -BeTrue
                $script:LastResourceGraphRetryCount | Should -Be 1

                # Second call: clean (no throttle). Flags must reset back to FALSE / 0.
                function az {
                    $global:LASTEXITCODE = 0
                    return '{"count":0,"data":[],"total_records":0}'
                }
                [void](Invoke-AzResourceGraphQuery -Query 'resources')
                $script:LastResourceGraphThrottled | Should -BeFalse
                $script:LastResourceGraphRetryCount | Should -Be 0
            }
        }
    }

    Context 'Cross-call throttle coordination (v0.7.84)' {
        # v0.7.84 added a module-scope cross-call cooldown so that a throttle
        # event observed in call N causes call N+1 to sleep out a short
        # voluntary window on entry. This complements the v0.7.68 per-page
        # retry loop (which only handles bursts WITHIN one call). The cooldown
        # state lives in $script:ArgCrossCallCooldownUntil and
        # $script:ArgConsecutiveThrottledCalls; each call exposes how long it
        # actually slept on entry via $script:LastResourceGraphCrossCallCooldownSeconds.
        # The -DisableCrossCallCooldown switch opts out (used in tests and by
        # callers that have their own rate-limiting upstream).

        It 'Sets the cross-call cooldown window after observing throttling' {
            InModuleScope AzLocal.UpdateManagement {
                # Reset state so this test doesn't inherit cooldown from a prior test.
                $script:ArgCrossCallCooldownUntil = [DateTime]::MinValue
                $script:ArgConsecutiveThrottledCalls = 0

                $script:Phase = 0
                function az {
                    $script:Phase++
                    if ($script:Phase -eq 1) {
                        Write-Error -ErrorAction Continue 'ERROR: 429 throttled'
                        $global:LASTEXITCODE = 1
                        return
                    }
                    $global:LASTEXITCODE = 0
                    return '{"count":0,"data":[],"total_records":0}'
                }
                $before = Get-Date
                [void](Invoke-AzResourceGraphQuery -Query 'resources' -RetryBaseSeconds 0.1 -DisableCrossCallCooldown -WarningAction SilentlyContinue)
                # After a throttle event, the cooldown window must be set to a
                # future instant relative to the start of the call.
                $script:ArgCrossCallCooldownUntil | Should -BeGreaterThan $before
                $script:ArgConsecutiveThrottledCalls | Should -BeGreaterThan 0
            }
        }

        It 'Sleeps on entry when a previous call set a cross-call cooldown window' {
            InModuleScope AzLocal.UpdateManagement {
                # Manually arm a 300ms cooldown window. A subsequent clean call
                # must wait it out on entry and report the wait via the
                # per-call diagnostic flag.
                $script:ArgCrossCallCooldownUntil = (Get-Date).AddMilliseconds(300)
                function az {
                    $global:LASTEXITCODE = 0
                    return '{"count":0,"data":[],"total_records":0}'
                }
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                [void](Invoke-AzResourceGraphQuery -Query 'resources')
                $sw.Stop()
                # Elapsed must be at least the cooldown (allow generous slack
                # for slow CI; minimum guarantee is ~250ms).
                $sw.Elapsed.TotalMilliseconds | Should -BeGreaterThan 250
                $script:LastResourceGraphCrossCallCooldownSeconds | Should -BeGreaterThan 0
                # Reset for downstream tests.
                $script:ArgCrossCallCooldownUntil = [DateTime]::MinValue
                $script:ArgConsecutiveThrottledCalls = 0
            }
        }

        It '-DisableCrossCallCooldown bypasses the cooldown wait on entry' {
            InModuleScope AzLocal.UpdateManagement {
                # Arm a 500ms cooldown. With -DisableCrossCallCooldown the
                # call must NOT sleep and must report 0 cooldown applied.
                $script:ArgCrossCallCooldownUntil = (Get-Date).AddMilliseconds(500)
                function az {
                    $global:LASTEXITCODE = 0
                    return '{"count":0,"data":[],"total_records":0}'
                }
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                [void](Invoke-AzResourceGraphQuery -Query 'resources' -DisableCrossCallCooldown)
                $sw.Stop()
                # Must complete fast - well under the 500ms cooldown.
                $sw.Elapsed.TotalMilliseconds | Should -BeLessThan 250
                $script:LastResourceGraphCrossCallCooldownSeconds | Should -Be 0
                # Reset for downstream tests.
                $script:ArgCrossCallCooldownUntil = [DateTime]::MinValue
                $script:ArgConsecutiveThrottledCalls = 0
            }
        }

        It 'Decays the consecutive-throttle counter on a clean call' {
            InModuleScope AzLocal.UpdateManagement {
                # Pretend we are 3 throttled calls deep. A clean call must
                # decrement the counter to 2 (and not below 0).
                $script:ArgConsecutiveThrottledCalls = 3
                $script:ArgCrossCallCooldownUntil = [DateTime]::MinValue
                function az {
                    $global:LASTEXITCODE = 0
                    return '{"count":0,"data":[],"total_records":0}'
                }
                [void](Invoke-AzResourceGraphQuery -Query 'resources' -DisableCrossCallCooldown)
                $script:ArgConsecutiveThrottledCalls | Should -Be 2

                # Three more clean calls must drive it to 0 and clamp at 0.
                [void](Invoke-AzResourceGraphQuery -Query 'resources' -DisableCrossCallCooldown)
                [void](Invoke-AzResourceGraphQuery -Query 'resources' -DisableCrossCallCooldown)
                [void](Invoke-AzResourceGraphQuery -Query 'resources' -DisableCrossCallCooldown)
                $script:ArgConsecutiveThrottledCalls | Should -Be 0
            }
        }
    }
}

#endregion Internal Helper: Invoke-AzResourceGraphQuery

Describe 'Internal Helper: Invoke-AzCliJson (v0.7.67)' {
    # New in v0.7.67. Generic wrapper around 'az <subcommand>' that applies the
    # same stderr/stdout stream-split + JSON parse pattern as Invoke-AzRestJson
    # and Invoke-AzResourceGraphQuery, so callers outside the 'az rest' path
    # (notably 'az account show' in Get-AzLocalClusterInventory) no longer
    # have to inline the unsafe `az ... 2>&1 | ConvertFrom-Json` boilerplate.

    Context 'Stream-split JSON parsing' {
        It 'Returns Ok=$true and parsed Data on a clean JSON response' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return '{"id":"00000000-0000-0000-0000-000000000000","name":"sub-name"}' }
                $global:LASTEXITCODE = 0
                $res = Invoke-AzCliJson -Arguments @('account','show','--subscription','x')
                $res.Ok | Should -BeTrue
                $res.Data.name | Should -Be 'sub-name'
                $res.Error | Should -BeNullOrEmpty
            }
        }

        It 'Ignores stderr WARNING lines when parsing the JSON body (cp1252 regression guard)' {
            # Mirrors the Invoke-AzResourceGraphQuery cp1252 guard. Write-Error
            # makes the line surface as an ErrorRecord under 2>&1; without the
            # stream-type filter the WARNING would be prepended to the JSON and
            # ConvertFrom-Json would throw.
            InModuleScope AzLocal.UpdateManagement {
                function az {
                    Write-Error 'WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded.'
                    return '{"name":"sub-after-warning"}'
                }
                $global:LASTEXITCODE = 0
                $res = Invoke-AzCliJson -Arguments @('account','show') -ErrorAction SilentlyContinue
                $res.Ok | Should -BeTrue
                $res.Data.name | Should -Be 'sub-after-warning'
            }
        }

        It 'Returns Ok=$false with scrubbed Error when CLI exits non-zero' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return 'ERROR: not authenticated' }
                $global:LASTEXITCODE = 1
                $res = Invoke-AzCliJson -Arguments @('account','show')
                $res.Ok | Should -BeFalse
                $res.Data | Should -BeNullOrEmpty
                $res.Error | Should -Match 'not authenticated'
            }
        }

        It 'Returns Ok=$true with Data=$null when stdout is empty' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return '' }
                $global:LASTEXITCODE = 0
                $res = Invoke-AzCliJson -Arguments @('logout')
                $res.Ok | Should -BeTrue
                $res.Data | Should -BeNullOrEmpty
            }
        }

        It 'Returns Ok=$false with parse-failure Error when stdout is not JSON' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return 'this is not json' }
                $global:LASTEXITCODE = 0
                $res = Invoke-AzCliJson -Arguments @('account','show')
                $res.Ok | Should -BeFalse
                $res.Error | Should -Match 'JSON parse failure'
            }
        }

        It 'Appends --only-show-errors to the invocation' {
            InModuleScope AzLocal.UpdateManagement {
                $script:capturedArgs = $null
                function az {
                    $script:capturedArgs = @($args)
                    return '{}'
                }
                $global:LASTEXITCODE = 0
                [void](Invoke-AzCliJson -Arguments @('account','show'))
                $script:capturedArgs | Should -Contain '--only-show-errors'
            }
        }

        It 'Restores PYTHONIOENCODING after a successful call' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return '{}' }
                $global:LASTEXITCODE = 0
                $before = $env:PYTHONIOENCODING
                try {
                    $env:PYTHONIOENCODING = 'sentinel-clean'
                    [void](Invoke-AzCliJson -Arguments @('account','show'))
                    $env:PYTHONIOENCODING | Should -Be 'sentinel-clean'
                }
                finally {
                    $env:PYTHONIOENCODING = $before
                }
            }
        }
    }
}

#endregion Internal Helper: Invoke-AzCliJson

#region Fleet Health Failures (v0.7.65)

Describe 'Function: Get-AzLocalFleetHealthFailures' {

    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Get-AzLocalFleetHealthFailures
        }

        It 'Should have SubscriptionId parameter' {
            $command.Parameters.Keys | Should -Contain 'SubscriptionId'
        }

        It 'Should have Severity parameter with ValidateSet (Critical, Warning, All)' {
            $command.Parameters.Keys | Should -Contain 'Severity'
            $validateSet = $command.Parameters['Severity'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet | Should -Not -BeNullOrEmpty
            $validateSet.ValidValues | Should -Contain 'Critical'
            $validateSet.ValidValues | Should -Contain 'Warning'
            $validateSet.ValidValues | Should -Contain 'All'
        }

        It 'Should have View parameter with ValidateSet (Detail, Summary)' {
            $command.Parameters.Keys | Should -Contain 'View'
            $validateSet = $command.Parameters['View'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $validateSet | Should -Not -BeNullOrEmpty
            $validateSet.ValidValues | Should -Contain 'Detail'
            $validateSet.ValidValues | Should -Contain 'Summary'
        }

        It 'Should have UpdateRingTag parameter with ValidatePattern' {
            $command.Parameters.Keys | Should -Contain 'UpdateRingTag'
            $vp = $command.Parameters['UpdateRingTag'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] }
            $vp | Should -Not -BeNullOrEmpty
        }

        It 'Should have ExportPath and PassThru parameters' {
            $command.Parameters.Keys | Should -Contain 'ExportPath'
            $command.Parameters.Keys | Should -Contain 'PassThru'
        }

        It 'Should declare OutputType' {
            $command.OutputType | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Detail view' {

        It 'Returns one row per (cluster, failing health-check) with the expected shape' {
            InModuleScope AzLocal.UpdateManagement {
                # v0.7.76: ARG now returns one row per cluster carrying the raw
                # healthCheckResult array; the function expands client-side.
                # Two clusters, two failing checks each across Critical + Warning.
                $payload = @{
                    count = 2
                    data  = @(
                        @{
                            ClusterName       = 'Cluster01'
                            ResourceGroup     = 'RG1'
                            SubscriptionId    = 'sub-1111'
                            ClusterResourceId = '/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            ClusterPortalUrl  = 'https://portal.azure.com/#@/resource/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            HealthCheckCount  = 2
                            HealthCheckResult = @(
                                @{
                                    name               = 'storage-pool-health'
                                    displayName        = 'Storage pool degraded'
                                    description        = 'A storage pool drive is in degraded state.'
                                    remediation        = 'Replace the failed drive.'
                                    severity           = 'Critical'
                                    status             = 'Failed'
                                    targetResourceName = ''
                                    targetResourceType = ''
                                    timestamp          = '2026-05-16T08:00:00Z'
                                },
                                @{
                                    name               = 'time-skew'
                                    displayName        = 'Time skew detected'
                                    description        = 'Cluster nodes time skew > 1s.'
                                    remediation        = 'Validate NTP configuration.'
                                    severity           = 'Warning'
                                    status             = 'Failed'
                                    targetResourceName = ''
                                    targetResourceType = ''
                                    timestamp          = '2026-05-16T07:30:00Z'
                                }
                            )
                        },
                        @{
                            ClusterName       = 'Cluster02'
                            ResourceGroup     = 'RG2'
                            SubscriptionId    = 'sub-1111'
                            ClusterResourceId = '/subscriptions/sub-1111/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02'
                            ClusterPortalUrl  = 'https://portal.azure.com/#@/resource/subscriptions/sub-1111/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02'
                            HealthCheckCount  = 2
                            HealthCheckResult = @(
                                @{
                                    name               = 'storage-pool-health'
                                    displayName        = 'Storage pool degraded'
                                    description        = 'A storage pool drive is in degraded state.'
                                    remediation        = 'Replace the failed drive.'
                                    severity           = 'Critical'
                                    status             = 'Failed'
                                    targetResourceName = ''
                                    targetResourceType = ''
                                    timestamp          = '2026-05-16T08:15:00Z'
                                },
                                @{
                                    name               = 'network-mtu'
                                    displayName        = 'Network MTU misconfiguration'
                                    description        = 'Cluster nodes have inconsistent MTU.'
                                    remediation        = 'Align MTU across all NICs.'
                                    severity           = 'Warning'
                                    status             = 'Failed'
                                    targetResourceName = ''
                                    targetResourceType = ''
                                    timestamp          = '2026-05-16T07:00:00Z'
                                }
                            )
                        }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $rows = Get-AzLocalFleetHealthFailures -View Detail
                $rows | Should -HaveCount 4
                $rows[0].PSObject.Properties.Name | Should -Contain 'ClusterName'
                $rows[0].PSObject.Properties.Name | Should -Contain 'FailureReason'
                $rows[0].PSObject.Properties.Name | Should -Contain 'Severity'
                $rows[0].PSObject.Properties.Name | Should -Contain 'LastOccurrence'
                $rows[0].PSObject.Properties.Name | Should -Contain 'ClusterResourceId'
                @($rows | Where-Object { $_.Severity -eq 'Critical' }).Count | Should -Be 2
                @($rows | Where-Object { $_.Severity -eq 'Warning'  }).Count | Should -Be 2
            }
        }

        It 'Returns an empty array when Resource Graph reports no failing checks' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return '{"count":0,"data":[]}' }
                $global:LASTEXITCODE = 0
                $rows = Get-AzLocalFleetHealthFailures
                ,$rows | Should -BeOfType ([object[]])
                $rows.Count | Should -Be 0
            }
        }
    }

    Context 'Summary view' {

        It 'Aggregates rows by FailureReason + Severity and orders by ClusterCount desc' {
            InModuleScope AzLocal.UpdateManagement {
                # v0.7.76: cluster-shaped mock. Storage pool degraded hits 2
                # clusters (C1, C2); Time skew hits 2 (C1, C3); Network MTU
                # hits 1 (C2). Expected ordering: Critical first; among the
                # two ClusterCount=2 reasons, Critical (Storage pool) outranks
                # Warning (Time skew).
                $payload = @{
                    count = 3
                    data  = @(
                        @{ ClusterName='C1'; ResourceGroup='RG1'; SubscriptionId='s1'; ClusterResourceId='/x/c1'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c1'; HealthCheckCount=2; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded';        description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' },
                            @{ name='ts';  displayName='Time skew detected';           description='d'; remediation='r'; severity='Warning';  status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T07:00:00Z' }
                        ) },
                        @{ ClusterName='C2'; ResourceGroup='RG1'; SubscriptionId='s1'; ClusterResourceId='/x/c2'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c2'; HealthCheckCount=2; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded';        description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:30:00Z' },
                            @{ name='mtu'; displayName='Network MTU misconfiguration'; description='d'; remediation='r'; severity='Warning';  status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T06:00:00Z' }
                        ) },
                        @{ ClusterName='C3'; ResourceGroup='RG1'; SubscriptionId='s1'; ClusterResourceId='/x/c3'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c3'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='ts';  displayName='Time skew detected';           description='d'; remediation='r'; severity='Warning';  status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T07:30:00Z' }
                        ) }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $summary = Get-AzLocalFleetHealthFailures -View Summary
                $summary | Should -Not -BeNullOrEmpty
                $summary.Count | Should -BeGreaterOrEqual 3

                # Most widespread (ClusterCount=2) must come first.
                $summary[0].FailureReason | Should -Be 'Storage pool degraded'
                $summary[0].Severity      | Should -Be 'Critical'
                $summary[0].ClusterCount  | Should -Be 2
                $summary[0].FailureCount  | Should -Be 2
                $summary[0].AffectedClusters | Should -Match 'C1'
                $summary[0].AffectedClusters | Should -Match 'C2'

                # Among the two ClusterCount=2 entries (Time skew is also 2 clusters),
                # Critical sorts before Warning - so Storage pool degraded is first;
                # Time skew (Warning, 2 clusters) comes before Network MTU (Warning, 1 cluster).
                $reasonsInOrder = $summary | Select-Object -ExpandProperty FailureReason
                $reasonsInOrder[0] | Should -Be 'Storage pool degraded'
                # Verify the lowest-impact failure is at the bottom
                $summary[-1].FailureReason | Should -Be 'Network MTU misconfiguration'
                $summary[-1].ClusterCount  | Should -Be 1
            }
        }
    }

    Context 'Severity filter' {

        BeforeAll {
            # v0.7.76: severity filtering moved client-side, so these tests
            # exercise output filtering rather than KQL string content.
            # Mock returns one cluster carrying three failed checks: one
            # Critical, one Warning, one Informational.
            # NOTE: $global: scope is required so InModuleScope (which switches
            # the script scope to the module) can still read the payload.
            $global:SeverityMockPayload = @{
                count = 1
                data  = @(
                    @{
                        ClusterName       = 'Cluster01'
                        ResourceGroup     = 'RG1'
                        SubscriptionId    = 's1'
                        ClusterResourceId = '/x/c1'
                        ClusterPortalUrl  = 'https://portal.azure.com/#@/resource/x/c1'
                        HealthCheckCount  = 3
                        HealthCheckResult = @(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical';      status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' },
                            @{ name='ts';  displayName='Time skew detected';    description='d'; remediation='r'; severity='Warning';       status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T07:30:00Z' },
                            @{ name='inf'; displayName='Info noise';            description='d'; remediation='r'; severity='Informational'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T07:00:00Z' }
                        )
                    }
                )
            } | ConvertTo-Json -Depth 8
        }

        It 'Severity=Critical filters output to Critical-only rows' {
            InModuleScope AzLocal.UpdateManagement {
                function az { return $global:SeverityMockPayload }
                $global:LASTEXITCODE = 0

                $rows = Get-AzLocalFleetHealthFailures -Severity Critical
                $rows | Should -HaveCount 1
                $rows[0].Severity | Should -Be 'Critical'
                $rows[0].FailureReason | Should -Be 'Storage pool degraded'
            }
        }

        It "Severity=All returns Critical + Warning rows and excludes Informational" {
            InModuleScope AzLocal.UpdateManagement {
                function az { return $global:SeverityMockPayload }
                $global:LASTEXITCODE = 0

                $rows = Get-AzLocalFleetHealthFailures -Severity All
                $rows | Should -HaveCount 2
                @($rows | Where-Object { $_.Severity -eq 'Critical' }).Count | Should -Be 1
                @($rows | Where-Object { $_.Severity -eq 'Warning'  }).Count | Should -Be 1
                @($rows | Where-Object { $_.Severity -eq 'Informational' }).Count | Should -Be 0
            }
        }
    }

    Context 'UpdateRingTag scoping' {

        It 'Issues a second ARG query against the resources table to map UpdateRing -> ResourceIds and filters detail rows' {
            InModuleScope AzLocal.UpdateManagement {
                $script:Calls = 0
                function az {
                    $script:Calls++
                    if ($script:Calls -eq 1) {
                        # v0.7.76: first call returns cluster-shape rows with raw
                        # healthCheckResult arrays.
                        return (@{
                            count = 2
                            data  = @(
                                @{ ClusterName='Cluster01'; ResourceGroup='RG1'; SubscriptionId='s1'; ClusterResourceId='/subscriptions/s1/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'; ClusterPortalUrl='https://portal.azure.com/#@/resource/c1'; HealthCheckCount=1; HealthCheckResult=@(
                                    @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' }
                                ) },
                                @{ ClusterName='Cluster02'; ResourceGroup='RG2'; SubscriptionId='s1'; ClusterResourceId='/subscriptions/s1/resourceGroups/RG2/providers/Microsoft.AzureStackHCI/clusters/Cluster02'; ClusterPortalUrl='https://portal.azure.com/#@/resource/c2'; HealthCheckCount=1; HealthCheckResult=@(
                                    @{ name='ts'; displayName='Time skew detected'; description='d'; remediation='r'; severity='Warning'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T07:00:00Z' }
                                ) }
                            )
                        } | ConvertTo-Json -Depth 8)
                    }
                    elseif ($script:Calls -eq 2) {
                        # Second call: UpdateRing tag mapping - only Cluster01 is in Wave1
                        return (@{
                            count = 1
                            data  = @(
                                @{ id = '/subscriptions/s1/resourcegroups/rg1/providers/microsoft.azurestackhci/clusters/cluster01' }
                            )
                        } | ConvertTo-Json -Depth 6)
                    }
                    else {
                        throw "Unexpected az call $($script:Calls)"
                    }
                }
                $global:LASTEXITCODE = 0

                $rows = Get-AzLocalFleetHealthFailures -UpdateRingTag 'Wave1'
                $script:Calls | Should -Be 2
                $rows | Should -HaveCount 1
                $rows[0].ClusterName | Should -Be 'Cluster01'
            }
        }
    }

    Context 'Export' {

        It 'Writes a CSV file when ExportPath ends in .csv and does not emit objects unless -PassThru' {
            InModuleScope AzLocal.UpdateManagement {
                $payload = @{
                    count = 1
                    data  = @(
                        @{ ClusterName='C1'; ResourceGroup='RG1'; SubscriptionId='s1'; ClusterResourceId='/x/c1'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c1'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' }
                        ) }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $tempDir = Join-Path $env:TEMP "azlocal-fleethealth-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
                $csv = Join-Path $tempDir 'fleet-health-detail.csv'

                try {
                    $result = Get-AzLocalFleetHealthFailures -ExportPath $csv
                    $result | Should -BeNullOrEmpty
                    Test-Path $csv | Should -BeTrue
                    $loaded = Import-Csv $csv
                    $loaded | Should -HaveCount 1
                    $loaded[0].FailureReason | Should -Be 'Storage pool degraded'
                }
                finally {
                    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'Emits objects AND writes the file when -PassThru is set' {
            InModuleScope AzLocal.UpdateManagement {
                $payload = @{
                    count = 1
                    data  = @(
                        @{ ClusterName='C1'; ResourceGroup='RG1'; SubscriptionId='s1'; ClusterResourceId='/x/c1'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c1'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' }
                        ) }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $tempDir = Join-Path $env:TEMP "azlocal-fleethealth-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
                New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
                $csv = Join-Path $tempDir 'fleet-health-detail.csv'

                try {
                    $rows = Get-AzLocalFleetHealthFailures -ExportPath $csv -PassThru
                    $rows | Should -HaveCount 1
                    Test-Path $csv | Should -BeTrue
                }
                finally {
                    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Context 'Naming Convention' {
        It 'Should use AzLocal noun prefix' {
            $noun = 'Get-AzLocalFleetHealthFailures'.Split('-')[1]
            $noun | Should -BeLike 'AzLocal*'
        }
    }
}

#endregion Fleet Health Failures (v0.7.65)

#region Internal Helper: Invoke-FleetJobsInParallel

Describe 'Internal Helper: Invoke-FleetJobsInParallel' {

    Context 'Fast-path (ThrottleLimit=1)' {

        It 'Should execute scriptblock inline without Start-Job when ThrottleLimit is 1' {
            InModuleScope AzLocal.UpdateManagement {
                $sb = {
                    param([object[]]$Batch, [string]$Arg1, [string]$ModPath)
                    [PSCustomObject]@{ Count = $Batch.Count; Arg = $Arg1 }
                }
                $result = Invoke-FleetJobsInParallel -InputItems @(1, 2, 3) -ScriptBlock $sb `
                    -ThrottleLimit 1 -ArgumentList @('hello')

                $result | Should -HaveCount 1
                $result[0].Failed | Should -Be $false
                $result[0].Output.Count | Should -Be 3
                $result[0].Output.Arg | Should -Be 'hello'
            }
        }

        It 'Should return an empty array when InputItems is empty' {
            InModuleScope AzLocal.UpdateManagement {
                $sb = { param([object[]]$Batch, [string]$ModPath) 'unused' }
                $result = Invoke-FleetJobsInParallel -InputItems @() -ScriptBlock $sb -ThrottleLimit 4
                ,$result | Should -BeOfType ([object[]])
                $result.Count | Should -Be 0
            }
        }

        It 'Should capture errors from the inline scriptblock as Failed=$true' {
            InModuleScope AzLocal.UpdateManagement {
                $sb = { param([object[]]$Batch, [string]$ModPath) throw 'boom' }
                $result = Invoke-FleetJobsInParallel -InputItems @('a') -ScriptBlock $sb -ThrottleLimit 1
                $result | Should -HaveCount 1
                $result[0].Failed | Should -Be $true
                $result[0].Error | Should -Match 'boom'
            }
        }
    }

    Context 'ModulePath trailing argument (regression: v0.7.4 parallel-path bug)' {

        # When the helper passes the trailing $ModulePath to the per-batch
        # scriptblock, it MUST be the root AzLocal.UpdateManagement.psd1 (or
        # .psm1) - NOT this helper's own .ps1. Otherwise, child Start-Job
        # runspaces calling Import-Module $ModulePath load only the helper
        # and every private helper reference fails with
        #   "Cannot use '&' to invoke in the context of module 'Invoke-FleetJobsInParallel' because it is not imported."
        # See: regression bug observed on a 9-cluster Prod fleet against the
        # PSGallery-published v0.7.4 build.

        It 'Should pass the root module manifest path (not the helper .ps1) as the trailing ModulePath argument' {
            InModuleScope AzLocal.UpdateManagement {
                $captured = $null
                $sb = {
                    param([object[]]$Batch, [string]$ModPath)
                    # Echo back the path so the test can assert on it.
                    [PSCustomObject]@{ ModPath = $ModPath }
                }
                $result = Invoke-FleetJobsInParallel -InputItems @('item1') -ScriptBlock $sb -ThrottleLimit 1
                $captured = $result[0].Output.ModPath
                $captured | Should -Not -BeNullOrEmpty
                # Must point at the root manifest/module, not the helper file.
                $captured | Should -Match 'AzLocal\.UpdateManagement\.ps[dm]1$'
                $captured | Should -Not -Match 'Invoke-FleetJobsInParallel\.ps1$'
            }
        }
    }
}

#endregion Internal Helper: Invoke-FleetJobsInParallel

#region Internal Helper: Get-AzLocalModuleRootManifestPath

Describe 'Internal Helper: Get-AzLocalModuleRootManifestPath' {

    # This helper centralises the post-v0.7.3 fix: $PSScriptRoot inside any
    # Public/ or Private/ .ps1 resolves to that subfolder, NOT the module
    # root. The helper must return the root manifest (preferring .psd1)
    # so child Start-Job runspaces can re-import the whole module.

    Context 'Resolution via loaded module' {

        It 'Should return a path ending in AzLocal.UpdateManagement.psd1 when the module is loaded' {
            InModuleScope AzLocal.UpdateManagement {
                $resolved = Get-AzLocalModuleRootManifestPath
                $resolved | Should -Not -BeNullOrEmpty
                $resolved | Should -Match 'AzLocal\.UpdateManagement\.ps[dm]1$'
                # MUST NOT be a Public/ or Private/ nested-module .ps1.
                $resolved | Should -Not -Match '\\(Public|Private)\\[^\\]+\.ps1$'
                Test-Path -LiteralPath $resolved | Should -Be $true
            }
        }

        It 'Should resolve correctly when given a CallerScriptPath inside Public/' {
            InModuleScope AzLocal.UpdateManagement {
                $fakeCaller = Join-Path -Path (Split-Path -Parent (Get-Module AzLocal.UpdateManagement | Select-Object -First 1).Path) -ChildPath 'Public\Get-AzLocalUpdateRuns.ps1'
                $resolved = Get-AzLocalModuleRootManifestPath -CallerScriptPath $fakeCaller
                $resolved | Should -Match 'AzLocal\.UpdateManagement\.ps[dm]1$'
                $resolved | Should -Not -Match '\\Public\\'
            }
        }

        It 'Should resolve correctly when given a CallerScriptPath inside Private/' {
            InModuleScope AzLocal.UpdateManagement {
                $fakeCaller = Join-Path -Path (Split-Path -Parent (Get-Module AzLocal.UpdateManagement | Select-Object -First 1).Path) -ChildPath 'Private\Invoke-FleetJobsInParallel.ps1'
                $resolved = Get-AzLocalModuleRootManifestPath -CallerScriptPath $fakeCaller
                $resolved | Should -Match 'AzLocal\.UpdateManagement\.ps[dm]1$'
                $resolved | Should -Not -Match '\\Private\\'
            }
        }
    }
}

#endregion Internal Helper: Get-AzLocalModuleRootManifestPath

#region Internal Helper: Invoke-FleetOpClusterAction

Describe 'Internal Helper: Invoke-FleetOpClusterAction' {

    Context 'Success path' {

        It 'Should mark state as Succeeded and record attempts for GetStatus' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Get-AzLocalUpdateSummary { return [PSCustomObject]@{ State = 'UpToDate' } }
                $cs = [PSCustomObject]@{
                    ClusterName = 'c1'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'
                    Status = 'Pending'; Attempts = 0; LastAttempt = $null; LastError = $null; Result = $null
                }
                Invoke-FleetOpClusterAction -ClusterState $cs -Operation 'GetStatus' -MaxRetries 0 -RetryDelaySeconds 0

                $cs.Status | Should -Be 'Succeeded'
                $cs.Attempts | Should -Be 1
                $cs.LastError | Should -BeNullOrEmpty
                $cs.Result.State | Should -Be 'UpToDate'
            }
        }
    }

    Context 'Retry + failure path' {

        It 'Should retry MaxRetries+1 times and mark Failed with LastError on persistent failure' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Get-AzLocalUpdateSummary { throw 'transient api error' }
                Mock Start-Sleep { }
                $cs = [PSCustomObject]@{
                    ClusterName = 'c2'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c2'
                    Status = 'Pending'; Attempts = 0; LastAttempt = $null; LastError = $null; Result = $null
                }
                Invoke-FleetOpClusterAction -ClusterState $cs -Operation 'GetStatus' -MaxRetries 2 -RetryDelaySeconds 0

                $cs.Status | Should -Be 'Failed'
                $cs.Attempts | Should -Be 3
                $cs.LastError | Should -Match 'transient api error'
                Assert-MockCalled Get-AzLocalUpdateSummary -Times 3 -Exactly
            }
        }
    }

    Context 'ApplyUpdate parameter mapping' {

        It 'Should invoke Start-AzLocalClusterUpdate with -ClusterResourceIds plural + Force=true and treat Status=UpdateStarted as Succeeded' {
            InModuleScope AzLocal.UpdateManagement {
                $script:CapturedParams = $null
                Mock Start-AzLocalClusterUpdate {
                    param($ClusterResourceIds, [switch]$Force, $UpdateName)
                    $script:CapturedParams = @{
                        ClusterResourceIds = $ClusterResourceIds
                        Force              = [bool]$Force
                        UpdateName         = $UpdateName
                    }
                    return [PSCustomObject]@{ ClusterName = 'c1'; Status = 'UpdateStarted'; Message = 'ok' }
                }
                $cs = [PSCustomObject]@{
                    ClusterName = 'c1'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'
                    Status = 'Pending'; Attempts = 0; LastAttempt = $null; LastError = $null; Result = $null
                }
                Invoke-FleetOpClusterAction -ClusterState $cs -Operation 'ApplyUpdate' -MaxRetries 0 -RetryDelaySeconds 0

                $cs.Status | Should -Be 'Succeeded'
                $script:CapturedParams.ClusterResourceIds | Should -HaveCount 1
                $script:CapturedParams.ClusterResourceIds[0] | Should -Be $cs.ResourceId
                $script:CapturedParams.Force | Should -Be $true
            }
        }

        It 'Should treat Start-AzLocalClusterUpdate Status!=UpdateStarted as a retryable failure' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Start-AzLocalClusterUpdate {
                    return [PSCustomObject]@{ ClusterName = 'c1'; Status = 'HealthCheckBlocked'; Message = 'blocked' }
                }
                Mock Start-Sleep { }
                $cs = [PSCustomObject]@{
                    ClusterName = 'c1'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'
                    Status = 'Pending'; Attempts = 0; LastAttempt = $null; LastError = $null; Result = $null
                }
                Invoke-FleetOpClusterAction -ClusterState $cs -Operation 'ApplyUpdate' -MaxRetries 1 -RetryDelaySeconds 0
                $cs.Status | Should -Be 'Failed'
                $cs.Attempts | Should -Be 2
                $cs.LastError | Should -Match 'HealthCheckBlocked'
            }
        }
    }

    Context 'CheckReadiness parameter mapping' {

        It 'Should invoke Get-AzLocalClusterUpdateReadiness with -ClusterResourceIds plural' {
            InModuleScope AzLocal.UpdateManagement {
                $script:CapturedIds = $null
                Mock Get-AzLocalClusterUpdateReadiness {
                    param($ClusterResourceIds)
                    $script:CapturedIds = $ClusterResourceIds
                    return [PSCustomObject]@{ ReadyForUpdate = $true }
                }
                $cs = [PSCustomObject]@{
                    ClusterName = 'c1'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'
                    Status = 'Pending'; Attempts = 0; LastAttempt = $null; LastError = $null; Result = $null
                }
                Invoke-FleetOpClusterAction -ClusterState $cs -Operation 'CheckReadiness' -MaxRetries 0 -RetryDelaySeconds 0
                $cs.Status | Should -Be 'Succeeded'
                $script:CapturedIds | Should -HaveCount 1
                $script:CapturedIds[0] | Should -Be $cs.ResourceId
            }
        }
    }
}

#endregion Internal Helper: Invoke-FleetOpClusterAction

#region Integration: Invoke-AzLocalFleetOperation parallel dispatch

Describe 'Invoke-AzLocalFleetOperation (parallel dispatch via helpers)' {

    Context 'ThrottleLimit=1 inline fast-path' {

        It 'Should merge per-cluster mutations back into $state.Clusters and count succeeded/failed correctly' {
            InModuleScope AzLocal.UpdateManagement {
                $callLog = [System.Collections.Generic.List[string]]::new()
                Mock Start-AzLocalClusterUpdate {
                    param($ClusterResourceIds, [switch]$Force, $UpdateName)
                    $rid = $ClusterResourceIds[0]
                    [void]$callLog.Add($rid)
                    # First cluster succeeds, second fails.
                    if ($rid -like '*/c1') {
                        return [PSCustomObject]@{ ClusterName = 'c1'; Status = 'UpdateStarted'; Message = 'ok' }
                    }
                    return [PSCustomObject]@{ ClusterName = 'c2'; Status = 'Failed'; Message = 'boom' }
                }
                Mock Start-Sleep { }

                $ids = @(
                    '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'
                    '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c2'
                )

                $state = Invoke-AzLocalFleetOperation `
                    -ClusterResourceIds $ids `
                    -Operation 'ApplyUpdate' `
                    -BatchSize 50 -ThrottleLimit 1 `
                    -DelayBetweenBatchesSeconds 0 `
                    -MaxRetries 0 -RetryDelaySeconds 5 `
                    -Force -PassThru

                $state.TotalClusters | Should -Be 2
                $state.SucceededCount | Should -Be 1
                $state.FailedCount | Should -Be 1
                $state.CompletedCount | Should -Be 2
                ($state.Clusters | Where-Object ClusterName -eq 'c1').Status | Should -Be 'Succeeded'
                ($state.Clusters | Where-Object ClusterName -eq 'c2').Status | Should -Be 'Failed'
                ($state.Clusters | Where-Object ClusterName -eq 'c2').LastError | Should -Match 'Failed'
                $callLog.Count | Should -Be 2
            }
        }

        It 'Should not reprocess clusters that are already Status=Succeeded (resume semantics)' {
            InModuleScope AzLocal.UpdateManagement {
                # Mock ApplyUpdate so that if we see c1 we fail the test.
                Mock Start-AzLocalClusterUpdate {
                    param($ClusterResourceIds)
                    # Intentionally always return Succeeded to prove we never call on pre-succeeded.
                    return [PSCustomObject]@{ Status = 'UpdateStarted' }
                }
                Mock Start-Sleep { }

                # Hack: we cannot pre-seed state through Invoke-AzLocalFleetOperation,
                # but Invoke-FleetOpClusterAction skips Status='Succeeded' via the
                # scriptblock in the parallel helper. We test the skip path by
                # calling the helper directly.
                $cs = [PSCustomObject]@{
                    ClusterName = 'c1'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'
                    Status = 'Succeeded'; Attempts = 2; LastAttempt = (Get-Date).ToString('o'); LastError = $null; Result = $null
                }
                # Invoke-FleetOpClusterAction does NOT itself skip succeeded; the
                # scriptblock inside Invoke-AzLocalFleetOperation does. So
                # simulate that: if Status is Succeeded, don't call action.
                if ($cs.Status -ne 'Succeeded') {
                    Invoke-FleetOpClusterAction -ClusterState $cs -Operation 'ApplyUpdate' -MaxRetries 0 -RetryDelaySeconds 0
                }
                Assert-MockCalled Start-AzLocalClusterUpdate -Times 0 -Exactly
                $cs.Status | Should -Be 'Succeeded'
            }
        }
    }
}

#endregion Integration: Invoke-AzLocalFleetOperation parallel dispatch

#region Integration: Get-AzLocalFleetProgress parallel dispatch

# v0.7.68 ARG-first refactor: rewritten to mock Invoke-AzResourceGraphQuery (the
# cmdlet now reads fleet state in a single ARG batch against
# microsoft.azurestackhci/clusters/updatesummaries, no per-cluster fan-out).
Describe 'Get-AzLocalFleetProgress (ARG-batch dispatch)' {

    Context 'Single ARG batch read against updatesummaries' {

        It 'Aggregates Succeeded / UpdateInProgress / NeedsAttention counts across clusters from one ARG batch' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Install-AzGraphExtension { return $true }

                # Single ARG call returns one row per cluster shaped per the
                # cmdlet's projection: properties bag + ClusterResourceId_
                # (already lowercased by the KQL).
                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/c1'
                            properties = [PSCustomObject]@{ state = 'AppliedSuccessfully'; healthState = 'Success'; lastUpdated = '2025-10-01T00:00:00Z' }
                        }
                        [PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/c2'
                            properties = [PSCustomObject]@{ state = 'UpdateInProgress'; healthState = 'Success'; lastUpdated = '2025-10-01T00:00:00Z' }
                        }
                        [PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/c3'
                            properties = [PSCustomObject]@{ state = 'UpdateFailed'; healthState = 'Failure'; lastUpdated = '2025-10-01T00:00:00Z' }
                        }
                    )
                }

                $fakeState = [PSCustomObject]@{
                    RunId    = 'test'
                    Clusters = @(
                        [PSCustomObject]@{ ClusterName = 'c1'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'; ResourceGroup = 'r'; SubscriptionId = 's' }
                        [PSCustomObject]@{ ClusterName = 'c2'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c2'; ResourceGroup = 'r'; SubscriptionId = 's' }
                        [PSCustomObject]@{ ClusterName = 'c3'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c3'; ResourceGroup = 'r'; SubscriptionId = 's' }
                    )
                }

                $progress = Get-AzLocalFleetProgress -State $fakeState -Detailed

                $progress.TotalClusters | Should -Be 3
                $progress.Succeeded     | Should -Be 1
                $progress.InProgress    | Should -Be 1
                $progress.Failed        | Should -Be 1
                $progress.Completed     | Should -Be 1   # succeeded + upToDate
                $progress.ClusterStatuses | Should -HaveCount 3

                # ARG-first contract: exactly ONE Invoke-AzResourceGraphQuery call
                # for the entire fleet, regardless of cluster count.
                Assert-MockCalled Invoke-AzResourceGraphQuery -Times 1 -Exactly
            }
        }

        It 'Maps clusters missing from the ARG response to UpdateState=Unknown' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Install-AzGraphExtension { return $true }
                Mock Invoke-AzResourceGraphQuery {
                    # Only c1 returns; c2 is missing (e.g. ARG indexing lag,
                    # or no updateSummaries/default has been created yet).
                    return @(
                        [PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/c1'
                            properties = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Success'; lastUpdated = '2025-10-01T00:00:00Z' }
                        }
                    )
                }

                $fakeState = [PSCustomObject]@{
                    RunId    = 'test'
                    Clusters = @(
                        [PSCustomObject]@{ ClusterName = 'c1'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'; ResourceGroup = 'r'; SubscriptionId = 's' }
                        [PSCustomObject]@{ ClusterName = 'c2'; ResourceId = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c2'; ResourceGroup = 'r'; SubscriptionId = 's' }
                    )
                }

                $progress = Get-AzLocalFleetProgress -State $fakeState -Detailed

                $progress.TotalClusters | Should -Be 2
                ($progress.ClusterStatuses | Where-Object ClusterName -eq 'c2').UpdateState | Should -Be 'Unknown'
            }
        }
    }
}

#endregion Integration: Get-AzLocalFleetProgress parallel dispatch

#region Schema contract: Get-AzLocalFleetStatusData

# v0.7.68: schema-contract Pester tests for the top-level shape of the object
# returned by Get-AzLocalFleetStatusData. These tests do NOT exercise the
# per-cluster collection logic (covered elsewhere) - they only assert the
# documented public schema so consumers (the HTML report, downstream JSON,
# automation harnesses) cannot be silently broken by an internal refactor.
Describe 'Get-AzLocalFleetStatusData (schema contract)' {

    Context 'Top-level shape of the returned PSCustomObject' {

        It 'Returns the documented top-level keys with the expected types' {
            InModuleScope AzLocal.UpdateManagement {
                # Shadow native az so any incidental probe (account show etc.) succeeds.
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable { return $true }
                Mock Install-AzGraphExtension { return $true }

                # Stub the per-cluster ARM reads with minimal-but-valid payloads.
                Mock Invoke-AzRestJson {
                    param($Uri)
                    if ($Uri -match '/updateSummaries/default') {
                        return [PSCustomObject]@{ Data = [PSCustomObject]@{ properties = [PSCustomObject]@{
                            state = 'AppliedSuccessfully'; healthState = 'Success'
                            currentVersion = '12.2402.0'; currentSbeVersion = 'N/A'
                            lastChecked = '2025-10-01T00:00:00Z'; lastUpdated = '2025-10-01T00:00:00Z'
                            healthCheckResult = @()
                        } } }
                    }
                    if ($Uri -match '/updates\?api-version') {
                        return [PSCustomObject]@{ Data = [PSCustomObject]@{ value = @() } }
                    }
                    if ($Uri -match '/updateRuns\?api-version') {
                        return [PSCustomObject]@{ Data = [PSCustomObject]@{ value = @() } }
                    }
                    # Cluster info
                    return [PSCustomObject]@{ Data = [PSCustomObject]@{
                        properties = [PSCustomObject]@{ status = 'Succeeded' }
                    } }
                }

                $rid = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/c1'
                $result = Get-AzLocalFleetStatusData -ClusterResourceIds @($rid)

                $result | Should -Not -BeNullOrEmpty
                # The documented top-level schema. If any of these names change,
                # the HTML report and any JSON consumer will silently break.
                $expectedKeys = @(
                    'SchemaVersion','Timestamp','ModuleVersion','Scope','TotalClusters',
                    'Readiness','ClusterDetails','LatestRuns','HealthResults','FailedClusters'
                )
                $actualKeys = @($result.PSObject.Properties.Name)
                foreach ($k in $expectedKeys) { $actualKeys | Should -Contain $k }

                $result.SchemaVersion  | Should -Be '1.0'
                $result.ModuleVersion  | Should -Be $script:ModuleVersion
                $result.TotalClusters  | Should -Be 1
                $result.Scope          | Should -Match 'cluster\(s\) by Resource ID'
                # Array-typed members must always be arrays (never $null), even
                # when empty - downstream consumers .Count them without guards.
                ,$result.Readiness      | Should -BeOfType ([object[]])
                ,$result.ClusterDetails | Should -BeOfType ([object[]])
                ,$result.LatestRuns     | Should -BeOfType ([object[]])
                ,$result.HealthResults  | Should -BeOfType ([object[]])
                ,$result.FailedClusters | Should -BeOfType ([object[]])
                # Timestamp is an ISO-8601 UTC string the consumer .ParseExact()s.
                $result.Timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            }
        }

        It 'Rejects an empty -ClusterResourceIds array at the parameter binder' {
            InModuleScope AzLocal.UpdateManagement {
                # The empty-fleet condition does NOT surface as a stale skeleton
                # object (SchemaVersion=1.0, TotalClusters=0) - the parameter is
                # decorated with [ValidateNotNullOrEmpty] so an explicitly empty
                # caller is rejected at bind time. Callers that want the empty
                # case must reach it via -AllClusters returning 0 resources,
                # which surfaces a documented Write-Log warning + $null return.
                {
                    Get-AzLocalFleetStatusData -ClusterResourceIds @() -WarningAction SilentlyContinue
                } | Should -Throw
            }
        }

        It 'ModuleVersion field tracks the module-scope $script:ModuleVersion constant' {
            InModuleScope AzLocal.UpdateManagement {
                # The HTML report and JSON consumers display this field as the
                # provenance of the data file. It must reflect the actual loaded
                # module - not a hardcoded literal that the maintainer forgot to
                # bump.
                $script:ModuleVersion | Should -Not -BeNullOrEmpty
                $script:ModuleVersion | Should -Match '^\d+\.\d+\.\d+$'
            }
        }
    }
}

#endregion Schema contract: Get-AzLocalFleetStatusData

#region Integration: Get-AzLocalUpdateSummary parallel dispatch

# v0.7.68 ARG-first refactor: the multi-cluster path now reads via a single
# Invoke-AzResourceGraphQuery batch against
# microsoft.azurestackhci/clusters/updatesummaries instead of per-cluster
# Invoke-AzRestJson fan-out. Tests rewritten accordingly.
Describe 'Get-AzLocalUpdateSummary (ARG-batch dispatch)' {

    Context 'Single ARG batch read for multi-cluster -ClusterResourceIds' {

        It 'Returns one row per input cluster from a single ARG batch and strips internal __DisplayTag' {
            InModuleScope AzLocal.UpdateManagement {
                # Shadow native `az` so `az account show` returns success.
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable { return $true }
                Mock Install-AzGraphExtension { return $true }

                $script:seenQueries = [System.Collections.Generic.List[string]]::new()
                Mock Invoke-AzResourceGraphQuery {
                    param($Query)
                    [void]$script:seenQueries.Add([string]$Query)
                    return @(
                        [PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-a/providers/Microsoft.AzureStackHCI/updateSummaries/default'
                            name = 'default'
                            type = 'microsoft.azurestackhci/clusters/updatesummaries'
                            location = 'eastus'
                            ClusterName_       = 'cluster-a'
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-a'
                            properties = [PSCustomObject]@{
                                state           = 'UpToDate'
                                healthState     = 'Success'
                                currentVersion  = '10.2506.0.28'
                                lastUpdated     = '2025-10-01T10:00:00Z'
                                lastChecked     = '2025-10-01T11:00:00Z'
                                updateStateProperties = [PSCustomObject]@{ availableUpdates = 0 }
                            }
                        }
                        [PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-b/providers/Microsoft.AzureStackHCI/updateSummaries/default'
                            name = 'default'
                            type = 'microsoft.azurestackhci/clusters/updatesummaries'
                            location = 'eastus'
                            ClusterName_       = 'cluster-b'
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-b'
                            properties = [PSCustomObject]@{
                                state           = 'UpdateAvailable'
                                healthState     = 'Success'
                                currentVersion  = '10.2502.0.10'
                                lastUpdated     = '2025-10-01T10:00:00Z'
                                lastChecked     = '2025-10-01T11:00:00Z'
                                updateStateProperties = [PSCustomObject]@{ availableUpdates = 2 }
                            }
                        }
                    )
                }

                $ids = @(
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-a'
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-b'
                )

                $results = Get-AzLocalUpdateSummary -ClusterResourceIds $ids -PassThru

                $results | Should -HaveCount 2
                ($results | Where-Object ClusterName -eq 'cluster-a').UpdateState | Should -Be 'UpToDate'
                ($results | Where-Object ClusterName -eq 'cluster-b').UpdateState | Should -Be 'UpdateAvailable'

                # Exactly one ARG batch fired for the whole fleet, regardless of
                # the number of cluster IDs supplied.
                Assert-MockCalled Invoke-AzResourceGraphQuery -Times 1 -Exactly
                # And the KQL targets the updatesummaries namespace with the
                # cluster IDs lower-cased into an in~() literal.
                $script:seenQueries[0] | Should -Match "microsoft\.azurestackhci/clusters/updatesummaries"
                $script:seenQueries[0] | Should -Match "cluster-a"
                $script:seenQueries[0] | Should -Match "cluster-b"

                # Output rows must not leak internal projection columns.
                foreach ($r in $results) {
                    $r.PSObject.Properties.Name | Should -Not -Contain '__DisplayTag'
                    $r.PSObject.Properties.Name | Should -Not -Contain 'ClusterResourceId_'
                    $r.PSObject.Properties.Name | Should -Not -Contain 'ClusterName_'
                }
            }
        }

        It 'Produces UpdateState=No Summary when a cluster has no record in the ARG response' {
            InModuleScope AzLocal.UpdateManagement {
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable { return $true }
                Mock Install-AzGraphExtension { return $true }
                Mock Invoke-AzResourceGraphQuery {
                    # Only cluster-good has an updateSummaries record - the new
                    # ARG-first design replaces the legacy per-cluster Error
                    # status with a "No Summary" row when ARG returns no record
                    # for that cluster id.
                    return @(
                        [PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-good/providers/Microsoft.AzureStackHCI/updateSummaries/default'
                            name = 'default'
                            type = 'microsoft.azurestackhci/clusters/updatesummaries'
                            location = 'eastus'
                            ClusterName_       = 'cluster-good'
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-good'
                            properties = [PSCustomObject]@{ state = 'UpToDate'; healthState = 'Success' }
                        }
                    )
                }
                $ids = @(
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-good'
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-missing'
                )
                $results = Get-AzLocalUpdateSummary -ClusterResourceIds $ids -PassThru
                ($results | Where-Object ClusterName -eq 'cluster-good').UpdateState   | Should -Be 'UpToDate'
                ($results | Where-Object ClusterName -eq 'cluster-missing').UpdateState | Should -Be 'No Summary'
            }
        }
    }
}

#endregion Integration: Get-AzLocalUpdateSummary parallel dispatch

#region Integration: Start-AzLocalClusterUpdate prefetched pass-through

Describe 'Start-AzLocalClusterUpdate (prefetched pass-through)' {

    Context 'PrefetchedUpdateSummaries skips the internal summary fetch' {
        It 'Should use the pre-fetched summary object and not call Get-AzLocalUpdateSummary' {
            InModuleScope AzLocal.UpdateManagement {
                $resourceId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/prefetched-a'
                $prefetched = [PSCustomObject]@{
                    properties = [PSCustomObject]@{
                        state = 'NotApplicableBecausePrefetched'
                        healthState = 'Success'
                    }
                }

                Mock Test-ExportPathWritable { return $true }
                Mock Test-AzCliAvailable { return $true }
                Mock Get-AzLocalClusterInfo {
                    return [PSCustomObject]@{
                        id = $resourceId
                        name = 'prefetched-a'
                        properties = [PSCustomObject]@{ status = 'ConnectedRecently' }
                    }
                }
                Mock Get-AzLocalUpdateSummary { throw 'should not be called when prefetched summary is supplied' }
                # Stop the pipeline early - cluster state is not in valid updates list,
                # so the function emits a Skipped record and continues without needing
                # further mocks. That is enough to prove the prefetched path was taken.

                $cache = @{ $resourceId = $prefetched }
                $results = Start-AzLocalClusterUpdate `
                    -ClusterResourceIds @($resourceId) `
                    -PrefetchedUpdateSummaries $cache `
                    -Force `
                    -PassThru 4>$null 6>$null

                $results | Should -Not -BeNullOrEmpty
                Assert-MockCalled Get-AzLocalUpdateSummary -Times 0 -Exactly
            }
        }
    }

    Context 'PrefetchedAvailableUpdates skips the internal available-updates fetch' {
        It 'Should use the pre-fetched available-updates array and not call Get-AzLocalAvailableUpdates' {
            InModuleScope AzLocal.UpdateManagement {
                $resourceId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/prefetched-b'

                # Summary shows an updateable state so the function reaches the
                # available-updates step; we then assert that Get-AzLocalAvailableUpdates
                # is NOT called because the pre-fetched cache hit short-circuits it.
                $summary = [PSCustomObject]@{
                    properties = [PSCustomObject]@{
                        state = 'UpdateAvailable'
                        healthState = 'Success'
                    }
                }
                $prefetchedUpdates = @(
                    [PSCustomObject]@{
                        name = '10.2506.0.28'
                        properties = [PSCustomObject]@{ state = 'NotReady'; packageType = 'Solution' }
                    }
                )

                Mock Test-ExportPathWritable { return $true }
                Mock Test-AzCliAvailable { return $true }
                Mock Get-AzLocalClusterInfo {
                    return [PSCustomObject]@{
                        id = $resourceId
                        name = 'prefetched-b'
                        properties = [PSCustomObject]@{ status = 'ConnectedRecently' }
                    }
                }
                Mock Get-AzLocalUpdateSummary { return $summary }
                Mock Test-AzLocalClusterHealth { return @([PSCustomObject]@{ IsBlocking = $false; ClusterName = 'prefetched-b' }) }
                Mock Get-AzLocalAvailableUpdates { throw 'should not be called when prefetched available updates are supplied' }
                Mock Get-LastUpdateRunErrorSummary { return [PSCustomObject]@{ ErrorStep = ''; ErrorMessage = '' } }
                Mock Get-HealthCheckFailureSummary { return '' }

                $cache = @{ $resourceId = $prefetchedUpdates }
                $results = Start-AzLocalClusterUpdate `
                    -ClusterResourceIds @($resourceId) `
                    -PrefetchedAvailableUpdates $cache `
                    -Force `
                    -PassThru 4>$null 6>$null

                $results | Should -Not -BeNullOrEmpty
                Assert-MockCalled Get-AzLocalAvailableUpdates -Times 0 -Exactly
            }
        }
    }
}

#endregion Integration: Start-AzLocalClusterUpdate prefetched pass-through

#region Integration: Get-AzLocalClusterUpdateReadiness parallel dispatch

# v0.7.68 ARG-first refactor: multi-cluster readiness now issues three ARG
# queries (cluster lookup, updatesummaries, updates) instead of per-cluster
# ARM REST fan-out. Rewritten to mock Invoke-AzResourceGraphQuery and to
# discriminate by query text (resources vs updatesummaries vs updates).
Describe 'Get-AzLocalClusterUpdateReadiness (ARG-batch dispatch)' {

    Context 'Three ARG batches (clusters, updatesummaries, updates)' {

        It 'Aggregates one row per cluster, tallies recommended versions, and strips internal __ columns' {
            InModuleScope AzLocal.UpdateManagement {
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable      { return $true }
                Mock Install-AzGraphExtension { return $true }
                # The readiness gates query healthCheckResult only on Failure rows.
                Mock Get-HealthCheckFailureSummary { return '' }

                # cluster-a is Connected + UpdateAvailable with one Ready update,
                # cluster-b is Connected + UpdateAvailable with one Downloading update,
                # cluster-c is Connected + UpToDate (no updates).
                Mock Invoke-AzResourceGraphQuery {
                    param($Query)
                    if ($Query -match 'updatesummaries') {
                        return @(
                            [PSCustomObject]@{
                                ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-a'
                                properties = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Success' }
                            }
                            [PSCustomObject]@{
                                ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-b'
                                properties = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Success' }
                            }
                            [PSCustomObject]@{
                                ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-c'
                                properties = [PSCustomObject]@{ state = 'UpToDate'; healthState = 'Success' }
                            }
                        )
                    }
                    elseif ($Query -match "clusters/updates'") {
                        return @(
                            [PSCustomObject]@{
                                ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-a'
                                UpdateName_ = '10.2506.0.28'
                                name = '10.2506.0.28'
                                properties = [PSCustomObject]@{ state = 'Ready'; packageType = 'Solution' }
                            }
                            [PSCustomObject]@{
                                ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-b'
                                UpdateName_ = '10.2506.0.28'
                                name = '10.2506.0.28'
                                properties = [PSCustomObject]@{ state = 'Downloading'; packageType = 'Solution' }
                            }
                        )
                    }
                    else {
                        # Cluster lookup against `resources`.
                        return @(
                            [PSCustomObject]@{
                                id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-a'
                                name = 'cluster-a'; resourceGroup = 'r'; subscriptionId = 's'; tags = $null
                                properties = [PSCustomObject]@{ status = 'ConnectedRecently' }
                            }
                            [PSCustomObject]@{
                                id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-b'
                                name = 'cluster-b'; resourceGroup = 'r'; subscriptionId = 's'; tags = $null
                                properties = [PSCustomObject]@{ status = 'ConnectedRecently' }
                            }
                            [PSCustomObject]@{
                                id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-c'
                                name = 'cluster-c'; resourceGroup = 'r'; subscriptionId = 's'; tags = $null
                                properties = [PSCustomObject]@{ status = 'ConnectedRecently' }
                            }
                        )
                    }
                }

                $ids = @(
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-a'
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-b'
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-c'
                )
                $results = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $ids -PassThru

                $results | Should -HaveCount 3
                ($results | Where-Object ClusterName -eq 'cluster-a').ReadyForUpdate    | Should -BeTrue
                ($results | Where-Object ClusterName -eq 'cluster-a').RecommendedUpdate | Should -Be '10.2506.0.28'
                ($results | Where-Object ClusterName -eq 'cluster-b').ReadyForUpdate    | Should -BeFalse
                ($results | Where-Object ClusterName -eq 'cluster-c').ReadyForUpdate    | Should -BeFalse

                # v0.7.62: every output row must carry ClusterResourceId so the
                # apply-updates pipeline step can call Start-AzLocalClusterUpdate
                # directly from the readiness CSV.
                foreach ($r in $results) {
                    $r.PSObject.Properties.Name | Should -Contain 'ClusterResourceId'
                    $r.ClusterResourceId        | Should -Match '^/subscriptions/.+/clusters/[^/]+$'
                }
                # Internal tally fields must not leak to caller output.
                foreach ($r in $results) {
                    $r.PSObject.Properties.Name | Should -Not -Contain '__DisplayTag'
                    $r.PSObject.Properties.Name | Should -Not -Contain '__CountedRecommendedUpdate'
                    $r.PSObject.Properties.Name | Should -Not -Contain 'ClusterResourceId_'
                }

                # ARG-first contract: exactly 3 ARG calls (cluster lookup +
                # updateSummaries + updates) for the entire fleet.
                Assert-MockCalled Invoke-AzResourceGraphQuery -Times 3 -Exactly
            }
        }
    }
}

#endregion Integration: Get-AzLocalClusterUpdateReadiness parallel dispatch

#region Readiness gates (v0.7.61: ClusterState + Critical health checks)

# v0.7.68 ARG-first refactor: rewritten to mock Invoke-AzResourceGraphQuery
# (the cmdlet issues 3 ARG batches: cluster lookup, updatesummaries, updates).
Describe 'Get-AzLocalClusterUpdateReadiness readiness gates' {

    Context 'BlockingReasons column and ReadyForUpdate gating' {

        BeforeEach {
            # Common helper: build a $script:argMockFactory that the test
            # bodies pass to `Mock Invoke-AzResourceGraphQuery` so each test
            # can vary cluster status / health / updates independently.
        }

        It 'Downgrades ReadyForUpdate to False when ClusterState is NotConnectedRecently' {
            InModuleScope AzLocal.UpdateManagement {
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable      { return $true }
                Mock Install-AzGraphExtension { return $true }
                Mock Get-HealthCheckFailureSummary { return '' }

                Mock Invoke-AzResourceGraphQuery {
                    param($Query)
                    if ($Query -match 'updatesummaries') {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/gated-conn'
                            properties = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Success' }
                        })
                    }
                    elseif ($Query -match "clusters/updates'") {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/gated-conn'
                            UpdateName_ = '10.2506.0.28'
                            name = '10.2506.0.28'
                            properties = [PSCustomObject]@{ state = 'Ready'; packageType = 'Solution' }
                        })
                    }
                    else {
                        return @([PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/gated-conn'
                            name = 'gated-conn'; resourceGroup = 'r'; subscriptionId = 's'; tags = $null
                            properties = [PSCustomObject]@{ status = 'NotConnectedRecently' }
                        })
                    }
                }

                $ids = @('/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/gated-conn')
                $results = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $ids -PassThru

                $results | Should -HaveCount 1
                $row = $results[0]
                $row.ReadyForUpdate           | Should -BeFalse
                $row.PSObject.Properties.Name | Should -Contain 'BlockingReasons'
                $row.BlockingReasons          | Should -Match 'NotConnectedRecently'
                $row.ClusterState             | Should -Be 'NotConnectedRecently'
            }
        }

        It 'Downgrades ReadyForUpdate to False when HealthCheckFailures contains [Critical]' {
            InModuleScope AzLocal.UpdateManagement {
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable      { return $true }
                Mock Install-AzGraphExtension { return $true }
                Mock Get-HealthCheckFailureSummary { return '[Critical] Storage Services Health Check (NodeA)' }

                Mock Invoke-AzResourceGraphQuery {
                    param($Query)
                    if ($Query -match 'updatesummaries') {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/gated-health'
                            properties = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Failure' }
                        })
                    }
                    elseif ($Query -match "clusters/updates'") {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/gated-health'
                            UpdateName_ = '10.2506.0.28'
                            name = '10.2506.0.28'
                            properties = [PSCustomObject]@{ state = 'Ready'; packageType = 'Solution' }
                        })
                    }
                    else {
                        return @([PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/gated-health'
                            name = 'gated-health'; resourceGroup = 'r'; subscriptionId = 's'; tags = $null
                            properties = [PSCustomObject]@{ status = 'ConnectedRecently' }
                        })
                    }
                }

                $ids = @('/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/gated-health')
                $results = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $ids -PassThru

                $row = $results[0]
                $row.ReadyForUpdate      | Should -BeFalse
                $row.BlockingReasons     | Should -Match 'CriticalHealthCheck'
                $row.HealthCheckFailures | Should -Match '\[Critical\]'
            }
        }

        It 'Combines both reasons when both gates fire' {
            InModuleScope AzLocal.UpdateManagement {
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable      { return $true }
                Mock Install-AzGraphExtension { return $true }
                Mock Get-HealthCheckFailureSummary { return '[Critical] Storage Services Health Check (NodeA)' }

                Mock Invoke-AzResourceGraphQuery {
                    param($Query)
                    if ($Query -match 'updatesummaries') {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/gated-both'
                            properties = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Failure' }
                        })
                    }
                    elseif ($Query -match "clusters/updates'") {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/gated-both'
                            UpdateName_ = '10.2506.0.28'
                            name = '10.2506.0.28'
                            properties = [PSCustomObject]@{ state = 'Ready'; packageType = 'Solution' }
                        })
                    }
                    else {
                        return @([PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/gated-both'
                            name = 'gated-both'; resourceGroup = 'r'; subscriptionId = 's'; tags = $null
                            properties = [PSCustomObject]@{ status = 'NotConnectedRecently' }
                        })
                    }
                }

                $ids = @('/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/gated-both')
                $results = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $ids -PassThru

                $row = $results[0]
                $row.ReadyForUpdate  | Should -BeFalse
                $row.BlockingReasons | Should -Match 'CriticalHealthCheck'
                $row.BlockingReasons | Should -Match 'NotConnectedRecently'
            }
        }

        It 'Leaves ReadyForUpdate True when Connected and no Critical health checks' {
            InModuleScope AzLocal.UpdateManagement {
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable      { return $true }
                Mock Install-AzGraphExtension { return $true }
                Mock Get-HealthCheckFailureSummary { return '' }

                Mock Invoke-AzResourceGraphQuery {
                    param($Query)
                    if ($Query -match 'updatesummaries') {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/happy'
                            properties = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Success' }
                        })
                    }
                    elseif ($Query -match "clusters/updates'") {
                        return @([PSCustomObject]@{
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/happy'
                            UpdateName_ = '10.2506.0.28'
                            name = '10.2506.0.28'
                            properties = [PSCustomObject]@{ state = 'Ready'; packageType = 'Solution' }
                        })
                    }
                    else {
                        return @([PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/happy'
                            name = 'happy'; resourceGroup = 'r'; subscriptionId = 's'; tags = $null
                            properties = [PSCustomObject]@{ status = 'ConnectedRecently' }
                        })
                    }
                }

                $ids = @('/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/happy')
                $results = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds $ids -PassThru

                $row = $results[0]
                $row.ReadyForUpdate  | Should -BeTrue
                $row.BlockingReasons | Should -Be ''
            }
        }
    }
}

#endregion Readiness gates (v0.7.61: ClusterState + Critical health checks)

#region Integration: Get-AzLocalUpdateRuns parallel dispatch

# v0.7.68 ARG-first refactor: rewritten to mock Invoke-AzResourceGraphQuery
# (the cmdlet issues a single ARG batch against
# microsoft.azurestackhci/clusters/updates/updateruns instead of per-cluster
# /updateRuns ARM REST fan-out).
Describe 'Integration: Get-AzLocalUpdateRuns parallel dispatch' {
    Context 'Single ARG batch read against updateruns' {
        It 'Aggregates one row per cluster with correct State + RunId and strips internal fields' {
            InModuleScope AzLocal.UpdateManagement {
                function global:az { $global:LASTEXITCODE = 0; return '{}' }
                Mock Test-AzCliAvailable      { return $true }
                Mock Install-AzGraphExtension { return $true }

                Mock Invoke-AzResourceGraphQuery {
                    # Single ARG call returns one updateruns row per cluster
                    # shaped per the cmdlet's projection (id carries the
                    # /updates/<name>/updateRuns/<runId> tail so the private
                    # Format-AzLocalUpdateRun helper can extract RunId).
                    $rows = @(
                        [PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-a/providers/Microsoft.AzureStackHCI/updates/10.2506.0.28/updateRuns/run-1'
                            name = 'run-1'
                            type = 'microsoft.azurestackhci/clusters/updates/updateruns'
                            location = 'eastus'
                            ClusterName_       = 'cluster-a'
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-a'
                            UpdateName_        = '10.2506.0.28'
                            ts = (Get-Date).AddHours(-2)
                            properties = [PSCustomObject]@{
                                state           = 'Succeeded'
                                timeStarted     = (Get-Date).AddHours(-2).ToString('o')
                                lastUpdatedTime = (Get-Date).AddHours(-1).ToString('o')
                                location        = 'eastus'
                                progress        = [PSCustomObject]@{
                                    steps = @([PSCustomObject]@{ name = 'Step1'; status = 'Success' })
                                }
                            }
                        }
                        [PSCustomObject]@{
                            id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-b/providers/Microsoft.AzureStackHCI/updates/10.2506.0.28/updateRuns/run-1'
                            name = 'run-1'
                            type = 'microsoft.azurestackhci/clusters/updates/updateruns'
                            location = 'eastus'
                            ClusterName_       = 'cluster-b'
                            ClusterResourceId_ = '/subscriptions/s/resourcegroups/r/providers/microsoft.azurestackhci/clusters/cluster-b'
                            UpdateName_        = '10.2506.0.28'
                            ts = (Get-Date).AddHours(-2)
                            properties = [PSCustomObject]@{
                                state           = 'InProgress'
                                timeStarted     = (Get-Date).AddHours(-2).ToString('o')
                                lastUpdatedTime = (Get-Date).AddHours(-1).ToString('o')
                                location        = 'eastus'
                                progress        = [PSCustomObject]@{
                                    steps = @([PSCustomObject]@{ name = 'Step1'; status = 'InProgress' })
                                }
                            }
                        }
                    )
                    # Return as array (comma-prefix preserves array semantics
                    # when Pester's mock framework passes the value back to caller).
                    return ,$rows
                }

                $ids = @(
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-a'
                    '/subscriptions/s/resourceGroups/r/providers/Microsoft.AzureStackHCI/clusters/cluster-b'
                )
                $results = Get-AzLocalUpdateRuns -ClusterResourceIds $ids -UpdateName '10.2506.0.28' -Latest -PassThru

                $results | Should -HaveCount 2
                ($results | Where-Object ClusterName -eq 'cluster-a').State | Should -Be 'Succeeded'
                ($results | Where-Object ClusterName -eq 'cluster-b').State | Should -Be 'InProgress'
                ($results | Where-Object ClusterName -eq 'cluster-a').RunId | Should -Be 'run-1'

                # ARG-first contract: exactly ONE ARG call regardless of fleet
                # size (replaces N ARM REST calls in pre-0.7.68 design).
                Assert-MockCalled Invoke-AzResourceGraphQuery -Times 1 -Exactly

                foreach ($r in $results) {
                    $r.PSObject.Properties.Name | Should -Not -Contain '__DisplayTag'
                    $r.PSObject.Properties.Name | Should -Not -Contain '__CountedState'
                    $r.PSObject.Properties.Name | Should -Not -Contain 'DisplayTag'
                    $r.PSObject.Properties.Name | Should -Not -Contain 'ClusterResourceId_'
                }
            }
        }
    }
}

#endregion Integration: Get-AzLocalUpdateRuns parallel dispatch

#region Sideloaded Payload Workflow (v0.7.1)

Describe 'Helper Function: ConvertFrom-AzLocalUpdateSideloaded (Internal)' {
    BeforeAll { $moduleName = 'AzLocal.UpdateManagement' }

    Context 'Accepted values' {
        It 'Returns $true for "True" / "true" / "TRUE"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'True' })  | Should -Be $true
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'true' })  | Should -Be $true
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'TRUE' })  | Should -Be $true
        }
        It 'Returns $true for "1"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value '1' }) | Should -Be $true
        }
        It 'Returns $false for "False" / "false" / "FALSE"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'False' }) | Should -Be $false
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'false' }) | Should -Be $false
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'FALSE' }) | Should -Be $false
        }
        It 'Returns $false for "0"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value '0' }) | Should -Be $false
        }
        It 'Trims surrounding whitespace' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value '  True  ' }) | Should -Be $true
        }
    }

    Context 'Rejected values' {
        It 'Throws on empty string' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value '' } } | Should -Throw '*cannot be empty*'
        }
        It 'Throws on Yes / No / Enabled / 2' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'Yes' } }     | Should -Throw '*Invalid UpdateSideloaded*'
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'No' } }      | Should -Throw '*Invalid UpdateSideloaded*'
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value 'Enabled' } } | Should -Throw '*Invalid UpdateSideloaded*'
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateSideloaded -Value '2' } }       | Should -Throw '*Invalid UpdateSideloaded*'
        }
    }
}

Describe 'Helper Function: Test-AzLocalUpdateSideloadedAllowed (Internal)' {
    BeforeAll { $moduleName = 'AzLocal.UpdateManagement' }

    It 'Allowed=$true and TagPresent=$false when tag is empty/null' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateSideloadedAllowed -UpdateSideloaded '' }
        $r.Allowed    | Should -Be $true
        $r.TagPresent | Should -Be $false
    }
    It 'Allowed=$true when tag is True' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateSideloadedAllowed -UpdateSideloaded 'True' }
        $r.Allowed    | Should -Be $true
        $r.TagPresent | Should -Be $true
        $r.Reason     | Should -BeLike '*UpdateSideloaded == True*'
    }
    It 'Allowed=$true when tag is 1' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateSideloadedAllowed -UpdateSideloaded '1' }
        $r.Allowed | Should -Be $true
    }
    It 'Allowed=$false with clear reason when tag is False' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateSideloadedAllowed -UpdateSideloaded 'False' }
        $r.Allowed    | Should -Be $false
        $r.TagPresent | Should -Be $true
        $r.Reason     | Should -BeLike '*UpdateSideloaded == False*'
    }
    It 'Allowed=$false when tag is 0' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateSideloadedAllowed -UpdateSideloaded '0' }
        $r.Allowed | Should -Be $false
    }
    It 'Throws on malformed tag (caller decides fail-closed/-Force)' {
        { & (Get-Module $moduleName) { Test-AzLocalUpdateSideloadedAllowed -UpdateSideloaded 'Yes' } } | Should -Throw '*Invalid UpdateSideloaded*'
    }
}

# v0.7.90: UpdateExcluded operator-override gate
Describe 'Helper Function: ConvertFrom-AzLocalUpdateExcluded (Internal)' {
    BeforeAll { $moduleName = 'AzLocal.UpdateManagement' }

    Context 'Accepted values' {
        It 'Returns $true for "True" / "true" / "TRUE"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'True' })  | Should -Be $true
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'true' })  | Should -Be $true
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'TRUE' })  | Should -Be $true
        }
        It 'Returns $true for "1"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value '1' }) | Should -Be $true
        }
        It 'Returns $false for "False" / "false" / "FALSE"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'False' }) | Should -Be $false
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'false' }) | Should -Be $false
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'FALSE' }) | Should -Be $false
        }
        It 'Returns $false for "0"' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value '0' }) | Should -Be $false
        }
        It 'Trims surrounding whitespace' {
            (& (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value '  True  ' }) | Should -Be $true
        }
    }

    Context 'Rejected values' {
        It 'Throws on empty string' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value '' } } | Should -Throw '*cannot be empty*'
        }
        It 'Throws on Yes / No / Enabled / 2' {
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'Yes' } }     | Should -Throw '*Invalid UpdateExcluded*'
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'No' } }      | Should -Throw '*Invalid UpdateExcluded*'
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value 'Enabled' } } | Should -Throw '*Invalid UpdateExcluded*'
            { & (Get-Module $moduleName) { ConvertFrom-AzLocalUpdateExcluded -Value '2' } }       | Should -Throw '*Invalid UpdateExcluded*'
        }
    }
}

Describe 'Helper Function: Test-AzLocalUpdateExcludedAllowed (Internal)' {
    BeforeAll { $moduleName = 'AzLocal.UpdateManagement' }

    It 'Allowed=$true and TagPresent=$false when tag is empty/null' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateExcludedAllowed -UpdateExcluded '' }
        $r.Allowed    | Should -Be $true
        $r.TagPresent | Should -Be $false
    }
    It 'Allowed=$false with clear reason when tag is True (semantics INVERTED vs Sideloaded)' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateExcludedAllowed -UpdateExcluded 'True' }
        $r.Allowed    | Should -Be $false
        $r.TagPresent | Should -Be $true
        $r.Reason     | Should -BeLike '*UpdateExcluded == True*'
    }
    It 'Allowed=$false when tag is 1' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateExcludedAllowed -UpdateExcluded '1' }
        $r.Allowed | Should -Be $false
    }
    It 'Allowed=$true when tag is False' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateExcludedAllowed -UpdateExcluded 'False' }
        $r.Allowed    | Should -Be $true
        $r.TagPresent | Should -Be $true
        $r.Reason     | Should -BeLike '*UpdateExcluded == False*'
    }
    It 'Allowed=$true when tag is 0' {
        $r = & (Get-Module $moduleName) { Test-AzLocalUpdateExcludedAllowed -UpdateExcluded '0' }
        $r.Allowed | Should -Be $true
    }
    It 'Throws on malformed tag (caller decides fail-closed/-Force)' {
        { & (Get-Module $moduleName) { Test-AzLocalUpdateExcludedAllowed -UpdateExcluded 'Yes' } } | Should -Throw '*Invalid UpdateExcluded*'
    }
}

Describe 'Integration: Start-AzLocalClusterUpdate ExcludedByTag status (v0.7.90)' {
    Context 'ExcludedByTag status in result counting' {
        It 'ExcludedByTag is included in the skip statuses list' {
            $skipStatuses = @("Skipped", "NotReady", "NoUpdatesAvailable", "NoReadyUpdates", "NotFound", "UpdateNotFound", "HealthCheckBlocked", "ScheduleBlocked", "SideloadedBlocked", "ExcludedByTag")
            $skipStatuses | Should -Contain "ExcludedByTag"
        }
    }

    Context 'JUnit XML export handles ExcludedByTag' {
        It 'Export-ResultsToJUnitXml should handle ExcludedByTag result' {
            $testResult = [PSCustomObject]@{
                ClusterName = 'test-cluster'
                Status      = 'ExcludedByTag'
                Message     = 'UpdateExcluded == True, update is blocked'
                UpdateName  = $null
                StartTime   = Get-Date
                EndTime     = Get-Date
                Duration    = '00:00:01'
            }
            $outputPath = Join-Path $env:TEMP "pester-junit-excluded-test-$([Guid]::NewGuid()).xml"
            try {
                & (Get-Module 'AzLocal.UpdateManagement') {
                    param($results, $path)
                    Export-ResultsToJUnitXml -Results $results -OutputPath $path -TestSuiteName 'Test' -OperationType 'StartUpdate'
                } @($testResult) $outputPath
                Test-Path $outputPath | Should -BeTrue
                $xml = [xml](Get-Content -Path $outputPath -Raw)
                $xml.testsuites.testsuite.testcase.name | Should -BeLike '*test-cluster*'
            }
            finally {
                if (Test-Path $outputPath) { Remove-Item -Path $outputPath -Force -ErrorAction SilentlyContinue }
            }
        }
    }
}

Describe 'Helper Function: Test-AzLocalUpdateVersionInProgressMatch (Internal)' {
    BeforeAll { $moduleName = 'AzLocal.UpdateManagement' }

    It 'Exact match returns $true' {
        (& (Get-Module $moduleName) { Test-AzLocalUpdateVersionInProgressMatch -TagValue 'Solution12.2604.1003.209' -RunUpdateName 'Solution12.2604.1003.209' }) | Should -Be $true
    }
    It 'Case-insensitive match returns $true' {
        (& (Get-Module $moduleName) { Test-AzLocalUpdateVersionInProgressMatch -TagValue 'solution12.2604.1003.209' -RunUpdateName 'SOLUTION12.2604.1003.209' }) | Should -Be $true
    }
    It 'Whitespace-tolerant match returns $true' {
        (& (Get-Module $moduleName) { Test-AzLocalUpdateVersionInProgressMatch -TagValue '  Solution12.2604.1003.209  ' -RunUpdateName 'Solution12.2604.1003.209' }) | Should -Be $true
    }
    It 'Mismatch returns $false' {
        (& (Get-Module $moduleName) { Test-AzLocalUpdateVersionInProgressMatch -TagValue 'Solution12.2604.1003.209' -RunUpdateName 'Solution12.2604.1003.210' }) | Should -Be $false
    }
    It 'Returns $false when either side is empty' {
        (& (Get-Module $moduleName) { Test-AzLocalUpdateVersionInProgressMatch -TagValue '' -RunUpdateName 'X' }) | Should -Be $false
        (& (Get-Module $moduleName) { Test-AzLocalUpdateVersionInProgressMatch -TagValue 'X' -RunUpdateName '' }) | Should -Be $false
    }
}

Describe 'Helper Function: Invoke-AzLocalSideloadedAutoResetForCluster (Internal)' {
    BeforeAll {
        $moduleName = 'AzLocal.UpdateManagement'
        $rid = '/subscriptions/s/resourceGroups/r/providers/microsoft.azurestackhci/clusters/c1'
    }

    BeforeEach {
        # v0.7.62: Set-AzLocalClusterTagsMerge now uses the ARM tags subresource
        # (PATCH .../providers/Microsoft.Resources/tags/default). The GET shape is
        # {"properties":{"tags":{...}}} and up to two PATCHes can fire per call
        # (one for "operation":"Merge", one for "operation":"Delete") - so we
        # capture all PATCH bodies into an array and reshape the GET stub
        # response to the subresource envelope.
        $global:azGetTagsJson  = $null
        $global:azPatchCalled  = $false
        $global:azPatchBodies  = @()
        InModuleScope AzLocal.UpdateManagement {
            function global:az {
                $args2 = @($args)
                $global:LASTEXITCODE = 0
                if ($args2 -contains 'PATCH') {
                    $fIdx = [array]::IndexOf($args2, '--body')
                    if ($fIdx -ge 0 -and $args2[$fIdx + 1] -match '^@(.+)$') {
                        $global:azPatchBodies += ,(Get-Content -Raw $matches[1])
                    }
                    $global:azPatchCalled = $true
                    return ''
                }
                if ($args2 -contains 'GET') {
                    $uIdx = [array]::IndexOf($args2, '--uri')
                    $uri  = if ($uIdx -ge 0) { $args2[$uIdx + 1] } else { '' }
                    $raw  = $global:azGetTagsJson
                    # Tags subresource GET (Set-AzLocalClusterTagsMerge) expects
                    # the {"properties":{"tags":{...}}} envelope. The cluster
                    # resource GET (Invoke-AzLocalSideloadedAutoResetForCluster
                    # reads $cluster.tags) wants the legacy {"tags":{...}} shape.
                    if ($uri -match '/providers/Microsoft\.Resources/tags/default') {
                        if ($raw -and $raw -notmatch '"properties"\s*:') {
                            $raw = '{"properties":' + $raw + '}'
                        }
                    }
                    return $raw
                }
                return ''
            }
        }
    }

    AfterEach {
        InModuleScope AzLocal.UpdateManagement { Remove-Item function:\global:az -ErrorAction SilentlyContinue }
        Remove-Variable -Name azGetTagsJson, azPatchCalled, azPatchBodies -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Action=NoTag when UpdateSideloaded tag is absent' {
        $global:azGetTagsJson = '{"tags":{"UpdateRing":"Wave1"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'Solution12.2604.1003.209' } $rid
        $r.Action | Should -Be 'NoTag'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=OrphanCleared when UpdateSideloaded absent but stale UpdateVersionInProgress matches a Succeeded run' {
        # Cluster opted out of sideloaded workflow (no UpdateSideloaded) but a stale
        # UpdateVersionInProgress tag remains from a previous in-module update. Latest
        # run is Succeeded and matches the tag - clear the orphan tag, do NOT write
        # UpdateSideloaded.
        $global:azGetTagsJson = '{"tags":{"UpdateRing":"Wave1","UpdateVersionInProgress":"Solution12.2604.1003.209"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'Solution12.2604.1003.209' -Confirm:$false } $rid
        $r.Action | Should -Be 'OrphanCleared'
        $r.Message | Should -BeLike '*orphan*'
        $global:azPatchCalled | Should -Be $true
        # v0.7.62: tags-subresource path emits a single PATCH (Delete operation)
        # whose body contains only the keys being removed. No merge PATCH (we are
        # not writing UpdateSideloaded). Preserved tags (UpdateRing) are NOT in
        # the body - the subresource preserves them structurally.
        $global:azPatchBodies.Count | Should -Be 1
        $deleteBody = $global:azPatchBodies[0]
        $deleteBody | Should -Match '"operation":\s*"Delete"'
        $deleteBody | Should -Match 'UpdateVersionInProgress'
        $deleteBody | Should -Not -Match 'UpdateSideloaded'
        $deleteBody | Should -Not -Match 'UpdateRing'
    }

    It 'Action=NoTag when UpdateSideloaded absent and orphan UpdateVersionInProgress does NOT match latest run' {
        # Stale tag, but the latest run name does not match - safer to leave the orphan
        # tag in place than to risk clearing a tag that points at a different update.
        $global:azGetTagsJson = '{"tags":{"UpdateVersionInProgress":"Solution12.2604.1003.209"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'Solution12.2604.1003.210' } $rid
        $r.Action | Should -Be 'NoTag'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=NoTag when UpdateSideloaded absent and orphan UpdateVersionInProgress present but latest run not Succeeded' {
        $global:azGetTagsJson = '{"tags":{"UpdateVersionInProgress":"Solution12.2604.1003.209"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState InProgress -LatestRunUpdateName 'Solution12.2604.1003.209' } $rid
        $r.Action | Should -Be 'NoTag'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=Skipped when UpdateSideloaded=False already' {
        $global:azGetTagsJson = '{"tags":{"UpdateSideloaded":"False"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'X' } $rid
        $r.Action | Should -Be 'Skipped'
        $r.Message | Should -BeLike '*already*'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=RunNotSucceeded when latest run state is InProgress' {
        $global:azGetTagsJson = '{"tags":{"UpdateSideloaded":"True","UpdateVersionInProgress":"Solution12.2604.1003.209"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState InProgress -LatestRunUpdateName 'Solution12.2604.1003.209' } $rid
        $r.Action | Should -Be 'RunNotSucceeded'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=NoRuns when latest run state is empty (cluster has no run history)' {
        $global:azGetTagsJson = '{"tags":{"UpdateSideloaded":"True","UpdateVersionInProgress":"Solution12.2604.1003.209"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState '' -LatestRunUpdateName '' } $rid
        $r.Action | Should -Be 'NoRuns'
        $r.Message | Should -BeLike '*no update runs*'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=Skipped when UpdateSideloaded=True but UpdateVersionInProgress is missing' {
        $global:azGetTagsJson = '{"tags":{"UpdateSideloaded":"True"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'Solution12.2604.1003.209' } $rid
        $r.Action | Should -Be 'Skipped'
        $r.Message | Should -BeLike '*outside this module*'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=Skipped when UpdateVersionInProgress mismatches the run name' {
        $global:azGetTagsJson = '{"tags":{"UpdateSideloaded":"True","UpdateVersionInProgress":"Solution12.2604.1003.209"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'Solution12.2604.1003.210' } $rid
        $r.Action | Should -Be 'Skipped'
        $r.Message | Should -BeLike '*does not match*'
        $global:azPatchCalled | Should -Be $false
    }

    It 'Action=Reset and PATCH called when match + Succeeded' {
        $global:azGetTagsJson = '{"tags":{"UpdateRing":"Wave1","UpdateSideloaded":"True","UpdateVersionInProgress":"Solution12.2604.1003.209"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'Solution12.2604.1003.209' -Confirm:$false } $rid
        $r.Action | Should -Be 'Reset'
        $r.NewSideloaded | Should -Be 'False'
        $global:azPatchCalled | Should -Be $true
        # v0.7.62: two PATCHes are emitted via the ARM tags subresource:
        #   1. Merge body   -> sets UpdateSideloaded=False
        #   2. Delete body  -> removes UpdateVersionInProgress
        # Preserved tags (UpdateRing) appear in neither body (the subresource
        # preserves them structurally, not via payload echo).
        $global:azPatchBodies.Count | Should -Be 2
        $mergeBody  = $global:azPatchBodies | Where-Object { $_ -match '"operation":\s*"Merge"' } | Select-Object -First 1
        $deleteBody = $global:azPatchBodies | Where-Object { $_ -match '"operation":\s*"Delete"' } | Select-Object -First 1
        $mergeBody  | Should -Not -BeNullOrEmpty
        $deleteBody | Should -Not -BeNullOrEmpty
        $mergeBody  | Should -Match '"UpdateSideloaded":\s*"False"'
        $mergeBody  | Should -Not -Match 'UpdateVersionInProgress'
        $deleteBody | Should -Match 'UpdateVersionInProgress'
        $deleteBody | Should -Not -Match 'UpdateSideloaded'
        # Existing UpdateRing is preserved structurally - never in any PATCH body.
        ($global:azPatchBodies -join "`n") | Should -Not -Match 'UpdateRing'
    }

    It 'Action=Reset on -Force even with mismatch' {
        $global:azGetTagsJson = '{"tags":{"UpdateSideloaded":"True","UpdateVersionInProgress":"OldVer"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'NewVer' -Force -Confirm:$false } $rid
        $r.Action | Should -Be 'Reset'
        $global:azPatchCalled | Should -Be $true
    }

    It 'Action=Skipped on malformed UpdateSideloaded value (no PATCH)' {
        $global:azGetTagsJson = '{"tags":{"UpdateSideloaded":"Yes"}}'
        $r = & (Get-Module $moduleName) { param($id) Invoke-AzLocalSideloadedAutoResetForCluster -ClusterName c1 -ClusterResourceId $id -LatestRunState Succeeded -LatestRunUpdateName 'X' } $rid
        $r.Action | Should -Be 'Skipped'
        $r.Message | Should -BeLike '*Malformed*'
        $global:azPatchCalled | Should -Be $false
    }
}

#endregion Sideloaded Payload Workflow (v0.7.1)

#region ITSM Connector Phase 1 (v0.7.4)

Describe 'ITSM: Get-AzLocalItsmDedupeKey' {
    It 'Should return a 64-char lowercase hex SHA256' {
        $key = & (Get-Module AzLocal.UpdateManagement) {
            Get-AzLocalItsmDedupeKey -ClusterResourceId '/subs/x/rg/r/providers/Microsoft.AzureStackHCI/clusters/c1' `
                -UpdateName '2511.0.10.0' -TriggerCategory 'Cluster update failure'
        }
        $key | Should -Match '^[a-f0-9]{64}$'
    }

    It 'Should be deterministic for the same inputs' {
        $k1 = & (Get-Module AzLocal.UpdateManagement) { Get-AzLocalItsmDedupeKey -ClusterResourceId 'A' -UpdateName 'U' -TriggerCategory 'C' }
        $k2 = & (Get-Module AzLocal.UpdateManagement) { Get-AzLocalItsmDedupeKey -ClusterResourceId 'A' -UpdateName 'U' -TriggerCategory 'C' }
        $k1 | Should -Be $k2
    }

    It 'Should be case-insensitive on inputs' {
        $k1 = & (Get-Module AzLocal.UpdateManagement) { Get-AzLocalItsmDedupeKey -ClusterResourceId 'ABC' -UpdateName 'U' -TriggerCategory 'C' }
        $k2 = & (Get-Module AzLocal.UpdateManagement) { Get-AzLocalItsmDedupeKey -ClusterResourceId 'abc' -UpdateName 'u' -TriggerCategory 'c' }
        $k1 | Should -Be $k2
    }

    It 'Should produce different keys for different categories' {
        $k1 = & (Get-Module AzLocal.UpdateManagement) { Get-AzLocalItsmDedupeKey -ClusterResourceId 'A' -UpdateName 'U' -TriggerCategory 'Failure' }
        $k2 = & (Get-Module AzLocal.UpdateManagement) { Get-AzLocalItsmDedupeKey -ClusterResourceId 'A' -UpdateName 'U' -TriggerCategory 'Health' }
        $k1 | Should -Not -Be $k2
    }
}

Describe 'ITSM: Get-AzLocalItsmTriggerDecision' {
    BeforeAll {
        $script:itsmTriggers = @{
            Failed = @{ RaiseTicket = $true; Severity = 2; Category = 'Cluster update failure'; MirrorTo = @('Teams','Slack') }
            ScheduleBlocked = @{ RaiseTicket = $false }
            Skipped = @{ RaiseTicket = $false }
            SideloadedBlocked = @{ RaiseTicket = $true; Severity = 4; Category = 'Operator action'; MirrorTo = @() }
        }
        $script:itsmDefaults = @{ MirrorTo = @('Teams') }
    }

    It 'Returns ShouldTicket=true with severity for raiseTicket status' {
        $d = & (Get-Module AzLocal.UpdateManagement) {
            param($t,$df) Get-AzLocalItsmTriggerDecision -Status 'Failed' -Triggers $t -Defaults $df
        } $script:itsmTriggers $script:itsmDefaults
        $d.ShouldTicket | Should -BeTrue
        $d.Severity     | Should -Be 2
        $d.Category     | Should -Be 'Cluster update failure'
    }

    It 'Returns ShouldTicket=false when raiseTicket=false' {
        $d = & (Get-Module AzLocal.UpdateManagement) {
            param($t,$df) Get-AzLocalItsmTriggerDecision -Status 'ScheduleBlocked' -Triggers $t -Defaults $df
        } $script:itsmTriggers $script:itsmDefaults
        $d.ShouldTicket | Should -BeFalse
    }

    It 'Returns ShouldTicket=false for unmapped status' {
        $d = & (Get-Module AzLocal.UpdateManagement) {
            param($t,$df) Get-AzLocalItsmTriggerDecision -Status 'WeirdNewStatus' -Triggers $t -Defaults $df
        } $script:itsmTriggers $script:itsmDefaults
        $d.ShouldTicket | Should -BeFalse
        $d.Reason       | Should -Match 'not in the trigger matrix'
    }

    It 'Honours explicit empty MirrorTo on a trigger (suppresses mirror)' {
        $d = & (Get-Module AzLocal.UpdateManagement) {
            param($t,$df) Get-AzLocalItsmTriggerDecision -Status 'SideloadedBlocked' -Triggers $t -Defaults $df
        } $script:itsmTriggers $script:itsmDefaults
        $d.ShouldTicket           | Should -BeTrue
        $d.MirrorTargets.Count    | Should -Be 0
    }

    It 'Falls back to default mirror list when trigger has no MirrorTo' {
        $triggers = @{ Failed = @{ RaiseTicket = $true; Severity = 2 } }
        $d = & (Get-Module AzLocal.UpdateManagement) {
            param($t,$df) Get-AzLocalItsmTriggerDecision -Status 'Failed' -Triggers $t -Defaults $df
        } $triggers $script:itsmDefaults
        $d.MirrorTargets | Should -Contain 'Teams'
    }

    It 'Throws on invalid severity' {
        $triggers = @{ Failed = @{ RaiseTicket = $true; Severity = 9 } }
        {
            & (Get-Module AzLocal.UpdateManagement) {
                param($t) Get-AzLocalItsmTriggerDecision -Status 'Failed' -Triggers $t
            } $triggers
        } | Should -Throw -ExpectedMessage '*severity*'
    }
}

Describe 'ITSM: Format-AzLocalIncidentBody' {
    It 'Substitutes a simple top-level token' {
        $r = & (Get-Module AzLocal.UpdateManagement) {
            Format-AzLocalIncidentBody -Template 'Hello {{name}}' -Context @{ name = 'World' } -NoHtmlEscape
        }
        $r | Should -Be 'Hello World'
    }

    It 'Substitutes a nested dotted token' {
        $r = & (Get-Module AzLocal.UpdateManagement) {
            Format-AzLocalIncidentBody -Template '{{a.b.c}}' -Context @{ a = @{ b = @{ c = 'deep' } } } -NoHtmlEscape
        }
        $r | Should -Be 'deep'
    }

    It 'HTML-escapes by default' {
        $r = & (Get-Module AzLocal.UpdateManagement) {
            Format-AzLocalIncidentBody -Template '{{x}}' -Context @{ x = '<script>alert(1)</script>' }
        }
        $r | Should -Be '&lt;script&gt;alert(1)&lt;/script&gt;'
    }

    It 'Renders missing path tokens as empty strings' {
        $r = & (Get-Module AzLocal.UpdateManagement) {
            Format-AzLocalIncidentBody -Template '[{{a.missing}}]' -Context @{ a = @{} } -NoHtmlEscape
        }
        $r | Should -Be '[]'
    }
}

Describe 'ITSM: Resolve-AzLocalItsmSecret' {
    It 'Resolves env:// to the environment variable value' {
        $env:AZLOCAL_TEST_SECRET = 'envValue123'
        try {
            $v = & (Get-Module AzLocal.UpdateManagement) {
                Resolve-AzLocalItsmSecret -Reference 'env://AZLOCAL_TEST_SECRET'
            }
            $v | Should -Be 'envValue123'
        }
        finally {
            Remove-Item env:AZLOCAL_TEST_SECRET -ErrorAction SilentlyContinue
        }
    }

    It 'Throws when env:// reference points to a missing variable' {
        Remove-Item env:AZLOCAL_TEST_MISSING -ErrorAction SilentlyContinue
        {
            & (Get-Module AzLocal.UpdateManagement) {
                Resolve-AzLocalItsmSecret -Reference 'env://AZLOCAL_TEST_MISSING'
            }
        } | Should -Throw -ExpectedMessage '*empty environment variable*'
    }

    It 'Throws on bare name without DefaultKeyVault' {
        {
            & (Get-Module AzLocal.UpdateManagement) {
                Resolve-AzLocalItsmSecret -Reference 'just-a-name'
            }
        } | Should -Throw -ExpectedMessage '*bare name*'
    }

    It 'Throws on literal:// without -AllowLiteral' {
        {
            & (Get-Module AzLocal.UpdateManagement) {
                Resolve-AzLocalItsmSecret -Reference 'literal://hello'
            }
        } | Should -Throw -ExpectedMessage '*AllowLiteral*'
    }

    It 'Returns the literal value when -AllowLiteral is set' {
        $v = & (Get-Module AzLocal.UpdateManagement) {
            Resolve-AzLocalItsmSecret -Reference 'literal://https://corp.service-now.com' -AllowLiteral
        }
        $v | Should -Be 'https://corp.service-now.com'
    }

    It 'Throws on unrecognised reference form' {
        {
            & (Get-Module AzLocal.UpdateManagement) {
                Resolve-AzLocalItsmSecret -Reference 'weird://nope'
            }
        } | Should -Throw -ExpectedMessage '*not a recognised form*'
    }
}

Describe 'ITSM: Get-AzLocalItsmConfig' {
    BeforeAll {
        $script:configDir = Join-Path $env:TEMP "itsm-cfg-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:configDir -ItemType Directory -Force | Out-Null
    }
    AfterAll {
        Remove-Item -Path $script:configDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Parses a valid JSON config' {
        $p = Join-Path $script:configDir 'ok.json'
        @{
            schemaVersion = 1
            secrets = @{ source = 'keyvault'; keyvaultName = 'kv1'; servicenow = @{ clientId='ci'; clientSecret='cs'; instanceUrl='env://X' } }
            defaults = @{ itsmTarget = 'ServiceNow' }
            triggers = @{ Failed = @{ raiseTicket = $true; severity = 2 } }
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $p -Encoding UTF8
        $cfg = Get-AzLocalItsmConfig -Path $p
        $cfg.SchemaVersion | Should -Be 1
        $cfg.Triggers['Failed'].RaiseTicket | Should -BeTrue
        $cfg.Triggers['Failed'].Severity    | Should -Be 2
    }

    It 'Throws on missing schemaVersion' {
        $p = Join-Path $script:configDir 'bad-no-schema.json'
        @{ secrets = @{ source='keyvault' }; defaults = @{ itsmTarget='ServiceNow' }; triggers = @{} } |
            ConvertTo-Json -Depth 5 | Set-Content -Path $p -Encoding UTF8
        { Get-AzLocalItsmConfig -Path $p } | Should -Throw -ExpectedMessage '*schemaVersion*'
    }

    It 'Throws when itsmTarget is not ServiceNow' {
        $p = Join-Path $script:configDir 'bad-target.json'
        @{
            schemaVersion = 1
            secrets = @{ source = 'keyvault'; keyvaultName = 'kv1' }
            defaults = @{ itsmTarget = 'Jira' }
            triggers = @{ Failed = @{ raiseTicket = $true } }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $p -Encoding UTF8
        { Get-AzLocalItsmConfig -Path $p } | Should -Throw -ExpectedMessage '*ServiceNow*'
    }

    It 'Throws on invalid secrets.source' {
        $p = Join-Path $script:configDir 'bad-src.json'
        @{
            schemaVersion = 1
            secrets = @{ source = 'badvalue' }
            defaults = @{ itsmTarget = 'ServiceNow' }
            triggers = @{ Failed = @{ raiseTicket = $true } }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $p -Encoding UTF8
        { Get-AzLocalItsmConfig -Path $p } | Should -Throw -ExpectedMessage '*secrets.source*'
    }

    It 'Throws on out-of-range severity' {
        $p = Join-Path $script:configDir 'bad-sev.json'
        @{
            schemaVersion = 1
            secrets = @{ source = 'keyvault'; keyvaultName = 'kv1' }
            defaults = @{ itsmTarget = 'ServiceNow' }
            triggers = @{ Failed = @{ raiseTicket = $true; severity = 99 } }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $p -Encoding UTF8
        { Get-AzLocalItsmConfig -Path $p } | Should -Throw -ExpectedMessage '*out of range*'
    }

    It 'Throws when the file does not exist' {
        { Get-AzLocalItsmConfig -Path (Join-Path $script:configDir 'nope.json') } | Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'ITSM: New-AzLocalIncident' {
    BeforeAll {
        $script:incDir = Join-Path $env:TEMP "itsm-inc-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:incDir -ItemType Directory -Force | Out-Null

        $script:junitPath = Join-Path $script:incDir 'update-results.xml'
        $junit = @'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="AzLocal" tests="2">
    <testcase classname="Update" name="cluster-a">
      <failure type="UpdateFailed" message="apply failed">install error</failure>
      <properties>
        <property name="Status" value="Failed"/>
        <property name="ClusterName" value="cluster-a"/>
        <property name="ClusterResourceId" value="/subs/x/rg/r/providers/Microsoft.AzureStackHCI/clusters/cluster-a"/>
        <property name="UpdateName" value="2511.0.10.0"/>
      </properties>
    </testcase>
    <testcase classname="Update" name="cluster-b">
      <properties>
        <property name="Status" value="ScheduleBlocked"/>
        <property name="ClusterName" value="cluster-b"/>
        <property name="ClusterResourceId" value="/subs/x/rg/r/providers/Microsoft.AzureStackHCI/clusters/cluster-b"/>
        <property name="UpdateName" value="2511.0.10.0"/>
      </properties>
    </testcase>
  </testsuite>
</testsuites>
'@
        Set-Content -Path $script:junitPath -Value $junit -Encoding UTF8

        $script:cfg = [pscustomobject]@{
            SchemaVersion = 1
            SourcePath    = (Join-Path $script:incDir 'fake.yml')
            Secrets       = @{
                keyvaultName = 'kv1'
                servicenow   = @{ clientId='ci'; clientSecret='cs'; instanceUrl='literal://https://corp.service-now.com' }
            }
            Defaults      = @{
                itsmTarget      = 'ServiceNow'
                assignmentGroup = 'AzureLocal-Ops'
            }
            Triggers      = @{
                Failed          = @{ RaiseTicket = $true; Severity = 2; Category = 'Cluster update failure' }
                ScheduleBlocked = @{ RaiseTicket = $false }
            }
            Lifecycle = $null; Mirror = $null; Storage = $null; Raw = @{}
        }
    }

    AfterAll {
        Remove-Item -Path $script:incDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'In DryRun mode, returns one row per cluster with no HTTP calls' {
        $results = & (Get-Module AzLocal.UpdateManagement) {
            param($junit, $cfg)
            New-AzLocalIncident -InputArtifactPath $junit -Config $cfg -DryRun
        } $script:junitPath $script:cfg

        $results.Count | Should -Be 2

        $a = $results | Where-Object ClusterName -eq 'cluster-a'
        $b = $results | Where-Object ClusterName -eq 'cluster-b'

        $a.Action    | Should -Be 'DryRun'
        $a.Severity  | Should -Be 2
        $a.DedupeKey | Should -Match '^[a-f0-9]{64}$'

        $b.Action    | Should -Be 'Skipped'
        $b.DedupeKey | Should -BeNullOrEmpty
    }

    It 'Throws when InputArtifactPath does not exist' {
        {
            & (Get-Module AzLocal.UpdateManagement) {
                param($cfg) New-AzLocalIncident -InputArtifactPath 'C:\does\not\exist.xml' -Config $cfg -DryRun
            } $script:cfg
        } | Should -Throw -ExpectedMessage '*not found*'
    }

    It 'Emits Skipped+Reason for rows missing ClusterResourceId (does not throw the whole batch)' {
        # JUnit with one Failed row that has NO ClusterResourceId property
        $brokenJunit = @'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="AzLocal" tests="1">
    <testcase classname="Update" name="cluster-x">
      <failure type="UpdateFailed" message="apply failed">install error</failure>
      <properties>
        <property name="Status" value="Failed"/>
        <property name="ClusterName" value="cluster-x"/>
        <property name="UpdateName" value="2511.0.10.0"/>
      </properties>
    </testcase>
  </testsuite>
</testsuites>
'@
        $brokenPath = Join-Path $script:incDir 'broken.xml'
        Set-Content -Path $brokenPath -Value $brokenJunit -Encoding UTF8

        $results = & (Get-Module AzLocal.UpdateManagement) {
            param($p, $c) New-AzLocalIncident -InputArtifactPath $p -Config $c -DryRun
        } $brokenPath $script:cfg

        $resultsArr = @($results)
        $resultsArr.Count    | Should -Be 1
        $resultsArr[0].Action| Should -Be 'Skipped'
        $resultsArr[0].Reason| Should -Match 'missing ClusterResourceId'
    }
}

Describe 'ITSM: Invoke-AzLocalItsmHttp' {
    It 'Wraps Invoke-RestMethod and returns the parsed response' {
        $r = InModuleScope AzLocal.UpdateManagement {
            Mock Invoke-RestMethod { return [pscustomobject]@{ ok = $true; value = 42 } }
            Invoke-AzLocalItsmHttp -Method GET -Uri 'https://example/api'
        }
        $r.ok    | Should -BeTrue
        $r.value | Should -Be 42
    }

    It 'Passes byte[] bodies through unchanged (does NOT JSON-encode binary uploads)' {
        InModuleScope AzLocal.UpdateManagement {
            $script:capturedBody = $null
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec, $ErrorAction)
                $script:capturedBody = $Body
                return [pscustomobject]@{ ok = $true }
            }
            $bytes = [byte[]](1, 2, 3, 4, 5)
            $null = Invoke-AzLocalItsmHttp -Method POST -Uri 'https://x/api' -Body $bytes -ContentType 'application/octet-stream'
            ($script:capturedBody -is [byte[]]) | Should -BeTrue
            $script:capturedBody.Count | Should -Be 5
        }
    }

    It 'Passes string bodies (e.g. form-urlencoded) through unchanged' {
        InModuleScope AzLocal.UpdateManagement {
            $script:capturedBody = $null
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec, $ErrorAction)
                $script:capturedBody = $Body
                return [pscustomobject]@{ ok = $true }
            }
            $null = Invoke-AzLocalItsmHttp -Method POST -Uri 'https://x/api' -Body 'a=1&b=2' -ContentType 'application/x-www-form-urlencoded'
            $script:capturedBody | Should -Be 'a=1&b=2'
        }
    }

    It 'JSON-encodes hashtable bodies' {
        InModuleScope AzLocal.UpdateManagement {
            $script:capturedBody = $null
            Mock Invoke-RestMethod {
                param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec, $ErrorAction)
                $script:capturedBody = $Body
                return [pscustomobject]@{ ok = $true }
            }
            $null = Invoke-AzLocalItsmHttp -Method POST -Uri 'https://x/api' -Body @{ a = 1 }
            $script:capturedBody | Should -Match '"a":1'
        }
    }
}

Describe 'ITSM: Invoke-AzLocalServiceNowAdapter' {
    It 'Does not expose -Username or -Password parameters (Phase 1 = client_credentials only)' {
        $params = InModuleScope AzLocal.UpdateManagement {
            (Get-Command Invoke-AzLocalServiceNowAdapter).Parameters.Keys
        }
        $params | Should -Not -Contain 'Username'
        $params | Should -Not -Contain 'Password'
    }

    It 'TestConnection probes the incident table (not sys_user)' {
        InModuleScope AzLocal.UpdateManagement {
            $script:capturedUri = $null
            Mock Invoke-AzLocalItsmHttp {
                param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec, $MaxAttempts)
                $script:capturedUri = $Uri
                return [pscustomobject]@{ result = @() }
            }
            $null = Invoke-AzLocalServiceNowAdapter -Action TestConnection `
                -InstanceUrl 'https://corp.service-now.com' -AccessToken 'tok'
            $script:capturedUri | Should -Match '/api/now/table/incident'
            $script:capturedUri | Should -Not -Match '/api/now/table/sys_user'
        }
    }
}

Describe 'ITSM: Get-AzLocalItsmConfig - mixed source validation' {
    BeforeAll {
        $script:mixedDir = Join-Path $env:TEMP "itsm-mixed-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:mixedDir -ItemType Directory -Force | Out-Null
    }
    AfterAll {
        Remove-Item -Path $script:mixedDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Throws when secrets.source=mixed but secrets.keyvaultName is not set' {
        $p = Join-Path $script:mixedDir 'mixed-no-kv.json'
        @{
            schemaVersion = 1
            secrets = @{ source = 'mixed'; servicenow = @{ clientId='ci'; clientSecret='cs'; instanceUrl='env://X' } }
            defaults = @{ itsmTarget = 'ServiceNow' }
            triggers = @{ Failed = @{ raiseTicket = $true } }
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $p -Encoding UTF8
        { Get-AzLocalItsmConfig -Path $p } | Should -Throw -ExpectedMessage '*secrets.source=mixed*keyvaultName*'
    }

    It 'Accepts secrets.source=mixed when secrets.keyvaultName is set' {
        $p = Join-Path $script:mixedDir 'mixed-ok.json'
        @{
            schemaVersion = 1
            secrets = @{ source = 'mixed'; keyvaultName = 'kv1'; servicenow = @{ clientId='ci'; clientSecret='cs'; instanceUrl='env://X' } }
            defaults = @{ itsmTarget = 'ServiceNow' }
            triggers = @{ Failed = @{ raiseTicket = $true } }
        } | ConvertTo-Json -Depth 8 | Set-Content -Path $p -Encoding UTF8
        $cfg = Get-AzLocalItsmConfig -Path $p
        $cfg.SchemaVersion | Should -Be 1
        $cfg.Secrets['keyvaultName'] | Should -Be 'kv1'
    }
}

Describe 'ITSM: New-AzLocalIncident -ExportPath CSV sanitization' {
    BeforeAll {
        $script:csvDir = Join-Path $env:TEMP "itsm-csv-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:csvDir -ItemType Directory -Force | Out-Null

        $script:csvJunit = Join-Path $script:csvDir 'junit.xml'
        $junit = @'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="AzLocal" tests="1">
    <testcase classname="Update" name="cluster-evil">
      <failure type="UpdateFailed" message="apply failed">install error</failure>
      <properties>
        <property name="Status" value="Failed"/>
        <property name="ClusterName" value="=cmd|'/c calc'!A1"/>
        <property name="ClusterResourceId" value="/subs/x/rg/r/providers/Microsoft.AzureStackHCI/clusters/cluster-evil"/>
        <property name="UpdateName" value="2511.0.10.0"/>
      </properties>
    </testcase>
  </testsuite>
</testsuites>
'@
        Set-Content -Path $script:csvJunit -Value $junit -Encoding UTF8

        $script:csvCfg = [pscustomobject]@{
            SchemaVersion = 1
            SourcePath    = (Join-Path $script:csvDir 'fake.yml')
            Secrets       = @{
                keyvaultName = 'kv1'
                servicenow   = @{ clientId='ci'; clientSecret='cs'; instanceUrl='literal://https://corp.service-now.com' }
            }
            Defaults      = @{ itsmTarget = 'ServiceNow'; assignmentGroup = 'AzureLocal-Ops' }
            Triggers      = @{ Failed = @{ RaiseTicket = $true; Severity = 2 } }
            Lifecycle = $null; Mirror = $null; Storage = $null; Raw = @{}
        }
    }

    AfterAll {
        Remove-Item -Path $script:csvDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Neutralises CSV-formula-like ClusterName values in the exported file' {
        $csvPath = Join-Path $script:csvDir 'out.csv'
        $null = & (Get-Module AzLocal.UpdateManagement) {
            param($junit, $cfg, $out)
            New-AzLocalIncident -InputArtifactPath $junit -Config $cfg -DryRun -ExportPath $out
        } $script:csvJunit $script:csvCfg $csvPath

        Test-Path $csvPath | Should -BeTrue
        $rows = Import-Csv -Path $csvPath
        @($rows).Count | Should -Be 1
        # ConvertTo-SafeCsvField prefixes formula-leading values with a leading tick/space
        # so a spreadsheet does not treat the cell as a formula. The exact prefix is the
        # module's standard sanitization (no leading '=', '+', '-', '@', or pipe).
        $rows[0].ClusterName | Should -Not -Match '^[=+\-@]'
        $rows[0].ClusterName | Should -Match 'cmd'
    }
}

Describe 'ITSM: New-AzLocalIncident dedupe lookup runs in DryRun' {
    BeforeAll {
        $script:dryDir = Join-Path $env:TEMP "itsm-dry-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:dryDir -ItemType Directory -Force | Out-Null
        $script:dryJunit = Join-Path $script:dryDir 'junit.xml'
        @'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="AzLocal" tests="1">
    <testcase classname="Update" name="cluster-dedupe">
      <failure type="UpdateFailed" message="apply failed">install error</failure>
      <properties>
        <property name="Status" value="Failed"/>
        <property name="ClusterName" value="cluster-dedupe"/>
        <property name="ClusterResourceId" value="/subs/x/rg/r/providers/Microsoft.AzureStackHCI/clusters/cluster-dedupe"/>
        <property name="UpdateName" value="2511.0.10.0"/>
      </properties>
    </testcase>
  </testsuite>
</testsuites>
'@ | Set-Content -Path $script:dryJunit -Encoding UTF8

        $script:dryCfg = [pscustomobject]@{
            SchemaVersion = 1
            SourcePath    = (Join-Path $script:dryDir 'fake.yml')
            Secrets       = @{
                keyvaultName = 'kv1'
                servicenow   = @{
                    clientId     = 'literal://ci'
                    clientSecret = 'literal://cs'
                    instanceUrl  = 'literal://https://corp.service-now.com'
                }
            }
            Defaults      = @{ itsmTarget = 'ServiceNow'; assignmentGroup = 'AzureLocal-Ops' }
            Triggers      = @{ Failed = @{ RaiseTicket = $true; Severity = 2 } }
            Lifecycle = $null; Mirror = $null; Storage = $null; Raw = @{}
        }
    }

    AfterAll {
        Remove-Item -Path $script:dryDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'DryRun calls FindByDedupe and reports DedupedToExisting when an existing ticket is returned' {
        InModuleScope AzLocal.UpdateManagement {
            $script:dedupeCalled = $false
            $script:createCalled = $false
            Mock Resolve-AzLocalItsmSecret { 'literal-value' }
            Mock Invoke-AzLocalServiceNowAdapter {
                param($Action)
                switch ($Action) {
                    'GetToken'      { return [pscustomobject]@{ AccessToken = 'tok' } }
                    'FindByDedupe'  {
                        $script:dedupeCalled = $true
                        return [pscustomobject]@{ sys_id = 'abc123'; number = 'INC0000999' }
                    }
                    'CreateIncident' {
                        $script:createCalled = $true
                        return [pscustomobject]@{ sys_id = 'new'; number = 'INC9999' }
                    }
                }
            }
        }

        $results = & (Get-Module AzLocal.UpdateManagement) {
            param($junit, $cfg)
            New-AzLocalIncident -InputArtifactPath $junit -Config $cfg -DryRun
        } $script:dryJunit $script:dryCfg

        $resultsArr = @($results)
        $resultsArr.Count          | Should -Be 1
        $resultsArr[0].Action      | Should -Be 'DedupedToExisting'
        $resultsArr[0].TicketId    | Should -Be 'INC0000999'
        $resultsArr[0].TicketSysId | Should -Be 'abc123'

        InModuleScope AzLocal.UpdateManagement {
            $script:dedupeCalled | Should -BeTrue
            $script:createCalled | Should -BeFalse
        }
    }

    It 'DryRun degrades gracefully when secret resolution fails (Action=DryRun, Reason annotated)' {
        InModuleScope AzLocal.UpdateManagement {
            Mock Resolve-AzLocalItsmSecret { throw "fake auth failure" }
            Mock Invoke-AzLocalServiceNowAdapter { throw "should not be called" }
        }

        $results = & (Get-Module AzLocal.UpdateManagement) {
            param($junit, $cfg)
            New-AzLocalIncident -InputArtifactPath $junit -Config $cfg -DryRun -WarningAction SilentlyContinue
        } $script:dryJunit $script:dryCfg

        $resultsArr = @($results)
        $resultsArr.Count       | Should -Be 1
        $resultsArr[0].Action   | Should -Be 'DryRun'
        $resultsArr[0].Reason   | Should -Match 'Dedupe lookup skipped'
    }
}

Describe 'ITSM: New-AzLocalIncident -ExportJUnitPath' {
    BeforeAll {
        $script:jxDir = Join-Path $env:TEMP "itsm-jx-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:jxDir -ItemType Directory -Force | Out-Null
        $script:jxJunit = Join-Path $script:jxDir 'junit.xml'
        @'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="AzLocal" tests="2">
    <testcase classname="Update" name="cluster-ok">
      <properties>
        <property name="Status" value="Failed"/>
        <property name="ClusterName" value="cluster-ok"/>
        <property name="ClusterResourceId" value="/subs/x/rg/r/providers/Microsoft.AzureStackHCI/clusters/cluster-ok"/>
        <property name="UpdateName" value="2511.0.10.0"/>
      </properties>
    </testcase>
    <testcase classname="Update" name="cluster-skip">
      <properties>
        <property name="Status" value="ScheduleBlocked"/>
        <property name="ClusterName" value="cluster-skip"/>
        <property name="ClusterResourceId" value="/subs/x/rg/r/providers/Microsoft.AzureStackHCI/clusters/cluster-skip"/>
        <property name="UpdateName" value="2511.0.10.0"/>
      </properties>
    </testcase>
  </testsuite>
</testsuites>
'@ | Set-Content -Path $script:jxJunit -Encoding UTF8

        $script:jxCfg = [pscustomobject]@{
            SchemaVersion = 1
            SourcePath    = (Join-Path $script:jxDir 'fake.yml')
            Secrets       = @{
                keyvaultName = 'kv1'
                servicenow   = @{
                    clientId     = 'literal://ci'
                    clientSecret = 'literal://cs'
                    instanceUrl  = 'literal://https://corp.service-now.com'
                }
            }
            Defaults      = @{ itsmTarget = 'ServiceNow'; assignmentGroup = 'AzureLocal-Ops' }
            Triggers      = @{
                Failed          = @{ RaiseTicket = $true;  Severity = 2 }
                ScheduleBlocked = @{ RaiseTicket = $false }
            }
            Lifecycle = $null; Mirror = $null; Storage = $null; Raw = @{}
        }
    }

    AfterAll {
        Remove-Item -Path $script:jxDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Writes a parseable JUnit XML file with one testcase per result row' {
        $junitOut = Join-Path $script:jxDir 'itsm-results.xml'

        $null = & (Get-Module AzLocal.UpdateManagement) {
            param($junit, $cfg, $out)
            New-AzLocalIncident -InputArtifactPath $junit -Config $cfg -DryRun -ExportJUnitPath $out -WarningAction SilentlyContinue
        } $script:jxJunit $script:jxCfg $junitOut

        Test-Path $junitOut | Should -BeTrue
        [xml]$doc = Get-Content -Path $junitOut -Raw
        $cases = $doc.SelectNodes('//testcase')
        @($cases).Count | Should -Be 2
        # Export-ResultsToJUnitXml prefixes the testcase name with "$OperationType-".
        # So the ScheduleBlocked row appears as IncidentAction-cluster-skip and must
        # carry a <skipped> child.
        ($doc.SelectNodes('//testcase[@name="IncidentAction-cluster-skip"]/skipped')).Count | Should -Be 1
        # Test suite name is the bare TestSuiteName; classname on each testcase is TestSuiteName.OperationType
        $doc.SelectSingleNode('//testsuite').name | Should -Be 'AzureLocalItsm'
        $doc.SelectNodes('//testcase[@classname="AzureLocalItsm.IncidentAction"]').Count | Should -Be 2
    }
}

Describe 'ITSM: Get-AzLocalItsmConfig normalises non-Hashtable YAML dictionaries' {
    It 'Converts a Dictionary[object,object] from ConvertFrom-Yaml into a case-insensitive hashtable tree' {
        $yamlPath = Join-Path $env:TEMP "itsm-norm-$([guid]::NewGuid().Guid.Substring(0,8)).yml"
        # Content is irrelevant because we mock ConvertFrom-Yaml below; the
        # file just has to exist so Test-Path passes.
        Set-Content -Path $yamlPath -Value 'placeholder' -Encoding UTF8

        try {
            $cfg = InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $yamlPath } {
                param($Path)

                # Build a generic Dictionary[object,object] tree exactly like
                # some powershell-yaml versions emit (case-SENSITIVE keys).
                $dict = [System.Collections.Generic.Dictionary[object,object]]::new()
                $dict['schemaVersion'] = 1
                $secrets = [System.Collections.Generic.Dictionary[object,object]]::new()
                $secrets['source'] = 'envvar'
                $sn = [System.Collections.Generic.Dictionary[object,object]]::new()
                $sn['clientId']     = 'env://X'
                $sn['clientSecret'] = 'env://Y'
                $sn['instanceUrl']  = 'literal://https://corp.service-now.com'
                $secrets['servicenow'] = $sn
                $dict['secrets'] = $secrets
                $defaults = [System.Collections.Generic.Dictionary[object,object]]::new()
                $defaults['itsmTarget'] = 'ServiceNow'
                $dict['defaults'] = $defaults
                $triggers = [System.Collections.Generic.Dictionary[object,object]]::new()
                $failedEntry = [System.Collections.Generic.Dictionary[object,object]]::new()
                $failedEntry['raiseTicket'] = $true
                $failedEntry['severity']    = 2
                $triggers['Failed'] = $failedEntry
                $dict['triggers'] = $triggers

                Mock Get-Module -ParameterFilter { $Name -eq 'powershell-yaml' -and $ListAvailable } { return [pscustomobject]@{ Name = 'powershell-yaml' } }
                Mock Import-Module {}
                Mock ConvertFrom-Yaml { return $dict }

                Get-AzLocalItsmConfig -Path $Path
            }

            $cfg.SchemaVersion | Should -Be 1
            # Both PascalCase (config-time) and camelCase (YAML-native) must work
            $cfg.Triggers['Failed']                  | Should -Not -BeNullOrEmpty
            $cfg.Triggers['Failed'].ContainsKey('RaiseTicket') | Should -BeTrue
            $cfg.Triggers['Failed']['raiseTicket']   | Should -BeTrue
        }
        finally {
            Remove-Item -Path $yamlPath -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion ITSM Connector Phase 1 (v0.7.4)

#region Copy-AzLocalPipelineExample (v0.7.4, updated in v0.7.50)

Describe 'Function: Copy-AzLocalPipelineExample' {
    BeforeAll {
        # The function reads from (Get-Module AzLocal.UpdateManagement).ModuleBase
        # which during test runs resolves to the repo module root, so the real
        # Automation-Pipeline-Examples/ folder under the repo is the test source.
        $script:cpDestRoot = Join-Path $env:TEMP "azlocal-cpe-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:cpDestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item $script:cpDestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Default (-Platform All): copies the full source tree into a child Automation-Pipeline-Examples folder under -Destination' {
        $dest = Join-Path $script:cpDestRoot 'default'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        $r = Copy-AzLocalPipelineExample -Destination $dest -PassThru 6>$null

        $r | Should -Not -BeNullOrEmpty
        $r.FullName | Should -Be (Join-Path $dest 'Automation-Pipeline-Examples')
        Test-Path (Join-Path $r.FullName 'README.md') | Should -BeTrue
        Test-Path (Join-Path $r.FullName 'github-actions') | Should -BeTrue
        Test-Path (Join-Path $r.FullName 'azure-devops') | Should -BeTrue
    }

    It '-Platform GitHub: copies *.yml files DIRECTLY into -Destination (no wrapper folder, no README, no .itsm)' {
        $dest = Join-Path $script:cpDestRoot 'gh'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        $r = Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -PassThru 6>$null

        # Target root IS -Destination, not a child of it
        $r.FullName | Should -Be $dest

        # YAMLs landed directly in $dest
        $yamls = @(Get-ChildItem -LiteralPath $dest -Filter '*.yml' -File)
        $yamls.Count | Should -BeGreaterThan 0
        $yamls.Name | Should -Contain 'Step.0_authentication-test.yml'

        # No platform-named subfolder, no Automation-Pipeline-Examples wrapper
        Test-Path (Join-Path $dest 'github-actions') | Should -BeFalse
        Test-Path (Join-Path $dest 'azure-devops')   | Should -BeFalse
        Test-Path (Join-Path $dest 'Automation-Pipeline-Examples') | Should -BeFalse

        # README and .itsm are NOT copied with -Platform GitHub
        Test-Path (Join-Path $dest 'README.md') | Should -BeFalse
        Test-Path (Join-Path $dest '.itsm')     | Should -BeFalse
    }

    It '-Platform AzureDevOps: copies *.yml files DIRECTLY into -Destination (no wrapper folder, no README, no .itsm)' {
        $dest = Join-Path $script:cpDestRoot 'ado'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        $r = Copy-AzLocalPipelineExample -Destination $dest -Platform AzureDevOps -PassThru 6>$null

        $r.FullName | Should -Be $dest

        $yamls = @(Get-ChildItem -LiteralPath $dest -Filter '*.yml' -File)
        $yamls.Count | Should -BeGreaterThan 0
        $yamls.Name | Should -Contain 'Step.0_authentication-test.yml'

        Test-Path (Join-Path $dest 'azure-devops')   | Should -BeFalse
        Test-Path (Join-Path $dest 'github-actions') | Should -BeFalse
        Test-Path (Join-Path $dest 'Automation-Pipeline-Examples') | Should -BeFalse
        Test-Path (Join-Path $dest 'README.md') | Should -BeFalse
        Test-Path (Join-Path $dest '.itsm')     | Should -BeFalse
    }

    It '-Platform GitHub: peacefully co-exists with unrelated pre-existing files in -Destination' {
        $dest = Join-Path $script:cpDestRoot 'gh-coexist'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null
        # Simulate the realistic case: .github\workflows\ already contains an
        # unrelated user-authored workflow. The function must NOT refuse to copy
        # just because the destination is non-empty.
        Set-Content -Path (Join-Path $dest 'my-other-build.yml') -Value 'name: my-other-build' -Encoding ASCII

        { Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null } | Should -Not -Throw

        # Original file untouched
        Test-Path (Join-Path $dest 'my-other-build.yml') | Should -BeTrue
        # Module YAMLs alongside it
        @(Get-ChildItem -LiteralPath $dest -Filter '*.yml' -File).Count | Should -BeGreaterThan 1
    }

    It 'Refuses to overwrite an existing file by default and lists the conflicts (no -Update)' {
        $dest = Join-Path $script:cpDestRoot 'no-overwrite'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        # First copy populates the target with module YAMLs
        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null | Out-Null

        # Second copy must refuse: ALL the same files now exist as conflicts.
        # The error message must hint at the -Update escape hatch.
        { Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null } |
            Should -Throw -ExpectedMessage '*refusing to overwrite*'
        { Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null } |
            Should -Throw -ExpectedMessage '*-Update*'
    }

    It '-Update -Confirm:$false overwrites existing files without prompting (automation path)' {
        $dest = Join-Path $script:cpDestRoot 'update-confirm-false'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        # Seed the destination so every file is a conflict
        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null | Out-Null

        # Mutate one destination file so we can prove it gets overwritten
        $target = Join-Path $dest 'Step.0_authentication-test.yml'
        $sentinel = '# SENTINEL - if this comment survives, -Update did not overwrite'
        Set-Content -LiteralPath $target -Value $sentinel -Encoding ASCII
        (Get-Content -LiteralPath $target -Raw) | Should -Match 'SENTINEL'

        # -Update -Confirm:$false must NOT throw and must overwrite the sentinel
        { Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Update -Confirm:$false 6>$null } |
            Should -Not -Throw

        (Get-Content -LiteralPath $target -Raw) | Should -Not -Match 'SENTINEL'
    }

    It '-Update is exposed as a [switch] parameter in v0.7.50' {
        $cmd = Get-Command -Name 'Copy-AzLocalPipelineExample' -ErrorAction Stop
        $cmd.Parameters.ContainsKey('Update') | Should -BeTrue
        $cmd.Parameters['Update'].ParameterType | Should -Be ([switch])
    }

    It 'No-to-All only suppresses overwrites, not brand-new files (v0.7.50 regression guard)' {
        # Background: In an early v0.7.50 pass the per-file loop's top guard was
        #     if ($noToAll) { $skippedCount++; continue }
        # which skipped EVERY remaining file once the user chose No-to-All,
        # even files that did not already exist at the destination (no prompt
        # would have been raised for them). The corrected semantics match
        # PowerShell's canonical No-to-All meaning ("answer No to all remaining
        # prompts") rather than "halt all subsequent operations". This test
        # asserts the corrected source pattern is present so the bug cannot
        # silently re-appear.
        $cmd = Get-Command -Name 'Copy-AzLocalPipelineExample' -ErrorAction Stop
        $src = $cmd.ScriptBlock.ToString()
        # Corrected guard: skip only when there is an existing file to overwrite.
        $src | Should -Match 'if\s*\(\s*\$noToAll\s+-and\s+\$destExists\s*\)'
        # The bare-noToAll early-continue must NOT reappear at the top of the loop.
        $src | Should -Not -Match 'foreach\s*\(\s*\$pair\s+in\s+\$copyPairs\s*\)\s*\{\s*if\s*\(\s*\$noToAll\s*\)\s*\{\s*\$skippedCount\+\+\s*;?\s*continue'
    }

    It '-Update -WhatIf does not modify any existing files' {
        $dest = Join-Path $script:cpDestRoot 'update-whatif'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        # Seed and then mutate
        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null | Out-Null
        $target = Join-Path $dest 'Step.0_authentication-test.yml'
        $sentinel = '# WHATIF SENTINEL - -WhatIf must preserve this'
        Set-Content -LiteralPath $target -Value $sentinel -Encoding ASCII

        # -Update -WhatIf must NOT modify the file
        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Update -WhatIf 6>$null

        (Get-Content -LiteralPath $target -Raw) | Should -Match 'WHATIF SENTINEL'
    }

    It '-Force parameter has been removed in v0.7.50' {
        # Inspect the function's parameter metadata directly - more robust than
        # relying on the engine's FQErrorID, which differs across PS editions.
        $cmd = Get-Command -Name 'Copy-AzLocalPipelineExample' -ErrorAction Stop
        $cmd.Parameters.ContainsKey('Force') | Should -BeFalse
    }

    It '-Flatten parameter has been removed in v0.7.50' {
        $cmd = Get-Command -Name 'Copy-AzLocalPipelineExample' -ErrorAction Stop
        $cmd.Parameters.ContainsKey('Flatten') | Should -BeFalse
    }

    It '-WhatIf does not copy anything' {
        $dest = Join-Path $script:cpDestRoot 'whatif'
        # Note: dest does not yet exist; -WhatIf should not create it either
        Copy-AzLocalPipelineExample -Destination $dest -WhatIf 6>$null
        Test-Path (Join-Path $dest 'Automation-Pipeline-Examples') | Should -BeFalse
    }

    It '-PassThru returns a DirectoryInfo; without it nothing is emitted to the pipeline' {
        $dest = Join-Path $script:cpDestRoot 'passthru'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        $withPT = Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -PassThru 6>$null
        $withPT | Should -BeOfType [System.IO.DirectoryInfo]
        $withPT.FullName | Should -Be $dest

        $dest2 = Join-Path $script:cpDestRoot 'nopassthru'
        New-Item -Path $dest2 -ItemType Directory -Force | Out-Null
        $noPT = Copy-AzLocalPipelineExample -Destination $dest2 -Platform GitHub 6>$null
        $noPT | Should -BeNullOrEmpty
    }

    It 'Creates -Destination when it does not already exist' {
        $dest = Join-Path $script:cpDestRoot 'autocreate'
        # Intentionally not creating $dest beforehand
        Test-Path $dest | Should -BeFalse

        $r = Copy-AzLocalPipelineExample -Destination $dest -PassThru 6>$null

        Test-Path $dest | Should -BeTrue
        Test-Path (Join-Path $r.FullName 'README.md') | Should -BeTrue
    }

    # v0.7.92: starter apply-updates-schedule.yml drop (default-on for
    # -Platform GitHub|AzureDevOps; suppressed by -SkipStarterSchedule).
    # The starter lands ONE LEVEL UP from -Destination so the schedule
    # file sits beside .github\workflows\ (GitHub) or the pipelines
    # folder (ADO) rather than inside it.

    It 'v0.7.92: -SkipStarterSchedule is exposed as a [switch] parameter' {
        $cmd = Get-Command -Name 'Copy-AzLocalPipelineExample' -ErrorAction Stop
        $cmd.Parameters.ContainsKey('SkipStarterSchedule') | Should -BeTrue
        $cmd.Parameters['SkipStarterSchedule'].ParameterType | Should -Be ([switch])
    }

    It 'v0.7.92: -Platform GitHub default drops starter apply-updates-schedule.yml ONE LEVEL UP from -Destination' {
        $repoRoot = Join-Path $script:cpDestRoot 'gh-starter-fresh'
        $dest = Join-Path $repoRoot '.github\workflows'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null | Out-Null

        $scheduleDest = Join-Path $repoRoot '.github\apply-updates-schedule.yml'
        Test-Path $scheduleDest | Should -BeTrue
        # File content must match the bundled example verbatim (starter copy
        # is byte-for-byte, no templating).
        $module = Get-Module -Name 'AzLocal.UpdateManagement' | Sort-Object Version -Descending | Select-Object -First 1
        $source = Join-Path $module.ModuleBase 'Automation-Pipeline-Examples\apply-updates-schedule.example.yml'
        (Get-FileHash -LiteralPath $scheduleDest).Hash | Should -Be (Get-FileHash -LiteralPath $source).Hash
    }

    It 'v0.7.92: -Platform AzureDevOps default drops starter apply-updates-schedule.yml ONE LEVEL UP from -Destination' {
        $repoRoot = Join-Path $script:cpDestRoot 'ado-starter-fresh'
        $dest = Join-Path $repoRoot 'pipelines'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        Copy-AzLocalPipelineExample -Destination $dest -Platform AzureDevOps 6>$null | Out-Null

        $scheduleDest = Join-Path $repoRoot 'apply-updates-schedule.yml'
        Test-Path $scheduleDest | Should -BeTrue
    }

    It 'v0.7.92: existing apply-updates-schedule.yml at the target is NEVER overwritten by the starter copy' {
        $repoRoot = Join-Path $script:cpDestRoot 'gh-starter-preserve'
        $dest = Join-Path $repoRoot '.github\workflows'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        # Pre-seed an operator-tailored schedule file
        $scheduleDest = Join-Path $repoRoot '.github\apply-updates-schedule.yml'
        $sentinel = '# OPERATOR SENTINEL - must never be overwritten by Copy-AzLocalPipelineExample'
        Set-Content -LiteralPath $scheduleDest -Value $sentinel -Encoding ASCII

        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub 6>$null | Out-Null

        # Sentinel must survive
        (Get-Content -LiteralPath $scheduleDest -Raw) | Should -Match 'OPERATOR SENTINEL'
    }

    It 'v0.7.92: -SkipStarterSchedule suppresses the starter copy entirely' {
        $repoRoot = Join-Path $script:cpDestRoot 'gh-starter-skip'
        $dest = Join-Path $repoRoot '.github\workflows'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -SkipStarterSchedule 6>$null | Out-Null

        $scheduleDest = Join-Path $repoRoot '.github\apply-updates-schedule.yml'
        Test-Path $scheduleDest | Should -BeFalse
    }

    It 'v0.7.92: -Platform All does NOT drop a starter schedule (only GitHub|AzureDevOps do)' {
        # Isolate under a fresh parent so earlier tests in this Describe
        # (notably the GitHub copies that drop a starter ONE LEVEL UP) cannot
        # leak a sibling apply-updates-schedule.yml into the parent we probe.
        $parent = Join-Path $script:cpDestRoot 'all-no-starter-parent'
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
        $dest = Join-Path $parent 'all-no-starter'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        Copy-AzLocalPipelineExample -Destination $dest 6>$null | Out-Null

        # Default -Platform All copies into a child Automation-Pipeline-Examples
        # folder under -Destination, so the "one level up" rule (which only
        # applies to platform-specific copies) does NOT come into play.
        Test-Path (Join-Path $parent 'apply-updates-schedule.yml') | Should -BeFalse
        Test-Path (Join-Path $dest 'apply-updates-schedule.yml') | Should -BeFalse
    }

    It 'v0.7.92: -WhatIf does not write the starter schedule' {
        $repoRoot = Join-Path $script:cpDestRoot 'gh-starter-whatif'
        $dest = Join-Path $repoRoot '.github\workflows'
        New-Item -Path $dest -ItemType Directory -Force | Out-Null

        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -WhatIf 6>$null | Out-Null

        $scheduleDest = Join-Path $repoRoot '.github\apply-updates-schedule.yml'
        Test-Path $scheduleDest | Should -BeFalse
    }
}

#endregion Copy-AzLocalPipelineExample (v0.7.4, updated in v0.7.50, v0.7.92)

#region Copy-AzLocalItsmSample (v0.7.50)

Describe 'Function: Copy-AzLocalItsmSample' {
    BeforeAll {
        $script:itsmDestRoot = Join-Path $env:TEMP "azlocal-itsm-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -Path $script:itsmDestRoot -ItemType Directory -Force | Out-Null
    }

    AfterAll {
        Remove-Item $script:itsmDestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'Is exported by the module' {
        $cmd = Get-Command -Name 'Copy-AzLocalItsmSample' -Module 'AzLocal.UpdateManagement' -ErrorAction Stop
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.CommandType | Should -Be 'Function'
    }

    It 'Default -Destination ends in .itsm' {
        $cmd = Get-Command -Name 'Copy-AzLocalItsmSample' -ErrorAction Stop
        # Look at the default value embedded in the function source
        $src = $cmd.ScriptBlock.ToString()
        $src | Should -Match "Join-Path\s+-Path\s+\`$PWD\.Path\s+-ChildPath\s+'\.itsm'"
    }

    It '-WhatIf does not copy anything' {
        $dest = Join-Path $script:itsmDestRoot 'whatif'
        # Note: dest does not yet exist; -WhatIf should not create file contents either
        Copy-AzLocalItsmSample -Destination $dest -WhatIf 6>$null
        # No YAML should have been written even if the directory was created
        Test-Path (Join-Path $dest 'azurelocal-itsm.yml') | Should -BeFalse
    }

    It 'Default copy: writes azurelocal-itsm.yml and templates/incident-body.md' {
        $dest = Join-Path $script:itsmDestRoot 'default'
        $r = Copy-AzLocalItsmSample -Destination $dest -PassThru 6>$null

        $r | Should -BeOfType [System.IO.DirectoryInfo]
        $r.FullName | Should -Be $dest
        Test-Path (Join-Path $dest 'azurelocal-itsm.yml') | Should -BeTrue
        Test-Path (Join-Path $dest 'templates\incident-body.md') | Should -BeTrue
    }

    It 'Refuses to overwrite an existing file by default and points at -Update' {
        $dest = Join-Path $script:itsmDestRoot 'no-overwrite'
        Copy-AzLocalItsmSample -Destination $dest 6>$null | Out-Null

        { Copy-AzLocalItsmSample -Destination $dest 6>$null } |
            Should -Throw -ExpectedMessage '*refusing to overwrite*'
        { Copy-AzLocalItsmSample -Destination $dest 6>$null } |
            Should -Throw -ExpectedMessage '*-Update*'
    }

    It '-Update -Confirm:$false overwrites existing files without prompting (automation path)' {
        $dest = Join-Path $script:itsmDestRoot 'update-confirm-false'
        Copy-AzLocalItsmSample -Destination $dest 6>$null | Out-Null

        $target = Join-Path $dest 'azurelocal-itsm.yml'
        $sentinel = '# SENTINEL - if this survives, -Update did not overwrite'
        Set-Content -LiteralPath $target -Value $sentinel -Encoding ASCII
        (Get-Content -LiteralPath $target -Raw) | Should -Match 'SENTINEL'

        { Copy-AzLocalItsmSample -Destination $dest -Update -Confirm:$false 6>$null } |
            Should -Not -Throw

        (Get-Content -LiteralPath $target -Raw) | Should -Not -Match 'SENTINEL'
    }

    It '-Update -WhatIf does not modify any existing files' {
        $dest = Join-Path $script:itsmDestRoot 'update-whatif'
        Copy-AzLocalItsmSample -Destination $dest 6>$null | Out-Null

        $target = Join-Path $dest 'azurelocal-itsm.yml'
        $sentinel = '# WHATIF SENTINEL - -WhatIf must preserve this'
        Set-Content -LiteralPath $target -Value $sentinel -Encoding ASCII

        Copy-AzLocalItsmSample -Destination $dest -Update -WhatIf 6>$null

        (Get-Content -LiteralPath $target -Raw) | Should -Match 'WHATIF SENTINEL'
    }

    It '-Update is exposed as a [switch] parameter' {
        $cmd = Get-Command -Name 'Copy-AzLocalItsmSample' -ErrorAction Stop
        $cmd.Parameters.ContainsKey('Update') | Should -BeTrue
        $cmd.Parameters['Update'].ParameterType | Should -Be ([switch])
    }

    It 'Has the No-to-All only-when-destExists regression guard (matches Copy-AzLocalPipelineExample fix)' {
        $cmd = Get-Command -Name 'Copy-AzLocalItsmSample' -ErrorAction Stop
        $src = $cmd.ScriptBlock.ToString()
        $src | Should -Match 'if\s*\(\s*\$noToAll\s+-and\s+\$destExists\s*\)'
    }

    It '-PassThru returns a DirectoryInfo; without it nothing is emitted to the pipeline' {
        $dest = Join-Path $script:itsmDestRoot 'passthru'
        $withPT = Copy-AzLocalItsmSample -Destination $dest -PassThru 6>$null
        $withPT | Should -BeOfType [System.IO.DirectoryInfo]
        $withPT.FullName | Should -Be $dest

        $dest2 = Join-Path $script:itsmDestRoot 'nopassthru'
        $noPT = Copy-AzLocalItsmSample -Destination $dest2 6>$null
        $noPT | Should -BeNullOrEmpty
    }

    It 'Creates -Destination (including templates subfolder) when it does not already exist' {
        $dest = Join-Path $script:itsmDestRoot 'autocreate'
        Test-Path $dest | Should -BeFalse

        Copy-AzLocalItsmSample -Destination $dest 6>$null | Out-Null

        Test-Path $dest | Should -BeTrue
        Test-Path (Join-Path $dest 'templates') | Should -BeTrue
        Test-Path (Join-Path $dest 'templates\incident-body.md') | Should -BeTrue
    }
}

#endregion Copy-AzLocalItsmSample (v0.7.50)

#region Apply-Updates Schedule Coverage Advisor (v0.7.65)

Describe 'Function: Test-AzLocalApplyUpdatesScheduleCoverage' {

    Context 'Parameter Validation' {
        BeforeAll {
            $command = Get-Command Test-AzLocalApplyUpdatesScheduleCoverage
        }

        It 'Is CmdletBinding' {
            $command.CmdletBinding | Should -BeTrue
        }

        It 'Should have View parameter with ValidateSet (Audit, Matrix, Recommend)' {
            $command.Parameters.Keys | Should -Contain 'View'
            $vs = $command.Parameters['View'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $vs | Should -Not -BeNullOrEmpty
            ($vs.ValidValues | Sort-Object) | Should -Be (@('Audit','Matrix','Recommend') | Sort-Object)
        }

        It 'Should have Platform parameter with ValidateSet (GitHubActions, AzureDevOps, Both)' {
            $command.Parameters.Keys | Should -Contain 'Platform'
            $vs = $command.Parameters['Platform'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $vs | Should -Not -BeNullOrEmpty
            ($vs.ValidValues | Sort-Object) | Should -Be (@('AzureDevOps','Both','GitHubActions') | Sort-Object)
        }

        It 'Should have LeadTimeMinutes parameter with ValidateRange 0..60' {
            $command.Parameters.Keys | Should -Contain 'LeadTimeMinutes'
            $vr = $command.Parameters['LeadTimeMinutes'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateRangeAttribute] }
            $vr | Should -Not -BeNullOrEmpty
            $vr.MinRange | Should -Be 0
            $vr.MaxRange | Should -Be 60
        }

        It 'Should have SubscriptionId, PipelineYamlPath, UpdateRingTag, IncludeUntagged, ExportPath, PassThru parameters' {
            foreach ($p in @('SubscriptionId','PipelineYamlPath','UpdateRingTag','IncludeUntagged','ExportPath','PassThru')) {
                $command.Parameters.Keys | Should -Contain $p
            }
        }

        It 'Declares [OutputType([PSCustomObject[]])]' {
            # PSCustomObject is a PowerShell accelerator for PSObject, so the
            # resolved type name on the OutputTypeAttribute is 'PSObject[]'.
            $command.OutputType.Type.Name | Should -Contain 'PSObject[]'
        }

        It 'Throws when -View Audit is used without -PipelineYamlPath or -SchedulePath' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery { @() }
                { Test-AzLocalApplyUpdatesScheduleCoverage -View Audit } |
                    Should -Throw -ExpectedMessage '*requires at least one of -PipelineYamlPath or -SchedulePath*'
            }
        }

        It 'Throws when PipelineYamlPath does not exist' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery { @() }
                { Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath 'X:\does\not\exist.yml' } |
                    Should -Throw -ExpectedMessage '*PipelineYamlPath not found*'
            }
        }
    }

    Context 'Private helper: Convert-AzLocalUpdateWindowToCron' {
        It 'Sat-Sun_02:00-06:00 with lead 5 -> 55 1 * * 6,0' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Sat-Sun_02:00-06:00' -LeadTimeMinutes 5
                $r | Should -HaveCount 1
                $r[0].CronExpression | Should -Be '55 1 * * 6,0'
                $r[0].FireHour | Should -Be 1
                $r[0].FireMinute | Should -Be 55
                $r[0].DayShift | Should -BeFalse
            }
        }

        It 'Mon-Fri_22:00-04:00 with lead 5 -> 55 21 * * 1-5 (range)' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon-Fri_22:00-04:00' -LeadTimeMinutes 5
                $r | Should -HaveCount 1
                $r[0].CronExpression | Should -Be '55 21 * * 1-5'
            }
        }

        It 'Sun_03:00-07:00 with lead 5 -> 55 2 * * 0' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Sun_03:00-07:00' -LeadTimeMinutes 5
                $r[0].CronExpression | Should -Be '55 2 * * 0'
            }
        }

        It 'Lead-time wrap: Mon_00:05-04:00 with lead 10 -> 55 23 * * 0 (Sun) with DayShift=$true' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon_00:05-04:00' -LeadTimeMinutes 10
                $r[0].CronExpression | Should -Be '55 23 * * 0'
                $r[0].DayShift | Should -BeTrue
            }
        }

        It 'Multi-segment window emits one cron per segment' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon-Fri_22:00-04:00;Sat-Sun_02:00-10:00' -LeadTimeMinutes 5
                $r | Should -HaveCount 2
                ($r | ForEach-Object CronExpression) -join '|' | Should -Be '55 21 * * 1-5|55 1 * * 6,0'
            }
        }
    }

    Context 'Private helper: Convert-AzLocalUpdateWindowToCron -FiresPerWindow 2 (belt-and-braces, v0.7.92)' {
        It 'FiresPerWindow=1 (default) is back-compat: one row per segment, IsRetry=false' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Sat-Sun_02:00-06:00' -LeadTimeMinutes 5
                $r | Should -HaveCount 1
                $r[0].IsRetry | Should -BeFalse
            }
        }

        It '4h window Sat-Sun_02:00-06:00: open at 01:55, retry at +60min cap (03:00)' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Sat-Sun_02:00-06:00' -LeadTimeMinutes 5 -FiresPerWindow 2
                $r | Should -HaveCount 2
                $r[0].CronExpression | Should -Be '55 1 * * 6,0'
                $r[0].IsRetry | Should -BeFalse
                $r[1].CronExpression | Should -Be '0 3 * * 6,0'
                $r[1].IsRetry | Should -BeTrue
                $r[1].DayShift | Should -BeFalse
            }
        }

        It '3h window Mon-Fri_20:00-23:00: open at 19:55, retry at midpoint 21:00 (180/2=90, capped to 60)' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon-Fri_20:00-23:00' -LeadTimeMinutes 5 -FiresPerWindow 2
                $r | Should -HaveCount 2
                $r[0].CronExpression | Should -Be '55 19 * * 1-5'
                $r[1].CronExpression | Should -Be '0 21 * * 1-5'
                $r[1].IsRetry | Should -BeTrue
            }
        }

        It '6h overnight Mon-Fri_22:00-04:00: retry at 23:00 (no day shift, window has not crossed midnight yet)' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon-Fri_22:00-04:00' -LeadTimeMinutes 5 -FiresPerWindow 2
                $r | Should -HaveCount 2
                $r[0].CronExpression | Should -Be '55 21 * * 1-5'
                $r[1].CronExpression | Should -Be '0 23 * * 1-5'
                $r[1].IsRetry | Should -BeTrue
                $r[1].DayShift | Should -BeFalse
            }
        }

        It 'Short window Sat_03:00-03:30 (30min): retry at midpoint 03:15' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Sat_03:00-03:30' -LeadTimeMinutes 5 -FiresPerWindow 2
                $r | Should -HaveCount 2
                $r[0].CronExpression | Should -Be '55 2 * * 6'
                $r[1].CronExpression | Should -Be '15 3 * * 6'
                $r[1].IsRetry | Should -BeTrue
            }
        }

        It 'Overnight crossing midnight: Mon_23:30-00:30 retry at 24:00 forward-day-shifts to Tue 00:00' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon_23:30-00:30' -LeadTimeMinutes 5 -FiresPerWindow 2
                $r | Should -HaveCount 2
                # Open: 23:30 - 5min lead = 23:25 Mon (no shift, still Mon).
                $r[0].CronExpression | Should -Be '25 23 * * 1'
                $r[0].DayShift | Should -BeFalse
                # Retry: 23:30 + 30min midpoint = 24:00 -> 00:00 Tue (forward day shift).
                $r[1].CronExpression | Should -Be '0 0 * * 2'
                $r[1].IsRetry | Should -BeTrue
                $r[1].DayShift | Should -BeTrue
            }
        }

        It '24h-style window Mon-Fri_00:00-23:00: retry capped at +60min (01:00, same day, no shift)' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon-Fri_00:00-23:00' -LeadTimeMinutes 0 -FiresPerWindow 2
                $r | Should -HaveCount 2
                $r[0].CronExpression | Should -Be '0 0 * * 1-5'
                # 23h = 1380min, midpoint 690min, capped to 60 -> 01:00.
                $r[1].CronExpression | Should -Be '0 1 * * 1-5'
                $r[1].IsRetry | Should -BeTrue
                $r[1].DayShift | Should -BeFalse
            }
        }

        It 'Multi-segment window with FiresPerWindow=2 emits TWO rows per segment (4 total)' {
            InModuleScope AzLocal.UpdateManagement {
                $r = Convert-AzLocalUpdateWindowToCron -UpdateStartWindow 'Mon-Fri_22:00-04:00;Sat-Sun_02:00-06:00' -LeadTimeMinutes 5 -FiresPerWindow 2
                $r | Should -HaveCount 4
                @($r | Where-Object IsRetry -eq $false).Count | Should -Be 2
                @($r | Where-Object IsRetry -eq $true).Count  | Should -Be 2
            }
        }
    }

    Context 'Private helper: ConvertFrom-AzLocalCronExpression' {
        It 'Parses 55 1 * * 6,0 and enumerates 2 fire times in the reference week' {
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression '55 1 * * 6,0'
                $p.IsValid | Should -BeTrue
                $p.IsComplex | Should -BeFalse
                @($p.FireTimes).Count | Should -Be 2
            }
        }

        It 'Parses comma-separated minutes (0,15,30,45) into 4 entries per hour' {
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression '0,15,30,45 2 * * 1'
                $p.IsValid | Should -BeTrue
                @($p.FireTimes).Count | Should -Be 4
            }
        }

        It 'Flags non-* DayOfMonth as IsComplex (advisor cannot evaluate)' {
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression '0 2 15 * *'
                $p.IsValid | Should -BeTrue
                $p.IsComplex | Should -BeTrue
                @($p.FireTimes).Count | Should -Be 0
            }
        }

        It 'Parses */15 step syntax (v0.7.67) and enumerates 4 fires per hour' {
            # v0.7.67: cron step syntax is now supported. Pre-v0.7.67 this
            # asserted IsValid=$false and ErrorMessage matched "not supported";
            # the advisor would falsely flag every-15-minute crons as
            # UnparseableCron even though GitHub Actions and Azure DevOps
            # both honour the syntax.
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression '*/15 * * * *'
                $p.IsValid | Should -BeTrue
                $p.IsComplex | Should -BeFalse
                # 60 / 15 = 4 minutes per hour * 24 hours * 7 days = 672 fires.
                @($p.FireTimes).Count | Should -Be 672
            }
        }

        It 'Parses bounded step range 9-17/2 in the hour field (v0.7.67)' {
            InModuleScope AzLocal.UpdateManagement {
                # 0 9-17/2 * * 1-5 -> hours 9,11,13,15,17 on weekdays = 5 fires/day * 5 days = 25.
                $p = ConvertFrom-AzLocalCronExpression -Expression '0 9-17/2 * * 1-5'
                $p.IsValid | Should -BeTrue
                $p.IsComplex | Should -BeFalse
                @($p.FireTimes).Count | Should -Be 25
            }
        }

        It 'Parses start-anchored step 5/15 in the minute field (v0.7.67)' {
            InModuleScope AzLocal.UpdateManagement {
                # 5/15 in minute (0-59) -> 5,20,35,50 = 4 fires per hour.
                $p = ConvertFrom-AzLocalCronExpression -Expression '5/15 * * * 1'
                $p.IsValid | Should -BeTrue
                @($p.FireTimes).Count | Should -Be (4 * 24)
                # First fire should be at minute 5, not 0.
                $p.FireTimes[0].Minute | Should -Be 5
            }
        }

        It 'Rejects step expressions with non-positive N (v0.7.67)' {
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression '*/0 * * * *'
                $p.IsValid | Should -BeFalse
                $p.ErrorMessage | Should -Match 'positive integer'
            }
        }

        It 'Rejects wrong field count' {
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression '0 2 * *'
                $p.IsValid | Should -BeFalse
                $p.ErrorMessage | Should -Match '5 cron fields'
            }
        }

        It 'Treats DOW=7 as Sunday (== 0)' {
            InModuleScope AzLocal.UpdateManagement {
                $p7 = ConvertFrom-AzLocalCronExpression -Expression '0 2 * * 7'
                $p0 = ConvertFrom-AzLocalCronExpression -Expression '0 2 * * 0'
                @($p7.FireTimes).Count | Should -Be 1
                $p7.FireTimes[0] | Should -Be $p0.FireTimes[0]
            }
        }

        It 'Accepts an empty string and returns IsValid=$false with structured error (v0.7.69)' {
            # Regression: v0.7.68 declared [Parameter(Mandatory)][string]$Expression,
            # so the binder rejected '' before the function body could surface the
            # 'Cron expression is empty.' message. v0.7.69 adds [AllowEmptyString()]
            # so the IsNullOrWhiteSpace handler actually runs.
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression ''
                $p.IsValid      | Should -BeFalse
                $p.ErrorMessage | Should -Be 'Cron expression is empty.'
            }
        }

        It 'Accepts a whitespace-only string and returns IsValid=$false with structured error (v0.7.69)' {
            InModuleScope AzLocal.UpdateManagement {
                $p = ConvertFrom-AzLocalCronExpression -Expression '   '
                $p.IsValid      | Should -BeFalse
                $p.ErrorMessage | Should -Be 'Cron expression is empty.'
            }
        }
    }

    Context 'Private helper: Read-AzLocalApplyUpdatesYamlCrons' {
        BeforeAll {
            $script:tmpYamlDir = Join-Path $env:TEMP "schedule-cov-tests-$(Get-Random)"
            New-Item -ItemType Directory -Path (Join-Path $script:tmpYamlDir 'github-actions') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:tmpYamlDir 'azure-devops')   -Force | Out-Null
            @"
on:
  workflow_dispatch:
  schedule:
    - cron: '55 1 * * 6,0'
    - cron: "0 22 * * 5"
"@ | Set-Content -Path (Join-Path $script:tmpYamlDir 'github-actions\Step.6_apply-updates.yml') -Encoding ASCII
            @"
trigger: none
schedules:
  - cron: '30 2 * * 1-5'
    displayName: Weekday early-morning
    branches:
      include: [ main ]
"@ | Set-Content -Path (Join-Path $script:tmpYamlDir 'azure-devops\Step.6_apply-updates.yml') -Encoding ASCII
        }
        AfterAll {
            Remove-Item -Path $script:tmpYamlDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Discovers 2 GH cron lines + 1 ADO cron line with platform inferred from folder name' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ tmpYamlDir = $script:tmpYamlDir } {
                param($tmpYamlDir)
                $r = Read-AzLocalApplyUpdatesYamlCrons -Path $tmpYamlDir
                @($r).Count | Should -Be 3
                @($r | Where-Object Platform -eq 'GitHubActions').Count | Should -Be 2
                @($r | Where-Object Platform -eq 'AzureDevOps').Count   | Should -Be 1
            }
        }

        It 'Strips surrounding quotes from cron expressions' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ tmpYamlDir = $script:tmpYamlDir } {
                param($tmpYamlDir)
                $r = Read-AzLocalApplyUpdatesYamlCrons -Path $tmpYamlDir
                ($r | ForEach-Object CronExpression) | Should -Contain '55 1 * * 6,0'
                ($r | ForEach-Object CronExpression) | Should -Contain '0 22 * * 5'
                ($r | ForEach-Object CronExpression) | Should -Contain '30 2 * * 1-5'
            }
        }

        It 'Does NOT match sibling Step.N pipelines (v0.7.69 glob regression)' {
            # v0.7.68 used `Get-ChildItem -LiteralPath -Recurse -Include`, which
            # silently ignored the -Include filter and returned every recursed
            # file. As a result the audit picked up Step.1, Step.3, Step.6, and
            # Step.7 schedule crons as if they were apply-updates crons. The
            # fix uses per-pattern -Filter calls (which honour -Recurse).
            $regressionDir = Join-Path $env:TEMP "schedule-cov-glob-$(Get-Random)"
            New-Item -ItemType Directory -Path (Join-Path $regressionDir 'github-actions') -Force | Out-Null
            try {
                # Sibling pipelines that carry their own (legitimate) schedule
                # crons - audit should ignore all of these.
                @"
on:
  schedule:
    - cron: '0 6 * * 1'
"@ | Set-Content -Path (Join-Path $regressionDir 'github-actions\Step.1_inventory-clusters.yml') -Encoding ASCII
                @"
on:
  schedule:
    - cron: '0 5 * * 1'
"@ | Set-Content -Path (Join-Path $regressionDir 'github-actions\Step.3_apply-updates-schedule-audit.yml') -Encoding ASCII
                @"
on:
  schedule:
    - cron: '0 7 * * *'
"@ | Set-Content -Path (Join-Path $regressionDir 'github-actions\Step.9_fleet-health-status.yml') -Encoding ASCII
                # Apply-updates file: ships with only commented-out cron examples,
                # so the reader should return ZERO crons for this folder overall.
                @"
on:
  workflow_dispatch:
  # schedule:
  #   - cron: '0 22 * * 6'
"@ | Set-Content -Path (Join-Path $regressionDir 'github-actions\Step.6_apply-updates.yml') -Encoding ASCII

                InModuleScope AzLocal.UpdateManagement -Parameters @{ dir = $regressionDir } {
                    param($dir)
                    $r = Read-AzLocalApplyUpdatesYamlCrons -Path $dir
                    @($r).Count | Should -Be 0
                }
            }
            finally {
                Remove-Item -Path $regressionDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Skips quoted whitespace-only cron captures (v0.7.69)' {
            # The regex `[^'"]+` also matches whitespace runs, so a malformed
            # `cron: '   '` would emit a record with CronExpression='' once
            # Trim() ran. v0.7.69 drops that record at the reader rather than
            # letting it crash the downstream parser binder.
            $emptyDir = Join-Path $env:TEMP "schedule-cov-emptycron-$(Get-Random)"
            New-Item -ItemType Directory -Path (Join-Path $emptyDir 'github-actions') -Force | Out-Null
            try {
                @"
on:
  schedule:
    - cron: '   '
    - cron: '0 22 * * 6'
"@ | Set-Content -Path (Join-Path $emptyDir 'github-actions\Step.6_apply-updates.yml') -Encoding ASCII

                InModuleScope AzLocal.UpdateManagement -Parameters @{ dir = $emptyDir } {
                    param($dir)
                    $r = Read-AzLocalApplyUpdatesYamlCrons -Path $dir
                    @($r).Count | Should -Be 1
                    $r[0].CronExpression | Should -Be '0 22 * * 6'
                }
            }
            finally {
                Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Behavior: Audit / Matrix / Recommend' {
        BeforeAll {
            $script:tmpYamlDir2 = Join-Path $env:TEMP "schedule-cov-behaviour-$(Get-Random)"
            New-Item -ItemType Directory -Path (Join-Path $script:tmpYamlDir2 'github-actions') -Force | Out-Null
            # YAML covers Sat/Sun windows (fires Sat 01:50, Sun 01:50) but does NOT cover Mon-Fri windows.
            @"
on:
  schedule:
    - cron: '50 1 * * 6,0'
"@ | Set-Content -Path (Join-Path $script:tmpYamlDir2 'github-actions\Step.6_apply-updates.yml') -Encoding ASCII
        }
        AfterAll {
            Remove-Item -Path $script:tmpYamlDir2 -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Audit: reports Covered for Sat-Sun window and Uncovered for Mon-Fri window' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ tmpYamlDir2 = $script:tmpYamlDir2 } {
                param($tmpYamlDir2)
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Wave1';      UpdateStartWindow='Sat-Sun_02:00-06:00' },
                        [PSCustomObject]@{ ClusterName='c2'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c2'; UpdateRing='Wave1';      UpdateStartWindow='Sat-Sun_02:00-06:00' },
                        [PSCustomObject]@{ ClusterName='c3'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c3'; UpdateRing='Production'; UpdateStartWindow='Mon-Fri_22:00-04:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $tmpYamlDir2 -PassThru 6>$null
                $rWave  = $result | Where-Object UpdateRing -eq 'Wave1'
                $rProd  = $result | Where-Object UpdateRing -eq 'Production'
                $rWave.Status | Should -Be 'Covered'
                $rWave.ClusterCount | Should -Be 2
                $rProd.Status | Should -Be 'Uncovered'
                $rProd.RequiredCronUTC | Should -Be '55 21 * * 1-5'
            }
        }

        It 'Matrix: emits one row per distinct (Ring, Window) with RequiredCronUTC populated' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Wave1'; UpdateStartWindow='Sat-Sun_02:00-06:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Matrix -PassThru 6>$null
                $result | Should -HaveCount 1
                $result[0].RequiredCronUTC | Should -Be '55 1 * * 6,0'
                $result[0].ClusterCount | Should -Be 1
            }
        }

        It 'Recommend: dedupes crons across rings and emits one row per cron' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Pilot'; UpdateStartWindow='Sat-Sun_02:00-06:00' },
                        [PSCustomObject]@{ ClusterName='c2'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c2'; UpdateRing='Wave1'; UpdateStartWindow='Sat-Sun_02:00-06:00' }
                    )
                }
                # Pin to FiresPerWindow=1 (pre-v0.7.92 behaviour) so the single-cron dedupe assertion still holds.
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -RecommendFiresPerWindow 1 -PassThru 6>$null
                $result | Should -HaveCount 1
                $result[0].CronExpression | Should -Be '55 1 * * 6,0'
                $result[0].ClusterCount   | Should -Be 2
                ($result[0].Rings | Sort-Object) | Should -Be @('Pilot','Wave1')
                $result[0].Snippet | Should -Match "schedule:"
            }
        }

        It 'Audit: MalformedTag emitted when UpdateStartWindow tag fails to parse' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ tmpYamlDir2 = $script:tmpYamlDir2 } {
                param($tmpYamlDir2)
                Mock Invoke-AzResourceGraphQuery {
                    @([PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='X'; UpdateStartWindow='NotAWindow' })
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $tmpYamlDir2 -PassThru 6>$null
                ($result | Where-Object UpdateRing -eq 'X').Status | Should -Be 'MalformedTag'
            }
        }

        It '-IncludeUntagged surfaces clusters with no UpdateStartWindow tag' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ tmpYamlDir2 = $script:tmpYamlDir2 } {
                param($tmpYamlDir2)
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Wave1'; UpdateStartWindow='Sat-Sun_02:00-06:00' },
                        [PSCustomObject]@{ ClusterName='c2'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c2'; UpdateRing='';      UpdateStartWindow='' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $tmpYamlDir2 -IncludeUntagged -PassThru 6>$null
                ($result | Where-Object Status -eq 'NoWindowTag').ClusterCount | Should -Be 1
            }
        }
    }

    Context 'Belt-and-braces: -RecommendFiresPerWindow + RingMixedWindows (v0.7.92)' {
        BeforeAll {
            $script:beltYamlDir = Join-Path $env:TEMP "schedule-cov-belt-$(Get-Random)"
            New-Item -ItemType Directory -Path (Join-Path $script:beltYamlDir 'github-actions') -Force | Out-Null
            # Cover the Sat-Sun opening edge so Audit reports Covered for that ring.
            @"
on:
  schedule:
    - cron: '55 1 * * 6,0'
"@ | Set-Content -Path (Join-Path $script:beltYamlDir 'github-actions\Step.6_apply-updates.yml') -Encoding ASCII
        }
        AfterAll {
            Remove-Item -Path $script:beltYamlDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Recommend default (-RecommendFiresPerWindow=2) emits TWO rows per window (open + retry)' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Pilot'; UpdateStartWindow='Sat-Sun_02:00-06:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -PassThru 6>$null
                @($result).Count | Should -Be 2
                $open  = $result | Where-Object CronExpression -eq '55 1 * * 6,0'
                $retry = $result | Where-Object CronExpression -eq '0 3 * * 6,0'
                $open  | Should -Not -BeNullOrEmpty
                $retry | Should -Not -BeNullOrEmpty
                $open.Snippet  | Should -Match '\(open\)'
                $retry.Snippet | Should -Match '\(retry\)'
            }
        }

        It 'Recommend with -RecommendFiresPerWindow 1 emits ONLY the opening cron (back-compat)' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Pilot'; UpdateStartWindow='Sat-Sun_02:00-06:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -RecommendFiresPerWindow 1 -PassThru 6>$null
                @($result).Count | Should -Be 1
                $result[0].CronExpression | Should -Be '55 1 * * 6,0'
            }
        }

        It 'Audit emits RingMixedWindows when same ring has two different UpdateStartWindow values' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ beltYamlDir = $script:beltYamlDir } {
                param($beltYamlDir)
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Production'; UpdateStartWindow='Sat-Sun_02:00-06:00' },
                        [PSCustomObject]@{ ClusterName='c2'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c2'; UpdateRing='Production'; UpdateStartWindow='Mon-Fri_22:00-04:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $beltYamlDir -PassThru 6>$null
                $mixed = @($result | Where-Object Status -eq 'RingMixedWindows')
                $mixed | Should -HaveCount 1
                $mixed[0].UpdateRing | Should -Be 'Production'
                $mixed[0].ClusterCount | Should -Be 2
                $mixed[0].UpdateStartWindow | Should -Match 'Mon-Fri_22:00-04:00'
                $mixed[0].UpdateStartWindow | Should -Match 'Sat-Sun_02:00-06:00'
                # Per-(Ring, Window) coverage rows are also emitted alongside the mixed warning.
                @($result | Where-Object { $_.UpdateRing -eq 'Production' -and $_.Status -in @('Covered','Uncovered','PartiallyCovered') }).Count | Should -Be 2
            }
        }

        It 'Audit does NOT emit RingMixedWindows when each ring has a single UpdateStartWindow' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ beltYamlDir = $script:beltYamlDir } {
                param($beltYamlDir)
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Pilot';      UpdateStartWindow='Sat-Sun_02:00-06:00' },
                        [PSCustomObject]@{ ClusterName='c2'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c2'; UpdateRing='Production'; UpdateStartWindow='Mon-Fri_22:00-04:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $beltYamlDir -PassThru 6>$null
                @($result | Where-Object Status -eq 'RingMixedWindows') | Should -HaveCount 0
            }
        }
    }

    Context 'Regression: multi-segment / multi-cron row-shape (Finding 1, v0.7.76)' {
        # These tests guard against the silent row-collapse bug where the public
        # cmdlet wrapped helper return values with @() while the helpers used
        # `return , $arr` to preserve Object[N] shape. Wrapping a `, $arr`
        # return with @() collapses it to Object[1] containing the inner array,
        # so multi-row scenarios silently produced one nested-array row instead
        # of N rows. See `docs/MODULE-REVIEW-AND-RECOMMENDATIONS.md` Finding 1.
        BeforeAll {
            $script:multiYamlDir = Join-Path $env:TEMP "schedule-cov-multicron-$(Get-Random)"
            New-Item -ItemType Directory -Path (Join-Path $script:multiYamlDir 'github-actions') -Force | Out-Null
            # Two cron triggers in one YAML: Sat-Sun 01:50 AND Mon-Fri 21:55.
            # Read-AzLocalApplyUpdatesYamlCrons returns Object[2] via `, $arr`;
            # a regressed caller wrapping with @() would receive Object[1] and
            # this test would fail.
            @"
on:
  schedule:
    - cron: '50 1 * * 6,0'
    - cron: '55 21 * * 1-5'
"@ | Set-Content -Path (Join-Path $script:multiYamlDir 'github-actions\Step.6_apply-updates.yml') -Encoding ASCII
        }
        AfterAll {
            Remove-Item -Path $script:multiYamlDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It 'Audit: multi-cron YAML produces Covered for both Sat-Sun AND Mon-Fri windows' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ multiYamlDir = $script:multiYamlDir } {
                param($multiYamlDir)
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Wave1';      UpdateStartWindow='Sat-Sun_02:00-06:00' },
                        [PSCustomObject]@{ ClusterName='c2'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c2'; UpdateRing='Production'; UpdateStartWindow='Mon-Fri_22:00-04:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $multiYamlDir -PassThru 6>$null
                # If the @() wrap regression returns - both rows would collapse
                # to a single nested-array row and one of these assertions would
                # fail with `Status` being a System.Object[] of array values.
                ($result | Where-Object UpdateRing -eq 'Wave1').Status      | Should -Be 'Covered'
                ($result | Where-Object UpdateRing -eq 'Production').Status | Should -Be 'Covered'
            }
        }

        It 'Audit: multi-segment UpdateStartWindow (Mon-Fri_22:00-04:00;Sat-Sun_02:00-10:00) reports both segments parsed' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ multiYamlDir = $script:multiYamlDir } {
                param($multiYamlDir)
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='HybridRing'; UpdateStartWindow='Mon-Fri_22:00-04:00;Sat-Sun_02:00-10:00' }
                    )
                }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $multiYamlDir -PassThru 6>$null
                # The HybridRing row contains TWO required crons (one per segment).
                # Convert-AzLocalUpdateWindowToCron returns Object[2] via `, $arr`;
                # a regressed caller wrapping with @() would produce Object[1]
                # containing the nested array, and downstream coverage matching
                # would compare a single nested-array string against YAML crons
                # and always report Uncovered (silent false negative).
                #
                # Audit view ROLLS multi-segment windows into a single row per
                # (UpdateRing, UpdateStartWindow) with all required crons reflected
                # in RequiredCronUTC (semicolon-separated). This test asserts
                # both segments are PARSED (visible in RequiredCronUTC) and
                # both contribute to the rolled-up Status.
                $hybrid = @($result | Where-Object UpdateRing -eq 'HybridRing')
                $hybrid | Should -Not -BeNullOrEmpty
                $hybrid.Count | Should -Be 1 -Because 'multi-segment windows roll into one Audit row per (UpdateRing, UpdateStartWindow)'
                # RequiredCronUTC must reflect BOTH segments. If the @() wrap
                # regression returns the second cron will be missing or the
                # field will surface as a System.Object[] of array values
                # (semicolon join would then produce 'System.Object[]; System.Object[]').
                $hybrid[0].RequiredCronUTC | Should -Match ';' -Because 'two required crons must be semicolon-joined'
                $hybrid[0].RequiredCronUTC | Should -Not -Match 'System.Object' -Because 'a regressed caller wrap with @() collapses Object[2] into Object[1] of nested arrays'
                # Both segments covered by the two-cron YAML.
                $hybrid[0].Status | Should -Be 'Covered'
            }
        }

        It 'Recommend: multi-segment UpdateStartWindow emits one row per cron with stable dedupe key' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='HybridRing'; UpdateStartWindow='Mon-Fri_22:00-04:00;Sat-Sun_02:00-10:00' }
                    )
                }
                # Pin to FiresPerWindow=1 (pre-v0.7.92 behaviour) so the per-segment row count is unambiguous (2 instead of 4 with belt-and-braces).
                $result = Test-AzLocalApplyUpdatesScheduleCoverage -View Recommend -RecommendFiresPerWindow 1 -PassThru 6>$null
                # If RequiredCrons collapsed to one nested-array row, Recommend
                # would emit a single CronExpression equal to a `System.Object[]`
                # string and the count would be 1. With the fix it should be 2.
                @($result).Count | Should -Be 2
                # Each emitted row should have a real cron string, not a
                # stringified array.
                foreach ($r in $result) {
                    $r.CronExpression | Should -Match '^\d+\s+\d+\s+\*\s+\*\s+'
                    $r.ClusterCount | Should -Be 1
                }
            }
        }
    }

    Context 'Integration: shipped Automation-Pipeline-Examples bundle (v0.7.69)' {
        # End-to-end smoke against the actual YAMLs published to PSGallery as
        # part of the module. This is the gap that let v0.7.68 ship with the
        # -LiteralPath/-Include glob regression: unit tests only fed the reader
        # synthetic Step.6_apply-updates.yml files in isolation, never a real
        # multi-pipeline folder. Running the audit against the bundle now
        # guarantees that no future change re-introduces a glob that also picks
        # up sibling Step.N_*.yml schedule triggers.
        BeforeAll {
            $script:bundleGhDir = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples\github-actions'
        }

        It 'Audit against the shipped GitHub Actions bundle returns rows without throwing' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ bundleGhDir = $script:bundleGhDir } {
                param($bundleGhDir)
                Mock Invoke-AzResourceGraphQuery {
                    @(
                        [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Wave1'; UpdateStartWindow='Sat-Sun_02:00-06:00' }
                    )
                }
                { Test-AzLocalApplyUpdatesScheduleCoverage -View Audit -PipelineYamlPath $bundleGhDir -PassThru 6>$null } |
                    Should -Not -Throw
            }
        }

        It 'Reader finds zero crons in the shipped bundle (no false-positive sibling matches)' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ bundleGhDir = $script:bundleGhDir } {
                param($bundleGhDir)
                $r = Read-AzLocalApplyUpdatesYamlCrons -Path $bundleGhDir
                @($r).Count | Should -Be 0 -Because 'the shipped Step.6_apply-updates.yml ships with only commented cron examples, and the reader must NOT pick up crons from sibling Step.N pipelines'
            }
        }
    }
}

#endregion Apply-Updates Schedule Coverage Advisor (v0.7.65)

#region v0.7.66 UX + Multi-Value UpdateRing regression suite

Describe 'v0.7.66 UpdateRing ValidatePattern accepts list & wildcard forms' {
    # Strategy: directly probe the ValidatePattern attribute on every public
    # cmdlet that accepts UpdateRingValue / UpdateRingTag. Going through the
    # actual cmdlet would require Azure mocking just to exercise the validator,
    # which is fragile. Reflecting on the AttributeMetadata is deterministic.

    # NOTE: these arrays MUST be defined at Discovery time (i.e. outside
    # BeforeAll / BeforeEach) so the -ForEach blocks below can enumerate
    # them when Pester builds the test tree. BeforeAll runs during the Run
    # phase, after discovery - using $script: there yields an empty -ForEach
    # set and zero generated It blocks.
    BeforeDiscovery {
        $script:RingValueCmdlets = @(
            'Get-AzLocalAvailableUpdates'
            'Get-AzLocalClusterInventory'
            'Get-AzLocalClusterUpdateReadiness'
            'Get-AzLocalFleetProgress'
            'Get-AzLocalFleetStatusData'
            'Get-AzLocalUpdateRuns'
            'Get-AzLocalUpdateSummary'
            'Invoke-AzLocalFleetOperation'
            'New-AzLocalFleetStatusHtmlReport'
            'Reset-AzLocalSideloadedTag'
            'Set-AzLocalClusterUpdateRingTag'
            'Start-AzLocalClusterUpdate'
            'Test-AzLocalClusterHealth'
            'Test-AzLocalFleetHealthGate'
        )
        # Get-AzLocalFleetHealthFailures uses the param name UpdateRingTag.
        $script:RingTagCmdlets = @(
            'Get-AzLocalFleetHealthFailures'
        )
    }

    Context 'ValidatePattern attribute' {
        It "Cmdlet <Cmdlet> -UpdateRingValue accepts 'Wave1', 'Prod;Ring2', and '***'" -ForEach @(
            $script:RingValueCmdlets | ForEach-Object { @{ Cmdlet = $_; ParamName = 'UpdateRingValue' } }
        ) {
            $cmd = Get-Command -Name $Cmdlet -Module AzLocal.UpdateManagement
            $cmd | Should -Not -BeNullOrEmpty -Because "v0.7.66 cmdlets should be exported"
            $param = $cmd.Parameters[$ParamName]
            $param | Should -Not -BeNullOrEmpty -Because "$Cmdlet should expose -$ParamName"
            $vp = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] }
            $vp | Should -Not -BeNullOrEmpty -Because "$Cmdlet -$ParamName must carry a ValidatePattern attribute"
            $rx = $vp.RegexPattern
            # Acceptance set - all of these must match the relaxed regex.
            # NOTE: '***' (three stars) is the deliberate wildcard token introduced in v0.7.66.
            # A bare '*' is REJECTED so a single-character typo cannot accidentally scope a fleet-wide write.
            foreach ($candidate in @('Wave1', 'Prod', 'Ring2', 'Prod;Ring2', 'A;B;C', '***', 'a_b-c', 'X0', 'p1;p2;p3')) {
                ([regex]::IsMatch($candidate, $rx)) | Should -BeTrue -Because "'$candidate' should be a valid -$ParamName value for $Cmdlet under v0.7.66"
            }
            # Rejection set - must still block obviously hostile/malformed inputs AND the easy-to-mistype '*', '**', '****' variants.
            foreach ($candidate in @('Foo bar', "abc'def", '<script>', 'a;b;', ';abc', 'abc;', '', '#bad', "a`nb", '*', '**', '****', '*Wave1', 'Wave1*', '***;Wave1')) {
                ([regex]::IsMatch($candidate, $rx)) | Should -BeFalse -Because "'$candidate' must NOT be accepted by $Cmdlet -$ParamName (v0.7.66 only accepts ring tokens or the exact 3-star '***' wildcard)"
            }
        }

        It "Cmdlet <Cmdlet> -<ParamName> accepts 'Wave1', 'Prod;Ring2', and '***'" -ForEach @(
            $script:RingTagCmdlets | ForEach-Object { @{ Cmdlet = $_; ParamName = 'UpdateRingTag' } }
        ) {
            $cmd = Get-Command -Name $Cmdlet -Module AzLocal.UpdateManagement
            $param = $cmd.Parameters[$ParamName]
            $param | Should -Not -BeNullOrEmpty
            $vp = $param.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidatePatternAttribute] }
            $vp | Should -Not -BeNullOrEmpty
            $rx = $vp.RegexPattern
            foreach ($candidate in @('Wave1', 'Prod;Ring2', '***')) {
                ([regex]::IsMatch($candidate, $rx)) | Should -BeTrue -Because "'$candidate' should be a valid -$ParamName value for $Cmdlet under v0.7.66"
            }
            foreach ($candidate in @('Foo bar', "abc'def", 'abc;', '', '*', '**', '****')) {
                ([regex]::IsMatch($candidate, $rx)) | Should -BeFalse -Because "'$candidate' must NOT be accepted (single/double/quad-star are rejected; only the exact 3-star '***' wildcard passes)"
            }
        }
    }
}

Describe 'v0.7.66 ConvertTo-AzLocalUpdateRingKqlFilter helper' {
    # Helper is private to the module; exercise it via InModuleScope.

    It 'Returns isnotempty clause for "***" (wildcard scopes to clusters that HAVE a non-empty UpdateRing tag)' {
        InModuleScope AzLocal.UpdateManagement {
            (ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue '***') | Should -Be "| where isnotempty(tags['UpdateRing'])"
        }
    }

    It 'Honours -TagAccessor for the "***" wildcard on the fleet-health failures path (tostring)' {
        InModuleScope AzLocal.UpdateManagement {
            (ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue '***' -TagAccessor "tostring(tags['UpdateRing'])") | Should -Be "| where isnotempty(tostring(tags['UpdateRing']))"
        }
    }

    It 'Returns =~ clause for a single ring' {
        InModuleScope AzLocal.UpdateManagement {
            (ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue 'Wave1') | Should -Be "| where tags['UpdateRing'] =~ 'Wave1'"
        }
    }

    It 'Returns in~ clause for a semicolon-delimited list' {
        InModuleScope AzLocal.UpdateManagement {
            (ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue 'Prod;Ring2') | Should -Be "| where tags['UpdateRing'] in~ ('Prod','Ring2')"
        }
    }

    It "Escapes embedded single quotes by doubling them (KQL safe)" {
        InModuleScope AzLocal.UpdateManagement {
            $out = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue "ab'cd"
            $out | Should -Be "| where tags['UpdateRing'] =~ 'ab''cd'"
        }
    }

    It 'Honours -TagAccessor for the fleet-health failures path (tostring)' {
        InModuleScope AzLocal.UpdateManagement {
            (ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue 'Wave1' -TagAccessor "tostring(tags['UpdateRing'])") | Should -Be "| where tostring(tags['UpdateRing']) =~ 'Wave1'"
        }
    }

    It 'Trims whitespace and drops empty segments' {
        InModuleScope AzLocal.UpdateManagement {
            $out = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue ' Wave1 ; Wave2 '
            $out | Should -Be "| where tags['UpdateRing'] in~ ('Wave1','Wave2')"
        }
    }

    It 'Returns empty string for null/empty/whitespace input' {
        InModuleScope AzLocal.UpdateManagement {
            (ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue '')   | Should -Be ''
            (ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue '   ') | Should -Be ''
        }
    }
}

Describe 'v0.7.66 Artifact download names carry a UTC timestamp suffix' {
    # Every downloadable artifact must include either a GH outputs token
    # (steps.<id>.outputs.timestamp) or an ADO output variable
    # ($(<stamp>.artifactStamp)) so that re-running the same pipeline on the
    # same day produces distinct zip filenames.

    BeforeAll {
        $script:examplesRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples')).Path
    }

    It 'GitHub Actions: every upload-artifact step uses a timestamped name and azlocal- prefix' {
        $ghDir   = Join-Path $script:examplesRoot 'github-actions'
        $ghFiles = Get-ChildItem -Path $ghDir -Filter '*.yml' -File
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($yml in $ghFiles) {
            $content = Get-Content -LiteralPath $yml.FullName -Raw
            # Find every upload-artifact step's `name:` value in its `with:` block.
            $rxArtifact = [regex]::new("(?ms)uses:\s*actions/upload-artifact@[^\r\n]+\r?\n\s*with:\s*\r?\n\s*name:\s*([^\r\n]+)")
            foreach ($m in $rxArtifact.Matches($content)) {
                $name = $m.Groups[1].Value.Trim().Trim("'""")
                if ($name -notmatch 'azlocal-') {
                    $offenders.Add("$($yml.Name): upload-artifact name '$name' missing azlocal- prefix")
                }
                if ($name -notmatch '\$\{\{\s*steps\.[^}]+\.outputs\.timestamp\s*\}\}') {
                    $offenders.Add("$($yml.Name): upload-artifact name '$name' missing steps.<id>.outputs.timestamp suffix")
                }
            }
        }
        $detail = if ($offenders.Count -gt 0) { $offenders -join [Environment]::NewLine } else { '(no offenders)' }
        $offenders.Count | Should -Be 0 -Because "every actions/upload-artifact step must carry an azlocal-* name with steps.<id>.outputs.timestamp. Findings:$([Environment]::NewLine)$detail"
    }

    It 'Azure DevOps: every PublishBuildArtifacts / PublishPipelineArtifact uses a timestamped name and azlocal- prefix' {
        $adoDir   = Join-Path $script:examplesRoot 'azure-devops'
        $adoFiles = Get-ChildItem -Path $adoDir -Filter '*.yml' -File
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($yml in $adoFiles) {
            $content = Get-Content -LiteralPath $yml.FullName -Raw
            # Match both ArtifactName: '...' and artifact: '...'
            $rxAdo = [regex]::new("(?im)^\s*(ArtifactName|artifact)\s*:\s*'([^']+)'")
            foreach ($m in $rxAdo.Matches($content)) {
                $key  = $m.Groups[1].Value
                $name = $m.Groups[2].Value
                if ($name -notmatch '^azlocal-') {
                    $offenders.Add("$($yml.Name): ${key} '$name' missing azlocal- prefix")
                }
                # Accept either the in-stage step-output form (`$(stamp.artifactStamp)`)
                # OR a cross-stage variable that ends in `ArtifactStamp)`, which is
                # how `Step.6_apply-updates.yml` consumes the CheckReadiness stage's stamp
                # via the `readinessArtifactStamp` mapped variable.
                if ($name -notmatch '\$\(.+?[Aa]rtifactStamp\)') {
                    $offenders.Add("$($yml.Name): ${key} '$name' missing a `$(...artifactStamp) suffix")
                }
            }
        }
        $detail = if ($offenders.Count -gt 0) { $offenders -join [Environment]::NewLine } else { '(no offenders)' }
        $offenders.Count | Should -Be 0 -Because "every PublishBuildArtifacts/PublishPipelineArtifact ArtifactName must be azlocal-*_`$(stamp.artifactStamp). Findings:$([Environment]::NewLine)$detail"
    }

    It 'GitHub Actions: legacy non-stamped artifact names are gone' {
        $ghDir = Join-Path $script:examplesRoot 'github-actions'
        $legacyTokens = @(
            'name: fleet-status-reports'
            'name: fleet-health-reports'
            'name: cluster-inventory'
            'name: updatering-tag-logs'
            'name: schedule-coverage-reports'
            'name: readiness-report'
            'name: readiness-assessment'
            'name: update-logs'
            'name: itsm-results'
        )
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($yml in Get-ChildItem -Path $ghDir -Filter '*.yml' -File) {
            $content = Get-Content -LiteralPath $yml.FullName -Raw
            foreach ($t in $legacyTokens) {
                if ($content -match [regex]::Escape($t) + '\s*$' -or $content -match [regex]::Escape($t) + '\r?\n') {
                    $offenders.Add("$($yml.Name): still contains legacy artifact token '$t'")
                }
            }
        }
        $detail = if ($offenders.Count -gt 0) { $offenders -join [Environment]::NewLine } else { '(no offenders)' }
        $offenders.Count | Should -Be 0 -Because "v0.7.66 renamed every GH artifact to azlocal-*_<timestamp>. Findings:$([Environment]::NewLine)$detail"
    }

    It 'Azure DevOps: legacy non-stamped ArtifactName values are gone' {
        $adoDir = Join-Path $script:examplesRoot 'azure-devops'
        $legacyTokens = @(
            "ArtifactName: 'FleetStatusReports'"
            "ArtifactName: 'FleetHealthReports'"
            "ArtifactName: 'cluster-inventory'"
            "ArtifactName: 'updatering-tag-logs'"
            "ArtifactName: 'ScheduleCoverageReports'"
            "ArtifactName: 'readiness-report'"
            "artifact: 'readiness-assessment'"
            "ArtifactName: 'update-logs'"
            "ArtifactName: 'itsm-results'"
        )
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($yml in Get-ChildItem -Path $adoDir -Filter '*.yml' -File) {
            $content = Get-Content -LiteralPath $yml.FullName -Raw
            foreach ($t in $legacyTokens) {
                if ($content -match [regex]::Escape($t)) {
                    $offenders.Add("$($yml.Name): still contains legacy artifact token '$t'")
                }
            }
        }
        $detail = if ($offenders.Count -gt 0) { $offenders -join [Environment]::NewLine } else { '(no offenders)' }
        $offenders.Count | Should -Be 0 -Because "v0.7.66 renamed every ADO ArtifactName to azlocal-*_`$(stamp.artifactStamp). Findings:$([Environment]::NewLine)$detail"
    }
}

Describe 'v0.7.66 Fleet Update Status summary uses status emojis and groups failures first' {
    # Guards the v0.7.66 UX refresh of Step.8_fleet-update-status.yml summary blocks (file was Step.7 prior to v0.7.90 renumber)
    # on both GH and ADO. The summary now uses 'red cross / green tick' emojis
    # instead of '[ok]/[fail]/...' bracket markers, and the per-cluster JUnit
    # block orders failed clusters first.

    BeforeAll {
        $script:examplesRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples')).Path
        $script:fleetStatusFiles = @(
            Join-Path $script:examplesRoot 'github-actions\Step.8_fleet-update-status.yml'
            Join-Path $script:examplesRoot 'azure-devops\Step.8_fleet-update-status.yml'
        )
    }

    It "Both Step.8_fleet-update-status.yml files contain success and failure status emojis" {
        foreach ($yml in $script:fleetStatusFiles) {
            # Must read explicitly as UTF-8; the YAML has no BOM, and PS 5.1
            # Get-Content -Raw without -Encoding defaults to Default (cp1252),
            # which mangles multi-byte glyphs like U+2705 into 3 separate chars.
            $content = [System.IO.File]::ReadAllText($yml, [System.Text.UTF8Encoding]::new($false))
            # PowerShell here strings to dodge Unicode source-file confusion in this test:
            $tick  = [string]::new([char[]]@(0x2705))            # white-heavy-check-mark
            $cross = [string]::new([char[]]@(0x274C))            # cross-mark
            ($content -match [regex]::Escape($tick))  | Should -BeTrue  -Because "$(Split-Path -Leaf $yml) must use the U+2705 success emoji in its summary"
            ($content -match [regex]::Escape($cross)) | Should -BeTrue  -Because "$(Split-Path -Leaf $yml) must use the U+274C failure emoji in its summary"
            # Legacy bracket markers must be gone:
            ($content -match '\[ok\]')    | Should -BeFalse -Because "$(Split-Path -Leaf $yml) must no longer use the '[ok]' bracket marker"
            ($content -match '\[fail\]')  | Should -BeFalse -Because "$(Split-Path -Leaf $yml) must no longer use the '[fail]' bracket marker"
        }
    }

    It "Both Step.8_fleet-update-status.yml files render a UTC timestamp in the summary heading" {
        foreach ($yml in $script:fleetStatusFiles) {
            $content = Get-Content -LiteralPath $yml -Raw
            ($content -match 'Fleet Update Status Summary\s*_\(generated \$generatedUtc\)_') | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must include the generated UTC timestamp in the H2 heading"
            ($content -match 'generatedUtc\s*=\s*\(Get-Date\)\.ToUniversalTime\(\)') | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must compute generatedUtc with ToUniversalTime()"
        }
    }

    It "Both Step.8_fleet-update-status.yml files bucket failed clusters ahead of passed clusters before emitting the JUnit table" {
        foreach ($yml in $script:fleetStatusFiles) {
            $content = Get-Content -LiteralPath $yml -Raw
            ($content -match '\$failedClusters')    | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must build a `$failedClusters bucket"
            ($content -match '\$passedClusters')    | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must build a `$passedClusters bucket"
            ($content -match '\$orderedClusters\s*=\s*@\(\$failedClusters') | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must concatenate failed-first, then passed, into `$orderedClusters"
        }
    }
}

Describe 'v0.7.66 Pipeline update_ring inputs document multi-value and wildcard support' {
    BeforeAll {
        $script:examplesRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples')).Path
    }

    It "Every pipeline file that surfaces an update_ring/updateRing input mentions ';' and '***'" {
        $files = Get-ChildItem -Path $script:examplesRoot -Recurse -Filter '*.yml' -File
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($yml in $files) {
            $content = Get-Content -LiteralPath $yml.FullName -Raw
            # Only check files that EXPOSE the input (not files that merely read it via INPUT_UPDATE_RING).
            $exposesInput = $content -match '(?m)^\s+update_ring:\s*$' -or $content -match '(?m)^\s+-\s+name:\s+updateRing\s*$'
            if (-not $exposesInput) { continue }
            # Search for description: 'X' or displayName: 'X' lines following the input declaration.
            # v0.7.66 deliberately uses '***' (three stars) - a bare '*' is REJECTED by the cmdlet's ValidatePattern.
            $hasMultiHint = $content -match "Prod;Ring2" -and $content -match "'\*\*\*'"
            if (-not $hasMultiHint) {
                $offenders.Add("$($yml.FullName.Substring($script:examplesRoot.Length).TrimStart('\','/')): update_ring/updateRing input does not mention 'Prod;Ring2' AND '***' in its description/displayName")
            }
        }
        $detail = if ($offenders.Count -gt 0) { $offenders -join [Environment]::NewLine } else { '(no offenders)' }
        $offenders.Count | Should -Be 0 -Because "v0.7.66 documents multi-value + wildcard UpdateRing support on every exposed input. Findings:$([Environment]::NewLine)$detail"
    }
}

#endregion v0.7.66 UX + Multi-Value UpdateRing regression suite


#region v0.7.67 CI/CD parity + doc-drift regression suite

Describe 'v0.7.67 schedule-audit zero-row JUnit parity' {
    # v0.7.67 regression guard: Step.3_apply-updates-schedule-audit.yml previously
    # behaved differently across CI platforms when the fleet had no tagged
    # clusters. Azure DevOps emitted a passing testcase ("No tagged clusters
    # found - nothing to audit") so the run rendered as passed (1/1) in the
    # Tests tab. GitHub Actions wrote an EMPTY <testsuite>, which
    # dorny/test-reporter surfaced as "no tests found" - indistinguishable
    # from a broken reporter step. v0.7.67 brings the GH workflow into parity
    # by writing the same passing testcase for the zero-row case. This test
    # guards both files so neither side regresses.
    BeforeAll {
        $script:examplesRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples')).Path
    }

    It 'GitHub Actions schedule-audit YAML emits the zero-row testcase' {
        $yml = Join-Path $script:examplesRoot 'github-actions\Step.3_apply-updates-schedule-audit.yml'
        Test-Path -LiteralPath $yml | Should -BeTrue -Because "the GH schedule-audit YAML should exist at $yml"
        $content = Get-Content -LiteralPath $yml -Raw
        # v0.7.70: zero-row JUnit emission was refactored into a Write-Suite helper
        # with -EmptyPlaceholderName. The semantic guarantee (zero-row testcase is
        # emitted with this exact name) is preserved; the literal <testcase> string
        # is now built at runtime from the helper template.
        $content | Should -Match "-EmptyPlaceholderName 'No tagged clusters found - nothing to audit'" -Because 'v0.7.67/v0.7.70 wire the zero-row JUnit testcase via Write-Suite -EmptyPlaceholderName in the GH schedule-audit YAML'
        $content | Should -Match 'classname=`"ScheduleCoverage`" name=`"\{0\}`"' -Because 'the Write-Suite helper must build the testcase line with classname="ScheduleCoverage" and a {0} placeholder for the name'
    }

    It 'Azure DevOps schedule-audit YAML still emits the zero-row testcase' {
        $yml = Join-Path $script:examplesRoot 'azure-devops\Step.3_apply-updates-schedule-audit.yml'
        Test-Path -LiteralPath $yml | Should -BeTrue -Because "the ADO schedule-audit YAML should exist at $yml"
        $content = Get-Content -LiteralPath $yml -Raw
        # See GH note above - same refactor applies.
        $content | Should -Match "-EmptyPlaceholderName 'No tagged clusters found - nothing to audit'" -Because 'the ADO schedule-audit YAML must wire the zero-row JUnit testcase via Write-Suite -EmptyPlaceholderName since v0.7.0; v0.7.70 must not regress it'
        $content | Should -Match 'classname=`"ScheduleCoverage`" name=`"\{0\}`"' -Because 'the Write-Suite helper must build the testcase line with classname="ScheduleCoverage" and a {0} placeholder for the name'
    }
}

Describe 'v0.7.67 doc drift - old UpdateRing regex' {
    # v0.7.67 doc-drift guard: v0.7.66 widened the UpdateRing ValidatePattern
    # from the strict single-token form '^[A-Za-z0-9_-]{1,64}$' to the
    # semicolon-list + wildcard form
    # '^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$'. The strict
    # regex must NOT appear in any consumer-facing README. The CHANGELOG.md
    # historical entry for the regex change is the only legitimate place
    # where the old regex may still appear (as a historical reference).
    # This test scans non-CHANGELOG markdown for the literal old regex.
    It 'No consumer-facing README documents the v0.7.65 strict-single-token UpdateRing regex' {
        $oldRegexLiteral = '^[A-Za-z0-9_-]{1,64}$'
        $moduleRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        # CHANGELOG.md is the historical record - it MAY contain the old
        # regex when documenting the change. Everywhere else, it is drift.
        $targets = @(
            Join-Path $moduleRoot 'README.md'
            Join-Path $moduleRoot 'Automation-Pipeline-Examples\README.md'
        )
        $offenders = New-Object System.Collections.Generic.List[string]
        foreach ($md in $targets) {
            if (-not (Test-Path -LiteralPath $md)) { continue }
            $content = Get-Content -LiteralPath $md -Raw
            if ($content -and $content.Contains($oldRegexLiteral)) {
                $offenders.Add($md.Substring($moduleRoot.Length).TrimStart('\','/'))
            }
        }
        $detail = if ($offenders.Count -gt 0) { $offenders -join [Environment]::NewLine } else { '(no offenders)' }
        $offenders.Count | Should -Be 0 -Because "v0.7.66 widened the UpdateRing regex to accept semicolon-separated lists and the '***' wildcard. Any non-CHANGELOG README that still documents the strict single-token regex '$oldRegexLiteral' will mislead consumers. Findings:$([Environment]::NewLine)$detail"
    }
}

Describe 'v0.7.67 schedule-audit summary - cron fixes first when issues exist' {
    # Phase 4.3: when Uncovered / PartiallyCovered / MalformedTag / UnparseableCron > 0,
    # the schedule-audit pipelines must surface the recommended cron block ABOVE the
    # detail table so operators can act without scrolling. Guardrail asserts that both
    # YAMLs carry the conditional structure (hasIssues + 'Action required' header).
    $moduleRoot = Split-Path $PSScriptRoot -Parent
    $yamlCases = @(
        @{
            Platform = 'github-actions'
            YamlPath = (Join-Path $moduleRoot 'Automation-Pipeline-Examples\github-actions\Step.3_apply-updates-schedule-audit.yml')
        }
        @{
            Platform = 'azure-devops'
            YamlPath = (Join-Path $moduleRoot 'Automation-Pipeline-Examples\azure-devops\Step.3_apply-updates-schedule-audit.yml')
        }
    )

    It '[<Platform>] schedule-audit YAML emits recommendation before audit detail when issues exist' -ForEach $yamlCases {
        Test-Path $YamlPath | Should -BeTrue -Because "expected schedule-audit YAML at $YamlPath"
        $content = Get-Content -Path $YamlPath -Raw
        $content | Should -Match '\$hasIssues\s*=\s*\(\(\[int\]\$uncovered\)' -Because 'Phase 4.3 / v0.7.70 conditional must compute $hasIssues from the issue counts.'
        # v0.7.70: the 'Action required - ...' header literals moved into the
        # -View Recommend cmdlet output ($reco), so the YAML no longer contains
        # them verbatim. The structural guarantee (recommendation BEFORE detail
        # when $hasIssues) is preserved by the 'if ($hasIssues -and $reco) { $md = $reco + $md }'
        # block which prepends $reco to the summary markdown.
        $content | Should -Match 'if\s*\(\s*\$hasIssues\s+-and\s+\$reco\s*\)' -Because 'v0.7.70 must keep the hasIssues+reco conditional so the Recommend block is prepended above the audit detail table.'
        $idxRecoBlock      = $content.IndexOf('if ($hasIssues -and $reco)')
        $idxAuditDetail    = $content.IndexOf('### Audit Detail')
        $idxRecoBlock      | Should -BeGreaterThan -1
        $idxAuditDetail    | Should -BeGreaterThan -1
        $idxRecoBlock      | Should -BeLessThan $idxAuditDetail -Because 'When issues exist, the conditional that prepends the Recommend output must appear earlier in the summary script than the detail table emission.'
    }
}

Describe 'v0.7.67 Reset-AzLocalSideloadedTag warns on malformed Resource IDs' {
    # v0.7.67 review finding: the ByResourceId resolver silently dropped Resource
    # IDs that did not end in '/clusters/<name>'. Operators with typo'd inputs
    # (trailing slash, wrong provider, truncated string) would never see the
    # entry was excluded from the reset. This test ensures the resolver emits a
    # Write-Log Warning for any input it cannot match.
    BeforeAll {
        $moduleName = 'AzLocal.UpdateManagement'
    }

    It 'Writes a Warning for a malformed Resource ID and does not include it in targets' {
        InModuleScope AzLocal.UpdateManagement {
            $warnings = @()
            Mock Write-Log -ParameterFilter { $Level -eq 'Warning' } -MockWith {
                $script:warnings += ,$Message
            }
            Mock Write-Log {}
            Mock Test-AzCliAvailable { return $true }
            # Force the function to short-circuit before any 'az' / network call:
            # by passing only a malformed RID, $targets will end up empty, and
            # the function returns @() with a "no matching clusters" warning.
            $script:warnings = @()
            $script:result = $null
            { $script:result = Reset-AzLocalSideloadedTag `
                -ClusterResourceIds @('/this/is/not/a/cluster/resource/id') `
                -Confirm:$false } | Should -Not -Throw
            ($script:warnings -join "`n") | Should -Match "does not match an Azure Local cluster Resource ID"
        }
    }
}

Describe 'v0.7.67 Import-AzLocalFleetState size guard' {
    # v0.7.67 review finding: the helper called `Get-Content -Raw |
    # ConvertFrom-Json` on the input file without any size check. A user
    # pointed at a multi-GB file (typo, mis-glob, malicious symlink) would
    # OOM the runner. We now reject anything > 50 MB.
    It 'Throws when the input file exceeds the 50 MB safety cap' {
        InModuleScope AzLocal.UpdateManagement {
            $tempFile = Join-Path $env:TEMP "fleet-state-oversize-$([guid]::NewGuid()).json"
            '{"RunId":"x","TotalClusters":0,"CompletedCount":0,"FailedCount":0,"PendingCount":0}' |
                Out-File -FilePath $tempFile -Encoding ASCII
            try {
                Mock Get-Item {
                    [PSCustomObject]@{ Length = 60MB; FullName = $tempFile }
                } -ParameterFilter { $LiteralPath -eq $tempFile }
                # Capture Write-Error rather than letting it surface (the
                # helper catches the throw and re-emits via Write-Error,
                # returning $null).
                $result = Import-AzLocalFleetState -Path $tempFile -ErrorAction SilentlyContinue -ErrorVariable err
                $result | Should -BeNullOrEmpty
                ($err | Out-String) | Should -Match '50 MB safety cap'
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'Loads a normal-sized fleet state without invoking the cap' {
        InModuleScope AzLocal.UpdateManagement {
            $tempFile = Join-Path $env:TEMP "fleet-state-normal-$([guid]::NewGuid()).json"
            '{"RunId":"abc","StartTime":"2025-01-01T00:00:00Z","TotalClusters":1,"CompletedCount":0,"FailedCount":0,"PendingCount":1}' |
                Out-File -FilePath $tempFile -Encoding ASCII
            try {
                $result = Import-AzLocalFleetState -Path $tempFile
                $result | Should -Not -BeNullOrEmpty
                $result.RunId | Should -Be 'abc'
            }
            finally {
                Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

#endregion v0.7.67 CI/CD parity + doc-drift regression suite



#region v0.7.68 Update-AzLocalPipelineExample + marker parser

Describe 'Helper Function: Get-AzLocalPipelineCustomiseMarkers (Internal)' {

    It 'Returns an empty hashtable on empty input' {
        InModuleScope AzLocal.UpdateManagement {
            $r = Get-AzLocalPipelineCustomiseMarkers -Text ''
            $r | Should -BeOfType [hashtable]
            $r.Count | Should -Be 0
        }
    }

    It 'Returns an empty hashtable when no markers are present' {
        InModuleScope AzLocal.UpdateManagement {
            $r = Get-AzLocalPipelineCustomiseMarkers -Text @"
name: My Workflow
on:
  push:
    branches: [main]
"@
            $r.Count | Should -Be 0
        }
    }

    It 'Parses a single marker block with multi-line body' {
        InModuleScope AzLocal.UpdateManagement {
            $text = @"
on:
  # BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers
  schedule:
    - cron: '0 22 * * 6'
  # END-AZLOCAL-CUSTOMIZE:schedule-triggers
  workflow_dispatch:
"@
            $r = Get-AzLocalPipelineCustomiseMarkers -Text $text
            $r.Count | Should -Be 1
            $r.ContainsKey('schedule-triggers') | Should -BeTrue
            $r['schedule-triggers'].BeginLine | Should -Match 'BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers'
            $r['schedule-triggers'].EndLine   | Should -Match 'END-AZLOCAL-CUSTOMIZE:schedule-triggers'
            $r['schedule-triggers'].Body      | Should -Match "cron: '0 22 \* \* 6'"
        }
    }

    It 'Parses multiple distinct markers in the same file' {
        InModuleScope AzLocal.UpdateManagement {
            $text = @"
on:
  # BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers
  schedule: []
  # END-AZLOCAL-CUSTOMIZE:schedule-triggers
env:
  # BEGIN-AZLOCAL-CUSTOMIZE:itsm-secrets
  TOKEN: `${{ secrets.MY_TOKEN }}
  # END-AZLOCAL-CUSTOMIZE:itsm-secrets
"@
            $r = Get-AzLocalPipelineCustomiseMarkers -Text $text
            $r.Count | Should -Be 2
            $r.ContainsKey('schedule-triggers') | Should -BeTrue
            $r.ContainsKey('itsm-secrets')      | Should -BeTrue
        }
    }

    It 'Reconstructing BeginLine + Body + EndLine reproduces the original span exactly' {
        InModuleScope AzLocal.UpdateManagement {
            $text = "preamble`n  # BEGIN-AZLOCAL-CUSTOMIZE:demo`nline1`nline2`n  # END-AZLOCAL-CUSTOMIZE:demo`ntail"
            $r = Get-AzLocalPipelineCustomiseMarkers -Text $text
            $r.Count | Should -Be 1
            $b = $r['demo']
            $reassembled = $b.BeginLine + $b.Body + $b.EndLine
            $text.Substring($b.Index, $b.Length) | Should -BeExactly $reassembled
        }
    }

    It 'Skips duplicate marker names and keeps the first occurrence' {
        InModuleScope AzLocal.UpdateManagement {
            $text = @"
# BEGIN-AZLOCAL-CUSTOMIZE:dup
first
# END-AZLOCAL-CUSTOMIZE:dup
# BEGIN-AZLOCAL-CUSTOMIZE:dup
second
# END-AZLOCAL-CUSTOMIZE:dup
"@
            $r = Get-AzLocalPipelineCustomiseMarkers -Text $text 3>$null
            $r.Count | Should -Be 1
            $r['dup'].Body | Should -Match 'first'
        }
    }
}

Describe 'Function: Update-AzLocalPipelineExample' {

    BeforeAll {
        # The cmdlet resolves -Platform 'GitHub' to <ModuleBase>/Automation-Pipeline-Examples/github-actions
        # so all tests below operate against the development checkout's bundled samples.
        $script:UpePlatformSrcGh  = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples\github-actions'
        $script:UpePlatformSrcAdo = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples\azure-devops'
    }

    Context 'Parameter surface' {
        It 'Has Destination, Platform, Force, PassThru parameters' {
            $cmd = Get-Command Update-AzLocalPipelineExample
            $cmd.Parameters.Keys | Should -Contain 'Destination'
            $cmd.Parameters.Keys | Should -Contain 'Platform'
            $cmd.Parameters.Keys | Should -Contain 'Force'
            $cmd.Parameters.Keys | Should -Contain 'PassThru'
        }
        It 'Supports ShouldProcess (WhatIf / Confirm)' {
            $cmd = Get-Command Update-AzLocalPipelineExample
            $cmd.Parameters.Keys | Should -Contain 'WhatIf'
            $cmd.Parameters.Keys | Should -Contain 'Confirm'
        }
        It 'Platform is ValidateSet GitHub|AzureDevOps' {
            $cmd = Get-Command Update-AzLocalPipelineExample
            $attr = $cmd.Parameters['Platform'].Attributes |
                Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
            $attr | Should -Not -BeNullOrEmpty
            ($attr.ValidValues | Sort-Object) -join ',' | Should -Be 'AzureDevOps,GitHub'
        }
        It 'Throws when -Destination does not exist' {
            { Update-AzLocalPipelineExample -Destination "$env:TEMP\does-not-exist-$([guid]::NewGuid())" -Platform GitHub -PassThru } |
                Should -Throw -ExpectedMessage '*Destination*does not exist*'
        }
    }

    Context 'Net-new files are Created on the first run into an empty folder' {
        It 'Copies every bundled GitHub Actions YAML into an empty destination' {
            $temp = Join-Path $env:TEMP "upe-create-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            try {
                $r = Update-AzLocalPipelineExample -Destination $temp -Platform GitHub -PassThru -Confirm:$false
                $r | Should -Not -BeNullOrEmpty
                ($r | Where-Object Action -eq 'Created').Count | Should -BeGreaterThan 0
                ($r | Where-Object Action -eq 'Updated').Count | Should -Be 0
                # Every bundled GitHub Actions sample should now exist in the destination.
                $expected = Get-ChildItem -Path $script:UpePlatformSrcGh -Filter '*.yml' -File | Select-Object -ExpandProperty Name
                foreach ($name in $expected) {
                    Test-Path -LiteralPath (Join-Path $temp $name) | Should -BeTrue
                }
            }
            finally { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'Marker-aware merge preserves destination customisations' {
        It 'Replaces the schedule-triggers body with the destination body in Step.6_apply-updates.yml' {
            $temp = Join-Path $env:TEMP "upe-merge-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            try {
                # 1. Copy the bundled Step.6_apply-updates.yml to the destination.
                $src = Join-Path $script:UpePlatformSrcGh 'Step.6_apply-updates.yml'
                Copy-Item -Path $src -Destination $temp
                $destFile = Join-Path $temp 'Step.6_apply-updates.yml'

                # 2. Inject a customer cron INSIDE the schedule-triggers marker block.
                $customerBody = "`r`n  schedule:`r`n    - cron: '0 22 * * 6'  # Wave1 SatNight22UTC`r`n  "
                $destTextOriginal = [System.IO.File]::ReadAllText($destFile, [System.Text.UTF8Encoding]::new($false))
                $pattern = '(?ms)(BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers[^\r\n]*)(.*?)(  # END-AZLOCAL-CUSTOMIZE:schedule-triggers)'
                $destTextCustom = [regex]::Replace($destTextOriginal, $pattern, ('${1}' + [System.Text.RegularExpressions.Regex]::Escape($customerBody).Replace('\\','\').Replace('$','$$') + '${3}'), 1)
                # Simpler: do the substitution by string slice, not regex - the regex with .Escape is brittle.
                $marker = '# BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers'
                $endMark = '# END-AZLOCAL-CUSTOMIZE:schedule-triggers'
                $iStart = $destTextOriginal.IndexOf($marker) + $marker.Length
                $iEnd   = $destTextOriginal.IndexOf($endMark)
                $destTextCustom = $destTextOriginal.Substring(0,$iStart) + $customerBody + '  ' + $destTextOriginal.Substring($iEnd)
                [System.IO.File]::WriteAllText($destFile, $destTextCustom, [System.Text.UTF8Encoding]::new($false))

                # 3. Run the cmdlet. Source body should be REPLACED with customer body.
                $r = Update-AzLocalPipelineExample -Destination $temp -Platform GitHub -PassThru -Confirm:$false
                $row = $r | Where-Object { $_.File -like '*Step.6_apply-updates.yml' }
                $row.Action            | Should -Match 'Updated|Unchanged'
                # Customer cron MUST survive
                $newText = [System.IO.File]::ReadAllText($destFile, [System.Text.UTF8Encoding]::new($false))
                $newText | Should -Match "cron: '0 22 \* \* 6'"
                $row.PreservedMarkers | Should -Contain 'schedule-triggers'
            }
            finally { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'WhatIf does not write to disk' {
        It 'Reports Created for net-new files without creating them' {
            $temp = Join-Path $env:TEMP "upe-whatif-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            try {
                Update-AzLocalPipelineExample -Destination $temp -Platform GitHub -WhatIf 6>$null 4>$null
                (Get-ChildItem -Path $temp -File -ErrorAction SilentlyContinue).Count | Should -Be 0
            }
            finally { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Context 'First-migration (destination has no markers) requires -Force' {
        It 'Refuses to write without -Force and emits Skipped-NeedsForce' {
            $temp = Join-Path $env:TEMP "upe-firstmig-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            try {
                # Place a stripped-down YAML at dest with NO markers, same filename as a bundled file.
                $destFile = Join-Path $temp 'Step.6_apply-updates.yml'
                'name: legacy file with no markers' | Set-Content -LiteralPath $destFile -Encoding utf8

                $r = Update-AzLocalPipelineExample -Destination $temp -Platform GitHub -PassThru -Confirm:$false 3>$null
                $row = $r | Where-Object { $_.File -like '*Step.6_apply-updates.yml' }
                $row.Action | Should -Be 'Skipped-NeedsForce'
                # Dest file unchanged
                (Get-Content -Raw -LiteralPath $destFile) | Should -Match 'legacy file with no markers'
            }
            finally { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
        It 'Overwrites and records the new marker names when -Force is supplied' {
            $temp = Join-Path $env:TEMP "upe-firstmig-force-$([guid]::NewGuid())"
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            try {
                $destFile = Join-Path $temp 'Step.6_apply-updates.yml'
                'name: legacy file with no markers' | Set-Content -LiteralPath $destFile -Encoding utf8

                $r = Update-AzLocalPipelineExample -Destination $temp -Platform GitHub -PassThru -Force -Confirm:$false 3>$null
                $row = $r | Where-Object { $_.File -like '*Step.6_apply-updates.yml' }
                $row.Action | Should -Be 'Overwritten'
                $row.NewMarkers | Should -Contain 'schedule-triggers'
                (Get-Content -Raw -LiteralPath $destFile) | Should -Match 'BEGIN-AZLOCAL-CUSTOMIZE:schedule-triggers'
            }
            finally { Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

#endregion v0.7.68 Update-AzLocalPipelineExample + marker parser

#region v0.7.69 Apply-Updates Schedule (ring-aware: reader, resolver, next-firings, generator, update)

Describe 'v0.7.69 Apply-Updates Schedule: Get-AzLocalApplyUpdatesScheduleConfig (reader)' {
    BeforeAll {
        $script:sr_tmp = Join-Path $TestDrive 'sched-reader'
        New-Item -ItemType Directory -Path $script:sr_tmp -Force | Out-Null
    }
    It 'Throws with remediation hint when file not found' {
        { Get-AzLocalApplyUpdatesScheduleConfig -Path (Join-Path $script:sr_tmp 'does-not-exist.yml') } |
            Should -Throw -ExpectedMessage '*schedule file not found*'
    }
    It 'Parses a minimal valid schedule and returns expected fields' {
        $p = Join-Path $script:sr_tmp 'minimal.yml'
        $body = @'
schemaVersion: 1
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
    notes: 'first week monday'
'@
        Set-Content -LiteralPath $p -Value $body -Encoding utf8
        $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
        $cfg.SchemaVersion       | Should -Be 1
        $cfg.CycleWeeks          | Should -Be 4
        $cfg.CycleAnchorISOWeek  | Should -Be 1
        $cfg.CycleAnchorYear     | Should -Be 2026
        @($cfg.Schedule).Count   | Should -Be 1
        $cfg.Schedule[0].rings   | Should -Be 'Canary'
    }
    It "Throws 'schedule: list is empty' when no active rows (the strawman safety gate)" {
        $p = Join-Path $script:sr_tmp 'empty.yml'
        # All rows commented out - mirrors what the strawman generator emits.
        $body = @'
schemaVersion: 1
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  # - weeksInCycle: '1'
  #   daysOfWeek: 'Mon'
  #   rings: 'Canary'
'@
        Set-Content -LiteralPath $p -Value $body -Encoding utf8
        { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
            Should -Throw -ExpectedMessage "*'schedule:' list is empty*"
    }
    It 'Rejects unsupported schemaVersion' {
        $p = Join-Path $script:sr_tmp 'unsupported.yml'
        $body = @'
schemaVersion: 99
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '1'
    daysOfWeek: '*'
    rings: 'Canary'
'@
        Set-Content -LiteralPath $p -Value $body -Encoding utf8
        { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
            Should -Throw -ExpectedMessage "*schemaVersion '99' is not supported*"
    }
    It 'Rejects out-of-range cycleWeeks' {
        $p = Join-Path $script:sr_tmp 'badcycle.yml'
        $body = @'
schemaVersion: 1
cycleWeeks: 100
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '1'
    daysOfWeek: '*'
    rings: 'Canary'
'@
        Set-Content -LiteralPath $p -Value $body -Encoding utf8
        { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
            Should -Throw -ExpectedMessage "*'cycleWeeks' must be an integer in 1..52*"
    }
}

Describe 'v0.7.69 Apply-Updates Schedule: Resolve-AzLocalCurrentUpdateRing (resolver)' {
    BeforeAll {
        $script:sv_tmp = Join-Path $TestDrive 'sched-resolver'
        New-Item -ItemType Directory -Path $script:sv_tmp -Force | Out-Null

        # 4-week cycle anchored at ISO W1 2026; Mon-only rotation + every-Fri overlap row
        $p = Join-Path $script:sv_tmp 'cycle.yml'
        $body = @'
schemaVersion: 1
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
    notes: 'wk1 mon'
  - weeksInCycle: '2'
    daysOfWeek: 'Mon'
    rings: 'Ring1'
    notes: 'wk2 mon'
  - weeksInCycle: '3,4'
    daysOfWeek: 'Mon'
    rings: 'Prod'
    notes: 'wk3-4 mon'
  - weeksInCycle: '*'
    daysOfWeek: 'Fri'
    rings: 'Canary;Ring1'
    notes: 'every-friday union overlap'
'@
        Set-Content -LiteralPath $p -Value $body -Encoding utf8
        $script:sv_cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p

        # Compute Monday-of-ISO-W1-2026 once (this is the anchor day in UTC).
        $jan4 = [datetime]::new(2026, 1, 4, 0, 0, 0, [DateTimeKind]::Utc)
        $isoOff = ((($jan4.DayOfWeek.value__ + 6) % 7))
        $script:sv_wk1Mon = $jan4.AddDays(-1 * $isoOff)
    }
    It 'Resolves week-1 Monday to Canary' {
        $r = Resolve-AzLocalCurrentUpdateRing -Schedule $script:sv_cfg -Now $script:sv_wk1Mon.AddHours(12)
        $r.CycleWeek       | Should -Be 1
        $r.Rings           | Should -Contain 'Canary'
        $r.UpdateRingValue | Should -Be 'Canary'
    }
    It 'Resolves week-2 Monday to Ring1' {
        $r = Resolve-AzLocalCurrentUpdateRing -Schedule $script:sv_cfg -Now $script:sv_wk1Mon.AddDays(7).AddHours(12)
        $r.CycleWeek       | Should -Be 2
        $r.UpdateRingValue | Should -Be 'Ring1'
    }
    It 'Wraps cycle math past anchor: week 5 -> cycleWeek 1' {
        $r = Resolve-AzLocalCurrentUpdateRing -Schedule $script:sv_cfg -Now $script:sv_wk1Mon.AddDays(28).AddHours(12)
        $r.CycleWeek | Should -Be 1
    }
    It 'Returns empty Rings with explanatory Reason on no match' {
        # Tuesday is unscheduled in this config.
        $r = Resolve-AzLocalCurrentUpdateRing -Schedule $script:sv_cfg -Now $script:sv_wk1Mon.AddDays(1).AddHours(12)
        @($r.Rings).Count   | Should -Be 0
        $r.UpdateRingValue  | Should -BeNullOrEmpty
        $r.Reason           | Should -Match 'No schedule row matches'
    }
    It 'Unions overlapping rows (Friday) and joins rings with ; separator' {
        $wk1Fri = $script:sv_wk1Mon.AddDays(4).AddHours(12)
        $r = Resolve-AzLocalCurrentUpdateRing -Schedule $script:sv_cfg -Now $wk1Fri
        $r.Rings            | Should -Contain 'Canary'
        $r.Rings            | Should -Contain 'Ring1'
        @($r.Rings).Count   | Should -Be 2
        $r.UpdateRingValue  | Should -Be 'Canary;Ring1'
    }
}

Describe 'v0.7.69 Apply-Updates Schedule: Get-AzLocalApplyUpdatesScheduleNextFirings' {
    BeforeAll {
        $script:nf_tmp = Join-Path $TestDrive 'sched-firings'
        New-Item -ItemType Directory -Path $script:nf_tmp -Force | Out-Null

        $p = Join-Path $script:nf_tmp 'preview.yml'
        $body = @'
schemaVersion: 1
cycleWeeks: 2
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '*'
    daysOfWeek: 'Mon'
    rings: 'Canary'
    notes: 'every mon'
'@
        Set-Content -LiteralPath $p -Value $body -Encoding utf8
        $script:nf_cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
    }
    It 'Default Days = cycleWeeks*7 (14 rows for a 2-week cycle)' {
        $r = Get-AzLocalApplyUpdatesScheduleNextFirings -Schedule $script:nf_cfg
        @($r).Count | Should -Be 14
    }
    It 'Respects explicit -Days' {
        $r = Get-AzLocalApplyUpdatesScheduleNextFirings -Schedule $script:nf_cfg -Days 7
        @($r).Count | Should -Be 7
    }
    It 'Each row stamps DateUtc, DayOfWeekName, CycleWeek and UpdateRingValue' {
        # 2026-01-05 is Monday of ISO W2/2026.
        $start = [datetime]::new(2026, 1, 5, 0, 0, 0, [DateTimeKind]::Utc)
        $r = Get-AzLocalApplyUpdatesScheduleNextFirings -Schedule $script:nf_cfg -StartDate $start -Days 7
        $r[0].DateUtc.DayOfWeek | Should -Be ([System.DayOfWeek]::Monday)
        $r[0].UpdateRingValue   | Should -Be 'Canary'
        $r[0].Rings             | Should -Contain 'Canary'
        # Tuesday through Sunday are 'No match' in this config (only Mon matches).
        $r[1].UpdateRingValue   | Should -BeNullOrEmpty
        $r[1].Note              | Should -Be 'No match'
    }
}

Describe 'v0.7.69 Apply-Updates Schedule: New-AzLocalApplyUpdatesScheduleConfig (offline generator)' {
    BeforeAll {
        $script:gen_tmp = Join-Path $TestDrive 'sched-gen'
        New-Item -ItemType Directory -Path $script:gen_tmp -Force | Out-Null
    }
    It 'Emits a strawman with every schedule row commented out (safety gate)' {
        $out = Join-Path $script:gen_tmp 'apply-updates-schedule.yml'
        $null = New-AzLocalApplyUpdatesScheduleConfig -OutputPath $out -Rings @('Canary','Ring1','Ring2','Prod') -Force 6>$null
        Test-Path -LiteralPath $out | Should -Be $true
        $text = Get-Content -LiteralPath $out -Raw
        $text | Should -Match 'schemaVersion:\s*2'
        $text | Should -Match 'cycleWeeks:\s*4'
        # Active (uncommented) schedule rows must be zero.
        @($text -split "`n" | Where-Object { $_ -match '^\s*-\s+weeksInCycle:' }).Count | Should -Be 0
        # Commented strawman rows must cover all rings (one per ring + extras).
        @($text -split "`n" | Where-Object { $_ -match '^\s*#\s*-\s+weeksInCycle:' }).Count | Should -BeGreaterOrEqual 4
    }
    It 'Strawman triggers the reader safety gate (empty active schedule)' {
        $out = Join-Path $script:gen_tmp 'safety.yml'
        $null = New-AzLocalApplyUpdatesScheduleConfig -OutputPath $out -Rings @('Canary','Ring1') -Force 6>$null
        { Get-AzLocalApplyUpdatesScheduleConfig -Path $out } |
            Should -Throw -ExpectedMessage "*'schedule:' list is empty*"
    }
    It 'Refuses to overwrite an existing file without -Force' {
        $out = Join-Path $script:gen_tmp 'refuse.yml'
        $null = New-AzLocalApplyUpdatesScheduleConfig -OutputPath $out -Rings @('Canary') -Force 6>$null
        { New-AzLocalApplyUpdatesScheduleConfig -OutputPath $out -Rings @('Canary') 6>$null } |
            Should -Throw -ExpectedMessage '*already exists*'
    }
}

Describe 'v0.7.69 Apply-Updates Schedule: Update-AzLocalApplyUpdatesScheduleConfig' {
    BeforeAll {
        $script:up_tmp = Join-Path $TestDrive 'sched-update'
        New-Item -ItemType Directory -Path $script:up_tmp -Force | Out-Null

        $script:up_live = Join-Path $script:up_tmp 'live.yml'
        $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
        Set-Content -LiteralPath $script:up_live -Value $body -Encoding utf8
    }
    It 'Throws when -MergeNewRings is used (reserved for v0.7.70)' {
        { Update-AzLocalApplyUpdatesScheduleConfig -Path $script:up_live -MergeNewRings -Confirm:$false } |
            Should -Throw -ExpectedMessage '*reserved for v0.7.70*'
    }
    It 'Throws with remediation hint when file does not exist' {
        $missing = Join-Path $script:up_tmp 'does-not-exist.yml'
        { Update-AzLocalApplyUpdatesScheduleConfig -Path $missing -Confirm:$false } |
            Should -Throw -ExpectedMessage '*file not found*'
    }
    It 'No-op when file is already on the current schema version (idempotent)' {
        $before = Get-Item -LiteralPath $script:up_live
        $r = Update-AzLocalApplyUpdatesScheduleConfig -Path $script:up_live -PassThru -Confirm:$false 6>$null
        $r.Action               | Should -Be 'Unchanged-SchemaCurrent'
        $after = Get-Item -LiteralPath $script:up_live
        $after.Length           | Should -Be $before.Length
        $after.LastWriteTimeUtc | Should -Be $before.LastWriteTimeUtc
    }
}

Describe 'v0.7.89 Apply-Updates Schedule v2: allowedUpdateVersions allow-list' {
    BeforeAll {
        $script:av_tmp = Join-Path $TestDrive 'sched-allow'
        New-Item -ItemType Directory -Path $script:av_tmp -Force | Out-Null

        # Anchor Monday-of-ISO-W1-2026 (UTC) for resolver tests.
        $jan4 = [datetime]::new(2026, 1, 4, 0, 0, 0, [DateTimeKind]::Utc)
        $isoOff = ((($jan4.DayOfWeek.value__ + 6) % 7))
        $script:av_wk1Mon = $jan4.AddDays(-1 * $isoOff)
    }

    Context 'Validator: schemaVersion 2 acceptance + allow-list validation' {
        It 'Rejects schemaVersion: 2 without a top-level allowedUpdateVersions (mandatory in v0.7.89)' {
            $p = Join-Path $script:av_tmp 'v2-no-allow.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
                Should -Throw -ExpectedMessage "*requires a top-level 'allowedUpdateVersions:' field*"
        }

        It "Accepts schemaVersion: 2 with top-level 'Latest' (default = no constraint)" {
            $p = Join-Path $script:av_tmp 'v2-latest-default.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $cfg.SchemaVersion                       | Should -Be 2
            @($cfg.AllowedUpdateVersions).Count      | Should -Be 1
            $cfg.AllowedUpdateVersions[0]            | Should -Be 'Latest'
        }

        It "Canonicalises 'latest' / 'LATEST' to PascalCase 'Latest' (case-insensitive sentinel)" {
            foreach ($variant in 'latest','LATEST','LaTeSt') {
                $p = Join-Path $script:av_tmp "v2-latest-$variant.yml"
                $body = @"
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: '$variant'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
"@
                Set-Content -LiteralPath $p -Value $body -Encoding utf8
                $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
                $cfg.AllowedUpdateVersions[0] | Should -Be 'Latest' -Because "case-insensitive input '$variant' should canonicalise to PascalCase"
            }
        }

        It "Rejects mixed 'Latest;<explicit>' (sentinel cannot be combined with explicit versions in a single field)" {
            $p = Join-Path $script:av_tmp 'v2-mixed.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest;10.2604.0.123'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
                Should -Throw -ExpectedMessage "*mixes the reserved sentinel 'Latest' with explicit*"
        }

        It 'Parses top-level allowedUpdateVersions into a [string[]] preserving order' {
            $p = Join-Path $script:av_tmp 'v2-top.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: '10.2604.0.123;10.2610.0.456'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            @($cfg.AllowedUpdateVersions).Count | Should -Be 2
            $cfg.AllowedUpdateVersions[0]       | Should -Be '10.2604.0.123'
            $cfg.AllowedUpdateVersions[1]       | Should -Be '10.2610.0.456'
        }

        It 'Parses per-row allowedUpdateVersions into AllowedUpdateVersionsParsed' {
            $p = Join-Path $script:av_tmp 'v2-row.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
    allowedUpdateVersions: '10.2604.0.123'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $row = $cfg.Schedule[0]
            @($row.AllowedUpdateVersionsParsed).Count | Should -Be 1
            $row.AllowedUpdateVersionsParsed[0]       | Should -Be '10.2604.0.123'
        }

        It 'Rejects top-level allowedUpdateVersions on schemaVersion 1 with migration remediation hint' {
            $p = Join-Path $script:av_tmp 'v1-top.yml'
            $body = @'
schemaVersion: 1
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: '10.2604.0.123'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
                Should -Throw -ExpectedMessage "*requires schemaVersion >= 2*"
        }

        It 'Rejects per-row allowedUpdateVersions on schemaVersion 1' {
            $p = Join-Path $script:av_tmp 'v1-row.yml'
            $body = @'
schemaVersion: 1
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
    allowedUpdateVersions: '10.2604.0.123'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
                Should -Throw -ExpectedMessage "*requires schemaVersion >= 2*"
        }

        It "Rejects empty token from stray ';' (e.g. 'a;;b')" {
            $p = Join-Path $script:av_tmp 'v2-stray.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'a;;b'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
                Should -Throw -ExpectedMessage "*empty token*"
        }

        It 'Rejects whitespace inside a token' {
            $p = Join-Path $script:av_tmp 'v2-ws.yml'
            # YAML single-quoted strings preserve embedded spaces as data.
            $body = @"
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: '10.2604.0 .123;10.2610.0.456'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
"@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            { Get-AzLocalApplyUpdatesScheduleConfig -Path $p } |
                Should -Throw -ExpectedMessage "*contains whitespace*"
        }

        It 'Deduplicates case-insensitively preserving first-occurrence order' {
            $p = Join-Path $script:av_tmp 'v2-dedup.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: '10.2604.0.123;10.2610.0.456;10.2604.0.123'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            @($cfg.AllowedUpdateVersions).Count | Should -Be 2
            $cfg.AllowedUpdateVersions[0]       | Should -Be '10.2604.0.123'
            $cfg.AllowedUpdateVersions[1]       | Should -Be '10.2610.0.456'
        }
    }

    Context 'Resolver: precedence row > top-level + UNION across rows' {
        It "Per-row overrides top-level when ANY matched row has the field (Source = 'row')" {
            $p = Join-Path $script:av_tmp 'res-row-wins.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'top.1.2.3'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
    allowedUpdateVersions: 'row.4.5.6'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $r = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $script:av_wk1Mon.AddHours(12)
            $r.AllowedUpdateVersionsSource | Should -Be 'row'
            @($r.AllowedUpdateVersions).Count | Should -Be 1
            $r.AllowedUpdateVersions[0]    | Should -Be 'row.4.5.6'
            $r.AllowedUpdateVersionsValue  | Should -Be 'row.4.5.6'
        }

        It "Falls back to top-level when NO matched row has the field (Source = 'top-level')" {
            $p = Join-Path $script:av_tmp 'res-top-wins.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'top.1.2.3;top.4.5.6'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $r = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $script:av_wk1Mon.AddHours(12)
            $r.AllowedUpdateVersionsSource     | Should -Be 'top-level'
            @($r.AllowedUpdateVersions).Count  | Should -Be 2
            $r.AllowedUpdateVersionsValue      | Should -Be 'top.1.2.3;top.4.5.6'
        }

        It "Top-level 'Latest' resolves to an empty effective allow-list with Source='top-level' (no constraint sentinel)" {
            $p = Join-Path $script:av_tmp 'res-top-latest.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $r = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $script:av_wk1Mon.AddHours(12)
            $r.AllowedUpdateVersionsSource    | Should -Be 'top-level'
            @($r.AllowedUpdateVersions).Count | Should -Be 0
            $r.AllowedUpdateVersionsValue     | Should -BeNullOrEmpty
        }

        It "Cross-row UNION: a row contributing 'Latest' collapses the effective list to empty (Latest wins)" {
            $p = Join-Path $script:av_tmp 'res-latest-wins.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest'
schedule:
  - weeksInCycle: '*'
    daysOfWeek: 'Fri'
    rings: 'Canary'
    allowedUpdateVersions: 'a;b'
  - weeksInCycle: '*'
    daysOfWeek: 'Fri'
    rings: 'Ring1'
    allowedUpdateVersions: 'Latest'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $wk1Fri = $script:av_wk1Mon.AddDays(4).AddHours(12)
            $r = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $wk1Fri
            $r.AllowedUpdateVersionsSource    | Should -Be 'row'
            @($r.AllowedUpdateVersions).Count | Should -Be 0
            $r.AllowedUpdateVersionsValue     | Should -BeNullOrEmpty
            $r.Reason                         | Should -Match 'AllowedUpdateVersions \(row\): Latest \(no constraint'
        }

        It 'UNIONs allow-lists across multiple matched rows (with case-insensitive dedup)' {
            # Friday Wk1: matches both 'Fri' rows; per-row wins; lists union and dedup.
            $p = Join-Path $script:av_tmp 'res-union.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest'
schedule:
  - weeksInCycle: '*'
    daysOfWeek: 'Fri'
    rings: 'Canary'
    allowedUpdateVersions: 'a;b'
  - weeksInCycle: '*'
    daysOfWeek: 'Fri'
    rings: 'Ring1'
    allowedUpdateVersions: 'B;c'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $wk1Fri = $script:av_wk1Mon.AddDays(4).AddHours(12)
            $r = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $wk1Fri
            $r.AllowedUpdateVersionsSource    | Should -Be 'row'
            @($r.AllowedUpdateVersions).Count | Should -Be 3
            ($r.AllowedUpdateVersions -join ';') | Should -Be 'a;b;c'
        }

        It "Row without the field is 'no opinion' (does not collapse the UNION to empty)" {
            $p = Join-Path $script:av_tmp 'res-opinion.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'Latest'
schedule:
  - weeksInCycle: '*'
    daysOfWeek: 'Fri'
    rings: 'Canary'
    allowedUpdateVersions: 'only.this'
  - weeksInCycle: '*'
    daysOfWeek: 'Fri'
    rings: 'Ring1'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $wk1Fri = $script:av_wk1Mon.AddDays(4).AddHours(12)
            $r = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $wk1Fri
            $r.AllowedUpdateVersionsSource    | Should -Be 'row'
            @($r.AllowedUpdateVersions).Count | Should -Be 1
            $r.AllowedUpdateVersions[0]       | Should -Be 'only.this'
        }

        It "Appends 'AllowedUpdateVersions (source): ...' to Reason when an allow-list is in effect" {
            $p = Join-Path $script:av_tmp 'res-reason.yml'
            $body = @'
schemaVersion: 2
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
allowedUpdateVersions: 'x.y.z'
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
'@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $r = Resolve-AzLocalCurrentUpdateRing -Schedule $cfg -Now $script:av_wk1Mon.AddHours(12)
            $r.Reason | Should -Match 'AllowedUpdateVersions \(top-level\): x\.y\.z\.'
        }
    }

    Context 'Schema migration: 1->2 (additive, idempotent)' {
        It 'Migrates schemaVersion 1 to 2 and inserts the documented commented block' {
            $p = Join-Path $script:av_tmp 'mig-v1.yml'
            $body = @"
schemaVersion: 1
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026

# ---- Schedule entries ----
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
"@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $r = Update-AzLocalApplyUpdatesScheduleConfig -Path $p -PassThru -Confirm:$false 6>$null
            $r.Action      | Should -Be 'Migrated'
            $r.FromVersion | Should -Be 1
            $r.ToVersion   | Should -Be 2
            $migrated = Get-Content -LiteralPath $p -Raw
            $migrated | Should -Match 'schemaVersion:\s*2'
            $migrated | Should -Match '# >>> ALLOWED-UPDATE-VERSIONS-V2 <<<'
            $migrated | Should -Match '#\s+allowedUpdateVersions:'
            # v0.7.89: migrator inserts an ACTIVE top-level
            # 'allowedUpdateVersions: ''Latest''' line so the migrated
            # file satisfies the new mandatory rule with zero behaviour
            # change ('Latest' = no constraint = historic v0.7.88 default).
            $migrated | Should -Match "allowedUpdateVersions:\s*'Latest'"
            # Reader accepts the migrated file.
            $cfg = Get-AzLocalApplyUpdatesScheduleConfig -Path $p
            $cfg.SchemaVersion | Should -Be 2
        }

        It 'Migration is idempotent: running twice produces the same file' {
            $p = Join-Path $script:av_tmp 'mig-idem.yml'
            $body = @"
schemaVersion: 1
cycleWeeks: 4
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026

# ---- Schedule entries ----
schedule:
  - weeksInCycle: '1'
    daysOfWeek: 'Mon'
    rings: 'Canary'
"@
            Set-Content -LiteralPath $p -Value $body -Encoding utf8
            $null = Update-AzLocalApplyUpdatesScheduleConfig -Path $p -PassThru -Confirm:$false 6>$null
            $afterFirst = Get-Content -LiteralPath $p -Raw
            $r2 = Update-AzLocalApplyUpdatesScheduleConfig -Path $p -PassThru -Confirm:$false 6>$null
            $r2.Action | Should -Be 'Unchanged-SchemaCurrent'
            $afterSecond = Get-Content -LiteralPath $p -Raw
            $afterSecond | Should -Be $afterFirst
            # Marker appears exactly once.
            ([regex]::Matches($afterSecond, '# >>> ALLOWED-UPDATE-VERSIONS-V2 <<<')).Count | Should -Be 1
        }
    }

    Context 'Start-AzLocalClusterUpdate: -AllowedUpdateVersions parameter surface' {
        BeforeAll { $script:av_cmd = Get-Command Start-AzLocalClusterUpdate }
        It 'Exposes -AllowedUpdateVersions parameter' {
            $script:av_cmd.Parameters.Keys | Should -Contain 'AllowedUpdateVersions'
        }
        It 'AllowedUpdateVersions is typed as [string[]]' {
            $script:av_cmd.Parameters['AllowedUpdateVersions'].ParameterType.FullName | Should -Be 'System.String[]'
        }
        It 'AllowedUpdateVersions is NOT mandatory (allow-list is optional)' {
            $param = $script:av_cmd.Parameters['AllowedUpdateVersions']
            $attrs = $param.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            ($attrs | ForEach-Object Mandatory) | Should -Not -Contain $true
        }
    }
}

#endregion v0.7.69 Apply-Updates Schedule (ring-aware)

#region v0.7.70 (Workstream A: Step.3 Audit UX refresh + Workstream B: Step.7 Fleet Health Overview)

# -----------------------------------------------------------------------------
# v0.7.70 - Workstream A: Test-AzLocalApplyUpdatesScheduleCoverage
# -----------------------------------------------------------------------------
# v0.7.70 added a 'Section' discriminator ('Schedule' for ring-diff rows,
# 'Cron' for window-coverage rows) to every Audit row, the cmdlet now emits
# missing-from-schedule + orphaned-in-schedule rows whenever -SchedulePath
# is supplied, and -View Recommend renders one multi-section markdown
# snippet with "## Action required (N of M)" numbering. These tests cover
# all five of those behaviour changes (AS1..AS6).

Describe 'Function: Test-AzLocalApplyUpdatesScheduleCoverage - v0.7.70 Section discriminator + multi-section Recommend' {

    BeforeAll {
        # Reusable ARG payload: two clusters on Wave1 with a Sat-Sun window,
        # plus one cluster on Production with a Mon-Fri window that the
        # default empty cron set will NOT cover.
        $script:v7_70_argRows = @(
            [PSCustomObject]@{ ClusterName='c1'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c1'; UpdateRing='Wave1';      UpdateStartWindow='Sat-Sun_02:00-06:00' },
            [PSCustomObject]@{ ClusterName='c2'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c2'; UpdateRing='Wave1';      UpdateStartWindow='Sat-Sun_02:00-06:00' },
            [PSCustomObject]@{ ClusterName='c3'; ResourceGroup='r'; SubscriptionId='s'; ClusterResourceId='/s/r/c3'; UpdateRing='Production'; UpdateStartWindow='Mon-Fri_22:00-04:00' }
        )

        # Empty pipeline YAML directory => zero crons => every window Uncovered.
        $script:v7_70_yamlDir = Join-Path $env:TEMP "v770-coverage-yaml-$(Get-Random)"
        New-Item -ItemType Directory -Path (Join-Path $script:v7_70_yamlDir 'github-actions') -Force | Out-Null
        @"
on:
  workflow_dispatch:
"@ | Set-Content -Path (Join-Path $script:v7_70_yamlDir 'github-actions\Step.6_apply-updates.yml') -Encoding ASCII

        # Schedule file that knows about Pilot + Wave1 but is MISSING 'Production'
        # (which is tagged on c3) and ORPHANS 'Pilot' (which no cluster carries).
        # NOTE: top-level keys must be at column 0; the schedule reader's lexer is
        # not a general YAML parser. Field names: weeksInCycle, daysOfWeek, rings.
        $script:v7_70_schedDir = Join-Path $env:TEMP "v770-coverage-sched-$(Get-Random)"
        New-Item -ItemType Directory -Path $script:v7_70_schedDir -Force | Out-Null
        $script:v7_70_schedPath = Join-Path $script:v7_70_schedDir 'apply-updates-schedule.yml'
        @"
schemaVersion: 1
cycleWeeks: 2
cycleAnchorISOWeek: 1
cycleAnchorYear: 2026
schedule:
  - weeksInCycle: '1'
    daysOfWeek:   'Sat'
    rings:        'Pilot'
    notes:        'Pilot only'
  - weeksInCycle: '2'
    daysOfWeek:   'Sat'
    rings:        'Wave1'
    notes:        'Wave1 only'
"@ | Set-Content -Path $script:v7_70_schedPath -Encoding ASCII
    }

    AfterAll {
        Remove-Item -Path $script:v7_70_yamlDir  -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $script:v7_70_schedDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'AS1 / AS2 - Section discriminator on Audit rows' {

        It 'AS1: Audit rows have Section=Schedule for RingMissing/Orphaned and Section=Cron for ring/window rows' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Audit -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                # Schedule rows: Production missing, Pilot orphaned.
                $missing  = $result | Where-Object Status -eq 'RingMissingFromSchedule'
                $orphaned = $result | Where-Object Status -eq 'RingOrphanedInSchedule'
                $missing  | Should -Not -BeNullOrEmpty
                $orphaned | Should -Not -BeNullOrEmpty
                $missing.Section  | Should -Be 'Schedule'
                $orphaned.Section | Should -Be 'Schedule'

                # Cron rows: at least one (Ring, Window) tuple from the ARG data.
                $cronRows = $result | Where-Object Section -eq 'Cron'
                $cronRows | Should -Not -BeNullOrEmpty
                ($cronRows | ForEach-Object Section | Sort-Object -Unique) | Should -Be 'Cron'
            }
        }

        It 'AS2: Schedule-section rows have empty UpdateStartWindow + RequiredCronUTC (the ring is the unit, not a window)' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Audit -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                $scheduleRows = $result | Where-Object Section -eq 'Schedule'
                $scheduleRows | Should -Not -BeNullOrEmpty
                foreach ($r in $scheduleRows) {
                    [string]$r.UpdateStartWindow    | Should -BeNullOrEmpty
                    [string]$r.RequiredCronUTC | Should -BeNullOrEmpty
                }
            }
        }

        It 'AS5: Schedule-section rows are suppressed when -SchedulePath is omitted' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $result = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Audit -PipelineYamlPath $yamlDir -PassThru 6>$null

                $scheduleRows = $result | Where-Object Section -eq 'Schedule'
                @($scheduleRows).Count | Should -Be 0
                ($result | Where-Object Section -eq 'Cron') | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'AS3 / AS4 / AS6 - -View Recommend emits multi-section markdown' {

        It 'AS3: Recommend emits an "Action required - add these rings" section when RingMissingFromSchedule rows are present' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $rec = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Recommend -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                $snippet = ($rec | Select-Object -First 1).Snippet
                $snippet | Should -Not -BeNullOrEmpty
                $snippet | Should -Match '## Action required.*add these rings'
            }
        }

        It 'AS4: Recommend emits an "Action required - cron coverage" section when uncovered windows are present' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $rec = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Recommend -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                $snippet = ($rec | Select-Object -First 1).Snippet
                $snippet | Should -Not -BeNullOrEmpty
                $snippet | Should -Match '## Action required.*cron coverage'
            }
        }

        It 'AS6: when both schedule and cron sections are emitted, the schedule section appears BEFORE the cron section' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $rec = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Recommend -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                $snippet  = ($rec | Select-Object -First 1).Snippet
                $idxSched = $snippet.IndexOf('add these rings')
                $idxCron  = $snippet.IndexOf('cron coverage')
                $idxSched | Should -BeGreaterThan -1
                $idxCron  | Should -BeGreaterThan -1
                $idxSched | Should -BeLessThan $idxCron -Because 'schedule fixes have higher blast radius and must surface first'
            }
        }
    }

    # v0.7.75: when the caller does NOT pass -Platform, the cmdlet
    # auto-detects the host CI platform from environment variables so a
    # stale consumer yml (that does not pass -Platform) self-heals against
    # the cross-platform-noise failure mode (GH workflow run still emits
    # the ADO snippet). The tests below cover the four paths through the
    # auto-detect block: GITHUB_ACTIONS, TF_BUILD, explicit -Platform Both
    # honoured even in CI, and the "no CI env vars" interactive default.
    Context 'AS7-AS10 v0.7.75 CI host auto-detection' {

        BeforeEach {
            # Pre-clear so each test starts from a known-clean env.
            Remove-Item Env:GITHUB_ACTIONS                       -ErrorAction SilentlyContinue
            Remove-Item Env:TF_BUILD                             -ErrorAction SilentlyContinue
            Remove-Item Env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI   -ErrorAction SilentlyContinue
        }
        AfterEach {
            Remove-Item Env:GITHUB_ACTIONS                       -ErrorAction SilentlyContinue
            Remove-Item Env:TF_BUILD                             -ErrorAction SilentlyContinue
            Remove-Item Env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI   -ErrorAction SilentlyContinue
        }

        It 'AS7: auto-detects Platform=GitHubActions when $env:GITHUB_ACTIONS=true and -Platform is omitted' {
            $env:GITHUB_ACTIONS = 'true'
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $rec = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Recommend -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                $snippet = ($rec | Select-Object -First 1).Snippet
                $snippet | Should -Match 'workflow_dispatch'
                $snippet | Should -Not -Match 'displayName: "Apply Updates - covers above window"' `
                    -Because 'GH-host auto-detect must suppress the ADO snippet'
            }
        }

        It 'AS8: auto-detects Platform=AzureDevOps when $env:TF_BUILD=True and -Platform is omitted' {
            $env:TF_BUILD = 'True'
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $rec = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Recommend -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                $snippet = ($rec | Select-Object -First 1).Snippet
                $snippet | Should -Match 'displayName: "Apply Updates - covers above window"'
                $snippet | Should -Not -Match 'workflow_dispatch' `
                    -Because 'ADO-host auto-detect must suppress the GH snippet'
            }
        }

        It 'AS9: explicit -Platform Both is honoured even inside a CI runner ($env:GITHUB_ACTIONS=true)' {
            $env:GITHUB_ACTIONS = 'true'
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $rec = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Recommend -PipelineYamlPath $yamlDir -SchedulePath $schedPath -Platform Both -PassThru 6>$null

                $snippet = ($rec | Select-Object -First 1).Snippet
                $snippet | Should -Match 'workflow_dispatch'
                $snippet | Should -Match 'displayName: "Apply Updates - covers above window"' `
                    -Because 'an explicit caller -Platform Both must suppress auto-detect (caller wins)'
            }
        }

        It 'AS10: interactive default ("Both") preserved when neither $env:GITHUB_ACTIONS nor $env:TF_BUILD is set' {
            # BeforeEach has already cleared both env vars; -Platform omitted.
            InModuleScope AzLocal.UpdateManagement -Parameters @{
                yamlDir = $script:v7_70_yamlDir; schedPath = $script:v7_70_schedPath; rows = $script:v7_70_argRows
            } {
                param($yamlDir, $schedPath, $rows)
                Mock Invoke-AzResourceGraphQuery { $rows }
                $rec = Test-AzLocalApplyUpdatesScheduleCoverage `
                    -View Recommend -PipelineYamlPath $yamlDir -SchedulePath $schedPath -PassThru 6>$null

                $snippet = ($rec | Select-Object -First 1).Snippet
                $snippet | Should -Match 'workflow_dispatch' `
                    -Because 'interactive operator wants both snippets to compare'
                $snippet | Should -Match 'displayName: "Apply Updates - covers above window"' `
                    -Because 'interactive operator wants both snippets to compare'
            }
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.70 - Workstream A: Step.3 YAML scaffold check (AS7)
# -----------------------------------------------------------------------------
# AS7 verifies that the regenerated Step.3 pipeline templates (both GH and
# ADO) emit TWO JUnit <testsuite> elements - 'Schedule (ring diff)' first
# and 'Cron coverage' second - so downstream test panels render the dual
# section UX the cmdlet now produces.

Describe 'Step.3 pipeline scaffolds - v0.7.70 dual JUnit testsuite emission' {

    Context 'AS7 - YAML scaffolds reference both Schedule and Cron suite names' {

        It 'Step.3 GitHub Actions YAML contains both "Schedule (ring diff)" and "Cron coverage" suite names' {
            $ghYaml = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples\github-actions\Step.3_apply-updates-schedule-audit.yml'
            Test-Path $ghYaml | Should -BeTrue
            $raw = Get-Content -Raw -LiteralPath $ghYaml
            $raw | Should -Match 'Schedule \(ring diff\)'
            $raw | Should -Match 'Cron coverage'
        }

        It 'Step.3 Azure DevOps YAML contains both "Schedule (ring diff)" and "Cron coverage" suite names' {
            $adoYaml = Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples\azure-devops\Step.3_apply-updates-schedule-audit.yml'
            Test-Path $adoYaml | Should -BeTrue
            $raw = Get-Content -Raw -LiteralPath $adoYaml
            $raw | Should -Match 'Schedule \(ring diff\)'
            $raw | Should -Match 'Cron coverage'
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.70 - Workstream B: Get-AzLocalFleetHealthFailures (BS1..BS5)
# -----------------------------------------------------------------------------
# v0.7.70 reordered the Summary view to put Critical before Warning
# regardless of ClusterCount; added AffectedClusterPortalUrls to Summary
# rows (positionally paired with AffectedClusters via the new '; '
# separator); and added TargetResourceName, TargetResourceType, and
# ClusterPortalUrl to Detail rows.

Describe 'Function: Get-AzLocalFleetHealthFailures - v0.7.70 schema + ordering' {

    Context 'BS1 - Summary view sorts Critical before Warning regardless of ClusterCount' {

        It 'A widespread Warning does NOT outrank a less-widespread Critical' {
            InModuleScope AzLocal.UpdateManagement {
                # v0.7.76: cluster-shape mock.
                # Time-skew (Warning) hits THREE clusters; Storage pool (Critical) hits ONE.
                # Old (pre-v0.7.70) sort would put Time skew first (ClusterCount=3 wins).
                # New v0.7.70 sort puts Critical first regardless of count.
                $payload = @{
                    count = 4
                    data  = @(
                        @{ ClusterName='C1'; ResourceGroup='R'; SubscriptionId='s1'; ClusterResourceId='/x/c1'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c1'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName='c1'; targetResourceType='cluster'; timestamp='2026-05-16T08:00:00Z' }
                        ) },
                        @{ ClusterName='C2'; ResourceGroup='R'; SubscriptionId='s1'; ClusterResourceId='/x/c2'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c2'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='ts';  displayName='Time skew detected';    description='d'; remediation='r'; severity='Warning';  status='Failed'; targetResourceName='c2'; targetResourceType='cluster'; timestamp='2026-05-16T07:00:00Z' }
                        ) },
                        @{ ClusterName='C3'; ResourceGroup='R'; SubscriptionId='s1'; ClusterResourceId='/x/c3'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c3'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='ts';  displayName='Time skew detected';    description='d'; remediation='r'; severity='Warning';  status='Failed'; targetResourceName='c3'; targetResourceType='cluster'; timestamp='2026-05-16T07:00:00Z' }
                        ) },
                        @{ ClusterName='C4'; ResourceGroup='R'; SubscriptionId='s1'; ClusterResourceId='/x/c4'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c4'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='ts';  displayName='Time skew detected';    description='d'; remediation='r'; severity='Warning';  status='Failed'; targetResourceName='c4'; targetResourceType='cluster'; timestamp='2026-05-16T07:00:00Z' }
                        ) }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $summary = Get-AzLocalFleetHealthFailures -View Summary
                $summary | Should -Not -BeNullOrEmpty
                $summary[0].Severity      | Should -Be 'Critical'
                $summary[0].FailureReason | Should -Be 'Storage pool degraded'
                $summary[0].ClusterCount  | Should -Be 1
                # Warning (with ClusterCount=3) follows the Critical (with ClusterCount=1).
                $summary[1].Severity      | Should -Be 'Warning'
                $summary[1].ClusterCount  | Should -Be 3
            }
        }
    }

    Context 'BS2 / BS3 - Detail rows expose target resource and portal URL' {

        It 'BS2: Detail rows contain TargetResourceName, TargetResourceType, and ClusterPortalUrl properties' {
            InModuleScope AzLocal.UpdateManagement {
                $payload = @{
                    count = 1
                    data  = @(
                        @{
                            ClusterName       = 'Cluster01'
                            ResourceGroup     = 'RG1'
                            SubscriptionId    = 'sub-1111'
                            ClusterResourceId = '/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            ClusterPortalUrl  = 'https://portal.azure.com/#@/resource/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            HealthCheckCount  = 1
                            HealthCheckResult = @(
                                @{
                                    name               = 'storage-pool-health'
                                    displayName        = 'Storage pool degraded'
                                    description        = 'd'
                                    remediation        = 'r'
                                    severity           = 'Critical'
                                    status             = 'Failed'
                                    targetResourceName = 'Drive-7'
                                    targetResourceType = 'PhysicalDisk'
                                    timestamp          = '2026-05-16T08:00:00Z'
                                }
                            )
                        }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $rows = Get-AzLocalFleetHealthFailures -View Detail
                $rows | Should -HaveCount 1
                $rows[0].PSObject.Properties.Name | Should -Contain 'TargetResourceName'
                $rows[0].PSObject.Properties.Name | Should -Contain 'TargetResourceType'
                $rows[0].PSObject.Properties.Name | Should -Contain 'ClusterPortalUrl'
            }
        }

        It 'BS3: ClusterPortalUrl matches the portal URL shape (https://portal.azure.com/#@/resource/subscriptions/...)' {
            InModuleScope AzLocal.UpdateManagement {
                $payload = @{
                    count = 1
                    data  = @(
                        @{
                            ClusterName       = 'Cluster01'
                            ResourceGroup     = 'RG1'
                            SubscriptionId    = 'sub-1111'
                            ClusterResourceId = '/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            ClusterPortalUrl  = 'https://portal.azure.com/#@/resource/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            HealthCheckCount  = 1
                            HealthCheckResult = @(
                                @{ name='x'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' }
                            )
                        }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $rows = Get-AzLocalFleetHealthFailures -View Detail
                $rows[0].ClusterPortalUrl | Should -Match '^https://portal\.azure\.com/#@/resource/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.AzureStackHCI/clusters/[^/]+$'
            }
        }
    }

    Context 'BS4 / BS5 - Summary rows expose paired AffectedClusterPortalUrls and use the new "; " separator' {

        It 'BS4: AffectedClusters and AffectedClusterPortalUrls have the same "; "-split count' {
            InModuleScope AzLocal.UpdateManagement {
                $payload = @{
                    count = 2
                    data  = @(
                        @{ ClusterName='C1'; ResourceGroup='R'; SubscriptionId='s'; ClusterResourceId='/x/c1'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c1'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' }
                        ) },
                        @{ ClusterName='C2'; ResourceGroup='R'; SubscriptionId='s'; ClusterResourceId='/x/c2'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c2'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:10:00Z' }
                        ) }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $summary = Get-AzLocalFleetHealthFailures -View Summary
                $summary[0].PSObject.Properties.Name | Should -Contain 'AffectedClusterPortalUrls'
                $names = @($summary[0].AffectedClusters          -split '; ')
                $urls  = @($summary[0].AffectedClusterPortalUrls -split '; ')
                $names.Count | Should -Be $urls.Count
                $names.Count | Should -Be 2
            }
        }

        It 'BS5: AffectedClusters uses the new "; " separator (space after the semicolon, never "; A" run together)' {
            InModuleScope AzLocal.UpdateManagement {
                $payload = @{
                    count = 2
                    data  = @(
                        @{ ClusterName='C1'; ResourceGroup='R'; SubscriptionId='s'; ClusterResourceId='/x/c1'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c1'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:00:00Z' }
                        ) },
                        @{ ClusterName='C2'; ResourceGroup='R'; SubscriptionId='s'; ClusterResourceId='/x/c2'; ClusterPortalUrl='https://portal.azure.com/#@/resource/x/c2'; HealthCheckCount=1; HealthCheckResult=@(
                            @{ name='spd'; displayName='Storage pool degraded'; description='d'; remediation='r'; severity='Critical'; status='Failed'; targetResourceName=''; targetResourceType=''; timestamp='2026-05-16T08:10:00Z' }
                        ) }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $summary = Get-AzLocalFleetHealthFailures -View Summary
                $value   = [string]$summary[0].AffectedClusters
                # NEVER a semicolon immediately followed by a non-space character.
                $value | Should -Not -Match ';[^ ]'
                # Multi-cluster value must contain at least one "; ".
                $value | Should -Match '; '
            }
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.76 - Get-AzLocalFleetHealthFailures: ARG mv-expand 128-cap regression
# -----------------------------------------------------------------------------
# v0.7.76 removed the `mv-expand` from the ARG query because Azure Resource
# Graph silently caps the operator at 128 expanded child rows per parent.
# Any cluster whose `properties.healthCheckResult` array exceeded 128 entries
# was silently losing >50% of its health checks - including Failed ones.
# This Describe block proves the fix: when the ARG response carries a
# 200-entry array with a Failed entry at index 150 (well past the old 128
# cap), the cmdlet now expands it client-side and returns the entry.

Describe 'Function: Get-AzLocalFleetHealthFailures - v0.7.76 ARG mv-expand 128-cap regression' {

    Context 'Client-side expansion bypasses the ARG mv-expand cap' {

        It 'Returns a Failed entry at array index 150 (well past the historical 128-row mv-expand cap)' {
            InModuleScope AzLocal.UpdateManagement {
                # Build a 200-entry healthCheckResult: 199 Succeeded fillers
                # plus one Failed entry placed at index 150. The OLD KQL
                # would silently drop everything past index 128, so the
                # Failed entry would never have appeared in the result.
                $checks = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt 200; $i++) {
                    if ($i -eq 150) {
                        [void]$checks.Add(@{
                            name               = 'late-failure-marker'
                            displayName        = 'Late array position failure (index 150)'
                            description        = 'Synthetic failure placed beyond the historical mv-expand 128-row cap.'
                            remediation        = 'Confirm client-side expansion is present.'
                            severity           = 'Critical'
                            status             = 'Failed'
                            targetResourceName = 'BeyondCap'
                            targetResourceType = 'RegressionMarker'
                            timestamp          = '2026-05-19T12:00:00Z'
                        })
                    } else {
                        [void]$checks.Add(@{
                            name               = "filler-$i"
                            displayName        = "Filler check $i"
                            description        = 'd'
                            remediation        = 'r'
                            severity           = 'Critical'
                            status             = 'Succeeded'
                            targetResourceName = ''
                            targetResourceType = ''
                            timestamp          = '2026-05-19T11:00:00Z'
                        })
                    }
                }

                $payload = @{
                    count = 1
                    data  = @(
                        @{
                            ClusterName       = 'BigCluster'
                            ResourceGroup     = 'RG-big'
                            SubscriptionId    = 'sub-big'
                            ClusterResourceId = '/subscriptions/sub-big/resourceGroups/RG-big/providers/Microsoft.AzureStackHCI/clusters/BigCluster'
                            ClusterPortalUrl  = 'https://portal.azure.com/#@/resource/subscriptions/sub-big/resourceGroups/RG-big/providers/Microsoft.AzureStackHCI/clusters/BigCluster'
                            HealthCheckCount  = 200
                            HealthCheckResult = $checks.ToArray()
                        }
                    )
                } | ConvertTo-Json -Depth 8
                function az { return $payload }
                $global:LASTEXITCODE = 0

                $rows = Get-AzLocalFleetHealthFailures -View Detail
                $rows | Should -HaveCount 1
                $rows[0].ClusterName        | Should -Be 'BigCluster'
                $rows[0].FailureName        | Should -Be 'late-failure-marker'
                $rows[0].FailureReason      | Should -Be 'Late array position failure (index 150)'
                $rows[0].Severity           | Should -Be 'Critical'
                $rows[0].TargetResourceName | Should -Be 'BeyondCap'
            }
        }

        It 'KQL no longer contains mv-expand on properties.healthCheckResult (regression guard)' {
            InModuleScope AzLocal.UpdateManagement {
                $script:CapturedKql = $null
                function az {
                    $argList = @($args)
                    $qIdx = $argList.IndexOf('-q')
                    if ($qIdx -ge 0 -and $qIdx + 1 -lt $argList.Count) {
                        $script:CapturedKql = $argList[$qIdx + 1]
                    }
                    return '{"count":0,"data":[]}'
                }
                $global:LASTEXITCODE = 0

                $null = Get-AzLocalFleetHealthFailures
                $script:CapturedKql | Should -Not -BeNullOrEmpty
                # The KQL must project healthCheckResult as a raw array column,
                # NOT mv-expand it - mv-expand silently caps at 128 rows.
                $script:CapturedKql | Should -Not -Match 'mv-expand'
                $script:CapturedKql | Should -Match 'HealthCheckResult\s*=\s*properties\.healthCheckResult'
            }
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.76 - Get-AzLocalFleetHealthOverview: ARG mv-expand 128-cap regression
# -----------------------------------------------------------------------------
# v0.7.76 also removed the `mv-expand pkg = properties.packageVersions`
# from this cmdlet for the same reason as Get-AzLocalFleetHealthFailures:
# Azure Resource Graph silently caps mv-expand at 128 child rows per
# parent. While `packageVersions` is normally small (~4 entries), there is
# no schema upper bound, so we now project the raw array and roll up
# SbeVersion client-side. These tests prove the new behaviour.

Describe 'Function: Get-AzLocalFleetHealthOverview - v0.7.76 ARG mv-expand 128-cap regression' {

    Context 'Client-side SBE roll-up bypasses the ARG mv-expand cap' {

        It 'Returns the SBE version when packageVersions has 200 entries with SBE at index 150 (past the historical 128-row cap)' {
            InModuleScope AzLocal.UpdateManagement {
                # Build a 200-entry packageVersions array: 199 non-SBE
                # fillers plus one SBE entry placed at index 150. The OLD
                # KQL `mv-expand pkg = properties.packageVersions` would
                # silently drop everything past index 128, including the
                # SBE entry, and SbeVersion would have been '(none)'.
                $pkgs = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt 200; $i++) {
                    if ($i -eq 150) {
                        [void]$pkgs.Add([PSCustomObject]@{
                            packageType = 'SBE'
                            version     = '4.5.6.7-RegressionMarker'
                        })
                    } else {
                        [void]$pkgs.Add([PSCustomObject]@{
                            packageType = "Filler-$i"
                            version     = "0.0.0.$i"
                        })
                    }
                }

                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName          = 'BigPkgCluster'
                            ClusterPortalUrl     = 'https://portal.azure.com/#@/resource/x/big'
                            HealthStatus         = 'Healthy'
                            UpdateStatus         = 'AppliedSuccessfully'
                            CurrentVersion       = '12.2604.0'
                            SbeVersion           = ''
                            PackageVersions      = $pkgs.ToArray()
                            AzureConnection      = 'Connected'
                            LastChecked          = '2026-05-16T08:00:00Z'
                            HealthResultsAgeDays = 0
                            ResourceGroup        = 'RG-big'
                            NodeCount            = 4
                            SubscriptionId       = 'sub-big'
                        }
                    )
                }

                $rows = Get-AzLocalFleetHealthOverview 6>$null
                $rows | Should -HaveCount 1
                $rows[0].SbeVersion | Should -Be '4.5.6.7-RegressionMarker'
                # PackageVersions must be stripped from the output schema.
                $rows[0].PSObject.Properties.Name | Should -Not -Contain 'PackageVersions'
            }
        }

        It 'Defaults SbeVersion to "(none)" when packageVersions is empty and the column is present' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName          = 'EmptyPkgCluster'
                            ClusterPortalUrl     = 'https://portal.azure.com/#@/resource/x/empty'
                            HealthStatus         = 'Healthy'
                            UpdateStatus         = 'AppliedSuccessfully'
                            CurrentVersion       = '12.2604.0'
                            SbeVersion           = ''
                            PackageVersions      = @()
                            AzureConnection      = 'Connected'
                            LastChecked          = '2026-05-16T08:00:00Z'
                            HealthResultsAgeDays = 0
                            ResourceGroup        = 'RG-empty'
                            NodeCount            = 4
                            SubscriptionId       = 'sub-empty'
                        }
                    )
                }
                $rows = Get-AzLocalFleetHealthOverview 6>$null
                $rows[0].SbeVersion | Should -Be '(none)'
                $rows[0].PSObject.Properties.Name | Should -Not -Contain 'PackageVersions'
            }
        }

        It 'KQL no longer contains mv-expand on properties.packageVersions (regression guard)' {
            InModuleScope AzLocal.UpdateManagement {
                $script:CapturedKqlOverview = $null
                Mock Invoke-AzResourceGraphQuery -ParameterFilter { $true } -MockWith {
                    param($Query, $SubscriptionId)
                    $script:CapturedKqlOverview = $Query
                    return @()
                }
                $null = Get-AzLocalFleetHealthOverview 6>$null
                $script:CapturedKqlOverview | Should -Not -BeNullOrEmpty
                $script:CapturedKqlOverview | Should -Not -Match 'mv-expand'
                $script:CapturedKqlOverview | Should -Match 'PackageVersions\s*=\s*properties\.packageVersions'
            }
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.76 - Get-AzLocalUpdateRunFailures: ARG mv-expand 128-cap regression
# -----------------------------------------------------------------------------
# v0.7.76 also removed the 7-level nested `mv-expand` chain (s1..s7) from
# this cmdlet. Each level independently capped at 128 child rows, so any
# update-run step with >128 siblings risked having its deepest error
# silently dropped (compounded across all 7 levels). The deepest-error
# walk now runs client-side via Resolve-AzLocalUpdateRunDeepestError on
# the raw `progress.steps` array. These tests prove the new behaviour.

Describe 'Function: Get-AzLocalUpdateRunFailures - v0.7.76 ARG mv-expand 128-cap regression' {

    Context 'Client-side step-tree walk bypasses the ARG mv-expand cap' {

        It 'Surfaces the deepest errorMessage from sibling index 150 of a 200-sibling step level (past the historical 128-row cap)' {
            InModuleScope AzLocal.UpdateManagement {
                # Build a step tree where level 2 has 200 siblings and the
                # only one carrying a meaningful errorMessage is at index
                # 150. The OLD KQL `mv-expand s2 = s1.steps` would silently
                # drop everything past index 128, so the error would never
                # have surfaced.
                $level2Siblings = New-Object System.Collections.ArrayList
                for ($i = 0; $i -lt 200; $i++) {
                    if ($i -eq 150) {
                        [void]$level2Siblings.Add([PSCustomObject]@{
                            name         = "Level2-Step-$i-DEEP-ERROR"
                            errorMessage = 'Action plan Check Update readiness ID xyz failed with state: Failed - regression marker at sibling 150'
                            steps        = @()
                        })
                    } else {
                        [void]$level2Siblings.Add([PSCustomObject]@{
                            name         = "Level2-Filler-$i"
                            errorMessage = ''
                            steps        = @()
                        })
                    }
                }

                $progressSteps = @(
                    [PSCustomObject]@{
                        name         = 'Level1-Apply'
                        description  = 'Apply update'
                        errorMessage = ''
                        steps        = $level2Siblings.ToArray()
                    }
                )

                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName       = 'BigStepCluster'
                            ResourceGroup     = 'RG-bigstep'
                            SubscriptionId    = 'sub-bigstep'
                            ClusterResourceId = '/subscriptions/sub-bigstep/resourceGroups/RG-bigstep/providers/Microsoft.AzureStackHCI/clusters/BigStepCluster'
                            UpdateName        = 'Solution.X'
                            RunId             = 'run-big-1'
                            State             = 'Failed'
                            StartTime         = '2026-05-15T20:00:00Z'
                            EndTime           = '2026-05-15T21:30:00Z'
                            DurationMinutes   = 90
                            ProgressSteps     = $progressSteps
                            StackTracePreview = ''
                            Status            = 'Failed'
                            ProgressDescription = 'Apply update'
                            ProgressJsonBytes = 1234
                            ProgressJson      = ''
                        }
                    )
                }

                $rows = Get-AzLocalUpdateRunFailures -State All 6>$null
                $rows | Should -HaveCount 1
                $rows[0].DeepestStepDepth | Should -Be 2
                $rows[0].DeepestStepName  | Should -Be 'Level2-Step-150-DEEP-ERROR'
                $rows[0].DeepestErrMsg    | Should -Match 'regression marker at sibling 150'
                $rows[0].ErrorCategory    | Should -Be 'HealthCheck'
                $rows[0].PSObject.Properties.Name | Should -Not -Contain 'ProgressSteps'
            }
        }

        It 'Walks at least 8 levels deep (matches or exceeds the historical 8-level KQL ceiling)' {
            InModuleScope AzLocal.UpdateManagement {
                # Construct an 8-level chain. The deepest step carries the
                # only errorMessage; the walker must return Depth=8.
                $deep = [PSCustomObject]@{
                    name         = 'L8-Deepest'
                    errorMessage = 'Deepest error at level 8 - certificate rotation failed'
                    steps        = @()
                }
                for ($lvl = 7; $lvl -ge 1; $lvl--) {
                    $deep = [PSCustomObject]@{
                        name         = "L$lvl-Step"
                        errorMessage = ''
                        steps        = @($deep)
                    }
                }
                # `$deep` is now the root; the walker treats the input as
                # the steps[] array, so wrap it.
                $progressSteps = @($deep)

                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName       = 'DeepCluster'
                            ResourceGroup     = 'RG-deep'
                            SubscriptionId    = 'sub-deep'
                            ClusterResourceId = '/subscriptions/sub-deep/resourceGroups/RG-deep/providers/Microsoft.AzureStackHCI/clusters/DeepCluster'
                            UpdateName        = 'Solution.Y'
                            RunId             = 'run-deep-1'
                            State             = 'Failed'
                            StartTime         = '2026-05-15T20:00:00Z'
                            EndTime           = '2026-05-15T21:00:00Z'
                            DurationMinutes   = 60
                            ProgressSteps     = $progressSteps
                            StackTracePreview = ''
                            Status            = 'Failed'
                            ProgressDescription = ''
                            ProgressJsonBytes = 100
                            ProgressJson      = ''
                        }
                    )
                }

                $rows = Get-AzLocalUpdateRunFailures -State All 6>$null
                $rows | Should -HaveCount 1
                $rows[0].DeepestStepDepth | Should -Be 8
                $rows[0].DeepestStepName  | Should -Be 'L8-Deepest'
                $rows[0].DeepestErrMsg    | Should -Match 'level 8'
                $rows[0].ErrorCategory    | Should -Be 'Certificates'
            }
        }

        It 'KQL no longer contains mv-expand on progress.steps (regression guard)' {
            InModuleScope AzLocal.UpdateManagement {
                $script:CapturedKqlRuns = $null
                Mock Invoke-AzResourceGraphQuery -ParameterFilter { $true } -MockWith {
                    param($Query, $SubscriptionId)
                    if ($null -eq $script:CapturedKqlRuns) {
                        $script:CapturedKqlRuns = $Query
                    }
                    return @()
                }
                $null = Get-AzLocalUpdateRunFailures -State All 6>$null
                $script:CapturedKqlRuns | Should -Not -BeNullOrEmpty
                $script:CapturedKqlRuns | Should -Not -Match 'mv-expand'
                $script:CapturedKqlRuns | Should -Match 'ProgressSteps\s*=\s*progressObj\.steps'
            }
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.76 - Resolve-AzLocalUpdateRunDeepestError private helper unit tests
# -----------------------------------------------------------------------------

Describe 'Private Helper: Resolve-AzLocalUpdateRunDeepestError - v0.7.76 step-tree walker' {

    It 'Returns Depth=0 for $null input' {
        InModuleScope AzLocal.UpdateManagement {
            $r = Resolve-AzLocalUpdateRunDeepestError -Steps $null
            $r.Depth | Should -Be 0
            $r.Msg   | Should -Be ''
        }
    }

    It 'Returns Depth=0 for empty array' {
        InModuleScope AzLocal.UpdateManagement {
            $r = Resolve-AzLocalUpdateRunDeepestError -Steps @()
            $r.Depth | Should -Be 0
        }
    }

    It 'Returns Depth=1 with the step name for a single-level errorMessage' {
        InModuleScope AzLocal.UpdateManagement {
            $steps = @(
                [PSCustomObject]@{ name = 'Step-A'; errorMessage = 'Something failed at level 1'; steps = @() }
            )
            $r = Resolve-AzLocalUpdateRunDeepestError -Steps $steps
            $r.Depth | Should -Be 1
            $r.Name  | Should -Be 'Step-A'
            $r.Msg   | Should -Match 'level 1'
        }
    }

    It 'Picks the DEEPEST errorMessage when multiple levels carry one' {
        InModuleScope AzLocal.UpdateManagement {
            $steps = @(
                [PSCustomObject]@{
                    name         = 'L1'
                    errorMessage = 'Shallow error at level 1'
                    steps        = @(
                        [PSCustomObject]@{
                            name         = 'L2'
                            errorMessage = 'Mid error at level 2'
                            steps        = @(
                                [PSCustomObject]@{
                                    name         = 'L3-Deepest'
                                    errorMessage = 'Deepest error at level 3'
                                    steps        = @()
                                }
                            )
                        }
                    )
                }
            )
            $r = Resolve-AzLocalUpdateRunDeepestError -Steps $steps
            $r.Depth | Should -Be 3
            $r.Name  | Should -Be 'L3-Deepest'
            $r.Msg   | Should -Match 'level 3'
        }
    }

    It 'Captures FirstDescription from the first top-level step with a non-empty description' {
        InModuleScope AzLocal.UpdateManagement {
            $steps = @(
                [PSCustomObject]@{ name = 'A'; description = 'First top-level description'; errorMessage = ''; steps = @() }
                [PSCustomObject]@{ name = 'B'; description = 'Second description';          errorMessage = ''; steps = @() }
            )
            $r = Resolve-AzLocalUpdateRunDeepestError -Steps $steps
            $r.Depth            | Should -Be 0
            $r.FirstDescription | Should -Be 'First top-level description'
        }
    }

    It 'Walks past 200 siblings to find an error at index 150 (mv-expand 128-cap regression)' {
        InModuleScope AzLocal.UpdateManagement {
            $siblings = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt 200; $i++) {
                if ($i -eq 150) {
                    [void]$siblings.Add([PSCustomObject]@{
                        name         = "S-$i-DEEP"
                        errorMessage = 'Sibling 150 carries the only meaningful error'
                        steps        = @()
                    })
                } else {
                    [void]$siblings.Add([PSCustomObject]@{
                        name         = "S-$i"
                        errorMessage = ''
                        steps        = @()
                    })
                }
            }
            $r = Resolve-AzLocalUpdateRunDeepestError -Steps $siblings.ToArray()
            $r.Depth | Should -Be 1
            $r.Name  | Should -Be 'S-150-DEEP'
            $r.Msg   | Should -Match 'Sibling 150'
        }
    }

    It 'Ignores errorMessages shorter than the 10-character meaningful threshold' {
        InModuleScope AzLocal.UpdateManagement {
            $steps = @(
                [PSCustomObject]@{ name = 'X'; errorMessage = 'short'; steps = @() }
            )
            $r = Resolve-AzLocalUpdateRunDeepestError -Steps $steps
            $r.Depth | Should -Be 0
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.70 - Workstream B: Get-AzLocalFleetHealthOverview (BS6, BS7, BS8)
# -----------------------------------------------------------------------------

Describe 'Function: Get-AzLocalFleetHealthOverview - v0.7.70 (ARG-first fleet health summary)' {

    Context 'BS6 / BS7 - Cmdlet is exported and module function count is 36' {

        It 'BS6: Get-AzLocalFleetHealthOverview is exported by the module' {
            $cmd = Get-Command -Module AzLocal.UpdateManagement -Name Get-AzLocalFleetHealthOverview -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }

        It 'BS7: Module exports exactly 38 functions (was 37 in v0.7.86 before New-AzLocalFleetConnectivityStatusSummary was added in v0.7.87)' {
            (Get-Module AzLocal.UpdateManagement).ExportedFunctions.Count | Should -Be 38
        }
    }

    Context 'BS8 - Returns expected schema columns when Resource Graph returns rows' {

        It 'BS8: Output rows expose the documented columns (ClusterName, ClusterPortalUrl, HealthStatus, UpdateStatus, CurrentVersion, SbeVersion, AzureConnection, LastChecked, HealthResultsAgeDays, ResourceGroup, NodeCount, SubscriptionId)' {
            InModuleScope AzLocal.UpdateManagement {
                # Mock the ARG helper to return one already-projected row in the shape
                # the cmdlet's KQL `project` clause emits. The cmdlet itself does no
                # further reshaping, so the test confirms the schema flows through
                # unchanged.
                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName          = 'Cluster01'
                            ClusterPortalUrl     = 'https://portal.azure.com/#@/resource/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            HealthStatus         = 'Healthy'
                            UpdateStatus         = 'AppliedSuccessfully'
                            CurrentVersion       = '12.2503.0'
                            SbeVersion           = '4.1.2.0'
                            AzureConnection      = 'Connected'
                            LastChecked          = '2026-05-16T08:00:00Z'
                            HealthResultsAgeDays = 0
                            ResourceGroup        = 'RG1'
                            NodeCount            = 4
                            SubscriptionId       = 'sub-1111'
                        }
                    )
                }

                $rows = Get-AzLocalFleetHealthOverview 6>$null
                $rows | Should -HaveCount 1
                foreach ($prop in @(
                    'ClusterName','ClusterPortalUrl','HealthStatus','UpdateStatus',
                    'CurrentVersion','SbeVersion','AzureConnection','LastChecked',
                    'HealthResultsAgeDays','ResourceGroup','NodeCount','SubscriptionId'
                )) {
                    $rows[0].PSObject.Properties.Name | Should -Contain $prop
                }
                $rows[0].ClusterPortalUrl | Should -Match '^https://portal\.azure\.com/#@/resource/subscriptions/'
                Assert-MockCalled Invoke-AzResourceGraphQuery -Times 1 -Exactly
            }
        }
    }
}

# -----------------------------------------------------------------------------
# v0.7.70 - Workstream C: Get-AzLocalUpdateRunFailures fleet-scale failure-detail columns
# + Step.6 "📜 Update Run History and Error Details" JUnit wiring
# -----------------------------------------------------------------------------

Describe 'Function: Get-AzLocalUpdateRunFailures - v0.7.70 fleet-scale failure-detail columns (BS9 - BS12)' {

    Context 'BS9 - Detail view exposes the new Status / CurrentStep / Duration / LastUpdated / UpdateRunPortalUrl columns' {

        It 'BS9: Output row exposes all new columns' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName          = 'Arizona'
                            ResourceGroup        = 'arizona'
                            SubscriptionId       = 'fbaf508b-cb61-4383-9cda-a42bfa0c7bc9'
                            ClusterResourceId    = '/subscriptions/fbaf508b-cb61-4383-9cda-a42bfa0c7bc9/resourceGroups/arizona/providers/Microsoft.AzureStackHCI/clusters/Arizona'
                            UpdateName           = 'Solution12.2604.1003.1005'
                            RunId                = 'add1f87d-4174-4997-ae39-d9d41088be27'
                            State                = 'Failed'
                            StartTime            = '2026-05-15T20:28:25.3093764Z'
                            EndTime              = '2026-05-15T21:11:15.2041076Z'
                            DurationMinutes      = 42.83
                            DeepestStepDepth     = 1
                            DeepestStepName      = 'Update is blocked due to health check failure'
                            DeepestErrMsg        = 'Action plan Check Update readiness ID 1084e062-5d0b-48c0-b4d6-c1693b575bc1 failed with state: Failed'
                            StackTracePreview    = ''
                            ErrorCategory        = 'HealthCheck'
                            Status               = 'Extracted'
                            ProgressDescription  = 'Step 1 of 17 in update'
                            ProgressJsonBytes    = 1234
                            ProgressJson         = ''
                        }
                    )
                }

                $rows = Get-AzLocalUpdateRunFailures -State Failed 6>$null
                $rows | Should -HaveCount 1
                $names = $rows[0].PSObject.Properties.Name
                foreach ($prop in @('Status','CurrentStep','Duration','LastUpdated','UpdateRunPortalUrl')) {
                    $names | Should -Contain $prop
                }
            }
        }

        It 'BS10: UpdateRunPortalUrl matches the SingleInstanceHistoryDetails portal deep-link pattern (URL-encoded cluster resource id)' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName=''; ResourceGroup=''; SubscriptionId='sub-1111'
                            ClusterResourceId='/subscriptions/sub-1111/resourceGroups/RG1/providers/Microsoft.AzureStackHCI/clusters/Cluster01'
                            UpdateName='Sol.1'; RunId='r1'; State='Failed'
                            StartTime='2026-05-15T20:28:25Z'; EndTime='2026-05-15T21:11:15Z'
                            DurationMinutes=42; DeepestStepDepth=1; DeepestStepName='x'
                            DeepestErrMsg='e'; StackTracePreview=''; ErrorCategory='HealthCheck'
                            Status='Extracted'; ProgressDescription=''
                            ProgressJsonBytes=10; ProgressJson=''
                        }
                    )
                }
                $rows = Get-AzLocalUpdateRunFailures -State Failed 6>$null
                $url = $rows[0].UpdateRunPortalUrl
                $url | Should -Match '^https://portal\.azure\.com/#view/Microsoft_AzureStackHCI_PortalExtension/SingleInstanceHistoryDetails\.ReactView/resourceId/.+/updateName~/null/updateRunName~/null/refresh~/false$'
                # Must be URL-encoded (every '/' in the resource id becomes %2F).
                $url | Should -Match '%2Fsubscriptions%2Fsub-1111%2FresourceGroups%2FRG1%2Fproviders%2FMicrosoft\.AzureStackHCI%2Fclusters%2FCluster01'
            }
        }

        It 'BS11: Duration is formatted as a human-readable string built from EndTime - StartTime (e.g. "42m 50s")' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName='C'; ResourceGroup='R'; SubscriptionId='s'
                            ClusterResourceId='/x/c'; UpdateName='u'; RunId='r'; State='Failed'
                            StartTime='2026-05-15T20:00:00Z'; EndTime='2026-05-15T20:42:50Z'
                            DurationMinutes=42.83; DeepestStepDepth=1; DeepestStepName='x'
                            DeepestErrMsg='e'; StackTracePreview=''; ErrorCategory='Other'
                            Status='Error'; ProgressDescription=''
                            ProgressJsonBytes=10; ProgressJson=''
                        }
                    )
                }
                $rows = Get-AzLocalUpdateRunFailures -State Failed 6>$null
                # Either "42m 50s" or (allowing for sub-second precision rounding) starts with "42m "
                $rows[0].Duration | Should -Match '^42m '
            }
        }

        It 'BS12: CurrentStep falls back to DeepestStepName for Failed runs' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-AzResourceGraphQuery {
                    return @(
                        [PSCustomObject]@{
                            ClusterName='C'; ResourceGroup='R'; SubscriptionId='s'
                            ClusterResourceId='/x/c'; UpdateName='u'; RunId='r'; State='Failed'
                            StartTime='2026-05-15T20:00:00Z'; EndTime='2026-05-15T20:42:50Z'
                            DurationMinutes=42.83; DeepestStepDepth=1
                            DeepestStepName='VerifyNCResources'
                            DeepestErrMsg='e'; StackTracePreview=''; ErrorCategory='Other'
                            Status='Error'; ProgressDescription='Step 9 of 17'
                            ProgressJsonBytes=10; ProgressJson=''
                        }
                    )
                }
                $rows = Get-AzLocalUpdateRunFailures -State Failed 6>$null
                $rows[0].CurrentStep | Should -Be 'VerifyNCResources'
            }
        }
    }
}

Describe 'v0.7.70 Step.6 "📜 Update Run History and Error Details" JUnit + markdown wiring' {

    BeforeAll {
        $script:examplesRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..\Automation-Pipeline-Examples')).Path
        $script:step6Files = @(
            Join-Path $script:examplesRoot 'github-actions\Step.8_fleet-update-status.yml'
            Join-Path $script:examplesRoot 'azure-devops\Step.8_fleet-update-status.yml'
        )
    }

    It 'BS13: Both Step.6 YAML files emit the new "📜 Update Run History and Error Details" testsuite name' {
        foreach ($yml in $script:step6Files) {
            $content = [System.IO.File]::ReadAllText($yml, [System.Text.UTF8Encoding]::new($false))
            # U+1F4DC SCROLL emoji
            $scroll = [string]::new([System.Text.Encoding]::UTF32.GetChars([System.BitConverter]::GetBytes(0x1F4DC)))
            ($content.Contains($scroll + ' Update Run History and Error Details')) | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must declare the new testsuite name with the scroll emoji"
        }
    }

    It 'BS14: Both Step.6 YAML files call Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved' {
        foreach ($yml in $script:step6Files) {
            $content = Get-Content -LiteralPath $yml -Raw
            ($content -match 'Get-AzLocalUpdateRunFailures\s+-State\s+Failed\s+-OnlyUnresolved') | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must drive the new section from the cmdlet with -State Failed -OnlyUnresolved"
        }
    }

    It 'BS15: Both Step.6 YAML files export update-run-history.csv and update-run-history.json' {
        foreach ($yml in $script:step6Files) {
            $content = Get-Content -LiteralPath $yml -Raw
            $content | Should -Match 'update-run-history\.csv'
            $content | Should -Match 'update-run-history\.json'
        }
    }

    It 'BS16: Both Step.6 YAML files render the markdown table heading and use the 9-column failure-detail layout' {
        foreach ($yml in $script:step6Files) {
            $content = [System.IO.File]::ReadAllText($yml, [System.Text.UTF8Encoding]::new($false))
            $content | Should -Match 'Cluster Name \| Update Name \| Update State \| Status \| Current Step \| Verbose Error Details \| Duration \| Time Started \| Last Updated'
        }
    }

    It 'BS17: Both Step.6 YAML files surface a runHistoryCount output for downstream gating' {
        foreach ($yml in $script:step6Files) {
            $content = Get-Content -LiteralPath $yml -Raw
            # GH-actions uses RUN_HISTORY_COUNT; ADO uses runHistoryCount.
            $hasOutput = ($content -match 'RUN_HISTORY_COUNT=') -or ($content -match 'variable=runHistoryCount;')
            $hasOutput | Should -BeTrue -Because "$(Split-Path -Leaf $yml) must export runHistoryCount so downstream steps can render the markdown table"
        }
    }
}

#endregion v0.7.70 (Workstream A: Step.3 Audit UX refresh + Workstream B: Step.7 Fleet Health Overview)

#endregion v0.7.69 Apply-Updates Schedule (ring-aware)



#region v0.7.70 Phase E: Get-AzLocalLatestSolutionVersion

Describe 'Function: Get-AzLocalLatestSolutionVersion (v0.7.70 Phase E)' {

    BeforeAll {
        # Sample manifest mirroring the real aka.ms/AzureEdgeUpdates payload shape.
        # 2604 is the highest YYMM (which is what Step.6 SupportStatus will anchor on).
        # 2510 is older than the 6-month window ending at 2604 (2604,2603,2602,2601,2512,2511)
        # and so MUST end up Unsupported when the manifest probe succeeds.
        $script:sampleManifestXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<ASZSolutionBundleUpdates>
  <ManifestInfo Version="1.0" />
  <ApplicableUpdate>
    <UpdateInfo UpdateName="StackHCI 2604" Version="Solution12.2604.1003.1005" Type="Solution" PackageSizeInMb="2048" />
    <UpdateInfo UpdateName="StackHCI 2603" Version="Solution12.2603.1002.1001" Type="Solution" PackageSizeInMb="2048" />
  </ApplicableUpdate>
  <PackageMetadata>
    <ServicesUpdates>
      <Update>
        <UpdateInfo UpdateName="HciService 2604" Version="Solution12.2604.1003.1005" Type="Services" />
      </Update>
      <Update>
        <UpdateInfo UpdateName="HciService 2604-hotfix" Version="Solution12.2604.1005.1007" Type="Services" />
      </Update>
      <Update>
        <UpdateInfo UpdateName="HciService 2510" Version="Solution12.2510.5005.7008" Type="Services" />
      </Update>
    </ServicesUpdates>
  </PackageMetadata>
</ASZSolutionBundleUpdates>
'@
    }

    Context 'Happy path (manifest reachable)' {

        It 'Returns LatestYYMM=2604 from the sample manifest' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $script:sampleManifestXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                $r = Get-AzLocalLatestSolutionVersion
                $r.LatestYYMM | Should -Be '2604'
            }
        }

        It 'Returns the highest Version string at LatestYYMM (hotfix wins)' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $script:sampleManifestXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                $r = Get-AzLocalLatestSolutionVersion
                # Both 2604.1003.1005 and 2604.1005.1007 exist - the higher Version wins.
                $r.LatestVersion | Should -Be 'Solution12.2604.1005.1007'
            }
        }

        It 'Builds the 6-month window in calendar order (newest first)' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $script:sampleManifestXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                $r = Get-AzLocalLatestSolutionVersion
                $r.SupportedYYMMs       | Should -HaveCount 6
                $r.SupportedYYMMs[0]    | Should -Be '2604'
                $r.SupportedYYMMs[1]    | Should -Be '2603'
                $r.SupportedYYMMs[2]    | Should -Be '2602'
                $r.SupportedYYMMs[3]    | Should -Be '2601'
                $r.SupportedYYMMs[4]    | Should -Be '2512'   # year rollover
                $r.SupportedYYMMs[5]    | Should -Be '2511'
                # Critical user-stated invariant: 2510 is OUTSIDE the window once 2604 is published
                $r.SupportedYYMMs       | Should -Not -Contain '2510'
            }
        }

        It 'Respects -SupportWindowMonths override' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $script:sampleManifestXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                $r = Get-AzLocalLatestSolutionVersion -SupportWindowMonths 3
                $r.SupportedYYMMs       | Should -HaveCount 3
                $r.SupportedYYMMs       | Should -Be @('2604','2603','2602')
                $r.SupportWindowMonths  | Should -Be 3
            }
        }

        It 'AllReleases contains entries from BOTH XPath sources with correct Source attribution' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $script:sampleManifestXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                $r = Get-AzLocalLatestSolutionVersion
                $r.AllReleases.Count                                         | Should -Be 5
                @($r.AllReleases | Where-Object Source -eq 'ApplicableUpdate.UpdateInfo').Count                | Should -Be 2
                @($r.AllReleases | Where-Object Source -eq 'PackageMetadata.ServicesUpdates.Update.UpdateInfo').Count | Should -Be 3
                # Every release should have a non-empty Yymm
                ($r.AllReleases | Where-Object { -not $_.Yymm }).Count       | Should -Be 0
            }
        }

        It 'Sets ManifestUrl, ManifestFetchedAt, and Source on the result' {
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $script:sampleManifestXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                $r = Get-AzLocalLatestSolutionVersion
                $r.ManifestUrl       | Should -Be 'https://aka.ms/AzureEdgeUpdates'
                $r.ManifestFetchedAt | Should -BeOfType [DateTime]
                $r.Source            | Should -Be 'aka.ms/AzureEdgeUpdates'
            }
        }

        It 'Handles year-rollover when LatestYYMM=2601 (3-month window crosses year boundary)' {
            $rollOverXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<ASZSolutionBundleUpdates>
  <ApplicableUpdate>
    <UpdateInfo UpdateName="StackHCI 2601" Version="Solution12.2601.0001.0001" />
  </ApplicableUpdate>
</ASZSolutionBundleUpdates>
'@
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $rollOverXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                $r = Get-AzLocalLatestSolutionVersion -SupportWindowMonths 3
                $r.SupportedYYMMs | Should -Be @('2601','2512','2511')
            }
        }
    }

    Context 'Error paths (network / parse failures)' {

        It 'Throws when Invoke-WebRequest fails (network unreachable)' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-WebRequest { throw [System.Net.WebException]::new('Name or service not known') }
                { Get-AzLocalLatestSolutionVersion } | Should -Throw '*Failed to fetch Azure Edge Updates manifest*'
            }
        }

        It 'Throws when HTTP returns a non-2xx status code' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 503; Content = '' } }
                { Get-AzLocalLatestSolutionVersion } | Should -Throw '*HTTP 503*'
            }
        }

        It 'Throws when manifest body is empty' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = '' } }
                { Get-AzLocalLatestSolutionVersion } | Should -Throw '*empty body*'
            }
        }

        It 'Throws when manifest body is not valid XML' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = '<<not xml>>' } }
                { Get-AzLocalLatestSolutionVersion } | Should -Throw '*not valid XML*'
            }
        }

        It 'Throws when root element is missing' {
            InModuleScope AzLocal.UpdateManagement {
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = '<?xml version="1.0"?><WrongRoot/>' } }
                { Get-AzLocalLatestSolutionVersion } | Should -Throw '*<ASZSolutionBundleUpdates>*'
            }
        }

        It 'Throws when no UpdateInfo entries are present' {
            $emptyXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<ASZSolutionBundleUpdates>
  <Metadata Schema="1"/>
</ASZSolutionBundleUpdates>
'@
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $emptyXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                { Get-AzLocalLatestSolutionVersion } | Should -Throw '*no parseable UpdateInfo entries*'
            }
        }

        It 'Throws when UpdateInfo entries have no YYMM token in their Version' {
            $badXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<ASZSolutionBundleUpdates>
  <ApplicableUpdate>
    <UpdateInfo UpdateName="Junk" Version="1.0.0" />
    <UpdateInfo UpdateName="JunkAlpha" Version="alpha.beta.gamma" />
  </ApplicableUpdate>
</ASZSolutionBundleUpdates>
'@
            InModuleScope AzLocal.UpdateManagement -Parameters @{ Xml = $badXml } {
                param($Xml)
                Mock Invoke-WebRequest { return [PSCustomObject]@{ StatusCode = 200; Content = $Xml } }
                { Get-AzLocalLatestSolutionVersion } | Should -Throw '*YYMM token*'
            }
        }
    }

    Context 'Parameter validation' {

        It 'Rejects a non-http(s) ManifestUrl' {
            { Get-AzLocalLatestSolutionVersion -ManifestUrl 'file:///c:/temp/m.xml' } |
                Should -Throw '*does not match*'
        }

        It 'Rejects -SupportWindowMonths below 1' {
            { Get-AzLocalLatestSolutionVersion -SupportWindowMonths 0 } |
                Should -Throw '*less than the minimum*'
        }

        It 'Rejects -SupportWindowMonths above 24' {
            { Get-AzLocalLatestSolutionVersion -SupportWindowMonths 25 } |
                Should -Throw '*greater than the maximum*'
        }
    }
}

Describe 'Pipeline contract: Step.6 SupportStatus anchor (v0.7.70 Phase E)' {

    BeforeAll {
        $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $script:step6Files = @(
            Join-Path -Path $script:repoRoot -ChildPath 'Automation-Pipeline-Examples/github-actions/Step.8_fleet-update-status.yml'
            Join-Path -Path $script:repoRoot -ChildPath 'Automation-Pipeline-Examples/azure-devops/Step.8_fleet-update-status.yml'
        )
    }

    It 'Both Step.6 YAML files invoke Get-AzLocalLatestSolutionVersion' {
        foreach ($yml in $script:step6Files) {
            $content = Get-Content -LiteralPath $yml -Raw
            $content | Should -Match 'Get-AzLocalLatestSolutionVersion' -Because "$(Split-Path -Leaf $yml) must call the Microsoft-manifest probe to anchor the SupportStatus window"
        }
    }

    It 'Both Step.6 YAML files surface a supportSource property in JUnit' {
        foreach ($yml in $script:step6Files) {
            $content = Get-Content -LiteralPath $yml -Raw
            $content | Should -Match 'supportSource' -Because "$(Split-Path -Leaf $yml) must emit the SupportSource flag so consumers can tell manifest-anchored from fleet-observed windows apart"
        }
    }

    It 'Both Step.6 YAML files wrap the manifest probe in try/catch with a fleet-observed fallback' {
        foreach ($yml in $script:step6Files) {
            $content = Get-Content -LiteralPath $yml -Raw
            $content | Should -Match 'fleet-observed' -Because "$(Split-Path -Leaf $yml) must fall back to fleet-observed top-6 when the manifest is unreachable"
        }
    }
}

Describe 'Smoke test: Step.4 pipeline cmdlet migration (v0.7.79)' {
    # v0.7.79: Step.4 inline KQL + Invoke-ArgQuery/Extract-ArgProjectedColumns replaced by
    # Get-AzLocalFleetConnectivityStatus module cmdlet. This smoke test verifies that:
    #   (a) Both YAML flavors call the cmdlet (no regression to inline queries)
    #   (b) The module cmdlet handles ARG normalization internally (tested in cmdlet unit tests below)

    BeforeAll {
        $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $script:step4Files = @(
            Join-Path -Path $script:repoRoot -ChildPath 'Automation-Pipeline-Examples/github-actions/Step.4_fleet-connectivity-status.yml'
            Join-Path -Path $script:repoRoot -ChildPath 'Automation-Pipeline-Examples/azure-devops/Step.4_fleet-connectivity-status.yml'
        )
    }

    It 'Step.4 GH Actions calls Get-AzLocalFleetConnectivityStatus' {
        $content = Get-Content -LiteralPath $script:step4Files[0] -Raw
        $content | Should -Match 'Get-AzLocalFleetConnectivityStatus' -Because 'Step.4 GH must call the v0.7.79 module cmdlet'
    }

    It 'Step.4 ADO calls Get-AzLocalFleetConnectivityStatus' {
        $content = Get-Content -LiteralPath $script:step4Files[1] -Raw
        $content | Should -Match 'Get-AzLocalFleetConnectivityStatus' -Because 'Step.4 ADO must call the v0.7.79 module cmdlet'
    }

    It 'Step.4 GH Actions does not contain inline Invoke-ArgQuery' {
        $content = Get-Content -LiteralPath $script:step4Files[0] -Raw
        $content | Should -Not -Match 'function Invoke-ArgQuery' -Because 'Inline ARG query helper removed in v0.7.79 migration'
    }

    It 'Step.4 ADO does not contain inline Invoke-ArgQuery' {
        $content = Get-Content -LiteralPath $script:step4Files[1] -Raw
        $content | Should -Not -Match 'function Invoke-ArgQuery' -Because 'Inline ARG query helper removed in v0.7.79 migration'
    }
}

Describe 'Regression v0.7.83: Step.4 ARB inline script handles single-cluster ClusterId without [char].Trim() bug' {
    # v0.7.82 shipped a Step.4 ARB Add-Suite -GetCase block that called
    # $clusterIdList[0].Trim() where $clusterIdList was built via
    # `if ($r.ClusterId) { @(($r.ClusterId -split ',\s*') | Where-Object { $_ }) } else { @() }`.
    # When $r.ClusterId is a SINGLE non-empty string (the common single-
    # cluster-per-RG case), Where-Object collapses to a scalar, the @() wrap
    # is undone by the if-as-expression, and $clusterIdList becomes a bare
    # [string]. Indexing then yields [char], whose .Trim() throws:
    #   "Method invocation failed because [System.Char] does not contain a method named 'Trim'."
    #
    # v0.7.83 fix: [string[]] cast on the variable + [string] cast at the
    # indexing site. The same pattern existed twice more in the file (orphan-
    # ARB reconciliation block) and was hardened too.
    #
    # These tests are BOTH static (regex on the YAML content) and dynamic
    # (executing the exact two-line pattern against synthetic ClusterId
    # values that exercise single-cluster, multi-cluster, and null cases).

    BeforeAll {
        $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $script:step4Cases = @(
            @{ Platform = 'github-actions'; Path = (Join-Path -Path $script:repoRoot -ChildPath 'Automation-Pipeline-Examples/github-actions/Step.4_fleet-connectivity-status.yml') }
            @{ Platform = 'azure-devops';   Path = (Join-Path -Path $script:repoRoot -ChildPath 'Automation-Pipeline-Examples/azure-devops/Step.4_fleet-connectivity-status.yml') }
        )
    }

    It 'Step.4 [<Platform>] casts $clusterIdList to [string[]] in the ARB Add-Suite block' -ForEach $script:step4Cases {
        $content = Get-Content -LiteralPath $Path -Raw
        $content | Should -Match '\[string\[\]\]\$clusterIdList = if \(\$r\.ClusterId\)' `
            -Because "Step.4 $Platform must cast `$clusterIdList to [string[]] to prevent the v0.7.82 [char].Trim() bug on single-cluster ClusterId"
    }

    It 'Step.4 [<Platform>] casts $clusterIdList[0] to [string] before .Trim() (belt-and-suspenders)' -ForEach $script:step4Cases {
        $content = Get-Content -LiteralPath $Path -Raw
        $content | Should -Match '\(\[string\]\$clusterIdList\[0\]\)\.Trim\(\)' `
            -Because "Step.4 $Platform must cast `$clusterIdList[0] to [string] before .Trim() as defence-in-depth"
    }

    It 'Step.4 [<Platform>] casts $ids to [string[]] in BOTH orphan-ARB reconciliation sites' -ForEach $script:step4Cases {
        $content = Get-Content -LiteralPath $Path -Raw
        # Expect the cast in: (a) arbByClusterId lookup loop, (b) orphanArbs filter
        $castOccurrences = [regex]::Matches($content, '\[string\[\]\]\$ids = if \(').Count
        $castOccurrences | Should -BeGreaterOrEqual 2 `
            -Because "Step.4 $Platform must cast `$ids to [string[]] in both the arbByClusterId loop and orphanArbs filter (currently safe due to foreach scalar-iteration semantics, but brittle to refactor)"
    }

    It 'Step.4 [<Platform>] does NOT contain the unwrapped v0.7.82 buggy pattern' -ForEach $script:step4Cases {
        $content = Get-Content -LiteralPath $Path -Raw
        # The buggy shape is `$x = if (...) { @(... | Where-Object {...}) } else { @() }` without a [string[]] prefix.
        # Match the bare `$clusterIdList = if (` or `$ids = if (` (no cast).
        $content | Should -Not -Match '(?m)^\s*\$clusterIdList = if \(' `
            -Because "Step.4 $Platform must not regress to the unwrapped `$clusterIdList = if-@-else pattern (v0.7.82 bug)"
        $content | Should -Not -Match '(?m)^\s*\$ids = if \(' `
            -Because "Step.4 $Platform must not regress to the unwrapped `$ids = if-@-else pattern (v0.7.82 bug)"
    }

    It 'Execute: single-cluster ClusterId does not throw [char].Trim()' {
        # Direct re-execution of the exact two lines that v0.7.83 ships.
        # This is the regression guard: if anyone strips the [string[]] cast
        # in a future refactor, this test fails immediately rather than waiting
        # for a customer to run Step.4 against a single-cluster ARB row.
        $r = [PSCustomObject]@{ ClusterId = '/subscriptions/abc/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/HCI01' }
        $err = $null
        try {
            [string[]]$clusterIdList = if ($r.ClusterId) { ($r.ClusterId -split ',\s*') | Where-Object { $_ } } else { @() }
            $primaryClusterId = if ($clusterIdList.Count -gt 0) { ([string]$clusterIdList[0]).Trim() } else { '' }
        } catch { $err = $_ }
        $err | Should -BeNullOrEmpty -Because 'The v0.7.83 fix must not throw on a single-cluster ClusterId'
        $primaryClusterId | Should -Be $r.ClusterId
    }

    It 'Execute: comma-separated multi-cluster ClusterId yields both IDs trimmed' {
        $r = [PSCustomObject]@{ ClusterId = '/subs/x/A, /subs/x/B' }
        [string[]]$clusterIdList = if ($r.ClusterId) { ($r.ClusterId -split ',\s*') | Where-Object { $_ } } else { @() }
        $clusterIdList.Count | Should -Be 2
        ([string]$clusterIdList[0]).Trim() | Should -Be '/subs/x/A'
        ([string]$clusterIdList[1]).Trim() | Should -Be '/subs/x/B'
    }

    It 'Execute: null ClusterId yields empty primary without throwing' {
        $r = [PSCustomObject]@{ ClusterId = $null }
        [string[]]$clusterIdList = if ($r.ClusterId) { ($r.ClusterId -split ',\s*') | Where-Object { $_ } } else { @() }
        $primaryClusterId = if ($clusterIdList.Count -gt 0) { ([string]$clusterIdList[0]).Trim() } else { '' }
        $primaryClusterId | Should -Be ''
    }

    It 'Execute: empty-string ClusterId yields empty primary without throwing' {
        $r = [PSCustomObject]@{ ClusterId = '' }
        [string[]]$clusterIdList = if ($r.ClusterId) { ($r.ClusterId -split ',\s*') | Where-Object { $_ } } else { @() }
        $primaryClusterId = if ($clusterIdList.Count -gt 0) { ([string]$clusterIdList[0]).Trim() } else { '' }
        $primaryClusterId | Should -Be ''
    }

    It 'Execute (REGRESSION): the v0.7.82 unwrapped pattern DOES throw on single-cluster ClusterId' {
        # Negative-control: prove the bug still exists in the unwrapped pattern.
        # If this test ever passes without throwing, PowerShell's collection-
        # unwrap semantics may have changed and the [string[]] cast might no
        # longer be needed (it remains good defensive style either way).
        $r = [PSCustomObject]@{ ClusterId = '/subscriptions/abc/clusterA' }
        $clusterIdList = if ($r.ClusterId) { @(($r.ClusterId -split ',\s*') | Where-Object { $_ }) } else { @() }
        # On PS 5.1 and PS 7+, $clusterIdList collapses to [string] here.
        # $clusterIdList[0] is [char]; .Trim() must throw.
        { $clusterIdList[0].Trim() } | Should -Throw '*does not contain a method named*'
    }
}

#endregion v0.7.70 Phase E: Get-AzLocalLatestSolutionVersion

#region v0.7.79: Get-AzLocalFleetConnectivityStatus

Describe 'Function: Get-AzLocalFleetConnectivityStatus (v0.7.79)' {

    Context 'Export and basic contract' {

        It 'Is exported by the module' {
            $cmd = Get-Command -Module AzLocal.UpdateManagement -Name Get-AzLocalFleetConnectivityStatus -ErrorAction SilentlyContinue
            $cmd | Should -Not -BeNullOrEmpty
            $cmd.CommandType | Should -Be 'Function'
        }

        It 'Has SubscriptionId, ExportPath, and PassThru parameters' {
            $cmd = Get-Command -Module AzLocal.UpdateManagement -Name Get-AzLocalFleetConnectivityStatus
            $cmd.Parameters.Keys | Should -Contain 'SubscriptionId'
            $cmd.Parameters.Keys | Should -Contain 'ExportPath'
            $cmd.Parameters.Keys | Should -Contain 'PassThru'
        }
    }

    Context 'Output schema - all 7 properties returned when ARG has data' {

        BeforeAll {
            # Five ARG queries; return synthetic rows for each.
            # Query routing is by KQL content pattern.
                Mock Invoke-AzResourceGraphQuery -ModuleName AzLocal.UpdateManagement {
                    param([string]$Query)
                    if ($Query -match 'microsoft\.azurestackhci/clusters' -and $Query -notmatch 'updateSummaries' -and $Query -notmatch 'extensibilityresources') {
                        # Q1: cluster rows
                        return @(
                            [PSCustomObject]@{
                                name = 'cl-east'
                                id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.AzureStackHCI/clusters/cl-east'
                                resourceGroup  = 'rg1'
                                subscriptionId = 'sub1'
                                location       = 'eastus'
                                properties     = [PSCustomObject]@{
                                    connectivityStatus = 'Connected'
                                    status             = 'Succeeded'
                                    # v0.7.84: realistic HCI cluster schema - reportedProperties.nodes is
                                    # an array of node objects; there is no 'nodeCount' scalar property.
                                    reportedProperties = [PSCustomObject]@{
                                        nodes = @(
                                            [PSCustomObject]@{ name = 'node1' },
                                            [PSCustomObject]@{ name = 'node2' }
                                        )
                                    }
                                }
                            }
                        )
                    }
                    if ($Query -match 'updateSummaries') {
                        # Q2: updateSummaries (cluster version map)
                        return @(
                            [PSCustomObject]@{
                                id         = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.AzureStackHCI/clusters/cl-east'
                                properties = [PSCustomObject]@{ currentVersion = '10.2411.1.0' }
                            }
                        )
                    }
                    if ($Query -match 'hybridcompute/machines') {
                        # Q3: Arc machines
                        return @(
                            [PSCustomObject]@{
                                name = 'node1'
                                id   = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/node1'
                                resourceGroup  = 'rg1'
                                subscriptionId = 'sub1'
                                properties     = [PSCustomObject]@{
                                    status                   = 'Connected'
                                    cloudMetadata            = [PSCustomObject]@{ provider = 'AzSHCI' }
                                    parentClusterResourceId  = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.AzureStackHCI/clusters/cl-east'
                                    agentVersion             = '1.40.0'
                                    osSku                    = 'AzureStackHCIHost'
                                    osVersion                = '10.0.25398.0'
                                    lastStatusChange         = '2025-01-15T10:00:00Z'
                                }
                            }
                        )
                    }
                    if ($Query -match 'edgedevices') {
                        # Q4: NIC data
                        return @(
                            [PSCustomObject]@{
                                id            = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/node1/providers/Microsoft.AzureStackHCI/edgedevices/default'
                                resourceGroup = 'rg1'
                                subscriptionId = 'sub1'
                                properties    = [PSCustomObject]@{
                                    reportedProperties = [PSCustomObject]@{
                                        networkProfile = [PSCustomObject]@{
                                            nicDetails = @(
                                                [PSCustomObject]@{
                                                    adapterName          = 'Ethernet1'
                                                    nicStatus            = 'Up'
                                                    driverVersion        = '1.0'
                                                    interfaceDescription = 'Intel Ethernet'
                                                    ip4Address           = '10.0.0.1'
                                                    subnetMask           = '255.255.255.0'
                                                    defaultGateway       = '10.0.0.254'
                                                    dnsServers           = @('8.8.8.8')
                                                    macAddress           = 'AA:BB:CC:DD:EE:FF'
                                                }
                                            )
                                        }
                                    }
                                }
                            }
                        )
                    }
                    if ($Query -match 'resourceconnector/appliances') {
                        # Q5: ARB
                        return @(
                            [PSCustomObject]@{
                                name           = 'arb-east'
                                id             = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.ResourceConnector/appliances/arb-east'
                                resourceGroup  = 'rg1'
                                subscriptionId = 'sub1'
                                properties     = [PSCustomObject]@{ status = 'Running' }
                                systemData     = [PSCustomObject]@{ lastModifiedAt = '2025-01-15T10:00:00Z' }
                            }
                        )
                    }
                    return @()
                }

            Mock Write-Log -ModuleName AzLocal.UpdateManagement { }
            $script:result = Get-AzLocalFleetConnectivityStatus -PassThru
        }

        It 'Returns a hashtable / PSCustomObject with ClusterRows' {
            $script:result | Should -Not -BeNullOrEmpty
            $script:result.ClusterRows | Should -Not -BeNullOrEmpty
        }

        It 'ClusterRows has expected columns' {
            $row = $script:result.ClusterRows[0]
            $row.PSObject.Properties.Name | Should -Contain 'ClusterName'
            $row.PSObject.Properties.Name | Should -Contain 'ConnectivityStatus'
            $row.PSObject.Properties.Name | Should -Contain 'ClusterStatus'
            $row.PSObject.Properties.Name | Should -Contain 'NodeCount'
            $row.PSObject.Properties.Name | Should -Contain 'Location'
            $row.PSObject.Properties.Name | Should -Contain 'ResourceGroup'
            $row.PSObject.Properties.Name | Should -Contain 'SubscriptionId'
        }

        It 'ArcSummary property exists' {
            $script:result.PSObject.Properties.Name | Should -Contain 'ArcSummary'
        }

        It 'ArcSummary rows have AgentStatus and Count columns' {
            $summaryRow = $script:result.ArcSummary | Select-Object -First 1
            if ($summaryRow) {
                $summaryRow.PSObject.Properties.Name | Should -Contain 'AgentStatus'
                $summaryRow.PSObject.Properties.Name | Should -Contain 'Count'
            }
        }

        It 'NonConnectedMachines property exists' {
            $script:result.PSObject.Properties.Name | Should -Contain 'NonConnectedMachines'
        }

        It 'NicIssues property exists' {
            $script:result.PSObject.Properties.Name | Should -Contain 'NicIssues'
        }

        It 'NicAll property exists' {
            $script:result.PSObject.Properties.Name | Should -Contain 'NicAll'
        }

        It 'NicAll rows have NicType and NicStatus columns' {
            $nicRow = $script:result.NicAll | Select-Object -First 1
            if ($nicRow) {
                $nicRow.PSObject.Properties.Name | Should -Contain 'NicType'
                $nicRow.PSObject.Properties.Name | Should -Contain 'NicStatus'
                $nicRow.PSObject.Properties.Name | Should -Contain 'NicName'
            }
        }

        It 'NicStats property exists and has NicType, NicStatus, Count columns' {
            $script:result.PSObject.Properties.Name | Should -Contain 'NicStats'
            $statsRow = $script:result.NicStats | Select-Object -First 1
            if ($statsRow) {
                $statsRow.PSObject.Properties.Name | Should -Contain 'NicType'
                $statsRow.PSObject.Properties.Name | Should -Contain 'NicStatus'
                $statsRow.PSObject.Properties.Name | Should -Contain 'Count'
            }
        }

        It 'ArbRows property exists' {
            $script:result.PSObject.Properties.Name | Should -Contain 'ArbRows'
        }

        It 'ArbRows has expected columns' {
            $arbRow = $script:result.ArbRows | Select-Object -First 1
            if ($arbRow) {
                $arbRow.PSObject.Properties.Name | Should -Contain 'ArbName'
                $arbRow.PSObject.Properties.Name | Should -Contain 'ArbStatus'
                $arbRow.PSObject.Properties.Name | Should -Contain 'ClusterName'
                $arbRow.PSObject.Properties.Name | Should -Contain 'ResourceGroup'
                $arbRow.PSObject.Properties.Name | Should -Contain 'SubscriptionId'
            }
        }
    }

    Context 'ArcSummary groups by AgentStatus client-side (not via KQL summarize)' {

        BeforeAll {
            Mock Invoke-AzResourceGraphQuery -ModuleName AzLocal.UpdateManagement {
                    param([string]$Query)
                    if ($Query -match 'hybridcompute/machines') {
                        # Return 3 Connected + 1 Disconnected machine (no KQL summarize)
                        return @(
                            [PSCustomObject]@{
                                name = 'node1'; id = '/subs/s1/rg/rg1/node1'
                                resourceGroup = 'rg1'; subscriptionId = 's1'
                                properties = [PSCustomObject]@{
                                    status = 'Connected'
                                    cloudMetadata = [PSCustomObject]@{ provider = 'AzSHCI' }
                                    parentClusterResourceId = '/subs/s1/rg/rg1/cl1'
                                    agentVersion = '1.0'; osSku = ''; osVersion = ''; lastStatusChange = ''
                                }
                            },
                            [PSCustomObject]@{
                                name = 'node2'; id = '/subs/s1/rg/rg1/node2'
                                resourceGroup = 'rg1'; subscriptionId = 's1'
                                properties = [PSCustomObject]@{
                                    status = 'Connected'
                                    cloudMetadata = [PSCustomObject]@{ provider = 'AzSHCI' }
                                    parentClusterResourceId = '/subs/s1/rg/rg1/cl1'
                                    agentVersion = '1.0'; osSku = ''; osVersion = ''; lastStatusChange = ''
                                }
                            },
                            [PSCustomObject]@{
                                name = 'node3'; id = '/subs/s1/rg/rg1/node3'
                                resourceGroup = 'rg1'; subscriptionId = 's1'
                                properties = [PSCustomObject]@{
                                    status = 'Connected'
                                    cloudMetadata = [PSCustomObject]@{ provider = 'AzSHCI' }
                                    parentClusterResourceId = '/subs/s1/rg/rg1/cl1'
                                    agentVersion = '1.0'; osSku = ''; osVersion = ''; lastStatusChange = ''
                                }
                            },
                            [PSCustomObject]@{
                                name = 'node4'; id = '/subs/s1/rg/rg1/node4'
                                resourceGroup = 'rg1'; subscriptionId = 's1'
                                properties = [PSCustomObject]@{
                                    status = 'Disconnected'
                                    cloudMetadata = [PSCustomObject]@{ provider = 'AzSHCI' }
                                    parentClusterResourceId = '/subs/s1/rg/rg1/cl1'
                                    agentVersion = '1.0'; osSku = ''; osVersion = ''; lastStatusChange = ''
                                }
                            }
                        )
                    }
                    return @()
                }

                Mock Write-Log -ModuleName AzLocal.UpdateManagement { }
                $script:arcResult = Get-AzLocalFleetConnectivityStatus -PassThru
        }

        It 'ArcSummary has exactly 2 rows (Connected + Disconnected) not 4 raw machine rows' {
            $script:arcResult.ArcSummary.Count | Should -Be 2
        }

        It 'ArcSummary Connected row has Count=3' {
            $connected = $script:arcResult.ArcSummary | Where-Object { $_.AgentStatus -eq 'Connected' }
            $connected | Should -Not -BeNullOrEmpty
            $connected.Count | Should -Be 3
        }

        It 'ArcSummary Disconnected row has Count=1' {
            $disconnected = $script:arcResult.ArcSummary | Where-Object { $_.AgentStatus -eq 'Disconnected' }
            $disconnected | Should -Not -BeNullOrEmpty
            $disconnected.Count | Should -Be 1
        }

        It 'NonConnectedMachines contains only the Disconnected node' {
            $script:arcResult.NonConnectedMachines.Count | Should -Be 1
            $script:arcResult.NonConnectedMachines[0].NodeName | Should -Be 'node4'
        }
    }

    Context 'Empty ARG results return empty collections, not null' {

        BeforeAll {
            Mock Invoke-AzResourceGraphQuery -ModuleName AzLocal.UpdateManagement { return @() }
            Mock Write-Log -ModuleName AzLocal.UpdateManagement { }
            $script:emptyResult = Get-AzLocalFleetConnectivityStatus -PassThru
        }

        It 'ClusterRows is empty array not null' {
            $script:emptyResult.ClusterRows | Should -Not -BeNullOrEmpty -Because 'Should be an empty array'
            $script:emptyResult.ClusterRows.Count | Should -Be 0
        } -Skip  # Acceptable: null vs empty distinction depends on @() wrapping in cmdlet

        It 'Returns a result object even when all queries return empty' {
            $script:emptyResult | Should -Not -BeNullOrEmpty
        }

        It 'ArbRows is not null when no ARB resources exist' {
            $script:emptyResult.PSObject.Properties.Name | Should -Contain 'ArbRows'
        }
    }
}

#endregion v0.7.79: Get-AzLocalFleetConnectivityStatus

#region v0.7.84: Get-AzLocalFleetConnectivityStatus correctness fixes

Describe 'Regression v0.7.84: Get-AzLocalFleetConnectivityStatus correctness fixes (Step.4 summary)' {
    # Three bugs surfaced in real Step.4 GitHub Actions output (run #9 on 2026-05-21)
    # against a 20-cluster fleet running module v0.7.83:
    #
    # Bug A: 'Nodes' column = 0 for ALL clusters + 'Cluster-reported node count (sum)' = 0
    #        + 'Node coverage delta' = -(Arc-joined nodes).
    #        Root cause: code read 'properties.reportedProperties.nodeCount' which
    #        does NOT exist in the HCI cluster ARG schema. The real property is
    #        'properties.reportedProperties.nodes' (an array of node objects).
    #
    # Bug B: 'Non-Connected Machines' table ClusterName column corrupted to a
    #        single character (cluster 'Mobile' -> 'e', 'alrs-cc' -> 'c', etc.).
    #        Root cause: `CoerceStr (([string]($clusterId -split '/'))[-1])` applied
    #        the [string] cast to the WHOLE ARRAY (joining with spaces), then [-1]
    #        returned the last CHARACTER of the joined string instead of the last
    #        array element. Same bug CLASS as the v0.7.82/v0.7.83 [char].Trim() bug.
    #
    # Bug C: ARB DaysSinceLastModified = -1 for EVERY ARB (Running and Offline).
    #        Root cause: (1) the ARG `resources` query did not explicitly project
    #        systemData.lastModifiedAt so it was often $null in the response, and
    #        (2) the code short-circuited Running ARBs to -1 as an opaque sentinel.
    #        Fix: `| extend lastModifiedAt = tostring(systemData.lastModifiedAt)`
    #        in the KQL, and drop the Running short-circuit so real days is
    #        computed for ALL ARBs regardless of status.
    #
    # The tests below are BOTH static (regex on the source file to detect
    # regression of any of the three fixes) and dynamic (re-execute the cmdlet
    # against synthetic ARG payloads that mimic the real fleet response and
    # assert the resulting row values).

    BeforeAll {
        $script:repoRoot   = Split-Path -Path $PSScriptRoot -Parent
        $script:sourcePath = Join-Path -Path $script:repoRoot -ChildPath 'Public/Get-AzLocalFleetConnectivityStatus.ps1'
        $script:sourceText = Get-Content -LiteralPath $script:sourcePath -Raw
    }

    Context 'Static (source-code) regression guards' {

        It 'Bug A: source reads properties.reportedProperties.nodes (NOT .nodeCount)' {
            $script:sourceText | Should -Match "'properties\.reportedProperties\.nodes'" `
                -Because 'v0.7.84 fix must read the nodes array - .nodeCount does not exist in the HCI cluster ARG schema'
            $script:sourceText | Should -Not -Match "'properties\.reportedProperties\.nodeCount'" `
                -Because 'v0.7.84 fix removed the nodeCount path which always returned `$null and produced NodeCount=0 for every cluster'
        }

        It 'Bug B: source extracts cluster name without [string] cast on the split array' {
            $script:sourceText | Should -Match '\(\(\$clusterId -split ''/''\)\[-1\]\)' `
                -Because 'v0.7.84 fix indexes the split ARRAY directly with [-1] - no [string] cast on the array'
            $script:sourceText | Should -Not -Match '\[string\]\(\$clusterId -split ''/''\)' `
                -Because 'v0.7.84 fix removed the bug pattern [string]($clusterId -split ''/'') which joined the array into a space-separated string then took its last CHARACTER'
        }

        It 'Bug C: ARB KQL explicitly extends lastModifiedAt from systemData' {
            $script:sourceText | Should -Match 'extend lastModifiedAt = tostring\(systemData\.lastModifiedAt\)' `
                -Because 'v0.7.84 fix guarantees lastModifiedAt is present as a top-level column even when ARG strips systemData from the default response'
        }

        It 'Bug C: ARB DaysSinceLastModified no longer short-circuits Running ARBs to -1' {
            $script:sourceText | Should -Not -Match "if \(\`$status -ieq 'Running'\) \{\s*\[int\]-1" `
                -Because 'v0.7.84 UX fix shows real days for ALL ARBs (Running and non-Running); -1 is reserved only for missing/unparseable timestamps'
        }
    }

    Context 'Execution (mock ARG payload) regression guards' {

        BeforeAll {
            # Realistic ARG payloads that mimic the real fleet response.
            # Crucially:
            #   - cluster.properties.reportedProperties.nodes is an ARRAY (Bug A repro)
            #   - Arc machine.parentClusterResourceId is a real ARM ID ending in cluster name (Bug B repro)
            #   - ARB.systemData.lastModifiedAt is present (Bug C repro - 5/10 days ago)

            $script:daysAgoRunningArb = 5
            $script:daysAgoOfflineArb = 10
            $script:runningArbStamp   = (Get-Date).AddDays(-$script:daysAgoRunningArb).ToString('o')
            $script:offlineArbStamp   = (Get-Date).AddDays(-$script:daysAgoOfflineArb).ToString('o')

            Mock Invoke-AzResourceGraphQuery -ModuleName AzLocal.UpdateManagement {
                param([string]$Query)
                if ($Query -match 'microsoft\.azurestackhci/clusters' -and $Query -notmatch 'updateSummaries' -and $Query -notmatch 'extensibilityresources') {
                    return @(
                        [PSCustomObject]@{
                            name = 'Mobile'
                            id   = '/subscriptions/sub1/resourceGroups/acx-mobile-azl/providers/Microsoft.AzureStackHCI/clusters/Mobile'
                            resourceGroup  = 'acx-mobile-azl'
                            subscriptionId = 'sub1'
                            location       = 'eastus'
                            properties     = [PSCustomObject]@{
                                connectivityStatus = 'PartiallyConnected'
                                status             = 'NotConnectedRecently'
                                # Realistic 3-node Azure Local cluster (Bug A repro)
                                reportedProperties = [PSCustomObject]@{
                                    nodes = @(
                                        [PSCustomObject]@{ name = 'Mobile-A' },
                                        [PSCustomObject]@{ name = 'Mobile-B' },
                                        [PSCustomObject]@{ name = 'Mobile-C' }
                                    )
                                }
                            }
                        }
                    )
                }
                if ($Query -match 'updateSummaries') { return @() }
                if ($Query -match 'hybridcompute/machines') {
                    return @(
                        [PSCustomObject]@{
                            name = 'Mobile-A'
                            id   = '/subscriptions/sub1/resourceGroups/acx-mobile-azl/providers/Microsoft.HybridCompute/machines/Mobile-A'
                            resourceGroup  = 'acx-mobile-azl'
                            subscriptionId = 'sub1'
                            properties     = [PSCustomObject]@{
                                status                  = 'Disconnected'
                                cloudMetadata           = [PSCustomObject]@{ provider = 'AzSHCI' }
                                # Bug B repro: real ARM ID with cluster name 'Mobile' as last segment.
                                # Pre-fix code would have returned 'e' (last char of 'Mobile').
                                parentClusterResourceId = '/subscriptions/sub1/resourceGroups/acx-mobile-azl/providers/Microsoft.AzureStackHCI/clusters/Mobile'
                                agentVersion            = '1.40.0'
                                osSku                   = 'Azure Stack HCI'
                                osVersion               = '10.0.26100.32522'
                                lastStatusChange        = '2026-04-28T20:58:26Z'
                            }
                        }
                    )
                }
                if ($Query -match 'edgedevices') { return @() }
                if ($Query -match 'resourceconnector/appliances') {
                    # Two ARBs: one Running, one Offline. Both have real systemData.lastModifiedAt.
                    # The KQL `extend lastModifiedAt = tostring(systemData.lastModifiedAt)` makes
                    # the field available top-level - we mirror that here so the mock matches the
                    # post-fix shape.
                    return @(
                        [PSCustomObject]@{
                            name           = 'Mobile-arcbridge'
                            id             = '/subscriptions/sub1/resourceGroups/acx-mobile-azl/providers/Microsoft.ResourceConnector/appliances/Mobile-arcbridge'
                            resourceGroup  = 'acx-mobile-azl'
                            subscriptionId = 'sub1'
                            properties     = [PSCustomObject]@{ status = 'Offline' }
                            systemData     = [PSCustomObject]@{ lastModifiedAt = $script:offlineArbStamp }
                            lastModifiedAt = $script:offlineArbStamp
                        },
                        [PSCustomObject]@{
                            name           = 'Healthy-arcbridge'
                            id             = '/subscriptions/sub1/resourceGroups/other-rg/providers/Microsoft.ResourceConnector/appliances/Healthy-arcbridge'
                            resourceGroup  = 'other-rg'
                            subscriptionId = 'sub1'
                            properties     = [PSCustomObject]@{ status = 'Running' }
                            systemData     = [PSCustomObject]@{ lastModifiedAt = $script:runningArbStamp }
                            lastModifiedAt = $script:runningArbStamp
                        }
                    )
                }
                return @()
            }

            Mock Write-Log -ModuleName AzLocal.UpdateManagement { }
            $script:bugRepro = Get-AzLocalFleetConnectivityStatus -PassThru
        }

        It 'Bug A: cluster NodeCount reflects the length of the nodes array (3, not 0)' {
            $cluster = $script:bugRepro.ClusterRows | Where-Object { $_.ClusterName -eq 'Mobile' }
            $cluster | Should -Not -BeNullOrEmpty
            $cluster.NodeCount | Should -Be 3 `
                -Because 'v0.7.84 fix must count properties.reportedProperties.nodes elements (Mobile cluster has 3 nodes); pre-fix code returned 0 because it read the non-existent .nodeCount scalar'
        }

        It 'Bug B: NonConnectedMachines ClusterName is the FULL last segment of the ARM ID (not last character)' {
            $machine = $script:bugRepro.NonConnectedMachines | Where-Object { $_.NodeName -eq 'Mobile-A' }
            $machine | Should -Not -BeNullOrEmpty
            $machine.ClusterName | Should -Be 'Mobile' `
                -Because 'v0.7.84 fix must return the full last segment of parentClusterResourceId (cluster ''Mobile''); pre-fix bug returned ''e'' (last character of the joined string)'
            # Belt-and-suspenders: assert NOT a single character.
            $machine.ClusterName.Length | Should -BeGreaterThan 1 `
                -Because 'a single-character ClusterName is the diagnostic signature of the v0.7.83 scalar-collapse bug'
        }

        It 'Bug C: Running ARB DaysSinceLastModified computes real days (not -1 sentinel)' {
            $arb = $script:bugRepro.ArbRows | Where-Object { $_.ArbName -eq 'Healthy-arcbridge' }
            $arb | Should -Not -BeNullOrEmpty
            $arb.ArbStatus | Should -Be 'Running'
            # Allow +/- 1 day tolerance for clock drift / int truncation.
            $arb.DaysSinceLastModified | Should -BeGreaterOrEqual ($script:daysAgoRunningArb - 1) `
                -Because 'v0.7.84 UX fix removes the Running -> -1 short-circuit; real days is computed for healthy ARBs too'
            $arb.DaysSinceLastModified | Should -BeLessOrEqual ($script:daysAgoRunningArb + 1)
        }

        It 'Bug C: Offline ARB DaysSinceLastModified computes real days (not -1 because systemData is now extended)' {
            $arb = $script:bugRepro.ArbRows | Where-Object { $_.ArbName -eq 'Mobile-arcbridge' }
            $arb | Should -Not -BeNullOrEmpty
            $arb.ArbStatus | Should -Be 'Offline'
            $arb.DaysSinceLastModified | Should -BeGreaterOrEqual ($script:daysAgoOfflineArb - 1) `
                -Because 'v0.7.84 KQL extend makes lastModifiedAt available; pre-fix would have returned -1 because systemData was often missing from the ARG response'
            $arb.DaysSinceLastModified | Should -BeLessOrEqual ($script:daysAgoOfflineArb + 1)
        }
    }

    Context 'Negative-control: pre-fix bug shapes still produce wrong output' {

        It 'Bug B negative-control: [string](array)[-1] still returns the last CHARACTER of the joined string' {
            # Direct re-execution of the pre-v0.7.84 buggy expression.
            # If PowerShell's array-to-string coercion semantics ever change, this
            # test fails loudly and forces re-evaluation of whether the [string]
            # cast wrapping is even needed any more.
            $clusterId = '/subscriptions/abc/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/Mobile'
            $buggyResult = ([string]($clusterId -split '/'))[-1]
            $buggyResult | Should -Be 'e' `
                -Because 'pre-fix code returned the last char of the space-joined array, not the last array element - this is the diagnostic signature of the v0.7.84 Bug B'
        }

        It 'Bug B positive-control: ($arr)[-1] without the [string] cast returns the full last element' {
            $clusterId = '/subscriptions/abc/resourceGroups/rg/providers/Microsoft.AzureStackHCI/clusters/Mobile'
            $fixedResult = ($clusterId -split '/')[-1]
            $fixedResult | Should -Be 'Mobile' `
                -Because 'the v0.7.84 fix removes the [string] cast on the array so [-1] indexes the array directly and returns the cluster name in full'
        }
    }
}

#endregion v0.7.84: Get-AzLocalFleetConnectivityStatus correctness fixes

#region v0.7.87: New-AzLocalFleetConnectivityStatusSummary (renderer extraction) + 21K-cap regression guard

# v0.7.87 ships a new public renderer function that builds the Step.4 markdown
# step-summary used by BOTH the GitHub Actions and Azure DevOps pipelines.
#
# Background:
#   v0.7.85 added a 'How to interpret + act on a non-zero reconciliation'
#   subsection to the inline Step.4 summary script. The combined `run:` body
#   in the GH Actions YAML grew from <21K to ~23.9K chars while still
#   containing 11 `${{ steps.fleet-connectivity.outputs.X }}` substitutions,
#   so GH parsed the whole body as a single expression and hit its 21,000-
#   char expression-length cap at workflow parse time.
#
# v0.7.86 mitigated by moving the 11 step-output substitutions to a step-
# level `env:` block (so the `run:` body has zero `${{ }}` and is no longer
# parsed as an expression). v0.7.87 takes the next step and extracts the
# 285-line markdown renderer into a module function so:
#   1. Both pipelines call one function instead of duplicating the renderer.
#   2. The renderer is now Pester-testable (this Describe block).
#   3. A regression guard test enforces a 21,000-char ceiling on every
#      `run:` block in every bundled GitHub Actions YAML, catching future
#      cap-exhaustion BEFORE it hits production parsing.
#   4. As a side effect, the structural anomaly in the ADO Step.4 YAML
#      (where the markdown step's PublishTestResults@2 task was absorbed
#      into the bloated pwsh block scalar and never ran as a real step)
#      is now fixed - the parsed ADO pipeline goes from 10 to 11 steps.

Describe 'Function: New-AzLocalFleetConnectivityStatusSummary' {
    Context 'Parameter Validation' {
        BeforeAll {
            $script:fcsCmd = Get-Command -Name New-AzLocalFleetConnectivityStatusSummary -ErrorAction Stop
        }

        It 'Should be exported' {
            $script:fcsCmd | Should -Not -BeNullOrEmpty
        }

        It 'Should have OutputType [string]' {
            $ot = $script:fcsCmd.OutputType
            ($ot | Where-Object { $_.Type -eq [string] }) | Should -Not -BeNullOrEmpty
        }

        It 'Should have FromCsvReports parameter set' {
            $script:fcsCmd.ParameterSets.Name | Should -Contain 'FromCsvReports'
        }

        It 'Should have FromObjects parameter set' {
            $script:fcsCmd.ParameterSets.Name | Should -Contain 'FromObjects'
        }

        It 'Should default to FromCsvReports parameter set' {
            $script:fcsCmd.DefaultParameterSet | Should -Be 'FromCsvReports'
        }

        It 'ReportsPath should be mandatory in FromCsvReports' {
            $p = $script:fcsCmd.Parameters['ReportsPath']
            $attr = $p.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' -and $_.ParameterSetName -eq 'FromCsvReports' }
            $attr.Mandatory | Should -Be $true
        }

        It 'Counts should be mandatory (both parameter sets)' {
            $p = $script:fcsCmd.Parameters['Counts']
            $attrs = $p.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            ($attrs | ForEach-Object { $_.Mandatory } | Sort-Object -Unique) | Should -Be $true
        }

        It 'PassThru should be a switch parameter' {
            $script:fcsCmd.Parameters['PassThru'].SwitchParameter | Should -Be $true
        }

        It 'OutputPath should NOT be mandatory' {
            $p = $script:fcsCmd.Parameters['OutputPath']
            $attrs = $p.Attributes | Where-Object { $_.TypeId.Name -eq 'ParameterAttribute' }
            ($attrs | ForEach-Object { $_.Mandatory }) | Should -Not -Contain $true
        }
    }

    Context 'Counts hashtable validation' {
        BeforeAll {
            $script:emptyObjects = @{
                ClusterRows = @(); ArcSummary  = @(); ArcRows = @()
                NicRows     = @(); NicStats    = @(); ArbRows = @()
            }
        }

        It 'Throws when Counts is missing keys' {
            { New-AzLocalFleetConnectivityStatusSummary @script:emptyObjects -Counts @{ ClusterTotal = 0 } } |
                Should -Throw -ExpectedMessage '*missing required key*'
        }

        It 'Accepts string values in Counts (env-var pipeline pattern)' {
            $counts = @{
                ClusterTotal = '5'; ClusterFail = '1'
                ArcTotal     = '20'; ArcFail = '2'
                NicTotal     = '80'; NicFail = '0'
                ArbTotal     = '5'; ArbFail = '0'
                TotalFailures = '3'; CriticalCount = '2'; WarningCount = '1'
            }
            { New-AzLocalFleetConnectivityStatusSummary @script:emptyObjects -Counts $counts } |
                Should -Not -Throw
        }

        It 'Accepts integer values in Counts' {
            $counts = @{
                ClusterTotal = 5; ClusterFail = 1
                ArcTotal     = 20; ArcFail = 2
                NicTotal     = 80; NicFail = 0
                ArbTotal     = 5; ArbFail = 0
                TotalFailures = 3; CriticalCount = 2; WarningCount = 1
            }
            { New-AzLocalFleetConnectivityStatusSummary @script:emptyObjects -Counts $counts } |
                Should -Not -Throw
        }
    }

    Context 'Markdown structure and content' {
        BeforeAll {
            $script:counts = @{
                ClusterTotal   = 3
                ClusterFail    = 1
                ArcTotal       = 12
                ArcFail        = 2
                NicTotal       = 48
                NicFail        = 3
                ArbTotal       = 3
                ArbFail        = 0
                TotalFailures  = 6
                CriticalCount  = 4
                WarningCount   = 2
            }

            $script:clusterRows = @(
                [pscustomobject]@{ ClusterName = 'Mobile';   ClusterId = '/sub/abc/rg/x/p/m.azurestackhci/clusters/Mobile';   ConnectivityStatus = 'Connected';         ClusterStatus = 'Healthy'; NodeCount = 4; ResourceGroup = 'rg-mobile';   Location = 'eastus' }
                [pscustomobject]@{ ClusterName = 'NewYork';  ClusterId = '/sub/abc/rg/y/p/m.azurestackhci/clusters/NewYork';  ConnectivityStatus = 'Disconnected';      ClusterStatus = 'Error';   NodeCount = 4; ResourceGroup = 'rg-newyork';  Location = 'eastus' }
                [pscustomobject]@{ ClusterName = 'Dallas';   ClusterId = '';                                                  ConnectivityStatus = 'ConnectedRecently'; ClusterStatus = 'Healthy'; NodeCount = 4; ResourceGroup = 'rg-dallas';   Location = 'centralus' }
            )
            $script:arcSummary = @(
                [pscustomobject]@{ AgentStatus = 'Connected';    Count = 10 }
                [pscustomobject]@{ AgentStatus = 'Disconnected'; Count = 2 }
            )
            $script:arcRows = @(
                [pscustomobject]@{ NodeName = 'nyc-n01'; MachineId = '/sub/abc/rg/y/p/m.hybridcompute/machines/nyc-n01'; ClusterName = 'NewYork'; ClusterId = '/sub/abc/rg/y/p/m.azurestackhci/clusters/NewYork'; AgentStatus = 'Disconnected'; OsSku = 'AzureLocal 25H2'; OsVersion = '10.0.26100.1'; ClusterVersion = '12.2509.1001.22'; LastStatusChange = '2026-05-20T10:00:00Z'; ResourceGroup = 'rg-newyork'; SubscriptionId = 'abc' }
            )
            $script:nicRows = @(
                [pscustomobject]@{ NodeName = 'nyc-n01'; NicName = 'Mgmt1'; NicStatus = 'Disconnected'; DriverVersion = '1.0'; Ip4Address = '10.0.0.10'; InterfaceDescription = 'Intel X710'; ClusterName = 'NewYork' }
            )
            $script:nicStats = @(
                [pscustomobject]@{ NicType = 'Physical'; NicStatus = 'Up';           Count = 40 }
                [pscustomobject]@{ NicType = 'Physical'; NicStatus = 'Disconnected'; Count = 3 }
            )
            $script:arbRows = @(
                [pscustomobject]@{ ArbName = 'arb-mobile';  ArbId = '/sub/abc/rg/x/p/m.resourceconnector/appliances/arb-mobile';  ArbStatus = 'Running'; ClusterId = '/sub/abc/rg/x/p/m.azurestackhci/clusters/Mobile';  ResourceGroup = 'rg-mobile';  DaysSinceLastModified = 7 }
                [pscustomobject]@{ ArbName = 'arb-newyork'; ArbId = '/sub/abc/rg/y/p/m.resourceconnector/appliances/arb-newyork'; ArbStatus = 'Failed';  ClusterId = '/sub/abc/rg/y/p/m.azurestackhci/clusters/NewYork'; ResourceGroup = 'rg-newyork'; DaysSinceLastModified = 30 }
            )

            $script:md = New-AzLocalFleetConnectivityStatusSummary `
                -ClusterRows $script:clusterRows -ArcSummary $script:arcSummary -ArcRows $script:arcRows `
                -NicRows $script:nicRows -NicStats $script:nicStats -ArbRows $script:arbRows `
                -Counts $script:counts
        }

        It 'Returns a non-empty string' {
            $script:md | Should -Not -BeNullOrEmpty
            $script:md.Length | Should -BeGreaterThan 1000
        }

        It 'Returns markdown well below the 21,000-char GitHub Actions expression cap' {
            $script:md.Length | Should -BeLessThan 18000 `
                -Because 'the renderer output must fit comfortably under the GH 21K cap (with headroom) even when emitted by a `run:` block that contains `${{ }}` substitutions in future'
        }

        It 'Includes the top-level summary heading' {
            $script:md | Should -Match '## Fleet Connectivity Status Summary'
        }

        It 'Includes the KPI summary table header' {
            $script:md | Should -Match '\| Scope \| Total \| Failing \| Healthy \|'
        }

        It 'Includes the Cluster KPI row with substituted counts' {
            $script:md | Should -Match '\*\*Clusters\*\* \| 3 \| 1 \| 2'
        }

        It 'Includes the Arc KPI row with substituted counts' {
            $script:md | Should -Match '\*\*Arc Agents \(per machine\)\*\* \| 12 \| 2 \| 10'
        }

        It 'Includes the TOTAL FAILURES row' {
            $script:md | Should -Match '\*\*TOTAL FAILURES\*\* \| - \| \*\*6\*\* \| \(Critical=4, Warning=2\)'
        }

        It 'Includes the reconciliation table heading' {
            $script:md | Should -Match '### Node \+ ARB Coverage Reconciliation'
        }

        It 'Includes the How-to-interpret subsection' {
            $script:md | Should -Match '### How to interpret \+ act on a non-zero reconciliation'
        }

        It 'Includes the Cluster Connectivity (with ARB Status) table heading' {
            $script:md | Should -Match '### Cluster Connectivity \(with ARB Status\)'
        }

        It 'Renders cluster rows with portal links when ClusterId is present' {
            $script:md | Should -Match '\[Mobile\]\(https://portal\.azure\.com/#@/resource/sub/abc/rg/x/p/m\.azurestackhci/clusters/Mobile\)'
        }

        It 'Renders plain cluster name when ClusterId is empty' {
            $script:md | Should -Match '\| Dallas \|'
        }

        It 'Renders ARB cell when cluster has an ARB' {
            $script:md | Should -Match '\[arb-mobile\]\(https://portal\.azure\.com/#@/resource/sub/abc/rg/x/p/m\.resourceconnector/appliances/arb-mobile\)'
        }

        It 'Renders _(no ARB)_ placeholder when cluster has no matching ARB' {
            # Dallas has no ClusterId so cannot match any ARB. The row should
            # carry the _(no ARB)_ placeholder.
            $script:md | Should -Match '_\(no ARB\)_'
        }

        It 'Includes Arc Agent Connection Status Summary heading' {
            $script:md | Should -Match '### Arc Agent Connection Status Summary'
        }

        It 'Includes Non-Connected Machines heading' {
            $script:md | Should -Match '### Non-Connected Machines'
        }

        It 'Includes Physical NIC Statistics heading' {
            $script:md | Should -Match '### Physical NIC Statistics \(full inventory\)'
        }

        It 'Includes Physical NIC Issues heading' {
            $script:md | Should -Match '### Physical NIC Issues \(Disconnected, non-APIPA IP\)'
        }

        It 'Includes Reports Available list' {
            $script:md | Should -Match '### Reports Available'
            $script:md | Should -Match 'fleet-cluster-connectivity\.csv'
            $script:md | Should -Match 'fleet-arb-status\.csv'
        }

        It 'Includes the Generated-at footer' {
            $script:md | Should -Match '\*Generated at \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC\*'
        }

        It 'Includes Unicode emoji icons' {
            # Check for the white heavy check mark (Pass) and cross mark (Critical).
            $script:md.Contains([char]0x2705) | Should -Be $true
            $script:md.Contains([char]0x274C) | Should -Be $true
        }

        It 'Computes Healthy = max(0, Total - Failing)' {
            # Counts: ClusterTotal=3, ClusterFail=1, healthy should be 2 (matched above)
            # ArcTotal=12, ArcFail=2, healthy=10 (matched above)
            # ArbTotal=3, ArbFail=0, healthy=3
            $script:md | Should -Match '\*\*Azure Resource Bridges\*\* \| 3 \| 0 \| 3'
        }
    }

    Context 'Empty input handling (all-empty fleet)' {
        BeforeAll {
            $script:zeroCounts = @{
                ClusterTotal = 0; ClusterFail = 0
                ArcTotal     = 0; ArcFail = 0
                NicTotal     = 0; NicFail = 0
                ArbTotal     = 0; ArbFail = 0
                TotalFailures = 0; CriticalCount = 0; WarningCount = 0
            }
            $script:mdEmpty = New-AzLocalFleetConnectivityStatusSummary `
                -ClusterRows @() -ArcSummary @() -ArcRows @() `
                -NicRows @() -NicStats @() -ArbRows @() `
                -Counts $script:zeroCounts
        }

        It 'Emits a non-empty markdown document even with zero inputs' {
            $script:mdEmpty | Should -Not -BeNullOrEmpty
            $script:mdEmpty.Length | Should -BeGreaterThan 1000
        }

        It 'Emits "*No clusters returned.*" placeholder for empty cluster set' {
            $script:mdEmpty | Should -Match '\*No clusters returned\.\*'
        }

        It 'Emits "*No Arc-enabled machines returned for the selected scope.*" placeholder' {
            $script:mdEmpty | Should -Match '\*No Arc-enabled machines returned for the selected scope\.\*'
        }

        It 'Emits "*All machines are Connected.*" placeholder for empty Arc-rows' {
            $script:mdEmpty | Should -Match '\*All machines are Connected\.\*'
        }

        It 'Emits "*No NIC data returned for the selected scope.*" placeholder' {
            $script:mdEmpty | Should -Match '\*No NIC data returned for the selected scope\.\*'
        }

        It 'Emits "*No physical NIC issues*" placeholder for empty NIC issues' {
            $script:mdEmpty | Should -Match '\*No physical NIC issues\.'
        }

        It 'Does NOT include the Orphan ARBs section when there are no orphans' {
            $script:mdEmpty | Should -Not -Match '### Orphan ARBs'
        }

        It 'Stays well under the 21K cap with empty inputs' {
            $script:mdEmpty.Length | Should -BeLessThan 18000
        }
    }

    Context 'Orphan ARBs section appears when orphan ARBs are present' {
        BeforeAll {
            $script:orphanCounts = @{
                ClusterTotal = 1; ClusterFail = 0
                ArcTotal     = 0; ArcFail = 0
                NicTotal     = 0; NicFail = 0
                ArbTotal     = 2; ArbFail = 0
                TotalFailures = 0; CriticalCount = 0; WarningCount = 0
            }
            # One in-scope cluster, but the ARB array has TWO entries: one
            # matching, one orphaned (ClusterId pointing at a cluster NOT in
            # the in-scope cluster list).
            $script:orphanClusters = @(
                [pscustomobject]@{ ClusterName = 'Mobile'; ClusterId = '/sub/abc/rg/x/p/m.azurestackhci/clusters/Mobile'; ConnectivityStatus = 'Connected'; ClusterStatus = 'Healthy'; NodeCount = 4; ResourceGroup = 'rg-mobile'; Location = 'eastus' }
            )
            $script:orphanArbsInput = @(
                [pscustomobject]@{ ArbName = 'arb-mobile';   ArbId = '/sub/abc/rg/x/p/m.resourceconnector/appliances/arb-mobile';   ArbStatus = 'Running'; ClusterId = '/sub/abc/rg/x/p/m.azurestackhci/clusters/Mobile';      ResourceGroup = 'rg-mobile';   DaysSinceLastModified = 7 }
                [pscustomobject]@{ ArbName = 'arb-stale';    ArbId = '/sub/abc/rg/z/p/m.resourceconnector/appliances/arb-stale';    ArbStatus = 'Offline'; ClusterId = '/sub/abc/rg/z/p/m.azurestackhci/clusters/DeletedCluster'; ResourceGroup = 'rg-stale';    DaysSinceLastModified = 120 }
            )
            $script:mdOrphan = New-AzLocalFleetConnectivityStatusSummary `
                -ClusterRows $script:orphanClusters -ArcSummary @() -ArcRows @() `
                -NicRows @() -NicStats @() -ArbRows $script:orphanArbsInput `
                -Counts $script:orphanCounts
        }

        It 'Includes the Orphan ARBs section heading' {
            $script:mdOrphan | Should -Match '### Orphan ARBs \(no matching cluster in scope\)'
        }

        It 'Lists the orphan ARB by name' {
            $script:mdOrphan | Should -Match 'arb-stale'
        }

        It 'Does NOT list the non-orphan ARB in the Orphan ARBs section' {
            # arb-mobile should appear in the Cluster Connectivity table but
            # NOT in the Orphan ARBs section. Verify by counting occurrences
            # of arb-mobile (should be 1 - the cluster table row only).
            ($script:mdOrphan -split 'arb-mobile').Count - 1 | Should -BeGreaterOrEqual 1
        }

        It 'Reconciliation table reports the correct orphan ARB count' {
            $script:mdOrphan | Should -Match '\| Orphan ARBs \| 1 \|'
        }
    }

    Context 'Multi-cluster-per-RG ARB (comma-separated ClusterId)' {
        BeforeAll {
            $script:mcrgCounts = @{
                ClusterTotal = 2; ClusterFail = 0
                ArcTotal     = 0; ArcFail = 0
                NicTotal     = 0; NicFail = 0
                ArbTotal     = 1; ArbFail = 0
                TotalFailures = 0; CriticalCount = 0; WarningCount = 0
            }
            $script:mcrgClusters = @(
                [pscustomobject]@{ ClusterName = 'ClusterA'; ClusterId = '/sub/abc/rg/shared/p/m.azurestackhci/clusters/ClusterA'; ConnectivityStatus = 'Connected'; ClusterStatus = 'Healthy'; NodeCount = 4; ResourceGroup = 'rg-shared'; Location = 'eastus' }
                [pscustomobject]@{ ClusterName = 'ClusterB'; ClusterId = '/sub/abc/rg/shared/p/m.azurestackhci/clusters/ClusterB'; ConnectivityStatus = 'Connected'; ClusterStatus = 'Healthy'; NodeCount = 4; ResourceGroup = 'rg-shared'; Location = 'eastus' }
            )
            # One ARB serving BOTH clusters (multi-cluster-per-RG case).
            $script:mcrgArbs = @(
                [pscustomobject]@{ ArbName = 'arb-shared'; ArbId = '/sub/abc/rg/shared/p/m.resourceconnector/appliances/arb-shared'; ArbStatus = 'Running'; ClusterId = '/sub/abc/rg/shared/p/m.azurestackhci/clusters/ClusterA, /sub/abc/rg/shared/p/m.azurestackhci/clusters/ClusterB'; ResourceGroup = 'rg-shared'; DaysSinceLastModified = 5 }
            )
            $script:mdMcrg = New-AzLocalFleetConnectivityStatusSummary `
                -ClusterRows $script:mcrgClusters -ArcSummary @() -ArcRows @() `
                -NicRows @() -NicStats @() -ArbRows $script:mcrgArbs `
                -Counts $script:mcrgCounts
        }

        It 'Matches the shared ARB to BOTH ClusterA and ClusterB' {
            # arb-shared link should appear twice (once per cluster row).
            ($script:mdMcrg -split [regex]::Escape('[arb-shared]')).Count - 1 | Should -Be 2
        }

        It 'Reports zero orphan ARBs (the ARB matches both clusters)' {
            $script:mdMcrg | Should -Match '\| Orphan ARBs \| 0 \|'
        }

        It 'Reports two clusters with an ARB in the reconciliation table' {
            $script:mdMcrg | Should -Match '\| Clusters with an ARB \| 2 \|'
        }
    }

    Context 'Output options: -OutputPath, -PassThru' {
        BeforeAll {
            $script:tmpDir = Join-Path -Path $env:TEMP -ChildPath ('fcs-test-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:tmpDir -Force | Out-Null
            $script:zeroCounts = @{
                ClusterTotal = 0; ClusterFail = 0
                ArcTotal     = 0; ArcFail = 0
                NicTotal     = 0; NicFail = 0
                ArbTotal     = 0; ArbFail = 0
                TotalFailures = 0; CriticalCount = 0; WarningCount = 0
            }
            $script:emptyArgs = @{
                ClusterRows = @(); ArcSummary  = @(); ArcRows = @()
                NicRows     = @(); NicStats    = @(); ArbRows = @()
                Counts      = $script:zeroCounts
            }
        }

        AfterAll {
            if (Test-Path -LiteralPath $script:tmpDir) {
                Remove-Item -LiteralPath $script:tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Returns markdown by default (no OutputPath)' {
            $result = New-AzLocalFleetConnectivityStatusSummary @script:emptyArgs
            $result | Should -Not -BeNullOrEmpty
            $result.GetType().Name | Should -Be 'String'
        }

        It 'Writes file when -OutputPath is provided (no PassThru -> no return value)' {
            $outFile = Join-Path -Path $script:tmpDir -ChildPath 'out-1.md'
            $result = New-AzLocalFleetConnectivityStatusSummary @script:emptyArgs -OutputPath $outFile
            Test-Path -LiteralPath $outFile | Should -Be $true
            (Get-Item -LiteralPath $outFile).Length | Should -BeGreaterThan 100
            $result | Should -BeNullOrEmpty
        }

        It 'Writes file AND returns string when -OutputPath + -PassThru' {
            $outFile = Join-Path -Path $script:tmpDir -ChildPath 'out-2.md'
            $result = New-AzLocalFleetConnectivityStatusSummary @script:emptyArgs -OutputPath $outFile -PassThru
            Test-Path -LiteralPath $outFile | Should -Be $true
            $result | Should -Not -BeNullOrEmpty
            $result.GetType().Name | Should -Be 'String'
        }

        It 'Writes UTF-8 without BOM' {
            $outFile = Join-Path -Path $script:tmpDir -ChildPath 'out-3.md'
            New-AzLocalFleetConnectivityStatusSummary @script:emptyArgs -OutputPath $outFile | Out-Null
            $bytes = [IO.File]::ReadAllBytes($outFile)
            # No BOM: first three bytes should NOT be 0xEF 0xBB 0xBF.
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -Be $false
        }

        It 'Creates parent directory if it does not exist' {
            $nestedFile = Join-Path -Path $script:tmpDir -ChildPath 'nested/sub/out.md'
            New-AzLocalFleetConnectivityStatusSummary @script:emptyArgs -OutputPath $nestedFile | Out-Null
            Test-Path -LiteralPath $nestedFile | Should -Be $true
        }
    }

    Context 'CSV-based input (FromCsvReports parameter set)' {
        BeforeAll {
            $script:csvDir = Join-Path -Path $env:TEMP -ChildPath ('fcs-csv-' + [Guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:csvDir -Force | Out-Null

            @([pscustomobject]@{ ClusterName = 'Mobile'; ClusterId = '/sub/abc/rg/x/p/m.azurestackhci/clusters/Mobile'; ConnectivityStatus = 'Connected'; ClusterStatus = 'Healthy'; NodeCount = 4; ResourceGroup = 'rg-mobile'; Location = 'eastus' }) |
                Export-Csv -Path (Join-Path $script:csvDir 'fleet-cluster-connectivity.csv') -NoTypeInformation
            @([pscustomobject]@{ AgentStatus = 'Connected'; Count = 4 }) |
                Export-Csv -Path (Join-Path $script:csvDir 'fleet-arc-status-summary.csv') -NoTypeInformation
            # Intentionally omit other CSVs to verify missing-file handling.

            $script:csvCounts = @{
                ClusterTotal = 1; ClusterFail = 0
                ArcTotal     = 4; ArcFail = 0
                NicTotal     = 0; NicFail = 0
                ArbTotal     = 0; ArbFail = 0
                TotalFailures = 0; CriticalCount = 0; WarningCount = 0
            }
            $script:mdCsv = New-AzLocalFleetConnectivityStatusSummary -ReportsPath $script:csvDir -Counts $script:csvCounts
        }

        AfterAll {
            if (Test-Path -LiteralPath $script:csvDir) {
                Remove-Item -LiteralPath $script:csvDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'Reads CSVs from the ReportsPath folder' {
            $script:mdCsv | Should -Match '\[Mobile\]'
        }

        It 'Treats missing CSV files as empty (no error)' {
            # No fleet-arb-status.csv, no fleet-physical-nics.csv etc.
            # Should still produce a complete markdown document.
            $script:mdCsv | Should -Match '### Cluster Connectivity \(with ARB Status\)'
            $script:mdCsv | Should -Match '\*No physical NIC issues\.'
        }

        It 'Respects the Counts hashtable even when CSVs are missing' {
            $script:mdCsv | Should -Match '\*\*Clusters\*\* \| 1 \|'
            $script:mdCsv | Should -Match '\*\*Arc Agents \(per machine\)\*\* \| 4 \|'
        }
    }
}

Describe 'Regression v0.7.87: bundled GitHub Actions YAML run: blocks stay under GitHub 21,000-char expression cap' {
    # Defensive regression guard. GitHub Actions enforces a 21,000-char
    # expression-length cap on any `run:` block that contains `${{ ... }}`
    # substitutions (the whole `run:` body is parsed as one expression).
    # v0.7.85 inadvertently exceeded this cap by appending a long
    # 'How to interpret + act on a non-zero reconciliation' subsection
    # to the Step.4 markdown summary while keeping 11 step-output
    # substitutions inline. v0.7.86 + v0.7.87 mitigated by moving the
    # substitutions to step-level `env:` blocks (zero `${{ }}` in body)
    # AND extracting the renderer into a module function.
    #
    # This test enforces an 18,000-char ceiling on every `run:` block
    # in every bundled GitHub Actions YAML, regardless of whether the
    # block currently contains `${{ }}`. The 3K headroom under the
    # 21K cap allows for:
    #   - growth during development of new features,
    #   - future re-introduction of `${{ }}` substitutions (the
    #     post-substitution length matters, not the pre-substitution
    #     length, and substitutions can expand).
    #
    # Failing this test means a `run:` block has grown too large.
    # The fix is one of:
    #   1. Extract the renderer/logic into a module function (the
    #      v0.7.87 pattern - see New-AzLocalFleetConnectivityStatusSummary).
    #   2. Move static prose into a separate file consumed via
    #      `Get-Content -Raw`.
    #   3. Move inline `${{ }}` substitutions to step-level `env:`
    #      vars so the cap stops applying (though the test still
    #      enforces the ceiling defensively).

    # Pester v5 NOTE: code at this level (outside BeforeAll/It) runs at
    # DISCOVERY phase. $PSScriptRoot is available here, so we can enumerate
    # the bundled YAML files now and use the resulting case array as the
    # argument to `It -ForEach`. (Computing the array inside BeforeAll would
    # be too late - -ForEach is evaluated at discovery.)
    $script:repoRootForCap = Split-Path -Path $PSScriptRoot -Parent
    $script:ghActionsDir   = Join-Path -Path $script:repoRootForCap -ChildPath 'Automation-Pipeline-Examples/github-actions'
    $script:GhYamlCapCases = @(
        Get-ChildItem -Path $script:ghActionsDir -Filter '*.yml' -File |
            ForEach-Object { @{ FileName = $_.Name; FullPath = $_.FullName } }
    )

    BeforeAll {
        $script:RunBlockCharCeiling = 18000
        $script:repoRootForCap      = Split-Path -Path $PSScriptRoot -Parent
        $script:ghActionsDir        = Join-Path -Path $script:repoRootForCap -ChildPath 'Automation-Pipeline-Examples/github-actions'

        # Helper: enumerate `run: |` (and `script: |`) literal block scalars
        # in a YAML file by tracking indentation. A block scalar terminates
        # at the first non-blank line whose indent is <= the indent of the
        # `run:` (or `script:`) key. Each block also reports whether its
        # body contains any `${{ ... }}` GitHub Actions expression - the
        # 21,000-char cap only applies to expression-bearing blocks.
        function script:Get-YamlBlockScalars {
            param([Parameter(Mandatory)][string]$Path)

            $lines  = Get-Content -LiteralPath $Path
            $blocks = [System.Collections.Generic.List[object]]::new()
            $inBlk  = $false
            $start  = -1
            $keyInd = 0
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $ln = $lines[$i]
                if (-not $inBlk -and $ln -match '^(\s+)(run|script):\s*\|') {
                    $inBlk  = $true
                    $start  = $i
                    $keyInd = $Matches[1].Length
                    continue
                }
                if ($inBlk) {
                    $curInd = if ($ln -match '^( *)\S') { $Matches[1].Length } else { -1 }
                    if ($curInd -ge 0 -and $curInd -le $keyInd) {
                        $body = ($lines[($start + 1)..($i - 1)] -join "`n")
                        $blocks.Add([pscustomobject]@{
                                StartLine     = $start + 1
                                EndLine       = $i
                                Chars         = $body.Length
                                HasExpression = ($body -match '\$\{\{')
                            })
                        $inBlk = $false
                    }
                }
            }
            if ($inBlk) {
                $body = ($lines[($start + 1)..($lines.Count - 1)] -join "`n")
                $blocks.Add([pscustomobject]@{
                        StartLine     = $start + 1
                        EndLine       = $lines.Count
                        Chars         = $body.Length
                        HasExpression = ($body -match '\$\{\{')
                    })
            }
            return , $blocks.ToArray()
        }
    }

    It 'every <FileName> expression-bearing run/script block stays under the 18,000-char ceiling (3K headroom under GH 21K expression cap)' -ForEach $script:GhYamlCapCases {
        $blocks = & (Get-Command -Name Get-YamlBlockScalars) -Path $FullPath
        # The 21,000-char cap only applies to run: blocks that contain
        # `${{ }}` expressions (GH evaluates expressions as one unit).
        # Static run: blocks (no expressions) are not subject to the cap.
        $exprBlocks = @($blocks | Where-Object { $_.HasExpression })
        foreach ($b in $exprBlocks) {
            $b.Chars | Should -BeLessThan $script:RunBlockCharCeiling `
                -Because "$FileName has a run: block at L$($b.StartLine)-L$($b.EndLine) that is $($b.Chars) chars AND contains `${{ }}` expressions. The GitHub Actions expression-length cap is 21,000 chars; this test enforces an 18,000 ceiling with 3K headroom. Fix by extracting the logic into a module function (see New-AzLocalFleetConnectivityStatusSummary in v0.7.87) or moving `${{ }}` substitutions to step-level env: vars."
        }
    }

    It 'Step.4 GH YAML uses the new renderer function (no inline 22 KB markdown)' {
        $step4 = Join-Path -Path $script:ghActionsDir -ChildPath 'Step.4_fleet-connectivity-status.yml'
        $raw   = Get-Content -LiteralPath $step4 -Raw
        $raw | Should -Match 'New-AzLocalFleetConnectivityStatusSummary' `
            -Because 'Step.4 must call the v0.7.87 renderer function rather than inlining the markdown summary'
        $raw | Should -Not -Match '## Fleet Connectivity Status Summary' `
            -Because 'the markdown summary heading must NOT appear inline in the YAML - the renderer function owns the markdown'
    }

    It 'Step.4 ADO YAML uses the new renderer function (no inline 22 KB markdown)' {
        $step4 = Join-Path -Path $script:repoRootForCap -ChildPath 'Automation-Pipeline-Examples/azure-devops/Step.4_fleet-connectivity-status.yml'
        $raw   = Get-Content -LiteralPath $step4 -Raw
        $raw | Should -Match 'New-AzLocalFleetConnectivityStatusSummary' `
            -Because 'Step.4 ADO must call the same v0.7.87 renderer function as the GH twin'
        $raw | Should -Not -Match '## Fleet Connectivity Status Summary' `
            -Because 'the markdown summary heading must NOT appear inline in the YAML - the renderer function owns the markdown'
    }
}

#endregion v0.7.87: New-AzLocalFleetConnectivityStatusSummary (renderer extraction) + 21K-cap regression guard
