#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

Describe 'Get-HyperVVMCheckpointHealth source contracts' {
    BeforeAll {
        $script:ToolRoot = Split-Path $PSScriptRoot -Parent
        $script:ModulePath = Join-Path $script:ToolRoot 'Get-HyperVVMCheckpointHealth.psm1'
        $script:ManifestPath = Join-Path $script:ToolRoot 'Get-HyperVVMCheckpointHealth.psd1'
        $script:AssessmentModulePath = Join-Path $script:ToolRoot 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        $script:CollectionModulePath = Join-Path $script:ToolRoot 'Private\Get-HyperVVMCheckpointHealth.Collection.psm1'
        $script:PolicyModulePath = Join-Path $script:ToolRoot 'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        $script:RenderingModulePath = Join-Path $script:ToolRoot 'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        $script:StorageModulePath = Join-Path $script:ToolRoot 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        $script:ReadmePath = Join-Path $script:ToolRoot 'README.md'
        $script:Source = Get-Content -LiteralPath $script:ModulePath -Raw
        $script:AssessmentSource = Get-Content -LiteralPath $script:AssessmentModulePath -Raw
        $tokens = $null
        $parseErrors = $null
        $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:ModulePath,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $script:ParseErrors = @($parseErrors)
    }

    It 'parses without PowerShell syntax errors' {
        $script:ParseErrors.Count | Should -Be 0
    }

    It 'requires Windows PowerShell 5.1 compatible syntax' {
        $script:Source | Should -Match '#Requires -Version 5\.1'
        $script:Source | Should -Not -Match '\?\?'
        $script:Source | Should -Not -Match '\?\.'
    }

    It 'does not array-wrap known generic lists to obtain their count' {
        $script:Source | Should -Not -Match '@\(\$diskReports\)\.Count'
        $script:Source | Should -Not -Match '@\(\$script:ExcludedMatched\)\.Count'
        $script:Source | Should -Not -Match '@\(\$script:DiscoveredCandidates\)\.Count'
    }

    It 'keeps the source and README versions synchronized' {
        $sourceVersion = [regex]::Match($script:Source, '(?m)^\$script:ScriptVersion\s*=\s*''([^'']+)''').Groups[1].Value
        $readme = Get-Content -LiteralPath $script:ReadmePath -Raw
        $readmeVersion = [regex]::Match($readme, '(?m)^- Version: ([0-9.]+)').Groups[1].Value
        $sourceVersion | Should -Not -BeNullOrEmpty
        $sourceVersion | Should -Be $readmeVersion
    }

    It 'declares core functions in their owning modules' {
        $functionNames = @($script:Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | ForEach-Object Name)
        $functionNames | Should -Contain 'Invoke-VMCheckpointAudit'
        $functionNames | Should -Contain 'Get-HistoricVMEventCorrelation'
        $functionNames | Should -Not -Contain 'ConvertTo-VMCheckpointAuditHtml'
        (Get-Content -LiteralPath $script:RenderingModulePath -Raw) | Should -Match 'function ConvertTo-VMCheckpointAuditHtml'
    }

    It 'uses the ranked discovery selector without a hard-coded default cap' {
        $script:Source | Should -Match 'Select-DiscoveredVMsForAudit\s+-Candidates'
        $script:Source | Should -Not -Match '\$script:MaxDiscoveredToAudit'
    }

    It 'records dedicated telemetry for new chain and discovery runtime work' {
        $script:Source | Should -Match '\$policyInitializationStart\s*=\s*Get-TelemetryNow'
        $script:Source | Should -Match 'Add-TelemetryEntry\s+-Step ''1\.05\.07''\s+-Phase ''Checkpoint health policy initialization''[\s\S]*?-StartUtc \$policyInitializationStart'
        $script:Source | Should -Not -Match '\$privateModuleImportStart'
        $script:Source | Should -Match 'if \(\$null -ne \$discoveredVMs -and \$discoveredVMs\.Count -gt 0\)'
        $script:Source | Should -Not -Match 'if \(@\(\$discoveredVMs\)\.Count -gt 0\)'
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.20\.10'\s+-Phase 'VHD chain collection and validation'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.65\.10'\s+-Phase 'Checkpoint staleness assessment'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.20'\s+-Phase 'Discovered VM validation and selection'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.35\.10'\s+-Phase 'Cluster virtual disk ownership inventory'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.35\.20'\s+-Phase 'Cluster virtual disk file inventory'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.35\.30'\s+-Phase 'Virtual disk housekeeping classification'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.35\.40'\s+-Phase 'Per-VM orphan candidate classification'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.45\.10'\s+-Phase 'HRL collection and cadence assessment'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.85'\s+-Phase 'Per-VM text report write'"
        $script:Source | Should -Match 'VirtualDiskInventory\s*=\s*\[pscustomobject\]'
    }

    It 'captures unrecovered failures with exact support links' {
        $script:Source | Should -Match 'function Add-AuditDiagnostic'
        $script:Source | Should -Match 'function Write-AuditDebugLog'
        $script:Source | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth#readme'
        $script:Source | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth-Feedback'
        $script:Source | Should -Match "-DiagnosticOperation 'Scan node-wide Worker/VMMS event logs'"
        $script:Source | Should -Match "-Operation 'Enumerate VMs on node \(fallback discovery\)'"
        $script:Source | Should -Match "-Operation 'Capture initial VM state token'"
        $script:Source | Should -Match "-Operation 'Capture final VM state token'"
        $script:Source | Should -Match "-Operation 'Write node-wide events CSV'"
    }

    It 'keeps node event scan failures distinct from successful empty results' {
        $script:Source | Should -Match '\$script:NodeEventCache\[\$nodeCacheKey\]\s*=\s*\[pscustomobject\]'
        $script:Source | Should -Not -Match '\$script:NodeEventCache\[\$nodeCacheKey\]\s*=\s*\$null'
        $script:Source | Should -Match 'EventCollectionStatus\s*=\s*\[pscustomobject\]'
    }

    It 'prevents unavailable event evidence from producing an unqualified clean verdict' {
        $script:Source | Should -Match '\$eventEvidenceUnavailable\s*=\s*\(\$eventCollectionStatus\.Status\s*-eq\s*''Unavailable''\)'
        $script:Source | Should -Match '-RequiredEvidenceUnavailable \$eventEvidenceUnavailable'
        $script:Source | Should -Match '\$investigate\s*=\s*\[bool\]\$verdictAssessment\.Investigate'
        $script:Source | Should -Match 'AssessmentConfidence\s*=\s*\[string\]\$assessmentConfidence'
        $script:Source | Should -Match 'CollectionStatus\s*=\s*\[pscustomobject\]'
    }

    It 'uses evidence labels that do not authorize virtual disk removal' {
        $script:Source | Should -Not -Match 'SafeToDelete'
        $script:Source | Should -Not -Match 'Likely SAFE to delete'
        $script:Source | Should -Match 'TransientDeleteLockObserved'
        $script:Source | Should -Match 'RollbackFingerprintCandidate'
    }

    It 'centralizes event decision policy and records its rule cardinalities' {
        $script:AssessmentSource | Should -Match 'function Get-HyperVEventPolicy'
        $script:Source | Should -Not -Match 'function Get-HyperVEventPolicy'
        $script:Source | Should -Match '\$script:EventPolicy\s*=\s*Get-HyperVEventPolicy'
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.05\.10'\s+-Phase 'Event policy initialization'"
        $script:Source | Should -Match '\$vmCriticalEvents\s*=\s*@\(\$vmConcernEvents\s*\|\s*Where-Object\s*\{\s*\$_\.IsConfirmingFork\s*\}\)'
        $script:Source | Should -Match '\$mergeFailIds\s*=\s*@\(\$script:EventPolicy\.MergeFailureIds\)'
    }

    It 'avoids quadratic array appends in high-volume remote collectors' {
        $script:Source | Should -Not -Match '\$result\s*\+=' 
        $script:Source | Should -Not -Match '\$rows\s*\+=' 
        $script:Source | Should -Not -Match '\$folders\s*\+=' 
        $script:Source | Should -Not -Match '\$out\s*\+=' 
        $script:Source | Should -Match '\$rows\.ToArray\(\)'
        $script:Source | Should -Match '\$out\.ToArray\(\)'
    }

    It 'rechecks VM state and makes changed collection state inconclusive' {
        $script:Source | Should -Match "Show-AuditProgress\s+-Step 80\s+-Status 'Rechecking VM collection state consistency'"
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.80\.10'\s+-Phase 'VM collection state consistency recheck'"
        $script:Source | Should -Match '\$stateChangedDuringCollection\s*=\s*\(\$stateConsistencyStatus\s*-eq\s*''Changed''\)'
        $script:Source | Should -Match '\$investigate\s*=\s*\$true'
        $script:Source | Should -Match 'StateConsistency\s*=\s*\[pscustomobject\]'
    }

    It 'supports mutually exclusive named and all-cluster VM selectors' {
        $script:Source | Should -Match "CmdletBinding\(DefaultParameterSetName = 'ByName'\)"
        $script:Source | Should -Match '(?s)ParameterSetName=''ByName''.+?\[object\[\]\]\$VMName'
        $script:Source | Should -Match 'ParameterSetName=''AllVMs''\)\]\s*\[switch\]\$ProcessAllVMs'
        $script:Source | Should -Match 'Get-ClusterGroup -Cluster \$resolvedClusterName -ErrorAction Stop'
        $script:Source | Should -Match "Phase 'Process all clustered VMs selection'"
    }

    It 'keeps clean text guidance distinct from review-only housekeeping' {
        $script:Source | Should -Match 'No VM-health action required from this result'
        $script:Source | Should -Match 'Review the separate cluster / storage housekeeping observations in the HTML report'
        $script:Source | Should -Match '\$script:HousekeepingFindings\.Count\s+-gt\s+0'
    }

    It 'mentions unhealthy VSS in INVESTIGATE guidance only when unhealthy writers were collected' {
        $script:Source | Should -Match '(?s)if \(\$vssUnhealthy\.Count -gt 0\) \{\s+Write-AuditReportLine\s+"  evidence is more consistent with a stalled / failed backup checkpoint involving unhealthy"\s+Write-AuditReportLine\s+"  VSS writers than on-disk chain corruption.*?\} else \{\s+Write-AuditReportLine\s+"  evidence is more consistent with a stalled / failed backup checkpoint or another operational"\s+Write-AuditReportLine\s+"  checkpoint workflow than on-disk chain corruption'
        $script:Source | Should -Match '(?s)if \(\$vssUnhealthy\.Count -gt 0\) \{\s+Write-Alert\s+"  was NOT observed \(evidence is more consistent with a stalled / failed backup checkpoint".*?"  involving unhealthy VSS writers than on-disk chain corruption\).*?\} else \{\s+Write-Alert\s+"  was NOT observed \(evidence is more consistent with a stalled / failed backup checkpoint".*?"  or another operational checkpoint workflow than on-disk chain corruption\)."'
        $script:Source | Should -Not -Match 'likely cause is a stalled / failed backup checkpoint or an unhealthy VSS writer rather than'
        $script:Source | Should -Not -Match 'likely a stalled / failed backup checkpoint or an unhealthy VSS writer'
    }

    It 'preserves exact file metadata for housekeeping totals and filtering' {
        $script:Source | Should -Match 'Length\s+=\s+\[long\]\$diskFile\.Length'
        $script:Source | Should -Match 'FullName\s+=\s+\[string\]\$diskFile\.FullName'
        $script:Source | Should -Match 'ParentPath\s+=\s+\[string\]\(Split-Path'
        $script:Source | Should -Match 'CsvRoot\s+=\s+\[string\]\$diskFile\.CsvRoot'
    }

    It 'prewarms cluster-wide virtual disk inventories before per-VM iteration' {
        $prewarmCall = $script:Source.LastIndexOf('Initialize-ClusterVirtualDiskInventories -Cluster $Cluster')
        $vmLoop = $script:Source.LastIndexOf('foreach ($name in $script:PendingVMNames)')
        $prewarmCall | Should -BeGreaterThan 0
        $vmLoop | Should -BeGreaterThan $prewarmCall
        $script:Source | Should -Match 'DurationMs\s+=\s+\[long\]\$nodeStopwatch\.ElapsedMilliseconds'
        $script:Source | Should -Match 'DurationMs\s+=\s+\[long\]\$rootStopwatch\.ElapsedMilliseconds'
        $script:Source | Should -Match 'parentPathByVhd\.ContainsKey\(\$cursor\)'
        $script:Source | Should -Match 'vhdWithoutParent\.Contains\(\$cursor\)'
        $script:Source | Should -Match "Add-TelemetryEntry -Step '1\.07' -Phase 'Cluster virtual disk inventory preflight \(total\)'"
        $script:Source | Should -Match "DiagnosticOperation 'Enumerate cluster shared volumes for inventory preflight'"
        $script:Source | Should -Match "DiagnosticOperation 'Invoke ownership inventory on cluster node'"
        $script:Source | Should -Match "DiagnosticOperation 'Invoke virtual-disk file inventory on cluster node'"
        $script:Source | Should -Match 'Add-AuditDiagnosticMessage -Message \(\[string\]\$collectionError\)'
        $script:Source | Should -Match 'Add-AuditDiagnosticMessage -Message \(\[string\]\$pathError\.Error\)'
        $script:Source | Should -Match 'Scope \("Node=\{0\}; Path=\{1\}" -f \$TargetNode, \$pathError\.Path\)'
    }

    It 'times and retry-protects Replica monitoring settings collection' {
        $script:Source | Should -Match "Add-TelemetryEntry -Step '1\.10\.40\.05' -Phase 'Replica relationship and monitoring collection'"
        $script:Source | Should -Match "DiagnosticOperation 'Collect Hyper-V Replica monitoring settings'"
        $script:Source | Should -Match 'AttemptCount \(\[ref\]\$replicationServerAttempts\)'
        $script:Source | Should -Not -Match '(?s)Get-VMReplicationServer -ErrorAction Stop.*?catch\s*\{\s*\[pscustomobject\]'
    }

    It 'keeps all target-cluster runtime commands read-only' {
        $runtimeFiles = @($script:ModulePath) + @(Get-ChildItem -LiteralPath (Join-Path $script:ToolRoot 'Private') -Filter '*.psm1' -File | ForEach-Object { $_.FullName })
        $forbiddenCommands = [System.Collections.Generic.List[string]]::new()
        foreach ($runtimeFile in $runtimeFiles) {
            $runtimeTokens = $null
            $runtimeErrors = $null
            $runtimeAst = [System.Management.Automation.Language.Parser]::ParseFile($runtimeFile, [ref]$runtimeTokens, [ref]$runtimeErrors)
            @($runtimeErrors).Count | Should -Be 0
            $commands = @($runtimeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))
            foreach ($command in $commands) {
                $commandName = $command.GetCommandName()
                if ($commandName -and $commandName -match '^(Set|Start|Stop|Restart|Remove|New|Checkpoint|Restore|Merge|Optimize|Repair|Update)-(VM|VHD|Cluster|Storage|PhysicalDisk|VirtualDisk|Volume|VSS|Service|WinEvent)') {
                    [void]$forbiddenCommands.Add(('{0}: {1}' -f (Split-Path $runtimeFile -Leaf), $commandName))
                }
                if ($commandName -in @('Clear-EventLog', 'wevtutil.exe', 'diskshadow.exe')) {
                    [void]$forbiddenCommands.Add(('{0}: {1}' -f (Split-Path $runtimeFile -Leaf), $commandName))
                }
            }
        }
        $forbiddenCommands.ToArray() | Should -BeNullOrEmpty
    }

    It 'caches cluster roles and Analytic status once per run' {
        $script:Source | Should -Match '\$script:ClusterGroupByVm\[\[string\]\$g\.Name\]\s*=\s*\[pscustomobject\]'
        $script:Source | Should -Match '\$group\s*=\s*if \(\$script:ClusterGroupByVm\.ContainsKey\(\$VMName\)\)'
        $script:Source | Should -Match '\$script:AnalyticStatusCache\s*=\s*@\(Invoke-Command'
        $script:Source | Should -Match "Add-TelemetryEntry\s+-Step '1\.10\.55\.10'\s+-Phase 'Analytic channel status \(once per run\)'"
    }

    It 'warns that report artifacts are sensitive and the ZIP is unencrypted' {
        $script:Source | Should -Match 'SENSITIVE DATA: audit artifacts can contain'
        $script:Source | Should -Match 'The ZIP bundle is NOT encrypted'
        $script:Source | Should -Match '-AnonymizeTelemetry affects only performance telemetry'
    }

    It 'declares private implementation modules in the manifest with no duplicate root helpers' {
        foreach ($privateModulePath in @($script:AssessmentModulePath, $script:CollectionModulePath, $script:PolicyModulePath, $script:RenderingModulePath, $script:StorageModulePath)) {
            Test-Path $privateModulePath | Should -BeTrue
        }
        $manifest = Import-PowerShellDataFile -LiteralPath $script:ManifestPath
        @($manifest.NestedModules).Count | Should -Be 5
        $manifest.NestedModules | Should -Contain 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        $manifest.NestedModules | Should -Contain 'Private\Get-HyperVVMCheckpointHealth.Collection.psm1'
        $manifest.NestedModules | Should -Contain 'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        $manifest.NestedModules | Should -Contain 'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        $manifest.NestedModules | Should -Contain 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        $script:AssessmentSource | Should -Match "'EnabledEmpty'"
        $script:AssessmentSource | Should -Match "'Disabled'"
        $script:AssessmentSource | Should -Match '\$sufficient\s*=\s*\(\$status\s*-in'
        $script:Source | Should -Match '\$ExecutionContext\.SessionState\.Module\.NestedModules'
        $script:Source | Should -Not -Match 'Import-Module \$(assessment|collection|policy)ModulePath'
        foreach ($helperName in @(
            'Get-HyperVEventPolicy', 'Get-HyperVEventSignalAssessment', 'Resolve-HyperVOperationRecovery',
            'Get-VMCollectionStateToken', 'Compare-VMCollectionStateToken', 'Get-HyperVReplicationAssessment',
            'Resolve-HyperVEventAttribution', 'Resolve-EventCoverage', 'Select-DiscoveredVMsForAudit',
            'Resolve-ActiveCheckpointHistoricVerdict', 'ConvertTo-VMCheckpointAuditHtml', 'Get-VHDChainReport',
            'Get-CheckpointStalenessAssessment', 'Resolve-AvhdxOwnership',
            'Get-VMOrphanCandidatesFromClusterInventory', 'Get-VirtualDiskHousekeepingClassification',
            'Get-ClusterStorageHealthSnapshot'
        )) {
            $script:Source | Should -Not -Match ("function\s+{0}\b" -f [regex]::Escape($helperName))
        }
    }
}

