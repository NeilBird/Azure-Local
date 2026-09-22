function Test-AzLocalUpdateSideloadedAllowed {
    <#
    .SYNOPSIS
        Evaluates whether an update is allowed by the UpdateSideloaded tag.
    .DESCRIPTION
        Returns a structured result indicating whether the sideloaded gate permits
        the update to proceed. Mirrors the shape returned by Test-AzLocalUpdateScheduleAllowed
        so the calling decision site in Start-AzLocalClusterUpdate can use a uniform pattern.

        Decision rules:
        - Supplied staged and selected names differ   -> Allowed=$false
        - Tag absent / empty                          -> Allowed=$true (no gate)
        - Tag parses to True (or '1')                 -> Allowed=$true
        - Tag parses to False (or '0')                -> Allowed=$false, Reason='UpdateSideloaded == False'
        - Tag value malformed                         -> throws (caller decides fail-closed vs -Force)
    .PARAMETER UpdateSideloaded
        The raw UpdateSideloaded tag value (or $null/empty if the tag is not set).
    .PARAMETER SideloadedVersion
        Optional UpdateSideloadedVersion tag containing the exact staged update name.
    .PARAMETER SelectedUpdateName
        Exact selected update name to compare with the staged identity. The caller
        separately checks the effective allowed-version policy.
    .OUTPUTS
        PSCustomObject with Allowed (bool), Reason (string), Details (string),
        TagPresent (bool), TagValue (string)
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$UpdateSideloaded,
        [string]$SideloadedVersion,
        [string]$SelectedUpdateName
    )

    if ($SideloadedVersion -and $SelectedUpdateName -and $SideloadedVersion -ne $SelectedUpdateName) {
        return [pscustomobject]@{
            Allowed = $false
            Reason = 'Sideloaded update identity mismatch'
            Details = "UpdateSideloadedVersion '$SideloadedVersion' does not match selected update '$SelectedUpdateName'."
            TagPresent = $true
            TagValue = $UpdateSideloaded
        }
    }

    if ([string]::IsNullOrWhiteSpace($UpdateSideloaded)) {
        return [PSCustomObject]@{
            Allowed    = $true
            Reason     = "UpdateSideloaded tag not set"
            Details    = "No sideloaded-payload gate configured on this cluster."
            TagPresent = $false
            TagValue   = $null
        }
    }

    # Throws on malformed - caller catches and applies fail-closed/Force semantics.
    $parsed = ConvertFrom-AzLocalUpdateSideloaded -Value $UpdateSideloaded

    if ($parsed) {
        return [PSCustomObject]@{
            Allowed    = $true
            Reason     = "UpdateSideloaded == True"
            Details    = "Sideloaded payload is staged; update is permitted."
            TagPresent = $true
            TagValue   = $UpdateSideloaded
        }
    }

    return [PSCustomObject]@{
        Allowed    = $false
        Reason     = "UpdateSideloaded == False, update is blocked"
        Details    = "Cluster has UpdateSideloaded=False (sideloaded content has not been staged or has already been consumed)."
        TagPresent = $true
        TagValue   = $UpdateSideloaded
    }
}
