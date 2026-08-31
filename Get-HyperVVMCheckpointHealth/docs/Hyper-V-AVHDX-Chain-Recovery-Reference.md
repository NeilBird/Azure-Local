# Hyper-V AVHDX Parent-Chain Recovery Technical Reference

> [!IMPORTANT]
> **Status: knowledge and informational guidance only.** This document is not a Microsoft
> support statement, an approved customer change procedure, or authorization to modify a live
> customer environment. It does not replace Microsoft Support (CSS), backup-vendor guidance,
> storage-vendor guidance, or a customer-specific recovery plan. For any active customer support
> issue involving a broken, missing, ambiguous, or potentially inconsistent VHDX/AVHDX chain,
> open a Microsoft Support (CSS) case before making changes.

## Purpose

This technical reference explains the evidence, safety boundaries, and supported Hyper-V PowerShell cmdlets relevant to investigating a broken Hyper-V differencing-disk chain when the base `.vhdx` and checkpoint `.avhdx` files are still present on the file system. Command examples are included to make the concepts concrete; they are not a recommendation to execute a repair without case-specific review and approval.

It is intended for experienced Hyper-V, Windows Server, and Azure Local administrators working with Microsoft Support (CSS) and other responsible vendors under an approved change and recovery process. The examples use **only supported Hyper-V PowerShell cmdlets**, but selecting an incorrect parent can cause silent and irreversible guest-data corruption.

> [!CAUTION]
> Do not treat this reference as routine checkpoint maintenance or as remediation prescribed by
> `Get-AzStackHciVMCheckpointHealth`. For a live customer issue, stop and open a Microsoft Support
> (CSS) case before changing a parent path, VM attachment, checkpoint, or virtual-disk file.
> Preserving recoverable data is more important than returning the VM to service quickly.

## Scope

Use this reference to understand a case only when all the following conditions apply:

- The affected VM is turned off.
- The relevant `.vhdx` and `.avhdx` files still exist.
- A differencing disk reports a missing or inaccessible parent, or its embedded parent path is no longer correct.
- The files can be copied or snapshotted at the storage layer before modification.
- An administrator can identify the VM, every virtual disk attached to it, and the expected checkpoint history.

This reference does not cover:

- Missing, truncated, or physically corrupted VHDX/AVHDX files.
- Recovery where the base disk was modified after the checkpoint chain was created.
- Recovery from an unknown mixture of backup generations.
- Shared VHD Set (`.vhds`) recovery.
- Guest-cluster shared-disk recovery.
- Storage Spaces Direct, ReFS, CSV, or physical-media repair.
- Reconstruction of missing VM configuration or checkpoint metadata.

## Recovery principles

A checkpoint chain is ordered from the base disk to the current leaf:

```text
Base.vhdx
  <- Checkpoint-A.avhdx
       <- Checkpoint-B.avhdx
            <- Current-Leaf.avhdx
```

Each child contains changed blocks and relies on every ancestor beneath it. The newest leaf normally represents the current VM disk state. Attaching the VM directly to the base or an older child discards all newer changes from the VM's visible state.

