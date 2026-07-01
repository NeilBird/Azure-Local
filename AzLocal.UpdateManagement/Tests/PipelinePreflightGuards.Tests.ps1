#Requires -Module Pester
<#
.SYNOPSIS
    v0.9.12 feature tests for the two pipeline preflight guard cmdlets:
      - Assert-AzLocalAzureSubscriptionAccess (fails when the authenticated
        identity can see zero ENABLED subscriptions).
      - Assert-AzLocalPipelineReport (fails when the collect step produced no
        report file, before the misleading "No test report files were found"
        publish-step error can fire).

.NOTES
    Both cmdlets emit a run-summary block + step output and THEN throw on the
    failure path. The Local-host tests exercise the pure pass/throw logic
    (summary writes land harmlessly in $env:TEMP). The GitHub-host tests set
    GITHUB_ACTIONS + GITHUB_STEP_SUMMARY + GITHUB_OUTPUT and assert the
    remediation block / step output are actually written - the surface the
    operator sees in the run summary, per the feature's core requirement.
#>

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop

    # Snapshot the host-detection env vars so tests can force Local vs GitHub
    # without leaking state into the rest of the suite.
    $script:SavedGithubActions = $env:GITHUB_ACTIONS
    $script:SavedTfBuild       = $env:TF_BUILD
    $script:SavedStepSummary   = $env:GITHUB_STEP_SUMMARY
    $script:SavedGithubOutput  = $env:GITHUB_OUTPUT

    # Force Local host for the default (logic) contexts.
    $env:GITHUB_ACTIONS = $null
    $env:TF_BUILD       = $null
}

AfterAll {
    $env:GITHUB_ACTIONS      = $script:SavedGithubActions
    $env:TF_BUILD            = $script:SavedTfBuild
    $env:GITHUB_STEP_SUMMARY = $script:SavedStepSummary
    $env:GITHUB_OUTPUT       = $script:SavedGithubOutput
    Remove-Module AzLocal.UpdateManagement -Force -ErrorAction SilentlyContinue
}

Describe 'Assert-AzLocalAzureSubscriptionAccess' {

    Context 'Local host - pass/throw logic (injected account list)' {

        BeforeEach {
            $env:GITHUB_ACTIONS = $null
            $env:TF_BUILD       = $null
        }

        It 'Passes and (with -PassThru) returns the enabled count when subscriptions are visible' {
            $json = '[{"id":"s1","name":"Sub 1","state":"Enabled"},{"id":"s2","name":"Sub 2","state":"Enabled"}]'
            $count = Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson $json -PassThru
            $count | Should -Be 2
        }

        It 'Throws when the account list is an empty array' {
            { Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson '[]' } |
                Should -Throw -ExpectedMessage '*no accessible Azure subscriptions*'
        }

        It 'Throws when the account list JSON is empty / whitespace' {
            { Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson '   ' } |
                Should -Throw -ExpectedMessage '*no accessible Azure subscriptions*'
        }

        It 'Throws when every visible subscription is Disabled (not Enabled)' {
            $json = '[{"id":"s1","name":"Sub 1","state":"Disabled"},{"id":"s2","name":"Sub 2","state":"Warned"}]'
            { Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson $json } |
                Should -Throw -ExpectedMessage '*no accessible Azure subscriptions*'
        }

        It 'Counts only Enabled subscriptions when a mix is returned' {
            $json = '[{"id":"s1","state":"Enabled"},{"id":"s2","state":"Disabled"},{"id":"s3","state":"Enabled"}]'
            $count = Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson $json -PassThru
            $count | Should -Be 2
        }

        It 'Falls back to counting every account when no state field is present (older az / fixtures)' {
            $json = '[{"id":"s1","name":"Sub 1"},{"id":"s2","name":"Sub 2"}]'
            $count = Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson $json -PassThru
            $count | Should -Be 2
        }

        It 'Respects -MinimumCount (2 enabled but 3 required -> throws)' {
            $json = '[{"id":"s1","state":"Enabled"},{"id":"s2","state":"Enabled"}]'
            { Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson $json -MinimumCount 3 } |
                Should -Throw -ExpectedMessage '*no accessible Azure subscriptions*'
        }
    }

    Context 'GitHub host - run-summary + step output are written' {

        BeforeEach {
            $env:GITHUB_ACTIONS      = 'true'
            $env:TF_BUILD            = $null
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive ('summary-{0}.md' -f ([guid]::NewGuid()))
            $env:GITHUB_OUTPUT       = Join-Path $TestDrive ('output-{0}.txt' -f ([guid]::NewGuid()))
        }

        AfterEach {
            $env:GITHUB_ACTIONS      = $null
            $env:GITHUB_STEP_SUMMARY = $null
            $env:GITHUB_OUTPUT       = $null
        }

        It 'Failure path writes the remediation block to the run summary and sets subscription_count=0' {
            { Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson '[]' } | Should -Throw

            $summary = Get-Content -Path $env:GITHUB_STEP_SUMMARY -Raw
            $summary | Should -Match 'Azure login returned no accessible subscriptions'
            $summary | Should -Match 'Assign an RBAC role'

            $out = Get-Content -Path $env:GITHUB_OUTPUT -Raw
            $out | Should -Match 'subscription_count=0'
        }

        It 'Success path writes a confirmation to the run summary and sets subscription_count' {
            $json = '[{"id":"s1","state":"Enabled"},{"id":"s2","state":"Enabled"}]'
            Assert-AzLocalAzureSubscriptionAccess -SubscriptionListJson $json

            $summary = Get-Content -Path $env:GITHUB_STEP_SUMMARY -Raw
            $summary | Should -Match 'Azure subscription access verified'

            $out = Get-Content -Path $env:GITHUB_OUTPUT -Raw
            $out | Should -Match 'subscription_count=2'
        }
    }
}