Describe 'Checkpoint health policy fixtures' {
    BeforeAll {
        $policyModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        Import-Module $policyModulePath -Force
    }

    It 'preserves built-in path behavior and keeps CSV verdict policy disabled by default' {
        $policy = Get-CheckpointHealthDefaultPolicy
        $policy.SchemaVersion | Should -Be 1
        $policy.CsvFreeSpace.Enabled | Should -BeFalse
        $policy.CsvFreeSpace.MinimumFreePercent | Should -Be 15
        $policy.CsvFreeSpace.MinimumFreeGB | Should -Be 100
        $policy.Orphan.ClassifyZeroByteAsLiveMount | Should -BeTrue
        $policy.Replication.Hrl.Enabled | Should -BeTrue
        $policy.Replication.Hrl.CadenceMultiplier | Should -Be 10
        $policy.Replication.Hrl.MinimumStaleMinutes | Should -Be 15
        $policy.Replication.Hrl.RequireReplicationConcern | Should -BeTrue
        Test-CheckpointHealthPathPattern -Path 'C:\ClusterStorage\Volume1\Images\base.vhdx' -Patterns $policy.Storage.ImageLibraryPathPatterns | Should -BeTrue
        Test-CheckpointHealthPathPattern -Path 'C:\ClusterStorage\Volume1\ImageStore\base.vhdx' -Patterns $policy.Storage.ImageLibraryPathPatterns | Should -BeTrue
        Test-CheckpointHealthPathPattern -Path 'C:\ClusterStorage\Volume1\rubriklivemount\disk.avhdx' -Patterns $policy.Orphan.LiveMountPathPatterns | Should -BeTrue
        $script:Source | Should -Not -Match 'rubriklivemount|_temp_'
        $script:Source | Should -Not -Match "ImageLibraryPathPatterns\s*=\s*@\('"
        $policyModule = Get-Module Get-HyperVVMCheckpointHealth.Policy
        $emptyArrayProperty = & $policyModule {
            Get-CheckpointHealthPolicyProperty -Object ([ordered]@{ Patterns = @() }) -Name 'Patterns'
        }
        $emptyArrayProperty.Exists | Should -BeTrue
        @($emptyArrayProperty.Value).Count | Should -Be 0
    }

    It 'flags configured CSV percentage or absolute free-space breaches only when enabled' {
        $volumes = @([pscustomobject]@{ Volume = 'CSV01'; FreePct = 20; FreeGB = 50 })
        $disabled = Get-CsvFreeSpaceAssessment -Volumes $volumes -Policy ([pscustomobject]@{ Enabled = $false; MinimumFreePercent = 15; MinimumFreeGB = 100 })
        $enabled = Get-CsvFreeSpaceAssessment -Volumes $volumes -Policy ([pscustomobject]@{ Enabled = $true; MinimumFreePercent = 15; MinimumFreeGB = 100 })
        $disabled.IsConcern | Should -BeFalse
        $enabled.IsConcern | Should -BeTrue
        @($enabled.Breaches).Count | Should -Be 1
    }

    It 'derives HRL age from cadence and requires independent Replica corroboration by default' {
        $policy = (Get-CheckpointHealthDefaultPolicy).Replication.Hrl
        $file = [pscustomobject]@{ Name = 'disk.hrl'; FullName = 'C:\VMs\disk.hrl'; Length = 1; LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-60) }
        $healthy = Get-HrlCadenceAssessment -Files @($file) -ReplicationEnabled $true -FrequencySeconds 300 -ReplicationConcern $false -Policy $policy
        $unhealthy = Get-HrlCadenceAssessment -Files @($file) -ReplicationEnabled $true -FrequencySeconds 300 -ReplicationConcern $true -Policy $policy
        $healthy.ThresholdMinutes | Should -Be 50
        $healthy.ExceedsCadenceCount | Should -Be 1
        $healthy.IsConcern | Should -BeFalse
        $unhealthy.IsConcern | Should -BeTrue
        $unhealthy.CorroboratedByReplication | Should -BeTrue
    }
}

Describe 'VM checkpoint verdict assessment fixtures' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $modulePath -Force
    }

    It 'maps <Case> evidence to <Expected>' -TestCases @(
        @{ Case = 'complete clean'; Parameters = @{}; Expected = 'OK' }
        @{ Case = 'stale evidence'; Parameters = @{ HasStaleEvidence = $true }; Expected = 'INVESTIGATE' }
        @{ Case = 'confirming fork with attached layer'; Parameters = @{ ConfirmingForkSignature = $true; HasAttachedLayers = $true }; Expected = 'HOLD STATE' }
        @{ Case = 'required evidence unavailable'; Parameters = @{ RequiredEvidenceUnavailable = $true }; Expected = 'INVESTIGATE' }
        @{ Case = 'state changed during collection'; Parameters = @{ StateInconclusive = $true }; Expected = 'INVESTIGATE' }
    ) {
        param($Case, $Parameters, $Expected)

        $assessment = Get-VMCheckpointVerdictAssessment @Parameters
        $assessment.Recommendation | Should -Be $Expected
    }
}

