function Get-AzLocalReadyForUpdateRows {
    ########################################
    <#
    .SYNOPSIS
        Projects the 'Ready for Update' subset of readiness rows into a flat,
        shared shape used by both the Assess Update Readiness pipeline and the
        Monitor Fleet Update Status pipeline.
    .DESCRIPTION
        v0.8.97 single source of truth for the "Clusters - Ready for Update"
        view. Filters readiness rows to those classified 'ReadyForUpdate' by
        the shared Get-AzLocalClusterReadinessStatus cascade, resolves each
        cluster's UpdateRing tag from the supplied ResourceId -> ring map, and
        returns one flat PSCustomObject per cluster with the columns shared by
        the markdown table renderer (Get-AzLocalReadyForUpdateTableMarkdown)
        and the CSV artefact.

        Rows are sorted by UpdateRing, then ClusterName, matching the wave-
        oriented ordering used elsewhere in the readiness summary.
    .PARAMETER ReadinessRows
        The readiness rows returned by Get-AzLocalClusterUpdateReadiness.
    .PARAMETER RingByResourceId
        Hashtable mapping (case-sensitive) ClusterResourceId -> UpdateRing tag
        value, built from cluster inventory. Missing entries fall back to '-'.
    .OUTPUTS
        PSCustomObject[] - ClusterName, UpdateRing, CurrentVersion,
        RecommendedUpdate, ClusterResourceId.
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.97
        Created : 2026-06-24
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([System.Object[]])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object[]]$ReadinessRows = @(),

        [Parameter(Mandatory = $false)]
        [hashtable]$RingByResourceId = @{}
    )

    $readyRows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in @($ReadinessRows)) {
        if ($null -eq $r) { continue }
        if ((Get-AzLocalClusterReadinessStatus -ReadinessRow $r) -ne 'ReadyForUpdate') { continue }

        $clusterResId = if ($r.PSObject.Properties['ClusterResourceId'] -and $r.ClusterResourceId) { [string]$r.ClusterResourceId } else { '' }
        $ring = if ($clusterResId -and $RingByResourceId.ContainsKey($clusterResId)) { [string]$RingByResourceId[$clusterResId] } else { '-' }
        $cv = if ($r.PSObject.Properties['CurrentVersion'] -and $r.CurrentVersion) { [string]$r.CurrentVersion } else { '-' }
        $ru = if ($r.PSObject.Properties['RecommendedUpdate'] -and $r.RecommendedUpdate) { [string]$r.RecommendedUpdate } else { '-' }

        $readyRows.Add([pscustomobject]@{
                ClusterName       = [string]$r.ClusterName
                UpdateRing        = $ring
                CurrentVersion    = $cv
                RecommendedUpdate = $ru
                ClusterResourceId = $clusterResId
            }) | Out-Null
    }

    $sorted = @($readyRows | Sort-Object UpdateRing, ClusterName)
    return $sorted
}
