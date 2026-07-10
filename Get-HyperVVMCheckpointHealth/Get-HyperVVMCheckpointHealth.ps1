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
    .\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-VM -CimSession (Get-Cluster).Name) -OutputPath 'C:\Temp\Reports'

    Audits every VM on the cluster by passing the VM OBJECTS; writes a per-VM .txt transcript and events .csv.

.EXAMPLE
    .\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-VM -CimSession (Get-Cluster).Name).Name -OutputPath 'C:\Temp\Reports'

    Audits every VM on the cluster by passing the VM NAMES.

.EXAMPLE
    Get-VM -CimSession (Get-Cluster).Name | .\Get-HyperVVMCheckpointHealth.ps1 -OutputPath 'C:\Temp\Reports'

    Pipes the VM objects straight in.

.NOTES
    Author : Neil Bird, Microsoft
    Date   : July 2026
    Requires: PowerShell 5.1+, the Hyper-V and FailoverClusters modules, rights to query the cluster /
              Hyper-V / the nodes' event logs, and WinRM (Invoke-Command) to the owning and cluster nodes.

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

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
    [ValidateNotNullOrEmpty()]
    [Alias('Name','VM')]
    # Accepts VM name(s) OR VM objects (from Get-VM). Objects are normalized to their .Name in the
    # process block, so -VMName $VMs (objects), -VMName $VMs.Name (strings), and 'Get-VM | ...' all work.
    [object[]]$VMName,

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

    # How far back to look when the event scan runs (default 96 hours = 4 days).
    [ValidateRange(1, 720)]
    [int]$EventLookbackHours = 96,

    # Event IDs to explicitly flag as a concern. Defaults cover the checkpoint fork-commit /
    # merge failure mode on Hyper-V-Worker/Admin and Hyper-V-VMMS/Admin:
    #   3216  Worker: failed to switch to new differencing disks during checkpoint (0x800703EE)
    #   3280  Worker: related checkpoint/disk error
    #   18500 VMMS:   checkpoint started      18510 VMMS: checkpoint completed
    #   18590 VMMS:   checkpoint FAILED (fork-commit, 0x80048102) - key customer-visible signature
    #   18590 Worker: guest OS bugcheck / fatal error (SAME id, different channel - the VM crashed;
    #                 e.g. after a migration reopened a rolled-back chain). Check the Log column.
    #   18012 VMMS:   checkpoint operation failed
    #   12240 VMMS:   attachment (.avhdx) not found        15268 VMMS: failed to get disk information
    #   16300 VMMS:   cannot load a virtual machine configuration
    #   19070/19090/19080 VMMS: background disk merge started / interrupted / finished
    [int[]]$WorkerEventIds = @(3216, 3280, 18500, 18510, 18590, 18012, 12240, 15268, 16300, 19070, 19080, 19090),

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
    [switch]$NoColour
)

