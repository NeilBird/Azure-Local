function Get-DeepestErrorMessage {
    <#
    .SYNOPSIS
        Recursively walks the update run step hierarchy and returns the deepest non-empty errorMessage from any Error/Failed step.
    .DESCRIPTION
        The ARM payload nests errorMessage on whichever leaf actually threw. Older parents in the
        chain may carry a duplicate or summarised message, or no message at all. This helper
        applies a coalesce(e8Msg..e1Msg) pattern: walk the tree, prefer the deepest non-empty
        errorMessage on an Error/Failed-status step. Used by Format-AzLocalUpdateRun in v0.7.96
        to surface a dedicated ErrorMessage column so operators can triage failed runs without
        clicking through to the Azure portal.

        v0.8.80: when -IncludeDescription is supplied the helper returns a hashtable
        @{ Msg = ''; Description = '' } instead of a bare string. The description is the
        step's `description` field captured at the SAME depth as Msg, so renderers that
        want to display both (the human-readable line AND the raw trace) can do so. The
        default (bare-string) return shape is preserved for back-compat with the existing
        unit tests.
    .NOTES
        Returns an empty string (or @{Msg='';Description=''} with -IncludeDescription) when
        no error message is found (callers can if-guard cheaply).

        Consumed by Format-AzLocalUpdateRun -> Get-AzLocalUpdateRuns -> the Step.08
        monitor renderer (Export-AzLocalUpdateRunMonitorReport).

        Parallel walker: Resolve-AzLocalUpdateRunDeepestError (Private/) walks the same
        tree shape but returns a richer hashtable, used by Get-AzLocalUpdateRunFailures
        for the Step.09 fleet-update-status renderer. If you change the deepest-step
        contract here, update Resolve-AzLocalUpdateRunDeepestError too so the two
        pipelines stay in sync.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $false)]
        [array]$Steps,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 20,

        [Parameter(Mandatory = $false)]
        [switch]$IncludeDescription
    )

    $emptyResult = if ($IncludeDescription) { @{ Msg = ''; Description = '' } } else { '' }
    if (-not $Steps -or $Steps.Count -eq 0 -or $MaxDepth -le 0) { return $emptyResult }

    foreach ($step in $Steps) {
        if ($step.status -notin @('Error', 'Failed')) { continue }

        if ($step.steps -and $step.steps.Count -gt 0) {
            $deeper = Get-DeepestErrorMessage -Steps $step.steps -MaxDepth ($MaxDepth - 1) -IncludeDescription:$IncludeDescription
            if ($IncludeDescription) {
                if ($deeper.Msg) { return $deeper }
            }
            elseif ($deeper) { return $deeper }
        }
        if ($step.PSObject.Properties['errorMessage'] -and $step.errorMessage) {
            $msg = [string]$step.errorMessage
            if ($IncludeDescription) {
                $desc = ''
                if ($step.PSObject.Properties['description'] -and $step.description) {
                    $desc = [string]$step.description
                }
                return @{ Msg = $msg; Description = $desc }
            }
            return $msg
        }
    }
    return $emptyResult
}
