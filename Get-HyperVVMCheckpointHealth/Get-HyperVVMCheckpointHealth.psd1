@{
    RootModule = 'Get-HyperVVMCheckpointHealth.psm1'
    NestedModules = @(
        'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Collection.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Policy.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1'
        'Private\Get-HyperVVMCheckpointHealth.Storage.psm1'
    )
    ModuleVersion = '0.2.21'
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
            ReleaseNotes = 'Version 0.2.21 improvements: prevents healthy Replica metadata writes from causing state-only INVESTIGATE verdicts; aligns fleet Replica, HRL, and event evidence; highlights abnormal Replica observations; adds collapsible per-VM cards and complete housekeeping CSV export; contains the VM summary table within the shared report width; submits bounded Windows PowerShell 5.1 remote ownership-inventory workers before local collection to permit overlap when run on a verified target-cluster node, including two-node clusters, with single-node/workstation sequential behavior, fallback, and expanded worker/coordinator telemetry; and makes -PassThru a stable tested automation contract with full per-VM event evidence plus shared run-level housekeeping, storage, discovery, node-event, metadata, outcome, and artifact data.'
        }
    }
}
