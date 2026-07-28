@{
    RootModule = 'Get-HyperVVMCheckpointHealth.psm1'
    NestedModules = @(
        'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Collection.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
    )
    ModuleVersion = '0.2.29'
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
            ReleaseNotes = 'Version 0.2.29 improves report evidence hierarchy and precision: labels base-disk age separately from checkpoint age; limits per-VM TXT event tables to VM-attributed rows while summarizing node-wide context; adds the Boolean CollectedAsConcern CSV field while retaining Concern compatibility; scopes the stale-layer card to attached AVHDX; preserves Replica measurement advisories in OK prose; removes unsupported attribution of timestamp-only changes; moves cluster low-signal event detail to the bottom of storage health with a conditional Executive Summary link; and distinguishes unreferenced disks in VM-associated folders from referenced-owner/folder placement mismatches without inferring ownership from filenames.'
        }
    }
}
