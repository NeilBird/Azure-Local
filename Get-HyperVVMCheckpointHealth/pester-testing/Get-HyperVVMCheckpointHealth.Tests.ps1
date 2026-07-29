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
        $script:RenderingSource = Get-Content -LiteralPath $script:RenderingModulePath -Raw
        $script:StorageSource = Get-Content -LiteralPath $script:StorageModulePath -Raw
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

    It 'opens every external renderer link safely in a new tab' {
        $externalAnchors = @([regex]::Matches($script:RenderingSource, '<a\s+[^>]*href=(["''])https?://[^>]*>'))
        $externalAnchors.Count | Should -BeGreaterThan 0
        @($externalAnchors | Where-Object { $_.Value -notmatch '\starget=(["''])_blank\1' }).Count | Should -Be 0
        @($externalAnchors | Where-Object { $_.Value -notmatch '\srel=(["''])noopener noreferrer\1' }).Count | Should -Be 0
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

    It 'prefetches node diagnostics with bounded concurrency before input and discovered audits' {
        $script:Source | Should -Match 'function Get-NodeDiagnosticSnapshot'
        $script:Source | Should -Match 'function Invoke-NodeDiagnosticPrefetch'
        $script:Source | Should -Match 'function Initialize-NodeDiagnosticPrefetch'
        $script:Source | Should -Match '-ThrottleLimit 4 -SkipEvents:\$SkipEvents'
        $script:Source | Should -Match '\$initialDiagnosticNodes[\s\S]*?Initialize-NodeDiagnosticPrefetch[\s\S]*?foreach \(\$name in \$script:PendingVMNames\)'
        $script:Source | Should -Match '\$discoveredDiagnosticNodes[\s\S]*?Initialize-NodeDiagnosticPrefetch[\s\S]*?foreach \(\$dv in \$toAudit\)'
        $script:Source | Should -Match "Add-TelemetryEntry -Step '1\.08\.10' -Phase 'Node diagnostic prefetch coordination'"
        $script:Source | Should -Match "Add-TelemetryEntry -Step '1\.08\.10\.10' -Phase 'Event prefetch worker'"
        $script:Source | Should -Match "Add-TelemetryEntry -Step '1\.08\.10\.20' -Phase 'VSS prefetch worker'"
        $script:Source | Should -Match 'NodePrefetchMode\s*=\s*if'
        $script:Source | Should -Match 'NodePrefetchThrottle\s*=\s*if'
        $script:Source | Should -Match 'NodePrefetchNodes\s*=\s*@\('
        $script:Source | Should -Match 'NodePrefetchFailed\s*=\s*@\('
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

    It 'collects storage Health Service faults as read-only evidence only' {
        $script:StorageSource | Should -Match 'Get-HealthFault -ErrorAction Stop'
        $script:StorageSource | Should -Match 'HealthFaultCollectionStatus'
        $script:StorageSource | Should -Match 'HealthFaultCollection\s*='
        $script:StorageSource | Should -Match 'ExceptionType\s*=\s*\$_\.Exception\.GetType\(\)\.FullName'
        $script:StorageSource | Should -Match 'ErrorCategory\s*='
        $script:StorageSource | Should -Match 'Microsoft\\\.Health\\\.\(\?:FaultType\|EntityType\)'
        $script:StorageSource | Should -Match 'FaultDomain\|PhysicalDisk\|StorageEnclosure\|StoragePool\|StorageScaleUnit\|VirtualDisks\|Volume'
        $script:StorageSource | Should -Match '@\(\$Snapshot\.HealthFaults\)\.Count -gt 0'
        $script:StorageSource | Should -Match '\$summary = Get-StorageHealthSummary -Snapshot \$raw'
        $script:StorageSource | Should -Match 'RecommendedActions\s+= if \(\$_\.PSObject\.Properties\[''RecommendedActions''\]\)'
        $script:StorageSource | Should -Not -Match 'Debug-StorageSubSystem|Repair-Storage|Set-Storage|Start-Storage'
    }

    It 'distinguishes successful-empty and failed Health Service collection in HTML' {
        $script:RenderingSource | Should -Match 'Health Service collection status: Success; zero active faults returned'
        $script:RenderingSource | Should -Match 'Health Service collection status: Failed'
        $script:RenderingSource | Should -Match 'missing fault detail does not negate an observed unhealthy subsystem'
        $script:RenderingSource | Should -Match 'Review the run debug log for full diagnostic context'
    }

    It 'keeps remote storage fault filtering self-contained' {
        $script:StorageSource | Should -Match '\$scan\s*=\s*\{\s*param\(\$StorageFaultTypePattern\)'
        $script:StorageSource | Should -Match 'Invoke-Command.+-ArgumentList \$storageFaultTypePattern'
        $script:StorageSource | Should -Not -Match 'Where-Object \{ Test-StorageHealthFault'
    }

    It 'preserves conservative historic and skipped-event behavior' {
        $script:Source | Should -Match 'if \(-not \$SkipWorkerEvents -and @\(\$orphans\)\.Count -gt 0'
        $script:Source | Should -Match "Operation 'Historic event correlation around orphan timestamps'"
        $script:Source | Should -Match "Operation 'Historic event correlation around active checkpoint creation'"
        $script:Source | Should -Match '\$activeCkptHistoric\s*=\s*\$null\s*\$activeCkptCoverageIncomplete\s*=\s*\$true'
    }

    It 'uses the snapshot node rather than the cache key in fleet event context' {
        $script:Source | Should -Match 'Node\s*=\s*\[string\]\$OwningNode'
        $script:Source | Should -Match 'Node\s*=\s*if \(\$nodeEventSnapshot\.PSObject\.Properties\[''Node''\]\)'
    }

    It 'initializes Replica server settings for disabled relationships' {
        $script:Source | Should -Match '\$replicationServerSettings\s*=\s*\$null'
    }

    It 'keeps node event scan failures distinct from successful empty results' {
        $script:Source | Should -Match '\$script:NodeEventCache\[\$nodeCacheKey\]\s*=\s*\[pscustomobject\]'
        $script:Source | Should -Not -Match '\$script:NodeEventCache\[\$nodeCacheKey\]\s*=\s*\$null'
        $script:Source | Should -Match 'EventCollectionStatus\s*=\s*\[pscustomobject\]'
        $script:Source | Should -Match '\$cachedNodeEvents\s*=\s*\$null\s*if\s*\(\$cachedNodeSnapshot\.Status\s*-eq\s*''Success''\)\s*\{\s*\[object\[\]\]\$cachedNodeEvents\s*=\s*@\(\$cachedNodeSnapshot\.Rows\)'
        $script:Source | Should -Match '\$workerEvents\s*=\s*\$null\s*if\s*\(\$null\s*-ne\s*\$cachedNodeEvents\)\s*\{\s*\[object\[\]\]\$workerEvents\s*=\s*@\('
    }

    It 'finalizes complete PassThru automation rows only after run artifacts exist' {
        $script:Source | Should -Not -Match 'if \(\$PassThru\) \{ \$vmSummary \}'
        $script:Source | Should -Not -Match 'if \(\$PassThru\) \{ \$s \}'
        $script:Source | Should -Match 'VmEvents\s*=\s*@\(\$workerEvents\s*\|\s*Where-Object\s*\{\s*\$_\.VmAttributed\s*\}'
        $script:Source | Should -Match '\$runData\s*=\s*\[pscustomobject\]\[ordered\]@\{'
        $script:Source | Should -Match 'HousekeepingFindings\s*=\s*\$script:HousekeepingFindings\.ToArray\(\)'
        $script:Source | Should -Match 'StorageHealth\s*=\s*\$script:ClusterStorageHealth'
        $script:Source | Should -Match 'NodeEventContext\s*=\s*\$nodeEventContext'
        $script:Source | Should -Match 'Complete-CheckpointHealthPassThruResult\s+-Result\s+\$auditResult\s+-RunData\s+\$runData'
        $script:Source | Should -Match 'VMsProcessed\s*=\s*\$script:AllAuditResults\.Count'
        $script:Source | Should -Match 'VMsFullyAssessed\s*=\s*@\(\$script:AllAuditResults\s*\|\s*Where-Object'
        $script:Source | Should -Match 'Processed\s*=\s*\$script:AllAuditResults\.Count'
        $script:Source | Should -Match 'FullyAssessed\s*=\s*@\(\$script:AllAuditResults\s*\|\s*Where-Object'
    }

    It 'uses the Hyper-V canonical VM name for successful results and artifacts' {
        $script:Source | Should -Match 'Name\s*=\s*\[string\]\$v\.Name'
        $script:Source | Should -Match 'if \(\$vm\.Name\) \{\s*\$VMName\s*=\s*\[string\]\$vm\.Name'
        $script:Source | Should -Match '\$reportFile\s*=\s*Join-Path \$OutputPath \("\{0\}_VMAudit_\{1\}\.txt" -f \$safeName, \$reportTimestamp\)'
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
        $script:Source | Should -Match '\$stateInconclusive\s*=\s*\(\$stateConsistencyImpact\s*-eq\s*''Inconclusive''\)'
        $script:Source | Should -Match '\$investigate\s*=\s*\$true'
        $script:Source | Should -Match 'StateConsistency\s*=\s*\[pscustomobject\]'
    }

    It 'keeps healthy Replica-only configuration writes advisory' {
        $script:Source | Should -Match '\$stateConsistencyImpact\s*=\s*Get-VMCollectionStateImpact'
        $script:Source | Should -Match '\$replicaConfigWriteAdvisory\s*=\s*\(\$stateConsistencyImpact\s*-eq\s*''Advisory''\)'
        $script:Source | Should -Match 'StateConsistencyImpact\s*=\s*\[string\]\$stateConsistencyImpact'
    }

    It 'builds event driver counts and ID labels from the same escalating subset' {
        $script:Source | Should -Match '\$vmEscalatingConcernEvents\s*=\s*@\(\$vmCriticalEvents\)'
        $script:Source | Should -Match '\$vmEscalatingConcernCount\s*=\s*@\(\$vmEscalatingConcernEvents\)\.Count'
        $script:Source | Should -Match '\$vmEscalatingIdSummary\s*=\s*\(@\(\$vmEscalatingConcernEvents\s*\|\s*Group-Object Id'
        $script:Source | Should -Match '\$vmEscalatingConcernCount,\s*\$vmEscalatingIdSummary'
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

    It 'includes unhealthy VSS in the shared driver model only when unhealthy writers were collected' {
        $script:Source | Should -Match '\$hasVssDriver\s*=\s*\(\$vssUnhealthy\.Count -gt 0\)'
        $script:Source | Should -Match '(?s)if \(\$hasVssDriver\) \{ \[void\]\$investigationDriverLabels\.Add\(\("\{0\} unhealthy VSS writer\(s\)" -f \$vssUnhealthy\.Count\)\) \}'
        $script:Source | Should -Match "Resolve unhealthy VSS writers with the workload or backup owner"
        $script:Source | Should -Not -Match 'likely cause is a stalled / failed backup checkpoint or an unhealthy VSS writer rather than'
        $script:Source | Should -Not -Match 'likely a stalled / failed backup checkpoint or an unhealthy VSS writer'
    }

    It 'keeps HRL-only and event-artifact prose evidence-specific' {
        $script:Source | Should -Match 'Hyper-V Replica HRL files exceed the cadence-aware threshold with Replica corroboration'
        $script:Source | Should -Match 'full, untruncated Hyper-V event messages that back the event findings above'
        $script:Source | Should -Match 'full, untruncated Hyper-V event messages retained as context; no event row drives this verdict'
        $script:Source | Should -Not -Match 'messages that back the findings above'
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
        $script:Source | Should -Match 'WorkerDurationMs\s+=\s+\[long\]\$workerStopwatch\.ElapsedMilliseconds'
        $script:Source | Should -Match 'WorkerStartUtc\s+=\s+\$workerStartUtc'
        $script:Source | Should -Match 'WorkerEndUtc\s+=\s+\[DateTime\]::UtcNow'
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

    It 'uses native event identity for deterministic ordering and structured CSV projection' {
        ([regex]::Matches($script:Source, 'RecordId\s*=\s*\[long\]\$eventRecord\.RecordId')).Count | Should -Be 2
        $script:Source | Should -Match "Sort-Object 'Time \(UTC\)', Log, RecordId, Id, FullMessage"
        $script:AssessmentSource | Should -Match 'function ConvertTo-HyperVEventCsvRows'
        $script:AssessmentSource | Should -Match 'EvidenceScope\s*=\s*\$scope'
        $script:AssessmentSource | Should -Match 'CorrelationWindowStartUtc'
        $script:AssessmentSource | Should -Match 'IsConfirmingFork\s*=\s*\[bool\]\$signal\.IsConfirmingFork'
        $script:AssessmentSource | Should -Match '\$seen\.Add\(\$identityKey\)'
    }

    It 'normalizes Replica relationship timestamps to Zulu before stringification' {
        $script:Source | Should -Match 'LastReplicationTime\s*=\s*if \(\$r\.LastReplicationTime\)'
        $script:Source | Should -Match '\(\[datetime\]\$r\.LastReplicationTime\)\.ToUniversalTime\(\)\.ToString\(''yyyy-MM-dd HH:mm:ssZ''\)'
        $script:Source | Should -Not -Match 'LastReplicationTime\s*=\s*\[string\]\$r\.LastReplicationTime'
    }

    It 'renders historic correlation timestamps as Zulu without redundant UTC suffixes' {
        $script:Source | Should -Match "Windows\s+=.*ToUniversalTime\(\)\.ToString\('yyyy-MM-dd HH:mm:ssZ'\)"
        $script:Source | Should -Not -Match 'OldestAvailableUtc\) UTC'
        $script:Source | Should -Not -Match 'active checkpoint created \{0\} UTC'
        $script:Source | Should -Not -Match 'oldest available \{0\} UTC'
    }

    It 'explains former-owner historic provenance and names the structured artifact' {
        $script:Source | Should -Match 'current VM ownership does not invalidate VM-ID-attributed evidence from another cluster node'
        $script:Source | Should -Match "events CSV \(\{0\}\) includes the historic rows used by this verdict"
        $script:RenderingSource | Should -Match 'current VM ownership does not invalidate VM-ID-attributed evidence from another cluster node'
        $script:RenderingSource | Should -Match "structured rows used by this verdict are in this VM's events CSV"
    }

    It 'labels timestamp scope and uses artifact-specific safety language' {
        $script:Source | Should -Match 'Collection started \(UTC\)'
        $script:Source | Should -Match 'VM assessment completed \(UTC\)'
        $script:RenderingSource | Should -Match 'Fleet report finalized \(UTC\)'
        $script:RenderingSource | Should -Match 'Before modifying any checkpoint-related AVHDX/VHD artifact or differencing chain'
        $script:RenderingSource | Should -Not -Match 'before merging, removing, renaming, or deleting anything'
    }

    It 'documents explicit scope arithmetic and authoritative event CSV semantics' {
        $script:RenderingSource | Should -Match '\$inputCount input \+ \$autoAuditedCount automatically discovered = \$countAll processed'
        $script:RenderingSource | Should -Match 'Concern.*compatibility field.*CollectedAsConcern'
        $script:RenderingSource | Should -Match 'VerdictDriver.*authoritative'
    }

    It 'renders collection-state impact and detail without a stable advisory contradiction' {
        $script:RenderingSource | Should -Match 'Advisory - VM configuration \(\.vmcx\) timestamp changed during collection'
        $script:RenderingSource | Should -Match 'Inconclusive - material collection-state change'
        $script:RenderingSource | Should -Not -Match 'Stable - VM configuration \(\.vmcx\) file timestamp changed'
    }
}

Describe 'Per-VM event marker CSV contract' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
        $functionAst = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-VMEventsMarkerCsv'
        }, $true) | Select-Object -First 1
        Invoke-Expression $functionAst.Extent.Text
    }

    It 'writes a schema-consistent marker when a VM is not found' {
        $OutputPath = $TestDrive
        $VMName = 'MISSING-VM'
        $reportFile = Join-Path $TestDrive 'MISSING-VM_VMAudit_test.txt'

        $csvName = Write-VMEventsMarkerCsv -Message "VM 'MISSING-VM' was not found; event collection was not attempted."
        $row = Import-Csv -LiteralPath (Join-Path $TestDrive $csvName)

        @($row.PSObject.Properties.Name) | Should -Be @(
            'Time (UTC)', 'Node', 'Id', 'Level', 'Log', 'Concern', 'CollectedAsConcern', 'VmAttributed',
            'AttributionMethod', 'AttributionConfidence', 'EvidenceScope', 'CorrelationAnchor',
            'CorrelationWindowStartUtc', 'CorrelationWindowEndUtc', 'EventClassification',
            'VerdictDriver', 'IsConfirmingFork', 'RecoveryDisposition', 'DispositionReason', 'FullMessage'
        )
        $row.Level | Should -Be 'Info'
        $row.FullMessage | Should -Match 'was not found; event collection was not attempted'
        $row.EventClassification | Should -Be 'Informational'
        $row.VerdictDriver | Should -Be 'False'
        $row.RecoveryDisposition | Should -Be 'NotApplicable'
    }

    It 'keeps the NOT FOUND text report self-contained' {
        $source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1') -Raw

        $source | Should -Match 'RESULT: NOT FOUND - this VM was not fully assessed\. Do not treat it as healthy based on this report\.'
        $source | Should -Match 'Event collection was not attempted for the missing VM\.'
        $source | Should -Match "Rerun: Get-HyperVVMCheckpointHealth -VMName '<confirmed-name>' -Cluster"
        $source | Should -Match 'No checkpoint, disk, Replica, VSS, or event conclusion was produced for this VM\.'
    }
}