Describe 'Assert-AzLocalPipelineReport' {

    Context 'Local host - pass/throw logic (real filesystem via TestDrive)' {

        BeforeEach {
            $env:GITHUB_ACTIONS = $null
            $env:TF_BUILD       = $null
        }

        It 'Passes and (with -PassThru) returns the matching file when a non-empty report exists' {
            $reportDir = Join-Path $TestDrive ('rpt-{0}' -f ([guid]::NewGuid()))
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $file = Join-Path $reportDir 'results.xml'
            Set-Content -Path $file -Value '<testsuite/>'

            $matched = @(Assert-AzLocalPipelineReport -Path (Join-Path $reportDir '*.xml') -ProducingStepName 'Collect Test' -PassThru)
            $matched | Should -HaveCount 1
            $matched[0] | Should -Be $file
        }

        It 'Throws when the glob matches no files at all' {
            $reportDir = Join-Path $TestDrive ('rpt-{0}' -f ([guid]::NewGuid()))
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            { Assert-AzLocalPipelineReport -Path (Join-Path $reportDir '*.xml') -ProducingStepName 'Collect Test' } |
                Should -Throw -ExpectedMessage '*no report files produced*'
        }

        It 'Throws when only a zero-byte report matches (default requires non-empty)' {
            $reportDir = Join-Path $TestDrive ('rpt-{0}' -f ([guid]::NewGuid()))
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $reportDir 'empty.xml') -Force | Out-Null
            { Assert-AzLocalPipelineReport -Path (Join-Path $reportDir '*.xml') -ProducingStepName 'Collect Test' } |
                Should -Throw -ExpectedMessage '*no report files produced*'
        }

        It 'Passes with -AllowEmpty when only a zero-byte report matches' {
            $reportDir = Join-Path $TestDrive ('rpt-{0}' -f ([guid]::NewGuid()))
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $file = Join-Path $reportDir 'empty.xml'
            New-Item -ItemType File -Path $file -Force | Out-Null
            $matched = Assert-AzLocalPipelineReport -Path (Join-Path $reportDir '*.xml') -AllowEmpty -PassThru
            @($matched) | Should -HaveCount 1
        }

        It 'Passes when at least one of several globs matches' {
            $reportDir = Join-Path $TestDrive ('rpt-{0}' -f ([guid]::NewGuid()))
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            $file = Join-Path $reportDir 'results.xml'
            Set-Content -Path $file -Value '<testsuite/>'
            $globs = @((Join-Path $reportDir '*.csv'), (Join-Path $reportDir '*.xml'))
            $matched = Assert-AzLocalPipelineReport -Path $globs -PassThru
            @($matched) | Should -HaveCount 1
        }
    }

    Context 'GitHub host - failure writes the run-summary block' {

        BeforeEach {
            $env:GITHUB_ACTIONS      = 'true'
            $env:TF_BUILD            = $null
            $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive ('rpt-summary-{0}.md' -f ([guid]::NewGuid()))
        }

        AfterEach {
            $env:GITHUB_ACTIONS      = $null
            $env:GITHUB_STEP_SUMMARY = $null
        }

        It 'Failure path writes the "No diagnostic reports were produced" block to the run summary' {
            $reportDir = Join-Path $TestDrive ('rpt-{0}' -f ([guid]::NewGuid()))
            New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
            { Assert-AzLocalPipelineReport -Path (Join-Path $reportDir '*.xml') -ProducingStepName 'Collect Fleet Health Status' } |
                Should -Throw

            $summary = Get-Content -Path $env:GITHUB_STEP_SUMMARY -Raw
            $summary | Should -Match 'No diagnostic reports were produced'
            $summary | Should -Match 'Collect Fleet Health Status'
        }
    }
}
