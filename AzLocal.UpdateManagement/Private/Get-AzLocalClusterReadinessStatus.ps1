function Get-AzLocalClusterReadinessStatus {
    ########################################
    <#
    .SYNOPSIS
        Classifies a single Get-AzLocalClusterUpdateReadiness row into exactly
        one readiness-status bucket using the canonical priority cascade.
    .DESCRIPTION
        v0.8.74 single source of truth for the "what state is this cluster in"
        classification shared by Step.5 (Export-AzLocalClusterUpdateReadinessReport),
        Step.7 (Export-AzLocalClusterReadinessGateReport) and Step.9
        (Export-AzLocalFleetUpdateStatusReport).

        Prior to this helper each step re-implemented the bucket logic inline,
        and the "Up to Date" definition drifted: Step.9's rendered Primary Status
        table used a priority cascade (correct), while Step.5 and the JSON exports
        used a stricter test that also required AllAvailableUpdates to be empty.
        That strict test silently returned zero "Up to Date" clusters in
        production because a cluster that has applied all updates still carries
        the already-Installed update names in AllAvailableUpdates - so up-to-date
        clusters were mis-bucketed as "Not Ready" (Step.5) or shown with a
        no-entry icon (Step.7), implying failure.

        Every consumer now calls this helper so the classification is identical
        across all three steps.

        Priority cascade (first match wins, cluster counted exactly once):
            UpdateFailed > ActionRequired > HealthFailure > SbeBlocked >
            InProgress > ReadyForUpdate > UpToDate > NeedsInvestigation
    .PARAMETER ReadinessRow
        A single PSCustomObject row as emitted by Get-AzLocalClusterUpdateReadiness.
        Optional properties are read defensively for Set-StrictMode -Version Latest.
    .OUTPUTS
        [string] one of:
            UpdateFailed, ActionRequired, HealthFailure, SbeBlocked,
            InProgress, ReadyForUpdate, UpToDate, NeedsInvestigation
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.74
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$ReadinessRow
    )

    Set-StrictMode -Version Latest

    # Strict-mode-safe optional property reads. Different code paths in
    # Get-AzLocalClusterUpdateReadiness emit rows with the same shape, but
    # external callers (and the error/catch row) may not, so guard every read.
    $updateState = if ($ReadinessRow.PSObject.Properties['UpdateState'] -and $ReadinessRow.UpdateState) { [string]$ReadinessRow.UpdateState } else { '' }
    $healthState = if ($ReadinessRow.PSObject.Properties['HealthState'] -and $ReadinessRow.HealthState) { [string]$ReadinessRow.HealthState } else { '' }
    $hasPrereq   = if ($ReadinessRow.PSObject.Properties['HasPrerequisiteUpdates'] -and $ReadinessRow.HasPrerequisiteUpdates) { [string]$ReadinessRow.HasPrerequisiteUpdates } else { '' }
    $readyForUpdate = if ($ReadinessRow.PSObject.Properties['ReadyForUpdate']) { [bool]$ReadinessRow.ReadyForUpdate } else { $false }

    if ($updateState -in @('Failed', 'UpdateFailed', 'NeedsAttention'))       { return 'UpdateFailed' }
    elseif ($updateState -eq 'PreparationFailed')                            { return 'ActionRequired' }
    elseif ($healthState -eq 'Failure')                                      { return 'HealthFailure' }
    elseif ($hasPrereq)                                                      { return 'SbeBlocked' }
    elseif ($updateState -in @('UpdateInProgress', 'PreparationInProgress')) { return 'InProgress' }
    elseif ($readyForUpdate -eq $true)                                       { return 'ReadyForUpdate' }
    elseif ($updateState -in @('UpToDate', 'AppliedSuccessfully'))           { return 'UpToDate' }
    else                                                                     { return 'NeedsInvestigation' }
}
