#Requires -Version 5.1

function Get-HyperVVMCheckpointHealth {
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
    chain metadata inconsistent. The inconsistency can stay dormant while the VM runs. A later live
    migration or restart can expose it, roll the disks back to their base, and orphan the data held in
    the .avhdx layer(s).

    The module makes NO changes to the VM, disks, checkpoints, or cluster (see README.md). The only
    optional writes are the per-VM .txt report and events .csv (when -OutputPath is supplied), a single
    self-contained HTML fleet report (on by default; suppress with -NoHtml), and a results .zip bundling
    those files (on by default when -OutputPath is used; suppress with -NoZip). The console is QUIET by
    default (concise one-line verdict per VM); pass -Quiet:$false for the full per-VM report on screen.
    While running it shows a "VM X of Y" progress bar with a per-VM, per-section sub-bar.

    The HTML report is the primary human-readable output. Detailed text is captured for the optional
    .txt transcript and is only echoed to the console with -Quiet:$false. By default NOTHING is written
    to the pipeline. Pass -PassThru to emit one [pscustomobject] per VM after the run is complete. Each
    object has a stable flat summary, complete per-VM ReportData, and the same shared RunData snapshot
    containing run-level housekeeping, storage, discovery, event-context, metadata, and artifact data.

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
    Get-HyperVVMCheckpointHealth -VMName 'TestVM01'

    Audits a single VM by name and writes the default HTML report to the current directory.

.EXAMPLE
    Get-HyperVVMCheckpointHealth -ProcessAllVMs -OutputPath 'C:\Temp\Reports'

    Audits EVERY clustered VM when run ON a cluster node. VM names are resolved from the local cluster
    through the cluster API (RPC, no WinRM and no double hop). Writes per-VM .txt and events .csv files.

.EXAMPLE
    'VM01','VM02','VM03' | Get-HyperVVMCheckpointHealth -OutputPath 'C:\Temp\Reports'

    Audits a specific list of VMs (piped names). The module resolves each VM's owning node itself and
    collects the data in that node's context, so no double-hop authentication is required.

.EXAMPLE
    Get-HyperVVMCheckpointHealth -VMName 'TestVM01' -SkipWorkerEvents -SkipAnalyticCheck

    Fastest run: disk / checkpoint / chain state only, skipping the event-log scan and Analytic check.

.EXAMPLE
    Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' -ProcessAllVMs -OutputPath 'C:\Temp\Reports'

    A single self-contained HTML fleet report is written by DEFAULT. With -OutputPath it lands in the
    per-run sub-folder as 'VMCheckpointAudit-<ClusterName>-yyyy-MM-dd.html' alongside the .txt/.csv;
    without -OutputPath it is written to the current directory. Override the location with
    -HtmlReportPath <folder-or-file>, or suppress it entirely with -NoHtml. The report has one row per
    audited VM (colour-coded verdict), summary cards, a fleet table, and per-VM detail - ideal to email
    or attach to a backup-vendor / Microsoft (CSS) case.

.EXAMPLE
    Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' -ProcessAllVMs -OutputPath 'C:\Temp\Reports'

    Runs REMOTELY from a management workstation (with the RSAT 'Failover Clustering' tools). -Cluster
    targets the named cluster via the cluster RPC API and each owning node is reached in a SINGLE hop -
    no double hop. Without -Cluster the command must be run ON a cluster node.

    -ProcessAllVMs enumerates the named cluster directly, so -Cluster is supplied only once.

.EXAMPLE
    $results = Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' -ProcessAllVMs -OutputPath 'C:\Temp\Reports' -PassThru
    $results | Where-Object HoldState | Format-Table VMName, OwningNode, Recommendation

    With -PassThru the command emits ONE [pscustomobject] per VM after all collection and artifact
    writes finish. Every row has the same stable property set, including Source, AssessmentConfidence,
    CollectionStatus, ReportData, and RunData. ReportData contains complete per-VM assessment evidence,
    typed InvestigationDrivers, and full VM-attributed event rows. RunData is one shared, non-circular
    snapshot containing cluster/storage housekeeping, storage health, discovery candidates, node event
    context, run metadata, and artifact paths. ReportData is $null for NOT FOUND / ERROR rows, while
    their top-level AssessmentConfidence and CollectionStatus remain usable. Drill in, e.g.:
        $results | Where-Object { $_.ReportData.HasForkSignature } |
            ForEach-Object { $_.ReportData.Checkpoints } | Format-Table Name, AgeHrs, Stale

.EXAMPLE
    Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' -ProcessAllVMs -ExcludedVMListCsv '.\CheckPointAudit_Excluded_VMs.csv' -OutputPath 'C:\Temp\Reports'

    Audits every clustered VM EXCEPT those listed in the exclusion CSV. The file has a single column
    with a 'VMName' header (a headerless single-column file also works); each VM whose name matches
    (case-INSENSITIVE) is skipped BEFORE it is audited. Handy to permanently omit known-noisy or
    intentionally long-checkpointed VMs from a fleet run. A relative path (e.g. '.\CheckPointAudit_
    Excluded_VMs.csv', in the same folder as the module) is resolved against the current directory; a
    missing / unreadable file is a non-fatal warning and the run proceeds with no exclusions.

.OUTPUTS
    None to the pipeline by default. A single self-contained HTML fleet report is written by default
    (suppress with -NoHtml; relocate with -HtmlReportPath); with -OutputPath, the captured detailed text
    and events are also written to per-VM .txt/.csv files. With -PassThru, one
    [pscustomobject] per VM is emitted to the pipeline - flat properties (VMName, Recommendation,
    HoldState, Has* flags, counts, ReportFile, Detail) for quick Where-Object / Export-Csv roll-ups,
    plus nested ReportData and shared RunData objects for complete per-VM and run-level automation
    (see the -PassThru example above). Rows are emitted after the run and artifact writes complete.

.NOTES
    Author  : Neil Bird, Microsoft
    Created : 2026-07-10
    Updated : 2026-07-29
    Version : 0.2.30
    
    Requires: Windows PowerShell 5.1 (this module is written for, and validated against, Windows
              PowerShell 5.1 ONLY - it is NOT intended or tested for PowerShell 7.x). Requires the
              FailoverClusters module locally and the Hyper-V module on the cluster nodes, plus rights
              to query the cluster / Hyper-V / the nodes' event logs and WinRM to each remote owning node.
              To run REMOTELY from a management workstation, use -Cluster <name> and install the RSAT
              'Failover Clustering' tools on the workstation. Do NOT run it from inside an interactive
              remoting session (Enter-PSSession) to a node - reaching another node from there is a
              'double hop' and is blocked; run it ON a node, or from a workstation with -Cluster.

    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR
    FITNESS FOR A PARTICULAR PURPOSE.

    This sample is not supported under any Microsoft standard support program or service.
    The module is provided AS IS without warranty of any kind. Microsoft further disclaims all
    implied warranties including, without limitation, any implied warranties of merchantability
    or of fitness for a particular purpose. The entire risk arising out of the use or performance
    of the sample and documentation remains with you. In no event shall Microsoft, its authors,
    or anyone else involved in the creation, production, or delivery of the module be liable for
    any damages whatsoever (including, without limitation, damages for loss of business profits,
    business interruption, loss of business information, or other pecuniary loss) arising out of
    the use of or inability to use the sample or documentation, even if Microsoft has been advised
    of the possibility of such damages.
#>

# NOTE: the Windows PowerShell 5.1 (Desktop) edition and the FailoverClusters module are enforced by
# RUNTIME guards at the top of the begin block below - NOT by '#Requires -PSEdition Desktop' /
# '#Requires -Modules FailoverClusters'. Those directives make PowerShell refuse to introspect the
# script when the current session does not satisfy them, which breaks tab-completion of -Parameters
# when authoring on a PowerShell 7 workstation (or one without the RSAT clustering tools). The runtime
# guards give the same clear failure at execution time while keeping tooling / completion working.
# FailoverClusters is required LOCALLY in both run modes (on a node, or on a workstation via the RSAT
# 'Failover Clustering' tools). Hyper-V is intentionally NOT required locally: with -Cluster the
# Hyper-V cmdlets run inside the owning-node session, so a management workstation need not have it.

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true, ParameterSetName='ByName')]
    [ValidateNotNullOrEmpty()]
    [Alias('Name','VM')]
    # Accepts VM name(s) OR VM objects (from Get-VM). Objects are normalized to their .Name in the
    # process block, so -VMName $VMs (objects), -VMName $VMs.Name (strings), and 'Get-VM | ...' all work.
    [object[]]$VMName,

    # Audit every clustered virtual machine returned by Get-ClusterGroup. Use without -Cluster when
    # logged directly onto a cluster node, or combine with -Cluster from an RSAT management workstation.
    # Mutually exclusive with -VMName so the requested fleet has one unambiguous source.
    [Parameter(Mandatory=$true, ParameterSetName='AllVMs')]
    [switch]$ProcessAllVMs,

    # Optional: target a cluster BY NAME so the command can be run from a management workstation (with
    # the RSAT 'Failover Clustering' tools installed) instead of on a node. The cluster queries use the
    # cluster RPC API and each owning node is then reached in a SINGLE remoting hop from the
    # workstation - no double hop. When OMITTED, the command targets the LOCAL cluster and REQUIRES that
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
    # run command, but only audited automatically when this switch is set. Non-recursive: only names
    # that resolve to real clustered VMs are added and their own discoveries are not expanded.
    [switch]$IncludeDiscoveredVMs,

    # Optional maximum number of validated discovered VMs to auto-audit. When omitted, every eligible
    # discovery is audited. When supplied, candidates are ranked by strongest evidence before the cap.
    [ValidateRange(1, 1000)]
    [Nullable[int]]$MaxDiscoveredVMs,

    # Optional: path to a CSV file listing VM names to EXCLUDE from the audit. The file has a single
    # column with a 'VMName' header (a headerless single-column file is also accepted). It is read ONCE
    # at start; any requested / piped VM whose name matches (case-INSENSITIVE) is skipped BEFORE it is
    # audited, and excluded VMs are NOT auto-audited via -IncludeDiscoveredVMs either. A missing or
    # unreadable file is a non-fatal warning (the run proceeds with no exclusions).
    [string]$ExcludedVMListCsv,

    # Optional schema-versioned YAML policy for image-library paths, live-mount patterns, CSV free-space
    # thresholds, and cadence-aware HRL assessment. Parsed by the module with no external dependency.
    [string]$PolicyPath,

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

    [ValidateRange(1, 10080)]
    [int]$MaxReplicationAgeMinutes = 60,

    [ValidateRange(0, 1048576)]
    [long]$MaxPendingReplicationMB = 1024,

    [ValidateRange(0, 86400)]
    [int]$MaxReplicationLatencySeconds = 300,

    [ValidateRange(0, 1000000)]
    [int]$MaxMissedReplicationCount = 0,

    [ValidateRange(1, 1000)]
    [double]$MaxReplicationAgeCycles = 12,

    [ValidateRange(0.1, 1000)]
    [double]$MaxPendingReplicationCycles = 2,

    [ValidateRange(0.1, 1000)]
    [double]$MaxReplicationLatencyCycles = 2,

    [ValidateRange(0, 100)]
    [double]$MaxMissedReplicationRatePercent = 10,

    [ValidateRange(1, 1000000)]
    [long]$MinMissedReplicationCountForConcern = 3,

    # Skip the per-node check of the Hyper-V-VMMS/Analytic diagnostic channel state.
    [switch]$SkipAnalyticCheck,

    # Colour is ON by default for interactive consoles (section headings + RESULT/WARNING/HOLD STATE).
    # It auto-disables when output is redirected (> file, | Out-File, $x = Get-HyperVVMCheckpointHealth ...) so captured text
    # stays complete, and the -OutputPath transcript captures the coloured lines as plain text anyway.
    # Use -NoColour to force plain output.
    [Alias('NoColor')]
    [switch]$NoColour,

    # Emit one [pscustomobject] per VM to the PIPELINE (VMName, Cluster, OwningNode, Recommendation,
    # HoldState, HasAttachedCheckpoints, HasStaleCheckpoints, HasOrphanedCheckpoints, counts,
    # ReportFile, Detail, plus a nested ReportData object with the rich per-VM detail the HTML
    # renders). WITHOUT -PassThru nothing is written to the pipeline, so '$x = Get-HyperVVMCheckpointHealth ...' stays clean.
    # Use -PassThru to feed Where-Object / Export-Csv / fleet roll-ups.
    [switch]$PassThru,

    # Where to write the single self-contained HTML fleet report (one row per audited VM). ON by
    # default. Accepts EITHER a folder (the file is auto-named 'VMCheckpointAudit-<ClusterName>-
    # yyyy-MM-dd.html') OR a full path ending in '.html'. When omitted, the report defaults to the
    # per-run sub-folder created under -OutputPath; if -OutputPath was also omitted it is written to
    # the current directory. Use -NoHtml to suppress it entirely.
    [string]$HtmlReportPath,

    # Suppress the HTML fleet report (it is generated by default). Concise console status, the
    # -OutputPath .txt/.csv files and the -PassThru pipeline objects are unaffected.
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
# 1) Windows PowerShell 5.1 (Desktop edition) only - this module is written for, and validated
#    against, WinPS 5.1 and is NOT intended for PowerShell 7.x (Core).
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw "This module requires Windows PowerShell 5.1 (Desktop edition). It is running under PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)) - re-run it in Windows PowerShell 5.1."
}
# 2) The command must be loaded through its manifest so all internal implementation modules are
#    present. Importing the bare root .psm1 remains discoverable for tooling, but is not executable.
$requiredNestedModules = @(
    'Get-HyperVVMCheckpointHealth.Assessment'
    'Get-HyperVVMCheckpointHealth.Collection'
    'Get-HyperVVMCheckpointHealth.Policy'
    'Get-HyperVVMCheckpointHealth.Rendering'
    'Get-HyperVVMCheckpointHealth.Storage'
)
$loadedNestedModules = @($ExecutionContext.SessionState.Module.NestedModules | ForEach-Object { $_.Name })
$missingNestedModules = @($requiredNestedModules | Where-Object { $loadedNestedModules -notcontains $_ })
if ($missingNestedModules.Count -gt 0) {
    throw @"
Get-HyperVVMCheckpointHealth was not loaded through its module manifest, or its internal modules
are incomplete. Import the manifest instead:

  Import-Module '$PSScriptRoot\Get-HyperVVMCheckpointHealth.psd1' -Force

Missing internal modules: $($missingNestedModules -join ', ')
"@
}
# 3) FailoverClusters must be available locally (on a cluster node, or via the RSAT 'Failover
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

# Module version - single source of truth surfaced in the HTML report (header meta + footer) so a
# saved / emailed report always states which build produced it. Keep in sync with the .NOTES Version.
$script:ScriptVersion = '0.2.30'

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
#   1               = whole module run (total)
#   1.05.15         = all-cluster VM selection when -ProcessAllVMs is used
#   1.08.10         = bounded node diagnostic prefetch coordination
#   1.08.10.10      = event prefetch worker per owning node
#   1.08.10.20      = VSS prefetch worker per owning node
#   1.10            = per-VM audit (total)   - repeats once per audited VM (input AND discovered)
#   1.10.NN         = per-VM audit section   - NN = 05,10,15,... (assigned at each Show-AuditProgress call)
#   1.10.20.10      = VHD chain collection and validation (inside per-VM disk section)
#   1.10.50.10      = node-wide event-log scan (a sub-step of section 1.10.50; runs once per node)
#   1.10.60.10      = VSS writer scan (a sub-step of section 1.10.60; runs once per node)
#   1.10.65.10      = attached-layer and named-snapshot staleness assessment
#   1.10.75         = rendering findings / RESULT text + building the per-VM result object
#   1.10.80         = VM collection state consistency section
#   1.10.80.10      = VM collection state consistency recheck
#   1.20            = discovered VM validation and selection (once per run)
#   1.30            = cluster storage-health snapshot
#   1.40            = HTML report render + write
$script:Telemetry = [System.Collections.Generic.List[object]]::new()
$script:AuditDiagnostics = [System.Collections.Generic.List[object]]::new()
$script:DebugLogPath = $null
$script:VMSectionStepNo = $null
$script:VMSectionName = $null

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
        [int]$DelayMs = 750,
        [ref]$AttemptCount,
        [string]$DiagnosticOperation = 'Read-only operation after retries',
        [string]$DiagnosticScope = ''
    )
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($AttemptCount) { $AttemptCount.Value = $attempt }
        try { return (& $ScriptBlock) }
        catch {
            if ($attempt -ge $MaxAttempts) {
                Add-AuditDiagnostic -ErrorRecord $_ -Operation $DiagnosticOperation -Scope $DiagnosticScope -AttemptCount $attempt
                throw
            }
            Start-Sleep -Milliseconds ($DelayMs * $attempt)
        }
    }
}

# Microsoft Learn troubleshooting reference for Hyper-V VM backup / checkpoint / storage failures.
# Surfaced in the summary and problem statement so operators have an authoritative next-read. Any
# text quoted VERBATIM from this article in the report is attributed to it (title + URL below).
$script:TroubleshootTitle = 'Microsoft Learn: Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures'
$script:TroubleshootUrl   = 'https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage'

# Report-output helpers. Detailed report lines are captured into a per-VM buffer and are only echoed
# to the host when -Quiet:$false is requested. The pipeline remains reserved for -PassThru objects.
# The captured lines feed the .txt report and the HOLD STATE support summary in the HTML.
# Colour is ON by default; it auto-disables when output is redirected (so a captured/paged view stays
# readable) or when -NoColour is passed. -PassThru objects are emitted separately by the end block.
$script:UseColour = (-not $NoColour) -and (-not [Console]::IsOutputRedirected)

# Console verbosity + report capture. The full per-VM report is ALWAYS captured (line by line) into
# $script:VMReportBuffer so it can be written to the per-VM .txt and mined for the HOLD STATE support
# summary shown in the HTML. In Quiet mode (the default) the detailed lines are captured but NOT echoed
# to the console - only concise verdicts and final pointers are shown.
$script:QuietConsole   = [bool]$Quiet
$script:VMReportBuffer = $null
function Write-AuditReportLine {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Detailed report renderer keeps output off the success pipeline and only echoes when explicitly requested.')]
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
function Write-AuditStatus {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Concise operator status remains visible without contaminating the success pipeline.')]
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [object]$Object,
        [System.ConsoleColor]$ForegroundColor
    )
    $params = @{ Object = $Object }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $params['ForegroundColor'] = $ForegroundColor }
    Microsoft.PowerShell.Utility\Write-Host @params
}
function Write-Section {
    param([string]$Text)
    if ($script:UseColour) { Write-AuditReportLine $Text -ForegroundColor Cyan } else { Write-AuditReportLine $Text }
}
function Write-Alert {
    param([string]$Text, [ValidateSet('Info', 'Good', 'Warning', 'Critical')][string]$Level = 'Info')
    if ($script:UseColour) {
        $fg = switch ($Level) { 'Good' { 'Green' } 'Warning' { 'Yellow' } 'Critical' { 'Red' } default { 'Gray' } }
        Write-AuditReportLine $Text -ForegroundColor $fg
    } else {
        Write-AuditReportLine $Text
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

# Capture an unrecovered ErrorRecord without allowing diagnostic collection to interrupt the audit.
function Add-AuditDiagnostic {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$Scope = '',
        [int]$AttemptCount = 0
    )

    try {
        $invocation = $ErrorRecord.InvocationInfo
        $exception = $ErrorRecord.Exception
        $innerExceptions = [System.Collections.Generic.List[string]]::new()
        $inner = if ($exception) { $exception.InnerException } else { $null }
        while ($inner) {
            [void]$innerExceptions.Add(('{0}: {1}' -f $inner.GetType().FullName, $inner.Message))
            $inner = $inner.InnerException
        }
        $targetText = if ($null -eq $ErrorRecord.TargetObject) { '' } else { [string]$ErrorRecord.TargetObject }
        if ($targetText.Length -gt 2000) { $targetText = $targetText.Substring(0, 2000) + '... [truncated]' }

        [void]$script:AuditDiagnostics.Add([pscustomobject]@{
            Sequence              = $script:AuditDiagnostics.Count + 1
            TimestampUtc          = (Get-TelemetryNow).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
            Operation             = $Operation
            Scope                 = $Scope
            TelemetryStep         = [string]$script:VMSectionStepNo
            TelemetryPhase        = [string]$script:VMSectionName
            AttemptCount          = $AttemptCount
            ExceptionType         = if ($exception) { $exception.GetType().FullName } else { '' }
            ExceptionMessage      = if ($exception) { [string]$exception.Message } else { [string]$ErrorRecord }
            HResult               = if ($exception) { ('0x{0:X8}' -f ($exception.HResult -band 0xffffffffL)) } else { '' }
            InnerExceptions       = $innerExceptions.ToArray()
            CategoryInfo          = [string]$ErrorRecord.CategoryInfo
            FullyQualifiedErrorId = [string]$ErrorRecord.FullyQualifiedErrorId
            ErrorDetails          = if ($ErrorRecord.ErrorDetails) { [string]$ErrorRecord.ErrorDetails.Message } else { '' }
            TargetObjectType      = if ($null -ne $ErrorRecord.TargetObject) { $ErrorRecord.TargetObject.GetType().FullName } else { '' }
            TargetObject          = $targetText
            CommandName           = if ($invocation -and $invocation.MyCommand) { [string]$invocation.MyCommand.Name } else { '' }
            ScriptName            = if ($invocation) { [string]$invocation.ScriptName } else { '' }
            ScriptLineNumber      = if ($invocation) { [int]$invocation.ScriptLineNumber } else { 0 }
            OffsetInLine          = if ($invocation) { [int]$invocation.OffsetInLine } else { 0 }
            SourceLine            = if ($invocation) { [string]$invocation.Line } else { '' }
            PositionMessage       = if ($invocation) { [string]$invocation.PositionMessage } else { '' }
            ScriptStackTrace      = [string]$ErrorRecord.ScriptStackTrace
        })
        Write-AuditDebugLog
    } catch {
        Write-Warning "Could not capture detailed audit diagnostics: $($_.Exception.Message)"
    }
}

function Add-AuditDiagnosticMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$Scope = ''
    )

    $exception = New-Object System.InvalidOperationException($Message)
    $errorRecord = New-Object System.Management.Automation.ErrorRecord(
        $exception,
        'ReadOnlyCollectionIncomplete',
        [System.Management.Automation.ErrorCategory]::ReadError,
        $Scope
    )
    Add-AuditDiagnostic -ErrorRecord $errorRecord -Operation $Operation -Scope $Scope
}

function Write-AuditDebugLog {
    if (-not $script:DebugLogPath -or $script:AuditDiagnostics.Count -eq 0) { return }

    try {
        $lines = [System.Collections.Generic.List[string]]::new()
        [void]$lines.Add('Get-HyperVVMCheckpointHealth unrecovered-failure debug log')
        [void]$lines.Add('')
        [void]$lines.Add('SENSITIVE DATA: This log can contain VM/node names, paths, command context, and error details.')
        [void]$lines.Add('Review it before sharing and use only an approved secure support channel.')
        [void]$lines.Add(('Usage documentation: {0}' -f 'https://aka.ms/Get-HyperVVMCheckpointHealth#readme'))
        [void]$lines.Add(('Feedback / GitHub issue: {0}' -f 'https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback'))
        [void]$lines.Add('')
        [void]$lines.Add(('GeneratedUtc: {0}' -f (Get-TelemetryNow).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")))
        [void]$lines.Add(('ToolVersion: {0}' -f $script:ScriptVersion))
        [void]$lines.Add(('PowerShellVersion: {0}' -f $PSVersionTable.PSVersion))
        [void]$lines.Add(('PSEdition: {0}' -f $PSVersionTable.PSEdition))
        [void]$lines.Add(('OSVersion: {0}' -f [Environment]::OSVersion.VersionString))
        [void]$lines.Add(('Machine: {0}' -f $env:COMPUTERNAME))
        [void]$lines.Add(('FailureCount: {0}' -f $script:AuditDiagnostics.Count))

        foreach ($diagnostic in $script:AuditDiagnostics) {
            [void]$lines.Add('')
            [void]$lines.Add(('=' * 80))
            [void]$lines.Add(('Failure #{0}' -f $diagnostic.Sequence))
            foreach ($propertyName in @(
                'TimestampUtc', 'Operation', 'Scope', 'TelemetryStep', 'TelemetryPhase', 'AttemptCount',
                'ExceptionType', 'ExceptionMessage', 'HResult', 'CategoryInfo', 'FullyQualifiedErrorId',
                'ErrorDetails', 'TargetObjectType', 'TargetObject', 'CommandName', 'ScriptName',
                'ScriptLineNumber', 'OffsetInLine', 'SourceLine', 'PositionMessage', 'ScriptStackTrace'
            )) {
                [void]$lines.Add(('{0}: {1}' -f $propertyName, $diagnostic.$propertyName))
            }
            if (@($diagnostic.InnerExceptions).Count -gt 0) {
                [void]$lines.Add('InnerExceptions:')
                foreach ($innerException in $diagnostic.InnerExceptions) { [void]$lines.Add(('  {0}' -f $innerException)) }
            }
        }

        [System.IO.File]::WriteAllLines($script:DebugLogPath, $lines.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Warning "Could not write the audit debug log '$script:DebugLogPath': $($_.Exception.Message)"
    }
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
        for ($i = $startIdx; $i -le $endIdx; $i++) { Write-AuditReportLine ('  ' + $lines[$i]) }
        Write-AuditReportLine ''
    }
}

function ConvertTo-AuditByteText {
    [OutputType([string])]
    param([long]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ("$Bytes bytes")
}

function Get-ReplicaMeasurementEvidenceText {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][object]$Assessment,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Breaches
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($breach in @($Breaches)) {
        switch ($breach) {
            'LastReplicationAge' {
                [void]$parts.Add(('last replication age {0}; effective limit {1}' -f
                    (ConvertTo-ReplicaDurationText -Minutes ([double]$Assessment.LastReplicationAgeMinutes)),
                    (ConvertTo-ReplicaDurationText -Minutes ([double]$Assessment.EffectiveMaxAgeMinutes))))
            }
            'PendingBytes' {
                [void]$parts.Add(('pending data {0} (effective limit {1})' -f
                    (ConvertTo-AuditByteText ([long]$Assessment.PendingBytes)),
                    (ConvertTo-AuditByteText ([long]$Assessment.EffectiveMaxPendingBytes))))
            }
            'Latency' {
                [void]$parts.Add(('average latency {0:N1} sec (effective limit {1:N1} sec)' -f
                    [double]$Assessment.LatencySeconds, [double]$Assessment.EffectiveMaxLatencySeconds))
            }
            'MissedCount' {
                $rateText = if ($null -ne $Assessment.MissedRatePercent) { '; {0:N2}% of measured attempts' -f [double]$Assessment.MissedRatePercent } else { '; rate unavailable' }
                [void]$parts.Add(('missed replications {0}{1}' -f [long]$Assessment.MissedCount, $rateText))
            }
        }
    }
    $parts.ToArray() -join '; '
}

function Get-ReplicaAssessmentRows {
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)][object]$Assessment,
        [AllowEmptyString()][string]$PrimaryServer,
        [AllowEmptyString()][string]$ReplicaServer
    )

    $concernBreaches = @($Assessment.ConcernBreaches)
    $advisoryBreaches = @($Assessment.AdvisoryBreaches)
    $getMetricAssessment = {
        param([string]$Breach)
        if (-not $Assessment.MeasurementsAvailable) { return 'Unavailable' }
        if ($concernBreaches -contains $Breach) { return 'Concern' }
        if ($advisoryBreaches -contains $Breach) { return 'Advisory' }
        'Within effective limit'
    }
    $lastReplicationText = if ($Assessment.MeasurementsAvailable -and $Assessment.LastReplicationTimeUtc -and ([datetime]$Assessment.LastReplicationTimeUtc -ne [datetime]::MinValue)) {
        '{0} ({1} ago)' -f ([datetime]$Assessment.LastReplicationTimeUtc).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ'), (ConvertTo-ReplicaDurationText -Minutes ([double]$Assessment.LastReplicationAgeMinutes))
    } else { 'Unavailable' }
    $cycleText = if ($Assessment.MeasurementsAvailable) {
        'Successful {0}; missed {1}; missed rate {2}' -f $(if ([long]$Assessment.SuccessfulCount -ge 0) { [long]$Assessment.SuccessfulCount } else { 'Unavailable' }), [long]$Assessment.MissedCount, $(if ($null -ne $Assessment.MissedRatePercent) { '{0:N2}%' -f [double]$Assessment.MissedRatePercent } else { 'Unavailable' })
    } else { 'Unavailable' }

    @(
        [pscustomobject]@{ Signal = 'Product state and health'; Observed = "$($Assessment.State) / $($Assessment.Health)"; Guardrail = 'Authoritative Get-VMReplication evidence'; Assessment = [string]$Assessment.ProductSeverity }
        [pscustomobject]@{ Signal = 'Relationship'; Observed = "Mode $($Assessment.Mode)"; Guardrail = "Primary $PrimaryServer; replica $ReplicaServer"; Assessment = 'Context' }
        [pscustomobject]@{ Signal = 'Replication cadence'; Observed = $(if ([double]$Assessment.FrequencySeconds -gt 0) { '{0:N1} sec' -f [double]$Assessment.FrequencySeconds } else { 'Unavailable' }); Guardrail = 'Used to calculate relationship-aware limits'; Assessment = 'Context' }
        [pscustomobject]@{ Signal = 'Monitoring window'; Observed = $(if ([double]$Assessment.MonitoringIntervalSeconds -gt 0) { [timespan]::FromSeconds([double]$Assessment.MonitoringIntervalSeconds).ToString() } else { 'Unavailable' }); Guardrail = 'Get-VMReplicationServer monitoring interval'; Assessment = 'Context' }
        [pscustomobject]@{ Signal = 'Last replication'; Observed = $lastReplicationText; Guardrail = $(if ([double]$Assessment.EffectiveMaxAgeMinutes -gt 0) { '{0} effective maximum age' -f (ConvertTo-ReplicaDurationText -Minutes ([double]$Assessment.EffectiveMaxAgeMinutes)) } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'LastReplicationAge') }
        [pscustomobject]@{ Signal = 'Average replication size'; Observed = $(if ($Assessment.MeasurementsAvailable) { ConvertTo-AuditByteText ([long]$Assessment.AverageReplicationBytes) } else { 'Unavailable' }); Guardrail = 'Workload baseline for pending-data limit'; Assessment = 'Context' }
        [pscustomobject]@{ Signal = 'Pending replication data'; Observed = $(if ($Assessment.MeasurementsAvailable) { ConvertTo-AuditByteText ([long]$Assessment.PendingBytes) } else { 'Unavailable' }); Guardrail = $(if ([long]$Assessment.EffectiveMaxPendingBytes -gt 0) { "$(ConvertTo-AuditByteText ([long]$Assessment.EffectiveMaxPendingBytes)) effective maximum" } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'PendingBytes') }
        [pscustomobject]@{ Signal = 'Average replication latency'; Observed = $(if ($Assessment.MeasurementsAvailable) { '{0:N1} sec' -f [double]$Assessment.LatencySeconds } else { 'Unavailable' }); Guardrail = $(if ([double]$Assessment.EffectiveMaxLatencySeconds -gt 0) { '{0:N1} sec effective maximum' -f [double]$Assessment.EffectiveMaxLatencySeconds } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'Latency') }
        [pscustomobject]@{ Signal = 'Measured replication cycles'; Observed = $cycleText; Guardrail = $(if ([double]$Assessment.MaxMissedRatePercent -gt 0) { '{0:N2}% maximum missed rate' -f [double]$Assessment.MaxMissedRatePercent } else { 'Count and rate guardrails' }); Assessment = (& $getMetricAssessment 'MissedCount') }
    )
}











function Get-NodeDiagnosticSnapshot {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 8760)][int]$LookbackHours,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ConcernIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ContextIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CodePatterns,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3,
        [ValidateRange(0, 60000)][int]$DelayMs = 750,
        [bool]$SkipEvents = $false
    )

    $workerStartUtc = [DateTime]::UtcNow
    $workerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $errors = [System.Collections.Generic.List[object]]::new()

    $eventStatus = if ($SkipEvents) { 'Skipped' } else { 'Unavailable' }
    $eventRows = @()
    $channelStatus = @()
    $eventError = ''
    $eventAttempts = 0
    $eventDurationMs = 0L
    if (-not $SkipEvents) {
        $eventStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            $eventAttempts = $attempt
            try {
                $start = (Get-Date).AddHours(-$LookbackHours)
                $codeRx = ($CodePatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
                $attemptRows = [System.Collections.Generic.List[object]]::new()
                $attemptChannels = [System.Collections.Generic.List[object]]::new()
                foreach ($log in @(
                    [pscustomobject]@{ Name = 'Microsoft-Windows-Hyper-V-Worker-Admin'; Channel = 'Worker' }
                    [pscustomobject]@{ Name = 'Microsoft-Windows-Hyper-V-VMMS-Admin'; Channel = 'VMMS' }
                )) {
                    try {
                        $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log.Name; StartTime = $start } -ErrorAction Stop)
                        foreach ($eventRecord in $events) {
                            if (-not (($codeRx -and $eventRecord.Message -match $codeRx) -or ($ConcernIds -contains $eventRecord.Id) -or ($ContextIds -contains $eventRecord.Id))) { continue }
                            $isConcern = (($codeRx -and $eventRecord.Message -match $codeRx) -or ($ConcernIds -contains $eventRecord.Id))
                            [void]$attemptRows.Add([pscustomobject]@{
                                'Time (UTC)' = $eventRecord.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
                                RecordId     = [long]$eventRecord.RecordId
                                Id           = [int]$eventRecord.Id
                                Level        = [string]$eventRecord.LevelDisplayName
                                Log          = $log.Channel
                                Concern      = if ($isConcern) { 'YES' } else { '' }
                                Message      = ($eventRecord.Message -split "`r?`n")[0]
                                FullMessage  = ($eventRecord.Message -replace "`r?`n", ' | ')
                            })
                        }
                        [void]$attemptChannels.Add([pscustomobject]@{ Channel = $log.Channel; Status = 'Success'; Error = '' })
                    } catch {
                        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                            [void]$attemptChannels.Add([pscustomobject]@{ Channel = $log.Channel; Status = 'Success'; Error = '' })
                        } else {
                            throw ("{0} query failed: {1}" -f $log.Channel, $_.Exception.Message)
                        }
                    }
                }
                $eventRows = $attemptRows.ToArray()
                $channelStatus = $attemptChannels.ToArray()
                $eventStatus = 'Success'
                $eventError = ''
                break
            } catch {
                $eventError = $_.Exception.Message
                if ($attempt -lt $MaxAttempts -and $DelayMs -gt 0) {
                    Start-Sleep -Milliseconds ($DelayMs * $attempt)
                }
            }
        }
        $eventStopwatch.Stop()
        $eventDurationMs = [long]$eventStopwatch.ElapsedMilliseconds
        if ($eventStatus -ne 'Success') {
            $channelStatus = @(
                [pscustomobject]@{ Channel = 'Worker'; Status = 'Unavailable'; Error = $eventError }
                [pscustomobject]@{ Channel = 'VMMS'; Status = 'Unavailable'; Error = $eventError }
            )
            [void]$errors.Add([pscustomobject]@{ Operation = 'Event'; Message = $eventError; AttemptCount = $eventAttempts })
        }
    }

    $vssStatus = 'Unavailable'
    $vssRows = @()
    $vssError = ''
    $vssAttempts = 0
    $vssStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $vssAttempts = $attempt
        try {
            $raw = @(& vssadmin list writers 2>$null)
            $text = ($raw -join "`n")
            $writers = [System.Collections.Generic.List[object]]::new()
            foreach ($block in ($text -split '(?m)^Writer name:')) {
                if ($block -notmatch "'") { continue }
                $name = if ($block -match "'([^']+)'") { $Matches[1] } else { '' }
                $state = if ($block -match 'State:\s*(.+)') { $Matches[1].Trim() } else { '' }
                $lastError = if ($block -match 'Last error:\s*(.+)') { $Matches[1].Trim() } else { '' }
                if ($name) {
                    [void]$writers.Add([pscustomobject]@{ Writer = $name; State = $state; 'Last error' = $lastError })
                }
            }
            $vssRows = $writers.ToArray()
            $vssStatus = 'Success'
            $vssError = ''
            break
        } catch {
            $vssError = $_.Exception.Message
            if ($attempt -lt $MaxAttempts -and $DelayMs -gt 0) {
                Start-Sleep -Milliseconds ($DelayMs * $attempt)
            }
        }
    }
    $vssStopwatch.Stop()
    if ($vssStatus -ne 'Success') {
        [void]$errors.Add([pscustomobject]@{ Operation = 'VSS'; Message = $vssError; AttemptCount = $vssAttempts })
    }

    $workerStopwatch.Stop()
    [pscustomobject]@{
        Complete         = (($SkipEvents -or $eventStatus -eq 'Success') -and $vssStatus -eq 'Success')
        EventStatus      = $eventStatus
        EventRows        = @($eventRows)
        ChannelStatus    = @($channelStatus)
        EventError       = $eventError
        EventAttempts    = $eventAttempts
        EventDurationMs  = $eventDurationMs
        VssStatus        = $vssStatus
        VssRows          = @($vssRows)
        VssError         = $vssError
        VssAttempts      = $vssAttempts
        VssDurationMs    = [long]$vssStopwatch.ElapsedMilliseconds
        Errors           = $errors.ToArray()
        WorkerStartUtc   = $workerStartUtc
        WorkerEndUtc     = [DateTime]::UtcNow
        WorkerDurationMs = [long]$workerStopwatch.ElapsedMilliseconds
    }
}

