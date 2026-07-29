[CmdletBinding()]
[OutputType([System.IO.FileInfo])]
param(
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot 'VMCheckpointAudit-contoso01-example.html'
}

$toolRoot = Split-Path $PSScriptRoot -Parent
$assessmentModulePath = Join-Path $toolRoot 'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
$renderingModulePath = Join-Path $toolRoot 'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
Import-Module $assessmentModulePath -Force -ErrorAction Stop
Import-Module $renderingModulePath -Force -ErrorAction Stop

$baseReportData = [pscustomobject]@{
    State = 'Running'; Status = 'Operating normally'; Version = '12.0'; HostMaxVersion = '12.0'
    VmVerOlder = $false; Uptime = '12.08:34:21'; CheckpointType = 'Production'
    AutomaticCheckpoints = $false; AttachedDiskCount = 2; CheckpointLayers = 0
    Checkpoints = @(); StaleCheckpointCount = 0; StaleHours = 24
    StaleAttachedLayerCount = 0; StaleSnapshotCount = 0; SnapshotLayerMismatch = $false
    ChainComplete = $true; IncompleteChainCount = 0; StateConsistencyStatus = 'Stable'
    AttachedVhdLayers = @()
    Replication = [pscustomobject]@{ Enabled = $false; State = ''; Health = ''; Mode = ''; Primary = ''; Replica = ''; LastReplicationTime = '' }
    VssState = 'Healthy'; VssTotal = 10; VssUnhealthyCount = 0; VssUnhealthy = @()
    AnalyticNodesNeedEnable = @(); CsvVolumes = @(); OrphanCount = 0; Orphans = @()
    HasOrphans = $false; HasForkSignature = $false; EventConcernCount = 0
    VmEventConcernCount = 0; EventBreakdown = @(); EventLookbackHours = 168
    EventsCsvName = ''; NodeEventsCsvName = ''; SupportCaseSummary = ''
    VmHighConcernCount = 0; VmLowConcernCount = 0; VmCriticalCount = 0
    VmHighOpCount = 0; VmEscalatingConcernCount = 0; HighOpSelfResolved = $false
    VmHighConcernIds = ''; LowSignalOnly = $false; NodeDominantNote = ''
    ReplHealth = ''; ReplUnhealthy = $false; ReplAdvisory = $false; ReplCritical = $false
    ReplAssessment = $null
    SeverityScore = 0; HasRollbackFingerprint = $false; RollbackDate = ''
    HasStuckMergeOrphan = $false; OrphanOnlyLiveMount = $false
    HistoricForkConfirmed = $false; Historic = $null; ActiveCkptForkConfirmed = $false
    ActiveCkptLogsWrapped = $false; ActiveCkptCoverageIncomplete = $false
    CannotConfirmMigrationSafe = $false; ActiveCkptOldestCreateUtc = ''
    ActiveCkptOldestAvailUtc = ''; ActiveCkptHistoric = $null
    PolicySource = 'BuiltInDefaults'; CsvFreeSpaceAssessment = $null; HrlAssessment = $null
}

