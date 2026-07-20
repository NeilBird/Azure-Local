@{
    RootModule = 'Get-HyperVVMCheckpointHealth.psm1'
    ModuleVersion = '0.2.18'
    CompatiblePSEditions = @('Desktop')
    GUID = '8b35df55-2975-48f8-bdb8-c8bc8da4a49c'
    Author = 'Neil Bird, Microsoft'
    CompanyName = 'Microsoft'
    Copyright = '(c) Microsoft. All rights reserved.'
    Description = 'Read-only Hyper-V VM checkpoint, differencing-disk, replication, and event-evidence health audit for Azure Local and Windows Server Failover Clusters.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-HyperVVMCheckpointHealth')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('AzureLocal', 'Hyper-V', 'FailoverCluster', 'Checkpoint', 'Diagnostics')
            LicenseUri = 'https://github.com/NeilBird/Azure-Local/blob/main/LICENSE'
            ProjectUri = 'https://github.com/NeilBird/Azure-Local/tree/main/Get-HyperVVMCheckpointHealth'
            ReleaseNotes = 'Version 0.2.18 adds evidence-integrity hardening, typed replication assessment, state consistency checks, private assessment and collection modules, and a Windows PowerShell 5.1 regression suite.'
        }
    }
}
