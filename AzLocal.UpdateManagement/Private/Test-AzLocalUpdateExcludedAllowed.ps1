function Test-AzLocalUpdateExcludedAllowed {
    <#
    .SYNOPSIS
        Evaluates whether an update is allowed by the UpdateExcluded tag.
    .DESCRIPTION
        Returns a structured result indicating whether the operator-set exclusion gate
        permits the update to proceed. Mirrors the shape returned by
        Test-AzLocalUpdateSideloadedAllowed / Test-AzLocalUpdateScheduleAllowed so the
        calling decision site in Start-AzLocalClusterUpdate can use a uniform pattern.

        UpdateExcluded is a hard, fleet-level override. When set to True the cluster
        is skipped regardless of UpdateRing scope, UpdateSideloaded state, or
        UpdateStartWindow / UpdateExclusionsWindow schedule. It is evaluated BEFORE the
        sideloaded and schedule gates.

        Decision rules:
        - Tag absent / empty                          -> Allowed=$true (no override)
        - Tag parses to True (or '1')                 -> Allowed=$false, Reason='UpdateExcluded == True'
        - Tag parses to False (or '0')                -> Allowed=$true
        - Tag value malformed                         -> throws (caller decides fail-closed vs -Force)
    .PARAMETER UpdateExcluded
        The raw UpdateExcluded tag value (or $null/empty if the tag is not set).
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
        [string]$UpdateExcluded
    )

    if ([string]::IsNullOrWhiteSpace($UpdateExcluded)) {
        return [PSCustomObject]@{
            Allowed    = $true
            Reason     = "UpdateExcluded tag not set"
            Details    = "No operator exclusion override configured on this cluster."
            TagPresent = $false
            TagValue   = $null
        }
    }

    # Throws on malformed - caller catches and applies fail-closed/Force semantics.
    $parsed = ConvertFrom-AzLocalUpdateExcluded -Value $UpdateExcluded

    if ($parsed) {
        return [PSCustomObject]@{
            Allowed    = $false
            Reason     = "UpdateExcluded == True, update is blocked"
            Details    = "Cluster has UpdateExcluded=True (operator override). This gate overrides UpdateRing scope, UpdateSideloaded state, and UpdateStartWindow / UpdateExclusionsWindow schedule. Flip the tag to False to re-enable automation."
            TagPresent = $true
            TagValue   = $UpdateExcluded
        }
    }

    return [PSCustomObject]@{
        Allowed    = $true
        Reason     = "UpdateExcluded == False"
        Details    = "Cluster is not excluded by operator override; downstream gates evaluated."
        TagPresent = $true
        TagValue   = $UpdateExcluded
    }
}