$historicReportData = $baseReportData.PSObject.Copy()
$historicReportData.Uptime = '4.03:18:42'
$historicReportData.OrphanCount = 2
$historicReportData.HasOrphans = $true
$historicReportData.HasRollbackFingerprint = $true
$historicReportData.RollbackDate = '2026-06-14'
$historicReportData.HistoricForkConfirmed = $true
$historicReportData.SeverityScore = 95
$historicReportData.EventsCsvName = 'TestVM01_Events_2026-07-20.csv'
$historicReportData.NodeEventsCsvName = '_NodeEvents_node01_2026-07-20.csv'
$historicReportData.Orphans = @(
    [pscustomobject]@{
        Name = 'TestVM01_Data_recovery.avhdx'; SizeGB = 18.4
        Created = '2026-06-14 02:10:12Z'; LastWrite = '2026-06-14 02:16:45Z'
        AgeHrs = 874.1; AgeDays = 36.4
        Likely = 'Historic merge artifact. Preserve and correlate with the backup job before any action.'
        FullName = 'C:\ClusterStorage\UserStorage_1\TestVM01\Virtual Hard Disks\TestVM01_Data_recovery.avhdx'
    },
    [pscustomobject]@{
        Name = 'TestVM01_OS_recovery.avhdx'; SizeGB = 6.8
        Created = '2026-06-14 02:10:11Z'; LastWrite = '2026-06-14 02:16:46Z'
        AgeHrs = 874.1; AgeDays = 36.4
        Likely = 'Historic merge artifact. Preserve and correlate with the backup job before any action.'
        FullName = 'C:\ClusterStorage\UserStorage_2\TestVM01\Virtual Hard Disks\TestVM01_OS_recovery.avhdx'
    }
)
$historicReportData.Historic = [pscustomobject]@{
    MatchCount = 2; WindowMinutes = 30
    NodesSearched = @(1..10 | ForEach-Object { 'node{0:d2}' -f $_ })
    Windows = @('2026-06-14 01:40:11Z - 2026-06-14 02:46:46Z')
    CoverageComplete = $true; OldestAvailableUtc = '2026-05-01 00:00:00Z'
    Coverage = @()
    Matches = @(
        [pscustomobject]@{
            Time = '2026-06-14 02:14:08Z'; Node = 'node01'
            Log = 'Microsoft-Windows-Hyper-V-VMMS-Admin'; Id = 3216
            Message = 'Synthetic example: the checkpoint operation for TestVM01 could not commit the differencing chain.'
        },
        [pscustomobject]@{
            Time = '2026-06-14 02:15:31Z'; Node = 'node01'
            Log = 'Microsoft-Windows-Hyper-V-Worker-Admin'; Id = 19100
            Message = 'Synthetic example: the background merge for TestVM01 did not complete.'
        }
    )
}