begin {

# Colour helpers - only emit colour (via Write-Host) when enabled; otherwise fall back to
# Write-Output so redirection, transcript capture, and $var assignment behave exactly as before.
# Colour is ON by default for interactive consoles, but auto-OFF when output is redirected (so '>',
# Out-File, and '$x = .\script' stay complete) or when -NoColour is passed. The -OutputPath transcript
# still captures the (plain-text) lines regardless, so no duplicate writing / Write-HostAndFile needed.
$script:UseColour = (-not $NoColour) -and (-not [Console]::IsOutputRedirected)
function Write-Section {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Opt-in colour via -Colour; falls back to Write-Output.')]
    param([string]$Text)
    if ($script:UseColour) { Write-Host $Text -ForegroundColor Cyan } else { Write-Output $Text }
}
function Write-Alert {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Opt-in colour via -Colour; falls back to Write-Output.')]
    param([string]$Text, [ValidateSet('Info', 'Good', 'Warning', 'Critical')][string]$Level = 'Info')
    if ($script:UseColour) {
        $fg = switch ($Level) { 'Good' { 'Green' } 'Warning' { 'Yellow' } 'Critical' { 'Red' } default { 'Gray' } }
        Write-Host $Text -ForegroundColor $fg
    } else {
        Write-Output $Text
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
        for ($i = $startIdx; $i -le $endIdx; $i++) { Write-Output ('  ' + $lines[$i]) }
        Write-Output ''
    }
}

function Invoke-VMCheckpointAudit {
    [CmdletBinding()]
    param(
        [string]$VMName,
        [string]$OutputPath,
        [int]$StaleHours,
        [switch]$SkipWorkerEvents,
        [int]$EventLookbackHours,
        [int[]]$WorkerEventIds,
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
        $reportFile = Join-Path $OutputPath ("VMAudit_{0}_{1}.txt" -f $safeName, [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
        Start-Transcript -Path $reportFile -Force | Out-Null
        $transcriptStarted = $true
    }

    # Per-VM sub-progress (child of the "VM X of Y" bar). Auto-increments a step counter so sections
    # can be reordered without renumbering. Progress uses its own stream, so it never pollutes the
    # transcript, redirected output, or the returned boolean.
    $script:VMSectionStep = 0
    function Show-AuditProgress {
        param([string]$Status)
        $script:VMSectionStep++
        $pct = [math]::Min(100, [int](($script:VMSectionStep / $script:VMSectionTotal) * 100))
        Write-Progress -Id 2 -ParentId 1 -Activity ("Auditing VM: {0}" -f $VMName) -Status $Status -PercentComplete $pct
    }

    try {

    Show-AuditProgress 'Resolving cluster and VM'
    # Resolve the cluster once (friendly failure if this isn't a cluster node / the service is down):
    try {
        $ClusterName = (Get-Cluster -ErrorAction Stop).Name
    } catch {
        Write-Alert "  ERROR: could not query the failover cluster (is this a cluster node with the Cluster service running?): $($_.Exception.Message)" -Level Critical
        return
    }

    # Find the VM object, across any node in the cluster:
    $VMObject = Get-VM -CimSession $ClusterName -Name $VMName -ErrorAction SilentlyContinue
    if (-not $VMObject) {
        Write-Output "VM '$VMName' not found on the cluster: $ClusterName"
        return
    }
    # Owning Node:
    $OwningNode = $VMObject.ComputerName
    # Report header: VM name, owning node, and when this audit was run:
    Write-Output "==================================================================="
    Write-Section "  VM CheckPoint (Differencing Disk) Audit"
    Write-Output "  Cluster         : $ClusterName"
    Write-Output "  VM Name         : $VMName"
    Write-Output "  VM Id           : $($VMObject.VMId)"
    Write-Output "  Owning Node     : $OwningNode"
    # Colour the VM Status: 'Operating normally' = green, Critical/Error/Failed = red, else amber.
    $statusLevel = switch -Wildcard ("$($VMObject.Status)") { 'Operating normally' { 'Good'; break } '*Critical*' { 'Critical'; break } '*Error*' { 'Critical'; break } '*Fail*' { 'Critical'; break } default { 'Warning' } }
    Write-Alert "  VM Status       : $($VMObject.Status)" -Level $statusLevel
    # Colour the VM State: Running = green, anything containing 'Critical' = red, else amber.
    $stateLevel = switch -Wildcard ("$($VMObject.State)") { 'Running' { 'Good' } '*Critical*' { 'Critical' } default { 'Warning' } }
    Write-Alert "  VM State        : $($VMObject.State)" -Level $stateLevel
    Write-Output "  Uptime          : $($VMObject.Uptime)"
    # Auto Checkpoints: when True, Hyper-V takes a checkpoint automatically every time the VM STARTS
    # (a Client Hyper-V default; normally False on servers/clusters) - a source of 'unexpected' .avhdx
    # layers. Checkpoint Type is the style of checkpoint the VM is configured to take, which governs
    # how each checkpoint's fork is committed (the failure mode under investigation). Values annotated.
    $autoCkptNote = if ($VMObject.AutomaticCheckpointsEnabled) { 'auto checkpoint taken at every VM start' } else { 'no automatic checkpoint at VM start' }
    Write-Output "  Auto Checkpoints: $($VMObject.AutomaticCheckpointsEnabled) ($autoCkptNote)"
    $ckptTypeNote = switch ("$($VMObject.CheckpointType)") {
        'Production'     { 'app-consistent via in-guest VSS; falls back to Standard if VSS is unavailable' }
        'ProductionOnly' { 'app-consistent via in-guest VSS; FAILS if VSS is unavailable (no fallback)' }
        'Standard'       { 'captures saved memory / running state (dev/test style)' }
        'Disabled'       { 'checkpoints are not allowed on this VM' }
        default          { '' }
    }
    if ($ckptTypeNote) {
        Write-Output "  Checkpoint Type : $($VMObject.CheckpointType) ($ckptTypeNote)"
    } else {
        Write-Output "  Checkpoint Type : $($VMObject.CheckpointType)"
    }
    Write-Output "  Stale >=        : $StaleHours hours (flagged as 'YES')"
    Write-Output "  Run At          : $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
    Write-Output "==================================================================="

    # Clustered role state / current owner (should match the Owning Node above):
    Show-AuditProgress 'Reading cluster role'
    Write-Section "Cluster Role (Get-ClusterGroup):"
    $group = Get-ClusterGroup -Cluster $ClusterName -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $VMName }
    if ($group) {
        $group | Format-Table Name, State, OwnerNode -AutoSize | Out-Indented
    } else {
        Write-Output "  No clustered role named '$VMName' found (the VM may be non-clustered)."
        Write-Output ""
    }

    # VM configuration file (.vmcx) - the failure mode hinges on stale on-disk chain metadata that
    # lives in this file, so its path and last-write time are worth surfacing (a recently rewritten
    # config - e.g. right after a fork-commit revert or a migration - is a useful signal).
    $vmcxPath = Join-Path $VMObject.ConfigurationLocation ("Virtual Machines\{0}.vmcx" -f $VMObject.VMId)
    Show-AuditProgress 'Reading VM configuration (.vmcx)'
    Write-Section "VM Configuration (.vmcx):"
    try {
        $vmcxInfo = Invoke-Command -ComputerName $OwningNode -ScriptBlock { Get-Item -LiteralPath $using:vmcxPath -ErrorAction SilentlyContinue } -ErrorAction Stop
    } catch {
        $vmcxInfo = $null
        Write-Alert "  Could not reach $OwningNode to read the .vmcx (WinRM?): $($_.Exception.Message)" -Level Warning
    }
    if ($vmcxInfo) {
        Write-Output ("  Path           : {0}" -f $vmcxInfo.FullName)
        Write-Output ("  LastWrite (UTC): {0}" -f $vmcxInfo.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Output ("  Age (hrs)      : {0}" -f [math]::Round(([DateTime]::UtcNow - $vmcxInfo.LastWriteTimeUtc).TotalHours, 1))
    } else {
        Write-Output ("  Config file not found at expected path (older .xml format?): {0}" -f $vmcxPath)
    }
    Write-Output ""

    # Track every VHD path we touch, so we can later spot orphaned .avhdx files on disk:
    $allChainPaths = [System.Collections.Generic.List[string]]::new()

    # Enumerate each attached disk and resolve its full differencing chain (top .avhdx -> ... -> base).
    # Per-disk reads are guarded so one unreadable VHD (or a WinRM hiccup) doesn't abort the whole audit.
    Show-AuditProgress 'Enumerating attached disks and differencing chains'
    $diskReports = [System.Collections.Generic.List[object]]::new()
    foreach ($disk in (Get-VMHardDiskDrive -VM $VMObject -ErrorAction SilentlyContinue)) {
        $chain = [System.Collections.Generic.List[object]]::new()
        $p = $disk.Path
        while ($p) {
            try {
                $v = Get-VHD -CimSession $OwningNode -Path $p -ErrorAction Stop
            } catch {
                Write-Alert "  WARNING: could not read VHD '$p' on ${OwningNode}: $($_.Exception.Message)" -Level Warning
                break
            }
            # Size + timestamps are filesystem metadata, not on the Get-VHD object, so read the file
            # itself on the owning node. If that read fails, fall back to Get-VHD's FileSize and leave
            # timestamps null (handled downstream) rather than aborting.
            $file = $null
            try {
                $file = Invoke-Command -ComputerName $OwningNode -ScriptBlock { Get-Item -LiteralPath $using:p } -ErrorAction Stop
            } catch {
                Write-Alert "  WARNING: could not read file metadata for '$p' on $OwningNode (WinRM?): $($_.Exception.Message)" -Level Warning
            }
            $allChainPaths.Add($v.Path)
            $chain.Add([pscustomobject]@{
                Path      = $v.Path
                Type      = $v.VhdType
                SizeGB    = if ($file) { [math]::Round($file.Length / 1GB, 2) } else { [math]::Round(($v.FileSize) / 1GB, 2) }
                Created   = if ($file) { $file.CreationTimeUtc }  else { $null }
                LastWrite = if ($file) { $file.LastWriteTimeUtc } else { $null }
            })
            $p = $v.ParentPath
        }
        if ($chain.Count -eq 0) {
            # Could not read even the attached disk - record a minimal entry so it still appears.
            $diskReports.Add([pscustomobject]@{
                Attached = Split-Path $disk.Path -Leaf; Path = $disk.Path; TopType = 'Unknown'
                SizeGB = $null; ChainDepth = 0; CheckpointCount = 0; AnyStale = $false; Chain = $chain
            })
            continue
        }
        $diskReports.Add([pscustomobject]@{
            Attached        = Split-Path $disk.Path -Leaf
            Path            = $disk.Path
            TopType         = $chain[0].Type
            SizeGB          = [math]::Round((($chain | Where-Object { $null -ne $_.SizeGB } | Measure-Object -Property SizeGB -Sum).Sum), 2)
            ChainDepth      = $chain.Count
            # A Differencing (.avhdx) layer == an active checkpoint; the final Dynamic/Fixed disk is the base:
            CheckpointCount = ($chain | Where-Object { $_.Type -eq 'Differencing' }).Count
            AnyStale        = (@($chain | Where-Object { $_.LastWrite -and ([DateTime]::UtcNow - $_.LastWrite).TotalHours -ge $StaleHours }).Count -gt 0)
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
        @{N='Stale';E={ if ($_.AnyStale) { 'YES' } else { '' } }} | Format-Table -AutoSize | Out-Indented

    # (b) Per-disk detail - one labelled block per disk so the full path is never truncated or
    # column-wrapped, including the attached (top-of-chain) disk's size, timestamps, age and stale flag:
    Write-Section "Attached Disk Detail:"
    $diskIndex = 0
    foreach ($d in $diskReports) {
        $diskIndex++
        Write-Output ("  Disk {0} of {1}" -f $diskIndex, $diskReports.Count)
        Write-Output ("  Disk File Name : {0}" -f $d.Attached)
        Write-Output ("  Disk Full Path : {0}" -f $d.Path)
        Write-Output ("  Type           : {0}" -f $d.TopType)
        $top = if ($d.Chain.Count -gt 0) { $d.Chain[0] } else { $null }
        if ($top) {
            Write-Output ("  This Disk (GB) : {0}" -f $top.SizeGB)
        }
        Write-Output ("  Chain Size (GB): {0} (total across all {1} layer(s))" -f $d.SizeGB, $d.ChainDepth)
        if ($top -and $top.Created) {
            Write-Output ("  Created (UTC)  : {0}" -f $top.Created.ToString('yyyy-MM-dd HH:mm:ss'))
        } else {
            Write-Output "  Created (UTC)  : (unavailable)"
        }
        if ($top -and $top.LastWrite) {
            $topAge = [math]::Round(([DateTime]::UtcNow - $top.LastWrite).TotalHours, 1)
            Write-Output ("  LastWrite (UTC): {0}" -f $top.LastWrite.ToString('yyyy-MM-dd HH:mm:ss'))
            Write-Output ("  Age (hrs)      : {0}" -f $topAge)
            if ($topAge -ge $StaleHours) { Write-Output "  Stale          : YES" }
        } else {
            Write-Output "  LastWrite (UTC): (unavailable)"
        }
        Write-Output ""
    }

    # (c) Differencing-chain detail - ONLY for disks that actually have a checkpoint layer
    # (ChainDepth > 1). Depth-1 disks add nothing here, so they are omitted to keep the report short.
    $deepDisks = @($diskReports | Where-Object { $_.ChainDepth -gt 1 })
    if ($deepDisks.Count -gt 0) {
        Write-Section "Differencing Chains (disks with a checkpoint layer):"
        foreach ($d in $deepDisks) {
            Write-Output "  $($d.Attached):"
            Write-Output "  Level 0 = the ACTIVE disk the VM writes to (child); each level's parent is the"
            Write-Output "  level below it; the highest level is the BASE. Chains can be many layers deep."
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
                    Stale             = if ($c.LastWrite -and ([DateTime]::UtcNow - $c.LastWrite).TotalHours -ge $StaleHours) { 'YES' } else { '' }
                }
            }
            $chainRows | Format-Table Level, Role, 'VHD File Name', Type, SizeGB, 'LastWrite (UTC)', 'Age (hrs)', Stale -AutoSize | Out-Indented
        }
    } else {
        Write-Section "Differencing Chains: none (no attached disk has a checkpoint layer)."
        Write-Output ""
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
            Write-Output "  (Could not match this VM's disks to a specific volume - showing all cluster volumes.)"
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
        Write-Output "  Could not query Cluster Shared Volumes: $($_.Exception.Message)"
        Write-Output ""
    }

    # Named checkpoints on the VM - maps .avhdx files to checkpoints such as 'Initial Replica':
    Show-AuditProgress 'Enumerating checkpoints'
    Write-Section "Checkpoints (Get-VMSnapshot):"
    $checkpoints = Get-VMSnapshot -CimSession $OwningNode -VMName $VMName -ErrorAction SilentlyContinue
    if ($checkpoints) {
        $checkpoints | Sort-Object CreationTime | Format-Table -AutoSize `
            Name,
            @{N='Type';E={ if ($_.PSObject.Properties['CheckpointType']) { $_.CheckpointType } else { $_.SnapshotType } }},
            @{N='Purpose';E={
                $t = if ($_.PSObject.Properties['SnapshotType']) { "$($_.SnapshotType)" }
                     elseif ($_.PSObject.Properties['CheckpointType']) { "$($_.CheckpointType)" } else { '' }
                switch -Wildcard ($t) {
                    'AppConsistent*' { 'Replica recovery point (app-consistent)'; break }
                    'Synced*'        { 'Replica synced checkpoint';                break }
                    '*Replica*'      { 'Hyper-V Replica checkpoint';               break }
                    'Recovery'       { 'Replica recovery point';                   break }
                    'Planned'        { 'Planned failover checkpoint';              break }
                    'Production*'    { 'Production checkpoint (backup)';           break }
                    'Standard'       { 'Standard checkpoint (manual/backup)';      break }
                    default          { if ($t) { $t } else { 'Unknown' } }
                }
            }},
            @{N='Created (UTC)';E={ $_.CreationTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') }},
            @{N='Age (hrs)';E={ [math]::Round(([DateTime]::UtcNow - $_.CreationTime.ToUniversalTime()).TotalHours, 1) }},
            @{N='Stale';E={ if (([DateTime]::UtcNow - $_.CreationTime.ToUniversalTime()).TotalHours -ge $StaleHours) { 'YES' } else { '' } }},
            @{N='Parent';E={ if ($_.PSObject.Properties['ParentCheckpointName']) { $_.ParentCheckpointName } else { $_.ParentSnapshotName } }} | Out-Indented
    } else {
        Write-Output "  No checkpoints present on '$VMName'."
        Write-Output ""
    }

    # Collect every folder holding one of this VM's VHDs - the attached chain AND any checkpoint
    # disks - so we scan all relevant locations. There is no separate HRL path setting in Hyper-V
    # Replica: the .hrl log always sits next to the VHD it protects.
    $folderSet = [System.Collections.Generic.List[string]]::new()
    $allChainPaths | ForEach-Object { $folderSet.Add((Split-Path $_ -Parent)) }
    if ($checkpoints) {
        foreach ($cp in $checkpoints) {
            # $cp carries its own CimSession, so do not also pass -CimSession here:
            Get-VMHardDiskDrive -VMSnapshot $cp -ErrorAction SilentlyContinue |
                ForEach-Object { if ($_.Path) { $folderSet.Add((Split-Path $_.Path -Parent)) } }
        }
    }
    $vhdFolders = $folderSet | Sort-Object -Unique

    # Orphaned differencing disks: .avhdx files on disk that are NOT part of any attached chain
    # (a stuck/failed merge or a leftover replica recovery point can leave these behind):
    Show-AuditProgress 'Scanning for orphaned .avhdx files'
    Write-Section "Orphaned .avhdx Files (present on disk but not attached to the VM):"
    if ($vhdFolders) {
        try {
            $onDiskAvhdx = Invoke-Command -ComputerName $OwningNode -ScriptBlock {
                $using:vhdFolders | ForEach-Object {
                    Get-ChildItem -LiteralPath $_ -Filter '*.avhdx' -File -ErrorAction SilentlyContinue
                }
            } -ErrorAction Stop
        } catch {
            $onDiskAvhdx = $null
            Write-Alert "  Could not reach $OwningNode to scan for .avhdx files (WinRM?): $($_.Exception.Message)" -Level Warning
        }
        $attachedSet = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]$allChainPaths, [System.StringComparer]::OrdinalIgnoreCase)
        $orphans = $onDiskAvhdx | Where-Object { -not $attachedSet.Contains($_.FullName) }
        if ($orphans) {
            $orphans | Select-Object `
                Name,
                @{N='SizeGB';E={ [math]::Round($_.Length / 1GB, 2) }},
                @{N='LastWrite (UTC)';E={ $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }},
                FullName | Format-Table -AutoSize -Wrap | Out-Indented
        } else {
            Write-Output "  None found - every .avhdx in the VM's folders is part of an attached chain."
            Write-Output ""
        }
    } else {
        Write-Output "  No VHD folders resolved to scan."
        Write-Output ""
    }

    # Replication health: on the PRIMARY, ongoing replication is tracked in .hrl logs (see below),
    # while the REPLICA stores recovery points as .avhdx checkpoints. A stalled initial replication
    # or a backlogged log can keep these artifacts around and inflate disk usage.
    Show-AuditProgress 'Checking Hyper-V Replica status'
    Write-Section "Hyper-V Replica (HVR) Status:"
    if ($VMObject.ReplicationState -ne 'Disabled') {
        $replication = Get-VMReplication -CimSession $OwningNode -VMName $VMName -ErrorAction SilentlyContinue
        if ($replication) {
            $replication | Format-List Name, State, Health, Mode, ReplicationRelationshipType,
                PrimaryServerName, ReplicaServerName, LastReplicationTime, FrequencySec, ReplicationHealthDetails | Out-Indented

            # Replication throughput / backlog - shows if replication is falling behind:
            Write-Section "Hyper-V Replica Statistics (Measure-VMReplication):"
            $replMeasure = Measure-VMReplication -CimSession $OwningNode -VMName $VMName -ErrorAction SilentlyContinue
            if ($replMeasure) {
                $replMeasure | Format-List ReplicationHealth, LastReplicationTime,
                    AverageReplicationSize, MaximumReplicationSize, PendingReplicationSize,
                    AverageReplicationLatency, ReplicationSuccessCount, MissedReplicationCount | Out-Indented
            } else {
                Write-Output "  No replication statistics available."
                Write-Output ""
            }
        } else {
            Write-Output "HVR Replication reported as '$($VMObject.ReplicationState)' but no replication object was returned."
            Write-Output ""
        }
    } else {
        Write-Output "HVR Replication is not enabled for '$VMName'."
        Write-Output ""
    }

    # Hyper-V Replica change logs (.hrl): on the PRIMARY, Replica tracks writes in per-VHD .hrl logs
    # (NOT .avhdx). A large or stale .hrl usually means replication is backlogged or stuck.
    Show-AuditProgress 'Scanning Replica change logs (.hrl)'
    Write-Section "Hyper-V Replica Change Logs (.hrl):"
    if ($vhdFolders) {
        try {
            $hrlFiles = Invoke-Command -ComputerName $OwningNode -ScriptBlock {
                $using:vhdFolders | ForEach-Object {
                    Get-ChildItem -LiteralPath $_ -Filter '*.hrl' -File -ErrorAction SilentlyContinue
                }
            } -ErrorAction Stop
        } catch {
            $hrlFiles = $null
            Write-Alert "  Could not reach $OwningNode to scan for .hrl logs (WinRM?): $($_.Exception.Message)" -Level Warning
        }
        if ($hrlFiles) {
            $hrlFiles | Sort-Object Name | Select-Object `
                Name,
                @{N='SizeMB';E={ [math]::Round($_.Length / 1MB, 2) }},
                @{N='LastWrite (UTC)';E={ $_.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss') }},
                @{N='Age (hrs)';E={ [math]::Round(([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalHours, 1) }},
                @{N='Stale';E={ if (([DateTime]::UtcNow - $_.LastWriteTimeUtc).TotalHours -ge $StaleHours) { 'YES' } else { '' } }},
                FullName | Format-Table -AutoSize -Wrap | Out-Indented
        } else {
            Write-Output "  No .hrl replication logs found (expected on a PRIMARY with replication enabled)."
            Write-Output ""
        }
    } else {
        Write-Output "  No VHD folders resolved to scan."
        Write-Output ""
    }

    # Scan the owning node's Hyper-V event logs for the checkpoint fork-commit / merge failure mode.
    # The documented chain is: Replica change-tracking / resync failures (leading indicators) ->
    # checkpoint fork-commit failure (18590, 0x80048102) -> per-disk .vmcx revert leaves the chain
    # inconsistent -> backup product retries fail (0x80070020) -> the inconsistency stays dormant while
    # the VM runs -> a later live migration / restart reopens the chain and can roll disks back to base.
    # Matching by event ID is node-wide on purpose: some of these events carry a blank or different VM GUID.
    # Runs by default; use -SkipWorkerEvents to opt out.
    $eventConcernCount = 0
    if (-not $SkipWorkerEvents) {
        Show-AuditProgress 'Scanning Hyper-V Worker/VMMS event logs'
        Write-Section "Hyper-V Worker/VMMS Admin Events (last $EventLookbackHours h on $OwningNode):"
        # Match on the VM GUID as well as the name - Worker/VMMS messages reference the
        # 'Virtual machine ID <GUID>', which is far more reliable than the long friendly name.
        $vmId = [string]$VMObject.VMId
        try {
        $workerEvents = Invoke-Command -ComputerName $OwningNode -ScriptBlock {
            $start  = (Get-Date).AddHours(-$using:EventLookbackHours)
            $vm     = $using:VMName
            $vmId   = $using:vmId
            $ids    = $using:WorkerEventIds
            # Single alternation regex built from the (escaped) HRESULT strings:
            $codeRx = ($using:ErrorCodePatterns | ForEach-Object { [regex]::Escape($_) }) -join '|'
            Get-WinEvent -FilterHashtable @{
                LogName   = 'Microsoft-Windows-Hyper-V-Worker-Admin', 'Microsoft-Windows-Hyper-V-VMMS-Admin'
                StartTime = $start
            } -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Message -match [regex]::Escape($vm)   -or
                $_.Message -match [regex]::Escape($vmId) -or
                ($codeRx -and $_.Message -match $codeRx) -or
                ($ids -contains $_.Id)
            } |
            Select-Object `
                @{N='Time (UTC)';E={ $_.TimeCreated.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') }},
                Id,
                @{N='Level';E={ $_.LevelDisplayName }},
                @{N='Log';E={ if ($_.LogName -like '*Worker*') { 'Worker' } elseif ($_.LogName -like '*VMMS*') { 'VMMS' } else { $_.LogName } }},
                @{N='Concern';E={ if (($codeRx -and $_.Message -match $codeRx) -or ($ids -contains $_.Id)) { 'YES' } else { '' } }},
                @{N='Message';E={ ($_.Message -split "`r?`n")[0] }},
                @{N='FullMessage';E={ ($_.Message -replace "`r?`n", ' | ') }}
        } -ErrorAction Stop
        } catch {
            $workerEvents = $null
            Write-Alert "  Could not reach $OwningNode to read event logs (WinRM?): $($_.Exception.Message)" -Level Warning
        }

        if ($workerEvents) {
            $workerEvents = $workerEvents | Sort-Object 'Time (UTC)'
            # Console table shows the first message line only (readability). The full, untruncated
            # text is preserved in the CSV export below.
            $workerEvents | Format-Table 'Time (UTC)', Id, Level, Log, Concern, Message -AutoSize -Wrap | Out-Indented
            $eventConcernCount = @($workerEvents | Where-Object { $_.Concern -eq 'YES' }).Count

            # Export the FULL event detail to CSV (no truncation) when an -OutputPath was supplied.
            # The file name includes the VM name and the UTC date (yyyy-MM-dd).
            if ($OutputPath) {
                $csvFolder = Split-Path -Parent $reportFile
                $csvName   = "Events_{0}_{1}.csv" -f ($VMName -replace '[^\w.\-]', '_'), [DateTime]::UtcNow.ToString('yyyy-MM-dd')
                $csvPath   = Join-Path $csvFolder $csvName
                $workerEvents | Select-Object 'Time (UTC)', Id, Level, Log, Concern, FullMessage |
                    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
                Write-Output "  Full event detail exported to CSV: $csvPath"
            }
        } else {
            Write-Output "  No matching events in the last $EventLookbackHours hours."
            Write-Output ""
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
        $nodes = @((Get-ClusterNode -ErrorAction SilentlyContinue).Name)
        if (-not $nodes) { $nodes = @($OwningNode) }
        $analyticStatus = Invoke-Command -ComputerName $nodes -ScriptBlock {
            $log = $using:analyticLog
            try   { $enabled = [bool](Get-WinEvent -ListLog $log -ErrorAction Stop).IsEnabled }
            catch { $enabled = 'Unknown (log not found)' }
            [pscustomobject]@{ Node = $env:COMPUTERNAME; Channel = $log; Enabled = $enabled }
        } -ErrorAction SilentlyContinue
        if ($analyticStatus) {
            $analyticStatus | Sort-Object Node | Format-Table Node, Channel, Enabled -AutoSize | Out-Indented
            $disabledNodes = @($analyticStatus | Where-Object { $_.Enabled -eq $false })
            if ($disabledNodes.Count -gt 0) {
                Write-Output "  DISABLED on: $($disabledNodes.Node -join ', ')"
                Write-Output "  To enable it (run elevated on each node listed above, if you choose to):"
                Write-Output "      wevtutil sl $analyticLog /e:true"
                Write-Output ""
            }
        } else {
            Write-Output "  Could not query the Analytic channel status on the cluster nodes."
            Write-Output ""
        }
    }

    # Summary: total active checkpoints (differencing / .avhdx layers) across all attached disks:
    Show-AuditProgress 'Building summary'
    $totalCheckpoints = ($diskReports | Measure-Object -Property CheckpointCount -Sum).Sum
    $hasCheckpoints   = $totalCheckpoints -gt 0
    # Count named checkpoints older than the stale threshold:
    $staleCheckpoints = @($checkpoints | Where-Object { ([DateTime]::UtcNow - $_.CreationTime.ToUniversalTime()).TotalHours -ge $StaleHours })
    Write-Output "==================================================================="
    if ($hasCheckpoints) {
        Write-Alert "  RESULT: $totalCheckpoints CheckPoint (differencing/AVHDX) disk(s) present on '$VMName'." -Level Warning
    } else {
        Write-Alert "  RESULT: No CheckPoint AVHDX disks are attached to '$VMName'." -Level Good
    }
    if ($staleCheckpoints.Count -gt 0) {
        Write-Alert "  WARNING: $($staleCheckpoints.Count) checkpoint(s) are >= $StaleHours hours old (possibly stuck)." -Level Warning
    }
    if ($eventConcernCount -gt 0) {
        Write-Alert "  WARNING: $eventConcernCount concerning Hyper-V event(s) found ($($ErrorCodePatterns -join '/') or IDs $($WorkerEventIds -join ', '))." -Level Warning
    }
    if ($eventConcernCount -gt 0 -and ($hasCheckpoints -or $staleCheckpoints.Count -gt 0)) {
        Write-Output ""
        Write-Alert "  HOLD STATE: checkpoint/merge failure signatures AND unmerged differencing disk(s) are present." -Level Critical
        Write-Alert "  Do NOT live-migrate, quick-migrate, storage-migrate, or restart this VM - reopening an" -Level Critical
        Write-Alert "  inconsistent disk chain can roll disks back to their base and lose intervening data." -Level Critical
        Write-Alert "  Open a Microsoft support case to validate/merge the chain before any such operation." -Level Critical
    }
    # Always remind the reader this is diagnostic only - any interpretation / remediation goes via CSS.
    Write-Output ""
    Write-Alert "  NOTE: This report is DIAGNOSTIC ONLY and makes no changes. For interpretation of these" -Level Info
    Write-Alert "  findings or any remediation, open a Microsoft Support (CSS) case and act on their advice." -Level Info
    Write-Output "==================================================================="

    # Boolean return for downstream/automation use (True = checkpoints present):
    return $hasCheckpoints

    }
    catch {
        # Safety net: any unexpected terminating error for THIS VM is reported and swallowed so a
        # multi-VM run continues with the next VM instead of aborting the whole batch.
        Write-Alert "  ERROR auditing '$VMName': $($_.Exception.Message)" -Level Critical
    }
    finally {
        if ($transcriptStarted) {
            Stop-Transcript | Out-Null
            Write-Output "Report saved to: $reportFile"
        }
    }
}

# Collect all requested VMs (works for both the -VMName array and pipeline input) so the parent
# progress bar can show an accurate "VM X of Y"; $VMSectionTotal drives the per-VM sub-progress %.
$script:PendingVMNames = [System.Collections.Generic.List[string]]::new()
$script:VMSectionTotal = 12

# Resolve a single per-run output sub-folder (once per invocation) so every VM in this run is
# grouped together and repeated runs never collide. Only created when -OutputPath is supplied.
$script:RunFolder = $null
if ($OutputPath) {
    $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-dd_HHmmss') + 'Z'
    $script:RunFolder = Join-Path $OutputPath "CheckpointAudit_$stamp"
    if (-not (Test-Path -LiteralPath $script:RunFolder)) {
        New-Item -ItemType Directory -Path $script:RunFolder -Force | Out-Null
    }
    Write-Output "Writing per-VM reports to: $script:RunFolder"
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

        Invoke-VMCheckpointAudit -VMName $name -OutputPath $script:RunFolder -StaleHours $StaleHours `
            -SkipWorkerEvents:$SkipWorkerEvents -EventLookbackHours $EventLookbackHours `
            -WorkerEventIds $WorkerEventIds -ErrorCodePatterns $ErrorCodePatterns `
            -SkipAnalyticCheck:$SkipAnalyticCheck

        # Clear this VM's sub-progress bar before moving to the next VM.
        Write-Progress -Id 2 -ParentId 1 -Activity ("Auditing VM: {0}" -f $name) -Completed
    }
    Write-Progress -Id 1 -Activity 'Hyper-V VM checkpoint / differencing-disk audit' -Completed
}