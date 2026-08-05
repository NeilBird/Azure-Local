@{
    RootModule = 'Get-HyperVVMCheckpointHealth.psm1'
    NestedModules = @(
        'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Collection.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
    )
    ModuleVersion = '0.2.32'
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
            ReleaseNotes = 'Version 0.2.32 strengthens evidence integrity and fleet performance: VSS native failures and malformed output are incomplete evidence; historic attribution uses structured VM identity; event CSVs preserve RecordId and explicit empty/unavailable states; standard and historic event evidence share one automation projection; artifact failures lower confidence; fleet coverage uses High/Moderate/Low confidence; node prefetch scales to eight workers; and historic cross-node scans use bounded fan-out with query, failure, and duration telemetry.'
        }
    }
}
