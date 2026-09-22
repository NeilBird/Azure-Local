BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\AzLocal.UpdateManagement.psd1') -Force
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\AzLocal.UpdateManagement.psd1') -Force
}

Describe 'Monitor suppression opt-in settings' {
    It 'Defaults renewal off with a seven-day maximum' {
        $settings = Get-AzLocalFleetSettings -Path (Join-Path $TestDrive 'missing.yml')
        $settings.RenewMonitorSuppressionDuringUpdates | Should -BeFalse
        $settings.MonitorSuppressionMaxTotalHours | Should -Be 168
    }

    It 'Accepts renewal settings independently of their order: <Hours>' -TestCases @(
        @{ Hours = 49 }, @{ Hours = 168 }, @{ Hours = 720 }
    ) {
        param($Hours)
        $path = Join-Path $TestDrive 'renewal.yml'
        "schemaVersion: 6`nmonitorSuppressionMaxTotalHours: $Hours # maximum`nrenewMonitorSuppressionDuringUpdates: true`nsuppressMonitorNotificationsPerClusterDuringUpdates: true" | Set-Content $path
        $settings = Get-AzLocalFleetSettings -Path $path
        $settings.RenewMonitorSuppressionDuringUpdates | Should -BeTrue
        $settings.MonitorSuppressionMaxTotalHours | Should -Be $Hours
        $settings.SuppressMonitorNotificationsPerClusterDuringUpdates | Should -BeTrue
    }

    It 'Rejects invalid renewal settings: <Setting>' -TestCases @(
        @{ Setting = "renewMonitorSuppressionDuringUpdates: 'true'" },
        @{ Setting = 'renewMonitorSuppressionDuringUpdates: yes' },
        @{ Setting = "renewMonitorSuppressionDuringUpdates: true`nrenewMonitorSuppressionDuringUpdates: false" },
        @{ Setting = 'monitorSuppressionMaxTotalHours: 48' },
        @{ Setting = 'monitorSuppressionMaxTotalHours: 721' },
        @{ Setting = 'monitorSuppressionMaxTotalHours: 999999999999999999' },
        @{ Setting = 'monitorSuppressionMaxTotalHours: 49.5' },
        @{ Setting = "monitorSuppressionMaxTotalHours: '168'" },
        @{ Setting = 'monitorSuppressionMaxTotalHours:' },
        @{ Setting = "monitorSuppressionMaxTotalHours: 168`nmonitorSuppressionMaxTotalHours: 72" }
    ) {
        param($Setting)
        $path = Join-Path $TestDrive 'invalid-renewal.yml'
        "schemaVersion: 6`n$Setting" | Set-Content $path
        { Get-AzLocalFleetSettings -Path $path } | Should -Throw '*Get-AzLocalFleetSettings:*'
    }

    It 'Defaults off for a missing file' {
        (Get-AzLocalFleetSettings -Path (Join-Path $TestDrive 'missing.yml')).SuppressMonitorNotificationsPerClusterDuringUpdates | Should -BeFalse
    }

    It 'Accepts only unquoted booleans: <Value>' -TestCases @(
        @{ Value = 'true'; Expected = $true },
        @{ Value = 'false'; Expected = $false }
    ) {
        param($Value, $Expected)
        $path = Join-Path $TestDrive 'fleet.yml'
        "schemaVersion: 6`nsuppressMonitorNotificationsPerClusterDuringUpdates: $Value" | Set-Content $path
        (Get-AzLocalFleetSettings -Path $path).SuppressMonitorNotificationsPerClusterDuringUpdates | Should -Be $Expected
    }

    It 'Rejects invalid or duplicate opt-in: <Value>' -TestCases @(
        @{ Value = "'true'" }, @{ Value = 'yes' }, @{ Value = '1' }, @{ Value = '' },
        @{ Value = "true`nsuppressMonitorNotificationsPerClusterDuringUpdates: false" }
    ) {
        param($Value)
        $path = Join-Path $TestDrive 'fleet.yml'
        "schemaVersion: 6`nsuppressMonitorNotificationsPerClusterDuringUpdates: $Value" | Set-Content $path
        { Get-AzLocalFleetSettings -Path $path } | Should -Throw '*unquoted true or false*'
    }

    It 'Preserves older schemas with both features disabled: <Version>' -TestCases @(
        @{ Version = 1 }, @{ Version = 3 }, @{ Version = 4 }, @{ Version = 5 }
    ) {
        param($Version)
        $path = Join-Path $TestDrive 'legacy.yml'
        "schemaVersion: $Version" | Set-Content $path
        $settings = Get-AzLocalFleetSettings -Path $path
        $settings.SuppressMonitorNotificationsPerClusterDuringUpdates | Should -BeFalse
        $settings.RenewMonitorSuppressionDuringUpdates | Should -BeFalse
    }

    It 'Requires schema 6 for each new setting: <Setting>' -TestCases @(
        @{ Setting = 'suppressMonitorNotificationsPerClusterDuringUpdates: false' },
        @{ Setting = 'renewMonitorSuppressionDuringUpdates: false' },
        @{ Setting = 'monitorSuppressionMaxTotalHours: 168' }
    ) {
        param($Setting)
        $path = Join-Path $TestDrive 'legacy-new-setting.yml'
        "schemaVersion: 5`n$Setting" | Set-Content $path
        { Get-AzLocalFleetSettings -Path $path } | Should -Throw '*require schemaVersion: 6*'
    }
}

