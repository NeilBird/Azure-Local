# Get-HyperVVMCheckpointHealth

> **Disclaimer:** This script is NOT a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT License](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

## Latest version:

- Script: [`Get-HyperVVMCheckpointHealth.ps1`](./Get-HyperVVMCheckpointHealth.ps1)
- Updated: 2026-07-15
- Version: 0.2.13

## TL;DR

An example PowerShell script that performs a **read-only** audit of a VM's **checkpoint / differencing-disk chain, Hyper-V replication, and node event logs**. It automates the creation of a portable HTML Summary Report that highlights VMs with aged checkpoints, failing replication, and/or signals of concern that could occur during VM migration.

This script provides insights that should be used as part of an operator investigation. It is NOT intended to troubleshoot active issues, nor does it provide a root-cause analysis (RCA). It is ONLY suitable as a tool to surface existing event data or configuration drift for VM checkpoints and/or replication issues.

- **This script is NOT a supported service or offering from Microsoft. It is provided as example code only.**

## Overview and details of intended use

This example script performs a read-only audit of a Hyper-V VM's **checkpoint / differencing-disk chain, Hyper-V replication, and specific diagnostic event data** on an Azure Local or Windows Server Failover Cluster. It can be used to surface the specific failure mode where a checkpoint **fork-commit failure** leaves a VM's on-disk (`.vmcx`) chain metadata inconsistent — an inconsistency that can stay **dormant while the VM runs** and then be **materialised by a live migration or restart**, which can potentially cause the VM to roll the disks back to their base VHDX file(s), which can result in the data that is / was stored in the AVHDX file(s) being orphaned.

The script is intended for Azure Local / Windows Server administrators / operators who need to audit the VMs running on a specific cluster — specifically for any anomalies in checkpoint, replication, or storage-related events. It generates automated output in the form of detailed `.txt` reports, `.csv` event-log data, and a portable **HTML summary** file that serves as the at-a-glance audit report.

## Contents

- [Safety — this script makes no changes](#safety--this-script-makes-no-changes)
- [Requirements](#requirements)
- [How it connects (no double-hop)](#how-it-connects-no-double-hop)
- [Usage](#usage)
- [Parameters](#parameters)
- [What it reports](#what-it-reports)
- [Portable HTML report & results bundle](#portable-html-report--results-bundle)
- [Output files](#output-files-only-with--outputpath)
- [Failure-signature reference](#failure-signature-reference)
- [VM states (verdicts)](#vm-states-verdicts)
- [Enabling the Analytic channel](#enabling-the-analytic-channel-optional-operators-choice)
- [Return value](#return-value)

## Safety — this script makes no changes

The script is **read-only** with respect to the VMs, disks, checkpoints, cluster, and event logs. Every data call is a `Get-*` / `Measure-*`, and the owner-context blocks only run read-only commands (`Get-VM`, `Get-VMHostSupportedVersion`, `Get-VHD`, `Get-VMSnapshot`, `Get-VMReplication`, `Get-Item`, `Get-ChildItem`, `Get-WinEvent`, `vssadmin list writers` (which only *enumerates* VSS writer state), and the storage-health snapshot `Get-StorageJob` / `Get-VirtualDisk` / `Get-PhysicalDisk` / `Get-StorageSubSystem` / `Get-ClusterSharedVolumeState`).

- It **never** creates/deletes/merges checkpoints, migrates, or changes VM/cluster state.
- The Analytic-channel enable command is **printed only** — never executed.
- The **only** filesystem writes are diagnostic **artifacts**: a per-VM `.txt` report and events `.csv` (with `-OutputPath`), a single self-contained **HTML** fleet report (on by default — into the `-OutputPath` run folder, or the current directory if `-OutputPath` is omitted), and a results **`.zip`** bundling them (on by default when `-OutputPath` is used). Suppress with `-NoHtml` / `-NoZip`. None of these change the VM, disks, checkpoints, or cluster.
- It is **diagnostic only** — it does not determine root cause definitively or remediate anything. For **backup / checkpoint-merge or VSS** findings, engage your **third-party backup vendor first** (their product owns the checkpoint lifecycle); **open a Microsoft Support (CSS) case** for a confirmed fork-commit signature, or when the vendor rules out their product. Act on their advice before taking action.

## Requirements

- **Windows PowerShell 5.1** with the **Hyper-V** and **FailoverClusters** modules available. This script is written for, and validated against, **Windows PowerShell 5.1 only** — it is **not** intended for PowerShell 7.x.
- Run it **on a cluster node** (interactive / SConfig logon), **or** from a **management workstation** using **`-Cluster <name>`** (with the RSAT **Failover Clustering** tools installed).
- On a **management workstation**, install the RSAT **Failover Clustering** tools so `Get-ClusterGroup` / `Get-Cluster` resolve locally (without them you get `Get-ClusterGroup : The term ... is not recognized`):
  ```powershell
  # Windows 10 / 11 client (run elevated)
  Add-WindowsCapability -Online -Name 'Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0'

  # Windows Server (run elevated)
  Install-WindowsFeature -Name RSAT-Clustering-PowerShell
  ```
- Rights to query the cluster, Hyper-V, and the nodes' event logs. When the VM's owning node is not the local node, WinRM to that owning node is used for a **single** hop.

## How it connects (no double-hop)

The script is designed to avoid "double-hop" authentication failures (the `0x8009030e` Kerberos error you get when a remoting session tries to reach a second machine). It:

1. finds the cluster nodes and the VM's **owning node** using the **cluster API** (`Get-ClusterGroup` / `Get-ClusterNode` — RPC, no WinRM), then
2. runs every data-collection command in the **owner context** — **directly (locally)** when the current node owns the VM (zero hops), otherwise through **one** remoting session to the owning node.

Two supported ways to run it, both single-hop:

- **On a cluster node** (interactive / SConfig logon). VMs owned by that node are read locally (zero hops); VMs on other nodes are reached in one hop.
- **From a management workstation** with **`-Cluster <name>`** (RSAT Failover Clustering installed). The cluster queries use RPC and each owning node is reached in one hop from the workstation. If you build the `-VMName` list from a `Get-ClusterGroup` sub-expression, add `-Cluster <name>` to **that** query too — it runs locally and does not inherit the script's `-Cluster` (see the remote example in Usage).

> **Do not** `Enter-PSSession` into a node and then run the script: if the VM is owned by a *different* node, reaching it is a **second (double) hop** and is blocked (`Access is denied` / `0x8009030e`) unless CredSSP/delegation is configured. The script detects this and tells you to run it on a node or use `-Cluster`.

## Usage

```powershell
# Basic audit of one VM (console only)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01'

# One VM, also writing a per-VM .txt report and events .csv into a folder
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01' -OutputPath 'C:\Temp\Reports'

# Multiple VMs by name (array) - each gets its own .txt and .csv in the folder
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01','TestVM02' -OutputPath 'C:\Temp\Reports'

# Every clustered VM - ON A NODE. The bare Get-ClusterGroup targets the LOCAL cluster, so this form
# only works when run on a cluster node (for a workstation, use the -Cluster form below).
.\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine').Name -OutputPath 'C:\Temp\Reports'

# A specific list of VM names (piped) - the script resolves each VM's owning node itself
'VM01','VM02','VM03' | .\Get-HyperVVMCheckpointHealth.ps1 -OutputPath 'C:\Temp\Reports'

# REMOTE: from a management workstation (RSAT Failover Clustering) - target a cluster by name.
# STEP 1 - verify the RSAT Failover Clustering tools are present on THIS workstation (see Requirements
# to install if this returns nothing / $false). Get-ClusterGroup and Get-Cluster come from this module.
if (Get-Module -ListAvailable FailoverClusters) { 'FailoverClusters: OK' } else { 'FailoverClusters: MISSING - install RSAT (see Requirements)' }
Get-Command Get-ClusterGroup -ErrorAction SilentlyContinue   # should resolve; blank = tools not installed

# STEP 2 - run it. NOTE: -Cluster must appear TWICE - the (Get-ClusterGroup -Cluster 'CLUS01' ...) that
# builds the -VMName list is a SEPARATE local command that does NOT inherit the script's -Cluster, so it
# needs its own; the script's -Cluster then governs the audit.
.\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name -OutputPath 'C:\Temp\Reports'

# Equivalent remote pipeline form (names gathered from the remote cluster, then piped in)
Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine' |
    Select-Object -ExpandProperty Name |
    .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' -OutputPath 'C:\Temp\Reports'

# Wider event look-back (14 days, vs the 7-day default) and a lower stale threshold (12h)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01' -EventLookbackHours 336 -StaleHours 12

# Skip the event-log scan and the Analytic-channel check (fastest, disk/checkpoint state only)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01' -SkipWorkerEvents -SkipAnalyticCheck

# -PassThru: also emit one object per VM to the pipeline (for Where-Object / Export-Csv / roll-ups)
$r = .\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM01','TestVM02' -OutputPath 'C:\Temp\Reports' -PassThru
$r | Where-Object HoldState | Format-Table VMName, OwningNode, Recommendation

# HTML fleet report + results .zip are produced BY DEFAULT (into the -OutputPath run folder). The
# console is quiet by default (one-line verdict per VM); the .txt and HTML still hold the full detail.
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'VM01','VM02' -OutputPath 'C:\Temp\Reports'

# Full per-VM report on the console as well as the files
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'VM01' -OutputPath 'C:\Temp\Reports' -Quiet:$false

# Also audit high-risk VMs DISCOVERED in the event data (bounded, non-recursive)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'VM01' -OutputPath 'C:\Temp\Reports' -IncludeDiscoveredVMs

# Audit every clustered VM EXCEPT those named in an exclusion CSV (single 'VMName' column, case-insensitive)
.\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine').Name -ExcludedVMListCsv 'C:\Temp\CheckPointAudit_Excluded_VMs.csv' -OutputPath 'C:\Temp\Reports'

# Choose the HTML location explicitly (folder or full .html path); suppress the zip and/or HTML
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'VM01' -OutputPath 'C:\Temp\Reports' -HtmlReportPath 'C:\Reports\audit.html' -NoZip
```

### Download / save the script and run it

Review the source first: [`Get-HyperVVMCheckpointHealth.ps1`](./Get-HyperVVMCheckpointHealth.ps1). Then either download it with the `Invoke-WebRequest` example below to save it locally, or [copy and paste the entire script using the Raw link](https://raw.githubusercontent.com/NeilBird/Azure-Local/main/Get-HyperVVMCheckpointHealth/Get-HyperVVMCheckpointHealth.ps1) and save it locally. The example below shows executing the script for a VM named `TestVM`, saving output in the `C:\Temp\` folder:

```powershell
# Download the script from GitHub and save it to the current folder
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/main/Get-HyperVVMCheckpointHealth/Get-HyperVVMCheckpointHealth.ps1' -OutFile '.\Get-HyperVVMCheckpointHealth.ps1'

# Run the downloaded script for a VM named 'TestVM'
.\Get-HyperVVMCheckpointHealth.ps1 -VMName 'TestVM' -OutputPath C:\Temp\

# Or, ON A CLUSTER NODE, audit EVERY clustered VM. The bare Get-ClusterGroup targets the LOCAL
# cluster (cluster API - RPC, no WinRM), so this form is for running on a node. It returns every
# clustered VM across all nodes, so -IncludeDiscoveredVMs is not needed here (they are already in
# the list); use that switch only when auditing a SUBSET of VMs.
.\Get-HyperVVMCheckpointHealth.ps1 -VMName (Get-ClusterGroup | Where-Object GroupType -eq 'VirtualMachine').Name -OutputPath C:\Temp\
```

> **Note:** Depending on your execution policy, you may need to unblock the downloaded file first: `Unblock-File -Path '.\Get-HyperVVMCheckpointHealth.ps1'`.

> **Names or objects:** `-VMName` accepts VM **names** *or* VM **objects** (from `Get-VM`), as an array or via the pipeline. VM objects are normalized to their `.Name` inside the script, so `-VMName $VMs`, `-VMName $VMs.Name`, and `Get-VM | ...` all work. Each VM is audited **independently** - one VM not being found (or erroring) does not stop the rest. An input that resolves to no name, or to a string >100 chars (e.g. a mistakenly joined list), is skipped with a warning.

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-VMName` | object[] (mandatory) | — | One or more VM **names** or VM **objects** (from `Get-VM`). Accepts an array and pipeline input (aliases `Name`, `VM`). Objects are normalized to `.Name`; names >100 chars are skipped with a warning. |
| `-Cluster` | string | — | Optional. Target a cluster **by name** so the script can run from a **management workstation** (RSAT Failover Clustering) instead of on a node — cluster queries use RPC and each owning node is reached in a **single** hop. When omitted, the script targets the **local** cluster and a `Get-Cluster` guard rail requires you to be **on a cluster node** (it fails clearly if not). |
| `-OutputPath` | string | — | Optional **base folder** for reports. Each run creates a timestamped sub-folder; each VM gets its own `.txt` transcript **and** events `.csv` inside it. If omitted, output is **console-only** (nothing saved) and the script warns at the start and end of the run to re-run with `-OutputPath` to capture files for a support case. |
| `-StaleHours` | int | `24` | Age (hours) at/beyond which a checkpoint or differencing disk is flagged `Stale = YES`. If your backup product legitimately keeps checkpoints for longer (e.g. a 48-hour retention window), raise this (e.g. `-StaleHours 48`) so expected long-lived checkpoints are not flagged. |
| `-SkipWorkerEvents` | switch | off | Skip the Hyper-V Worker/VMMS event-log scan. |
| `-EventLookbackHours` | int | `168` (7 days) | How far back the event scan looks (1–720). |
| `-WorkerEventIds` | int[] | see below | Event IDs that indicate a genuine **problem** and drive the `Concern = YES` flag (node-wide match). |
| `-ContextEventIds` | int[] | see below | **Informational** lifecycle event IDs. These are still **surfaced** for the timeline but are **never** flagged as a concern (e.g. VM started, checkpoint completed, merge started / finished OK). |
| `-ErrorCodePatterns` | string[] | see below | HRESULT strings flagged as a concern when present in an event message. |
| `-SkipAnalyticCheck` | switch | off | Skip the per-node `Hyper-V-VMMS/Analytic` channel state check. |
| `-PassThru` | switch | off | Emit **one `[pscustomobject]` per VM** to the pipeline (for `Where-Object` / `Export-Csv` / fleet roll-ups). Without it, **nothing** is written to the pipeline — the report goes to the host and, with `-OutputPath`, to the `.txt`/`.csv` files. See [Return value](#return-value). |
| `-Quiet` | bool | `$true` | Console verbosity. **Quiet by default**: the full per-VM report still goes to the `.txt` and HTML, while the console shows only a concise one-line verdict per VM plus the final HTML/zip pointers. Pass `-Quiet:$false` to stream the complete per-VM report to the console too. |
| `-HtmlReportPath` | string | — | Where to write the portable HTML fleet report. Accepts a **folder** (auto-named `VMCheckpointAudit-<Cluster>-yyyy-MM-dd.html`) or a full path ending in `.html`. Defaults to the `-OutputPath` run folder; if `-OutputPath` is omitted too, the current directory. |
| `-NoHtml` | switch | off | Suppress the HTML fleet report (generated by default). |
| `-NoZip` | switch | off | Suppress the results `.zip` bundle (created by default when `-OutputPath` is supplied). |
| `-IncludeDiscoveredVMs` | switch | off | Also audit VMs **discovered** in the owning node's event data with a **high-risk** signal (merge interrupted/failed, sharing violation `0x80070020`, or cannot-load-config) but not in the audit list. Such VMs are **always surfaced** (console + HTML); this switch additionally audits them — **bounded** (cap 25) and **non-recursive**. |
| `-ExcludedVMListCsv` | string | — | Optional path to a CSV listing VM names to **exclude** from the audit. Single column with a `VMName` header (a headerless single-column file also works). Read **once** at start; any requested / piped VM whose name matches (**case-insensitive**) is skipped **before** it is audited, and excluded VMs are **not** auto-audited via `-IncludeDiscoveredVMs` either. A missing / unreadable file is a non-fatal warning (the run proceeds with no exclusions). Handy to permanently omit known-noisy or intentionally long-checkpointed VMs from a fleet run. |
| `-SkipStorageHealth` | switch | off | Skip the read-only cluster storage-health snapshot (S2D storage jobs, CSV state, virtual/physical disk health). On by default; gathered once per run. |
| `-NoColour` (`-NoColor`) | switch | off | Colour is **on by default** for interactive consoles (headings + RESULT/WARNING/HOLD STATE). It auto-disables when output is redirected (`> file`, `Out-File`, `$x = .\script`) so captured text stays readable; the `-OutputPath` transcript captures the lines as plain text either way. Pass `-NoColour` to force plain output. |

## What it reports

1. **Header** — cluster, VM name, VM Id (GUID), owning node, status/state, **VM config version** and the **latest version supported by the cluster** (via `Get-VMHostSupportedVersion`), uptime, then two checkpoint-config fields, the stale threshold and run time (UTC). When the VM's config version is older than the latest, a separate low **VM Configuration Version** section notes this as *migration / start* context — with the exact wording from the Microsoft guide and the `Update-VMVersion` remediation — and states explicitly that it is **not** a cause of the checkpoint/merge failure being investigated.
   - **Auto Checkpoints** (`AutomaticCheckpointsEnabled`) — when `True`, Hyper-V takes a checkpoint **automatically every time the VM starts** (a Client Hyper-V default; normally `False` on servers/clusters). A `True` here explains "unexpected" `.avhdx` layers appearing on boot.
   - **Checkpoint Type** (`CheckpointType`) — the style of checkpoint the VM is configured to take, which governs how each checkpoint's fork is committed: `Production` = app-consistent via in-guest VSS (falls back to Standard if VSS is unavailable); `ProductionOnly` = same but fails with no fallback; `Standard` = captures saved memory/running state (dev/test); `Disabled` = checkpoints not allowed. The value is annotated inline in the output.
2. **VM configuration (`.vmcx`)** — the config file path plus its last-write time and age (the failure mode hinges on stale on-disk chain metadata living here).
3. **Disk chain** — presented in three parts: an **overview table** (one row per attached disk: type, size, chain depth, checkpoint count, stale), a **per-disk detail block** (labelled `Disk File Name` / `Disk Full Path` plus type, size, created/last-write (UTC), age, stale — full path never truncated), and **differencing-chain detail shown only for disks that actually have a checkpoint layer** (depth > 1).
4. **Checkpoints** (`Get-VMSnapshot`) — name, type, a derived **Purpose** (backup vs Replica vs manual), age, stale flag, parent.
5. **Orphaned `.avhdx`** — files on disk in the VM's VHD folders that are **not** part of any attached chain (a stuck / failed merge or a leftover replica recovery point can leave these behind). Each is listed with its **size, created (UTC) and last-write (UTC)** timestamps and full path. Finding **any** orphan flags the VM **INVESTIGATE** (confirm with your backup team before removing — the script never deletes anything).
6. **Replica change logs (`.hrl`)** — per-VHD replication logs with size/age (a large/stale `.hrl` = replication backlog).
7. **Cluster Shared Volume free space** — scoped to the volume(s) hosting this VM's disks (falls back to all cluster volumes if it can't match); a stuck merge is often blocked by low free space.
8. **Cluster role** (`Get-ClusterGroup`) — clustered role state and current owner.
9. **Hyper-V Replica** — `Get-VMReplication` health + `Measure-VMReplication` throughput/backlog.
10. **Worker/VMMS event scan** — recent events matching the VM (name **or** GUID), any listed HRESULT, or any listed event ID. Each row is marked `Concern = YES` **only** for a genuine problem (an HRESULT match or a concern event ID); informational lifecycle events (VM started, checkpoint completed, merge started / finished OK) are listed for context but left blank. To keep the report readable, repeated rows for the same event ID are **collapsed** in the console / `.txt` (the first few are shown, followed by a `Removed N duplicate Event ID X entries - Review CSV file for full details.` note); the **full untruncated text of every event is written to the CSV**.
11. **Analytic channel (per node)** — whether `Hyper-V-VMMS/Analytic` is enabled; prints the enable command where it is not.
12. **VSS writer health** (`vssadmin list writers` — read-only) — flags any VSS writer whose state is not `Stable` or that reports a last error. Failed / timed-out VSS writers are a leading cause of Hyper-V checkpoint / backup failures (per the Microsoft troubleshooting guide).
13. **Summary** — checkpoint count, stale-checkpoint + backup-check guidance, event-concern warning, and a **severity assessment**: **HOLD STATE (data-loss risk)** when a confirmed fork-commit / merge signature accompanies unmerged differencing disk(s), or **INVESTIGATE** when only symptom-level signals (e.g. repeated `15268`, an aged backup checkpoint, or an unhealthy VSS writer) are present. Each includes a plain-language "why flagged" line and links the Microsoft Learn troubleshooting article.
14. **Problem Statement (for a Microsoft Support / CSS case)** — a copy/paste-ready block: cluster/owner/VM, plain-language findings, concerning events grouped by ID with first/last timestamps, the severity assessment, any unhealthy VSS writers, the requested action, the artifacts to attach (the `.txt` report and events `.csv`, by path), and the Microsoft Learn reference. It always closes with a reminder that the report is diagnostic only and that interpretation / remediation should go through a Microsoft Support (CSS) case.

> **Progress:** while running, the script shows a parent progress bar (`VM X of Y`) with a per-VM sub-bar that updates through each section (resolving the VM, cluster role, disks, checkpoints, the event-log scan, etc.) — useful on a busy or large cluster where operations like the event-log scan can take time. Progress uses the PowerShell progress stream, so it never appears in the transcript, redirected output, or the returned value.

15. **Cluster storage health (Storage Spaces Direct / CSV)** — a read-only, cluster-wide snapshot (gathered **once** per run): active `Get-StorageJob` repair/resync jobs, CSVs in redirected/paused state, and any unhealthy virtual/physical disks. Storage-layer disruption is a plausible contributing factor for the merge / `0x80070020` / `16300` symptoms (files transiently locked or unavailable). The HTML also recommends Microsoft's CSS **Storage Diagnostic** (`Install-Module -Name Microsoft.AzLocal.CSSTools`; then `Start-AzsSupportStorageDiagnostic`) for a deep S2D / SBL analysis. Skip with `-SkipStorageHealth`.
16. **Discovered high-risk VMs** — VMs referenced in the node's **high-risk** event signals (merge interrupted / failed, `0x80070020`, cannot-load-config) but **not** in the audit list, cross-checked against real clustered VMs. Always **surfaced** (console + HTML) with a ready-to-run command; audited automatically only with `-IncludeDiscoveredVMs` (bounded, non-recursive).

## Portable HTML report & results bundle

By default the run produces a single **self-contained HTML fleet report** (`VMCheckpointAudit-<Cluster>-<yyyy-MM-dd>.html`) — dark-themed, no external assets, safe to email or open on any device with a browser. It contains: summary cards (including an **Orphaned .avhdx** count); a **Recommended next steps** list (see below); a **VM summary table** with distinct **Checkpoints** (`Get-VMSnapshot` count) and **AVHDX files** (differencing layers = Checkpoints × Disks) columns; a **Discovered high-risk VMs** section; **per-VM detailed information** (including a per-VM **Orphaned .avhdx files** table — name, size, created + last-write timestamps, full path — and, for HOLD STATE VMs, a copy/paste **Support Case summary**); a **Cluster storage health** section; and an anonymised **Information** section explaining the fork-commit signature and the exact Event IDs / HRESULTs that indicate it.

### Recommended next steps (context-gated)

Near the top of the report, a **Recommended next steps** list shows only the advice that is **actually actionable for this run** — each bullet is gated on what the audit found across the fleet, so a clean run stays short and a problem run surfaces exactly the relevant guidance:

- **Backup team first** / **Confirm expected vs abandoned** — shown when ≥ 1 **stale** checkpoint was found across the fleet.
- **INVESTIGATE (backup team first)** — shown when ≥ 1 VM is **INVESTIGATE** *and* there are **no** stale checkpoints in the fleet. It covers VMs flagged by an unhealthy VSS writer or VM-attributed concern events **without** a fork-commit signature — triage with the backup team/vendor first; **no immediate Microsoft Support case** is needed for these. When a stale checkpoint is the INVESTIGATE driver, the two stale-checkpoint bullets above already cover it, so this bullet is suppressed to avoid duplicate advice.
- **Orphaned `.avhdx` file(s)** — shown when ≥ 1 orphaned `.avhdx` was found in any VM's disk folder(s) (not attached to any chain). Confirm with the backup team whether each is safe to remove before deleting any; the per-VM **Orphaned .avhdx files** table lists names, sizes and timestamps.
- **Enable the Analytic channel** — shown only when a node still has the `Hyper-V-VMMS/Analytic` channel disabled (and the check was not skipped).
- **Rule out storage-layer disruption** — shown only when the storage-health snapshot is **Degraded** / has active storage jobs.
- **HOLD STATE VMs** and **Open a Microsoft Support case** — shown **only** when ≥ 1 VM is in **HOLD STATE** (a fork-commit signature is present somewhere in the fleet). On INVESTIGATE-only / clean runs the Microsoft-case line is deliberately omitted, because with no fork-commit signature the next step is backup-team / vendor triage, not a support case.

When none of the above apply, a single **"No action required from this audit"** line is shown instead.

When `-OutputPath` is used, a results **`.zip`** bundling the `.txt` + `.csv` + `.html` is also created (suppress with `-NoZip`), and the console prints guidance to **copy the zip to a device with a browser, unzip, and open the HTML**. The console itself is **quiet by default** (one-line verdict per VM); use `-Quiet:$false` for the full report on screen.

## Output files (only with `-OutputPath`)

`-OutputPath` is an **optional base folder** (console-only if omitted). Each run creates a timestamped **sub-folder** inside it, and one set of files is written **per VM** in that sub-folder:

```
<OutputPath>\
  VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.zip        <- results bundle (default; suppress with -NoZip)
  CheckpointAudit_<yyyy-MM-dd_HHmmssZ>\                   <- one sub-folder per run
    <VMName>_VMAudit_<yyyyMMdd-HHmmss>.txt               <- full report for that VM
    <VMName>_Events_<yyyy-MM-dd>.csv                     <- that VM's events, full untruncated text
    VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.html    <- portable fleet report (default; suppress with -NoHtml)
```

- **`<VMName>_VMAudit_<yyyyMMdd-HHmmss>.txt`** — the full per-VM report (written from the captured output buffer; complete regardless of `-Quiet`).
- **`<VMName>_Events_<yyyy-MM-dd>.csv`** — that VM's event scan with the **complete, untruncated** message text (newlines flattened to ` | `). The `.txt` collapses repeated rows for the same event ID (first few shown + a `Removed N duplicate...` note), so use this CSV for the full record of every event.
- **`VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.html`** — the single portable fleet report covering all audited VMs (see [Portable HTML report](#portable-html-report--results-bundle)).
- **`VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.zip`** — a bundle of the run folder (`.txt` + `.csv` + `.html`), for copying to a browser device / attaching to a support case in one file.

File names lead with the **VM name** so per-VM reports sort together for easy reading. Running against many VMs produces one `.txt` + one `.csv` per VM, all grouped in a single per-run sub-folder so repeated runs never intermix. The run-folder path is printed at the start of the run.

## Failure-signature reference

The defaults target the checkpoint fork-commit / merge failure mode.

### Concerning event IDs (`-WorkerEventIds`)

These indicate a genuine problem and are flagged **`Concern = YES`**:

| Log | ID | Meaning |
|---|---|---|
| Worker | `3216` | Failed to switch to new differencing disks during checkpoint (`0x800703EE`) |
| Worker | `3280` | Related checkpoint/disk error |
| VMMS | `18590` | Checkpoint operation reported a failure. When it carries a fork-commit HRESULT (e.g. `0x80048102`), **that HRESULT** is the fork-commit signature (see note below). |
| Worker | `18590` | Guest OS bugcheck / fatal error — **same ID, different channel** (the VM crashed, e.g. after a migration reopened a rolled-back chain). Check the `Log` column to tell them apart. |
| VMMS | `18012` | Checkpoint operation failed |
| VMMS | `12240` | Attachment (`.avhdx`) not found |
| VMMS | `15268` | Failed to get disk information |
| VMMS | `16300` | Cannot load a virtual machine configuration |
| VMMS | `19090` | Background disk merge **interrupted** |
| VMMS | `19100` | Background disk merge **failed** to complete (e.g. `0x80070020` sharing violation) |

> **Fork-commit signature (drives `HOLD STATE`)** = a concern event **attributable to the VM** whose ID is `3216` **or** whose message contains one of the HRESULTs listed below (`0x80048102`, `0x800480BD`, `0x800480BC`, `0x800703EE`). **As of v0.2.12, event ID `18590` on its own is NOT treated as the signature** — the Worker-channel `18590` is a guest-OS bugcheck (e.g. Stop `0x7E`), not a checkpoint failure, so counting the bare ID produced false positives. A genuine VMMS checkpoint fork-commit is still caught by its `0x80048102` HRESULT. All the IDs above are still collected and flagged `Concern = YES` for the timeline; they just don't, by ID alone, force a HOLD STATE.

### Informational context event IDs (`-ContextEventIds`)

These are **surfaced for the timeline** but are **never** flagged as a concern (on their own they are normal, healthy operations). Previously these were incorrectly stamped `Concern = YES`:

| Log | ID | Meaning |
|---|---|---|
| VMMS | `18500` | VM started successfully |
| VMMS | `18510` | Checkpoint completed |
| VMMS | `19070` | Background disk merge started |
| VMMS | `19080` | Background disk merge finished **successfully** |

> Event **collection** is intentionally **node-wide** — some of these events carry a blank or a different VM GUID, so scoping the *query* strictly to one VM would miss them. The per-VM **verdict**, however, only counts events **attributable to that VM** (the message names the VM or its VM ID); node-wide events that reference *other* VMs are surfaced as a node-context note and do not change a VM's state (v0.2.12). See [VM states (verdicts)](#vm-states-verdicts).

### HRESULTs (`-ErrorCodePatterns`)

| Code | Meaning | Role |
|---|---|---|
| `0x80048102` | `VM_E_COMMIT_FORKS_ERROR` | Checkpoint fork-commit failed — root-cause trigger |
| `0x800480BD` | `VM_E_FR_CHANGE_TRACKING_FAILED` | Replica change-tracking failure — leading indicator |
| `0x800480BC` | `VM_E_FR_RESYNC_REQUIRED` | Replica relationship broken — leading indicator |
| `0x80070020` | `ERROR_SHARING_VIOLATION` | Backup product cannot open the disk — symptom |
| `0x800703EE` | `ERROR_FILE_INVALID` | A volume changed underneath an open file |
| `0x80070002` | `ERROR_FILE_NOT_FOUND` | The `.avhdx` / VM config file is missing |

## VM states (verdicts)

Every audited VM is assigned exactly **one** state (the `Recommendation` property). The state is decided **per VM**, from that VM's own checkpoint chain plus only the Hyper-V events **attributable to that VM** (a concerning event counts toward a VM only when its message names that VM or its VM ID). Node-wide events that reference *other* VMs are reported as **context** and never, on their own, change a VM's verdict.

### State matrix

| State | When it is assigned (precise logic) | Typical example | What to do |
|---|---|---|---|
| **HOLD STATE** &nbsp;(data-loss risk) | A **fork-commit / merge-failure signature for this VM** is present **AND** the VM has unmerged differencing disk(s). Signature = a concern event **attributable to this VM** whose ID is `3216` **or** whose message contains one of the HRESULTs `0x80048102`, `0x800480BD`, `0x800480BC`, `0x800703EE`. "Unmerged disk(s)" = `HasAttachedCheckpoints` **or** `StaleCheckpointCount > 0`. | VM is running on 2 active `.avhdx` layers **and** a `3216` (or `0x80048102`) event names this VM. | **Do not** live/quick/storage-migrate or restart the VM until the chain is validated/merged. **Engage Microsoft Support (CSS)** to confirm the safe path. |
| **INVESTIGATE** | **Not** HOLD STATE, **and** at least one VM-scoped concern signal: `StaleCheckpointCount > 0` **or** `ConcernEventCount > 0` (concern events attributable to this VM) **or** an unhealthy VSS writer (`VssUnhealthyCount > 0`). | A backup checkpoint on this VM is 36 h old (≥ the 24 h `-StaleHours` threshold), or a VSS writer for this VM is in a failed/retryable state - but no fork-commit signature. | **Engage your third-party backup vendor first** (their product owns the checkpoint merge-after-backup). Review the backup job and the **VSS Writer Health** section; confirm whether an aged checkpoint is expected. Open a CSS case only if the vendor rules it out or a fork signature later appears. |
| **OK** | None of the above - no fork signature, no stale checkpoint, no VM-attributable concern events, no unhealthy VSS writer for this VM. | VM has **no checkpoints**, is running normally, replication healthy. The node has concerning events, but they reference **other** VMs (shown as a node-context note). | No action required. The node-context note lists how many events belong to other VMs (see the events CSV `VmAttributed` column). |
| **NOT FOUND** | The named VM was not found on any node of the cluster (collection outcome, not a health verdict). `ReportData` is `$null`; see `Detail`. | `-VMName 'Typo01'` where no such VM exists on the cluster. | Check the VM name / cluster; re-run. |
| **ERROR** | The audit could not complete for this VM - e.g. the cluster name could not be resolved, or an unexpected exception occurred (collection outcome). `ReportData` is `$null`; see `Detail` and the console. | `-Cluster 'BadName'` cannot be resolved, or remoting to the owning node failed. | Fix the underlying access/name/remoting issue (see [How it connects](#how-it-connects-no-double-hop)) and re-run. |

### Evaluation order (precedence)

The states are mutually exclusive and decided in this order:

1. **ERROR / NOT FOUND** - if data collection could not complete or the VM does not exist, that is the state (no health verdict is attempted).
2. **HOLD STATE** - fork-commit signature **for this VM** *and* unmerged differencing disk(s).
3. **INVESTIGATE** - not HOLD STATE, but at least one VM-scoped concern signal (stale checkpoint / this VM's concern events / unhealthy VSS).
4. **OK** - none of the above.

> **Why a checkpoint-free, healthy VM is `OK`, not `INVESTIGATE`:** the verdict only consumes events **attributable to the VM being audited**. A busy node can log many checkpoint/merge events for *other* VMs; those are surfaced as a node-context note but do not escalate a VM that has no checkpoints of its own and no concern events naming it. (This VM-scoping was introduced in v0.2.12; earlier versions counted node-wide events against every VM.)

Continuing to run a HOLD STATE / INVESTIGATE VM **in place** is generally safe (Hyper-V keeps using the in-memory chain state) - the risk is materialised by a migrate/restart. Both levels, and the report's Problem Statement, link the Microsoft Learn troubleshooting guide:

> [Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage)

## Enabling the Analytic channel (optional, operator's choice)

The internal per-disk `.vmcx` revert failure is traced only to `Hyper-V-VMMS/Analytic`, which is disabled by default. To capture it for future incidents, run **elevated on each node**:

```cmd
wevtutil sl Microsoft-Windows-Hyper-V-VMMS-Analytic /e:true /q:true
```

## Return value

By **default the script writes nothing to the pipeline** — the human-readable report goes to the host (and, with `-OutputPath`, to the per-VM `.txt` transcript + events `.csv`). This keeps `$x = .\Get-HyperVVMCheckpointHealth.ps1 ...` clean.

Add **`-PassThru`** to emit **one `[pscustomobject]` per VM** to the pipeline, in addition to the console report / files:

| Property | Type | Meaning |
|---|---|---|
| `VMName` | string | VM name audited. |
| `Cluster` | string | Cluster name. |
| `OwningNode` | string | Node that owns/runs the VM. |
| `Recommendation` | string | `HOLD STATE` / `INVESTIGATE` / `OK` / `NOT FOUND` / `ERROR`. |
| `HoldState` | bool | Fork-commit / merge-failure signature **and** unmerged differencing disk(s) present together (data-loss risk). |
| `HasAttachedCheckpoints` | bool | One or more active differencing (`.avhdx`) layers attached. |
| `HasStaleCheckpoints` | bool | One or more checkpoints ≥ `-StaleHours` old. |
| `HasOrphanedCheckpoints` | bool | Orphaned `.avhdx` present on disk (not part of any attached chain). |
| `AttachedCheckpointCount` | int | Count of active differencing layers across attached disks. |
| `StaleCheckpointCount` | int | Count of checkpoints ≥ `-StaleHours` old. |
| `ConcernEventCount` | int | Count of `Concern = YES` Hyper-V events **attributable to this VM** (the message names this VM or its VM ID). Node-wide concern events that reference other VMs are reported as context and are **not** counted here. |
| `ReportFile` | string | Path to this VM's `.txt` report (`$null` when `-OutputPath` omitted). |
| `Detail` | string | Extra context for `NOT FOUND` / `ERROR` rows. |
| `ReportData` | object | Rich per-VM detail (checkpoints, disks, replication, VSS, analytic, events, config version, and — for HOLD STATE — the Support Case summary) that the HTML fleet report renders. `$null` for `NOT FOUND` / `ERROR` rows. |

A row is emitted for **every** VM — including `NOT FOUND` / `ERROR` cases — so a fleet sweep always yields one object per VM:

```powershell
$r = .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' `
        -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name `
        -OutputPath 'C:\Temp\Reports' -PassThru

$r | Where-Object HoldState | Format-Table VMName, OwningNode, Recommendation
$r | Export-Csv 'C:\Temp\Reports\fleet-summary.csv' -NoTypeInformation
```

### Drilling into `ReportData`

The flat top-level properties are ideal for quick `Where-Object` / `Export-Csv` roll-ups. For deeper integration, the nested `ReportData` object exposes the same rich per-VM detail the HTML report renders — checkpoints, disks, replication, VSS writers, the Analytic-channel state, the concerning-event breakdown, config-version comparison, and (for HOLD STATE) the copy/paste Support Case summary:

```powershell
$r = .\Get-HyperVVMCheckpointHealth.ps1 -Cluster 'CLUS01' `
        -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name `
        -OutputPath 'C:\Temp\Reports' -PassThru

# Drill into the rich detail for any VM carrying the fork-commit signature
$r | Where-Object { $_.ReportData.HasForkSignature } |
    ForEach-Object { $_.ReportData.Checkpoints } |
    Format-Table Name, AgeHrs, Stale

# Every stale checkpoint across the whole fleet
$r | ForEach-Object {
    $_.ReportData.Checkpoints | Where-Object Stale |
        Select-Object @{n='VM';e={ $_.Name }}, AgeHrs
}

# Hyper-V Replica health (ReportData.Replication is a nested object, not a flat string)
$r | Where-Object { $_.ReportData.Replication.Enabled } |
    Select-Object VMName, @{n='ReplState';e={ $_.ReportData.Replication.State }},
                          @{n='ReplHealth';e={ $_.ReportData.Replication.Health }}
```

> **Note:** array members of `ReportData` (`Checkpoints`, `Orphans`, `VssUnhealthy`, `CsvVolumes`, `EventBreakdown`, `AnalyticNodesNeedEnable`) display as `System.Object[]` in a default list view — that is just the formatter; enumerate them (as above) to see the elements. `ReportData` is `$null` for `NOT FOUND` / `ERROR` rows, so guard with `Where-Object { $_.ReportData }` first if needed.
