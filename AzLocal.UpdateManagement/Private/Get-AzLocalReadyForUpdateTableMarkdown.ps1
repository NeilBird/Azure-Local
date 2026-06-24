function Get-AzLocalReadyForUpdateTableMarkdown {
    ########################################
    <#
    .SYNOPSIS
        Renders the shared "Clusters - Ready for Update" markdown table.
    .DESCRIPTION
        v0.8.97 single source of truth for the "### Clusters - Ready for Update"
        section shared by the Assess Update Readiness pipeline and the Monitor
        Fleet Update Status pipeline. Consumes the flat rows produced by
        Get-AzLocalReadyForUpdateRows and emits markdown lines (a heading, the
        shared Ctrl-click tip, and a table) ready to append to a step-summary
        builder.

        Columns: Cluster (portal deep-link), Update Ring, Current Update,
        Recommended Update.
    .PARAMETER ReadyRows
        The projected rows from Get-AzLocalReadyForUpdateRows.
    .PARAMETER Heading
        The markdown heading line. Default '### Clusters - Ready for Update'.
    .OUTPUTS
        [string[]] - markdown lines to append to a step-summary builder.
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
        [object[]]$ReadyRows = @(),

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Heading = '### Clusters - Ready for Update'
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add($Heading)
    [void]$lines.Add('')

    $rows = @($ReadyRows)
    if ($rows.Count -eq 0) {
        [void]$lines.Add('_No clusters are currently Ready for Update._')
        [void]$lines.Add('')
        return $lines.ToArray()
    }

    [void]$lines.Add("_$($rows.Count) cluster(s) ready to update now, grouped by UpdateRing._")
    [void]$lines.Add('')
    [void]$lines.Add((Get-AzLocalCtrlClickTip))
    [void]$lines.Add('')
    [void]$lines.Add('| Cluster | Update Ring | Current Update | Recommended Update |')
    [void]$lines.Add('|---------|-------------|----------------|--------------------|')
    foreach ($r in $rows) {
        $clusterResId = if ($r.PSObject.Properties['ClusterResourceId'] -and $r.ClusterResourceId) { [string]$r.ClusterResourceId } else { '' }
        $clusterCell = Get-AzLocalClusterPortalLink -ClusterName ([string]$r.ClusterName) -ClusterResourceId $clusterResId
        $ring = if ($r.PSObject.Properties['UpdateRing'] -and $r.UpdateRing) { ([string]$r.UpdateRing) -replace '\|', '\|' } else { '-' }
        $cv = if ($r.PSObject.Properties['CurrentVersion'] -and $r.CurrentVersion) { ([string]$r.CurrentVersion) -replace '\|', '\|' } else { '-' }
        $ru = if ($r.PSObject.Properties['RecommendedUpdate'] -and $r.RecommendedUpdate) { ([string]$r.RecommendedUpdate) -replace '\|', '\|' } else { '-' }
        [void]$lines.Add("| $clusterCell | $ring | $cv | $ru |")
    }
    [void]$lines.Add('')
    return $lines.ToArray()
}
