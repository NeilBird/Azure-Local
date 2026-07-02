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
                        properties         = [PSCustomObject]@{ state = 'UpdateAvailable'; healthState = 'Success' }
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
    # Install-Module call in a 3-attempt, exponential-backoff (10s, 20s) retry
    # loop so a transient PSGallery search/propagation blip ("No match was found
    # for the specified search criteria and module name 'AzLocal.UpdateManagement'")
    # no longer fails the whole run. The retry MUST be an inline pwsh loop (not a
    # module cmdlet) because it runs BEFORE the module is installed, and NOT the
    # native ADO retryCountOnTaskFailure (which has no configurable backoff and
    # would disturb the counted login-retry assertions above).

    It 'Every pipeline YAML that installs the module wraps Install-Module in the 3-attempt retry loop' {
        $ymlFiles = Get-ChildItem -Path $script:PipelineRoot -Recurse -Filter '*.yml' -File
        $ymlFiles.Count | Should -BeGreaterThan 0

        $issues = New-Object System.Collections.Generic.List[string]
        foreach ($yml in $ymlFiles) {
            $content = Get-Content -Raw -LiteralPath $yml.FullName
            $installCount = ([regex]::Matches($content, [regex]::Escape('Install-Module @installArgs'))).Count
            if ($installCount -eq 0) { continue }

            $retryCount = ([regex]::Matches($content, [regex]::Escape('$installMaxAttempts = 3'))).Count
            $sleepCount = ([regex]::Matches($content, [regex]::Escape('Start-Sleep -Seconds $installRetryDelay'))).Count

            $relPath = $yml.FullName.Substring($script:PipelineRoot.Length).TrimStart('\', '/')
            if ($retryCount -ne $installCount) {
                $issues.Add("${relPath}: has $installCount install call(s) but $retryCount retry loop opener(s) (`$installMaxAttempts = 3)")
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
            $retryTotal   += ([regex]::Matches($content, [regex]::Escape('$installMaxAttempts = 3'))).Count
        }
        $installTotal | Should -Be 26
        $retryTotal   | Should -Be $installTotal
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
}
