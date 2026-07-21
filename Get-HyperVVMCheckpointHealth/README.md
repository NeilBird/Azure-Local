# Get-HyperVVMCheckpointHealth

> **Disclaimer:** This module is NOT a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT License](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

## Latest version:

- Module: `Get-HyperVVMCheckpointHealth`
- Updated: 2026-07-21
- Version: 0.2.19

## TL;DR

An example PowerShell module providing the `Get-HyperVVMCheckpointHealth` command, which performs a **read-only** audit of a VM's **checkpoint / differencing-disk chain, Hyper-V replication, and node event logs**. It automates the creation of a portable HTML Summary Report that highlights VMs with aged checkpoints, failing replication, and/or signals of concern that could occur during VM migration.

This module provides insights that should be used as part of an operator investigation. It is NOT intended to troubleshoot active issues, nor does it provide a root-cause analysis (RCA). It is ONLY suitable as a tool to surface existing event data or configuration drift for VM checkpoints and/or replication issues.

- **This module is NOT a supported service or offering from Microsoft. It is provided as example code only.**

> **See an example / fictitious report before running the module:** review the [synthetic Contoso HTML report](./examples/VMCheckpointAudit-contoso01-example.html) and the [screenshots below](#synthetic-example-report). It contains only invented `contoso01`, `node01`-`node10`, `TestVM01`-`TestVM20`, event, timestamp, and `C:\ClusterStorage\UserStorage_X\` volumes.

## Overview and details of intended use

This example module performs a read-only audit of a Hyper-V VM's **checkpoint / differencing-disk chain, Hyper-V replication, and specific diagnostic event data** on an Azure Local or Windows Server Failover Cluster. It can be used to surface the specific failure mode where a checkpoint **fork-commit failure** leaves a VM's on-disk (`.vmcx`) chain metadata inconsistent — an inconsistency that can stay **dormant while the VM runs** and then be **materialised by a live migration or restart**, which can potentially cause the VM to roll the disks back to their base VHDX file(s), which can result in the data that is / was stored in the AVHDX file(s) being orphaned.

The module is intended for Azure Local / Windows Server administrators / operators who need to audit the VMs running on a specific cluster — specifically for any anomalies in checkpoint, replication, or storage-related events. It generates automated output in the form of detailed `.txt` reports, `.csv` event-log data, and a portable **HTML summary** file that serves as the at-a-glance audit report.

## Contents

- [Safety — this module makes no changes](#safety--this-module-makes-no-changes)
- [Requirements](#requirements)
- [How it connects (no double-hop)](#how-it-connects-no-double-hop)
- [Download and import the module](#download-and-import-the-module)
- [Usage examples](#usage-examples)
- [Parameters, syntax and helpful information](#parameters-syntax-and-helpful-information)
- [What it reports](#what-it-reports)
- [Portable HTML report & results bundle](#portable-html-report--results-bundle)
- [Synthetic example report](#synthetic-example-report)
- [Output files](#output-files-only-with--outputpath)
- [VM states (verdicts)](#vm-states-verdicts)
- [Enabling the Analytic channel](#enabling-the-analytic-channel-optional-operators-choice)
- [Return value](#return-value)
- [Release packaging](#release-packaging-maintainers)
- [What's New](#whats-new)
- [Failure-signature reference](#failure-signature-reference)

## Safety — this module makes no changes

The module is **read-only** with respect to the VMs, disks, checkpoints, cluster, and event logs. Every data call is a `Get-*` / `Measure-*`, and the owner-context blocks only run read-only commands (`Get-VM`, `Get-VMHostSupportedVersion`, `Get-VHD`, `Get-VMSnapshot`, `Get-VMReplication`, `Get-Item`, `Get-ChildItem`, `Get-WinEvent`, `vssadmin list writers` (which only *enumerates* VSS writer state), and the storage-health snapshot `Get-StorageJob` / `Get-VirtualDisk` / `Get-PhysicalDisk` / `Get-StorageSubSystem` / `Get-ClusterSharedVolumeState`).

- It **never** creates/deletes/merges checkpoints, migrates, or changes VM/cluster state.
- The Analytic-channel enable command is **printed only** — never executed.
- The **only** filesystem writes are diagnostic **artifacts**: per-VM `.txt` reports, event `.csv` files, performance-telemetry JSON, and a conditional `_debug_log_*.txt` for unrecovered failures (with `-OutputPath`); a single self-contained **HTML** fleet report (on by default - in the `-OutputPath` run folder, or the current directory if `-OutputPath` is omitted); and a results **`.zip`** containing the run-folder artifacts (on by default when `-OutputPath` is used). Suppress the HTML/ZIP with `-NoHtml` / `-NoZip`. None of these change the VM, disks, checkpoints, or cluster.
- It is **diagnostic only** — it does not determine root cause definitively or remediate anything. For **backup / checkpoint-merge or VSS** findings, engage your **third-party backup vendor first** (their product owns the checkpoint lifecycle); **open a Microsoft Support (CSS) case** for a confirmed fork-commit signature, or when the vendor rules out their product. Act on their advice before taking action.

### Operational impact

Read-only does not mean zero resource use. The module performs metadata, event-log, RPC/WinRM, and filesystem reads. In particular, virtual-disk housekeeping enumerates VM/snapshot ownership across the cluster and recursively inventories VHD/VHDX/AVHDX files on Cluster Shared Volumes. Event-log scans and `vssadmin list writers` can also take time. These operations do not reconfigure workloads, but a broad run can add temporary CPU, storage, network, and management-plane load.

When running with `-ProcessAllVMs`, consider scheduling the audit outside core business hours, particularly on large or busy clusters. Review elapsed time and the performance-telemetry JSON to understand the impact in your environment before making fleet-wide runs part of a regular operating schedule.

The separate setup script changes files only beneath `<InstallRoot>\Get-HyperVVMCheckpointHealth` (`C:\Temp\Get-HyperVVMCheckpointHealth` by default). It verifies the release ZIP hash and staged module version before replacing that directory, restores the previous directory if installation validation fails, imports the command without running an audit, and supports `-WhatIf` for a no-change preview. Do not use an installation root where the `Get-HyperVVMCheckpointHealth` child directory contains unrelated files.

## Sensitive data handling

Treat every saved audit artifact as **sensitive operational data**. The `.txt`, `.csv`, `.html`, telemetry JSON, `_debug_log_*.txt`, and `.zip` can contain VM and node names, identifiers, storage paths, event payloads, command context, and application details.

- Write reports only to an access-controlled, operator-owned location. Do not use a broadly writable share or a public synchronization folder.
- Transfer artifacts to backup vendors or Microsoft Support only through your organization's approved secure support channel.
- The generated ZIP is a convenience bundle and is **not encrypted**. The module does not accept a ZIP password because command-line passwords are exposed through process history and logs. Apply your organization's approved encrypted-container or secure-transfer control after generation when required.
- Retain artifacts only for the active investigation and your required audit period, then delete all extracted copies and bundles according to policy.
- `-AnonymizeTelemetry` applies **only** to the performance-telemetry JSON. It does not redact TXT, CSV, HTML, ZIP content, file names, paths, or free-text event messages. Do not describe the report bundle as anonymized.
- Review event messages before wider sharing because free text can contain guest, application, account, or file information that deterministic name replacement would not reliably remove.
- The debug log is **not anonymized**. Review it before sharing and send it only through an approved secure support channel. It intentionally avoids credentials, bound-parameter dumps, and environment-variable dumps, but exact errors, paths, target objects, and source context can still be sensitive.

## Requirements

- **Windows PowerShell 5.1** with the **FailoverClusters** module available locally. This module is written for, and validated against, **Windows PowerShell 5.1 only** — it is **not** intended for PowerShell 7.x. The **Hyper-V** module is required on the cluster nodes, but not on an RSAT management workstation because Hyper-V collection runs on each VM's owning node through a direct WinRM session.
- Run it **on a cluster node** (interactive / SConfig logon), **or** from a **management workstation** using **`-Cluster <name>`** (with the RSAT **Failover Clustering** tools installed).
- On a **management workstation**, install the RSAT **Failover Clustering** tools so `Get-ClusterGroup` / `Get-Cluster` resolve locally (without them you get `Get-ClusterGroup : The term ... is not recognized`):
  ```powershell
  # Windows 10 / 11 client (run elevated)
  Add-WindowsCapability -Online -Name 'Rsat.FailoverCluster.Management.Tools~~~~0.0.1.0'

  # Windows Server (run elevated)
  Install-WindowsFeature -Name RSAT-Clustering-PowerShell
  ```
- Rights to query the cluster, Hyper-V, and the nodes' event logs. When the VM's owning node is not the local node, WinRM to that owning node is used for a **single** hop.

### Internal structure

Version 0.2.19 is distributed as a PowerShell module with a single exported command and manifest-managed private nested modules. Keep the extracted directory intact:

```text
Get-HyperVVMCheckpointHealth\
    Get-HyperVVMCheckpointHealth.psd1   # Import-Module entry point
    Get-HyperVVMCheckpointHealth.psm1   # exported command implementation
    Private\
        Get-HyperVVMCheckpointHealth.Assessment.psm1
        Get-HyperVVMCheckpointHealth.Collection.psm1
        Get-HyperVVMCheckpointHealth.Policy.psm1
        Get-HyperVVMCheckpointHealth.Rendering.psm1
        Get-HyperVVMCheckpointHealth.Storage.psm1
    checkpoint-health-policy.example.yml
    README.md
    LICENSE
```

The manifest exports only `Get-HyperVVMCheckpointHealth` and declares all five private modules under `NestedModules`. The root module owns the public parameter and pipeline contract, run orchestration, retry/diagnostic services, remoting-session coordination, and artifact writes. Event policy, attribution, coverage, recovery, replication, verdict, discovery-selection, and state-comparison decisions live in the assessment module. The compact VM state collector lives in collection; optional operator policy loading and policy assessments live in policy; the self-contained HTML renderer lives in rendering; stateless VHD-chain, staleness, ownership, housekeeping, and storage-health logic lives in storage. The two cluster-wide virtual-disk inventory coordinators remain in the root because they depend on its retry, diagnostics, and pooled-session lifecycle. Import the manifest rather than the root `.psm1`; bare root-module execution is intentionally rejected.

Do not download or move only the `.psm1` or `Private` files. Use the complete release ZIP so relative imports remain valid.

## How it connects (no double-hop)

The module is designed to avoid "double-hop" authentication failures (the `0x8009030e` Kerberos error you get when a remoting session tries to reach a second machine). It:

1. finds the cluster nodes and the VM's **owning node** using the **cluster API** (`Get-ClusterGroup` / `Get-ClusterNode` — RPC, no WinRM), then
2. runs every data-collection command in the **owner context** — **directly (locally)** when the current node owns the VM (zero hops), otherwise through **one** remoting session to the owning node.

Two supported ways to run it, both single-hop:

- **On a cluster node** (interactive / SConfig logon). VMs owned by that node are read locally (zero hops); VMs on other nodes are reached in one hop.
- **From a management workstation** with **`-Cluster <name>`** (RSAT Failover Clustering installed). The cluster queries use RPC and each owning node is reached in one hop from the workstation. If you build the `-VMName` list from a `Get-ClusterGroup` sub-expression, add `-Cluster <name>` to **that** query too — it runs locally and does not inherit the command's `-Cluster` (see the remote example in Usage).

> **Do not** `Enter-PSSession` into a node and then run the command: if the VM is owned by a *different* node, reaching it is a **second (double) hop** and is blocked (`Access is denied` / `0x8009030e`) unless CredSSP/delegation is configured. The module detects this and tells you to run it on a node or use `-Cluster`.

### Download and import the module

Download the versioned ZIP from the repository's [GitHub Releases page](https://github.com/NeilBird/Azure-Local/releases). The supported 0.2.19 release asset is `Get-HyperVVMCheckpointHealth-0.2.19.zip`; it contains the manifest, root module, five private modules, example policy YAML, README, and license. Do not use a raw single-file link because the module requires its manifest and sibling private modules.

The release also publishes [`Setup-Get-HyperVVMCheckpointHealth.ps1`](Setup-Get-HyperVVMCheckpointHealth.ps1) as a separate asset outside the ZIP. The setup script is pinned to the supported version and SHA256 hash, replaces only `C:\Temp\Get-HyperVVMCheckpointHealth` by default, validates the staged manifest/version, imports the module, and verifies the command. It does not run an audit. Use `-InstallRoot` to choose another parent directory.

Download the ZIP, download the setup script, and run the setup script:

```powershell
Invoke-WebRequest 'https://github.com/NeilBird/Azure-Local/releases/download/Get-HyperVVMCheckpointHealth-v0.2.19/Get-HyperVVMCheckpointHealth-0.2.19.zip' -OutFile "$env:TEMP\Get-HyperVVMCheckpointHealth-0.2.19.zip"
Invoke-WebRequest 'https://github.com/NeilBird/Azure-Local/releases/download/Get-HyperVVMCheckpointHealth-v0.2.19/Setup-Get-HyperVVMCheckpointHealth.ps1' -OutFile "$env:TEMP\Setup-Get-HyperVVMCheckpointHealth.ps1"
Unblock-File "$env:TEMP\Setup-Get-HyperVVMCheckpointHealth.ps1"; & "$env:TEMP\Setup-Get-HyperVVMCheckpointHealth.ps1" -ZipPath "$env:TEMP\Get-HyperVVMCheckpointHealth-0.2.19.zip"
```

Then run the audit separately. On a cluster node:

```powershell

# One VM, also writing a per-VM .txt report and events .csv into a folder
Get-HyperVVMCheckpointHealth -VMName 'TestVM01' -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Audit all VMs:
Get-HyperVVMCheckpointHealth -ProcessAllVMs -OutputPath C:\Temp\VM_Checkpoint_Reports
```

From a management workstation with the RSAT Failover Clustering tools installed:

```powershell
Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' -ProcessAllVMs -OutputPath C:\Temp\VM_Checkpoint_Reports
```

`-ProcessAllVMs` and `-VMName` are mutually exclusive. Use `-VMName` to audit a subset, with optional `-IncludeDiscoveredVMs` for additional VMs found through high-risk event evidence.

The release tag and all three assets must exist before the `Invoke-WebRequest` example works. Until the GitHub release is published, build or clone the repository and import the local manifest directly.

To install the extracted module into the current user's standard Windows PowerShell module path and import it later by name:

```powershell
$userModuleBase = Join-Path ([Environment]::GetFolderPath('MyDocuments')) `
    'WindowsPowerShell\Modules\Get-HyperVVMCheckpointHealth'
$versionModuleRoot = Join-Path $userModuleBase $version
New-Item -ItemType Directory -Path $versionModuleRoot -Force | Out-Null
Copy-Item -Path (Join-Path $moduleRoot '*') -Destination $versionModuleRoot -Recurse -Force

Import-Module Get-HyperVVMCheckpointHealth -RequiredVersion $version -Force
Get-Module Get-HyperVVMCheckpointHealth | Select-Object Name, Version, Path
```

Install it separately for each operator account that runs the audit, or place the same versioned module directory under an organization-managed all-users module path using your normal software deployment controls.

> **Names or objects:** `-VMName` accepts VM **names** *or* VM **objects** (from `Get-VM`), as an array or via the pipeline. VM objects are normalized to their `.Name` inside the command, so `-VMName $VMs`, `-VMName $VMs.Name`, and `Get-VM | ...` all work. Each VM is audited **independently** - one VM not being found (or erroring) does not stop the rest. An input that resolves to no name, or to a string >100 chars (e.g. a mistakenly joined list), is skipped with a warning.

## Usage examples

```powershell
# Basic audit of one VM (writes the default HTML report to the current directory)
Get-HyperVVMCheckpointHealth -VMName 'TestVM01'

# One VM, also writing a per-VM .txt report and events .csv into a folder
Get-HyperVVMCheckpointHealth -VMName 'TestVM01' -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Multiple VMs by name (array) - each gets its own .txt and .csv in the folder
Get-HyperVVMCheckpointHealth -VMName 'TestVM01','TestVM02' -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Every clustered VM - ON A NODE.
Get-HyperVVMCheckpointHealth -ProcessAllVMs -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# A specific list of VM names (piped) - the module resolves each VM's owning node itself
'VM01','VM02','VM03' | Get-HyperVVMCheckpointHealth -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# REMOTE: from a management workstation (RSAT Failover Clustering) - target a cluster by name.
# STEP 1 - verify the RSAT Failover Clustering tools are present on THIS workstation (see Requirements
# to install if this returns nothing / $false). Get-ClusterGroup and Get-Cluster come from this module.
if (Get-Module -ListAvailable FailoverClusters) { 'FailoverClusters: OK' } else { 'FailoverClusters: MISSING - install RSAT (see Requirements)' }
Get-Command Get-ClusterGroup -ErrorAction SilentlyContinue   # should resolve; blank = tools not installed

# STEP 2 - run it. -ProcessAllVMs enumerates the named cluster, so -Cluster is supplied once.
Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' -ProcessAllVMs -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Equivalent remote pipeline form (names gathered from the remote cluster, then piped in)
Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine' |
    Select-Object -ExpandProperty Name |
    Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Wider event look-back (14 days, vs the 7-day default) and a lower stale threshold (12h)
Get-HyperVVMCheckpointHealth -VMName 'TestVM01' -EventLookbackHours 336 -StaleHours 12

# Skip the event-log scan and the Analytic-channel check (fastest, disk/checkpoint state only)
Get-HyperVVMCheckpointHealth -VMName 'TestVM01' -SkipWorkerEvents -SkipAnalyticCheck

# -PassThru: also emit one object per VM to the pipeline (for Where-Object / Export-Csv / roll-ups)
$r = Get-HyperVVMCheckpointHealth -VMName 'TestVM01','TestVM02' -OutputPath 'C:\Temp\VM_Checkpoint_Reports' -PassThru
$r | Where-Object HoldState | Format-Table VMName, OwningNode, Recommendation

# HTML fleet report + results .zip are produced BY DEFAULT (into the -OutputPath run folder). The
# console is quiet by default (one-line verdict per VM); the .txt and HTML still hold the full detail.
Get-HyperVVMCheckpointHealth -VMName 'VM01','VM02' -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Full per-VM report on the console as well as the files
Get-HyperVVMCheckpointHealth -VMName 'VM01' -OutputPath 'C:\Temp\VM_Checkpoint_Reports' -Quiet:$false

# Also audit high-risk VMs DISCOVERED in the event data (uncapped unless -MaxDiscoveredVMs is supplied)
Get-HyperVVMCheckpointHealth -VMName 'VM01' -OutputPath 'C:\Temp\VM_Checkpoint_Reports' -IncludeDiscoveredVMs

# Audit every clustered VM EXCEPT those named in an exclusion CSV (single 'VMName' column, case-insensitive)
Get-HyperVVMCheckpointHealth -ProcessAllVMs -ExcludedVMListCsv '.\CheckPointAudit_Excluded_VMs.csv' -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Apply an optional schema-versioned policy for image/live-mount paths, CSV free space, and HRL cadence.
# powershell-yaml is required only when -PolicyPath is supplied.
Install-Module powershell-yaml -Scope CurrentUser
Get-HyperVVMCheckpointHealth -VMName 'VM01' -PolicyPath '.\checkpoint-health-policy.yml' -OutputPath 'C:\Temp\VM_Checkpoint_Reports'

# Choose the HTML location explicitly (folder or full .html path); suppress the zip and/or HTML
Get-HyperVVMCheckpointHealth -VMName 'VM01' -OutputPath 'C:\Temp\VM_Checkpoint_Reports' -HtmlReportPath 'C:\Reports\audit.html' -NoZip
```

### Optional policy file

`checkpoint-health-policy.example.yml` is an operator template, not an automatically discovered configuration file. Downloading, extracting, renaming, or editing it does **not** change command behavior. The module reads YAML only when that exact file path is supplied with `-PolicyPath`:

```powershell
Get-HyperVVMCheckpointHealth -VMName 'VM01' `
    -PolicyPath 'C:\Temp\Get-HyperVVMCheckpointHealth\checkpoint-health-policy.example.yml' `
    -OutputPath 'C:\Temp\VM_Checkpoint_Reports'
```

Without `-PolicyPath`, the command does not search the current directory, module directory, or `-OutputPath`; it uses the built-in policy below and does not require `powershell-yaml`.

| Policy setting | Built-in value | Effect |
|---|---|---|
| `schemaVersion` | `1` | Identifies the supported YAML contract. A supplied policy must contain `schemaVersion: 1`. |
| `storage.imageLibraryPathPatterns` | `(?i)[\\/](?:image|images|imagestore|template|templates|library|gallery|golden)(?:[\\/]|$)` | Excludes matching VHD, VHDX, and AVHDX paths from cluster/storage housekeeping findings. Exact `ImageStore` path segments and versioned `linux-cblmariner-x.x.x.x.vhdx` ARB appliance images are always excluded, including when a supplied policy uses `[]`; add patterns for other known image repositories. This affects housekeeping observations only and never changes VM health verdicts. |
| `orphan.liveMountPathPatterns` | `(?i)rubriklivemount`, `(?i)_temp_` | Classifies matching orphan AVHDX paths as backup live-mount/instant-recovery evidence. |
| `orphan.classifyZeroByteAsLiveMount` | `true` | Also classifies a zero-byte orphan AVHDX as live-mount evidence. |
| `csvFreeSpace.enabled` | `false` | CSV free-space policy does not affect the verdict unless explicitly enabled. |
| `csvFreeSpace.minimumFreePercent` | `15` | When CSV policy is enabled, free space below 15% is a breach. |
| `csvFreeSpace.minimumFreeGB` | `100` | When CSV policy is enabled, free space below 100 GB is a breach. Either CSV threshold breach drives `INVESTIGATE`, never `HOLD STATE`. |
| `replication.hrl.enabled` | `true` | Enables cadence-aware HRL assessment. |
| `replication.hrl.cadenceMultiplier` | `10` | Multiplies the Replica frequency when calculating the HRL age threshold. |
| `replication.hrl.minimumStaleMinutes` | `15` | Sets the minimum HRL age threshold. Effective threshold: `max(15 minutes, FrequencySec / 60 x 10)`. |
| `replication.hrl.requireReplicationConcern` | `true` | Prevents HRL age alone from escalating a healthy or idle Replica relationship. Typed Replica health or measurement concern must corroborate it. |

When `-PolicyPath` is supplied, the loader starts with these built-in values and overlays only the keys present in the YAML file. Omitted sections and properties retain their built-in values. A supplied `imageLibraryPathPatterns` or `liveMountPathPatterns` array replaces the complete configurable built-in array; it is not appended. Use `[]` to intentionally configure no additional patterns for that category. Exact `ImageStore` segments and versioned `linux-cblmariner-x.x.x.x.vhdx` ARB appliance image names remain automatic housekeeping exclusions even when `imageLibraryPathPatterns: []` is supplied.

The **Cluster / storage housekeeping to review** table omits virtual disks whose full paths match the automatic `ImageStore` exclusion, whose file name matches the versioned ARB appliance image form `linux-cblmariner-x.x.x.x.vhdx` (numeric components), or whose path matches a configured `storage.imageLibraryPathPatterns` expression. For another known image repository, create a policy file and pass it explicitly:

```yaml
schemaVersion: 1
storage:
    imageLibraryPathPatterns:
        - '(?i)[\\/]MyImageRepository(?:[\\/]|$)'
```

```powershell
Get-HyperVVMCheckpointHealth -VMName 'VM01' `
        -PolicyPath '.\checkpoint-health-policy.yml' `
        -OutputPath 'C:\Temp\VM_Checkpoint_Reports'
```

Patterns are evaluated against the complete path and should identify an intentional repository directory, not a broad incidental substring. Exclusion only removes that file from housekeeping observations; it does not authorize file modification or deletion. For a non-excluded finding, the HTML asks whether it belongs to an image library and points to this policy mechanism before advising the operator to confirm ownership and storage layout.

The policy is loaded once before cluster collection. The module imports `powershell-yaml` only for this path. It stops the run for a missing/empty file, unsupported schema version, invalid regex, `minimumFreePercent` outside `0..100`, negative `minimumFreeGB`, `cadenceMultiplier` below `1`, or `minimumStaleMinutes` below `1`. The HTML and `-PassThru` `ReportData.PolicySource` value show `BuiltInDefaults` or the full loaded policy path so an operator can confirm which source was active.

These YAML settings are separate from normal command parameters such as `-StaleHours`, the absolute Replica limits, and the cadence-aware Replica limits; those parameter defaults remain documented in the table below and are not changed by the YAML policy.

## Parameters, syntax and helpful information

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-VMName` | object[] (mandatory in `ByName`) | — | One or more VM **names** or VM **objects** (from `Get-VM`). Accepts an array and pipeline input (aliases `Name`, `VM`). Objects are normalized to `.Name`; names >100 chars are skipped with a warning. Mutually exclusive with `-ProcessAllVMs`. |
| `-ProcessAllVMs` | switch (mandatory in `AllVMs`) | off | Audit every clustered VM on the local cluster, or on the cluster named by `-Cluster`. Mutually exclusive with `-VMName`; `-ExcludedVMListCsv` still applies. |
| `-Cluster` | string | — | Optional. Target a cluster **by name** so the module can run from a **management workstation** (RSAT Failover Clustering) instead of on a node — cluster queries use RPC and each owning node is reached in a **single** hop. When omitted, the command targets the **local** cluster and a `Get-Cluster` guard rail requires you to be **on a cluster node** (it fails clearly if not). |
| `-OutputPath` | string | — | Optional **base folder** for reports. Each run creates a timestamped sub-folder containing per-VM `.txt` transcripts, event `.csv` files, telemetry JSON, and the default HTML report; the ZIP is written beside that folder. If omitted, no run folder, TXT, CSV, telemetry JSON, or ZIP is created, but the default HTML report is still written to the current directory unless `-NoHtml` is supplied. |
| `-StaleHours` | int | `24` | Age (hours) at/beyond which a checkpoint or differencing disk is flagged `Stale = YES`. If your backup product legitimately keeps checkpoints for longer (e.g. a 48-hour retention window), raise this (e.g. `-StaleHours 48`) so expected long-lived checkpoints are not flagged. |
| `-MaxReplicationAgeMinutes` | int | `60` | Absolute age guardrail. The effective age limit is the larger of this value and `FrequencySec x MaxReplicationAgeCycles`. |
| `-MaxReplicationAgeCycles` | int | `12` | Cadence-aware age allowance, measured in relationship replication cycles. |
| `-MaxPendingReplicationMB` | long | `1024` | Absolute pending-backlog guardrail. The effective backlog limit is the larger of this value and average replication bytes x `MaxPendingReplicationCycles`. |
| `-MaxPendingReplicationCycles` | int | `2` | Workload-relative pending-backlog allowance, measured in average replication batches. |
| `-MaxReplicationLatencySeconds` | int | `300` | Absolute latency guardrail. The effective latency limit is the larger of this value and `FrequencySec x MaxReplicationLatencyCycles`. |
| `-MaxReplicationLatencyCycles` | int | `2` | Cadence-aware latency allowance, measured in relationship replication cycles. |
| `-MaxMissedReplicationCount` | int | `0` | Absolute missed-cycle advisory threshold. A breach becomes a material concern only when the minimum count and missed-rate guardrails are also met. |
| `-MaxMissedReplicationRatePercent` | int | `10` | Maximum missed-cycle percentage across the available Replica monitoring window. |
| `-MinMissedReplicationCountForConcern` | int | `3` | Minimum missed count required before missed-cycle evidence becomes a material concern. An isolated miss remains advisory when product health/state is Normal. |
| `-SkipWorkerEvents` | switch | off | Skip the Hyper-V Worker/VMMS event-log scan. |
| `-EventLookbackHours` | int | `168` (7 days) | How far back the event scan looks (1–720). |
| `-WorkerEventIds` | int[] | see below | Event IDs that indicate a genuine **problem** and drive the `Concern = YES` flag (node-wide match). |
| `-ContextEventIds` | int[] | see below | **Informational** lifecycle event IDs. These are still **surfaced** for the timeline but are **never** flagged as a concern (e.g. VM started, checkpoint completed, merge started / finished OK). |
| `-ErrorCodePatterns` | string[] | see below | HRESULT strings flagged as a concern when present in an event message. |
| `-SkipAnalyticCheck` | switch | off | Skip the per-node `Hyper-V-VMMS/Analytic` channel state check. |
| `-PassThru` | switch | off | Emit **one `[pscustomobject]` per VM** to the pipeline (for `Where-Object` / `Export-Csv` / fleet roll-ups). Without it, **nothing** is written to the pipeline; HTML remains the primary report and `-OutputPath` also creates `.txt`/`.csv` files. See [Return value](#return-value). |
| `-Quiet` | bool | `$true` | Console verbosity. **Quiet by default**: the full per-VM report still goes to the `.txt` and HTML, while the console shows only a concise one-line verdict per VM plus the final HTML/zip pointers. Pass `-Quiet:$false` to stream the complete per-VM report to the console too. |
| `-HtmlReportPath` | string | — | Where to write the portable HTML fleet report. Accepts a **folder** (auto-named `VMCheckpointAudit-<Cluster>-yyyy-MM-dd.html`) or a full path ending in `.html`. Defaults to the `-OutputPath` run folder; if `-OutputPath` is omitted too, the current directory. |
| `-NoHtml` | switch | off | Suppress the HTML fleet report (generated by default). |
| `-NoZip` | switch | off | Suppress the results `.zip` bundle (created by default when `-OutputPath` is supplied). |
| `-IncludeDiscoveredVMs` | switch | off | Also audit VMs **discovered** in the owning node's event data with a **high-risk** signal (merge interrupted/failed, sharing violation `0x80070020`, or cannot-load-config) but not in the audit list. Such VMs are **always surfaced** (console + HTML); this switch additionally audits all validated discoveries, non-recursively. |
| `-MaxDiscoveredVMs` | nullable int | — | Optional explicit cap for `-IncludeDiscoveredVMs`. When omitted, every validated discovery is audited. When supplied, strongest evidence is selected first and deferred VMs remain visible in output. |
| `-ExcludedVMListCsv` | string | — | Optional path to a CSV listing VM names to **exclude** from the audit. Single column with a `VMName` header (a headerless single-column file also works). Read **once** at start; any requested / piped VM whose name matches (**case-insensitive**) is skipped **before** it is audited, and excluded VMs are **not** auto-audited via `-IncludeDiscoveredVMs` either. A relative path (e.g. `.\CheckPointAudit_Excluded_VMs.csv`, in the module folder) resolves against the current directory. There is **no** `Test-Path` parameter validation — a missing / unreadable file is a non-fatal warning (the run proceeds with no exclusions). Handy to permanently omit known-noisy or intentionally long-checkpointed VMs from a fleet run. |
| `-PolicyPath` | string | — | Optional path to a `schemaVersion: 1` YAML policy. It can replace full-path regex lists used for image-library and backup live-mount classification, enable CSV percentage/absolute free-space thresholds, and tune cadence-aware HRL assessment. The file is loaded once before cluster collection and invalid schemas, values, or regexes stop the run. Requires the optional `powershell-yaml` module only when supplied. Start from `checkpoint-health-policy.example.yml`. |
| `-SkipStorageHealth` | switch | off | Skip the read-only cluster storage-health snapshot (S2D storage jobs, CSV state, virtual/physical disk health). On by default; gathered once per run. |
| `-AnonymizeTelemetry` | switch | off | Anonymise the internal per-step performance-telemetry JSON (v0.2.15). When set, the cluster / node / VM names in the telemetry file **and** its file name (which becomes `code_execution_perf_telemetry_anon_<stamp>.json`) are replaced with stable pseudonyms (`CLUSTER`, `NODE-01`, `VM-001`) so the timing data can be shared for performance analysis without exposing customer identifiers. Affects **only** the telemetry JSON — the `.txt` / `.csv` / `.html` are unchanged. |
| `-NoColour` (`-NoColor`) | switch | off | Colour is **on by default** for interactive consoles (headings + RESULT/WARNING/HOLD STATE). It auto-disables when output is redirected (`> file`, `Out-File`, `$x = Get-HyperVVMCheckpointHealth ...`) so captured text stays readable; the `-OutputPath` transcript captures the lines as plain text either way. Pass `-NoColour` to force plain output. |

## What it reports

1. **Header** — cluster, VM name, VM Id (GUID), owning node, status/state, **VM config version** and the **latest version supported by the cluster** (via `Get-VMHostSupportedVersion`), uptime, then two checkpoint-config fields, the stale threshold and run time (UTC). When the VM's config version is older than the latest, a separate low **VM Configuration Version** section notes this as *migration / start* context — with the exact wording from the Microsoft guide and the `Update-VMVersion` remediation — and states explicitly that it is **not** a cause of the checkpoint/merge failure being investigated.
   - **Auto Checkpoints** (`AutomaticCheckpointsEnabled`) — when `True`, Hyper-V takes a checkpoint **automatically every time the VM starts** (a Client Hyper-V default; normally `False` on servers/clusters). A `True` here explains "unexpected" `.avhdx` layers appearing on boot.
   - **Checkpoint Type** (`CheckpointType`) — the style of checkpoint the VM is configured to take, which governs how each checkpoint's fork is committed: `Production` = app-consistent via in-guest VSS (falls back to Standard if VSS is unavailable); `ProductionOnly` = same but fails with no fallback; `Standard` = captures saved memory/running state (dev/test); `Disabled` = checkpoints not allowed. The value is annotated inline in the output.
2. **VM configuration (`.vmcx`)** — the config file path plus its last-write time and age (the failure mode hinges on stale on-disk chain metadata living here).
3. **Disk chain** — presented in three parts: an **overview table** (one row per attached disk: type, size, chain depth, checkpoint count, stale), a **per-disk detail block** (labelled `Disk File Name` / `Disk Full Path` plus type, size, created/last-write (UTC), age, stale — full path never truncated), and **differencing-chain detail shown only for disks that actually have a checkpoint layer** (depth > 1).
4. **Checkpoints** (`Get-VMSnapshot`) — name, type, a derived **Purpose** (backup vs Replica vs manual), age, stale flag, parent.
5. **Orphaned `.avhdx`** — files on disk in the VM's VHD folders that are **not** part of any attached chain (a stuck / failed merge or a leftover replica recovery point can leave these behind). Each is listed with its **size, created (UTC) and last-write (UTC)** timestamps and full path. Finding **any** orphan flags the VM **INVESTIGATE** (confirm with your backup team before removing — the module never deletes anything). In the HTML report each orphan is given a neutral evidence class: **RollbackFingerprintCandidate**, **StuckMerge**, **TransientDeleteLockObserved**, **LiveMount**, or **Leftover**. `-PolicyPath` can replace the full-path regular expressions used for live-mount/instant-recovery classification. The report never treats a pattern match as proof that removal is safe.
6. **Replica change logs (`.hrl`)** — per-VHD replication logs assessed against Replica cadence: `max(minimumStaleMinutes, FrequencySec x cadenceMultiplier)`. By default, age escalates only when typed Replica health or measurements independently indicate a concern, avoiding false alarms for idle but healthy relationships.
7. **Cluster Shared Volume free space** — scoped to the volume(s) hosting this VM's disks (falls back to all cluster volumes if it cannot match). The optional YAML policy can enable both minimum-free-percent and minimum-free-GB thresholds; either breach drives `INVESTIGATE` as storage capacity evidence, never as fork-commit proof.
8. **Cluster role** (`Get-ClusterGroup`) — clustered role state and current owner, projected from the once-per-run cluster-group cache.
9. **Hyper-V Replica** - `Get-VMReplication` product health/state remains authoritative, while `Measure-VMReplication` supplies throughput, backlog, latency, successful cycles, and missed cycles. The assessment uses each relationship's actual `FrequencySec`, average replication size, and the host's read-only `Get-VMReplicationServer` monitoring window. Absolute parameters remain guardrails. A measurement can be **Advisory** without changing the VM verdict; only product Warning/Critical/Unknown evidence or a material measurement concern drives `INVESTIGATE`. Each Replica-enabled per-VM card retains a concise summary and adds a relationship/measurement details table. The table is collapsed when healthy and opens automatically for advisory, concern, abnormal product health/state, or unavailable measurement evidence.
10. **Worker/VMMS event scan** — recent events matching the VM (name **or** GUID), any listed HRESULT, or any listed event ID. Each row is marked `Concern = YES` **only** for a genuine problem (an HRESULT match or a concern event ID); informational lifecycle events (VM started, checkpoint completed, merge started / finished OK) are listed for context but left blank. To keep the report readable, repeated rows for the same event ID are **collapsed** in the console / `.txt` (the first few are shown, followed by a `Removed N duplicate Event ID X entries - Review CSV file for full details.` note); the **full untruncated text of every event is written to the CSV**.
11. **Analytic channel (per node)** — whether `Hyper-V-VMMS/Analytic` is enabled; prints the enable command where it is not. The cluster-wide state is queried once per run and reused for every VM. This channel is optional diagnostic context only: its enabled, disabled, or empty state never drives **CANNOT CONFIRM**, `INVESTIGATE`, or assessment confidence.
12. **VSS writer health** (`vssadmin list writers` — read-only) — flags any VSS writer whose state is not `Stable` or that reports a last error. Failed / timed-out VSS writers are a leading cause of Hyper-V checkpoint / backup failures (per the Microsoft troubleshooting guide).
13. **Summary** — checkpoint count, stale-checkpoint + backup-check guidance, event-concern warning, and a **severity assessment**: **HOLD STATE (data-loss risk)** when a confirmed fork-commit / merge signature accompanies unmerged differencing disk(s), or **INVESTIGATE** when only symptom-level signals (e.g. an aged backup checkpoint, an orphaned `.avhdx`, an unhealthy replica, or an unhealthy VSS writer) are present. Each includes a plain-language "why flagged" line and links the Microsoft Learn troubleshooting article.
14. **Problem Statement (for a Microsoft Support / CSS case)** — a copy/paste-ready block: cluster/owner/VM, plain-language findings, concerning events grouped by ID with first/last timestamps, the severity assessment, any unhealthy VSS writers, the requested action, the artifacts to attach (the `.txt` report and events `.csv`, by path), and the Microsoft Learn reference. It always closes with a reminder that the report is diagnostic only and that interpretation / remediation should go through a Microsoft Support (CSS) case.

> **Progress:** while running, the command shows a parent progress bar (`VM X of Y`) with a per-VM sub-bar that updates through each section (resolving the VM, cluster role, disks, checkpoints, the event-log scan, etc.) — useful on a busy or large cluster where operations like the event-log scan can take time. Progress uses the PowerShell progress stream, so it never appears in the transcript, redirected output, or the returned value.

15. **Cluster storage health (Storage Spaces Direct / CSV)** — a read-only, cluster-wide snapshot (gathered **once** per run): active `Get-StorageJob` repair/resync jobs, CSVs in redirected/paused state, and any unhealthy virtual/physical disks. Storage-layer disruption is a plausible contributing factor for the merge / `0x80070020` / `16300` symptoms (files transiently locked or unavailable). The HTML also recommends Microsoft's CSS **Storage Diagnostic** (`Install-Module -Name Microsoft.AzLocal.CSSTools`; then `Start-AzsSupportStorageDiagnostic`) for a deep S2D / SBL analysis. Skip with `-SkipStorageHealth`.
16. **Discovered high-risk VMs** — VMs referenced in the node's **high-risk** event signals (merge interrupted / failed, `0x80070020`, cannot-load-config) but **not** in the audit list, cross-checked against real clustered VMs. Always **surfaced** (console + HTML) with a ready-to-run command; audited automatically only with `-IncludeDiscoveredVMs` (non-recursive and uncapped unless `-MaxDiscoveredVMs` is supplied).
17. **Historic cross-node event correlation** (v0.2.15) — shown **only** for a VM that has orphaned `.avhdx` files. The original fork-commit / merge events that produced the orphans can be far older than `-EventLookbackHours` (a rollback that happened days or weeks ago), so this targeted scan looks for **this VM's** fork-commit / merge events in windows around **both** each orphan's **creation** time (the checkpoint / fork-commit moment) **and** its **last-write** time (when a later migration / restart froze it — the two can be days apart), across **every** cluster node (single hop each — the VM may have been owned by a different node at the time). Overlapping / adjacent windows are merged into contiguous ranges (so one `Get-WinEvent` query covers them, correctly spanning midnight / month-end). It checks enablement and reads the oldest available event in each required `Hyper-V-Worker/Admin` and `Hyper-V-VMMS/Admin` log. An enabled channel with zero records is classified `EnabledEmpty` and is valid negative evidence; it is common on a node that has not emitted Worker events. A disabled or unqueryable required Admin channel is incomplete, while retained history newer than the search window is `Wrapped`. A recovered fork-commit event here is treated as **CONFIRMED** evidence a past rollback occurred.
18. **Active-checkpoint historic look-back + required-channel coverage check** (v0.2.17 / v0.2.18) — the same shared cross-node scan is now **also** run **proactively** for a VM that carries an **active (still-attached) checkpoint whose creation time predates `-EventLookbackHours`**. Because the standard node scan cannot reach back to when such a checkpoint was created, a fork-commit at that moment would otherwise be invisible while the VM keeps running with a dormant, inconsistent chain that a later live migration or restart could materialise. If a **confirming fork-commit** event is recovered at the checkpoint's creation time, the still-attached chain is classified **HOLD STATE** with clear "do not migrate/restart until the chain is validated" steps. If **no** event is found and any required Worker/VMMS Admin scope is `Wrapped`, `Disabled`, or `Unavailable` (including a failed query), the VM remains **INVESTIGATE / CANNOT CONFIRM**: incomplete coverage is not confirming evidence, but absence of evidence is not proof that migration or restart is safe. The report identifies the incomplete node/channel scopes; a `Wrapped` scope also shows the **checkpoint created** vs **oldest available event** timestamps. An enabled required Admin channel with zero records is `EnabledEmpty`, which is sufficient coverage and does **not** cause **CANNOT CONFIRM**. This scan is cluster-wide by design (a long-lived checkpoint may have survived migrations across nodes) and cheap (a few narrow windows). The optional VMMS Analytic channel is excluded from this coverage decision.

## Portable HTML report & results bundle

By default the run produces a single **self-contained HTML fleet report** (`VMCheckpointAudit-<Cluster>-<yyyy-MM-dd>.html`) — dark-themed, no external assets, safe to email or open on any device with a browser. The header states the cluster, module version, and (from v0.2.14) a run summary line: **`Processed <N> VMs, across <M> cluster nodes, in hh:mm:ss`** — the end-to-end wall-clock time to audit the fleet and render the report. Its summary starts with a full-width **VM(s) audited** card, followed on desktop by one seven-card metric row: **Hold state**, **Investigate**, **OK**, **Incomplete**, **Stale AVHDX layers**, **Stale snapshots**, and **Orphaned .avhdx** (the last card sits at the far right). The grid responsively reduces to four, two, then one column on narrower screens. The report also contains: a **Recommended next steps** list (see below); a **VM summary table** with a **VM Source** column (Input vs auto-**Discovered**), distinct **Checkpoints** (`Get-VMSnapshot` count) and **AVHDX files** (differencing layers = Checkpoints × Disks) columns, an **Oldest ckpt age** shown in **both hours and days** — and (v0.2.15) each VM name is an **anchor link** that jumps to that VM's detail card; a **Discovered high-risk VMs** section; **per-VM detailed information** (including a per-VM **Checkpoints** table whose **Age** column shows each checkpoint's age in **hours and days**, a per-VM **Orphaned .avhdx files** table — name, size, created + last-write timestamps, per-orphan **class** and **Likely / action** read, full path — a **Historic event correlation** section when the VM has orphans, and, for HOLD STATE VMs, a copy/paste **Support Case summary**); a **Cluster storage health** section; and (v0.2.16) an **Appendix - Knowledge and Information** section whose two reference blocks are **collapsed by default** behind a clear **&#9654; Show / &#9660; Hide** button - a **Diagnostic event IDs - severity classification** table (how the tool grades each ID / HRESULT into the HOLD STATE / INVESTIGATE / low-signal / informational tiers) and the anonymised **technical background** explaining the fork-commit signature and the exact Event IDs / HRESULTs that indicate it. The Microsoft Learn troubleshooting reference sits at the top of the Appendix (always visible).

**Actionable per-VM evidence (v0.2.19):** whenever a differencing layer is present, the VM card includes an open **Attached VHD chain evidence** table with the layer type, size, timestamps, age/stale assessment, full path, and parent path. This substantiates stale-layer and snapshot/layer-mismatch findings even when `Get-VMSnapshot` exposes no matching named checkpoint. `INVESTIGATE` guidance is selected by the actual driver: checkpoint/storage findings retain chain-validation context, while Replica-only findings direct the operator to the Replica evidence and breached effective limits rather than displaying an unrelated fork-commit disclaimer.

**Readability — sparing, semantic colour (v0.2.17):** the report uses colour only where it aids triage, drawn from the dark theme so it stays legible: verdict pills (**HOLD STATE** red / **INVESTIGATE** amber / **OK** green); **amber** for a warning value — a stale `YES`, a non-zero **Orphans** / **Stale** count, or an oldest-checkpoint age at/over the `-StaleHours` threshold — with a **muted grey `0`** so clean rows recede and real counts stand out; and **bold soft-red** for the single most important imperative (*"Do NOT migrate or restart this VM"* / *"Do NOT live/quick/storage-migrate or restart"*) inside a HOLD STATE / pre-migration callout.

### Synthetic example report

The source-controlled [synthetic HTML report](./examples/VMCheckpointAudit-contoso01-example.html) is generated by the current production renderer, not hand-authored HTML. It models a 10-node `contoso01` cluster with 20 VMs: 16 input VMs, 4 automatically discovered VMs, 1 active-checkpoint **HOLD STATE**, 7 **INVESTIGATE**, and 12 **OK**. Its invented findings include a confirmed historic rollback recovery case, orphaned AVHDX files, stale named checkpoints and attached layers, unhealthy Hyper-V Replica states, and review-only virtual-disk housekeeping observations. All 20 synthetic VMs have healthy VSS writers.

GitHub displays repository HTML as source rather than running it. To use the interactive report, download [VMCheckpointAudit-contoso01-example.html](./examples/VMCheckpointAudit-contoso01-example.html), then open that self-contained file in a browser. Maintainers can reproduce it with [New-SyntheticExampleReport.ps1](./examples/New-SyntheticExampleReport.ps1); the generator parses `ConvertTo-VMCheckpointAuditHtml` from the module and fails if its approved synthetic identity or storage-path rules are violated.

**Fleet summary and mixed verdicts**

![Synthetic contoso01 fleet summary showing one HOLD STATE and seven INVESTIGATE VMs](./docs/images/checkpoint-health-example-summary.png)

**Active-checkpoint HOLD STATE confirmed by the all-node historic event look-back**

![Synthetic TestVM07 active-checkpoint HOLD STATE detail](./docs/images/checkpoint-health-example-active-hold.png)

**Confirmed historic rollback recovery case**

![Synthetic TestVM01 confirmed historic rollback detail](./docs/images/checkpoint-health-example-historic-rollback.png)

**Cluster and storage housekeeping review**

![Synthetic review-only virtual disk placement and inventory findings](./docs/images/checkpoint-health-example-housekeeping.png)

The housekeeping findings deliberately include `.vhdx` files that are not referenced by a VM or snapshot chain, a disk stored beneath another VM's folder, and a shared-reference candidate. These are **review observations, not deletion instructions**. A base `.vhdx` candidate is not an orphaned checkpoint AVHDX and does not change a VM health verdict; confirm ownership, image-library intent, backup retention, and storage layout before moving or deleting anything.

CSV inventory skips the exact Windows metadata folder `System Volume Information`; it cannot contain workload virtual disks and its normal access restrictions do not make coverage incomplete. If another folder beneath a readable CSV cannot be enumerated, readable branches are retained but coverage remains incomplete and the report adds **CSV folder path inaccessible** with the exact failed path. A CSV root that cannot be opened remains **CSV root incomplete**.

The self-contained HTML retains each finding's exact byte length, extension, full path, parent path, CSV root, and timestamps. It shows human-readable and exact-byte totals, deduplicated case-insensitively by full path. All category checkboxes are enabled by default; unchecking a category removes its rows and updates the visible count, unique-file bytes, storage-by-category chart, and top-parent-path chart. Search, CSV-root, extension, minimum-size, and sortable-column controls require no network connection or external JavaScript.

Every HTML Executive Summary includes a persistent **Report scope** notice stating the audited VM count, UTC generation time, and point-in-time nature of the read-only assessment. It clarifies that the findings form part of a wider cluster, storage, backup, workload, and operational-history assessment rather than a complete cluster health assessment. When discoveries remain unaudited, an additional **Audit coverage** sentence states their count and excludes them explicitly from the findings and summary totals.

### Recommended next steps (context-gated)

Near the top of the report, a **Recommended next steps** list shows only the advice that is **actually actionable for this run** — each bullet is gated on what the audit found across the fleet, so a clean run stays short and a problem run surfaces exactly the relevant guidance:

- **Backup team first** / **Confirm expected vs abandoned** — shown when ≥ 1 **stale** checkpoint was found across the fleet.
- **INVESTIGATE — backup checkpoint / merge appears to be failing** — shown when ≥ 1 VM is **INVESTIGATE** driven **only** by its own high-signal checkpoint/merge failure events that **did not self-resolve** (no following successful merge `19080`, and no orphan / stale layer left behind). This is a strong indication the backup product's checkpoint or post-backup merge is repeatedly failing for those VMs; triage with the backup team/vendor first (Microsoft Support only if a `3216` / fork-commit HRESULT is among them). As of v0.2.17 this bullet is **no longer suppressed** just because stale checkpoints also exist elsewhere in the fleet. A failure that **was** followed by a successful merge with no leftover layer is treated as benign self-healing backup activity and reported **OK with a note**, not INVESTIGATE.
- **HOLD STATE — fork-commit at an active checkpoint's creation** / **INVESTIGATE — cannot confirm (required coverage incomplete)** — shown when a VM carries an active checkpoint created outside the lookback window and the historic look-back either recovered a confirming fork-commit event at that creation time (HOLD; do not migrate/restart until the chain is validated) or found at least one required Worker/VMMS Admin scope to be wrapped, disabled, unavailable, or failed (INVESTIGATE / CANNOT CONFIRM). The report names each incomplete scope; wrapped scopes also show the checkpoint-created vs oldest-available-event timestamps. Enabled-but-empty required Admin logs are sufficient and do not trigger this warning. The optional Analytic channel never participates in this decision.
- **Orphaned `.avhdx` file(s)** — shown when ≥ 1 orphaned `.avhdx` was found in any VM's disk folder(s) (not attached to any chain). As of v0.2.17 the guidance is **prescriptive** rather than a bare "confirm with the backup team": (1) **match each file to a job** — find the backup / restore / instant-recovery (live-mount) / replica-seed job for **that** VM in your backup product's history at the file's Created / LastWrite time (a job that failed or aborted then is the usual cause); (2) if it is a **live-mount / instant-recovery** file, unmount it **through the backup product** (do NOT delete it by hand — that leaves the product's catalog inconsistent); (3) if it is a **leftover initial-replica** point, let Hyper-V Replica remove it (resume / resync); (4) **before removing anything**, confirm a current verified backup exists, **quarantine** (move / rename) the file first, keep it one retention cycle, confirm the VM and its next backup are healthy, then delete. The per-VM **Orphaned .avhdx files** table lists names, sizes, timestamps and a per-file **Likely / action** read (Rollback / StuckMerge / SafeToDelete / LiveMount / Leftover).
- **Enable the Analytic channel** — shown only when a node still has the `Hyper-V-VMMS/Analytic` channel disabled (and the check was not skipped).
- **Rule out storage-layer disruption** — shown only when the storage-health snapshot is **Degraded** / has active storage jobs.
- **HOLD STATE VMs** and **Open a Microsoft Support case** — shown **only** when ≥ 1 VM is in **HOLD STATE** (a fork-commit signature is present somewhere in the fleet). On INVESTIGATE-only / clean runs the Microsoft-case line is deliberately omitted, because with no fork-commit signature the next step is backup-team / vendor triage, not a support case.

When none of the above apply, a single **"No action required from this audit"** line is shown instead.

When `-OutputPath` is used, a results **`.zip`** bundling the run folder's `.txt`, `.csv`, `.html`, telemetry `.json`, and any conditional `_debug_log_*.txt` artifact is also created (suppress with `-NoZip`), and the console prints guidance to **copy the zip to a device with a browser, unzip, and open the HTML**. The console itself is **quiet by default** (one-line verdict per VM); use `-Quiet:$false` for the full report on screen.

## Output files (only with `-OutputPath`)

`-OutputPath` is an **optional base folder**. If omitted, no run folder is created, although the default HTML report is still written to the current directory unless `-NoHtml` is supplied. When provided, each run creates a timestamped **sub-folder** inside it, and one set of files is written **per VM** in that sub-folder:

```
<OutputPath>\
  VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.zip        <- results bundle (default; suppress with -NoZip)
  CheckpointAudit_<yyyy-MM-dd_HHmmssZ>\                   <- one sub-folder per run
    <VMName>_VMAudit_<yyyyMMdd-HHmmss>.txt               <- full report for that VM
    <VMName>_Events_<yyyy-MM-dd>.csv                     <- that VM's own events (VM-attributed), full untruncated text
    _NodeEvents_<node>_<yyyy-MM-dd>.csv                  <- node-wide events, written ONCE per node (shared context)
    VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.html    <- portable fleet report (default; suppress with -NoHtml)
    code_execution_perf_telemetry_<ClusterName>_<stamp>.json  <- internal per-step timing telemetry (see note below)
    _debug_log_<stamp>.txt                              <- only when an operation fails after recovery/retries
```

- **`<VMName>_VMAudit_<yyyyMMdd-HHmmss>.txt`** — the full per-VM report (written from the captured output buffer; complete regardless of `-Quiet`).
- **`<VMName>_Events_<yyyy-MM-dd>.csv`** — that VM's **VM-attributed** events with the **complete, untruncated** message text (newlines flattened to ` | `). The `.txt` collapses repeated rows for the same event ID (first few shown + a `Removed N duplicate...` note), so use this CSV for the full record of every event.
- **`_NodeEvents_<node>_<yyyy-MM-dd>.csv`** — (v0.2.14) the **node-wide** event scan for each owning node, written **once per node** rather than duplicated into every VM's CSV. Node-wide events (e.g. a repeated `15268` flood that references many VMs) are shared context, so keeping them in one per-node file — and each VM's CSV to just its own attributed rows — dramatically shrinks large fleet runs. Each per-VM report points to the relevant node CSV for the node-wide detail.
- **`VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.html`** — the single portable fleet report covering all audited VMs (see [Portable HTML report](#portable-html-report--results-bundle)).
- **`VMCheckpointAudit-<ClusterName>-<yyyy-MM-dd>.zip`** — a bundle of the run folder (`.txt` + `.csv` + `.html` + telemetry `.json` + conditional debug log), for copying to a browser device / attaching to a support case in one file.
- **`code_execution_perf_telemetry_<ClusterName>_<stamp>.json`** — (v0.2.15, expanded in v0.2.18) an **internal** per-step performance-telemetry file with hierarchical step numbers and accurate start/end times. It includes parent sections for every major report phase plus focused nested timings for chain validation, all four virtual-disk housekeeping stages, replication/HRL, event scan/attribution/recovery, Analytic state, VSS, staleness, historic correlation, state consistency, per-VM TXT writes, discovery, storage health, and HTML rendering. Parent and child durations overlap and must not be summed. It is written into the run folder and bundled into the `.zip`, but is not referenced by the HTML report. Add `-AnonymizeTelemetry` to replace cluster/node/VM names in this file and its file name with stable pseudonyms.
- **`_debug_log_<stamp>.txt`** — (v0.2.18) written only when an operation remains failed after retries/recovery or a report artifact cannot be written. It records UTC time, operation/scope, active telemetry phase, retry count, exception type/message/HResult, inner exceptions, category and error ID, safely truncated target context, command/script/line/column/position, stack trace, and basic PowerShell/OS/module context. The console prints its exact path. Review it for sensitive data before sharing it securely, then use [feedback / GitHub issues](https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback) for a reproducible module failure.

File names lead with the **VM name** so per-VM reports sort together for easy reading. Running against many VMs produces one `.txt` + one `.csv` per VM, all grouped in a single per-run sub-folder so repeated runs never intermix. The run-folder path is printed at the start of the run.

## VM states (verdicts)

Every audited VM is assigned exactly **one** state (the `Recommendation` property). The state is decided **per VM**, from that VM's own checkpoint chain plus only the Hyper-V events **attributable to that VM** (a concerning event counts toward a VM only when its message names that VM or its VM ID). Node-wide events that reference *other* VMs are reported as **context** and never, on their own, change a VM's verdict.

### State matrix

| State | When it is assigned (precise logic) | Typical example | What to do |
|---|---|---|---|
| **HOLD STATE** &nbsp;(data-loss risk) | A **fork-commit / merge-failure signature for this VM** is present **AND** the VM has unmerged differencing disk(s). The confirming event may be in the normal lookback or recovered by the cross-node historic scan around a still-attached checkpoint's creation time. Signature = a concern event **attributable to this VM** whose ID is `3216` **or** whose message contains one of the HRESULTs `0x80048102`, `0x800480BD`, `0x800480BC`, `0x800703EE`. "Unmerged disk(s)" = `HasAttachedCheckpoints` **or** `StaleCheckpointCount > 0`. | VM is running on 2 active `.avhdx` layers **and** a current or historically recovered `3216` (or `0x80048102`) event names this VM. | **Do not** live/quick/storage-migrate or restart the VM until the chain is validated/merged. **Engage Microsoft Support (CSS)** to confirm the safe path. |
| **INVESTIGATE** | **Not** HOLD STATE, **and** at least one VM-scoped concern signal: a **stale** checkpoint (`StaleCheckpointCount > 0`), an **orphaned** `.avhdx` (`OrphanCount > 0`), an **unhealthy VSS writer** (`VssUnhealthyCount > 0`), an **unhealthy replica** (Critical / Warning), an **UNRESOLVED HIGH-signal** per-VM concern event - ID `3216`/`18012`/`19100`/`16300`, or a fork-commit HRESULT, that did **not** self-resolve (v0.2.17) - **or** an active checkpoint whose creation-time Worker/VMMS coverage is incomplete, so migration safety cannot be confirmed from event data. **Low-signal** per-VM chatter alone (e.g. a transient `19090` that completed, or `15268`), **and** a HIGH operation-failure that **self-resolved** (followed by a successful `19080` merge with no leftover layer), do **not** trigger INVESTIGATE (see the OK row). | A backup checkpoint on this VM is 36 h old (≥ the 24 h `-StaleHours` threshold), an orphaned `.avhdx` is present, the replica is Critical, a VSS writer for this VM is in a failed/retryable state, or the VM's own checkpoint/merge is repeatedly failing with no successful merge afterwards - but no confirming fork-commit signature. | **Engage your third-party backup vendor first** (their product owns the checkpoint merge-after-backup). Review the backup job and the **VSS Writer Health** section; confirm whether an aged checkpoint is expected. Open a CSS case if a fork signature appears, required historic evidence confirms one, or the vendor rules out their product. |
| **OK** | None of the INVESTIGATE drivers above - no fork signature, no stale checkpoint, no orphaned `.avhdx`, no unhealthy VSS writer, no unhealthy replica, and no **high-signal** VM-attributed concern event. A VM whose **only** signal is **low-signal** per-VM chatter (e.g. a transient `19090` that later completed with no leftover `.avhdx`, or `15268` storage/housekeeping noise) is still **OK**, with a low-key note explaining the low-signal events. | VM has **no checkpoints**, is running normally, replication healthy - or its only events are low-signal and left nothing behind. The node may have concerning events, but they reference **other** VMs (shown as a node-context note). | No action required. The note lists any low-signal events / how many events belong to other VMs (see the events CSV `VmAttributed` column). |
| **NOT FOUND** | The named VM was not found on any node of the cluster (collection outcome, not a health verdict). `ReportData` is `$null`; see `Detail`. | `-VMName 'Typo01'` where no such VM exists on the cluster. | Check the VM name / cluster; re-run. |
| **ERROR** | The audit could not complete for this VM - e.g. the cluster name could not be resolved, or an unexpected exception occurred (collection outcome). `ReportData` is `$null`; see `Detail` and the console. | `-Cluster 'BadName'` cannot be resolved, or remoting to the owning node failed. | Fix the underlying access/name/remoting issue (see [How it connects](#how-it-connects-no-double-hop)) and re-run. |

### Evaluation order (precedence)

The states are mutually exclusive and decided in this order:

1. **ERROR / NOT FOUND** - if data collection could not complete or the VM does not exist, that is the state (no health verdict is attempted).
2. **HOLD STATE** - fork-commit signature **for this VM** *and* unmerged differencing disk(s).
3. **INVESTIGATE** - not HOLD STATE, but at least one VM-scoped concern signal: a stale checkpoint, an orphaned `.avhdx`, an unhealthy VSS writer, an unhealthy replica (Critical / Warning), or a **high-signal** per-VM concern event (`3216`/`18012`/`19100`/`16300` or a fork-commit HRESULT). **Low-signal-only** per-VM chatter (e.g. a transient `19090` or `15268`) does **not** trigger INVESTIGATE.
4. **OK** - none of the above (a low-signal-only VM lands here with a note).

> **Why a checkpoint-free, healthy VM is `OK`, not `INVESTIGATE`:** the verdict only consumes events **attributable to the VM being audited**. A busy node can log many checkpoint/merge events for *other* VMs; those are surfaced as a node-context note but do not escalate a VM that has no checkpoints of its own and no concern events naming it. (This VM-scoping was introduced in v0.2.12; earlier versions counted node-wide events against every VM.)

Continuing to run a HOLD STATE / INVESTIGATE VM **in place** is generally safe (Hyper-V keeps using the in-memory chain state) - the risk is materialised by a migrate/restart. Both levels, and the report's Problem Statement, link the Microsoft Learn troubleshooting guide:

> [Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures](https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage)

## Enabling the Analytic channel (optional, operator's choice)

The internal per-disk `.vmcx` revert failure is traced only to `Hyper-V-VMMS/Analytic`, which is disabled by default. This optional channel supplements future incident detail but is not part of required Worker/VMMS Admin coverage and never causes **CANNOT CONFIRM** or changes the verdict. To capture it for future incidents, run **elevated on each node**:

```cmd
wevtutil sl Microsoft-Windows-Hyper-V-VMMS-Analytic /e:true /q:true
```

## Return value

By **default the command writes nothing to the pipeline**. The HTML file is the primary human-readable report; the console shows concise status, and `-OutputPath` also creates the per-VM `.txt` transcript and events `.csv`. This keeps `$x = Get-HyperVVMCheckpointHealth ...` clean.

Add **`-PassThru`** to emit **one `[pscustomobject]` per VM** to the pipeline, in addition to the report files:

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
| `StaleAttachedLayerCount` | int | Count of attached differencing layers at/beyond `-StaleHours`, independent of named snapshot metadata. |
| `SnapshotLayerMismatch` | bool | Snapshot and attached-layer representations disagree; treated as inconclusive evidence requiring investigation. |
| `ConcernEventCount` | int | Count of `Concern = YES` Hyper-V events **attributable to this VM** (the message names this VM or its VM ID). Node-wide concern events that reference other VMs are reported as context and are **not** counted here. |
| `AssessmentConfidence` | string | `Complete` only when required chain, inventory, event, historic, and state-consistency evidence is complete; otherwise `Incomplete`. |
| `CollectionStatus` | object | Machine-readable status for chain, virtual-disk, event, historic, and state-consistency collection. Required event scopes distinguish `Covered`, `EnabledEmpty`, `Wrapped`, `Disabled`, and `Unavailable`; an enabled-empty Admin log is sufficient, while wrapped, disabled, or unavailable evidence is incomplete. `Changed` and `Skipped` remain distinct for other collectors. |
| `ReportFile` | string | Path to this VM's `.txt` report (`$null` when `-OutputPath` omitted). |
| `Detail` | string | Extra context for `NOT FOUND` / `ERROR` rows. |
| `ReportData` | object | Rich per-VM detail (checkpoints, `AttachedVhdLayers`, disks, replication, VSS, analytic, events, config version, and — for HOLD STATE — the Support Case summary) that the HTML fleet report renders. `$null` for `NOT FOUND` / `ERROR` rows. |

Negative evidence is reassuring only when its required collection status is complete. An enabled required Admin channel with zero records is a valid no-event result; a missing query, wrapped history, disabled required channel, changed VM state, or skipped source is retained as incomplete evidence and cannot silently produce an unqualified clean verdict. The optional Analytic channel is excluded from this confidence decision. Orphan labels are evidence classifications only; they never authorize deletion or remediation.

A row is emitted for **every** VM — including `NOT FOUND` / `ERROR` cases — so a fleet sweep always yields one object per VM:

```powershell
$r = Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' `
        -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name `
        -OutputPath 'C:\Temp\VM_Checkpoint_Reports' -PassThru

$r | Where-Object HoldState | Format-Table VMName, OwningNode, Recommendation
$r | Export-Csv 'C:\Temp\VM_Checkpoint_Reports\fleet-summary.csv' -NoTypeInformation
```

### Drilling into `ReportData`

The flat top-level properties are ideal for quick `Where-Object` / `Export-Csv` roll-ups. For deeper integration, the nested `ReportData` object exposes the same rich per-VM detail the HTML report renders — checkpoints, disks, replication, VSS writers, the Analytic-channel state, the concerning-event breakdown, config-version comparison, and (for HOLD STATE) the copy/paste Support Case summary:

```powershell
$r = Get-HyperVVMCheckpointHealth -Cluster 'CLUS01' `
        -VMName (Get-ClusterGroup -Cluster 'CLUS01' | Where-Object GroupType -eq 'VirtualMachine').Name `
        -OutputPath 'C:\Temp\VM_Checkpoint_Reports' -PassThru

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

## Release packaging (maintainers)

Every release from 0.2.18 onward must publish the module as a ZIP. Publishing only the root `.psm1` is unsupported because it requires the manifest and five private modules. `Build-Release.ps1` uses an explicit allow-list, validates manifest/module version parity, stages the runtime files, validates the staged manifest, and writes both a versioned ZIP and SHA256 checksum file:

```powershell
Set-Location .\Get-HyperVVMCheckpointHealth
.\Build-Release.ps1
```

Generated assets are written to the ignored `release` directory:

```text
release\Get-HyperVVMCheckpointHealth-0.2.19.zip
release\Get-HyperVVMCheckpointHealth-0.2.19.zip.sha256
```

Create the GitHub release with tag `Get-HyperVVMCheckpointHealth-v0.2.19` and upload the generated ZIP, its SHA256 file, and `Setup-Get-HyperVVMCheckpointHealth.ps1` as three separate assets. The setup script remains outside the ZIP. Before publishing a future version:

1. Update the version in the root module, manifest, README, release notes, and the setup script's `$version` value.
2. Run the redirected Windows PowerShell 5.1 Pester suite.
3. After every file included in the ZIP is final, run `Build-Release.ps1`; use `-Force` only when intentionally replacing a local build for the same version. Copy the resulting SHA256 into the setup script's `$expectedSha256` value. Any later change to an in-ZIP file requires rebuilding the ZIP and repinning this hash again.
4. Extract the ZIP into a clean directory, import its manifest under Windows PowerShell 5.1, and verify `Get-Command Get-HyperVVMCheckpointHealth`.
5. Publish the ZIP and checksum as release assets using the tag and asset naming convention above.

## What's New

### Version 0.2.19

- Consolidates private helper ownership into five manifest-managed modules for assessment, collection, policy, rendering, and storage. Package-integrity checks reject bare root-module execution and incomplete release bundles with actionable guidance.
- Makes Hyper-V Replica assessment cadence- and workload-aware. Product health/state remains authoritative; relationship frequency, average replication size, monitoring-window success/miss counts, backlog, and latency provide measurement context. Advisory drift is reported separately from material concerns, and each Replica-enabled VM card includes a detailed relationship/measurement table that is collapsed when healthy and open when attention is needed.
- Corrects operation-recovery correlation so a later successful merge does not incorrectly mark checkpoint-request failure `18012` or configuration-load failure `16300` as recovered.
- Expands cluster/storage housekeeping with exact file metadata, deduplicated storage totals using adaptive MB/GB/TB units without duplicate raw-byte text, default-enabled category filters, search, root/extension/minimum-size filters, sortable columns, and synchronized storage charts in the self-contained HTML report.
- Excludes the non-workload `System Volume Information` directory from CSV traversal and distinguishes an inaccessible CSV root from a lower **CSV folder path inaccessible** finding while retaining files collected from readable branches.
- Adds a persistent point-in-time scope and audit-coverage notice to every HTML Executive Summary, including the audited VM count, generation time, and any additional discovered VMs not audited in that run.
- Adds per-VM attached VHD chain evidence whenever a differencing layer is present, so stale-layer and snapshot/layer-mismatch findings remain actionable even when no named checkpoint is exposed. `INVESTIGATE` guidance is now selected by the actual driver, preventing Replica-only findings from receiving an unrelated unconfirmed fork-commit disclaimer.
- Prewarms cluster-wide virtual-disk ownership and file inventories before per-VM auditing, caches repeated VHD metadata reads, and records total, per-node, and per-root performance timings.
- Extends retry and diagnostics coverage to the new Replica monitoring and inventory paths. Terminal read failures are written to the conditional `_debug_log_*.txt` with operation, scope, retry, exception, command, source, and stack context.
- Enforces the read-only target-cluster invariant with an AST-based regression gate and adds release/package integrity coverage.

### Version 0.2.18

- Added hierarchical performance telemetry for major collection and report phases, including virtual-disk housekeeping and historic event correlation.
- Added the conditional `_debug_log_*.txt` for operations that remain failed after retries, capturing exact exception, command/source context, stack trace, active phase, and retry count.

### Version 0.2.17

- Added proactive cross-node historic event look-back for active checkpoints older than the normal event window, with explicit warnings when required Worker/VMMS Admin history is wrapped or unavailable.
- Distinguished critical fork-commit evidence from operation failures that later self-resolved, and improved orphan guidance, next-step gating, and semantic HTML readability.

### Version 0.2.16

- Reclassified transient merge-interrupted event `19090` as low-signal and cached VSS writer state once per node to reduce noise and repeated collection.
- Added historic correlation to console/TXT output, timed final rendering and ZIP creation, and moved technical reference material into a collapsed HTML appendix.

### Version 0.2.15

- Added hierarchical JSON performance telemetry with optional anonymization, transient-read retries, and source labels for input and event-discovered VMs.
- Added targeted cross-node historic event correlation around orphan AVHDX creation and last-write windows, with per-orphan classification/action context and HTML navigation anchors.

### Version 0.2.14

- Added fleet-scale cluster, node, VM-owner, session, supported-version, CSV, and event caches so shared data is collected once and reused across VM audits.
- Added one node-wide events CSV per node, high- versus low-signal event handling, per-orphan guidance, and end-to-end run timing in the HTML summary.

### Version 0.2.13

- Added orphaned AVHDX discovery with creation timestamps, per-VM HTML detail, a fleet summary card, and an `INVESTIGATE` prompt for files not attached to a VM disk chain.

### Version 0.2.12

- Scoped checkpoint verdicts to events attributable to the audited VM, preventing node-wide events for other VMs from escalating a healthy VM.
- Documented the VM state model and stopped treating bare event ID `18590` as a fork-commit signature without a confirming HRESULT.

For complete historical details, see the repository history and versioned GitHub release notes. Report reproducible failures through [feedback / GitHub issues](https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback).

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
>
> **Low-signal vs high-signal for the per-VM verdict (v0.2.14 / v0.2.16 / v0.2.17):** only **high-signal** per-VM events - `3216`, `18012`, `19100`, `16300`, or a fork-commit HRESULT - can escalate an otherwise-clean VM to **INVESTIGATE**. The remaining concern IDs (`3280`, `12240`, `15268`, and - **as of v0.2.16** - `19090` *background disk merge interrupted*) are **low-signal**: still collected, still flagged `Concern = YES`, and still used for **discovery**, but they do **not**, on their own, change a VM's verdict. `19090` was reclassified because an interrupted merge is transient and normally completes later; a merge that genuinely never finished leaves an orphaned `.avhdx`, which is caught independently by the orphan scan.
>
> **CRITICAL vs HIGH-operation split + self-resolution (v0.2.17):** the high-signal set is refined into a **CRITICAL** class (`3216` + fork-commit HRESULTs — the on-disk chain / data-loss signature, never demoted) and a **HIGH operation-failure** class (`18012` checkpoint-op-failed, `19100` merge-failed, `16300` cannot-load-config). A HIGH operation-failure event escalates to **INVESTIGATE only when it did *not* self-resolve** — i.e. it was **not** followed by a successful background merge (`19080`) for that VM **and** left an orphan / stale layer behind. This was added after real-fleet data showed some backup products log a **nightly** `18012` “checkpoint operation failed” that is immediately followed by `19070` → `19080` “merge finished **successfully**”, leaving no orphan / stale layer — benign, self-healing activity that previously produced a permanent, un-actionable INVESTIGATE. Such self-resolved failures are now reported **OK with an explicit note** (visible, never hidden); genuinely **unresolved** failures (no following `19080`) are reported as *“backup checkpoint / merge appears to be failing”* with concrete steps.

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
