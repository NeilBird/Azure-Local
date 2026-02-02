# Azure Local - Cluster Node Pending Restart Check

**Latest Version:** v0.2.4

> **Disclaimer:** This module is NOT a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT License](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

## Overview

This PowerShell script checks all nodes in Azure Local (formerly Azure Stack HCI) clusters for pending restart indicators. It connects to each cluster specified in a CSV file, retrieves the nodes, and checks each node for common pending restart signals.

The script supports **parallel processing** using runspaces for improved performance when checking large numbers of clusters and nodes.

## Features

- ✅ Checks multiple clusters from a CSV file
- ✅ Parallel node checking with configurable throttle limit
- ✅ Detects multiple pending restart indicators:
  - Component Based Servicing (CBS) reboot pending
  - Windows Update reboot required
  - Pending file rename operations
  - Computer rename pending
  - Domain join/rename signals (Netlogon)
  - SCCM/ConfigMgr client reboot pending (if applicable)
  - Azure Local/HCI Cluster-Aware Updating (CAU) state
  - Azure Stack HCI Update state
  - **Windows Installer (msiexec) active installation** - Can block further MSI operations during updates
- ✅ Exports results to CSV
- ✅ Optional detailed diagnostic information
- ✅ Configurable timeout and credential support

## Requirements

- PowerShell 5.1 or later
- **FailoverClusters** module (for `Get-Cluster` and `Get-ClusterNode` cmdlets)
- Network connectivity to target clusters and nodes
- Appropriate permissions to query cluster nodes and remote registry

## Files

| File | Description |
|------|-------------|
| `Test-ClusterPendingRestart.ps1` | Main script |
| `TestPendingRestart-Module/TestPendingRestart.psd1` | Module manifest |
| `TestPendingRestart-Module/TestPendingRestart.psm1` | Module with `Test-PendingRestart` and `Write-Log` functions |

## Command Line Installation

Download all required files directly from GitHub using PowerShell:

```powershell
# Create folder structure
New-Item -ItemType Directory -Path ".\TestPendingRestart-Module" -Force | Out-Null

# Download the main script
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/Test-ClusterPendingRestart/Test-ClusterPendingRestart.ps1' -OutFile .\Test-ClusterPendingRestart.ps1

# Download the module files
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/Test-ClusterPendingRestart/TestPendingRestart-Module/TestPendingRestart.psd1' -OutFile .\TestPendingRestart-Module\TestPendingRestart.psd1
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/Test-ClusterPendingRestart/TestPendingRestart-Module/TestPendingRestart.psm1' -OutFile .\TestPendingRestart-Module\TestPendingRestart.psm1

# (Optional) Download the README
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/Test-ClusterPendingRestart/README.md' -OutFile .\README.md

# Run the script
.\Test-ClusterPendingRestart.ps1 -ClusterName "MyCluster01" -NoConfirm
```

## CSV File Format

The input CSV file must contain a `Cluster` column with cluster names:

```csv
Cluster,HealthStatus,State
cluster01,Healthy,UpdateAvailable
cluster02,Healthy,UpdateAvailable
```

> **Note:** Only the `Cluster` column is required. Additional columns are ignored.

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-ClusterName` | No* | - | Name of one or more clusters to check directly (alias: `-Cluster`) |
| `-CSVFilePath` | No* | Prompts | Path to CSV file containing cluster names |
| `-OutputPath` | No | Current directory | Directory where results CSV will be saved |
| `-Credential` | No | Current user | PSCredential for remote authentication |
| `-TimeoutSeconds` | No | 30 | Timeout for remote connections (5-300) |
| `-ThrottleLimit` | No | 10 | Maximum concurrent node checks (1-50) |
| `-NoConfirm` | No | False | Skip confirmation prompt |
| `-Detailed` | No | False | Include detailed diagnostic information |

> **Note:** Use either `-ClusterName` OR `-CSVFilePath`. If neither is provided, the script prompts for CSV input.

## Usage Examples

### Check a Single Cluster

```powershell
.\Test-ClusterPendingRestart.ps1 -ClusterName "MyCluster01"
```

### Check Multiple Clusters Directly

```powershell
.\Test-ClusterPendingRestart.ps1 -ClusterName "Cluster01", "Cluster02", "Cluster03" -NoConfirm
```

### Basic Usage (Interactive - prompts for CSV)

```powershell
.\Test-ClusterPendingRestart.ps1
```

Prompts for CSV file path and runs with default settings.

### Specify CSV File

```powershell
.\Test-ClusterPendingRestart.ps1 -CSVFilePath "C:\Clusters\clusters.csv"
```

### Automated Run (No Confirmation)

```powershell
.\Test-ClusterPendingRestart.ps1 -CSVFilePath ".\clusters.csv" -NoConfirm
```

### With Credentials and Custom Output Path

```powershell
.\Test-ClusterPendingRestart.ps1 -CSVFilePath ".\clusters.csv" -Credential (Get-Credential) -OutputPath "C:\Results"
```

### High-Performance Run with Detailed Output

```powershell
.\Test-ClusterPendingRestart.ps1 -CSVFilePath ".\clusters.csv" -ThrottleLimit 20 -Detailed -NoConfirm
```

### Extended Timeout for Slow Networks

```powershell
.\Test-ClusterPendingRestart.ps1 -CSVFilePath ".\clusters.csv" -TimeoutSeconds 60
```

## Output

### CSV Output

The script generates a timestamped CSV file with the following columns:

| Column | Description |
|--------|-------------|
| `ClusterName` | Name of the cluster |
| `ComputerName` | Name of the node |
| `NodeState` | Cluster node state (Up, Down, Paused, etc.) |
| `PendingRestart` | True/False indicating if restart is pending (does not include MSI check) |
| `MsiInstallationInProgress` | True/False indicating if a Windows Installer (msiexec) operation is active and would block further MSI installs |
| `Reasons` | Semicolon-separated list of pending restart reasons |
| `CheckSucceeded` | "True" if check completed successfully, or "False: <error message>" if failed |

### Example Output

```csv
"ClusterName","ComputerName","NodeState","PendingRestart","MsiInstallationInProgress","Reasons","CheckSucceeded"
"CLUSTER01","NODE01","Up","False","False","","True"
"CLUSTER01","NODE02","Up","False","True","","True"
"CLUSTER01","NODE03","Up","True","False","CBS:RebootPending","True"
```

### Console Output

The script provides color-coded console output showing progress and summary:

```
[2026-02-02 10:30:00] [START]    === Azure Local - Cluster Node Pending Restart Check Script ===
[2026-02-02 10:30:00] [INFO]     Script execution started
[2026-02-02 10:30:01] [SUCCESS]  Successfully imported 1 clusters from CSV file.
[2026-02-02 10:30:05] [COMPLETE] === Summary ===
[2026-02-02 10:30:05] [INFO]     Total nodes checked: 2
[2026-02-02 10:30:05] [SUCCESS]  Successful checks: 2
[2026-02-02 10:30:05] [INFO]     Failed checks: 0
[2026-02-02 10:30:05] [INFO]     Nodes with pending restart: 0
[2026-02-02 10:30:05] [INFO]     Nodes with MSI installation in progress: 0
```

## Pending Restart Indicators

The script checks for the following restart indicators:

| Indicator | Registry/Method | Description |
|-----------|-----------------|-------------|
| CBS:RebootPending | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending` | Component servicing requires restart |
| WU:RebootRequired | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired` | Windows Update requires restart |
| SessionMgr:PendingFileRenameOperations | `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` | Pending file operations on restart |
| ComputerName:RenamePending | ComputerName registry comparison | Computer rename pending |
| Netlogon:JoinDomain | `HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain` | Domain join pending |
| Netlogon:AvoidSpnSet | `HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\AvoidSpnSet` | SPN set pending |
| ConfigMgr:RebootPending | CCM_ClientUtilities WMI | SCCM/ConfigMgr client restart pending |
| Orchestrator:RebootRequired | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\RebootRequired` | Update Orchestrator requires restart |
| AzureStackHCI:RebootRequired | `HKLM:\SOFTWARE\Microsoft\AzureStack\HCI\Update` | Azure Stack HCI update requires restart |
| MSI:InstallerInProgress | msiexec process + `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\InProgress` | Active Windows Installer operation blocks further MSI installs |

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| "Module not found" | Ensure the `TestPendingRestart-Module` folder exists with both `.psd1` and `.psm1` files |
| "Host unreachable" | Verify network connectivity and firewall rules allow WinRM (port 5985/5986) |
| "Access denied" | Use `-Credential` parameter with appropriate permissions |
| Empty results | Verify CSV file has correct `Cluster` column header |

### Firewall Requirements

Ensure the following ports are open between the script host and target nodes:
- **TCP 5985** - WinRM HTTP
- **TCP 5986** - WinRM HTTPS

## Author

**Neil Bird, MSFT**

## Version History

| Version | Date | Changes |
|---------|------|---------|| 0.2.4 | February 2nd, 2026 | MSI check no longer sets PendingRestart; combined Success/Errors into CheckSucceeded column; added MSI summary to console output || 0.2.3 | February 2nd, 2026 | Added `-ClusterName` parameter for direct cluster input without CSV |
| 0.2.2 | February 2nd, 2026 | Added Windows Installer (msiexec) active installation check with `MsiInstallationInProgress` column |
| 0.2.1 | February 2nd, 2026 | Fixed runspace result collection issue |
| 0.2.0 | January 30th, 2026 | Added parallel processing with runspaces |
| 0.1.0 | January 30th, 2026 | Initial release |

## License

This project is licensed under the MIT License - see the [LICENSE](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) file for details.