Describe 'Active-checkpoint historic verdict fixtures' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $modulePath -Force
    }

    It 'promotes confirmed fork evidence on a still-active checkpoint to HOLD STATE' {
        $result = Resolve-ActiveCheckpointHistoricVerdict -HoldState:$false -Investigate:$true `
            -LowSignalOnly:$false -SeverityScore 65 -ForkConfirmed:$true -CoverageIncomplete:$false

        $result.HoldState | Should -BeTrue
        $result.Investigate | Should -BeFalse
        $result.LowSignalOnly | Should -BeFalse
        $result.SeverityScore | Should -Be 100
    }

    It 'keeps incomplete historic coverage as INVESTIGATE rather than HOLD STATE' {
        $result = Resolve-ActiveCheckpointHistoricVerdict -HoldState:$false -Investigate:$false `
            -LowSignalOnly:$true -SeverityScore 5 -ForkConfirmed:$false -CoverageIncomplete:$true

        $result.HoldState | Should -BeFalse
        $result.Investigate | Should -BeTrue
        $result.LowSignalOnly | Should -BeFalse
        $result.SeverityScore | Should -Be 55
    }

    It 'preserves the existing verdict when historic coverage is complete and no fork is found' {
        $result = Resolve-ActiveCheckpointHistoricVerdict -HoldState:$false -Investigate:$false `
            -LowSignalOnly:$false -SeverityScore 0 -ForkConfirmed:$false -CoverageIncomplete:$false

        $result.HoldState | Should -BeFalse
        $result.Investigate | Should -BeFalse
        $result.SeverityScore | Should -Be 0
    }
}

Describe 'Module distribution contracts' {
    BeforeAll {
        $script:ModuleRoot = Split-Path $PSScriptRoot -Parent
        $script:ManifestPath = Join-Path $script:ModuleRoot 'Get-HyperVVMCheckpointHealth.psd1'
        $script:ModuleSourcePath = Join-Path $script:ModuleRoot 'Get-HyperVVMCheckpointHealth.psm1'
        $script:Manifest = Test-ModuleManifest -Path $script:ManifestPath -ErrorAction Stop
        Import-Module $script:ManifestPath -Force -ErrorAction Stop
        $script:ModuleCommand = Get-Command Get-HyperVVMCheckpointHealth -Module Get-HyperVVMCheckpointHealth
    }

    It 'imports a valid 0.2.19 module manifest' {
        $script:Manifest.Version.ToString() | Should -Be '0.2.19'
        $script:Manifest.ExportedFunctions.Keys | Should -Contain 'Get-HyperVVMCheckpointHealth'
    }

    It 'keeps manifest and module versions synchronized' {
        $moduleSource = Get-Content -LiteralPath $script:ModuleSourcePath -Raw
        $moduleVersion = [regex]::Match($moduleSource, '(?m)^\$script:ScriptVersion\s*=\s*''([^'']+)''').Groups[1].Value
        $script:Manifest.Version.ToString() | Should -Be $moduleVersion
    }

    It 'attaches all private modules without exporting their helper commands' {
        $module = Get-Module Get-HyperVVMCheckpointHealth
        @($module.NestedModules | ForEach-Object Name | Sort-Object) | Should -Be @(
            'Get-HyperVVMCheckpointHealth.Assessment'
            'Get-HyperVVMCheckpointHealth.Collection'
            'Get-HyperVVMCheckpointHealth.Policy'
            'Get-HyperVVMCheckpointHealth.Rendering'
            'Get-HyperVVMCheckpointHealth.Storage'
        )
        @($module.ExportedFunctions.Keys) | Should -Be @('Get-HyperVVMCheckpointHealth')
        & $module {
            foreach ($helperName in @('Get-HyperVEventPolicy', 'Get-VMCollectionStateToken', 'Get-CheckpointHealthDefaultPolicy', 'ConvertTo-VMCheckpointAuditHtml', 'Get-VHDChainReport')) {
                Get-Command $helperName -CommandType Function -ErrorAction Stop | Should -Not -BeNullOrEmpty
            }
        }
    }

    It 'rejects execution after importing the bare root module' {
        Remove-Module Get-HyperVVMCheckpointHealth -Force -ErrorAction SilentlyContinue
        try {
            Import-Module $script:ModuleSourcePath -Force -ErrorAction Stop
            { Get-HyperVVMCheckpointHealth -VMName 'TEST-MANIFEST-GUARD' -NoHtml -NoZip -SkipStorageHealth -ErrorAction Stop } |
                Should -Throw '*not loaded through its module manifest*Import-Module*Get-HyperVVMCheckpointHealth.psd1*'
        } finally {
            Remove-Module Get-HyperVVMCheckpointHealth -Force -ErrorAction SilentlyContinue
            Import-Module $script:ManifestPath -Force -ErrorAction Stop
        }
    }

    It 'rejects a staged package missing a declared private module' {
        $stagedRoot = Join-Path $TestDrive 'IncompleteModule'
        Copy-Item -LiteralPath $script:ModuleRoot -Destination $stagedRoot -Recurse
        Remove-Item -LiteralPath (Join-Path $stagedRoot 'Private\Get-HyperVVMCheckpointHealth.Collection.psm1') -Force
        { Test-ModuleManifest -Path (Join-Path $stagedRoot 'Get-HyperVVMCheckpointHealth.psd1') -ErrorAction Stop } |
            Should -Throw '*Get-HyperVVMCheckpointHealth.Collection.psm1*'
    }

    It 'uses explicit report and status writers without overriding Write-Host' {
        $moduleSource = Get-Content -LiteralPath $script:ModuleSourcePath -Raw
        $moduleSource | Should -Match '(?m)^function Write-AuditReportLine \{'
        $moduleSource | Should -Match '(?m)^function Write-AuditStatus \{'
        $moduleSource | Should -Not -Match '(?m)^function Write-Host \{'
    }

    It 'exports the complete command parameter surface' {
        $expectedParameters = @(
            'VMName', 'Cluster', 'OutputPath', 'IncludeDiscoveredVMs', 'MaxDiscoveredVMs',
            'ExcludedVMListCsv', 'PolicyPath', 'StaleHours', 'SkipWorkerEvents', 'EventLookbackHours',
            'WorkerEventIds', 'ContextEventIds', 'ErrorCodePatterns', 'MaxReplicationAgeMinutes',
            'MaxPendingReplicationMB', 'MaxReplicationLatencySeconds', 'MaxMissedReplicationCount',
            'MaxReplicationAgeCycles', 'MaxPendingReplicationCycles', 'MaxReplicationLatencyCycles',
            'MaxMissedReplicationRatePercent', 'MinMissedReplicationCountForConcern',
            'SkipAnalyticCheck', 'NoColour', 'PassThru', 'HtmlReportPath', 'NoHtml', 'Quiet',
            'NoZip', 'SkipStorageHealth', 'AnonymizeTelemetry'
        )
        foreach ($parameterName in $expectedParameters) {
            $script:ModuleCommand.Parameters.Keys | Should -Contain $parameterName
        }
        $script:ModuleCommand.Parameters['VMName'].Aliases | Should -Contain 'VM'
        $script:ModuleCommand.Parameters['NoColour'].Aliases | Should -Contain 'NoColor'
    }

    It 'retains every runtime file required by the module' {
        @(
            'Get-HyperVVMCheckpointHealth.psd1',
            'Get-HyperVVMCheckpointHealth.psm1',
            'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1',
            'Private\Get-HyperVVMCheckpointHealth.Collection.psm1',
            'Private\Get-HyperVVMCheckpointHealth.Policy.psm1',
            'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1',
            'Private\Get-HyperVVMCheckpointHealth.Storage.psm1',
            'checkpoint-health-policy.example.yml'
        ) | ForEach-Object {
            Test-Path -LiteralPath (Join-Path $script:ModuleRoot $_) -PathType Leaf | Should -BeTrue
        }
    }

    It 'has no duplicate compatibility script entry point' {
        Test-Path -LiteralPath (Join-Path $script:ModuleRoot 'Get-HyperVVMCheckpointHealth.ps1') | Should -BeFalse
    }

    It 'ships a reproducible release packager with an explicit runtime allow-list' {
        $buildPath = Join-Path $script:ModuleRoot 'Build-Release.ps1'
        Test-Path -LiteralPath $buildPath -PathType Leaf | Should -BeTrue
        $buildSource = Get-Content -LiteralPath $buildPath -Raw
        $buildSource | Should -Match 'Test-ModuleManifest'
        $buildSource | Should -Match 'Get-HyperVVMCheckpointHealth\.Assessment\.psm1'
        $buildSource | Should -Match 'Get-HyperVVMCheckpointHealth\.Collection\.psm1'
        $buildSource | Should -Match 'Get-HyperVVMCheckpointHealth\.Policy\.psm1'
        $buildSource | Should -Match 'Get-HyperVVMCheckpointHealth\.Rendering\.psm1'
        $buildSource | Should -Match 'Get-HyperVVMCheckpointHealth\.Storage\.psm1'
        $buildSource | Should -Match 'checkpoint-health-policy\.example\.yml'
        $buildSource | Should -Match 'Get-FileHash.+SHA256'
        $buildSource | Should -Not -Match 'Setup-Get-HyperVVMCheckpointHealth\.ps1'
    }

    It 'provides an external hash-pinned setup script that installs without running an audit' {
        $setupPath = Join-Path $script:ModuleRoot 'Setup-Get-HyperVVMCheckpointHealth.ps1'
        Test-Path -LiteralPath $setupPath -PathType Leaf | Should -BeTrue
        $setupSource = Get-Content -LiteralPath $setupPath -Raw
        $setupSource | Should -Match "\$version = '0\.2\.19'"
        $setupSource | Should -Match "\$expectedSha256 = '[0-9a-f]{64}'"
        $setupSource | Should -Match '\[string\]\$InstallRoot = ''C:\\Temp'''
        $setupSource | Should -Match 'Get-FileHash.+SHA256'
        $setupSource | Should -Match 'Test-ModuleManifest'
        $setupSource | Should -Not -Match 'Get-ClusterGroup'
        $setupSource | Should -Not -Match '& \$moduleName -VMName'
        $setupSource | Should -Not -Match 'Remove-Item \$installRoot'
    }

    It 'documents the module ZIP as the supported installation unit' {
        $readme = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'README.md') -Raw
        $readme | Should -Match 'Download and import the module'
        $readme | Should -Match 'single exported command'
        $readme | Should -Match 'Setup-Get-HyperVVMCheckpointHealth\.ps1'
        $readme | Should -Match 'setup script remains outside the ZIP'
        $readme | Should -Not -Match '(?<!Setup-)Get-HyperVVMCheckpointHealth\.ps1'
    }

    It 'documents exporting exact VM image exclusions into new and existing policies' {
        $readme = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'README.md') -Raw
        $readme | Should -Match 'Export VM image exclusions from the HTML report'
        $readme | Should -Match 'available only for `\.vhd` and `\.vhdx` base-disk candidates; it is never offered for `\.avhdx`'
        $readme | Should -Match 'For a new policy, paste the complete generated `schemaVersion`, `storage`, and `imageLibraryPathPatterns` block'
        $readme | Should -Match 'For an existing policy, copy only the generated.*entries into its existing `storage\.imageLibraryPathPatterns` array'
        $readme | Should -Match 'repeat the original audit command with `-PolicyPath ''\.\\checkpoint-health-policy\.yml''`'
        $readme | Should -Match '`storage\.imageLibraryPathPatterns` is a replacement array'
    }

    It 'documents current historic coverage and HTML card semantics' {
        $readme = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'README.md') -Raw
        $readme | Should -Match 'required-channel coverage check'
        $readme | Should -Match 'Wrapped.+Disabled.+Unavailable'
        $readme | Should -Match 'EnabledEmpty.+sufficient coverage'
        $readme | Should -Match 'optional VMMS Analytic channel is excluded'
        $readme | Should -Match 'full-width \*\*VM\(s\) audited\*\* card'
        $readme | Should -Match 'Orphaned \.avhdx.+far right'
        $readme | Should -Not -Match 'cannot confirm \(logs wrapped\)'
    }
}

Describe 'Shippable content safety' {
    BeforeAll {
        $script:ToolRoot = Split-Path $PSScriptRoot -Parent
        $script:ShipFiles = @(Get-ChildItem -LiteralPath $script:ToolRoot -Recurse -File |
            Where-Object {
                $_.FullName -notmatch '\\specs\\' -and
                $_.FullName -notmatch '\\pester-testing\\results\\' -and
                $_.Extension -in @('.ps1', '.psm1', '.psd1', '.md', '.json', '.csv', '.txt', '.yml', '.yaml')
            })
        $script:EmailRegex = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
        $script:GuidRegex = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $script:AllowedEmailDomains = @('example.com', 'example.org', 'example.net', 'contoso.com')
    }

    It 'contains no non-example email addresses' {
        $offenders = foreach ($file in $script:ShipFiles) {
            foreach ($match in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), $script:EmailRegex)) {
                $domain = ($match.Value -split '@', 2)[1].ToLowerInvariant()
                if ($script:AllowedEmailDomains -notcontains $domain) {
                    '{0}: {1}' -f $file.FullName, $match.Value
                }
            }
        }
        @($offenders).Count | Should -Be 0 -Because (@($offenders) -join [Environment]::NewLine)
    }

    It 'contains no real-looking GUIDs in tests or documentation' {
        $filesToCheck = @($script:ShipFiles | Where-Object {
            $_.FullName -notin @(
                (Join-Path $script:ToolRoot 'Get-HyperVVMCheckpointHealth.psm1'),
                (Join-Path $script:ToolRoot 'Get-HyperVVMCheckpointHealth.psd1')
            )
        })
        $offenders = foreach ($file in $filesToCheck) {
            foreach ($match in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), $script:GuidRegex)) {
                $hex = $match.Value.Replace('-', '').ToLowerInvariant()
                if ((@($hex.ToCharArray() | Select-Object -Unique)).Count -gt 1) {
                    '{0}: {1}' -f $file.FullName, $match.Value
                }
            }
        }
        @($offenders).Count | Should -Be 0 -Because (@($offenders) -join [Environment]::NewLine)
    }

    It 'contains no common hard-secret formats' {
        $secretPattern = '-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----|\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bAKIA[0-9A-Z]{16}\b|AccountKey\s*=\s*[A-Za-z0-9+/]{60,}={0,2}'
        $offenders = foreach ($file in $script:ShipFiles) {
            if (Select-String -LiteralPath $file.FullName -Pattern $secretPattern -Quiet) {
                $file.FullName
            }
        }
        @($offenders).Count | Should -Be 0 -Because (@($offenders) -join [Environment]::NewLine)
    }
}

Describe 'HTML fleet report usability' {
    BeforeAll {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        $renderingModulePath = Join-Path $toolRoot 'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        Import-Module $renderingModulePath -Force

        $normalReportData = [pscustomobject]@{
            State = 'Running'; Status = 'Operating normally'; Version = '12.0'; HostMaxVersion = '12.0'
            VmVerOlder = $false; Uptime = '1.00:00:00'; CheckpointType = 'Production'
            AutomaticCheckpoints = $false; AttachedDiskCount = 1; CheckpointLayers = 0
            Checkpoints = @(); StaleCheckpointCount = 0; StaleHours = 24
            StaleAttachedLayerCount = 0; StaleSnapshotCount = 0; SnapshotLayerMismatch = $false
            AttachedVhdLayers = @()
            Replication = [pscustomobject]@{
                Enabled = $true; State = 'Replicating'; Health = 'Normal'; Mode = 'Primary'
                Primary = 'TEST-NODE-01'; Replica = 'TEST-REPLICA-01'; LastReplicationTime = '2026-01-01 09:59:00'
            }
            VssState = 'Healthy'; VssTotal = 10; VssUnhealthyCount = 0; VssUnhealthy = @()
            AnalyticNodesNeedEnable = @(); CsvVolumes = @(); OrphanCount = 0; Orphans = @()
            HasOrphans = $false; HasForkSignature = $false; EventConcernCount = 0
            VmEventConcernCount = 0; EventBreakdown = @(); EventLookbackHours = 168
            EventsCsvName = ''; NodeEventsCsvName = ''; SupportCaseSummary = ''
            VmHighConcernCount = 0; VmLowConcernCount = 0; VmCriticalCount = 0
            VmHighOpCount = 0; VmEscalatingConcernCount = 0; HighOpSelfResolved = $false
            VmHighConcernIds = ''; LowSignalOnly = $false; NodeDominantNote = ''
            ReplHealth = 'Normal'; ReplUnhealthy = $false; ReplAdvisory = $false; ReplCritical = $false
            ReplAssessment = [pscustomobject]@{
                Severity = 'Healthy'; ProductSeverity = 'Healthy'; MeasurementStatus = 'Healthy'
                State = 'Replicating'; Health = 'Normal'; IsConcern = $false; HasAdvisory = $false; IsCritical = $false
                Mode = 'Primary'; Reason = 'Hyper-V Replica reports Normal health with an available state.'
                MeasurementsAvailable = $true; LastReplicationTimeUtc = [datetime]'2026-01-01T09:59:00Z'
                PendingBytes = 0; EffectiveMaxPendingBytes = 1GB; LatencySeconds = 0; EffectiveMaxLatencySeconds = 600
                MissedCount = 0; MissedRatePercent = 0; LastReplicationAgeMinutes = 1; EffectiveMaxAgeMinutes = 60
                FrequencySeconds = 300; AverageReplicationBytes = 64MB; SuccessfulCount = 120
                MonitoringIntervalSeconds = 3600; MaxMissedRatePercent = 10
                ConcernBreaches = @(); AdvisoryBreaches = @(); ThresholdBreaches = @()
            }
            SeverityScore = 0; HasRollbackFingerprint = $false; RollbackDate = ''
            HasStuckMergeOrphan = $false; OrphanOnlyLiveMount = $false
            HistoricForkConfirmed = $false; Historic = $null; ActiveCkptForkConfirmed = $false
            ActiveCkptLogsWrapped = $false; ActiveCkptCoverageIncomplete = $false; CannotConfirmMigrationSafe = $false
            ActiveCkptOldestCreateUtc = ''; ActiveCkptOldestAvailUtc = ''; ActiveCkptHistoric = $null
        }
        $criticalReportData = $normalReportData.PSObject.Copy()
        $criticalReportData.Replication = [pscustomobject]@{
            Enabled = $true; State = 'Error'; Health = 'Critical'; Mode = 'Primary'
            Primary = 'TEST-NODE-02'; Replica = 'TEST-REPLICA-02'; LastReplicationTime = '2026-01-01 09:59:00'
        }
        $criticalReportData.ReplHealth = 'Critical'
        $criticalReportData.ReplUnhealthy = $true
        $criticalReportData.ReplCritical = $true
        $criticalReportData.ReplAssessment = [pscustomobject]@{
            Severity = 'Critical'; ProductSeverity = 'Critical'; MeasurementStatus = 'Healthy'
            State = 'Error'; Health = 'Critical'; IsConcern = $true; HasAdvisory = $false; IsCritical = $true
            Mode = 'Primary'; Reason = 'Hyper-V Replica health is Critical.'
            MeasurementsAvailable = $true; LastReplicationTimeUtc = [datetime]'2026-01-01T09:59:00Z'
            PendingBytes = 0; EffectiveMaxPendingBytes = 1GB; LatencySeconds = 0; EffectiveMaxLatencySeconds = 600
            MissedCount = 0; MissedRatePercent = 0; LastReplicationAgeMinutes = 1; EffectiveMaxAgeMinutes = 60
            FrequencySeconds = 300; AverageReplicationBytes = 64MB; SuccessfulCount = 120
            MonitoringIntervalSeconds = 3600; MaxMissedRatePercent = 10
            ConcernBreaches = @(); AdvisoryBreaches = @(); ThresholdBreaches = @()
        }
        $criticalReportData.SeverityScore = 60
        $staleLayerReportData = $normalReportData.PSObject.Copy()
        $staleLayerReportData.CheckpointLayers = 1
        $staleLayerReportData.StaleAttachedLayerCount = 1
        $staleLayerReportData.SnapshotLayerMismatch = $true
        $staleLayerReportData.AttachedVhdLayers = @(
            [pscustomobject]@{
                Disk = 'TEST-VM-STALE-LAYER_OS.avhdx'; Layer = 1; Type = 'Differencing'; SizeGB = 8.5
                Created = '2025-12-29 10:00:00'; LastWrite = '2025-12-30 10:00:00'; AgeHrs = 38; Stale = $true
                Path = 'C:\ClusterStorage\Volume1\TEST-VM-STALE-LAYER_OS.avhdx'
                ParentPath = 'C:\ClusterStorage\Volume1\TEST-VM-STALE-LAYER_OS.vhdx'
            }
        )
        $staleLayerReportData.SeverityScore = 70

        $results = @(
            [pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }
            [pscustomobject]@{ VMName = 'TEST-VM-REPLICA'; OwningNode = 'TEST-NODE-02'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $criticalReportData; Detail = '' }
            [pscustomobject]@{ VMName = 'TEST-VM-STALE-LAYER'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; StaleAttachedLayerCount = 1; ReportData = $staleLayerReportData; Detail = '' }
            [pscustomobject]@{ VMName = 'TEST-VM-MISSING'; OwningNode = ''; Recommendation = 'NOT FOUND'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $null; Detail = 'Synthetic VM was not found.' }
        )
        $discoverySummary = [pscustomobject]@{
            EligibleCount = 3; AuditedCount = 2; DeferredCount = 1; Cap = 2
        }
        $script:RenderedHtml = ConvertTo-VMCheckpointAuditHtml -Results $results -StaleHours 24 `
            -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs @([pscustomobject]@{ Name = 'TEST-VM-DEFERRED'; Reason = 'Synthetic deferred evidence' }) `
            -DiscoverySummary $discoverySummary -StorageHealth $null -IncludeDiscoveredVMs:$true -ScriptVersion '0.2.19' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1 `
            -HousekeepingFindings @(
                [pscustomobject]@{
                    Category = 'Placement inconsistency'; Scope = 'TEST-VM-NORMAL'
                    FileName = 'Data<review>.vhdx'
                    FullName = 'C:\ClusterStorage\Volume1\TEST-VM-NORMAL\Data<review>.vhdx'
                    ParentPath = 'C:\ClusterStorage\Volume1\TEST-VM-NORMAL'
                    CsvRoot = 'C:\ClusterStorage\Volume1'; Extension = '.vhdx'; Length = 1572864
                    Observation = 'Attached disk is stored under another VM folder <review>'
                    Review = 'Confirm the intended storage layout.'
                }
                [pscustomobject]@{
                    Category = 'Inventory coverage'; Scope = 'TEST-NODE-02'
                    FileName = ''
                    Observation = 'The node inventory query did not complete.'
                    Review = 'Review the debug log before rerunning the audit.'
                }
                [pscustomobject]@{
                    Category = 'Unattached base disk candidate'; Scope = 'C:\ClusterStorage\Volume1'
                    FileName = 'BaseImage.vhdx'
                    FullName = 'C:\ClusterStorage\Volume1\BaseImage.vhdx'
                    ParentPath = 'C:\ClusterStorage\Volume1'
                    CsvRoot = 'C:\ClusterStorage\Volume1'; Extension = '.vhdx'; Length = 0
                    Observation = 'No VM or snapshot chain references this base disk under complete coverage.'
                    Review = 'If this virtual disk belongs to an image library, exclude its full path with storage.imageLibraryPathPatterns in a checkpoint-health-policy.yml file supplied via -PolicyPath (see README.md). Otherwise, confirm intended ownership.'
                }
            )
        $script:CleanRenderedHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs $null -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.19' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 2 -ClusterCsvCount 1 -HousekeepingFindings @([pscustomobject]@{
                Category = 'Unattached base disk candidate'; Scope = 'C:\ClusterStorage\UserStorage_1'
                FileName = 'BaseDisk.vhdx'
                Observation = 'No VM or snapshot chain references this base disk under complete coverage: C:\ClusterStorage\UserStorage_1\BaseDisk.vhdx'
                Review = 'If this virtual disk belongs to an image library, exclude its full path with storage.imageLibraryPathPatterns in a checkpoint-health-policy.yml file supplied via -PolicyPath (see README.md). Otherwise, confirm intended ownership. Do not modify the file based only on this report.'
            })
        $advisoryReportData = $normalReportData.PSObject.Copy()
        $advisoryReportData.ReplAssessment = $normalReportData.ReplAssessment.PSObject.Copy()
        $advisoryReportData.ReplAssessment.MeasurementStatus = 'Advisory'
        $advisoryReportData.ReplAssessment.HasAdvisory = $true
        $advisoryReportData.ReplAssessment.MissedCount = 1
        $advisoryReportData.ReplAssessment.MissedRatePercent = 0.83
        $advisoryReportData.ReplAssessment.AdvisoryBreaches = @('MissedCount')
        $advisoryReportData.ReplAssessment.ThresholdBreaches = @('MissedCount')
        $advisoryReportData.ReplAssessment.Reason = 'Hyper-V Replica reports Normal health with measurement drift that warrants observation.'
        $script:AdvisoryReplicaHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-ADVISORY'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $advisoryReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 10:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.19' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1
    }

    It 'shows an incomplete count for NOT FOUND and ERROR rows' {
        $script:RenderedHtml | Should -Match '<div class="l">Incomplete</div>'
        $script:RenderedHtml | Should -Match '<div class="n">1</div><div class="l">Incomplete</div>'
        $script:RenderedHtml | Should -Match 'Incomplete assessment:.*1 VM.*NOT FOUND or ERROR'
        $script:RenderedHtml | Should -Match '_debug_log_\*\.txt'
        $script:RenderedHtml | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth#readme'
        $script:RenderedHtml | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth-Feedback'
    }

    It 'states the point-in-time report scope and audited VM count in every report' {
        $script:RenderedHtml | Should -Match '<strong class="scope-label">Report scope:</strong> This report is a point-in-time, read-only assessment of the <strong>4 VMs audited in this run</strong>, generated at <strong>2026-01-01 00:00:00 UTC</strong>\.'
        $script:RenderedHtml | Should -Match 'wider assessment of the cluster, storage, backup solution, workloads, and relevant operational history\.'
        $script:RenderedHtml | Should -Match '\.scope-label\{color:#d97706;font-weight:700\}'
        $script:RenderedHtml | Should -Match 'It is not a complete cluster health assessment and does not represent the health of VMs that were not audited\.'
        $script:CleanRenderedHtml | Should -Match '<strong>1 VM audited in this run</strong>'
    }

    It 'states additional unaudited discovery coverage only when applicable' {
        $script:RenderedHtml | Should -Match '<strong>Audit coverage:</strong> <strong>1 additional discovered VM was not audited in this run</strong> and is not represented by the findings or summary totals below\.'
        $script:CleanRenderedHtml | Should -Not -Match '<strong>Audit coverage:</strong>'
    }

    It 'warn-highlights abnormal Replica state while leaving normal replication neutral' {
        $script:RenderedHtml | Should -Match "<span class='warnval'>Error \(Critical\)</span>"
        $script:RenderedHtml | Should -Match '<td>Replicating \(Normal\)</td>'
        $script:RenderedHtml | Should -Not -Match "<span class='warnval'>Replicating \(Normal\)</span>"
        $script:RenderedHtml | Should -Not -Match 'unhealthy Hyper-V Replica'
        $script:RenderedHtml | Should -Not -Match 'replica health Normal'
    }

    It 'renders per-VM Replica details collapsed when healthy and open when attention is needed' {
        $script:RenderedHtml | Should -Match '<details><summary>Hyper-V Replica details - Replicating / Normal; measurements Healthy</summary>'
        $script:RenderedHtml | Should -Match '<details open><summary>Hyper-V Replica details - Error / Critical; measurements Healthy</summary>'
        $script:AdvisoryReplicaHtml | Should -Match '<details open><summary>Hyper-V Replica details - Replicating / Normal; measurements Advisory</summary>'
        $script:RenderedHtml | Should -Match '<th>Signal</th><th>Observed</th><th>Effective guardrail / context</th><th>Assessment</th>'
        foreach ($signal in @('Product state and health', 'Relationship', 'Replication cadence', 'Monitoring window', 'Last replication', 'Average replication size', 'Pending replication data', 'Average replication latency', 'Measured replication cycles')) {
            $script:RenderedHtml | Should -Match ([regex]::Escape("<td>$signal</td>"))
        }
        $script:AdvisoryReplicaHtml | Should -Match "<span class='warnval'>Advisory</span>"
    }

    It 'labels every per-VM card heading explicitly' {
        $script:RenderedHtml | Should -Match '<h3><span class="vm-label">VM Name:</span> <code>TEST-VM-NORMAL</code>'
        $script:RenderedHtml | Should -Match '<h3><span class="vm-label">VM Name:</span> <code>TEST-VM-MISSING</code>'
    }

    It 'uses a full-width audited-VM lead card and keeps orphaned AVHDX last' {
        $script:RenderedHtml | Should -Match '<div class="card lead"><div class="n">4</div><div class="l">VMs audited</div></div>'
        $script:RenderedHtml | Should -Match '(?s)<div class="cards">.*VMs audited.*Hold state.*Investigate.*OK.*Incomplete.*Stale AVHDX layers.*Stale snapshots.*Orphaned \.avhdx.*</div>'
        $script:RenderedHtml | Should -Match '\.cards\{display:grid;grid-template-columns:repeat\(7,minmax\(0,1fr\)\)'
        $script:RenderedHtml | Should -Match '\.card\.lead\{grid-column:1/-1\}'
    }

    It 'does not describe empty active-checkpoint coverage as wrapped' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData.CannotConfirmMigrationSafe = $true
        $reportData.ActiveCkptCoverageIncomplete = $true
        $reportData.ActiveCkptLogsWrapped = $false
        $reportData.ActiveCkptOldestCreateUtc = '2026-07-10 12:04:00'
        $reportData.ActiveCkptOldestAvailUtc = '2026-07-02 13:25:22'
        $reportData.ActiveCkptHistoric = [pscustomobject]@{
            Coverage = @(
                [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'Worker'; Status = 'Disabled'; Sufficient = $false; OldestAvailable = $null }
                [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'VMMS'; Status = 'Covered'; Sufficient = $true; OldestAvailable = [datetime]'2026-07-02T13:25:22Z' }
            )
        }
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-COVERAGE'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 1; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' `
            -GeneratedUtc '2026-07-20 12:26:52' -DiscoveredVMs @() `
            -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.19' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match 'required Worker/VMMS coverage is incomplete'
        $html | Should -Match 'TEST-NODE-01/Worker=Disabled'
        $html | Should -Not -Match 'wrapped past this active checkpoint'
        $html | Should -Not -Match 'only go back to'
    }

    It 'never treats optional Analytic-channel status as CANNOT CONFIRM coverage' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData.AnalyticNodesNeedEnable = @('TEST-NODE-01')
        $reportData.CannotConfirmMigrationSafe = $false
        $reportData.ActiveCkptCoverageIncomplete = $false
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-ANALYTIC'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' `
            -GeneratedUtc '2026-07-20 12:26:52' -DiscoveredVMs @() `
            -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.19' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match 'Analytic channel.*Not enabled on this node'
        $html | Should -Not -Match 'CANNOT CONFIRM from event data'
    }

    It 'reports discovery counts and explicit cap-reached guidance' {
        $script:RenderedHtml | Should -Match 'Discovery: <b>3</b> eligible.*<b>2</b> auto-audited.*<b>1</b> deferred.*cap: <b>2</b>'
        $script:RenderedHtml | Should -Match 'Discovered VMs not audited - discovery cap reached'
        $script:RenderedHtml | Should -Not -Match 'adding <code>-IncludeDiscoveredVMs</code>'
    }

    It 'reports stale attached layers separately from named snapshots' {
        $script:RenderedHtml | Should -Match '<div class="n">1</div><div class="l">Stale AVHDX layers</div>'
        $script:RenderedHtml | Should -Match '<div class="n">0</div><div class="l">Stale snapshots</div>'
        $script:RenderedHtml | Should -Match '<th>Stale<br>evidence</th>'
        $script:RenderedHtml | Should -Match '1 layer / 0 snapshots'
        $script:RenderedHtml | Should -Not -Match '>1 / 0<'
        $script:RenderedHtml | Should -Match 'Stale attached AVHDX layers \(&ge;24h\)</div><div>1</div>'
        $script:RenderedHtml | Should -Match 'Snapshot/layer representation</div><div>MISMATCH'
        $script:RenderedHtml | Should -Match '1 stale attached AVHDX layer\(s\)'
        $script:RenderedHtml | Should -Match 'Attached VHD chain evidence \(1 layer\(s\)\)'
        $script:RenderedHtml | Should -Match 'TEST-VM-STALE-LAYER_OS\.avhdx'
    }

    It 'uses Replica-specific guidance for a Replica-only INVESTIGATE result' {
        $script:RenderedHtml | Should -Match 'Review the Hyper-V Replica details below, confirm connectivity and capacity on both replication partners'
        $replicaCard = [regex]::Match($script:RenderedHtml, '(?s)<div class="vm" id="vm-TEST-VM-REPLICA">.*?(?=<div class="vm"|</main>)').Value
        $replicaCard | Should -Not -Match 'checkpoint fork-commit signature was NOT observed'
    }

    It 'labels stale snapshot counts instead of rendering an ambiguous ratio' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData.StaleCheckpointCount = 1
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-STALE-SNAPSHOT'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 1; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' `
            -GeneratedUtc '2026-07-20 12:26:52' -DiscoveredVMs @() `
            -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.19' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match '0 layers / 1 snapshot'
        $html | Should -Not -Match '>0 / 1<'
    }

    It 'places operational housekeeping observations immediately before the appendix' {
        $script:RenderedHtml | Should -Match 'Cluster / storage housekeeping to review:'
        $script:RenderedHtml | Should -Match 'Operational excellence and consistent storage practices improve reliability and reduce operational complexity.'
        $script:RenderedHtml | Should -Match 'Attached disk is stored under another VM folder &lt;review&gt;'
        $script:RenderedHtml | Should -Match 'Do not move, rename, merge, or delete virtual disk files based solely on this report.'
        $script:RenderedHtml.IndexOf('Cluster / storage housekeeping to review:') | Should -BeLessThan $script:RenderedHtml.IndexOf('Appendix - Knowledge and Information')
    }

    It 'shows an explicit message instead of an empty housekeeping table' {
        $html = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs $null -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.19' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 2 -ClusterCsvCount 1 -HousekeepingFindings $null

        $html | Should -Match 'No cluster or storage housekeeping observations were produced by the checks performed in this run\.'
        $html | Should -Match 'This is not a comprehensive storage-layout certification\.'
        $html | Should -Not -Match '<table class="housekeeping">'
    }

    It 'uses a human-readable zero for housekeeping rows without file-size data' {
        $script:RenderedHtml | Should -Not -Match "id='hk-visible-bytes'>0 bytes"
        $script:RenderedHtml | Should -Match "var readable = bytes > 0 \? '< 1 KB' : '0 KB';"
    }

    It 'keeps clean VM-health wording distinct from review-only housekeeping' {
        $script:CleanRenderedHtml | Should -Match 'Exec Summary - no VM health action required:'
        $script:CleanRenderedHtml | Should -Match 'No VM-health action required from this audit:'
        $script:CleanRenderedHtml | Should -Match 'Review the separate cluster / storage housekeeping observations'
        $script:CleanRenderedHtml | Should -Not -Match 'Cluster / backup administrators should INVESTIGATE'
    }

    It 'links unattached base disk README guidance in a new tab' {
        $script:CleanRenderedHtml | Should -Match 'supplied via -PolicyPath \(see <a href="https://aka\.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">README\.md</a>\)\.'
        $script:CleanRenderedHtml | Should -Not -Match '\(see README\.md\)'
    }

    It 'gives housekeeping findings readable desktop columns and stacked mobile labels' {
        $script:RenderedHtml | Should -Match '<table class="housekeeping" id="hk-table"><colgroup>'
        $script:RenderedHtml | Should -Match '<col class="hk-category"><col class="hk-scope"><col class="hk-filecol"><col class="hk-size"><col class="hk-observation"><col class="hk-review">'
        $script:RenderedHtml | Should -Match 'data-sort="scope">Scope</button>'
        $script:RenderedHtml | Should -Match "<td data-label='Scope'><code>TEST-VM-NORMAL</code></td>"
        $script:RenderedHtml | Should -Match "<td data-label='Scope'><code>TEST-NODE-02</code></td>"
        $script:RenderedHtml | Should -Match "<div class='hk-file'><code>Data&lt;review&gt;\.vhdx</code></div><code>C:\\ClusterStorage"
        $script:RenderedHtml | Should -Match "data-label='Size' class='num'>1\.50 MB</td>"
        $script:RenderedHtml | Should -Not -Match '1572864 bytes'
        $script:RenderedHtml | Should -Match 'table\.housekeeping\{table-layout:fixed\}'
        $script:RenderedHtml | Should -Match 'table\.housekeeping col\.hk-filecol\{width:24%\}'
        $script:RenderedHtml | Should -Match 'table\.housekeeping col\.hk-review\{width:16%\}'
        $script:RenderedHtml | Should -Match 'table\.housekeeping td::before\{content:attr\(data-label\)'
        $script:RenderedHtml | Should -Match 'table\.housekeeping td \.hk-observation\{grid-column:2;min-width:0\}'
    }

    It 'enables all housekeeping categories and exposes live filtering and chart surfaces' {
        $script:RenderedHtml | Should -Match "class='hk-category-filter' type='checkbox'.*checked"
        $script:RenderedHtml | Should -Match "id='hk-select-all'>Select all"
        $script:RenderedHtml | Should -Match "id='hk-clear-all'>Clear all"
        $script:RenderedHtml | Should -Match "id='hk-visible-bytes'>1\.50 MB</strong>"
        $script:RenderedHtml | Should -Match "id='hk-category-chart'"
        $script:RenderedHtml | Should -Match "id='hk-path-chart'"
        $script:RenderedHtml | Should -Match 'Cluster Shared Volume \(CSV\) paths'
        $script:RenderedHtml | Should -Match "aria-label='Visible housekeeping storage by Cluster Shared Volume'"
        $script:RenderedHtml | Should -Match 'function csvVolumeName\(rootPath\)'
        $script:RenderedHtml | Should -Match "var csvVolume = csvVolumeName\(row\.getAttribute\('data-root'\)\)"
        $script:RenderedHtml | Should -Match 'byCsvVolume\[csvVolume\]'
        $script:RenderedHtml | Should -Not -Match 'Top visible parent paths'
        $script:RenderedHtml | Should -Match 'function applyFilters\(\)'
        $script:RenderedHtml | Should -Match "box\.addEventListener\('change', applyFilters\)"
        $script:RenderedHtml | Should -Match 'seen\[identity\]'
    }

    It 'filters selected unattached VHDX rows and reveals copyable persistent policy settings below the table' {
        ([regex]::Matches($script:RenderedHtml, "class='hk-image-filter' type='checkbox'> Filter out as VM image")).Count | Should -Be 1
        $script:RenderedHtml | Should -Match "id='hk-image-policy' hidden><h3>Persistent VM image policy settings</h3>"
        $script:RenderedHtml | Should -Match "id='hk-image-policy-yaml' readonly aria-label='Generated VM image policy settings'"
        $script:RenderedHtml | Should -Match "id='hk-copy-policy'>Copy policy settings</button>"
        $script:RenderedHtml | Should -Match "id='hk-restore-images'>Restore all rows</button>"
        $script:RenderedHtml.IndexOf('</tbody></table>') | Should -BeLessThan $script:RenderedHtml.IndexOf("id='hk-image-policy'")
        $script:RenderedHtml.IndexOf("id='hk-image-policy'") | Should -BeLessThan $script:RenderedHtml.IndexOf('Appendix - Knowledge and Information')
        $script:RenderedHtml | Should -Match "var matches = \(!imageBox \|\| !imageBox\.checked\)"
        $script:RenderedHtml | Should -Match "yamlLines = \['schemaVersion: 1', 'storage:', '    imageLibraryPathPatterns:'\]"
        $script:RenderedHtml | Should -Match "escapeRegex\(path\)"
        $script:RenderedHtml | Should -Match "hidden only in this open report"
        $script:RenderedHtml | Should -Match 'For a new policy file, paste the complete generated block'
        $script:RenderedHtml | Should -Match 'For an existing policy, copy only the generated <code>- .* entries into its existing <code>storage\.imageLibraryPathPatterns</code> list'
        $script:RenderedHtml | Should -Match "repeat the original audit command with <code>-PolicyPath '\.\\checkpoint-health-policy\.yml'</code>"
        $script:RenderedHtml | Should -Match 'do not change VM health verdicts or authorize modifying the selected files'
    }

    It 'counts duplicate housekeeping file paths once in storage totals' {
        $duplicateFindings = @(
            [pscustomobject]@{ Category = 'Placement'; Scope = 'TEST-VM'; FileName = 'Disk.vhdx'; FullName = 'C:\ClusterStorage\Volume1\Disk.vhdx'; ParentPath = 'C:\ClusterStorage\Volume1'; CsvRoot = 'C:\ClusterStorage\Volume1'; Extension = '.vhdx'; Length = 1572864; Observation = 'Synthetic'; Review = 'Review.' },
            [pscustomobject]@{ Category = 'Shared reference'; Scope = 'TEST-VM'; FileName = 'Disk.vhdx'; FullName = 'C:\ClusterStorage\Volume1\Disk.vhdx'; ParentPath = 'C:\ClusterStorage\Volume1'; CsvRoot = 'C:\ClusterStorage\Volume1'; Extension = '.vhdx'; Length = 1572864; Observation = 'Synthetic'; Review = 'Review.' }
        )
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM'; OwningNode = 'TEST-NODE'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'TEST-CLUSTER' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.19' -ReportGenerationTime '00:00:01' -ClusterNodeCount 1 -ClusterCsvCount 1 `
            -HousekeepingFindings $duplicateFindings

        ([regex]::Matches($html, 'Unfiltered unique-file storage: <strong>1\.50 MB</strong>')).Count | Should -Be 1
        $html | Should -Not -Match '1572864 bytes'
        $html | Should -Not -Match '3\.00 MB'
    }

    It 'scales housekeeping storage display to TB without exposing raw byte counts' {
        $twoTerabytes = 2TB
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM'; OwningNode = 'TEST-NODE'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'TEST-CLUSTER' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.19' -ReportGenerationTime '00:00:01' -ClusterNodeCount 1 -ClusterCsvCount 1 `
            -HousekeepingFindings @([pscustomobject]@{ Category = 'Placement'; Scope = 'TEST-VM'; FileName = 'Large.vhdx'; FullName = 'C:\ClusterStorage\Volume1\Large.vhdx'; ParentPath = 'C:\ClusterStorage\Volume1'; CsvRoot = 'C:\ClusterStorage\Volume1'; Extension = '.vhdx'; Length = $twoTerabytes; Observation = 'Synthetic'; Review = 'Review.' })

        $html | Should -Match "id='hk-visible-bytes'>2\.00 TB</strong>"
        $html | Should -Match "data-label='Size' class='num'>2\.00 TB</td>"
        $html | Should -Not -Match "$twoTerabytes bytes"
        $html | Should -Match 'return readable;'
    }

    It 'contains wide non-housekeeping tables on narrow screens' {
        $script:RenderedHtml | Should -Match '@media\(max-width:760px\)\{\s*table:not\(\.housekeeping\)\{display:block;overflow-x:auto\}'
    }
}