Describe 'Structured historic event evidence contract' {
    BeforeAll {
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
        $script:EventPolicy = Get-HyperVEventPolicy
    }

    It 'projects one confirming former-owner row from overlapping historic windows' {
        $message = "Checkpoint fork commit failed for VM 'ContosoVM01' (11111111-1111-1111-1111-111111111111) with 0x800703EE.`r`nPreserve evidence."
        $matches = @(
            [pscustomobject]@{ Time = '2026-07-01 10:00:00Z'; Node = 'Node01'; RecordId = 42; Id = 3216; Level = 'Error'; Log = 'Worker'; Message = $message.Split("`r")[0]; FullMessage = ($message -replace "`r?`n", ' | '); EvidenceScope = 'HistoricOrphanWindow'; CorrelationAnchor = 'OrphanCreate'; CorrelationWindowStartUtc = '2026-07-01 08:00:00Z'; CorrelationWindowEndUtc = '2026-07-01 12:00:00Z' }
            [pscustomobject]@{ Time = '2026-07-01 10:00:00Z'; Node = 'Node01'; RecordId = 42; Id = 3216; Level = 'Error'; Log = 'Worker'; Message = $message.Split("`r")[0]; FullMessage = ($message -replace "`r?`n", ' | '); EvidenceScope = 'HistoricOrphanWindow'; CorrelationAnchor = 'OrphanLastWrite'; CorrelationWindowStartUtc = '2026-07-01 09:00:00Z'; CorrelationWindowEndUtc = '2026-07-01 13:00:00Z' }
        )

        $rows = @(ConvertTo-HyperVEventCsvRows -Events $matches -Policy $script:EventPolicy `
            -VMName 'ContosoVM01' -VMId '11111111-1111-1111-1111-111111111111' -DefaultNode 'Node02')

        $rows.Count | Should -Be 1
        $rows[0].Node | Should -Be 'Node01'
        $rows[0].VmAttributed | Should -BeTrue
        $rows[0].AttributionMethod | Should -Be 'StructuredGuid'
        $rows[0].AttributionConfidence | Should -Be 'High'
        $rows[0].EvidenceScope | Should -Be 'HistoricOrphanWindow'
        $rows[0].CorrelationAnchor | Should -Be 'OrphanCreate'
        $rows[0].Concern | Should -Be 'YES'
        $rows[0].CollectedAsConcern | Should -BeTrue
        $rows[0].IsConfirmingFork | Should -BeTrue
        $rows[0].VerdictDriver | Should -BeTrue
        $rows[0].FullMessage | Should -Match 'Preserve evidence'
    }
}

Describe 'Cluster low-signal event flood contract' {
    BeforeAll {
        $renderingModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        Import-Module $renderingModulePath -Force
    }

    It 'surfaces sustained 15268 volume without producing a VM verdict' {
        $start = [datetime]'2026-07-01T00:00:00Z'
        $events = @(0..1999 | ForEach-Object {
            [pscustomobject]@{ 'Time (UTC)' = $start.AddSeconds($_ * 72).ToString('yyyy-MM-dd HH:mm:ssZ'); Id = 15268; FullMessage = 'Failed to get the disk information' }
        })

        $observations = @(Get-HyperVEventFloodObservations -NodeEventContext @([pscustomobject]@{ Node = 'Node01'; Events = $events }))

        $observations.Count | Should -Be 1
        $observations[0].Count | Should -Be 2000
        $observations[0].DurationMinutes | Should -BeGreaterThan 2398
        $observations[0].DistinctMessageCount | Should -Be 1
        $observations[0].PSObject.Properties.Name | Should -Not -Contain 'Recommendation'
    }

    It 'does not surface isolated low-signal rows' {
        $events = @(
            [pscustomobject]@{ 'Time (UTC)' = '2026-07-01 00:00:00Z'; Id = 15268; FullMessage = 'Failed to get the disk information' }
            [pscustomobject]@{ 'Time (UTC)' = '2026-07-02 00:00:00Z'; Id = 15268; FullMessage = 'Failed to get the disk information' }
            [pscustomobject]@{ 'Time (UTC)' = '2026-07-03 00:00:00Z'; Id = 15268; FullMessage = 'Failed to get the disk information' }
            [pscustomobject]@{ 'Time (UTC)' = '2026-07-04 00:00:00Z'; Id = 15268; FullMessage = 'Failed to get the disk information' }
        )

        @(Get-HyperVEventFloodObservations -NodeEventContext @([pscustomobject]@{ Node = 'Node01'; Events = $events })).Count | Should -Be 0
    }
}

Describe 'TXT Replica effective-limit evidence' {
    BeforeAll {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        $modulePath = Join-Path $toolRoot 'Get-HyperVVMCheckpointHealth.psm1'
        Import-Module (Join-Path $toolRoot 'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1') -Force
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
        foreach ($functionName in @('ConvertTo-AuditByteText', 'Get-ReplicaMeasurementEvidenceText', 'Get-ReplicaAssessmentRows')) {
            $functionAst = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            Invoke-Expression $functionAst.Extent.Text
        }
    }

    It 'renders the same typed Replica guardrails used by HTML' {
        $assessment = [pscustomobject]@{
            State = 'Replicating'; Health = 'Normal'; Mode = 'Primary'; ProductSeverity = 'Healthy'
            MeasurementsAvailable = $true; LastReplicationTimeUtc = [datetime]'2026-01-01T09:59:00Z'; LastReplicationAgeMinutes = 1
            FrequencySeconds = 300; MonitoringIntervalSeconds = 3600; AverageReplicationBytes = 64MB
            PendingBytes = 3GB; LatencySeconds = 9; SuccessfulCount = 120; MissedCount = 0; MissedRatePercent = 0
            EffectiveMaxAgeMinutes = 60; EffectiveMaxPendingBytes = 1GB; EffectiveMaxLatencySeconds = 600; MaxMissedRatePercent = 10
            ConcernBreaches = @('PendingBytes'); AdvisoryBreaches = @()
        }

        $rows = @(Get-ReplicaAssessmentRows -Assessment $assessment -PrimaryServer 'PRIMARY-01' -ReplicaServer 'REPLICA-01')

        $rows.Count | Should -Be 9
        ($rows | Where-Object Signal -eq 'Pending replication data').Observed | Should -Be '3.00 GB'
        ($rows | Where-Object Signal -eq 'Pending replication data').Guardrail | Should -Be '1.00 GB effective maximum'
        ($rows | Where-Object Signal -eq 'Pending replication data').Assessment | Should -Be 'Concern'
        ($rows | Where-Object Signal -eq 'Last replication').Observed | Should -Match 'Z \(1\.0 min ago\)'
    }

    It 'uses Unavailable instead of zero when measurements are absent' {
        $assessment = [pscustomobject]@{
            State = 'Waiting'; Health = 'Warning'; Mode = 'Primary'; ProductSeverity = 'Warning'
            MeasurementsAvailable = $false; LastReplicationTimeUtc = [datetime]::MinValue; LastReplicationAgeMinutes = $null
            FrequencySeconds = 0; MonitoringIntervalSeconds = 0; AverageReplicationBytes = 0
            PendingBytes = 0; LatencySeconds = 0; SuccessfulCount = -1; MissedCount = 0; MissedRatePercent = $null
            EffectiveMaxAgeMinutes = 60; EffectiveMaxPendingBytes = 1GB; EffectiveMaxLatencySeconds = 300; MaxMissedRatePercent = 10
            ConcernBreaches = @(); AdvisoryBreaches = @()
        }

        $rows = @(Get-ReplicaAssessmentRows -Assessment $assessment -PrimaryServer '' -ReplicaServer '')

        ($rows | Where-Object Signal -eq 'Pending replication data').Observed | Should -Be 'Unavailable'
        ($rows | Where-Object Signal -eq 'Pending replication data').Assessment | Should -Be 'Unavailable'
        ($rows | Where-Object Signal -eq 'Measured replication cycles').Observed | Should -Be 'Unavailable'
    }

    It 'describes measurement concerns from typed breaches instead of product-health prose' {
        $assessment = [pscustomobject]@{
            LastReplicationAgeMinutes = 58318.6; EffectiveMaxAgeMinutes = 180
            PendingBytes = 0; EffectiveMaxPendingBytes = 1GB
            LatencySeconds = 0; EffectiveMaxLatencySeconds = 1800
            MissedCount = 92; MissedRatePercent = 100
        }

        $text = Get-ReplicaMeasurementEvidenceText -Assessment $assessment -Breaches @('LastReplicationAge', 'MissedCount')

        $text | Should -Be 'last replication age 58,318.6 min (40.5 days); effective limit 180.0 min; missed replications 92; 100.00% of measured attempts'
        $text | Should -Not -Match 'health is Critical'
    }
}

Describe 'Replica duration display contract' {
    BeforeAll {
        $assessmentModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $assessmentModulePath -Force
    }

    It 'keeps sub-day ages in minutes' {
        ConvertTo-ReplicaDurationText -Minutes 1439.9 | Should -Be '1,439.9 min'
    }

    It 'uses singular day at the exact boundary' {
        ConvertTo-ReplicaDurationText -Minutes 1440 | Should -Be '1,440.0 min (1.0 day)'
    }

    It 'adds operator-readable days to multi-week ages' -TestCases @(
        @{ Minutes = 45047.1; Expected = '45,047.1 min (31.3 days)' }
        @{ Minutes = 62843.2; Expected = '62,843.2 min (43.6 days)' }
    ) {
        param($Minutes, $Expected)

        ConvertTo-ReplicaDurationText -Minutes $Minutes | Should -Be $Expected
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

    It 'loads the shipped policy template without an external YAML module' {
        $policyPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'checkpoint-health-policy.example.yml'

        $policy = Import-CheckpointHealthPolicy -Path $policyPath

        $policy.SchemaVersion | Should -Be 1
        @($policy.Storage.ImageLibraryPathPatterns).Count | Should -Be 0
        @($policy.Orphan.LiveMountPathPatterns).Count | Should -Be 0
        $policy.Orphan.ClassifyZeroByteAsLiveMount | Should -BeTrue
        $policy.Replication.Hrl.Enabled | Should -BeTrue
        $policy.Replication.Hrl.CadenceMultiplier | Should -Be 10
        $policySource = Get-Content -LiteralPath $policyModulePath -Raw
        $policySource | Should -Not -Match 'powershell-yaml|ConvertFrom-Yaml'
    }

    It 'loads a downloaded minimal image policy without an external YAML module' {
        $policyPath = Join-Path $TestDrive 'checkpoint-health-policy.yml'
        @'
schemaVersion: 1
storage:
    imageLibraryPathPatterns:
        - '(?i)^C:\\ClusterStorage\\UserStorage_3\\image\.vhd$'
'@ | Set-Content -LiteralPath $policyPath -Encoding ASCII

        $policy = Import-CheckpointHealthPolicy -Path $policyPath

        @($policy.Storage.ImageLibraryPathPatterns).Count | Should -Be 1
        Test-CheckpointHealthPathPattern -Path 'C:\ClusterStorage\UserStorage_3\image.vhd' -Patterns $policy.Storage.ImageLibraryPathPatterns | Should -BeTrue
        $policy.CsvFreeSpace.Enabled | Should -BeFalse
        $policy.Replication.Hrl.Enabled | Should -BeTrue
    }

    It 'rejects unsupported YAML constructs instead of guessing' {
        $policyPath = Join-Path $TestDrive 'unsupported-policy.yml'
        "schemaVersion: 1`nunsupported: value" | Set-Content -LiteralPath $policyPath -Encoding ASCII

        { Import-CheckpointHealthPolicy -Path $policyPath } | Should -Throw '*Unsupported policy YAML value*line 2*'
    }

    It 'rejects an empty policy explicitly' {
        $policyPath = Join-Path $TestDrive 'empty-policy.yml'
        Set-Content -LiteralPath $policyPath -Value '' -Encoding ASCII

        { Import-CheckpointHealthPolicy -Path $policyPath } | Should -Throw '*policy file is empty*'
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

Describe 'PassThru automation result contract' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        Import-Module $modulePath -Force
        $script:ExpectedPassThruProperties = @(
            'VMName', 'Cluster', 'OwningNode', 'Source', 'Recommendation', 'HoldState',
            'HasAttachedCheckpoints', 'HasStaleCheckpoints', 'HasOrphanedCheckpoints',
            'AttachedCheckpointCount', 'StaleCheckpointCount', 'StaleAttachedLayerCount',
            'SnapshotLayerMismatch', 'ConcernEventCount', 'AssessmentConfidence',
            'CollectionStatus', 'ReportFile', 'Detail', 'ReportData', 'RunData'
        )
    }

    It 'emits the exact stable property set and promotes nested assessment status' {
        $nestedStatus = [pscustomobject]@{
            VhdChains = [pscustomobject]@{ Status = 'Complete' }
            VirtualDiskInventory = [pscustomobject]@{ Status = 'Complete' }
            EventLogs = [pscustomobject]@{ Status = 'Success' }
            HistoricEvents = [pscustomobject]@{ Status = 'NotRequired' }
            StateConsistency = [pscustomobject]@{ Status = 'Stable' }
            VssWriters = [pscustomobject]@{ Status = 'Healthy' }
        }
        $reportData = [pscustomobject]@{ AssessmentConfidence = 'Complete'; CollectionStatus = $nestedStatus }
        $runData = [pscustomobject]@{ Cluster = 'TEST-CLUSTER'; HousekeepingFindings = @() }
        $inputResult = [pscustomobject]@{
            VMName = 'TEST-VM'; Cluster = 'TEST-CLUSTER'; OwningNode = 'TEST-NODE'; Source = 'Discovered'
            Recommendation = 'OK'; HoldState = $false; HasAttachedCheckpoints = $true
            HasStaleCheckpoints = $false; HasOrphanedCheckpoints = $false; AttachedCheckpointCount = 1
            StaleCheckpointCount = 0; StaleAttachedLayerCount = 0; SnapshotLayerMismatch = $false
            ConcernEventCount = 0; ReportFile = 'C:\Temp\TEST-VM.txt'; Detail = ''; ReportData = $reportData
        }

        $result = Complete-CheckpointHealthPassThruResult -Result $inputResult -RunData $runData

        @($result.PSObject.Properties.Name) | Should -Be $script:ExpectedPassThruProperties
        $result.Source | Should -Be 'Discovered'
        $result.AssessmentConfidence | Should -Be 'Complete'
        $result.CollectionStatus.EventLogs.Status | Should -Be 'Success'
        $result.CollectionStatus.Outcome.Status | Should -Be 'OK'
        [object]::ReferenceEquals($result.RunData, $runData) | Should -BeTrue
    }

    It 'preserves combined CSV file-system reasons in the shared run storage snapshot' {
        $storageHealth = [pscustomobject]@{
            Summary = 'Degraded'
            CsvRedirected = @([pscustomobject]@{
                Volume = 'UserStorage_1'
                FsReason = 'IncompatibleFileSystemFilter, FileSystemReFs'
            })
        }
        $runData = [pscustomobject]@{ Cluster = 'TEST-CLUSTER'; StorageHealth = $storageHealth }
        $inputResult = [pscustomobject]@{
            VMName = 'TEST-VM'; Cluster = 'TEST-CLUSTER'; Recommendation = 'INVESTIGATE'
            Detail = 'Storage review required.'; ReportData = $null
        }

        $result = Complete-CheckpointHealthPassThruResult -Result $inputResult -RunData $runData

        $result.RunData.StorageHealth.CsvRedirected[0].FsReason | Should -Be 'IncompatibleFileSystemFilter, FileSystemReFs'
    }

    It 'promotes the assessment text into Detail for an INVESTIGATE result' {
        $assessmentText = 'Checkpoint or virtual-disk evidence requires validation.'
        $nestedStatus = [pscustomobject]@{
            VhdChains = [pscustomobject]@{ Status = 'Complete' }
            VirtualDiskInventory = [pscustomobject]@{ Status = 'Complete' }
            EventLogs = [pscustomobject]@{ Status = 'Success' }
            HistoricEvents = [pscustomobject]@{ Status = 'Complete' }
            StateConsistency = [pscustomobject]@{ Status = 'Stable' }
            VssWriters = [pscustomobject]@{ Status = 'Healthy' }
        }
        $reportData = [pscustomobject]@{
            AssessmentConfidence = 'High'
            CollectionStatus = $nestedStatus
            InvestigationDrivers = [pscustomobject]@{ AssessmentText = $assessmentText }
        }
        $inputResult = [pscustomobject]@{
            VMName = 'TEST-VM'; Cluster = 'TEST-CLUSTER'; OwningNode = 'TEST-NODE'
            Recommendation = 'INVESTIGATE'; Detail = ''; ReportData = $reportData
        }

        $result = Complete-CheckpointHealthPassThruResult -Result $inputResult -RunData ([pscustomobject]@{ Cluster = 'TEST-CLUSTER' })

        $result.Detail | Should -Be $assessmentText
        $result.CollectionStatus.Outcome.Detail | Should -Be $assessmentText
        $result.CollectionStatus.VhdChains.Status | Should -Be 'Complete'
        $result.CollectionStatus.EventLogs.Status | Should -Be 'Success'
        $result.CollectionStatus.VssWriters.Status | Should -Be 'Healthy'
    }

    It 'returns predictable incomplete status for NOT FOUND and ERROR rows' {
        $runData = [pscustomobject]@{ Cluster = 'TEST-CLUSTER' }
        $inputs = @(
            [pscustomobject]@{ VMName = 'MISSING'; Cluster = 'TEST-CLUSTER'; Recommendation = 'NOT FOUND'; Detail = 'Not found.'; ReportData = $null }
            [pscustomobject]@{ VMName = 'FAILED'; Cluster = 'TEST-CLUSTER'; Recommendation = 'ERROR'; Detail = 'Collection failed.'; ReportData = $null }
        )

        $results = @($inputs | Complete-CheckpointHealthPassThruResult -RunData $runData)

        $results.Count | Should -Be 2
        foreach ($result in $results) {
            @($result.PSObject.Properties.Name) | Should -Be $script:ExpectedPassThruProperties
            $result.AssessmentConfidence | Should -Be 'Incomplete'
            $result.CollectionStatus.VhdChains.Status | Should -Be 'NotCollected'
            $result.CollectionStatus.Outcome.Status | Should -Be $result.Recommendation
            $result.CollectionStatus.Outcome.Detail | Should -Be $result.Detail
            $result.ReportFile | Should -BeNullOrEmpty
        }
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

    It 'imports a valid 0.2.30 module manifest' {
        $script:Manifest.Version.ToString() | Should -Be '0.2.30'
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

    It 'renders fleet-only helpers through the manifest-managed module topology' {
        $module = Get-Module Get-HyperVVMCheckpointHealth
        $events = @(0..9 | ForEach-Object {
            [pscustomobject]@{ 'Time (UTC)' = ([datetime]'2026-07-01T00:00:00Z').AddSeconds($_ * 30).ToString('yyyy-MM-dd HH:mm:ssZ'); Id = 15268; FullMessage = 'Failed to get the disk information' }
        })
        $storageHealth = [pscustomobject]@{
            Summary = 'Healthy'; Source = 'TEST-NODE'; StorageJobs = @(); CsvRedirected = @()
            VDiskUnhealthy = @(); PDiskUnhealthy = @(); Note = ''; HealthFaultCollectionStatus = 'Success'
            HealthFaults = @(); Subsystem = @()
        }
        $html = & $module {
            param($nodeEvents, $storageSnapshot)
            ConvertTo-VMCheckpointAuditHtml -Results @() -StaleHours 24 -EventLookbackHours 168 `
                -ClusterName 'TEST-CLUSTER' -GeneratedUtc '2026-07-01 01:00:00Z' -DiscoveredVMs @() `
                -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
                -StorageHealth $storageSnapshot -HousekeepingFindings @() -NodeEventContext @([pscustomobject]@{ Node = 'TEST-NODE'; Events = $nodeEvents }) `
                -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.30' -ReportGenerationTime '00:00:01' -ClusterNodeCount 1 -ClusterCsvCount 1
        } $events $storageHealth
        $html | Should -Match 'Cluster-level low-signal event observation'
        $html | Should -Match "<a href='#cluster-low-signal-events'>Cluster-level low-signal event observation:</a>"
        $html | Should -Match "id='cluster-low-signal-events'"
        $storageStart = $html.IndexOf("id='cluster-storage-health'")
        $observationStart = $html.IndexOf("id='cluster-low-signal-events'")
        $deeperAnalysisStart = $html.IndexOf('Deeper analysis (recommended)')
        $storageStart | Should -BeLessThan $observationStart
        $observationStart | Should -BeLessThan $deeperAnalysisStart
        & $module { ConvertTo-ReplicaDurationText -Minutes 20160 } | Should -Be '20,160.0 min (14.0 days)'
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

    It 'documents the complete PassThru automation contract and correct nesting' {
        $readme = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'README.md') -Raw
        $readme | Should -Match '\| `Source` \| string \|'
        $readme | Should -Match '\| `AssessmentConfidence` \| string \| Top-level automation field:'
        $readme | Should -Match '\| `CollectionStatus` \| object \| Top-level, consistently shaped status'
        $readme | Should -Match '\| `RunData` \| object \| Shared final run snapshot'
        $readme | Should -Match 'ReportData\.VmEvents'
        $readme | Should -Match '\$run = \$r\[0\]\.RunData'
        $readme | Should -Match '\$vmResult\.VMName'
        $readme | Should -Not -Match "Select-Object @\{n='VM';e=\{ \$_\.Name \}\}, AgeHrs"
        $readme | Should -Match 'dark orange identifies the observed value that supports a concern'
        $readme | Should -Match 'stale checkpoint or attached AVHDX `YES` and the checkpoint creation age that breached `-StaleHours`'
        $readme | Should -Match 'Base VHDX rows are not checkpoints: their creation interval is labelled \*\*Disk age\*\*, and \*\*Checkpoint stale = n/a \(base\)\*\*'
        $readme | Should -Match 'driver-specific `Detail` text for `INVESTIGATE`'
        $readme | Should -Match 'event-attribution telemetry records `Rows=0`'
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
        $setupSource | Should -Match ("\`$version = '{0}'" -f [regex]::Escape($script:Manifest.Version.ToString()))
        $setupSource | Should -Match "\$expectedSha256 = '[0-9a-f]{64}'"
        $setupSource | Should -Match '\[string\]\$InstallRoot = ''C:\\Temp'''
        $setupSource | Should -Match '\$scriptDirectoryZipPath\s*=\s*Join-Path\s+\$PSScriptRoot\s+\$expectedAssetName'
        $setupSource | Should -Match '\$tempDirectoryZipPath\s*=\s*Join-Path\s+\$env:TEMP\s+\$expectedAssetName'
        $setupSource | Should -Match '(?s)Test-Path.+\$scriptDirectoryZipPath.+elseif.+Test-Path.+\$tempDirectoryZipPath'
        $setupSource | Should -Match "Release ZIP was not found beside the setup script.+or in the temporary directory"
        $setupSource | Should -Match '\$WhatIfPreference\s*=\s*\$false[\s\S]+Get-FileHash.+SHA256'
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
        $readme | Should -Match 'For a new policy, choose \*\*Download checkpoint-health-policy\.yml\*\*'
        $readme | Should -Match 'For an existing policy, choose \*\*Copy policy settings\*\*.*copy only the generated.*entries into its existing `storage\.imageLibraryPathPatterns` array'
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
        $staleLayerReportData.CheckpointLayers = 2
        $staleLayerReportData.StaleAttachedLayerCount = 2
        $staleLayerReportData.SnapshotLayerMismatch = $true
        $staleLayerReportData | Add-Member -NotePropertyName SnapshotLayerTimestampDivergence -NotePropertyValue $true
        $staleLayerReportData | Add-Member -NotePropertyName OldestSnapshotUtc -NotePropertyValue '2026-07-15 21:41:33Z'
        $staleLayerReportData | Add-Member -NotePropertyName OldestAttachedLayerUtc -NotePropertyValue '2026-06-21 21:37:32Z'
        $staleLayerReportData | Add-Member -NotePropertyName OldestTimestampDeltaHours -NotePropertyValue 576.1
        $staleLayerReportData.AttachedVhdLayers = @(
            [pscustomobject]@{
                Chain = 'TEST-VM-STALE-LAYER_OS-CURRENT.avhdx'; FileName = 'TEST-VM-STALE-LAYER_OS-CURRENT.avhdx'
                Layer = 1; Role = 'Active (top)'; Type = 'Differencing'; SizeGB = 8.5
                Created = '2025-12-29 10:00:00Z'; LastWrite = '2026-01-01 09:55:00Z'
                CheckpointAgeHrs = 74; LastActivityAgeHrs = 0.1; CheckpointStale = $true
                Path = 'C:\ClusterStorage\Volume1\TEST-VM-STALE-LAYER_OS-CURRENT.avhdx'
                ParentPath = 'C:\ClusterStorage\Volume1\TEST-VM-STALE-LAYER_OS-OLDER.avhdx'
            }
            [pscustomobject]@{
                Chain = 'TEST-VM-STALE-LAYER_OS-CURRENT.avhdx'; FileName = 'TEST-VM-STALE-LAYER_OS-OLDER.avhdx'
                Layer = 2; Role = 'Checkpoint'; Type = 'Differencing'; SizeGB = 4.25
                Created = '2025-12-28 10:00:00Z'; LastWrite = '2025-12-29 10:00:00Z'
                CheckpointAgeHrs = 98; LastActivityAgeHrs = 74; CheckpointStale = $true
                Path = 'C:\ClusterStorage\Volume1\TEST-VM-STALE-LAYER_OS-OLDER.avhdx'
                ParentPath = 'C:\ClusterStorage\Volume1\TEST-VM-STALE-LAYER_OS.vhdx'
            }
            [pscustomobject]@{
                Chain = 'TEST-VM-STALE-LAYER_OS-CURRENT.avhdx'; FileName = 'TEST-VM-STALE-LAYER_OS.vhdx'
                Layer = 3; Role = 'Base'; Type = 'Dynamic'; SizeGB = 64
                Created = '2025-01-01 10:00:00Z'; LastWrite = '2025-12-28 10:00:00Z'
                CheckpointAgeHrs = $null; LastActivityAgeHrs = 98; CheckpointStale = $false
                Path = 'C:\ClusterStorage\Volume1\TEST-VM-STALE-LAYER_OS.vhdx'; ParentPath = ''
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
            -DiscoverySummary $discoverySummary -StorageHealth $null -IncludeDiscoveredVMs:$true -ScriptVersion '0.2.21' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1 `
            -HousekeepingFindings @(
                [pscustomobject]@{
                    Category = 'Placement inconsistency'; Scope = 'TEST-VM-NORMAL'
                    FileName = 'Data<review>.vhdx'
                    FullName = 'C:\ClusterStorage\Volume1\TEST-VM-NORMAL\Data<review>.vhdx'
                    ParentPath = 'C:\ClusterStorage\Volume1\TEST-VM-NORMAL'
                    CsvRoot = 'C:\ClusterStorage\Volume1'; Extension = '.vhdx'; Length = 1572864
                    Owners = @('OWNER-VM'); AssociatedVMs = @('FOLDER-VM')
                    Observation = 'VM owner(s): OWNER-VM. Folder-associated VM(s): FOLDER-VM. The authoritative VM reference and detected storage-folder association differ <review>.'
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
                    Review = 'If this virtual disk belongs to an image library, exclude its full path with storage.imageLibraryPathPatterns in a checkpoint-health-policy.yml file supplied via -PolicyPath (see housekeeping guidance). Otherwise, confirm intended ownership.'
                }
            )
        $script:CleanRenderedHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs $null -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 2 -ClusterCsvCount 1 -HousekeepingFindings @([pscustomobject]@{
                Category = 'Unattached base disk candidate'; Scope = 'C:\ClusterStorage\UserStorage_1'
                FileName = 'BaseDisk.vhdx'
                Observation = 'No VM or snapshot chain references this base disk under complete coverage: C:\ClusterStorage\UserStorage_1\BaseDisk.vhdx'
                Review = 'If this virtual disk belongs to an image library, exclude its full path with storage.imageLibraryPathPatterns in a checkpoint-health-policy.yml file supplied via -PolicyPath (see housekeeping guidance). Otherwise, confirm intended ownership. Do not modify the file based only on this report.'
            })
        $degradedStorage = [pscustomobject]@{
            Summary = 'Degraded'; Source = 'TEST-NODE-01'; StorageJobs = @(); CsvRedirected = @()
            VDiskUnhealthy = @(); PDiskUnhealthy = @(); Note = ''
            HealthFaultCollectionStatus = 'Success'
            Subsystem = @(
                [pscustomobject]@{ Name = 'Clustered Windows Storage'; Health = 'Unhealthy' }
                [pscustomobject]@{ Name = 'Windows Storage'; Health = 'Healthy' }
            )
            HealthFaults = @([pscustomobject]@{
                Severity = 'Warning'; Reason = 'Synthetic storage health fault <review>'
                FaultingObjectDescription = 'Synthetic affected object'; FaultingObjectLocation = 'Synthetic location'
                RecommendedActions = @('Inspect the affected storage object <carefully>.', 'Open a CSS case if the fault persists.')
            })
        }
        $script:DegradedStorageHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs $null -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $degradedStorage -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.24' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 2 -ClusterCsvCount 1 -HousekeepingFindings @()
        $filterRedirectedStorage = [pscustomobject]@{
            Summary = 'Degraded'; Source = 'TEST-NODE-01'; StorageJobs = @()
            CsvRedirected = @([pscustomobject]@{
                Volume = 'UserStorage_1'; Nodes = 'TEST-NODE-01, TEST-NODE-02'
                State = 'FileSystemRedirected'; BlockReason = ''
                FsReason = 'IncompatibleFileSystemFilter, FileSystemReFs'
            })
            VDiskUnhealthy = @(); PDiskUnhealthy = @(); Subsystem = @(); HealthFaults = @(); Note = ''
            HealthFaultCollectionStatus = 'Success'
        }
        $script:FilterRedirectedStorageHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs $null -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $filterRedirectedStorage -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.30' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 2 -ClusterCsvCount 1 -HousekeepingFindings @()
        $degradedStorageWithoutFaults = $degradedStorage.PSObject.Copy()
        $degradedStorageWithoutFaults.HealthFaults = @()
        $script:DegradedStorageNoFaultHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs $null -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $degradedStorageWithoutFaults -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.24' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 2 -ClusterCsvCount 1 -HousekeepingFindings @()
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
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.21' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1
        $measurementConcernReportData = $normalReportData.PSObject.Copy()
        $measurementConcernReportData.ReplUnhealthy = $true
        $measurementConcernReportData.ReplAssessment = $normalReportData.ReplAssessment.PSObject.Copy()
        $measurementConcernReportData.ReplAssessment.Severity = 'Warning'
        $measurementConcernReportData.ReplAssessment.ProductSeverity = 'Healthy'
        $measurementConcernReportData.ReplAssessment.MeasurementStatus = 'Concern'
        $measurementConcernReportData.ReplAssessment.IsConcern = $true
        $measurementConcernReportData.ReplAssessment.PendingBytes = 3GB
        $measurementConcernReportData.ReplAssessment.EffectiveMaxPendingBytes = 1GB
        $measurementConcernReportData.ReplAssessment.ConcernBreaches = @('PendingBytes')
        $measurementConcernReportData.ReplAssessment.ThresholdBreaches = @('PendingBytes')
        $measurementConcernReportData.ReplAssessment.Reason = 'Pending replication data materially exceeds the effective relationship-aware limit.'
        $script:MeasurementConcernReplicaHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-MEASUREMENT'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $measurementConcernReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 10:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.24' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1
        $stateAdvisoryReportData = $normalReportData.PSObject.Copy()
        $stateAdvisoryReportData | Add-Member -NotePropertyName StateConsistencyStatus -NotePropertyValue 'Changed'
        $stateAdvisoryReportData | Add-Member -NotePropertyName StateConsistencyImpact -NotePropertyValue 'Advisory'
        $stateAdvisoryReportData | Add-Member -NotePropertyName StateConsistencyReasons -NotePropertyValue @('ConfigLastWriteUtc')
        $script:StateAdvisoryHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-STATE-ADVISORY'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $stateAdvisoryReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 10:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.21' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1
        $hrlConcernReportData = $normalReportData.PSObject.Copy()
        $hrlConcernReportData | Add-Member -NotePropertyName HrlAssessment -NotePropertyValue ([pscustomobject]@{
            Enabled = $true; ReplicationEnabled = $true; ThresholdMinutes = 50
            ExceedsCadenceCount = 12; CorroboratedByReplication = $true; IsConcern = $true
        })
        $script:HrlConcernHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-HRL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $hrlConcernReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 10:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.21' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1
    }

    It 'shows an incomplete count for NOT FOUND and ERROR rows' {
        $script:RenderedHtml | Should -Match '<div class="l">Incomplete</div>'
        $script:RenderedHtml | Should -Match '<div class="n">1</div><div class="l">Incomplete</div>'
        $script:RenderedHtml | Should -Match 'Assessment incomplete:.*1 VM.*For <strong>NOT FOUND</strong>, verify the VM name and cluster.*For <strong>ERROR</strong>, review permissions, connectivity, and the debug log'
        $script:RenderedHtml | Should -Match 'Input VM name\(s\) not found on this cluster: <strong>TEST-VM-MISSING</strong>'
        $script:RenderedHtml | Should -Match 'INVESTIGATE - input VM name\(s\) not found on this cluster \(1\):</strong> TEST-VM-MISSING'
        $script:RenderedHtml | Should -Match 'Get-HyperVVMCheckpointHealth -VMName &#39;TEST-VM-MISSING&#39; -OutputPath &lt;folder&gt;'
        $script:RenderedHtml | Should -Not -Match '_debug_log_\*\.txt'
    }

    It 'places VM source badges below VM names in the summary table' {
        $script:RenderedHtml | Should -Match '\.vmn>a\{display:block\}'
        $script:RenderedHtml | Should -Match '\.vmn>\.src\{display:block;width:max-content;margin:4px 0 0\}'
        $script:RenderedHtml | Should -Match '<td class="vmn"><a[^>]+><code>TEST-VM-NORMAL</code></a><span class="src input">Input</span></td>'
    }

    It 'warn-highlights verdict-driving event counts while leaving low-signal counts neutral' {
        $highSignalReportData = $normalReportData.PSObject.Copy()
        $highSignalReportData.VmEventConcernCount = 7
        $highSignalReportData.VmHighConcernCount = 5
        $highSignalHtml = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-HIGH-EVENTS'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $highSignalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 10:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false `
            -ScriptVersion '0.2.24' -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1

        $highSignalHtml | Should -Match '<td class="num">7 <span class=''warnval''>\(5 hi\)</span></td>'
        $script:RenderedHtml | Should -Not -Match '<span class=''warnval''>\([^<]+ low\)</span>'
    }

    It 'shows debug-log guidance only when unrecovered diagnostics were recorded' {
        $html = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-ERROR'; OwningNode = ''; Recommendation = 'ERROR'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $null; Detail = 'Synthetic collection error.' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 10:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -DebugLogAvailable:$true `
            -ScriptVersion '0.2.24' -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1

        $html | Should -Match 'Unrecovered collection errors were logged'
        $html | Should -Match '_debug_log_\*\.txt'
        $html | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth#readme'
        $html | Should -Match 'https://aka\.ms/Get-HyperVVMCheckpointHealth-Feedback'
        $html | Should -Match 'Exec Summary - assessment incomplete:'
        $html | Should -Not -Match 'Exec Summary - no VM health action required:'
    }

    It 'distinguishes processed, fully assessed, and incomplete VM counts in every report' {
        $script:RenderedHtml | Should -Match 'Cluster <b>CONTOSO-CLUSTER-01</b> &nbsp;&bull;&nbsp; 4 processed VMs &nbsp;&bull;&nbsp; 3 fully assessed'
        $script:RenderedHtml | Should -Match '<strong class="scope-label">Report scope:</strong> <strong>4 input \+ 0 automatically discovered = 4 processed</strong>; <strong>3 were fully assessed</strong>; <strong>1 was incomplete</strong>\.'
        $script:RenderedHtml | Should -Match 'Fleet report finalized \(UTC\): <strong>2026-01-01 00:00:00Z</strong>\.'
        $script:RenderedHtml | Should -Match 'wider assessment of the cluster, storage, backup solution, workloads, and relevant operational history\.'
        $script:RenderedHtml | Should -Match '\.scope-label\{color:#d97706;font-weight:700\}'
        $script:RenderedHtml | Should -Match 'It is not a complete cluster health assessment and does not represent the health of VMs that were not fully assessed\.'
        $script:CleanRenderedHtml | Should -Match '<strong>1 input \+ 0 automatically discovered = 1 processed</strong>; <strong>1 was fully assessed</strong>; <strong>0 were incomplete</strong>'
    }

    It 'distinguishes no attributed events from low-signal events and reports a checked Analytic channel precisely' {
        $script:CleanRenderedHtml | Should -Match 'Concerning events - this VM \(168h\)</div><div>0 \(none attributed\)</div>'
        $script:CleanRenderedHtml | Should -Match 'Analytic channel</div><div>Enabled</div>'
        $script:CleanRenderedHtml | Should -Not -Match 'Enabled \(or not checked\)'
    }

    It 'keeps finding-specific orphan guidance aligned across TXT and HTML output' {
        $moduleSource = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1') -Raw

        $moduleSource | Should -Match 'based on your own investigation into that specific orphaned checkpoint file\.'
        $moduleSource | Should -Not -Match 'at its timestamps and obtain vendor or Microsoft Support guidance before changing it\.'
    }

    It 'keeps healthy Replica timestamp-only activity as quiet state detail' {
        $script:StateAdvisoryHtml | Should -Match '<div class="k">Collection state consistency</div><div>Advisory - VM configuration \(\.vmcx\) timestamp changed during collection; core state and disk paths remained stable</div>'
        $script:StateAdvisoryHtml | Should -Not -Match 'No action is required for this advisory'
        $script:StateAdvisoryHtml | Should -Match "<div class='callout ok'><strong>OK\.</strong>"
    }

    It 'uses evidence-scoped labels and advisory-aware summary prose' {
        $moduleSource = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1') -Raw

        $script:RenderedHtml | Should -Match '<div class="l">Stale attached AVHDX layers</div>'
        $moduleSource | Should -Match "Disk age\s+: \{0\} hours \(since base disk creation\)"
        $moduleSource | Should -Match 'if \(\$top\.Type -eq ''Differencing''\)[\s\S]+Checkpoint age : \{0\} hours \(since AVHDX creation\)[\s\S]+elseif \(\$top\.Type -in @\(''Dynamic'', ''Fixed''\)\)[\s\S]+Disk age\s+: \{0\} hours \(since base disk creation\)'
        $moduleSource | Should -Match 'no verdict-driving Replica concern; one measurement advisory is recorded'
        $moduleSource | Should -Match 'The audit did not identify the writer of this timestamp-only change\.'
        $moduleSource | Should -Not -Match 'Normal Replica metadata activity can cause this\.'
    }

    It 'prints VM-attributed events before summarizing node-wide context in TXT reports' {
        $moduleSource = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1') -Raw

        $moduleSource | Should -Match '\$txtVmEvents\s*=\s*@\(\$workerEvents \| Where-Object \{ \$_\.VmAttributed \}\)'
        $moduleSource | Should -Match 'Node-wide event context is summarized below and exported separately; it is not listed in this VM table\.'
    }

    It 'states additional unaudited discovery coverage only when applicable' {
        $script:RenderedHtml | Should -Match '<strong>Audit coverage:</strong> <strong>1 additional discovered VM was not audited in this run</strong> and is not represented by the findings or summary totals below\.'
        $script:CleanRenderedHtml | Should -Not -Match '<strong>Audit coverage:</strong>'
    }

    It 'surfaces storage fault actions and retains CSS deep-analysis guidance' {
        $script:DegradedStorageHtml | Should -Match "<strong><a href='#cluster-storage-health'>Cluster storage requires investigation:</a></strong> 1 active storage Health Service fault\(s\): Synthetic storage health fault &lt;review&gt;\."
        $script:DegradedStorageHtml | Should -Match "<details class='report-section' id='cluster-storage-health' open><summary><h2>Cluster storage health \(Storage Spaces Direct / CSV\)</h2></summary><div class='report-section-body'>"
        $script:DegradedStorageHtml | Should -Match '<strong>Storage status: Degraded\.</strong> Read-only snapshot \(source node <code>TEST-NODE-01</code>\)\.</div>'
        $script:DegradedStorageHtml | Should -Not -Match 'Storage-layer disruption - S2D repair / resync jobs'
        $script:DegradedStorageHtml | Should -Match '<p><strong>Why this check matters:</strong> storage repair/resync activity, abnormal CSV redirection or state, and unhealthy disks can make checkpoint or merge files temporarily locked or unavailable\.'
        $script:DegradedStorageHtml | Should -Not -Match '<p class=''muted''><strong>Why this check matters:</strong>'
        $script:DegradedStorageHtml | Should -Match 'A ReFS CSV reporting File System Redirected mode with reason <code>FileSystemReFs</code> is normal on Azure Local / S2D and is not flagged'
        $script:DegradedStorageHtml | Should -Match '<strong>Why this snapshot is non-healthy:</strong> 1 active storage Health Service fault\(s\): Synthetic storage health fault &lt;review&gt;\.'
        $script:DegradedStorageHtml | Should -Match '<h3>Active storage Health Service faults \(read-only evidence\)</h3>'
        $script:DegradedStorageHtml | Should -Match '<th>Recommended action\(s\)</th>'
        $script:DegradedStorageHtml | Should -Match '<td><span class=''warnval''>Warning</span></td><td>Synthetic storage health fault &lt;review&gt;</td><td>Synthetic affected object</td><td>Synthetic location</td><td>Inspect the affected storage object &lt;carefully&gt;\.<br>Open a CSS case if the fault persists\.</td>'
        $script:DegradedStorageHtml | Should -Match '<strong>EVIDENCE - </strong>These records come from <code>Get-HealthFault</code> and are displayed as observed diagnostic evidence\.'
        $script:DegradedStorageHtml | Should -Not -Match '<p class=''muted''><strong>EVIDENCE - </strong>'
        $script:DegradedStorageHtml | Should -Match "(?s)<strong>EVIDENCE - </strong>.*?</p><p><strong>Storage knowledge links:</strong></p><ul><li><a href='https://learn\.microsoft\.com/en-us/windows-server/failover-clustering/health-service-faults'.*?</a></li><li><a href='https://learn\.microsoft\.com/en-us/windows-server/storage/storage-spaces/troubleshooting-storage-spaces'.*?</a></li></ul>"
        $script:DegradedStorageHtml | Should -Match 'Recommended actions are shown exactly as supplied by the matching storage fault\.'
        $script:DegradedStorageHtml | Should -Match '<strong>Deeper analysis \(recommended\):</strong> this is a lightweight snapshot\.'
        $script:DegradedStorageHtml | Should -Match 'Install-Module -Name Microsoft\.AzLocal\.CSSTools'
        $script:DegradedStorageHtml | Should -Match "<a href='https://github\.com/Azure/AzureLocal-Supportability/blob/main/tools/CSSTools/1\.2605\.5\.1611/functions/Start-AzsSupportStorageDiagnostic\.md' target='_blank' rel='noopener noreferrer'>Start-AzsSupportStorageDiagnostic documentation</a>"
        $script:DegradedStorageHtml | Should -Match "<a href='https://learn\.microsoft\.com/en-us/windows-server/failover-clustering/health-service-faults' target='_blank' rel='noopener noreferrer'>Health Service faults \| Microsoft Learn</a>"
        $script:DegradedStorageHtml | Should -Match "<a href='https://learn\.microsoft\.com/en-us/windows-server/storage/storage-spaces/troubleshooting-storage-spaces' target='_blank' rel='noopener noreferrer'>Storage Spaces Direct troubleshooting \| Microsoft Learn</a>"
        $deeperAnalysis = [regex]::Match($script:DegradedStorageHtml, "(?s)<div class='callout info'><strong>Deeper analysis \(recommended\):</strong>.*?</div>").Value
        $deeperAnalysis | Should -Not -Match 'Health Service faults \| Microsoft Learn'
        $deeperAnalysis | Should -Not -Match 'Storage Spaces Direct troubleshooting \| Microsoft Learn'
        $script:DegradedStorageHtml | Should -Match 'Open a Microsoft Support \(CSS\) support request if you need additional guidance before taking action\.'
        $script:DegradedStorageHtml | Should -Not -Match 'A <em>Warning</em> here is often a minor, non-storage fault'
        $script:DegradedStorageHtml | Should -Not -Match 'Debug-StorageSubSystem|Repair-Storage|Set-Storage'
    }

    It 'adds read-only minifilter guidance only for incompatible CSV file-system filters' {
        $script:FilterRedirectedStorageHtml | Should -Match '<strong>Incompatible file-system filter reported:</strong>'
        $script:FilterRedirectedStorageHtml | Should -Match '<code>FileSystemReFs</code> remains expected for ReFS CSVs'
        $script:FilterRedirectedStorageHtml | Should -Match 'Get-ClusterSharedVolumeState \| Sort-Object VolumeFriendlyName, Node'
        $script:FilterRedirectedStorageHtml | Should -Match 'Invoke-Command -ComputerName \$nodes -ScriptBlock \{ fltmc filters; fltmc instances \}'
        $script:FilterRedirectedStorageHtml | Should -Match 'Selected-filter details:'
        $script:FilterRedirectedStorageHtml | Should -Match '\$filterName = .*&lt;filtername&gt;'
        $script:FilterRedirectedStorageHtml | Should -Match 'Get-CimInstance Win32_SystemDriver -Filter'
        $script:FilterRedirectedStorageHtml | Should -Match 'Get-ItemProperty -LiteralPath \$servicePath'
        $script:FilterRedirectedStorageHtml | Should -Match 'Select-Object DisplayName, ImagePath, Start, SupportedFeatures'
        $script:FilterRedirectedStorageHtml | Should -Match 'Treat <code>SupportedFeatures</code> as collected evidence; confirm its meaning and product support with the driver owner or vendor\.'
        $script:FilterRedirectedStorageHtml | Should -Match 'Id=5120,5142'
        $script:FilterRedirectedStorageHtml | Should -Match 'Do not unload or remove a filter based only on this report'
        $script:DegradedStorageHtml | Should -Not -Match '<strong>Incompatible file-system filter reported:</strong>'
        $script:CleanRenderedHtml | Should -Not -Match 'fltmc filters'
    }

    It 'labels the housekeeping rationale clearly' {
        $script:RenderedHtml | Should -Match '<strong>WHY THIS MATTERS:</strong> Operational excellence and consistent storage practices improve reliability and reduce operational complexity\.'
        $script:RenderedHtml | Should -Match '<strong>Do not move, rename, merge, or delete virtual disk files based solely on this report, all decisions and actions are your responsibility\.</strong>'
    }

    It 'links a deduplicated housekeeping roll-up from the Executive Summary' {
        $script:RenderedHtml | Should -Match "<strong><a href='#housekeeping'>Cluster storage \(VHD and checkpoint\) housekeeping audit results:</a></strong> identified <strong>3</strong> item\(s\), with a total unique-file storage size of <strong>1\.50 MB</strong>, across <strong>1</strong> Cluster Shared Volume\(s\)\. <strong>Action:</strong> review this section to determine whether the files are required VM images, inconsistent VM VHD paths, and/or unrequired orphaned objects\."
        $script:CleanRenderedHtml | Should -Match "<strong><a href='#housekeeping'>Cluster storage \(VHD and checkpoint\) housekeeping audit results:</a></strong> identified <strong>1</strong> item\(s\), with a total unique-file storage size of <strong>0 KB</strong>, across <strong>0</strong> Cluster Shared Volume\(s\)\."
    }

    It 'states when an unhealthy subsystem returns no Health Service fault detail' {
        $script:DegradedStorageNoFaultHtml | Should -Match '1 storage subsystem\(s\) report Unhealthy, but no active Health Service fault detail was returned \(collection status: Success\)'
        $script:DegradedStorageNoFaultHtml | Should -Match '<strong>Health Service collection status: Success; zero active faults returned\.</strong>'
        $script:DegradedStorageNoFaultHtml | Should -Match '<strong>Health Service detail unavailable:</strong> the subsystem state is Unhealthy, but no active fault records are available'
        $script:DegradedStorageNoFaultHtml | Should -Match '<p><strong>Storage knowledge links:</strong></p><ul>'
        $script:DegradedStorageNoFaultHtml | Should -Match 'Health Service faults \| Microsoft Learn'
        $script:DegradedStorageNoFaultHtml | Should -Match 'Storage Spaces Direct troubleshooting \| Microsoft Learn'
        $script:CleanRenderedHtml | Should -Not -Match 'Cluster storage requires investigation'
    }

    It 'warn-highlights abnormal Replica state while leaving normal replication neutral' {
        $script:RenderedHtml | Should -Match "<span class='warnval'>Error \(Critical\)</span>"
        $script:RenderedHtml | Should -Match ([regex]::Escape('<div class="k">Hyper-V Replica</div><div><span class=''warnval''>Error (Critical)</span></div>'))
        $script:RenderedHtml | Should -Match '<td>Replicating \(Normal\)</td>'
        $script:RenderedHtml | Should -Match '<div class="k">Hyper-V Replica</div><div>Replicating \(Normal\)</div>'
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
        $script:RenderedHtml | Should -Match "<td><span class='warnval'>Error / Critical</span></td>"
        $script:RenderedHtml | Should -Match "<td>Replicating / Normal</td>"
    }

    It 'keeps product health Normal while warn-highlighting exact measurement concern evidence' {
        $script:MeasurementConcernReplicaHtml | Should -Match '<details open><summary>Hyper-V Replica details - Replicating / Normal; measurements Concern</summary>'
        $script:MeasurementConcernReplicaHtml | Should -Match "<td>Replicating \(Normal\)<br><span class='warnval'>Concern - pending data 3\.00 GB \(effective limit 1\.00 GB\)</span></td>"
        $script:MeasurementConcernReplicaHtml | Should -Match "Replica measurement assessment</div><div><span class='warnval'>Concern - pending data 3\.00 GB \(effective limit 1\.00 GB\)</span>"
        $script:MeasurementConcernReplicaHtml | Should -Match 'Hyper-V Replica measurements need attention \(1 VM\(s\)\):</strong> the measured replication age, backlog, latency, or missed cycles for TEST-VM-MEASUREMENT'
        $script:MeasurementConcernReplicaHtml | Should -Not -Match 'Hyper-V Replica product health/state needs attention'
    }

    It 'labels every per-VM card heading explicitly' {
        $script:RenderedHtml | Should -Match '<h3><span class="vm-label">VM Name:</span> <code>TEST-VM-NORMAL</code>'
        $script:RenderedHtml | Should -Match '<h3><span class="vm-label">VM Name:</span> <code>TEST-VM-MISSING</code>'
        $script:RenderedHtml | Should -Match '<div class="k">VM name</div><div><code>TEST-VM-NORMAL</code></div>\s*<div class="k">Source</div>'
        $script:RenderedHtml | Should -Match "<div class='kv'><div class='k'>VM name</div><div><code>TEST-VM-MISSING</code></div></div>"
    }

    It 'collapses OK per-VM cards and keeps non-OK cards open by default' {
        $script:RenderedHtml | Should -Match '<details class="vm" id="vm-TEST-VM-NORMAL">\s*<summary><h3><span class="vm-label">VM Name:</span>'
        $script:RenderedHtml | Should -Not -Match '<details class="vm" id="vm-TEST-VM-NORMAL" open>'
        $script:RenderedHtml | Should -Match '<details class="vm" id="vm-TEST-VM-MISSING" open>\s*<summary><h3><span class="vm-label">VM Name:</span>'
        $script:RenderedHtml | Should -Match '\.vm>summary::before\{content:''\\25B6'''
        $script:RenderedHtml | Should -Match '\.vm\[open\]>summary::before\{content:''\\25BC''\}'
        ([regex]::Matches($script:RenderedHtml, '<details class="vm(?: hold)?" id="vm-')).Count | Should -Be 4
        ([regex]::Matches($script:RenderedHtml, '<details class="vm(?: hold)?" id="vm-[^"]+" open>')).Count | Should -Be 3
    }

    It 'sorts per-VM cards by verdict criticality and descending severity' {
        $detailsStart = $script:RenderedHtml.IndexOf('Per-VM detailed information')
        $stalePosition = $script:RenderedHtml.IndexOf('id="vm-TEST-VM-STALE-LAYER"', $detailsStart)
        $replicaPosition = $script:RenderedHtml.IndexOf('id="vm-TEST-VM-REPLICA"', $detailsStart)
        $normalPosition = $script:RenderedHtml.IndexOf('id="vm-TEST-VM-NORMAL"', $detailsStart)
        $missingPosition = $script:RenderedHtml.IndexOf('id="vm-TEST-VM-MISSING"', $detailsStart)
        $stalePosition | Should -BeLessThan $replicaPosition
        $replicaPosition | Should -BeLessThan $normalPosition
        $normalPosition | Should -BeLessThan $missingPosition
    }

    It 'reports healthy Replica config-write changes as quiet stable detail' {
        $script:StateAdvisoryHtml | Should -Match 'Collection state consistency</div><div>Advisory - VM configuration \(\.vmcx\) timestamp changed during collection; core state and disk paths remained stable'
        $script:StateAdvisoryHtml | Should -Not -Match 'Normal Replica metadata activity can cause this\.'
        $script:StateAdvisoryHtml | Should -Match '<span class="pill ok">OK</span>'
        $script:StateAdvisoryHtml | Should -Not -Match '<strong>INVESTIGATE\.</strong>'
    }

    It 'rolls HRL-only concerns into the ordinary summary and a dedicated action' {
        $script:HrlConcernHtml | Should -Match 'findings: 1 VM\(s\) with cadence-breaching HRL evidence\.'
        $script:HrlConcernHtml | Should -Match 'Hyper-V Replica log cadence needs attention \(1 VM\(s\)\):</strong> the <code>\.hrl</code> files for TEST-VM-HRL exceed the age limit'
        $script:HrlConcernHtml | Should -Match "<td>Replicating \(Normal\)<br><span class='warnval'>12 queued HRL files beyond cadence</span></td>"
        $script:HrlConcernHtml | Should -Match 'Do not delete or modify <code>\.hrl</code> files based on this report\.'
        $script:CleanRenderedHtml | Should -Not -Match 'queued HRL files beyond cadence'
        $script:AdvisoryReplicaHtml | Should -Not -Match 'queued HRL files beyond cadence'
    }

    It 'renders every top-level report section as a matching default-open disclosure' {
        $script:RenderedHtml | Should -Match '<details class="report-section" id="recommended-next-steps" open>\s*<summary><h2>Recommended next steps</h2></summary>\s*<div class="report-section-body">'
        $script:RenderedHtml | Should -Match '<details class="report-section" id="vm-summary" open>\s*<summary><h2>VM summary table</h2></summary>\s*<div class="report-section-body">'
        $script:RenderedHtml | Should -Match "<details class='report-section' id='discovered-vms' open><summary><h2>Discovered VMs not audited - discovery cap reached</h2></summary><div class='report-section-body'>"
        $script:RenderedHtml | Should -Match "<details class='report-section' open><summary><h2>Per-VM detailed information</h2></summary><div class='report-section-body'>"
        $script:DegradedStorageHtml | Should -Match "<details class='report-section' id='cluster-storage-health' open><summary><h2>Cluster storage health \(Storage Spaces Direct / CSV\)</h2></summary><div class='report-section-body'>"
        $script:RenderedHtml | Should -Match '<details class="report-section" id="housekeeping" open>\s*<summary><h2>Cluster / storage housekeeping to review:</h2></summary>\s*<div class="report-section-body">'
        $script:RenderedHtml | Should -Match '<details class="report-section" id="appendix" open>\s*<summary><h2>Appendix - Knowledge and Information</h2></summary>\s*<div class="report-section-body">'
        $script:RenderedHtml | Should -Match 'details\.report-section>summary::before\{content:''\\25B6'''
        $script:RenderedHtml | Should -Match 'details\.report-section\[open\]>summary::before\{content:''\\25BC''\}'
    }

    It 'uses a full-width audited-VM lead card and keeps orphaned AVHDX last' {
        $script:RenderedHtml | Should -Match '<div class="card lead"><div class="n">4</div><div class="l">VMs processed \(3 fully assessed\)</div></div>'
        $script:RenderedHtml | Should -Match '(?s)<div class="cards">.*VMs processed.*Hold state.*Investigate.*OK.*Incomplete.*Stale attached AVHDX layers.*Stale snapshots.*Orphaned \.avhdx.*</div>'
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
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match 'required Worker/VMMS logs are incomplete'
        $html | Should -Match 'TEST-NODE-01/Worker=Disabled'
        $html | Should -Not -Match 'wrapped past this active checkpoint'
        $html | Should -Not -Match 'only go back to'
    }

    It 'uses direct plain-English safety and recovery guidance' {
        $script:RenderedHtml | Should -Match '<strong>Reason for this verdict:</strong>'
        $script:RenderedHtml | Should -Match 'Do not move, rename, merge, or delete virtual disk files based solely on this report'
        $script:RenderedHtml | Should -Not -Match 'absence of evidence is not proof'
        $script:RenderedHtml | Should -Not -Match 'quarantine folder'
        $script:RenderedHtml | Should -Not -Match 'Driver:'
        $script:RenderedHtml | Should -Not -Match 'bounded operation window'
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
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
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
        $script:RenderedHtml | Should -Match '<div class="n">2</div><div class="l">Stale attached AVHDX layers</div>'
        $script:RenderedHtml | Should -Match '<div class="n">0</div><div class="l">Stale snapshots</div>'
        $script:RenderedHtml | Should -Match '<th>Stale<br>evidence</th>'
        $script:RenderedHtml | Should -Match '2 layers / 0 snapshots'
        $script:RenderedHtml | Should -Not -Match '>2 / 0<'
        $script:RenderedHtml | Should -Match "Stale attached AVHDX layers \(&ge;24h\)</div><div><span class='warnval'>2</span></div>"
        $script:RenderedHtml | Should -Match "Snapshot/layer representation</div><div><span class='warnval'>MISMATCH"
        $script:RenderedHtml | Should -Match "Oldest snapshot object / AVHDX timestamps</div><div><span class='warnval'>DIVERGENT - oldest snapshot object 2026-07-15 21:41:33Z; oldest AVHDX file 2026-06-21 21:37:32Z; difference 576\.1 h"
        $script:RenderedHtml | Should -Match '<th>Oldest snapshot<br>object age</th>'
        $script:RenderedHtml | Should -Match '2 stale attached AVHDX layer\(s\)'
        $script:RenderedHtml | Should -Match 'Attached VHD chain evidence \(3 layer\(s\)\)'
        $script:RenderedHtml | Should -Match "<div class='chain-scroll'><table class='chain-evidence'>"
        $script:RenderedHtml | Should -Match "<th class='num'>Layer</th><th>Role</th><th>Layer file</th>"
        $script:RenderedHtml | Should -Match "<tr class='chain-group'><th colspan='9'>Attached chain: <code>TEST-VM-STALE-LAYER_OS-CURRENT\.avhdx</code>"
        $script:RenderedHtml | Should -Match ">Active \(top\)</td><td class='chain-file'>TEST-VM-STALE-LAYER_OS-CURRENT\.avhdx</td>"
        $script:RenderedHtml | Should -Match ">Checkpoint</td><td class='chain-file'>TEST-VM-STALE-LAYER_OS-OLDER\.avhdx</td>"
        $script:RenderedHtml | Should -Match ">Base</td><td class='chain-file'>TEST-VM-STALE-LAYER_OS\.vhdx</td>"
        $script:RenderedHtml | Should -Match "<th class='num ckptage'>AVHDX file age</th><th class='num ckptage'>Last activity</th><th>Checkpoint stale</th>"
        $script:RenderedHtml | Should -Match '<summary>Full path and parent-path evidence</summary>'
        $script:RenderedHtml | Should -Match '<td><code>n/a \(base\)</code></td>'
        $script:RenderedHtml | Should -Match "<span class='warnval'>74 h<br>3\.1 d</span>.*0\.1 h<br>0 d.*<span class='warnval'>YES</span>"
        $script:RenderedHtml | Should -Match 'class=''num ckptage''>n/a</td><td class=''num ckptage''>98 h<br>4\.1 d<br><span class="muted">.*?</span></td><td>n/a \(base\)</td>'
    }

    It 'renders root and unavailable named-checkpoint parents explicitly' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData.Checkpoints = @(
            [pscustomobject]@{ Name = 'Root'; Type = 'Production'; Purpose = 'Production checkpoint (backup)'; Created = '2026-01-01 08:00:00Z'; AgeHrs = 2; Stale = $false; Parent = ''; ParentDisplay = 'n/a (root)' }
            [pscustomobject]@{ Name = 'Child'; Type = 'Production'; Purpose = 'Production checkpoint (backup)'; Created = '2026-01-01 09:00:00Z'; AgeHrs = 1; Stale = $false; Parent = 'Root'; ParentDisplay = 'Root' }
            [pscustomobject]@{ Name = 'Unknown'; Type = 'Production'; Purpose = 'Production checkpoint (backup)'; Created = '2026-01-01 09:30:00Z'; AgeHrs = 0.5; Stale = $false; Parent = ''; ParentDisplay = 'Unavailable' }
        )
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-PARENTS'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 10:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.27' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 2 -ClusterCsvCount 1

        $html | Should -Match '<td class=''ckptname''>Root</td>.*<td>n/a \(root\)</td>'
        $html | Should -Match "<th class='num ckptage'>Snapshot object age</th>"
        $html | Should -Match '<td class=''ckptname''>Child</td>.*<td>Root</td>'
        $html | Should -Match '<td class=''ckptname''>Unknown</td>.*<td>Unavailable</td>'
    }

    It 'uses driver-specific TXT escalation language' {
        $source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1') -Raw

        $source | Should -Match 'This event evidence does not identify a disk requiring manual action\.'
        $source | Should -Match 'Escalate if a merge failure or durable artifact persists, ownership or purpose cannot be established'
        $source | Should -Match 'Escalate if the abnormal state persists after connectivity, capacity, and configuration review\.'
        $source | Should -Match 'Route first to the collection owner'
        $source | Should -Match 'Do not modify HRL files based on this report\.'
    }

    It 'uses Replica-specific guidance for a Replica-only INVESTIGATE result' {
        $script:RenderedHtml | Should -Match 'Review the Hyper-V Replica details below, confirm connectivity and capacity on both replication partners'
        $replicaCard = [regex]::Match($script:RenderedHtml, '(?s)<details class="vm" id="vm-TEST-VM-REPLICA" open>.*?</details>').Value
        $replicaCard | Should -Not -Match 'checkpoint fork-commit signature was NOT observed'
    }

    It 'uses reliability guidance without merge or removal advice for an event-only INVESTIGATE result' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData.VmEventConcernCount = 7
        $reportData.VmHighConcernCount = 7
        $reportData.VmHighOpCount = 7
        $reportData.VmEscalatingConcernCount = 7
        $reportData.VmHighConcernIds = '18012 x7'
        $reportData.EventsCsvName = 'TEST-VM-EVENTS_Events.csv'
        $reportData.EventBreakdown = @([pscustomobject]@{ Id = 18012; Count = 7; First = '2026-07-15 22:00:20'; Last = '2026-07-21 22:00:20'; Sample = 'Checkpoint operation failed.' })
        $reportData | Add-Member -NotePropertyName InvestigationDrivers -NotePropertyValue ([pscustomobject]@{
            Labels = @('7 unresolved VM-attributed checkpoint/merge operation failure event(s) [18012 x7]')
            AssessmentText = 'Recurring checkpoint or merge operation failures require job-history review.'
            ActionLines = @('Compare the VM event CSV timestamps and IDs with backup/checkpoint job history.')
            HasCheckpointArtifact = $false; HasEvents = $true; HasReplica = $false
            HasStateInconclusive = $false; HasVss = $false; HasStorage = $false; HasEvidenceUnavailable = $false
        })
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-EVENTS'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' `
            -GeneratedUtc '2026-07-21 12:00:00' -DiscoveredVMs @() `
            -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match 'checkpoint reliability evidence rather than proof of chain corruption'
        $html | Should -Match 'there is no disk merge or removal action from this result'
        $html | Should -Match '<details open><summary>Concerning events attributable to this VM \(7 in 168h\)</summary>'
        $html | Should -Match '<strong>What to INVESTIGATE for this VM - recurring backup/checkpoint reliability:</strong> This <code>18012</code> finding does not, by itself, require Microsoft Support involvement\.'
        $html | Should -Match '<strong>Observed pattern:</strong> Review the expanded event evidence below for the first/last timestamps and recurrence\.'
        $html | Should -Match 'Event <code>18012</code> alone does not identify a virtual-disk file that requires operator action\.'
        $html | Should -Match 'If Hyper-V or the backup product is already performing a checkpoint cleanup or merge, allow that managed operation to complete'
        $html | Should -Match 'For repeated failures, if applicable, check with your backup solution vendor for assistance and guidance\.'
        $html | Should -Match 'open a support request \(SR\) case with Microsoft Support when recurring checkpoint failures remain after the backup/checkpoint owner has ruled out their component\.'
        $html | Should -Not -Match 'Do not place the VM under a migration/restart hold based on event <code>18012</code> alone\.'
        $html | Should -Not -Match 'Escalate to Microsoft Support when|durable disk artifact|disk residue|do not manually merge'
        $html | Should -Not -Match 'before any merge/removal action'
    }

    It 'names only the present snapshot and orphan evidence in artifact guidance' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData.StaleCheckpointCount = 1
        $reportData.OrphanCount = 1
        $reportData.HasOrphans = $true
        $reportData | Add-Member -NotePropertyName InvestigationDrivers -NotePropertyValue ([pscustomobject]@{
            Labels = @('1 stale named snapshot(s) at or beyond 24h', '1 orphaned .avhdx file(s)')
            AssessmentText = 'Checkpoint or virtual-disk evidence requires validation.'
            ActionLines = @('Review the snapshot and orphan evidence with the backup/storage owner.')
            HasCheckpointArtifact = $true; HasEvents = $false; HasReplica = $false
            HasStateInconclusive = $false; HasVss = $false; HasStorage = $false; HasEvidenceUnavailable = $false
        })
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-ARTIFACT'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 1; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' `
            -GeneratedUtc '2026-07-21 12:00:00' -DiscoveredVMs @() `
            -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match 'No confirming checkpoint fork-commit signature was observed, so on-disk chain corruption is not established\.'
        $html | Should -Match 'Before modifying any checkpoint-related AVHDX/VHD artifact or differencing chain, validate the stale snapshot and orphaned \.avhdx with the backup/storage owner, confirm ownership and purpose, verify current backup protection, and follow an approved procedure\.'
        $html | Should -Not -Match 'attached-chain, checkpoint, orphan, event, and backup-job evidence'
    }

    It 'uses rerun guidance and names the driver for a state-only INVESTIGATE result' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData | Add-Member -NotePropertyName StateConsistencyStatus -NotePropertyValue 'Changed'
        $reportData | Add-Member -NotePropertyName InvestigationDrivers -NotePropertyValue ([pscustomobject]@{
            Labels = @('INCONCLUSIVE collection state (Changed: ConfigLastWriteUtc)')
            AssessmentText = 'The VM changed state during collection, so the evidence is inconclusive.'
            ActionLines = @('Rerun the audit after activity has settled.')
            HasCheckpointArtifact = $false; HasEvents = $false; HasReplica = $false
            HasStateInconclusive = $true; HasVss = $false; HasStorage = $false; HasEvidenceUnavailable = $false
        })
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-STATE'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' `
            -GeneratedUtc '2026-07-21 12:00:00' -DiscoveredVMs @() `
            -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match 'INCONCLUSIVE collection state \(Changed: ConfigLastWriteUtc\)'
        $html | Should -Match 'Rerun the audit after migration, checkpoint, merge, replication, or power-state activity has settled'
        $html | Should -Not -Match 'stalled / failed backup checkpoint'
    }

    It 'uses the shared investigation driver model for TXT findings and final reasons' {
        $moduleSourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1'
        $moduleSource = Get-Content -LiteralPath $moduleSourcePath -Raw
        $moduleSource | Should -Match 'InvestigationDrivers = \$investigationDrivers'
        $moduleSource | Should -Match 'foreach \(\$driverLabel in @\(\$investigationDrivers\.Labels\)\)'
        $moduleSource | Should -Match 'Why flagged: \{0\}.*investigationDrivers\.Labels'
        $moduleSource | Should -Not -Match 'Why flagged: \{0\} concerning event\(s\).*stale attached AVHDX'
    }

    It 'labels stale snapshot counts instead of rendering an ambiguous ratio' {
        $reportData = $normalReportData.PSObject.Copy()
        $reportData.StaleCheckpointCount = 1
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-STALE-SNAPSHOT'; OwningNode = 'TEST-NODE-01'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 1; ReportData = $reportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' `
            -GeneratedUtc '2026-07-20 12:26:52' -DiscoveredVMs @() `
            -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
            -ClusterNodeCount 1 -ClusterCsvCount 1 -HousekeepingFindings @()

        $html | Should -Match '0 layers / 1 snapshot'
        $html | Should -Not -Match '>0 / 1<'
    }

    It 'places operational housekeeping observations immediately before the appendix' {
        $script:RenderedHtml | Should -Match 'Cluster / storage housekeeping to review:'
        $script:RenderedHtml | Should -Match 'Operational excellence and consistent storage practices improve reliability and reduce operational complexity.'
        $script:RenderedHtml | Should -Match 'VM owner\(s\): OWNER-VM\. Folder-associated VM\(s\): FOLDER-VM\.'
        $script:RenderedHtml | Should -Match 'Do not move, rename, merge, or delete virtual disk files based solely on this report.'
        $script:RenderedHtml | Should -Match 'row and category totals may overlap and are not unique-file counts'
        $script:RenderedHtml.IndexOf('Cluster / storage housekeeping to review:') | Should -BeLessThan $script:RenderedHtml.IndexOf('Appendix - Knowledge and Information')
    }

    It 'shows an explicit message instead of an empty housekeeping table' {
        $html = ConvertTo-VMCheckpointAuditHtml `
            -Results @([pscustomobject]@{ VMName = 'TEST-VM-NORMAL'; OwningNode = 'TEST-NODE-01'; Recommendation = 'OK'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $normalReportData; Detail = '' }) `
            -StaleHours 24 -EventLookbackHours 168 -ClusterName 'CONTOSO-CLUSTER-01' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs $null -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' `
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

    It 'links unattached base disk housekeeping guidance in a new tab' {
        $script:CleanRenderedHtml | Should -Match 'supplied via -PolicyPath \(see <a href="https://aka\.ms/Get-HyperVVMCheckpointHealth#cluster-storage-housekeeping" target="_blank" rel="noopener noreferrer">housekeeping guidance</a>\)\.'
        $script:CleanRenderedHtml | Should -Not -Match "<td data-label='Review'>[^<]*\(see housekeeping guidance\)"
    }

    It 'gives housekeeping findings readable desktop columns and stacked mobile labels' {
        $script:RenderedHtml | Should -Match '<table class="housekeeping" id="hk-table"><colgroup>'
        $script:RenderedHtml | Should -Match '<col class="hk-category"><col class="hk-scope"><col class="hk-filecol"><col class="hk-size"><col class="hk-observation"><col class="hk-review">'
        $script:RenderedHtml | Should -Match 'data-sort="scope" data-direction="none" aria-label="Sort by Scope"><span>Scope</span><span class="hk-sort-arrows" aria-hidden="true"><span class="hk-sort-up">&#9650;</span><span class="hk-sort-down">&#9660;</span>'
        $script:RenderedHtml | Should -Match "<td data-label='Scope'><code>TEST-VM-NORMAL</code></td>"
        $script:RenderedHtml | Should -Match "<td data-label='Scope'><code>TEST-NODE-02</code></td>"
        $script:RenderedHtml | Should -Match "<div class='hk-file'><code>Data&lt;review&gt;\.vhdx</code></div><code>C:\\ClusterStorage"
        $script:RenderedHtml | Should -Match "data-label='Size' class='num'>1\.50 MB</td>"
        $script:RenderedHtml | Should -Match 'VM owner\(s\): OWNER-VM\. Folder-associated VM\(s\): FOLDER-VM\.'
        $script:RenderedHtml | Should -Not -Match '1572864 bytes'
        $script:RenderedHtml | Should -Match 'table\.housekeeping\{table-layout:fixed\}'
        $script:RenderedHtml | Should -Match 'table\.housekeeping col\.hk-filecol\{width:24%\}'
        $script:RenderedHtml | Should -Match 'table\.housekeeping col\.hk-review\{width:16%\}'
        $script:RenderedHtml | Should -Match 'table\.housekeeping td::before\{content:attr\(data-label\)'
        $script:RenderedHtml | Should -Match 'table\.housekeeping td \.hk-observation\{grid-column:2;min-width:0\}'
        ([regex]::Matches($script:RenderedHtml, 'class="hk-sort-arrows"')).Count | Should -Be 4
        $script:RenderedHtml | Should -Match "parentNode\.setAttribute\('aria-sort', direction\)"
        $script:RenderedHtml | Should -Match "data-direction='ascending'.*hk-sort-up"
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
        $recommendedIndex = $script:RenderedHtml.IndexOf('<h2>Recommended next steps</h2>')
        $eventCountsIndex = $script:RenderedHtml.IndexOf('<strong>Reading the event counts:</strong>')
        $summaryTableIndex = $script:RenderedHtml.IndexOf('<h2>VM summary table</h2>')
        $recommendedIndex | Should -BeGreaterThan -1
        $summaryTableIndex | Should -BeGreaterThan $recommendedIndex
        $eventCountsIndex | Should -BeGreaterThan $summaryTableIndex
        $script:RenderedHtml | Should -Match "box\.addEventListener\('change', applyFilters\)"
        $script:RenderedHtml | Should -Match 'seen\[identity\]'
    }

    It 'exports every housekeeping row to CSV using embedded report metadata' {
        $script:RenderedHtml | Should -Match "class='hk-tools-header'>.*class='hk-export' type='button' id='hk-export-csv'"
        $script:RenderedHtml | Should -Match "id='hk-export-csv' data-cluster='CONTOSO-CLUSTER-01' data-generated='2026-01-01 00:00:00Z'"
        $script:RenderedHtml | Should -Match 'Download all findings \(CSV\)'
        $script:RenderedHtml | Should -Match 'function csvEscape\(value\)'
        $script:RenderedHtml | Should -Match 'rows\.forEach\(function \(row\)'
        $script:RenderedHtml | Should -Match "return 'CheckpointHousekeeping-' \+ cluster \+ '-' \+ timestamp \+ '\.csv'"
        $script:RenderedHtml | Should -Match "new Blob\(\['\\uFEFF' \+ lines\.join\('\\r\\n'\)\]"
        $script:RenderedHtml | Should -Match "data-file-name='Data&lt;review&gt;\.vhdx'.*data-observation='VM owner\(s\): OWNER-VM\. Folder-associated VM\(s\): FOLDER-VM\. The authoritative VM reference and detected storage-folder association differ &lt;review&gt;\.'"
        $script:RenderedHtml | Should -Match "getElementById\('hk-export-csv'\)\.addEventListener\('click', exportHousekeepingCsv\)"
    }

    It 'sorts housekeeping findings by size descending by default' {
        $script:RenderedHtml | Should -Match 'aria-sort="descending"><button class="hk-sort" type="button" data-sort="bytes" data-direction="descending" aria-label="Sort by Size, currently descending"'
        $script:RenderedHtml | Should -Match 'var sortAscending = \{ bytes: false \};'
        $largeRowIndex = $script:RenderedHtml.IndexOf("data-file-name='Data&lt;review&gt;.vhdx'")
        $zeroByteRowIndex = $script:RenderedHtml.IndexOf("data-file-name='BaseImage.vhdx'")
        $largeRowIndex | Should -BeGreaterThan -1
        $zeroByteRowIndex | Should -BeGreaterThan $largeRowIndex
    }

    It 'filters selected unattached VHDX rows and offers a downloadable persistent policy below the table' {
        ([regex]::Matches($script:RenderedHtml, "class='hk-image-filter' type='checkbox'> Filter out as VM image")).Count | Should -Be 1
        $script:RenderedHtml | Should -Match "id='hk-image-policy' hidden><h3>Persistent VM image policy settings</h3>"
        $script:RenderedHtml | Should -Match "id='hk-image-policy-yaml' readonly aria-label='Generated VM image policy settings'"
        $script:RenderedHtml | Should -Match "id='hk-download-policy'>Download checkpoint-health-policy\.yml</button>"
        $script:RenderedHtml | Should -Match "id='hk-copy-policy'>Copy policy settings</button>"
        $script:RenderedHtml | Should -Match "id='hk-restore-images'>Restore all rows</button>"
        $script:RenderedHtml.IndexOf('</tbody></table>') | Should -BeLessThan $script:RenderedHtml.IndexOf("id='hk-image-policy'")
        $script:RenderedHtml.IndexOf("id='hk-image-policy'") | Should -BeLessThan $script:RenderedHtml.IndexOf('Appendix - Knowledge and Information')
        $script:RenderedHtml | Should -Match "var matches = \(!imageBox \|\| !imageBox\.checked\)"
        $script:RenderedHtml | Should -Match "yamlLines = \['schemaVersion: 1', 'storage:', '    imageLibraryPathPatterns:'\]"
        $script:RenderedHtml | Should -Match "escapeRegex\(path\)"
        $script:RenderedHtml | Should -Match "function downloadImagePolicy\(\)"
        $script:RenderedHtml | Should -Match "new Blob\(\[content\], \{ type: 'application/yaml;charset=utf-8' \}\)"
        $script:RenderedHtml | Should -Match "link\.download = 'checkpoint-health-policy\.yml'"
        $script:RenderedHtml | Should -Match "getElementById\('hk-download-policy'\)\.addEventListener\('click', downloadImagePolicy\)"
        $script:RenderedHtml | Should -Match "hidden only in this open report"
        $script:RenderedHtml | Should -Match 'For a new policy, select <strong>Download checkpoint-health-policy\.yml</strong>'
        $script:RenderedHtml | Should -Match 'For an existing policy, select <strong>Copy policy settings</strong>.*copy only the generated <code>- .* entries into its existing <code>storage\.imageLibraryPathPatterns</code> list'
        $script:RenderedHtml | Should -Match "Supply the saved YAML file to the original audit command with <code>-PolicyPath '\.\\checkpoint-health-policy\.yml'</code>"
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
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' -ClusterNodeCount 1 -ClusterCsvCount 1 `
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
            -StorageHealth $null -ScriptVersion '0.2.21' -ReportGenerationTime '00:00:01' -ClusterNodeCount 1 -ClusterCsvCount 1 `
            -HousekeepingFindings @([pscustomobject]@{ Category = 'Placement'; Scope = 'TEST-VM'; FileName = 'Large.vhdx'; FullName = 'C:\ClusterStorage\Volume1\Large.vhdx'; ParentPath = 'C:\ClusterStorage\Volume1'; CsvRoot = 'C:\ClusterStorage\Volume1'; Extension = '.vhdx'; Length = $twoTerabytes; Observation = 'Synthetic'; Review = 'Review.' })

        $html | Should -Match "id='hk-visible-bytes'>2\.00 TB</strong>"
        $html | Should -Match "data-label='Size' class='num'>2\.00 TB</td>"
        $html | Should -Not -Match "$twoTerabytes bytes"
        $html | Should -Match 'return readable;'
    }

    It 'contains wide non-housekeeping tables on narrow screens' {
        $script:RenderedHtml | Should -Match '\.wrap\{width:100%;max-width:1440px;margin:0 auto;padding:32px 24px 80px\}'
        $script:RenderedHtml | Should -Match '@media\(max-width:1440px\)\{table:not\(\.housekeeping\)\{display:block;overflow-x:auto\}\}'
    }

    It 'wraps long generated tokens inside mobile callouts' {
        $script:RenderedHtml | Should -Match '\.callout\{[^}]*overflow-wrap:anywhere'
        $script:RenderedHtml | Should -Match '\.callout li\{min-width:0;overflow-wrap:anywhere\}'
    }

    It 'uses confirmed wording prominently when historic event evidence confirms rollback' {
        $confirmedReportData = $normalReportData.PSObject.Copy()
        $confirmedReportData.HasRollbackFingerprint = $true
        $confirmedReportData.HistoricForkConfirmed = $true
        $confirmedReportData.RollbackDate = '2025-12-01'
        $confirmedReportData.OrphanCount = 2
        $confirmedReportData.HasOrphans = $true
        $confirmedReportData.SeverityScore = 90
        $html = ConvertTo-VMCheckpointAuditHtml -Results @(
            [pscustomobject]@{ VMName = 'TEST-VM-CONFIRMED'; OwningNode = 'TEST-NODE'; Recommendation = 'INVESTIGATE'; Source = 'Input'; StaleCheckpointCount = 0; ReportData = $confirmedReportData; Detail = '' }
        ) -StaleHours 24 -EventLookbackHours 168 -ClusterName 'TEST-CLUSTER' -GeneratedUtc '2026-01-01 00:00:00' `
            -DiscoveredVMs @() -DiscoverySummary ([pscustomobject]@{ EligibleCount = 0; AuditedCount = 0; DeferredCount = 0; Cap = $null }) `
            -StorageHealth $null -HousekeepingFindings @() -IncludeDiscoveredVMs:$false -ScriptVersion '0.2.26' `
            -ReportGenerationTime '00:00:01' -ClusterNodeCount 1 -ClusterCsvCount 1

        $html | Should -Match 'PRIORITY - CONFIRMED historic rollback \(1 VM\(s\)\)'
        $html | Should -Match 'INVESTIGATE - CONFIRMED historic rollback\.'
        $html | Should -Not -Match 'PRIORITY - possible historic rollback'
        $html | Should -Not -Match 'INVESTIGATE - possible historic rollback\.'
    }

    It 'contains only the VM summary table within the shared report width on desktop' {
        $script:RenderedHtml | Should -Match '\.vm-summary-scroll\{width:100%;max-width:100%;overflow-x:auto\}'
        $script:RenderedHtml | Should -Match '(?s)<h2>VM summary table</h2>.*?<div class="vm-summary-scroll">\s*<table>.*?</tbody></table></div>'
        ([regex]::Matches($script:RenderedHtml, '<div class="vm-summary-scroll">')).Count | Should -Be 1
    }

    It 'stacks per-VM key-value details on narrow screens' {
        $script:RenderedHtml | Should -Match '@media\(max-width:640px\)\{[^}]*\.cards\{[^}]+\}\s*\.kv\{grid-template-columns:minmax\(0,1fr\);gap:0\}'
        $script:RenderedHtml | Should -Match '\.kv div\{min-width:0\}'
        $script:RenderedHtml | Should -Match '\.kv div\.k\{margin-top:8px\}'
        $script:RenderedHtml | Should -Match '@media\(max-width:390px\)\{[^}]*\.cards\{grid-template-columns:1fr\}\s*\.hk-charts\{grid-template-columns:minmax\(0,1fr\)\}'
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
        $script:ScriptVersion = '0.2.24'
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
            '(?s)<details class="vm(?: hold)?" id="vm-(TestVM\d{2})"(?: open)?>(.*?)(?=<details class="vm(?: hold)?" id="vm-|</div></details>\s*<details class=''report-section'' id=''cluster-storage-health'')'
        )
    }

    It 'uses the approved synthetic ten-node, twenty-VM inventory' {
        $script:ExampleHtml | Should -Match '<strong>Synthetic example report\.</strong>'
        $script:ExampleHtml | Should -Match 'Cluster <b>contoso01</b>'
        $script:ExampleHtml | Should -Match 'Cluster size: <b>10</b> nodes'
        $script:ExampleHtml | Should -Match '<div class="n">20</div><div class="l">VMs processed \(20 fully assessed\)</div>'
        @($script:DetailBlocks).Count | Should -Be 20
        @($script:DetailBlocks | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique).Count | Should -Be 20
    }

    It 'uses Zulu notation for every displayed absolute timestamp' {
        [regex]::Matches($script:ExampleHtml, '(?<!\d)20\d{2}-\d{2}-\d{2} \d{2}:\d{2}(?::\d{2})?(?![Z\d:])').Count | Should -Be 0
        $script:ExampleHtml | Should -Not -Match '20\d{2}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z UTC'
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
        $script:ExampleHtml | Should -Match '<div class="n">4</div><div class="l">Stale attached AVHDX layers</div>'
        $script:ExampleHtml | Should -Match '<div class="n">3</div><div class="l">Stale snapshots</div>'
        $script:ExampleHtml | Should -Match "Confirmed historic 'fork-commit / merge failure'"
        $script:ExampleHtml | Should -Match "HOLD STATE - fork-commit recorded at this active checkpoint's creation"
        $script:ExampleHtml | Should -Match 'Error \(Critical\)'
        $script:ExampleHtml | Should -Match 'Resynchronizing \(Warning\)'
        [regex]::Matches($script:ExampleHtml, '<div class="k">VSS writers</div><div>All 10 writer\(s\) Stable \(no last error\)</div>').Count | Should -Be 20
    }

    It 'demonstrates conditional incompatible file-system filter guidance' {
        $script:ExampleHtml | Should -Match 'Incompatible file-system filter reported:'
        $script:ExampleHtml | Should -Match 'IncompatibleFileSystemFilter, FileSystemReFs'
        $script:ExampleHtml | Should -Match 'fltmc filters'
        $script:ExampleHtml | Should -Match 'Do not unload or remove a filter based only on this report'
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
        $script:ExampleHtml | Should -Match 'VM owner\(s\): TestVM03\. Folder-associated VM\(s\): TestVM08\.'
        $script:ExampleHtml | Should -Match 'The authoritative VM reference and detected storage-folder association differ\.'
        $script:ExampleHtml | Should -Match 'Unattached base disk candidate'
        $script:ExampleHtml | Should -Match 'Shared virtual disk reference'
        $script:ExampleHtml | Should -Match 'Shared VHD Set reference'
        $script:ExampleHtml | Should -Match 'GuestClusterData\.vhds'
        $script:ExampleHtml | Should -Match 'TestVM08_LegacyData\.vhdx'
        $script:ExampleHtml | Should -Match 'TestVM12_Archive\.vhdx'
        ([regex]::Matches($script:ExampleHtml, "class='hk-image-filter' type='checkbox'> Filter out as VM image")).Count | Should -Be 2
        $script:ExampleHtml | Should -Match "id='hk-image-policy' hidden><h3>Persistent VM image policy settings</h3>"
        $script:ExampleHtml | Should -Match 'If this virtual disk belongs to an image library, exclude its full path with storage\.imageLibraryPathPatterns in a checkpoint-health-policy\.yml file supplied via -PolicyPath \(see <a href="https://aka\.ms/Get-HyperVVMCheckpointHealth#cluster-storage-housekeeping" target="_blank" rel="noopener noreferrer">housekeeping guidance</a>\)\.'
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

    It 'flags an old attached AVHDX even when it was written recently and no named snapshot exists' {
        $assessment = Get-CheckpointStalenessAssessment -DiskReports @(
            [pscustomobject]@{ Chain = @([pscustomobject]@{
                Type = 'Differencing'
                Created = $script:AssessmentNow.AddHours(-30)
                LastWrite = $script:AssessmentNow.AddMinutes(-5)
            }) }
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
            [pscustomobject]@{ Chain = @([pscustomobject]@{ Type = 'Differencing'; Created = $script:AssessmentNow.AddHours(-30); LastWrite = $script:AssessmentNow.AddMinutes(-5) }) }
            [pscustomobject]@{ Chain = @([pscustomobject]@{ Type = 'Differencing'; Created = $script:AssessmentNow.AddHours(-30); LastWrite = $script:AssessmentNow.AddMinutes(-10) }) }
        ) -Snapshots @([pscustomobject]@{ CreationTimeUtc = $script:AssessmentNow.AddHours(-30) }) `
            -StaleHours 24 -NowUtc $script:AssessmentNow

        $assessment.StaleAttachedLayerCount | Should -Be 2
        $assessment.StaleSnapshotCount | Should -Be 1
        $assessment.SnapshotLayerMismatch | Should -BeFalse
        $assessment.SnapshotLayerTimestampDivergence | Should -BeFalse
        $assessment.OldestTimestampDeltaHours | Should -Be 0
    }

    It 'reports divergent oldest snapshot-object and AVHDX-file timestamps independently' {
        $assessment = Get-CheckpointStalenessAssessment -DiskReports @(
            [pscustomobject]@{ Chain = @([pscustomobject]@{ Type = 'Differencing'; Created = $script:AssessmentNow.AddDays(-37.6) }) }
            [pscustomobject]@{ Chain = @([pscustomobject]@{ Type = 'Differencing'; Created = $script:AssessmentNow.AddDays(-37.6) }) }
        ) -Snapshots @([pscustomobject]@{ CreationTimeUtc = $script:AssessmentNow.AddDays(-13.6) }) `
            -StaleHours 24 -NowUtc $script:AssessmentNow

        $assessment.SnapshotLayerMismatch | Should -BeFalse
        $assessment.SnapshotLayerTimestampDivergence | Should -BeTrue
        $assessment.OldestTimestampDeltaHours | Should -Be 576
        $assessment.OldestSnapshotUtc | Should -Be $script:AssessmentNow.AddDays(-13.6).ToUniversalTime()
        $assessment.OldestAttachedLayerUtc | Should -Be $script:AssessmentNow.AddDays(-37.6).ToUniversalTime()
    }

    It 'counts an old checkpoint layer beneath a recently written active top layer' {
        $assessment = Get-CheckpointStalenessAssessment -DiskReports @(
            [pscustomobject]@{ Chain = @(
                [pscustomobject]@{ Type = 'Differencing'; Created = $script:AssessmentNow.AddHours(-1); LastWrite = $script:AssessmentNow.AddMinutes(-5) }
                [pscustomobject]@{ Type = 'Differencing'; Created = $script:AssessmentNow.AddHours(-48); LastWrite = $script:AssessmentNow.AddHours(-1) }
                [pscustomobject]@{ Type = 'Dynamic'; Created = $script:AssessmentNow.AddDays(-100); LastWrite = $script:AssessmentNow.AddDays(-100) }
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
        $result.Windows | Should -Be @('2026-07-10 10:00:00Z - 2026-07-10 14:00:00Z')
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

    It 'reports a zero missed rate when measured cycles are available' {
        $result = Get-HyperVReplicationAssessment -Enabled $true -State 'Replicating' -Health 'Normal' -Mode 'Primary' `
            -MeasurementsAvailable $true -FrequencySeconds 300 -SuccessfulCount 120 -MissedCount 0
        $result.MissedRatePercent | Should -Be 0
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

    It 'marks unresolved checkpoint request failures as verdict-driving CSV evidence' {
        $policy = Get-HyperVEventPolicy
        $event = [pscustomobject]@{ Id = 18012; 'Time (UTC)' = '2026-01-01 10:00:00'; FullMessage = 'Checkpoint operation failed.'; SignalRole = 'Operational'; IsConfirmingFork = $false }
        $result = Get-HyperVEventCsvDisposition -Event $event -Events @($event) -Policy $policy

        $result.EventClassification | Should -Be 'High-signal'
        $result.VerdictDriver | Should -BeTrue
        $result.RecoveryDisposition | Should -Be 'Unresolved'
    }

    It 'marks recovered merge failures and low-signal events as non-driving context' {
        $policy = Get-HyperVEventPolicy
        $failure = [pscustomobject]@{ Id = 19100; 'Time (UTC)' = '2026-01-01 10:00:00'; FullMessage = 'Merge failed for C:\ClusterStorage\Volume1\VM-TEST\disk-test.avhdx.'; SignalRole = 'Operational'; IsConfirmingFork = $false }
        $completion = [pscustomobject]@{ Id = 19080; 'Time (UTC)' = '2026-01-01 10:03:00'; FullMessage = 'Merge completed for C:\ClusterStorage\Volume1\VM-TEST\disk-test.avhdx.'; SignalRole = 'Context'; IsConfirmingFork = $false }
        $lowSignal = [pscustomobject]@{ Id = 19090; 'Time (UTC)' = '2026-01-01 10:04:00'; FullMessage = 'Background merge interrupted.'; SignalRole = 'Operational'; IsConfirmingFork = $false }

        $recovered = Get-HyperVEventCsvDisposition -Event $failure -Events @($failure, $completion) -Policy $policy
        $context = Get-HyperVEventCsvDisposition -Event $lowSignal -Events @($failure, $completion, $lowSignal) -Policy $policy

        $recovered.VerdictDriver | Should -BeFalse
        $recovered.RecoveryDisposition | Should -Be 'ConfirmedRecovered'
        $context.EventClassification | Should -Be 'Low-signal'
        $context.VerdictDriver | Should -BeFalse
        $context.RecoveryDisposition | Should -Be 'ContextOnly'
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

    It 'treats a sole config write under healthy active Replica as advisory' {
        Get-VMCollectionStateImpact -Status Changed -Reasons @('ConfigLastWriteUtc') `
            -ReplicationEnabled $true -ReplicaProductSeverity Healthy -ReplicaState Replicating | Should -Be 'Advisory'
    }

    It 'keeps a config write plus another state change inconclusive' {
        Get-VMCollectionStateImpact -Status Changed -Reasons @('ConfigLastWriteUtc', 'CheckpointCount') `
            -ReplicationEnabled $true -ReplicaProductSeverity Healthy -ReplicaState Replicating | Should -Be 'Inconclusive'
    }

    It 'keeps a config-only change without healthy active Replica inconclusive' {
        Get-VMCollectionStateImpact -Status Changed -Reasons @('ConfigLastWriteUtc') `
            -ReplicationEnabled $true -ReplicaProductSeverity Critical -ReplicaState WaitingForStartResynchronize | Should -Be 'Inconclusive'
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

    It 'fans remote ownership collection out once and restores stable node order' {
        $localNode = $env:COMPUTERNAME
        $remoteNodes = @('REMOTE-NODE-B', 'REMOTE-NODE-A')
        $script:FanoutJob = Start-Job -ScriptBlock { }
        Mock New-PSSession {
            [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }
        Mock Remove-PSSession { }
        Mock Wait-Job { $Job }
        Mock Receive-Job {
            foreach ($remoteNode in @('REMOTE-NODE-B', 'REMOTE-NODE-A')) {
                $remoteResult = [pscustomobject]@{
                    Complete = $true; VMCount = 1; SnapshotCount = 0
                    Rows = @([pscustomobject]@{ VMName = "VM-$remoteNode"; Path = "C:\TEST\$remoteNode.vhdx"; Source = 'Current' })
                    Folders = @(); Errors = @(); WorkerDurationMs = 25
                }
                Add-Member -InputObject $remoteResult -NotePropertyName PSComputerName -NotePropertyValue $remoteNode
                $remoteResult
            }
        }
        Mock Remove-Job { }
        Mock Get-VM { @() }
        Mock Invoke-Command {
            if ($AsJob) { $script:FanoutJob } else { & $ScriptBlock }
        }

        $result = Get-ClusterVirtualDiskOwnershipInventory -Nodes @($remoteNodes[0], $localNode, $remoteNodes[1]) `
            -LocalNode $localNode -SessionByNode @{}

        $result.Complete | Should -BeTrue
        $result.ExecutionMode | Should -Be 'ConcurrentRemote'
        $result.ThrottleLimit | Should -Be 2
        @($result.Nodes.Node) | Should -Be @('REMOTE-NODE-A', 'REMOTE-NODE-B', $localNode)
        @($result.Rows).Count | Should -Be 2
        Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { @($Session).Count -eq 2 -and $ThrottleLimit -eq 2 -and $AsJob }
        Should -Invoke Wait-Job -Times 1 -Exactly
        Should -Invoke Receive-Job -Times 1 -Exactly
        Should -Invoke Remove-PSSession -Times 2 -Exactly
    }

    It 'overlaps one remote worker with local collection on a two-node cluster' {
        $localNode = $env:COMPUTERNAME
        $script:OrchestrationOrder = [System.Collections.Generic.List[string]]::new()
        $script:FanoutJob = Start-Job -ScriptBlock { }
        Mock New-PSSession {
            [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }
        Mock Remove-PSSession { }
        Mock Wait-Job { $Job }
        Mock Receive-Job {
            $remoteResult = [pscustomobject]@{
                Complete = $true; VMCount = 0; SnapshotCount = 0
                Rows = @(); Folders = @(); Errors = @(); WorkerDurationMs = 25
            }
            Add-Member -InputObject $remoteResult -NotePropertyName PSComputerName -NotePropertyValue 'REMOTE-NODE-A'
            $remoteResult
        }
        Mock Remove-Job { }
        Mock Get-VM { [void]$script:OrchestrationOrder.Add('LocalCollected'); @() }
        Mock Invoke-Command {
            if ($AsJob) {
                [void]$script:OrchestrationOrder.Add('RemoteStarted')
                $script:FanoutJob
            } else {
                & $ScriptBlock
            }
        }

        $result = Get-ClusterVirtualDiskOwnershipInventory -Nodes @($localNode, 'REMOTE-NODE-A') `
            -LocalNode $localNode -SessionByNode @{}

        $result.Complete | Should -BeTrue
        $result.ExecutionMode | Should -Be 'ConcurrentRemote'
        $result.ThrottleLimit | Should -Be 1
        @($result.Nodes.Node) | Should -Be @('REMOTE-NODE-A', $localNode)
        @($script:OrchestrationOrder) | Should -Be @('RemoteStarted', 'LocalCollected')
        Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { @($Session).Count -eq 1 -and $ThrottleLimit -eq 1 -and $AsJob }
        Should -Invoke Wait-Job -Times 1 -Exactly
        Should -Invoke Receive-Job -Times 1 -Exactly
        Should -Invoke Remove-Job -Times 1 -Exactly
    }

    It 'keeps a single-node cluster local and sequential' {
        Mock Get-VM { @() }
        Mock New-PSSession { throw 'New-PSSession must not run for one local node.' }
        Mock Invoke-Command { throw 'Invoke-Command must not run for one local node.' }

        $result = Get-ClusterVirtualDiskOwnershipInventory -Nodes @($env:COMPUTERNAME) `
            -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeTrue
        $result.ExecutionMode | Should -Be 'Sequential'
        $result.ThrottleLimit | Should -Be 1
        @($result.Nodes.Node) | Should -Be @($env:COMPUTERNAME)
        Should -Invoke New-PSSession -Times 0 -Exactly
        Should -Invoke Invoke-Command -Times 0 -Exactly
    }

    It 'keeps management-workstation ownership collection sequential' {
        Mock New-PSSession {
            [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }
        Mock Get-VM { @() }
        Mock Invoke-Command { & $ScriptBlock }

        $result = Get-ClusterVirtualDiskOwnershipInventory -Nodes @('REMOTE-NODE-B', 'REMOTE-NODE-A') `
            -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeTrue
        $result.ExecutionMode | Should -Be 'Sequential'
        $result.ThrottleLimit | Should -Be 1
        Should -Invoke Invoke-Command -Times 2 -Exactly -ParameterFilter { @($Session).Count -eq 1 }
    }

    It 'falls back to sequential collection when concurrent session preparation fails' {
        $script:SessionOpenAttempt = 0
        Mock New-PSSession {
            $script:SessionOpenAttempt++
            if ($script:SessionOpenAttempt -eq 2) { throw 'Concurrent session preparation failed.' }
            [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }
        Mock Remove-PSSession { }
        Mock Get-VM { @() }
        Mock Invoke-Command { & $ScriptBlock }

        $result = Get-ClusterVirtualDiskOwnershipInventory `
            -Nodes @($env:COMPUTERNAME, 'REMOTE-NODE-A', 'REMOTE-NODE-B') `
            -LocalNode $env:COMPUTERNAME -SessionByNode @{}

        $result.Complete | Should -BeTrue
        $result.ExecutionMode | Should -Be 'SequentialFallback'
        $result.ThrottleLimit | Should -Be 1
        @($result.Nodes).Count | Should -Be 3
        Should -Invoke Invoke-Command -Times 2 -Exactly -ParameterFilter { @($Session).Count -eq 1 }
        Should -Invoke Remove-PSSession -Times 1 -Exactly
    }
}

Describe 'Node diagnostic prefetch runtime' {
    BeforeAll {
        $toolRoot = Split-Path $PSScriptRoot -Parent
        $modulePath = Join-Path $toolRoot 'Get-HyperVVMCheckpointHealth.psm1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$parseErrors)
        foreach ($functionName in @('Get-NodeDiagnosticSnapshot', 'Invoke-NodeDiagnosticPrefetch', 'Initialize-NodeDiagnosticPrefetch')) {
            $functionAst = $ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $node.Name -eq $functionName
            }, $true) | Select-Object -First 1
            $functionAst | Should -Not -BeNullOrEmpty
            Invoke-Expression $functionAst.Extent.Text
        }
        function Add-AuditDiagnosticMessage { param($Message, $Operation, $Scope) }
        function Add-AuditDiagnostic { param($ErrorRecord, $Operation, $Scope) }
        function Invoke-WithRetry {
            param($ScriptBlock, $DiagnosticOperation, $DiagnosticScope, [ref]$AttemptCount)
            if ($AttemptCount) { $AttemptCount.Value = 1 }
            & $ScriptBlock
        }
        function Write-AuditReportLine { param($Message) }
        function Write-Alert { param($Message, $Level) }
        function Get-TelemetryNow { [DateTimeOffset]::UtcNow }
        function Add-TelemetryEntry { param($Step, $Phase, $Detail, $StartUtc, $EndUtc) }
        function global:vssadmin { }
        function New-TestNodeDiagnosticSnapshot {
            param([string]$Node = 'REMOTE-NODE')
            [pscustomobject]@{
                Complete = $true; EventStatus = 'Success'; EventRows = @(); ChannelStatus = @(
                    [pscustomobject]@{ Channel = 'Worker'; Status = 'Success'; Error = '' }
                    [pscustomobject]@{ Channel = 'VMMS'; Status = 'Success'; Error = '' }
                ); EventError = ''; EventAttempts = 1; EventDurationMs = 20L
                VssStatus = 'Success'; VssRows = @(); VssError = ''; VssAttempts = 1; VssDurationMs = 10L
                Errors = @(); WorkerStartUtc = [DateTime]::UtcNow.AddMilliseconds(-30)
                WorkerEndUtc = [DateTime]::UtcNow; WorkerDurationMs = 30L
            }
        }
    }

    AfterAll {
        Remove-Item function:\global:vssadmin -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:NodeEventCache = @{}
        $script:VssByNode = @{}
        $script:NodeCsvNameByNode = @{}
        $script:SessionByNode = @{}
    }

    It 'retries transient event reads before running VSS on the same node' {
        $script:CollectionOrder = [System.Collections.Generic.List[string]]::new()
        $script:EventCallCount = 0
        Mock Get-WinEvent {
            [void]$script:CollectionOrder.Add('Event')
            $script:EventCallCount++
            if ($script:EventCallCount -eq 1) { throw 'Transient event read failure.' }
            [pscustomobject]@{
                TimeCreated = [DateTime]'2026-07-23T12:00:00Z'; Id = 19100
                LevelDisplayName = 'Error'; Message = "VM 'TEST-VM' merge failed."
            }
        }
        Mock vssadmin {
            [void]$script:CollectionOrder.Add('VSS')
            "Writer name: 'Test Writer'"
            '   State: [1] Stable'
            '   Last error: No error'
        }

        $result = Get-NodeDiagnosticSnapshot -LookbackHours 168 -ConcernIds @(19100) `
            -ContextIds @() -CodePatterns @() -MaxAttempts 3 -DelayMs 0

        $result.Complete | Should -BeTrue
        $result.EventAttempts | Should -Be 2
        $result.EventStatus | Should -Be 'Success'
        @($result.EventRows).Count | Should -Be 2
        $result.VssStatus | Should -Be 'Success'
        @($result.VssRows).Count | Should -Be 1
        @($script:CollectionOrder)[-1] | Should -Be 'VSS'
    }

    It 'continues to VSS and returns explicit partial failure when event retries are exhausted' {
        Mock Get-WinEvent { throw 'Event service unavailable.' }
        Mock vssadmin {
            "Writer name: 'Test Writer'"
            '   State: [1] Stable'
            '   Last error: No error'
        }

        $result = Get-NodeDiagnosticSnapshot -LookbackHours 168 -ConcernIds @() `
            -ContextIds @() -CodePatterns @() -MaxAttempts 2 -DelayMs 0

        $result.Complete | Should -BeFalse
        $result.EventStatus | Should -Be 'Unavailable'
        $result.EventAttempts | Should -Be 2
        $result.VssStatus | Should -Be 'Success'
        @($result.Errors).Count | Should -Be 1
        $result.Errors[0].Operation | Should -Be 'Event'
    }

    It 'fans remote nodes out with a bounded throttle while collecting the local node' {
        $localNode = $env:COMPUTERNAME
        $remoteNodes = @('REMOTE-NODE-B', 'REMOTE-NODE-A')
        $script:PrefetchOrder = [System.Collections.Generic.List[string]]::new()
        $script:FanoutJob = Start-Job -ScriptBlock { }
        Mock New-PSSession {
            [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }
        Mock Remove-PSSession { }
        Mock Remove-Job { }
        Mock Wait-Job { $Job }
        Mock Get-WinEvent { [void]$script:PrefetchOrder.Add('LocalEvent'); @() }
        Mock vssadmin { @() }
        Mock Receive-Job {
            foreach ($remoteNode in $remoteNodes) {
                $remoteResult = New-TestNodeDiagnosticSnapshot -Node $remoteNode
                Add-Member -InputObject $remoteResult -NotePropertyName PSComputerName -NotePropertyValue $remoteNode
                $remoteResult
            }
        }
        Mock Invoke-Command {
            if ($AsJob) {
                [void]$script:PrefetchOrder.Add('RemoteStarted')
                $script:FanoutJob
            } else {
                & $ScriptBlock @ArgumentList
            }
        }

        $result = Invoke-NodeDiagnosticPrefetch -Nodes @($remoteNodes[0], $localNode, $remoteNodes[1]) `
            -LocalNode $localNode -SessionByNode @{} -LookbackHours 168 `
            -ConcernIds @() -ContextIds @() -CodePatterns @() -ThrottleLimit 2 -MaxAttempts 1 -DelayMs 0

        $result.Complete | Should -BeTrue
        $result.ExecutionMode | Should -Be 'Concurrent'
        $result.ThrottleLimit | Should -Be 2
        @($result.Nodes.Node) | Should -Be @($remoteNodes[0], $remoteNodes[1], $localNode | Sort-Object)
        @($script:PrefetchOrder)[0] | Should -Be 'RemoteStarted'
        Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter {
            @($Session).Count -eq 2 -and $ThrottleLimit -eq 2 -and $AsJob
        }
        Should -Invoke Remove-PSSession -Times 2 -Exactly
    }

    It 'retries a remote node sequentially when fan-out returns no result for it' {
        $localNode = $env:COMPUTERNAME
        $remoteNodes = @('REMOTE-NODE-A', 'REMOTE-NODE-B')
        $script:FanoutJob = Start-Job -ScriptBlock { }
        Mock New-PSSession {
            [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }
        Mock Remove-PSSession { }
        Mock Remove-Job { }
        Mock Wait-Job { $Job }
        Mock Receive-Job {
            $remoteResult = New-TestNodeDiagnosticSnapshot -Node 'REMOTE-NODE-A'
            Add-Member -InputObject $remoteResult -NotePropertyName PSComputerName -NotePropertyValue 'REMOTE-NODE-A'
            $remoteResult
        }
        Mock Invoke-Command {
            if ($AsJob) { $script:FanoutJob } else { New-TestNodeDiagnosticSnapshot }
        }

        $result = Invoke-NodeDiagnosticPrefetch -Nodes $remoteNodes -LocalNode $localNode `
            -SessionByNode @{} -LookbackHours 168 -ConcernIds @() -ContextIds @() `
            -CodePatterns @() -ThrottleLimit 2 -MaxAttempts 1 -DelayMs 0

        $result.Complete | Should -BeTrue
        @($result.Nodes | Where-Object { $_.Node -eq 'REMOTE-NODE-B' }).ExecutionMode | Should -Be 'SequentialRetry'
        Should -Invoke Invoke-Command -Times 1 -Exactly -ParameterFilter { -not $AsJob }
    }

    It 'falls back to sequential collection when concurrent session preparation fails' {
        $localNode = $env:COMPUTERNAME
        $script:SessionOpenCount = 0
        Mock New-PSSession {
            $script:SessionOpenCount++
            if ($script:SessionOpenCount -eq 2) { throw 'Concurrent session preparation failed.' }
            [System.Runtime.Serialization.FormatterServices]::GetUninitializedObject(
                [System.Management.Automation.Runspaces.PSSession]
            )
        }
        Mock Remove-PSSession { }
        Mock Get-WinEvent { @() }
        Mock vssadmin { @() }
        Mock Invoke-Command { & $ScriptBlock @ArgumentList }

        $result = Invoke-NodeDiagnosticPrefetch `
            -Nodes @($localNode, 'REMOTE-NODE-A', 'REMOTE-NODE-B') -LocalNode $localNode `
            -SessionByNode @{} -LookbackHours 168 -ConcernIds @() -ContextIds @() `
            -CodePatterns @() -ThrottleLimit 2 -MaxAttempts 1 -DelayMs 0

        $result.Complete | Should -BeTrue
        $result.ExecutionMode | Should -Be 'SequentialFallback'
        $result.ThrottleLimit | Should -Be 1
        @($result.Nodes).Count | Should -Be 3
        @($result.Nodes.ExecutionMode | Sort-Object -Unique) | Should -Be @('SequentialFallback')
        Should -Invoke Invoke-Command -Times 2 -Exactly -ParameterFilter { -not $AsJob }
        Should -Invoke Remove-PSSession -Times 1 -Exactly
    }

    It 'does not launch prefetch again when both node caches are populated' {
        $node = 'REMOTE-NODE-A'
        $script:NodeEventCache["$node|168"] = [pscustomobject]@{ Status = 'Success'; Rows = @() }
        $script:VssByNode[$node] = @()
        Mock Invoke-NodeDiagnosticPrefetch { throw 'Coordinator must not run for cached nodes.' }

        $result = Initialize-NodeDiagnosticPrefetch -Nodes @($node) -LocalNode $env:COMPUTERNAME `
            -OutputPath '' -LookbackHours 168 -ConcernIds @() -ContextIds @() -CodePatterns @()

        $result.ExecutionMode | Should -Be 'Cached'
        @($result.Nodes).Count | Should -Be 0
        Should -Invoke Invoke-NodeDiagnosticPrefetch -Times 0 -Exactly
    }

    It 'merges prefetched event and VSS evidence and writes the node CSV once' {
        $node = 'REMOTE-NODE-A'
        $eventRow = [pscustomobject]@{
            'Time (UTC)' = '2026-07-23 12:00:00'; Id = 19100; Level = 'Error'; Log = 'VMMS'
            Concern = 'YES'; Message = 'Merge failed'; FullMessage = 'Merge failed'
        }
        $snapshot = New-TestNodeDiagnosticSnapshot -Node $node
        $snapshot.EventRows = @($eventRow)
        $snapshot.VssRows = @([pscustomobject]@{ Writer = 'Test Writer'; State = '[1] Stable'; 'Last error' = 'No error' })
        Mock Invoke-NodeDiagnosticPrefetch {
            [pscustomobject]@{
                Complete = $true; ExecutionMode = 'Concurrent'; ThrottleLimit = 1
                CoordinatorDurationMs = 30L
                Nodes = @([pscustomobject]@{
                    Node = $node; Complete = $true; DurationMs = 30L
                    ExecutionMode = 'ConcurrentRemote'; Result = $snapshot; Error = ''
                })
            }
        }

        $result = Initialize-NodeDiagnosticPrefetch -Nodes @($node) -LocalNode $env:COMPUTERNAME `
            -OutputPath $TestDrive -LookbackHours 168 -ConcernIds @(19100) -ContextIds @() -CodePatterns @()

        $result.Complete | Should -BeTrue
        $script:NodeEventCache["$node|168"].Status | Should -Be 'Success'
        @($script:NodeEventCache["$node|168"].Rows).Count | Should -Be 1
        @($script:VssByNode[$node]).Count | Should -Be 1
        $script:NodeCsvNameByNode[$node] | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $TestDrive $script:NodeCsvNameByNode[$node]) | Should -BeTrue
    }
}

Describe 'Ownership inventory performance telemetry contracts' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1'
        $source = Get-Content -LiteralPath $modulePath -Raw
    }

    It 'records worker and coordinator timing with execution mode and throttle' {
        $source | Should -Match "Add-TelemetryEntry -Step '1\.07\.10\.10' -Phase 'Ownership inventory worker'"
        $source | Should -Match "Add-TelemetryEntry -Step '1\.07\.10\.20' -Phase 'Ownership inventory worker coordination'"
        $source | Should -Match 'Mode=\{0\}; Nodes=\{1\}; RemoteNodes=\{2\}; Throttle=\{3\}'
        $source | Should -Match 'WorkerDurationMs=\{5\}; NodeElapsedMs=\{6\}; WallDurationMs=\{7\}'
        $source | Should -Match 'ClockAdjustmentMs=\{7\}'
        $source | Should -Match '\$nodeStart = \$nodeEnd\.AddMilliseconds\(-1 \* \$workerDurationMs\)'
        $source | Should -Match 'WorkerStartUtc = \$workerStartUtc'
        $source | Should -Match 'WorkerEndUtc\s+= \[DateTime\]::UtcNow'
        $source | Should -Match "\$executionMode = 'ConcurrentRemote'"
        $source | Should -Match '\$remoteNodes\.Count -gt 0'
        $source | Should -Match '-ThrottleLimit \$throttleLimit -AsJob -ErrorAction Stop'
        $source | Should -Match '\$throttleLimit = \[math\]::Min\(8, \$remoteNodes\.Count\)'
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
        $result.PlacementReason | Should -Be 'UnreferencedInVMAssociatedFolder'
        $result.Owners | Should -BeNullOrEmpty
        $result.AssociatedVMs | Should -Be @('TEST-VM-01')
        $result.HealthVerdictImpact | Should -BeFalse
    }

    It 'retains the unattached differencing category for an AVHDX in a VM-associated folder' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\TEST-VM-01\detached.avhdx' -Owners @() `
            -VMAssociatedFolders @([pscustomobject]@{ VMName = 'TEST-VM-01'; Path = 'C:\TEST\CSV01\TEST-VM-01' }) `
            -CoverageComplete $true -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'UnattachedDifferencingCandidate'
        $result.PlacementReason | Should -BeNullOrEmpty
        $result.AssociatedVMs | Should -Be @('TEST-VM-01')
        $result.HealthVerdictImpact | Should -BeFalse
    }

    It 'distinguishes an authoritative owner from a different VM-associated folder' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\FOLDER-VM\attached.vhdx' -Owners @('OWNER-VM') `
            -VMAssociatedFolders @([pscustomobject]@{ VMName = 'FOLDER-VM'; Path = 'C:\TEST\CSV01\FOLDER-VM' }) `
            -CoverageComplete $true -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'PlacementInconsistency'
        $result.PlacementReason | Should -Be 'ReferencedOwnerFolderMismatch'
        $result.Owners | Should -Be @('OWNER-VM')
        $result.AssociatedVMs | Should -Be @('FOLDER-VM')
    }

    It 'allows an attached disk when a shared folder is associated with its owner and another VM' {
        $sharedPath = 'C:\TEST\CSV01\arc-rp-storage'
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path "$sharedPath\OWNER-VM-OSDisk.vhdx" -Owners @('OWNER-VM') `
            -VMAssociatedFolders @(
                [pscustomobject]@{ VMName = 'OWNER-VM'; Path = $sharedPath }
                [pscustomobject]@{ VMName = 'SIBLING-VM'; Path = $sharedPath }
            ) -CoverageComplete $true -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'AttachedVirtualDisk'
        $result.PlacementReason | Should -BeNullOrEmpty
        $result.Owners | Should -Be @('OWNER-VM')
        $result.AssociatedVMs | Should -Be @('OWNER-VM', 'SIBLING-VM')
    }

    It 'allows an attached disk outside detected VM folders' {
        $result = Get-VirtualDiskHousekeepingClassification `
            -Path 'C:\TEST\CSV01\SharedData\attached.vhdx' -Owners @('OWNER-VM') `
            -VMAssociatedFolders @([pscustomobject]@{ VMName = 'OWNER-VM'; Path = 'C:\TEST\CSV01\OWNER-VM' }) `
            -CoverageComplete $true -ImageLibraryPathPatterns $script:ImageLibraryPathPatterns

        $result.Classification | Should -Be 'AttachedVirtualDisk'
        $result.PlacementReason | Should -BeNullOrEmpty
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

    It 'keeps image-library guidance off attached placement inconsistencies' {
        $source = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-HyperVVMCheckpointHealth.psm1') -Raw
        $source | Should -Match 'VM owner\(s\): none\. Folder-associated VM\(s\): \$associatedVmText\. No VM or snapshot inventory references this virtual disk under complete coverage\.'
        $source | Should -Match 'VM owner\(s\): \$ownerText\. Folder-associated VM\(s\): \$associatedVmText\. The authoritative VM reference and detected storage-folder association differ\.'
        $source | Should -Match 'Filename text is not used as ownership evidence'
        $source | Should -Match 'Do not attach, move, rename, or delete it based only on this report\.'
        $source | Should -Match "default\s+\{ 'If this virtual disk belongs to an image library, exclude its full path with storage\.imageLibraryPathPatterns"
    }

    It 'documents housekeeping categories and the attached-disk boundary at a dedicated anchor' {
        $readme = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'README.md') -Raw
        $readme | Should -Match '(?m)^## Cluster storage housekeeping\r?$'
        $readme | Should -Match 'Placement inconsistency.+authoritative VM or snapshot reference'
        $readme | Should -Match 'none of the VMs associated with the containing folder is an authoritative owner'
        $readme | Should -Match 'AKS Arc RP workload directory shared by its control-plane and worker VMs'
        $readme | Should -Match 'Filename tokens are never treated as ownership evidence'
        $readme | Should -Match 'attached disk outside all detected VM folders is allowed'
        $readme | Should -Match 'Filter out as VM image.+only.+Unattached base disk candidate'
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

Describe 'Storage Health Service fault classification' {
    BeforeAll {
        $storageModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
        Import-Module $storageModulePath -Force
    }

    It 'excludes a cluster update-availability fault from storage evidence' {
        InModuleScope Get-HyperVVMCheckpointHealth.Storage {
            $fault = [pscustomobject]@{
                FaultType = 'Microsoft.Health.FaultType.Cluster.UpdateAvailable'
                FaultingObjectType = 'Microsoft.Health.EntityType.Cluster'
                FaultingObjectDescription = 'UpdateAvailable'
                Reason = 'Your cluster has one or more updates available.'
            }

            Test-StorageHealthFault -Fault $fault | Should -BeFalse
        }
    }

    It 'includes Microsoft StorHealth fault types' {
        InModuleScope Get-HyperVVMCheckpointHealth.Storage {
            foreach ($entityType in @('FaultDomain', 'PhysicalDisk', 'StorageEnclosure', 'StoragePool', 'StorageScaleUnit', 'VirtualDisks', 'Volume')) {
                $fault = [pscustomobject]@{
                    FaultType = "Microsoft.Health.FaultType.$entityType.SyntheticFault"
                    FaultingObjectType = $entityType
                }
                Test-StorageHealthFault -Fault $fault | Should -BeTrue
            }
        }
    }

    It 'uses the storage object type when the fault type is unavailable' {
        InModuleScope Get-HyperVVMCheckpointHealth.Storage {
            Test-StorageHealthFault -Fault ([pscustomobject]@{ FaultingObjectType = 'Microsoft.Health.EntityType.PhysicalDisk' }) | Should -BeTrue
        }
    }

    It 'marks an otherwise healthy snapshot degraded when a storage fault remains' {
        InModuleScope Get-HyperVVMCheckpointHealth.Storage {
            $snapshot = [pscustomobject]@{
                StorageModule = $true; StorageJobs = @(); VDiskUnhealthy = @(); PDiskUnhealthy = @()
                CsvRedirected = @(); Subsystem = @(); HealthFaults = @([pscustomobject]@{ FaultType = 'Microsoft.Health.FaultType.Volume.CapacityLow' })
            }
            Get-StorageHealthSummary -Snapshot $snapshot | Should -Be 'Degraded'
            $snapshot.HealthFaults = @()
            Get-StorageHealthSummary -Snapshot $snapshot | Should -Be 'Healthy'
        }
    }

    It 'preserves a combined incompatible-filter and ReFS reason as abnormal CSV evidence' {
        InModuleScope Get-HyperVVMCheckpointHealth.Storage {
            function Get-StorageJob { @() }
            function Get-VirtualDisk { @() }
            function Get-PhysicalDisk { @() }
            function Get-StorageSubSystem { [pscustomobject]@{ FriendlyName = 'S2D'; HealthStatus = 'Healthy' } }
            function Get-HealthFault { @() }
            function Get-ClusterSharedVolumeState {
                [pscustomobject]@{
                    Node = 'TEST-NODE-01'
                    VolumeFriendlyName = 'UserStorage_1'
                    StateInfo = 'FileSystemRedirected'
                    BlockRedirectedIOReason = 'NotBlockRedirected'
                    FileSystemRedirectedIOReason = 'IncompatibleFileSystemFilter, FileSystemReFs'
                }
            }

            $result = Get-ClusterStorageHealthSnapshot -TargetNode $env:COMPUTERNAME

            $result.Summary | Should -Be 'Degraded'
            @($result.CsvRedirected).Count | Should -Be 1
            $result.CsvRedirected[0].FsReason | Should -Be 'IncompatibleFileSystemFilter, FileSystemReFs'
        }
    }

    It 'filters storage faults when the scan executes in isolated remote scope' {
        InModuleScope Get-HyperVVMCheckpointHealth.Storage {
            Mock Invoke-Command {
                param($ComputerName, $ScriptBlock, $ArgumentList)
                & $ScriptBlock $ArgumentList[0]
            }
            function Get-StorageJob { @() }
            function Get-VirtualDisk { @() }
            function Get-PhysicalDisk { @() }
            function Get-StorageSubSystem { [pscustomobject]@{ FriendlyName = 'S2D'; HealthStatus = 'Healthy' } }
            function Get-ClusterSharedVolumeState { @() }
            function Get-HealthFault {
                @(
                    [pscustomobject]@{ FaultType = 'Microsoft.Health.FaultType.Volume.CapacityLow'; Reason = 'Storage fault' }
                    [pscustomobject]@{ FaultType = 'Microsoft.Health.FaultType.Cluster.UpdateAvailable'; Reason = 'Update fault' }
                )
            }

            $result = Get-ClusterStorageHealthSnapshot -TargetNode 'REMOTE-NODE'

            $result.HealthFaultCollectionStatus | Should -Be 'Success'
            @($result.HealthFaults).Count | Should -Be 1
            $result.HealthFaults[0].Reason | Should -Be 'Storage fault'
            $result.Summary | Should -Be 'Degraded'
        }
    }
}
