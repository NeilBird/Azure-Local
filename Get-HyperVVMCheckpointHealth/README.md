# Get-HyperVVMCheckpointHealth

> **Disclaimer:** This script is NOT a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT License](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

## TL;DR

An example PowerShell script that performs a **read-only** audit of a VM's **checkpoint / differencing-disk chain / replication** configuration, intended for use on an Azure Local or Windows Server Failover cluster.

Read-only health audit of a Hyper-V VM's **checkpoint / differencing-disk chain** on a Windows Server Failover Cluster or Azure Local cluster. It surfaces the specific failure mode where a checkpoint **fork-commit failure** leaves a VM's on-disk (`.vmcx`) chain metadata inconsistent — an inconsistency that can stay **dormant while the VM runs** and then be **materialised by a live migration or restart**, which can potentially cause the VM to roll the disks back to their base VHDX file(s), which can result in the data that is / was stored in the AVHDX file(s) being orphaned.

## Safety — this script makes no changes

The script is **read-only** with respect to the VMs, disks, checkpoints, cluster, and event logs. Every data call is a `Get-*` / `Measure-*`, and the remote `Invoke-Command` blocks only run `Get-Item` / `Get-ChildItem` / `Get-WinEvent`.

- It **never** creates/deletes/merges checkpoints, migrates, or changes VM/cluster state.
- The Analytic-channel enable command is **printed only** — never executed.
- The **only** filesystem writes happen when you opt in with `-OutputPath`: the `.txt` transcript, the events `.csv`, and (if needed) the output directory. With no `-OutputPath`, nothing is written.
- It is **diagnostic only** — it does not determine root cause definitively or remediate anything. For interpretation of the findings, or any remediation, **open a Microsoft Support (CSS) case** and act on their advice before taking action.

## Requirements

- PowerShell 5.1+ with the **Hyper-V** and **FailoverClusters** modules available.
- Run from a management host (or cluster node) that can reach the cluster and its nodes.
- **WinRM / `Invoke-Command`** to the owning node and cluster nodes (used to read file timestamps, scan `.avhdx` / `.hrl` files, query event logs, and check the Analytic channel state).
- Rights to query the cluster, Hyper-V, and the nodes' event logs.

## Usage

```powershell
# Basic audit of one VM (console only)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01'

# One VM, also writing a per-VM .txt report and events .csv into a folder
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01' -OutputPath 'C:\Temp\Reports'

# Multiple VMs by name (array) - each gets its own .txt and .csv in the folder
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01','TestVM02' -OutputPath 'C:\Temp\Reports'

# Every VM on the cluster - pass the VM OBJECTS directly (normalized to .Name internally)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-VM -CimSession (Get-Cluster).Name) -OutputPath 'C:\Temp\Reports'

# Every VM on the cluster - pass the names
.\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-VM -CimSession (Get-Cluster).Name).Name -OutputPath 'C:\Temp\Reports'

# Every VM on the cluster (pipeline - VM objects piped straight in)
Get-VM -CimSession (Get-Cluster).Name | .\Get-HyperVVMCheckpointHealth.ps1 -OutputPath 'C:\Temp\Reports'

# Wider event look-back (7 days) and a lower stale threshold (12h)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01' -EventLookbackHours 168 -StaleHours 12

# Skip the event-log scan and the Analytic-channel check (fastest, disk/checkpoint state only)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01' -SkipWorkerEvents -SkipAnalyticCheck
```

### Download / save the script and run it

Review the source first: [`Get-HyperVVMCheckpointHealth.ps1`](./Get-HyperVVMCheckpointHealth.ps1). Then either download it with the `Invoke-WebRequest` example below to save it locally, or [copy and paste the entire script using the Raw link](https://raw.githubusercontent.com/NeilBird/Azure-Local/main/Get-HyperVVMCheckpointHealth/Get-HyperVVMCheckpointHealth.ps1) and save it locally. The example below shows executing the script for a VM named `TestVM`, saving output in the `C:\Temp\` folder:

```powershell
# Download the script from GitHub and save it to the current folder
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/main/Get-HyperVVMCheckpointHealth/Get-HyperVVMCheckpointHealth.ps1' -OutFile '.\Get-HyperVVMCheckpointHealth.ps1'

# Run the downloaded script for a VM named 'TestVM'
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM' -OutputPath C:\Temp\
```

> **Note:** Depending on your execution policy, you may need to unblock the downloaded file first: `Unblock-File -Path '.\Get-HyperVVMCheckpointHealth.ps1'`.

> **Names or objects:** `-VMName` accepts VM **names** *or* VM **objects** (from `Get-VM`), as an array or via the pipeline. VM objects are normalized to their `.Name` inside the script, so `-VMName $VMs`, `-VMName $VMs.Name`, and `Get-VM | ...` all work. Each VM is audited **independently** - one VM not being found (or erroring) does not stop the rest. An input that resolves to no name, or to a string >100 chars (e.g. a mistakenly joined list), is skipped with a warning.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-VMName` | object[] (mandatory) | — | One or more VM **names** or VM **objects** (from `Get-VM`). Accepts an array and pipeline input (aliases `Name`, `VM`). Objects are normalized to `.Name`; names >100 chars are skipped with a warning. |
| `-OutputPath` | string | — | Optional **base folder** for reports. Each run creates a timestamped sub-folder; each VM gets its own `.txt` transcript **and** events `.csv` inside it. Console-only if omitted. |
| `-StaleHours` | int | `24` | Age (hours) at/beyond which a checkpoint or differencing disk is flagged `Stale = YES`. |
| `-SkipWorkerEvents` | switch | off | Skip the Hyper-V Worker/VMMS event-log scan. |
| `-EventLookbackHours` | int | `96` (4 days) | How far back the event scan looks (1–720). |
| `-WorkerEventIds` | int[] | see below | Event IDs flagged as a concern (node-wide match). |
| `-ErrorCodePatterns` | string[] | see below | HRESULT strings flagged as a concern when present in an event message. |
| `-SkipAnalyticCheck` | switch | off | Skip the per-node `Hyper-V-VMMS/Analytic` channel state check. |
| `-NoColour` (`-NoColor`) | switch | off | Colour is **on by default** for interactive consoles (headings + RESULT/WARNING/HOLD STATE). It auto-disables when output is redirected (`> file`, `Out-File`, `$x = .\script`) so captured text stays complete; the `-OutputPath` transcript captures the lines as plain text either way. Pass `-NoColour` to force plain output. |

## What it reports

1. **Header** — cluster, VM name, VM Id (GUID), owning node, status/state, uptime, then two checkpoint-config fields, the stale threshold and run time (UTC):
   - **Auto Checkpoints** (`AutomaticCheckpointsEnabled`) — when `True`, Hyper-V takes a checkpoint **automatically every time the VM starts** (a Client Hyper-V default; normally `False` on servers/clusters). A `True` here explains "unexpected" `.avhdx` layers appearing on boot.
   - **Checkpoint Type** (`CheckpointType`) — the style of checkpoint the VM is configured to take, which governs how each checkpoint's fork is committed: `Production` = app-consistent via in-guest VSS (falls back to Standard if VSS is unavailable); `ProductionOnly` = same but fails with no fallback; `Standard` = captures saved memory/running state (dev/test); `Disabled` = checkpoints not allowed. The value is annotated inline in the output.
2. **VM configuration (`.vmcx`)** — the config file path plus its last-write time and age (the failure mode hinges on stale on-disk chain metadata living here).
3. **Disk chain** — presented in three parts: an **overview table** (one row per attached disk: type, size, chain depth, checkpoint count, stale), a **per-disk detail block** (labelled `Disk File Name` / `Disk Full Path` plus type, size, created/last-write (UTC), age, stale — full path never truncated), and **differencing-chain detail shown only for disks that actually have a checkpoint layer** (depth > 1).
4. **Checkpoints** (`Get-VMSnapshot`) — name, type, a derived **Purpose** (backup vs Replica vs manual), age, stale flag, parent.
5. **Orphaned `.avhdx`** — files on disk in the VM's VHD folders that are **not** part of any attached chain.
6. **Replica change logs (`.hrl`)** — per-VHD replication logs with size/age (a large/stale `.hrl` = replication backlog).
7. **Cluster Shared Volume free space** — scoped to the volume(s) hosting this VM's disks (falls back to all cluster volumes if it can't match); a stuck merge is often blocked by low free space.
8. **Cluster role** (`Get-ClusterGroup`) — clustered role state and current owner.
9. **Hyper-V Replica** — `Get-VMReplication` health + `Measure-VMReplication` throughput/backlog.
10. **Worker/VMMS event scan** — recent events matching the VM (name **or** GUID), any listed error code, or any listed event ID. The console shows the first message line; the **full untruncated text is written to CSV** (see below).
11. **Analytic channel (per node)** — whether `Hyper-V-VMMS/Analytic` is enabled; prints the enable command where it is not.
12. **Summary** — checkpoint count, stale warnings, event-concern warning, and a **HOLD STATE** warning (see below). It always closes with a reminder that the report is diagnostic only and that interpretation / remediation should go through a Microsoft Support (CSS) case.

> **Progress:** while running, the script shows a parent progress bar (`VM X of Y`) with a per-VM sub-bar that updates through each section (resolving the VM, cluster role, disks, checkpoints, the event-log scan, etc.) — useful on a busy or large cluster where operations like the event-log scan can take time. Progress uses the PowerShell progress stream, so it never appears in the transcript, redirected output, or the returned value.

## Output files (only with `-OutputPath`)

`-OutputPath` is an **optional base folder** (console-only if omitted). Each run creates a timestamped **sub-folder** inside it, and one set of files is written **per VM** in that sub-folder:

```
<OutputPath>\
  CheckpointAudit_<yyyy-MM-dd_HHmmssZ>\        <- one sub-folder per run
    VMAudit_<VMName>_<yyyyMMdd-HHmmss>.txt      <- full console transcript for that VM
    Events_<VMName>_<yyyy-MM-dd>.csv            <- that VM's events, full untruncated text
```

- **`VMAudit_<VMName>_<yyyyMMdd-HHmmss>.txt`** — full console transcript of that VM's run.
- **`Events_<VMName>_<yyyy-MM-dd>.csv`** — that VM's event scan with the **complete, untruncated** message text (newlines flattened to ` | `). Use this rather than the console table, which truncates long messages.

Running against many VMs therefore produces one `.txt` + one `.csv` per VM, all grouped in a single per-run sub-folder so repeated runs never intermix. The run-folder path is printed at the start of the run.

## Failure-signature reference

The defaults target the checkpoint fork-commit / merge failure mode.

### Event IDs (`-WorkerEventIds`)

| Log | ID | Meaning |
|---|---|---|
| Worker | `3216` | Failed to switch to new differencing disks during checkpoint (`0x800703EE`) |
| Worker | `3280` | Related checkpoint/disk error |
| VMMS | `18500` / `18510` | Checkpoint started / completed |
| VMMS | `18590` | Checkpoint failed (fork-commit, `0x80048102`) — key signature |
| Worker | `18590` | Guest OS bugcheck / fatal error — **same ID, different channel** (the VM crashed, e.g. after a migration reopened a rolled-back chain). Check the `Log` column to tell them apart. |
| VMMS | `18012` | Checkpoint operation failed |
| VMMS | `12240` | Attachment (`.avhdx`) not found |
| VMMS | `15268` | Failed to get disk information |
| VMMS | `16300` | Cannot load a virtual machine configuration |
| VMMS | `19070` / `19090` / `19080` | Background disk merge started / interrupted / finished |

> Event-ID matching is intentionally **node-wide** — some of these events carry a blank or a different VM GUID, so scoping strictly to one VM would miss them.

### HRESULTs (`-ErrorCodePatterns`)

| Code | Meaning | Role |
|---|---|---|
| `0x80048102` | `VM_E_COMMIT_FORKS_ERROR` | Checkpoint fork-commit failed — root-cause trigger |
| `0x800480BD` | `VM_E_FR_CHANGE_TRACKING_FAILED` | Replica change-tracking failure — leading indicator |
| `0x800480BC` | `VM_E_FR_RESYNC_REQUIRED` | Replica relationship broken — leading indicator |
| `0x80070020` | `ERROR_SHARING_VIOLATION` | Backup product cannot open the disk — symptom |
| `0x800703EE` | `ERROR_FILE_INVALID` | A volume changed underneath an open file |
| `0x80070002` | `ERROR_FILE_NOT_FOUND` | The `.avhdx` / VM config file is missing |

## HOLD STATE guidance

When the report finds **checkpoint/merge failure signatures AND unmerged differencing disk(s)**, it prints a
**HOLD STATE** warning. In that condition:

- **Do NOT** live-migrate, quick-migrate, storage-migrate, or restart the VM. Reopening an inconsistent disk chain can roll disks back to their base and lose intervening data.
- Continuing to run the VM in place is generally safe (Hyper-V keeps using the in-memory chain state).
- **Open a Microsoft support case** to validate/merge the chain before any migration or restart.

## Enabling the Analytic channel (optional, operator's choice)

The internal per-disk `.vmcx` revert failure is traced only to `Hyper-V-VMMS/Analytic`, which is disabled by default. To capture it for future incidents, run **elevated on each node**:

```cmd
wevtutil sl Microsoft-Windows-Hyper-V-VMMS/Analytic /e:true
```

## Return value

The script returns a `[bool]` **per VM** — `$true` when that VM has one or more active checkpoint (differencing) disks — for use in automation. When multiple VMs are supplied, one boolean is emitted per VM.