Describe 'Unrecovered-failure debug log' {
    BeforeAll {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        $modulePath = Join-Path $toolRoot 'Get-HyperVVMCheckpointHealth.psm1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
        foreach ($functionName in @('Get-TelemetryNow', 'Write-AuditDebugLog', 'Add-AuditDiagnostic', 'Add-AuditDiagnosticMessage', 'Invoke-WithRetry')) {
            $functionAst = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Invoke-Expression $functionAst.Extent.Text
        }
    }

    BeforeEach {
        $script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $script:TelemetryClockBaseUtc = [DateTimeOffset]::UtcNow
        $script:ScriptVersion = '0.2.19'
        $script:VMSectionStepNo = 45
        $script:VMSectionName = 'Scanning Replica change logs (.hrl)'
        $script:AuditDiagnostics = [System.Collections.Generic.List[object]]::new()
        $script:DebugLogPath = Join-Path $TestDrive '_debug_log_test.txt'
        Remove-Item -LiteralPath $script:DebugLogPath -Force -ErrorAction SilentlyContinue
    }

    It 'writes exact ErrorRecord context, phase, stack, and support guidance' {
        function Invoke-SyntheticDiagnosticFailure {
            throw [System.InvalidOperationException]::new('synthetic diagnostic failure')
        }

        try { Invoke-SyntheticDiagnosticFailure } catch { $errorRecord = $_ }
        Add-AuditDiagnostic -ErrorRecord $errorRecord -Operation 'Synthetic collector' -Scope 'VM=TEST-VM-01' -AttemptCount 3

        $content = Get-Content -LiteralPath $script:DebugLogPath -Raw
        $content | Should -Match 'Operation: Synthetic collector'
        $content | Should -Match 'Scope: VM=TEST-VM-01'
        $content | Should -Match 'TelemetryStep: 45'
        $content | Should -Match 'TelemetryPhase: Scanning Replica change logs \(\.hrl\)'
        $content | Should -Match 'AttemptCount: 3'
        $content | Should -Match 'ExceptionType: System\.InvalidOperationException'
        $content | Should -Match 'ExceptionMessage: synthetic diagnostic failure'
        $content | Should -Match 'ScriptLineNumber: [1-9][0-9]*'
        $content | Should -Match 'PositionMessage:'
        $content | Should -Match 'ScriptStackTrace:.*Invoke-SyntheticDiagnosticFailure'
        $content | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth#readme'
        $content | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth-Feedback'
    }

    It 'writes returned read-only collector errors to the debug log' {
        Add-AuditDiagnosticMessage -Message 'Synthetic CSV root read failure' `
            -Operation 'Collect cluster virtual disk file inventory' -Scope 'Node=TEST-NODE; Root=TEST-ROOT'

        $content = Get-Content -LiteralPath $script:DebugLogPath -Raw
        $content | Should -Match 'Operation: Collect cluster virtual disk file inventory'
        $content | Should -Match 'Scope: Node=TEST-NODE; Root=TEST-ROOT'
        $content | Should -Match 'ExceptionType: System\.InvalidOperationException'
        $content | Should -Match 'ExceptionMessage: Synthetic CSV root read failure'
        $content | Should -Match 'FullyQualifiedErrorId: ReadOnlyCollectionIncomplete'
    }

    It 'does not create a debug log when no failures were captured' {
        Write-AuditDebugLog
        Test-Path -LiteralPath $script:DebugLogPath | Should -BeFalse
    }

    It 'records the final retry attempt before rethrowing' {
        $script:RetryAttempts = 0
        { Invoke-WithRetry -MaxAttempts 2 -DelayMs 0 -DiagnosticOperation 'Synthetic retry' -DiagnosticScope 'Node=TEST-NODE-01' -ScriptBlock { $script:RetryAttempts++; throw 'retry failed' } } | Should -Throw '*retry failed*'

        $content = Get-Content -LiteralPath $script:DebugLogPath -Raw
        $script:RetryAttempts | Should -Be 2
        $content | Should -Match 'Operation: Synthetic retry'
        $content | Should -Match 'Scope: Node=TEST-NODE-01'
        $content | Should -Match 'AttemptCount: 2'
    }
}

Describe 'Synthetic HTML example report' {
    BeforeAll {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        $script:ExamplePath = Join-Path $toolRoot 'examples\VMCheckpointAudit-contoso01-example.html'
        $script:ExampleHtml = Get-Content -LiteralPath $script:ExamplePath -Raw
        $script:DetailBlocks = [regex]::Matches(
            $script:ExampleHtml,
            '(?s)<div class="vm(?: hold)?" id="vm-(TestVM\d{2})">(.*?)(?=<div class="vm(?: hold)?" id="vm-|<h2>Cluster storage health)'
        )
    }

    It 'uses the approved synthetic ten-node, twenty-VM inventory' {
        $script:ExampleHtml | Should -Match '<strong>Synthetic example report\.</strong>'
        $script:ExampleHtml | Should -Match 'Cluster <b>contoso01</b>'
        $script:ExampleHtml | Should -Match 'Cluster size: <b>10</b> nodes'
        $script:ExampleHtml | Should -Match '<div class="n">20</div><div class="l">VMs audited</div>'
        @($script:DetailBlocks).Count | Should -Be 20
        @($script:DetailBlocks | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count | Should -Be 20
    }

    It 'contains sixteen input VMs and four discovered VMs' {
        @($script:DetailBlocks | Where-Object { $_.Groups[2].Value -match '<span class="src input">Input</span>' }).Count | Should -Be 16
        @($script:DetailBlocks | Where-Object { $_.Groups[2].Value -match '<span class="src discovered">Discovered</span>' }).Count | Should -Be 4
        $script:ExampleHtml | Should -Match 'Discovery: <b>4</b> eligible.*<b>4</b> auto-audited.*<b>0</b> deferred'
    }

    It 'demonstrates field-like checkpoint orphan and replication findings without unhealthy VSS' {
        $script:ExampleHtml | Should -Match '<div class="n">1</div><div class="l">Hold state</div>'
        $script:ExampleHtml | Should -Match '<div class="n">7</div><div class="l">Investigate</div>'
        $script:ExampleHtml | Should -Match '<div class="n">12</div><div class="l">OK</div>'
        $script:ExampleHtml | Should -Match '<div class="n">4</div><div class="l">Orphaned \.avhdx</div>'
        $script:ExampleHtml | Should -Match '<div class="n">4</div><div class="l">Stale AVHDX layers</div>'
        $script:ExampleHtml | Should -Match '<div class="n">3</div><div class="l">Stale snapshots</div>'
        $script:ExampleHtml | Should -Match "Confirmed historic 'fork-commit / merge failure'"
        $script:ExampleHtml | Should -Match "HOLD STATE - fork-commit recorded at this active checkpoint's creation"
        $script:ExampleHtml | Should -Match 'Error \(Critical\)'
        $script:ExampleHtml | Should -Match 'Resynchronizing \(Warning\)'
        [regex]::Matches($script:ExampleHtml, '<div class="k">VSS writers</div><div>All 10 writer\(s\) Stable \(no last error\)</div>').Count | Should -Be 20
    }

    It 'rolls every INVESTIGATE VM into the HOLD executive summary' {
        $script:ExampleHtml | Should -Match '<strong>7 additional VM\(s\) are flagged INVESTIGATE:</strong>'
        $script:ExampleHtml | Should -Match '<strong>Fleet-wide checkpoint / replication evidence:</strong> 4 stale attached AVHDX layer\(s\), 3 stale named snapshot\(s\), 4 orphaned \.avhdx file\(s\), 2 VM\(s\) with Replica product-health/state concerns, 1 VM\(s\) with material Replica measurement concerns, 1 VM\(s\) with Replica measurement advisories\.'
    }

    It 'contains only synthetic identities and approved UserStorage paths' {
        $script:ExampleHtml | Should -Not -Match '(?i)Legal (?:&|&amp;) General|KWDRPT|GBKOS|ALCSS'
        $script:ExampleHtml | Should -Not -Match '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
        $paths = @([regex]::Matches($script:ExampleHtml, '(?i)C:\\ClusterStorage\\[^<\s''"]+') | ForEach-Object {
                [System.Net.WebUtility]::HtmlDecode($_.Value)
            })
        @($paths).Count | Should -BeGreaterThan 0
        @($paths | Where-Object { $_ -notmatch '^C:\\ClusterStorage\\UserStorage_[12](?:$|\\(?:TestVM(?:0[1-9]|1[0-9]|20)|GuestCluster)(?:$|\\))' }).Count | Should -Be 0
    }

    It 'demonstrates review-only virtual disk housekeeping findings' {
        $script:ExampleHtml | Should -Match 'Placement inconsistency'
        $script:ExampleHtml | Should -Match 'Unattached base disk candidate'
        $script:ExampleHtml | Should -Match 'Shared virtual disk reference'
        $script:ExampleHtml | Should -Match 'Shared VHD Set reference'
        $script:ExampleHtml | Should -Match 'GuestClusterData\.vhds'
        $script:ExampleHtml | Should -Match 'TestVM08_LegacyData\.vhdx'
        $script:ExampleHtml | Should -Match 'TestVM12_Archive\.vhdx'
        ([regex]::Matches($script:ExampleHtml, "class='hk-image-filter' type='checkbox'> Filter out as VM image")).Count | Should -Be 2
        $script:ExampleHtml | Should -Match "id='hk-image-policy' hidden><h3>Persistent VM image policy settings</h3>"
        $script:ExampleHtml | Should -Match 'If this virtual disk belongs to an image library, exclude its full path with storage\.imageLibraryPathPatterns in a checkpoint-health-policy\.yml file supplied via -PolicyPath \(see <a href="https://aka\.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">README\.md</a>\)\.'
        $script:ExampleHtml | Should -Match 'Do not modify the file based only on this report\.'
    }
}

Describe 'Discovered VM audit selection' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $modulePath -Force
    }

    It 'aggregates reasons and audits strongest evidence before applying the cap' {
        $candidates = @(
            [pscustomobject]@{ Name = 'TEST-VM-TRANSIENT'; Reason = 'Background disk merge interrupted (event 19090)' }
            [pscustomobject]@{ Name = 'TEST-VM-FAILED'; Reason = 'Background disk merge FAILED (event 19100)' }
            [pscustomobject]@{ Name = 'TEST-VM-SHARING'; Reason = 'Sharing violation on disk (0x80070020)' }
            [pscustomobject]@{ Name = 'TEST-VM-FAILED'; Reason = 'Cannot load VM configuration (event 16300)' }
        )

        $selection = Select-DiscoveredVMsForAudit -Candidates $candidates -Maximum 2

        $selection.EligibleCount | Should -Be 3
        $selection.Audit.Count | Should -Be 2
        $selection.Deferred.Count | Should -Be 1
        $selection.Audit.Name | Should -Be @('TEST-VM-FAILED', 'TEST-VM-SHARING')
        $selection.Deferred.Name | Should -Be @('TEST-VM-TRANSIENT')
        ($selection.Audit | Where-Object Name -eq 'TEST-VM-FAILED').Reasons.Count | Should -Be 2
    }

    It 'returns no deferred VMs when eligible discoveries equal the cap' {
        $selection = Select-DiscoveredVMsForAudit -Candidates @(
            [pscustomobject]@{ Name = 'TEST-VM-A'; Reason = 'Cannot load VM configuration (event 16300)' }
            [pscustomobject]@{ Name = 'TEST-VM-B'; Reason = 'Background disk merge interrupted (event 19090)' }
        ) -Maximum 2

        $selection.EligibleCount | Should -Be 2
        $selection.Audit.Count | Should -Be 2
        $selection.Deferred.Count | Should -Be 0
    }

    It 'audits every eligible discovery when no maximum is specified' {
        $selection = Select-DiscoveredVMsForAudit -Candidates @(
            [pscustomobject]@{ Name = 'TEST-VM-A'; Reason = 'Background disk merge interrupted (event 19090)' }
            [pscustomobject]@{ Name = 'TEST-VM-B'; Reason = 'Background disk merge FAILED (event 19100)' }
            [pscustomobject]@{ Name = 'TEST-VM-C'; Reason = 'Sharing violation on disk (0x80070020)' }
        )

        $selection.EligibleCount | Should -Be 3
        $selection.Audit.Count | Should -Be 3
        $selection.Deferred.Count | Should -Be 0
        $selection.Cap | Should -BeNullOrEmpty
    }

    It 'accepts an explicit null maximum from orchestration as no cap' {
        $selection = Select-DiscoveredVMsForAudit -Candidates @(
            [pscustomobject]@{ Name = 'TEST-VM-A'; Reason = 'Background disk merge FAILED (event 19100)' }
            [pscustomobject]@{ Name = 'TEST-VM-B'; Reason = 'Background disk merge interrupted (event 19090)' }
        ) -Maximum $null

        $selection.Audit.Count | Should -Be 2
        $selection.Deferred.Count | Should -Be 0
        $selection.Cap | Should -BeNullOrEmpty
    }
}

Describe 'VHD chain traversal' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        Import-Module $modulePath -Force
    }

    It 'marks a differencing chain complete only when it reaches a base disk' {
        $vhdByPath = @{
            'C:\TEST\active.avhdx' = [pscustomobject]@{ Path = 'C:\TEST\active.avhdx'; VhdType = 'Differencing'; ParentPath = 'C:\TEST\base.vhdx'; FileSize = 10GB }
            'C:\TEST\base.vhdx' = [pscustomobject]@{ Path = 'C:\TEST\base.vhdx'; VhdType = 'Dynamic'; ParentPath = $null; FileSize = 20GB }
        }
        $result = Get-VHDChainReport -Path 'C:\TEST\active.avhdx' `
            -GetVhdCommand { param($path) $vhdByPath[$path] } `
            -GetItemCommand { param($path) $null }

        $result.Complete | Should -BeTrue
        $result.Chain.Count | Should -Be 2
        $result.TerminalType | Should -Be 'Dynamic'
        $result.DepthLimitReached | Should -BeFalse
        $result.Error | Should -BeNullOrEmpty
    }

    It 'surfaces an unreadable parent as an incomplete chain' {
        $result = Get-VHDChainReport -Path 'C:\TEST\active.avhdx' `
            -GetVhdCommand {
                param($path)
                if ($path -like '*active.avhdx') {
                    return [pscustomobject]@{ Path = $path; VhdType = 'Differencing'; ParentPath = 'C:\TEST\missing.vhdx'; FileSize = 10GB }
                }
                throw 'Synthetic parent read failure'
            } -GetItemCommand { param($path) $null }

        $result.Complete | Should -BeFalse
        $result.FailurePath | Should -Be 'C:\TEST\missing.vhdx'
        $result.Error | Should -Match 'Synthetic parent read failure'
    }

    It 'terminates and reports a cyclic parent chain' {
        $vhdByPath = @{
            'C:\TEST\one.avhdx' = [pscustomobject]@{ Path = 'C:\TEST\one.avhdx'; VhdType = 'Differencing'; ParentPath = 'C:\TEST\two.avhdx'; FileSize = 10GB }
            'C:\TEST\two.avhdx' = [pscustomobject]@{ Path = 'C:\TEST\two.avhdx'; VhdType = 'Differencing'; ParentPath = 'C:\TEST\one.avhdx'; FileSize = 10GB }
        }
        $result = Get-VHDChainReport -Path 'C:\TEST\one.avhdx' `
            -GetVhdCommand { param($path) $vhdByPath[$path] } `
            -GetItemCommand { param($path) $null }

        $result.Complete | Should -BeFalse
        $result.Chain.Count | Should -Be 2
        $result.Error | Should -Match 'cycle'
    }

    It 'rejects a differencing layer that has no terminal parent' {
        $result = Get-VHDChainReport -Path 'C:\TEST\detached.avhdx' `
            -GetVhdCommand { param($path) [pscustomobject]@{ Path = $path; VhdType = 'Differencing'; ParentPath = $null; FileSize = 10GB } } `
            -GetItemCommand { param($path) $null }

        $result.Complete | Should -BeFalse
        $result.TerminalType | Should -Be 'Differencing'
        $result.Error | Should -Match 'terminal base disk was not reached'
    }

    It 'reports when the conservative depth limit is reached' {
        $result = Get-VHDChainReport -Path 'C:\TEST\layer-1.avhdx' -MaximumDepth 2 `
            -GetVhdCommand {
                param($path)
                $number = [int]([regex]::Match($path, '(\d+)').Groups[1].Value)
                [pscustomobject]@{ Path = $path; VhdType = 'Differencing'; ParentPath = "C:\TEST\layer-$($number + 1).avhdx"; FileSize = 10GB }
            } -GetItemCommand { param($path) $null }

        $result.Complete | Should -BeFalse
        $result.Chain.Count | Should -Be 2
        $result.DepthLimitReached | Should -BeTrue
        $result.Error | Should -Match 'maximum depth'
    }
}

Describe 'Checkpoint staleness assessment' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        Import-Module $modulePath -Force
        $script:AssessmentNow = [datetime]'2026-07-20T12:00:00Z'
    }

    It 'flags a stale attached AVHDX even when no named snapshot exists' {
        $assessment = Get-CheckpointStalenessAssessment -DiskReports @(
            [pscustomobject]@{ Chain = @([pscustomobject]@{ Type = 'Differencing'; LastWrite = $script:AssessmentNow.AddHours(-30) }) }
        ) -Snapshots @() -StaleHours 24 -NowUtc $script:AssessmentNow

        $assessment.StaleAttachedLayerCount | Should -Be 1
        $assessment.StaleSnapshotCount | Should -Be 0
        $assessment.SnapshotLayerMismatch | Should -BeTrue
    }

    It 'flags a stale named snapshot when no attached layer is reachable' {
        $assessment = Get-CheckpointStalenessAssessment -DiskReports @() -Snapshots @(
            [pscustomobject]@{ CreationTimeUtc = $script:AssessmentNow.AddHours(-30) }
        ) -StaleHours 24 -NowUtc $script:AssessmentNow

        $assessment.StaleAttachedLayerCount | Should -Be 0
        $assessment.StaleSnapshotCount | Should -Be 1
        $assessment.SnapshotLayerMismatch | Should -BeTrue
    }

    It 'does not equate one snapshot with one layer on a multi-disk VM' {
        $assessment = Get-CheckpointStalenessAssessment -DiskReports @(
            [pscustomobject]@{ Chain = @([pscustomobject]@{ Type = 'Differencing'; LastWrite = $script:AssessmentNow.AddHours(-30) }) }
            [pscustomobject]@{ Chain = @([pscustomobject]@{ Type = 'Differencing'; LastWrite = $script:AssessmentNow.AddHours(-30) }) }
        ) -Snapshots @([pscustomobject]@{ CreationTimeUtc = $script:AssessmentNow.AddHours(-30) }) `
            -StaleHours 24 -NowUtc $script:AssessmentNow

        $assessment.StaleAttachedLayerCount | Should -Be 2
        $assessment.StaleSnapshotCount | Should -Be 1
        $assessment.SnapshotLayerMismatch | Should -BeFalse
    }

    It 'counts an old checkpoint layer beneath a recently written active top layer' {
        $assessment = Get-CheckpointStalenessAssessment -DiskReports @(
            [pscustomobject]@{ Chain = @(
                [pscustomobject]@{ Type = 'Differencing'; LastWrite = $script:AssessmentNow.AddMinutes(-5) }
                [pscustomobject]@{ Type = 'Differencing'; LastWrite = $script:AssessmentNow.AddHours(-48) }
                [pscustomobject]@{ Type = 'Dynamic'; LastWrite = $script:AssessmentNow.AddDays(-100) }
            ) }
        ) -Snapshots @([pscustomobject]@{ CreationTimeUtc = $script:AssessmentNow.AddHours(-48) }) `
            -StaleHours 24 -NowUtc $script:AssessmentNow

        $assessment.StaleAttachedLayerCount | Should -Be 1
        $assessment.StaleSnapshotCount | Should -Be 1
    }
}

Describe 'Cluster AVHDX ownership classification' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        Import-Module $modulePath -Force
        $script:ImageLibraryPathPatterns = @('(?i)[\\/](?:image|images|template|templates|library|gallery|golden)(?:[\\/]|$)')
    }

    It 'classifies paths case-insensitively across current and other VMs' {
        $inventory = @(
            [pscustomobject]@{ FullName = 'C:\TEST\CSV01\TEST-VM-01\disk.avhdx' }
            [pscustomobject]@{ FullName = 'C:\TEST\CSV01\TEST-VM-02\disk.avhdx' }
            [pscustomobject]@{ FullName = 'C:\TEST\CSV02\unowned.avhdx' }
        )
        $owners = @(
            [pscustomobject]@{ VMName = 'TEST-VM-01'; Path = 'c:\test\csv01\test-vm-01\DISK.avhdx' }
            [pscustomobject]@{ VMName = 'TEST-VM-02'; Path = 'C:\TEST\CSV01\TEST-VM-02\disk.avhdx' }
        )

        $result = Resolve-AvhdxOwnership -Inventory $inventory -Ownership $owners -CurrentVMName 'TEST-VM-01' -CoverageComplete $true

        @($result | Where-Object Classification -eq 'AttachedToThisVM').Count | Should -Be 1
        @($result | Where-Object Classification -eq 'AttachedToOtherVM').Count | Should -Be 1
        @($result | Where-Object Classification -eq 'UnattachedCandidate').Count | Should -Be 1
        $unattached = $result | Where-Object Classification -eq 'UnattachedCandidate'
        ($null -eq $unattached.Owners) | Should -BeFalse
        @($unattached.Owners).Count | Should -Be 0
    }

    It 'never labels an unowned path orphan when ownership coverage is incomplete' {
        $result = Resolve-AvhdxOwnership `
            -Inventory @([pscustomobject]@{ FullName = 'C:\TEST\CSV01\unknown.avhdx' }) `
            -Ownership @() -CurrentVMName 'TEST-VM-01' -CoverageComplete $false

        $result[0].Classification | Should -Be 'OwnershipAmbiguous'
    }

    It 'preserves all owners when a path is referenced by more than one VM' {
        $path = 'C:\TEST\CSV01\shared.avhdx'
        $result = Resolve-AvhdxOwnership -Inventory @([pscustomobject]@{ FullName = $path }) -Ownership @(
            [pscustomobject]@{ VMName = 'TEST-VM-01'; Path = $path }
            [pscustomobject]@{ VMName = 'TEST-VM-02'; Path = $path }
        ) -CurrentVMName 'TEST-VM-01' -CoverageComplete $true

        $result[0].Classification | Should -Be 'AttachedToThisVM'
        @($result[0].Owners).Count | Should -Be 2
    }
}

Describe 'Historic event coverage assessment' {
    BeforeAll {
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
        $script:WindowStart = [datetime]'2026-01-10T00:00:00Z'
    }

    It 'is complete only when every expected node and channel covers the window' {
        $rows = @(
            [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'Worker'; QuerySucceeded = $true; IsEnabled = $true; OldestAvailable = $script:WindowStart.AddDays(-2); Error = '' }
            [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'VMMS'; QuerySucceeded = $true; IsEnabled = $true; OldestAvailable = $script:WindowStart.AddDays(-1); Error = '' }
            [pscustomobject]@{ Node = 'TEST-NODE-02'; Channel = 'Worker'; QuerySucceeded = $true; IsEnabled = $true; OldestAvailable = $script:WindowStart.AddHours(-1); Error = '' }
            [pscustomobject]@{ Node = 'TEST-NODE-02'; Channel = 'VMMS'; QuerySucceeded = $true; IsEnabled = $true; OldestAvailable = $script:WindowStart.AddMinutes(-1); Error = '' }
        )

        $result = Resolve-EventCoverage -CoverageRows $rows -ExpectedNodes @('TEST-NODE-01', 'TEST-NODE-02') `
            -ExpectedChannels @('Worker', 'VMMS') -EarliestWindowStart $script:WindowStart

        $result.Complete | Should -BeTrue
        $result.OverallStatus | Should -Be 'Covered'
        @($result.Rows | Where-Object Status -ne 'Covered').Count | Should -Be 0
    }

    It 'does not let one retained channel hide another wrapped channel' {
        $rows = @(
            [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'Worker'; QuerySucceeded = $true; IsEnabled = $true; OldestAvailable = $script:WindowStart.AddDays(-2); Error = '' }
            [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'VMMS'; QuerySucceeded = $true; IsEnabled = $true; OldestAvailable = $script:WindowStart.AddHours(2); Error = '' }
        )

        $result = Resolve-EventCoverage -CoverageRows $rows -ExpectedNodes @('TEST-NODE-01') `
            -ExpectedChannels @('Worker', 'VMMS') -EarliestWindowStart $script:WindowStart

        $result.Complete | Should -BeFalse
        $result.OverallStatus | Should -Be 'Incomplete'
        ($result.Rows | Where-Object Channel -eq 'VMMS').Status | Should -Be 'Wrapped'
    }

    It 'marks missing and failed node-channel rows unavailable' {
        $rows = @(
            [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'Worker'; QuerySucceeded = $false; IsEnabled = $null; OldestAvailable = $null; Error = 'Synthetic query failure' }
        )

        $result = Resolve-EventCoverage -CoverageRows $rows -ExpectedNodes @('TEST-NODE-01') `
            -ExpectedChannels @('Worker', 'VMMS') -EarliestWindowStart $script:WindowStart

        $result.Complete | Should -BeFalse
        @($result.Rows | Where-Object Status -eq 'Unavailable').Count | Should -Be 2
        ($result.Rows | Where-Object Channel -eq 'Worker').Error | Should -Be 'Synthetic query failure'
    }

    It 'accepts an enabled empty channel without claiming retained history' {
        $result = Resolve-EventCoverage -CoverageRows @(
            [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'Worker'; QuerySucceeded = $true; IsEnabled = $true; OldestAvailable = $null; Error = '' }
        ) -ExpectedNodes @('TEST-NODE-01') -ExpectedChannels @('Worker') -EarliestWindowStart $script:WindowStart

        $result.Complete | Should -BeTrue
        $result.Rows[0].Status | Should -Be 'EnabledEmpty'
        $result.Rows[0].Sufficient | Should -BeTrue
    }

    It 'treats a disabled required Admin channel as incomplete' {
        $result = Resolve-EventCoverage -CoverageRows @(
            [pscustomobject]@{ Node = 'TEST-NODE-01'; Channel = 'Worker'; QuerySucceeded = $true; IsEnabled = $false; OldestAvailable = $null; Error = '' }
        ) -ExpectedNodes @('TEST-NODE-01') -ExpectedChannels @('Worker') -EarliestWindowStart $script:WindowStart

        $result.Complete | Should -BeFalse
        $result.Rows[0].Status | Should -Be 'Disabled'
        $result.Rows[0].Sufficient | Should -BeFalse
    }
}

