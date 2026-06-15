function Get-AzLocalClusterPortalLink {
    ########################################
    <#
    .SYNOPSIS
        Wraps a cluster name in an Azure-portal deep-link anchor for
        step-summary markdown.
    .DESCRIPTION
        v0.8.81 single source of truth for the "<a href='...portal.azure.com/#@/resource{id}'>{name}</a>"
        snippet shared by every Public cmdlet that renders a cluster column
        in a markdown step summary.

        Prior to this helper the same anchor was inlined into Step.04/08/09/10
        with subtle drift (some used $r.ClusterPortalUrl, some constructed the
        URL from ClusterResourceId, some forgot to escape, etc.). All consumers
        now call this helper.

        Falls back gracefully:
          - If ClusterPortalUrl is supplied, uses it verbatim.
          - Else if ClusterResourceId is supplied, builds the portal URL.
          - Else returns the plain cluster name (no markup).

        Output stays HTML-safe by default - the cluster name is passed through
        as-is because every emitting site already controls the value
        (it comes from ARG output, never user input). Override -Escape to
        force HTML-escape if the caller is not certain.

    .PARAMETER ClusterName
        The visible cluster name to display inside the anchor. Required.

    .PARAMETER ClusterResourceId
        The full ARM resource id of the cluster (used to build the portal URL
        when ClusterPortalUrl is not supplied).

    .PARAMETER ClusterPortalUrl
        A pre-built portal URL. When supplied, takes precedence over
        ClusterResourceId.

    .PARAMETER Escape
        Force HTML escaping of the cluster name inside the anchor. Off by
        default - cluster names come from ARG and never contain markup.

    .OUTPUTS
        [string] - HTML anchor (when a URL is available) or plain name.

    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.81
        Created : 2026-06-15
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter()]
        [string]$ClusterResourceId,

        [Parameter()]
        [string]$ClusterPortalUrl,

        [Parameter()]
        [switch]$Escape
    )

    Set-StrictMode -Version Latest

    if (-not $ClusterName) { return '' }

    $name = if ($Escape) {
        $ClusterName -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
    } else {
        $ClusterName
    }

    $url = if ($ClusterPortalUrl) {
        $ClusterPortalUrl
    } elseif ($ClusterResourceId) {
        'https://portal.azure.com/#@/resource{0}' -f $ClusterResourceId
    } else {
        ''
    }

    if ($url) {
        return ('<a href="{0}">{1}</a>' -f $url, $name)
    }

    return $name
}
