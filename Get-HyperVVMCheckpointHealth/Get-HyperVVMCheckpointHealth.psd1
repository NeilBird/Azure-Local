@{
    RootModule = 'Get-HyperVVMCheckpointHealth.psm1'
    NestedModules = @(
        'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Collection.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
    )
    ModuleVersion = '0.2.23'
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
            ReleaseNotes = 'Version 0.2.23 improvements: adds bounded cross-node event and VSS prefetch with same-node serialization, retries, deterministic cache merging, sequential fallback, and performance telemetry; adds read-only storage Health Service fault evidence, fault-specific recommended actions, and degraded-storage Executive Summary detail while excluding unrelated cluster faults and retaining the CSS Storage Diagnostic as the general deep-analysis follow-up; adds visible accessible housekeeping sort arrows; and clarifies that housekeeping category rows may overlap and are not unique-file counts.'
        }
    }
}