function Invoke-NodeDiagnosticPrefetch {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Nodes,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LocalNode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SessionByNode,
        [Parameter(Mandatory)][ValidateRange(1, 8760)][int]$LookbackHours,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ConcernIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ContextIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CodePatterns,
        [ValidateRange(1, 8)][int]$ThrottleLimit = 4,
        [ValidateRange(1, 10)][int]$MaxAttempts = 3,
        [ValidateRange(0, 60000)][int]$DelayMs = 750,
        [switch]$SkipEvents
    )

    $orderedNodes = @($Nodes | Where-Object { $_ } | Sort-Object -Unique)
    $coordinatorStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($orderedNodes.Count -eq 0) {
        $coordinatorStopwatch.Stop()
        return [pscustomobject]@{
            Complete = $true; ExecutionMode = 'None'; ThrottleLimit = 0; Nodes = @(); CoordinatorDurationMs = 0L
        }
    }

    $collector = ${function:Get-NodeDiagnosticSnapshot}
    # Each comma-wrapped array must remain one positional ArgumentList value in Windows PowerShell 5.1.
    # Removing the unary comma flattens IDs/patterns and shifts every parameter that follows them.
    $collectorArguments = @(
        $LookbackHours
        (,$ConcernIds)
        (,$ContextIds)
        (,$CodePatterns)
        $MaxAttempts
        $DelayMs
        [bool]$SkipEvents
    )
    $localNodeShort = $LocalNode.Split('.')[0]
    $localNodes = @($orderedNodes | Where-Object { $_.Split('.')[0] -eq $localNodeShort })
    $remoteNodes = @($orderedNodes | Where-Object { $_.Split('.')[0] -ne $localNodeShort })
    $nodeResults = [System.Collections.Generic.List[object]]::new()
    $executionMode = 'Sequential'
    $effectiveThrottle = 1

    $addNodeResult = {
        param([string]$Node, $Result, [long]$DurationMs, [string]$Mode, [string]$ErrorMessage)
        [void]$nodeResults.Add([pscustomobject]@{
            Node          = $Node
            Complete      = ($Result -and [bool]$Result.Complete)
            DurationMs    = $DurationMs
            ExecutionMode = $Mode
            Result        = $Result
            Error         = $ErrorMessage
        })
        if ($Result) {
            foreach ($collectionError in @($Result.Errors)) {
                Add-AuditDiagnosticMessage -Message ([string]$collectionError.Message) `
                    -Operation ("Prefetch node {0} diagnostics" -f $collectionError.Operation) `
                    -Scope ("Node={0}; Attempts={1}" -f $Node, $collectionError.AttemptCount)
            }
        }
    }

    $collectSequentialNode = {
        param([string]$Node, [string]$Mode)
        $nodeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if ($Node.Split('.')[0] -eq $localNodeShort) {
                $result = & $collector @collectorArguments
            } else {
                $session = $SessionByNode[$Node]
                if ($session -and $session.State -ne 'Opened') {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    $SessionByNode.Remove($Node)
                    $session = $null
                }
                if (-not $session) {
                    $session = Invoke-WithRetry -DiagnosticOperation 'Open node-diagnostic prefetch remoting session' `
                        -DiagnosticScope ("Node={0}" -f $Node) -ScriptBlock {
                            New-PSSession -ComputerName $Node -ErrorAction Stop
                        }
                    $SessionByNode[$Node] = $session
                }
                $result = Invoke-WithRetry -DiagnosticOperation 'Invoke node-diagnostic prefetch' `
                    -DiagnosticScope ("Node={0}" -f $Node) -ScriptBlock {
                        Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList $collectorArguments -ErrorAction Stop
                    }
            }
            $nodeStopwatch.Stop()
            & $addNodeResult $Node $result ([long]$nodeStopwatch.ElapsedMilliseconds) $Mode ''
        } catch {
            $nodeStopwatch.Stop()
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Prefetch node diagnostics' -Scope ("Node={0}; Mode={1}" -f $Node, $Mode)
            & $addNodeResult $Node $null ([long]$nodeStopwatch.ElapsedMilliseconds) $Mode $_.Exception.Message
        }
    }

    if ($orderedNodes.Count -gt 1 -and $remoteNodes.Count -gt 0) {
        $temporarySessions = [System.Collections.Generic.List[object]]::new()
        $sessionByShortName = @{}
        $fanoutJob = $null
        try {
            foreach ($remoteNode in $remoteNodes) {
                $session = Invoke-WithRetry -DiagnosticOperation 'Open concurrent node-diagnostic prefetch session' `
                    -DiagnosticScope ("Node={0}" -f $remoteNode) -ScriptBlock {
                        New-PSSession -ComputerName $remoteNode -ErrorAction Stop
                    }
                [void]$temporarySessions.Add($session)
                $sessionByShortName[$remoteNode.Split('.')[0].ToLowerInvariant()] = $session
            }

            $executionMode = 'Concurrent'
            $effectiveThrottle = [math]::Min($ThrottleLimit, $remoteNodes.Count)
            $fanoutErrors = @()
            $fanoutJob = Invoke-Command -Session $temporarySessions.ToArray() -ScriptBlock $collector `
                -ArgumentList $collectorArguments -ThrottleLimit $effectiveThrottle -AsJob -ErrorAction Stop

            foreach ($localMatch in $localNodes) {
                & $collectSequentialNode $localMatch 'Local'
            }

            Wait-Job -Job $fanoutJob -ErrorAction Stop | Out-Null
            $remoteResults = @(Receive-Job -Job $fanoutJob -ErrorAction SilentlyContinue -ErrorVariable fanoutErrors)
            foreach ($childJob in @($fanoutJob.ChildJobs)) {
                foreach ($childError in @($childJob.Error)) {
                    Add-AuditDiagnostic -ErrorRecord $childError -Operation 'Concurrent node-diagnostic prefetch child job' `
                        -Scope ("Location={0}; Throttle={1}" -f $childJob.Location, $effectiveThrottle)
                }
            }
            foreach ($remoteNode in $remoteNodes) {
                $nodeShort = $remoteNode.Split('.')[0]
                $remoteResult = @($remoteResults | Where-Object {
                    $_.PSComputerName -and $_.PSComputerName.Split('.')[0].Equals($nodeShort, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
                if ($remoteResult.Count -gt 0) {
                    $workerDurationMs = if ($remoteResult[0].PSObject.Properties['WorkerDurationMs']) {
                        [long]$remoteResult[0].WorkerDurationMs
                    } else { 0L }
                    & $addNodeResult $remoteNode $remoteResult[0] $workerDurationMs 'ConcurrentRemote' ''
                } else {
                    $session = $sessionByShortName[$nodeShort.ToLowerInvariant()]
                    $retryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                    try {
                        $result = Invoke-WithRetry -DiagnosticOperation 'Retry node diagnostics after concurrent fan-out' `
                            -DiagnosticScope ("Node={0}" -f $remoteNode) -ScriptBlock {
                                Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList $collectorArguments -ErrorAction Stop
                            }
                        $retryStopwatch.Stop()
                        & $addNodeResult $remoteNode $result ([long]$retryStopwatch.ElapsedMilliseconds) 'SequentialRetry' ''
                    } catch {
                        $retryStopwatch.Stop()
                        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Retry node diagnostics after concurrent fan-out' `
                            -Scope ("Node={0}" -f $remoteNode)
                        & $addNodeResult $remoteNode $null ([long]$retryStopwatch.ElapsedMilliseconds) 'SequentialRetry' $_.Exception.Message
                    }
                }
            }
            foreach ($fanoutError in @($fanoutErrors)) {
                Add-AuditDiagnostic -ErrorRecord $fanoutError -Operation 'Concurrent node-diagnostic prefetch fan-out' `
                    -Scope ("Nodes={0}; Throttle={1}" -f $remoteNodes.Count, $effectiveThrottle)
            }
        } catch {
            if ($fanoutJob) {
                Stop-Job -Job $fanoutJob -ErrorAction SilentlyContinue
                Remove-Job -Job $fanoutJob -Force -ErrorAction SilentlyContinue
                $fanoutJob = $null
            }
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Prepare concurrent node-diagnostic prefetch' `
                -Scope ("Nodes={0}; FallingBack=Sequential" -f $orderedNodes.Count)
            $executionMode = 'SequentialFallback'
            $effectiveThrottle = 1
            $nodeResults.Clear()
            foreach ($node in $orderedNodes) { & $collectSequentialNode $node 'SequentialFallback' }
        } finally {
            if ($fanoutJob) { Remove-Job -Job $fanoutJob -Force -ErrorAction SilentlyContinue }
            foreach ($temporarySession in @($temporarySessions)) {
                if ($temporarySession) { Remove-PSSession -Session $temporarySession -ErrorAction SilentlyContinue }
            }
        }
    } else {
        foreach ($node in $orderedNodes) {
            & $collectSequentialNode $node $(if ($localNodes -contains $node) { 'Local' } else { 'SequentialRemote' })
        }
    }

    $coordinatorStopwatch.Stop()
    $orderedNodeResults = @($nodeResults | Sort-Object { [array]::IndexOf($orderedNodes, [string]$_.Node) })
    [pscustomobject]@{
        Complete              = (@($orderedNodeResults | Where-Object { -not $_.Complete }).Count -eq 0)
        ExecutionMode         = $executionMode
        ThrottleLimit         = $effectiveThrottle
        Nodes                 = $orderedNodeResults
        CoordinatorDurationMs = [long]$coordinatorStopwatch.ElapsedMilliseconds
    }
}

function Initialize-NodeDiagnosticPrefetch {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Nodes,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LocalNode,
        [AllowEmptyString()][string]$OutputPath,
        [Parameter(Mandatory)][ValidateRange(1, 8760)][int]$LookbackHours,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ConcernIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][int[]]$ContextIds,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CodePatterns,
        [switch]$SkipEvents
    )

    $nodesToCollect = @($Nodes | Where-Object {
        if (-not $_) { return $false }
        $eventCacheKey = "{0}|{1}" -f $_, $LookbackHours
        ((-not $SkipEvents) -and -not $script:NodeEventCache.ContainsKey($eventCacheKey)) -or
            (-not $script:VssByNode.ContainsKey($_))
    } | Sort-Object -Unique)
    if ($nodesToCollect.Count -eq 0) {
        return [pscustomobject]@{
            Complete = $true; ExecutionMode = 'Cached'; ThrottleLimit = 0; Nodes = @(); CoordinatorDurationMs = 0L
        }
    }

    Write-AuditReportLine ("Prefetching read-only event/VSS diagnostics from {0} owning node(s), with bounded cross-node concurrency." -f $nodesToCollect.Count)
    $prefetchStart = Get-TelemetryNow
    $prefetch = Invoke-NodeDiagnosticPrefetch -Nodes $nodesToCollect -LocalNode $LocalNode `
        -SessionByNode $script:SessionByNode -LookbackHours $LookbackHours `
        -ConcernIds $ConcernIds -ContextIds $ContextIds -CodePatterns $CodePatterns `
        -ThrottleLimit 4 -SkipEvents:$SkipEvents
    $prefetchEnd = Get-TelemetryNow

    foreach ($nodeResult in @($prefetch.Nodes)) {
        $node = [string]$nodeResult.Node
        $snapshot = $nodeResult.Result
        if (-not $snapshot) {
            if (-not $SkipEvents) {
                $eventCacheKey = "{0}|{1}" -f $node, $LookbackHours
                $script:NodeEventCache[$eventCacheKey] = [pscustomobject]@{
                    Node = $node; Status = 'Unavailable'; Rows = @(); ChannelStatus = @(
                        [pscustomobject]@{ Channel = 'Worker'; Status = 'Unavailable'; Error = [string]$nodeResult.Error }
                        [pscustomobject]@{ Channel = 'VMMS'; Status = 'Unavailable'; Error = [string]$nodeResult.Error }
                    ); Error = [string]$nodeResult.Error; AttemptedUtc = [DateTime]::UtcNow; AttemptCount = 0
                }
            }
            $script:VssByNode[$node] = $null
            Write-Alert ("  Node diagnostic prefetch failed for '{0}': {1}. Event/VSS evidence is marked unavailable; the audit will continue." -f $node, $nodeResult.Error) -Level Warning
            continue
        }

        if (-not $SkipEvents) {
            $eventCacheKey = "{0}|{1}" -f $node, $LookbackHours
            $script:NodeEventCache[$eventCacheKey] = [pscustomobject]@{
                Node          = $node
                Status        = [string]$snapshot.EventStatus
                Rows          = @($snapshot.EventRows)
                ChannelStatus = @($snapshot.ChannelStatus)
                Error         = [string]$snapshot.EventError
                AttemptedUtc  = [DateTime]$snapshot.WorkerEndUtc
                AttemptCount  = [int]$snapshot.EventAttempts
            }
            if ($snapshot.EventStatus -eq 'Success' -and $OutputPath -and @($snapshot.EventRows).Count -gt 0) {
                $nodeCsvPath = $null
                try {
                    $nodeCsvName = "_NodeEvents_{0}_{1}.csv" -f ($node -replace '[^\w.\-]', '_'), [DateTime]::UtcNow.ToString('yyyy-MM-dd')
                    $nodeCsvPath = Join-Path $OutputPath $nodeCsvName
                    if (-not (Test-Path -LiteralPath $nodeCsvPath)) {
                        @($snapshot.EventRows) | Select-Object 'Time (UTC)', Id, Level, Log, Concern, FullMessage |
                            Export-Csv -LiteralPath $nodeCsvPath -NoTypeInformation -Encoding UTF8
                    }
                    $script:NodeCsvNameByNode[$node] = $nodeCsvName
                } catch {
                    Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Write prefetched node-wide events CSV' `
                        -Scope ("Node={0}; File={1}" -f $node, $nodeCsvPath)
                    Write-Alert "  Could not write the prefetched node-wide events CSV for '$node': $($_.Exception.Message)" -Level Warning
                }
            }
        }

        $script:VssByNode[$node] = if ($snapshot.VssStatus -eq 'Success') { @($snapshot.VssRows) } else { $null }
        if ($snapshot.EventStatus -eq 'Unavailable') {
            Write-Alert ("  Event prefetch was unavailable on '{0}' after {1} attempt(s): {2}" -f $node, $snapshot.EventAttempts, $snapshot.EventError) -Level Warning
        }
        if ($snapshot.VssStatus -eq 'Unavailable') {
            Write-Alert ("  VSS prefetch was unavailable on '{0}' after {1} attempt(s): {2}" -f $node, $snapshot.VssAttempts, $snapshot.VssError) -Level Warning
        }

        $workerStart = [DateTimeOffset]$snapshot.WorkerStartUtc
        $eventStart = $workerStart
        $eventEnd = $eventStart.AddMilliseconds([long]$snapshot.EventDurationMs)
        $vssStart = $eventEnd
        $vssEnd = $vssStart.AddMilliseconds([long]$snapshot.VssDurationMs)
        Add-TelemetryEntry -Step '1.08.10.10' -Phase 'Event prefetch worker' `
            -Detail ("Node={0}; Mode={1}; Status={2}; Rows={3}; Attempts={4}; ChannelErrors={5}" -f `
                $node, $nodeResult.ExecutionMode, $snapshot.EventStatus, @($snapshot.EventRows).Count,
                $snapshot.EventAttempts, @($snapshot.ChannelStatus | Where-Object { $_.Status -ne 'Success' }).Count) `
            -StartUtc $eventStart -EndUtc $eventEnd
        Add-TelemetryEntry -Step '1.08.10.20' -Phase 'VSS prefetch worker' `
            -Detail ("Node={0}; Mode={1}; Status={2}; Writers={3}; Attempts={4}" -f `
                $node, $nodeResult.ExecutionMode, $snapshot.VssStatus, @($snapshot.VssRows).Count, $snapshot.VssAttempts) `
            -StartUtc $vssStart -EndUtc $vssEnd
    }

    Add-TelemetryEntry -Step '1.08.10' -Phase 'Node diagnostic prefetch coordination' `
        -Detail ("Mode={0}; Nodes={1}; Throttle={2}; CompleteNodes={3}; FailedNodes={4}; EventRows={5}; VssWriters={6}; WallDurationMs={7}" -f `
            $prefetch.ExecutionMode, $nodesToCollect.Count, $prefetch.ThrottleLimit,
            @($prefetch.Nodes | Where-Object { $_.Complete }).Count,
            @($prefetch.Nodes | Where-Object { -not $_.Complete }).Count,
            [long](($prefetch.Nodes | ForEach-Object { if ($_.Result) { @($_.Result.EventRows).Count } else { 0 } } | Measure-Object -Sum).Sum),
            [long](($prefetch.Nodes | ForEach-Object { if ($_.Result) { @($_.Result.VssRows).Count } else { 0 } } | Measure-Object -Sum).Sum),
            $prefetch.CoordinatorDurationMs) -StartUtc $prefetchStart -EndUtc $prefetchEnd
    return $prefetch
}

function Get-ClusterVirtualDiskOwnershipInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Nodes,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LocalNode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SessionByNode
    )

    $collector = {
        $workerStartUtc = [DateTime]::UtcNow
        $workerStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $rows = [System.Collections.Generic.List[object]]::new()
        $folders = [System.Collections.Generic.List[object]]::new()
        $errors = [System.Collections.Generic.List[string]]::new()
        $state = [pscustomobject]@{ Complete = $true }
        $parentPathByVhd = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $vhdWithoutParent = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $vmCount = 0
        $snapshotCount = 0

        function Add-OwnershipPath {
            param([string]$VMName, [string]$Path, [string]$Source)
            if ([string]::IsNullOrWhiteSpace($Path)) { return }
            [void]$rows.Add([pscustomobject]@{ VMName = $VMName; Path = $Path; Source = $Source })
            $parent = Split-Path -Path $Path -Parent
            if ($parent) { [void]$folders.Add([pscustomobject]@{ VMName = $VMName; Path = $parent }) }
        }

        function Add-DiskAndChain {
            param([string]$VMName, [string]$Path, [string]$Source)
            if ([string]::IsNullOrWhiteSpace($Path)) { return }
            Add-OwnershipPath -VMName $VMName -Path $Path -Source $Source
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            $cursor = $Path
            for ($depth = 0; $cursor -and $depth -lt 256; $depth++) {
                if (-not $seen.Add($cursor)) {
                    $state.Complete = $false
                    [void]$errors.Add("Cycle detected while reading chain for '$VMName': $cursor")
                    break
                }
                if ($parentPathByVhd.ContainsKey($cursor)) {
                    $parentPath = $parentPathByVhd[$cursor]
                } elseif ($vhdWithoutParent.Contains($cursor)) {
                    $parentPath = ''
                } else {
                    try {
                        $vhd = Get-VHD -Path $cursor -ErrorAction Stop
                        $parentPath = [string]$vhd.ParentPath
                        if ($parentPath) { $parentPathByVhd[$cursor] = $parentPath } else { [void]$vhdWithoutParent.Add($cursor) }
                    } catch {
                        $state.Complete = $false
                        [void]$errors.Add("Get-VHD failed for '$VMName' path '$cursor': $($_.Exception.Message)")
                        break
                    }
                }
                if (-not $parentPath) { break }
                $cursor = $parentPath
                Add-OwnershipPath -VMName $VMName -Path $cursor -Source ($Source + 'Chain')
                if ($depth -eq 255) {
                    $state.Complete = $false
                    [void]$errors.Add("Chain depth limit reached for '$VMName': $Path")
                }
            }
        }

        try {
            $vms = @(Get-VM -ErrorAction Stop)
        } catch {
            $workerStopwatch.Stop()
            return [pscustomobject]@{ Complete = $false; VMCount = 0; SnapshotCount = 0; Rows = @(); Folders = @(); Errors = @("Get-VM failed: $($_.Exception.Message)"); WorkerStartUtc = $workerStartUtc; WorkerEndUtc = [DateTime]::UtcNow; WorkerDurationMs = [long]$workerStopwatch.ElapsedMilliseconds }
        }

        foreach ($vmItem in $vms) {
            $vmCount++
            $vmName = [string]$vmItem.Name
            if ($vmItem.ConfigurationLocation) {
                [void]$folders.Add([pscustomobject]@{ VMName = $vmName; Path = [string]$vmItem.ConfigurationLocation })
            }
            try {
                foreach ($disk in @(Get-VMHardDiskDrive -VM $vmItem -ErrorAction Stop)) {
                    Add-DiskAndChain -VMName $vmName -Path ([string]$disk.Path) -Source 'Current'
                }
            } catch {
                $state.Complete = $false
                [void]$errors.Add("Current disk query failed for '$vmName': $($_.Exception.Message)")
            }
            try {
                $snapshots = @(Get-VMSnapshot -VM $vmItem -ErrorAction Stop)
                $snapshotCount += $snapshots.Count
                foreach ($snapshot in $snapshots) {
                    try {
                        foreach ($disk in @(Get-VMHardDiskDrive -VMSnapshot $snapshot -ErrorAction Stop)) {
                            Add-DiskAndChain -VMName $vmName -Path ([string]$disk.Path) -Source 'Snapshot'
                        }
                    } catch {
                        $state.Complete = $false
                        [void]$errors.Add("Snapshot disk query failed for '$vmName': $($_.Exception.Message)")
                    }
                }
            } catch {
                $state.Complete = $false
                [void]$errors.Add("Snapshot query failed for '$vmName': $($_.Exception.Message)")
            }
        }
        $workerStopwatch.Stop()
        [pscustomobject]@{
            Complete      = [bool]$state.Complete
            VMCount       = $vmCount
            SnapshotCount = $snapshotCount
            Rows          = $rows.ToArray()
            Folders       = $folders.ToArray()
            Errors        = $errors.ToArray()
            WorkerStartUtc = $workerStartUtc
            WorkerEndUtc  = [DateTime]::UtcNow
            WorkerDurationMs = [long]$workerStopwatch.ElapsedMilliseconds
        }
    }

    $orderedNodes = @($Nodes | Where-Object { $_ } | Sort-Object -Unique)
    $localNodeShort = $LocalNode.Split('.')[0]
    $localClusterNode = @($orderedNodes | Where-Object { $_.Split('.')[0] -eq $localNodeShort }).Count -gt 0
    $remoteNodes = @($orderedNodes | Where-Object { $_.Split('.')[0] -ne $localNodeShort })
    $nodeResults = [System.Collections.Generic.List[object]]::new()
    $coordinatorStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $executionMode = 'Sequential'
    $throttleLimit = 1

    $addNodeResult = {
        param([string]$Node, $Result, [long]$DurationMs, [string]$Mode, [string]$ErrorMessage)
        [void]$nodeResults.Add([pscustomobject]@{
            Node          = $Node
            Complete      = ($Result -and [bool]$Result.Complete)
            DurationMs    = $DurationMs
            ExecutionMode = $Mode
            Result        = $Result
            Error         = $ErrorMessage
        })
        if ($Result) {
            foreach ($collectionError in @($Result.Errors)) {
                Add-AuditDiagnosticMessage -Message ([string]$collectionError) `
                    -Operation 'Collect cluster virtual disk ownership inventory' -Scope ("Node={0}" -f $Node)
            }
        }
    }

    $collectSequentialNode = {
        param([string]$Node)
        $nodeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            if ($Node.Split('.')[0] -eq $localNodeShort) {
                $result = & $collector
            } else {
                $session = $SessionByNode[$Node]
                if ($session -and $session.State -ne 'Opened') {
                    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                    $SessionByNode.Remove($Node)
                    $session = $null
                }
                if (-not $session) {
                    $session = Invoke-WithRetry -DiagnosticOperation 'Open ownership-inventory remoting session' -DiagnosticScope ("Node={0}" -f $Node) -ScriptBlock { New-PSSession -ComputerName $Node -ErrorAction Stop }
                    $SessionByNode[$Node] = $session
                }
                $result = Invoke-WithRetry -DiagnosticOperation 'Invoke ownership inventory on cluster node' `
                    -DiagnosticScope ("Node={0}" -f $Node) -ScriptBlock {
                        Invoke-Command -Session $session -ScriptBlock $collector -ErrorAction Stop
                    }
            }
            $nodeStopwatch.Stop()
            & $addNodeResult $Node $result ([long]$nodeStopwatch.ElapsedMilliseconds) `
                $(if ($Node.Split('.')[0] -eq $localNodeShort) { 'Local' } else { 'SequentialRemote' }) ''
        } catch {
            $nodeStopwatch.Stop()
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Collect cluster virtual disk ownership inventory' -Scope ("Node={0}" -f $Node)
            & $addNodeResult $Node $null ([long]$nodeStopwatch.ElapsedMilliseconds) `
                $(if ($Node.Split('.')[0] -eq $localNodeShort) { 'Local' } else { 'SequentialRemote' }) $_.Exception.Message
        }
    }

    if ($localClusterNode -and $remoteNodes.Count -gt 0) {
        $temporarySessions = [System.Collections.Generic.List[object]]::new()
        $sessionByShortName = @{}
        $fanoutJob = $null
        try {
            foreach ($remoteNode in $remoteNodes) {
                $session = Invoke-WithRetry -DiagnosticOperation 'Open concurrent ownership-inventory remoting session' `
                    -DiagnosticScope ("Node={0}" -f $remoteNode) -ScriptBlock { New-PSSession -ComputerName $remoteNode -ErrorAction Stop }
                [void]$temporarySessions.Add($session)
                $sessionByShortName[$remoteNode.Split('.')[0].ToLowerInvariant()] = $session
            }

            $executionMode = 'ConcurrentRemote'
            $throttleLimit = [math]::Min(8, $remoteNodes.Count)

            $fanoutStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $fanoutErrors = @()
            $fanoutJob = Invoke-Command -Session $temporarySessions.ToArray() -ScriptBlock $collector `
                -ThrottleLimit $throttleLimit -AsJob -ErrorAction Stop

            foreach ($localMatch in @($orderedNodes | Where-Object { $_.Split('.')[0] -eq $localNodeShort })) {
                & $collectSequentialNode $localMatch
            }

            Wait-Job -Job $fanoutJob -ErrorAction Stop | Out-Null
            $remoteResults = @(Receive-Job -Job $fanoutJob -ErrorAction SilentlyContinue -ErrorVariable fanoutErrors)
            $fanoutStopwatch.Stop()

            foreach ($remoteNode in $remoteNodes) {
                $nodeShort = $remoteNode.Split('.')[0]
                $remoteResult = @($remoteResults | Where-Object {
                    $_.PSComputerName -and $_.PSComputerName.Split('.')[0].Equals($nodeShort, [StringComparison]::OrdinalIgnoreCase)
                } | Select-Object -First 1)
                if ($remoteResult.Count -gt 0) {
                    $workerDurationMs = if ($remoteResult[0].PSObject.Properties['WorkerDurationMs']) { [long]$remoteResult[0].WorkerDurationMs } else { [long]$fanoutStopwatch.ElapsedMilliseconds }
                    & $addNodeResult $remoteNode $remoteResult[0] $workerDurationMs 'ConcurrentRemote' ''
                } else {
                    $session = $sessionByShortName[$nodeShort.ToLowerInvariant()]
                    $retryStopwatch = $null
                    try {
                        $retryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                        $result = Invoke-WithRetry -DiagnosticOperation 'Retry ownership inventory after concurrent fan-out' `
                            -DiagnosticScope ("Node={0}" -f $remoteNode) -ScriptBlock {
                                Invoke-Command -Session $session -ScriptBlock $collector -ErrorAction Stop
                            }
                        $retryStopwatch.Stop()
                        & $addNodeResult $remoteNode $result ([long]$retryStopwatch.ElapsedMilliseconds) 'SequentialRetry' ''
                    } catch {
                        if ($retryStopwatch) { $retryStopwatch.Stop() }
                        $retryDurationMs = if ($retryStopwatch) { [long]$retryStopwatch.ElapsedMilliseconds } else { 0L }
                        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Collect cluster virtual disk ownership inventory' -Scope ("Node={0}" -f $remoteNode)
                        & $addNodeResult $remoteNode $null $retryDurationMs 'SequentialRetry' $_.Exception.Message
                    }
                }
            }
            foreach ($fanoutError in @($fanoutErrors)) {
                Add-AuditDiagnostic -ErrorRecord $fanoutError -Operation 'Concurrent ownership inventory fan-out' `
                    -Scope ("Nodes={0}; Throttle={1}" -f $remoteNodes.Count, $throttleLimit)
            }
        } catch {
            if ($fanoutJob) {
                Stop-Job -Job $fanoutJob -ErrorAction SilentlyContinue
                Remove-Job -Job $fanoutJob -Force -ErrorAction SilentlyContinue
                $fanoutJob = $null
            }
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Prepare concurrent ownership inventory' `
                -Scope ("Nodes={0}; FallingBack=Sequential" -f $remoteNodes.Count)
            $executionMode = 'SequentialFallback'
            $throttleLimit = 1
            $nodeResults.Clear()
            foreach ($node in $orderedNodes) { & $collectSequentialNode $node }
        } finally {
            if ($fanoutJob) { Remove-Job -Job $fanoutJob -Force -ErrorAction SilentlyContinue }
            foreach ($temporarySession in @($temporarySessions)) {
                if ($temporarySession) { Remove-PSSession -Session $temporarySession -ErrorAction SilentlyContinue }
            }
        }
    } else {
        foreach ($node in $orderedNodes) { & $collectSequentialNode $node }
    }

    $coordinatorStopwatch.Stop()
    $orderedNodeResults = @($nodeResults | Sort-Object { [array]::IndexOf($orderedNodes, [string]$_.Node) })

    $rows = @($orderedNodeResults | ForEach-Object { if ($_.Result) { $_.Result.Rows } } | Where-Object { $_ } |
        Sort-Object VMName, Path, Source -Unique)
    $folders = @($orderedNodeResults | ForEach-Object { if ($_.Result) { $_.Result.Folders } } | Where-Object { $_ } |
        Sort-Object VMName, Path -Unique)
    $errors = @($orderedNodeResults | ForEach-Object {
        $nodeResult = $_
        if ($nodeResult.Error) { "Node '$($nodeResult.Node)': $($nodeResult.Error)" }
        if ($nodeResult.Result) { $nodeResult.Result.Errors | ForEach-Object { "Node '$($nodeResult.Node)': $_" } }
    })
    [pscustomobject]@{
        Complete      = ($orderedNodes.Count -gt 0 -and @($orderedNodeResults | Where-Object { -not $_.Complete }).Count -eq 0)
        ExecutionMode = $executionMode
        ThrottleLimit = $throttleLimit
        CoordinatorDurationMs = [long]$coordinatorStopwatch.ElapsedMilliseconds
        Nodes         = $orderedNodeResults
        Rows          = $rows
        Folders       = $folders
        Errors        = $errors
        VMCount       = [int](($orderedNodeResults | ForEach-Object { if ($_.Result) { $_.Result.VMCount } } | Measure-Object -Sum).Sum)
        SnapshotCount = [int](($orderedNodeResults | ForEach-Object { if ($_.Result) { $_.Result.SnapshotCount } } | Measure-Object -Sum).Sum)
    }
}

function Get-ClusterVirtualDiskFileInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CsvVolumes,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TargetNode,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LocalNode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SessionByNode
    )

    $roots = @($CsvVolumes | ForEach-Object { [string]$_.SharedVolumeInfo.FriendlyVolumeName } |
        Where-Object { $_ } | Sort-Object -Unique)
    $collector = {
        param([string[]]$Roots)
        $files = [System.Collections.Generic.List[object]]::new()
        $rootStatus = [System.Collections.Generic.List[object]]::new()
        foreach ($root in $Roots) {
            $rootStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $rootFiles = [System.Collections.Generic.List[object]]::new()
            $pathErrors = [System.Collections.Generic.List[object]]::new()
            $skippedPaths = [System.Collections.Generic.List[string]]::new()
            try {
                if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "CSV root is not accessible: $root" }
                $pendingPaths = [System.Collections.Generic.Queue[string]]::new()
                $pendingPaths.Enqueue($root)
                while ($pendingPaths.Count -gt 0) {
                    $currentPath = $pendingPaths.Dequeue()
                    try {
                        $children = @(Get-ChildItem -LiteralPath $currentPath -Force -ErrorAction Stop)
                    } catch {
                        [void]$pathErrors.Add([pscustomobject]@{
                            Path   = $currentPath
                            IsRoot = $currentPath.Equals($root, [StringComparison]::OrdinalIgnoreCase)
                            Error  = $_.Exception.Message
                        })
                        continue
                    }
                    foreach ($child in $children) {
                        if ($child.PSIsContainer) {
                            if ($child.Name -eq 'System Volume Information') {
                                [void]$skippedPaths.Add([string]$child.FullName)
                            } elseif (-not ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                                $pendingPaths.Enqueue([string]$child.FullName)
                            }
                        } elseif ($child.Extension -in @('.vhd', '.vhdx', '.avhdx', '.vhds')) {
                            [void]$rootFiles.Add($child)
                        }
                    }
                }
            } catch {
                [void]$pathErrors.Add([pscustomobject]@{ Path = $root; IsRoot = $true; Error = $_.Exception.Message })
            }
            foreach ($file in $rootFiles) {
                [void]$files.Add([pscustomobject]@{
                    Name             = [string]$file.Name
                    FullName         = [string]$file.FullName
                    Extension        = [string]$file.Extension
                    Length           = [long]$file.Length
                    CreationTimeUtc  = $file.CreationTimeUtc
                    LastWriteTimeUtc = $file.LastWriteTimeUtc
                    CsvRoot          = $root
                })
            }
            $rootStopwatch.Stop()
            [void]$rootStatus.Add([pscustomobject]@{
                Root             = $root
                Complete         = ($pathErrors.Count -eq 0)
                DurationMs       = [long]$rootStopwatch.ElapsedMilliseconds
                FileCount        = $rootFiles.Count
                Error            = if ($pathErrors.Count -gt 0) { [string]$pathErrors[0].Error } else { '' }
                PathErrors       = $pathErrors.ToArray()
                SkippedPaths     = $skippedPaths.ToArray()
            })
        }
        [pscustomobject]@{ Files = $files.ToArray(); Roots = $rootStatus.ToArray() }
    }

    try {
        if ($TargetNode.Split('.')[0] -eq $LocalNode.Split('.')[0]) {
            $result = & $collector $roots
        } else {
            $session = $SessionByNode[$TargetNode]
            if ($session -and $session.State -ne 'Opened') {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                $SessionByNode.Remove($TargetNode)
                $session = $null
            }
            if (-not $session) {
                $session = Invoke-WithRetry -DiagnosticOperation 'Open virtual-disk inventory remoting session' -DiagnosticScope ("Node={0}" -f $TargetNode) -ScriptBlock { New-PSSession -ComputerName $TargetNode -ErrorAction Stop }
                $SessionByNode[$TargetNode] = $session
            }
            $result = Invoke-WithRetry -DiagnosticOperation 'Invoke virtual-disk file inventory on cluster node' `
                -DiagnosticScope ("Node={0}" -f $TargetNode) -ScriptBlock {
                    Invoke-Command -Session $session -ScriptBlock $collector -ArgumentList (,$roots) -ErrorAction Stop
                }
        }
        $files = @($result.Files | Sort-Object FullName -Unique)
        $rootStatus = @($result.Roots)
        $pathErrors = @($rootStatus | ForEach-Object { @($_.PathErrors) })
        foreach ($pathError in $pathErrors) {
            Add-AuditDiagnosticMessage -Message ([string]$pathError.Error) `
                -Operation 'Collect cluster virtual disk file inventory' -Scope ("Node={0}; Path={1}" -f $TargetNode, $pathError.Path)
        }
        [pscustomobject]@{
            Complete = ($roots.Count -gt 0 -and @($rootStatus | Where-Object { -not $_.Complete }).Count -eq 0)
            Files    = $files
            Roots    = $rootStatus
            PathErrors = $pathErrors
            SkippedPaths = @($rootStatus | ForEach-Object { @($_.SkippedPaths) })
            Errors   = @($pathErrors | ForEach-Object { "Path '$($_.Path)': $($_.Error)" })
        }
    } catch {
        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Collect cluster virtual disk file inventory' -Scope ("Node={0}" -f $TargetNode)
        [pscustomobject]@{
            Complete = $false
            Files    = @()
            Roots    = @($roots | ForEach-Object {
                [pscustomobject]@{
                    Root         = $_
                    Complete     = $false
                    FileCount    = 0
                    Error        = 'Inventory command failed.'
                    PathErrors   = @([pscustomobject]@{ Path = $_; IsRoot = $true; Error = 'Inventory command failed.' })
                    SkippedPaths = @()
                }
            })
            PathErrors = @($roots | ForEach-Object { [pscustomobject]@{ Path = $_; IsRoot = $true; Error = 'Inventory command failed.' } })
            SkippedPaths = @()
            Errors   = @("Node '$TargetNode': $($_.Exception.Message)")
        }
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
# is NOT proof). Each node is reached in a SINGLE hop from the command's own session (no double hop);
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
        [object[]]$CorrelationAnchors = @(),
        [int]$WindowMinutes = 60,
        [int[]]$SignatureIds,
        [string]$SignatureRx,
        [ValidateSet('HistoricOrphanWindow', 'HistoricActiveCheckpointWindow')]
        [string]$EvidenceScope = 'HistoricOrphanWindow'
    )
    # Collapse the orphan timestamps to distinct search windows (round DOWN to the hour) so many
    # orphans frozen at the same moment produce ONE window, not dozens. NOTE: build a fresh
    # hour-truncated DateTime (zeroing minutes/seconds AND milliseconds) - subtracting whole minutes /
    # seconds leaves the sub-second component intact, which defeats Sort-Object -Unique and produces
    # many near-identical windows.
    $anchorRows = if (@($CorrelationAnchors).Count -gt 0) {
        @($CorrelationAnchors | Where-Object { $_ -and $_.Time } | ForEach-Object {
            [pscustomobject]@{ Time = ([datetime]$_.Time).ToUniversalTime(); Type = [string]$_.Type }
        })
    } else {
        @($Timestamps | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ Time = $_.ToUniversalTime(); Type = 'Unspecified' }
        })
    }
    $hourWindows = @($anchorRows | ForEach-Object {
            $u = $_.Time
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
    foreach ($range in $ranges) {
        $rangeAnchors = @($anchorRows | Where-Object { $_.Time -ge $range.Start -and $_.Time -le $range.End } | ForEach-Object { $_.Type } | Sort-Object -Unique)
        Add-Member -InputObject $range -NotePropertyName Anchor -NotePropertyValue ($rangeAnchors -join '+') -Force
    }

    $localNode = $env:COMPUTERNAME
    $scan = {
        param($vmName, $vmId, $ranges, $sigIds, $sigRx, $evidenceScope)
        $logs = @(
            [pscustomobject]@{ Name = 'Microsoft-Windows-Hyper-V-Worker-Admin'; Channel = 'Worker' }
            [pscustomobject]@{ Name = 'Microsoft-Windows-Hyper-V-VMMS-Admin'; Channel = 'VMMS' }
        )
        $coverage = [System.Collections.Generic.List[object]]::new()
        $hits = [System.Collections.Generic.List[object]]::new()
        foreach ($log in $logs) {
            $oldest = $null
            $querySucceeded = $true
            $queryError = ''
            $isEnabled = $null
            try {
                $isEnabled = [bool](Get-WinEvent -ListLog $log.Name -ErrorAction Stop).IsEnabled
                if ($isEnabled) {
                    $oldestEvent = Get-WinEvent -LogName $log.Name -Oldest -MaxEvents 1 -ErrorAction Stop | Select-Object -First 1
                    if ($oldestEvent) { $oldest = $oldestEvent.TimeCreated }
                }
            } catch {
                if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
                    $querySucceeded = $false
                    $queryError = $_.Exception.Message
                }
            }
            if ($querySucceeded) {
                foreach ($range in $ranges) {
                    try {
                        Get-WinEvent -FilterHashtable @{ LogName = $log.Name; StartTime = $range.Start; EndTime = $range.End } -ErrorAction Stop |
                            Where-Object {
                                ((($vmName -and $_.Message -match [regex]::Escape($vmName)) -or ($vmId -and $_.Message -match [regex]::Escape($vmId)))) -and
                                (($sigIds -contains $_.Id) -or ($sigRx -and $_.Message -match $sigRx))
                            } | ForEach-Object {
                                [void]$hits.Add([pscustomobject]@{
                                    Node    = $env:COMPUTERNAME
                                    Time    = $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
                                    RecordId = [long]$_.RecordId
                                    Id      = [int]$_.Id
                                    Level   = [string]$_.LevelDisplayName
                                    Log     = $log.Channel
                                    Message = ($_.Message -split "`r?`n")[0]
                                    FullMessage = ($_.Message -replace "`r?`n", ' | ')
                                    EvidenceScope = $evidenceScope
                                    CorrelationAnchor = [string]$range.Anchor
                                    CorrelationWindowStartUtc = $range.Start.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
                                    CorrelationWindowEndUtc = $range.End.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
                                })
                            }
                    } catch {
                        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
                            $querySucceeded = $false
                            $queryError = $_.Exception.Message
                            break
                        }
                    }
                }
            }
            [void]$coverage.Add([pscustomobject]@{
                Node            = $env:COMPUTERNAME
                Channel         = $log.Channel
                QuerySucceeded  = $querySucceeded
                IsEnabled       = $isEnabled
                OldestAvailable = $oldest
                Error           = $queryError
            })
        }
        [pscustomobject]@{ Node = $env:COMPUTERNAME; Matches = $hits.ToArray(); Coverage = $coverage.ToArray() }
    }

    $perNode = foreach ($node in @($Nodes | Where-Object { $_ } | Sort-Object -Unique)) {
        try {
            if ($node.Split('.')[0] -eq $localNode) {
                & $scan $VMName $VMId $ranges $SignatureIds $SignatureRx $EvidenceScope
            } else {
                Invoke-Command -ComputerName $node -ScriptBlock $scan -ArgumentList $VMName, $VMId, $ranges, $SignatureIds, $SignatureRx, $EvidenceScope -ErrorAction Stop
            }
        } catch {
            [pscustomobject]@{
                Node = $node
                Matches = @()
                Coverage = @(
                    [pscustomobject]@{ Node = $node; Channel = 'Worker'; QuerySucceeded = $false; IsEnabled = $null; OldestAvailable = $null; Error = $_.Exception.Message }
                    [pscustomobject]@{ Node = $node; Channel = 'VMMS'; QuerySucceeded = $false; IsEnabled = $null; OldestAvailable = $null; Error = $_.Exception.Message }
                )
            }
        }
    }

    $allMatches = @($perNode | ForEach-Object { $_.Matches } | Where-Object { $_ } |
        Group-Object { if ([long]$_.RecordId -gt 0) { '{0}|{1}|{2}' -f $_.Node, $_.Log, $_.RecordId } else { '{0}|{1}|{2}|{3}|{4}' -f $_.Node, $_.Log, $_.Time, $_.Id, $_.FullMessage } } |
        ForEach-Object { $_.Group | Select-Object -First 1 } | Sort-Object Time, Node, Log, RecordId)
    # Earliest point actually searched = the Start of the first merged range (it already includes the
    # -WindowMinutes expansion), so every node/channel is compared against the true search floor.
    $earliestWindowStart = (@($ranges | Sort-Object Start)[0]).Start
    $coverageRows = @($perNode | ForEach-Object { $_.Coverage } | Where-Object { $_ })
    $coverageAssessment = Resolve-EventCoverage -CoverageRows $coverageRows `
        -ExpectedNodes @($Nodes | Where-Object { $_ } | Sort-Object -Unique) `
        -ExpectedChannels @('Worker', 'VMMS') -EarliestWindowStart $earliestWindowStart
    $oldestVals = @($coverageAssessment.Rows | ForEach-Object { $_.OldestAvailable } | Where-Object { $_ } | Sort-Object)
    $oldestAll = if ($oldestVals.Count -gt 0) { $oldestVals[-1] } else { $null }
    [pscustomobject]@{
        Windows            = @($ranges | Sort-Object Start | ForEach-Object { "{0} - {1}" -f $_.Start.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ'), $_.End.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ') })
        WindowMinutes      = $WindowMinutes
        NodesSearched      = @($Nodes | Where-Object { $_ } | Sort-Object -Unique)
        Matches            = $allMatches
        MatchCount         = @($allMatches).Count
        OldestAvailableUtc = if ($oldestAll) { $oldestAll.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ') } else { $null }
        CoverageComplete   = [bool]$coverageAssessment.Complete
        CoverageStatus     = [string]$coverageAssessment.OverallStatus
        Coverage           = @($coverageAssessment.Rows)
        LogsWrappedPastWindow = (@($coverageAssessment.Rows | Where-Object { $_.Status -eq 'Wrapped' }).Count -gt 0)
    }
}