$results = @(
    [pscustomobject]@{
        VMName = 'TestVM01'; OwningNode = 'node01'; Recommendation = 'INVESTIGATE'
        Source = 'Input'; StaleCheckpointCount = 0; ReportData = $historicReportData; Detail = ''
    }
    foreach ($vmNumber in 2..20) {
        $healthyReportData = $baseReportData.PSObject.Copy()
        $healthyReportData.AttachedDiskCount = if (($vmNumber % 4) -eq 0) { 2 } else { 1 }
        $healthyReportData.Uptime = '{0}.{1:d2}:{2:d2}:{3:d2}' -f `
            (6 + $vmNumber), ($vmNumber % 24), (($vmNumber * 3) % 60), (($vmNumber * 7) % 60)
        $recommendation = 'OK'
        switch ($vmNumber) {
            2 {
                $healthyReportData.OrphanCount = 1
                $healthyReportData.HasOrphans = $true
                $healthyReportData.HasStuckMergeOrphan = $true
                $healthyReportData.SeverityScore = 75
                $healthyReportData.Orphans = @([pscustomobject]@{
                    Name = 'TestVM02_Data_orphan.avhdx'; SizeGB = 11.2
                    Created = '2026-07-16 01:22:04Z'; LastWrite = '2026-07-16 01:38:19Z'
                    AgeHrs = 107.6; AgeDays = 4.5
                    Likely = 'Possible stuck merge artifact. Match it to the synthetic backup window before any action.'
                    FullName = 'C:\ClusterStorage\UserStorage_1\TestVM02\Virtual Hard Disks\TestVM02_Data_orphan.avhdx'
                })
                $recommendation = 'INVESTIGATE'
            }
            3 {
                $healthyReportData.CheckpointLayers = 1
                $healthyReportData.StaleAttachedLayerCount = 1
                $healthyReportData.StaleCheckpointCount = 1
                $healthyReportData.Checkpoints = @([pscustomobject]@{
                    Name = 'Backup checkpoint - synthetic'; Type = 'Recovery'; Purpose = 'Backup'
                    Created = '2026-07-17 00:15:00Z'; AgeHrs = 83.8; Stale = $true; Parent = ''
                })
                $healthyReportData.SeverityScore = 70
                $recommendation = 'INVESTIGATE'
            }
            4 {
                $healthyReportData.CheckpointLayers = 1
                $healthyReportData.StaleAttachedLayerCount = 1
                $healthyReportData.SnapshotLayerMismatch = $true
                $healthyReportData.AttachedVhdLayers = @(
                    [pscustomobject]@{
                        Chain = 'TestVM04_OS_9f42.avhdx'; FileName = 'TestVM04_OS_9f42.avhdx'
                        Layer = 1; Role = 'Active (top)'; Type = 'Differencing'; SizeGB = 18.6
                        Created = '2026-07-17 06:10:00Z'; LastWrite = '2026-07-20 11:58:00Z'
                        CheckpointAgeHrs = 77.9; LastActivityAgeHrs = 0.1; CheckpointStale = $true
                        AgeHrs = 77.9; Stale = $true
                        Path = 'C:\ClusterStorage\UserStorage_1\TestVM04\Virtual Hard Disks\TestVM04_OS_9f42.avhdx'
                        ParentPath = 'C:\ClusterStorage\UserStorage_1\TestVM04\Virtual Hard Disks\TestVM04_OS.vhdx'
                    },
                    [pscustomobject]@{
                        Chain = 'TestVM04_OS_9f42.avhdx'; FileName = 'TestVM04_OS.vhdx'
                        Layer = 2; Role = 'Base'; Type = 'Dynamic'; SizeGB = 64.0
                        Created = '2026-03-02 09:00:00Z'; LastWrite = '2026-07-17 06:10:00Z'
                        CheckpointAgeHrs = $null; LastActivityAgeHrs = 77.9; CheckpointStale = $false
                        AgeHrs = $null; Stale = $false
                        Path = 'C:\ClusterStorage\UserStorage_1\TestVM04\Virtual Hard Disks\TestVM04_OS.vhdx'; ParentPath = ''
                    }
                )
                $healthyReportData.SeverityScore = 72
                $recommendation = 'INVESTIGATE'
            }
            5 {
                $healthyReportData.Replication = [pscustomobject]@{
                    Enabled = $true; State = 'Error'; Health = 'Critical'; Mode = 'Primary'
                    Primary = 'node05'; Replica = 'node06'; LastReplicationTime = '2026-07-20 10:15:00Z'
                }
                $healthyReportData.ReplHealth = 'Critical'
                $healthyReportData.ReplUnhealthy = $true
                $healthyReportData.ReplCritical = $true
                $healthyReportData.ReplAssessment = [pscustomobject]@{
                    Severity = 'Critical'; ProductSeverity = 'Critical'; MeasurementStatus = 'Concern'
                    State = 'Error'; Health = 'Critical'; Mode = 'Primary'; IsConcern = $true; HasAdvisory = $false; IsCritical = $true
                    Reason = 'Hyper-V Replica health is Critical.'; MeasurementsAvailable = $true
                    LastReplicationTimeUtc = [datetime]'2026-07-20T10:15:00Z'; LastReplicationAgeMinutes = 105
                    PendingBytes = 3GB; LatencySeconds = 900; MissedCount = 5; FrequencySeconds = 300
                    AverageReplicationBytes = 256MB; SuccessfulCount = 95; MissedRatePercent = 5
                    MonitoringIntervalSeconds = 3600; EffectiveMaxAgeMinutes = 60
                    EffectiveMaxPendingBytes = 1GB; EffectiveMaxLatencySeconds = 600; MaxMissedRatePercent = 10
                    ThresholdBreaches = @('LastReplicationAge', 'PendingBytes', 'Latency', 'MissedCount')
                    ConcernBreaches = @('LastReplicationAge', 'PendingBytes', 'Latency'); AdvisoryBreaches = @('MissedCount')
                }
                $healthyReportData.SeverityScore = 65
                $recommendation = 'INVESTIGATE'
            }
            6 {
                $healthyReportData.Replication = [pscustomobject]@{
                    Enabled = $true; State = 'Resynchronizing'; Health = 'Warning'; Mode = 'Primary'
                    Primary = 'node06'; Replica = 'node05'; LastReplicationTime = '2026-07-20 11:40:00Z'
                }
                $healthyReportData.ReplHealth = 'Warning'
                $healthyReportData.ReplUnhealthy = $true
                $healthyReportData.ReplAdvisory = $true
                $healthyReportData.ReplAssessment = [pscustomobject]@{
                    Severity = 'Warning'; ProductSeverity = 'Warning'; MeasurementStatus = 'Advisory'
                    State = 'Resynchronizing'; Health = 'Warning'; Mode = 'Primary'; IsConcern = $true; HasAdvisory = $true; IsCritical = $false
                    Reason = 'Hyper-V Replica health is Warning with measurement drift that warrants observation.'; MeasurementsAvailable = $true
                    LastReplicationTimeUtc = [datetime]'2026-07-20T11:40:00Z'; LastReplicationAgeMinutes = 20
                    PendingBytes = 1536MB; LatencySeconds = 350; MissedCount = 1; FrequencySeconds = 300
                    AverageReplicationBytes = 1GB; SuccessfulCount = 99; MissedRatePercent = 1
                    MonitoringIntervalSeconds = 3600; EffectiveMaxAgeMinutes = 60
                    EffectiveMaxPendingBytes = 2GB; EffectiveMaxLatencySeconds = 600; MaxMissedRatePercent = 10
                    ThresholdBreaches = @('PendingBytes', 'Latency', 'MissedCount'); ConcernBreaches = @()
                    AdvisoryBreaches = @('PendingBytes', 'Latency', 'MissedCount')
                }
                $healthyReportData.SeverityScore = 55
                $recommendation = 'INVESTIGATE'
            }
            7 {
                $healthyReportData.CheckpointLayers = 1
                $healthyReportData.StaleAttachedLayerCount = 1
                $healthyReportData.StaleCheckpointCount = 1
                $healthyReportData.Checkpoints = @([pscustomobject]@{
                    Name = 'Active checkpoint with historic fork evidence'; Type = 'Recovery'; Purpose = 'Backup'
                    Created = '2026-07-10 04:20:00Z'; AgeHrs = 248.7; Stale = $true; Parent = ''
                })
                $healthyReportData.ActiveCkptForkConfirmed = $true
                $healthyReportData.ActiveCkptOldestCreateUtc = '2026-07-10 04:20:00Z'
                $healthyReportData.ActiveCkptHistoric = [pscustomobject]@{
                    WindowMinutes = 120; NodesSearched = @(1..10 | ForEach-Object { 'node{0:d2}' -f $_ })
                    Coverage = @(); CoverageComplete = $true; Matches = @([pscustomobject]@{
                        Time = '2026-07-10 04:23:18Z'; Node = 'node07'; Log = 'Worker'; Id = 3216
                        Message = 'Synthetic example: fork-commit evidence at TestVM07 checkpoint creation.'
                    })
                }
                $healthyReportData.SeverityScore = 100
                $recommendation = 'HOLD STATE'
            }
            17 {
                $healthyReportData.CheckpointLayers = 1
                $healthyReportData.StaleAttachedLayerCount = 1
                $healthyReportData.StaleCheckpointCount = 1
                $healthyReportData.Checkpoints = @([pscustomobject]@{
                    Name = 'Discovered backup checkpoint - synthetic'; Type = 'Recovery'; Purpose = 'Backup'
                    Created = '2026-07-18 03:30:00Z'; AgeHrs = 56.5; Stale = $true; Parent = ''
                })
                $healthyReportData.OrphanCount = 1
                $healthyReportData.HasOrphans = $true
                $healthyReportData.SeverityScore = 80
                $healthyReportData.Orphans = @([pscustomobject]@{
                    Name = 'TestVM17_OS_orphan.avhdx'; SizeGB = 4.6
                    Created = '2026-07-18 03:31:10Z'; LastWrite = '2026-07-18 03:44:52Z'
                    AgeHrs = 56.3; AgeDays = 2.3
                    Likely = 'Unattached backup checkpoint artifact. Preserve it until the synthetic job history is reviewed.'
                    FullName = 'C:\ClusterStorage\UserStorage_2\TestVM17\Virtual Hard Disks\TestVM17_OS_orphan.avhdx'
                })
                $recommendation = 'INVESTIGATE'
            }
        }
        [pscustomobject]@{
            VMName = 'TestVM{0:d2}' -f $vmNumber
            OwningNode = 'node{0:d2}' -f ((($vmNumber - 1) % 10) + 1)
            Recommendation = $recommendation
            Source = if ($vmNumber -le 16) { 'Input' } else { 'Discovered' }
            StaleCheckpointCount = $healthyReportData.StaleCheckpointCount
            ReportData = $healthyReportData
            Detail = ''
        }
    }
)

$storageHealth = [pscustomobject]@{
    Summary = 'Degraded'; Source = 'node01'; StorageJobs = @()
    CsvRedirected = @([pscustomobject]@{
        Volume = 'UserStorage_1'; Nodes = 'node01, node02'
        State = 'FileSystemRedirected'; BlockReason = ''
        FsReason = 'IncompatibleFileSystemFilter, FileSystemReFs'
    })
    VDiskUnhealthy = @(); PDiskUnhealthy = @()
    Subsystem = @([pscustomobject]@{ Name = 'contoso01 S2D on contoso01'; Health = 'Healthy' })
    Note = ''
}

$housekeepingFindings = @(
    [pscustomobject]@{
        Category = 'Placement inconsistency'; Scope = 'TestVM03, TestVM08'
        FileName = 'TestVM03_Data.vhdx'
        FullName = 'C:\ClusterStorage\UserStorage_1\TestVM08\Virtual Hard Disks\TestVM03_Data.vhdx'
        ParentPath = 'C:\ClusterStorage\UserStorage_1\TestVM08\Virtual Hard Disks'
        CsvRoot = 'C:\ClusterStorage\UserStorage_1'; Extension = '.vhdx'; Length = 32212254720
        PlacementReason = 'ReferencedOwnerFolderMismatch'
        Owners = @('TestVM03'); AssociatedVMs = @('TestVM08')
        Observation = 'Authoritative VM or snapshot inventory references this disk for TestVM03, but its path is under a folder associated with TestVM08. Filename text is not used as ownership evidence: C:\ClusterStorage\UserStorage_1\TestVM08\Virtual Hard Disks\TestVM03_Data.vhdx'
        Review = 'Confirm whether the authoritative owner and different associated folder are intentional with the VM, backup, and storage owners. Do not move or rename the file based only on this report.'
    },
    [pscustomobject]@{
        Category = 'Unattached base disk candidate'; Scope = 'TestVM08'
        FileName = 'TestVM08_LegacyData.vhdx'
        FullName = 'C:\ClusterStorage\UserStorage_1\TestVM08\Virtual Hard Disks\TestVM08_LegacyData.vhdx'
        ParentPath = 'C:\ClusterStorage\UserStorage_1\TestVM08\Virtual Hard Disks'
        CsvRoot = 'C:\ClusterStorage\UserStorage_1'; Extension = '.vhdx'; Length = 21474836480
        Observation = 'No VM or snapshot chain references this base disk under complete coverage: C:\ClusterStorage\UserStorage_1\TestVM08\Virtual Hard Disks\TestVM08_LegacyData.vhdx'
        Review = 'If this virtual disk belongs to an image library, exclude its full path with storage.imageLibraryPathPatterns in a checkpoint-health-policy.yml file supplied via -PolicyPath (see housekeeping guidance). Otherwise, confirm intended ownership and storage layout with the VM, backup, and storage owners. Do not modify the file based only on this report.'
    },
    [pscustomobject]@{
        Category = 'Unattached base disk candidate'; Scope = 'TestVM12'
        FileName = 'TestVM12_Archive.vhdx'
        FullName = 'C:\ClusterStorage\UserStorage_2\TestVM12\Virtual Hard Disks\TestVM12_Archive.vhdx'
        ParentPath = 'C:\ClusterStorage\UserStorage_2\TestVM12\Virtual Hard Disks'
        CsvRoot = 'C:\ClusterStorage\UserStorage_2'; Extension = '.vhdx'; Length = 10737418240
        Observation = 'No VM or snapshot chain references this base disk under complete coverage: C:\ClusterStorage\UserStorage_2\TestVM12\Virtual Hard Disks\TestVM12_Archive.vhdx'
        Review = 'If this virtual disk belongs to an image library, exclude its full path with storage.imageLibraryPathPatterns in a checkpoint-health-policy.yml file supplied via -PolicyPath (see housekeeping guidance). Otherwise, confirm intended ownership and storage layout with the VM, backup, and storage owners. Do not modify the file based only on this report.'
    },
    [pscustomobject]@{
        Category = 'Shared virtual disk reference'; Scope = 'TestVM14, TestVM15'
        FileName = 'SharedData01.vhdx'
        Observation = 'More than one VM or snapshot inventory references this path: C:\ClusterStorage\UserStorage_2\TestVM14\Virtual Hard Disks\SharedData01.vhdx'
        Review = 'Confirm that the shared reference is intentional and supported for this workload. Do not modify the file based only on this report.'
    },
    [pscustomobject]@{
        Category = 'Shared VHD Set reference'; Scope = 'TestVM16, TestVM17'
        FileName = 'GuestClusterData.vhds'
        FullName = 'C:\ClusterStorage\UserStorage_2\GuestCluster\GuestClusterData.vhds'
        ParentPath = 'C:\ClusterStorage\UserStorage_2\GuestCluster'
        CsvRoot = 'C:\ClusterStorage\UserStorage_2'; Extension = '.vhds'; Length = 4194304
        Classification = 'AttachedVirtualDisk'
        Observation = 'More than one VM references this VHD Set path: C:\ClusterStorage\UserStorage_2\GuestCluster\GuestClusterData.vhds'
        Review = 'VHD Sets are designed for shared guest-cluster storage. Confirm that the listed VMs are the intended guest-cluster nodes. Do not modify the VHDS or its Hyper-V-managed files based only on this report.'
    }
)

$discoverySummary = [pscustomobject]@{
    EligibleCount = 4; AuditedCount = 4; DeferredCount = 0; Cap = $null
}

$floodStartUtc = [datetimeoffset]'2026-07-20T10:45:00+00:00'
$nodeEventContext = @([pscustomobject]@{
    Node = 'node04'
    Events = @(0..120 | ForEach-Object {
        [pscustomobject]@{
            'Time (UTC)' = $floodStartUtc.AddSeconds($_ * 30).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ssZ')
            Id = 15268
            FullMessage = 'Synthetic example: Failed to get the disk information.'
        }
    })
})

$html = ConvertTo-VMCheckpointAuditHtml -Results $results -StaleHours 24 `
    -EventLookbackHours 168 -ClusterName 'contoso01' -GeneratedUtc '2026-07-20 12:00:00' `
    -DiscoveredVMs @() -DiscoverySummary $discoverySummary -StorageHealth $storageHealth `
    -HousekeepingFindings $housekeepingFindings -NodeEventContext $nodeEventContext -IncludeDiscoveredVMs:$true `
    -ScriptVersion '0.2.30' -ReportGenerationTime '00:01:24' -ClusterNodeCount 10 -ClusterCsvCount 2

$syntheticNotice = @'
<div class="callout info synthetic-example"><strong>Synthetic example report.</strong> Every cluster, node, VM, path, timestamp, and event message in this file is invented for documentation. TestVM07 demonstrates an active-checkpoint HOLD STATE confirmed by historic event evidence; seven VMs demonstrate historic rollback, orphaned AVHDX, stale checkpoint/layer, and Hyper-V Replica INVESTIGATE findings; 12 VMs are healthy comparisons. A sustained cluster-level low-signal Event 15268 observation is shown for node04 without changing any VM verdict. The inventory contains 16 input VMs and 4 automatically discovered VMs.</div>
'@
$html = $html.Replace('<div class="wrap">', "<div class=`"wrap`">`r`n$syntheticNotice")
if ($html -notmatch 'Cluster-level low-signal event observation:' -or $html -notmatch '<code>node04</code>: 121 event\(s\)') {
    throw 'The synthetic cluster-level Event 15268 observation was not rendered.'
}

$allowedNames = @('contoso01') + @(1..20 | ForEach-Object { 'TestVM{0:d2}' -f $_ }) + `
    @(1..10 | ForEach-Object { 'node{0:d2}' -f $_ })
$identityValues = @(
    'contoso01'
    @($results | ForEach-Object { $_.VMName; $_.OwningNode })
    @($historicReportData.Historic.NodesSearched)
    $storageHealth.Source
)
$unexpectedNames = @($identityValues | Where-Object { $_ -and $allowedNames -notcontains $_ } | Sort-Object -Unique)
if ($unexpectedNames.Count -gt 0) {
    throw "Unexpected identity values in synthetic report data: $($unexpectedNames -join ', ')"
}
if ($html -match '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b') {
    throw 'An email address was found in the synthetic report.'
}
$clusterPaths = @([regex]::Matches($html, '(?i)C:\\ClusterStorage\\[^<\s''"]+') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Value) })
$unexpectedPaths = @($clusterPaths | Where-Object { $_ -notmatch '^C:\\ClusterStorage\\UserStorage_[12](?:$|\\(?:TestVM(?:0[1-9]|1[0-9]|20)|GuestCluster)(?:$|\\))' })
if ($unexpectedPaths.Count -gt 0) {
    throw "Unexpected ClusterStorage path in synthetic report: $($unexpectedPaths -join ', ')"
}

$outputDirectory = Split-Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
[System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.UTF8Encoding]::new($false))
Get-Item -LiteralPath $OutputPath