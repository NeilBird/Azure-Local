<#
.SYNOPSIS
    Read-only health audit of a Hyper-V VM's checkpoint / differencing-disk chain on a failover cluster.

.DESCRIPTION
    Audits one or more Hyper-V VMs on a Windows Server Failover Cluster or Azure Local cluster and
    reports the VM configuration (.vmcx) timestamp, the attached disk / differencing-disk chain,
    checkpoints, orphaned .avhdx files, Hyper-V Replica status and .hrl change logs, Cluster Shared
    Volume free space, the cluster role, and the Hyper-V Worker/VMMS event signatures for the
    checkpoint fork-commit / merge failure mode.

    It surfaces the failure mode where a checkpoint fork-commit failure leaves a VM's on-disk (.vmcx)
    chain metadata inconsistent - an inconsistency that can stay dormant while the VM runs and then be
    materialised by a live migration or restart, rolling the disks back to their base and orphaning the
    data held in the .avhdx layer(s).

    The script makes NO changes to the VM, disks, checkpoints, or cluster (see README.md). The only
    optional writes are the per-VM .txt report and events .csv (when -OutputPath is supplied), a single
    self-contained HTML fleet report (on by default; suppress with -NoHtml), and a results .zip bundling
    those files (on by default when -OutputPath is used; suppress with -NoZip). The console is QUIET by
    default (concise one-line verdict per VM); pass -Quiet:$false for the full per-VM report on screen.
    While running it shows a "VM X of Y" progress bar with a per-VM, per-section sub-bar.

    The human-readable report is written to the HOST (and, with -OutputPath, the .txt transcript);
    by default NOTHING is written to the pipeline. Pass -PassThru to also emit one [pscustomobject]
    per VM to the pipeline (VMName, OwningNode, Recommendation, HoldState, Has* flags, counts, plus a
    nested ReportData object with the full per-VM detail) for Where-Object / Export-Csv / fleet roll-ups.

    DISCLAIMER / CAVEATS:
      - EXAMPLE code. NOT a Microsoft-supported product or service offering; provided with NO warranty
        of any kind (see the MIT License and README.md).
      - DIAGNOSTIC ONLY: it presents read-only state to help INVESTIGATE the checkpoint fork-commit /
        merge failure mode. It does NOT determine root cause definitively and does NOT remediate anything.
      - Do NOT take remediation action (live/quick/storage-migrate, restart, merge or delete checkpoints /
        disks, edit the .vmcx, etc.) based solely on this output. For interpretation of the findings and
        any remediation, open a Microsoft Support (CSS) case and act on their advice.
      - Validate in a test environment first and ensure you have good, tested backups before any change.

.EXAMPLE
    .\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01'

    Audits a single VM by name (console only).

.EXAMPLE
    .\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine').Name -OutputPath 'C:\Temp\Reports'

    Audits EVERY clustered VM when run ON a cluster node. The VM names come from the cluster API
    (Get-ClusterGroup - RPC, no WinRM and no double hop). NOTE: the bare Get-ClusterGroup sub-expression
    is a SEPARATE command that runs in YOUR session and targets the LOCAL cluster, so this form only
    works on a node. To do the same from a management workstation, see the -Cluster example below
    (you must add -Cluster to the inner Get-ClusterGroup as well). Writes a per-VM .txt and events .csv.

.EXAMPLE
    'VM01','VM02','VM03' | .\Get-HyperVVMCheckpointHealth.ps1 -OutputPath 'C:\Temp\Reports'

    Audits a specific list of VMs (piped names). The script resolves each VM's owning node itself and
    collects the data in that node's context, so no double-hop authentication is required.

.EXAMPLE
    .\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01' -SkipWorkerEvents -SkipAnalyticCheck

    Fastest run: disk / checkpoint / chain state only, skipping the event-log scan and Analytic check.

.EXAMPLE
    .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name -OutputPath 'C:\Temp\Reports'

    A single self-contained HTML fleet report is written by DEFAULT. With -OutputPath it lands in the
    per-run sub-folder as 'VMCheckpointAudit-<ClusterName>-yyyy-MM-dd.html' alongside the .txt/.csv;
    without -OutputPath it is written to the current directory. Override the location with
    -HtmlReportPath <folder-or-file>, or suppress it entirely with -NoHtml. The report has one row per
    audited VM (colour-coded verdict), summary cards, a fleet table, and per-VM detail - ideal to email
    or attach to a backup-vendor / Microsoft (CSS) case.

.EXAMPLE
    .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name -OutputPath 'C:\Temp\Reports'

    Runs REMOTELY from a management workstation (with the RSAT 'Failover Clustering' tools). -Cluster
    targets the named cluster via the cluster RPC API and each owning node is reached in a SINGLE hop -
    no double hop. Without -Cluster the script must be run ON a cluster node.

    IMPORTANT: -Cluster must appear TWICE. The (Get-ClusterGroup -Cluster 'CLUS01' ...) sub-expression
    that builds the -VMName list is a SEPARATE command that runs in your local session BEFORE the
    script starts; it does NOT inherit the script's -Cluster, so it needs its own -Cluster to point at
    the remote cluster. The script's own -Cluster then governs the audit itself. (Equivalent pipeline
    form: Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine' |
    Select-Object -ExpandProperty Name | .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' ...)

.EXAMPLE
    $results = .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name -OutputPath 'C:\Temp\Reports' -PassThru
    $results | Where-Object HoldState | Format-Table VMName, OwningNode, Recommendation

    With -PassThru the script emits ONE [pscustomobject] per VM to the pipeline (in addition to the
    console report and, with -OutputPath, the per-VM .txt/.csv files). Without -PassThru nothing is
    written to the pipeline. The object carries: VMName, Cluster, OwningNode, Recommendation
    ('HOLD STATE' / 'INVESTIGATE' / 'OK' / 'NOT FOUND' / 'ERROR'), HoldState, HasAttachedCheckpoints,
    HasStaleCheckpoints, HasOrphanedCheckpoints, AttachedCheckpointCount, StaleCheckpointCount,
    ConcernEventCount, ReportFile, Detail - ideal for Where-Object / Export-Csv / fleet roll-ups.
    It ALSO carries a nested ReportData object with the rich per-VM detail the HTML report renders
    (Checkpoints[], AttachedDiskCount, CheckpointLayers, StaleCheckpointCount, Replication, VssState,
    VssUnhealthy[], AnalyticNodesNeedEnable[], CsvVolumes[], OrphanCount, Orphans[], HasForkSignature,
    EventBreakdown[], Version/HostMaxVersion, and - for HOLD STATE - SupportCaseSummary). ReportData
    is $null for NOT FOUND / ERROR rows. Drill in, e.g.:
        $results | Where-Object { $_.ReportData.HasForkSignature } |
            ForEach-Object { $_.ReportData.Checkpoints } | Format-Table Name, AgeHrs, Stale

.EXAMPLE
    .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name -ExcludedVMListCsv '.\CheckPointAudit_Excluded_VMs.csv' -OutputPath 'C:\Temp\Reports'

    Audits every clustered VM EXCEPT those listed in the exclusion CSV. The file has a single column
    with a 'VMName' header (a headerless single-column file also works); each VM whose name matches
    (case-INSENSITIVE) is skipped BEFORE it is audited. Handy to permanently omit known-noisy or
    intentionally long-checkpointed VMs from a fleet run. A relative path (e.g. '.\CheckPointAudit_
    Excluded_VMs.csv', in the same folder as the script) is resolved against the current directory; a
    missing / unreadable file is a non-fatal warning and the run proceeds with no exclusions.

.OUTPUTS
    None to the pipeline by default - the human-readable report goes to the host and, with -OutputPath,
    to a per-VM .txt transcript + events .csv. A single self-contained HTML fleet report is also written
    by default (suppress with -NoHtml; relocate with -HtmlReportPath). With -PassThru, one
    [pscustomobject] per VM is emitted to the pipeline - flat properties (VMName, Recommendation,
    HoldState, Has* flags, counts, ReportFile, Detail) for quick Where-Object / Export-Csv roll-ups,
    PLUS a nested ReportData object with the full per-VM detail the HTML renders (see the -PassThru
    example above for the ReportData fields and a drill-in snippet).

.NOTES
    Author  : Neil Bird, Microsoft
    Created : 2026-07-10
    Updated : 2026-07-17
    Version : 0.2.15
    
    Requires: Windows PowerShell 5.1 (this script is written for, and validated against, Windows
              PowerShell 5.1 ONLY - it is NOT intended or tested for PowerShell 7.x). Also requires the Hyper-V
              and FailoverClusters modules, rights to query the cluster / Hyper-V / the nodes' event
              logs, and (when the VM's owning node is not the local node) WinRM to that owning node.
              To run REMOTELY from a management workstation, use -Cluster <name> and install the RSAT
              'Failover Clustering' tools on the workstation. Do NOT run it from inside an interactive
              remoting session (Enter-PSSession) to a node - reaching another node from there is a
              'double hop' and is blocked; run it ON a node, or from a workstation with -Cluster.

    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR
    FITNESS FOR A PARTICULAR PURPOSE.

    This sample is not supported under any Microsoft standard support program or service.
    The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
    implied warranties including, without limitation, any implied warranties of merchantability
    or of fitness for a particular purpose. The entire risk arising out of the use or performance
    of the sample and documentation remains with you. In no event shall Microsoft, its authors,
    or anyone else involved in the creation, production, or delivery of the script be liable for
    any damages whatsoever (including, without limitation, damages for loss of business profits,
    business interruption, loss of business information, or other pecuniary loss) arising out of
    the use of or inability to use the sample or documentation, even if Microsoft has been advised
    of the possibility of such damages.
#>

#Requires -Version 5.1
# NOTE: the Windows PowerShell 5.1 (Desktop) edition and the FailoverClusters module are enforced by
# RUNTIME guards at the top of the begin block below - NOT by '#Requires -PSEdition Desktop' /
# '#Requires -Modules FailoverClusters'. Those directives make PowerShell refuse to introspect the
# script when the current session does not satisfy them, which breaks tab-completion of -Parameters
# when authoring on a PowerShell 7 workstation (or one without the RSAT clustering tools). The runtime
# guards give the same clear failure at execution time while keeping tooling / completion working.
# FailoverClusters is required LOCALLY in both run modes (on a node, or on a workstation via the RSAT
# 'Failover Clustering' tools). Hyper-V is intentionally NOT required locally: with -Cluster the
# Hyper-V cmdlets run inside the owning-node session, so a management workstation need not have it.

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [ValidateNotNullOrEmpty()]
    [Alias('Name','VM')]
    # Accepts VM name(s) OR VM objects (from Get-VM). Objects are normalized to their .Name in the
    # process block, so -VMName $VMs (objects), -VMName $VMs.Name (strings), and 'Get-VM | ...' all work.
    [object[]]$VMName,

    # Optional: target a cluster BY NAME so the script can be run from a management workstation (with
    # the RSAT 'Failover Clustering' tools installed) instead of on a node. The cluster queries use the
    # cluster RPC API and each owning node is then reached in a SINGLE remoting hop from the
    # workstation - no double hop. When OMITTED, the script targets the LOCAL cluster and REQUIRES that
    # you are running ON a cluster node (a Get-Cluster guard rail enforces this and fails clearly if not).
    [ValidateNotNullOrEmpty()]
    [string]$Cluster,

    # Optional: base folder for reports. Each run creates a timestamped sub-folder
    # (CheckpointAudit_<UTC>) inside it; every VM then gets its own .txt transcript and .csv event
    # export in that sub-folder. Console-only if omitted. Base folder is created if it does not exist.
    [string]$OutputPath,

    # Also audit VMs that were NOT requested but were DISCOVERED in the owning node's event data with a
    # high-risk checkpoint/merge signature (background disk merge interrupted / failed, or 'cannot load
    # VM configuration'). OFF by default: such VMs are always SURFACED (console + HTML) with a ready-to-
    # run command, but only audited automatically when this switch is set. Bounded and non-recursive:
    # only names that resolve to real clustered VMs are added, their own discoveries are not expanded,
    # and the number added is capped (see $script:MaxDiscoveredToAudit).
    [switch]$IncludeDiscoveredVMs,

    # Optional: path to a CSV file listing VM names to EXCLUDE from the audit. The file has a single
    # column with a 'VMName' header (a headerless single-column file is also accepted). It is read ONCE
    # at start; any requested / piped VM whose name matches (case-INSENSITIVE) is skipped BEFORE it is
    # audited, and excluded VMs are NOT auto-audited via -IncludeDiscoveredVMs either. A missing or
    # unreadable file is a non-fatal warning (the run proceeds with no exclusions).
    [string]$ExcludedVMListCsv,

    # Age (in hours) at or beyond which a checkpoint / differencing disk is flagged as stale.
    [ValidateRange(0, 8760)]
    [int]$StaleHours = 24,

    # On by default: scan the owning node's Hyper-V Worker/VMMS event logs for recent errors
    # relevant to checkpoint/VHD problems. Use -SkipWorkerEvents to opt out and keep the run light.
    [switch]$SkipWorkerEvents,

    # How far back to look when the event scan runs (default 168 hours = 7 days).
    [ValidateRange(1, 720)]
    [int]$EventLookbackHours = 168,

    # Event IDs that indicate a genuine PROBLEM (drive the 'Concern = YES' flag). Defaults cover the
    # checkpoint fork-commit / merge failure mode on Hyper-V-Worker/Admin and Hyper-V-VMMS/Admin:
    #   3216  Worker: failed to switch to new differencing disks during checkpoint (0x800703EE)
    #   3280  Worker: related checkpoint/disk error
    #   18590 VMMS:   checkpoint FAILED (fork-commit, 0x80048102) - key customer-visible signature
    #   18590 Worker: guest OS bugcheck / fatal error (SAME id, different channel - the VM crashed;
    #                 e.g. after a migration reopened a rolled-back chain). Check the Log column.
    #   18012 VMMS:   checkpoint operation failed
    #   12240 VMMS:   attachment (.avhdx) not found        15268 VMMS: failed to get disk information
    #   16300 VMMS:   cannot load a virtual machine configuration
    #   19090 VMMS:   background disk merge INTERRUPTED
    #   19100 VMMS:   background disk merge FAILED to complete (e.g. 0x80070020 sharing violation)
    [int[]]$WorkerEventIds = @(3216, 3280, 18590, 18012, 12240, 15268, 16300, 19090, 19100),

    # Informational lifecycle event IDs. These are still SURFACED (for the timeline / context) but are
    # NOT flagged as a concern, because on their own they are normal, healthy operations:
    #   18500 VMMS:   VM started successfully          18510 VMMS: checkpoint completed
    #   19070 VMMS:   background disk merge started     19080 VMMS: background disk merge FINISHED successfully
    [int[]]$ContextEventIds = @(18500, 18510, 19070, 19080),

    # HRESULT strings to flag as a concern when they appear in an event message:
    #   0x80048102 = VM_E_COMMIT_FORKS_ERROR        (checkpoint fork-commit failed - ROOT-CAUSE trigger)
    #   0x800480BD = VM_E_FR_CHANGE_TRACKING_FAILED (Replica change-tracking failure - leading indicator)
    #   0x800480BC = VM_E_FR_RESYNC_REQUIRED        (Replica relationship broken - leading indicator)
    #   0x80070020 = ERROR_SHARING_VIOLATION        (backup product cannot open the disk - symptom)
    #   0x800703EE = ERROR_FILE_INVALID             (a volume changed underneath an open file)
    #   0x80070002 = ERROR_FILE_NOT_FOUND           (the .avhdx / VM config file is missing)
    [string[]]$ErrorCodePatterns = @('0x80048102', '0x800480BD', '0x800480BC', '0x80070020', '0x800703EE', '0x80070002'),

    # Skip the per-node check of the Hyper-V-VMMS/Analytic diagnostic channel state.
    [switch]$SkipAnalyticCheck,

    # Colour is ON by default for interactive consoles (section headings + RESULT/WARNING/HOLD STATE).
    # It auto-disables when output is redirected (> file, | Out-File, $x = .\script) so captured text
    # stays complete, and the -OutputPath transcript captures the coloured lines as plain text anyway.
    # Use -NoColour to force plain output.
    [Alias('NoColor')]
    [switch]$NoColour,

    # Emit one [pscustomobject] per VM to the PIPELINE (VMName, Cluster, OwningNode, Recommendation,
    # HoldState, HasAttachedCheckpoints, HasStaleCheckpoints, HasOrphanedCheckpoints, counts,
    # ReportFile, Detail, plus a nested ReportData object with the rich per-VM detail the HTML
    # renders). The human-readable report always goes to the HOST (and, with -OutputPath, the .txt
    # transcript); WITHOUT -PassThru nothing is written to the pipeline, so '$x = .\script' stays
    # clean. Use -PassThru to feed Where-Object / Export-Csv / fleet roll-ups.
    [switch]$PassThru,

    # Where to write the single self-contained HTML fleet report (one row per audited VM). ON by
    # default. Accepts EITHER a folder (the file is auto-named 'VMCheckpointAudit-<ClusterName>-
    # yyyy-MM-dd.html') OR a full path ending in '.html'. When omitted, the report defaults to the
    # per-run sub-folder created under -OutputPath; if -OutputPath was also omitted it is written to
    # the current directory. Use -NoHtml to suppress it entirely.
    [string]$HtmlReportPath,

    # Suppress the HTML fleet report (it is generated by default). The console report, the -OutputPath
    # .txt/.csv files and the -PassThru pipeline objects are unaffected.
    [switch]$NoHtml,

    # Console verbosity. ON (quiet) by DEFAULT: the full per-VM report is written to the .txt file and
    # the HTML, while the console shows only a concise one-line verdict per VM plus the final pointers
    # to the HTML / zip. Pass -Quiet:$false to stream the complete per-VM report to the console as well.
    [bool]$Quiet = $true,

    # Suppress the results .zip bundle (it is created by DEFAULT when -OutputPath is supplied). The zip
    # gathers the per-run .txt / .csv / .html so the whole audit can be copied to a browser device and
    # attached to a support case in one file.
    [switch]$NoZip,

    # Skip the read-only cluster storage-health snapshot (Storage Spaces Direct / CSV / virtual+physical
    # disk health + active storage jobs). On by default; the snapshot is cluster-wide and gathered once.
    [switch]$SkipStorageHealth,

    # v0.2.15: anonymise the internal performance-telemetry JSON. When set, the cluster name, node names
    # and VM names in the telemetry file (and its file name) are replaced with STABLE pseudonyms
    # (CLUSTER, NODE-01.., VM-001..) so the timing data can be shared for performance analysis WITHOUT
    # exposing customer identifiers. Only affects the telemetry JSON - the .txt / .csv / .html are not.
    [switch]$AnonymizeTelemetry
)

begin {

# Runtime requirement guards (see the NOTE above the param block for why these are NOT '#Requires').
# 1) Windows PowerShell 5.1 (Desktop edition) only - this script is written for, and validated
#    against, WinPS 5.1 and is NOT intended for PowerShell 7.x (Core).
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "This script requires Windows PowerShell 5.1 (Desktop edition). It is running under PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) - re-run it in Windows PowerShell 5.1."
}
# 2) FailoverClusters must be available locally (on a cluster node, or via the RSAT 'Failover
#    Clustering' tools on a management workstation).
if (-not (Get-Module -ListAvailable -Name FailoverClusters)) {
    throw @"
The 'FailoverClusters' module is not available. Run this on a cluster node, or install the RSAT
'Failover Clustering' tools on this workstation:
  - Windows 10/11 client : Add-WindowsCapability -Online -Name Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0
  - Windows Server       : Install-WindowsFeature RSAT-Clustering-PowerShell
Then run this in Windows PowerShell 5.1, on a cluster node or a workstation that can reach the cluster.
"@
}

# Script version - single source of truth surfaced in the HTML report (header meta + footer) so a
# saved / emailed report always states which build produced it. Keep in sync with the .NOTES Version.
$script:ScriptVersion = '0.2.15'

# v0.2.14: end-to-end run stopwatch - started as early as possible so the HTML report can state the
# total time taken to audit the whole fleet and render the report ("Report generation time hh:mm:ss").
# v0.2.15: the SAME stopwatch also drives the performance-telemetry clock - every telemetry timestamp
# is derived as $script:TelemetryClockBaseUtc + $script:RunStopwatch.Elapsed, giving monotonic,
# high-resolution (sub-millisecond) UTC start/end times that never jump if the wall clock is adjusted.
$script:TelemetryClockBaseUtc = [System.DateTimeOffset]::UtcNow
$script:RunStopwatch          = [System.Diagnostics.Stopwatch]::StartNew()

# v0.2.15: MANDATORY performance telemetry. Every phase / step of the run records a STRUCTURED entry
# (hierarchical Step number + accurate Start/End UTC + duration) into this list; at the end it is
# written as a 'code_execution_perf_telemetry_<cluster>_<stamp>.json' file bundled in the results zip.
# It is for our own future performance tuning ONLY and is deliberately NOT surfaced in the HTML report.
#
# Step-number scheme (single-digit root; two-digit sub-steps with GAPS of 5 for future insertion;
# numbers intentionally REPEAT for every VM in the audit loop, distinguished by the Detail field):
#   1               = whole script run (total)
#   1.10            = per-VM audit (total)   - repeats once per audited VM (input AND discovered)
#   1.10.NN         = per-VM audit section   - NN = 05,10,15,... (assigned at each Show-AuditProgress call)
#   1.10.50.10      = node-wide event-log scan (a sub-step of section 1.10.50; runs once per node)
#   1.20            = (reserved / free for a future pre-audit phase)
#   1.30            = cluster storage-health snapshot
#   1.40            = HTML report render + write
$script:Telemetry = [System.Collections.Generic.List[object]]::new()

# High-resolution 'now' for telemetry (monotonic UTC). Returns a [DateTimeOffset].
function Get-TelemetryNow { $script:TelemetryClockBaseUtc.AddTicks($script:RunStopwatch.Elapsed.Ticks) }

# v0.2.15 (F3): retry a transient-prone READ-ONLY operation (remoting / cluster-API RPC) a few times
# with a short linear backoff, then let the LAST exception propagate so the caller's existing graceful
# fallback still applies. Safe to repeat (read-only). Used for New-PSSession and the once-per-run
# cluster discovery calls (Get-Cluster / Get-ClusterNode / Get-ClusterGroup) so a single WinRM / RPC
# blip does not abort a VM's audit or empty a cache.
function Invoke-WithRetry {
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$DelayMs = 750
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try { return (& $ScriptBlock) }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Milliseconds ($DelayMs * $attempt)
        }
    }
}

# Microsoft Learn troubleshooting reference for Hyper-V VM backup / checkpoint / storage failures.
# Surfaced in the summary and problem statement so operators have an authoritative next-read. Any
# text quoted VERBATIM from this article in the report is attributed to it (title + URL below).
$script:TroubleshootTitle = 'Microsoft Learn: Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures'
$script:TroubleshootUrl   = 'https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage'

# Colour helpers. The human-readable report is ALWAYS written to the HOST (Write-Host) - never to the
# pipeline / success stream - so the pipeline stays reserved for the -PassThru per-VM summary object.
# A Write-Host proxy (defined below) captures every host line into a per-VM buffer, which is written to
# the .txt (when -OutputPath is supplied) and mined for the HOLD STATE support summary in the HTML.
# Colour is ON by default; it auto-disables when output is redirected (so a captured/paged view stays
# readable) or when -NoColour is passed. -PassThru objects are emitted separately by the end block.
$script:UseColour = (-not $NoColour) -and (-not [Console]::IsOutputRedirected)

# Console verbosity + report capture. The full per-VM report is ALWAYS captured (line by line) into
# $script:VMReportBuffer so it can be written to the per-VM .txt and mined for the HOLD STATE support
# summary shown in the HTML. In Quiet mode (the default) the detailed lines are captured but NOT echoed
# to the console - only the concise verdict + final pointers are shown. The Write-Host proxy below is
# what implements this: it shadows the Write-Host cmdlet for the whole script, so every existing
# Write-Host / Write-Section / Write-Alert / Out-Indented call is captured without further changes.
$script:QuietConsole   = [bool]$Quiet
$script:VMReportBuffer = $null
function Write-Host {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Deliberate in-script proxy: captures report lines to a buffer and conditionally echoes to the host for Quiet mode. Fully qualified Microsoft.PowerShell.Utility\Write-Host is used inside to avoid recursion.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Proxy that captures report lines to a buffer and conditionally echoes to the host.')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
        [object[]]$Object,
        [object]$Separator = ' ',
        [System.ConsoleColor]$ForegroundColor,
        [System.ConsoleColor]$BackgroundColor,
        [switch]$NoNewline
    )
    $text = if ($null -ne $Object) { ($Object -join "$Separator") } else { '' }
    # When a VM audit is in progress its buffer is active: capture the line. In Quiet mode, that is all
    # we do for detail lines (no console echo). Outside an audit (buffer $null) - e.g. begin/end block
    # messages - nothing is captured and the line is always shown.
    if ($null -ne $script:VMReportBuffer) {
        [void]$script:VMReportBuffer.Add([string]$text)
        if ($script:QuietConsole) { return }
    }
    $params = @{ Object = $Object; Separator = $Separator }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $params['ForegroundColor'] = $ForegroundColor }
    if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $params['BackgroundColor'] = $BackgroundColor }
    if ($NoNewline) { $params['NoNewline'] = $true }
    Microsoft.PowerShell.Utility\Write-Host @params
}
function Write-Section {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Opt-in colour via -Colour; falls back to Write-Host.')]
    param([string]$Text)
    if ($script:UseColour) { Write-Host $Text -ForegroundColor Cyan } else { Write-Host $Text }
}
function Write-Alert {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Opt-in colour via -Colour; falls back to Write-Host.')]
    param([string]$Text, [ValidateSet('Info', 'Good', 'Warning', 'Critical')][string]$Level = 'Info')
    if ($script:UseColour) {
        $fg = switch ($Level) { 'Good' { 'Green' } 'Warning' { 'Yellow' } 'Critical' { 'Red' } default { 'Gray' } }
        Write-Host $Text -ForegroundColor $fg
    } else {
        Write-Host $Text
    }
}

# v0.2.15: record ONE performance-telemetry entry. Takes a hierarchical Step number, a Phase name, an
# optional Detail (e.g. VM name / node), and the Start/End [DateTimeOffset] from Get-TelemetryNow.
# Emitted as JSON at the end of the run for our own perf tuning; NEVER surfaced in the HTML report.
function Add-TelemetryEntry {
    param(
        [string]$Step,
        [string]$Phase,
        [string]$Detail = '',
        [System.DateTimeOffset]$StartUtc,
        [System.DateTimeOffset]$EndUtc
    )
    $dur = $EndUtc - $StartUtc
    [void]$script:Telemetry.Add([pscustomobject]@{
        Order       = $script:Telemetry.Count + 1
        Step        = $Step
        Phase       = $Phase
        Detail      = $Detail
        StartUtc    = $StartUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        EndUtc      = $EndUtc.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        DurationMs  = [long][math]::Round($dur.TotalMilliseconds)
        DurationSec = [math]::Round($dur.TotalSeconds, 3)
    })
}

# Render a Format-Table / Format-List result consistently: strip the leading and trailing blank
# lines that the formatter emits, indent every content line by two spaces (so tables line up with
# the 2-space text sections), and finish with exactly one blank line before the next section.
function Out-Indented {
    param([Parameter(ValueFromPipeline=$true)]$InputObject)
    begin { $collected = [System.Collections.Generic.List[object]]::new() }
    process { $collected.Add($InputObject) }
    end {
        $lines = (($collected | Out-String -Width 4096) -split "`r?`n")
        $startIdx = 0
        while ($startIdx -lt $lines.Count -and [string]::IsNullOrWhiteSpace($lines[$startIdx])) { $startIdx++ }
        $endIdx = $lines.Count - 1
        while ($endIdx -ge $startIdx -and [string]::IsNullOrWhiteSpace($lines[$endIdx])) { $endIdx-- }
        for ($i = $startIdx; $i -le $endIdx; $i++) { Write-Host ('  ' + $lines[$i]) }
        Write-Host ''
    }
}

