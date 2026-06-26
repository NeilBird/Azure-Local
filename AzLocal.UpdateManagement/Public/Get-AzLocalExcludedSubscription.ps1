function Get-AzLocalExcludedSubscription {
    ########################################
    <#
    .SYNOPSIS
        Shows the subscription IDs that are currently excluded from all
        AzLocal.UpdateManagement Azure Resource Graph queries.

    .DESCRIPTION
        v0.9.1 visibility cmdlet for the optional subscription exclusion list.
        Returns the effective set of excluded subscription IDs for this session,
        resolving them on first use from either an explicit
        Set-AzLocalExcludedSubscription call or the
        AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH environment variable (which points at
        a CSV in source control - the documented CI/CD single source of truth).

        Use this to confirm, from an interactive session or a pipeline step,
        which subscriptions are being filtered out of inventory, readiness,
        fleet status, and every other ARG-backed report. Excluded subscriptions
        are removed centrally inside Invoke-AzResourceGraphQuery, so every
        cmdlet and report inherits the exclusion automatically.

        When the source is a header-only CSV (the variable is wired but no rows
        are populated) the count is 0 and nothing is excluded - this is a valid,
        non-failing state.

    .OUTPUTS
        [PSCustomObject] with:
          - SubscriptionIds : [string[]] of lowercased excluded subscription GUIDs
          - Count           : number of excluded subscriptions
          - Source          : where the list came from (the CSV path, an
                              explicit override marker, or $null when none)
          - IsExplicit      : $true when set via Set-AzLocalExcludedSubscription

    .EXAMPLE
        Get-AzLocalExcludedSubscription

        Lists the subscriptions currently excluded from ARG queries this session.

    .EXAMPLE
        (Get-AzLocalExcludedSubscription).SubscriptionIds

        Returns just the array of excluded subscription-id GUIDs.

    .NOTES
        Author : AzLocal.UpdateManagement
        Version: 0.9.1
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    Set-StrictMode -Version Latest

    $ids = @(Get-AzLocalExcludedSubscriptionId)

    return [PSCustomObject]@{
        SubscriptionIds = $ids
        Count           = $ids.Count
        Source          = $script:ExcludedSubscriptionSource
        IsExplicit      = [bool]$script:ExcludedSubscriptionsExplicit
    }
}