Describe 'Historic event correlation coverage aggregation' {
    BeforeAll {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        Import-Module (Join-Path $toolRoot 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1') -Force
        $modulePath = Join-Path $toolRoot 'Get-HyperVVMCheckpointHealth.psm1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-HistoricVMEventCorrelation'
        }, $true) | Select-Object -First 1
        $functionAst | Should -Not -BeNullOrEmpty
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'accepts an enabled empty channel when the other retained history covers the window' {
        Mock Get-WinEvent {
            if ($ListLog) { return [pscustomobject]@{ IsEnabled = $true } }
            if ($LogName -like '*Worker*') { return }
            if ($Oldest) { return [pscustomobject]@{ TimeCreated = [datetime]'2026-07-02T13:25:22Z' } }
        }

        $result = Get-HistoricVMEventCorrelation -VMName 'TEST-VM-01' -VMId '00000000-0000-0000-0000-000000000000' `
            -Nodes @($env:COMPUTERNAME) -Timestamps @([datetime]'2026-07-10T12:04:00Z') -WindowMinutes 120 `
            -SignatureIds @(3216) -SignatureRx '0x80048102'

        $result.CoverageComplete | Should -BeTrue
        @($result.Coverage | Where-Object Status -eq 'EnabledEmpty').Count | Should -Be 1
        @($result.Coverage | Where-Object Status -eq 'Wrapped').Count | Should -Be 0
        $result.LogsWrappedPastWindow | Should -BeFalse
    }
}