function Initialize-ClusterVirtualDiskInventories {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [AllowEmptyString()][string]$Cluster,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FirstVMName
    )

    if ($null -ne $script:VirtualDiskOwnershipInventory -and $null -ne $script:VirtualDiskFileInventory) { return }

    $localNode = $env:COMPUTERNAME
    $preflightStart = Get-TelemetryNow
    $preflightStatus = 'Completed'
    try {
        if (-not $script:ClusterNameCache) {
            $script:ClusterNameCache = if ($Cluster) {
                (Invoke-WithRetry -DiagnosticOperation 'Resolve requested cluster for inventory preflight' -DiagnosticScope ("Cluster={0}" -f $Cluster) -ScriptBlock { Get-Cluster -Name $Cluster -ErrorAction Stop }).Name
            } else {
                (Invoke-WithRetry -DiagnosticOperation 'Resolve local cluster for inventory preflight' -ScriptBlock { Get-Cluster -ErrorAction Stop }).Name
            }
        }
        if ($null -eq $script:ClusterNodesCache) {
            $script:ClusterNodesCache = @(Invoke-WithRetry -DiagnosticOperation 'Enumerate cluster nodes for inventory preflight' -DiagnosticScope ("Cluster={0}" -f $script:ClusterNameCache) -ScriptBlock {
                Get-ClusterNode -Cluster $script:ClusterNameCache -ErrorAction Stop
            } | ForEach-Object { [string]$_.Name })
        }
        if ($null -eq $script:GroupOwnerByVm) {
            $script:GroupOwnerByVm = @{}
            $script:ClusterGroupByVm = @{}
            $groups = @(Invoke-WithRetry -DiagnosticOperation 'Enumerate cluster groups for inventory preflight' -DiagnosticScope ("Cluster={0}" -f $script:ClusterNameCache) -ScriptBlock {
                Get-ClusterGroup -Cluster $script:ClusterNameCache -ErrorAction Stop
            })
            foreach ($group in $groups) {
                if ($group -and $group.Name -and -not $script:GroupOwnerByVm.ContainsKey([string]$group.Name)) {
                    $script:GroupOwnerByVm[[string]$group.Name] = [string]$group.OwnerNode.Name
                    $script:ClusterGroupByVm[[string]$group.Name] = [pscustomobject]@{ Name = [string]$group.Name; State = [string]$group.State; OwnerNode = [string]$group.OwnerNode.Name }
                }
            }
        }
        if ($null -eq $script:ClusterCsvCache) {
            $script:ClusterCsvCache = @(Invoke-WithRetry -DiagnosticOperation 'Enumerate cluster shared volumes for inventory preflight' `
                -DiagnosticScope ("Cluster={0}" -f $script:ClusterNameCache) -ScriptBlock {
                    Get-ClusterSharedVolume -Cluster $script:ClusterNameCache -ErrorAction Stop
                })
        }

        $nodes = if (@($script:ClusterNodesCache).Count -gt 0) { @($script:ClusterNodesCache) } else { @($localNode) }
        $targetNode = if ($script:GroupOwnerByVm.ContainsKey($FirstVMName)) { [string]$script:GroupOwnerByVm[$FirstVMName] } else { $localNode }
        $ownershipStart = Get-TelemetryNow
        $script:VirtualDiskOwnershipInventory = Get-ClusterVirtualDiskOwnershipInventory -Nodes $nodes -LocalNode $localNode -SessionByNode $script:SessionByNode
        $ownershipEnd = Get-TelemetryNow
        foreach ($nodeTiming in @($script:VirtualDiskOwnershipInventory.Nodes)) {
            $nodeEnd = if ($nodeTiming.Result -and $nodeTiming.Result.PSObject.Properties['WorkerEndUtc']) { [DateTime]$nodeTiming.Result.WorkerEndUtc } else { $ownershipEnd }
            $workerDurationMs = if ($nodeTiming.Result -and $nodeTiming.Result.PSObject.Properties['WorkerDurationMs']) { [long]$nodeTiming.Result.WorkerDurationMs } else { [long]$nodeTiming.DurationMs }
            $rawWorkerStart = if ($nodeTiming.Result -and $nodeTiming.Result.PSObject.Properties['WorkerStartUtc']) { [DateTime]$nodeTiming.Result.WorkerStartUtc } else { $nodeEnd.AddMilliseconds(-1 * $workerDurationMs) }
            $clockAdjustmentMs = [long][math]::Round((($nodeEnd - $rawWorkerStart).TotalMilliseconds) - $workerDurationMs)
            $nodeStart = $nodeEnd.AddMilliseconds(-1 * $workerDurationMs)
            Add-TelemetryEntry -Step '1.07.10.10' -Phase 'Ownership inventory worker' `
                -Detail ("Node={0}; Mode={1}; Complete={2}; VMs={3}; Snapshots={4}; Paths={5}; Error={6}; ClockAdjustmentMs={7}" -f `
                    $nodeTiming.Node, $nodeTiming.ExecutionMode, $nodeTiming.Complete,
                    $(if ($nodeTiming.Result) { [int]$nodeTiming.Result.VMCount } else { 0 }),
                    $(if ($nodeTiming.Result) { [int]$nodeTiming.Result.SnapshotCount } else { 0 }),
                    $(if ($nodeTiming.Result) { @($nodeTiming.Result.Rows).Count } else { 0 }),
                    [bool]$nodeTiming.Error, $clockAdjustmentMs) -StartUtc $nodeStart -EndUtc $nodeEnd
        }
        Add-TelemetryEntry -Step '1.07.10.20' -Phase 'Ownership inventory worker coordination' `
            -Detail ("Mode={0}; Nodes={1}; RemoteNodes={2}; Throttle={3}; FailedNodes={4}; WorkerDurationMs={5}; NodeElapsedMs={6}; WallDurationMs={7}" -f `
                $script:VirtualDiskOwnershipInventory.ExecutionMode, $nodes.Count,
                @($nodes | Where-Object { $_.Split('.')[0] -ne $localNode.Split('.')[0] }).Count,
                $script:VirtualDiskOwnershipInventory.ThrottleLimit,
                @($script:VirtualDiskOwnershipInventory.Nodes | Where-Object { -not $_.Complete }).Count,
                [long](($script:VirtualDiskOwnershipInventory.Nodes | ForEach-Object {
                    if ($_.Result -and $_.Result.PSObject.Properties['WorkerDurationMs']) { [long]$_.Result.WorkerDurationMs } else { [long]$_.DurationMs }
                } | Measure-Object -Sum).Sum),
                [long](($script:VirtualDiskOwnershipInventory.Nodes | Measure-Object DurationMs -Sum).Sum),
                $script:VirtualDiskOwnershipInventory.CoordinatorDurationMs) `
            -StartUtc $ownershipStart -EndUtc $ownershipEnd
        $nodeTimings = @($script:VirtualDiskOwnershipInventory.Nodes | ForEach-Object { '{0}={1}ms' -f $_.Node, $_.DurationMs }) -join ';'
        Add-TelemetryEntry -Step '1.07.10' -Phase 'Preflight cluster virtual disk ownership inventory' `
            -Detail ("Mode={0}; Throttle={1}; Nodes={2}; Paths={3}; Timings={4}; Complete={5}" -f `
                $script:VirtualDiskOwnershipInventory.ExecutionMode, $script:VirtualDiskOwnershipInventory.ThrottleLimit,
                $nodes.Count, @($script:VirtualDiskOwnershipInventory.Rows).Count, $nodeTimings,
                $script:VirtualDiskOwnershipInventory.Complete) -StartUtc $ownershipStart -EndUtc $ownershipEnd

        $fileStart = Get-TelemetryNow
        $script:VirtualDiskFileInventory = Get-ClusterVirtualDiskFileInventory -CsvVolumes @($script:ClusterCsvCache) `
            -TargetNode $targetNode -LocalNode $localNode -SessionByNode $script:SessionByNode
        $rootTimings = @($script:VirtualDiskFileInventory.Roots | ForEach-Object { '{0}={1}ms' -f $_.Root, $_.DurationMs }) -join ';'
        Add-TelemetryEntry -Step '1.07.20' -Phase 'Preflight cluster virtual disk file inventory' `
            -Detail ("Roots={0}; Files={1}; Timings={2}; Complete={3}" -f @($script:VirtualDiskFileInventory.Roots).Count, @($script:VirtualDiskFileInventory.Files).Count, $rootTimings, $script:VirtualDiskFileInventory.Complete) `
            -StartUtc $fileStart -EndUtc (Get-TelemetryNow)
    } catch {
        $preflightStatus = 'Failed'
        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Preflight cluster virtual disk inventories' -Scope ("Cluster={0}; FirstVM={1}" -f $Cluster, $FirstVMName)
        Write-Alert "  Cluster virtual disk inventory preflight could not complete; the first VM audit will retry the missing read-only inventory: $($_.Exception.Message)" -Level Warning
    } finally {
        Add-TelemetryEntry -Step '1.07' -Phase 'Cluster virtual disk inventory preflight (total)' `
            -Detail ("Cluster={0}; FirstVM={1}; Status={2}; OwnershipReady={3}; FileInventoryReady={4}" -f `
                $script:ClusterNameCache, $FirstVMName, $preflightStatus,
                ($null -ne $script:VirtualDiskOwnershipInventory), ($null -ne $script:VirtualDiskFileInventory)) `
            -StartUtc $preflightStart -EndUtc (Get-TelemetryNow)
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
    # supplied it is also written to a per-VM .txt at the end. The Write-AuditReportLine helper (see begin block)
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
    $eventsCsvName = $null
    $reportTimestamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    if ($OutputPath) {
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        $safeName   = ($VMName -replace '[^\w.\-]', '_')
        # VM name FIRST in the file name so per-VM reports sort together alphabetically for humans.
        $reportFile = Join-Path $OutputPath ("{0}_VMAudit_{1}.txt" -f $safeName, $reportTimestamp)
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
            [int]   $StaleAttachedLayerCount = 0,
            [bool]  $SnapshotLayerMismatch   = $false,
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
            StaleAttachedLayerCount = $StaleAttachedLayerCount
            SnapshotLayerMismatch   = $SnapshotLayerMismatch
            ConcernEventCount       = $ConcernEventCount
            ReportFile              = $reportFile
            Detail                  = $Detail
            ReportData              = $ReportData
        }
    }

    function Write-VMEventsMarkerCsv {
        param([Parameter(Mandatory = $true)][string]$Message)

        if (-not $OutputPath -or -not $reportFile) { return $null }

        $markerCsvName = "{0}_Events_{1}.csv" -f ($VMName -replace '[^\w.\-]', '_'), [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        $markerCsvPath = Join-Path (Split-Path -Parent $reportFile) $markerCsvName
        [pscustomobject]@{
            'Time (UTC)' = ''
            Node         = ''
            Id           = ''
            Level        = 'Info'
            Log          = ''
            Concern      = ''
            CollectedAsConcern = $false
            VmAttributed = ''
            AttributionMethod = ''
            AttributionConfidence = ''
            EvidenceScope = 'StandardLookback'
            CorrelationAnchor = ''
            CorrelationWindowStartUtc = ''
            CorrelationWindowEndUtc = ''
            EventClassification = 'Informational'
            VerdictDriver = $false
            IsConfirmingFork = $false
            RecoveryDisposition = 'NotApplicable'
            DispositionReason = 'Marker row; no event was assessed.'
            FullMessage  = $Message
        } | Select-Object 'Time (UTC)', Node, Id, Level, Log, Concern, CollectedAsConcern, VmAttributed, AttributionMethod,
            AttributionConfidence, EvidenceScope, CorrelationAnchor, CorrelationWindowStartUtc,
            CorrelationWindowEndUtc, EventClassification, VerdictDriver, IsConfirmingFork,
            RecoveryDisposition, DispositionReason, FullMessage |
            Export-Csv -LiteralPath $markerCsvPath -NoTypeInformation -Encoding UTF8
        return $markerCsvName
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
            $ClusterName = (Invoke-WithRetry -DiagnosticOperation 'Resolve requested cluster' -DiagnosticScope ("Cluster={0}; VM={1}" -f $Cluster, $VMName) -ScriptBlock { Get-Cluster -Name $Cluster -ErrorAction Stop }).Name
            $script:ClusterNameCache = $ClusterName
        } else {
            $ClusterName = (Invoke-WithRetry -DiagnosticOperation 'Resolve local cluster' -DiagnosticScope ("VM={0}" -f $VMName) -ScriptBlock { Get-Cluster -ErrorAction Stop }).Name
            $script:ClusterNameCache = $ClusterName
        }
    } catch {
        if ($Cluster) {
            Write-Alert "  ERROR: could not reach cluster '$Cluster': $($_.Exception.Message)" -Level Critical
            Write-Alert "  Check the name, that the RSAT 'Failover Clustering' tools are installed, and that you have rights to it." -Level Critical
        } else {
            Write-Alert "  ERROR: this host is not a cluster node, or the Cluster service is not running: $($_.Exception.Message)" -Level Critical
            Write-Alert "  Run this command ON a cluster node, or from a management host using -Cluster <ClusterName>." -Level Critical
        }
        return (New-AuditSummary -Recommendation 'ERROR' -Detail 'Cluster could not be resolved (see console).')
    }

    # --- Resolve the VM's OWNING NODE without relying on double-hop authentication ------------------
    # This command is designed to run either locally on a cluster node (interactive / SConfig logon) or
    # via a SINGLE PowerShell Remoting hop into one node. To avoid a second ("double") hop we (1) find
    # the cluster nodes and the VM's owning node using the cluster API (RPC - no WinRM), then (2) run
    # every data-collection command in the OWNER CONTEXT: directly (locally) when this node owns the
    # VM, otherwise through ONE remoting session to the owning node (see Invoke-OnOwner above).
    $LocalNode    = $env:COMPUTERNAME
    # v0.2.14: cluster node list fetched once per run (Get-ClusterNode), reused for every VM.
    if ($null -eq $script:ClusterNodesCache) {
        try {
            $script:ClusterNodesCache = @(Invoke-WithRetry -DiagnosticOperation 'Enumerate cluster nodes' -DiagnosticScope ("Cluster={0}" -f $ClusterName) -ScriptBlock { Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop } | ForEach-Object { [string]$_.Name })
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
        $script:ClusterGroupByVm = @{}
        $allClusterGroups = @()
        try { $allClusterGroups = @(Invoke-WithRetry -DiagnosticOperation 'Enumerate cluster groups' -DiagnosticScope ("Cluster={0}" -f $ClusterName) -ScriptBlock { Get-ClusterGroup -Cluster $ClusterName -ErrorAction Stop }) }
        catch { Write-Alert "  Could not enumerate cluster groups (after retries): $($_.Exception.Message)" -Level Warning }
        foreach ($g in $allClusterGroups) {
            if ($g -and $g.Name -and -not $script:GroupOwnerByVm.ContainsKey([string]$g.Name)) {
                $script:GroupOwnerByVm[[string]$g.Name] = [string]$g.OwnerNode.Name
                $script:ClusterGroupByVm[[string]$g.Name] = [pscustomobject]@{
                    Name      = [string]$g.Name
                    State     = [string]$g.State
                    OwnerNode = [string]$g.OwnerNode.Name
                }
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
                        $names = @(Get-VM -ErrorAction Stop | ForEach-Object { [string]$_.Name })
                    } else {
                        $names = @(Invoke-Command -ComputerName $node -ScriptBlock {
                            Get-VM -ErrorAction Stop | ForEach-Object { [string]$_.Name }
                        } -ErrorAction Stop)
                    }
                    foreach ($vmn in $names) {
                        if ($vmn -and -not $script:ProbeVmNodeMap.ContainsKey($vmn)) { $script:ProbeVmNodeMap[$vmn] = $node }
                    }
                } catch {
                    Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Enumerate VMs on node (fallback discovery)' -Scope ("Node={0}; Cluster={1}; RequestedVM={2}" -f $node, $ClusterName, $VMName)
                    # Could not reach this node in a single hop - keep building from the others.
                }
            }
        }
        if ($script:ProbeVmNodeMap.ContainsKey($VMName)) { $OwningNode = [string]$script:ProbeVmNodeMap[$VMName] }
    }

    if (-not $OwningNode) {
        $notFoundReason = "VM '$VMName' was not found on any node of cluster '$ClusterName'; event collection was not attempted."
        Write-Section 'RESULT: NOT FOUND - this VM was not fully assessed. Do not treat it as healthy based on this report.'
        Write-AuditReportLine ("  Input VM name: {0}" -f $VMName)
        Write-AuditReportLine ("  Cluster: {0}" -f $ClusterName)
        Write-AuditReportLine ("  Reason: VM was not found on any cluster node.")
        Write-AuditReportLine "  Event collection was not attempted for the missing VM."
        $eventsCsvName = Write-VMEventsMarkerCsv -Message $notFoundReason
        if ($eventsCsvName) {
            Write-AuditReportLine ("Events CSV marker written to: {0}" -f (Join-Path (Split-Path -Parent $reportFile) $eventsCsvName))
        }
        Write-AuditReportLine ""
        Write-Section 'Required follow-up:'
        Write-AuditReportLine "  1. Verify the VM name spelling and any naming differences."
        Write-AuditReportLine "  2. Verify that '$ClusterName' is the cluster that owns the VM."
        Write-AuditReportLine ("  3. Rerun: Get-HyperVVMCheckpointHealth -VMName '<confirmed-name>' -Cluster '{0}' -OutputPath '{1}'" -f $ClusterName, $OutputPath)
        Write-AuditReportLine ""
        Write-AuditReportLine "  No checkpoint, disk, Replica, VSS, or event conclusion was produced for this VM."
        return (New-AuditSummary -Recommendation 'NOT FOUND' -Detail $notFoundReason)
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
                $pooled = Invoke-WithRetry -DiagnosticOperation 'Open VM-owner remoting session' -DiagnosticScope ("VM={0}; Owner={1}" -f $VMName, $OwningNode) -ScriptBlock { New-PSSession -ComputerName $OwningNode -ErrorAction Stop }
                $script:SessionByNode[$OwningNode] = $pooled
            } catch {
                Write-Alert "  ERROR: could not open a remoting session to owning node '$OwningNode': $($_.Exception.Message)" -Level Critical
                Write-Alert "  TIP: run this command directly ON the owning node (interactive / SConfig logon), or from a" -Level Critical
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
            Name                        = [string]$v.Name
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
        Write-AuditReportLine "VM '$VMName' could not be read on owning node '$OwningNode'."
        return (New-AuditSummary -Recommendation 'ERROR' -Owner $OwningNode -Detail 'VM object could not be read on the owning node.')
    }
    # Use Hyper-V's canonical VM-name casing for successful results and artifacts. Preserve the
    # operator-supplied name for NOT FOUND / ERROR rows where no authoritative VM object exists.
    if ($vm.Name) {
        $VMName = [string]$vm.Name
        if ($OutputPath) {
            $safeName = ($VMName -replace '[^\w.\-]', '_')
            $reportFile = Join-Path $OutputPath ("{0}_VMAudit_{1}.txt" -f $safeName, $reportTimestamp)
        }
    }
    # Attach the (cached) per-node supported-version list to the VM projection so downstream code that
    # reads $vm.HostSupportedVersions is unchanged.
    Add-Member -InputObject $vm -NotePropertyName HostSupportedVersions -NotePropertyValue $hostSupportedVersions -Force

    $stateTokenCollectorDefinition = (Get-Command Get-VMCollectionStateToken -CommandType Function).Definition
    $stateTokenStart = $null
    $stateTokenStartError = ''
    try {
        $stateTokenStart = Invoke-OnOwner -ScriptBlock {
            param($name, $owner, $collectorDefinition)
            $collectStateToken = [scriptblock]::Create($collectorDefinition)
            & $collectStateToken -VMName $name -OwnerNode $owner
        } -ArgumentList $VMName, $OwningNode, $stateTokenCollectorDefinition
    } catch {
        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Capture initial VM state token' -Scope ("VM={0}; Owner={1}" -f $VMName, $OwningNode)
        $stateTokenStartError = $_.Exception.Message
        Write-Alert "  Could not capture the initial VM state token: $stateTokenStartError" -Level Warning
    }

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
    Write-AuditReportLine "==================================================================="
    Write-Section "  VM CheckPoint (Differencing Disk) Audit"
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'Cluster', $ClusterName)
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'VM Name', $VMName)
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'VM Id', $vm.VMId)
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'Owning Node', $OwningNode)
    # Colour the VM Status: 'Operating normally' = green, Critical/Error/Failed = red, else amber.
    $statusLevel = switch -Wildcard ("$($vm.Status)") { 'Operating normally' { 'Good'; break } '*Critical*' { 'Critical'; break } '*Error*' { 'Critical'; break } '*Fail*' { 'Critical'; break } default { 'Warning' } }
    Write-Alert ("  {0,-27} : {1}" -f 'VM Status', $vm.Status) -Level $statusLevel
    # Colour the VM State: Running = green, anything containing 'Critical' = red, else amber.
    $stateLevel = switch -Wildcard ("$($vm.State)") { 'Running' { 'Good' } '*Critical*' { 'Critical' } default { 'Warning' } }
    Write-Alert ("  {0,-27} : {1}" -f 'VM State', $vm.State) -Level $stateLevel
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'VM Config Version', $vm.Version)
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'Latest supported by cluster', $(if ($hostMaxVer) { $hostMaxVer } else { 'unknown' }))
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'Uptime', $vm.Uptime)
    # Auto Checkpoints: when True, Hyper-V takes a checkpoint automatically every time the VM STARTS
    # (a Client Hyper-V default; normally False on servers/clusters) - a source of 'unexpected' .avhdx
    # layers. Checkpoint Type is the style of checkpoint the VM is configured to take, which governs
    # how each checkpoint's fork is committed (the failure mode under investigation). Values annotated.
    $autoCkptNote = if ($vm.AutomaticCheckpointsEnabled) { 'auto checkpoint taken at every VM start' } else { 'no automatic checkpoint at VM start' }
    Write-AuditReportLine ("  {0,-27} : {1} ({2})" -f 'Auto Checkpoints', $vm.AutomaticCheckpointsEnabled, $autoCkptNote)
    $ckptTypeNote = switch ("$($vm.CheckpointType)") {
        'Production'     { 'app-consistent via in-guest VSS; falls back to Standard if VSS is unavailable' }
        'ProductionOnly' { 'app-consistent via in-guest VSS; FAILS if VSS is unavailable (no fallback)' }
        'Standard'       { 'captures saved memory / running state (dev/test style)' }
        'Disabled'       { 'checkpoints are not allowed on this VM' }
        default          { '' }
    }
    if ($ckptTypeNote) {
        Write-AuditReportLine ("  {0,-27} : {1} ({2})" -f 'Checkpoint Type', $vm.CheckpointType, $ckptTypeNote)
    } else {
        Write-AuditReportLine ("  {0,-27} : {1}" -f 'Checkpoint Type', $vm.CheckpointType)
    }
    Write-AuditReportLine ("  {0,-27} : {1} hours (flagged as 'YES')" -f 'Stale >=', $StaleHours)
    Write-AuditReportLine ("  {0,-27} : {1}" -f 'Collection started (UTC)', [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ssZ'))
    Write-AuditReportLine "==================================================================="

    # Clustered role state / current owner (should match the Owning Node above):
    Show-AuditProgress -Step 10 -Status 'Reading cluster role'
    Write-Section "Cluster Role (Get-ClusterGroup):"
    $group = if ($script:ClusterGroupByVm.ContainsKey($VMName)) { $script:ClusterGroupByVm[$VMName] } else { $null }
    if ($group) {
        $group | Format-Table Name, State, OwnerNode -AutoSize | Out-Indented
    } else {
        Write-AuditReportLine "  No clustered role named '$VMName' found (the VM may be non-clustered)."
        Write-AuditReportLine ""
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
        Write-AuditReportLine ("  Path           : {0}" -f $vmcxInfo.FullName)
        Write-AuditReportLine ("  LastWrite (UTC): {0}" -f $vmcxInfo.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ'))
        Write-AuditReportLine ("  Age (hrs)      : {0}" -f [math]::Round(([DateTime]::UtcNow - $vmcxInfo.LastWriteTimeUtc).TotalHours, 1))
    } else {
        Write-AuditReportLine ("  Config file not found at expected path (older .xml format?): {0}" -f $vmcxPath)
    }
    Write-AuditReportLine ""

    # Track every VHD path we touch, so we can later spot orphaned .avhdx files on disk:
    $allChainPaths = [System.Collections.Generic.List[string]]::new()
    # Set true if the orphan scan below finds any .avhdx not part of an attached chain (feeds -PassThru).
    $hasOrphans = $false
    # Orphaned .avhdx rows found by the scan below (initialised here so the HTML data build can read it
    # even when no VHD folders were resolved to scan).
    $orphans = @()
    # Cluster Shared Volume rows hosting this VM's disks (captured for the HTML report; see below).
    $csvReport = @()
    $csvFreeSpaceAssessment = $null
    # Hyper-V Replica object for this VM (null unless replication is enabled; read by the HTML build).
    $replInfo = $null
    $replAssessment = $null
    $replicationServerSettings = $null
    # Nodes whose Hyper-V-VMMS/Analytic channel is NOT actively enabled (disabled, or 'not found').
    # Populated by the Analytic section below and surfaced as a TIP in the RESULT block so the operator
    # can choose to enable it for extra diagnostic detail on the NEXT occurrence (it is easily missed
    # mid-report). Stays empty when -SkipAnalyticCheck is used, so no TIP is shown in that case.
    $analyticNodesNeedEnable = @()

    # Enumerate each attached disk and resolve its full differencing chain (top .avhdx -> ... -> base).
    # This runs in ONE owner-context call (single hop for a remote owner) and flattens the VhdType enum
    # to a string on the owner, so the downstream 'Differencing' comparisons are robust after transport.
    Show-AuditProgress -Step 20 -Status 'Enumerating attached disks and differencing chains'
    $chainCollectionStart = Get-TelemetryNow
    $diskReports = [System.Collections.Generic.List[object]]::new()
    $chainCollectorDefinition = (Get-Command Get-VHDChainReport -CommandType Function).Definition
    $rawDisks = @(Invoke-OnOwner -ScriptBlock {
        param($n, $collectorDefinition)
        $vmObj  = Get-VM -Name $n -ErrorAction SilentlyContinue
        $collectChain = [scriptblock]::Create($collectorDefinition)
        foreach ($disk in (Get-VMHardDiskDrive -VM $vmObj -ErrorAction SilentlyContinue)) {
            $chainReport = & $collectChain -Path $disk.Path
            [pscustomobject]@{
                Attached    = Split-Path $disk.Path -Leaf
                Path        = [string]$disk.Path
                Chain       = @($chainReport.Chain)
                Complete    = [bool]$chainReport.Complete
                FailurePath = [string]$chainReport.FailurePath
                ChainError  = [string]$chainReport.Error
                TerminalType = [string]$chainReport.TerminalType
                DepthLimitReached = [bool]$chainReport.DepthLimitReached
            }
        }
    } -ArgumentList $VMName, $chainCollectorDefinition)

    foreach ($rd in $rawDisks) {
        $chain = @($rd.Chain)
        foreach ($layer in $chain) { $allChainPaths.Add([string]$layer.Path) }
        if ($chain.Count -eq 0) {
            # Could not read even the attached disk - record a minimal entry so it still appears.
            $diskReports.Add([pscustomobject]@{
                Attached = $rd.Attached; Path = $rd.Path; TopType = 'Unknown'
                SizeGB = $null; ChainDepth = 0; CheckpointCount = 0; AnyStale = $false; Chain = $chain
                ChainComplete = [bool]$rd.Complete; ChainError = [string]$rd.ChainError; FailurePath = [string]$rd.FailurePath
                TerminalType = [string]$rd.TerminalType; DepthLimitReached = [bool]$rd.DepthLimitReached
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
            # Checkpoint age comes from the DIFFERENCING layer's creation time. LastWrite is activity
            # evidence only: an active AVHDX can be written continuously while its checkpoint grows old.
            AnyStale        = (@($chain | Where-Object { $_.Type -eq 'Differencing' -and $_.Created -and ([DateTime]::UtcNow - $_.Created).TotalHours -ge $StaleHours }).Count -gt 0)
            Chain           = $chain
            ChainComplete   = [bool]$rd.Complete
            ChainError      = [string]$rd.ChainError
            FailurePath     = [string]$rd.FailurePath
            TerminalType    = [string]$rd.TerminalType
            DepthLimitReached = [bool]$rd.DepthLimitReached
        })
    }
    $incompleteChains = @($diskReports | Where-Object { -not $_.ChainComplete })
    $hasIncompleteChain = $incompleteChains.Count -gt 0
    $chainLayerCount = (@($diskReports | ForEach-Object { [int]$_.ChainDepth }) | Measure-Object -Sum).Sum
    if (-not $chainLayerCount) { $chainLayerCount = 0 }
    Add-TelemetryEntry -Step '1.10.20.10' -Phase 'VHD chain collection and validation' `
        -Detail ("{0}; Disks={1}; Layers={2}; Incomplete={3}" -f $VMName, $diskReports.Count, $chainLayerCount, $incompleteChains.Count) `
        -StartUtc $chainCollectionStart -EndUtc (Get-TelemetryNow)

    # (a) Overview - one compact row per attached disk (short columns, never wraps). ChainSizeGB is
    # the TOTAL of every layer in the chain (active .avhdx + any checkpoints + base), NOT the size of
    # the single attached file - the per-layer sizes are broken out under 'Differencing Chains' below.
    Write-Section "Attached Disks ($($diskReports.Count)):"
    $diskReports | Select-Object `
        Attached,
        @{N='Type';E={ $_.TopType }},
        @{N='ChainSizeGB';E={ $_.SizeGB }},
        ChainDepth,
        ChainComplete,
        TerminalType,
        CheckpointCount,
        @{N='Stale';E={ if ($_.CheckpointCount -gt 0) { if ($_.AnyStale) { 'YES' } else { 'NO' } } else { 'n/a' } }} | Format-Table -AutoSize | Out-Indented

    # (b) Per-disk detail - one labelled block per disk so the full path is never truncated or
    # column-wrapped, including the attached (top-of-chain) disk's size, timestamps, age and stale flag:
    Write-Section "Attached Disk Detail:"
    $diskIndex = 0
    foreach ($d in $diskReports) {
        $diskIndex++
        Write-AuditReportLine ("  Disk {0} of {1}" -f $diskIndex, $diskReports.Count)
        Write-AuditReportLine ("  Disk File Name : {0}" -f $d.Attached)
        Write-AuditReportLine ("  Disk Full Path : {0}" -f $d.Path)
        Write-AuditReportLine ("  Type           : {0}" -f $d.TopType)
        $top = if ($d.Chain.Count -gt 0) { $d.Chain[0] } else { $null }
        if ($top) {
            Write-AuditReportLine ("  This Disk (GB) : {0}" -f $top.SizeGB)
        }
        Write-AuditReportLine ("  Chain Size (GB): {0} (total across all {1} layer(s))" -f $d.SizeGB, $d.ChainDepth)
        Write-AuditReportLine ("  Chain Complete : {0}" -f $(if ($d.ChainComplete) { 'YES' } else { 'NO' }))
        Write-AuditReportLine ("  Terminal Type  : {0}" -f $(if ($d.TerminalType) { $d.TerminalType } else { '(not reached)' }))
        if (-not $d.ChainComplete) {
            Write-Alert ("  Chain read failed at '{0}': {1}" -f $d.FailurePath, $d.ChainError) -Level Critical
            Write-Alert "  This disk's parent chain is incomplete; do not treat its layer counts as authoritative." -Level Critical
        }
        if ($top -and $top.Created) {
            $topCheckpointAge = [math]::Round(([DateTime]::UtcNow - $top.Created).TotalHours, 1)
            Write-AuditReportLine ("  Created (UTC)  : {0}" -f $top.Created.ToString('yyyy-MM-dd HH:mm:ssZ'))
            if ($top.Type -eq 'Differencing') {
                Write-AuditReportLine ("  Checkpoint age : {0} hours (since AVHDX creation)" -f $topCheckpointAge)
            } elseif ($top.Type -in @('Dynamic', 'Fixed')) {
                Write-AuditReportLine ("  Disk age       : {0} hours (since base disk creation)" -f $topCheckpointAge)
            } else {
                Write-AuditReportLine ("  Disk age       : {0} hours (since file creation)" -f $topCheckpointAge)
            }
        } else {
            Write-AuditReportLine "  Created (UTC)  : (unavailable)"
            if ($top -and $top.Type -eq 'Differencing') {
                Write-AuditReportLine "  Checkpoint age : (unavailable)"
            } else {
                Write-AuditReportLine "  Disk age       : (unavailable)"
            }
        }
        if ($top -and $top.LastWrite) {
            $topActivityAge = [math]::Round(([DateTime]::UtcNow - $top.LastWrite).TotalHours, 1)
            Write-AuditReportLine ("  LastWrite (UTC): {0}" -f $top.LastWrite.ToString('yyyy-MM-dd HH:mm:ssZ'))
            Write-AuditReportLine ("  Last activity  : {0} hours (since last write; ~0 = active / in-use)" -f $topActivityAge)
            $topStale = if ($top.Type -eq 'Differencing') {
                if ($top.Created -and $topCheckpointAge -ge $StaleHours) { 'YES' } else { 'NO' }
            } elseif ([System.IO.Path]::GetExtension([string]$top.Path).Equals('.vhds', [System.StringComparison]::OrdinalIgnoreCase)) {
                'n/a (shared VHD Set)'
            } elseif ($top.Type -in @('Dynamic', 'Fixed')) { 'n/a (base)' } else { "n/a ($($top.Type))" }
            Write-AuditReportLine ("  Checkpoint stale: {0}" -f $topStale)
        } else {
            Write-AuditReportLine "  LastWrite (UTC): (unavailable)"
            Write-AuditReportLine "  Last activity  : (unavailable)"
        }
        Write-AuditReportLine ""
    }

    # (c) Differencing-chain detail - ONLY for disks that actually have a checkpoint layer
    # (ChainDepth > 1). Depth-1 disks add nothing here, so they are omitted to keep the report short.
    $deepDisks = @($diskReports | Where-Object { $_.ChainDepth -gt 1 })
    if ($deepDisks.Count -gt 0) {
        Write-Section "Differencing Chains (disks with a checkpoint layer):"
        foreach ($d in $deepDisks) {
            Write-AuditReportLine "  $($d.Attached):"
            Write-AuditReportLine "  Level 0 = the ACTIVE disk the VM writes to (child); each level's parent is the"
            Write-AuditReportLine "  level below it; the highest level is the BASE. Chains can be many layers deep."
            Write-AuditReportLine "  CheckpointAgeHrs = hours since an AVHDX layer was created; LastActivityHrs = hours"
            Write-AuditReportLine "  since it was last written. Base disks are not checkpoints and show n/a (base)."
            # Project the chain with an explicit Level (0 = active top) and Role so the parent -> child
            # hierarchy and total depth are unambiguous. SizeGB here is each LAYER's own size.
            $chainRows = for ($li = 0; $li -lt $d.Chain.Count; $li++) {
                $c = $d.Chain[$li]
                $role = if ($c.Type -eq 'Differencing') {
                    if ($li -eq 0) { 'Active (top)' } else { 'Checkpoint' }
                } elseif ([System.IO.Path]::GetExtension([string]$c.Path).Equals('.vhds', [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ($li -eq 0) { 'Active VHD Set (top)' } else { 'VHD Set' }
                } elseif ($c.Type -in @('Dynamic', 'Fixed')) { 'Base' } else { "Attached ($($c.Type))" }
                [pscustomobject]@{
                    Level             = $li
                    Role              = $role
                    'VHD File Name'   = Split-Path $c.Path -Leaf
                    Type              = $c.Type
                    SizeGB            = $c.SizeGB
                    CheckpointAgeHrs  = if ($c.Type -eq 'Differencing' -and $c.Created) { [math]::Round(([DateTime]::UtcNow - $c.Created).TotalHours, 1) } else { $null }
                    LastActivityHrs   = if ($c.LastWrite) { [math]::Round(([DateTime]::UtcNow - $c.LastWrite).TotalHours, 1) } else { $null }
                    CheckpointStale   = if ($c.Type -in @('Dynamic', 'Fixed')) { 'n/a (base)' } elseif ($c.Type -ne 'Differencing') { 'n/a' } elseif ($c.Created -and ([DateTime]::UtcNow - $c.Created).TotalHours -ge $StaleHours) { 'YES' } else { 'NO' }
                }
            }
            $chainRows | Format-Table Level, Role, 'VHD File Name', Type, SizeGB, CheckpointAgeHrs, LastActivityHrs, CheckpointStale -AutoSize | Out-Indented
        }
    } else {
        Write-Section "Differencing Chains: none (no attached disk has a checkpoint layer)."
        Write-AuditReportLine ""
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
            Write-AuditReportLine "  (Could not match this VM's disks to a specific volume - showing all cluster volumes.)"
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
        $csvFreeSpaceAssessment = Get-CsvFreeSpaceAssessment -Volumes $csvReport -Policy $script:CheckpointHealthPolicy.CsvFreeSpace
        if ($csvFreeSpaceAssessment.IsConcern) {
            Write-Alert ("  CSV free-space policy breached on {0} hosting volume(s). Thresholds: free >= {1}% and >= {2} GB." -f `
                @($csvFreeSpaceAssessment.Breaches).Count, $csvFreeSpaceAssessment.MinimumFreePercent, $csvFreeSpaceAssessment.MinimumFreeGB) -Level Warning
        }
    } catch {
        Write-AuditReportLine "  Could not query Cluster Shared Volumes: $($_.Exception.Message)"
        Write-AuditReportLine ""
    }

    # Named checkpoints on the VM - maps .avhdx files to checkpoints such as 'Initial Replica'.
    # Collected in the owner context (single hop for a remote owner), including each checkpoint's disk
    # folders so the orphan / .hrl scans below know where to look.
    Show-AuditProgress -Step 30 -Status 'Enumerating checkpoints'
    Write-Section "Checkpoints (Get-VMSnapshot):"
    $ckptData = Invoke-OnOwner -ScriptBlock {
        param($n)
        $snaps   = Get-VMSnapshot -VMName $n -ErrorAction SilentlyContinue
        $rows    = [System.Collections.Generic.List[object]]::new()
        $folders = [System.Collections.Generic.List[string]]::new()
        foreach ($s in $snaps) {
            $snapType = if ($s.PSObject.Properties['SnapshotType']) { [string]$s.SnapshotType } elseif ($s.PSObject.Properties['CheckpointType']) { [string]$s.CheckpointType } else { '' }
            $typeVal  = if ($s.PSObject.Properties['CheckpointType']) { [string]$s.CheckpointType } else { [string]$s.SnapshotType }
            $parentProperty = if ($s.PSObject.Properties['ParentCheckpointName']) { $s.PSObject.Properties['ParentCheckpointName'] } else { $s.PSObject.Properties['ParentSnapshotName'] }
            $parent = if ($parentProperty) { [string]$parentProperty.Value } else { '' }
            [void]$rows.Add([pscustomobject]@{
                Name            = [string]$s.Name
                Type            = $typeVal
                SnapType        = $snapType
                CreationTimeUtc = $s.CreationTime.ToUniversalTime()
                Parent          = $parent
                ParentDisplay   = if (-not $parentProperty) { 'Unavailable' } elseif ([string]::IsNullOrWhiteSpace($parent)) { 'n/a (root)' } else { $parent }
            })
            foreach ($hd in (Get-VMHardDiskDrive -VMSnapshot $s -ErrorAction SilentlyContinue)) {
                if ($hd.Path) { [void]$folders.Add((Split-Path $hd.Path -Parent)) }
            }
        }
        [pscustomobject]@{ Rows = $rows.ToArray(); Folders = $folders.ToArray() }
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
            @{N='Created (UTC)';E={ $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ') }},
            @{N='Age (hrs)';E={ [math]::Round(([DateTime]::UtcNow - $_.CreationTimeUtc).TotalHours, 1) }},
            @{N='Stale';E={ if (([DateTime]::UtcNow - $_.CreationTimeUtc).TotalHours -ge $StaleHours) { 'YES' } else { 'NO' } }},
            @{N='Parent';E={ $_.ParentDisplay }} | Out-Indented
    } else {
        Write-AuditReportLine "  No checkpoints present on '$VMName'."
        Write-AuditReportLine ""
    }

    # Collect every folder holding one of this VM's VHDs - the attached chain AND any checkpoint disks -
    # so we scan all relevant locations. There is no separate HRL path setting in Hyper-V Replica: the
    # .hrl log always sits next to the VHD it protects.
    $folderSet = [System.Collections.Generic.List[string]]::new()
    $allChainPaths | ForEach-Object { $folderSet.Add((Split-Path $_ -Parent)) }
    foreach ($f in @($ckptData.Folders)) { if ($f) { $folderSet.Add([string]$f) } }
    $vhdFolders = @($folderSet | Sort-Object -Unique)

    # Build complete cluster-wide ownership and file inventories ONCE. An AVHDX can feed the legacy
    # per-VM orphan evidence only when every cluster node and every CSV root was read successfully,
    # no VM/snapshot/chain owns it, and it is inside one of this VM's associated disk folders.
    Show-AuditProgress -Step 35 -Status 'Classifying cluster virtual disk ownership'
    Write-Section "Orphaned .avhdx Files (cluster ownership verified):"
    if ($null -eq $script:VirtualDiskOwnershipInventory) {
        $ownershipStart = Get-TelemetryNow
        $ownershipNodes = if (@($clusterNodes).Count -gt 0) { @($clusterNodes) } else { @($LocalNode) }
        $script:VirtualDiskOwnershipInventory = Get-ClusterVirtualDiskOwnershipInventory `
            -Nodes $ownershipNodes -LocalNode $LocalNode -SessionByNode $script:SessionByNode
        Add-TelemetryEntry -Step '1.10.35.10' -Phase 'Cluster virtual disk ownership inventory' `
            -Detail ("Nodes={0}; FailedNodes={1}; VMs={2}; Snapshots={3}; Paths={4}; Folders={5}; Errors={6}; Complete={7}" -f `
                $ownershipNodes.Count,
                @($script:VirtualDiskOwnershipInventory.Nodes | Where-Object { -not $_.Complete }).Count,
                $script:VirtualDiskOwnershipInventory.VMCount, $script:VirtualDiskOwnershipInventory.SnapshotCount,
                @($script:VirtualDiskOwnershipInventory.Rows).Count,
                @($script:VirtualDiskOwnershipInventory.Folders).Count, @($script:VirtualDiskOwnershipInventory.Errors).Count,
                $script:VirtualDiskOwnershipInventory.Complete) `
            -StartUtc $ownershipStart -EndUtc (Get-TelemetryNow)
    }
    if ($null -eq $script:VirtualDiskFileInventory) {
        $fileInventoryStart = Get-TelemetryNow
        $script:VirtualDiskFileInventory = Get-ClusterVirtualDiskFileInventory `
            -CsvVolumes @($script:ClusterCsvCache) -TargetNode $OwningNode -LocalNode $LocalNode `
            -SessionByNode $script:SessionByNode
        $extensionCounts = @($script:VirtualDiskFileInventory.Files | Group-Object Extension | Sort-Object Name |
            ForEach-Object { "{0}={1}" -f $_.Name.ToLowerInvariant(), $_.Count }) -join ';'
        Add-TelemetryEntry -Step '1.10.35.20' -Phase 'Cluster virtual disk file inventory' `
            -Detail ("Roots={0}; FailedRoots={1}; Files={2}; Extensions={3}; Errors={4}; Complete={5}" -f `
                @($script:VirtualDiskFileInventory.Roots).Count,
                @($script:VirtualDiskFileInventory.Roots | Where-Object { -not $_.Complete }).Count,
                @($script:VirtualDiskFileInventory.Files).Count,
                $extensionCounts, @($script:VirtualDiskFileInventory.Errors).Count,
                $script:VirtualDiskFileInventory.Complete) `
            -StartUtc $fileInventoryStart -EndUtc (Get-TelemetryNow)
    }
    $virtualDiskCoverageComplete = [bool]($script:VirtualDiskOwnershipInventory.Complete -and $script:VirtualDiskFileInventory.Complete)
    $vhdSetManagedFolders = @($script:VirtualDiskOwnershipInventory.Rows | Where-Object {
        $_.Path -and [System.IO.Path]::GetExtension([string]$_.Path).Equals('.vhds', [System.StringComparison]::OrdinalIgnoreCase)
    } | ForEach-Object { [System.IO.Path]::GetDirectoryName([string]$_.Path) } | Where-Object { $_ } | Sort-Object -Unique)
    if (-not $script:VirtualDiskHousekeepingBuilt) {
        $classificationStart = Get-TelemetryNow
        $ownersByPath = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.HashSet[string]]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($ownershipRow in @($script:VirtualDiskOwnershipInventory.Rows)) {
            $ownershipPath = [string]$ownershipRow.Path
            if (-not $ownershipPath) { continue }
            if (-not $ownersByPath.ContainsKey($ownershipPath)) {
                $ownersByPath[$ownershipPath] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            }
            if ($ownershipRow.VMName) { [void]$ownersByPath[$ownershipPath].Add([string]$ownershipRow.VMName) }
        }
        $classificationCounts = @{}
        if (-not $virtualDiskCoverageComplete) {
            $coverageErrors = @($script:VirtualDiskOwnershipInventory.Errors) + @($script:VirtualDiskFileInventory.Errors)
            [void]$script:HousekeepingFindings.Add([pscustomobject]@{
                Category    = 'Ownership coverage incomplete'
                Scope       = 'Cluster virtual disk inventory'
                Observation = ("Ownership or CSV coverage was incomplete; {0} collection error(s) prevent unattached/orphan conclusions." -f $coverageErrors.Count)
                Review      = 'Review the collection errors and rerun from a host that can read every cluster node and CSV root.'
            })
            foreach ($nodeResult in @($script:VirtualDiskOwnershipInventory.Nodes | Where-Object { -not $_.Complete })) {
                $nodeErrors = @()
                if ($nodeResult.Error) { $nodeErrors += [string]$nodeResult.Error }
                if ($nodeResult.Result) { $nodeErrors += @($nodeResult.Result.Errors | ForEach-Object { [string]$_ }) }
                [void]$script:HousekeepingFindings.Add([pscustomobject]@{
                    Category    = 'Ownership node incomplete'
                    Scope       = [string]$nodeResult.Node
                    Observation = if ($nodeErrors.Count -gt 0) { $nodeErrors -join '; ' } else { 'The node ownership query did not complete.' }
                    Review      = 'Restore read-only Hyper-V and remoting access to this node, then rerun the inventory.'
                })
            }
            foreach ($pathError in @($script:VirtualDiskFileInventory.PathErrors)) {
                $category = if ($pathError.IsRoot) { 'CSV root incomplete' } else { 'CSV folder path inaccessible' }
                [void]$script:HousekeepingFindings.Add([pscustomobject]@{
                    Category    = $category
                    Scope       = [string]$pathError.Path
                    Observation = if ($pathError.Error) { [string]$pathError.Error } else { 'The path could not be inventoried.' }
                    Review      = if ($pathError.IsRoot) { 'Restore read-only access to this CSV root, then rerun the inventory.' } else { 'Restore read-only access to this sub-folder, then rerun the inventory.' }
                })
            }
            $classificationCounts['OwnershipAmbiguous'] = @($script:VirtualDiskFileInventory.Files).Count
        } else {
            foreach ($diskFile in @($script:VirtualDiskFileInventory.Files)) {
                $diskOwners = @(if ($ownersByPath.ContainsKey([string]$diskFile.FullName)) { @($ownersByPath[[string]$diskFile.FullName]) } else { @() })
                $classification = Get-VirtualDiskHousekeepingClassification -Path ([string]$diskFile.FullName) `
                    -Owners $diskOwners -VMAssociatedFolders @($script:VirtualDiskOwnershipInventory.Folders) `
                    -CoverageComplete $true -ImageLibraryPathPatterns $script:CheckpointHealthPolicy.Storage.ImageLibraryPathPatterns `
                    -VhdSetManagedFolders $vhdSetManagedFolders
                if (-not $classificationCounts.ContainsKey($classification.Classification)) { $classificationCounts[$classification.Classification] = 0 }
                $classificationCounts[$classification.Classification]++
                if ($classification.Classification -in @('ExcludedImageLibraryAsset', 'VhdSetManagedAsset')) { continue }
                if (@($classification.Owners).Count -gt 1) {
                    $isVhdSet = ([string]$diskFile.Extension).Equals('.vhds', [System.StringComparison]::OrdinalIgnoreCase)
                    [void]$script:HousekeepingFindings.Add([pscustomobject]@{
                        Category    = if ($isVhdSet) { 'Shared VHD Set reference' } else { 'Shared virtual disk reference' }
                        Scope       = @($classification.Owners) -join ', '
                        FileName    = [string]$diskFile.Name
                        FullName    = [string]$diskFile.FullName
                        ParentPath  = [string](Split-Path -Path ([string]$diskFile.FullName) -Parent)
                        Extension   = [string]$diskFile.Extension
                        Length      = [long]$diskFile.Length
                        CsvRoot     = [string]$diskFile.CsvRoot
                        CreationTimeUtc = $diskFile.CreationTimeUtc
                        LastWriteTimeUtc = $diskFile.LastWriteTimeUtc
                        Classification = [string]$classification.Classification
                        Observation = if ($isVhdSet) { "More than one VM references this VHD Set path: $($diskFile.FullName)" } else { "More than one VM or snapshot inventory references this path: $($diskFile.FullName)" }
                        Review      = if ($isVhdSet) { 'VHD Sets are designed for shared guest-cluster storage. Confirm that the listed VMs are the intended guest-cluster nodes. Do not modify the VHDS or its Hyper-V-managed files based only on this report.' } else { 'Confirm that the shared reference is intentional and supported for this workload. Do not modify the file based only on this report.' }
                    })
                }
                if ($classification.Classification -eq 'AttachedVirtualDisk') { continue }
                $category = switch ($classification.Classification) {
                    'PlacementInconsistency'          { 'Placement inconsistency' }
                    'UnattachedDifferencingCandidate' { 'Unattached differencing disk candidate' }
                    'UnattachedVhdSetCandidate'       { 'Unattached VHD Set candidate' }
                    default                           { 'Unattached base disk candidate' }
                }
                $scopeNames = @((@($classification.Owners) + @($classification.AssociatedVMs)) | Where-Object { $_ } | Sort-Object -Unique)
                $scope = if ($scopeNames.Count -gt 0) { $scopeNames -join ', ' } elseif ($diskFile.CsvRoot) { [string]$diskFile.CsvRoot } else { 'Cluster storage' }
                $ownerText = if (@($classification.Owners).Count -gt 0) { @($classification.Owners) -join ', ' } else { 'none' }
                $associatedVmText = if (@($classification.AssociatedVMs).Count -gt 0) { @($classification.AssociatedVMs) -join ', ' } else { 'none' }
                $observation = switch ($classification.Classification) {
                    'PlacementInconsistency'          {
                        if ($classification.PlacementReason -eq 'UnreferencedInVMAssociatedFolder') {
                            "No VM or snapshot inventory references this virtual disk under complete coverage, but its path is inside a folder associated with VM(s): $associatedVmText. Filename text is not used as ownership evidence: $($diskFile.FullName)"
                        } else {
                            "This virtual disk is referenced by VM(s): $ownerText, but its path is inside a folder associated with different VM(s): $associatedVmText. Filename text is not used as ownership evidence: $($diskFile.FullName)"
                        }
                    }
                    'UnattachedDifferencingCandidate' { "No VM or snapshot chain references this AVHDX under complete coverage: $($diskFile.FullName)" }
                    'UnattachedVhdSetCandidate'       { "No VM or snapshot inventory references this VHDS under complete coverage: $($diskFile.FullName)" }
                    default                           { "No VM or snapshot chain references this base disk under complete coverage: $($diskFile.FullName)" }
                }
                $review = switch ($classification.Classification) {
                    'PlacementInconsistency'          {
                        if ($classification.PlacementReason -eq 'UnreferencedInVMAssociatedFolder') {
                            'Confirm whether this unreferenced disk is a required image, retired workload disk, backup/live-mount artifact, or intentionally retained data. Verify its history with the VM and backup owners. Do not attach, move, rename, or delete it based only on this report.'
                        } else {
                            'Confirm whether the authoritative VM reference and the different VM-associated storage folder are intentional. Review the VM configuration and storage layout with the VM, backup, and storage owners. Do not move or rename the file based only on this report.'
                        }
                    }
                    'UnattachedDifferencingCandidate' { 'Confirm whether this unreferenced differencing disk contains required recovery data with the VM and backup owners. Do not merge, move, or delete the file based only on this report.' }
                    'UnattachedVhdSetCandidate'       { 'Confirm whether this unreferenced VHD Set is still required by a guest cluster with the VM, backup, and storage owners. Do not modify the VHDS or its Hyper-V-managed files based only on this report.' }
                    default                           { 'If this virtual disk belongs to an image library, exclude its full path with storage.imageLibraryPathPatterns in a checkpoint-health-policy.yml file supplied via -PolicyPath (see housekeeping guidance). Otherwise, confirm intended ownership and storage layout with the VM, backup, and storage owners. Do not modify the file based only on this report.' }
                }
                [void]$script:HousekeepingFindings.Add([pscustomobject]@{
                    Category    = $category
                    Scope       = $scope
                    FileName    = [string]$diskFile.Name
                    FullName    = [string]$diskFile.FullName
                    ParentPath  = [string](Split-Path -Path ([string]$diskFile.FullName) -Parent)
                    Extension   = [string]$diskFile.Extension
                    Length      = [long]$diskFile.Length
                    CsvRoot     = [string]$diskFile.CsvRoot
                    CreationTimeUtc = $diskFile.CreationTimeUtc
                    LastWriteTimeUtc = $diskFile.LastWriteTimeUtc
                    Classification = [string]$classification.Classification
                    PlacementReason = [string]$classification.PlacementReason
                    Owners       = @($classification.Owners)
                    AssociatedVMs = @($classification.AssociatedVMs)
                    Observation = $observation
                    Review      = $review
                })
            }
        }
        $classificationDetail = @($classificationCounts.GetEnumerator() | Sort-Object Name |
            ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join ';'
        Add-TelemetryEntry -Step '1.10.35.30' -Phase 'Virtual disk housekeeping classification' `
            -Detail ("Files={0}; Findings={1}; Classes={2}; Complete={3}" -f `
                @($script:VirtualDiskFileInventory.Files).Count, $script:HousekeepingFindings.Count,
                $classificationDetail, $virtualDiskCoverageComplete) `
            -StartUtc $classificationStart -EndUtc (Get-TelemetryNow)
        $script:VirtualDiskHousekeepingBuilt = $true
    }

    $vmOrphanClassificationStart = Get-TelemetryNow
    if ($vhdFolders -and $virtualDiskCoverageComplete) {
        $currentVmVhdSetManagedFolders = @($script:VirtualDiskOwnershipInventory.Rows | Where-Object {
            $_.VMName -eq $VMName -and $_.Path -and
            [System.IO.Path]::GetExtension([string]$_.Path).Equals('.vhds', [System.StringComparison]::OrdinalIgnoreCase)
        } | ForEach-Object { [System.IO.Path]::GetDirectoryName([string]$_.Path) } | Where-Object { $_ } | Sort-Object -Unique)
        $orphans = @(Get-VMOrphanCandidatesFromClusterInventory `
            -Inventory @($script:VirtualDiskFileInventory.Files) `
            -Ownership @($script:VirtualDiskOwnershipInventory.Rows) `
            -CurrentVMName $VMName -VhdFolders $vhdFolders -CoverageComplete $true `
            -VhdSetManagedFolders $currentVmVhdSetManagedFolders)
        $hasOrphans = ($orphans.Count -gt 0)
        if ($orphans.Count -gt 0) {
            Write-Alert ("  {0} unattached .avhdx candidate(s) found (not referenced by any VM/snapshot chain):" -f $orphans.Count) -Level Warning
            $orphans | Sort-Object LastWriteTimeUtc -Descending | Select-Object `
                @{N='File Name';E={ $_.Name }},
                @{N='SizeGB';E={ [math]::Round($_.Length / 1GB, 2) }},
                @{N='Created (UTC)';E={ if ($_.CreationTimeUtc)  { $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ') }  else { '(unavailable)' } }},
                @{N='LastWrite (UTC)';E={ if ($_.LastWriteTimeUtc) { $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ') } else { '(unavailable)' } }},
                FullName | Format-Table -AutoSize -Wrap | Out-Indented
            Write-AuditReportLine  "  Complete cluster ownership coverage found no VM or snapshot chain referencing these files."
            Write-AuditReportLine  "  A stuck / failed merge, a failed backup checkpoint, an interrupted instant-recovery /"
            Write-AuditReportLine  "  live-mount, or a leftover initial Hyper-V Replica checkpoint can leave these behind."
            Write-AuditReportLine  "  Do NOT delete blindly. Match each file to the VM, backup, restore, mount, or replica activity"
            Write-AuditReportLine  "  at its timestamps. Before changing it, use vendor or Microsoft Support guidance or a procedure"
            Write-AuditReportLine  "  based on your own investigation into that specific orphaned checkpoint file."
        } else {
            Write-AuditReportLine "  None found - no globally unattached .avhdx candidate exists in this VM's associated folders."
            Write-AuditReportLine ""
        }
    } elseif (-not $virtualDiskCoverageComplete) {
        Write-Alert "  Ownership coverage is incomplete; no .avhdx file is classified as orphaned or unattached." -Level Warning
        Write-AuditReportLine "  Review the cluster/storage housekeeping section for collection coverage details."
        Write-AuditReportLine ""
    } else {
        Write-AuditReportLine "  No VHD folders were resolved for this VM; no per-VM orphan conclusion was made."
        Write-AuditReportLine ""
    }
    Add-TelemetryEntry -Step '1.10.35.40' -Phase 'Per-VM orphan candidate classification' `
        -Detail ("VM={0}; Source={1}; Folders={2}; InventoryFiles={3}; Candidates={4}; Complete={5}" -f `
            $VMName, $script:CurrentVMSource, @($vhdFolders).Count, @($script:VirtualDiskFileInventory.Files).Count,
            @($orphans).Count, $virtualDiskCoverageComplete) `
        -StartUtc $vmOrphanClassificationStart -EndUtc (Get-TelemetryNow)

    # Replication health: on the PRIMARY, ongoing replication is tracked in .hrl logs (see below),
    # while the REPLICA stores recovery points as .avhdx checkpoints. A stalled initial replication
    # or a backlogged log can keep these artifacts around and inflate disk usage.
    Show-AuditProgress -Step 40 -Status 'Checking Hyper-V Replica status'
    Write-Section "Hyper-V Replica (HVR) Status:"
    $replicationCollectionStart = Get-TelemetryNow
    $replicationServerAttempts = 0
    if ($vm.ReplicationState -ne 'Disabled') {
        $replicationServerCacheKey = $OwningNode.ToLowerInvariant()
        if (-not $script:ReplicationServerSettingsByNode.ContainsKey($replicationServerCacheKey)) {
            try {
                $script:ReplicationServerSettingsByNode[$replicationServerCacheKey] = Invoke-WithRetry `
                    -AttemptCount ([ref]$replicationServerAttempts) `
                    -DiagnosticOperation 'Collect Hyper-V Replica monitoring settings' `
                    -DiagnosticScope ("VM={0}; Owner={1}" -f $VMName, $OwningNode) `
                    -ScriptBlock {
                    Invoke-OnOwner -ScriptBlock {
                    $serverSettings = Get-VMReplicationServer -ErrorAction Stop
                    $monitoringIntervalProperty = $serverSettings.PSObject.Properties['MonitoringInterval']
                    $monitoringStartProperty = $serverSettings.PSObject.Properties['MonitoringStartTime']
                    [pscustomobject]@{
                        Available = $true
                        MonitoringIntervalSeconds = if ($monitoringIntervalProperty -and $monitoringIntervalProperty.Value) { [double]$monitoringIntervalProperty.Value.TotalSeconds } else { 0 }
                        MonitoringStartTime = if ($monitoringStartProperty -and $monitoringStartProperty.Value) { [string]$monitoringStartProperty.Value } else { '' }
                        Error = ''
                    }
                    }
                }
            } catch {
                $script:ReplicationServerSettingsByNode[$replicationServerCacheKey] = [pscustomobject]@{
                    Available = $false
                    MonitoringIntervalSeconds = 0
                    MonitoringStartTime = ''
                    Error = $_.Exception.Message
                }
                Write-Alert "  Hyper-V Replica monitoring settings were unavailable after retries: $($_.Exception.Message)" -Level Warning
            }
        }
        $replicationServerSettings = $script:ReplicationServerSettingsByNode[$replicationServerCacheKey]
        $replInfo = Invoke-OnOwner -ScriptBlock {
            param($n)
            $r = Get-VMReplication -VMName $n -ErrorAction SilentlyContinue
            $m = Measure-VMReplication -VMName $n -ErrorAction SilentlyContinue
            $successfulCountProperty = if ($m) { $m.PSObject.Properties['SuccessfulReplicationCount'] } else { $null }
            if (-not $successfulCountProperty -and $m) { $successfulCountProperty = $m.PSObject.Properties['ReplicationSuccessCount'] }
            [pscustomobject]@{
                Repl = if ($r) { [pscustomobject]@{
                    Name                        = [string]$r.Name
                    State                       = [string]$r.State
                    Health                      = [string]$r.Health
                    Mode                        = [string]$r.Mode
                    ReplicationRelationshipType = [string]$r.ReplicationRelationshipType
                    PrimaryServerName           = [string]$r.PrimaryServerName
                    ReplicaServerName           = [string]$r.ReplicaServerName
                    LastReplicationTime         = if ($r.LastReplicationTime) { ([datetime]$r.LastReplicationTime).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ') } else { '' }
                    FrequencySec                = [string]$r.FrequencySec
                    ReplicationHealthDetails    = [string]($r.ReplicationHealthDetails -join '; ')
                } } else { $null }
                Measure = if ($m) { [pscustomobject]@{
                    ReplicationHealth         = [string]$m.ReplicationHealth
                    LastReplicationTime       = if ($m.LastReplicationTime) { ([datetime]$m.LastReplicationTime).ToUniversalTime() } else { [datetime]::MinValue }
                    AverageReplicationSize    = [long]$m.AverageReplicationSize
                    MaximumReplicationSize    = [long]$m.MaximumReplicationSize
                    PendingReplicationSize    = [long]$m.PendingReplicationSize
                    AverageReplicationLatency = if ($m.AverageReplicationLatency -is [timespan]) { [double]$m.AverageReplicationLatency.TotalSeconds } else { [double]$m.AverageReplicationLatency }
                    SuccessfulReplicationCount = if ($successfulCountProperty) { [long]$successfulCountProperty.Value } else { -1 }
                    SuccessfulCountAvailable = [bool]$successfulCountProperty
                    MissedReplicationCount    = [long]$m.MissedReplicationCount
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
                    AverageReplicationLatency, SuccessfulReplicationCount, MissedReplicationCount | Out-Indented
                Write-AuditReportLine ("  Replica monitoring interval: {0}" -f $(if ($replicationServerSettings.Available -and $replicationServerSettings.MonitoringIntervalSeconds -gt 0) { [timespan]::FromSeconds($replicationServerSettings.MonitoringIntervalSeconds) } else { 'Unavailable' }))
                Write-AuditReportLine ""
            } else {
                Write-AuditReportLine "  No replication statistics available."
                Write-AuditReportLine ""
            }
        } else {
            Write-AuditReportLine "HVR Replication reported as '$($vm.ReplicationState)' but no replication object was returned."
            Write-AuditReportLine ""
        }
    } else {
        Write-AuditReportLine "HVR Replication is not enabled for '$VMName'."
        Write-AuditReportLine ""
    }
    Add-TelemetryEntry -Step '1.10.40.05' -Phase 'Replica relationship and monitoring collection' `
        -Detail ("VM={0}; Enabled={1}; Relationship={2}; Measurements={3}; ServerSettings={4}; ServerAttempts={5}; ServerError={6}" -f `
            $VMName, ($vm.ReplicationState -ne 'Disabled'), [bool]($replInfo -and $replInfo.Repl),
            [bool]($replInfo -and $replInfo.Measure), [bool]($replicationServerSettings -and $replicationServerSettings.Available),
            $replicationServerAttempts, $(if ($replicationServerSettings -and $replicationServerSettings.Error) { $replicationServerSettings.Error } else { '' })) `
        -StartUtc $replicationCollectionStart -EndUtc (Get-TelemetryNow)
    $replicationAssessmentStart = Get-TelemetryNow
    $replicationEnabled = ($vm.ReplicationState -ne 'Disabled')
    $replAssessment = Get-HyperVReplicationAssessment -Enabled $replicationEnabled `
        -State $(if ($replInfo -and $replInfo.Repl) { [string]$replInfo.Repl.State } else { [string]$vm.ReplicationState }) `
        -Health $(if ($replInfo -and $replInfo.Repl) { [string]$replInfo.Repl.Health } else { '' }) `
        -Mode $(if ($replInfo -and $replInfo.Repl) { [string]$replInfo.Repl.Mode } else { '' }) `
        -MeasurementsAvailable ([bool]($replInfo -and $replInfo.Measure)) `
        -LastReplicationTimeUtc $(if ($replInfo -and $replInfo.Measure) { [datetime]$replInfo.Measure.LastReplicationTime } else { [datetime]::MinValue }) `
        -PendingBytes $(if ($replInfo -and $replInfo.Measure) { [long]$replInfo.Measure.PendingReplicationSize } else { 0 }) `
        -LatencySeconds $(if ($replInfo -and $replInfo.Measure) { [double]$replInfo.Measure.AverageReplicationLatency } else { 0 }) `
        -MissedCount $(if ($replInfo -and $replInfo.Measure) { [long]$replInfo.Measure.MissedReplicationCount } else { 0 }) `
        -FrequencySeconds $(if ($replInfo -and $replInfo.Repl -and $replInfo.Repl.FrequencySec) { [double]$replInfo.Repl.FrequencySec } else { 0 }) `
        -AverageReplicationBytes $(if ($replInfo -and $replInfo.Measure) { [long]$replInfo.Measure.AverageReplicationSize } else { 0 }) `
        -SuccessfulCount $(if ($replInfo -and $replInfo.Measure -and $replInfo.Measure.SuccessfulCountAvailable) { [long]$replInfo.Measure.SuccessfulReplicationCount } else { -1 }) `
        -MonitoringIntervalSeconds $(if ($replicationServerSettings -and $replicationServerSettings.Available) { [double]$replicationServerSettings.MonitoringIntervalSeconds } else { 0 }) `
        -MaxAgeMinutes $MaxReplicationAgeMinutes -MaxPendingMB $MaxPendingReplicationMB `
        -MaxLatencySeconds $MaxReplicationLatencySeconds -MaxMissedCount $MaxMissedReplicationCount `
        -MaxAgeCycles $MaxReplicationAgeCycles -MaxPendingCycles $MaxPendingReplicationCycles `
        -MaxLatencyCycles $MaxReplicationLatencyCycles -MaxMissedRatePercent $MaxMissedReplicationRatePercent `
        -MinMissedCountForConcern $MinMissedReplicationCountForConcern
    Add-TelemetryEntry -Step '1.10.40.10' -Phase 'Typed replication assessment' `
        -Detail ("VM={0}; Enabled={1}; State={2}; Health={3}; ProductSeverity={4}; MeasurementStatus={5}; Concern={6}; Measurements={7}; Breaches={8}; Advisories={9}" -f `
            $VMName, $replicationEnabled, $replAssessment.State, $replAssessment.Health,
            $replAssessment.ProductSeverity, $replAssessment.MeasurementStatus, $replAssessment.IsConcern,
            $replAssessment.MeasurementsAvailable, @($replAssessment.ConcernBreaches).Count,
            @($replAssessment.AdvisoryBreaches).Count) `
        -StartUtc $replicationAssessmentStart -EndUtc (Get-TelemetryNow)
    if ($replicationEnabled) {
        Write-Section "Hyper-V Replica Effective Limit Assessment:"
        Get-ReplicaAssessmentRows -Assessment $replAssessment `
            -PrimaryServer $(if ($replInfo -and $replInfo.Repl) { [string]$replInfo.Repl.PrimaryServerName } else { '' }) `
            -ReplicaServer $(if ($replInfo -and $replInfo.Repl) { [string]$replInfo.Repl.ReplicaServerName } else { '' }) |
            Format-Table Signal, Observed, @{N='Effective guardrail / context';E={ $_.Guardrail }}, Assessment -AutoSize -Wrap | Out-Indented
        Write-AuditReportLine ("  {0} Product health/state remains authoritative; measurement advisories do not change the VM verdict by themselves." -f $replAssessment.Reason)
        Write-AuditReportLine ""
    }

    # Hyper-V Replica change logs (.hrl): on the PRIMARY, Replica tracks writes in per-VHD .hrl logs
    # (NOT .avhdx). A large or stale .hrl usually means replication is backlogged or stuck.
    Show-AuditProgress -Step 45 -Status 'Scanning Replica change logs (.hrl)'
    Write-Section "Hyper-V Replica Change Logs (.hrl):"
    $hrlStart = Get-TelemetryNow
    $hrlFiles = @()
    $hrlAssessment = $null
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
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Scan Hyper-V Replica change logs' -Scope ("VM={0}; Owner={1}" -f $VMName, $OwningNode)
            $hrlFiles = @()
            Write-Alert "  Could not scan for .hrl logs on '$OwningNode': $($_.Exception.Message)" -Level Warning
        }
        $replicationFrequencySeconds = if ($replInfo -and $replInfo.Repl -and $replInfo.Repl.FrequencySec) { [double]$replInfo.Repl.FrequencySec } else { 0 }
        $hrlAssessment = Get-HrlCadenceAssessment -Files $hrlFiles -ReplicationEnabled $replicationEnabled `
            -FrequencySeconds $replicationFrequencySeconds -ReplicationConcern ([bool]($replAssessment.IsConcern -or $replAssessment.HasAdvisory)) `
            -Policy $script:CheckpointHealthPolicy.Replication.Hrl
        if ($hrlAssessment.Rows.Count -gt 0) {
            $hrlAssessment.Rows | Sort-Object Name | Select-Object `
                Name,
                @{N='SizeMB';E={ [math]::Round($_.Length / 1MB, 2) }},
                @{N='LastWrite (UTC)';E={ $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ') }},
                @{N='Age (mins)';E={ [math]::Round($_.AgeMinutes, 1) }},
                @{N='Exceeds cadence';E={ if ($_.ExceedsCadence) { 'YES' } else { 'NO' } }},
                FullName | Format-Table -AutoSize -Wrap | Out-Indented
            Write-AuditReportLine ("  Cadence threshold: {0:N1} minutes (frequency {1:N1} min x {2}, minimum {3:N1} min)." -f `
                $hrlAssessment.ThresholdMinutes, $hrlAssessment.CadenceMinutes,
                $script:CheckpointHealthPolicy.Replication.Hrl.CadenceMultiplier,
                $script:CheckpointHealthPolicy.Replication.Hrl.MinimumStaleMinutes)
            if ($hrlAssessment.IsConcern) {
                Write-Alert "  HRL age exceeds cadence and Replica health or measurements independently indicate a concern." -Level Warning
            }
        } else {
            Write-AuditReportLine "  No .hrl replication logs found (expected on a PRIMARY with replication enabled)."
            Write-AuditReportLine ""
        }
    } else {
        Write-AuditReportLine "  No VHD folders resolved to scan."
        Write-AuditReportLine ""
    }
    Add-TelemetryEntry -Step '1.10.45.10' -Phase 'HRL collection and cadence assessment' `
        -Detail ("VM={0}; Source={1}; Files={2}; Assessed={3}; Concern={4}" -f $VMName, $script:CurrentVMSource, @($hrlFiles).Count, [bool]$hrlAssessment, [bool]($hrlAssessment -and $hrlAssessment.IsConcern)) `
        -StartUtc $hrlStart -EndUtc (Get-TelemetryNow)

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
    $workerEvents        = @()
    $vmAttributedEvents  = @()
    $vmId                = [string]$vm.VMId
    $eventCollectionStatus = [pscustomobject]@{
        Status = 'Skipped'; Error = ''; SourceNode = $OwningNode; AttemptedUtc = $null; AttemptCount = 0; ChannelStatus = @()
    }
    if (-not $SkipWorkerEvents) {
        Show-AuditProgress -Step 50 -Status 'Scanning Hyper-V Worker/VMMS event logs'
        Write-Section "Hyper-V Worker/VMMS Admin Events (last $EventLookbackHours h on $OwningNode):"
        # Match on the VM GUID as well as the name - Worker/VMMS messages reference the
        # 'Virtual machine ID <GUID>', which is far more reliable than the long friendly name.
        # v0.2.14: per-NODE event cache. The Worker/VMMS scan is NODE-WIDE, so on a fleet run every VM
        # on the same owning node would otherwise re-read the SAME (often huge) event set. Scan each
        # node ONCE (keyed by node + lookback), cache the concern/context rows, then derive THIS VM's
        # per-VM view (VmAttributed) locally from the cached set - a big speed-up and consistent
        # node-wide counts across VMs that share a node.
        $nodeCacheKey = "{0}|{1}" -f $OwningNode, $EventLookbackHours
        if (-not $script:NodeEventCache.ContainsKey($nodeCacheKey)) {
            # v0.2.15: time the node-wide Worker/VMMS event scan (typically the dominant per-node cost).
            $nodeScanStart = Get-TelemetryNow
            $nodeScanAttempts = 0
            try {
                $nodeSnapshot = Invoke-WithRetry -AttemptCount ([ref]$nodeScanAttempts) `
                    -DiagnosticOperation 'Scan node-wide Worker/VMMS event logs' `
                    -DiagnosticScope ("Node={0}; LookbackHours={1}" -f $OwningNode, $EventLookbackHours) -ScriptBlock {
                    Invoke-OnOwner -ScriptBlock {
                    param($lookbackHours, $concernIds, $contextIds, $codePatterns)
                    $start  = (Get-Date).AddHours(-$lookbackHours)
                    $codeRx = ($codePatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
                    $rows = [System.Collections.Generic.List[object]]::new()
                    $channels = [System.Collections.Generic.List[object]]::new()
                    foreach ($log in @(
                        [pscustomobject]@{ Name = 'Microsoft-Windows-Hyper-V-Worker-Admin'; Channel = 'Worker' }
                        [pscustomobject]@{ Name = 'Microsoft-Windows-Hyper-V-VMMS-Admin'; Channel = 'VMMS' }
                    )) {
                        try {
                            $events = @(Get-WinEvent -FilterHashtable @{ LogName = $log.Name; StartTime = $start } -ErrorAction Stop)
                            foreach ($eventRecord in $events) {
                                if (-not (($codeRx -and $eventRecord.Message -match $codeRx) -or ($concernIds -contains $eventRecord.Id) -or ($contextIds -contains $eventRecord.Id))) { continue }
                                $isConcern = (($codeRx -and $eventRecord.Message -match $codeRx) -or ($concernIds -contains $eventRecord.Id))
                                [void]$rows.Add([pscustomobject]@{
                                    'Time (UTC)' = $eventRecord.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
                                    RecordId     = [long]$eventRecord.RecordId
                                    Id           = [int]$eventRecord.Id
                                    Level        = [string]$eventRecord.LevelDisplayName
                                    Log          = $log.Channel
                                    Concern      = if ($isConcern) { 'YES' } else { '' }
                                    Message      = ($eventRecord.Message -split "`r?`n")[0]
                                    FullMessage  = ($eventRecord.Message -replace "`r?`n", ' | ')
                                })
                            }
                            [void]$channels.Add([pscustomobject]@{ Channel = $log.Channel; Status = 'Success'; Error = '' })
                        } catch {
                            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
                                [void]$channels.Add([pscustomobject]@{ Channel = $log.Channel; Status = 'Success'; Error = '' })
                            } else {
                                throw ("{0} query failed: {1}" -f $log.Channel, $_.Exception.Message)
                            }
                        }
                    }
                    [pscustomobject]@{ Rows = $rows.ToArray(); ChannelStatus = $channels.ToArray() }
                    } -ArgumentList $EventLookbackHours, $WorkerEventIds, $ContextEventIds, $ErrorCodePatterns
                }
                $script:NodeEventCache[$nodeCacheKey] = [pscustomobject]@{
                    Node          = [string]$OwningNode
                    Status        = 'Success'
                    Rows          = @($nodeSnapshot.Rows)
                    ChannelStatus = @($nodeSnapshot.ChannelStatus)
                    Error         = ''
                    AttemptedUtc  = [DateTime]::UtcNow
                    AttemptCount  = $nodeScanAttempts
                }
                # v0.2.14: write the NODE-WIDE event set ONCE per node to a shared _NodeEvents CSV, so
                # the (often huge, e.g. thousands of 15268) node context is stored a single time rather
                # than duplicated into every per-VM CSV on that node. Per-VM CSVs then carry only the
                # events attributable to that VM (below). This can more than halve a busy run's CSV size.
                if ($OutputPath -and @($nodeSnapshot.Rows).Count -gt 0) {
                    try {
                        $nodeCsvName = "_NodeEvents_{0}_{1}.csv" -f ($OwningNode -replace '[^\w.\-]', '_'), [DateTime]::UtcNow.ToString('yyyy-MM-dd')
                        $nodeCsvPath = Join-Path $OutputPath $nodeCsvName
                        if (-not (Test-Path -LiteralPath $nodeCsvPath)) {
                            @($nodeSnapshot.Rows) | Select-Object 'Time (UTC)', Id, Level, Log, Concern, FullMessage |
                                Export-Csv -LiteralPath $nodeCsvPath -NoTypeInformation -Encoding UTF8
                        }
                        $script:NodeCsvNameByNode[$OwningNode] = $nodeCsvName
                    } catch {
                        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Write node-wide events CSV' -Scope ("Node={0}; File={1}" -f $OwningNode, $nodeCsvPath)
                        Write-Alert "  Could not write the node-wide events CSV for '$OwningNode': $($_.Exception.Message)" -Level Warning
                    }
                }
            } catch {
                $script:NodeEventCache[$nodeCacheKey] = [pscustomobject]@{
                    Node          = [string]$OwningNode
                    Status        = 'Unavailable'
                    Rows          = @()
                    ChannelStatus = @(
                        [pscustomobject]@{ Channel = 'Worker'; Status = 'Unavailable'; Error = $_.Exception.Message }
                        [pscustomobject]@{ Channel = 'VMMS'; Status = 'Unavailable'; Error = $_.Exception.Message }
                    )
                    Error         = $_.Exception.Message
                    AttemptedUtc  = [DateTime]::UtcNow
                    AttemptCount  = $nodeScanAttempts
                }
                Write-Alert "  Could not read event logs on '$OwningNode': $($_.Exception.Message)" -Level Warning
            }
            $telemetrySnapshot = $script:NodeEventCache[$nodeCacheKey]
            Add-TelemetryEntry -Step '1.10.50.10' -Phase 'Node event-log scan (once per node)' `
                -Detail ("Node={0}; Status={1}; Rows={2}; Attempts={3}; ChannelErrors={4}" -f $OwningNode,
                    $telemetrySnapshot.Status, @($telemetrySnapshot.Rows).Count, $telemetrySnapshot.AttemptCount,
                    @($telemetrySnapshot.ChannelStatus | Where-Object { $_.Status -ne 'Success' }).Count) `
                -StartUtc $nodeScanStart -EndUtc (Get-TelemetryNow)
        }
        $cachedNodeSnapshot = $script:NodeEventCache[$nodeCacheKey]
        $eventCollectionStatus = [pscustomobject]@{
            Status        = [string]$cachedNodeSnapshot.Status
            Error         = [string]$cachedNodeSnapshot.Error
            SourceNode    = $OwningNode
            AttemptedUtc  = $cachedNodeSnapshot.AttemptedUtc
            AttemptCount  = [int]$cachedNodeSnapshot.AttemptCount
            ChannelStatus = @($cachedNodeSnapshot.ChannelStatus)
        }
        $cachedNodeEvents = $null
        if ($cachedNodeSnapshot.Status -eq 'Success') {
            [object[]]$cachedNodeEvents = @($cachedNodeSnapshot.Rows)
        }
        $eventAttributionStart = Get-TelemetryNow
        # Derive THIS VM's view from the cached node set. Structured GUID/name evidence is exact;
        # bounded friendly-name fallback is retained with explicit low confidence.
        $workerEvents = $null
        if ($null -ne $cachedNodeEvents) {
            [object[]]$workerEvents = @($cachedNodeEvents | ForEach-Object {
                $attribution = Resolve-HyperVEventAttribution -Message ([string]$_.FullMessage) -VMName $VMName -VMId $vmId
                $signalAssessment = Get-HyperVEventSignalAssessment -EventId ([int]$_.Id) -Log ([string]$_.Log) `
                    -Message ([string]$_.FullMessage) -Policy $script:EventPolicy
                [pscustomobject]@{
                    'Time (UTC)' = $_.'Time (UTC)'
                    RecordId     = $_.RecordId
                    Id           = $_.Id
                    Level        = $_.Level
                    Log          = $_.Log
                    Concern      = $_.Concern
                    VmAttributed = [bool]$attribution.Attributed
                    AttributionMethod = [string]$attribution.Method
                    AttributionConfidence = [string]$attribution.Confidence
                    SignalRole   = [string]$signalAssessment.Role
                    IsConfirmingFork = [bool]$signalAssessment.IsConfirmingFork
                    Message      = $_.Message
                    FullMessage  = $_.FullMessage
                }
            })
        } else {
            $workerEvents = $null
        }
        Add-TelemetryEntry -Step '1.10.50.20' -Phase 'Per-VM event attribution' `
            -Detail ("VM={0}; Rows={1}; Attributed={2}; HighConfidence={3}; LowConfidence={4}; Confirming={5}; Leading={6}" -f `
                $VMName, @($workerEvents).Count, @($workerEvents | Where-Object { $_.VmAttributed }).Count,
                @($workerEvents | Where-Object { $_.VmAttributed -and $_.AttributionConfidence -eq 'High' }).Count,
                @($workerEvents | Where-Object { $_.VmAttributed -and $_.AttributionConfidence -eq 'Low' }).Count,
                @($workerEvents | Where-Object { $_.VmAttributed -and $_.IsConfirmingFork }).Count,
                @($workerEvents | Where-Object { $_.VmAttributed -and $_.SignalRole -eq 'Leading' }).Count) `
            -StartUtc $eventAttributionStart -EndUtc (Get-TelemetryNow)

        if ($workerEvents -and $workerEvents.Count -gt 0) {
            $workerEvents      = @($workerEvents | Sort-Object 'Time (UTC)', Log, RecordId, Id, FullMessage)
            foreach ($eventRow in $workerEvents) {
                $eventDisposition = Get-HyperVEventCsvDisposition -Event $eventRow -Events $workerEvents -Policy $script:EventPolicy
                Add-Member -InputObject $eventRow -NotePropertyName EventClassification -NotePropertyValue $eventDisposition.EventClassification -Force
                Add-Member -InputObject $eventRow -NotePropertyName VerdictDriver -NotePropertyValue ([bool]$eventDisposition.VerdictDriver) -Force
                Add-Member -InputObject $eventRow -NotePropertyName RecoveryDisposition -NotePropertyValue $eventDisposition.RecoveryDisposition -Force
                Add-Member -InputObject $eventRow -NotePropertyName DispositionReason -NotePropertyValue $eventDisposition.DispositionReason -Force
            }
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

            # Keep the per-VM TXT focused on evidence attributable to this VM. Node-wide context is
            # summarized below and retained in its shared CSV rather than copied into every VM table.
            $txtVmEvents = @($workerEvents | Where-Object { $_.VmAttributed })
            $perIdCap     = 5
            $displayRows  = [System.Collections.Generic.List[object]]::new()
            $removedNotes = [System.Collections.Generic.List[string]]::new()
            $txtVmEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object {
                $grp = @($_.Group | Sort-Object 'Time (UTC)', Log, RecordId, Id, FullMessage)
                foreach ($e in ($grp | Select-Object -First $perIdCap)) { $displayRows.Add($e) }
                if ($grp.Count -gt $perIdCap) {
                    $removedNotes.Add(("  Removed {0} duplicate Event ID {1} entries (showing first {2}) - Review CSV file for full details." -f ($grp.Count - $perIdCap), $_.Name, $perIdCap))
                }
            }
            if ($txtVmEvents.Count -gt 0) {
                # Console table shows the first message line only (readability); full text is in the CSV.
                @($displayRows | Sort-Object 'Time (UTC)', Log, RecordId, Id, FullMessage) | Format-Table 'Time (UTC)', Id, Level, Log, Concern, Message -AutoSize -Wrap | Out-Indented
            } else {
                Write-AuditReportLine "  No matching events were attributable to this VM."
            }
            foreach ($note in $removedNotes) { Write-AuditReportLine $note }
            if ($removedNotes.Count -gt 0) { Write-AuditReportLine "" }
            Write-AuditReportLine ("  {0} event(s) attributable to this VM ({1} shown after collapsing duplicates); {2} collected as concern." -f $txtVmEvents.Count, $displayRows.Count, $vmEventConcernCount)
            Write-AuditReportLine "  Node-wide event context is summarized below and exported separately; it is not listed in this VM table."
            Write-AuditReportLine ("  Node-wide context: {0} other event(s), including {1} collected as concern for other VMs or no VM." -f ($workerEvents.Count - $txtVmEvents.Count), ($eventConcernCount - $vmEventConcernCount))
            Write-AuditReportLine  "  Informational lifecycle events (VM started, checkpoint completed, merge started / finished OK)"
            Write-AuditReportLine  "  attributable to this VM are listed for context but are not verdict drivers by themselves."
        } else {
            Write-AuditReportLine "  No matching events in the last $EventLookbackHours hours."
            Write-AuditReportLine ""
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
                ConvertTo-HyperVEventCsvRows -Events $vmAttributedEvents -Policy $script:EventPolicy `
                    -VMName $VMName -VMId $vmId -DefaultNode $OwningNode |
                    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
                Write-AuditReportLine ""
                Write-AuditReportLine "  This VM's full, untruncated event messages exported to CSV: $csvPath"
                if ($nodeCsvForVm) { Write-AuditReportLine "  Node-wide events (context, all VMs on $OwningNode) are in: $nodeCsvForVm" }
                Write-AuditReportLine "  (Use these CSVs rather than the truncated console table above - they have the complete text.)"
            } else {
                # No events attributable to THIS VM: still write the per-VM CSV (same columns) with one
                # informational marker row, so the presence of the file confirms the scan ran.
                $noneMsg = if ($nodeCsvForVm) { "No Hyper-V Worker/VMMS events attributable to this VM in the last $EventLookbackHours hours (scan ran). Node-wide events (all VMs on $OwningNode) are in $nodeCsvForVm." } else { "No matching Hyper-V Worker/VMMS events in the last $EventLookbackHours hours (scan ran; nothing to report)." }
                $eventsCsvName = Write-VMEventsMarkerCsv -Message $noneMsg
                Write-AuditReportLine "  (No events attributable to this VM - wrote a marker row: $csvPath$(if ($nodeCsvForVm) { "; node-wide events in $nodeCsvForVm" }))"
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
        if ($null -eq $script:AnalyticStatusCache) {
            $analyticStart = Get-TelemetryNow
            $nodes = if (@($script:ClusterNodesCache).Count -gt 0) { @($script:ClusterNodesCache) } else { @($OwningNode) }
            $script:AnalyticStatusCache = @(Invoke-Command -ComputerName $nodes -ScriptBlock {
                $log = $using:analyticLog
                try   { $enabled = [bool](Get-WinEvent -ListLog $log -ErrorAction Stop).IsEnabled }
                catch { $enabled = 'Unknown (log not found)' }
                [pscustomobject]@{ Node = $env:COMPUTERNAME; Channel = $log; Enabled = $enabled }
            } -ErrorAction SilentlyContinue)
            Add-TelemetryEntry -Step '1.10.55.10' -Phase 'Analytic channel status (once per run)' `
                -Detail ("Nodes={0}; Results={1}; NeedEnable={2}" -f $nodes.Count, $script:AnalyticStatusCache.Count,
                    @($script:AnalyticStatusCache | Where-Object { -not (($_.Enabled -is [bool]) -and $_.Enabled) }).Count) `
                -StartUtc $analyticStart -EndUtc (Get-TelemetryNow)
        }
        $analyticStatus = @($script:AnalyticStatusCache)
        if ($analyticStatus) {
            $analyticStatus | Sort-Object Node | Format-Table Node, Channel, Enabled -AutoSize | Out-Indented
            # Only a real boolean $true means the channel is capturing; $false OR 'Unknown (log not
            # found)' both mean it is NOT, so flag those nodes here and remember them for the RESULT tip.
            $analyticNodesNeedEnable = @($analyticStatus | Where-Object { -not (($_.Enabled -is [bool]) -and $_.Enabled) } | ForEach-Object { [string]$_.Node })
            if ($analyticNodesNeedEnable.Count -gt 0) {
                Write-AuditReportLine "  NOT enabled on: $($analyticNodesNeedEnable -join ', ')"
                Write-AuditReportLine "  To enable it (run elevated on each node listed above, if you choose to):"
                Write-AuditReportLine "      wevtutil sl $analyticLog /e:true /q:true"
                Write-AuditReportLine ""
            }
        } else {
            Write-AuditReportLine "  Could not query the Analytic channel status on the cluster nodes."
            Write-AuditReportLine ""
        }
    }

    # VSS writer health (READ-ONLY). Per the Microsoft troubleshooting guide, failed / timed-out VSS
    # writers are a leading cause of Hyper-V backup + checkpoint failures (a failed writer blocks the
    # app-consistent checkpoint, which is the operation under investigation here). 'vssadmin list
    # writers' only ENUMERATES writer state - it changes nothing. It needs an elevated context on the
    # owning node; if that is unavailable the section degrades gracefully.
    Show-AuditProgress -Step 60 -Status 'Checking VSS writer health'
    Write-Section "VSS Writer Health (vssadmin list writers - read-only):"
    # v0.2.16 PERF: VSS writer state is a NODE property ('vssadmin list writers' enumerates the owning
    # node's writers, not this VM's), so cache it ONCE per owning node and reuse it for every VM on that
    # node - exactly as the Worker/VMMS event scan is cached. On a fleet run this was the single biggest
    # cost (per-VM vssadmin can take tens of seconds to minutes); caching cuts it from once-per-VM to
    # once-per-node. A null cache entry means the query genuinely failed on that node (recorded so it is
    # not retried per VM).
    $vssWriters = $null
    if ($script:VssByNode.ContainsKey($OwningNode)) {
        $vssWriters = $script:VssByNode[$OwningNode]
    } else {
        # v0.2.16: time the once-per-node vssadmin scan as its own sub-step (1.10.60.10), mirroring the
        # node event-log scan (1.10.50.10), so the telemetry cleanly isolates the per-node VSS cost from
        # the per-VM overhead and can prove the caching saving on the next run.
        $vssScanStart = Get-TelemetryNow
        $vssScanAttempts = 0
        try {
            $vssWriters = @(Invoke-WithRetry -AttemptCount ([ref]$vssScanAttempts) `
                -DiagnosticOperation 'Query VSS writers on owning node' `
                -DiagnosticScope ("Node={0}" -f $OwningNode) -ScriptBlock {
                    Invoke-OnOwner -ScriptBlock {
                        $raw = & vssadmin list writers 2>$null
                        if (-not $raw) { return @() }
                        $text = ($raw -join "`n")
                        $out = [System.Collections.Generic.List[object]]::new()
                        foreach ($b in ($text -split "(?m)^Writer name:")) {
                            if ($b -notmatch "'") { continue }
                            $name    = if ($b -match "'([^']+)'")      { $Matches[1] }        else { '' }
                            $state   = if ($b -match "State:\s*(.+)")   { $Matches[1].Trim() } else { '' }
                            $lastErr = if ($b -match "Last error:\s*(.+)") { $Matches[1].Trim() } else { '' }
                            if ($name) { [void]$out.Add([pscustomobject]@{ Writer = $name; State = $state; 'Last error' = $lastErr }) }
                        }
                        $out.ToArray()
                    }
                })
            $script:VssByNode[$OwningNode] = $vssWriters
        } catch {
            $vssWriters = $null
            $script:VssByNode[$OwningNode] = $null
            Write-Alert "  Could not query VSS writers on '$OwningNode' after $vssScanAttempts attempt(s) (needs an elevated context): $($_.Exception.Message)" -Level Warning
        }
        Add-TelemetryEntry -Step '1.10.60.10' -Phase 'VSS writer scan (once per node)' `
            -Detail ("Node={0}; Status={1}; Writers={2}; Attempts={3}" -f $OwningNode,
                $(if ($null -ne $vssWriters) { 'Success' } else { 'Unavailable' }), @($vssWriters).Count, $vssScanAttempts) `
            -StartUtc $vssScanStart -EndUtc (Get-TelemetryNow)
    }
    $vssUnhealthy = @()
    if ($vssWriters -and $vssWriters.Count -gt 0) {
        $vssUnhealthy = @($vssWriters | Where-Object {
            (($_.'Last error') -and ($_.'Last error' -ne 'No error')) -or ($_.State -notmatch 'Stable')
        })
        if ($vssUnhealthy.Count -gt 0) {
            Write-Alert ("  {0} of {1} VSS writer(s) are NOT healthy (State not Stable, or a Last error):" -f $vssUnhealthy.Count, $vssWriters.Count) -Level Warning
            $vssUnhealthy | Format-Table Writer, State, 'Last error' -AutoSize -Wrap | Out-Indented
            Write-AuditReportLine "  Unhealthy VSS writers commonly block Hyper-V checkpoint / backup operations. Restarting the"
            Write-AuditReportLine "  related service(s) or the affected writer often clears them (see the reference below)."
        } else {
            Write-Alert "  All $($vssWriters.Count) VSS writer(s) report State: Stable with no last error." -Level Good
            Write-AuditReportLine ""
        }
    } else {
        Write-AuditReportLine "  VSS writer state unavailable (vssadmin needs an elevated context on the owning node)."
        Write-AuditReportLine ""
    }

    # Dedicated VM configuration-version note. IMPORTANT: the Microsoft troubleshooting guide does NOT
    # link an older VM config version to the checkpoint / merge failure under investigation; it lists a
    # configuration-version MISMATCH as a cause of MIGRATION / START failures (a separate category). It
    # is surfaced here as accurate, clearly-scoped context only, and only when the VM is behind latest.
    if ($vmVerOlder) {
        Write-Section "VM Configuration Version (migration / start context - NOT a checkpoint cause):"
        Write-AuditReportLine ("  This VM is at configuration version {0}; its owning node supports up to {1}." -f $vm.Version, $hostMaxVer)
        Write-AuditReportLine  "  This is NOT a stated cause of the checkpoint / merge failure being investigated. The text below"
        Write-AuditReportLine ("  is quoted VERBATIM from {0}" -f $script:TroubleshootTitle)
        Write-AuditReportLine  "  (which lists a configuration-version mismatch under migration / start failures):"
        Write-AuditReportLine  '      "Configuration version mismatch: VM configuration versions below the required minimum'
        Write-AuditReportLine  '       after migrations or upgrades."'
        Write-AuditReportLine  "  If an upgrade is required, shut the VM down first, then run 'Update-VMVersion' (or use Hyper-V"
        Write-AuditReportLine  "  Manager > Upgrade Configuration Version). This is an operator decision - the module changes nothing."
        Write-AuditReportLine ("  Reference: {0}" -f $script:TroubleshootTitle)
        Write-AuditReportLine ("             {0}" -f $script:TroubleshootUrl)
        Write-AuditReportLine ""
    }

    # Summary: total active checkpoints (differencing / .avhdx layers) across all attached disks:
    Show-AuditProgress -Step 65 -Status 'Building summary'
    $totalCheckpoints = @($diskReports | Measure-Object -Property CheckpointCount -Sum).Sum
    if (-not $totalCheckpoints) { $totalCheckpoints = 0 }
    $hasCheckpoints   = $totalCheckpoints -gt 0
    $stalenessAssessmentStart = Get-TelemetryNow
    $stalenessAssessment = Get-CheckpointStalenessAssessment -DiskReports $diskReports.ToArray() `
        -Snapshots $checkpoints -StaleHours $StaleHours -NowUtc ([datetime]::UtcNow)
    $staleCheckpoints = @($stalenessAssessment.StaleSnapshots)
    $staleAttachedLayerCount = [int]$stalenessAssessment.StaleAttachedLayerCount
    $snapshotLayerMismatch = [bool]$stalenessAssessment.SnapshotLayerMismatch
    Add-TelemetryEntry -Step '1.10.65.10' -Phase 'Checkpoint staleness assessment' `
        -Detail ("{0}; Layers={1}; StaleLayers={2}; Snapshots={3}; StaleSnapshots={4}; Mismatch={5}" -f $VMName, $stalenessAssessment.AttachedLayerCount, $staleAttachedLayerCount, $stalenessAssessment.SnapshotCount, $staleCheckpoints.Count, $snapshotLayerMismatch) `
        -StartUtc $stalenessAssessmentStart -EndUtc (Get-TelemetryNow)

    # Severity: distinguish a CONFIRMED checkpoint fork-commit / merge-failure signature (a genuine
    # data-loss risk if the VM is migrated / restarted) from symptom-only noise (e.g. repeated 15268
    # or an aged backup checkpoint), which usually points to a stalled / failed backup or an unhealthy
    # VSS writer rather than on-disk chain corruption.
    # v0.2.12: 18590 REMOVED from the fork-commit signature IDs - in the field it is the
    # Hyper-V-Worker "VM has encountered a fatal error" GUEST-OS bugcheck (e.g. Stop 0x7E), which is
    # unrelated to a checkpoint fork-commit / merge failure. The signature is now event 3216 or one of
    # the specific merge/commit HRESULTs, AND (v0.2.12) the event must be ATTRIBUTABLE TO THIS VM.
    $forkCommitRx     = @($script:EventPolicy.ForkCommitHResults | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $hasForkSignature = (@($vmConcernEvents | Where-Object { $_.IsConfirmingFork }).Count -gt 0)

    # v0.2.14: event SEVERITY split. Only HIGH-signal events attributable to THIS VM (its OWN
    # checkpoint / merge actually failed, or a fork-commit HRESULT) should escalate a VM to INVESTIGATE.
    # LOW-signal per-VM events (e.g. 15268 'failed to get disk information', 12240 attachment-not-found,
    # 3280 could-not-initiate, 32510 stale .hrl delete) are storage / housekeeping chatter and, on
    # their own, must NOT flag an otherwise-clean, running, checkpoint-free, replica-Normal VM.
    # v0.2.16: 19090 ('background disk merge INTERRUPTED') REMOVED from the high-signal set. An
    # interrupted merge is TRANSIENT by nature - Hyper-V retries and normally COMPLETES the merge later
    # (the field data shows 19070 'merge started' / 19080 'merge finished successfully' bracketing these).
    # A merge that was interrupted and genuinely never completed leaves an orphaned .avhdx behind, which
    # is caught independently by the orphan scan (and DOES drive INVESTIGATE via $hasOrphans). So a 19090
    # with NO leftover orphan / attached layer means the merge resolved - it must NOT, on its own, flag an
    # otherwise-clean VM (no orphans, no stale checkpoint, healthy replica) as INVESTIGATE with no
    # actionable next step. A genuine merge FAILURE (19100), a failed checkpoint (18012), a fork-commit
    # (3216) or cannot-load-config (16300) remain high-signal. 19090 is still shown (Concern=YES) and
    # still drives DISCOVERY, but is treated as low-signal for the per-VM verdict.
    $vmHighSignalIds     = @($script:EventPolicy.CriticalIds) + @($script:EventPolicy.OperationFailureIds)
    $vmHighConcernEvents = @($vmConcernEvents | Where-Object { ($vmHighSignalIds -contains [int]$_.Id) -or $_.IsConfirmingFork -or ($_.SignalRole -eq 'Leading') })
    $vmHighConcernCount  = @($vmHighConcernEvents).Count
    $vmLowConcernCount   = $vmEventConcernCount - $vmHighConcernCount

    # v0.2.17: separate the CRITICAL (fork-commit / on-disk chain, data-loss) class from the HIGH
    # OPERATION-FAILURE class, and detect causal or bounded recovery only where the failure represents a
    # merge operation. A later 19080 can resolve merge failure 19100, but it cannot prove recovery from
    # checkpoint-request failure 18012 (a merge may belong to another operation) or configuration-load
    # failure 16300. Those failures remain operational concerns even when no durable artifact is present.
    # A CRITICAL fork-commit event is NEVER demoted, regardless of any following merge.
    $vmHighOpIds      = @($script:EventPolicy.OperationFailureIds)
    $vmCriticalEvents = @($vmConcernEvents | Where-Object { $_.IsConfirmingFork })
    $vmHighOpEvents   = @($vmConcernEvents | Where-Object { (($vmHighOpIds -contains [int]$_.Id) -or ($_.SignalRole -eq 'Leading')) -and -not $_.IsConfirmingFork })
    $vmCriticalCount  = @($vmCriticalEvents).Count
    $vmHighOpCount    = @($vmHighOpEvents).Count
    $operationRecoveryStart = Get-TelemetryNow
    $operationRecovery = Resolve-HyperVOperationRecovery `
        -Events @($workerEvents | Where-Object { $_ -and $_.VmAttributed }) `
        -FailureIds @($script:EventPolicy.OperationFailureIds) `
        -CompletionIds @($script:EventPolicy.MergeSuccessIds) -MaxMinutes 30
    $recoveryCanReduceSeverity = ($operationRecovery.Status -in @('ConfirmedRecovered', 'ApparentlyRecovered'))
    $highOpSelfResolved = (($vmHighOpCount -gt 0) -and ($operationRecovery.FailureCount -eq $vmHighOpCount) -and `
        ($vmCriticalCount -eq 0) -and $recoveryCanReduceSeverity -and (-not $hasOrphans) -and `
        ($staleCheckpoints.Count -eq 0) -and ($staleAttachedLayerCount -eq 0) -and (-not $snapshotLayerMismatch))
    Add-TelemetryEntry -Step '1.10.50.30' -Phase 'Event operation recovery correlation' `
        -Detail ("VM={0}; Status={1}; Failures={2}; Completions={3}; Causal={4}; Apparent={5}; Unresolved={6}" -f `
            $VMName, $operationRecovery.Status, $operationRecovery.FailureCount, $operationRecovery.CompletionCount,
            $operationRecovery.CausalMatchCount, $operationRecovery.ApparentMatchCount, $operationRecovery.UnresolvedCount) `
        -StartUtc $operationRecoveryStart -EndUtc (Get-TelemetryNow)
    # The event count that ACTUALLY escalates a VM to INVESTIGATE on events alone: every CRITICAL event,
    # plus operation-failure events ONLY when they did not self-resolve.
    $vmEscalatingConcernEvents = @($vmCriticalEvents) + @(if (-not $highOpSelfResolved) { $vmHighOpEvents })
    $vmEscalatingConcernCount = @($vmEscalatingConcernEvents).Count

    # Replica health as a concern driver (v0.2.14). A Critical replica (e.g. resync required) or a
    # Warning is a genuine per-VM issue even with no checkpoints / events, so it drives INVESTIGATE.
    $replHealth    = [string]$replAssessment.Health
    $replCritical  = [bool]$replAssessment.IsCritical
    $replWarning   = ($replAssessment.IsConcern -and -not $replAssessment.IsCritical)
    $replAdvisory  = [bool]$replAssessment.HasAdvisory
    $replUnhealthy = [bool]$replAssessment.IsConcern
    $replProductConcern = ($replAssessment.ProductSeverity -in @('Critical', 'Warning', 'Unknown'))
    $replMeasurementConcern = ($replAssessment.MeasurementStatus -eq 'Concern')

    # v0.2.14: classify each orphaned .avhdx so the operator gets an ACTIONABLE read, and detect the
    # 'past rollback' fingerprint: several orphans across multiple disk folders
    # that share a common last-write DATE = the disks were rolled back to base at that time, orphaning
    # the checkpoint layers. That is the durable evidence of a MATERIALISED fork-commit event whose
    # original events may now be older than -EventLookbackHours. NEVER states 'safe to delete' - the
    # action and decision always rest with the operator.
    # v0.2.15: 16220 ('cannot delete .avhd file ... being used by another process (0x80070020). File
    # is safe to delete at any time.') is a TRANSIENT in-use lock at the moment a delete was attempted
    # - NOT a stuck/failed merge. It is handled as its own evidence class
    # ('TransientDeleteLockObserved') below: when a 16220 for THIS VM names THIS orphan's exact file,
    # the report records the prior attempted deletion but does not authorize removal. Real stuck/failed
    # merges are 19090 / 19100 / 32510.
    $mergeFailIds     = @($script:EventPolicy.MergeFailureIds)
    $rollbackDate     = $null
    $orphanClassified = @()
    if (@($orphans).Count -gt 0) {
        $orphanClassified = @($orphans | ForEach-Object {
            $o = $_; $leaf = [string]$o.Name
            $isLiveMount = (Test-CheckpointHealthPathPattern -Path ([string]$o.FullName) `
                -Patterns $script:CheckpointHealthPolicy.Orphan.LiveMountPathPatterns) -or `
                ($script:CheckpointHealthPolicy.Orphan.ClassifyZeroByteAsLiveMount -and ([long]$o.Length -eq 0))
            # v0.2.15 (F1): match the orphan file name in the event message with a case-insensitive
            # literal .Contains(), NOT -like "*$leaf*" - an .avhdx name containing a wildcard
            # metacharacter ([ ] * ?) would fail to match under -like and mis-classify the orphan.
            $stuckEvt = @($concernEvents | Where-Object { ($mergeFailIds -contains [int]$_.Id) -and $leaf -and ([string]$_.FullMessage).ToLower().Contains($leaf.ToLower()) })
            # A 16220 delete-attempt lock for THIS VM that names THIS orphan's exact file path.
            $lockEvt  = @($concernEvents | Where-Object { ([int]$_.Id -eq 16220) -and $_.VmAttributed -and $leaf -and ([string]$_.FullMessage).ToLower().Contains($leaf.ToLower()) } | Sort-Object 'Time (UTC)')
            $cls = if ($stuckEvt.Count -gt 0) { 'StuckMerge' } elseif ($lockEvt.Count -gt 0) { 'TransientDeleteLockObserved' } elseif ($isLiveMount) { 'LiveMount' } else { 'Leftover' }
            [pscustomobject]@{
                Orphan        = $o
                Class         = $cls
                MergeEventId  = if ($stuckEvt.Count -gt 0) { [int](@($stuckEvt)[0].Id) } else { $null }
                LockEventTime = if ($lockEvt.Count -gt 0) { [string](@($lockEvt)[0].'Time (UTC)') } else { $null }
            }
        })
        # Rollback fingerprint: >=4 orphans sharing ONE last-write date across >=2 distinct folders.
        # Files with their OWN per-file evidence (a real stuck-merge event, or a 16220 delete-attempt
        # lock naming that exact file) keep that stronger classification and are not relabelled.
        $byDate = @($orphans | Where-Object { $_.LastWriteTimeUtc } | Group-Object { $_.LastWriteTimeUtc.Date } | Sort-Object Count -Descending)
        if ($byDate.Count -gt 0) {
            $topDate  = $byDate[0]
            $folders  = @($topDate.Group | ForEach-Object { Split-Path $_.FullName -Parent } | Sort-Object -Unique)
            if ([int]$topDate.Count -ge 4 -and $folders.Count -ge 2) {
                $rollbackDate = ([datetime]$topDate.Name).ToString('yyyy-MM-dd')
                foreach ($oc in $orphanClassified) {
                    if ($oc.Orphan.LastWriteTimeUtc -and ($oc.Orphan.LastWriteTimeUtc.Date -eq [datetime]$topDate.Name) -and ($oc.Class -ne 'StuckMerge') -and ($oc.Class -ne 'TransientDeleteLockObserved')) { $oc.Class = 'RollbackFingerprintCandidate' }
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
    $eventEvidenceUnavailable = ($eventCollectionStatus.Status -eq 'Unavailable')
    $csvFreeSpaceConcern = [bool]($csvFreeSpaceAssessment -and $csvFreeSpaceAssessment.IsConcern)
    $hrlConcern = [bool]($hrlAssessment -and $hrlAssessment.IsConcern)
    $verdictAssessment = Get-VMCheckpointVerdictAssessment `
        -ConfirmingForkSignature $hasForkSignature `
        -HasAttachedLayers ($hasCheckpoints -or $staleCheckpoints.Count -gt 0) `
        -HasIncompleteChain $hasIncompleteChain `
        -HasStaleEvidence (($staleCheckpoints.Count -gt 0) -or ($staleAttachedLayerCount -gt 0)) `
        -SnapshotLayerMismatch $snapshotLayerMismatch -HasOrphans $hasOrphans `
        -VssUnhealthy ($vssUnhealthy.Count -gt 0) -ReplicationConcern ($replUnhealthy -or $hrlConcern) `
        -StorageConcern $csvFreeSpaceConcern `
        -EscalatingEventCount $vmEscalatingConcernCount -RequiredEvidenceUnavailable $eventEvidenceUnavailable
    $holdState = [bool]$verdictAssessment.HoldState
    $investigate = [bool]$verdictAssessment.Investigate
    # True when the ONLY thing found is low-signal per-VM chatter (drives the OK 'note' wording below).
    # v0.2.17: a VM whose only merge-eligible high-signal events were causally or apparently recovered is
    # NOT INVESTIGATE - it falls here and is reported OK with a specific recovery note.
    $lowSignalOnly    = ((-not $holdState) -and (-not $investigate) -and (($vmLowConcernCount -gt 0) -or $highOpSelfResolved))

    # Severity score used ONLY for ORDERING within a verdict band (higher sorts first). Lets orphan /
    # stale / replica-Critical INVESTIGATE VMs bubble above events-only ones; live-mount-only sits lowest.
    $severityScore = 0
    if ($holdState) { $severityScore = 100 }
    elseif ($investigate) {
        if     ($hasRollbackFingerprint)                    { $severityScore = 90 }
        elseif ($hasStuckMergeOrphan)                       { $severityScore = 80 }
        elseif ($hasIncompleteChain)                         { $severityScore = 75 }
        elseif ($snapshotLayerMismatch)                      { $severityScore = 70 }
        elseif ($staleAttachedLayerCount -gt 0)              { $severityScore = 65 }
        elseif ($staleCheckpoints.Count -gt 0)              { $severityScore = 65 }
        elseif ($replCritical)                              { $severityScore = 60 }
        elseif ($hasOrphans -and -not $orphanOnlyLiveMount) { $severityScore = 50 }
        elseif ($vmEscalatingConcernCount -gt 0)            { $severityScore = 45 }
        elseif ($replWarning)                               { $severityScore = 42 }
        elseif ($orphanOnlyLiveMount)                       { $severityScore = 30 }
        else                                                { $severityScore = 20 }
    }
    elseif ($lowSignalOnly) { $severityScore = 5 }

    $concernIdSummary     = (@($concernEvents   | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object { "{0} x{1}" -f $_.Name, $_.Count }) -join ', ')
    $vmConcernIdSummary   = (@($vmConcernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object { "{0} x{1}" -f $_.Name, $_.Count }) -join ', ')
    $vmEscalatingIdSummary = (@($vmEscalatingConcernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object { "{0} x{1}" -f $_.Name, $_.Count }) -join ', ')
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
    if (-not $SkipWorkerEvents -and @($orphans).Count -gt 0 -and @($clusterNodes).Count -gt 0) {
        Show-AuditProgress -Step 70 -Status 'Historic event correlation (around orphan timestamps)'
        $orphanAnchors = @($orphans | ForEach-Object {
            if ($_.CreationTimeUtc) { [pscustomobject]@{ Time = $_.CreationTimeUtc; Type = 'OrphanCreate' } }
            if ($_.LastWriteTimeUtc) { [pscustomobject]@{ Time = $_.LastWriteTimeUtc; Type = 'OrphanLastWrite' } }
        })
        $orphanTimes = @($orphanAnchors | ForEach-Object { $_.Time })
        if ($orphanTimes.Count -gt 0) {
            try {
                $historicCorrelation = Get-HistoricVMEventCorrelation -VMName $VMName -VMId ([string]$vm.VMId) `
                    -Nodes $clusterNodes -Timestamps $orphanTimes -WindowMinutes 120 `
                    -CorrelationAnchors $orphanAnchors -EvidenceScope HistoricOrphanWindow `
                    -SignatureIds @(3216, 18012, 19090, 19100, 16300) -SignatureRx $forkCommitRx
            } catch {
                Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Historic event correlation around orphan timestamps' `
                    -Scope ("VM={0}; Nodes={1}" -f $VMName, (@($clusterNodes) -join ','))
                $historicCorrelation = $null
            }
        }
    }
    # A historic fork-commit signature is strong evidence the rollback DID happen for this VM (even
    # though the events are outside the standard window). Surface it as its own flag.
    $historicForkConfirmed = ($historicCorrelation -and (@($historicCorrelation.Matches | Where-Object {
        (Get-HyperVEventSignalAssessment -EventId ([int]$_.Id) -Log ([string]$_.Log) -Message ([string]$_.Message) -Policy $script:EventPolicy).IsConfirmingFork
    }).Count -gt 0))

    # v0.2.17: ACTIVE-checkpoint historic look-back + event-log-wrap check. A VM can carry an ACTIVE
    # (still-attached, non-orphaned) checkpoint that was created LONGER AGO than -EventLookbackHours - so
    # the standard node scan cannot reach the moment the checkpoint was created, and a fork-commit that
    # happened THEN would be invisible (the VM keeps running with a dormant, inconsistent chain that a
    # later live migration / restart could materialise). This is exactly the case we must flag BEFORE the
    # operator migrates the VM, proactively. So: for each active checkpoint whose CREATION time predates
    # the lookback window, run the SAME targeted, windowed, cross-node historic scan anchored on that
    # creation time. We also record the OLDEST available Worker/VMMS event so that, when no fork-commit is
    # found, we can tell the operator WHETHER the logs even reach back far enough - if they have WRAPPED
    # past the checkpoint's creation, absence of a fork-commit is INCONCLUSIVE, not clean, and the module
    # CANNOT confirm from event data. Read-only, narrow query (a few short windows), so it stays cheap.
    $activeCkptHistoric        = $null
    $activeCkptForkConfirmed   = $false
    $activeCkptLogsWrapped     = $false
    $activeCkptCoverageIncomplete = $false
    $activeCkptOldestCreateUtc = $null
    $activeCkptOldestAvailUtc  = $null
    if (-not $SkipWorkerEvents -and $hasCheckpoints -and @($clusterNodes).Count -gt 0) {
        $lookbackStartUtc  = [DateTime]::UtcNow.AddHours(-$EventLookbackHours)
        $oldActiveCkpts    = @($checkpoints | Where-Object { $_.CreationTimeUtc -and ($_.CreationTimeUtc -lt $lookbackStartUtc) })
        if (@($oldActiveCkpts).Count -gt 0) {
            Show-AuditProgress -Step 70 -Status 'Historic event correlation (around active checkpoint create times)'
            $activeCkptTimes           = @($oldActiveCkpts | ForEach-Object { $_.CreationTimeUtc } | Where-Object { $_ })
            $activeCkptOldestCreateUtc = (@($activeCkptTimes | Sort-Object)[0]).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')
            try {
                $activeCkptHistoric = Get-HistoricVMEventCorrelation -VMName $VMName -VMId ([string]$vm.VMId) `
                    -Nodes $clusterNodes -Timestamps $activeCkptTimes -WindowMinutes 120 `
                    -CorrelationAnchors @($activeCkptTimes | ForEach-Object { [pscustomobject]@{ Time = $_; Type = 'ActiveCheckpointCreate' } }) `
                    -EvidenceScope HistoricActiveCheckpointWindow `
                    -SignatureIds @(3216, 18012, 19090, 19100, 16300) -SignatureRx $forkCommitRx
            } catch {
                Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Historic event correlation around active checkpoint creation' `
                    -Scope ("VM={0}; Nodes={1}" -f $VMName, (@($clusterNodes) -join ','))
                $activeCkptHistoric = $null
                $activeCkptCoverageIncomplete = $true
            }
            if ($activeCkptHistoric) {
                $activeCkptForkConfirmed  = (@($activeCkptHistoric.Matches | Where-Object {
                    (Get-HyperVEventSignalAssessment -EventId ([int]$_.Id) -Log ([string]$_.Log) -Message ([string]$_.Message) -Policy $script:EventPolicy).IsConfirmingFork
                }).Count -gt 0)
                $activeCkptOldestAvailUtc = [string]$activeCkptHistoric.OldestAvailableUtc
                $activeCkptCoverageIncomplete = ((-not $activeCkptForkConfirmed) -and (-not [bool]$activeCkptHistoric.CoverageComplete))
                # Preserve true wrapping separately from empty/unavailable/failed coverage so reporting
                # never attributes an incomplete result to the wrong timestamp or cause.
                $activeCkptLogsWrapped    = ((-not $activeCkptForkConfirmed) -and [bool]$activeCkptHistoric.LogsWrappedPastWindow)
            }
        }
    }
    # v0.2.17: proactive 'cannot confirm safe to migrate' signal - an active checkpoint predates the
    # reachable event history, so the window that would contain a fork-commit at its creation is gone.
    $cannotConfirmMigrationSafe = ($activeCkptCoverageIncomplete -and -not $activeCkptForkConfirmed)

    if ($OutputPath -and $reportFile) {
        $historicMatches = @()
        if ($historicCorrelation) { $historicMatches += @($historicCorrelation.Matches) }
        if ($activeCkptHistoric) { $historicMatches += @($activeCkptHistoric.Matches) }
        if ($historicMatches.Count -gt 0) {
            $allVmEvidence = @($vmAttributedEvents) + @($historicMatches)
            ConvertTo-HyperVEventCsvRows -Events $allVmEvidence -Policy $script:EventPolicy `
                -VMName $VMName -VMId $vmId -DefaultNode $OwningNode |
                Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
            Write-AuditReportLine ("  Historic evidence appended to this VM's event CSV: {0}" -f $csvPath)
        }
    }
    # A confirming fork-commit at the creation of a STILL-ATTACHED checkpoint is the dormant chain-risk
    # condition HOLD STATE exists to prevent: migration or restart could materialise the inconsistency.
    # Incomplete event coverage is not confirming evidence, so it remains INVESTIGATE / CANNOT CONFIRM.
    $activeHistoricVerdict = Resolve-ActiveCheckpointHistoricVerdict `
        -HoldState $holdState -Investigate $investigate -LowSignalOnly $lowSignalOnly `
        -SeverityScore $severityScore -ForkConfirmed $activeCkptForkConfirmed `
        -CoverageIncomplete $cannotConfirmMigrationSafe
    $holdState = [bool]$activeHistoricVerdict.HoldState
    $investigate = [bool]$activeHistoricVerdict.Investigate
    $lowSignalOnly = [bool]$activeHistoricVerdict.LowSignalOnly
    $severityScore = [int]$activeHistoricVerdict.SeverityScore

    # v0.2.16: render the historic correlation in the CONSOLE / .txt report too (previously it was only
    # emitted into the HTML, so the .txt - the artifact attached to a support case - omitted the single
    # strongest piece of evidence and could even read 'fork-commit signature NOT observed' while the HTML
    # said CONFIRMED). Only shown when the scan ran (i.e. the VM had orphaned .avhdx files).
    if ($historicCorrelation) {
        Write-AuditReportLine ""
        Write-Section "Historic Event Correlation (fork-commit / merge events around the orphan timestamps):"
        Write-AuditReportLine ("  Searched +/- {0} min around each orphan's create and last-write times, across {1} node(s)," -f $historicCorrelation.WindowMinutes, @($historicCorrelation.NodesSearched).Count)
        Write-AuditReportLine  "  for THIS VM's fork-commit / merge events that may predate the standard event lookback window."
        Write-AuditReportLine ("  Windows: {0}" -f ((@($historicCorrelation.Windows)) -join '; '))
        if ([int]$historicCorrelation.MatchCount -gt 0) {
            if ($historicForkConfirmed) {
                Write-Alert  "  Confirmed historic 'fork-commit / merge failure': events for this VM were recovered around" -Level Critical
                Write-Alert  "  the orphan timestamps (outside the standard window). This is strong evidence the rollback DID" -Level Critical
                Write-Alert  "  occur - engage Microsoft Support (CSS) / your backup vendor to recover the orphaned data." -Level Critical
                Write-AuditReportLine "  Source-node provenance: a historic event can remain valid when recorded on a former owner node;"
                Write-AuditReportLine "  current VM ownership does not invalidate VM-ID-attributed evidence from another cluster node."
                if ($eventsCsvName) {
                    Write-AuditReportLine ("  Structured evidence: this VM's events CSV ({0}) includes the historic rows used by this verdict." -f $eventsCsvName)
                }
            } else {
                Write-Alert ("  {0} historic event(s) recovered around the orphan timestamps (see below)." -f $historicCorrelation.MatchCount) -Level Warning
            }
            @($historicCorrelation.Matches) | Select-Object `
                @{N='Time (UTC)';E={ $_.Time }}, @{N='Node';E={ $_.Node }}, @{N='Log';E={ $_.Log }}, Id, Message |
                Format-Table -AutoSize -Wrap | Out-Indented
        } else {
            if (-not $historicCorrelation.CoverageComplete) {
                $incompleteScopes = @($historicCorrelation.Coverage | Where-Object { -not $_.Sufficient } | ForEach-Object { "{0}/{1}={2}" -f $_.Node, $_.Channel, $_.Status }) -join '; '
                Write-Alert "  No historic events found, but event coverage is INCOMPLETE." -Level Warning
                Write-AuditReportLine ("  Incomplete node/channel scopes: {0}" -f $incompleteScopes)
                Write-AuditReportLine  "  A required channel was wrapped, disabled, unavailable, or failed - absence here is NOT proof that"
                Write-AuditReportLine  "  no rollback occurred. Review collection status before drawing a clean conclusion."
            } else {
                Write-AuditReportLine ("  No historic fork-commit / merge events for this VM in the searched windows, and the logs DO cover" )
                Write-AuditReportLine ("  that period (oldest available {0}). The orphans are less likely to be a fork-commit rollback -" -f $historicCorrelation.OldestAvailableUtc)
                Write-AuditReportLine  "  more likely leftover backup / live-mount files. Confirm by matching each file to a backup / restore /"
                Write-AuditReportLine  "  live-mount job for this VM at its timestamps; if it is a live-mount, unmount it through the backup"
                Write-AuditReportLine  "  product rather than deleting it by hand (see the Orphaned .avhdx Files section above for the full steps)."
            }
        }
        Write-AuditReportLine ""
    }

    # v0.2.17: CONSOLE / .txt parity for the ACTIVE-checkpoint historic look-back + event-log-wrap check.
    if ($activeCkptHistoric) {
        Write-AuditReportLine ""
        Write-Section "Active-Checkpoint Historic Look-back (fork-commit / merge events around the checkpoint create time):"
        Write-AuditReportLine ("  This VM has an active checkpoint created {0} - older than the {1}h event lookback." -f $activeCkptOldestCreateUtc, $EventLookbackHours)
        Write-AuditReportLine ("  Searched +/- {0} min around the checkpoint create time(s), across {1} node(s)." -f $activeCkptHistoric.WindowMinutes, @($activeCkptHistoric.NodesSearched).Count)
        if ($activeCkptForkConfirmed) {
            Write-Alert  "  HOLD STATE: a 'fork-commit / merge-failure' event was recorded at this active checkpoint's" -Level Critical
            Write-Alert  "  creation. The differencing chain may be inconsistent while the VM runs; a live migration / restart" -Level Critical
            Write-Alert  "  could expose the inconsistency and cause the disks to roll back to their base disks. Do NOT perform" -Level Critical
            Write-Alert  "  a live, quick, or storage migration, or restart, until the chain is validated. Engage Microsoft" -Level Critical
            Write-Alert  "  Support (CSS) or your backup vendor. This is a dormant risk; data loss has not been detected." -Level Critical
            @($activeCkptHistoric.Matches) | Select-Object `
                @{N='Time (UTC)';E={ $_.Time }}, @{N='Node';E={ $_.Node }}, @{N='Log';E={ $_.Log }}, Id, Message |
                Format-Table -AutoSize -Wrap | Out-Indented
        } elseif ($cannotConfirmMigrationSafe) {
            $incompleteScopes = @($activeCkptHistoric.Coverage | Where-Object { -not $_.Sufficient } | ForEach-Object { "{0}/{1}={2}" -f $_.Node, $_.Channel, $_.Status }) -join '; '
            Write-Alert "  SAFETY COULD NOT BE VERIFIED: required Worker/VMMS logs are incomplete." -Level Warning
            Write-AuditReportLine ("  Incomplete node/channel scopes: {0}" -f $incompleteScopes)
            Write-AuditReportLine  "  The missing logs may contain fork-commit evidence that this audit could not detect."
            Write-AuditReportLine  "  The oldest available timestamp is shown in the structured result. Validate the differencing chain"
            Write-AuditReportLine  "  before any live migration, quick migration, storage migration, or restart."
        } else {
            Write-AuditReportLine ("  No fork-commit / merge events at the checkpoint create time, and the logs DO cover that period" )
            Write-AuditReportLine ("  (oldest available {0}). No pre-migration event-based concern for this active checkpoint." -f $activeCkptOldestAvailUtc)
        }
        Write-AuditReportLine ""
    }

    Show-AuditProgress -Step 80 -Status 'Rechecking VM collection state consistency'
    $stateRecheckStart = Get-TelemetryNow
    $stateTokenEnd = $null
    $stateTokenEndError = ''
    $stateConsistencyReasons = @()
    $stateConsistencyStatus = 'Unavailable'
    $stateConsistencyImpact = 'Inconclusive'
    $currentOwnerNode = $OwningNode
    try {
        $currentGroup = Get-ClusterGroup -Cluster $ClusterName -ErrorAction Stop | Where-Object { $_.Name -eq $VMName } | Select-Object -First 1
        if ($currentGroup -and $currentGroup.OwnerNode) { $currentOwnerNode = [string]$currentGroup.OwnerNode }
        if ($stateTokenStart) {
            if (-not $currentOwnerNode.Equals($OwningNode, [StringComparison]::OrdinalIgnoreCase)) {
                $stateTokenEnd = [pscustomobject]@{
                    OwnerNode = $currentOwnerNode; State = $stateTokenStart.State
                    CheckpointCount = $stateTokenStart.CheckpointCount; DiskPaths = @($stateTokenStart.DiskPaths)
                    ConfigLastWriteUtc = $stateTokenStart.ConfigLastWriteUtc
                }
            } else {
                $stateTokenEnd = Invoke-OnOwner -ScriptBlock {
                    param($name, $owner, $collectorDefinition)
                    $collectStateToken = [scriptblock]::Create($collectorDefinition)
                    & $collectStateToken -VMName $name -OwnerNode $owner
                } -ArgumentList $VMName, $currentOwnerNode, $stateTokenCollectorDefinition
            }
            $stateComparison = Compare-VMCollectionStateToken -StartToken $stateTokenStart -EndToken $stateTokenEnd
            $stateConsistencyReasons = @($stateComparison.Reasons)
            $stateConsistencyStatus = if ($stateComparison.Changed) { 'Changed' } else { 'Stable' }
        } else {
            $stateTokenEndError = $stateTokenStartError
            $stateConsistencyReasons = @('InitialStateTokenUnavailable')
        }
    } catch {
        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Capture final VM state token' -Scope ("VM={0}; StartOwner={1}; CurrentOwner={2}" -f $VMName, $OwningNode, $currentOwnerNode)
        $stateTokenEndError = $_.Exception.Message
        $stateConsistencyReasons = @('FinalStateTokenUnavailable')
    }
    $stateChangedDuringCollection = ($stateConsistencyStatus -eq 'Changed')
    $stateConsistencyUnavailable = ($stateConsistencyStatus -eq 'Unavailable')
    $stateConsistencyImpact = Get-VMCollectionStateImpact -Status $stateConsistencyStatus -Reasons $stateConsistencyReasons `
        -ReplicationEnabled $replicationEnabled -ReplicaProductSeverity ([string]$replAssessment.ProductSeverity) `
        -ReplicaState ([string]$replAssessment.State)
    $replicaConfigWriteAdvisory = ($stateConsistencyImpact -eq 'Advisory')
    $stateInconclusive = ($stateConsistencyImpact -eq 'Inconclusive')
    if ($stateInconclusive) {
        if (-not $holdState) { $investigate = $true }
        $lowSignalOnly = $false
        if ($severityScore -lt 70) { $severityScore = 70 }
        Write-AuditReportLine ""
        Write-Section "Collection State Consistency:"
        if ($stateChangedDuringCollection) {
            Write-Alert ("  INCONCLUSIVE - VM state changed during collection ({0}). Results may combine different VM states." -f ($stateConsistencyReasons -join ', ')) -Level Warning
        } else {
            Write-Alert ("  INCONCLUSIVE - VM state consistency could not be verified: {0}" -f $stateTokenEndError) -Level Warning
        }
        Write-AuditReportLine "  Rerun the audit after migration, checkpoint, merge, or power-state activity has settled."
        Write-AuditReportLine ""
    } elseif ($replicaConfigWriteAdvisory) {
        Write-AuditReportLine ""
        Write-Section "Collection State Consistency:"
        Write-AuditReportLine "  ADVISORY - only the VM configuration last-write timestamp changed during collection while"
        Write-AuditReportLine "  Hyper-V Replica remained Replicating / Normal. The audit did not identify the writer of this timestamp-only change."
        Write-AuditReportLine "  Owner, power state, checkpoint count, and attached disk paths remained stable, so this does not"
        Write-AuditReportLine "  make the checkpoint evidence inconclusive or change the VM health verdict."
        Write-AuditReportLine ""
    }
    Add-TelemetryEntry -Step '1.10.80.10' -Phase 'VM collection state consistency recheck' `
        -Detail ("VM={0}; Status={1}; Impact={2}; StartOwner={3}; EndOwner={4}; Reasons={5}; Errors={6}" -f `
            $VMName, $stateConsistencyStatus, $stateConsistencyImpact, $OwningNode, $currentOwnerNode,
            @($stateConsistencyReasons).Count, $(if ($stateTokenEndError) { 1 } else { 0 })) `
        -StartUtc $stateRecheckStart -EndUtc (Get-TelemetryNow)

    # Build one typed explanation model after every verdict input is known, including the final
    # collection-state recheck. TXT and HTML consume this same model so each active verdict driver
    # receives matching, actionable wording.
    $investigationDriverLabels = [System.Collections.Generic.List[string]]::new()
    $hasCheckpointArtifactDriver = ($hasIncompleteChain -or ($staleAttachedLayerCount -gt 0) -or
        ($staleCheckpoints.Count -gt 0) -or $snapshotLayerMismatch -or $hasOrphans)
    $hasEventDriver = ($vmEscalatingConcernCount -gt 0)
    $hasReplicaDriver = ($replProductConcern -or $replMeasurementConcern -or $hrlConcern)
    $hasStateDriver = $stateInconclusive
    $hasVssDriver = ($vssUnhealthy.Count -gt 0)
    $hasStorageDriver = $csvFreeSpaceConcern
    $hasEvidenceDriver = ($eventEvidenceUnavailable -or $cannotConfirmMigrationSafe)

    if ($hasIncompleteChain) { [void]$investigationDriverLabels.Add(("{0} incomplete or unreadable VHD chain(s)" -f $incompleteChains.Count)) }
    if ($staleAttachedLayerCount -gt 0) { [void]$investigationDriverLabels.Add(("{0} stale attached AVHDX layer(s)" -f $staleAttachedLayerCount)) }
    if ($staleCheckpoints.Count -gt 0) { [void]$investigationDriverLabels.Add(("{0} stale named snapshot(s) at or beyond {1}h" -f $staleCheckpoints.Count, $StaleHours)) }
    if ($snapshotLayerMismatch) { [void]$investigationDriverLabels.Add('snapshot/layer representation mismatch') }
    if ($hasOrphans) { [void]$investigationDriverLabels.Add(("{0} orphaned .avhdx file(s)" -f @($orphans).Count)) }
    if ($hasEventDriver) { [void]$investigationDriverLabels.Add(("{0} unresolved VM-attributed checkpoint/merge operation failure event(s) [{1}]" -f $vmEscalatingConcernCount, $vmEscalatingIdSummary)) }
    if ($hasVssDriver) { [void]$investigationDriverLabels.Add(("{0} unhealthy VSS writer(s)" -f $vssUnhealthy.Count)) }
    if ($hasReplicaDriver) {
        if ($replProductConcern) { [void]$investigationDriverLabels.Add(("Hyper-V Replica product health/state concern ({0} / {1})" -f $replAssessment.State, $replAssessment.Health)) }
        if ($replMeasurementConcern) {
            $replicaMeasurementEvidence = Get-ReplicaMeasurementEvidenceText -Assessment $replAssessment -Breaches @($replAssessment.ConcernBreaches)
            [void]$investigationDriverLabels.Add(("Hyper-V Replica measurement concern ({0})" -f $replicaMeasurementEvidence))
        }
        if ($hrlConcern) { [void]$investigationDriverLabels.Add(("{0} HRL file(s) beyond the cadence-aware threshold with Replica corroboration" -f $hrlAssessment.ExceedsCadenceCount)) }
    }
    if ($hasStorageDriver) { [void]$investigationDriverLabels.Add(("{0} CSV free-space policy breach(es)" -f @($csvFreeSpaceAssessment.Breaches).Count)) }
    if ($hasEvidenceDriver) {
        $evidenceLabel = if ($cannotConfirmMigrationSafe) { 'required Worker/VMMS history around active-checkpoint creation is incomplete' } else { 'required Hyper-V event evidence unavailable' }
        [void]$investigationDriverLabels.Add($evidenceLabel)
    }
    if ($hasStateDriver) {
        $stateReasonText = if ($stateConsistencyReasons.Count -gt 0) { $stateConsistencyReasons -join ', ' } else { 'state token unavailable' }
        [void]$investigationDriverLabels.Add(("INCONCLUSIVE collection state ({0}: {1})" -f $stateConsistencyStatus, $stateReasonText))
    }

    $investigationAssessmentText = if ($hasCheckpointArtifactDriver) {
        "Checkpoint or virtual-disk evidence requires validation. The specific checkpoint fork-commit signature was not observed in the current window, so on-disk chain corruption is not confirmed."
    } elseif ($hasEventDriver -and -not ($hasReplicaDriver -or $hasStateDriver -or $hasVssDriver -or $hasStorageDriver -or $hasEvidenceDriver)) {
        "Recurring checkpoint or merge operation failures require job-history review. No durable checkpoint disk residue or confirming fork-commit signature was found, so this is reliability evidence rather than proof of chain corruption."
    } elseif ($hasReplicaDriver -and -not ($hasStateDriver -or $hasVssDriver -or $hasStorageDriver -or $hasEvidenceDriver)) {
        if ($replProductConcern) {
            "Hyper-V Replica product health or state requires attention. This concern is independent of checkpoint-chain corruption."
        } elseif ($replMeasurementConcern) {
            "Hyper-V Replica measurements exceed effective relationship-aware limits. Product health remains $($replAssessment.Health); this concern is independent of checkpoint-chain corruption."
        } else {
            "Hyper-V Replica HRL files exceed the cadence-aware threshold with Replica corroboration. Product health remains $($replAssessment.Health); this concern is independent of checkpoint-chain corruption."
        }
    } elseif ($hasStateDriver -and -not ($hasReplicaDriver -or $hasVssDriver -or $hasStorageDriver -or $hasEvidenceDriver)) {
        "The VM changed state during collection or its final state could not be verified, so the evidence is inconclusive and may combine different VM states."
    } else {
        "Multiple independent health or evidence-coverage concerns require review; use the driver list below to route each item to the responsible owner."
    }

    $investigationActionLines = [System.Collections.Generic.List[string]]::new()
    if ($hasCheckpointArtifactDriver) {
        [void]$investigationActionLines.Add('Review the attached VHD chain, checkpoint, and orphan evidence with the backup/storage owner before any merge, removal, migration, or restart action. Escalate if a merge failure or durable artifact persists, ownership or purpose cannot be established, or that owner rules out its component.')
    }
    if ($hasEventDriver) { [void]$investigationActionLines.Add('This event evidence does not identify a disk requiring manual action. Compare the VM event CSV timestamps and IDs with backup/checkpoint job history; engage the job owner if failures recur, and re-run after the next backup cycle.') }
    if ($replProductConcern) { [void]$investigationActionLines.Add('Review Get-VMReplication health and relationship state on both partners; remediate through the Replica owner, then verify that product health returns to Normal and the relationship returns to its expected state. Escalate if the abnormal state persists after connectivity, capacity, and configuration review.') }
    if ($replMeasurementConcern) { [void]$investigationActionLines.Add('Review the breached Replica measurements and effective limits, monitoring window, network/storage demand, and capacity on both partners; re-run after the next monitoring interval and escalate to the Replica owner if the breach persists.') }
    if ($hrlConcern) { [void]$investigationActionLines.Add('Review the queued HRL files and cadence threshold with the Replica owner; verify replication progress and storage availability, then re-run after the next monitoring interval. Do not modify HRL files based on this report.') }
    if ($hasStateDriver) { [void]$investigationActionLines.Add('Rerun the audit after migration, checkpoint, merge, replication, or power-state activity has settled.') }
    if ($hasVssDriver) { [void]$investigationActionLines.Add('Resolve unhealthy VSS writers with the workload or backup owner, then rerun the affected backup and this audit.') }
    if ($hasStorageDriver) { [void]$investigationActionLines.Add('Restore the hosting CSV volumes to the configured free-space policy before retrying checkpoint-intensive operations.') }
    if ($hasEvidenceDriver) { [void]$investigationActionLines.Add('Route first to the collection owner to restore required Worker/VMMS event-log access or retention, then rerun and involve the relevant component owner if evidence remains unavailable. Absence of unavailable evidence is not proof of health.') }
    $investigationDrivers = [pscustomobject]@{
        Labels = $investigationDriverLabels.ToArray()
        AssessmentText = [string]$investigationAssessmentText
        ActionLines = $investigationActionLines.ToArray()
        HasCheckpointArtifact = [bool]$hasCheckpointArtifactDriver
        HasEvents = [bool]$hasEventDriver
        HasReplica = [bool]$hasReplicaDriver
        HasStateInconclusive = [bool]$hasStateDriver
        HasVss = [bool]$hasVssDriver
        HasStorage = [bool]$hasStorageDriver
        HasEvidenceUnavailable = [bool]$hasEvidenceDriver
    }

    # ---- Findings block for the operator / backup team (and, only when warranted, a CSS case) -------
    # A copy/paste-ready summary of the key findings. The framing ADAPTS to severity so we do NOT push
    # operators toward a Microsoft Support (CSS) case when there is no fork-commit signature: only
    # HOLD STATE (a confirmed fork-commit signature alongside unmerged differencing disks) warrants a
    # CSS case up front; INVESTIGATE and clean results are for the operator / backup team to triage
    # FIRST. It references the events CSV for the full, untruncated detail.
    # v0.2.16: open a dedicated 'Rendering findings + building result' section (1.10.75) here so the
    # findings / RESULT text AND the ReportData object build are timed on their own, instead of being
    # absorbed by the still-open 'Building summary' (1.10.65) / 'Historic event correlation' (1.10.70)
    # section (which the finally block would otherwise close only at the very end of the VM audit).
    Show-AuditProgress -Step 75 -Status 'Rendering findings + building result'
    if ($holdState) {
        $statementTitle = "PROBLEM STATEMENT (for a Microsoft Support (CSS) case and/or your backup vendor):"
    } elseif ($investigate) {
        $statementTitle = if ($historicForkConfirmed) {
            "FINDINGS - CONFIRMED HISTORIC ROLLBACK (engage Microsoft Support (CSS) / your backup vendor):"
        } else {
            "FINDINGS TO INVESTIGATE (for your operations / backup team - no Microsoft case needed yet):"
        }
    } else {
        $statementTitle = "SUMMARY (for your records):"
    }
    Write-AuditReportLine ""
    Write-Section $statementTitle
    Write-AuditReportLine "  ------------------------------------------------------------------------------"
    Write-AuditReportLine ("  Cluster / Owner : {0} / {1}" -f $ClusterName, $OwningNode)
    Write-AuditReportLine ("  VM              : {0}  (Id {1})" -f $VMName, $vm.VMId)
    Write-AuditReportLine ("  VM State/Status : {0} / {1}" -f $vm.State, $vm.Status)
    Write-AuditReportLine ("  Report run at   : {0}" -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ssZ'))
    Write-AuditReportLine ""
    if ($hasCheckpoints -and $holdState) {
        Write-AuditReportLine ("  This VM is running on {0} active differencing (.avhdx checkpoint) disk layer(s) over its base" -f $totalCheckpoints)
        Write-AuditReportLine  "  VHD(s), together with a 'checkpoint fork-commit / merge-failure' signature. That combination can"
        Write-AuditReportLine  "  leave the on-disk chain inconsistent and, if the VM is later migrated or restarted, roll the"
        Write-AuditReportLine  "  disks back to base and orphan the data held in the .avhdx layer(s)."
    } elseif ($hasCheckpoints) {
        Write-AuditReportLine ("  This VM is running on {0} active differencing (.avhdx checkpoint) disk layer(s) over its base" -f $totalCheckpoints)
        Write-AuditReportLine  "  VHD(s). No 'checkpoint fork-commit / merge-failure' signature was found, so these layer(s) are"
        Write-AuditReportLine  "  most likely a backup checkpoint that has not yet been merged - review them with your backup"
        Write-AuditReportLine  "  team before taking any action (this is NOT, on its own, a reason to open a Microsoft case)."
    } else {
        Write-AuditReportLine  "  This VM currently has no active differencing (.avhdx) disk layers attached."
    }
    if ($vmEventConcernCount -gt 0) {
        Write-AuditReportLine ""
        Write-AuditReportLine ("  {0} concerning Hyper-V event(s) attributable to THIS VM ({1}) on {2} in the last {3} hours, by event ID:" -f $vmEventConcernCount, $VMName, $OwningNode, $EventLookbackHours)
        $vmConcernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object {
            $times = @($_.Group.'Time (UTC)' | Sort-Object)
            if ($_.Count -le 1 -or $times[0] -eq $times[-1]) {
                Write-AuditReportLine ("    - ID {0}  x{1}   (at {2} UTC)" -f $_.Name, $_.Count, $times[0])
            } else {
                Write-AuditReportLine ("    - ID {0}  x{1}   (first {2} UTC, last {3} UTC)" -f $_.Name, $_.Count, $times[0], $times[-1])
            }
        }
    }
    if ($nodeOnlyConcernCount -gt 0) {
        Write-AuditReportLine ""
        Write-AuditReportLine ("  NOTE (node context): a further {0} concerning Hyper-V event(s) on {1} reference OTHER VMs (or no VM)" -f $nodeOnlyConcernCount, $OwningNode)
        Write-AuditReportLine  "  and are NOT attributed to this VM - they do not, on their own, mean this VM needs investigation."
        Write-AuditReportLine ("  Node-wide concern IDs (all VMs on {0}): [{1}]." -f $OwningNode, $concernIdSummary)
        Write-AuditReportLine  "  See the events CSV (VmAttributed column) for which events belong to which VM."
    }
    if ($vssUnhealthy.Count -gt 0) {
        Write-AuditReportLine ""
        Write-AuditReportLine ("  {0} VSS writer(s) are not healthy: {1}" -f $vssUnhealthy.Count, ((@($vssUnhealthy | ForEach-Object { $_.Writer })) -join ', '))
        Write-AuditReportLine  "  Unhealthy VSS writers commonly block Hyper-V checkpoint / backup operations."
    }
    if ($hasOrphans) {
        Write-AuditReportLine ""
        Write-AuditReportLine ("  {0} orphaned .avhdx file(s) are present in this VM's disk folder(s) but are NOT attached to the VM." -f @($orphans).Count)
        Write-AuditReportLine  "  A failed merge, failed backup checkpoint, interrupted live mount, or initial Replica recovery point"
        Write-AuditReportLine  "  can leave these files behind. Do NOT move, rename, merge, or delete them based only on this report."
        Write-AuditReportLine  "    1. Match it to a job: find the backup / restore / live-mount / replica-seed job for THIS VM in your"
        Write-AuditReportLine  "       backup product's history at the file's Created / LastWrite time (see the Orphaned .avhdx Files section)."
        Write-AuditReportLine  "    2. If it is a live-mount / instant-recovery file, unmount it THROUGH the backup product - do not delete by hand."
        Write-AuditReportLine  "    3. For an initial Replica recovery point, review Get-VMReplication health and follow the approved"
        Write-AuditReportLine  "       Replica recovery procedure."
        Write-AuditReportLine  "    4. Before any file change, confirm ownership and purpose, verify that a current backup exists, and"
        Write-AuditReportLine  "       use a procedure approved by the backup vendor or Microsoft Support, or based on your own"
        Write-AuditReportLine  "       investigation into that specific orphaned checkpoint file."
    }
    if ($holdState) {
        Write-AuditReportLine ""
        Write-AuditReportLine  "  ASSESSMENT: HOLD STATE (data-loss risk) - a 'checkpoint fork-commit / merge-failure' signature AND"
        Write-AuditReportLine  "  unmerged differencing disk(s) are present together. As a precaution this VM should NOT be"
        Write-AuditReportLine  "  live/quick/storage-migrated or restarted until the differencing chain has been validated (and"
        Write-AuditReportLine  "  merged if required); reopening an inconsistent chain can roll disks back to base and lose data."
    } elseif ($investigate) {
        Write-AuditReportLine ""
        if ($historicForkConfirmed) {
            Write-AuditReportLine  "  ASSESSMENT: INVESTIGATE (confirmed historic rollback) - no CURRENT fork-commit signature and no attached"
            Write-AuditReportLine  "  differencing disk(s), BUT a historic 'checkpoint fork-commit / merge failure' for this VM was CONFIRMED"
            Write-AuditReportLine  "  via historic events recovered around the orphaned .avhdx timestamps (see the Historic Event"
            Write-AuditReportLine  "  Correlation section above). The rollback has already occurred, and the orphaned file(s) may contain"
            Write-AuditReportLine  "  data that is no longer accessible to the VM. Engage Microsoft Support (CSS) or your backup vendor to"
            Write-AuditReportLine  "  recover them; do NOT delete them. Concern signal(s) for this VM:"
        } else {
            Write-AuditReportLine ("  ASSESSMENT: INVESTIGATE - {0}" -f $investigationDrivers.AssessmentText)
            Write-AuditReportLine  "  Concern signal(s) for this VM:"
        }
        if (-not $historicForkConfirmed) {
            foreach ($driverLabel in @($investigationDrivers.Labels)) {
                Write-AuditReportLine ("    - {0}." -f $driverLabel)
            }
        }
        if ($historicForkConfirmed) {
            Write-AuditReportLine  "    - CONFIRMED historic fork-commit / merge event(s) recovered for this VM (see Historic Event Correlation above)."
        }
    }
    if ($staleCheckpoints.Count -gt 0) {
        Write-AuditReportLine ""
        Write-AuditReportLine ("  {0} checkpoint(s) on this VM are older than {1} hours. A Third-Party Backup product that creates" -f $staleCheckpoints.Count, $StaleHours)
        Write-AuditReportLine  "  Hyper-V checkpoints normally requests the checkpoint MERGE (removal) only AFTER it has successfully"
        Write-AuditReportLine  "  copied the VM's data, so a checkpoint lingering well beyond the backup window suggests the backup"
        Write-AuditReportLine  "  did not complete or did not issue the merge. Check that product for the progress / completion of"
        Write-AuditReportLine  "  its backup job(s), and confirm whether these checkpoint(s) are expected (by design) or need manual"
        Write-AuditReportLine ("  investigation. If checkpoint(s) on this VM are EXPECTED to persist beyond {0}h (e.g. a longer" -f $StaleHours)
        Write-AuditReportLine  "  backup retention window), re-run with -StaleHours <n> (e.g. 48) to raise the threshold."
    }
    if (($staleAttachedLayerCount -gt 0) -and ($staleCheckpoints.Count -eq 0)) {
        Write-AuditReportLine ""
        Write-AuditReportLine ("  {0} attached AVHDX layer(s) are older than {1} hours, but no named snapshot is exposed by" -f $staleAttachedLayerCount, $StaleHours)
        Write-AuditReportLine  "  Get-VMSnapshot. Validate the active VHD chain and the backup product's recent job history before"
        Write-AuditReportLine  "  migration, restart, merge, or removal. Do not infer that the layer is safe to delete from the"
        Write-AuditReportLine  "  absence of a named snapshot."
    }
    Write-AuditReportLine ""
    if ($holdState) {
        Write-AuditReportLine  "  Requested action: engage Microsoft Support (CSS) and/or your backup vendor to advise on the safe"
        Write-AuditReportLine  "  next step to validate and merge / consolidate the differencing chain BEFORE any migration / restart."
    } elseif ($investigate) {
        if ($historicForkConfirmed) {
            Write-AuditReportLine  "  Suggested next steps (a historic fork-commit was CONFIRMED for this VM - treat as a recovery case):"
            Write-AuditReportLine  "    1. Do NOT delete the orphaned .avhdx file(s) - they may hold data written between the checkpoint"
            Write-AuditReportLine  "       and the rollback that has not been recovered."
            Write-AuditReportLine  "    2. Engage your backup vendor and open a Microsoft Support (CSS) case to advise on recovering the"
            Write-AuditReportLine  "       orphaned data and confirming the current chain is consistent before any migration / restart."
            Write-AuditReportLine  "    3. Re-run this audit with a larger -EventLookbackHours (e.g. 720) to capture more of the original"
            Write-AuditReportLine  "       event timeline for the case."
        } else {
            Write-AuditReportLine  "  Suggested next steps (route each driver to the responsible operations, backup, Replica, or storage owner):"
            $actionNumber = 0
            foreach ($actionLine in @($investigationDrivers.ActionLines)) {
                $actionNumber++
                Write-AuditReportLine ("    {0}. {1}" -f $actionNumber, $actionLine)
            }
            Write-AuditReportLine ("    {0}. Open a Microsoft Support case if a confirming fork-commit signature appears, a persistent merge failure or durable disk artifact cannot be resolved, or the responsible owner rules out their component." -f ($actionNumber + 1))
        }
    } else {
        $replicaAdvisorySummary = ($replAssessment -and $replAssessment.MeasurementStatus -eq 'Advisory')
        if ($lowSignalOnly) {
            if ($replicaAdvisorySummary) {
                Write-AuditReportLine "  No VM-health action required from this result - no active checkpoint layer(s), no orphaned .avhdx,"
                Write-AuditReportLine "  no verdict-driving Replica concern; one measurement advisory is recorded, and VSS writers are stable."
            } else {
                Write-AuditReportLine "  No VM-health action required from this result - no active checkpoint layer(s), no orphaned .avhdx, healthy replica"
                Write-AuditReportLine "  and stable VSS writers."
            }
            Write-AuditReportLine  "  This VM has no high-signal concern events; the low-signal event(s) attributed"
            Write-AuditReportLine  "  to it (e.g. a 'background disk merge interrupted' (19090) that subsequently completed with no leftover"
            Write-AuditReportLine  "  .avhdx, or 'failed to get disk information' (15268) storage / housekeeping chatter) are not, on their"
            Write-AuditReportLine  "  own, a concern and need no action."
        } else {
            if ($replicaAdvisorySummary) {
                Write-AuditReportLine "  No VM-health action required from this result - no active checkpoint layer(s) and no verdict-driving"
                Write-AuditReportLine "  Replica concern; one measurement advisory is recorded below the verdict threshold."
            } else {
                Write-AuditReportLine "  No VM-health action required from this result - no active checkpoint layer(s) and no concern signals were found."
            }
        }
        if ($script:HousekeepingFindings.Count -gt 0) {
            Write-AuditReportLine  "  Review the separate cluster / storage housekeeping observations in the HTML report before making"
            Write-AuditReportLine  "  any storage-layout changes; those review-only items do not change this VM's health verdict."
        }
    }
    Write-AuditReportLine ""
    if ($holdState) {
        Write-AuditReportLine  "  Artifacts from this audit to attach to the case:"
    } else {
        Write-AuditReportLine  "  Artifacts from this audit (for your records / to share with the responsible owner):"
    }
    if ($OutputPath -and $reportFile) {
        Write-AuditReportLine ("    - Text report : {0}" -f $reportFile)
        if ($eventsCsvName) {
            Write-AuditReportLine ("    - Events CSV  : {0}" -f (Join-Path (Split-Path -Parent $reportFile) $eventsCsvName))
            if ($hasEventDriver -or $hasForkSignature -or $historicForkConfirmed -or $activeCkptForkConfirmed) {
                Write-AuditReportLine  "                    (full, untruncated Hyper-V event messages that back the event findings above)"
            } else {
                Write-AuditReportLine  "                    (full, untruncated Hyper-V event messages retained as context; no event row drives this verdict)"
            }
        }
    } else {
        Write-AuditReportLine  "    - (Re-run with -OutputPath <folder> to capture the .txt report and events .csv to attach.)"
    }
    Write-AuditReportLine ""
    Write-AuditReportLine ("  Reference: {0}" -f $script:TroubleshootTitle)
    Write-AuditReportLine ("             {0}" -f $script:TroubleshootUrl)
    Write-AuditReportLine "  ------------------------------------------------------------------------------"

    # ---- Overall RESULT / verdict (shown last, after the copy/paste PROBLEM STATEMENT above) --------
    Write-AuditReportLine ""
    Write-AuditReportLine "==================================================================="
    $checkpointEvidenceLevel = if ($holdState) { 'Critical' } elseif ($investigate) { 'Warning' } else { 'Good' }
    if ($hasCheckpoints) {
        Write-Alert "  CHECKPOINT EVIDENCE: $totalCheckpoints CheckPoint (differencing/AVHDX) disk(s) present on '$VMName'." -Level $checkpointEvidenceLevel
    } else {
        Write-Alert "  CHECKPOINT EVIDENCE: No CheckPoint AVHDX disks are attached to '$VMName'." -Level $checkpointEvidenceLevel
    }
    if ($staleCheckpoints.Count -gt 0) {
        Write-Alert "  WARNING: $($staleCheckpoints.Count) named snapshot(s) are >= $StaleHours hours old (possibly stuck)." -Level Warning
    }
    if ($staleAttachedLayerCount -gt 0) {
        Write-Alert "  WARNING: $staleAttachedLayerCount attached AVHDX layer(s) are >= $StaleHours hours old." -Level Warning
    }
    if ($snapshotLayerMismatch) {
        Write-Alert "  WARNING: named snapshot and attached AVHDX presence do not match; validate the active chain." -Level Warning
    }
    if ($vmEventConcernCount -gt 0 -and ($vmEscalatingConcernCount -gt 0 -or $holdState -or $historicForkConfirmed)) {
        Write-Alert "  WARNING: $vmEventConcernCount concerning Hyper-V event(s) attributable to this VM (see the Concern=YES rows above)." -Level Warning
    } elseif ($vmEventConcernCount -gt 0) {
        Write-Alert "  LOW-SIGNAL NOTE: $vmEventConcernCount event(s) attributable to this VM do not change the VM health verdict; see the evidence and recovery context above." -Level Info
    } elseif ($nodeOnlyConcernCount -gt 0) {
        Write-Alert "  NOTE: $nodeOnlyConcernCount concerning Hyper-V event(s) on $OwningNode reference OTHER VMs (node context - not this VM)." -Level Info
    }
    if ($hasOrphans) {
        Write-Alert "  WARNING: $(@($orphans).Count) orphaned .avhdx file(s) present in this VM's disk folder(s) (not attached to the VM)." -Level Warning
    }
    if ($holdState) {
        Write-AuditReportLine ""
        Write-Alert "  HOLD STATE (data-loss risk): a 'checkpoint fork-commit / merge-failure' signature AND" -Level Critical
        Write-Alert "  unmerged differencing disk(s) are present together." -Level Critical
        Write-Alert ("  Why flagged: {0} active differencing (.avhdx) layer(s); fork-commit signature in event(s) [{1}]; {2} checkpoint(s) >= {3}h old." -f $totalCheckpoints, $vmConcernIdSummary, $staleCheckpoints.Count, $StaleHours) -Level Critical
        Write-Alert "  See the PROBLEM STATEMENT section above for the recommended next steps and a copy/paste case summary." -Level Critical
    } elseif ($investigate) {
        Write-AuditReportLine ""
        if ($historicForkConfirmed) {
            Write-Alert "  INVESTIGATE (confirmed historic rollback): no CURRENT fork-commit signature, but a historic 'checkpoint" -Level Critical
            Write-Alert "  fork-commit / merge failure' for this VM was CONFIRMED via historic events around the orphan timestamps." -Level Critical
            Write-Alert ("  Why flagged: CONFIRMED historic fork-commit event(s); {0} orphaned .avhdx file(s); {1} concerning event(s) for this VM [{2}]." -f @($orphans).Count, $vmEventConcernCount, $vmConcernIdSummary) -Level Critical
            Write-Alert "  See the Historic Event Correlation and FINDINGS TO INVESTIGATE sections above - engage Microsoft Support (CSS) / your backup vendor to recover the orphaned data." -Level Critical
        } else {
            Write-Alert ("  INVESTIGATE: {0}" -f $investigationDrivers.AssessmentText) -Level Warning
            Write-Alert ("  Why flagged: {0}." -f (@($investigationDrivers.Labels) -join '; ')) -Level Warning
            Write-Alert "  See the FINDINGS TO INVESTIGATE section above for driver-specific next steps and responsible-owner routing." -Level Warning
        }
    }
    # Diagnostic-coverage TIP (independent of the verdict): if the Hyper-V-VMMS/Analytic channel is not
    # enabled on one or more nodes, say so HERE in the RESULT block - mid-report it is easily missed.
    if ($analyticNodesNeedEnable.Count -gt 0) {
        Write-AuditReportLine ""
        Write-Alert ("  TIP: the Hyper-V-VMMS/Analytic channel is not enabled on: {0}." -f ($analyticNodesNeedEnable -join ', ')) -Level Info
        Write-Alert "  It is the only place the internal per-disk .vmcx revert ('Cannot revert configuration info for AVHD') is" -Level Info
        Write-Alert "  traced. Enabling it now (elevated, per node) captures that extra detail for the NEXT occurrence:" -Level Info
        Write-Alert "      wevtutil sl Microsoft-Windows-Hyper-V-VMMS-Analytic /e:true /q:true" -Level Info
    }
    Write-AuditReportLine "==================================================================="

    # Always remind the reader this is diagnostic only - any interpretation / remediation goes via the
    # backup vendor (backup/VSS findings) or Microsoft Support (confirmed fork-commit).
    Write-AuditReportLine ""
    Write-Alert "  NOTE: This report is DIAGNOSTIC ONLY and makes no changes. For backup / checkpoint-merge or VSS" -Level Info
    Write-Alert "  findings, engage your third-party backup vendor first; open a Microsoft Support (CSS) case for a" -Level Info
    Write-Alert "  confirmed fork-commit signature, or when the vendor rules out their product. Act on their advice." -Level Info
    Write-AuditReportLine "==================================================================="

    # Per-VM result object for the pipeline (emitted only when the caller passed -PassThru; the end
    # block gates that). The human report above went to the host / transcript, never the pipeline.
    $recommendation = if ($holdState) { 'HOLD STATE' } elseif ($investigate) { 'INVESTIGATE' } else { 'OK' }
    $historicCoverageIncomplete = (($historicCorrelation -and -not $historicCorrelation.CoverageComplete) -or `
        ($activeCkptHistoric -and -not $activeCkptHistoric.CoverageComplete))
    $assessmentConfidence = if ($hasIncompleteChain -or (-not $virtualDiskCoverageComplete) -or $eventEvidenceUnavailable -or $historicCoverageIncomplete -or $stateInconclusive) {
        'Low'
    } elseif ($eventCollectionStatus.Status -eq 'Skipped' -or -not $vssWriters -or @($vssWriters).Count -eq 0) {
        'Moderate'
    } else {
        'High'
    }

    # In Quiet mode the detailed report above was captured but not echoed; show a single concise verdict
    # line per VM (always to the real host, bypassing the buffer/quiet gate).
    if ($script:QuietConsole) {
        $verdictColour = switch ($recommendation) { 'HOLD STATE' { 'Red' } 'INVESTIGATE' { 'Yellow' } 'OK' { 'Green' } default { 'Gray' } }
        Write-AuditStatus ("  [{0}] {1}  (owner {2})" -f $VMName, $recommendation, $OwningNode) -ForegroundColor $verdictColour
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
            Created = $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ')
            AgeHrs  = $ageH
            Stale   = ($ageH -ge $StaleHours)
            Parent  = [string]$_.Parent
            ParentDisplay = [string]$_.ParentDisplay
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
    # full path). Newest-written first. v0.2.14 adds a per-orphan evidence class
    # LiveMount / Leftover) + an age-in-days + a neutral 'Likely' read - NEVER 'safe to delete'.
    $orphanClassLookup = @{}
    foreach ($oc in $orphanClassified) { if ($oc.Orphan -and $oc.Orphan.FullName) { $orphanClassLookup[[string]$oc.Orphan.FullName] = $oc } }
    $orphanRowsForHtml = @($orphans | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {
        $ocm     = $orphanClassLookup[[string]$_.FullName]
        $cls     = if ($ocm) { [string]$ocm.Class } else { 'Leftover' }
        $mergeId = if ($ocm) { $ocm.MergeEventId } else { $null }
        $lockTime = if ($ocm) { [string]$ocm.LockEventTime } else { $null }
        $ageHrs  = if ($_.LastWriteTimeUtc) { [math]::Round(([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalHours, 1) } else { $null }
        $ageDays = if ($_.LastWriteTimeUtc) { [math]::Round(([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalDays, 1) } else { $null }
        $likely  = switch ($cls) {
            'RollbackFingerprintCandidate' { 'Common-date rollback fingerprint candidate - do NOT remove; investigate / recover' }
            'StuckMerge'   { ("Possible stuck / failed merge (event {0}) - investigate before any action" -f $mergeId) }
            'TransientDeleteLockObserved' { if ($lockTime) { "A delete was attempted on $lockTime and blocked by a transient in-use lock (event 16220, 0x80070020). This records evidence only; it does not establish current ownership or authorize removal. Validate with the backup team and VM owner before any action." } else { "A prior delete attempt was blocked by a transient in-use lock (event 16220, 0x80070020). This records evidence only; it does not establish current ownership or authorize removal. Validate with the backup team and VM owner before any action." } }
            'LiveMount'    { 'Likely backup live-mount / instant-recovery artifact - match to the mount / restore job for this VM at its timestamp, then unmount it THROUGH the backup product (do NOT delete the file by hand)' }
            default        { 'Possible leftover backup or Replica file. Match it to a backup, restore, or replica-seed job for this VM at its Created and LastWrite times. Do not move, rename, merge, or delete it until ownership and purpose are confirmed. Use a procedure approved by the backup vendor and/or based on your own investigation into this orphaned checkpoint file.' }
        }
        [pscustomobject]@{
            Name      = [string]$_.Name
            SizeGB    = [math]::Round($_.Length / 1GB, 2)
            Created   = if ($_.CreationTimeUtc)  { $_.CreationTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ') }  else { '' }
            LastWrite = if ($_.LastWriteTimeUtc) { $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ssZ') } else { '' }
            AgeHrs    = $ageHrs
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
        AttachedDiskCount    = $diskReports.Count
        CheckpointLayers     = [int]$totalCheckpoints
        StaleAttachedLayerCount = $staleAttachedLayerCount
        StaleSnapshotCount   = $staleCheckpoints.Count
        SnapshotLayerMismatch = $snapshotLayerMismatch
        ChainComplete        = (-not $hasIncompleteChain)
        IncompleteChainCount = $incompleteChains.Count
        IncompleteChains     = @($incompleteChains | ForEach-Object { [pscustomobject]@{ Disk = [string]$_.Attached; FailurePath = [string]$_.FailurePath; Error = [string]$_.ChainError; TerminalType = [string]$_.TerminalType; DepthLimitReached = [bool]$_.DepthLimitReached } })
        AttachedVhdLayers    = @($diskReports | ForEach-Object {
            $diskReport = $_
            $diskChain = @($diskReport.Chain)
            for ($layerIndex = 0; $layerIndex -lt $diskChain.Count; $layerIndex++) {
                $layer = $diskChain[$layerIndex]
                $createdUtc = if ($layer.Created) { ([datetime]$layer.Created).ToUniversalTime() } else { $null }
                $lastWriteUtc = if ($layer.LastWrite) { ([datetime]$layer.LastWrite).ToUniversalTime() } else { $null }
                $isDifferencing = ([string]$layer.Type -eq 'Differencing')
                $checkpointAgeHrs = if ($isDifferencing -and $createdUtc) { [math]::Round(([datetime]::UtcNow - $createdUtc).TotalHours, 1) } else { $null }
                $lastActivityAgeHrs = if ($lastWriteUtc) { [math]::Round(([datetime]::UtcNow - $lastWriteUtc).TotalHours, 1) } else { $null }
                $checkpointStale = $isDifferencing -and $createdUtc -and (([datetime]::UtcNow - $createdUtc).TotalHours -ge $StaleHours)
                $role = if ($isDifferencing) {
                    if ($layerIndex -eq 0) { 'Active (top)' } else { 'Checkpoint' }
                } elseif ([string]$layer.Type -in @('Dynamic', 'Fixed')) { 'Base' } else { "Attached ($($layer.Type))" }
                [pscustomobject]@{
                    Chain              = [string]$diskReport.Attached
                    FileName           = Split-Path ([string]$layer.Path) -Leaf
                    Layer              = $layerIndex + 1
                    Role               = $role
                    Path               = [string]$layer.Path
                    Type               = [string]$layer.Type
                    SizeGB             = $layer.SizeGB
                    Created            = if ($createdUtc) { $createdUtc.ToString('yyyy-MM-dd HH:mm:ssZ') } else { '' }
                    LastWrite          = if ($lastWriteUtc) { $lastWriteUtc.ToString('yyyy-MM-dd HH:mm:ssZ') } else { '' }
                    CheckpointAgeHrs   = $checkpointAgeHrs
                    LastActivityAgeHrs = $lastActivityAgeHrs
                    CheckpointStale    = [bool]$checkpointStale
                    AgeHrs             = $checkpointAgeHrs
                    Stale              = [bool]$checkpointStale
                    ParentPath         = if (($layerIndex + 1) -lt $diskChain.Count) { [string]$diskChain[$layerIndex + 1].Path } else { '' }
                }
            }
        })
        Checkpoints          = $ckptRowsForHtml
        StaleCheckpointCount = $staleCheckpoints.Count
        StaleHours           = $StaleHours
        Replication          = $replForHtml
        VssState             = $vssStateForHtml
        VssTotal             = @($vssWriters).Count
        VssUnhealthyCount    = $vssUnhealthy.Count
        VssUnhealthy         = @($vssUnhealthy | ForEach-Object { [pscustomobject]@{ Writer = [string]$_.Writer; State = [string]$_.State; LastError = [string]$_.'Last error' } })
        AnalyticCheckSkipped    = [bool]$SkipAnalyticCheck
        AnalyticNodesNeedEnable = @($analyticNodesNeedEnable)
        CsvVolumes           = @($csvReport)
        CsvFreeSpaceAssessment = $csvFreeSpaceAssessment
        HrlAssessment        = $hrlAssessment
        PolicySource         = [string]$script:CheckpointHealthPolicy.Source
        VirtualDiskInventory = [pscustomobject]@{
            Complete      = [bool]$virtualDiskCoverageComplete
            FileCount     = @($script:VirtualDiskFileInventory.Files).Count
            OwnershipRows = @($script:VirtualDiskOwnershipInventory.Rows).Count
            Roots         = @($script:VirtualDiskFileInventory.Roots | ForEach-Object {
                [pscustomobject]@{ Root = [string]$_.Root; Complete = [bool]$_.Complete; FileCount = [int]$_.FileCount; Error = [string]$_.Error }
            })
            Nodes         = @($script:VirtualDiskOwnershipInventory.Nodes | ForEach-Object {
                $nodeInventoryResult = $_
                [pscustomobject]@{
                    Node          = [string]$nodeInventoryResult.Node
                    Complete      = [bool]$nodeInventoryResult.Complete
                    VMCount       = if ($nodeInventoryResult.Result) { [int]$nodeInventoryResult.Result.VMCount } else { 0 }
                    SnapshotCount = if ($nodeInventoryResult.Result) { [int]$nodeInventoryResult.Result.SnapshotCount } else { 0 }
                    Error         = [string]$nodeInventoryResult.Error
                    QueryErrors   = @(if ($nodeInventoryResult.Result) { @($nodeInventoryResult.Result.Errors) } else { @() })
                }
            })
        }
        OrphanCount          = @($orphans).Count
        Orphans              = $orphanRowsForHtml
        HasOrphans           = [bool]$hasOrphans
        HasForkSignature     = [bool]$hasForkSignature
        EventConcernCount    = $eventConcernCount
        VmEventConcernCount  = $vmEventConcernCount
        EventBreakdown       = $eventBreakdownForHtml
        VmEvents             = @($workerEvents | Where-Object { $_.VmAttributed } | ForEach-Object {
            [pscustomobject][ordered]@{
                TimeUtc                = [string]$_.'Time (UTC)'
                Id                     = [int]$_.Id
                Level                  = [string]$_.Level
                Log                    = [string]$_.Log
                Concern                = [string]$_.Concern
                AttributionMethod      = [string]$_.AttributionMethod
                AttributionConfidence  = [string]$_.AttributionConfidence
                SignalRole             = [string]$_.SignalRole
                IsConfirmingFork       = [bool]$_.IsConfirmingFork
                Message                = [string]$_.Message
                FullMessage            = [string]$_.FullMessage
            }
        })
        EventLookbackHours   = $EventLookbackHours
        EventsCsvName        = [string]$eventsCsvName
        EventsCsvPath        = if ($eventsCsvName -and $reportFile) { Join-Path (Split-Path -Parent $reportFile) $eventsCsvName } else { '' }
        NodeEventsCsvName    = [string]$script:NodeCsvNameByNode[$OwningNode]
        NodeEventsCsvPath    = if ($script:NodeCsvNameByNode[$OwningNode] -and $reportFile) { Join-Path (Split-Path -Parent $reportFile) ([string]$script:NodeCsvNameByNode[$OwningNode]) } else { '' }
        StateConsistencyStatus = [string]$stateConsistencyStatus
        StateConsistencyImpact = [string]$stateConsistencyImpact
        StateChangedDuringCollection = [bool]$stateChangedDuringCollection
        StateConsistencyReasons = @($stateConsistencyReasons)
        InvestigationDrivers = $investigationDrivers
        AssessmentConfidence = [string]$assessmentConfidence
        CollectionStatus     = [pscustomobject]@{
            VhdChains = [pscustomobject]@{
                Status = if ($hasIncompleteChain) { 'Incomplete' } else { 'Complete' }
                IncompleteCount = [int]$incompleteChains.Count
            }
            VirtualDiskInventory = [pscustomobject]@{
                Status = if ($virtualDiskCoverageComplete) { 'Complete' } else { 'Incomplete' }
                RootFailures = @($script:VirtualDiskFileInventory.Roots | Where-Object { -not $_.Complete }).Count
                NodeFailures = @($script:VirtualDiskOwnershipInventory.Nodes | Where-Object { -not $_.Complete }).Count
            }
            EventLogs = [pscustomobject]@{
                Status = [string]$eventCollectionStatus.Status
                Error = [string]$eventCollectionStatus.Error
                AttemptCount = [int]$eventCollectionStatus.AttemptCount
            }
            HistoricEvents = [pscustomobject]@{
                Status = if ($historicCoverageIncomplete) { 'Incomplete' } elseif ($historicCorrelation -or $activeCkptHistoric) { 'Complete' } else { 'NotRequired' }
            }
            StateConsistency = [pscustomobject]@{
                Status = [string]$stateConsistencyStatus
                Impact = [string]$stateConsistencyImpact
                Reasons = @($stateConsistencyReasons)
                Error = [string]$stateTokenEndError
            }
            VssWriters = [pscustomobject]@{ Status = [string]$vssStateForHtml }
        }
        EventCollectionStatus = [pscustomobject]@{
            Status        = [string]$eventCollectionStatus.Status
            Error         = [string]$eventCollectionStatus.Error
            SourceNode    = [string]$eventCollectionStatus.SourceNode
            AttemptedUtc  = $eventCollectionStatus.AttemptedUtc
            AttemptCount  = [int]$eventCollectionStatus.AttemptCount
            ChannelStatus = @($eventCollectionStatus.ChannelStatus)
        }
        SupportCaseSummary   = [string]$supportCaseSummary
        # v0.2.14 additions.
        VmHighConcernCount   = [int]$vmHighConcernCount
        VmLowConcernCount    = [int]$vmLowConcernCount
        # v0.2.17: CRITICAL vs HIGH-operation split + self-resolution. VmEscalatingConcernCount is the
        # count that actually drives INVESTIGATE on events alone (critical + UNRESOLVED operation events).
        VmCriticalCount      = [int]$vmCriticalCount
        VmHighOpCount        = [int]$vmHighOpCount
        VmEscalatingConcernCount = [int]$vmEscalatingConcernCount
        HighOpSelfResolved   = [bool]$highOpSelfResolved
        OperationRecoveryStatus = [string]$operationRecovery.Status
        OperationRecovery   = [pscustomobject]@{
            Status = [string]$operationRecovery.Status
            FailureCount = [int]$operationRecovery.FailureCount
            CompletionCount = [int]$operationRecovery.CompletionCount
            CausalMatchCount = [int]$operationRecovery.CausalMatchCount
            ApparentMatchCount = [int]$operationRecovery.ApparentMatchCount
            UnresolvedCount = [int]$operationRecovery.UnresolvedCount
        }
        # v0.2.17: summary of the HIGH-signal event IDs attributed to THIS VM (e.g. '18012 x3, 19100 x1'),
        # so the events-only INVESTIGATE step list can name the actual IDs the operator must chase.
        VmHighConcernIds     = [string]$vmEscalatingIdSummary
        LowSignalOnly        = [bool]$lowSignalOnly
        NodeDominantNote     = [string]$nodeDominantNote
        ReplHealth           = [string]$replHealth
        ReplUnhealthy        = [bool]$replUnhealthy
        ReplAdvisory         = [bool]$replAdvisory
        ReplCritical         = [bool]$replCritical
        ReplAssessment       = [pscustomobject]@{
            Severity = [string]$replAssessment.Severity
            ProductSeverity = [string]$replAssessment.ProductSeverity
            MeasurementStatus = [string]$replAssessment.MeasurementStatus
            State = [string]$replAssessment.State
            Health = [string]$replAssessment.Health
            Mode = [string]$replAssessment.Mode
            IsConcern = [bool]$replAssessment.IsConcern
            HasAdvisory = [bool]$replAssessment.HasAdvisory
            IsCritical = [bool]$replAssessment.IsCritical
            Reason = [string]$replAssessment.Reason
            MeasurementsAvailable = [bool]$replAssessment.MeasurementsAvailable
            LastReplicationTimeUtc = $replAssessment.LastReplicationTimeUtc
            LastReplicationAgeMinutes = $replAssessment.LastReplicationAgeMinutes
            PendingBytes = [long]$replAssessment.PendingBytes
            LatencySeconds = [double]$replAssessment.LatencySeconds
            MissedCount = [long]$replAssessment.MissedCount
            FrequencySeconds = [double]$replAssessment.FrequencySeconds
            AverageReplicationBytes = [long]$replAssessment.AverageReplicationBytes
            SuccessfulCount = [long]$replAssessment.SuccessfulCount
            MissedRatePercent = $replAssessment.MissedRatePercent
            MonitoringIntervalSeconds = [double]$replAssessment.MonitoringIntervalSeconds
            EffectiveMaxAgeMinutes = [double]$replAssessment.EffectiveMaxAgeMinutes
            EffectiveMaxPendingBytes = [long]$replAssessment.EffectiveMaxPendingBytes
            EffectiveMaxLatencySeconds = [double]$replAssessment.EffectiveMaxLatencySeconds
            MaxMissedRatePercent = [double]$replAssessment.MaxMissedRatePercent
            ThresholdBreaches = @($replAssessment.ThresholdBreaches)
            ConcernBreaches = @($replAssessment.ConcernBreaches)
            AdvisoryBreaches = @($replAssessment.AdvisoryBreaches)
        }
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
                CoverageComplete   = [bool]$historicCorrelation.CoverageComplete
                CoverageStatus     = [string]$historicCorrelation.CoverageStatus
                Coverage           = @($historicCorrelation.Coverage)
                LogsWrappedPastWindow = [bool]$historicCorrelation.LogsWrappedPastWindow
            }
        } else { $null }
        # v0.2.17: ACTIVE-checkpoint historic look-back + event-log-wrap findings (proactive, pre-migration).
        ActiveCkptForkConfirmed   = [bool]$activeCkptForkConfirmed
        ActiveCkptLogsWrapped     = [bool]$activeCkptLogsWrapped
        ActiveCkptCoverageIncomplete = [bool]$activeCkptCoverageIncomplete
        CannotConfirmMigrationSafe = [bool]$cannotConfirmMigrationSafe
        ActiveCkptOldestCreateUtc = [string]$activeCkptOldestCreateUtc
        ActiveCkptOldestAvailUtc  = [string]$activeCkptOldestAvailUtc
        ActiveCkptHistoric        = if ($activeCkptHistoric) {
            [pscustomobject]@{
                Windows            = @($activeCkptHistoric.Windows)
                WindowMinutes      = [int]$activeCkptHistoric.WindowMinutes
                NodesSearched      = @($activeCkptHistoric.NodesSearched)
                MatchCount         = [int]$activeCkptHistoric.MatchCount
                Matches            = @($activeCkptHistoric.Matches)
                OldestAvailableUtc = [string]$activeCkptHistoric.OldestAvailableUtc
                CoverageComplete   = [bool]$activeCkptHistoric.CoverageComplete
                CoverageStatus     = [string]$activeCkptHistoric.CoverageStatus
                Coverage           = @($activeCkptHistoric.Coverage)
                LogsWrappedPastWindow = [bool]$activeCkptHistoric.LogsWrappedPastWindow
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
        StaleAttachedLayerCount = $staleAttachedLayerCount
        SnapshotLayerMismatch   = $snapshotLayerMismatch
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
        Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Per-VM audit' -Scope ("VM={0}; Owner={1}; Source={2}" -f $VMName, $OwningNode, $script:CurrentVMSource)
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
            Write-AuditReportLine ''
            Write-AuditReportLine ("VM assessment completed (UTC): {0}" -f [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ssZ'))
            $reportWriteStart = Get-TelemetryNow
            try {
                [System.IO.File]::WriteAllLines($reportFile, $script:VMReportBuffer.ToArray(), (New-Object System.Text.UTF8Encoding($false)))
                if (-not $script:QuietConsole) { Write-AuditStatus "Report saved to: $reportFile" }
            } catch {
                Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Write per-VM text report' -Scope ("VM={0}; File={1}" -f $VMName, $reportFile)
                Write-Warning "Could not write the per-VM report file '$reportFile': $($_.Exception.Message)"
            } finally {
                Add-TelemetryEntry -Step '1.10.85' -Phase 'Per-VM text report write' -Detail ("VM={0}; Source={1}; File={2}" -f $VMName, $script:CurrentVMSource, (Split-Path $reportFile -Leaf)) -StartUtc $reportWriteStart -EndUtc (Get-TelemetryNow)
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
# Cluster storage-health snapshot (populated once, in the end block, unless -SkipStorageHealth).
$script:ClusterStorageHealth = $null
# Run-level operational observations populated by cluster-wide ownership and storage checks. These
# are rendered separately from VM health verdicts and never imply that a file is safe to remove.
$script:HousekeepingFindings = [System.Collections.Generic.List[object]]::new()
$policyInitializationStart = Get-TelemetryNow
$script:CheckpointHealthPolicy = if ($PolicyPath) { Import-CheckpointHealthPolicy -Path $PolicyPath } else { Get-CheckpointHealthDefaultPolicy }
Add-TelemetryEntry -Step '1.05.07' -Phase 'Checkpoint health policy initialization' `
    -Detail ("Schema={0}; Source={1}; ImagePatterns={2}; LiveMountPatterns={3}; CsvPolicyEnabled={4}; HrlPolicyEnabled={5}" -f `
        $script:CheckpointHealthPolicy.SchemaVersion, $script:CheckpointHealthPolicy.Source,
        @($script:CheckpointHealthPolicy.Storage.ImageLibraryPathPatterns).Count,
        @($script:CheckpointHealthPolicy.Orphan.LiveMountPathPatterns).Count,
        $script:CheckpointHealthPolicy.CsvFreeSpace.Enabled, $script:CheckpointHealthPolicy.Replication.Hrl.Enabled) `
    -StartUtc $policyInitializationStart -EndUtc (Get-TelemetryNow)
# v0.2.14: per-node Worker/VMMS event cache (keyed 'node|lookbackHours'). The event scan is node-wide,
# so caching it means each node is read ONCE per run rather than once per VM on that node.
$script:NodeEventCache = @{}
$eventPolicyStart = Get-TelemetryNow
$script:EventPolicy = Get-HyperVEventPolicy
Add-TelemetryEntry -Step '1.05.10' -Phase 'Event policy initialization' `
    -Detail ("Critical={0}; OperationFailure={1}; LowSignal={2}; Context={3}; HResults={4}" -f `
        @($script:EventPolicy.CriticalIds).Count, @($script:EventPolicy.OperationFailureIds).Count,
        @($script:EventPolicy.LowSignalIds).Count, @($script:EventPolicy.ContextIds).Count,
        (@($script:EventPolicy.ForkCommitHResults).Count + @($script:EventPolicy.LeadingHResults).Count + @($script:EventPolicy.SymptomHResults).Count)) `
    -StartUtc $eventPolicyStart -EndUtc (Get-TelemetryNow)
# v0.2.14: records the shared _NodeEvents_<node>_<date>.csv name written once per node, so each VM's
# report can point to the node-wide event detail without duplicating it into every per-VM CSV.
$script:NodeCsvNameByNode = @{}
# v0.2.14 fleet-scale caches: cluster-wide data that is IDENTICAL for every VM in a run is fetched
# ONCE and reused, instead of being re-queried per VM. On a large cluster (hundreds of VMs) this
# removes the bulk of the redundant cluster-API round-trips and remoting-session churn.
$script:ClusterNameCache    = $null   # resolved cluster name (Get-Cluster, once)
$script:ClusterNodesCache   = $null   # node-name array (Get-ClusterNode, once)
$script:GroupOwnerByVm      = $null   # hashtable VMName -> OwnerNode (Get-ClusterGroup, once)
$script:ClusterGroupByVm    = $null   # hashtable VMName -> role projection (same Get-ClusterGroup query)
$script:AnalyticStatusCache = $null   # cluster-wide Hyper-V-VMMS/Analytic status rows (once)
$script:ProbeVmNodeMap      = $null   # hashtable VMName -> node for non-clustered VMs (per-node Get-VM, once)
$script:SessionByNode       = @{}     # pooled PSSession per owning node, reused across VMs, disposed in end block
$script:HostVersionsByNode  = @{}     # hashtable node -> supported VM config versions (Get-VMHostSupportedVersion, once per node)
$script:ClusterCsvCache     = $null   # Get-ClusterSharedVolume result (once)
$script:VssByNode           = @{}     # hashtable node -> vssadmin writer rows (once per node; VSS writer state is node-scoped, not per-VM)
$script:NodeDiagnosticPrefetchRuns = [System.Collections.Generic.List[object]]::new() # actual initial/discovered-node prefetch coordinator results
$script:ReplicationServerSettingsByNode = @{} # read-only Replica monitoring interval/start settings (once per owner node)
$script:VirtualDiskOwnershipInventory = $null # all-node VM/snapshot/chain path ownership (once)
$script:VirtualDiskFileInventory = $null      # all-CSV .vhd/.vhdx/.avhdx file inventory (once)
$script:VirtualDiskHousekeepingBuilt = $false # run-level classifications emitted once

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
            Write-AuditReportLine ("Exclusion list: loaded {0} VM name(s) to skip from '{1}'." -f $script:ExcludedVMNames.Count, $ExcludedVMListCsv)
        } catch {
            Write-Alert ("WARNING: could not read -ExcludedVMListCsv '{0}': {1}. Proceeding with NO exclusions." -f $ExcludedVMListCsv, $_.Exception.Message) -Level Warning
        }
    } else {
        Write-Alert ("WARNING: -ExcludedVMListCsv '{0}' was not found. Proceeding with NO exclusions." -f $ExcludedVMListCsv) -Level Warning
    }
}

if ($ProcessAllVMs) {
    $processAllStart = Get-TelemetryNow
    $resolvedClusterName = if ($Cluster) {
        (Invoke-WithRetry -DiagnosticOperation 'Resolve cluster for ProcessAllVMs' -DiagnosticScope ("Cluster={0}" -f $Cluster) `
            -ScriptBlock { Get-Cluster -Name $Cluster -ErrorAction Stop }).Name
    } else {
        (Invoke-WithRetry -DiagnosticOperation 'Resolve local cluster for ProcessAllVMs' `
            -ScriptBlock { Get-Cluster -ErrorAction Stop }).Name
    }
    $clusterVmNames = @(Invoke-WithRetry -DiagnosticOperation 'Enumerate clustered VMs for ProcessAllVMs' `
        -DiagnosticScope ("Cluster={0}" -f $resolvedClusterName) `
        -ScriptBlock { Get-ClusterGroup -Cluster $resolvedClusterName -ErrorAction Stop } |
        Where-Object { $_.GroupType -eq 'VirtualMachine' } |
        ForEach-Object { [string]$_.Name } |
        Where-Object { $_ } |
        Sort-Object -Unique)
    foreach ($clusterVmName in $clusterVmNames) {
        if ($script:ExcludedVMNames.Count -gt 0 -and $script:ExcludedVMNames.Contains($clusterVmName)) {
            [void]$script:ExcludedMatched.Add($clusterVmName)
            continue
        }
        [void]$script:PendingVMNames.Add($clusterVmName)
    }
    $script:ClusterNameCache = [string]$resolvedClusterName
    Add-TelemetryEntry -Step '1.05.15' -Phase 'Process all clustered VMs selection' `
        -Detail ("Cluster={0}; Found={1}; Selected={2}; Excluded={3}" -f $resolvedClusterName, $clusterVmNames.Count, $script:PendingVMNames.Count, $script:ExcludedMatched.Count) `
        -StartUtc $processAllStart -EndUtc (Get-TelemetryNow)
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
    $script:DebugLogPath = Join-Path $script:RunFolder ("_debug_log_{0}.txt" -f $stamp)
    Write-AuditDebugLog
    Write-AuditReportLine "Writing per-VM reports to: $script:RunFolder"
} else {
    # Option C: no -OutputPath means console output only (nothing saved). Warn UP FRONT so the operator
    # can cancel and re-run with -OutputPath rather than discover it after a long multi-VM run.
    Write-Alert "WARNING: -OutputPath was not supplied - console output ONLY; NO .txt report or events .csv will be saved." -Level Warning
    Write-Alert "         Re-run with -OutputPath <folder> to capture files to attach to a backup-vendor / Microsoft (CSS) case." -Level Warning
    Write-AuditReportLine ""
}
if ($OutputPath -or -not $NoHtml) {
    Write-Alert "SENSITIVE DATA: audit artifacts can contain VM/node names, identifiers, paths, and full event messages." -Level Warning
    Write-Alert "Store them in an access-controlled operator location, transfer them only through approved secure channels," -Level Warning
    Write-Alert "and delete them according to your incident/support retention policy. The ZIP bundle is NOT encrypted." -Level Warning
    if ($AnonymizeTelemetry) {
        Write-Alert "-AnonymizeTelemetry affects only performance telemetry; it does NOT redact TXT, CSV, HTML, or ZIP reports." -Level Warning
    }
    Write-AuditReportLine ""
}

}

# Audit each requested VM. -VMName accepts an array and pipeline input (e.g. Get-VM | ...).
# Each VM is audited independently, so one VM's failure does not stop the rest. With -OutputPath,
# each VM gets its own .txt transcript and .csv event export.
process {
    if ($PSCmdlet.ParameterSetName -ne 'ByName') { return }
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
            Write-AuditReportLine ("Skipping '{0}': present in the -ExcludedVMListCsv exclusion list." -f $singleVMName)
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
    if ($script:ExcludedMatched.Count -gt 0) {
        Write-Alert ("Excluded {0} VM(s) from this run via -ExcludedVMListCsv: {1}" -f $script:ExcludedMatched.Count, (@($script:ExcludedMatched | Sort-Object -Unique) -join ', ')) -Level Info
    }
    if ($vmTotal -eq 0) {
        Write-Alert 'No VMs to audit (all requested VM(s) were excluded, or none were supplied).' -Level Warning
        return
    }
    Initialize-ClusterVirtualDiskInventories -Cluster $Cluster -FirstVMName ([string]$script:PendingVMNames[0])
    $initialDiagnosticNodes = @($script:PendingVMNames | ForEach-Object {
        if ($script:GroupOwnerByVm -and $script:GroupOwnerByVm.ContainsKey([string]$_)) {
            [string]$script:GroupOwnerByVm[[string]$_]
        }
    } | Where-Object { $_ } | Sort-Object -Unique)
    if ($initialDiagnosticNodes.Count -gt 0) {
        try {
            $prefetchRun = Initialize-NodeDiagnosticPrefetch -Nodes $initialDiagnosticNodes `
                -LocalNode $env:COMPUTERNAME -OutputPath $script:RunFolder -LookbackHours $EventLookbackHours `
                -ConcernIds $WorkerEventIds -ContextIds $ContextEventIds -CodePatterns $ErrorCodePatterns `
                -SkipEvents:$SkipWorkerEvents
            if (@($prefetchRun.Nodes).Count -gt 0) { [void]$script:NodeDiagnosticPrefetchRuns.Add($prefetchRun) }
        } catch {
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Initialize node diagnostic prefetch' `
                -Scope ("Nodes={0}; FallingBack=LazyCollection" -f $initialDiagnosticNodes.Count)
            Write-Alert ("  Node diagnostic prefetch could not initialize: {0}. The audit will use the existing lazy per-node collection path." -f $_.Exception.Message) -Level Warning
        }
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

    $discoverySelectionStart = Get-TelemetryNow
    # Cross-check high-risk names against REAL clustered VMs, preserving every validated reason so the
    # selector can aggregate evidence and rank each VM by its strongest signal.
    $validatedDiscoveredCandidates = [System.Collections.Generic.List[object]]::new()
    if ($script:DiscoveredCandidates.Count -gt 0) {
        $auditedNames = @($script:AllAuditResults | ForEach-Object { [string]$_.VMName })
        $clusterVmNames = @()
        try { $clusterVmNames = @(Get-ClusterGroup -Cluster $clusterForName -ErrorAction Stop | Where-Object { $_.GroupType -eq 'VirtualMachine' } | ForEach-Object { [string]$_.Name }) } catch { }
        foreach ($cand in $script:DiscoveredCandidates) {
            if (-not $cand.Name) { continue }
            $match = $clusterVmNames | Where-Object { $_ -eq $cand.Name } | Select-Object -First 1
            if (-not $match) { continue }
            if ($auditedNames -contains $match) { continue }
            if ($script:ExcludedVMNames.Count -gt 0 -and $script:ExcludedVMNames.Contains($match)) { continue }
            [void]$validatedDiscoveredCandidates.Add([pscustomobject]@{ Name = $match; Reason = [string]$cand.Reason })
        }
    }

    $discoverySelection = Select-DiscoveredVMsForAudit -Candidates $validatedDiscoveredCandidates.ToArray() -Maximum $MaxDiscoveredVMs
    $toAudit = @(if ($IncludeDiscoveredVMs) { @($discoverySelection.Audit) } else { @() })
    $discoveredVMs = if ($IncludeDiscoveredVMs) { @($discoverySelection.Deferred) } else { @($discoverySelection.Audit) }
    $discoverySummary = [pscustomobject]@{
        EligibleCount = [int]$discoverySelection.EligibleCount
        AuditedCount  = @($toAudit).Count
        DeferredCount = if ($IncludeDiscoveredVMs) { @($discoverySelection.Deferred).Count } else { 0 }
        Cap           = $discoverySelection.Cap
    }
    $discoveryCapDetail = if ($null -eq $discoverySummary.Cap) { 'None' } else { [string]$discoverySummary.Cap }
    Add-TelemetryEntry -Step '1.20' -Phase 'Discovered VM validation and selection' `
        -Detail ("Evidence={0}; Eligible={1}; Selected={2}; Deferred={3}; Cap={4}" -f $validatedDiscoveredCandidates.Count, $discoverySummary.EligibleCount, $discoverySummary.AuditedCount, $discoverySummary.DeferredCount, $discoveryCapDetail) `
        -StartUtc $discoverySelectionStart -EndUtc (Get-TelemetryNow)

    # Optionally auto-audit the selected VMs. Discovery expansion remains NON-recursive. With no
    # -MaxDiscoveredVMs value, every eligible discovery is selected.
    if ($IncludeDiscoveredVMs -and $toAudit.Count -gt 0) {
        $script:CurrentVMSource = 'Discovered'
        try {
            Write-AuditStatus ""
            $capDisplay = if ($null -eq $discoverySummary.Cap) { 'None' } else { [string]$discoverySummary.Cap }
            Write-AuditStatus ("  Discovery: {0} eligible; auditing {1}; deferred {2}; cap {3}." -f $discoverySummary.EligibleCount, $discoverySummary.AuditedCount, $discoverySummary.DeferredCount, $capDisplay) -ForegroundColor Cyan
            $discoveredDiagnosticNodes = @($toAudit | ForEach-Object {
                if ($script:GroupOwnerByVm -and $script:GroupOwnerByVm.ContainsKey([string]$_.Name)) {
                    [string]$script:GroupOwnerByVm[[string]$_.Name]
                }
            } | Where-Object { $_ } | Sort-Object -Unique)
            if ($discoveredDiagnosticNodes.Count -gt 0) {
                try {
                    $prefetchRun = Initialize-NodeDiagnosticPrefetch -Nodes $discoveredDiagnosticNodes `
                        -LocalNode $env:COMPUTERNAME -OutputPath $script:RunFolder -LookbackHours $EventLookbackHours `
                        -ConcernIds $WorkerEventIds -ContextIds $ContextEventIds -CodePatterns $ErrorCodePatterns `
                        -SkipEvents:$SkipWorkerEvents
                    if (@($prefetchRun.Nodes).Count -gt 0) { [void]$script:NodeDiagnosticPrefetchRuns.Add($prefetchRun) }
                } catch {
                    Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Initialize discovered-node diagnostic prefetch' `
                        -Scope ("Nodes={0}; FallingBack=LazyCollection" -f $discoveredDiagnosticNodes.Count)
                    Write-Alert ("  Discovered-node diagnostic prefetch could not initialize: {0}. The audit will use lazy per-node collection for missing evidence." -f $_.Exception.Message) -Level Warning
                }
            }
            foreach ($dv in $toAudit) {
                $ds = Invoke-VMCheckpointAudit -VMName $dv.Name -Cluster $Cluster -OutputPath $script:RunFolder -StaleHours $StaleHours `
                    -SkipWorkerEvents:$SkipWorkerEvents -EventLookbackHours $EventLookbackHours `
                    -WorkerEventIds $WorkerEventIds -ContextEventIds $ContextEventIds -ErrorCodePatterns $ErrorCodePatterns `
                    -SkipAnalyticCheck:$SkipAnalyticCheck
                foreach ($s in @($ds)) {
                    if ($s -and $s.PSObject.Properties['Recommendation']) { Add-Member -InputObject $s -NotePropertyName Source -NotePropertyValue 'Discovered' -Force; [void]$script:AllAuditResults.Add($s) }
                }
            }
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

    $nodeEventContext = @($script:NodeEventCache.GetEnumerator() | Sort-Object Name | ForEach-Object {
        $nodeEventSnapshot = $_.Value
        [pscustomobject][ordered]@{
            Node          = if ($nodeEventSnapshot.PSObject.Properties['Node']) { [string]$nodeEventSnapshot.Node } else { ([string]$_.Key -split '\|', 2)[0] }
            Status        = if ($nodeEventSnapshot.PSObject.Properties['Status']) { [string]$nodeEventSnapshot.Status } else { 'Unavailable' }
            Error         = if ($nodeEventSnapshot.PSObject.Properties['Error']) { [string]$nodeEventSnapshot.Error } else { '' }
            AttemptedUtc  = if ($nodeEventSnapshot.PSObject.Properties['AttemptedUtc']) { $nodeEventSnapshot.AttemptedUtc } else { $null }
            AttemptCount  = if ($nodeEventSnapshot.PSObject.Properties['AttemptCount']) { [int]$nodeEventSnapshot.AttemptCount } else { 0 }
            ChannelStatus = if ($nodeEventSnapshot.PSObject.Properties['ChannelStatus']) { @($nodeEventSnapshot.ChannelStatus) } else { @() }
            Events        = if ($nodeEventSnapshot.PSObject.Properties['Rows']) { @($nodeEventSnapshot.Rows) } else { @() }
        }
    })

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
                -ClusterName $clusterForName -GeneratedUtc ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ssZ')) `
                -DiscoveredVMs $discoveredVMs -DiscoverySummary $discoverySummary `
                -StorageHealth $script:ClusterStorageHealth -HousekeepingFindings $script:HousekeepingFindings.ToArray() `
                -NodeEventContext $nodeEventContext `
                -IncludeDiscoveredVMs:$IncludeDiscoveredVMs `
                -DebugLogAvailable:($script:DebugLogPath -and (Test-Path -LiteralPath $script:DebugLogPath)) `
                -ScriptVersion $script:ScriptVersion `
                -ReportGenerationTime $genTimeText `
                -ClusterNodeCount $clusterNodeCountForHtml -ClusterCsvCount $clusterCsvCountForHtml
            [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))
            Add-TelemetryEntry -Step '1.40' -Phase 'HTML report render + write' -Detail (Split-Path $htmlPath -Leaf) -StartUtc $htmlStart -EndUtc (Get-TelemetryNow)
            $htmlWritten = $htmlPath
            Write-AuditReportLine ""
            Write-AuditReportLine "HTML fleet report written to: $htmlPath"
        } catch {
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Write HTML fleet report' -Scope ("Cluster={0}; File={1}" -f $clusterForName, $htmlPath)
            Write-Alert "  WARNING: could not write the HTML fleet report: $($_.Exception.Message)" -Level Warning
        }
    }

    # v0.2.15: MANDATORY performance telemetry. Write the structured per-step timing breakdown as JSON
    # to the run folder BEFORE the zip is built, so it is bundled into the results zip. It is for our
    # own future performance tuning; it is deliberately NOT surfaced in the HTML report. Only written
    # when a run folder exists (i.e. -OutputPath was supplied). Non-fatal on failure.
    $telWritten = $null
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
            $prefetchNodeResults = @($script:NodeDiagnosticPrefetchRuns | ForEach-Object { $_.Nodes })
            $prefetchModes = @($script:NodeDiagnosticPrefetchRuns | ForEach-Object { [string]$_.ExecutionMode } | Where-Object { $_ } | Sort-Object -Unique)
            $telDoc  = [ordered]@{
                Tool               = 'Get-HyperVVMCheckpointHealth'
                ScriptVersion      = $script:ScriptVersion
                Cluster            = $telClusterField
                Anonymized         = [bool]$AnonymizeTelemetry
                GeneratedUtc       = (Get-TelemetryNow).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
                VMsProcessed       = $script:AllAuditResults.Count
                VMsFullyAssessed   = @($script:AllAuditResults | Where-Object { $_.Recommendation -notin @('NOT FOUND', 'ERROR') }).Count
                # Retained for telemetry consumers created before 0.2.22; equivalent to VMsProcessed.
                VMsAudited         = $script:AllAuditResults.Count
                OutcomeHoldState   = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'HOLD STATE' }).Count
                OutcomeInvestigate = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'INVESTIGATE' }).Count
                OutcomeOk          = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'OK' }).Count
                OutcomeNotFound    = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'NOT FOUND' }).Count
                OutcomeError       = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'ERROR' }).Count
                DiscoveryEligible  = $discoverySummary.EligibleCount
                DiscoveryAudited   = $discoverySummary.AuditedCount
                DiscoveryDeferred  = $discoverySummary.DeferredCount
                DiscoveryCap       = $discoverySummary.Cap
                ClusterNodes       = $telNodeCount
                ClusterCsvs        = $telCsvCount
                EventLookbackHours = $EventLookbackHours
                SkipWorkerEvents   = [bool]$SkipWorkerEvents
                SkipStorageHealth  = [bool]$SkipStorageHealth
                NodePrefetchRuns   = $script:NodeDiagnosticPrefetchRuns.Count
                NodePrefetchMode   = if ($prefetchModes.Count -gt 0) { $prefetchModes -join ',' } else { 'NotRun' }
                NodePrefetchThrottle = if ($script:NodeDiagnosticPrefetchRuns.Count -gt 0) { [int](($script:NodeDiagnosticPrefetchRuns | Measure-Object ThrottleLimit -Maximum).Maximum) } else { 0 }
                NodePrefetchNodes  = @($prefetchNodeResults | ForEach-Object { [string]$_.Node } | Where-Object { $_ } | Sort-Object -Unique).Count
                NodePrefetchFailed = @($prefetchNodeResults | Where-Object { -not $_.Complete }).Count
                TotalRunSeconds    = [math]::Round($script:RunStopwatch.Elapsed.TotalSeconds, 3)
                StepNumbering      = '1 = whole run; 1.05.15 = all-cluster VM selection for -ProcessAllVMs; 1.07 = cluster virtual-disk inventory preflight total; 1.07.10 = ownership inventory total; 1.07.10.10 = ownership worker timing per node; 1.07.10.20 = ownership worker coordination; 1.07.20 = file inventory; 1.08.10 = bounded node diagnostic prefetch coordination; 1.08.10.10 = event prefetch worker per node; 1.08.10.20 = VSS prefetch worker per node; 1.10 = per-VM audit total (repeats per VM); 1.10.NN = per-VM section (NN two-digit, gaps of 5); 1.10.20.10 = VHD chain collection+validation; 1.10.35.10-.40 = ownership/file inventory and housekeeping classification; 1.10.40.05 = Replica relationship+monitoring collection; 1.10.40.10 = typed replication assessment; 1.10.45.10 = HRL collection+assessment; 1.10.50.10 = lazy node event-log scan fallback; 1.10.50.20 = per-VM event attribution; 1.10.50.30 = operation recovery correlation; 1.10.55.10 = Analytic channel status; 1.10.60.10 = lazy VSS writer scan fallback; 1.10.65.10 = attached-layer+snapshot staleness assessment; 1.10.70 = historic event correlation (repeats by search window); 1.10.75 = findings / RESULT render + result-object build; 1.10.80 = collection state consistency section; 1.10.80.10 = collection state consistency recheck; 1.10.85 = per-VM text report write; 1.20 = discovered VM validation+selection; 1.30 = storage-health snapshot; 1.40 = HTML render+write. The results ZIP is timed on the console because this JSON is written before and bundled into it. Step numbers are HIERARCHICAL / NESTED: parent and child durations overlap, so do NOT sum DurationSec across levels. Order is completion order; sort by StartUtc for a true timeline. Step numbers intentionally repeat per VM - use Detail to distinguish them.'
                Steps              = $telSteps
            }
            $telJson = $telDoc | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($telPath, $telJson, (New-Object System.Text.UTF8Encoding($false)))
            $telWritten = $telPath
            Write-AuditReportLine "Performance telemetry written to: $telPath"
        } catch {
            Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Write performance telemetry' -Scope ("Cluster={0}; RunFolder={1}" -f $clusterForName, $script:RunFolder)
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
                # v0.2.16: time the zip on its console line. It CANNOT go in the telemetry JSON step list
                # because that JSON is written BEFORE the zip (so it is bundled INTO the zip) - a 1.50
                # entry would be recorded after the file was already serialised and would be lost. The
                # console elapsed is the practical way to see the (usually small) Compress-Archive cost.
                $zipStart = Get-TelemetryNow
                Compress-Archive -Path (Join-Path $script:RunFolder '*') -DestinationPath $zipPath -Force
                $zipSecs  = [math]::Round(((Get-TelemetryNow) - $zipStart).TotalSeconds, 1)
                $zipWritten = $zipPath
                Write-AuditReportLine ("Results bundled to zip:       {0}  (took {1}s)" -f $zipPath, $zipSecs)
            } catch {
                Add-AuditDiagnostic -ErrorRecord $_ -Operation 'Create results ZIP' -Scope ("Cluster={0}; File={1}" -f $clusterForName, $zipPath)
                Write-Alert "  WARNING: could not create the results zip: $($_.Exception.Message)" -Level Warning
            }
        } else {
            Write-Alert "  NOTE: no results .zip was created - it requires -OutputPath (there was nothing on disk to bundle)." -Level Info
        }
    }

    # Guidance: how to consume the portable report.
    if ($zipWritten) {
        Write-AuditReportLine ""
        Write-AuditReportLine "  To review: copy the zip file to a device with a web browser, unzip it, and open the"
        Write-AuditReportLine "  '$htmlFileName' file (titled 'Hyper-V VM Checkpoint Health Audit')."
    } elseif ($htmlWritten) {
        Write-AuditReportLine ""
        Write-AuditReportLine "  To review: open '$htmlFileName' (titled 'Hyper-V VM Checkpoint Health Audit') in a web browser."
    }

    if ($script:DebugLogPath -and (Test-Path -LiteralPath $script:DebugLogPath)) {
        Write-Alert "  Detailed failure diagnostics written to: $script:DebugLogPath" -Level Warning
        Write-Alert "  SENSITIVE DATA: review the debug log before sharing it through an approved secure channel." -Level Warning
        Write-AuditReportLine "  Usage documentation: https://aka.ms/Get-HyperVVMCheckpointHealth#readme"
        Write-AuditReportLine "  Feedback / GitHub issue: https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback"
    }

    # Surface any high-risk VMs discovered in event data but not audited (always shown, even in quiet).
    if ($null -ne $discoveredVMs -and $discoveredVMs.Count -gt 0) {
        Write-AuditStatus ""
        $notAuditedHeading = if ($IncludeDiscoveredVMs) { "  {0} discovered VM(s) were NOT audited because the explicit discovery cap was reached:" } else { "  {0} high-risk VM(s) were referenced in event data but were NOT audited:" }
        Write-AuditStatus ($notAuditedHeading -f $discoveredVMs.Count) -ForegroundColor Yellow
        foreach ($dv in $discoveredVMs) {
            $reasonText = if ($dv.PSObject.Properties['Reasons'] -and @($dv.Reasons).Count -gt 0) { @($dv.Reasons) -join '; ' } else { [string]$dv.Reason }
            Write-AuditStatus ("    - {0}  ({1})" -f $dv.Name, $reasonText) -ForegroundColor Yellow
        }
        $dvList = (@($discoveredVMs | ForEach-Object { "'{0}'" -f $_.Name }) -join ',')
        $clusterArg = if ($Cluster) { " -Cluster '$Cluster'" } else { '' }
        Write-AuditStatus "  Recommend auditing them, e.g.:" -ForegroundColor Yellow
        Write-AuditStatus ("    Get-HyperVVMCheckpointHealth -VMName $dvList$clusterArg -OutputPath <folder>")
        if (-not $IncludeDiscoveredVMs) {
            Write-AuditStatus "  (or re-run with -IncludeDiscoveredVMs to audit every eligible discovery automatically)."
        }
    }

    # Option C: repeat the 'nothing saved' warning at the END, so it is the last thing the operator
    # sees after a long run (the up-front warning may have scrolled off the console).
    if (-not $OutputPath) {
        Write-Alert "WARNING: no report was saved (no -OutputPath) - console output only. Re-run with -OutputPath <folder>" -Level Warning
        Write-Alert "         to capture the .txt report and events .csv to attach to a backup-vendor / Microsoft (CSS) case." -Level Warning
    }

    # Finalize automation output only after every VM, discovery pass, run-level assessment, and artifact
    # write has completed. This keeps -PassThru homogeneous (one object per VM) while giving every row
    # the same complete run snapshot. The snapshot deliberately does not contain Results, avoiding a
    # circular object graph; the pipeline itself is the result collection.
    if ($PassThru) {
        $runArtifactFiles = if ($script:RunFolder -and (Test-Path -LiteralPath $script:RunFolder)) {
            @(Get-ChildItem -LiteralPath $script:RunFolder -File | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; LengthBytes = [long]$_.Length; LastWriteTimeUtc = $_.LastWriteTimeUtc }
            })
        } else {
            @()
        }
        $eligibleCandidates = @($discoverySelection.Audit; $discoverySelection.Deferred)
        $runData = [pscustomobject][ordered]@{
            Tool                  = 'Get-HyperVVMCheckpointHealth'
            ScriptVersion         = [string]$script:ScriptVersion
            Cluster               = [string]$clusterForName
            GeneratedUtc          = (Get-TelemetryNow).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
            TotalRunSeconds       = [math]::Round($script:RunStopwatch.Elapsed.TotalSeconds, 3)
            ClusterNodeCount      = if ($script:ClusterNodesCache) { @($script:ClusterNodesCache).Count } else { 0 }
            ClusterCsvCount       = if ($script:ClusterCsvCache) { @($script:ClusterCsvCache).Count } else { 0 }
            PolicySource          = [string]$script:CheckpointHealthPolicy.Source
            Parameters            = [pscustomobject][ordered]@{
                StaleHours          = [int]$StaleHours
                EventLookbackHours  = [int]$EventLookbackHours
                IncludeDiscoveredVMs = [bool]$IncludeDiscoveredVMs
                DiscoveryCap        = $MaxDiscoveredVMs
                SkipWorkerEvents    = [bool]$SkipWorkerEvents
                SkipAnalyticCheck   = [bool]$SkipAnalyticCheck
                SkipStorageHealth   = [bool]$SkipStorageHealth
                AnonymizeTelemetry  = [bool]$AnonymizeTelemetry
            }
            OutcomeSummary        = [pscustomobject][ordered]@{
                Processed   = $script:AllAuditResults.Count
                FullyAssessed = @($script:AllAuditResults | Where-Object { $_.Recommendation -notin @('NOT FOUND', 'ERROR') }).Count
                # Retained for automation consumers created before 0.2.22; equivalent to Processed.
                Audited     = $script:AllAuditResults.Count
                HoldState   = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'HOLD STATE' }).Count
                Investigate = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'INVESTIGATE' }).Count
                Ok          = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'OK' }).Count
                NotFound    = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'NOT FOUND' }).Count
                Error       = @($script:AllAuditResults | Where-Object { $_.Recommendation -eq 'ERROR' }).Count
            }
            Discovery             = [pscustomobject][ordered]@{
                Summary               = $discoverySummary
                EligibleCandidates    = $eligibleCandidates
                AuditedCandidates     = @($toAudit)
                NotAuditedCandidates  = @($discoveredVMs)
            }
            ExcludedVMs           = @($script:ExcludedMatched | Sort-Object -Unique)
            HousekeepingFindings  = $script:HousekeepingFindings.ToArray()
            StorageHealth         = $script:ClusterStorageHealth
            NodeEventContext      = $nodeEventContext
            Artifacts             = [pscustomobject][ordered]@{
                RunFolder      = [string]$script:RunFolder
                HtmlReport     = [string]$htmlWritten
                TelemetryJson  = [string]$telWritten
                DebugLog       = if ($script:DebugLogPath -and (Test-Path -LiteralPath $script:DebugLogPath)) { [string]$script:DebugLogPath } else { '' }
                Zip            = [string]$zipWritten
                Files          = $runArtifactFiles
            }
        }

        foreach ($auditResult in $script:AllAuditResults.ToArray()) {
            Complete-CheckpointHealthPassThruResult -Result $auditResult -RunData $runData
        }
    }
}
}

Export-ModuleMember -Function Get-HyperVVMCheckpointHealth
