# AMA Extension Mitigation Script

## Overview

This PowerShell script applies a mitigation for a known performance issue affecting Azure Local (Azure Stack HCI) clusters running Azure Monitor Agent (AMA) Extension versions **1.40.0.0 or earlier**.

The issue occurs when the `MetricsExtension.Native.exe` process (a child of `AMAExtHealthMonitor.exe`) causes high resource utilization on cluster nodes. The mitigation stops this process and renames the executable to prevent it from restarting.

**Note:** This issue is resolved in AMA Extension version **1.41.0.0** and later. The script automatically skips nodes running the fixed version.

## What the Script Does

1. Connects to each specified cluster and retrieves the cluster nodes
2. On each node, checks if `MetricsExtension.Native.exe` is running as a child of `AMAExtHealthMonitor.exe`
3. Stops the process if found and renames the executable from `MetricsExtension.Native.exe` to `MetricsExtension.Native.exe.org`
4. Exports results to a CSV file with status for each node

## Requirements

- PowerShell 5.1 or later
- FailoverClusters module installed
- Administrative access to target clusters and nodes
- Network connectivity to cluster nodes (WinRM/PowerShell remoting)

## Usage Examples

### Single Cluster

```powershell
.\AMAExtensionMitigation.ps1 -ClusterName "MyCluster01"
```

### Multiple Clusters

```powershell
.\AMAExtensionMitigation.ps1 -ClusterName "Cluster01", "Cluster02", "Cluster03"
```

### Using a CSV File

```powershell
.\AMAExtensionMitigation.ps1 -CSVFilePath "C:\Clusters\clusters.csv"
```

The CSV file must contain a `Cluster` column:

```csv
Cluster
Cluster01
Cluster02
Cluster03
```

### Skip Confirmation Prompt

```powershell
.\AMAExtensionMitigation.ps1 -ClusterName "MyCluster01" -NoConfirm
```

### Custom Output Path for Results

```powershell
.\AMAExtensionMitigation.ps1 -CSVFilePath "C:\Clusters\clusters.csv" -OutputPath "C:\Results" -NoConfirm
```

## Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `-ClusterName` | No | Name of one or more clusters to process. Alias: `-Cluster` |
| `-CSVFilePath` | No | Path to CSV file containing cluster names (requires 'Cluster' column) |
| `-OutputPath` | No | Directory for results CSV (defaults to current directory) |
| `-NoConfirm` | No | Skip confirmation prompt before starting |

## Output

The script generates a CSV file with the following information for each node:

- **ClusterName**: Name of the cluster
- **NodeName**: Name of the node
- **Status**: Success or Fail
- **Message**: Details about the action taken or error encountered
- **AMAVersion**: Installed AMA Extension version

---

## ⚠️ Disclaimer

**THIS SCRIPT IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.**

**This script is NOT officially supported by Microsoft.** Use at your own risk. Always test in a non-production environment before deploying to production systems. The author(s) accept no liability for any issues arising from the use of this script.
