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
    optional writes are the per-VM .txt transcript and events .csv, and only when -OutputPath is
    supplied. While running it shows a "VM X of Y" progress bar with a per-VM, per-section sub-bar.

    The human-readable report is written to the HOST (and, with -OutputPath, the .txt transcript);
    by default NOTHING is written to the pipeline. Pass -PassThru to also emit one [pscustomobject]
    per VM to the pipeline (VMName, OwningNode, Recommendation, HoldState, Has* flags, counts) for
    Where-Object / Export-Csv / fleet roll-ups.

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

.OUTPUTS
    None by default - the human-readable report goes to the host and, with -OutputPath, to a per-VM
    .txt transcript + events .csv. With -PassThru, one [pscustomobject] per VM is emitted to the
    pipeline (see the -PassThru example above for its properties).

.NOTES
    Author  : Neil Bird, Microsoft
    Created : 2026-07-10
    Updated : 2026-07-14
    Version : 0.2.0
    
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
    [int[]]$WorkerEventIds = @(3216, 3280, 18590, 18012, 12240, 15268, 16300, 19090),

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
    # ReportFile, Detail). The human-readable report always goes to the HOST (and, with -OutputPath,
    # the .txt transcript); WITHOUT -PassThru nothing is written to the pipeline, so '$x = .\script'
    # stays clean. Use -PassThru to feed Where-Object / Export-Csv / fleet roll-ups.
    [switch]$PassThru
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

# Microsoft Learn troubleshooting reference for Hyper-V VM backup / checkpoint / storage failures.
# Surfaced in the summary and problem statement so operators have an authoritative next-read. Any
# text quoted VERBATIM from this article in the report is attributed to it (title + URL below).
$script:TroubleshootTitle = 'Microsoft Learn: Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures'
$script:TroubleshootUrl   = 'https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage'