Describe 'Typed Hyper-V replication assessment' {
    BeforeAll {
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
    }

    It 'treats disabled replication as not applicable and neutral' {
        $result = Get-HyperVReplicationAssessment -Enabled $false -State 'Disabled' -Health '' -Mode ''
        $result.Severity | Should -Be 'NotApplicable'
        $result.IsConcern | Should -BeFalse
    }

    It 'classifies normal active replication as healthy' {
        $result = Get-HyperVReplicationAssessment -Enabled $true -State 'Replicating' -Health 'Normal' -Mode 'Primary'
        $result.Severity | Should -Be 'Healthy'
        $result.IsConcern | Should -BeFalse
    }

    It 'classifies warning and critical health without display-text parsing' {
        (Get-HyperVReplicationAssessment -Enabled $true -State 'Replicating' -Health 'Warning' -Mode 'Primary').Severity | Should -Be 'Warning'
        $critical = Get-HyperVReplicationAssessment -Enabled $true -State 'Resynchronizing' -Health 'Critical' -Mode 'Replica'
        $critical.Severity | Should -Be 'Critical'
        $critical.IsCritical | Should -BeTrue
    }

    It 'does not treat enabled replication with missing evidence as healthy' {
        $result = Get-HyperVReplicationAssessment -Enabled $true -State '' -Health '' -Mode ''
        $result.Severity | Should -Be 'Unknown'
        $result.IsConcern | Should -BeTrue
    }

    It 'raises a warning when typed replication measurements exceed configured thresholds' {
        $result = Get-HyperVReplicationAssessment -Enabled $true -State 'Replicating' -Health 'Normal' -Mode 'Primary' `
            -MeasurementsAvailable $true -LastReplicationTimeUtc ([datetime]'2026-01-01T10:00:00Z') `
            -PendingBytes (2GB) -LatencySeconds 400 -MissedCount 3 -NowUtc ([datetime]'2026-01-01T12:00:00Z') `
            -MaxAgeMinutes 60 -MaxPendingMB 1024 -MaxLatencySeconds 300 -MaxMissedCount 0
        $result.Severity | Should -Be 'Warning'
        $result.IsConcern | Should -BeTrue
        $result.ThresholdBreaches | Should -Contain 'LastReplicationAge'
        $result.ThresholdBreaches | Should -Contain 'PendingBytes'
        $result.ThresholdBreaches | Should -Contain 'Latency'
        $result.ThresholdBreaches | Should -Contain 'MissedCount'
    }

    It 'keeps one missed cycle advisory when product health is Normal' {
        $result = Get-HyperVReplicationAssessment -Enabled $true -State 'Replicating' -Health 'Normal' -Mode 'Primary' `
            -MeasurementsAvailable $true -FrequencySeconds 300 -SuccessfulCount 287 -MissedCount 1
        $result.ProductSeverity | Should -Be 'Healthy'
        $result.MeasurementStatus | Should -Be 'Advisory'
        $result.HasAdvisory | Should -BeTrue
        $result.IsConcern | Should -BeFalse
        $result.AdvisoryBreaches | Should -Contain 'MissedCount'
    }

    It 'uses normal replication size to avoid an absolute-backlog false concern' {
        $result = Get-HyperVReplicationAssessment -Enabled $true -State 'Replicating' -Health 'Normal' -Mode 'Primary' `
            -MeasurementsAvailable $true -FrequencySeconds 300 -AverageReplicationBytes (2GB) -PendingBytes (1500MB)
        $result.ThresholdBreaches | Should -Contain 'PendingBytes'
        $result.AdvisoryBreaches | Should -Contain 'PendingBytes'
        $result.EffectiveMaxPendingBytes | Should -Be (4GB)
        $result.MeasurementStatus | Should -Be 'Advisory'
        $result.IsConcern | Should -BeFalse
    }
}

Describe 'Structured Hyper-V event attribution' {
    BeforeAll {
        $script:TestVmId = (('1' * 8), ('1' * 4), ('1' * 4), ('1' * 4), ('1' * 12)) -join '-'
        $script:UpperTestVmId = (('A' * 8), ('B' * 4), ('C' * 4), ('D' * 4), ('E' * 12)) -join '-'
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
    }

    It 'does not attribute a prefix VM name to a longer structured name' {
        $result = Resolve-HyperVEventAttribution -Message "Virtual machine 'APP010' failed." -VMName 'APP01' -VMId $script:TestVmId
        $result.Attributed | Should -BeFalse
        $result.Method | Should -Be 'StructuredName'
    }

    It 'matches structured names exactly even when the name contains regex characters' {
        $result = Resolve-HyperVEventAttribution -Message 'Virtual machine "APP[01]" failed.' -VMName 'APP[01]' -VMId $script:TestVmId
        $result.Attributed | Should -BeTrue
        $result.Confidence | Should -Be 'High'
    }

    It 'normalizes GUID braces and case and gives GUID evidence precedence' {
        $result = Resolve-HyperVEventAttribution -Message ("Virtual machine ID {{$($script:UpperTestVmId)}}; Virtual machine 'OTHER'.") -VMName 'APP01' -VMId $script:UpperTestVmId.ToLowerInvariant()
        $result.Attributed | Should -BeTrue
        $result.Method | Should -Be 'StructuredGuid'
    }

    It 'uses bounded fallback only when no structured identifier exists' {
        $match = Resolve-HyperVEventAttribution -Message 'Checkpoint operation failed for APP01.' -VMName 'APP01' -VMId $script:TestVmId
        $prefix = Resolve-HyperVEventAttribution -Message 'Checkpoint operation failed for APP010.' -VMName 'APP01' -VMId $script:TestVmId
        $path = Resolve-HyperVEventAttribution -Message 'Disk path C:\VMs\APP01\disk.vhdx could not be read.' -VMName 'APP01' -VMId $script:TestVmId
        $match.Attributed | Should -BeTrue
        $match.Confidence | Should -Be 'Low'
        $prefix.Attributed | Should -BeFalse
        $path.Attributed | Should -BeFalse
    }
}

Describe 'Hyper-V event signal taxonomy' {
    BeforeAll {
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
        $script:TestEventPolicy = Get-HyperVEventPolicy
    }

    It 'treats Replica change-tracking and resync HRESULTs as leading only' {
        foreach ($code in @('0x800480BD', '0x800480BC')) {
            $result = Get-HyperVEventSignalAssessment -EventId 0 -Log 'VMMS' -Message "Replica operation failed ($code)." -Policy $script:TestEventPolicy
            $result.Role | Should -Be 'Leading'
            $result.IsConfirmingFork | Should -BeFalse
        }
    }

    It 'requires checkpoint context for event 3216 and file-invalid confirmation' {
        $unrelated = Get-HyperVEventSignalAssessment -EventId 3216 -Log 'Worker' -Message 'An unrelated operation failed.' -Policy $script:TestEventPolicy
        $confirmed = Get-HyperVEventSignalAssessment -EventId 3216 -Log 'Worker' -Message 'Failed to switch checkpoint differencing disks (0x800703EE).' -Policy $script:TestEventPolicy
        $unrelated.IsConfirmingFork | Should -BeFalse
        $confirmed.IsConfirmingFork | Should -BeTrue
    }

    It 'treats commit-forks HRESULT as confirming regardless of numeric event reuse' {
        $result = Get-HyperVEventSignalAssessment -EventId 18590 -Log 'VMMS' -Message 'Checkpoint failed with 0x80048102.' -Policy $script:TestEventPolicy
        $result.Role | Should -Be 'Confirming'
        $result.IsConfirmingFork | Should -BeTrue
    }

    It 'keeps sharing violations and merge failures operational rather than confirming' {
        $result = Get-HyperVEventSignalAssessment -EventId 19100 -Log 'VMMS' -Message 'Merge failed with 0x80070020.' -Policy $script:TestEventPolicy
        $result.Role | Should -Be 'Operational'
        $result.IsConfirmingFork | Should -BeFalse
    }
}

Describe 'Hyper-V operation recovery correlation' {
    BeforeAll {
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
    }

    It 'never resolves a configuration-load failure with a later merge completion' {
        $events = @(
            [pscustomobject]@{ Id = 16300; 'Time (UTC)' = '2026-01-01 10:00:00'; FullMessage = 'Configuration could not load.' }
            [pscustomobject]@{ Id = 19080; 'Time (UTC)' = '2026-01-01 10:01:00'; FullMessage = 'Background merge completed.' }
        )
        (Resolve-HyperVOperationRecovery -Events $events -MaxMinutes 30).Status | Should -Be 'Unresolved'
    }

    It 'does not pair a completion outside the bounded operation window' {
        $events = @(
            [pscustomobject]@{ Id = 19100; 'Time (UTC)' = '2026-01-01 10:00:00'; FullMessage = 'Merge operation failed.' }
            [pscustomobject]@{ Id = 19080; 'Time (UTC)' = '2026-01-01 11:00:00'; FullMessage = 'Background merge completed.' }
        )
        (Resolve-HyperVOperationRecovery -Events $events -MaxMinutes 30).Status | Should -Be 'Unresolved'
    }

    It 'labels a bounded time-only pairing as apparently recovered' {
        $events = @(
            [pscustomobject]@{ Id = 19100; 'Time (UTC)' = '2026-01-01 10:00:00'; FullMessage = 'Merge operation failed.' }
            [pscustomobject]@{ Id = 19080; 'Time (UTC)' = '2026-01-01 10:05:00'; FullMessage = 'Background merge completed.' }
        )
        $result = Resolve-HyperVOperationRecovery -Events $events -MaxMinutes 30
        $result.Status | Should -Be 'ApparentlyRecovered'
        $result.CausalMatchCount | Should -Be 0
    }

    It 'does not treat a later merge completion as recovery for checkpoint request failure 18012' {
        $events = @(
            [pscustomobject]@{ Id = 18012; 'Time (UTC)' = '2026-01-01 10:00:00'; FullMessage = 'Checkpoint operation failed.' }
            [pscustomobject]@{ Id = 19080; 'Time (UTC)' = '2026-01-01 10:05:00'; FullMessage = 'Background merge completed.' }
        )
        $result = Resolve-HyperVOperationRecovery -Events $events -MaxMinutes 30
        $result.Status | Should -Be 'Unresolved'
        $result.UnresolvedCount | Should -Be 1
    }

    It 'confirms recovery when failure and completion share an exact disk path' {
        $events = @(
            [pscustomobject]@{ Id = 19100; 'Time (UTC)' = '2026-01-01 10:00:00'; FullMessage = 'Merge failed for C:\ClusterStorage\Volume1\VM-TEST\disk-test.avhdx.' }
            [pscustomobject]@{ Id = 19080; 'Time (UTC)' = '2026-01-01 10:03:00'; FullMessage = 'Merge completed for C:\ClusterStorage\Volume1\VM-TEST\disk-test.avhdx.' }
        )
        $result = Resolve-HyperVOperationRecovery -Events $events -MaxMinutes 30
        $result.Status | Should -Be 'ConfirmedRecovered'
        $result.CausalMatchCount | Should -Be 1
    }
}

Describe 'VM collection state consistency' {
    BeforeAll {
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
    }

    It 'treats reordered case-variant disk paths as the same state' {
        $start = [pscustomobject]@{ OwnerNode = 'NODE-A'; State = 'Running'; CheckpointCount = 1; DiskPaths = @('C:\CSV\disk-b.vhdx', 'C:\CSV\disk-a.vhdx'); ConfigLastWriteUtc = '2026-01-01T10:00:00Z' }
        $end = [pscustomobject]@{ OwnerNode = 'node-a'; State = 'Running'; CheckpointCount = 1; DiskPaths = @('c:\csv\DISK-A.vhdx', 'c:\csv\disk-b.vhdx'); ConfigLastWriteUtc = '2026-01-01T10:00:00Z' }
        (Compare-VMCollectionStateToken -StartToken $start -EndToken $end).Changed | Should -BeFalse
    }

    It 'reports owner, checkpoint, and disk changes independently' {
        $start = [pscustomobject]@{ OwnerNode = 'NODE-A'; State = 'Running'; CheckpointCount = 0; DiskPaths = @('C:\CSV\disk-a.vhdx'); ConfigLastWriteUtc = '2026-01-01T10:00:00Z' }
        $end = [pscustomobject]@{ OwnerNode = 'NODE-B'; State = 'Running'; CheckpointCount = 1; DiskPaths = @('C:\CSV\disk-b.vhdx'); ConfigLastWriteUtc = '2026-01-01T10:00:00Z' }
        $result = Compare-VMCollectionStateToken -StartToken $start -EndToken $end
        $result.Changed | Should -BeTrue
        $result.Reasons | Should -Contain 'OwnerNode'
        $result.Reasons | Should -Contain 'CheckpointCount'
        $result.Reasons | Should -Contain 'DiskPaths'
    }

    It 'reports VM state and configuration timestamp changes' {
        $start = [pscustomobject]@{ OwnerNode = 'NODE-A'; State = 'Running'; CheckpointCount = 0; DiskPaths = @(); ConfigLastWriteUtc = '2026-01-01T10:00:00Z' }
        $end = [pscustomobject]@{ OwnerNode = 'NODE-A'; State = 'Off'; CheckpointCount = 0; DiskPaths = @(); ConfigLastWriteUtc = '2026-01-01T10:05:00Z' }
        $result = Compare-VMCollectionStateToken -StartToken $start -EndToken $end
        $result.Reasons | Should -Contain 'State'
        $result.Reasons | Should -Contain 'ConfigLastWriteUtc'
    }
}

Describe 'Per-VM cluster orphan candidate selection' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        Import-Module $modulePath -Force
    }

    It 'excludes another VMs attached AVHDX and returns only the unowned candidate' {
        $ownedPath = 'C:\TEST\CSV01\TEST-VM-01\owned-by-other.avhdx'
        $candidatePath = 'C:\TEST\CSV01\TEST-VM-01\unowned.avhdx'
        $inventory = @(
            [pscustomobject]@{ Name = 'owned-by-other.avhdx'; FullName = $ownedPath }
            [pscustomobject]@{ Name = 'unowned.avhdx'; FullName = $candidatePath }
            [pscustomobject]@{ Name = 'base.vhdx'; FullName = 'C:\TEST\CSV01\TEST-VM-01\base.vhdx' }
        )
        $ownership = @([pscustomobject]@{ VMName = 'TEST-VM-02'; Path = $ownedPath })

        $result = Get-VMOrphanCandidatesFromClusterInventory -Inventory $inventory -Ownership $ownership `
            -CurrentVMName 'TEST-VM-01' -VhdFolders @('C:\TEST\CSV01\TEST-VM-01') -CoverageComplete $true

        @($result).Count | Should -Be 1
        $result[0].FullName | Should -Be $candidatePath
    }

    It 'returns no orphan candidates when any required coverage is incomplete' {
        $result = Get-VMOrphanCandidatesFromClusterInventory `
            -Inventory @([pscustomobject]@{ Name = 'unknown.avhdx'; FullName = 'C:\TEST\CSV01\TEST-VM-01\unknown.avhdx' }) `
            -Ownership @() -CurrentVMName 'TEST-VM-01' -VhdFolders @('C:\TEST\CSV01\TEST-VM-01') `
            -CoverageComplete $false

        @($result).Count | Should -Be 0
    }

    It 'does not return a VHD Set-managed AVHDX as a per-VM orphan candidate' {
        $managedFolder = 'C:\TEST\CSV01\GuestCluster'
        $result = Get-VMOrphanCandidatesFromClusterInventory `
            -Inventory @([pscustomobject]@{ Name = 'data-guid.avhdx'; FullName = "$managedFolder\data-guid.avhdx" }) `
            -Ownership @() -CurrentVMName 'GUEST-NODE-01' -VhdFolders @($managedFolder) `
            -CoverageComplete $true -VhdSetManagedFolders @($managedFolder.ToLowerInvariant())

        @($result).Count | Should -Be 0
    }
}

