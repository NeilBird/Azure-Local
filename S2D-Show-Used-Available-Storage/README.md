# Azure Local - Show Real Used / Real Available Storage (S2D)

> **Disclaimer:** This script is NOT a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT License](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

## TL;DR

A read-only PowerShell script that surfaces physical pool usage and estimates additional logical storage capacity on an Azure Local / Storage Spaces Direct (S2D) cluster. Use `PoolAllocatedTiB` and `PoolUsedPercent` for physical allocation, `PoolFreeRawTiB` and `PoolFreeRawPercent` for measured physical free space, and `EstimatedAdditionalLogicalDataTiB` for a planning estimate after allowing for recommended repair headroom and resiliency overhead. Primordial pools are excluded. Run from any node, in an elevated PowerShell session.

**The repair reserve is a recommendation, not an enforced deduction from the pool.** No drives are dedicated or marked as used by this calculation. Thin volumes can consume this headroom, leaving less capacity for repair after a drive failure. Resiliency overhead, unlike the recommended reserve, is a real physical cost incurred as data is written.

## What this script does

[`S2D-Show-Used-Available-Storage.ps1`](S2D-Show-Used-Available-Storage.ps1) is **read-only** - it does not modify any storage objects. Run from any node in an Azure Local / S2D cluster. It auto-detects the resiliency factor from your existing volumes rather than assuming 2-way or 3-way mirror, and flags if the cluster has volumes at multiple resiliency tiers.

By default, it produces two console views:

1. **Step 1 - Per-volume table** showing each virtual disk's `ThinMaxTiB`, `FootprintOnPoolTiB` (Real Used), and `LogicalWrittenTiB`.
2. **Step 2 - Pool-wide summary** showing the selected non-primordial pool's name, size, allocated/free capacity and percentages, configured thin-provisioning alert thresholds, recommended repair reserve, and `EstimatedAdditionalLogicalDataTiB` (a planning estimate, not a write limit).

With `-PassThru`, it returns one structured cluster report instead, without formatted tables or explanatory console text. Genuine warnings are still emitted.

## Requirements

- PowerShell 5.1 or later
- Administrator privileges (the storage cmdlets return limited or no data without elevation)
- `FailoverClusters` and `Storage` PowerShell modules
- Run from a node that is a member of an Azure Local / S2D cluster

## Usage

```powershell
# From any node in the cluster, in an elevated PowerShell session:
.\S2D-Show-Used-Available-Storage.ps1
```

### Structured output

```powershell
$report = .\S2D-Show-Used-Available-Storage.ps1 -PassThru
$report.ClusterName
$report.Pool
$report.Volumes

$report | ConvertTo-Json -Depth 5 | Set-Content -Path .\cluster-storage.json
$report.Pool | Export-Csv -Path .\pool-storage.csv -NoTypeInformation
$report.Volumes | Export-Csv -Path .\volume-storage.csv -NoTypeInformation
```

| Property | Type and meaning |
|---|---|
| `ClusterName` | Cluster name discovered using `Get-Cluster`, not the executing node's name. Null with a warning if discovery fails. |
| `CollectedAtUtc` | UTC `DateTime` recorded when report collection completes. |
| `Pool` | Object containing the pool-summary fields documented below. Numeric values remain numeric; `RepairReserveDriveEquivalents` is an integer rather than a display label. |
| `Volumes` | Array of per-volume objects, including for zero or one volume. |

In structured output, `Pool.ThinProvisioningAlertThresholdsPercent` is a numeric array, empty when not reported. The default console view renders it as comma-separated values or `Not reported`. JSON preserves nested arrays; CSV examples export the pool and volumes separately. Array-valued fields need flattening if individual threshold values are required in CSV cells.

You can also download and run it directly:

```powershell
Invoke-WebRequest -UseBasicParsing `
    -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/S2D-Show-Used-Available-Storage/S2D-Show-Used-Available-Storage.ps1' `
    -OutFile .\S2D-Show-Used-Available-Storage.ps1

.\S2D-Show-Used-Available-Storage.ps1
```

## How to read the output

### Sample output

The script produces a per-volume table followed by a pool-wide summary. Numbers below are illustrative only.

```text
Per-volume footprint on the storage pool:

Volume             Resiliency DataCopies ProvisioningType ThinMaxTiB FootprintOnPoolTiB LogicalWrittenTiB
------             ---------- ---------- ---------------- ---------- ------------------ -----------------
Infrastructure_1   Mirror              3 Fixed                  1.00               3.00              1.00
ClusterPerf...     Mirror              3 Fixed                  0.10               0.30              0.10
UserStorage_1      Mirror              3 Thin                  15.50               6.00              2.00
UserStorage_2      Mirror              3 Thin                  15.50               4.50              1.50

Pool-wide capacity summary:

PoolName                                  : SU1_Pool
PoolSizeTiB                               : 60.00
PoolAllocatedTiB                          : 13.80
PoolUsedPercent                           : 23.00
PoolFreeRawTiB                            : 46.20
PoolFreeRawPercent                        : 77.00
ThinProvisioningAlertThresholdsPercent     : 70
RecommendedRepairReserveTiB                : 6.40
RepairReserveDriveEquivalents              : 4 (one per node, capped at 4; not dedicated drives)
PhysicalHeadroomAfterRecommendedReserveTiB : 39.80
ResiliencyFactorAssumed                    : 3
ResiliencySource                           : detected from 4 volume(s); dominant = 3-copy
EstimatedAdditionalLogicalDataTiB          : 13.27

Used/free percentages describe physical pool allocation before the recommended repair allowance.
Repair reserve is recommended unallocated capacity, not dedicated drives or an enforced write limit.
Thin volumes can consume this headroom, leaving less capacity for repair after a drive failure.
Additional logical capacity is a planning estimate after the repair allowance and resiliency overhead.
Resiliency overhead is consumed as data is written; it is not pre-deducted from pool free space.
Thin-provisioning thresholds are capacity alerts, not write limits or reserved space.
Related capacity health failures may block update readiness; review the actual preupdate check results.
```

### Per-volume table - one row per virtual disk

| Column | What it tells you |
|---|---|
| `Volume` | Friendly name of the virtual disk / CSV. |
| `Resiliency` | e.g. `Mirror`, `Parity`. Mirror is what most Azure Local clusters run. |
| `DataCopies` | How many copies of each block the cluster keeps. `2` = 2-way mirror (typical for 2-node), `3` = 3-way mirror (3+ nodes). This is the resiliency factor for that volume. |
| `ProvisioningType` | `Thin` (deployment default for `UserStorage` volumes) or `Fixed` (used for system volumes like `Infrastructure_1` and `ClusterPerformanceHistory`). If it says `Thin`, the `Size` column in WAC/Portal is the thin maximum, not real usage. |
| `ThinMaxTiB` | The volume's "Size" - the upper bound it can ever grow to. Set at deployment time, not a physical reservation. |
| `FootprintOnPoolTiB` | **Real Used** - actual physical bytes this volume is consuming on the pool, mirror overhead included. This is the number to use for capacity reporting. |
| `LogicalWrittenTiB` | Approximate workload data in the volume (`FootprintOnPool / DataCopies`). Useful for "how much data does this app actually have". Approximate because deduplication, ReFS block cloning, and Storage Spaces metadata can skew it slightly. |

### Pool-wide summary - the cluster-level view

| Field | What it tells you |
|---|---|
| `PoolName` | Friendly name of the selected non-primordial pool. Primordial entries are not additional workload pools and are excluded. |
| `PoolSizeTiB` | Total usable pool size before any volumes. |
| `PoolAllocatedTiB` | Physical capacity allocated in the pool, read from `Get-StoragePool.AllocatedSize`, including resiliency overhead. This is pool-level **Real Used**, not application data size. |
| `PoolUsedPercent` | `AllocatedSize / Size * 100`, calculated from unrounded bytes. |
| `PoolFreeRawTiB` / `PoolFreeRawPercent` | Measured physical free space: `Size - AllocatedSize`, also expressed as a percentage of pool size. Includes the recommended repair headroom; does not yet account for future writes' resiliency overhead. Percentages are unavailable when pool size is zero or invalid. |
| `ThinProvisioningAlertThresholdsPercent` | Actual configured pool alert threshold(s), not an assumed default. Multiple values are comma-separated; absent or empty values show `Not reported`. These are alerts, not write limits; related health failures may affect update readiness. |
| `RecommendedRepairReserveTiB` | Estimated physical capacity recommended to leave unallocated for in-place repair. Not a hard reservation or enforced limit. |
| `RepairReserveDriveEquivalents` | Drive-equivalents used to size that recommendation: one per node, capped at four. No drives are dedicated, occupied, or removed from the pool by this calculation. |
| `PhysicalHeadroomAfterRecommendedReserveTiB` | Planning subtraction: physical free space minus recommended repair reserve. A negative value indicates a shortfall against the recommendation, not an enforced write block. |
| `ResiliencyFactorAssumed` / `ResiliencySource` | The mirror factor used in the final calculation, and whether it was detected, mixed, or defaulted. If you see `MIXED`, treat the bottom-line number as a planning estimate rather than precise. |
| `EstimatedAdditionalLogicalDataTiB` | Estimated additional logical data while preserving the recommended repair headroom, after accounting for resiliency overhead. Shared across thin volumes, not a per-volume allocation or guaranteed writable amount. Each volume also has its own logical ceiling. Reported as zero if recommended repair headroom is already exhausted. |

In short: **`PoolAllocatedTiB` is measured physical allocation**, **`PoolFreeRawTiB` is measured physical free space**, and **`EstimatedAdditionalLogicalDataTiB` is a planning estimate**. The per-volume **`FootprintOnPoolTiB`** shows each volume's physical footprint, including resiliency overhead.

### Capacity alerts: pool usage versus volume usage

These settings monitor different layers. None dedicates drives, reserves capacity, or sets a hard write limit.

| Control | What it monitors | Documented default |
|---|---|---|
| Pool `ThinProvisioningAlertThresholds` | Physical pool capacity usage, comparable to `PoolUsedPercent`. | 70%; the script displays the actual configured threshold(s). |
| `System.Storage.Volume.CapacityThreshold.Enabled` | Whether Health Service volume capacity threshold checks are enabled. | `True` |
| `System.Storage.Volume.CapacityThreshold.Warning` | Used percentage of an individual volume's filesystem capacity. | 80% |
| `System.Storage.Volume.CapacityThreshold.Critical` | Used percentage of an individual volume's filesystem capacity. | 90% |
| `System.Storage.StoragePool.CheckPoolReserveCapacity.Enabled` | Whether Health Service checks pool repair-reserve capacity. | `True` |

A thin volume can be well below its volume warning threshold while the shared physical pool is running low. Conversely, a volume can approach its logical ceiling while the pool still has free capacity. Monitor both layers; the volume's logical free space is not physical pool headroom.

For example, `ThinProvisioningAlertThresholds = {70}` means the pool is configured for a capacity alert when usage crosses 70%. It does not mean that 30% is reserved or that writes stop at 70%. Microsoft recommends retaining the default thin-provisioning alert threshold. The Health Service values above are documented defaults, not values queried by this script.

**Not a write limit does not mean no operational impact.** Related capacity health failures may block update readiness. Microsoft documents that critical readiness failures must be resolved and warning failures may also prevent lifecycle operations. Check the actual preupdate results, severity, and remediation; do not assume that crossing 70% always blocks every update, or raise/disable thresholds merely to get an update through. This capacity report does not determine update eligibility.

See [Storage thin provisioning - manage the default provisioning alert threshold](https://learn.microsoft.com/azure/azure-local/manage/manage-thin-provisioning-23h2#option-2-manage-default-provisioning-alert-threshold), [Health Service settings](https://learn.microsoft.com/azure/azure-local/manage/health-service-settings), and [Troubleshoot health check failures - severity levels](https://learn.microsoft.com/azure/azure-local/manage/troubleshoot-health-check-failures#health-check-severity-levels). This script reads configuration only; it does not change any threshold.

## Why the storage numbers don't tally across Portal, WAC and the Azure Local LENS workbook

Azure Local provisions volumes as **Thin** by default. That single fact explains most of the discrepancies you'll see between the **Azure portal**, **Windows Admin Center (WAC)**, and the **Azure Local LENS workbook**. Once you understand it, the "Real Used" / "Real Available" picture becomes much clearer.

The key thing to know:

Azure Local's deployment process creates **Thin** volumes by default for `UserStorage_X` volumes, plus **Fixed** volumes for the system data (`Infrastructure_1` and `ClusterPerformanceHistory`). The number of `UserStorage_X` volumes - and therefore each volume's thin maximum - is set at deployment time and varies by cluster, depending on the size of overall storage in the physical nodes. For example, a 2-node pattern can produce six 15.5 TiB volumes on one cluster and two 9.15 TiB volumes on another, depending on the number (and size) of physical data disks. The "Thin Maximum" is just the upper bound a thin volume can ever grow to; it is **not** a reservation of physical space, and it is **not** how much data the volume can actually hold.

Crucially, the sum of Thin Volume maximums across all volumes can exceed the pool's physical capacity. That's overprovisioning, and it's intentional - it lets each volume grow flexibly without you having to repartition the pool - but it's also why "Size" and "SizeRemaining" in the Azure portal and WAC can show you very little about real storage headroom.

This means:

- A volume's **"Size"** in the Portal/WAC is its **Thin Maximum** - a logical ceiling set at deployment time, not a physical allocation size.
- The volume's free space (**"SizeRemaining"**) is **not physical headroom** - it's logical headroom up to that thin maximum.
- All Thin volumes share the **same physical pool**, so additional logical capacity is a **pool-wide planning estimate**, not a per-volume allocation. Recommended repair headroom is not fenced off: thin volumes can consume it, but doing so reduces the capacity available for repairs. Do not treat 100% pool usage as a safe operating target.

This is why the Azure portal (storage paths), WAC's Volumes view, and the Azure Local LENS workbook (Azure Resource Graph data for storage paths) can all look inconsistent or alarming - they're each showing a different layer of an inherently multi-layered picture.

## The four layers of capacity

| Layer | What it shows | Resiliency overhead included? |
|---|---|---|
| Raw / Physical | Sum of all disks in the cluster | No |
| Storage Pool | Pool size (raw minus metadata) | No |
| Virtual disk footprint on pool | Physical bytes a volume consumes | Yes - ~2x logical data for 2-way mirror, ~3x for 3-way |
| Volume Size / SizeRemaining | Thin maximum + logical headroom | Misleading on Thin CSV volumes (Azure Local default) |

## The numbers you actually want

- **Real Used per volume** = `FootprintOnPool` from `Get-VirtualDisk` - physical bytes consumed, already inclusive of mirror overhead.
- **Logical data written per volume** = `FootprintOnPool / NumberOfDataCopies` (so /2 for 2-way mirror, /3 for 3-way).
- **Measured physical free space** = `Pool Size - Pool Allocated`. No repair allowance is automatically deducted from this number.
- **Estimated additional logical capacity** = `max(0, Pool Size - Pool Allocated - Recommended Repair Reserve) / Resiliency Factor`. The reserve is roughly one capacity drive-equivalent per node, capped at four, recommended to remain unallocated for in-place repair. This is a planning allowance, not a hard reservation. Resiliency overhead is a real cost of future writes, not an optional recommendation or a second deduction from existing allocated capacity. See [Microsoft's reserve-capacity guidance](https://learn.microsoft.com/windows-server/storage/storage-spaces/plan-volumes#reserve-capacity).

## Cross-referencing the other tools

### Windows Admin Center (WAC)

In WAC -> cluster -> **Volumes**, treat the `Size` column as the **thin maximum** and the `Used` column as **logical data written** (not the pool footprint). The cluster Dashboard's storage tile is the closest WAC view to pool-level reality. Keep physical free space separate from this script's planning estimate, which allows for recommended repair headroom and future writes' resiliency overhead.

> **Important:** if you're using WAC to administer Azure Local, please make sure you're **using version 5.2.6 or higher of the Cluster manager extension**. There's a known issue that can cause incorrect deletions when deleting volumes via WAC against Windows Server 2025 or Azure Local 24H2 - see [Windows Admin Center known issues](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/support/known-issues#incorrect-deletions-in-volumes-tool) on Microsoft Learn.

### Azure Local LENS Workbook

Azure Local LENS uses Azure Resource Graph against the ARM-projected properties, which inherit the same thin-maximum view as the Portal - that's correct for what it shows but isn't currently surfacing the pool-level "Real Available" calculation. A pool-level capacity panel that does the reserve subtraction and resiliency division would be a useful future addition to the workbook.

## Known limitations

- **First non-primordial pool only.** The script picks the first non-primordial `Get-StoragePool` result. Standard Azure Local clusters have a single S2D pool, so this is correct in nearly all cases - but be aware if you have ever attached additional pools.
- **Mixed resiliency is best-effort.** When the cluster contains volumes at more than one resiliency tier (e.g. some 2-way and some 3-way mirror), the script flags this as `MIXED` and reports `EstimatedAdditionalLogicalDataTiB` against the dominant factor. Treat that bottom-line number as a planning estimate rather than precise in mixed clusters.
- **Recommended repair reserve is an approximation, not an enforced limit.** The script uses "largest capacity drive size x min(node count, 4)". Review the allowance for heterogeneous drives or media tiers; Microsoft's guidance for NVMe + SSD + HDD clusters calls for separate SSD and HDD allowances. No drives or capacity are reserved by this script.
- **`LogicalWrittenTiB` is approximate.** Deduplication, ReFS block cloning, and Storage Spaces metadata mean `FootprintOnPool / DataCopies` is a close estimate, not an exact byte count of application data.

## License

[MIT License](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE)
