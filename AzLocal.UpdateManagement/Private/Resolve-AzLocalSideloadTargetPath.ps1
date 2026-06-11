function Resolve-AzLocalSideloadTargetPath {
    <#
    .SYNOPSIS
        Resolves the UNC path of an Azure Local cluster's infrastructure 'import'
        share, where the CombinedSolutionBundle (and any staged OEM SBE content)
        is copied prior to running Add-SolutionUpdate on a cluster node.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation.

        Precedence:
          1. An explicit ImportSharePath supplied on the auth-map row (operator
             override; may be a full UNC such as
             \\cluster\ClusterStorage$\Infrastructure_1\Shares\SU1_Infrastructure_1\import).
          2. The conventional Azure Local layout derived from the remoting host:
             \\<remotingHost>\C$\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import

        The on-prem documented mechanism copies the bundle into the import share,
        then expands it to an 'import\Solution' subfolder for Add-SolutionUpdate.
        This helper returns the 'import' root; the caller chooses the Solution /
        SBE subfolder.

    .PARAMETER RemotingHost
        The host name / FQDN used to reach the cluster (cluster name, override
        FQDN, or name + suffix). Used to build the default UNC.

    .PARAMETER ImportSharePath
        Optional operator override (auth-map ImportSharePath column).

    .OUTPUTS
        [string] the UNC path of the import share root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RemotingHost,

        [string]$ImportSharePath
    )

    if (-not [string]::IsNullOrWhiteSpace($ImportSharePath)) {
        return $ImportSharePath.TrimEnd('\')
    }

    # Default conventional Azure Local infrastructure volume layout.
    $relative = 'C$\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import'
    return ('\\{0}\{1}' -f $RemotingHost, $relative)
}
