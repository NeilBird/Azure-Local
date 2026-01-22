@{
    ModuleVersion = '0.1.6'
    GUID = 'a1b2c3d4-e5f6-7890-1234-567890abcdef'
    Author = 'Neil Bird, Azure Edge Infra team'
    CompanyName = 'Microsoft'
    Copyright = '(c) 2025 Microsoft. All rights reserved.'
    Description = 'PowerShell module for creating and managing Azure Local VMs with shared disks, featuring intelligent marketplace image discovery and automatic vNIC creation'
    PowerShellVersion = '5.1'
    
    RootModule = 'AzureLocalVM.psm1'
    
    FunctionsToExport = @(
        'Write-Log'
        'Invoke-WithRetry'
        'Test-Prerequisites'
        'Get-CustomLocationIdForCluster'
        'Test-AzureLocalLogicalNetwork'
        'Test-AzureLocalVMImage'
        'New-AzureLocalLogicalNetwork'
        'New-AzureLocalVNIC'
        'New-AzureLocalVM'
        'Get-CSVWithMostFreeSpace'
        'New-HyperVVHDSet'
        'Add-VHDSetToAzureLocalVM'
        'Add-AzureLocalVMDataDisk'
        'Remove-AzureLocalVMDataDisk'
        'Remove-AzureLocalVM'
    )
    
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    
    PrivateData = @{
        PSData = @{
            Tags = @('Azure', 'AzureLocal', 'AzureStackHCI', 'HyperV', 'VirtualMachine', 'SharedDisk')
            ProjectUri = ''
            ReleaseNotes = @'
Version 0.1.3 (December 3, 2025)
- Enhanced Test-AzureLocalVMImage with interactive marketplace image download
- Added automatic image download using New-AzStackHCIVMImage
- New-AzureLocalVM now prompts to download missing images from marketplace
- Improved user experience with numbered selection menus
- Return type change: Test-AzureLocalVMImage now returns PSCustomObject
'@
        }
    }
}