Describe 'Cluster virtual disk runtime collectors' {
    BeforeAll {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        $modulePath = Join-Path $toolRoot 'Get-HyperVVMCheckpointHealth.psm1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
        foreach ($functionName in @('Get-ClusterVirtualDiskOwnershipInventory', 'Get-ClusterVirtualDiskFileInventory')) {
            $functionAst = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            $functionAst | Should -Not -BeNullOrEmpty
            Invoke-Expression $functionAst.Extent.Text
        }
        function Get-VM { }
        function Get-VMHardDiskDrive { param($VM, $VMSnapshot) }
        function Get-VMSnapshot { param($VM) }
        function Get-VHD { param($Path) }
        function Add-AuditDiagnosticMessage { param($Message, $Operation, $Scope) }
        function Add-AuditDiagnostic { param($ErrorRecord, $Operation, $Scope) }
        function Invoke-WithRetry { param($ScriptBlock, $DiagnosticOperation, $DiagnosticScope) & $ScriptBlock }
    }

    It 'recursively inventories all supported virtual disk extensions and reports root completeness' {
        $csvRoot = Join-Path $TestDrive 'CSV01'
        $nested = Join-Path $csvRoot 'Nested'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        foreach ($name in @('base.vhd', 'data.vhdx', 'checkpoint.avhdx', 'guest-cluster.vhds', 'ignore.txt')) {
            New-Item -ItemType File -Path (Join-Path $nested $name) -Force | Out-Null
        }
        $csv = [pscustomobject]@{ SharedVolumeInfo = [pscustomobject]@{ FriendlyVolumeName = $csvRoot } }

        $result = Get-ClusterVirtualDiskFileInventory -CsvVolumes @($csv) `
            -TargetNode $env:COMPUTERNAME -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeTrue
        @($result.Files).Count | Should -Be 4
        @($result.Files.Extension | Sort-Object) | Should -Be @('.avhdx', '.vhd', '.vhds', '.vhdx')
        @($result.Roots).Count | Should -Be 1
        $result.Roots[0].Complete | Should -BeTrue
    }

    It 'skips System Volume Information without making CSV coverage incomplete' {
        $csvRoot = Join-Path $TestDrive 'CSV-SystemMetadata'
        $workload = Join-Path $csvRoot 'Workload'
        $systemMetadata = Join-Path $csvRoot 'System Volume Information'
        New-Item -ItemType Directory -Path $workload,$systemMetadata -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $workload 'workload.vhdx') -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $systemMetadata 'ignored.vhdx') -Force | Out-Null
        $csv = [pscustomobject]@{ SharedVolumeInfo = [pscustomobject]@{ FriendlyVolumeName = $csvRoot } }

        $result = Get-ClusterVirtualDiskFileInventory -CsvVolumes @($csv) `
            -TargetNode $env:COMPUTERNAME -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeTrue
        @($result.Files).Count | Should -Be 1
        $result.Files[0].Name | Should -Be 'workload.vhdx'
        @($result.PathErrors).Count | Should -Be 0
        @($result.SkippedPaths).Count | Should -Be 1
        $result.SkippedPaths[0] | Should -Be $systemMetadata
    }

    It 'retains readable files and records an unexpected inaccessible sub-folder' {
        $csvRoot = Join-Path $TestDrive 'CSV-Partial'
        $readable = Join-Path $csvRoot 'Readable'
        $blocked = Join-Path $csvRoot 'Blocked'
        New-Item -ItemType Directory -Path $readable,$blocked -Force | Out-Null
        New-Item -ItemType File -Path (Join-Path $readable 'readable.avhdx') -Force | Out-Null
        $csv = [pscustomobject]@{ SharedVolumeInfo = [pscustomobject]@{ FriendlyVolumeName = $csvRoot } }
        Mock Get-ChildItem {
            throw [System.UnauthorizedAccessException]::new("Access to the path '$blocked' is denied.")
        } -ParameterFilter { $LiteralPath -eq $blocked }

        $result = Get-ClusterVirtualDiskFileInventory -CsvVolumes @($csv) `
            -TargetNode $env:COMPUTERNAME -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeFalse
        @($result.Files).Count | Should -Be 1
        $result.Files[0].Name | Should -Be 'readable.avhdx'
        @($result.PathErrors).Count | Should -Be 1
        $result.PathErrors[0].Path | Should -Be $blocked
        $result.PathErrors[0].IsRoot | Should -BeFalse
        $result.Errors[0] | Should -Match 'Blocked'
    }

    It 'uses distinct housekeeping categories for root and CSV folder inventory failures' {
        $source = Get-Content -LiteralPath $modulePath -Raw
        $source | Should -Match 'if \(\$pathError\.IsRoot\) \{ ''CSV root incomplete'' \} else \{ ''CSV folder path inaccessible'' \}'
    }

    It 'returns structured root failures when the inventory command cannot run' {
        $csvRoot = Join-Path $TestDrive 'CSV-RemoteFailure'
        $csv = [pscustomobject]@{ SharedVolumeInfo = [pscustomobject]@{ FriendlyVolumeName = $csvRoot } }
        Mock New-PSSession { throw 'Remote session unavailable.' }

        $result = Get-ClusterVirtualDiskFileInventory -CsvVolumes @($csv) `
            -TargetNode 'REMOTE-NODE' -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeFalse
        @($result.Files).Count | Should -Be 0
        @($result.PathErrors).Count | Should -Be 1
        $result.PathErrors[0].Path | Should -Be $csvRoot
        $result.PathErrors[0].IsRoot | Should -BeTrue
        @($result.SkippedPaths).Count | Should -Be 0
        @($result.Roots[0].PathErrors).Count | Should -Be 1
    }

    It 'collects current, snapshot, and parent-chain ownership paths with workload counts' {
        Mock Get-VM { [pscustomobject]@{ Name = 'TEST-VM-01'; ConfigurationLocation = 'C:\TEST\CSV01\TEST-VM-01' } }
        Mock Get-VMHardDiskDrive {
            if ($VMSnapshot) { [pscustomobject]@{ Path = 'C:\TEST\CSV01\TEST-VM-01\snapshot.avhdx' } }
            else { [pscustomobject]@{ Path = 'C:\TEST\CSV01\TEST-VM-01\current.avhdx' } }
        }
        Mock Get-VMSnapshot { [pscustomobject]@{ Name = 'TEST-SNAPSHOT-01' } }
        Mock Get-VHD {
            switch ($Path) {
                'C:\TEST\CSV01\TEST-VM-01\current.avhdx' { [pscustomobject]@{ ParentPath = 'C:\TEST\CSV01\TEST-VM-01\base.vhdx' } }
                'C:\TEST\CSV01\TEST-VM-01\snapshot.avhdx' { [pscustomobject]@{ ParentPath = 'C:\TEST\CSV01\TEST-VM-01\snapshot-parent.vhdx' } }
                default { [pscustomobject]@{ ParentPath = $null } }
            }
        }

        $result = Get-ClusterVirtualDiskOwnershipInventory -Nodes @($env:COMPUTERNAME) `
            -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeTrue
        $result.VMCount | Should -Be 1
        $result.SnapshotCount | Should -Be 1
        @($result.Rows).Count | Should -Be 4
        @($result.Rows.Path) | Should -Contain 'C:\TEST\CSV01\TEST-VM-01\base.vhdx'
        @($result.Rows.Path) | Should -Contain 'C:\TEST\CSV01\TEST-VM-01\snapshot-parent.vhdx'
    }
}

Describe 'Virtual disk housekeeping classification' {
    BeforeAll {
        $script:ImageLibraryPathPatterns = @('(?i)[\\/](?:image|images|template|templates|library|gallery|golden)(?:[\\/]|$)')
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        Import-Module $modulePath -Force
    }

    It 'treats an unattached VHDX in a VM-associated folder as a placement review' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\TEST-VM-01\detached.vhdx' -Owners @() `
            -VMAssociatedFolders @([pscustomobject]@{ VMName = 'TEST-VM-01'; Path = 'C:\TEST\CSV01\TEST-VM-01' }) `
            -CoverageComplete $true -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'PlacementInconsistency'
        $result.HealthVerdictImpact | Should -BeFalse
    }

    It 'protects an ownerless AVHDX in an attached VHD Set directory from orphan conclusions' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\GuestCluster\data-guid.avhdx' -Owners @() `
            -VMAssociatedFolders @([pscustomobject]@{ VMName = 'GUEST-NODE-01'; Path = 'C:\TEST\CSV01\GuestCluster' }) `
            -CoverageComplete $true -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns `
            -VhdSetManagedFolders @('c:\test\csv01\guestcluster')

        $result.Classification | Should -Be 'VhdSetManagedAsset'
        $result.VhdSetManagedFolder | Should -Be 'c:\test\csv01\guestcluster'
        $result.HealthVerdictImpact | Should -BeFalse
    }

    It 'does not extend VHD Set protection into nested directories' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\GuestCluster\Archive\detached.avhdx' -Owners @() `
            -VMAssociatedFolders @() -CoverageComplete $true `
            -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns `
            -VhdSetManagedFolders @('C:\TEST\CSV01\GuestCluster')

        $result.Classification | Should -Be 'UnattachedDifferencingCandidate'
    }

    It 'does not hide an attached AVHDX in a VHD Set directory' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\GuestCluster\attached.avhdx' -Owners @('GUEST-NODE-01') `
            -VMAssociatedFolders @() -CoverageComplete $true `
            -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns `
            -VhdSetManagedFolders @('C:\TEST\CSV01\GuestCluster')

        $result.Classification | Should -Be 'AttachedVirtualDisk'
    }

    It 'classifies an unattached VHDS separately from base disks' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\GuestCluster\detached.vhds' -Owners @() `
            -VMAssociatedFolders @() -CoverageComplete $true `
            -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'UnattachedVhdSetCandidate'
        $result.HealthVerdictImpact | Should -BeFalse
    }

    It 'excludes an exact configured image-library path segment from housekeeping' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\Images\base-os.vhdx' -Owners @() -VMAssociatedFolders @() -CoverageComplete $true `
            -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'ExcludedImageLibraryAsset'
        $result.MatchedImageSegment | Should -Be 'Images'
    }

    It 'always excludes ImageStore VHDX and AVHDX paths before placement checks' {
        foreach ($path in @(
            'C:\TEST\CSV01\ImageStore\base-os.vhdx',
            'C:\TEST\CSV01\ImageStore\temporary-layer.avhdx'
        )) {
            $result = Get-VirtualDiskHousekeepingClassification `
                -Path $path -Owners @() `
                -VMAssociatedFolders @([pscustomobject]@{ VMName = 'TEST-VM-01'; Path = 'C:\TEST\CSV01' }) `
                -CoverageComplete $true -ImageLibraryPathPatterns @()

            $result.Classification | Should -Be 'ExcludedImageLibraryAsset'
            $result.MatchedImageSegment | Should -Be 'ImageStore'
        }
    }

    It 'always excludes versioned ARB CBL-Mariner appliance image VHDX files' {
        foreach ($fileName in @(
            'linux-cblmariner-0.11.26.10605.vhdx',
            'LINUX-CBLMARINER-12.3.456.78901.VHDX'
        )) {
            $result = Get-VirtualDiskHousekeepingClassification `
                -Path ("C:\TEST\CSV01\unassociated\{0}" -f $fileName) -Owners @() -VMAssociatedFolders @() `
                -CoverageComplete $true -ImageLibraryPathPatterns @()

            $result.Classification | Should -Be 'ExcludedImageLibraryAsset'
            $result.MatchedImageSegment | Should -Be $fileName
        }
    }

    It 'does not broadly exclude similar CBL-Mariner virtual disk names' {
        foreach ($case in @(
            [pscustomobject]@{ FileName = 'linux-cblmariner-latest.vhdx'; Expected = 'UnattachedBaseDiskCandidate' },
            [pscustomobject]@{ FileName = 'linux-cblmariner-0.11.26.10605-copy.vhdx'; Expected = 'UnattachedBaseDiskCandidate' },
            [pscustomobject]@{ FileName = 'linux-cblmariner-0.11.26.10605.avhdx'; Expected = 'UnattachedDifferencingCandidate' }
        )) {
            $result = Get-VirtualDiskHousekeepingClassification `
                -Path ("C:\TEST\CSV01\unassociated\{0}" -f $case.FileName) -Owners @() -VMAssociatedFolders @() `
                -CoverageComplete $true -ImageLibraryPathPatterns @()

            $result.Classification | Should -Be $case.Expected
        }
    }

    It 'omits excluded image assets and explains custom policy exclusions' {
        $source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1') -Raw
        $source | Should -Match "'ExcludedImageLibraryAsset', 'VhdSetManagedAsset'"
        $source | Should -Match 'exclude its full path with storage\.imageLibraryPathPatterns'
        $source | Should -Match 'checkpoint-health-policy\.yml file supplied via -PolicyPath'
    }

    It 'documents and reports VHD Set-managed storage conservatively' {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        $source = Get-Content -LiteralPath (Join-Path $toolRoot 'Get-HyperVVMCheckpointHealth.psm1') -Raw
        $storageSource = Get-Content -LiteralPath (Join-Path $toolRoot 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1') -Raw
        $readme = Get-Content -LiteralPath (Join-Path $toolRoot 'README.md') -Raw

        $source | Should -Match 'Category\s+= if \(\$isVhdSet\) \{ ''Shared VHD Set reference'' \}'
        $source | Should -Match "'ExcludedImageLibraryAsset', 'VhdSetManagedAsset'"
        $source | Should -Match '\$currentVmVhdSetManagedFolders = @\('
        $source | Should -Match '\$_\.VMName -eq \$VMName'
        $source | Should -Match '''n/a \(shared VHD Set\)'''
        $source | Should -Match '''Active VHD Set \(top\)'''
        $storageSource | Should -Match 'https://learn\.microsoft\.com/en-us/windows-server/virtualization/hyper-v/manage/create-vhdset-file'
        $readme | Should -Match 'ownerless `\.avhdx` files in that exact attached-VHDS directory'
    }

    It 'does not use an incidental image substring as an image-library hint' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\image-processing-vm\data.vhdx' -Owners @() -VMAssociatedFolders @() -CoverageComplete $true `
            -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'UnattachedBaseDiskCandidate'
    }

    It 'classifies an unattached AVHDX separately from an unattached base disk' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\unassociated\disk.avhdx' -Owners @() -VMAssociatedFolders @() -CoverageComplete $true `
            -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'UnattachedDifferencingCandidate'
    }

    It 'accepts the empty owner collection produced for an unowned inventory path' {
        $ownersByPath = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.HashSet[string]]' ([System.StringComparer]::OrdinalIgnoreCase)
        $diskOwners = if ($ownersByPath.ContainsKey('C:\TEST\CSV01\unassociated\disk.avhdx')) { @('TEST-VM-01') } else { @() }

        {
            Get-VirtualDiskHousekeepingClassification `
                -Path 'C:\TEST\CSV01\unassociated\disk.avhdx' -Owners $diskOwners -VMAssociatedFolders @() -CoverageComplete $true `
                -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns
        } | Should -Not -Throw
    }

    It 'makes incomplete coverage override image and unattached classifications' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\Images\base-os.vhdx' -Owners @() -VMAssociatedFolders @() -CoverageComplete $false `
            -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'OwnershipAmbiguous'
    }
}