# Colour helpers. The human-readable report is ALWAYS written to the HOST (Write-Host) - never to the
# pipeline / success stream - so the pipeline stays reserved for the -PassThru per-VM summary object.
# Start-Transcript (used when -OutputPath is supplied) still captures these host lines into the .txt.
# Colour is ON by default; it auto-disables when output is redirected (so a captured/paged view stays
# readable) or when -NoColour is passed. -PassThru objects are emitted separately by the end block.
$script:UseColour = (-not $NoColour) -and (-not [Console]::IsOutputRedirected)
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

    # Optionally tee ALL console output for THIS VM to its own .txt report (via a transcript).
    # -OutputPath is treated as a FOLDER; a per-VM file is auto-named inside it.
    $transcriptStarted = $false
    $reportFile = $null
    if ($OutputPath) {
        if (-not (Test-Path -LiteralPath $OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
        }
        $safeName   = ($VMName -replace '[^\w.\-]', '_')
        # VM name FIRST in the file name so per-VM reports sort together alphabetically for humans.
        $reportFile = Join-Path $OutputPath ("{0}_VMAudit_{1}.txt" -f $safeName, [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        Start-Transcript -Path $reportFile -Force | Out-Null
        $transcriptStarted = $true
    }

    # Per-VM sub-progress (child of the "VM X of Y" bar). Auto-increments a step counter so sections
    # can be reordered without renumbering. Progress uses its own stream, so it never pollutes the
    # host report, the transcript, or the per-VM summary object returned to the pipeline.
    $script:VMSectionStep = 0
    function Show-AuditProgress {
        param([string]$Status)
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
            [string]$Detail                  = ''
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
        }
    }

    try {

    Show-AuditProgress 'Resolving cluster and VM'
    # Resolve the cluster once. With -Cluster we target that NAMED cluster (remote management from a
    # workstation with the RSAT Failover Clustering tools); without it, this host must itself BE a
    # cluster node - the Get-Cluster guard rail below fails clearly if it is not.
    try {
        if ($Cluster) {
            $ClusterName = (Get-Cluster -Name $Cluster -ErrorAction Stop).Name
        } else {
            $ClusterName = (Get-Cluster -ErrorAction Stop).Name
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
    $clusterNodes = @(Get-ClusterNode -Cluster $ClusterName -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })

    # (1a) Preferred: the VM's clustered role names the owner directly (cluster API - no hop).
    $OwningNode = $null
    $group = Get-ClusterGroup -Cluster $ClusterName -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $VMName }
    if ($group) { $OwningNode = [string]$group.OwnerNode.Name }

    # (1b) Fallback (non-clustered VM, or a role whose name differs from the VM name): loop each node
    # and ask it LOCALLY which node runs the VM. Each probe is a single hop (or local) - never double.
    if (-not $OwningNode) {
        $probeNodes = if ($clusterNodes.Count -gt 0) { $clusterNodes } else { @($LocalNode) }
        foreach ($node in $probeNodes) {
            try {
                if ($node.Split('.')[0] -eq $LocalNode) {
                    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { $OwningNode = $node; break }
                } else {
                    $found = Invoke-Command -ComputerName $node -ScriptBlock {
                        param($n) [bool](Get-VM -Name $n -ErrorAction SilentlyContinue)
                    } -ArgumentList $VMName -ErrorAction Stop
                    if ($found) { $OwningNode = $node; break }
                }
            } catch {
                # Could not reach this node in a single hop - keep looking on the others.
            }
        }
    }

    if (-not $OwningNode) {
        Write-Host "VM '$VMName' not found on any node of cluster '$ClusterName'."
        return (New-AuditSummary -Recommendation 'NOT FOUND' -Detail 'VM not found on any cluster node.')
    }

    # (2) Establish the owner execution context: local when this node owns the VM (zero hops), else ONE
    # remoting session to the owning node. Every subsequent collection call goes through Invoke-OnOwner.
    $script:OwnerIsLocal = ($OwningNode.Split('.')[0] -eq $LocalNode)
    $script:OwnerSession = $null
    if (-not $script:OwnerIsLocal) {
        try {
            $script:OwnerSession = New-PSSession -ComputerName $OwningNode -ErrorAction Stop
        } catch {
            Write-Alert "  ERROR: could not open a remoting session to owning node '$OwningNode': $($_.Exception.Message)" -Level Critical
            Write-Alert "  TIP: run this script directly ON the owning node (interactive / SConfig logon), or from a" -Level Critical
            Write-Alert "       host that can reach it in a SINGLE hop. Reaching another node from inside a remoting" -Level Critical
            Write-Alert "       session is a 'double hop' and is blocked unless CredSSP/delegation is configured." -Level Critical
            return (New-AuditSummary -Recommendation 'ERROR' -Owner $OwningNode -Detail 'Could not open remoting session to owning node.')
        }
    }

    # Core VM properties, collected in the owner context as plain values (safe to render / serialize).
    # Also gathers the Hyper-V host's supported VM configuration versions (Get-VMHostSupportedVersion,
    # read-only) so we can compare the VM's version to the latest the owning node supports.
    $vm = Invoke-OnOwner -ScriptBlock {
        param($n)
        $v = Get-VM -Name $n -ErrorAction SilentlyContinue
        if (-not $v) { return $null }
        $sv = Get-VMHostSupportedVersion -ErrorAction SilentlyContinue
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
            HostSupportedVersions       = @($sv | ForEach-Object { [string]$_.Version })
        }
    } -ArgumentList $VMName
    if (-not $vm) {
        Write-Host "VM '$VMName' could not be read on owning node '$OwningNode'."
        return (New-AuditSummary -Recommendation 'ERROR' -Owner $OwningNode -Detail 'VM object could not be read on the owning node.')
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
    Show-AuditProgress 'Reading cluster role'
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
    Show-AuditProgress 'Reading VM configuration (.vmcx)'
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
    # Nodes whose Hyper-V-VMMS/Analytic channel is NOT actively enabled (disabled, or 'not found').
    # Populated by the Analytic section below and surfaced as a TIP in the RESULT block so the operator
    # can choose to enable it for extra diagnostic detail on the NEXT occurrence (it is easily missed
    # mid-report). Stays empty when -SkipAnalyticCheck is used, so no TIP is shown in that case.
    $analyticNodesNeedEnable = @()

    # Enumerate each attached disk and resolve its full differencing chain (top .avhdx -> ... -> base).
    # This runs in ONE owner-context call (single hop for a remote owner) and flattens the VhdType enum
    # to a string on the owner, so the downstream 'Differencing' comparisons are robust after transport.
    Show-AuditProgress 'Enumerating attached disks and differencing chains'
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
    Show-AuditProgress 'Checking Cluster Shared Volume free space'
    Write-Section "Cluster Shared Volume Free Space (hosting this VM's disks):"
    try {
        $diskFolders = @($allChainPaths | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique)
        $allCsv = Get-ClusterSharedVolume -Cluster $ClusterName -ErrorAction Stop
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
    } catch {
        Write-Host "  Could not query Cluster Shared Volumes: $($_.Exception.Message)"
        Write-Host ""
    }

    # Named checkpoints on the VM - maps .avhdx files to checkpoints such as 'Initial Replica'.
    # Collected in the owner context (single hop for a remote owner), including each checkpoint's disk
    # folders so the orphan / .hrl scans below know where to look.
    Show-AuditProgress 'Enumerating checkpoints'
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
    Show-AuditProgress 'Scanning for orphaned .avhdx files'
    Write-Section "Orphaned .avhdx Files (present on disk but not attached to the VM):"
    if ($vhdFolders) {
        try {
            $onDiskAvhdx = @(Invoke-OnOwner -ScriptBlock {
                param($folders)
                $folders | ForEach-Object {
                    Get-ChildItem -LiteralPath $_ -Filter '*.avhdx' -File -ErrorAction SilentlyContinue
                } | ForEach-Object {
                    [pscustomobject]@{ Name = [string]$_.Name; FullName = [string]$_.FullName; Length = [long]$_.Length; LastWriteTimeUtc = $_.LastWriteTimeUtc }
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
            $orphans | Select-Object `
                Name,
                @{N='SizeGB';E={ [math]::Round($_.Length / 1GB, 2) }},
                @{N='LastWrite (UTC)';E={ $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }},
                FullName | Format-Table -AutoSize -Wrap | Out-Indented
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
    Show-AuditProgress 'Checking Hyper-V Replica status'
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
    Show-AuditProgress 'Scanning Replica change logs (.hrl)'
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
    # Matching by event ID is node-wide on purpose: some of these events carry a blank or different VM GUID.
    # Runs by default; use -SkipWorkerEvents to opt out.
    $eventConcernCount = 0
    $concernEvents     = @()
    $eventsCsvName     = $null
    if (-not $SkipWorkerEvents) {
        Show-AuditProgress 'Scanning Hyper-V Worker/VMMS event logs'
        Write-Section "Hyper-V Worker/VMMS Admin Events (last $EventLookbackHours h on $OwningNode):"
        # Match on the VM GUID as well as the name - Worker/VMMS messages reference the
        # 'Virtual machine ID <GUID>', which is far more reliable than the long friendly name.
        $vmId = [string]$vm.VMId
        try {
            $workerEvents = @(Invoke-OnOwner -ScriptBlock {
                param($lookbackHours, $vmName, $vmId, $concernIds, $contextIds, $codePatterns)
                $start  = (Get-Date).AddHours(-$lookbackHours)
                # Single alternation regex built from the (escaped) HRESULT strings:
                $codeRx = ($codePatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
                Get-WinEvent -FilterHashtable @{
                    LogName   = 'Microsoft-Windows-Hyper-V-Worker-Admin', 'Microsoft-Windows-Hyper-V-VMMS-Admin'
                    StartTime = $start
                } -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Message -match [regex]::Escape($vmName) -or
                    $_.Message -match [regex]::Escape($vmId)   -or
                    ($codeRx -and $_.Message -match $codeRx)   -or
                    ($concernIds -contains $_.Id)              -or
                    ($contextIds -contains $_.Id)
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
            } -ArgumentList $EventLookbackHours, $VMName, $vmId, $WorkerEventIds, $ContextEventIds, $ErrorCodePatterns)
        } catch {
            $workerEvents = $null
            Write-Alert "  Could not read event logs on '$OwningNode': $($_.Exception.Message)" -Level Warning
        }

        if ($workerEvents -and $workerEvents.Count -gt 0) {
            $workerEvents      = @($workerEvents | Sort-Object 'Time (UTC)')
            $concernEvents     = @($workerEvents | Where-Object { $_.Concern -eq 'YES' })
            $eventConcernCount = $concernEvents.Count

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
            Write-Host ("  {0} event(s) matched ({1} shown after collapsing duplicates); {2} flagged as a Concern." -f $workerEvents.Count, $displayRows.Count, $eventConcernCount)
            Write-Host  "  Informational lifecycle events (VM started, checkpoint completed, merge started / finished OK)"
            Write-Host  "  are listed for context but NOT flagged as a Concern."

            # Export the FULL event detail to CSV (no truncation) when an -OutputPath was supplied.
            # The file name leads with the VM name and the UTC date (yyyy-MM-dd) so it sorts with the report.
            if ($OutputPath) {
                $csvFolder     = Split-Path -Parent $reportFile
                $eventsCsvName = "{0}_Events_{1}.csv" -f ($VMName -replace '[^\w.\-]', '_'), [DateTime]::UtcNow.ToString('yyyy-MM-dd')
                $csvPath       = Join-Path $csvFolder $eventsCsvName
                $workerEvents | Select-Object 'Time (UTC)', Id, Level, Log, Concern, FullMessage |
                    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
                Write-Host ""
                Write-Host "  Full, untruncated event messages exported to CSV: $csvPath"
                Write-Host "  (Use that CSV rather than the truncated console table above - it has the complete text.)"
            }
        } else {
            Write-Host "  No matching events in the last $EventLookbackHours hours."
            Write-Host ""
        }
    }

    # Per-node check: is the Hyper-V-VMMS/Analytic channel enabled? It is the only place the internal
    # per-disk .vmcx revert failure ('Cannot revert configuration info for AVHD') is traced, but it is
    # DISABLED by default. Report each cluster node's state and, where disabled, print the command the
    # operator can choose to run (elevated, on that node) to enable it.
    if (-not $SkipAnalyticCheck) {
        Show-AuditProgress 'Checking Analytic channel state'
        Write-Section "Hyper-V-VMMS/Analytic Channel (per node):"
        $analyticLog = 'Microsoft-Windows-Hyper-V-VMMS/Analytic'
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
                Write-Host "      wevtutil sl $analyticLog /e:true"
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
    Show-AuditProgress 'Checking VSS writer health'
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
    Show-AuditProgress 'Building summary'
    $totalCheckpoints = @($diskReports | Measure-Object -Property CheckpointCount -Sum).Sum
    if (-not $totalCheckpoints) { $totalCheckpoints = 0 }
    $hasCheckpoints   = $totalCheckpoints -gt 0
    # Count named checkpoints older than the stale threshold:
    $staleCheckpoints = @($checkpoints | Where-Object { ([DateTime]::UtcNow - $_.CreationTimeUtc).TotalHours -ge $StaleHours })

    # Severity: distinguish a CONFIRMED checkpoint fork-commit / merge-failure signature (a genuine
    # data-loss risk if the VM is migrated / restarted) from symptom-only noise (e.g. repeated 15268
    # or an aged backup checkpoint), which usually points to a stalled / failed backup or an unhealthy
    # VSS writer rather than on-disk chain corruption.
    $forkCommitIds    = @(3216, 18590)
    $forkCommitRx     = (@('0x80048102', '0x800480BD', '0x800480BC', '0x800703EE') | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $hasForkSignature = (@($concernEvents | Where-Object { ($forkCommitIds -contains [int]$_.Id) -or ($_.FullMessage -match $forkCommitRx) }).Count -gt 0)
    $holdState        = ($hasForkSignature -and ($hasCheckpoints -or $staleCheckpoints.Count -gt 0))
    $investigate      = ((-not $holdState) -and (($staleCheckpoints.Count -gt 0) -or ($eventConcernCount -gt 0) -or ($vssUnhealthy.Count -gt 0)))
    $concernIdSummary = (@($concernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object { "{0} x{1}" -f $_.Name, $_.Count }) -join ', ')

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
    if ($eventConcernCount -gt 0) {
        Write-Host ""
        Write-Host ("  {0} concerning Hyper-V event(s) were found on {1} in the last {2} hours, by event ID:" -f $eventConcernCount, $OwningNode, $EventLookbackHours)
        $concernEvents | Group-Object Id | Sort-Object { [int]$_.Name } | ForEach-Object {
            $times = @($_.Group.'Time (UTC)' | Sort-Object)
            Write-Host ("    - ID {0}  x{1}   (first {2} UTC, last {3} UTC)" -f $_.Name, $_.Count, $times[0], $times[-1])
        }
    }
    if ($vssUnhealthy.Count -gt 0) {
        Write-Host ""
        Write-Host ("  {0} VSS writer(s) are not healthy: {1}" -f $vssUnhealthy.Count, ((@($vssUnhealthy | ForEach-Object { $_.Writer })) -join ', '))
        Write-Host  "  Unhealthy VSS writers commonly block Hyper-V checkpoint / backup operations."
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
        if ($eventConcernCount -gt 0) {
            Write-Host ("    - {0} concerning Hyper-V event(s) [{1}] on {2} in the last {3}h (see the events section above)." -f $eventConcernCount, $concernIdSummary, $OwningNode, $EventLookbackHours)
        }
        if ($vssUnhealthy.Count -gt 0) {
            Write-Host ("    - {0} unhealthy VSS writer(s) (see the VSS Writer Health section above)." -f $vssUnhealthy.Count)
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
    if ($eventConcernCount -gt 0) {
        Write-Alert "  WARNING: $eventConcernCount concerning Hyper-V event(s) found (see the Concern=YES rows above)." -Level Warning
    }
    if ($holdState) {
        Write-Host ""
        Write-Alert "  HOLD STATE (data-loss risk): a checkpoint fork-commit / merge-failure signature AND" -Level Critical
        Write-Alert "  unmerged differencing disk(s) are present together." -Level Critical
        Write-Alert ("  Why flagged: {0} active differencing (.avhdx) layer(s); fork-commit signature in event(s) [{1}]; {2} checkpoint(s) >= {3}h old." -f $totalCheckpoints, $concernIdSummary, $staleCheckpoints.Count, $StaleHours) -Level Critical
        Write-Alert "  See the PROBLEM STATEMENT section above for the recommended next steps and a copy/paste case summary." -Level Critical
    } elseif ($investigate) {
        Write-Host ""
        Write-Alert "  INVESTIGATE: concern signals are present, but the specific checkpoint fork-commit signature" -Level Warning
        Write-Alert "  was NOT observed (likely a stalled / failed backup checkpoint or an unhealthy VSS writer)." -Level Warning
        Write-Alert ("  Why flagged: {0} concerning event(s) [{1}]; {2} checkpoint(s) >= {3}h old; {4} unhealthy VSS writer(s)." -f $eventConcernCount, $concernIdSummary, $staleCheckpoints.Count, $StaleHours, $vssUnhealthy.Count) -Level Warning
        Write-Alert "  See the FINDINGS TO INVESTIGATE section above for the suggested next steps (backup-team triage first; no Microsoft case needed yet)." -Level Warning
    }
    # Diagnostic-coverage TIP (independent of the verdict): if the Hyper-V-VMMS/Analytic channel is not
    # enabled on one or more nodes, say so HERE in the RESULT block - mid-report it is easily missed.
    if ($analyticNodesNeedEnable.Count -gt 0) {
        Write-Host ""
        Write-Alert ("  TIP: the Hyper-V-VMMS/Analytic channel is not enabled on: {0}." -f ($analyticNodesNeedEnable -join ', ')) -Level Info
        Write-Alert "  It is the only place the internal per-disk .vmcx revert ('Cannot revert configuration info for AVHD') is" -Level Info
        Write-Alert "  traced. Enabling it now (elevated, per node) captures that extra detail for the NEXT occurrence:" -Level Info
        Write-Alert "      wevtutil sl Microsoft-Windows-Hyper-V-VMMS/Analytic /e:true" -Level Info
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
    $summaryArgs = @{
        Recommendation          = $recommendation
        HoldState               = $holdState
        HasAttachedCheckpoints  = $hasCheckpoints
        HasStaleCheckpoints     = ($staleCheckpoints.Count -gt 0)
        HasOrphanedCheckpoints  = $hasOrphans
        AttachedCheckpointCount = [int]$totalCheckpoints
        StaleCheckpointCount    = $staleCheckpoints.Count
        ConcernEventCount       = $eventConcernCount
        Owner                   = $OwningNode
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
        # Close the single remoting session to the owning node (if one was opened for this VM).
        if ($script:OwnerSession) {
            Remove-PSSession -Session $script:OwnerSession -ErrorAction SilentlyContinue
            $script:OwnerSession = $null
        }
        if ($transcriptStarted) {
            Stop-Transcript | Out-Null
            Write-Host "Report saved to: $reportFile"
        }
    }
}

# Collect all requested VMs (works for both the -VMName array and pipeline input) so the parent
# progress bar can show an accurate "VM X of Y"; $VMSectionTotal drives the per-VM sub-progress %.
$script:PendingVMNames = [System.Collections.Generic.List[string]]::new()
$script:VMSectionTotal = 13

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

        # Defer the actual audit to the end block, where the true total is known (accurate X of Y).
        $script:PendingVMNames.Add($singleVMName)
    }
}

# Audit each collected VM. Runs in the end block so the parent progress bar knows the total count.
end {
    $vmTotal = $script:PendingVMNames.Count
    if ($vmTotal -eq 0) { return }
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

        # Emit the per-VM result object to the pipeline ONLY when -PassThru was requested; otherwise the
        # run is 'report to host / files' only and the pipeline stays empty.
        if ($PassThru) { $vmSummary }

        # Clear this VM's sub-progress bar before moving to the next VM.
        Write-Progress -Id 2 -ParentId 1 -Activity ("Auditing VM: {0}" -f $name) -Completed
    }
    Write-Progress -Id 1 -Activity 'Hyper-V VM checkpoint / differencing-disk audit' -Completed

    # Option C: repeat the 'nothing saved' warning at the END, so it is the last thing the operator
    # sees after a long run (the up-front warning may have scrolled off the console).
    if (-not $OutputPath) {
        Write-Alert "WARNING: no report was saved (no -OutputPath) - console output only. Re-run with -OutputPath <folder>" -Level Warning
        Write-Alert "         to capture the .txt report and events .csv to attach to a backup-vendor / Microsoft (CSS) case." -Level Warning
    }
}