# Build a single self-contained HTML fleet report (inline CSS, no external assets) from the per-VM
# result objects collected during the run. Consumes each result's .ReportData payload (built by
# New-AuditSummary on the success path); results without ReportData (ERROR / NOT FOUND) still render
# a row and a note. Returns the HTML as one [string]. Dynamic values are HTML-encoded; the renderer
# changes nothing. The 'Checkpoints' vs 'AVHDX files' distinction is deliberate: Checkpoints = the
# number of checkpoint objects (Get-VMSnapshot); AVHDX files = active differencing .avhdx layers on
# disk = Checkpoints x Disks (one checkpoint freezes a layer on every attached disk).
function ConvertTo-VMCheckpointAuditHtml {
    [OutputType([string])]
    param(
        [object[]]$Results,
        [int]$StaleHours,
        [int]$EventLookbackHours,
        [string]$ClusterName,
        [string]$GeneratedUtc,
        [object[]]$DiscoveredVMs,
        [object]$StorageHealth,
        [bool]$IncludeDiscoveredVMs,
        [string]$ScriptVersion,
        [string]$ReportGenerationTime,
        [int]$ClusterNodeCount,
        [int]$ClusterCsvCount
    )

    function ConvertTo-HtmlText { param([object]$Value) if ($null -eq $Value) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$Value) } }
    function Get-VerdictRank { param([string]$Rec) switch ($Rec) { 'HOLD STATE' { 0 } 'INVESTIGATE' { 1 } 'OK' { 2 } 'NOT FOUND' { 3 } default { 4 } } }
    function Get-VerdictPill {
        param([string]$Rec)
        switch ($Rec) {
            'HOLD STATE'  { '<span class="pill hold">HOLD STATE</span>' }
            'INVESTIGATE' { '<span class="pill investigate">INVESTIGATE</span>' }
            'OK'          { '<span class="pill ok">OK</span>' }
            'NOT FOUND'   { '<span class="pill err">NOT FOUND</span>' }
            default       { '<span class="pill err">ERROR</span>' }
        }
    }
    # Stable in-page anchor id for a VM (used to link the VM summary table to each VM's detail card).
    # Non-word characters are replaced so the id is always a valid HTML fragment identifier, and the
    # SAME function is used on both ends so the href and the id always match.
    function ConvertTo-Anchor { param([string]$Name) 'vm-' + ([regex]::Replace([string]$Name, '[^A-Za-z0-9_-]', '_')) }

    $rows       = @($Results)
    $countAll   = $rows.Count
    # Distinct cluster nodes that actually owned an audited VM (blank/unknown owners excluded).
    $nodeCount  = @($rows | ForEach-Object { [string]$_.OwningNode } | Where-Object { $_ } | Sort-Object -Unique).Count
    $countHold  = @($rows | Where-Object { $_.Recommendation -eq 'HOLD STATE' }).Count
    $countInv   = @($rows | Where-Object { $_.Recommendation -eq 'INVESTIGATE' }).Count
    $countOk    = @($rows | Where-Object { $_.Recommendation -eq 'OK' }).Count
    $staleTotal = (@($rows | ForEach-Object { [int]$_.StaleCheckpointCount }) | Measure-Object -Sum).Sum
    if (-not $staleTotal) { $staleTotal = 0 }
    # Fleet-wide count of orphaned .avhdx files (present in a VM's disk folder(s) but not attached to
    # any chain). Summed from each VM's ReportData.OrphanCount for the summary card and the gated
    # 'orphaned files' recommended-next-step below.
    $orphanTotal = (@($rows | ForEach-Object { if ($_.ReportData) { [int]$_.ReportData.OrphanCount } else { 0 } }) | Measure-Object -Sum).Sum
    if (-not $orphanTotal) { $orphanTotal = 0 }
    # True when at least one audited node still has the Hyper-V-VMMS Analytic channel NOT enabled
    # (per-VM ReportData.AnalyticNodesNeedEnable). Used to show the 'Enable the Analytic channel'
    # recommended step ONLY when it is actually actionable - if it is already enabled everywhere
    # (or the check was skipped), the bullet is omitted.
    $analyticNeedsEnable = (@($rows | ForEach-Object { if ($_.ReportData) { @($_.ReportData.AnalyticNodesNeedEnable) } } | Where-Object { $_ }).Count -gt 0)

    $sb = [System.Text.StringBuilder]::new()
    $head = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hyper-V VM Checkpoint Health Audit</title>
