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

Describe 'Release pull request preflight contract' -Tag 'ReleaseGate' {
    BeforeAll {
        $script:GatePath = Join-Path $PSScriptRoot 'Invoke-ReleasePrePullRequestGate.ps1'
        $script:PullRequestPath = Join-Path $PSScriptRoot '..\Tools\New-AzLocalReleasePullRequest.ps1'

        $tokens = $null
        $parseErrors = $null
        $script:GateAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:GatePath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty

        $tokens = $null
        $parseErrors = $null
        $script:PullRequestAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:PullRequestPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty
    }

    It 'runs hermetic Pester and the parallel live runner before writing a receipt' {
        $content = Get-Content -LiteralPath $script:GatePath -Raw
        $hermeticIndex = $content.IndexOf('Invoke-Pester -Configuration $config')
        $liveIndex = $content.IndexOf('& $liveRunnerPath -ThrottleLimit $ThrottleLimit')
        $receiptIndex = $content.IndexOf('$receipt = [pscustomobject]@{')

        $hermeticIndex | Should -BeGreaterThan -1
        $liveIndex | Should -BeGreaterThan $hermeticIndex
        $receiptIndex | Should -BeGreaterThan $liveIndex
        $content | Should -Match '\$liveResult\.Skipped -gt 0'
        $content | Should -Match '\$liveResult\.Inconclusive -gt 0'
    }

    It 'binds the receipt to HEAD and the manifest module version' {
        $content = Get-Content -LiteralPath $script:GatePath -Raw
        $content | Should -Match 'git rev-parse HEAD'
        $content | Should -Match "Import-PowerShellDataFile -Path \`$manifestPath"
        $content | Should -Match 'Commit\s+=\s+\$commit'
        $content | Should -Match 'ModuleVersion\s+=\s+\$moduleVersion'
        $content | Should -Match 'git status --porcelain'
        $content | Should -Match "git rev-parse '@\{upstream\}'"
    }

    It 'invokes the gate before GitHub CLI can create the pull request' {
        $content = Get-Content -LiteralPath $script:PullRequestPath -Raw
        $gateIndex = $content.IndexOf('& $gatePath -ThrottleLimit $ThrottleLimit')
        $createIndex = $content.IndexOf('gh pr create')

        $gateIndex | Should -BeGreaterThan -1
        $createIndex | Should -BeGreaterThan $gateIndex
    }
}

