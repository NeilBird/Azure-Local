function Get-AzLocalUpdateRunStepStats {
    <#
    .SYNOPSIS
        Recursively walks the update run step hierarchy and returns leaf-step completion statistics.
    .DESCRIPTION
        Azure Local update runs expose progress as a deeply nested step tree (observed up to
        7-9 levels deep with 150+ leaf steps on real solution updates). The top-level
        progress.steps array only ever holds a couple of coarse wrapper steps - typically
        "Prepare update" (Success) and "Start update" (InProgress/Error) - so counting the
        TOP level alone reports a near-constant "1/2 steps" for the entire multi-hour run,
        regardless of how far the install has actually progressed.

        This helper traverses the full tree and tallies the LEAF steps (those with no child
        steps). Leaf steps are the atomic units of work, so completed-vs-total leaves gives a
        meaningful progress signal that climbs as the run proceeds. Parent/wrapper steps are
        deliberately excluded from the totals to avoid double-counting (a parent only reports
        Success once all of its children have).

        Status mapping (case-insensitive):
          * Success / Skipped  -> Completed (Skipped counts as done so a finished run reaches 100%)
          * Error / Failed     -> Failed
          * InProgress         -> InProgress
          * anything else / blank (NotStarted/pending) -> counted in Total only

        Companion to Get-DeepestActiveStep / Get-CurrentStepPath / Get-DeepestErrorMessage,
        which already traverse the same tree for the CurrentStep / ErrorMessage columns.
    .NOTES
        Returns a PSCustomObject with TotalLeaf / CompletedLeaf / InProgressLeaf / FailedLeaf
        (all [int], all 0 when no steps are supplied).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [array]$Steps,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 20
    )

    $stats = [PSCustomObject]@{
        TotalLeaf      = 0
        CompletedLeaf  = 0
        InProgressLeaf = 0
        FailedLeaf     = 0
    }

    if (-not $Steps -or @($Steps).Count -eq 0 -or $MaxDepth -le 0) { return $stats }

    foreach ($step in $Steps) {
        if ($null -eq $step) { continue }
        $children = if ($step.PSObject.Properties['steps']) { $step.steps } else { $null }

        if ($children -and @($children).Count -gt 0) {
            $childStats = Get-AzLocalUpdateRunStepStats -Steps $children -MaxDepth ($MaxDepth - 1)
            $stats.TotalLeaf += $childStats.TotalLeaf
            $stats.CompletedLeaf += $childStats.CompletedLeaf
            $stats.InProgressLeaf += $childStats.InProgressLeaf
            $stats.FailedLeaf += $childStats.FailedLeaf
            continue
        }

        # Leaf step.
        $stats.TotalLeaf++
        $status = if ($step.PSObject.Properties['status'] -and $step.status) { [string]$step.status } else { '' }
        switch -Regex ($status) {
            '^(Success|Skipped)$' { $stats.CompletedLeaf++; break }
            '^(Error|Failed)$' { $stats.FailedLeaf++; break }
            '^InProgress$' { $stats.InProgressLeaf++; break }
            default { <# NotStarted / pending / blank: counted in TotalLeaf only #> }
        }
    }

    return $stats
}
