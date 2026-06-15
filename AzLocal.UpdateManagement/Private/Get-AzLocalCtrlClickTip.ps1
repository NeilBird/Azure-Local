function Get-AzLocalCtrlClickTip {
    ########################################
    <#
    .SYNOPSIS
        Returns the canonical "Hold Ctrl when clicking" markdown tip line
        used above every cluster-link table in pipeline step summaries.
    .DESCRIPTION
        v0.8.81 single source of truth for the tip note shared by Step.05-10
        cmdlets that render cluster portal links. GitHub markdown strips
        target="_blank" from anchors, so without this hint operators end up
        navigating away from the step summary every time they click a cluster
        name. The tip explains the Ctrl/Cmd-click workaround once per table.

        Prior to this helper the same string was duplicated (with subtle drift)
        across Step.08, Step.09 and Step.10. All consumers now call this helper.

    .OUTPUTS
        [string] - the markdown blockquote line, ready to add to a markdown
        builder list. Does NOT include a trailing newline; callers add it
        with their own [Environment]::NewLine join.

    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.81
        Created : 2026-06-15
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([string])]
    param()

    Set-StrictMode -Version Latest

    return '> **Tip:** Hold `Ctrl` (or `Cmd` on macOS) when clicking - or middle-click - Cluster links to open them in a new tab. (GitHub markdown strips `target="_blank"`.)'
}
