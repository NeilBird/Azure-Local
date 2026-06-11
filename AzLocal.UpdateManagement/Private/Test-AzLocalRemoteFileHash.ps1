function Test-AzLocalRemoteFileHash {
    <#
    .SYNOPSIS
        Verifies the SHA256 of a file on a remote Azure Local cluster node against
        the catalog-published hash.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation. After the
        detached robocopy lands the bundle on the cluster's import share, this
        confirms integrity on the node itself (over WinRM) before Add-SolutionUpdate
        is run, guarding against a partial/corrupt copy.

    .PARAMETER Session
        An open PSSession to the cluster node (from New-AzLocalPSRemotingSession).

    .PARAMETER RemotePath
        The path to the file AS SEEN ON THE NODE (local path on the node, not the
        UNC the runner/agent used).

    .PARAMETER ExpectedSha256
        The catalog SHA256 to compare against (case-insensitive).

    .OUTPUTS
        [PSCustomObject] with: Match [bool], ExpectedSha256, ActualSha256, RemotePath.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        # Untyped (ValidateNotNull) so the function is unit-testable by passing a
        # session double and mocking Invoke-Command; callers pass a real PSSession.
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Session,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RemotePath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedSha256
    )

    $actual = Invoke-Command -Session $Session -ScriptBlock {
        param($Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $null
        }
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    } -ArgumentList $RemotePath

    $actualText = if ($null -ne $actual) { ([string]$actual).ToUpperInvariant() } else { '' }
    $match = (-not [string]::IsNullOrEmpty($actualText)) -and
             [string]::Equals($actualText, $ExpectedSha256.ToUpperInvariant(), [System.StringComparison]::OrdinalIgnoreCase)

    return [PSCustomObject]@{
        Match          = $match
        ExpectedSha256 = $ExpectedSha256.ToUpperInvariant()
        ActualSha256   = $actualText
        RemotePath     = $RemotePath
    }
}