Describe 'Monitor suppression schema migration' {
    InModuleScope AzLocal.UpdateManagement {
        It 'Automatically migrates v5 with exact backup through the updater: <Platform>' -TestCases @(
            @{ Platform = 'GitHub'; Folder = '.github/workflows' }, @{ Platform = 'AzureDevOps'; Folder = 'pipelines' }
        ) {
            param($Platform, $Folder)
            $repoRoot = Join-Path $TestDrive $Platform
            $destination = Join-Path $repoRoot $Folder
            $configPath = Join-Path $repoRoot 'config'
            $null = New-Item $destination, $configPath -ItemType Directory -Force
            $path = Join-Path $configPath 'fleet-settings.yml'
            $before = "schemaVersion: 5 # keep`r`n# operator settings`r`nconcurrency:`r`n  maxUpdateRingTagConcurrentJobs: 2`r`n"
            [IO.File]::WriteAllText($path, $before, [Text.UTF8Encoding]::new($true))
            $beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
            Update-AzLocalPipelineExample -Destination $destination -Platform $Platform -Confirm:$false | Out-Null
            $backupPath = Join-Path $configPath 'fleet-settings_v5.bak.yml'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($backupPath)) | Should -BeExactly $beforeBytes
            $settings = Get-AzLocalFleetSettings -Path $path
            $settings.SchemaVersion | Should -Be 6
            $settings.MaxUpdateRingTagConcurrentJobs | Should -Be 2
            $settings.SuppressMonitorNotificationsPerClusterDuringUpdates | Should -BeFalse
            $settings.RenewMonitorSuppressionDuringUpdates | Should -BeFalse
            $after = [IO.File]::ReadAllText($path)
            $after.StartsWith($before.Replace('schemaVersion: 5', 'schemaVersion: 6')) | Should -BeTrue
            Update-AzLocalPipelineExample -Destination $destination -Platform $Platform -Confirm:$false | Out-Null
            [IO.File]::ReadAllText($path) | Should -BeExactly $after
        }

        It 'Restores exact original bytes when migrated settings fail validation' {
            $repoRoot = Join-Path $TestDrive 'invalid-settings'
            $destination = Join-Path $repoRoot '.github/workflows'
            $configPath = Join-Path $repoRoot 'config'
            $null = New-Item $destination, $configPath -ItemType Directory -Force
            $path = Join-Path $configPath 'fleet-settings.yml'
            [IO.File]::WriteAllText($path, "schemaVersion: 5`r`nmonitorSuppressionMaxTotalHours: 999`r`n# preserve this too", [Text.UTF8Encoding]::new($true))
            $beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))
            { Update-AzLocalPipelineExample -Destination $destination -Platform GitHub -Confirm:$false | Out-Null } | Should -Throw '*49 to 720*'
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) | Should -BeExactly $beforeBytes
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $configPath 'fleet-settings_v5.bak.yml'))) | Should -BeExactly $beforeBytes
        }

        It 'Preserves v5 content order comments and line endings: <Newline>' -TestCases @(
            @{ Newline = "`r`n" }, @{ Newline = "`n" }
        ) {
            param($Newline)
            $original = @('schemaVersion: 5 # keep me', '# operator reporting', 'reporting:', '  maxRowsPerTable: 42', '', '# operator concurrency', 'concurrency:', '  maxUpdateRingTagConcurrentJobs: 2') -join $Newline
            $result = Convert-AzLocalFleetSettingsSchemaVersion -Text $original
            $result.ToVersion | Should -Be 6
            $result.NewText.StartsWith($original.Replace('schemaVersion: 5', 'schemaVersion: 6')) | Should -BeTrue
            $result.NewText | Should -Match '(?m)^# renewMonitorSuppressionDuringUpdates: false\r?$'
            $result.NewText | Should -Match '(?m)^# monitorSuppressionMaxTotalHours: 168\r?$'
            $path = Join-Path $TestDrive 'migrated.yml'
            [IO.File]::WriteAllText($path, $result.NewText)
            $settings = Get-AzLocalFleetSettings -Path $path
            $settings.MaxRowsPerTable | Should -Be 42
            $settings.MaxUpdateRingTagConcurrentJobs | Should -Be 2
            $settings.RenewMonitorSuppressionDuringUpdates | Should -BeFalse
            (Convert-AzLocalFleetSettingsSchemaVersion -Text $result.NewText).NewText | Should -BeExactly $result.NewText
        }

        It 'Preserves existing explicit opt-ins and maximum without duplicating them' {
            $original = "schemaVersion: 5`nsuppressMonitorNotificationsPerClusterDuringUpdates: true`nrenewMonitorSuppressionDuringUpdates: true`nmonitorSuppressionMaxTotalHours: 96 # approved"
            $result = Convert-AzLocalFleetSettingsSchemaVersion -Text $original
            $result.NewText | Should -BeExactly $original.Replace('schemaVersion: 5', 'schemaVersion: 6')
        }

        It 'Keeps a fully commented starter inert' {
            $result = Convert-AzLocalFleetSettingsSchemaVersion -Text "# schemaVersion: 5`n# operator note"
            $path = Join-Path $TestDrive 'inert.yml'
            [IO.File]::WriteAllText($path, $result.NewText)
            (Get-AzLocalFleetSettings -Path $path).SuppressMonitorNotificationsPerClusterDuringUpdates | Should -BeFalse
            (Get-AzLocalFleetSettings -Path $path).RenewMonitorSuppressionDuringUpdates | Should -BeFalse
        }
    }
}