The supported PowerShell operation for changing the immediate parent locator is [`Set-VHD -ParentPath`](https://learn.microsoft.com/powershell/module/hyper-v/set-vhd). Use [`Test-VHD`](https://learn.microsoft.com/powershell/module/hyper-v/test-vhd) to test whether the chain beginning at a leaf is usable.

Re-associating disk files does **not** necessarily repair the VM's checkpoint configuration. Disk-chain repair and checkpoint-metadata reconciliation are separate tasks.

## Mandatory stop conditions

Stop and open a Microsoft Support (CSS) case if any of the following conditions is encountered:

- `Get-VHD` cannot read a required VHDX/AVHDX file.
- A required file is missing, zero length, unexpectedly small, or reports structural corruption.
- More than one plausible parent exists.
- Multiple branches exist and the active branch cannot be proven.
- `Set-VHD` reports a parent identifier mismatch.
- The base disk or an intermediate AVHDX might have been mounted or modified independently.
- Files might have been restored from different backup points.
- VM configuration, checkpoint metadata, and disk metadata disagree materially.
- The storage subsystem is unhealthy or still changing files.
- The workload contains regulated, safety-critical, or otherwise high-value data for which an unverified repair is unacceptable.

Do NOT use `-IgnoreIdMismatch` merely to make the command succeed. Microsoft documents that option for cases where the replacement parent's block contents are known to be exactly identical to the original parent. An incorrect override may produce a mountable but silently corrupted guest filesystem.

## Change controls and prerequisites

Before beginning:

1. Obtain customer approval, application-owner approval, and an approved maintenance window.
2. Record the incident timeline, last known successful VM operation, recent checkpoint activity, backup operations, storage events, and administrator actions.
3. Confirm that the VM is `Off`, not `Saved`, `Paused`, `Running`, or in a transitional state.
4. For a clustered VM, confirm the owner node and take the clustered VM role offline through cluster-aware tooling.
5. Confirm no VHDX/AVHDX in the chain is mounted by the host, attached to another VM, used by backup software, or being merged.
6. Preserve all files and VM configuration before making changes.
7. Confirm sufficient free space for copies and any later merge operation.
8. Run Hyper-V cmdlets on the host that owns or can access the storage. For shared storage, [`Get-VHD`](https://learn.microsoft.com/powershell/module/hyper-v/get-vhd) may need to run on the host currently using the disk.

> [!IMPORTANT]
> A storage snapshot is not a substitute for an independently recoverable backup unless the storage vendor confirms its consistency and recovery semantics for the affected Hyper-V files.

## Phase 1: Preserve evidence

Set case-specific values in an elevated PowerShell session:

```powershell
$vmName = 'VM01'
$caseId = 'CASE-00000000'
$diskFolder = 'C:\ClusterStorage\Volume01\VM01\Virtual Hard Disks'
$evidenceFolder = "C:\Temp\$caseId-HyperV-Chain-Evidence"

New-Item -Path $evidenceFolder -ItemType Directory -Force | Out-Null
```

Record the VM and disk attachment state:

```powershell
Get-VM -Name $vmName |
    Select-Object Name, Id, State, Status, ComputerName, ConfigurationLocation,
        CheckpointFileLocation |
    Export-Clixml -Path "$evidenceFolder\VM.xml"

Get-VMHardDiskDrive -VMName $vmName |
    Select-Object VMName, ControllerType, ControllerNumber, ControllerLocation,
        Path, DiskNumber, ResourcePoolName |
    Export-Csv -Path "$evidenceFolder\VMHardDiskDrives.csv" -NoTypeInformation

Get-VMSnapshot -VMName $vmName -ErrorAction SilentlyContinue |
    Select-Object VMName, Name, Id, SnapshotType, CreationTime, ParentSnapshotId |
    Export-Csv -Path "$evidenceFolder\VMCheckpoints.csv" -NoTypeInformation
```

Record the files without changing them:

```powershell
Get-ChildItem -Path $diskFolder -File -Recurse |
    Where-Object Extension -in '.vhd', '.vhdx', '.avhd', '.avhdx' |
    Select-Object FullName, Length, CreationTimeUtc, LastWriteTimeUtc |
    Export-Csv -Path "$evidenceFolder\DiskFiles.csv" -NoTypeInformation

Get-ChildItem -Path $diskFolder -File -Recurse |
    Where-Object Extension -in '.vhd', '.vhdx', '.avhd', '.avhdx' |
    Get-FileHash -Algorithm SHA256 |
    Export-Csv -Path "$evidenceFolder\DiskFileHashes.csv" -NoTypeInformation
```

Copy or storage-snapshot all relevant files before changing VHD metadata. Preserve:

- Every base VHDX and AVHDX candidate.
- VM configuration files (`.vmcx`) and runtime state files where present.
- Checkpoint configuration files (`.vmrs` and related files) where present.
- Hyper-V VMMS Admin logs, Failover Clustering logs, and relevant storage logs.
- Backup-product job logs and restore history.
- The evidence generated above.

Do not mount the preserved copies read/write. Keep an untouched recovery set throughout the case.

## Phase 2: Inventory VHD metadata

Create a read-only metadata inventory:

```powershell
$metadata = Get-ChildItem -Path $diskFolder -File -Recurse |
    Where-Object Extension -in '.vhd', '.vhdx', '.avhd', '.avhdx' |
    ForEach-Object {
        try {
            $vhd = Get-VHD -Path $_.FullName -ErrorAction Stop

            [pscustomobject]@{
                Path             = $vhd.Path
                VhdType          = $vhd.VhdType
                VhdFormat        = $vhd.VhdFormat
                ParentPath       = $vhd.ParentPath
                FileSize         = $vhd.FileSize
                Size             = $vhd.Size
                MinimumSize      = $vhd.MinimumSize
                LogicalSector    = $vhd.LogicalSectorSize
                PhysicalSector   = $vhd.PhysicalSectorSize
                BlockSize        = $vhd.BlockSize
                Attached         = $vhd.Attached
                Fragmentation    = $vhd.FragmentationPercentage
                Error            = $null
            }
        }
        catch {
            [pscustomobject]@{
                Path             = $_.FullName
                VhdType          = 'Unreadable'
                VhdFormat        = $null
                ParentPath       = $null
                FileSize         = $_.Length
                Size             = $null
                MinimumSize      = $null
                LogicalSector    = $null
                PhysicalSector   = $null
                BlockSize        = $null
                Attached         = $null
                Fragmentation    = $null
                Error            = $_.Exception.Message
            }
        }
    }

$metadata |
    Export-Csv -Path "$evidenceFolder\VHDMetadata.csv" -NoTypeInformation

$metadata |
    Format-Table Path, VhdType, ParentPath, FileSize, Size, Attached, Error -AutoSize
```

Any unreadable required file is a stop condition.

## Phase 3: Establish the intended chain

Determine the chain from evidence, not from filenames alone. Use all available sources:

- Embedded `ParentPath` values returned by `Get-VHD`.
- VM disk attachment returned by `Get-VMHardDiskDrive`.
- VM checkpoint hierarchy returned by [`Get-VMSnapshot`](https://learn.microsoft.com/powershell/module/hyper-v/get-vmsnapshot).
- Hyper-V Manager's **Inspect Disk** function.
- Event logs and backup records.
- Parent-identifier validation performed by `Set-VHD`.

File creation and modification timestamps are supporting evidence only. They can change during backup, restore, merge, storage replication, antivirus activity, or manual file operations.

Document the proposed chain explicitly before changing anything:

| Order | Role | File | Expected immediate parent | Evidence |
|---:|---|---|---|---|
| 0 | Base | `Base.vhdx` | None | VM and backup records |
| 1 | Child | `Checkpoint-A.avhdx` | `Base.vhdx` | Embedded locator and ID validation |
| 2 | Child | `Checkpoint-B.avhdx` | `Checkpoint-A.avhdx` | Embedded locator and ID validation |
| 3 | Leaf | `Current-Leaf.avhdx` | `Checkpoint-B.avhdx` | VM attachment and checkpoint history |

If the table cannot be completed with defensible evidence, stop and open a Microsoft Support (CSS) case.

## Phase 4: Re-associate immediate parents

> [!WARNING]
> The commands from this phase onward modify virtual-disk or VM state. For any live customer
> issue, do not execute them solely because an audit report or this reference identified a
> possible chain problem. Open a Microsoft Support (CSS) case, preserve recoverable copies, and
> proceed only under an approved, case-specific recovery and change plan.

Keep the VM and disk chain offline. Define absolute paths:

```powershell
$base   = 'C:\ClusterStorage\Volume01\VM01\Virtual Hard Disks\Base.vhdx'
$child1 = 'C:\ClusterStorage\Volume01\VM01\Virtual Hard Disks\Checkpoint-A.avhdx'
$child2 = 'C:\ClusterStorage\Volume01\VM01\Virtual Hard Disks\Checkpoint-B.avhdx'
$leaf   = 'C:\ClusterStorage\Volume01\VM01\Virtual Hard Disks\Current-Leaf.avhdx'
```

Preview each intended operation:

```powershell
Set-VHD -Path $child1 -ParentPath $base   -WhatIf
Set-VHD -Path $child2 -ParentPath $child1 -WhatIf
Set-VHD -Path $leaf   -ParentPath $child2 -WhatIf
```

After peer review of the paths, repair from the base outward, one relationship at a time:

```powershell
Set-VHD -Path $child1 -ParentPath $base   -Passthru -Confirm
Set-VHD -Path $child2 -ParentPath $child1 -Passthru -Confirm
Set-VHD -Path $leaf   -ParentPath $child2 -Passthru -Confirm
```

A successful operation without `-IgnoreIdMismatch` means Hyper-V accepted the selected immediate parent identity. It does not independently prove application-level data consistency.

If any command reports an identifier mismatch, do not continue with higher children. Preserve the complete error and continue through the Microsoft Support (CSS) case.

## Phase 5: Validate the repaired chain

Test the full chain from the current leaf:

```powershell
Test-VHD -Path $leaf
```

The required result is:

```text
True
```

Walk and record the chain:

```powershell
$currentPath = $leaf
$chain = [System.Collections.Generic.List[object]]::new()
$visited = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

while ($currentPath) {
    $resolvedPath = [System.IO.Path]::GetFullPath($currentPath)

    if (-not $visited.Add($resolvedPath)) {
        throw "Cycle detected in VHD chain at: $resolvedPath"
    }

    $disk = Get-VHD -Path $resolvedPath -ErrorAction Stop
    $chain.Add([pscustomobject]@{
        Path       = $disk.Path
        VhdType    = $disk.VhdType
        ParentPath = $disk.ParentPath
        FileSize   = $disk.FileSize
        Size       = $disk.Size
        Attached   = $disk.Attached
    })

    if ($disk.VhdType -eq 'Differencing') {
        if (-not $disk.ParentPath) {
            throw "Differencing disk has no parent path: $($disk.Path)"
        }

        $currentPath = $disk.ParentPath
    }
    else {
        $currentPath = $null
    }
}

$chain | Format-Table Path, VhdType, ParentPath, FileSize, Size, Attached -AutoSize
$chain | Export-Csv -Path "$evidenceFolder\RepairedChain.csv" -NoTypeInformation
```

Verify all of the following:

- The walk terminates at the expected base disk.
- No unexpected branch or cycle appears.
- Every intermediate parent is the approved file.
- Virtual size, sector sizes, and expected disk role are consistent.
- `Test-VHD` returns `True` for each VM leaf disk.
- The VM remains off and the disks remain unattached during offline validation.

## Phase 6: Verify the VM attachment

Repairing AVHDX metadata does not automatically update the VM configuration. Verify the configured media path:

```powershell
Get-VMHardDiskDrive -VMName $vmName |
    Format-Table ControllerType, ControllerNumber, ControllerLocation, Path -AutoSize
```

For a chain that will remain intact, the VM must normally point to the newest leaf. If the VM configuration points elsewhere, change only the specific controller slot after peer review:

```powershell
$drive = Get-VMHardDiskDrive -VMName $vmName |
    Where-Object {
        $_.ControllerType -eq 'SCSI' -and
        $_.ControllerNumber -eq 0 -and
        $_.ControllerLocation -eq 0
    }

if (@($drive).Count -ne 1) {
    throw 'Expected exactly one matching VM disk attachment.'
}

$drive | Set-VMHardDiskDrive -Path $leaf -Confirm
```

For clustered VMs, do not use `-AllowUnverifiedPaths` to bypass an unexpected cluster path-validation failure. Investigate the storage or cluster configuration instead.

## Phase 7: Choose a checkpoint disposition

### Option A: Preserve the repaired chain temporarily

Use this option when the immediate objective is controlled validation and Microsoft Support has not approved consolidation. Keep checkpoints and all source files unchanged until application owners validate the workload.

### Option B: Remove checkpoints through Hyper-V

If checkpoint metadata is present and consistent with the repaired disk chain, use Hyper-V checkpoint management rather than manual file deletion or manual merging:

```powershell
Get-VMSnapshot -VMName $vmName |
    Format-Table Name, SnapshotType, CreationTime, Id -AutoSize
```

After approval:

```powershell
Get-VMSnapshot -VMName $vmName |
    Remove-VMSnapshot -Confirm
```

See [`Remove-VMSnapshot`](https://learn.microsoft.com/powershell/module/hyper-v/remove-vmsnapshot).

Monitor the merge to completion. Do not interrupt the host, storage, cluster role, or VM management service during consolidation. Do not delete AVHDX files manually.

### Option C: Manual offline merge

Use [`Merge-VHD`](https://learn.microsoft.com/powershell/module/hyper-v/merge-vhd) only when checkpoint metadata cannot manage the chain and the recovery plan has been reviewed by Microsoft Support or an appropriately qualified recovery specialist.

`Merge-VHD` is an offline operation. Source AVHDX files involved in a merge are no longer valid for continued independent use after a successful merge. A manual merge can also leave existing checkpoint metadata inconsistent with disk state.

Do not use a manual merge as an exploratory operation. Work only from verified copies, record each source and destination, ensure sufficient storage capacity, and understand the resulting VM attachment before executing it.

## Phase 8: Controlled service validation

Before starting the production VM:

1. Confirm `Test-VHD` returns `True` for every leaf.
2. Confirm every VM disk controller slot points to the approved leaf or post-merge destination.
3. Confirm no unexpected AVHDX is omitted from the approved chain.
4. Confirm cluster ownership and storage accessibility.
5. Confirm backup, replication, and antivirus products will not interfere with initial validation.
6. Obtain application-owner approval to start the VM.

Start the VM under observation. Validate:

- Hyper-V reports normal VM status.
- The guest boots without filesystem-repair prompts.
- Windows and application event logs are reviewed.
- All expected guest volumes are online.
- Application consistency checks succeed.
- Database or application-native integrity checks succeed where applicable.
- Replication and backup health are reviewed before being re-enabled.

A successful boot is not proof of complete data integrity. Retain preserved files until the customer accepts recovery and a new, verified backup has completed.

## Rollback boundaries

There is no safe generic rollback after an incorrect parent has been used and the VM has written new data. Therefore:

- Do not start the VM until the chain is verified.
- Do not reuse modified recovery files as the only preserved copy.
- Do not merge until chain and checkpoint disposition are approved.
- If validation fails before VM startup, stop and return to untouched copies.
- If validation fails after VM startup, shut down the VM as soon as application safety permits, preserve the new state separately, and engage Microsoft Support.

## Microsoft Support (CSS) case recommendations

For any active customer support issue involving a broken or potentially inconsistent chain, open a Microsoft Support (CSS) case before mutation. This applies even when the expected chain appears clear. Select a Windows Server/Hyper-V or Azure Local support path appropriate to the deployment and business impact.

Provide the following with the case:

- Business impact, severity, and required recovery objective.
- Windows Server/Azure Local versions, build numbers, and recent updates.
- Hyper-V host and cluster topology.
- VM name, VM ID, configuration location, and current owner node.
- Exact error messages and timestamps, including screenshots where useful.
- Output from the evidence commands in this reference.
- The proposed base-to-leaf chain table and why each relationship is believed correct.
- `Get-VHD` metadata for every candidate file.
- `Test-VHD` results and complete errors.
- VMMS Admin and Failover Clustering logs covering the incident window.
- Storage, hardware, and backup-product events covering the incident window.
- A statement indicating whether any disk was mounted, renamed, copied, restored, compacted, merged, or modified after the incident.
- Confirmation that untouched copies exist and their hashes.

Do not upload customer VHDX/AVHDX files unless Microsoft Support requests them and the customer has approved a secure transfer. Virtual disks can contain credentials, personal data, encryption material, and other sensitive information.

Useful public support entry points:

- [Microsoft Support for business](https://support.serviceshub.microsoft.com/supportforbusiness)
- [Azure support request overview](https://learn.microsoft.com/azure/azure-portal/supportability/how-to-create-azure-support-request)
- [Collect diagnostic data for Azure Local](https://learn.microsoft.com/azure/azure-local/manage/collect-logs)

## Prohibited actions

Do not:

- Delete or rename AVHDX files to see whether the VM starts.
- Attach the VM directly to the base disk when newer children contain required changes.
- Mount candidate parents read/write.
- Use timestamps as the sole chain-ordering method.
- Use `Set-VHD -IgnoreIdMismatch` without proof of block-for-block parent equivalence.
- Run `Merge-VHD` while the chain is attached.
- Manually merge while valid checkpoint metadata still manages the chain.
- Use `Set-VMHardDiskDrive -AllowUnverifiedPaths` to conceal a cluster storage problem.
- Run compact, resize, convert, deduplication repair, or guest filesystem repair before preserving evidence.
- Delete the preserved recovery set immediately after the VM boots.

## Public documentation

- [`Get-VHD`](https://learn.microsoft.com/powershell/module/hyper-v/get-vhd): Inspect virtual hard disk metadata.
- [`Set-VHD`](https://learn.microsoft.com/powershell/module/hyper-v/set-vhd): Set an immediate parent path; includes the warning for `-IgnoreIdMismatch`.
- [`Test-VHD`](https://learn.microsoft.com/powershell/module/hyper-v/test-vhd): Test whether a VHD chain is usable.
- [`Merge-VHD`](https://learn.microsoft.com/powershell/module/hyper-v/merge-vhd): Perform an offline differencing-disk merge.
- [`Get-VMHardDiskDrive`](https://learn.microsoft.com/powershell/module/hyper-v/get-vmharddiskdrive): Inspect VM disk attachments.
- [`Set-VMHardDiskDrive`](https://learn.microsoft.com/powershell/module/hyper-v/set-vmharddiskdrive): Change the media attached to a VM disk controller slot.
- [`Get-VMSnapshot`](https://learn.microsoft.com/powershell/module/hyper-v/get-vmsnapshot): Inspect Hyper-V checkpoint metadata.
- [`Remove-VMSnapshot`](https://learn.microsoft.com/powershell/module/hyper-v/remove-vmsnapshot): Remove a checkpoint through Hyper-V.
- [Hyper-V checkpoints overview](https://learn.microsoft.com/windows-server/virtualization/hyper-v/checkpoints): Understand checkpoint behavior and management.
- [Failover Clustering PowerShell](https://learn.microsoft.com/powershell/module/failoverclusters/): Manage clustered VM roles through cluster-aware tooling.
- [Azure Local supportability and diagnostics](https://learn.microsoft.com/azure/azure-local/manage/collect-logs): Collect Azure Local diagnostic information.

## Disclaimer

This document provides knowledge and informational guidance only. It is not a Microsoft support statement, an approved customer change procedure, or authorization to perform recovery. For any live customer support issue, open a Microsoft Support (CSS) case before modifying VHDX/AVHDX metadata, checkpoint state, VM attachments, or virtual-disk files. This reference does not replace a customer-specific recovery plan, backup-vendor instructions, storage-vendor guidance, or Microsoft Support direction. Commands and paths must be reviewed for the customer's topology. The operator remains responsible for change approval, evidence preservation, data protection, security, and workload validation.