<style>
  :root{
    --bg:#0f172a; --panel:#1e293b; --panel2:#243349; --ink:#e2e8f0; --muted:#94a3b8;
    --line:#334155; --accent:#38bdf8;
    --amber:#f59e0b; --amber-bg:#3a2c07; --red:#ef4444; --red-bg:#3a0d0d;
    --green:#22c55e; --green-bg:#0f2e1a; --high:#fb7185; --high-bg:#3a1420;
  }
  *{box-sizing:border-box}
  body{margin:0;font-family:Segoe UI,-apple-system,Roboto,Helvetica,Arial,sans-serif;
    background:var(--bg);color:var(--ink);line-height:1.55;font-size:15px}
  .wrap{max-width:1120px;margin:0 auto;padding:32px 24px 80px}
  header.top{border-bottom:2px solid var(--line);padding-bottom:18px;margin-bottom:28px}
  header.top h1{margin:0 0 6px;font-size:26px;color:#fff}
  .meta{color:var(--muted);font-size:13px}
  .meta b{color:var(--ink)}
  h2{margin:38px 0 14px;font-size:20px;color:#fff;border-left:4px solid var(--accent);padding-left:10px}
  h3{margin:22px 0 8px;font-size:16px;color:#fff}
  p{margin:8px 0}
  a{color:var(--accent)}
  code{background:#0b1220;color:#7dd3fc;padding:1px 6px;border-radius:4px;font-size:13px;
    font-family:Consolas,Monaco,monospace;overflow-wrap:anywhere;word-break:break-word}
  pre{white-space:pre-wrap;word-break:break-word;background:#0b1220;color:#cbd5e1;padding:12px;
    border-radius:8px;font-size:12.5px;line-height:1.4;font-family:Consolas,Monaco,monospace;overflow:auto;max-height:560px}
  .cards{display:flex;flex-wrap:wrap;gap:14px;margin:8px 0 6px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
    padding:14px 18px;min-width:140px;flex:1}
  .card .n{font-size:30px;font-weight:700;color:#fff;line-height:1.1}
  .card .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;margin-top:4px}
  .card.amber .n{color:var(--amber)} .card.high .n{color:var(--high)} .card.green .n{color:var(--green)}
  .callout{border-radius:10px;padding:14px 18px;margin:16px 0;border:1px solid var(--line)}
  .callout.info{background:#0b2436;border-color:#1d4e6b}
  .callout.warn{background:var(--amber-bg);border-color:#7a5b12}
  .callout.high{background:var(--high-bg);border-color:#7a2438}
  .callout.ok{background:var(--green-bg);border-color:#1c6b3a}
  .disclaimer{background:var(--amber-bg);border:1px solid #7a5b12;border-radius:8px;
    padding:10px 16px;margin:0 0 22px;color:#fcd34d;font-size:12.5px;line-height:1.5}
  .disclaimer b{color:#fde68a}
  table{width:100%;border-collapse:collapse;margin:12px 0;font-size:13.5px;
    background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
  th,td{padding:9px 11px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top}
  th{background:var(--panel2);color:#cbd5e1;font-weight:600;white-space:nowrap}
  tbody tr:hover{background:#22304a}
  td.num{text-align:right;font-variant-numeric:tabular-nums}
  /* VM name / node cells must NOT wrap (a wrapped long VM name was unreadable). The global
     'code' rule breaks long words, so override it inside these cells. */
  td.nm{white-space:nowrap}
  td.nm code{white-space:nowrap;word-break:normal;overflow-wrap:normal}
  /* VM-name cell: short names stay on one line, but a very long name (e.g. a Kubernetes
     control-plane VM) is allowed to wrap so it never forces the whole table wider than the page. */
  td.vmn{max-width:300px}
  td.vmn code{white-space:normal;word-break:break-word;overflow-wrap:anywhere}
  .src{display:inline-block;margin-left:6px;padding:1px 7px;border-radius:999px;font-size:10.5px;
    font-weight:600;text-transform:uppercase;letter-spacing:.03em;vertical-align:middle}
  .src.input{background:#12303f;color:#7dd3fc;border:1px solid #1d4e6b}
  .src.discovered{background:#3a2c07;color:#fcd34d;border:1px solid #7a5b12}
  .pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11.5px;font-weight:700;white-space:nowrap}
  .pill.investigate{background:var(--amber-bg);color:#fcd34d;border:1px solid #7a5b12}
  .pill.high{background:var(--high-bg);color:#fda4af;border:1px solid #7a2438}
  .pill.ok{background:var(--green-bg);color:#86efac;border:1px solid #1c6b3a}
  .pill.hold{background:var(--red-bg);color:#fca5a5;border:1px solid #7a1f1f}
  .pill.err{background:#2a2f3a;color:#cbd5e1;border:1px solid #475569}
  .vm{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:6px 20px 18px;margin:16px 0}
  .vm.hold{border-color:#7a1f1f;box-shadow:0 0 0 1px #7a1f1f inset}
  .vm h3{display:flex;align-items:center;gap:10px}
  .kv{display:grid;grid-template-columns:230px 1fr;gap:2px 14px;margin:10px 0}
  .kv div.k{color:var(--muted)}
  ul{margin:8px 0;padding-left:22px} li{margin:3px 0}
  details{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:6px 14px;margin:10px 0}
  summary{cursor:pointer;font-weight:600;color:#cbd5e1}
  .muted{color:var(--muted)}
  footer{margin-top:44px;border-top:1px solid var(--line);padding-top:16px;color:var(--muted);font-size:12.5px}
</style>
</head>
<body>
<div class="wrap">
<div class="disclaimer"><b>&#9888; Disclaimer:</b> This tool is EXAMPLE code only - <b>it is NOT a Microsoft-supported product or service offering</b>; provided AS IS with NO warranty of any kind (see the MIT License and <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">README.md</a>). It collects READ-ONLY diagnostic data to render this report - it does NOT determine root cause definitively and does NOT remediate anything. Each VM's status is a data-driven analysis of cluster / VM state, diagnostic events and file-system objects. If you require assistance to interpret any findings, or need guidance prior to any remediation, open a Microsoft Support (CSS) support request (SR) case and act on their advice.</div>
'@
    [void]$sb.Append($head)

    # Header + summary cards.
    $vmWord   = if ($countAll -eq 1) { 'VM' } else { 'VMs' }
    $nodeWord = if ($nodeCount -eq 1) { 'cluster node' } else { 'cluster nodes' }
    [void]$sb.Append(@"
<header class="top">
  <h1>Hyper-V VM Checkpoint Health Audit</h1>
  <div class="meta">
    Cluster <b>$(ConvertTo-HtmlText $ClusterName)</b> &nbsp;&bull;&nbsp; $countAll audited $vmWord
    &nbsp;&bull;&nbsp; Report generated <b>$(ConvertTo-HtmlText $GeneratedUtc) UTC</b>
    &nbsp;&bull;&nbsp; Script version <b>$(ConvertTo-HtmlText $ScriptVersion)</b>$(if ($ReportGenerationTime) { "&nbsp;&bull;&nbsp; Processed <b>$countAll</b> $vmWord, across <b>$nodeCount</b> owning $nodeWord, in <b>$(ConvertTo-HtmlText $ReportGenerationTime)</b>" })<br>$(if ($ClusterNodeCount -gt 0) { "
    Cluster size: <b>$ClusterNodeCount</b> $(if ($ClusterNodeCount -eq 1) { 'node' } else { 'nodes' }) &nbsp;&bull;&nbsp; <b>$ClusterCsvCount</b> Cluster Shared Volume$(if ($ClusterCsvCount -eq 1) { '' } else { 's' })<br>" })
    Parameters: Stale CheckPoint threshold: $StaleHours h; Diagnostic events lookback: $EventLookbackHours h; Include discovered VMs: $(if ($IncludeDiscoveredVMs) { 'Yes' } else { 'No' }).<br>
    Read-only diagnostic - <b>no changes were made to any VM</b>.
  </div>
</header>

<div class="cards">
  <div class="card"><div class="n">$countAll</div><div class="l">$vmWord audited</div></div>
  <div class="card high"><div class="n">$countHold</div><div class="l">Hold state</div></div>
  <div class="card amber"><div class="n">$countInv</div><div class="l">Investigate</div></div>
  <div class="card green"><div class="n">$countOk</div><div class="l">OK</div></div>
  <div class="card amber"><div class="n">$staleTotal</div><div class="l">Stale checkpoints</div></div>
  <div class="card amber"><div class="n">$orphanTotal</div><div class="l">Orphaned .avhdx</div></div>
</div>
"@)

    # Adaptive headline.
    if ($countHold -gt 0) {
        [void]$sb.Append(@"
<div class="callout high">
  <strong>Exec Summary:</strong> $countHold VM(s) are in <strong>HOLD STATE</strong> - a checkpoint fork-commit /
  merge-failure signature AND unmerged differencing disk(s) are present together. As a precaution do NOT
  live/quick/storage-migrate or restart those VMs until the differencing chain has been validated (and
  merged if required). Engage Microsoft Support (CSS) and/or your backup vendor for those VMs.
</div>
"@)
    } else {
        [void]$sb.Append(@"
<div class="callout ok">
  <strong>Exec Summary:</strong> No VM shows the checkpoint <em>fork-commit / merge-failure</em> signature
  (event <code>3216</code> or an HRESULT such as <code>0x80048102</code>) and none is in a HOLD STATE, so
  <strong>no Microsoft Support (CSS) case is warranted yet</strong>. $staleTotal stale backup checkpoint(s)
  were found for the operations / backup team to triage first.
</div>
"@)
    }

    # Node-wide events caveat. v0.2.15: the report now shows TWO event counts per VM (per-VM attributed,
    # which drives the verdict, and node-wide for context), so this explains both rather than a single
    # node-wide figure.
    [void]$sb.Append(@'
<div class="callout info">
  <strong>Reading the event counts:</strong> each VM shows <strong>two</strong> figures - a <strong>per-VM</strong>
  count of concern events whose message names <em>that</em> VM (these drive its verdict), and a <strong>node-wide</strong>
  count for context (checkpoint / merge activity across <strong>all</strong> VMs on the owning node, often referencing
  <em>other</em> VMs). Only the node-wide figure is node health context, not proof the audited VM is failing; each VM's
  own attributed events are listed in its section below.
</div>
'@)

    # Recommended next steps (placed up-front, right after the summary callouts). Every bullet is
    # CONTEXT-GATED so the list shows only advice that is actually actionable for this run:
    #   - the two stale-checkpoint bullets appear only when >=1 stale checkpoint was found;
    #   - the INVESTIGATE bullet only when >=1 VM is INVESTIGATE ($countInv) AND there are NO stale
    #     checkpoints ($staleTotal -eq 0) - i.e. the INVESTIGATE driver is an unhealthy VSS writer or
    #     VM-attributed concern events rather than a stale checkpoint. When a stale checkpoint IS the
    #     driver, the two stale-checkpoint bullets above already cover it, so this bullet is suppressed
    #     to avoid duplicate 'backup team first' advice;
    #   - the Analytic-channel bullet only when a node still needs it enabled ($analyticNeedsEnable);
    #   - the storage bullet only when the storage snapshot is Degraded / has active jobs;
    #   - the HOLD STATE bullet only when >=1 VM is in HOLD STATE.
    # When none of those apply a single 'no action required' line is shown instead. The
    # 'Open a Microsoft Support case' escalation line is a fleet roll-up shown ONLY when >=1 VM is in
    # HOLD STATE (a fork-commit signature is present somewhere) - on INVESTIGATE-only / clean runs it
    # is omitted, because with no fork-commit signature the next step is backup-team triage, not a case.
    # NOTE: $countInv is included in $anyContextualStep so an INVESTIGATE-only run (e.g. VSS-writer /
    # concern-event driven with zero stale checkpoints) never falls through to 'No action required'.
    $storageDegraded   = ($StorageHealth -and (@('Degraded', 'Active storage jobs') -contains "$($StorageHealth.Summary)"))
    # v0.2.14 fleet roll-ups for the new gated bullets.
    $rollbackVMs          = @($rows | Where-Object { $_.ReportData -and $_.ReportData.HasRollbackFingerprint })
    $historicConfirmedVMs = @($rows | Where-Object { $_.ReportData -and $_.ReportData.HistoricForkConfirmed })
    $replicaUnhealthyVMs  = @($rows | Where-Object { $_.ReportData -and $_.ReportData.ReplUnhealthy })
    $anyContextualStep = ($staleTotal -gt 0) -or ($countInv -gt 0) -or $analyticNeedsEnable -or $storageDegraded -or ($countHold -gt 0) -or ($orphanTotal -gt 0) -or ($rollbackVMs.Count -gt 0) -or ($replicaUnhealthyVMs.Count -gt 0)
    [void]$sb.Append(@'
<h2>Recommended next steps</h2>
<ol>
'@)
    if (-not $anyContextualStep) {
        [void]$sb.Append(@'
  <li><strong>No action required from this audit:</strong> no stale checkpoints, no HOLD STATE VMs, no storage-layer disruption, and the Analytic channel is enabled (or was not checked). Keep this report for your records.</li>
'@)
    }
    if ($rollbackVMs.Count -gt 0) {
        $rbNames = (@($rollbackVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
  <li><strong>PRIORITY - possible PAST rollback ({0} VM(s)):</strong> {1} show a cluster of orphaned <code>.avhdx</code> frozen at a common date - the signature of a materialised fork-commit rollback (disks rolled back to base, orphaning the checkpoint layers). Those files may hold un-recovered data. Do NOT remove them; engage Microsoft Support (CSS) / your backup vendor to recover. Because the original events may predate the {2}h lookback, <strong>re-run with a larger window</strong> (e.g. <code>-EventLookbackHours 720</code>) to try to capture them - and see each VM's "Historic event correlation" detail{3}.</li>
'@ -f $rollbackVMs.Count, $rbNames, $EventLookbackHours, $(if ($historicConfirmedVMs.Count -gt 0) { ' (some are already CONFIRMED from recovered historic events)' } else { '' })))
    }
    if ($replicaUnhealthyVMs.Count -gt 0) {
        $rcNames = (@($replicaUnhealthyVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
  <li><strong>Hyper-V Replica needs attention ({0} VM(s)):</strong> {1} report an unhealthy replica (e.g. Critical / resynchronize-required). Start / repair replication for these (this is separate from the checkpoint items).</li>
'@ -f $replicaUnhealthyVMs.Count, $rcNames))
    }
    if ($staleTotal -gt 0) {
        [void]$sb.Append((@'
  <li><strong>INVESTIGATE - backup team first:</strong> for each VM with a stale checkpoint older than {0} hours, check your backup product's recent job history - did the last backup complete? Or is this a manual checkpoint that has been overlooked? Stale checkpoints can be an indicator that a backup did not finish or that the post-backup merge was not requested or failed.</li>
  <li><strong>INVESTIGATE - confirm expected vs abandoned:</strong> you need to confirm if the stale checkpoint(s) are expected (by design) or left behind by a failed backup. If from a point-in-time backup, the checkpoint should be removed / merged (preference for the backup product to perform the checkpoint removal action, over a manual deletion) - the action and decision rest with you / your backup team. If it is a deliberate manual checkpoint that is meant to be long-lived, it is fine to keep it (i.e. a stale flag is not always an issue that needs "fixing") - re-run this audit with <code>-StaleHours &lt;n&gt;</code> (e.g. a value above its age) so it is no longer flagged as stale.</li>
'@ -f $StaleHours))
    }
    if ($countInv -gt 0 -and $staleTotal -eq 0) {
        [void]$sb.Append((@'
  <li><strong>INVESTIGATE (backup team first):</strong> {0} VM(s) show concern signals (unhealthy VSS writer or VM-attributed checkpoint/merge events) but no fork-commit signature - triage with your backup team/vendor before any action; no immediate Microsoft support case is needed for these (see per-VM detail).</li>
'@ -f $countInv))
    }
    if ($orphanTotal -gt 0) {
        [void]$sb.Append((@'
  <li><strong>INVESTIGATE - orphaned .avhdx file(s):</strong> {0} .avhdx file(s) were found in VM disk folder(s) that are NOT attached to any VM chain - a stuck / failed merge or a leftover initial Hyper-V Replica checkpoint can leave these behind under specific scenarios. Confirm each file with your backup team or VM owner before removing any (do not delete blindly); open a Microsoft CSS case for guidance if required. The action and decision to cleanup these old file(s) rests with you / the administrator. See each VM's "Orphaned .avhdx files" detail below for names, sizes and timestamps.</li>
'@ -f $orphanTotal))
    }
    if ($analyticNeedsEnable) {
        [void]$sb.Append(@'
  <li><strong>Enable the Analytic channel</strong> (operator's choice; elevated, per node) to capture the internal per-disk revert trace for the next occurrence: <code>wevtutil sl Microsoft-Windows-Hyper-V-VMMS-Analytic /e:true /q:true</code></li>
'@)
    }
    if ($storageDegraded) {
        [void]$sb.Append(@'
  <li><strong>Rule out storage-layer disruption:</strong> the storage-health section shows active S2D repair / resync jobs, CSV redirection, or unhealthy disks - treat it as a probable contributing factor and run the CSS Storage Diagnostic (<code>Install-Module -Name Microsoft.AzLocal.CSSTools</code>; then <code>Start-AzsSupportStorageDiagnostic</code>).</li>
'@)
    }
    if ($countHold -gt 0) {
        [void]$sb.Append(@'
  <li><strong>HOLD STATE VMs:</strong> engage Microsoft Support (CSS) and/or your backup vendor before any migration / restart.</li>
'@)
    }
    # Case-escalation line: shown ONLY when at least one VM is in HOLD STATE (a fork-commit signature
    # is present somewhere in the fleet). This is a roll-up - if ANY audited VM has the signature a
    # Microsoft case is warranted (the per-VM detail below shows which). On INVESTIGATE-only / clean
    # runs it is deliberately omitted: with NO fork-commit signature the operator's next step is
    # backup-team / vendor triage of the aged checkpoint(s), NOT opening a Microsoft case.
    if ($countHold -gt 0) {
        [void]$sb.Append(@'
  <li><strong>Open a Microsoft Support case:</strong> a checkpoint fork-commit signature (event <code>3216</code> or an HRESULT such as <code>0x80048102</code>) is present on one or more VMs above - that is the condition that warrants a case (the per-VM detail shows which).</li>
'@)
    }
    [void]$sb.Append(@'
</ol>
'@)

    # VM summary table.
    [void]$sb.Append(@'
<h2>VM summary table</h2>
<p class="muted"><strong>Src</strong> = <span class="src input">Input</span> (you requested it) or <span class="src discovered">Discovered</span> (auto-added via <code>-IncludeDiscoveredVMs</code>). <strong>Checkpoints</strong> = checkpoint objects (<code>Get-VMSnapshot</code>). <strong>AVHDX files</strong> = active differencing <code>.avhdx</code> layers = <strong>Checkpoints &times; Disks</strong>. <strong>Orphans</strong> = <code>.avhdx</code> on disk but NOT attached. Rows are ordered by severity within each verdict.</p>
<table>
<thead><tr>
  <th>VM</th><th>State</th><th>Node</th><th>Cfg</th><th>Disks</th><th>Checkpoints</th><th>AVHDX files</th>
  <th>Orphans</th><th>Stale</th><th>Oldest ckpt age</th><th>Hyper-V Replica</th><th>Verdict</th>
</tr></thead>
<tbody>
'@)
    $sortedRows = $rows | Sort-Object `
        @{ Expression = { Get-VerdictRank $_.Recommendation } }, `
        @{ Expression = { if ($_.ReportData) { [int]$_.ReportData.SeverityScore } else { 0 } }; Descending = $true }, `
        VMName
    foreach ($r in $sortedRows) {
        $node = (("$($r.OwningNode)" -split '\.')[0])
        $rd   = $r.ReportData
        $pill = Get-VerdictPill $r.Recommendation
        # Source badge (Input vs Discovered) rendered next to the VM name.
        $srcBadge = ''
        if ($r.PSObject.Properties['Source'] -and $r.Source) {
            $srcCls = if ("$($r.Source)" -eq 'Discovered') { 'discovered' } else { 'input' }
            $srcBadge = "<span class=`"src $srcCls`">$(ConvertTo-HtmlText $r.Source)</span>"
        }
        if ($rd) {
            $ckptCount = @($rd.Checkpoints).Count
            $ages = @($rd.Checkpoints | ForEach-Object { [double]$_.AgeHrs })
            if ($ages.Count -gt 0) {
                $mx = ($ages | Measure-Object -Maximum).Maximum
                $oldest = if ($mx -ge 168) { '~{0}h (~{1}d)' -f [math]::Round($mx, 1), [math]::Round($mx / 24, 0) } else { '~{0}h' -f [math]::Round($mx, 1) }
            } else { $oldest = '-' }
            $repl = if ($rd.Replication.Enabled) { ConvertTo-HtmlText ("{0} ({1})" -f $rd.Replication.State, $rd.Replication.Health) } else { 'Not enabled' }
            $stateTxt = ConvertTo-HtmlText $rd.State
            [void]$sb.Append(@"
<tr>
  <td class="vmn"><a href="#$(ConvertTo-Anchor $r.VMName)"><code>$(ConvertTo-HtmlText $r.VMName)</code></a>$srcBadge</td><td>$stateTxt</td><td class="nm">$(ConvertTo-HtmlText $node)</td><td>$(ConvertTo-HtmlText $rd.Version)</td>
  <td class="num">$($rd.AttachedDiskCount)</td><td class="num">$ckptCount</td><td class="num">$($rd.CheckpointLayers)</td>
  <td class="num">$($rd.OrphanCount)</td><td class="num">$($rd.StaleCheckpointCount)</td><td>$oldest</td>
  <td>$repl</td><td>$pill</td>
</tr>
"@)
        } else {
            [void]$sb.Append(@"
<tr>
  <td class="vmn"><a href="#$(ConvertTo-Anchor $r.VMName)"><code>$(ConvertTo-HtmlText $r.VMName)</code></a>$srcBadge</td><td>-</td><td class="nm">$(ConvertTo-HtmlText $node)</td><td>-</td>
  <td class="num">-</td><td class="num">-</td><td class="num">-</td>
  <td class="num">-</td><td class="num">-</td><td>-</td>
  <td>-</td><td>$pill</td>
</tr>
"@)
        }
    }
    [void]$sb.Append("</tbody></table>`r`n")

    # Discovered high-risk VMs (referenced in event data but not in the audit list).
    if (@($DiscoveredVMs).Count -gt 0) {
        [void]$sb.Append("<h2>Discovered high-risk VMs (recommended to audit)</h2>`r`n")
        [void]$sb.Append("<div class='callout warn'>These VMs were <strong>not in the audit list</strong> but were referenced in this cluster's <strong>high-risk</strong> checkpoint / merge event signals (background disk merge interrupted / failed, sharing violation <code>0x80070020</code>, or 'cannot load VM configuration'). Given the data-loss risk of the fork-commit failure mode, auditing them is recommended.</div>`r`n")
        [void]$sb.Append("<table><thead><tr><th>VM</th><th>Why flagged</th></tr></thead><tbody>")
        foreach ($dv in $DiscoveredVMs) {
            [void]$sb.Append("<tr><td><code>$(ConvertTo-HtmlText $dv.Name)</code></td><td>$(ConvertTo-HtmlText $dv.Reason)</td></tr>")
        }
        [void]$sb.Append("</tbody></table>`r`n")
        $dvNames = (@($DiscoveredVMs | ForEach-Object { "'{0}'" -f $_.Name }) -join ',')
        [void]$sb.Append("<p>Audit them with:</p><pre>.\Get-HyperVVMCheckpointHealth.ps1 -VMName $(ConvertTo-HtmlText $dvNames) -OutputPath &lt;folder&gt;</pre>`r`n")
        [void]$sb.Append("<p class='muted'>Or re-run the original command adding <code>-IncludeDiscoveredVMs</code> to audit them automatically (bounded and non-recursive).</p>`r`n")
    }

    # Per-VM detail.
    [void]$sb.Append("<h2>Per-VM detailed information</h2>`r`n")
    foreach ($r in $sortedRows) {
        $rd   = $r.ReportData
        $pill = Get-VerdictPill $r.Recommendation
        $cls  = if ($r.Recommendation -eq 'HOLD STATE') { ' hold' } else { '' }
        $srcBadge = ''
        if ($r.PSObject.Properties['Source'] -and $r.Source) {
            $srcCls = if ("$($r.Source)" -eq 'Discovered') { 'discovered' } else { 'input' }
            $srcBadge = "<span class=`"src $srcCls`">$(ConvertTo-HtmlText $r.Source)</span>"
        }
        [void]$sb.Append("<div class=`"vm$cls`" id=`"$(ConvertTo-Anchor $r.VMName)`">`r`n  <h3><code>$(ConvertTo-HtmlText $r.VMName)</code> $pill$srcBadge</h3>`r`n")
        if (-not $rd) {
            [void]$sb.Append("  <div class='callout warn'>$(ConvertTo-HtmlText $r.Detail)</div>`r`n</div>")
            continue
        }
        $ckptCount = @($rd.Checkpoints).Count
        $verOld = if ($rd.VmVerOlder) { "Yes - v$(ConvertTo-HtmlText $rd.Version) vs cluster max v$(ConvertTo-HtmlText $rd.HostMaxVersion) (migration/start context only; not a checkpoint cause)." } else { 'No - at the latest supported version.' }
        $analytic = if (@($rd.AnalyticNodesNeedEnable) -contains $r.OwningNode) { 'Not enabled on this node' } else { 'Enabled (or not checked)' }
        $vss = switch ($rd.VssState) { 'Healthy' { "All $($rd.VssTotal) writer(s) Stable (no last error)" } 'Unhealthy' { "$($rd.VssUnhealthyCount) of $($rd.VssTotal) writer(s) NOT healthy" } default { 'Unavailable (needs elevated context on owner)' } }
        $srcText   = if ($r.PSObject.Properties['Source'] -and $r.Source) { [string]$r.Source } else { 'Input' }
        $nodeWideNote = if ($rd.PSObject.Properties['NodeDominantNote'] -and $rd.NodeDominantNote) { " ($($rd.NodeDominantNote))" } else { '' }
        [void]$sb.Append(@"
  <div class="kv">
    <div class="k">Source</div><div>$(ConvertTo-HtmlText $srcText) $(if ($srcText -eq 'Discovered') { '(auto-added via -IncludeDiscoveredVMs)' } else { '(you requested this VM)' })</div>
    <div class="k">VM state</div><div>$(ConvertTo-HtmlText $rd.State) / $(ConvertTo-HtmlText $rd.Status)</div>
    <div class="k">Owning node</div><div><code>$(ConvertTo-HtmlText $r.OwningNode)</code></div>
    <div class="k">Config version</div><div>$(ConvertTo-HtmlText $rd.Version) (cluster max $(ConvertTo-HtmlText $rd.HostMaxVersion))</div>
    <div class="k">Uptime</div><div>$(ConvertTo-HtmlText $rd.Uptime)</div>
    <div class="k">Attached disks</div><div>$($rd.AttachedDiskCount)</div>
    <div class="k">Checkpoints (Get-VMSnapshot)</div><div>$ckptCount</div>
    <div class="k">Differencing (.avhdx) files</div><div>$(if ([int]$rd.CheckpointLayers -gt 0) { "$($rd.CheckpointLayers) (= checkpoints &times; disks)" } else { '0 (no checkpoints)' })</div>
    <div class="k">Stale checkpoints (&ge;$($rd.StaleHours)h)</div><div>$($rd.StaleCheckpointCount)</div>
    <div class="k">Checkpoint type</div><div>$(ConvertTo-HtmlText $rd.CheckpointType)</div>
    <div class="k">Orphaned .avhdx</div><div>$($rd.OrphanCount)</div>
    <div class="k">Hyper-V Replica</div><div>$(if ($rd.Replication.Enabled) { ConvertTo-HtmlText ("{0} ({1})" -f $rd.Replication.State, $rd.Replication.Health) } else { 'Not enabled' })</div>
    <div class="k">VSS writers</div><div>$(ConvertTo-HtmlText $vss)</div>
    <div class="k">Analytic channel</div><div>$(ConvertTo-HtmlText $analytic)</div>
    <div class="k">Config behind latest</div><div>$verOld</div>
    <div class="k">Concerning events - this VM ($($rd.EventLookbackHours)h)</div><div>$($rd.VmEventConcernCount) ($(if ([int]$rd.VmHighConcernCount -gt 0) { "$($rd.VmHighConcernCount) high-signal" } else { 'low-signal only' }))</div>
    <div class="k">Concerning events - node-wide ($($rd.EventLookbackHours)h)</div><div>$($rd.EventConcernCount)$nodeWideNote (references other VMs / none - context only)</div>
  </div>
"@)
        # Assessment callout. v0.2.14: name the actual INVESTIGATE driver (so the operator sees WHY and
        # HOW urgent), surface the 'possible past rollback' fingerprint + historic-correlation result,
        # and add a low-key note on OK VMs whose only signal was low-signal chatter.
        if ($r.Recommendation -eq 'HOLD STATE') {
            [void]$sb.Append("  <div class='callout high'><strong>HOLD STATE (data-loss risk).</strong> A checkpoint fork-commit / merge-failure signature AND unmerged differencing disk(s) are present together. Do NOT migrate or restart this VM until the chain is validated (and merged if required); reopening an inconsistent chain can roll disks back to base. Engage Microsoft Support (CSS) and/or your backup vendor.</div>`r`n")
        } elseif ($r.Recommendation -eq 'INVESTIGATE') {
            # Build the driver phrase from the strongest signal down.
            $drv = @()
            if ($rd.HasRollbackFingerprint) { $drv += "possible PAST rollback - $($rd.OrphanCount) orphaned .avhdx frozen at a common date ($(ConvertTo-HtmlText $rd.RollbackDate))" }
            elseif ($rd.HasStuckMergeOrphan) { $drv += "orphaned .avhdx with a matching stuck/failed-merge event" }
            if ($rd.StaleCheckpointCount -gt 0) { $drv += "$($rd.StaleCheckpointCount) stale checkpoint(s)" }
            if ($rd.ReplCritical) { $drv += "replica health Critical ($(ConvertTo-HtmlText $rd.ReplHealth))" }
            elseif ($rd.ReplUnhealthy) { $drv += "replica health $(ConvertTo-HtmlText $rd.ReplHealth)" }
            if (($rd.OrphanCount -gt 0) -and -not $rd.HasRollbackFingerprint -and -not $rd.HasStuckMergeOrphan) {
                $drv += $(if ($rd.OrphanOnlyLiveMount) { "$($rd.OrphanCount) orphaned .avhdx (likely backup live-mount artifact)" } else { "$($rd.OrphanCount) orphaned .avhdx (leftover file)" })
            }
            if ($rd.VmHighConcernCount -gt 0) { $drv += "$($rd.VmHighConcernCount) high-signal event(s) for this VM" }
            if ($rd.VssState -eq 'Unhealthy') { $drv += "$($rd.VssUnhealthyCount) unhealthy VSS writer(s)" }
            $drvText = if ($drv.Count -gt 0) { (($drv) -join '; ') } else { 'concern signals present' }
            if ($rd.HasRollbackFingerprint) {
                [void]$sb.Append("  <div class='callout high'><strong>INVESTIGATE - possible PAST rollback.</strong> Driver: $drvText. The orphaned <code>.avhdx</code> appear to be the aftermath of a materialised fork-commit rollback on <strong>$(ConvertTo-HtmlText $rd.RollbackDate)</strong> - they may hold the data written between the checkpoint and the rollback. Do NOT remove them; engage Microsoft Support (CSS) / your backup vendor to recover. The original fork-commit events may predate the $($rd.EventLookbackHours)h lookback - see the historic correlation below.</div>`r`n")
            } else {
                [void]$sb.Append("  <div class='callout warn'><strong>INVESTIGATE.</strong> Driver: $drvText. The specific checkpoint fork-commit signature was NOT observed in the current window, so on-disk chain corruption is not confirmed - backup-team / operator triage first; no Microsoft case needed yet.</div>`r`n")
            }
        } elseif ($r.Recommendation -eq 'OK') {
            if ($rd.LowSignalOnly) {
                [void]$sb.Append("  <div class='callout ok'><strong>OK.</strong> No active checkpoint layers, no orphaned .avhdx, replica healthy and VSS stable. Note: $($rd.VmLowConcernCount) low-signal event(s) (e.g. 'failed to get disk information') are attributed to this VM - these are storage/housekeeping chatter and are not, on their own, a concern.</div>`r`n")
            } else {
                [void]$sb.Append("  <div class='callout ok'><strong>OK.</strong> No active checkpoint layers and no concern signals were found. No action required from this result.</div>`r`n")
            }
        }
        # HOLD STATE: the copy/paste support-case summary lifted verbatim from the per-VM report (collapsed).
        if ($r.Recommendation -eq 'HOLD STATE' -and $rd.PSObject.Properties['SupportCaseSummary'] -and $rd.SupportCaseSummary) {
            [void]$sb.Append("  <details open><summary>Support Case summary (copy/paste for Microsoft Support / your backup vendor)</summary><pre>$(ConvertTo-HtmlText $rd.SupportCaseSummary)</pre></details>`r`n")
        }
        # Checkpoints table.
        if ($ckptCount -gt 0) {
            [void]$sb.Append("  <details open><summary>Checkpoints ($ckptCount)</summary><table><thead><tr><th>Name</th><th>Type</th><th>Purpose</th><th>Created (UTC)</th><th>Age (hrs)</th><th>Stale</th><th>Parent</th></tr></thead><tbody>")
            foreach ($c in @($rd.Checkpoints | Sort-Object AgeHrs -Descending)) {
                $staleTxt = if ($c.Stale) { 'YES' } else { 'NO' }
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $c.Name)</td><td>$(ConvertTo-HtmlText $c.Type)</td><td>$(ConvertTo-HtmlText $c.Purpose)</td><td>$(ConvertTo-HtmlText $c.Created)</td><td class='num'>$($c.AgeHrs)</td><td>$staleTxt</td><td>$(ConvertTo-HtmlText $c.Parent)</td></tr>")
            }
            [void]$sb.Append("</tbody></table></details>`r`n")
        }
        # Orphaned .avhdx files table (present on disk in this VM's folder(s) but NOT attached to any
        # chain). v0.2.14: per-orphan class + age + a neutral 'Likely / action' read. NEVER states
        # 'safe to delete' - the action and decision always rest with the operator.
        if (@($rd.Orphans).Count -gt 0) {
            [void]$sb.Append("  <details open><summary>Orphaned .avhdx files ($($rd.OrphanCount)) - on disk but NOT attached to the VM</summary><table><thead><tr><th>File Name</th><th>Size (GB)</th><th>Created (UTC)</th><th>LastWrite (UTC)</th><th>Age (days)</th><th>Likely / action</th><th>Full path</th></tr></thead><tbody>")
            foreach ($o in @($rd.Orphans)) {
                $ageTxt = if ($null -ne $o.AgeDays) { "$($o.AgeDays)" } else { '-' }
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $o.Name)</td><td class='num'>$($o.SizeGB)</td><td>$(ConvertTo-HtmlText $o.Created)</td><td>$(ConvertTo-HtmlText $o.LastWrite)</td><td class='num'>$ageTxt</td><td>$(ConvertTo-HtmlText $o.Likely)</td><td><code>$(ConvertTo-HtmlText $o.FullName)</code></td></tr>")
            }
            [void]$sb.Append("</tbody></table><p class='muted'>Orphaned <code>.avhdx</code> are differencing files on disk that are not attached to the VM. They can be the aftermath of a rolled-back / stuck merge (which may hold un-recovered data) or leftover backup / live-mount files. <strong>Do not delete based on this report</strong> - Action: confirm each file with your backup team or VM owner. The action and decision to cleanup these old file(s) rests with you / the administrator.</p></details>`r`n")
        }
        # Historic cross-node event correlation (v0.2.14) - only present when this VM had orphans.
        if ($rd.PSObject.Properties['Historic'] -and $rd.Historic) {
            $hc = $rd.Historic
            $openAttr = if ([int]$hc.MatchCount -gt 0) { ' open' } else { '' }
            [void]$sb.Append("  <details$openAttr><summary>Historic event correlation ($($hc.MatchCount) match(es) around orphan timestamps, across $(@($hc.NodesSearched).Count) node(s))</summary>")
            [void]$sb.Append("<p class='muted'>Searched &plusmn;$($hc.WindowMinutes) min around each orphan's create and last-write times (windows: $(ConvertTo-HtmlText ((@($hc.Windows)) -join ', '))) across all cluster nodes, for this VM's fork-commit / merge events that may predate the $($rd.EventLookbackHours)h lookback.</p>")
            if ([int]$hc.MatchCount -gt 0) {
                if ($rd.HistoricForkConfirmed) {
                    [void]$sb.Append("<div class='callout high'><strong>CONFIRMED past fork-commit / merge failure.</strong> Historic events for this VM were recovered around the orphan timestamps (outside the standard window). This is strong evidence the rollback DID occur - engage Microsoft Support (CSS) / your backup vendor to recover the orphaned data.</div>")
                }
                [void]$sb.Append("<table><thead><tr><th>Time (UTC)</th><th>Node</th><th>Log</th><th>Id</th><th>Message</th></tr></thead><tbody>")
                foreach ($m in @($hc.Matches)) {
                    [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $m.Time)</td><td>$(ConvertTo-HtmlText $m.Node)</td><td>$(ConvertTo-HtmlText $m.Log)</td><td><code>$($m.Id)</code></td><td>$(ConvertTo-HtmlText $m.Message)</td></tr>")
                }
                [void]$sb.Append("</tbody></table>")
            } else {
                if ($hc.LogsWrappedPastWindow) {
                    [void]$sb.Append("<div class='callout warn'>No historic events found - but the event logs on the searched node(s) only go back to <strong>$(ConvertTo-HtmlText $hc.OldestAvailableUtc) UTC</strong>, which is AFTER the orphan timestamps. The logs have <strong>wrapped past</strong> the relevant window, so the original events are no longer available - <strong>absence here is NOT proof</strong> that no rollback occurred.</div>")
                } else {
                    [void]$sb.Append("<div class='callout ok'>No historic fork-commit / merge events for this VM in the searched windows, and the logs DO cover that period (oldest available $(ConvertTo-HtmlText $hc.OldestAvailableUtc) UTC). The orphans are less likely to be a fork-commit rollback - more likely leftover backup / live-mount files - but confirm with your backup team.</div>")
                }
            }
            [void]$sb.Append("</details>`r`n")
        }
        # Concerning events breakdown - events ATTRIBUTABLE TO THIS VM only (not node-wide). The
        # node-wide total is shown for context, but the itemised list is this VM's own events so the
        # per-VM section never lists another VM's events.
        if ($rd.VmEventConcernCount -gt 0 -and @($rd.EventBreakdown).Count -gt 0) {
            [void]$sb.Append("  <details><summary>Concerning events attributable to this VM ($($rd.VmEventConcernCount) in $($rd.EventLookbackHours)h)</summary><ul>")
            foreach ($e in @($rd.EventBreakdown)) {
                # Show a single timestamp when there is only one occurrence; a first/last range otherwise.
                $whenTxt = if ([int]$e.Count -le 1 -or "$($e.First)" -eq "$($e.Last)") { "at $(ConvertTo-HtmlText $e.First)" } else { "first $(ConvertTo-HtmlText $e.First), last $(ConvertTo-HtmlText $e.Last)" }
                [void]$sb.Append("<li><code>$($e.Id)</code> &times;$($e.Count) ($whenTxt) - $(ConvertTo-HtmlText $e.Sample)</li>")
            }
            [void]$sb.Append("</ul>")
            $nodeOnlyCount = [int]$rd.EventConcernCount - [int]$rd.VmEventConcernCount
            if ($nodeOnlyCount -gt 0) {
                [void]$sb.Append("<p class='muted'>A further $nodeOnlyCount concerning event(s) on this node reference OTHER VMs (or no VM) - node context only, not attributed to this VM and not listed here.</p>")
            }
            $csvPtr = @()
            if ($rd.EventsCsvName) { $csvPtr += "this VM's events in <code>$(ConvertTo-HtmlText $rd.EventsCsvName)</code>" }
            if ($rd.PSObject.Properties['NodeEventsCsvName'] -and $rd.NodeEventsCsvName) { $csvPtr += "node-wide detail in <code>$(ConvertTo-HtmlText $rd.NodeEventsCsvName)</code>" }
            if ($csvPtr.Count -gt 0) { [void]$sb.Append("<p class='muted'>Full, untruncated messages: $((($csvPtr) -join '; ')).</p>") }
            [void]$sb.Append("</details>`r`n")
        }
        [void]$sb.Append("</div>")
    }

    # Cluster storage-health snapshot (S2D / CSV) - a strong candidate contributing factor for the
    # checkpoint/merge symptoms (files transiently locked / unavailable during repair-resync or CSV
    # redirection). Read-only lightweight snapshot; points to the CSS deep-diagnostic for more.
    if ($StorageHealth) {
        $sh = $StorageHealth
        $badge = switch ("$($sh.Summary)") { 'Healthy' { 'ok' } 'Unavailable' { 'info' } default { 'warn' } }
        [void]$sb.Append("<h2>Cluster storage health (Storage Spaces Direct / CSV)</h2>`r`n")
        [void]$sb.Append("<div class='callout $badge'><strong>Storage status: $(ConvertTo-HtmlText $sh.Summary).</strong> Read-only snapshot (source node <code>$(ConvertTo-HtmlText $sh.Source)</code>). Storage-layer disruption - S2D repair / resync jobs, CSV block-redirected or paused state, or unhealthy disks - can cause the very symptoms behind checkpoint / merge failures (files transiently locked or unavailable: <code>0x80070020</code>, <code>0x80070002</code>, 'cannot load VM configuration'). Note: on Azure Local / S2D an <strong>ReFS CSV normally reports File System Redirected mode with reason <code>FileSystemReFs</code></strong> (from <code>Get-ClusterSharedVolumeState</code>) - that is by design (S2D serves the I/O over the software storage bus, so there is no redirect penalty) and is NOT flagged here. Only a NON-ReFS file-system redirect, block redirection, or a paused / offline volume is treated as abnormal.</div>`r`n")
        if (@($sh.StorageJobs).Count -gt 0) {
            [void]$sb.Append("<h3>Active storage jobs</h3><table><thead><tr><th>Job</th><th>State</th><th>% complete</th></tr></thead><tbody>")
            foreach ($j in @($sh.StorageJobs)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $j.Name)</td><td>$(ConvertTo-HtmlText $j.State)</td><td class='num'>$(ConvertTo-HtmlText $j.Pct)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if (@($sh.CsvRedirected).Count -gt 0) {
            [void]$sb.Append("<h3>CSVs in an abnormal state (block-redirected, non-ReFS file-system redirected, or paused)</h3><table><thead><tr><th>Volume</th><th>Affected node(s)</th><th>State</th><th>Block reason</th><th>FS reason</th></tr></thead><tbody>")
            foreach ($v in @($sh.CsvRedirected)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $v.Volume)</td><td>$(ConvertTo-HtmlText $v.Nodes)</td><td>$(ConvertTo-HtmlText $v.State)</td><td>$(ConvertTo-HtmlText $v.BlockReason)</td><td>$(ConvertTo-HtmlText $v.FsReason)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if (@($sh.VDiskUnhealthy).Count -gt 0) {
            [void]$sb.Append("<h3>Unhealthy virtual disks</h3><table><thead><tr><th>Name</th><th>Health</th><th>Operational</th></tr></thead><tbody>")
            foreach ($d in @($sh.VDiskUnhealthy)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $d.Name)</td><td>$(ConvertTo-HtmlText $d.Health)</td><td>$(ConvertTo-HtmlText $d.Operational)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if (@($sh.PDiskUnhealthy).Count -gt 0) {
            [void]$sb.Append("<h3>Unhealthy physical disks</h3><table><thead><tr><th>Name</th><th>Health</th><th>Operational</th><th>Usage</th></tr></thead><tbody>")
            foreach ($d in @($sh.PDiskUnhealthy)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $d.Name)</td><td>$(ConvertTo-HtmlText $d.Health)</td><td>$(ConvertTo-HtmlText $d.Operational)</td><td>$(ConvertTo-HtmlText $d.Usage)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if (@($sh.Subsystem).Count -gt 0) {
            $subTxt = (@($sh.Subsystem | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Health }) -join '; ')
            [void]$sb.Append("<p class='muted'>Storage subsystem health: $(ConvertTo-HtmlText $subTxt). (A <em>Warning</em> here is often a minor, non-storage fault such as 'update available' - use the CSS diagnostic below for the exact fault.)</p>")
        }
        if ("$($sh.Summary)" -eq 'Healthy') {
            [void]$sb.Append("<p class='muted'>No active storage jobs, no redirected CSVs, and no unhealthy virtual / physical disks were detected at snapshot time.</p>")
        }
        if ("$($sh.Summary)" -eq 'Unavailable' -and $sh.Note) {
            [void]$sb.Append("<p class='muted'>Storage cmdlets were not available from the snapshot node: $(ConvertTo-HtmlText $sh.Note)</p>")
        }
        [void]$sb.Append("<div class='callout info'><strong>Deeper analysis (recommended):</strong> this is a lightweight snapshot. For a full Storage Spaces Direct / SBL diagnostic - including storage event-channel analysis around the incident window - run Microsoft's CSS Storage Diagnostic, which performs far more checks:<br><code>Install-Module -Name Microsoft.AzLocal.CSSTools</code><br><code>Start-AzsSupportStorageDiagnostic</code><br><a href='https://github.com/Azure/AzureLocal-Supportability/blob/main/tools/CSSTools/1.2605.5.1611/functions/Start-AzsSupportStorageDiagnostic.md'>Start-AzsSupportStorageDiagnostic documentation</a></div>`r`n")
    }

    # Information (anonymised RCA background) + footer.
    [void]$sb.Append(@'
<h2>Informational: technical details of the 'checkpoint fork-commit / merge-failure' signature</h2>
<div class="callout info">
  <strong>Generic technical background</strong> - this section contains no customer, host or VM-specific data. It
  explains the failure mode this audit looks for and the exact Event IDs / error codes that indicate it is present.
</div>
<p><strong>What it is.</strong> When Hyper-V takes a checkpoint (including the checkpoint a backup product creates
automatically), the running disk is frozen and writes are redirected into a new differencing <code>.avhdx</code>.
When the checkpoint is later removed, Hyper-V must <em>commit</em> (merge) that fork back into its parent and rewrite
each disk''s on-disk configuration (<code>.vmcx</code>). If that <strong>fork-commit</strong> step fails, the per-disk
<code>.vmcx</code> can be reverted <em>inconsistently</em>: the VM keeps running normally on its in-memory chain, but
the on-disk chain metadata no longer matches. The inconsistency stays <strong>dormant</strong> until the VM is
live-migrated or restarted - at which point Hyper-V reopens the on-disk chain and can <strong>roll the disks back to
their base</strong>, orphaning everything written into the <code>.avhdx</code> layer(s) since the checkpoint.</p>
<p><strong>How it typically unfolds:</strong></p>
<ol>
  <li><strong>Leading indicators</strong> - Hyper-V Replica change-tracking / resync failures (<code>0x800480BD</code>, <code>0x800480BC</code>).</li>
  <li><strong>Trigger</strong> - the checkpoint fork-commit fails: VMMS event <code>18590</code> with <code>0x80048102</code> (<code>VM_E_COMMIT_FORKS_ERROR</code>), or Worker event <code>3216</code> (<code>0x800703EE</code>, failed to switch to the new differencing disks).</li>
  <li><strong>Per-disk revert</strong> leaves the <code>.vmcx</code> chain inconsistent (traced only on the Hyper-V-VMMS/Analytic channel, which is off by default).</li>
  <li><strong>Symptoms</strong> - backup retries then fail to open the disk (<code>0x80070020</code>, sharing violation); follow-on merges are interrupted / fail (<code>19090</code> / <code>19100</code>).</li>
  <li><strong>Dormant, then materialised</strong> - the VM runs fine until a live migration or restart reopens the chain and rolls the disks back.</li>
</ol>
<p><strong>Event IDs and error codes treated as the signature:</strong></p>
<table>
<thead><tr><th>Signal</th><th>Channel</th><th>Meaning</th><th>Role</th></tr></thead>
<tbody>
  <tr><td>HRESULT <code>0x80048102</code> (typically with VMMS event <code>18590</code>)</td><td>Hyper-V-VMMS</td><td><code>VM_E_COMMIT_FORKS_ERROR</code> - the checkpoint fork-commit failed</td><td><strong>Confirming</strong> (drives HOLD STATE)</td></tr>
  <tr><td>Event <code>18590</code> <em>without</em> a fork-commit HRESULT</td><td>Hyper-V-Worker</td><td>Guest-OS bugcheck / fatal error (e.g. Stop <code>0x7E</code>) - the VM crashed; this is NOT a checkpoint fork-commit</td><td>Context only (does not drive HOLD STATE)</td></tr>
  <tr><td>Event <code>3216</code> + <code>0x800703EE</code></td><td>Hyper-V-Worker</td><td>Failed to switch to the new differencing disks during checkpoint</td><td><strong>Confirming</strong></td></tr>
  <tr><td><code>0x800480BD</code></td><td>Replica</td><td><code>VM_E_FR_CHANGE_TRACKING_FAILED</code></td><td>Leading indicator</td></tr>
  <tr><td><code>0x800480BC</code></td><td>Replica</td><td><code>VM_E_FR_RESYNC_REQUIRED</code></td><td>Leading indicator</td></tr>
  <tr><td>Event <code>18012</code></td><td>Hyper-V-VMMS</td><td>Checkpoint operation failed</td><td>Corroborating</td></tr>
  <tr><td>Event <code>19090</code> / <code>19100</code></td><td>Hyper-V-VMMS</td><td>Background disk merge interrupted / failed (<code>0x80070020</code>)</td><td>Corroborating</td></tr>
  <tr><td>Event <code>12240</code> / <code>15268</code></td><td>Hyper-V-VMMS</td><td>Attachment <code>.avhdx</code> not found / failed to get disk information (<code>0x80070002</code>)</td><td>Corroborating</td></tr>
  <tr><td>Event <code>16300</code></td><td>Hyper-V-VMMS</td><td>Cannot load a virtual machine configuration</td><td>Corroborating</td></tr>
</tbody>
</table>
<p><strong>How the verdict is decided.</strong> A VM is flagged <span class="pill hold">HOLD STATE</span> only when a
<strong>confirming</strong> signal above is found <em>together with</em> one or more unmerged differencing
(<code>.avhdx</code>) layers - that combination is the data-loss risk. Concern signals <em>without</em> a confirming
fork-commit signature are flagged <span class="pill investigate">INVESTIGATE</span> (usually a stalled / failed backup
checkpoint or an unhealthy VSS writer), which the operations / backup team should triage first.</p>
<p class="muted">Reference: Microsoft Learn - Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures: <a href="https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage">learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage</a></p>

<footer>
  Generated by <code>Get-HyperVVMCheckpointHealth.ps1</code> (version __SCRIPTVERSION__). Read-only diagnostic report; no VM state was
  modified. Verdict legend: <span class="pill hold">HOLD STATE</span> fork-commit signature + unmerged
  disks (case-worthy) &nbsp; <span class="pill investigate">INVESTIGATE</span> concern signals, ops/backup
  team first &nbsp; <span class="pill ok">OK</span> no concerns &nbsp; <span class="pill err">ERROR / NOT FOUND</span>.
  <br><br><strong>DISCLAIMER:</strong> EXAMPLE code only - <strong>it is NOT a Microsoft-supported product or service offering</strong>; provided AS IS with NO warranty of any kind (see the MIT License and <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">README.md</a>). It collects READ-ONLY diagnostic data to render this report - it does NOT determine root cause definitively and does NOT remediate anything. Each VM's status is a data-driven analysis of cluster / VM state, diagnostic events and file-system objects. If you require assistance to interpret any findings, or need guidance prior to any remediation, open a Microsoft Support (CSS) support request (SR) case and act on their advice.
  <br><br><a href="https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback" target="_blank" rel="noopener noreferrer">Share feedback / report an issue</a>
</footer>
</div>
</body>
</html>
'@)
    return ($sb.ToString() -replace '__SCRIPTVERSION__', [System.Net.WebUtility]::HtmlEncode([string]$ScriptVersion))
}

# Read-only, lightweight cluster storage-health snapshot (Storage Spaces Direct / CSV). Gathered ONCE
# per run (S2D + storage jobs are cluster-wide). Runs the storage cmdlets in a cluster-node context:
# locally when this host is the target node, else via ONE remoting hop. Everything is wrapped so a
# missing Storage module / non-S2D host degrades gracefully to 'Unavailable' rather than throwing.
function Get-ClusterStorageHealthSnapshot {
    [OutputType([object])]
    param([string]$TargetNode)

    $scan = {
        $o = [ordered]@{
            ComputerName   = $env:COMPUTERNAME
            StorageModule  = [bool](Get-Command Get-StorageJob -ErrorAction SilentlyContinue)
            StorageJobs    = @()
            VDiskUnhealthy = @()
            PDiskUnhealthy = @()
            Subsystem      = @()
            CsvRedirected  = @()
            Notes          = @()
        }
        try { $o.StorageJobs = @(Get-StorageJob -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; State = [string]$_.JobState; Pct = [string]$_.PercentComplete } }) } catch { $o.Notes += "StorageJob: $($_.Exception.Message)" }
        try { $o.VDiskUnhealthy = @(Get-VirtualDisk -ErrorAction Stop | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' -or "$($_.OperationalStatus)" -notmatch '^(OK|Completed)$' } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus; Operational = [string]($_.OperationalStatus -join ',') } }) } catch { $o.Notes += "VirtualDisk: $($_.Exception.Message)" }
        try { $o.PDiskUnhealthy = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus; Operational = [string]($_.OperationalStatus -join ','); Usage = [string]$_.Usage } }) } catch { $o.Notes += "PhysicalDisk: $($_.Exception.Message)" }
        try { $o.Subsystem = @(Get-StorageSubSystem -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus } }) } catch { $o.Notes += "Subsystem: $($_.Exception.Message)" }
        try {
            # IMPORTANT: on Azure Local / S2D with ReFS, CSVs run in FileSystemRedirected mode BY DESIGN
            # (FileSystemRedirectedIOReason = FileSystemReFs) - that is NORMAL and must NOT be flagged as
            # degraded. Only surface genuinely abnormal states: block redirection for a real reason,
            # file-system redirection for a NON-ReFS reason, or a paused / offline volume.
            $benignFsReasons = @('NotFileSystemRedirected', 'FileSystemReFs', '')
            $csvAbnormal = @(Get-ClusterSharedVolumeState -ErrorAction Stop |
                Where-Object {
                    $br = "$($_.BlockRedirectedIOReason)"
                    $fr = "$($_.FileSystemRedirectedIOReason)"
                    $si = "$($_.StateInfo)"
                    ($br -and $br -ne 'NotBlockRedirected') -or
                    ($fr -and ($benignFsReasons -notcontains $fr)) -or
                    ($si -match 'Paused|Offline')
                })
            # Collapse to ONE row per volume. Get-ClusterSharedVolumeState returns a row per volume PER
            # NODE, so a large cluster (e.g. 8 nodes x 40 volumes = 320 rows) would flood the table and a
            # single affected volume would repeat across every node. Group by volume and aggregate the
            # affected node(s) + distinct non-benign reasons so the table stays compact at any scale.
            $o.CsvRedirected = @($csvAbnormal | Group-Object VolumeFriendlyName | ForEach-Object {
                $g = $_.Group
                [pscustomobject]@{
                    Volume      = [string]$_.Name
                    Nodes       = (@($g | ForEach-Object { [string]$_.Node } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
                    State       = (@($g | ForEach-Object { [string]$_.StateInfo } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
                    BlockReason = (@($g | ForEach-Object { [string]$_.BlockRedirectedIOReason } | Where-Object { $_ -and $_ -ne 'NotBlockRedirected' } | Sort-Object -Unique) -join ', ')
                    FsReason    = (@($g | ForEach-Object { [string]$_.FileSystemRedirectedIOReason } | Where-Object { $_ -and ($benignFsReasons -notcontains $_) } | Sort-Object -Unique) -join ', ')
                }
            })
        } catch { $o.Notes += "CsvState: $($_.Exception.Message)" }
        [pscustomobject]$o
    }

    try {
        $local = $env:COMPUTERNAME
        if ($TargetNode -and ($TargetNode.Split('.')[0] -ne $local)) {
            $raw = Invoke-Command -ComputerName $TargetNode -ScriptBlock $scan -ErrorAction Stop
        } else {
            $raw = & $scan
        }
    } catch {
        return [pscustomobject]@{ Available = $false; Source = $TargetNode; Summary = 'Unavailable'; Note = $_.Exception.Message; StorageJobs = @(); VDiskUnhealthy = @(); PDiskUnhealthy = @(); Subsystem = @(); CsvRedirected = @() }
    }

    $degraded = (@($raw.VDiskUnhealthy).Count -gt 0) -or (@($raw.PDiskUnhealthy).Count -gt 0) -or
        (@($raw.CsvRedirected).Count -gt 0) -or (@($raw.Subsystem | Where-Object { "$($_.Health)" -eq 'Unhealthy' }).Count -gt 0)
    $summary = if (-not $raw.StorageModule) { 'Unavailable' } elseif ($degraded) { 'Degraded' } elseif (@($raw.StorageJobs).Count -gt 0) { 'Active storage jobs' } else { 'Healthy' }
    [pscustomobject]@{
        Available      = [bool]$raw.StorageModule
        Source         = [string]$raw.ComputerName
        Summary        = $summary
        StorageJobs    = @($raw.StorageJobs)
        VDiskUnhealthy = @($raw.VDiskUnhealthy)
        PDiskUnhealthy = @($raw.PDiskUnhealthy)
        Subsystem      = @($raw.Subsystem)
        CsvRedirected  = @($raw.CsvRedirected)
        Note           = ((@($raw.Notes)) -join '; ')
    }
}

# Historic cross-node event correlation. When a VM has orphaned .avhdx files, the ORIGINAL
# fork-commit / merge events that produced them may be far older than -EventLookbackHours (e.g. a
# rollback that happened days / weeks ago). This targeted, TIME-WINDOWED scan looks +/- WindowMinutes
# around each orphan's CREATION and LAST-WRITE timestamps, ACROSS EVERY CLUSTER NODE (the VM may have
# been owned by a
# different node at incident time), for events attributable to THIS VM that carry a fork-commit /
# merge signature. It also records each log's OLDEST available event so we can tell "no events found -
# window is covered" (meaningful) from "no events found - logs have WRAPPED past the window" (absence
# is NOT proof). Each node is reached in a SINGLE hop from the script's own session (no double hop);
# the query is narrow (a few short windows) so it stays cheap even weeks back. Read-only.
# v0.2.15: search around the orphan's CREATION time as well as its last-write time. The .avhdx layer
# is created at the moment of the checkpoint / fork-commit, but its last-write is stamped only later
# when the rollback / live-migration freezes it - and those two moments can be DAYS apart (the chain
# inconsistency lies dormant until a migration materialises it). Centring windows on last-write ALONE
# therefore misses the original fork-commit event; anchoring on BOTH timestamps captures both ends.
function Get-HistoricVMEventCorrelation {
    [OutputType([object])]
    param(
        [string]$VMName,
        [string]$VMId,
        [string[]]$Nodes,
        [datetime[]]$Timestamps,
        [int]$WindowMinutes = 60,
        [int[]]$SignatureIds,
        [string]$SignatureRx
    )
    # Collapse the orphan timestamps to distinct search windows (round DOWN to the hour) so many
    # orphans frozen at the same moment produce ONE window, not dozens. NOTE: build a fresh
    # hour-truncated DateTime (zeroing minutes/seconds AND milliseconds) - subtracting whole minutes /
    # seconds leaves the sub-second component intact, which defeats Sort-Object -Unique and produces
    # many near-identical windows.
    $hourWindows = @($Timestamps | Where-Object { $_ } | ForEach-Object {
            $u = $_.ToUniversalTime()
            [datetime]::new($u.Year, $u.Month, $u.Day, $u.Hour, 0, 0, [System.DateTimeKind]::Utc)
        } | Sort-Object -Unique)
    if ($hourWindows.Count -eq 0) { return $null }

    # v0.2.15: expand each distinct hour to a +/- WindowMinutes span, then MERGE overlapping / adjacent
    # spans into contiguous [Start,End] ranges and query each merged range ONCE. Two orphan clusters an
    # hour or two apart (whose +/- windows overlap) collapse into a single query instead of two. All
    # arithmetic is on UTC DateTimes, so a span that crosses midnight / month-end / year-end is handled
    # natively as ONE continuous range (e.g. a 00:30 anchor with a 120-min window searches from 22:30
    # the PREVIOUS day through 02:30). Windows are pre-sorted ascending, so a single left-to-right
    # merge suffices: extend the current range while the next span starts at or before its End.
    $ranges = [System.Collections.Generic.List[object]]::new()
    foreach ($w in ($hourWindows | Sort-Object)) {
        $s = $w.AddMinutes(-$WindowMinutes)
        $e = $w.AddMinutes($WindowMinutes)
        if ($ranges.Count -gt 0 -and $s -le $ranges[$ranges.Count - 1].End) {
            if ($e -gt $ranges[$ranges.Count - 1].End) { $ranges[$ranges.Count - 1].End = $e }
        } else {
            $ranges.Add([pscustomobject]@{ Start = $s; End = $e })
        }
    }

    $localNode = $env:COMPUTERNAME
    $scan = {
        param($vmName, $vmId, $ranges, $sigIds, $sigRx)
        $logs   = 'Microsoft-Windows-Hyper-V-Worker-Admin', 'Microsoft-Windows-Hyper-V-VMMS-Admin'
        $oldest = $null
        foreach ($lg in $logs) {
            try {
                $o = Get-WinEvent -LogName $lg -Oldest -MaxEvents 1 -ErrorAction Stop | Select-Object -First 1
                if ($o -and ((-not $oldest) -or ($o.TimeCreated -lt $oldest))) { $oldest = $o.TimeCreated }
            } catch { }
        }
        $hits = @()
        foreach ($r in $ranges) {
            $start = $r.Start; $end = $r.End
            try {
                Get-WinEvent -FilterHashtable @{ LogName = $logs; StartTime = $start; EndTime = $end } -ErrorAction SilentlyContinue |
                    Where-Object {
                        # Attributable to THIS VM (name or GUID) AND carrying a signature ID / HRESULT.
                        ((($vmName -and $_.Message -match [regex]::Escape($vmName)) -or ($vmId -and $_.Message -match [regex]::Escape($vmId)))) -and
                        (($sigIds -contains $_.Id) -or ($sigRx -and $_.Message -match $sigRx))
                    } | ForEach-Object {
                        $hits += [pscustomobject]@{
                            Node    = $env:COMPUTERNAME
                            Time    = $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
                            Id      = [int]$_.Id
                            Log     = if ($_.LogName -like '*Worker*') { 'Worker' } elseif ($_.LogName -like '*VMMS*') { 'VMMS' } else { [string]$_.LogName }
                            Message = ($_.Message -split "`r?`n")[0]
                        }
                    }
            } catch { }
        }
        [pscustomobject]@{ Node = $env:COMPUTERNAME; Oldest = $oldest; Matches = @($hits) }
    }

    $perNode = foreach ($node in @($Nodes | Where-Object { $_ } | Sort-Object -Unique)) {
        try {
            if ($node.Split('.')[0] -eq $localNode) {
                & $scan $VMName $VMId $ranges $SignatureIds $SignatureRx
            } else {
                Invoke-Command -ComputerName $node -ScriptBlock $scan -ArgumentList $VMName, $VMId, $ranges, $SignatureIds, $SignatureRx -ErrorAction Stop
            }
        } catch {
            [pscustomobject]@{ Node = $node; Oldest = $null; Matches = @(); Error = "$($_.Exception.Message)" }
        }
    }

    $allMatches = @($perNode | ForEach-Object { $_.Matches } | Where-Object { $_ } | Sort-Object Time)
    $oldestVals = @($perNode | ForEach-Object { $_.Oldest } | Where-Object { $_ } | Sort-Object)
    $oldestAll  = if ($oldestVals.Count -gt 0) { $oldestVals[0] } else { $null }
    # Earliest point actually searched = the Start of the first merged range (it already includes the
    # -WindowMinutes expansion), so LogsWrappedPastWindow compares against the true search floor.
    $earliestWindowStart = (@($ranges | Sort-Object Start)[0]).Start
    [pscustomobject]@{
        Windows            = @($ranges | Sort-Object Start | ForEach-Object { "{0} - {1} UTC" -f $_.Start.ToString('yyyy-MM-dd HH:mm'), $_.End.ToString('yyyy-MM-dd HH:mm') })
        WindowMinutes      = $WindowMinutes
        NodesSearched      = @($Nodes | Where-Object { $_ } | Sort-Object -Unique)
        Matches            = $allMatches
        MatchCount         = @($allMatches).Count
        OldestAvailableUtc = if ($oldestAll) { $oldestAll.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
        # If the oldest available event is AFTER our earliest search window, the logs have wrapped past
        # the incident and the original events are gone - so a nil result is inconclusive, not clean.
        LogsWrappedPastWindow = if ($oldestAll) { ($oldestAll.ToUniversalTime() -gt $earliestWindowStart) } else { $true }
    }
}

function Invoke-VMCheckpointAudit {
    [CmdletBinding()]
    param(
        [string]$VMName,
        [string]$Cluster,
        [string]$OutputPath,
        [int]$StaleHours,
        [switch]$SkipWorkerEvents,
        [int]$EventLookbackHours,
        [int[]]$WorkerEventIds,
        [int[]]$ContextEventIds,
        [string[]]$ErrorCodePatterns,
        [switch]$SkipAnalyticCheck
    )

    # Capture ALL console output for THIS VM into a buffer. The buffer is always active (so the HOLD
    # STATE support summary can be mined for the HTML even without -OutputPath); when -OutputPath is
    # supplied it is also written to a per-VM .txt at the end. The Write-Host proxy (see begin block)
    # both captures into this buffer and, in Quiet mode, withholds the detail lines from the console.
    $script:VMReportBuffer = [System.Collections.Generic.List[string]]::new()
    # v0.2.15: per-VM audit start time + per-section tracking for the performance telemetry. The section
    # timer is opened/closed by Show-AuditProgress; the total is recorded in the finally block. Reset
    # the section state here so a previous VM's open section can never leak into this VM.
    $vmAuditStart             = Get-TelemetryNow
    $script:VMSectionStartUtc = $null
    $script:VMSectionStepNo   = $null
    $script:VMSectionName     = $null
    $reportFile = $null
    if ($OutputPath) {
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        $safeName   = ($VMName -replace '[^\w.\-]', '_')
        # VM name FIRST in the file name so per-VM reports sort together alphabetically for humans.
        $reportFile = Join-Path $OutputPath ("{0}_VMAudit_{1}.txt" -f $safeName, [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
    }

    # Per-VM sub-progress (child of the "VM X of Y" bar). v0.2.15: each call also CLOSES the previous
    # section's telemetry timer (recording its accurate Start/End) and OPENS the new one; the last open
    # section is closed in the finally block. The Step number (passed explicitly, two-digit with gaps
    # of 5) appears in the telemetry JSON as 1.10.<Step> - it is STABLE across releases, so inserting a
    # new section later can use a gap without renumbering the others. Progress uses its own stream, so
    # it never pollutes the host report, the transcript, or the per-VM summary object.
    $script:VMSectionStep = 0
    function Show-AuditProgress {
        param([int]$Step, [string]$Status)
        # Close the previously-open section (its duration is now - its start).
        if ($null -ne $script:VMSectionStartUtc) {
            Add-TelemetryEntry -Step ('1.10.{0:00}' -f $script:VMSectionStepNo) -Phase $script:VMSectionName -Detail "$VMName [$script:CurrentVMSource]" -StartUtc $script:VMSectionStartUtc -EndUtc (Get-TelemetryNow)
        }
        # Open the new section.
        $script:VMSectionStepNo   = $Step
        $script:VMSectionName     = $Status
        $script:VMSectionStartUtc = Get-TelemetryNow
        # Progress bar (unchanged behaviour): auto-increment for a smooth 0-100% sweep.
        $script:VMSectionStep++
        $pct = [math]::Min(100, [int](($script:VMSectionStep / $script:VMSectionTotal) * 100))
        Write-Progress -Id 2 -ParentId 1 -Activity ("Auditing VM: {0}" -f $VMName) -Status $Status -PercentComplete $pct
    }

    # Owner execution context (set once the owning node is resolved, below). All data collection runs
    # through Invoke-OnOwner so we NEVER make a double hop: it runs the scriptblock locally when this
    # node owns the VM, or through a SINGLE remoting session to the owning node otherwise. Scriptblocks
    # MUST take their inputs via param()/-ArgumentList (NOT $using:) so the same block works both ways.
    $script:OwnerIsLocal = $true
    $script:OwnerSession = $null
    function Invoke-OnOwner {
        param(
            [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
            [object[]]$ArgumentList = @()
        )
        if ($script:OwnerIsLocal) {
            & $ScriptBlock @ArgumentList
        } else {
            Invoke-Command -Session $script:OwnerSession -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
        }
    }

    # Build the per-VM result object. Uses $VMName / $ClusterName / $reportFile from the enclosing
    # scope (any not yet resolved are $null). Returned to the end block, which emits it to the pipeline
    # only when -PassThru was supplied; otherwise it is captured and discarded so the pipeline stays clean.
    function New-AuditSummary {
        param(
            [string]$Recommendation          = 'OK',
            [bool]  $HoldState               = $false,
            [bool]  $HasAttachedCheckpoints  = $false,
            [bool]  $HasStaleCheckpoints     = $false,
            [bool]  $HasOrphanedCheckpoints  = $false,
            [int]   $AttachedCheckpointCount = 0,
            [int]   $StaleCheckpointCount    = 0,
            [int]   $ConcernEventCount       = 0,
            [string]$Owner                   = '',
            [string]$Detail                  = '',
            [object]$ReportData              = $null
        )
        [pscustomobject]@{
            VMName                  = $VMName
            Cluster                 = $ClusterName
            OwningNode              = $Owner
            Recommendation          = $Recommendation
            HoldState               = $HoldState
            HasAttachedCheckpoints  = $HasAttachedCheckpoints
            HasStaleCheckpoints     = $HasStaleCheckpoints
            HasOrphanedCheckpoints  = $HasOrphanedCheckpoints
            AttachedCheckpointCount = $AttachedCheckpointCount
            StaleCheckpointCount    = $StaleCheckpointCount
            ConcernEventCount       = $ConcernEventCount
            ReportFile              = $reportFile
            Detail                  = $Detail
            ReportData              = $ReportData
        }
    }

    try {

    Show-AuditProgress -Step 5 -Status 'Resolving cluster and VM'
    # Resolve the cluster once. With -Cluster we target that NAMED cluster (remote management from a
    # workstation with the RSAT Failover Clustering tools); without it, this host must itself BE a
    # cluster node - the Get-Cluster guard rail below fails clearly if it is not.
    # v0.2.14: the resolved name is cached for the whole run (Get-Cluster called once, not per VM).
    try {
        if ($script:ClusterNameCache) {
            $ClusterName = $script:ClusterNameCache
        } elseif ($Cluster) {
            $ClusterName = (Invoke-WithRetry { Get-Cluster -Name $Cluster -ErrorAction Stop }).Name
            $script:ClusterNameCache = $ClusterName
        } else {
            $ClusterName = (Invoke-WithRetry { Get-Cluster -ErrorAction Stop }).Name
            $script:ClusterNameCache = $ClusterName
        }
    } catch {
        if ($Cluster) {
            Write-Alert "  ERROR: could not reach cluster '$Cluster': $($_.Exception.Message)" -Level Critical
            Write-Alert "  Check the name, that the RSAT 'Failover Clustering' tools are installed, and that you have rights to it." -Level Critical
        } else {
            Write-Alert "  ERROR: this host is not a cluster node, or the Cluster service is not running: $($_.Exception.Message)" -Level Critical
            Write-Alert "  Run this script ON a cluster node, or from a management host using -Cluster <ClusterName>." -Level Critical
        }
        return (New-AuditSummary -Recommendation 'ERROR' -Detail 'Cluster could not be resolved (see console).')
    }

    # --- Resolve the VM's OWNING NODE without relying on double-hop authentication ------------------
    # This script is designed to run either locally on a cluster node (interactive / SConfig logon) or
    # via a SINGLE PowerShell Remoting hop into one node. To avoid a second ("double") hop we (1) find
    # the cluster nodes and the VM's owning node using the cluster API (RPC - no WinRM), then (2) run
    # every data-collection command in the OWNER CONTEXT: directly (locally) when this node owns the
    # VM, otherwise through ONE remoting session to the owning node (see Invoke-OnOwner above).
    $LocalNode    = $env:COMPUTERNAME
    # v0.2.14: cluster node list fetched once per run (Get-ClusterNode), reused for every VM.
    if ($null -eq $script:ClusterNodesCache) {
        try {
            $script:ClusterNodesCache = @(Invoke-WithRetry { Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop } | ForEach-Object { [string]$_.Name })
        } catch {
            $script:ClusterNodesCache = @()
            Write-Alert "  Could not enumerate cluster nodes (after retries): $($_.Exception.Message)" -Level Warning
        }
    }
    $clusterNodes = $script:ClusterNodesCache

    # (1a) Preferred: the VM's clustered role names the owner directly (cluster API - no hop).
    # v0.2.14: build the VMName -> OwnerNode map ONCE per run (a single Get-ClusterGroup for the whole
    # cluster) instead of re-querying and filtering per VM - a large saving on big fleets. The hashtable
    # is case-insensitive (PowerShell default), matching the previous -eq name comparison.
    if ($null -eq $script:GroupOwnerByVm) {
        $script:GroupOwnerByVm = @{}
        $allClusterGroups = @()
        try { $allClusterGroups = @(Invoke-WithRetry { Get-ClusterGroup -Cluster $ClusterName -ErrorAction Stop }) }
        catch { Write-Alert "  Could not enumerate cluster groups (after retries): $($_.Exception.Message)" -Level Warning }
        foreach ($g in $allClusterGroups) {
            if ($g -and $g.Name -and -not $script:GroupOwnerByVm.ContainsKey([string]$g.Name)) {
                $script:GroupOwnerByVm[[string]$g.Name] = [string]$g.OwnerNode.Name
            }
        }
    }
    $OwningNode = $null
    if ($script:GroupOwnerByVm.ContainsKey($VMName)) { $OwningNode = [string]$script:GroupOwnerByVm[$VMName] }

    # (1b) Fallback (non-clustered VM, or a role whose name differs from the VM name): consult a
    # cluster-wide VMName -> node map built ONCE by asking each node LOCALLY for its full VM list (one
    # single hop per node, per run - not per VM). Each probe is a single hop (or local) - never double.
    if (-not $OwningNode) {
        if ($null -eq $script:ProbeVmNodeMap) {
            $script:ProbeVmNodeMap = @{}
            $probeNodes = if ($clusterNodes.Count -gt 0) { $clusterNodes } else { @($LocalNode) }
            foreach ($node in $probeNodes) {
                try {
                    if ($node.Split('.')[0] -eq $LocalNode) {
                        $names = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
                    } else {
                        $names = @(Invoke-Command -ComputerName $node -ScriptBlock {
                            Get-VM -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name }
                        } -ErrorAction Stop)
                    }
                    foreach ($vmn in $names) {
                        if ($vmn -and -not $script:ProbeVmNodeMap.ContainsKey($vmn)) { $script:ProbeVmNodeMap[$vmn] = $node }
                    }
                } catch {
                    # Could not reach this node in a single hop - keep building from the others.
                }
            }
        }
        if ($script:ProbeVmNodeMap.ContainsKey($VMName)) { $OwningNode = [string]$script:ProbeVmNodeMap[$VMName] }
    }

    if (-not $OwningNode) {
        Write-Host "VM '$VMName' not found on any node of cluster '$ClusterName'."
        return (New-AuditSummary -Recommendation 'NOT FOUND' -Detail 'VM not found on any cluster node.')
    }

    # (2) Establish the owner execution context: local when this node owns the VM (zero hops), else ONE
    # remoting session to the owning node. Every subsequent collection call goes through Invoke-OnOwner.
    # v0.2.14: sessions are POOLED per owning node ($script:SessionByNode) and reused across every VM
    # on that node - so a node with 40 VMs opens ONE session, not 40. A pooled session that is no
    # longer 'Opened' (dropped/broken) is discarded and reopened. All pooled sessions are disposed
    # together in the end block.
    $script:OwnerIsLocal = ($OwningNode.Split('.')[0] -eq $LocalNode)
    $script:OwnerSession = $null
    if (-not $script:OwnerIsLocal) {
        $pooled = $script:SessionByNode[$OwningNode]
        if ($pooled -and $pooled.State -ne 'Opened') {
            Remove-PSSession -Session $pooled -ErrorAction SilentlyContinue
            $script:SessionByNode.Remove($OwningNode)
            $pooled = $null
        }
        if (-not $pooled) {
            try {
                $pooled = Invoke-WithRetry { New-PSSession -ComputerName $OwningNode -ErrorAction Stop }
                $script:SessionByNode[$OwningNode] = $pooled
            } catch {
                Write-Alert "  ERROR: could not open a remoting session to owning node '$OwningNode': $($_.Exception.Message)" -Level Critical
                Write-Alert "  TIP: run this script directly ON the owning node (interactive / SConfig logon), or from a" -Level Critical
                Write-Alert "       host that can reach it in a SINGLE hop. Reaching another node from inside a remoting" -Level Critical
                Write-Alert "       session is a 'double hop' and is blocked unless CredSSP/delegation is configured." -Level Critical
                return (New-AuditSummary -Recommendation 'ERROR' -Owner $OwningNode -Detail 'Could not open remoting session to owning node.')
            }
        }
        $script:OwnerSession = $pooled
    }

    # Core VM properties, collected in the owner context as plain values (safe to render / serialize).
    # Also gathers the Hyper-V host's supported VM configuration versions (Get-VMHostSupportedVersion,
    # read-only) so we can compare the VM's version to the latest the owning node supports.
    # v0.2.14: the host's supported-version list is identical for every VM on a node, so it is fetched
    # ONCE per node ($script:HostVersionsByNode) and reused, rather than queried inside every VM scan.
    if (-not $script:HostVersionsByNode.ContainsKey($OwningNode)) {
        $script:HostVersionsByNode[$OwningNode] = @(Invoke-OnOwner -ScriptBlock {
            Get-VMHostSupportedVersion -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Version }
        })
    }
    $hostSupportedVersions = @($script:HostVersionsByNode[$OwningNode])

    $vm = Invoke-OnOwner -ScriptBlock {
        param($n)
        $v = Get-VM -Name $n -ErrorAction SilentlyContinue
        if (-not $v) { return $null }
        [pscustomobject]@{
            VMId                        = [string]$v.VMId
            Status                      = [string]$v.Status
            State                       = [string]$v.State
            Uptime                      = [string]$v.Uptime
            AutomaticCheckpointsEnabled = [bool]$v.AutomaticCheckpointsEnabled
            CheckpointType              = [string]$v.CheckpointType
            ConfigurationLocation       = [string]$v.ConfigurationLocation
            ReplicationState            = [string]$v.ReplicationState
            Version                     = [string]$v.Version
        }
    } -ArgumentList $VMName
    if (-not $vm) {
        Write-Host "VM '$VMName' could not be read on owning node '$OwningNode'."
        return (New-AuditSummary -Recommendation 'ERROR' -Owner $OwningNode -Detail 'VM object could not be read on the owning node.')
    }
    # Attach the (cached) per-node supported-version list to the VM projection so downstream code that
    # reads $vm.HostSupportedVersions is unchanged.
    Add-Member -InputObject $vm -NotePropertyName HostSupportedVersions -NotePropertyValue $hostSupportedVersions -Force

    # Compare the VM's configuration version to the latest the owning node supports
    # (Get-VMHostSupportedVersion). A VM older than the latest can be upgraded (Update-VMVersion) and,
    # in a mixed-version cluster, a version mismatch can block live migration. NOTE: an older config
    # version is NOT a stated cause of the checkpoint/merge failure - see the dedicated section below.
    $hostVerParsed = @($vm.HostSupportedVersions | Where-Object { $_ } | ForEach-Object { $p = $null; if ([version]::TryParse($_, [ref]$p)) { $p } })
    $hostMaxVer    = if ($hostVerParsed.Count -gt 0) { (@($hostVerParsed | Sort-Object -Descending)[0]).ToString() } else { $null }
    $vmVerOlder    = $false
    $vmVerParsed   = $null
    if ($hostMaxVer -and [version]::TryParse("$($vm.Version)", [ref]$vmVerParsed) -and ($vmVerParsed -lt [version]$hostMaxVer)) {
        $vmVerOlder = $true
    }

    # Report header: VM name, owning node, and when this audit was run. Labels are padded to a common
    # width so every field's colon lines up (the widest label is 'Latest supported by cluster').
    Write-Host "==================================================================="
    Write-Section "  VM CheckPoint (Differencing Disk) Audit"
    Write-Host ("  {0,-27} : {1}" -f 'Cluster', $ClusterName)
    Write-Host ("  {0,-27} : {1}" -f 'VM Name', $VMName)
    Write-Host ("  {0,-27} : {1}" -f 'VM Id', $vm.VMId)
    Write-Host ("  {0,-27} : {1}" -f 'Owning Node', $OwningNode)
    # Colour the VM Status: 'Operating normally' = green, Critical/Error/Failed = red, else amber.
    $statusLevel = switch -Wildcard ("$($vm.Status)") { 'Operating normally' { 'Good'; break } '*Critical*' { 'Critical'; break } '*Error*' { 'Critical'; break } '*Fail*' { 'Critical'; break } default { 'Warning' } }
    Write-Alert ("  {0,-27} : {1}" -f 'VM Status', $vm.Status) -Level $statusLevel
    # Colour the VM State: Running = green, anything containing 'Critical' = red, else amber.
    $stateLevel = switch -Wildcard ("$($vm.State)") { 'Running' { 'Good' } '*Critical*' { 'Critical' } default { 'Warning' } }
    Write-Alert ("  {0,-27} : {1}" -f 'VM State', $vm.State) -Level $stateLevel
    Write-Host ("  {0,-27} : {1}" -f 'VM Config Version', $vm.Version)
    Write-Host ("  {0,-27} : {1}" -f 'Latest supported by cluster', $(if ($hostMaxVer) { $hostMaxVer } else { 'unknown' }))
    Write-Host ("  {0,-27} : {1}" -f 'Uptime', $vm.Uptime)
    # Auto Checkpoints: when True, Hyper-V takes a checkpoint automatically every time the VM STARTS
    # (a Client Hyper-V default; normally False on servers/clusters) - a source of 'unexpected' .avhdx
    # layers. Checkpoint Type is the style of checkpoint the VM is configured to take, which governs
    # how each checkpoint's fork is committed (the failure mode under investigation). Values annotated.
    $autoCkptNote = if ($vm.AutomaticCheckpointsEnabled) { 'auto checkpoint taken at every VM start' } else { 'no automatic checkpoint at VM start' }
    Write-Host ("  {0,-27} : {1} ({2})" -f 'Auto Checkpoints', $vm.AutomaticCheckpointsEnabled, $autoCkptNote)
    $ckptTypeNote = switch ("$($vm.CheckpointType)") {
        'Production'     { 'app-consistent via in-guest VSS; falls back to Standard if VSS is unavailable' }
        'ProductionOnly' { 'app-consistent via in-guest VSS; FAILS if VSS is unavailable (no fallback)' }
        'Standard'       { 'captures saved memory / running state (dev/test style)' }
        'Disabled'       { 'checkpoints are not allowed on this VM' }
        default          { '' }
    }
    if ($ckptTypeNote) {
        Write-Host ("  {0,-27} : {1} ({2})" -f 'Checkpoint Type', $vm.CheckpointType, $ckptTypeNote)
    } else {
        Write-Host ("  {0,-27} : {1}" -f 'Checkpoint Type', $vm.CheckpointType)
    }
    Write-Host ("  {0,-27} : {1} hours (flagged as 'YES')" -f 'Stale >=', $StaleHours)
    Write-Host ("  {0,-27} : {1} UTC" -f 'Report Generated', [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host "==================================================================="

    # Clustered role state / current owner (should match the Owning Node above):
    Show-AuditProgress -Step 10 -Status 'Reading cluster role'
    Write-Section "Cluster Role (Get-ClusterGroup):"
    $group = Get-ClusterGroup -Cluster $ClusterName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $VMName }
    if ($group) {
        $group | Format-Table Name, State, OwnerNode -AutoSize | Out-Indented
    } else {
        Write-Host "  No clustered role named '$VMName' found (the VM may be non-clustered)."
        Write-Host ""
    }

    # VM configuration file (.vmcx) - the failure mode hinges on stale on-disk chain metadata that
    # lives in this file, so its path and last-write time are worth surfacing (a recently rewritten
    # config - e.g. right after a fork-commit revert or a migration - is a useful signal).
    $vmcxPath = Join-Path $vm.ConfigurationLocation ("Virtual Machines\{0}.vmcx" -f $vm.VMId)
    Show-AuditProgress -Step 15 -Status 'Reading VM configuration (.vmcx)'
    Write-Section "VM Configuration (.vmcx):"
    try {
        $vmcxInfo = Invoke-OnOwner -ScriptBlock {
            param($path)
            $f = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($f) { [pscustomobject]@{ FullName = [string]$f.FullName; LastWriteTimeUtc = $f.LastWriteTimeUtc } }
        } -ArgumentList $vmcxPath
    } catch {
        $vmcxInfo = $null
        Write-Alert "  Could not read the .vmcx on '$OwningNode': $($_.Exception.Message)" -Level Warning
    }
    if ($vmcxInfo) {
        Write-Host ("  Path           : {0}" -f $vmcxInfo.FullName)
        Write-Host ("  LastWrite (UTC): {0}" -f $vmcxInfo.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Host ("  Age (hrs)      : {0}" -f [math]::Round(([DateTime]::UtcNow - $vmcxInfo.LastWriteTimeUtc).TotalHours, 1))
    } else {
        Write-Host ("  Config file not found at expected path (older .xml format?): {0}" -f $vmcxPath)
    }
    Write-Host ""

    # Track every VHD path we touch, so we can later spot orphaned .avhdx files on disk:
    $allChainPaths = [System.Collections.Generic.List[string]]::new()
    # Set true if the orphan scan below finds any .avhdx not part of an attached chain (feeds -PassThru).
    $hasOrphans = $false
    # Orphaned .avhdx rows found by the scan below (initialised here so the HTML data build can read it
    # even when no VHD folders were resolved to scan).
    $orphans = @()
    # Cluster Shared Volume rows hosting this VM's disks (captured for the HTML report; see below).
    $csvReport = @()
    # Hyper-V Replica object for this VM (null unless replication is enabled; read by the HTML build).
    $replInfo = $null
    # Nodes whose Hyper-V-VMMS/Analytic channel is NOT actively enabled (disabled, or 'not found').
    # Populated by the Analytic section below and surfaced as a TIP in the RESULT block so the operator
    # can choose to enable it for extra diagnostic detail on the NEXT occurrence (it is easily missed
    # mid-report). Stays empty when -SkipAnalyticCheck is used, so no TIP is shown in that case.
    $analyticNodesNeedEnable = @()

    # Enumerate each attached disk and resolve its full differencing chain (top .avhdx -> ... -> base).
    # This runs in ONE owner-context call (single hop for a remote owner) and flattens the VhdType enum
    # to a string on the owner, so the downstream 'Differencing' comparisons are robust after transport.
    Show-AuditProgress -Step 20 -Status 'Enumerating attached disks and differencing chains'
    $diskReports = [System.Collections.Generic.List[object]]::new()
    $rawDisks = @(Invoke-OnOwner -ScriptBlock {
        param($n)
        $vmObj  = Get-VM -Name $n -ErrorAction SilentlyContinue
        $result = @()
        foreach ($disk in (Get-VMHardDiskDrive -VM $vmObj -ErrorAction SilentlyContinue)) {
            $chain = @()
            $p = $disk.Path
            while ($p) {
                $v = $null
                try { $v = Get-VHD -Path $p -ErrorAction Stop } catch { break }
                # Size + timestamps are filesystem metadata (not on the Get-VHD object), so read the file
                # itself. If that read fails, fall back to Get-VHD's FileSize and leave timestamps null.
                $file = $null
                try { $file = Get-Item -LiteralPath $p -ErrorAction Stop } catch { }
                $chain += [pscustomobject]@{
                    Path      = [string]$v.Path
                    Type      = [string]$v.VhdType
                    SizeGB    = if ($file) { [math]::Round($file.Length / 1GB, 2) } else { [math]::Round(($v.FileSize) / 1GB, 2) }
                    Created   = if ($file) { $file.CreationTimeUtc }  else { $null }
                    LastWrite = if ($file) { $file.LastWriteTimeUtc } else { $null }
                }
                $p = $v.ParentPath
            }
            $result += [pscustomobject]@{
                Attached = Split-Path $disk.Path -Leaf
                Path     = [string]$disk.Path
                Chain    = @($chain)
            }
        }
        $result
    } -ArgumentList $VMName)

    foreach ($rd in $rawDisks) {
        $chain = @($rd.Chain)
        foreach ($layer in $chain) { $allChainPaths.Add([string]$layer.Path) }
        if ($chain.Count -eq 0) {
            # Could not read even the attached disk - record a minimal entry so it still appears.
            $diskReports.Add([pscustomobject]@{
                Attached = $rd.Attached; Path = $rd.Path; TopType = 'Unknown'
                SizeGB = $null; ChainDepth = 0; CheckpointCount = 0; AnyStale = $false; Chain = $chain
            })
            continue
        }
        $diskReports.Add([pscustomobject]@{
            Attached        = $rd.Attached
            Path            = $rd.Path
            TopType         = $chain[0].Type
            SizeGB          = [math]::Round((($chain | Where-Object { $null -ne $_.SizeGB } | Measure-Object -Property SizeGB -Sum).Sum), 2)
            ChainDepth      = $chain.Count
            # A Differencing (.avhdx) layer == an active checkpoint; the final Dynamic/Fixed disk is the base.
            # NOTE: the @() wrapper is REQUIRED - in Windows PowerShell 5.1 a bare (pipeline).Count returns
            # $null when EXACTLY ONE item matches (the common single-checkpoint case), which silently
            # zeroed this count and made the summary wrongly report 'No CheckPoint AVHDX disks'.
            CheckpointCount = @($chain | Where-Object { $_.Type -eq 'Differencing' }).Count
            # Stale applies to DIFFERENCING (.avhdx) layers only - a base (Fixed/Dynamic) disk legitimately
            # has an old timestamp and must NOT be flagged stale (that was a false alarm).
            AnyStale        = (@($chain | Where-Object { $_.Type -eq 'Differencing' -and $_.LastWrite -and ([DateTime]::UtcNow - $_.LastWrite).TotalHours -ge $StaleHours }).Count -gt 0)
            Chain           = $chain
        })
    }

    # (a) Overview - one compact row per attached disk (short columns, never wraps). ChainSizeGB is
    # the TOTAL of every layer in the chain (active .avhdx + any checkpoints + base), NOT the size of
    # the single attached file - the per-layer sizes are broken out under 'Differencing Chains' below.
    Write-Section "Attached Disks ($($diskReports.Count)):"
    $diskReports | Select-Object `
        Attached,
        @{N='Type';E={ $_.TopType }},
        @{N='ChainSizeGB';E={ $_.SizeGB }},
        ChainDepth,
        CheckpointCount,
        @{N='Stale';E={ if ($_.CheckpointCount -gt 0) { if ($_.AnyStale) { 'YES' } else { 'NO' } } else { 'n/a' } }} | Format-Table -AutoSize | Out-Indented

    # (b) Per-disk detail - one labelled block per disk so the full path is never truncated or
    # column-wrapped, including the attached (top-of-chain) disk's size, timestamps, age and stale flag:
    Write-Section "Attached Disk Detail:"
    $diskIndex = 0
    foreach ($d in $diskReports) {
        $diskIndex++
        Write-Host ("  Disk {0} of {1}" -f $diskIndex, $diskReports.Count)
        Write-Host ("  Disk File Name : {0}" -f $d.Attached)
        Write-Host ("  Disk Full Path : {0}" -f $d.Path)
        Write-Host ("  Type           : {0}" -f $d.TopType)
        $top = if ($d.Chain.Count -gt 0) { $d.Chain[0] } else { $null }
        if ($top) {
            Write-Host ("  This Disk (GB) : {0}" -f $top.SizeGB)
        }
        Write-Host ("  Chain Size (GB): {0} (total across all {1} layer(s))" -f $d.SizeGB, $d.ChainDepth)
        if ($top -and $top.Created) {
            Write-Host ("  Created (UTC)  : {0}" -f $top.Created.ToString('yyyy-MM-dd HH:mm:ss'))
        } else {
            Write-Host "  Created (UTC)  : (unavailable)"
        }
        if ($top -and $top.LastWrite) {
            $topAge = [math]::Round(([DateTime]::UtcNow - $top.LastWrite).TotalHours, 1)
            Write-Host ("  LastWrite (UTC): {0}" -f $top.LastWrite.ToString('yyyy-MM-dd HH:mm:ss'))
            Write-Host ("  Age (hrs)      : {0}  (hours since last write; ~0 = active / in-use)" -f $topAge)
            # Stale only applies to a DIFFERENCING (.avhdx) layer; a base disk's old timestamp is normal.
            $topStale = if ($top.Type -eq 'Differencing') { if ($topAge -ge $StaleHours) { 'YES' } else { 'NO' } } else { 'n/a (base disk)' }
            Write-Host ("  Stale          : {0}" -f $topStale)
        } else {
            Write-Host "  LastWrite (UTC): (unavailable)"
        }
        Write-Host ""
    }

    # (c) Differencing-chain detail - ONLY for disks that actually have a checkpoint layer
    # (ChainDepth > 1). Depth-1 disks add nothing here, so they are omitted to keep the report short.
    $deepDisks = @($diskReports | Where-Object { $_.ChainDepth -gt 1 })
    if ($deepDisks.Count -gt 0) {
        Write-Section "Differencing Chains (disks with a checkpoint layer):"
        foreach ($d in $deepDisks) {
            Write-Host "  $($d.Attached):"
            Write-Host "  Level 0 = the ACTIVE disk the VM writes to (child); each level's parent is the"
            Write-Host "  level below it; the highest level is the BASE. Chains can be many layers deep."
            Write-Host "  Age (hrs) = hours since that layer was last written (0 = written within the hour;"
            Write-Host "  the active top layer is normally ~0 because the VM is writing to it right now)."
            # Project the chain with an explicit Level (0 = active top) and Role so the parent -> child
            # hierarchy and total depth are unambiguous. SizeGB here is each LAYER's own size.
            $chainRows = for ($li = 0; $li -lt $d.Chain.Count; $li++) {
                $c = $d.Chain[$li]
                $role = if ($c.Type -eq 'Differencing') { if ($li -eq 0) { 'Active (top)' } else { 'Checkpoint' } } else { 'Base' }
                [pscustomobject]@{
                    Level             = $li
                    Role              = $role
                    'VHD File Name'   = Split-Path $c.Path -Leaf
                    Type              = $c.Type
                    SizeGB            = $c.SizeGB
                    'LastWrite (UTC)' = if ($c.LastWrite) { $c.LastWrite.ToString('yyyy-MM-dd HH:mm:ss') } else { '(unavailable)' }
                    'Age (hrs)'       = if ($c.LastWrite) { [math]::Round(([DateTime]::UtcNow - $c.LastWrite).TotalHours, 1) } else { $null }
                    # Only DIFFERENCING (.avhdx) layers can be 'stale'. A Base disk's old timestamp is
                    # expected and healthy, so it shows 'n/a' rather than YES/NO.
                    Stale             = if ($c.Type -ne 'Differencing') { 'n/a' } elseif ($c.LastWrite -and ([DateTime]::UtcNow - $c.LastWrite).TotalHours -ge $StaleHours) { 'YES' } else { 'NO' }
                }
            }
            $chainRows | Format-Table Level, Role, 'VHD File Name', Type, SizeGB, 'LastWrite (UTC)', 'Age (hrs)', Stale -AutoSize | Out-Indented
        }
    } else {
        Write-Section "Differencing Chains: none (no attached disk has a checkpoint layer)."
        Write-Host ""
    }

    # Cluster Shared Volume free space - scoped to the volume(s) that actually host this VM's disks
    # (a stuck merge is often blocked by low free space on the hosting volume). Falls back to all
    # cluster volumes if this VM's disks cannot be matched to a mount point.
    Show-AuditProgress -Step 25 -Status 'Checking Cluster Shared Volume free space'
    Write-Section "Cluster Shared Volume Free Space (hosting this VM's disks):"
    try {
        $diskFolders = @($allChainPaths | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique)
        # v0.2.14: the cluster's CSV list is identical for every VM, so fetch it ONCE per run and reuse
        # the cached snapshot (a point-in-time free-space reading, which is all a report needs).
        if ($null -eq $script:ClusterCsvCache) {
            $script:ClusterCsvCache = @(Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction Stop)
        }
        $allCsv = $script:ClusterCsvCache
        $relevantCsv = $allCsv | Where-Object {
            $mount = [string]$_.SharedVolumeInfo.FriendlyVolumeName
            $mount -and (@($diskFolders | Where-Object { $_.StartsWith($mount, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0)
        }
        if (-not $relevantCsv) {
            Write-Host "  (Could not match this VM's disks to a specific volume - showing all cluster volumes.)"
            $relevantCsv = $allCsv
        }
        $relevantCsv | ForEach-Object {
            $part = $_.SharedVolumeInfo.Partition
            [pscustomobject]@{
                Volume     = $_.Name
                MountPoint = $_.SharedVolumeInfo.FriendlyVolumeName
                SizeGB     = [math]::Round($part.Size / 1GB, 2)
                FreeGB     = [math]::Round($part.FreeSpace / 1GB, 2)
                'Free %'   = [math]::Round(($part.FreeSpace / $part.Size) * 100, 1)
            }
        } | Format-Table -AutoSize | Out-Indented
        # Capture the same projection for the HTML fleet report (a separate pass so the console table
        # above is unchanged). Errors here are non-fatal - the HTML simply omits the CSV rows.
        $csvReport = @($relevantCsv | ForEach-Object {
            $p = $_.SharedVolumeInfo.Partition
            [pscustomobject]@{
                Volume     = [string]$_.Name
                MountPoint = [string]$_.SharedVolumeInfo.FriendlyVolumeName
                SizeGB     = [math]::Round($p.Size / 1GB, 2)
                FreeGB     = [math]::Round($p.FreeSpace / 1GB, 2)
                FreePct    = [math]::Round(($p.FreeSpace / $p.Size) * 100, 1)
            }
        })
    } catch {
        Write-Host "  Could not query Cluster Shared Volumes: $($_.Exception.Message)"
        Write-Host ""
    }

    # Named checkpoints on the VM - maps .avhdx files to checkpoints such as 'Initial Replica'.
    # Collected in the owner context (single hop for a remote owner), including each checkpoint's disk
    # folders so the orphan / .hrl scans below know where to look.
    Show-AuditProgress -Step 30 -Status 'Enumerating checkpoints'
    Write-Section "Checkpoints (Get-VMSnapshot):"
    $ckptData = Invoke-OnOwner -ScriptBlock {
        param($n)
        $snaps   = Get-VMSnapshot -VMName $n -ErrorAction SilentlyContinue
        $rows    = @()
        $folders = @()
        foreach ($s in $snaps) {
            $snapType = if ($s.PSObject.Properties['SnapshotType']) { [string]$s.SnapshotType } elseif ($s.PSObject.Properties['CheckpointType']) { [string]$s.CheckpointType } else { '' }
            $typeVal  = if ($s.PSObject.Properties['CheckpointType']) { [string]$s.CheckpointType } else { [string]$s.SnapshotType }
            $parent   = if ($s.PSObject.Properties['ParentCheckpointName']) { [string]$s.ParentCheckpointName } else { [string]$s.ParentSnapshotName }
            $rows += [pscustomobject]@{
                Name            = [string]$s.Name
                Type            = $typeVal
                SnapType        = $snapType
                CreationTimeUtc = $s.CreationTime.ToUniversalTime()
                Parent          = $parent
            }
            foreach ($hd in (Get-VMHardDiskDrive -VMSnapshot $s -ErrorAction SilentlyContinue)) {
                if ($hd.Path) { $folders += (Split-Path $hd.Path -Parent) }
            }
        }
        [pscustomobject]@{ Rows = @($rows); Folders = @($folders) }
    } -ArgumentList $VMName

    $checkpoints = @($ckptData.Rows)
    if ($checkpoints.Count -gt 0) {
        $checkpoints | Sort-Object CreationTimeUtc | Format-Table -AutoSize `
            Name,
            @{N='Type';E={ $_.Type }},
            @{N='Purpose';E={
                switch -Wildcard ("$($_.SnapType)") {
                    'AppConsistent*' { 'Replica recovery point (app-consistent)'; break }
                    'Synced*'        { 'Replica synced checkpoint';                break }
                    '*Replica*'      { 'Hyper-V Replica checkpoint';               break }
                    'Recovery'       { 'Replica recovery point';                   break }
                    'Planned'        { 'Planned failover checkpoint';              break }
                    'Production*'    { 'Production checkpoint (backup)';           break }
                    'Standard'       { 'Standard checkpoint (manual/backup)';      break }
                    default          { if ($_.SnapType) { $_.SnapType } else { 'Unknown' } }
                }
            }},
            @{N='Created (UTC)';E={ $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }},
            @{N='Age (hrs)';E={ [math]::Round(([DateTime]::UtcNow - $_.CreationTimeUtc).TotalHours, 1) }},
            @{N='Stale';E={ if (([DateTime]::UtcNow - $_.CreationTimeUtc).TotalHours -ge $StaleHours) { 'YES' } else { 'NO' } }},
            @{N='Parent';E={ $_.Parent }} | Out-Indented
    } else {
        Write-Host "  No checkpoints present on '$VMName'."
        Write-Host ""
    }

    # Collect every folder holding one of this VM's VHDs - the attached chain AND any checkpoint disks -
    # so we scan all relevant locations. There is no separate HRL path setting in Hyper-V Replica: the
    # .hrl log always sits next to the VHD it protects.
    $folderSet = [System.Collections.Generic.List[string]]::new()
    $allChainPaths | ForEach-Object { $folderSet.Add((Split-Path $_ -Parent)) }
    foreach ($f in @($ckptData.Folders)) { if ($f) { $folderSet.Add([string]$f) } }
    $vhdFolders = @($folderSet | Sort-Object -Unique)

    # Orphaned differencing disks: .avhdx files on disk that are NOT part of any attached chain
    # (a stuck/failed merge or a leftover replica recovery point can leave these behind):
    Show-AuditProgress -Step 35 -Status 'Scanning for orphaned .avhdx files'
    Write-Section "Orphaned .avhdx Files (present on disk but not attached to the VM):"
    if ($vhdFolders) {
        try {
            $onDiskAvhdx = @(Invoke-OnOwner -ScriptBlock {
                param($folders)
                $folders | ForEach-Object {
                    Get-ChildItem -LiteralPath $_ -Filter '*.avhdx' -File -ErrorAction SilentlyContinue
                } | ForEach-Object {
                    [pscustomobject]@{ Name = [string]$_.Name; FullName = [string]$_.FullName; Length = [long]$_.Length; CreationTimeUtc = $_.CreationTimeUtc; LastWriteTimeUtc = $_.LastWriteTimeUtc }
                }
            } -ArgumentList (,$vhdFolders))
        } catch {
            $onDiskAvhdx = $null
            Write-Alert "  Could not scan for .avhdx files on '$OwningNode': $($_.Exception.Message)" -Level Warning
        }
        $attachedSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$allChainPaths, [System.StringComparer]::OrdinalIgnoreCase)
        $orphans = @($onDiskAvhdx | Where-Object { $_ -and -not $attachedSet.Contains([string]$_.FullName) })
        $hasOrphans = ($orphans.Count -gt 0)
        if ($orphans.Count -gt 0) {
            Write-Alert ("  {0} orphaned .avhdx file(s) found (present on disk but NOT part of any attached chain):" -f $orphans.Count) -Level Warning
            $orphans | Sort-Object LastWriteTimeUtc -Descending | Select-Object `
                @{N='File Name';E={ $_.Name }},
                @{N='SizeGB';E={ [math]::Round($_.Length / 1GB, 2) }},
                @{N='Created (UTC)';E={ if ($_.CreationTimeUtc)  { $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }  else { '(unavailable)' } }},
                @{N='LastWrite (UTC)';E={ if ($_.LastWriteTimeUtc) { $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') } else { '(unavailable)' } }},
                FullName | Format-Table -AutoSize -Wrap | Out-Indented
            Write-Host  "  These are NOT attached to the VM - a stuck / failed merge or a leftover initial Hyper-V Replica"
            Write-Host  "  checkpoint can leave these behind under specific scenarios. Confirm with your backup team before"
            Write-Host  "  removing any (do not delete blindly). Open a Microsoft CSS case for guidance if required."
        } else {
            Write-Host "  None found - every .avhdx in the VM's folders is part of an attached chain."
            Write-Host ""
        }
    } else {
        Write-Host "  No VHD folders resolved to scan."
        Write-Host ""
    }

    # Replication health: on the PRIMARY, ongoing replication is tracked in .hrl logs (see below),
    # while the REPLICA stores recovery points as .avhdx checkpoints. A stalled initial replication
    # or a backlogged log can keep these artifacts around and inflate disk usage.
    Show-AuditProgress -Step 40 -Status 'Checking Hyper-V Replica status'
    Write-Section "Hyper-V Replica (HVR) Status:"
    if ($vm.ReplicationState -ne 'Disabled') {
        $replInfo = Invoke-OnOwner -ScriptBlock {
            param($n)
            $r = Get-VMReplication -VMName $n -ErrorAction SilentlyContinue
            $m = Measure-VMReplication -VMName $n -ErrorAction SilentlyContinue
            [pscustomobject]@{
                Repl = if ($r) { [pscustomobject]@{
                    Name                        = [string]$r.Name
                    State                       = [string]$r.State
                    Health                      = [string]$r.Health
                    Mode                        = [string]$r.Mode
                    ReplicationRelationshipType = [string]$r.ReplicationRelationshipType
                    PrimaryServerName           = [string]$r.PrimaryServerName
                    ReplicaServerName           = [string]$r.ReplicaServerName
                    LastReplicationTime         = [string]$r.LastReplicationTime
                    FrequencySec                = [string]$r.FrequencySec
                    ReplicationHealthDetails    = [string]($r.ReplicationHealthDetails -join '; ')
                } } else { $null }
                Measure = if ($m) { [pscustomobject]@{
                    ReplicationHealth         = [string]$m.ReplicationHealth
                    LastReplicationTime       = [string]$m.LastReplicationTime
                    AverageReplicationSize    = [string]$m.AverageReplicationSize
                    MaximumReplicationSize    = [string]$m.MaximumReplicationSize
                    PendingReplicationSize    = [string]$m.PendingReplicationSize
                    AverageReplicationLatency = [string]$m.AverageReplicationLatency
                    ReplicationSuccessCount   = [string]$m.ReplicationSuccessCount
                    MissedReplicationCount    = [string]$m.MissedReplicationCount
                } } else { $null }
            }
        } -ArgumentList $VMName
        if ($replInfo -and $replInfo.Repl) {
            $replInfo.Repl | Format-List Name, State, Health, Mode, ReplicationRelationshipType,
                PrimaryServerName, ReplicaServerName, LastReplicationTime, FrequencySec, ReplicationHealthDetails | Out-Indented

            # Replication throughput / backlog - shows if replication is falling behind:
            Write-Section "Hyper-V Replica Statistics (Measure-VMReplication):"
            if ($replInfo.Measure) {
                $replInfo.Measure | Format-List ReplicationHealth, LastReplicationTime,
                    AverageReplicationSize, MaximumReplicationSize, PendingReplicationSize,
                    AverageReplicationLatency, ReplicationSuccessCount, MissedReplicationCount | Out-Indented
            } else {
                Write-Host "  No replication statistics available."
                Write-Host ""
            }
        } else {
            Write-Host "HVR Replication reported as '$($vm.ReplicationState)' but no replication object was returned."
            Write-Host ""
        }
    } else {
        Write-Host "HVR Replication is not enabled for '$VMName'."
        Write-Host ""
    }

    # Hyper-V Replica change logs (.hrl): on the PRIMARY, Replica tracks writes in per-VHD .hrl logs
    # (NOT .avhdx). A large or stale .hrl usually means replication is backlogged or stuck.
    Show-AuditProgress -Step 45 -Status 'Scanning Replica change logs (.hrl)'
    Write-Section "Hyper-V Replica Change Logs (.hrl):"
    if ($vhdFolders) {
        try {
            $hrlFiles = @(Invoke-OnOwner -ScriptBlock {
                param($folders)
                $folders | ForEach-Object {
                    Get-ChildItem -LiteralPath $_ -Filter '*.hrl' -File -ErrorAction SilentlyContinue
                } | ForEach-Object {
                    [pscustomobject]@{ Name = [string]$_.Name; FullName = [string]$_.FullName; Length = [long]$_.Length; LastWriteTimeUtc = $_.LastWriteTimeUtc }
                }
            } -ArgumentList (,$vhdFolders))
        } catch {
            $hrlFiles = $null
            Write-Alert "  Could not scan for .hrl logs on '$OwningNode': $($_.Exception.Message)" -Level Warning
        }
        if ($hrlFiles -and $hrlFiles.Count -gt 0) {
            $hrlFiles | Sort-Object Name | Select-Object `
                Name,
                @{N='SizeMB';E={ [math]::Round($_.Length / 1MB, 2) }},
                @{N='LastWrite (UTC)';E={ $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }},
                @{N='Age (hrs)';E={ [math]::Round(([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalHours, 1) }},
                @{N='Stale';E={ if (([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalHours -ge $StaleHours) { 'YES' } else { 'NO' } }},
                FullName | Format-Table -AutoSize -Wrap | Out-Indented
        } else {
            Write-Host "  No .hrl replication logs found (expected on a PRIMARY with replication enabled)."
            Write-Host ""
        }
    } else {
        Write-Host "  No VHD folders resolved to scan."
        Write-Host ""
    }

    # Scan the owning node's Hyper-V event logs for the checkpoint fork-commit / merge failure mode.
    # The documented chain is: Replica change-tracking / resync failures (leading indicators) ->
    # checkpoint fork-commit failure (18590, 0x80048102) -> per-disk .vmcx revert leaves the chain
    # inconsistent -> backup product retries fail (0x80070020) -> the inconsistency stays dormant while
    # the VM runs -> a later live migration / restart reopens the chain and can roll disks back to base.
    # v0.2.12: event-ID / HRESULT matches are collected node-wide (some events carry a blank or a
    # different VM GUID), but only events ATTRIBUTABLE TO THIS VM (message names this VM or its GUID)
    # drive this VM's verdict; the rest are surfaced as node context. Runs by default; use
    # -SkipWorkerEvents to opt out.
    $eventConcernCount   = 0
    $concernEvents       = @()
    $vmConcernEvents     = @()
    $vmEventConcernCount = 0
    $eventsCsvName       = $null
    if (-not $SkipWorkerEvents) {
        Show-AuditProgress -Step 50 -Status 'Scanning Hyper-V Worker/VMMS event logs'
        Write-Section "Hyper-V Worker/VMMS Admin Events (last $EventLookbackHours h on $OwningNode):"
        # Match on the VM GUID as well as the name - Worker/VMMS messages reference the
        # 'Virtual machine ID <GUID>', which is far more reliable than the long friendly name.
        $vmId = [string]$vm.VMId
        # v0.2.14: per-NODE event cache. The Worker/VMMS scan is NODE-WIDE, so on a fleet run every VM
        # on the same owning node would otherwise re-read the SAME (often huge) event set. Scan each
        # node ONCE (keyed by node + lookback), cache the concern/context rows, then derive THIS VM's
        # per-VM view (VmAttributed) locally from the cached set - a big speed-up and consistent
        # node-wide counts across VMs that share a node.
        $nodeCacheKey = "{0}|{1}" -f $OwningNode, $EventLookbackHours
        if (-not $script:NodeEventCache.ContainsKey($nodeCacheKey)) {
            # v0.2.15: time the node-wide Worker/VMMS event scan (typically the dominant per-node cost).
            $nodeScanStart = Get-TelemetryNow
            try {
                $nodeRows = @(Invoke-OnOwner -ScriptBlock {
                    param($lookbackHours, $concernIds, $contextIds, $codePatterns)
                    $start  = (Get-Date).AddHours(-$lookbackHours)
                    # Single alternation regex built from the (escaped) HRESULT strings:
                    $codeRx = ($codePatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
                    Get-WinEvent -FilterHashtable @{
                        LogName   = 'Microsoft-Windows-Hyper-V-Worker-Admin', 'Microsoft-Windows-Hyper-V-VMMS-Admin'
                        StartTime = $start
                    } -ErrorAction SilentlyContinue |
                    Where-Object {
                        # NODE-WIDE set: any event carrying a concern/context ID or an HRESULT. Per-VM
                        # attribution is computed by the CALLER against the cached FullMessage.
                        ($codeRx -and $_.Message -match $codeRx) -or ($concernIds -contains $_.Id) -or ($contextIds -contains $_.Id)
                    } |
                    ForEach-Object {
                        # Concern = a genuine PROBLEM only: an HRESULT match, or an ID in the concern list.
                        # Informational lifecycle IDs (context list) are surfaced but NEVER flagged Concern.
                        $isConcern = (($codeRx -and $_.Message -match $codeRx) -or ($concernIds -contains $_.Id))
                        [pscustomobject]@{
                            'Time (UTC)' = $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
                            Id           = [int]$_.Id
                            Level        = [string]$_.LevelDisplayName
                            Log          = if ($_.LogName -like '*Worker*') { 'Worker' } elseif ($_.LogName -like '*VMMS*') { 'VMMS' } else { [string]$_.LogName }
                            Concern      = if ($isConcern) { 'YES' } else { '' }
                            Message      = ($_.Message -split "`r?`n")[0]
                            FullMessage  = ($_.Message -replace "`r?`n", ' | ')
                        }
                    }
                } -ArgumentList $EventLookbackHours, $WorkerEventIds, $ContextEventIds, $ErrorCodePatterns)
                $script:NodeEventCache[$nodeCacheKey] = @($nodeRows)
                # v0.2.14: write the NODE-WIDE event set ONCE per node to a shared _NodeEvents CSV, so
                # the (often huge, e.g. thousands of 15268) node context is stored a single time rather
                # than duplicated into every per-VM CSV on that node. Per-VM CSVs then carry only the
                # events attributable to that VM (below). This can more than halve a busy run's CSV size.
                if ($OutputPath -and @($nodeRows).Count -gt 0) {
                    try {
                        $nodeCsvName = "_NodeEvents_{0}_{1}.csv" -f ($OwningNode -replace '[^\w.\-]', '_'), [DateTime]::UtcNow.ToString('yyyy-MM-dd')
                        $nodeCsvPath = Join-Path $OutputPath $nodeCsvName
                        if (-not (Test-Path -LiteralPath $nodeCsvPath)) {
                            @($nodeRows) | Select-Object 'Time (UTC)', Id, Level, Log, Concern, FullMessage |
                                Export-Csv -LiteralPath $nodeCsvPath -NoTypeInformation -Encoding UTF8
                        }
                        $script:NodeCsvNameByNode[$OwningNode] = $nodeCsvName
                    } catch {
                        Write-Alert "  Could not write the node-wide events CSV for '$OwningNode': $($_.Exception.Message)" -Level Warning
                    }
                }
            } catch {
                $script:NodeEventCache[$nodeCacheKey] = $null
                Write-Alert "  Could not read event logs on '$OwningNode': $($_.Exception.Message)" -Level Warning
            }
            Add-TelemetryEntry -Step '1.10.50.10' -Phase 'Node event-log scan (once per node)' -Detail $OwningNode -StartUtc $nodeScanStart -EndUtc (Get-TelemetryNow)
        }
        $cachedNodeEvents = $script:NodeEventCache[$nodeCacheKey]
        # Derive THIS VM's view from the cached node set: stamp VmAttributed (message names this VM or
        # its GUID) onto each row. v0.2.12 semantics: only VM-attributed events drive this VM's verdict.
        if ($null -ne $cachedNodeEvents) {
            $workerEvents = @($cachedNodeEvents | ForEach-Object {
                $isVmAttributed = (($VMName -and $_.FullMessage -match [regex]::Escape($VMName)) -or ($vmId -and $_.FullMessage -match [regex]::Escape($vmId)))
                [pscustomobject]@{
                    'Time (UTC)' = $_.'Time (UTC)'
                    Id           = $_.Id
                    Level        = $_.Level
                    Log          = $_.Log
                    Concern      = $_.Concern
                    VmAttributed = [bool]$isVmAttributed
                    Message      = $_.Message
                    FullMessage  = $_.FullMessage
                }
            })
        } else {
            $workerEvents = $null
        }

        if ($workerEvents -and $workerEvents.Count -gt 0) {
            $workerEvents      = @($workerEvents | Sort-Object 'Time (UTC)')
            $concernEvents     = @($workerEvents | Where-Object { $_.Concern -eq 'YES' })
            $eventConcernCount = $concernEvents.Count
            # v0.2.12: split concern events into those attributable to THIS VM vs node-wide (other VMs).
            $vmConcernEvents     = @($concernEvents | Where-Object { $_.VmAttributed })
            $vmEventConcernCount = $vmConcernEvents.Count

            # Discover OTHER VMs referenced in this node's HIGH-RISK signals (background disk merge
            # interrupted / failed, or 'cannot load VM configuration'). Hyper-V messages quote the VM
            # friendly name, so pull quoted tokens; the end block cross-checks them against real
            # clustered VMs (which discards paths / noise) and de-duplicates. Collected for ALL VMs, and
            # optionally auto-audited via -IncludeDiscoveredVMs.
            $highRiskIds = @(19090, 19100, 16300)
            foreach ($ev in $concernEvents) {
                $isHighRisk = ($highRiskIds -contains [int]$ev.Id) -or ($ev.FullMessage -match '0x80070020')
                if (-not $isHighRisk) { continue }
                $reason = switch ([int]$ev.Id) {
                    19100   { 'Background disk merge FAILED (event 19100)' }
                    19090   { 'Background disk merge interrupted (event 19090)' }
                    16300   { 'Cannot load VM configuration (event 16300)' }
                    default { if ($ev.FullMessage -match '0x80070020') { 'Sharing violation on disk (0x80070020)' } else { 'High-risk checkpoint/merge signal' } }
                }
                foreach ($qm in [regex]::Matches([string]$ev.FullMessage, "'([^']+)'")) {
                    $cand = $qm.Groups[1].Value.Trim()
                    if ($cand) {
                        [void]$script:DiscoveredCandidates.Add([pscustomobject]@{
                            Name = $cand; Reason = $reason; SourceVM = $VMName; SourceNode = $OwningNode
                        })
                    }
                }
            }

            # The console / .txt table can be swamped by thousands of identical rows (e.g. repeated
            # 15268). Cap each event ID to the first few rows here; the CSV keeps EVERY event, and a
            # note states how many duplicates were collapsed and points to the CSV for full detail.
            $perIdCap     = 5
            $displayRows  = [System.Collections.Generic.List[object]]::new()
            $removedNotes = [System.Collections.Generic.List[string]]::new()
            $workerEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object {
                $grp = @($_.Group | Sort-Object 'Time (UTC)')
                foreach ($e in ($grp | Select-Object -First $perIdCap)) { $displayRows.Add($e) }
                if ($grp.Count -gt $perIdCap) {
                    $removedNotes.Add(("  Removed {0} duplicate Event ID {1} entries (showing first {2}) - Review CSV file for full details." -f ($grp.Count - $perIdCap), $_.Name, $perIdCap))
                }
            }
            # Console table shows the first message line only (readability); full text is in the CSV.
            @($displayRows | Sort-Object 'Time (UTC)') | Format-Table 'Time (UTC)', Id, Level, Log, Concern, Message -AutoSize -Wrap | Out-Indented
            foreach ($note in $removedNotes) { Write-Host $note }
            if ($removedNotes.Count -gt 0) { Write-Host "" }
            Write-Host ("  {0} event(s) matched ({1} shown after collapsing duplicates); {2} flagged as a Concern - {3} attributable to this VM, {4} node-wide (other VMs / none)." -f $workerEvents.Count, $displayRows.Count, $eventConcernCount, $vmEventConcernCount, ($eventConcernCount - $vmEventConcernCount))
            Write-Host  "  Informational lifecycle events (VM started, checkpoint completed, merge started / finished OK)"
            Write-Host  "  are listed for context but NOT flagged as a Concern."
        } else {
            Write-Host "  No matching events in the last $EventLookbackHours hours."
            Write-Host ""
        }

        # Export the event detail to CSV (no truncation) whenever an -OutputPath was supplied. This
        # ALWAYS writes the CSV - even with ZERO matching events, in which case it contains a single
        # 'no matching events' marker row - so every VM produces a CONSISTENT file set (.txt + .csv)
        # and a missing CSV is never mistaken for a bug or an incomplete run. The file name leads with
        # the VM name + UTC date (yyyy-MM-dd) so it sorts alongside the report.
        if ($OutputPath -and $reportFile) {
            $csvFolder     = Split-Path -Parent $reportFile
            $eventsCsvName = "{0}_Events_{1}.csv" -f ($VMName -replace '[^\w.\-]', '_'), [DateTime]::UtcNow.ToString('yyyy-MM-dd')
            $csvPath       = Join-Path $csvFolder $eventsCsvName
            $nodeCsvForVm  = [string]$script:NodeCsvNameByNode[$OwningNode]
            # v0.2.14: the per-VM CSV now carries ONLY events attributable to THIS VM. The node-wide
            # set (all concern/context events on the node, e.g. the 15268 flood) is written ONCE to the
            # shared _NodeEvents_<node>_<date>.csv above - no longer duplicated into every VM's CSV.
            $vmAttributedEvents = @($workerEvents | Where-Object { $_.VmAttributed })
            if ($vmAttributedEvents.Count -gt 0) {
                $vmAttributedEvents | Select-Object 'Time (UTC)', Id, Level, Log, Concern, VmAttributed, FullMessage |
                    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
                Write-Host ""
                Write-Host "  This VM's full, untruncated event messages exported to CSV: $csvPath"
                if ($nodeCsvForVm) { Write-Host "  Node-wide events (context, all VMs on $OwningNode) are in: $nodeCsvForVm" }
                Write-Host "  (Use these CSVs rather than the truncated console table above - they have the complete text.)"
            } else {
                # No events attributable to THIS VM: still write the per-VM CSV (same columns) with one
                # informational marker row, so the presence of the file confirms the scan ran.
                $noneMsg = if ($nodeCsvForVm) { "No Hyper-V Worker/VMMS events attributable to this VM in the last $EventLookbackHours hours (scan ran). Node-wide events (all VMs on $OwningNode) are in $nodeCsvForVm." } else { "No matching Hyper-V Worker/VMMS events in the last $EventLookbackHours hours (scan ran; nothing to report)." }
                [pscustomobject]@{
                    'Time (UTC)' = ''
                    Id           = ''
                    Level        = 'Info'
                    Log          = ''
                    Concern      = ''
                    VmAttributed = ''
                    FullMessage  = $noneMsg
                } | Select-Object 'Time (UTC)', Id, Level, Log, Concern, VmAttributed, FullMessage |
                    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
                Write-Host "  (No events attributable to this VM - wrote a marker row: $csvPath$(if ($nodeCsvForVm) { "; node-wide events in $nodeCsvForVm" }))"
            }
        }
    }

    # Per-node check: is the Hyper-V-VMMS/Analytic channel enabled? It is the only place the internal
    # per-disk .vmcx revert failure ('Cannot revert configuration info for AVHD') is traced, but it is
    # DISABLED by default. Report each cluster node's state and, where disabled, print the command the
    # operator can choose to run (elevated, on that node) to enable it.
    if (-not $SkipAnalyticCheck) {
        Show-AuditProgress -Step 55 -Status 'Checking Analytic channel state'
        Write-Section "Hyper-V-VMMS/Analytic Channel (per node):"
        $analyticLog = 'Microsoft-Windows-Hyper-V-VMMS-Analytic'
        $nodes = @((Get-ClusterNode -Cluster $ClusterName -ErrorAction SilentlyContinue).Name)
        if (-not $nodes) { $nodes = @($OwningNode) }
        $analyticStatus = Invoke-Command -ComputerName $nodes -ScriptBlock {
            $log = $using:analyticLog
            try   { $enabled = [bool](Get-WinEvent -ListLog $log -ErrorAction Stop).IsEnabled }
            catch { $enabled = 'Unknown (log not found)' }
            [pscustomobject]@{ Node = $env:COMPUTERNAME; Channel = $log; Enabled = $enabled }
        } -ErrorAction SilentlyContinue
        if ($analyticStatus) {
            $analyticStatus | Sort-Object Node | Format-Table Node, Channel, Enabled -AutoSize | Out-Indented
            # Only a real boolean $true means the channel is capturing; $false OR 'Unknown (log not
            # found)' both mean it is NOT, so flag those nodes here and remember them for the RESULT tip.
            $analyticNodesNeedEnable = @($analyticStatus | Where-Object { -not (($_.Enabled -is [bool]) -and $_.Enabled) } | ForEach-Object { [string]$_.Node })
            if ($analyticNodesNeedEnable.Count -gt 0) {
                Write-Host "  NOT enabled on: $($analyticNodesNeedEnable -join ', ')"
                Write-Host "  To enable it (run elevated on each node listed above, if you choose to):"
                Write-Host "      wevtutil sl $analyticLog /e:true /q:true"
                Write-Host ""
            }
        } else {
            Write-Host "  Could not query the Analytic channel status on the cluster nodes."
            Write-Host ""
        }
    }

    # VSS writer health (READ-ONLY). Per the Microsoft troubleshooting guide, failed / timed-out VSS
    # writers are a leading cause of Hyper-V backup + checkpoint failures (a failed writer blocks the
    # app-consistent checkpoint, which is the operation under investigation here). 'vssadmin list
    # writers' only ENUMERATES writer state - it changes nothing. It needs an elevated context on the
    # owning node; if that is unavailable the section degrades gracefully.
    Show-AuditProgress -Step 60 -Status 'Checking VSS writer health'
    Write-Section "VSS Writer Health (vssadmin list writers - read-only):"
    $vssWriters = $null
    try {
        $vssWriters = @(Invoke-OnOwner -ScriptBlock {
            $raw = & vssadmin list writers 2>$null
            if (-not $raw) { return @() }
            $text = ($raw -join "`n")
            $out = @()
            foreach ($b in ($text -split "(?m)^Writer name:")) {
                if ($b -notmatch "'") { continue }
                $name    = if ($b -match "'([^']+)'")      { $Matches[1] }        else { '' }
                $state   = if ($b -match "State:\s*(.+)")   { $Matches[1].Trim() } else { '' }
                $lastErr = if ($b -match "Last error:\s*(.+)") { $Matches[1].Trim() } else { '' }
                if ($name) { $out += [pscustomobject]@{ Writer = $name; State = $state; 'Last error' = $lastErr } }
            }
            $out
        })
    } catch {
        $vssWriters = $null
        Write-Alert "  Could not query VSS writers on '$OwningNode' (needs an elevated context): $($_.Exception.Message)" -Level Warning
    }
    $vssUnhealthy = @()
    if ($vssWriters -and $vssWriters.Count -gt 0) {
        $vssUnhealthy = @($vssWriters | Where-Object {
            (($_.'Last error') -and ($_.'Last error' -ne 'No error')) -or ($_.State -notmatch 'Stable')
        })
        if ($vssUnhealthy.Count -gt 0) {
            Write-Alert ("  {0} of {1} VSS writer(s) are NOT healthy (State not Stable, or a Last error):" -f $vssUnhealthy.Count, $vssWriters.Count) -Level Warning
            $vssUnhealthy | Format-Table Writer, State, 'Last error' -AutoSize -Wrap | Out-Indented
            Write-Host "  Unhealthy VSS writers commonly block Hyper-V checkpoint / backup operations. Restarting the"
            Write-Host "  related service(s) or the affected writer often clears them (see the reference below)."
        } else {
            Write-Alert "  All $($vssWriters.Count) VSS writer(s) report State: Stable with no last error." -Level Good
            Write-Host ""
        }
    } else {
        Write-Host "  VSS writer state unavailable (vssadmin needs an elevated context on the owning node)."
        Write-Host ""
    }

    # Dedicated VM configuration-version note. IMPORTANT: the Microsoft troubleshooting guide does NOT
    # link an older VM config version to the checkpoint / merge failure under investigation; it lists a
    # configuration-version MISMATCH as a cause of MIGRATION / START failures (a separate category). It
    # is surfaced here as accurate, clearly-scoped context only, and only when the VM is behind latest.
    if ($vmVerOlder) {
        Write-Section "VM Configuration Version (migration / start context - NOT a checkpoint cause):"
        Write-Host ("  This VM is at configuration version {0}; its owning node supports up to {1}." -f $vm.Version, $hostMaxVer)
        Write-Host  "  This is NOT a stated cause of the checkpoint / merge failure being investigated. The text below"
        Write-Host ("  is quoted VERBATIM from {0}" -f $script:TroubleshootTitle)
        Write-Host  "  (which lists a configuration-version mismatch under migration / start failures):"
        Write-Host  '      "Configuration version mismatch: VM configuration versions below the required minimum'
        Write-Host  '       after migrations or upgrades."'
        Write-Host  "  If an upgrade is required, shut the VM down first, then run 'Update-VMVersion' (or use Hyper-V"
        Write-Host  "  Manager > Upgrade Configuration Version). This is an operator decision - the script changes nothing."
        Write-Host ("  Reference: {0}" -f $script:TroubleshootTitle)
        Write-Host ("             {0}" -f $script:TroubleshootUrl)
        Write-Host ""
    }

    # Summary: total active checkpoints (differencing / .avhdx layers) across all attached disks:
    Show-AuditProgress -Step 65 -Status 'Building summary'
    $totalCheckpoints = @($diskReports | Measure-Object -Property CheckpointCount -Sum).Sum
    if (-not $totalCheckpoints) { $totalCheckpoints = 0 }
    $hasCheckpoints   = $totalCheckpoints -gt 0
    # Count named checkpoints older than the stale threshold:
    $staleCheckpoints = @($checkpoints | Where-Object { ([DateTime]::UtcNow - $_.CreationTimeUtc).TotalHours -ge $StaleHours })

    # Severity: distinguish a CONFIRMED checkpoint fork-commit / merge-failure signature (a genuine
    # data-loss risk if the VM is migrated / restarted) from symptom-only noise (e.g. repeated 15268
    # or an aged backup checkpoint), which usually points to a stalled / failed backup or an unhealthy
    # VSS writer rather than on-disk chain corruption.
    # v0.2.12: 18590 REMOVED from the fork-commit signature IDs - in the field it is the
    # Hyper-V-Worker "VM has encountered a fatal error" GUEST-OS bugcheck (e.g. Stop 0x7E), which is
    # unrelated to a checkpoint fork-commit / merge failure. The signature is now event 3216 or one of
    # the specific merge/commit HRESULTs, AND (v0.2.12) the event must be ATTRIBUTABLE TO THIS VM.
    $forkCommitIds    = @(3216)
    $forkCommitRx     = (@('0x80048102', '0x800480BD', '0x800480BC', '0x800703EE') | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $hasForkSignature = (@($vmConcernEvents | Where-Object { ($forkCommitIds -contains [int]$_.Id) -or ($_.FullMessage -match $forkCommitRx) }).Count -gt 0)
    $holdState        = ($hasForkSignature -and ($hasCheckpoints -or $staleCheckpoints.Count -gt 0))

    # v0.2.14: event SEVERITY split. Only HIGH-signal events attributable to THIS VM (its OWN
    # checkpoint / merge actually failed, or a fork-commit HRESULT) should escalate a VM to INVESTIGATE.
    # LOW-signal per-VM events (e.g. 15268 'failed to get disk information', 12240 attachment-not-found,
    # 3280 could-not-initiate, 32510 stale .hrl delete) are storage / housekeeping chatter and, on
    # their own, must NOT flag an otherwise-clean, running, checkpoint-free, replica-Normal VM.
    $vmHighSignalIds     = @(3216, 18012, 19090, 19100, 16300)
    $vmHighConcernEvents = @($vmConcernEvents | Where-Object { ($vmHighSignalIds -contains [int]$_.Id) -or ($_.FullMessage -match $forkCommitRx) })
    $vmHighConcernCount  = @($vmHighConcernEvents).Count
    $vmLowConcernCount   = $vmEventConcernCount - $vmHighConcernCount

    # Replica health as a concern driver (v0.2.14). A Critical replica (e.g. resync required) or a
    # Warning is a genuine per-VM issue even with no checkpoints / events, so it drives INVESTIGATE.
    $replHealth    = if ($replInfo -and $replInfo.Repl) { "$($replInfo.Repl.Health)" } else { '' }
    $replCritical  = ($replHealth -match 'Critical')
    $replWarning   = ($replHealth -match 'Warning')
    $replUnhealthy = ($replCritical -or $replWarning)

    # v0.2.14: classify each orphaned .avhdx so the operator gets an ACTIONABLE read, and detect the
    # 'past rollback' fingerprint: several orphans across multiple disk folders
    # that share a common last-write DATE = the disks were rolled back to base at that time, orphaning
    # the checkpoint layers. That is the durable evidence of a MATERIALISED fork-commit event whose
    # original events may now be older than -EventLookbackHours. NEVER states 'safe to delete' - the
    # action and decision always rest with the operator.
    # v0.2.15: 16220 ('cannot delete .avhd file ... being used by another process (0x80070020). File
    # is safe to delete at any time.') is a TRANSIENT in-use lock at the moment a delete was attempted
    # - NOT a stuck/failed merge. It is handled as its own class ('SafeToDelete') below: when a 16220
    # for THIS VM names THIS orphan's exact file, the file was simply locked when Hyper-V tried to
    # remove it and is now orphaned - the event itself states it is safe to delete. Real stuck/failed
    # merges are 19090 / 19100 / 32510.
    $mergeFailIds     = @(19090, 19100, 32510)
    $rollbackDate     = $null
    $orphanClassified = @()
    if (@($orphans).Count -gt 0) {
        $orphanClassified = @($orphans | ForEach-Object {
            $o = $_; $leaf = [string]$o.Name
            $isLiveMount = ($o.FullName -match 'rubriklivemount') -or ($leaf -match '_temp_') -or ([long]$o.Length -eq 0)
            # v0.2.15 (F1): match the orphan file name in the event message with a case-insensitive
            # literal .Contains(), NOT -like "*$leaf*" - an .avhdx name containing a wildcard
            # metacharacter ([ ] * ?) would fail to match under -like and mis-classify the orphan.
            $stuckEvt = @($concernEvents | Where-Object { ($mergeFailIds -contains [int]$_.Id) -and $leaf -and ([string]$_.FullMessage).ToLower().Contains($leaf.ToLower()) })
            # A 16220 delete-attempt lock for THIS VM that names THIS orphan's exact file path.
            $lockEvt  = @($concernEvents | Where-Object { ([int]$_.Id -eq 16220) -and $_.VmAttributed -and $leaf -and ([string]$_.FullMessage).ToLower().Contains($leaf.ToLower()) } | Sort-Object 'Time (UTC)')
            $cls = if ($stuckEvt.Count -gt 0) { 'StuckMerge' } elseif ($lockEvt.Count -gt 0) { 'SafeToDelete' } elseif ($isLiveMount) { 'LiveMount' } else { 'Leftover' }
            [pscustomobject]@{
                Orphan        = $o
                Class         = $cls
                MergeEventId  = if ($stuckEvt.Count -gt 0) { [int](@($stuckEvt)[0].Id) } else { $null }
                LockEventTime = if ($lockEvt.Count -gt 0) { [string](@($lockEvt)[0].'Time (UTC)') } else { $null }
            }
        })
        # Rollback fingerprint: >=4 orphans sharing ONE last-write date across >=2 distinct folders.
        # Files with their OWN per-file evidence (a real stuck-merge event, or a 16220 delete-attempt
        # lock naming that exact file) keep that stronger classification and are NOT relabelled Rollback.
        $byDate = @($orphans | Where-Object { $_.LastWriteTimeUtc } | Group-Object { $_.LastWriteTimeUtc.Date } | Sort-Object Count -Descending)
        if ($byDate.Count -gt 0) {
            $topDate  = $byDate[0]
            $folders  = @($topDate.Group | ForEach-Object { Split-Path $_.FullName -Parent } | Sort-Object -Unique)
            if ([int]$topDate.Count -ge 4 -and $folders.Count -ge 2) {
                $rollbackDate = ([datetime]$topDate.Name).ToString('yyyy-MM-dd')
                foreach ($oc in $orphanClassified) {
                    if ($oc.Orphan.LastWriteTimeUtc -and ($oc.Orphan.LastWriteTimeUtc.Date -eq [datetime]$topDate.Name) -and ($oc.Class -ne 'StuckMerge') -and ($oc.Class -ne 'SafeToDelete')) { $oc.Class = 'Rollback' }
                }
            }
        }
    }
    $hasRollbackFingerprint = [bool]$rollbackDate
    $hasStuckMergeOrphan    = (@($orphanClassified | Where-Object { $_.Class -eq 'StuckMerge' }).Count -gt 0)
    $orphanOnlyLiveMount    = ((@($orphans).Count -gt 0) -and (@($orphanClassified | Where-Object { $_.Class -ne 'LiveMount' }).Count -eq 0))

    # v0.2.14: INVESTIGATE is now driven by stale checkpoints, orphaned .avhdx, unhealthy VSS writers,
    # an unhealthy replica, OR HIGH-signal per-VM events - NOT by low-signal storage chatter. A VM whose
    # ONLY signal is LOW-signal per-VM events (and is otherwise clean) is reported OK with a low-key note.
    $investigate      = ((-not $holdState) -and (($staleCheckpoints.Count -gt 0) -or $hasOrphans -or ($vssUnhealthy.Count -gt 0) -or $replUnhealthy -or ($vmHighConcernCount -gt 0)))
    # True when the ONLY thing found is low-signal per-VM chatter (drives the OK 'note' wording below).
    $lowSignalOnly    = ((-not $holdState) -and (-not $investigate) -and ($vmLowConcernCount -gt 0))

    # Severity score used ONLY for ORDERING within a verdict band (higher sorts first). Lets orphan /
    # stale / replica-Critical INVESTIGATE VMs bubble above events-only ones; live-mount-only sits lowest.
    $severityScore = 0
    if ($holdState) { $severityScore = 100 }
    elseif ($investigate) {
        if     ($hasRollbackFingerprint)                    { $severityScore = 90 }
        elseif ($hasStuckMergeOrphan)                       { $severityScore = 80 }
        elseif ($staleCheckpoints.Count -gt 0)              { $severityScore = 65 }
        elseif ($replCritical)                              { $severityScore = 60 }
        elseif ($hasOrphans -and -not $orphanOnlyLiveMount) { $severityScore = 50 }
        elseif ($vmHighConcernCount -gt 0)                  { $severityScore = 45 }
        elseif ($replWarning)                               { $severityScore = 42 }
        elseif ($orphanOnlyLiveMount)                       { $severityScore = 30 }
        else                                                { $severityScore = 20 }
    }
    elseif ($lowSignalOnly) { $severityScore = 5 }

    $concernIdSummary     = (@($concernEvents   | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object { "{0} x{1}" -f $_.Name, $_.Count }) -join ', ')
    $vmConcernIdSummary   = (@($vmConcernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object { "{0} x{1}" -f $_.Name, $_.Count }) -join ', ')
    $nodeOnlyConcernCount = $eventConcernCount - $vmEventConcernCount
    # Dominant node-wide concern ID, for the 'mostly NNNNN' annotation on the node-wide KV row. Only
    # annotated when a single ID makes up at least half of the node-wide concern events.
    $nodeDominant     = if ($concernEvents.Count -gt 0) { @($concernEvents | Group-Object Id | Sort-Object Count -Descending)[0] } else { $null }
    $nodeDominantNote = if ($nodeDominant -and ([int]$nodeDominant.Count -ge [int][math]::Ceiling($eventConcernCount * 0.5))) { "mostly {0}" -f $nodeDominant.Name } else { '' }

    # v0.2.15: HISTORIC cross-node correlation. ONLY when this VM has orphaned .avhdx files - search a
    # window around each orphan's CREATION time (= the checkpoint / fork-commit moment) AND its
    # LAST-WRITE time (= when the rollback / migration froze it), across ALL cluster nodes, for THIS
    # VM's fork-commit / merge events that may predate the -EventLookbackHours window. The fork-commit
    # failure and the rollback that materialises it can be DAYS apart (the chain inconsistency lies
    # dormant until a live migration), so a window around last-write alone misses the original
    # fork-commit; anchoring on BOTH timestamps captures the fork-commit AND the rollback. Via each
    # log's oldest-available-event time we also tell when the logs have WRAPPED past the window.
    $historicCorrelation = $null
    if (@($orphans).Count -gt 0 -and @($clusterNodes).Count -gt 0) {
        Show-AuditProgress -Step 70 -Status 'Historic event correlation (around orphan timestamps)'
        $orphanTimes = @($orphans | ForEach-Object { $_.CreationTimeUtc; $_.LastWriteTimeUtc } | Where-Object { $_ })
        if ($orphanTimes.Count -gt 0) {
            try {
                $historicCorrelation = Get-HistoricVMEventCorrelation -VMName $VMName -VMId ([string]$vm.VMId) `
                    -Nodes $clusterNodes -Timestamps $orphanTimes -WindowMinutes 120 `
                    -SignatureIds @(3216, 18012, 19090, 19100, 16300) -SignatureRx $forkCommitRx
            } catch {
                $historicCorrelation = $null
            }
        }
    }
    # A historic fork-commit signature is strong evidence the rollback DID happen for this VM (even
    # though the events are outside the standard window). Surface it as its own flag.
    $historicForkConfirmed = ($historicCorrelation -and (@($historicCorrelation.Matches | Where-Object { ([int]$_.Id -eq 3216) -or ($_.Message -match $forkCommitRx) }).Count -gt 0))

    # ---- Findings block for the operator / backup team (and, only when warranted, a CSS case) -------
    # A copy/paste-ready summary of the key findings. The framing ADAPTS to severity so we do NOT push
    # operators toward a Microsoft Support (CSS) case when there is no fork-commit signature: only
    # HOLD STATE (a confirmed fork-commit signature alongside unmerged differencing disks) warrants a
    # CSS case up front; INVESTIGATE and clean results are for the operator / backup team to triage
    # FIRST. It references the events CSV for the full, untruncated detail.
    if ($holdState) {
        $statementTitle = "PROBLEM STATEMENT (for a Microsoft Support (CSS) case and/or your backup vendor):"
    } elseif ($investigate) {
        $statementTitle = "FINDINGS TO INVESTIGATE (for your operations / backup team - no Microsoft case needed yet):"
    } else {
        $statementTitle = "SUMMARY (for your records):"
    }
    Write-Host ""
    Write-Section $statementTitle
    Write-Host "  ------------------------------------------------------------------------------"
    Write-Host ("  Cluster / Owner : {0} / {1}" -f $ClusterName, $OwningNode)
    Write-Host ("  VM              : {0}  (Id {1})" -f $VMName, $vm.VMId)
    Write-Host ("  VM State/Status : {0} / {1}" -f $vm.State, $vm.Status)
    Write-Host ("  Report run at   : {0} UTC" -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss'))
    Write-Host ""
    if ($hasCheckpoints -and $holdState) {
        Write-Host ("  This VM is running on {0} active differencing (.avhdx checkpoint) disk layer(s) over its base" -f $totalCheckpoints)
        Write-Host  "  VHD(s), together with a checkpoint fork-commit / merge-failure signature. That combination can"
        Write-Host  "  leave the on-disk chain inconsistent and, if the VM is later migrated or restarted, roll the"
        Write-Host  "  disks back to base and orphan the data held in the .avhdx layer(s)."
    } elseif ($hasCheckpoints) {
        Write-Host ("  This VM is running on {0} active differencing (.avhdx checkpoint) disk layer(s) over its base" -f $totalCheckpoints)
        Write-Host  "  VHD(s). No checkpoint fork-commit / merge-failure signature was found, so these layer(s) are"
        Write-Host  "  most likely a backup checkpoint that has not yet been merged - review them with your backup"
        Write-Host  "  team before taking any action (this is NOT, on its own, a reason to open a Microsoft case)."
    } else {
        Write-Host  "  This VM currently has no active differencing (.avhdx) disk layers attached."
    }
    if ($vmEventConcernCount -gt 0) {
        Write-Host ""
        Write-Host ("  {0} concerning Hyper-V event(s) attributable to THIS VM ({1}) on {2} in the last {3} hours, by event ID:" -f $vmEventConcernCount, $VMName, $OwningNode, $EventLookbackHours)
        $vmConcernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object {
            $times = @($_.Group.'Time (UTC)' | Sort-Object)
            if ($_.Count -le 1 -or $times[0] -eq $times[-1]) {
                Write-Host ("    - ID {0}  x{1}   (at {2} UTC)" -f $_.Name, $_.Count, $times[0])
            } else {
                Write-Host ("    - ID {0}  x{1}   (first {2} UTC, last {3} UTC)" -f $_.Name, $_.Count, $times[0], $times[-1])
            }
        }
    }
    if ($nodeOnlyConcernCount -gt 0) {
        Write-Host ""
        Write-Host ("  NOTE (node context): a further {0} concerning Hyper-V event(s) on {1} reference OTHER VMs (or no VM)" -f $nodeOnlyConcernCount, $OwningNode)
        Write-Host  "  and are NOT attributed to this VM - they do not, on their own, mean this VM needs investigation."
        Write-Host ("  Node-wide concern IDs (all VMs on {0}): [{1}]." -f $OwningNode, $concernIdSummary)
        Write-Host  "  See the events CSV (VmAttributed column) for which events belong to which VM."
    }
    if ($vssUnhealthy.Count -gt 0) {
        Write-Host ""
        Write-Host ("  {0} VSS writer(s) are not healthy: {1}" -f $vssUnhealthy.Count, ((@($vssUnhealthy | ForEach-Object { $_.Writer })) -join ', '))
        Write-Host  "  Unhealthy VSS writers commonly block Hyper-V checkpoint / backup operations."
    }
    if ($hasOrphans) {
        Write-Host ""
        Write-Host ("  {0} orphaned .avhdx file(s) are present in this VM's disk folder(s) but are NOT attached to the VM." -f @($orphans).Count)
        Write-Host  "  A stuck / failed merge or a leftover replica recovery point can leave these behind - confirm with"
        Write-Host  "  your backup team before removing any (see the Orphaned .avhdx Files section above for details)."
    }
    if ($holdState) {
        Write-Host ""
        Write-Host  "  ASSESSMENT: HOLD STATE (data-loss risk) - a checkpoint fork-commit / merge-failure signature AND"
        Write-Host  "  unmerged differencing disk(s) are present together. As a precaution this VM should NOT be"
        Write-Host  "  live/quick/storage-migrated or restarted until the differencing chain has been validated (and"
        Write-Host  "  merged if required); reopening an inconsistent chain can roll disks back to base and lose data."
    } elseif ($investigate) {
        Write-Host ""
        Write-Host  "  ASSESSMENT: INVESTIGATE - the specific checkpoint fork-commit signature was NOT observed; the"
        Write-Host  "  likely cause is a stalled / failed backup checkpoint or an unhealthy VSS writer rather than"
        Write-Host  "  on-disk chain corruption. Concern signal(s) for this VM:"
        if ($staleCheckpoints.Count -gt 0) {
            Write-Host ("    - {0} checkpoint(s) at or beyond the {1}-hour stale threshold (set via -StaleHours; default 24)." -f $staleCheckpoints.Count, $StaleHours)
        }
        if ($vmEventConcernCount -gt 0) {
            Write-Host ("    - {0} concerning Hyper-V event(s) for THIS VM [{1}] on {2} in the last {3}h (see the events section above)." -f $vmEventConcernCount, $vmConcernIdSummary, $OwningNode, $EventLookbackHours)
        }
        if ($vssUnhealthy.Count -gt 0) {
            Write-Host ("    - {0} unhealthy VSS writer(s) (see the VSS Writer Health section above)." -f $vssUnhealthy.Count)
        }
        if ($hasOrphans) {
            Write-Host ("    - {0} orphaned .avhdx file(s) in this VM's disk folder(s) (see the Orphaned .avhdx Files section above)." -f @($orphans).Count)
        }
    }
    if ($staleCheckpoints.Count -gt 0) {
        Write-Host ""
        Write-Host ("  {0} checkpoint(s) on this VM are older than {1} hours. A Third-Party Backup product that creates" -f $staleCheckpoints.Count, $StaleHours)
        Write-Host  "  Hyper-V checkpoints normally requests the checkpoint MERGE (removal) only AFTER it has successfully"
        Write-Host  "  copied the VM's data, so a checkpoint lingering well beyond the backup window suggests the backup"
        Write-Host  "  did not complete or did not issue the merge. Check that product for the progress / completion of"
        Write-Host  "  its backup job(s), and confirm whether these checkpoint(s) are expected (by design) or need manual"
        Write-Host ("  investigation. If checkpoint(s) on this VM are EXPECTED to persist beyond {0}h (e.g. a longer" -f $StaleHours)
        Write-Host  "  backup retention window), re-run with -StaleHours <n> (e.g. 48) to raise the threshold."
    }
    Write-Host ""
    if ($holdState) {
        Write-Host  "  Requested action: engage Microsoft Support (CSS) and/or your backup vendor to advise on the safe"
        Write-Host  "  next step to validate and merge / consolidate the differencing chain BEFORE any migration / restart."
    } elseif ($investigate) {
        Write-Host  "  Suggested next steps (operator / backup team FIRST - a Microsoft Support (CSS) case is NOT needed"
        Write-Host  "  for this result):"
        Write-Host  "    1. Check your backup product's recent job history for this VM - did the last backup complete?"
        Write-Host  "    2. Confirm whether the aged checkpoint is expected (by design) or was left behind by a failed backup."
        Write-Host  "    3. If it is a leftover backup checkpoint, merge / remove it via the backup product (preferred), or"
        Write-Host  "       via Hyper-V Manager once your backup team confirms it is safe to do so."
        Write-Host  "    4. Only open a Microsoft Support (CSS) case if a fork-commit signature later appears, or your"
        Write-Host  "       backup vendor rules out their product."
    } else {
        Write-Host  "  No action required from this result - no active checkpoint layer(s) and no concern signals were found."
    }
    Write-Host ""
    if ($holdState) {
        Write-Host  "  Artifacts from this audit to attach to the case:"
    } else {
        Write-Host  "  Artifacts from this audit (for your records / to share with your backup team):"
    }
    if ($OutputPath -and $reportFile) {
        Write-Host ("    - Text report : {0}" -f $reportFile)
        if ($eventsCsvName) {
            Write-Host ("    - Events CSV  : {0}" -f (Join-Path (Split-Path -Parent $reportFile) $eventsCsvName))
            Write-Host  "                    (full, untruncated Hyper-V event messages that back the findings above)"
        }
    } else {
        Write-Host  "    - (Re-run with -OutputPath <folder> to capture the .txt report and events .csv to attach.)"
    }
    Write-Host ""
    Write-Host ("  Reference: {0}" -f $script:TroubleshootTitle)
    Write-Host ("             {0}" -f $script:TroubleshootUrl)
    Write-Host "  ------------------------------------------------------------------------------"

    # ---- Overall RESULT / verdict (shown last, after the copy/paste PROBLEM STATEMENT above) --------
    Write-Host ""
    Write-Host "==================================================================="
    if ($hasCheckpoints) {
        Write-Alert "  RESULT: $totalCheckpoints CheckPoint (differencing/AVHDX) disk(s) present on '$VMName'." -Level Warning
    } else {
        Write-Alert "  RESULT: No CheckPoint AVHDX disks are attached to '$VMName'." -Level Good
    }
    if ($staleCheckpoints.Count -gt 0) {
        Write-Alert "  WARNING: $($staleCheckpoints.Count) checkpoint(s) are >= $StaleHours hours old (possibly stuck)." -Level Warning
    }
    if ($vmEventConcernCount -gt 0) {
        Write-Alert "  WARNING: $vmEventConcernCount concerning Hyper-V event(s) attributable to this VM (see the Concern=YES rows above)." -Level Warning
    } elseif ($nodeOnlyConcernCount -gt 0) {
        Write-Alert "  NOTE: $nodeOnlyConcernCount concerning Hyper-V event(s) on $OwningNode reference OTHER VMs (node context - not this VM)." -Level Info
    }
    if ($hasOrphans) {
        Write-Alert "  WARNING: $(@($orphans).Count) orphaned .avhdx file(s) present in this VM's disk folder(s) (not attached to the VM)." -Level Warning
    }
    if ($holdState) {
        Write-Host ""
        Write-Alert "  HOLD STATE (data-loss risk): a checkpoint fork-commit / merge-failure signature AND" -Level Critical
        Write-Alert "  unmerged differencing disk(s) are present together." -Level Critical
        Write-Alert ("  Why flagged: {0} active differencing (.avhdx) layer(s); fork-commit signature in event(s) [{1}]; {2} checkpoint(s) >= {3}h old." -f $totalCheckpoints, $vmConcernIdSummary, $staleCheckpoints.Count, $StaleHours) -Level Critical
        Write-Alert "  See the PROBLEM STATEMENT section above for the recommended next steps and a copy/paste case summary." -Level Critical
    } elseif ($investigate) {
        Write-Host ""
        Write-Alert "  INVESTIGATE: concern signals are present, but the specific checkpoint fork-commit signature" -Level Warning
        Write-Alert "  was NOT observed (likely a stalled / failed backup checkpoint or an unhealthy VSS writer)." -Level Warning
        Write-Alert ("  Why flagged: {0} concerning event(s) for this VM [{1}]; {2} checkpoint(s) >= {3}h old; {4} unhealthy VSS writer(s); {5} orphaned .avhdx file(s)." -f $vmEventConcernCount, $vmConcernIdSummary, $staleCheckpoints.Count, $StaleHours, $vssUnhealthy.Count, @($orphans).Count) -Level Warning
        Write-Alert "  See the FINDINGS TO INVESTIGATE section above for the suggested next steps (backup-team triage first; no Microsoft case needed yet)." -Level Warning
    }
    # Diagnostic-coverage TIP (independent of the verdict): if the Hyper-V-VMMS/Analytic channel is not
    # enabled on one or more nodes, say so HERE in the RESULT block - mid-report it is easily missed.
    if ($analyticNodesNeedEnable.Count -gt 0) {
        Write-Host ""
        Write-Alert ("  TIP: the Hyper-V-VMMS/Analytic channel is not enabled on: {0}." -f ($analyticNodesNeedEnable -join ', ')) -Level Info
        Write-Alert "  It is the only place the internal per-disk .vmcx revert ('Cannot revert configuration info for AVHD') is" -Level Info
        Write-Alert "  traced. Enabling it now (elevated, per node) captures that extra detail for the NEXT occurrence:" -Level Info
        Write-Alert "      wevtutil sl Microsoft-Windows-Hyper-V-VMMS-Analytic /e:true /q:true" -Level Info
    }
    Write-Host "==================================================================="

    # Always remind the reader this is diagnostic only - any interpretation / remediation goes via the
    # backup vendor (backup/VSS findings) or Microsoft Support (confirmed fork-commit).
    Write-Host ""
    Write-Alert "  NOTE: This report is DIAGNOSTIC ONLY and makes no changes. For backup / checkpoint-merge or VSS" -Level Info
    Write-Alert "  findings, engage your third-party backup vendor first; open a Microsoft Support (CSS) case for a" -Level Info
    Write-Alert "  confirmed fork-commit signature, or when the vendor rules out their product. Act on their advice." -Level Info
    Write-Host "==================================================================="

    # Per-VM result object for the pipeline (emitted only when the caller passed -PassThru; the end
    # block gates that). The human report above went to the host / transcript, never the pipeline.
    $recommendation = if ($holdState) { 'HOLD STATE' } elseif ($investigate) { 'INVESTIGATE' } else { 'OK' }

    # In Quiet mode the detailed report above was captured but not echoed; show a single concise verdict
    # line per VM (always to the real host, bypassing the buffer/quiet gate).
    if ($script:QuietConsole) {
        $verdictColour = switch ($recommendation) { 'HOLD STATE' { 'Red' } 'INVESTIGATE' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
        Microsoft.PowerShell.Utility\Write-Host ("  [{0}] {1}  (owner {2})" -f $VMName, $recommendation, $OwningNode) -ForegroundColor $verdictColour
    }

    # For HOLD STATE VMs, mine the captured buffer for the 'PROBLEM STATEMENT' support block so the HTML
    # can show it verbatim in a collapsed section (copy/paste-ready for a support case). Delimited by the
    # two dashed rules the console block prints around it.
    $supportCaseSummary = ''
    if ($holdState -and $script:VMReportBuffer) {
        $bufLines = $script:VMReportBuffer.ToArray()
        $startI = -1
        for ($bi = 0; $bi -lt $bufLines.Count; $bi++) { if ($bufLines[$bi] -like '*PROBLEM STATEMENT*') { $startI = $bi; break } }
        if ($startI -ge 0) {
            $dashSeen = 0; $endI = $bufLines.Count - 1
            for ($bj = $startI; $bj -lt $bufLines.Count; $bj++) {
                if ($bufLines[$bj] -match '^\s*-{20,}\s*$') { $dashSeen++; if ($dashSeen -ge 2) { $endI = $bj; break } }
            }
            $supportCaseSummary = ($bufLines[$startI..$endI] -join "`r`n")
        }
    }

    # Build the structured detail the HTML fleet report renders (only the fields it needs). This is
    # carried on the result object's .ReportData property and consumed once, in the end block. Purpose
    # text mirrors the console 'Checkpoints' table so the HTML and console agree.
    $ckptRowsForHtml = @($checkpoints | Sort-Object CreationTimeUtc | ForEach-Object {
        $purpose = switch -Wildcard ("$($_.SnapType)") {
            'AppConsistent*' { 'Replica recovery point (app-consistent)'; break }
            'Synced*'        { 'Replica synced checkpoint';                break }
            '*Replica*'      { 'Hyper-V Replica checkpoint';               break }
            'Recovery'       { 'Replica recovery point';                   break }
            'Planned'        { 'Planned failover checkpoint';              break }
            'Production*'    { 'Production checkpoint (backup)';           break }
            'Standard'       { 'Standard checkpoint (manual/backup)';      break }
            default          { if ($_.SnapType) { $_.SnapType } else { 'Unknown' } }
        }
        $ageH = [math]::Round(([DateTime]::UtcNow - $_.CreationTimeUtc).TotalHours, 1)
        [pscustomobject]@{
            Name    = [string]$_.Name
            Type    = [string]$_.Type
            Purpose = $purpose
            Created = $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ss')
            AgeHrs  = $ageH
            Stale   = ($ageH -ge $StaleHours)
            Parent  = [string]$_.Parent
        }
    })
    # v0.2.15: the per-VM detail's event breakdown is built from events ATTRIBUTABLE TO THIS VM only
    # ($vmConcernEvents), NOT the node-wide set. Mixing other VMs' events into a VM's own section made
    # the detail misleading (e.g. another VM's 18012 / 19090 shown under this VM) and skewed the
    # driver wording. The node-wide TOTAL is still surfaced as a count in the KV grid for context; the
    # full node-wide list lives in the shared _NodeEvents CSV.
    $eventBreakdownForHtml = @($vmConcernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object {
        $times = @($_.Group.'Time (UTC)' | Sort-Object)
        [pscustomobject]@{
            Id     = [int]$_.Name
            Count  = $_.Count
            First  = [string]$times[0]
            Last   = [string]$times[-1]
            Sample = [string](@($_.Group)[0].Message)
        }
    })
    $replForHtml = if ($replInfo -and $replInfo.Repl) {
        [pscustomobject]@{
            Enabled             = $true
            State               = [string]$replInfo.Repl.State
            Health              = [string]$replInfo.Repl.Health
            Mode                = [string]$replInfo.Repl.Mode
            Primary             = [string]$replInfo.Repl.PrimaryServerName
            Replica             = [string]$replInfo.Repl.ReplicaServerName
            LastReplicationTime = [string]$replInfo.Repl.LastReplicationTime
        }
    } else {
        [pscustomobject]@{ Enabled = $false; State = ''; Health = ''; Mode = ''; Primary = ''; Replica = ''; LastReplicationTime = '' }
    }
    $vssStateForHtml = if (-not $vssWriters -or @($vssWriters).Count -eq 0) { 'Unavailable' } elseif ($vssUnhealthy.Count -gt 0) { 'Unhealthy' } else { 'Healthy' }
    # Orphaned .avhdx rows the HTML per-VM detail renders (name, size, created + last-write timestamps,
    # full path). Newest-written first. v0.2.14 adds a per-orphan CLASS (Rollback / StuckMerge /
    # LiveMount / Leftover) + an age-in-days + a neutral 'Likely' read - NEVER 'safe to delete'.
    $orphanClassLookup = @{}
    foreach ($oc in $orphanClassified) { if ($oc.Orphan -and $oc.Orphan.FullName) { $orphanClassLookup[[string]$oc.Orphan.FullName] = $oc } }
    $orphanRowsForHtml = @($orphans | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {
        $ocm     = $orphanClassLookup[[string]$_.FullName]
        $cls     = if ($ocm) { [string]$ocm.Class } else { 'Leftover' }
        $mergeId = if ($ocm) { $ocm.MergeEventId } else { $null }
        $lockTime = if ($ocm) { [string]$ocm.LockEventTime } else { $null }
        $ageDays = if ($_.LastWriteTimeUtc) { [math]::Round(([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalDays, 1) } else { $null }
        $likely  = switch ($cls) {
            'Rollback'     { 'Possible PAST rollback aftermath - do NOT remove; investigate / recover' }
            'StuckMerge'   { ("Possible stuck / failed merge (event {0}) - investigate before any action" -f $mergeId) }
            'SafeToDelete' { if ($lockTime) { "Likely SAFE to delete - a delete was attempted on $lockTime UTC but blocked by a transient in-use lock (event 16220, 0x80070020); the event states the file is 'safe to delete at any time'. Confirm with your backup team / VM owner, then remove." } else { "Likely SAFE to delete - a prior delete was blocked by a transient in-use lock (event 16220, 0x80070020); the event states the file is 'safe to delete at any time'. Confirm with your backup team / VM owner, then remove." } }
            'LiveMount'    { 'Likely backup live-mount / temp artifact - confirm with backup team' }
            default        { 'Leftover backup/replica file - confirm with backup team before any action' }
        }
        [pscustomobject]@{
            Name      = [string]$_.Name
            SizeGB    = [math]::Round($_.Length / 1GB, 2)
            Created   = if ($_.CreationTimeUtc)  { $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }  else { '' }
            LastWrite = if ($_.LastWriteTimeUtc) { $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') } else { '' }
            AgeDays   = $ageDays
            Class     = $cls
            Likely    = $likely
            FullName  = [string]$_.FullName
        }
    })
    $reportData = [pscustomobject]@{
        VMId                 = [string]$vm.VMId
        Status               = [string]$vm.Status
        State                = [string]$vm.State
        Version              = [string]$vm.Version
        HostMaxVersion       = [string]$hostMaxVer
        VmVerOlder           = [bool]$vmVerOlder
        Uptime               = [string]$vm.Uptime
        CheckpointType       = [string]$vm.CheckpointType
        AutomaticCheckpoints = [bool]$vm.AutomaticCheckpointsEnabled
        AttachedDiskCount    = @($diskReports).Count
        CheckpointLayers     = [int]$totalCheckpoints
        Checkpoints          = $ckptRowsForHtml
        StaleCheckpointCount = $staleCheckpoints.Count
        StaleHours           = $StaleHours
        Replication          = $replForHtml
        VssState             = $vssStateForHtml
        VssTotal             = @($vssWriters).Count
        VssUnhealthyCount    = $vssUnhealthy.Count
        VssUnhealthy         = @($vssUnhealthy | ForEach-Object { [pscustomobject]@{ Writer = [string]$_.Writer; State = [string]$_.State; LastError = [string]$_.'Last error' } })
        AnalyticNodesNeedEnable = @($analyticNodesNeedEnable)
        CsvVolumes           = @($csvReport)
        OrphanCount          = @($orphans).Count
        Orphans              = $orphanRowsForHtml
        HasOrphans           = [bool]$hasOrphans
        HasForkSignature     = [bool]$hasForkSignature
        EventConcernCount    = $eventConcernCount
        VmEventConcernCount  = $vmEventConcernCount
        EventBreakdown       = $eventBreakdownForHtml
        EventLookbackHours   = $EventLookbackHours
        EventsCsvName        = [string]$eventsCsvName
        NodeEventsCsvName    = [string]$script:NodeCsvNameByNode[$OwningNode]
        SupportCaseSummary   = [string]$supportCaseSummary
        # v0.2.14 additions.
        VmHighConcernCount   = [int]$vmHighConcernCount
        VmLowConcernCount    = [int]$vmLowConcernCount
        LowSignalOnly        = [bool]$lowSignalOnly
        NodeDominantNote     = [string]$nodeDominantNote
        ReplHealth           = [string]$replHealth
        ReplUnhealthy        = [bool]$replUnhealthy
        ReplCritical         = [bool]$replCritical
        SeverityScore        = [int]$severityScore
        HasRollbackFingerprint = [bool]$hasRollbackFingerprint
        RollbackDate         = [string]$rollbackDate
        HasStuckMergeOrphan  = [bool]$hasStuckMergeOrphan
        OrphanOnlyLiveMount  = [bool]$orphanOnlyLiveMount
        HistoricForkConfirmed = [bool]$historicForkConfirmed
        Historic             = if ($historicCorrelation) {
            [pscustomobject]@{
                Windows            = @($historicCorrelation.Windows)
                WindowMinutes      = [int]$historicCorrelation.WindowMinutes
                NodesSearched      = @($historicCorrelation.NodesSearched)
                MatchCount         = [int]$historicCorrelation.MatchCount
                Matches            = @($historicCorrelation.Matches)
                OldestAvailableUtc = [string]$historicCorrelation.OldestAvailableUtc
                LogsWrappedPastWindow = [bool]$historicCorrelation.LogsWrappedPastWindow
            }
        } else { $null }
    }

    $summaryArgs = @{
        Recommendation          = $recommendation
        HoldState               = $holdState
        HasAttachedCheckpoints  = $hasCheckpoints
        HasStaleCheckpoints     = ($staleCheckpoints.Count -gt 0)
        HasOrphanedCheckpoints  = $hasOrphans
        AttachedCheckpointCount = [int]$totalCheckpoints
        StaleCheckpointCount    = $staleCheckpoints.Count
        ConcernEventCount       = $vmEventConcernCount
        Owner                   = $OwningNode
        ReportData              = $reportData
    }
    return (New-AuditSummary @summaryArgs)

    }
    catch {
        # Safety net: any unexpected terminating error for THIS VM is reported and swallowed so a
        # multi-VM run continues with the next VM instead of aborting the whole batch. Still emit a
        # per-VM result object (Recommendation = 'ERROR') so a -PassThru fleet run has a row per VM.
        Write-Alert "  ERROR auditing '$VMName': $($_.Exception.Message)" -Level Critical
        New-AuditSummary -Recommendation 'ERROR' -Owner $OwningNode -Detail $_.Exception.Message
    }
    finally {
        # v0.2.15: close any still-open per-VM section timer, then record this VM's TOTAL audit time
        # (covers both input and discovered VMs). Step numbers repeat per VM by design; the Detail
        # (VM name + source) distinguishes them in the telemetry JSON.
        if ($null -ne $script:VMSectionStartUtc) {
            Add-TelemetryEntry -Step ('1.10.{0:00}' -f $script:VMSectionStepNo) -Phase $script:VMSectionName -Detail "$VMName [$script:CurrentVMSource]" -StartUtc $script:VMSectionStartUtc -EndUtc (Get-TelemetryNow)
            $script:VMSectionStartUtc = $null
        }
        if ($vmAuditStart) { Add-TelemetryEntry -Step '1.10' -Phase 'VM audit (total)' -Detail "$VMName [$script:CurrentVMSource]" -StartUtc $vmAuditStart -EndUtc (Get-TelemetryNow) }
        # v0.2.14: remoting sessions are POOLED per owning node ($script:SessionByNode) and reused
        # across VMs; they are disposed together in the end block. Just drop this VM's reference here
        # (do NOT close the pooled session - the next VM on this node reuses it).
        $script:OwnerSession = $null
        # Flush the captured report buffer to the per-VM .txt (when -OutputPath was supplied), then
        # deactivate the buffer so begin/end-block messages are shown normally again.
        if ($reportFile -and $script:VMReportBuffer) {
            try {
                [System.IO.File]::WriteAllLines($reportFile, $script:VMReportBuffer.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
                if (-not $script:QuietConsole) { Microsoft.PowerShell.Utility\Write-Host "Report saved to: $reportFile" }
            } catch {
                Write-Warning "Could not write the per-VM report file '$reportFile': $($_.Exception.Message)"
            }
        }
        $script:VMReportBuffer = $null
    }
}

# Collect all requested VMs (works for both the -VMName array and pipeline input) so the parent
# progress bar can show an accurate "VM X of Y"; $VMSectionTotal drives the per-VM sub-progress %.
$script:PendingVMNames = [System.Collections.Generic.List[string]]::new()
$script:VMSectionTotal = 13
# v0.2.15: stamped onto each VM's telemetry Detail so the JSON can tell operator-requested (Input) VMs
# apart from ones auto-added via -IncludeDiscoveredVMs (Discovered). Set around the discovered loop.
$script:CurrentVMSource = 'Input'
# Accumulate every per-VM result object for the single HTML fleet report built at the end of the run.
$script:AllAuditResults = [System.Collections.Generic.List[object]]::new()
# High-risk VM names discovered in event data (referenced by a merge-failed / merge-interrupted /
# cannot-load-config signal) but not necessarily in the audit list. Cross-checked and de-duplicated in
# the end block. Each entry: [pscustomobject]@{ Name; Reason; SourceVM; SourceNode }.
$script:DiscoveredCandidates = [System.Collections.Generic.List[object]]::new()
# Hard cap on how many discovered VMs -IncludeDiscoveredVMs will auto-audit (guards against a runaway
# expansion on a very busy node).
$script:MaxDiscoveredToAudit = 25
# Cluster storage-health snapshot (populated once, in the end block, unless -SkipStorageHealth).
$script:ClusterStorageHealth = $null
# v0.2.14: per-node Worker/VMMS event cache (keyed 'node|lookbackHours'). The event scan is node-wide,
# so caching it means each node is read ONCE per run rather than once per VM on that node.
$script:NodeEventCache = @{}
# v0.2.14: records the shared _NodeEvents_<node>_<date>.csv name written once per node, so each VM's
# report can point to the node-wide event detail without duplicating it into every per-VM CSV.
$script:NodeCsvNameByNode = @{}
# v0.2.14 fleet-scale caches: cluster-wide data that is IDENTICAL for every VM in a run is fetched
# ONCE and reused, instead of being re-queried per VM. On a large cluster (hundreds of VMs) this
# removes the bulk of the redundant cluster-API round-trips and remoting-session churn.
$script:ClusterNameCache    = $null   # resolved cluster name (Get-Cluster, once)
$script:ClusterNodesCache   = $null   # node-name array (Get-ClusterNode, once)
$script:GroupOwnerByVm      = $null   # hashtable VMName -> OwnerNode (Get-ClusterGroup, once)
$script:ProbeVmNodeMap      = $null   # hashtable VMName -> node for non-clustered VMs (per-node Get-VM, once)
$script:SessionByNode       = @{}     # pooled PSSession per owning node, reused across VMs, disposed in end block
$script:HostVersionsByNode  = @{}     # hashtable node -> supported VM config versions (Get-VMHostSupportedVersion, once per node)
$script:ClusterCsvCache     = $null   # Get-ClusterSharedVolume result (once)

# Exclusion list: VM names to SKIP, read ONCE from -ExcludedVMListCsv into a case-INSENSITIVE HashSet
# so the process-block membership test is O(1). A CSV with a 'VMName' header column is preferred; a
# headerless single-column file also works. A missing / unreadable file is a non-fatal WARNING - the
# run proceeds with no exclusions. $script:ExcludedMatched records the names actually skipped so the
# end block can report them.
$script:ExcludedVMNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
$script:ExcludedMatched = [System.Collections.Generic.List[string]]::new()
if ($ExcludedVMListCsv) {
    if (Test-Path -LiteralPath $ExcludedVMListCsv) {
        try {
            $exRows  = @(Import-Csv -LiteralPath $ExcludedVMListCsv -ErrorAction Stop)
            $exNames = @()
            if ($exRows.Count -gt 0 -and $exRows[0].PSObject.Properties['VMName']) {
                $exNames = @($exRows | ForEach-Object { [string]$_.VMName })
            } else {
                # No 'VMName' header - treat it as a plain one-name-per-line list (skip a stray header).
                $exNames = @(Get-Content -LiteralPath $ExcludedVMListCsv -ErrorAction Stop |
                    ForEach-Object { $_.Trim().Trim('"') } |
                    Where-Object { $_ -and $_ -ne 'VMName' })
            }
            foreach ($exName in $exNames) { if ($exName -and $exName.Trim()) { [void]$script:ExcludedVMNames.Add($exName.Trim()) } }
            Write-Host ("Exclusion list: loaded {0} VM name(s) to skip from '{1}'." -f $script:ExcludedVMNames.Count, $ExcludedVMListCsv)
        } catch {
            Write-Alert ("WARNING: could not read -ExcludedVMListCsv '{0}': {1}. Proceeding with NO exclusions." -f $ExcludedVMListCsv, $_.Exception.Message) -Level Warning
        }
    } else {
        Write-Alert ("WARNING: -ExcludedVMListCsv '{0}' was not found. Proceeding with NO exclusions." -f $ExcludedVMListCsv) -Level Warning
    }
}

# Resolve a single per-run output sub-folder (once per invocation) so every VM in this run is
# grouped together and repeated runs never collide. Only created when -OutputPath is supplied.
$script:RunFolder = $null
if ($OutputPath) {
    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd_HHmmss') + 'Z'
    $script:RunFolder = Join-Path $OutputPath "CheckpointAudit_$stamp"
    if (-not (Test-Path -LiteralPath $script:RunFolder)) {
        New-Item -ItemType Directory -Path $script:RunFolder -Force | Out-Null
    }
    Write-Host "Writing per-VM reports to: $script:RunFolder"
} else {
    # Option C: no -OutputPath means console output only (nothing saved). Warn UP FRONT so the operator
    # can cancel and re-run with -OutputPath rather than discover it after a long multi-VM run.
    Write-Alert "WARNING: -OutputPath was not supplied - console output ONLY; NO .txt report or events .csv will be saved." -Level Warning
    Write-Alert "         Re-run with -OutputPath <folder> to capture files to attach to a backup-vendor / Microsoft (CSS) case." -Level Warning
    Write-Host ""
}

}

# Audit each requested VM. -VMName accepts an array and pipeline input (e.g. Get-VM | ...).
# Each VM is audited independently, so one VM's failure does not stop the rest. With -OutputPath,
# each VM gets its own .txt transcript and .csv event export.
process {
    foreach ($item in $VMName) {
        # Normalize each input to a VM name string: accept a plain string, or a VM object (Get-VM)
        # via its .VMName / .Name property. This lets callers pass -VMName $VMs (objects),
        # -VMName $VMs.Name (strings), or pipe 'Get-VM | ...' without pre-extracting the name.
        $singleVMName =
            if ($item -is [string]) { $item }
            elseif ($item.PSObject.Properties['VMName'] -and $item.VMName) { [string]$item.VMName }
            elseif ($item.PSObject.Properties['Name']   -and $item.Name)   { [string]$item.Name }
            else { [string]$item }

        if ([string]::IsNullOrWhiteSpace($singleVMName)) {
            Write-Warning 'Skipping an input with no resolvable VM name.'
            continue
        }
        if ($singleVMName.Length -gt 100) {
            $preview = $singleVMName.Substring(0, [Math]::Min(40, $singleVMName.Length))
            Write-Warning ("Skipping '{0}...': resolved name is {1} chars (>100). Pass VM names or VM objects, not a single joined string." -f $preview, $singleVMName.Length)
            continue
        }

        # Skip VMs on the exclusion list (-ExcludedVMListCsv), matched case-INSENSITIVELY. Recorded so
        # the end block can report which VMs were skipped.
        if ($script:ExcludedVMNames.Count -gt 0 -and $script:ExcludedVMNames.Contains($singleVMName.Trim())) {
            Write-Host ("Skipping '{0}': present in the -ExcludedVMListCsv exclusion list." -f $singleVMName)
            [void]$script:ExcludedMatched.Add($singleVMName)
            continue
        }

        # Defer the actual audit to the end block, where the true total is known (accurate X of Y).
        $script:PendingVMNames.Add($singleVMName)
    }
}

# Audit each collected VM. Runs in the end block so the parent progress bar knows the total count.
end {
    $vmTotal = $script:PendingVMNames.Count
    # Report any VMs skipped by the exclusion list (always shown, even in quiet mode).
    if (@($script:ExcludedMatched).Count -gt 0) {
        Write-Alert ("Excluded {0} VM(s) from this run via -ExcludedVMListCsv: {1}" -f @($script:ExcludedMatched).Count, (@($script:ExcludedMatched | Sort-Object -Unique) -join ', ')) -Level Info
    }
    if ($vmTotal -eq 0) {
        Write-Alert 'No VMs to audit (all requested VM(s) were excluded, or none were supplied).' -Level Warning
        return
    }
    $vmIndex = 0
    foreach ($name in $script:PendingVMNames) {
        $vmIndex++
        Write-Progress -Id 1 -Activity 'Hyper-V VM checkpoint / differencing-disk audit' `
            -Status ("VM {0} of {1}: {2}" -f $vmIndex, $vmTotal, $name) `
            -PercentComplete ([int](($vmIndex - 1) * 100 / $vmTotal))

        $vmSummary = Invoke-VMCheckpointAudit -VMName $name -Cluster $Cluster -OutputPath $script:RunFolder -StaleHours $StaleHours `
            -SkipWorkerEvents:$SkipWorkerEvents -EventLookbackHours $EventLookbackHours `
            -WorkerEventIds $WorkerEventIds -ContextEventIds $ContextEventIds -ErrorCodePatterns $ErrorCodePatterns `
            -SkipAnalyticCheck:$SkipAnalyticCheck

        # Keep every per-VM result for the single HTML fleet report built after the loop (filter to real
        # summary objects so any stray pipeline output cannot become a phantom row).
        foreach ($s in @($vmSummary)) {
            if ($s -and $s.PSObject.Properties['Recommendation']) {
                # v0.2.14: tag how this VM entered the run so the report can distinguish operator-
                # requested (Input) VMs from ones the tool auto-added via -IncludeDiscoveredVMs.
                Add-Member -InputObject $s -NotePropertyName Source -NotePropertyValue 'Input' -Force
                [void]$script:AllAuditResults.Add($s)
            }
        }

        # Emit the per-VM result object to the pipeline ONLY when -PassThru was requested; otherwise the
        # run is 'report to host / files' only and the pipeline stays empty.
        if ($PassThru) { $vmSummary }

        # Clear this VM's sub-progress bar before moving to the next VM.
        Write-Progress -Id 2 -ParentId 1 -Activity ("Auditing VM: {0}" -f $name) -Completed
    }
    Write-Progress -Id 1 -Activity 'Hyper-V VM checkpoint / differencing-disk audit' -Completed

    # Resolve the report / zip base name from the cluster once (used by both the HTML and the zip).
    $clusterForName = @($script:AllAuditResults | ForEach-Object { $_.Cluster } | Where-Object { $_ })
    $clusterForName = if ($clusterForName.Count -gt 0) { [string]$clusterForName[0] } elseif ($Cluster) { $Cluster } else { 'cluster' }
    $safeCluster    = ($clusterForName -replace '[^\w.\-]', '_')
    # Report / zip file-name timestamp. Reuse the per-run folder's UTC stamp (yyyy-MM-dd_HHmmssZ) so the
    # HTML/zip names MATCH the run folder exactly and repeated same-day runs never overwrite each other.
    # Falls back to a fresh UTC stamp when no -OutputPath run folder exists (console/current-dir run).
    $runStamp       = if ($script:RunFolder) { (Split-Path $script:RunFolder -Leaf) -replace '^CheckpointAudit_', '' } else { [DateTime]::UtcNow.ToString('yyyy-MM-dd_HHmmss') + 'Z' }
    $htmlFileName   = "VMCheckpointAudit-{0}-{1}.html" -f $safeCluster, $runStamp

    # Cross-check the high-risk VM names discovered in event data against REAL clustered VMs (this
    # discards paths / noise), drop any already audited, and de-duplicate. Always surfaced; only
    # auto-audited when -IncludeDiscoveredVMs is set.
    $discoveredVMs = @()
    if (@($script:DiscoveredCandidates).Count -gt 0) {
        $auditedNames = @($script:AllAuditResults | ForEach-Object { [string]$_.VMName })
        $clusterVmNames = @()
        try { $clusterVmNames = @(Get-ClusterGroup -Cluster $clusterForName -ErrorAction Stop | Where-Object { $_.GroupType -eq 'VirtualMachine' } | ForEach-Object { [string]$_.Name }) } catch { }
        $seenDisc = @{}
        foreach ($cand in $script:DiscoveredCandidates) {
            if (-not $cand.Name) { continue }
            $match = $clusterVmNames | Where-Object { $_ -eq $cand.Name } | Select-Object -First 1
            if (-not $match) { continue }
            if ($auditedNames -contains $match) { continue }
            if ($script:ExcludedVMNames.Count -gt 0 -and $script:ExcludedVMNames.Contains($match)) { continue }
            if ($seenDisc.ContainsKey($match.ToLower())) { continue }
            $seenDisc[$match.ToLower()] = $true
            $discoveredVMs += [pscustomobject]@{ Name = $match; Reason = [string]$cand.Reason }
        }
    }

    # Optionally auto-audit the discovered VMs (bounded, NON-recursive: their own discoveries are not
    # expanded). They join the same fleet report; anything past the cap is still surfaced below.
    if ($IncludeDiscoveredVMs -and $discoveredVMs.Count -gt 0) {
        $toAudit = @($discoveredVMs | Select-Object -First $script:MaxDiscoveredToAudit)
        $script:CurrentVMSource = 'Discovered'
        try {
            Microsoft.PowerShell.Utility\Write-Host ""
            Microsoft.PowerShell.Utility\Write-Host ("  -IncludeDiscoveredVMs: auditing {0} discovered VM(s)..." -f $toAudit.Count) -ForegroundColor Cyan
            foreach ($dv in $toAudit) {
                $ds = Invoke-VMCheckpointAudit -VMName $dv.Name -Cluster $Cluster -OutputPath $script:RunFolder -StaleHours $StaleHours `
                    -SkipWorkerEvents:$SkipWorkerEvents -EventLookbackHours $EventLookbackHours `
                    -WorkerEventIds $WorkerEventIds -ContextEventIds $ContextEventIds -ErrorCodePatterns $ErrorCodePatterns `
                    -SkipAnalyticCheck:$SkipAnalyticCheck
                foreach ($s in @($ds)) {
                    if ($s -and $s.PSObject.Properties['Recommendation']) { Add-Member -InputObject $s -NotePropertyName Source -NotePropertyValue 'Discovered' -Force; [void]$script:AllAuditResults.Add($s); if ($PassThru) { $s } }
                }
            }
            # Remove the now-audited VMs from the discovered list (no re-expansion of new candidates).
            $auditedNames = @($script:AllAuditResults | ForEach-Object { [string]$_.VMName })
            $discoveredVMs = @($discoveredVMs | Where-Object { $auditedNames -notcontains $_.Name })
        } finally {
            # v0.2.15 (F11): always restore the source label, even if the discovered loop throws.
            $script:CurrentVMSource = 'Input'
        }
    }

    # v0.2.14: dispose the pooled per-node remoting sessions now that all VM audits are complete. The
    # storage-health snapshot below opens its own short-lived session, so it is unaffected.
    if ($script:SessionByNode -and $script:SessionByNode.Count -gt 0) {
        foreach ($sess in @($script:SessionByNode.Values)) {
            if ($sess) { Remove-PSSession -Session $sess -ErrorAction SilentlyContinue }
        }
        $script:SessionByNode = @{}
    }

    # Read-only cluster storage-health snapshot (once per run), unless suppressed. Query it from one of
    # the owning nodes we already reached (local if this host is that node).
    if (-not $SkipStorageHealth) {
        Write-Progress -Id 1 -Activity 'Hyper-V VM checkpoint / differencing-disk audit' -Status 'Gathering cluster storage health' -PercentComplete 99
        $ownerNodes  = @($script:AllAuditResults | ForEach-Object { $_.OwningNode } | Where-Object { $_ } | Sort-Object -Unique)
        $storageNode = if ($ownerNodes.Count -gt 0) { [string]$ownerNodes[0] } else { $env:COMPUTERNAME }
        $storageStart = Get-TelemetryNow
        $script:ClusterStorageHealth = Get-ClusterStorageHealthSnapshot -TargetNode $storageNode
        Add-TelemetryEntry -Step '1.30' -Phase 'Cluster storage-health snapshot' -Detail $storageNode -StartUtc $storageStart -EndUtc (Get-TelemetryNow)
        Write-Progress -Id 1 -Activity 'Hyper-V VM checkpoint / differencing-disk audit' -Completed
    }

    # Single self-contained HTML fleet report (ON by default; suppress with -NoHtml). Destination:
    # explicit -HtmlReportPath (a folder, or a full path ending in .html) > the -OutputPath per-run
    # sub-folder > the current directory. Any failure here is non-fatal to the run.
    $htmlWritten = $null
    if (-not $NoHtml -and $script:AllAuditResults.Count -gt 0) {
        try {
            if ($HtmlReportPath) {
                if ($HtmlReportPath -match '\.html?$') {
                    $htmlPath = $HtmlReportPath
                    $htmlDir  = Split-Path -Parent $htmlPath
                    if (-not $htmlDir) { $htmlDir = (Get-Location).Path; $htmlPath = Join-Path $htmlDir $htmlPath }
                } else {
                    $htmlDir  = $HtmlReportPath
                    $htmlPath = Join-Path $htmlDir $htmlFileName
                }
            } elseif ($script:RunFolder) {
                $htmlDir  = $script:RunFolder
                $htmlPath = Join-Path $htmlDir $htmlFileName
            } else {
                $htmlDir  = (Get-Location).Path
                $htmlPath = Join-Path $htmlDir $htmlFileName
            }
            if ($htmlDir -and -not (Test-Path -LiteralPath $htmlDir)) {
                New-Item -ItemType Directory -Path $htmlDir -Force | Out-Null
            }

            # End-to-end elapsed (floor the hours so 1h59m reads 01:59:xx, not 02:xx via [int] rounding).
            $runElapsed  = $script:RunStopwatch.Elapsed
            $genTimeText = '{0:00}:{1:00}:{2:00}' -f [int][math]::Floor($runElapsed.TotalHours), $runElapsed.Minutes, $runElapsed.Seconds

            # Cluster-scale metadata for the report header: TOTAL nodes in the cluster and the TOTAL
            # number of Cluster Shared Volumes (both cached once during the run). They give context for
            # the event-log scan scope and the run time - the Worker/VMMS scan cost scales with node
            # count, and CSV count is a rough proxy for how much storage the run touched.
            $clusterNodeCountForHtml = if ($script:ClusterNodesCache) { @($script:ClusterNodesCache).Count } else { 0 }
            $clusterCsvCountForHtml  = if ($script:ClusterCsvCache)   { @($script:ClusterCsvCache).Count }  else { 0 }

            $htmlStart = Get-TelemetryNow
            $html = ConvertTo-VMCheckpointAuditHtml -Results $script:AllAuditResults.ToArray() `
                -StaleHours $StaleHours -EventLookbackHours $EventLookbackHours `
                -ClusterName $clusterForName -GeneratedUtc ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) `
                -DiscoveredVMs $discoveredVMs -StorageHealth $script:ClusterStorageHealth -IncludeDiscoveredVMs:$IncludeDiscoveredVMs `
                -ScriptVersion $script:ScriptVersion `
                -ReportGenerationTime $genTimeText `
                -ClusterNodeCount $clusterNodeCountForHtml -ClusterCsvCount $clusterCsvCountForHtml
            [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))
            Add-TelemetryEntry -Step '1.40' -Phase 'HTML report render + write' -Detail (Split-Path $htmlPath -Leaf) -StartUtc $htmlStart -EndUtc (Get-TelemetryNow)
            $htmlWritten = $htmlPath
            Write-Host ""
            Write-Host "HTML fleet report written to: $htmlPath"
        } catch {
            Write-Alert "  WARNING: could not write the HTML fleet report: $($_.Exception.Message)" -Level Warning
        }
    }

    # v0.2.15: MANDATORY performance telemetry. Write the structured per-step timing breakdown as JSON
    # to the run folder BEFORE the zip is built, so it is bundled into the results zip. It is for our
    # own future performance tuning; it is deliberately NOT surfaced in the HTML report. Only written
    # when a run folder exists (i.e. -OutputPath was supplied). Non-fatal on failure.
    if ($script:RunFolder -and (Test-Path -LiteralPath $script:RunFolder)) {
        try {
            $telNodeCount = if ($script:ClusterNodesCache) { @($script:ClusterNodesCache).Count } else { 0 }
            $telCsvCount  = if ($script:ClusterCsvCache)   { @($script:ClusterCsvCache).Count }  else { 0 }
            # Record the ROOT step (1) covering the whole run, so the JSON has one top-level total.
            Add-TelemetryEntry -Step '1' -Phase 'Script run (total)' -Detail $clusterForName -StartUtc $script:TelemetryClockBaseUtc -EndUtc (Get-TelemetryNow)
            # F2: .ToArray() (never @() a generic List - the empty-list @() throws on some WinPS 5.1 builds).
            $telSteps        = $script:Telemetry.ToArray()
            $telClusterField = [string]$clusterForName
            $telFileCluster  = $safeCluster
            # v0.2.15 (-AnonymizeTelemetry): replace the cluster / node / VM names with STABLE pseudonyms
            # so the timing data can be shared for perf analysis without exposing customer identifiers.
            # The longest real string is replaced FIRST so a name that is a substring of another (e.g. a
            # short node name inside an FQDN or a VM name) is substituted correctly.
            if ($AnonymizeTelemetry) {
                $anonPairs = [System.Collections.Generic.List[object]]::new()
                [void]$anonPairs.Add([pscustomobject]@{ Real = [string]$clusterForName; Pseudo = 'CLUSTER' })
                $niAnon = 0
                foreach ($n in @($script:ClusterNodesCache | Where-Object { $_ } | Sort-Object -Unique)) {
                    $niAnon++
                    [void]$anonPairs.Add([pscustomobject]@{ Real = [string]$n; Pseudo = ('NODE-{0:00}' -f $niAnon) })
                    $shortN = ([string]$n -split '\.')[0]
                    if ($shortN -and $shortN -ne [string]$n) { [void]$anonPairs.Add([pscustomobject]@{ Real = $shortN; Pseudo = ('NODE-{0:00}' -f $niAnon) }) }
                }
                $viAnon = 0
                foreach ($vn in @($script:AllAuditResults | ForEach-Object { [string]$_.VMName } | Where-Object { $_ } | Sort-Object -Unique)) {
                    $viAnon++
                    [void]$anonPairs.Add([pscustomobject]@{ Real = $vn; Pseudo = ('VM-{0:000}' -f $viAnon) })
                }
                $anonOrdered = @($anonPairs | Where-Object { $_.Real } | Sort-Object { $_.Real.Length } -Descending)
                $protect = {
                    param([string]$Text)
                    if ([string]::IsNullOrEmpty($Text)) { return $Text }
                    foreach ($p in $anonOrdered) { $Text = [regex]::Replace($Text, [regex]::Escape($p.Real), $p.Pseudo, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
                    $Text
                }
                $telClusterField = & $protect $clusterForName
                $telFileCluster  = 'anon'
                $telSteps = @($telSteps | ForEach-Object {
                    [pscustomobject]@{
                        Order = $_.Order; Step = $_.Step; Phase = $_.Phase; Detail = (& $protect ([string]$_.Detail))
                        StartUtc = $_.StartUtc; EndUtc = $_.EndUtc; DurationMs = $_.DurationMs; DurationSec = $_.DurationSec
                    }
                })
            }
            $telName = "code_execution_perf_telemetry_{0}_{1}.json" -f $telFileCluster, $runStamp
            $telPath = Join-Path $script:RunFolder $telName
            $telDoc  = [ordered]@{
                Tool               = 'Get-HyperVVMCheckpointHealth.ps1'
                ScriptVersion      = $script:ScriptVersion
                Cluster            = $telClusterField
                Anonymized         = [bool]$AnonymizeTelemetry
                GeneratedUtc       = (Get-TelemetryNow).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                VMsAudited         = $script:AllAuditResults.Count
                ClusterNodes       = $telNodeCount
                ClusterCsvs        = $telCsvCount
                EventLookbackHours = $EventLookbackHours
                SkipWorkerEvents   = [bool]$SkipWorkerEvents
                SkipStorageHealth  = [bool]$SkipStorageHealth
                TotalRunSeconds    = [math]::Round($script:RunStopwatch.Elapsed.TotalSeconds, 3)
                StepNumbering      = '1 = whole run; 1.10 = per-VM audit total (repeats per VM); 1.10.NN = per-VM section (NN two-digit, gaps of 5); 1.10.50.10 = node event-log scan (once per node); 1.20 reserved; 1.30 = storage-health snapshot; 1.40 = HTML render+write. Step numbers are HIERARCHICAL / NESTED: 1.10 is a TOTAL that CONTAINS its 1.10.NN sections, 1.10.50.10 is inside 1.10.50, and 1 contains everything - do NOT sum DurationSec across levels (you would multi-count). Order = completion order (a nested sub-step is emitted before its parent); sort by StartUtc for a true timeline. Step numbers intentionally REPEAT per VM - use the Detail field to distinguish.'
                Steps              = $telSteps
            }
            $telJson = $telDoc | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($telPath, $telJson, (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "Performance telemetry written to: $telPath"
        } catch {
            Write-Alert "  WARNING: could not write the performance telemetry file: $($_.Exception.Message)" -Level Warning
        }
    }

    # Results .zip bundle (ON by default; suppress with -NoZip). Requires -OutputPath (a per-run folder
    # to bundle). Zips the run folder's .txt / .csv / .html into the -OutputPath root - a single file to
    # copy to a browser device and attach to a support case. Non-fatal on failure.
    $zipWritten = $null
    if (-not $NoZip) {
        if ($script:RunFolder -and (Test-Path -LiteralPath $script:RunFolder)) {
            try {
                $zipPath = Join-Path $OutputPath ("VMCheckpointAudit-{0}-{1}.zip" -f $safeCluster, $runStamp)
                if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
                Compress-Archive -Path (Join-Path $script:RunFolder '*') -DestinationPath $zipPath -Force
                $zipWritten = $zipPath
                Write-Host "Results bundled to zip:       $zipPath"
            } catch {
                Write-Alert "  WARNING: could not create the results zip: $($_.Exception.Message)" -Level Warning
            }
        } else {
            Write-Alert "  NOTE: no results .zip was created - it requires -OutputPath (there was nothing on disk to bundle)." -Level Info
        }
    }

    # Guidance: how to consume the portable report.
    if ($zipWritten) {
        Write-Host ""
        Write-Host "  To review: copy the zip file to a device with a web browser, unzip it, and open the"
        Write-Host "  '$htmlFileName' file (titled 'Hyper-V VM Checkpoint Health Audit')."
    } elseif ($htmlWritten) {
        Write-Host ""
        Write-Host "  To review: open '$htmlFileName' (titled 'Hyper-V VM Checkpoint Health Audit') in a web browser."
    }

    # Surface any high-risk VMs discovered in event data but not audited (always shown, even in quiet).
    if (@($discoveredVMs).Count -gt 0) {
        Microsoft.PowerShell.Utility\Write-Host ""
        Microsoft.PowerShell.Utility\Write-Host ("  {0} high-risk VM(s) were referenced in event data but were NOT audited:" -f @($discoveredVMs).Count) -ForegroundColor Yellow
        foreach ($dv in $discoveredVMs) { Microsoft.PowerShell.Utility\Write-Host ("    - {0}  ({1})" -f $dv.Name, $dv.Reason) -ForegroundColor Yellow }
        $dvList = (@($discoveredVMs | ForEach-Object { "'{0}'" -f $_.Name }) -join ',')
        $clusterArg = if ($Cluster) { " -Cluster '$Cluster'" } else { '' }
        Microsoft.PowerShell.Utility\Write-Host "  Recommend auditing them, e.g.:" -ForegroundColor Yellow
        Microsoft.PowerShell.Utility\Write-Host ("    .\Get-HyperVVMCheckpointHealth.ps1 -VMName $dvList$clusterArg -OutputPath <folder>")
        Microsoft.PowerShell.Utility\Write-Host "  (or re-run with -IncludeDiscoveredVMs to audit them automatically)."
    }

    # Option C: repeat the 'nothing saved' warning at the END, so it is the last thing the operator
    # sees after a long run (the up-front warning may have scrolled off the console).
    if (-not $OutputPath) {
        Write-Alert "WARNING: no report was saved (no -OutputPath) - console output only. Re-run with -OutputPath <folder>" -Level Warning
        Write-Alert "         to capture the .txt report and events .csv to attach to a backup-vendor / Microsoft (CSS) case." -Level Warning
    }
}