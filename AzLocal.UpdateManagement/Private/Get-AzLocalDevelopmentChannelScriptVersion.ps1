function Get-AzLocalDevelopmentChannelScriptVersion {
    <#
    .SYNOPSIS
        Extracts the version stamp from Apply-ModuleDevelopmentChannel.ps1.
    .DESCRIPTION
        Returns the version from the first valid
        AZLOCAL-DEVELOPMENT-CHANNEL-VERSION marker, or $null when no valid
        marker is present. Copy-AzLocalPipelineExample and
        Update-AzLocalPipelineExample use this value for safe, version-gated
        refreshes of the managed repo-root helper.
    .PARAMETER Text
        Full script text to scan.
    .OUTPUTS
        [version]
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, '(?im)^\s*#+\s*AZLOCAL-DEVELOPMENT-CHANNEL-VERSION\s*:\s*([0-9]+(?:\.[0-9]+){1,3})\s*$')
    if (-not $match.Success) {
        return $null
    }

    [version]$parsed = $null
    if ([version]::TryParse($match.Groups[1].Value.Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $null
}