function Test-AzLocalUpdateRunsInFlight {
    <#
    .SYNOPSIS
        Cheap fleet-wide probe: returns $true if ANY Azure Local update run is
        currently InProgress across every accessible subscription.

    .DESCRIPTION
        Runs a single, tightly-projected Azure Resource Graph query that asks
        only one question: "is there at least one update run whose state is
        InProgress anywhere I can see?". The query projects a single column and
        caps the result at one row (`| project id | limit 1`), so it is far
        cheaper than the per-cluster sweep that the Step.7 monitor performs.

        This backs the -SkipWhenIdle switch on
        Export-AzLocalUpdateRunMonitorReport: when the whole fleet has zero
        in-flight runs there is nothing for the monitor to report, so the
        expensive Get-AzLocalClusterInventory + Get-AzLocalUpdateRuns sweep can
        be skipped and the IDLE result emitted immediately.

        Scope note: the probe is deliberately fleet-wide and scope-independent.
        If the entire fleet has zero in-flight runs then any sub-scope (e.g. a
        single update ring) is necessarily also idle, so a single global probe
        is a sound gate for every -Scope value of the caller.

        Fail-safe contract: this function does NOT swallow query errors. The
        caller is expected to treat a probe failure as "maybe in-flight" (i.e.
        do NOT skip) so a transient ARG hiccup never causes a genuinely
        in-flight fleet to be reported as idle.

    .PARAMETER SubscriptionId
        Optional. If supplied, scopes the probe to that single subscription.
        Omit (the default) to probe across every subscription the identity can
        read - the correct behaviour for a fleet-wide "anything in flight?"
        gate.

    .OUTPUTS
        [bool]. $true if at least one update run is InProgress; otherwise
        $false. Throws if the underlying Resource Graph query fails.

    .EXAMPLE
        if (Test-AzLocalUpdateRunsInFlight) { 'Something is updating' }

    .NOTES
        Module: AzLocal.UpdateManagement (v0.8.90+)
        Used by: Export-AzLocalUpdateRunMonitorReport -SkipWhenIdle
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId
    )

    # Single-line KQL (Invoke-AzResourceGraphQuery normalises whitespace, but we
    # keep it on one line and free of '//' comments per that helper's contract).
    $kql = "extensibilityresources | where type =~ 'microsoft.azurestackhci/clusters/updates/updateruns' | where tostring(properties.state) =~ 'InProgress' | project id | limit 1"

    $argParams = @{ Query = $kql }
    if ($SubscriptionId) { $argParams['SubscriptionId'] = $SubscriptionId }

    # Invoke-AzResourceGraphQuery uses a `return , $arr` unary-comma return, so it
    # MUST be assigned directly - wrapping the call in @() would collapse the
    # row-set to Object[1] (see github-patterns.md). Wrapping the already-
    # materialised $rows variable in @() is safe and guarantees a .Count.
    $rows = Invoke-AzResourceGraphQuery @argParams
    return (@($rows).Count -gt 0)
}
