function New-AzLocalSubscriptionExclusionKqlClause {
    ########################################
    <#
    .SYNOPSIS
        Builds the KQL fragment that excludes resources belonging to a set of
        subscription IDs from an Azure Resource Graph query.

    .DESCRIPTION
        v0.9.1 helper for the central subscription-exclusion injection in
        Invoke-AzResourceGraphQuery. Given a set of subscription-id GUIDs, this
        returns a single KQL filter clause of the form:

            | where id !startswith '/subscriptions/<g1>/' and id !startswith '/subscriptions/<g2>/'

        The clause filters on the always-present 'id' column (every ARM
        resource id begins with '/subscriptions/<guid>/'), which makes it
        universal across the 'resources' and 'extensibilityresources' tables
        used throughout the module - including the extensibilityresources
        queries that derive their subscription from split(id,'/')[2] rather than
        a native subscriptionId column. KQL 'startswith' is case-insensitive, so
        GUID casing is irrelevant.

        Returns an empty string when the input is empty, so callers can inject
        unconditionally and get a no-op when there is nothing to exclude.

    .PARAMETER SubscriptionId
        The subscription-id GUIDs to exclude. Empty / whitespace entries are
        ignored.

    .OUTPUTS
        [string] - the KQL clause, or '' when there is nothing to exclude.

    .NOTES
        Author : AzLocal.UpdateManagement
        Version: 0.9.1
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId
    )

    Set-StrictMode -Version Latest

    if (-not $SubscriptionId -or @($SubscriptionId).Count -eq 0) {
        return ''
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($sid in $SubscriptionId) {
        if ([string]::IsNullOrWhiteSpace($sid)) { continue }
        $parts.Add(("id !startswith '/subscriptions/{0}/'" -f $sid.Trim().ToLower()))
    }

    if ($parts.Count -eq 0) {
        return ''
    }

    return '| where ' + ($parts.ToArray() -join ' and ')
}
