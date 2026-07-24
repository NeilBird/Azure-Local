function Get-DeepestActiveStep {
    <#
    .SYNOPSIS
        Recursively walks the update run step hierarchy to find the deepest InProgress or Failed step object.
    .DESCRIPTION
        Companion to Get-CurrentStepPath. Returns the leaf step object itself (not just its name path)
        so callers can pull fields like startTimeUtc, endTimeUtc, errorMessage off the deepest
        actively-executing or most-recently-failed step. Used by Format-AzLocalUpdateRun in v0.7.96
        to surface per-step elapsed (so a 16-node cluster's legitimate 8h overall run does not flag
        as stuck when its current Start/Stop/Apply step has actually been ticking along normally).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $false)]
        [array]$Steps,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 20
    )

    if (-not $Steps -or $Steps.Count -eq 0 -or $MaxDepth -le 0) { return $null }

    foreach ($step in $Steps) {
        if ($null -eq $step) { continue }
        # v0.9.18: guard status/steps under Set-StrictMode -Version Latest. A leaf step in
        # a failed run can omit the `steps` (and even `status`) property; a bare read THROWS
        # "The property 'steps' cannot be found on this object" (observed live: Tacoma failed
        # run bae9704e - four top-level LEAF steps with no `steps` child).
        $stepStatus = if ($step.PSObject.Properties['status']) { $step.status } else { $null }
        if ($stepStatus -in @("InProgress", "Error", "Failed")) {
            $childSteps = if ($step.PSObject.Properties['steps']) { $step.steps } else { $null }
            if ($childSteps -and @($childSteps).Count -gt 0) {
                $deeper = Get-DeepestActiveStep -Steps $childSteps -MaxDepth ($MaxDepth - 1)
                if ($deeper) { return $deeper }
            }
            return $step
        }
    }
    return $null
}
