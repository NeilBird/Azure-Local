@{
    # Module identification
    RootModule        = 'TestPendingRestart.psm1'
    ModuleVersion     = '0.2.3'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    
    # Author information
    Author            = 'Neil Bird'
    CompanyName       = 'Microsoft'
    Copyright         = '(c) 2026 Microsoft. All rights reserved.'
    
    # Module description
    Description       = 'PowerShell module to test computers for pending restart indicators. Checks for Windows Update, CBS, pending file renames, computer rename, domain join signals, SCCM/ConfigMgr client indicators, Azure Local/HCI-specific indicators (CAU state, Azure Stack HCI updates), and active Windows Installer (msiexec) installations.'
    
    # Minimum PowerShell version required
    PowerShellVersion = '5.1'
    
    # Functions to export from this module
    FunctionsToExport = @(
        'Write-Log',
        'Test-PendingRestart'
    )
    
    # Cmdlets to export (none in this module)
    CmdletsToExport   = @()
    
    # Variables to export (none in this module)
    VariablesToExport = @()
    
    # Aliases to export (none in this module)
    AliasesToExport   = @()
    
    # Private data / PSData for PowerShell Gallery
    PrivateData       = @{
        PSData = @{
            Tags         = @('PendingRestart', 'Reboot', 'WindowsUpdate', 'Azure', 'Cluster', 'AzureLocal', 'HCI', 'AzureStackHCI')
            LicenseUri   = ''
            ProjectUri   = ''
            ReleaseNotes = @'
## Version 0.2.0
- Added -Credential parameter for remote authentication
- Added -TimeoutSeconds parameter for connection timeout control
- Added -Detailed switch for verbose diagnostic information
- Added Azure Local/HCI-specific checks (Orchestrator, Azure Stack HCI Update state)
- Improved pipeline support with begin/process/end blocks
- Added session options for better timeout handling
- Enhanced error handling and reporting

## Version 0.1.5
- Initial module release
- Added Write-Log function with color-coded output and timestamps
- Added Test-PendingRestart function with comprehensive error handling
- Checks: CBS, Windows Update, Pending File Rename, Computer Rename, Netlogon, ConfigMgr
- Support for local and remote computer checks via WinRM
'@
        }
    }
}
