@{
    RootModule = 'Get-HyperVVMCheckpointHealth.psm1'
    NestedModules = @(
        'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Collection.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
    )
    ModuleVersion = '0.2.24'
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
            ProjectUri = 'https://aka.ms/Get-HyperVVMCheckpointHealth'
            ReleaseNotes = 'Version 0.2.24 improvements: separates Hyper-V Replica product health from measurement evidence in verdict reasons and actions; reports a zero missed-cycle rate as 0.00 percent when cycles were measured; aligns TXT and HTML evidence labels, concern highlighting, incomplete-assessment guidance, and conditional debug-log references; adds clearer event 18012 and storage-evidence guidance; improves per-VM report usability with copyable VM names, automatically expanded verdict-driving event details, and stable summary-table badge placement; and improves and simplifies the language used in next-step guidance, recommendations, and evidence-based output to increase clarity.'
        }
    }
}