Describe 'Monitor suppression apply summary' {
    InModuleScope AzLocal.UpdateManagement {
        It 'Renders recorded evidence without consulting current settings: <HostName>' -TestCases @(
            @{ HostName = 'GitHub' }, @{ HostName = 'AzureDevOps' }
        ) {
            param($HostName)
            $script:summaryHost = $HostName
            Mock Get-AzLocalPipelineHost { $script:summaryHost }
            Mock Get-AzLocalApplyScheduleSourceBanner { @() }
            Mock Get-AzLocalFleetSettings { throw 'Historical evidence must not depend on current settings' }
            Mock Add-AzLocalPipelineStepSummary { $script:suppressionSummaryMarkdown = $Markdown; 'summary.md' }
            $rows = foreach ($value in @('Enabled', 'N/A', 'Pending', 'Not verified', '')) {
                $row = [ordered]@{ ClusterName = "test-$value"; Status = 'UpdateStarted'; UpdateName = 'Solution1'; Duration = '00:00:02'; Message = 'Started' }
                if ($value) { $row.AlertSuppression = $value }
                [pscustomobject]$row
            }
            $path = Join-Path $TestDrive 'apply-results.json'
            $rows | ConvertTo-Json | Set-Content $path
            Add-AzLocalApplyUpdatesStepSummary -UpdateRing Test -ApplyResultsJsonPath $path
            $script:suppressionSummaryMarkdown | Should -Match '\| Duration \| Alert Suppression \| Message \|'
            foreach ($value in @('Enabled', 'N/A', 'Pending', 'Not verified', 'Not recorded')) {
                $script:suppressionSummaryMarkdown | Should -Match ([regex]::Escape("| 00:00:02 | $value | Started |"))
            }
        }
    }
}