Describe 'Live integration pipeline-command coverage contract' -Tag 'ReleaseGate' {
    BeforeAll {
        $moduleRoot = Join-Path $PSScriptRoot '..'
        $liveTestPath = Join-Path $PSScriptRoot 'Live-Integration.Tests.ps1'
        $pipelineRoot = Join-Path $moduleRoot 'Automation-Pipeline-Examples'

        $tokens = $null
        $parseErrors = $null
        $liveAst = [System.Management.Automation.Language.Parser]::ParseFile(
            $liveTestPath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrors | Should -BeNullOrEmpty
        $script:LiveDirectCommands = @($liveAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.CommandAst]
                }, $true) | ForEach-Object { $_.GetCommandName() } |
                Where-Object { $_ -match '^[A-Za-z]+-AzLocal' } | Sort-Object -Unique)

        $script:PipelineCommands = @(Get-ChildItem -LiteralPath $pipelineRoot -Recurse -Filter '*.yml' -File |
                ForEach-Object {
                    $content = Get-Content -LiteralPath $_.FullName -Raw
                    [regex]::Matches($content, '\b(?:Add|Assert|Connect|Copy|Export|Get|Invoke|New|Reset|Resolve|Resume|Set|Start|Stop|Sync|Test|Update)-AzLocal[A-Za-z0-9]+\b') |
                        ForEach-Object { $_.Value }
                } | Sort-Object -Unique)

        $script:LiveTransitiveCoverage = [ordered]@{
            'Get-AzLocalAvailableUpdates'             = 'Export-AzLocalFleetUpdateStatusReport'
            'Get-AzLocalClusterUpdateReadiness'       = 'Export-AzLocalClusterUpdateReadinessReport'
            'Get-AzLocalUpdateRuns'                   = 'Export-AzLocalUpdateRunMonitorReport'
            'Test-AzLocalApplyUpdatesScheduleCoverage' = 'Export-AzLocalApplyUpdatesScheduleAudit'
            'Test-AzLocalClusterHealth'               = 'Export-AzLocalClusterUpdateReadinessReport'
        }

        $script:OfflineCoverageReasons = [ordered]@{
            'Add-AzLocalApplyUpdatesStepSummary'        = 'Artifact renderer; covered by hermetic summary tests.'
            'Add-AzLocalFailedUpdateRetryHintSummary'   = 'Artifact renderer; covered by hermetic summary tests.'
            'Add-AzLocalNoReadyClustersStepSummary'     = 'Artifact renderer; covered by hermetic summary tests.'
            'Add-AzLocalPipelineSupportFooter'          = 'Artifact renderer; covered by hermetic pipeline tests.'
            'Add-AzLocalPipelineVersionBanner'          = 'Artifact renderer; covered by hermetic pipeline tests.'
            'Add-AzLocalSideloadStepSummary'            = 'Artifact renderer; covered by hermetic summary tests.'
            'Assert-AzLocalAzureSubscriptionAccess'     = 'Authentication failure paths require controlled mocks.'
            'Assert-AzLocalPipelineReport'              = 'Local artifact guard; covered by hermetic filesystem tests.'
            'Copy-AzLocalPipelineExample'               = 'Local template copy operation; covered by hermetic filesystem tests.'
            'Export-AzLocalClusterInventoryDriftReport' = 'Local artifact comparison; covered by hermetic fixture tests.'
            'Get-AzLocalItsmConfig'                      = 'Local configuration parser; covered by hermetic tests.'
            'Get-AzLocalSideloadSettings'                = 'Local configuration parser; covered by hermetic tests.'
            'Invoke-AzLocalPipelineTimedOperation'       = 'Diagnostic wrapper; covered by hermetic timing tests.'
            'New-AzLocalApplyUpdatesScheduleConfig'      = 'Local configuration writer; covered by hermetic tests.'
            'New-AzLocalFleetConnectivityStatusSummary' = 'Artifact renderer; transitively exercised and hermetically asserted.'
            'Resolve-AzLocalPipelineUpdateRing'          = 'Schedule parser; covered by deterministic fixture tests.'
            'Resolve-AzLocalSideloadPlan'                = 'Planning logic; covered by deterministic fixture tests.'
            'Set-AzLocalPipelineOutput'                  = 'Runner output adapter; covered by host-specific hermetic tests.'
            'Update-AzLocalPipelineExample'              = 'Local template updater; covered by hermetic filesystem tests.'
        }

        $script:DestructiveExclusionReasons = [ordered]@{
            'Invoke-AzLocalItsmTicketingFromArtifact'       = 'Creates external ITSM incidents.'
            'Invoke-AzLocalReadinessGatedClusterUpdate'     = 'Can start cluster updates.'
            'Invoke-AzLocalReadinessGatedFailedUpdateRetry' = 'Can retry failed cluster updates.'
            'Invoke-AzLocalSideloadUpdate'                  = 'Can copy and import update payloads.'
            'New-AzLocalIncident'                           = 'Creates an external ITSM incident.'
            'Set-AzLocalClusterUpdateRingTag'               = 'Writes Azure resource tags.'
            'Set-AzLocalClusterUpdateRingTagFromCsv'        = 'Writes Azure resource tags.'
            'Start-AzLocalClusterUpdate'                    = 'Starts an Azure Local update.'
            'Update-AzLocalSideloadCatalog'                 = 'Can modify sideload catalog state.'
        }
    }

    It 'classifies every command invoked by the bundled pipeline templates' {
        $classified = @(
            $script:LiveDirectCommands
            $script:LiveTransitiveCoverage.Keys
            $script:OfflineCoverageReasons.Keys
            $script:DestructiveExclusionReasons.Keys
        ) | Sort-Object -Unique
        $unclassified = @($script:PipelineCommands | Where-Object { $_ -notin $classified })
        $unclassified | Should -BeNullOrEmpty -Because 'every new pipeline command must be live-tested, transitively covered, or explicitly safety-excluded'
    }

    It 'keeps each transitive coverage wrapper directly exercised by the live suite' {
        foreach ($entry in $script:LiveTransitiveCoverage.GetEnumerator()) {
            $script:LiveDirectCommands | Should -Contain $entry.Value -Because "$($entry.Key) relies on live wrapper $($entry.Value)"
        }
    }

    It 'does not retain stale classifications for commands no longer used by a pipeline' {
        $reviewed = @(
            $script:LiveTransitiveCoverage.Keys
            $script:OfflineCoverageReasons.Keys
            $script:DestructiveExclusionReasons.Keys
        ) | Sort-Object -Unique
        $stale = @($reviewed | Where-Object { $_ -notin $script:PipelineCommands })
        $stale | Should -BeNullOrEmpty -Because 'the registry should describe the current pipeline command surface only'
    }
}