Describe 'Monitor suppression lifecycle' {
    InModuleScope AzLocal.UpdateManagement {
        BeforeEach {
            $script:suppressionCluster = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/test/providers/Microsoft.AzureStackHCI/clusters/test'
            $script:suppressionOperation = '22222222-2222-2222-2222-222222222222'
            $script:suppressionCreated = [datetimeoffset]::UtcNow.AddHours(-1)
            $script:suppressionRule = [pscustomobject]@{
                id = Get-AzLocalMonitorSuppressionRuleId $script:suppressionCluster
                tags = @{ ManagedBy = 'AzLocal.UpdateManagement'; ClusterResourceId = $script:suppressionCluster; OperationId = $script:suppressionOperation; UpdateName = 'Solution1'; CreatedUtc = $script:suppressionCreated.ToString('o') }
                properties = [pscustomobject]@{
                    enabled = $true
                    scopes = @($script:suppressionCluster)
                    actions = @([pscustomobject]@{ actionType = 'RemoveAllActionGroups' })
                    schedule = [pscustomobject]@{ effectiveFrom = $script:suppressionCreated.ToString('o'); effectiveUntil = $script:suppressionCreated.AddHours(48).ToString('o'); timeZone = 'UTC' }
                }
            }
            $script:suppressionTags = @{ UpdateMonitorSuppression = $script:suppressionOperation }
            Mock Get-AzLocalFleetSettings { [pscustomobject]@{ SuppressMonitorNotificationsPerClusterDuringUpdates = $true } }
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $true; Data = $script:suppressionRule; Error = '' } }
            Mock Set-AzLocalClusterTagsMerge { $true }
            Mock Get-AzLocalClusterUpdateRuns { @() }
            Mock Write-Log {}
        }

        It 'Makes no Azure calls when opted out' {
            Mock Get-AzLocalFleetSettings { [pscustomobject]@{ SuppressMonitorNotificationsPerClusterDuringUpdates = $false } }
            (Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1).Ready | Should -BeTrue
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
        }

        It 'Exports propagation deferral as JUnit skipped' {
            $path = Join-Path $TestDrive 'pending.xml'
            $row = [pscustomobject]@{ ClusterName = 'test'; Status = 'SuppressionPending'; Message = 'Awaiting propagation'; UpdateName = 'Solution1'; StartTime = Get-Date; EndTime = Get-Date; Duration = $null }
            Export-ResultsToJUnitXml -Results @($row) -OutputPath $path -TestSuiteName 'Suppression' -OperationType 'StartUpdate'
            [xml]$document = Get-Content -Raw $path
            $document.SelectSingleNode('//testcase/skipped') | Should -Not -BeNullOrEmpty
            $document.SelectSingleNode('//testsuite').skipped | Should -Be '1'
        }

        It 'Makes no Azure calls for an unmarked cluster during reconciliation' {
            (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags @{}).Status | Should -Be Disabled
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly
        }

        It 'Creates an exact-cluster bounded rule and defers the update' {
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'ResourceNotFound' } } -ParameterFilter { $Method -eq 'GET' }
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags @{}
            $result.Ready | Should -BeFalse
            $result.Status | Should -Be SuppressionPending
            Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'PUT' -and ($Body | ConvertFrom-Json).properties.scopes[0] -eq $script:suppressionCluster -and
                ($Body | ConvertFrom-Json).properties.actions[0].actionType -eq 'RemoveAllActionGroups' -and
                ($Body | ConvertFrom-Json).properties.schedule.timeZone -eq 'UTC'
            }
        }

        It 'Does not create or tag under WhatIf' {
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'ResourceNotFound' } }
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags @{} -WhatIf
            $result.Ready | Should -BeFalse
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
        }

        It 'Reuses the owned rule without extending its expiry' {
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags
            $result.Ready | Should -BeTrue
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
        }

        Context 'Bounded renewal' {
            BeforeEach {
                $script:suppressionCreated = [datetimeoffset]::UtcNow.AddHours(-44)
                $script:suppressionRule.tags.CreatedUtc = $script:suppressionCreated.ToString('o')
                $script:suppressionRule.properties.schedule.effectiveFrom = $script:suppressionCreated.ToString('o')
                $script:suppressionRule.properties.schedule.effectiveUntil = $script:suppressionCreated.AddHours(48).ToString('o')
                $script:renewalSettings = [pscustomobject]@{ SuppressMonitorNotificationsPerClusterDuringUpdates = $true; RenewMonitorSuppressionDuringUpdates = $true; MonitorSuppressionMaxTotalHours = 168 }
                Mock Get-AzLocalFleetSettings { $script:renewalSettings }
                Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'InProgress'; timeStarted = $script:suppressionCreated.AddHours(1).ToString('o') } } }
                Mock Invoke-AzRestJson {
                    $payload = $Body | ConvertFrom-Json
                    $script:suppressionRule.tags = $payload.tags
                    $script:suppressionRule.properties = $payload.properties
                    [pscustomobject]@{ Ok = $true; Data = $script:suppressionRule; Error = '' }
                } -ParameterFilter { $Method -eq 'PUT' }
            }

            It 'Renews the exact owned rule and reuses it without another PUT' {
                $result = Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags
                $result.ReportAction | Should -Be Extended
                $result.Message | Should -BeLike '*renewed*'
                (ConvertTo-AzLocalMonitorSuppressionUtc $result.ExpiresUtc) | Should -BeGreaterThan ([datetimeoffset]::UtcNow.AddHours(47))
                (ConvertTo-AzLocalMonitorSuppressionUtc $script:suppressionRule.tags.RenewalMaxExpiresUtc) | Should -Be $script:suppressionCreated.AddHours(168)
                $script:suppressionRule.tags.OperationId | Should -Be $script:suppressionOperation
                $script:suppressionRule.tags.UpdateName | Should -Be Solution1
                $script:suppressionRule.properties.scopes[0] | Should -Be $script:suppressionCluster
                $script:suppressionRule.properties.actions[0].actionType | Should -Be RemoveAllActionGroups
                $script:suppressionTags.UpdateMonitorSuppressionUntil = $result.ExpiresUtc
                (Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags).Ready | Should -BeTrue
                Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
                Should -Invoke Get-AzLocalClusterUpdateRuns -ParameterFilter { $resourceId -eq $script:suppressionCluster -and $updateNameFilter -eq 'Solution1' }
            }

            It 'Caps renewal from original creation and cannot raise a recorded cap' {
                $script:renewalSettings.MonitorSuppressionMaxTotalHours = 49
                $result = Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags
                (ConvertTo-AzLocalMonitorSuppressionUtc $result.ExpiresUtc) | Should -Be $script:suppressionCreated.AddHours(49)
                $script:renewalSettings.MonitorSuppressionMaxTotalHours = 720
                (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).ReportAction | Should -Be 'Limit reached'
                Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            }

            It 'Records the cap at creation when renewal is opted in' {
                Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'ResourceNotFound' } } -ParameterFilter { $Method -eq 'GET' }
                Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags @{} | Out-Null
                $created = ConvertTo-AzLocalMonitorSuppressionUtc $script:suppressionRule.tags.CreatedUtc
                (ConvertTo-AzLocalMonitorSuppressionUtc $script:suppressionRule.tags.RenewalMaxExpiresUtc) | Should -Be $created.AddHours(168)
                (ConvertTo-AzLocalMonitorSuppressionUtc $script:suppressionRule.tags.RenewalExpiresUtc) | Should -Be $created.AddHours(48)
            }

            It 'Requires both opt-ins: <Property>' -TestCases @(
                @{ Property = 'SuppressMonitorNotificationsPerClusterDuringUpdates' }, @{ Property = 'RenewMonitorSuppressionDuringUpdates' }
            ) {
                param($Property)
                $script:renewalSettings.$Property = $false
                Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags | Out-Null
                Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            }

            It 'Never renews without current active evidence: <State>/<StartHours>' -TestCases @(
                @{ State = 'Succeeded'; StartHours = 1 }, @{ State = 'Unknown'; StartHours = 1 },
                @{ State = 'InProgress'; StartHours = -1 }, @{ State = 'InProgress'; StartHours = 100 }, @{ State = ''; StartHours = 1 }
            ) {
                param($State, $StartHours)
                $script:renewalTestRuns = if ($State) { [pscustomobject]@{ properties = [pscustomobject]@{ state = $State; timeStarted = $script:suppressionCreated.AddHours($StartHours).ToString('o') } } } else { @() }
                Mock Get-AzLocalClusterUpdateRuns { $script:renewalTestRuns }
                Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags | Out-Null
                Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            }

            It 'Does not write under WhatIf' {
                (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags -WhatIf).Status | Should -Be WhatIf
                Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
                Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
            }

            It 'Retains existing marker on failed renewal' {
                Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Error = 'AuthorizationFailed'; Data = $null } } -ParameterFilter { $Method -eq 'PUT' }
                { Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags } | Should -Throw '*renewal failed*'
                Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
            }

            It 'Does not extend disabled rules or on run read failure: <Scenario>' -TestCases @(
                @{ Scenario = 'disabled' }, @{ Scenario = 'read failure' }
            ) {
                param($Scenario)
                if ($Scenario -eq 'disabled') {
                    $script:suppressionRule.properties.enabled = $false
                    Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags | Out-Null
                }
                else {
                    Mock Get-AzLocalClusterUpdateRuns { throw 'run read denied' }
                    { Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags } | Should -Throw '*run read denied*'
                }
                Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
            }

            It 'Cleans renewed suppression at the maximum even if an update is active' {
                $created = [datetimeoffset]::UtcNow.AddHours(-170)
                $script:suppressionRule.tags.CreatedUtc = $created.ToString('o')
                $script:suppressionRule.tags.RenewalMaxExpiresUtc = $created.AddHours(168).ToString('o')
                $script:suppressionRule.tags.RenewalExpiresUtc = $created.AddHours(168).ToString('o')
                $script:suppressionRule.properties.schedule.effectiveFrom = $created.ToString('o')
                $script:suppressionRule.properties.schedule.effectiveUntil = $created.AddHours(168).ToString('o')
                Mock Get-AzLocalFleetSettings { throw 'Cleanup must not load settings' }
                (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).Status | Should -Be SuppressionRemoved
                Should -Invoke Get-AzLocalClusterUpdateRuns -Times 0 -Exactly
                Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            }

            It 'Cleans a matching terminal run after renewal even with settings unreadable' {
                Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags | Out-Null
                Mock Get-AzLocalFleetSettings { throw 'Cleanup must not load settings' }
                Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Succeeded'; timeStarted = $script:suppressionCreated.AddHours(1).ToString('o') } } }
                (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).Status | Should -Be SuppressionRemoved
            }

            It 'Rejects altered renewal schedules and limits: <Scenario>' -TestCases @(
                @{ Scenario = 'schedule' }, @{ Scenario = 'limit' }, @{ Scenario = 'missing metadata' }
            ) {
                param($Scenario)
                Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags | Out-Null
                switch ($Scenario) {
                    'schedule' { $script:suppressionRule.properties.schedule.effectiveUntil = [datetimeoffset]::UtcNow.AddDays(10).ToString('o') }
                    'limit' { $script:suppressionRule.tags.RenewalMaxExpiresUtc = $script:suppressionCreated.AddHours(721).ToString('o') }
                    'missing metadata' { $script:suppressionRule.tags.PSObject.Properties.Remove('RenewalExpiresUtc') }
                }
                { Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags } | Should -Throw '*manual review*'
                Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
            }

            It 'Repairs the marker after successful renewal and failed tag write' {
                Mock Set-AzLocalClusterTagsMerge { throw 'tag write denied' }
                { Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags } | Should -Throw '*tag write denied*'
                Mock Set-AzLocalClusterTagsMerge { $true }
                (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).Status | Should -Be SuppressionActive
                Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
                Should -Invoke Set-AzLocalClusterTagsMerge -Times 2 -Exactly
            }
        }

        It 'Reuses an ARM JSON rule with a parsed local creation tag and an unspecified UTC schedule' {
            $script:suppressionRule.properties.schedule.effectiveFrom = $script:suppressionCreated.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
            $script:suppressionRule.properties.schedule.effectiveUntil = $script:suppressionCreated.AddHours(48).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss')
            $script:suppressionRule = $script:suppressionRule | ConvertTo-Json -Depth 8 | ConvertFrom-Json
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags
            $result.Ready | Should -BeTrue
            [math]::Abs(([datetimeoffset]::Parse($result.ExpiresUtc) - $script:suppressionCreated.AddHours(48)).TotalSeconds) | Should -BeLessThan 1
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
        }

        It 'Treats unspecified schedule DateTime values as UTC' {
            $schedule = [datetime]::new(2026, 9, 22, 13, 46, 45, [DateTimeKind]::Unspecified)
            (ConvertTo-AzLocalMonitorSuppressionUtc $schedule).ToString('o') | Should -Be '2026-09-22T13:46:45.0000000+00:00'
        }

        It 'Preserves offsets when converting creation and run timestamps' {
            (ConvertTo-AzLocalMonitorSuppressionUtc '2026-09-22T14:46:45+01:00').ToString('o') | Should -Be '2026-09-22T13:46:45.0000000+00:00'
            $localTime = [datetime]::new(2026, 9, 22, 13, 46, 45, [DateTimeKind]::Utc).ToLocalTime()
            (ConvertTo-AzLocalMonitorSuppressionUtc $localTime).ToString('o') | Should -Be '2026-09-22T13:46:45.0000000+00:00'
        }

        It 'Rejects shared scopes' {
            $script:suppressionRule.properties.scopes += '/subscriptions/other'
            { Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags } | Should -Throw '*mismatch*'
        }

        It 'Defers while the owned rule is still propagating' {
            $recent = [datetimeoffset]::UtcNow.AddMinutes(-5)
            $script:suppressionRule.tags.CreatedUtc = $recent.ToString('o')
            $script:suppressionRule.properties.schedule.effectiveFrom = $recent.ToString('o')
            $script:suppressionRule.properties.schedule.effectiveUntil = $recent.AddHours(48).ToString('o')
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags
            $result.Ready | Should -BeFalse
            $result.Status | Should -Be SuppressionPending
        }

        It 'Does not approve installation when the rule disappears during reconciliation' {
            $script:suppressionReadCount = 0
            Mock Invoke-AzRestJson {
                $script:suppressionReadCount++
                if ($script:suppressionReadCount -eq 1) { return [pscustomobject]@{ Ok = $true; Data = $script:suppressionRule; Error = '' } }
                return [pscustomobject]@{ Ok = $false; Data = $null; Error = 'ResourceNotFound' }
            }
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags
            $result.Ready | Should -BeFalse
            $result.Status | Should -Be SuppressionPending
        }

        It 'Does not approve a completed window when cleanup is only previewed' {
            Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Succeeded'; timeStarted = $script:suppressionCreated.AddMinutes(31).ToString('o') } } }
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags -WhatIf
            $result.Ready | Should -BeFalse
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Blocks installation and retains markers after a failed creation' {
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'ResourceNotFound' } } -ParameterFilter { $Method -eq 'GET' }
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'RequestDisallowedByPolicy' } } -ParameterFilter { $Method -eq 'PUT' }
            { Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags @{} } | Should -Throw '*creation failed*'
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 1 -Exactly -ParameterFilter { $null -ne $Tags.UpdateMonitorSuppression }
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly -ParameterFilter { $null -eq $Tags.UpdateMonitorSuppression }
        }

        It 'Does not create a rule without a durable cluster marker' {
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'ResourceNotFound' } }
            Mock Set-AzLocalClusterTagsMerge { throw 'tag write denied' }
            { Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags @{} } | Should -Throw '*tag write denied*'
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'Requires a fresh window before retrying a completed attempt' {
            Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Failed'; timeStarted = $script:suppressionCreated.AddMinutes(31).ToString('o') } } }
            $result = Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags
            $result.Ready | Should -BeFalse
            $result.Status | Should -Be SuppressionPending
            Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Retains markers when deletion fails' {
            Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Succeeded'; timeStarted = $script:suppressionCreated.AddMinutes(31).ToString('o') } } }
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'AuthorizationFailed' } } -ParameterFilter { $Method -eq 'DELETE' }
            { Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags } | Should -Throw '*markers retained*'
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
        }

        It 'Does not clean a completed attempt under WhatIf' {
            Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Succeeded'; timeStarted = $script:suppressionCreated.AddMinutes(31).ToString('o') } } }
            (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags -WhatIf).Status | Should -Be WhatIf
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
            Should -Invoke Set-AzLocalClusterTagsMerge -Times 0 -Exactly
        }

        It 'Retains suppression if any matching attempt is still active' {
            Mock Get-AzLocalClusterUpdateRuns {
                [pscustomobject]@{ properties = [pscustomobject]@{ state = 'InProgress'; timeStarted = $script:suppressionCreated.AddMinutes(32).ToString('o') } }
                [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Failed'; timeStarted = $script:suppressionCreated.AddMinutes(31).ToString('o') } }
            }
            (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).Status | Should -Be SuppressionActive
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Rejects operator-disabled rules' {
            $script:suppressionRule.properties.enabled = $false
            { Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags $script:suppressionTags } | Should -Throw '*disabled*'
        }

        It 'Rejects operation conflicts' {
            { Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags @{ UpdateMonitorSuppression = 'other' } } | Should -Throw '*marker mismatch*'
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Blocks on authorization errors without creating anything' {
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Data = $null; Error = 'AuthorizationFailed' } }
            { Invoke-AzLocalMonitorSuppression -Action Ensure -ClusterResourceId $script:suppressionCluster -UpdateName Solution1 -ClusterTags @{} } | Should -Throw '*read failed*'
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'Removes suppression on a matching terminal run: <State>' -TestCases @(
            @{ State = 'Succeeded' }, @{ State = 'Failed' }, @{ State = 'Canceled' }, @{ State = 'Cancelled' }
        ) {
            param($State)
            $script:suppressionRunState = $State
            Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = $script:suppressionRunState; timeStarted = $script:suppressionCreated.AddMinutes(31).ToString('o') } } }
            Mock Get-AzLocalFleetSettings { throw 'Cleanup must not depend on current opt-in' }
            (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).Status | Should -Be SuppressionRemoved
            Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Does not remove suppression for an older run of the same update' {
            Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'Succeeded'; timeStarted = $script:suppressionCreated.AddDays(-1).ToString('o') } } }
            (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).Status | Should -Be SuppressionActive
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Retains suppression on run-read failure' {
            Mock Get-AzLocalClusterUpdateRuns { throw 'read failed' }
            { Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags } | Should -Throw '*read failed*'
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        }

        It 'Cleans expired rules even without any update runs' {
            $script:suppressionRule.tags.CreatedUtc = $script:suppressionCreated.AddDays(-3).ToString('o')
            $script:suppressionRule.properties.schedule.effectiveFrom = $script:suppressionCreated.AddDays(-3).ToString('o')
            $script:suppressionRule.properties.schedule.effectiveUntil = $script:suppressionCreated.AddDays(-1).ToString('o')
            (Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $script:suppressionCluster -ClusterTags $script:suppressionTags).Status | Should -Be SuppressionRemoved
            Should -Invoke Get-AzLocalClusterUpdateRuns -Times 0 -Exactly
        }

        It 'Audits real reconciliation through the monitor with no visible runs: <Scenario>' -TestCases @(
            @{ Scenario = 'Active'; ExpectedAction = 'Active / Unchanged' },
            @{ Scenario = 'Terminal'; ExpectedAction = 'Removed' },
            @{ Scenario = 'Expired'; ExpectedAction = 'Removed' },
            @{ Scenario = 'Extended'; ExpectedAction = 'Extended' },
            @{ Scenario = 'DeleteFailure'; ExpectedAction = 'Failed' },
            @{ Scenario = 'ReadFailure'; ExpectedAction = 'Failed' },
            @{ Scenario = 'TagFailure'; ExpectedAction = 'Failed' },
            @{ Scenario = 'Disabled'; ExpectedAction = 'Disabled rule' },
            @{ Scenario = 'Missing'; ExpectedAction = 'Marker cleared' }
        ) {
            param($Scenario, $ExpectedAction)
            Mock Get-AzLocalClusterInventory { [pscustomobject]@{ ResourceId = $script:suppressionCluster; ClusterName = 'test'; tags = $script:suppressionTags } }
            Mock Test-AzLocalUpdateRunsInFlight { $false }
            Mock Get-AzLocalUpdateRuns { @() }
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $true; Data = [pscustomobject]@{ id = $script:suppressionCluster; tags = $script:suppressionTags }; Error = '' } } -ParameterFilter { $Uri -like "https://management.azure.com$($script:suppressionCluster)?*" }
            Mock Set-AzLocalPipelineOutput {}
            Mock Add-AzLocalPipelineStepSummary { $script:monitorSuppressionMarkdown = $Markdown; '' }
            if ($Scenario -in @('Terminal', 'DeleteFailure')) {
                $script:suppressionTags.UpdateMonitorSuppressionUntil = 'malformed expiry must not block cleanup'
                Mock Get-AzLocalFleetSettings { [pscustomobject]@{ SuppressMonitorNotificationsPerClusterDuringUpdates = $false; RenewMonitorSuppressionDuringUpdates = $false } }
                Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = @{ state = 'Succeeded'; timeStarted = $script:suppressionCreated.AddMinutes(31).ToString('o') } } }
            }
            if ($Scenario -eq 'Expired') {
                $script:suppressionRule.tags.CreatedUtc = $script:suppressionCreated.AddDays(-3).ToString('o')
                $script:suppressionRule.properties.schedule.effectiveFrom = $script:suppressionCreated.AddDays(-3).ToString('o')
                $script:suppressionRule.properties.schedule.effectiveUntil = $script:suppressionCreated.AddDays(-1).ToString('o')
            }
            if ($Scenario -in @('Extended', 'TagFailure')) {
                $script:suppressionCreated = [datetimeoffset]::UtcNow.AddHours(-44)
                $script:suppressionRule.tags.CreatedUtc = $script:suppressionCreated.ToString('o')
                $script:suppressionRule.properties.schedule.effectiveFrom = $script:suppressionCreated.ToString('o')
                $script:suppressionRule.properties.schedule.effectiveUntil = $script:suppressionCreated.AddHours(48).ToString('o')
                Mock Get-AzLocalFleetSettings { [pscustomobject]@{ SuppressMonitorNotificationsPerClusterDuringUpdates = $true; RenewMonitorSuppressionDuringUpdates = $true; MonitorSuppressionMaxTotalHours = 168 } }
                Mock Get-AzLocalClusterUpdateRuns { [pscustomobject]@{ properties = @{ state = 'InProgress'; timeStarted = $script:suppressionCreated.AddHours(1).ToString('o') } } }
            }
            if ($Scenario -eq 'Disabled') { $script:suppressionRule.properties.enabled = $false }
            if ($Scenario -eq 'DeleteFailure') { Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Error = 'delete | denied' } } -ParameterFilter { $Method -eq 'DELETE' } }
            if ($Scenario -eq 'ReadFailure') { Mock Get-AzLocalClusterUpdateRuns { throw 'run read | failed' } }
            if ($Scenario -eq 'TagFailure') { Mock Set-AzLocalClusterTagsMerge { throw 'expiry tag | failed after PUT' } }
            if ($Scenario -eq 'Missing') { Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $false; Error = 'ResourceNotFound' } } -ParameterFilter { $Uri -like '*Microsoft.AlertsManagement*' -and $Method -eq 'GET' } }
            $report = Export-AzLocalUpdateRunMonitorReport -Scope all -SkipWhenIdle -RecentAttemptWindowHours 0 -OutputDirectory $TestDrive -PassThru
            $report.SuppressionActions.Count | Should -Be 1
            $report.SuppressionActions[0].Action | Should -Be $ExpectedAction
            $report.InFlightCount | Should -Be 0
            @($report.Rows).Count | Should -Be 0
            [xml]$junit = Get-Content -Raw $report.XmlPath
            @($junit.SelectNodes('//testcase')).Count | Should -Be 0
            $csv = @(Import-Csv $report.SuppressionCsvPath)
            $json = @(Get-Content -Raw $report.SuppressionJsonPath | ConvertFrom-Json)
            $csv.Count | Should -Be 1
            $json.Count | Should -Be 1
            $csv[0].Action | Should -Be $ExpectedAction
            $json[0].Action | Should -Be $ExpectedAction
            $json[0].ClusterResourceId | Should -Be $script:suppressionCluster
            $script:monitorSuppressionMarkdown | Should -Match '### Alert Suppression Actions'
            $script:monitorSuppressionMarkdown | Should -Match ([regex]::Escape("| $ExpectedAction |"))
            if ($Scenario -eq 'Extended') {
                Should -Invoke Invoke-AzRestJson -Times 1 -Exactly -ParameterFilter { $Method -eq 'PUT' }
                (ConvertTo-AzLocalMonitorSuppressionUtc $json[0].ExpiresUtc) | Should -BeGreaterThan ([datetimeoffset]::UtcNow.AddHours(47))
            }
            if ($ExpectedAction -eq 'Failed') {
                $script:monitorSuppressionMarkdown | Should -Not -Match '\| (Extended|Removed) \|'
                $script:monitorSuppressionMarkdown | Should -Not -Match 'read \| failed|delete \| denied|tag \| failed'
            }
            if ($Scenario -in @('Terminal', 'Expired', 'Missing')) { $json[0].ExpiresUtc | Should -BeNullOrEmpty }
            Should -Invoke Get-AzLocalUpdateRuns -Times 1 -Exactly -ParameterFilter { $SkipSideloadedReset }
        }

        It 'Omits suppression summary and clears stale artifacts without marked clusters: <Idle>' -TestCases @(
            @{ Idle = $true }, @{ Idle = $false }
        ) {
            param($Idle)
            Mock Get-AzLocalClusterInventory { [pscustomobject]@{ ResourceId = $script:suppressionCluster; ClusterName = 'test'; tags = @{} } }
            Mock Test-AzLocalUpdateRunsInFlight { $false }
            Mock Get-AzLocalUpdateRuns { @() }
            Mock Get-AzLocalFleetSettings { [pscustomobject]@{ SuppressMonitorNotificationsPerClusterDuringUpdates = $false; RenewMonitorSuppressionDuringUpdates = $false } }
            Mock Set-AzLocalPipelineOutput {}
            Mock Add-AzLocalPipelineStepSummary { $script:monitorSuppressionMarkdown = $Markdown; '' }
            'stale evidence' | Set-Content (Join-Path $TestDrive 'update-monitor-suppression.json')
            'stale evidence' | Set-Content (Join-Path $TestDrive 'update-monitor-suppression.csv')
            $report = Export-AzLocalUpdateRunMonitorReport -Scope all -SkipWhenIdle:$Idle -RecentAttemptWindowHours 0 -OutputDirectory $TestDrive -PassThru
            $report.SuppressionActions.Count | Should -Be 0
            (Get-Content -Raw $report.SuppressionJsonPath).Trim() | Should -Be '[]'
            @(Import-Csv $report.SuppressionCsvPath).Count | Should -Be 0
            $script:monitorSuppressionMarkdown | Should -Not -Match 'Alert Suppression Actions'
            Should -Invoke Invoke-AzRestJson -Times 0 -Exactly
        }

        It 'Does not consume the retry guard while suppression is pending' {
            Mock Test-AzCliAvailable { $true }
            Mock Get-AzLocalClusterInfo { [pscustomobject]@{ id = $script:suppressionCluster; name = 'test'; tags = @{} } }
            Mock Get-AzLocalUpdateSummary { [pscustomobject]@{ properties = [pscustomobject]@{ state = 'UpdateFailed' } } }
            Mock Invoke-AzLocalMonitorSuppression { [pscustomobject]@{ Ready = $false; Status = 'SuppressionPending'; Message = 'Waiting for propagation' } }
            Mock Invoke-AzLocalUpdateApply { throw 'Must not apply yet' }
            Mock Write-AzLocalUpdateLastAttemptTag {}
            $result = Invoke-AzLocalFailedUpdateRetry -ClusterName test -SubscriptionId '11111111-1111-1111-1111-111111111111' -UpdateName Solution1 -Confirm:$false
            $result.Status | Should -Be SuppressionPending
            Should -Invoke Invoke-AzLocalUpdateApply -Times 0 -Exactly
            Should -Invoke Write-AzLocalUpdateLastAttemptTag -Times 0 -Exactly
        }

        It 'Honors suppression boundaries for public start: <Mode>' -TestCases @(
            @{ Mode = 'Apply'; Expected = 'SuppressionPending'; EnsureCalls = 1; PrepareCalls = 0 },
            @{ Mode = 'Prepare'; Expected = 'PreparationStarted'; EnsureCalls = 0; PrepareCalls = 1 },
            @{ Mode = 'WhatIf'; Expected = 'WouldUpdate'; EnsureCalls = 0; PrepareCalls = 0 },
            @{ Mode = 'Enabled'; Expected = 'UpdateStarted'; EnsureCalls = 1; PrepareCalls = 0 },
            @{ Mode = 'Disabled'; Expected = 'UpdateStarted'; EnsureCalls = 1; PrepareCalls = 0 }
        ) {
            param($Mode, $Expected, $EnsureCalls, $PrepareCalls)
            Mock az { $global:LASTEXITCODE = 0; '{"id":"11111111-1111-1111-1111-111111111111"}' }
            Mock Test-AzCliAvailable { $true }
            Mock Test-ExportPathWritable { $true }
            Mock Test-AzLocalClusterResourceInGlobalScope { $true }
            Mock Get-AzLocalClusterInfo { [pscustomobject]@{ id = $script:suppressionCluster; name = 'test'; tags = @{}; properties = @{ status = 'ConnectedRecently' } } }
            Mock Invoke-AzRestJson { [pscustomobject]@{ Ok = $true; Data = [pscustomobject]@{ id = $script:suppressionCluster; name = 'test'; tags = @{}; properties = @{ status = 'ConnectedRecently' } }; Error = '' } }
            Mock Get-AzLocalUpdateSummary { [pscustomobject]@{ properties = @{ state = 'UpdateAvailable'; healthState = 'Success' } } }
            Mock Test-AzLocalClusterHealth { [pscustomobject]@{ IsBlocking = $false; ClusterName = 'test' } }
            Mock Get-LastUpdateRunErrorSummary { [pscustomobject]@{ ErrorStep = ''; ErrorMessage = '' } }
            Mock Get-HealthCheckFailureSummary { '' }
            Mock Invoke-AzLocalMonitorSuppression { [pscustomobject]@{ Ready = $false; Status = 'SuppressionPending'; Message = 'Waiting for propagation' } }
            Mock Invoke-AzLocalUpdateApply { throw 'Must not install' }
            if ($Mode -in @('Enabled', 'Disabled')) {
                $script:startSuppressionStatus = if ($Mode -eq 'Enabled') { 'SuppressionActive' } else { 'Disabled' }
                Mock Invoke-AzLocalMonitorSuppression { [pscustomobject]@{ Ready = $true; Status = $script:startSuppressionStatus; Message = '' } }
                Mock Invoke-AzLocalUpdateApply { $true }
            }
            Mock Invoke-AzLocalUpdatePrepare { $true }
            Mock Write-AzLocalUpdateLastAttemptTag {}
            Mock Write-UpdateCsvLog {}
            $update = [pscustomobject]@{ name = 'Solution12.2610.1004.31'; properties = @{ state = 'Ready'; packageType = 'Solution'; version = '12.2610.1004.31' } }
            $parameters = @{
                ClusterResourceIds = @($script:suppressionCluster)
                PrefetchedAvailableUpdates = @{ $script:suppressionCluster = @($update) }
                UpdateName = $update.name
                Force = $true
                PassThru = $true
            }
            if ($Mode -eq 'Prepare') { $parameters.PrepareOnly = $true }
            if ($Mode -eq 'WhatIf') { $parameters.WhatIf = $true }
            $result = @(Start-AzLocalClusterUpdate @parameters)
            $result.Count | Should -Be 1
            $result[0].Status | Should -Be $Expected
            Should -Invoke Invoke-AzLocalMonitorSuppression -Times $EnsureCalls -Exactly
            Should -Invoke Invoke-AzLocalUpdatePrepare -Times $PrepareCalls -Exactly
            $expectedApplyCalls = if ($Mode -in @('Enabled', 'Disabled')) { 1 } else { 0 }
            Should -Invoke Invoke-AzLocalUpdateApply -Times $expectedApplyCalls -Exactly
            if ($Mode -eq 'Enabled') { $result[0].AlertSuppression | Should -Be Enabled }
            if ($Mode -in @('Disabled', 'Prepare')) { $result[0].AlertSuppression | Should -Be 'N/A' }
            if ($Mode -eq 'Apply') { $result[0].AlertSuppression | Should -Be Pending }
        }
    }
}