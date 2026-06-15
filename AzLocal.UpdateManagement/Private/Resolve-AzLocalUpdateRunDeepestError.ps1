function Resolve-AzLocalUpdateRunDeepestError {
    <#
    .SYNOPSIS
        Walks an Azure Local update-run `progress.steps` tree to find the
        deepest non-empty errorMessage and returns its depth, message,
        step name, and the top-level fallback description.

    .DESCRIPTION
        Replaces the v0.7.75 server-side KQL `mv-expand s1 .. s7` chain
        used by Get-AzLocalUpdateRunFailures. Each level of
        Azure Resource Graph's `mv-expand` operator silently caps at
        exactly 128 expanded child rows per parent (the same cap that
        caused the v0.7.76 P0 bug in Get-AzLocalFleetHealthFailures), so
        any update-run step that had more than 128 sibling steps at any
        level was at risk of having its deepest error silently dropped.

        This walker performs the same "find the deepest meaningful
        errorMessage" computation entirely in PowerShell on the raw
        `properties.progress.steps` array as returned by ARG, with no
        truncation. The output schema is intentionally identical to the
        columns the previous KQL projection emitted (Depth, Msg, Name,
        FirstDescription).

    .PARAMETER Steps
        The `steps` array (or an object with a `.steps` array) at the
        current tree level. Pass `progress.steps` from the ARG response
        on the first call. The walker recurses into `step.steps`
        automatically for as many levels as the data contains. `$null`
        and empty arrays are tolerated (return Depth=0).

    .PARAMETER Depth
        Internal recursion accumulator. The caller normally omits this
        and the walker starts at depth 1, matching the depth numbers the
        legacy KQL produced (DeepestStepDepth 1..8 or 0 if no error).

    .PARAMETER MaxDepth
        Defensive recursion ceiling. The previous KQL stopped at depth
        8 (s1..s7 + s7.steps[0]); we default to 16 here so unusually
        deep error chains still surface. Bumped above 8 to remove the
        previous artificial ceiling now that we are no longer paying
        the ARG join cost.

    .OUTPUTS
        Hashtable with keys:
          Depth            [int]    - 0 if no meaningful errorMessage
                                       was found, otherwise the depth
                                       (1-based) of the deepest match
          Msg              [string] - the deepest errorMessage text
          Name             [string] - that step's `name`
          Description      [string] - that step's `description` captured
                                       at the SAME recursion site as Msg
                                       (added v0.8.80 - the deepest step
                                       often has BOTH a human-readable
                                       description and an errorMessage
                                       trace; renderers should display
                                       both, not pick one)
          FirstDescription [string] - the very first non-empty
                                       top-level `description`, used as
                                       a fallback when no errorMessage
                                       was found anywhere in the tree

    .NOTES
        Author: Neil Bird, Microsoft.
        Added:  v0.7.76 (P0 ARG mv-expand 128-cap fix)
        Updated:v0.8.80 (added Description field at deepest site)
        Module: AzLocal.UpdateManagement (private helper)

        Consumed by Get-AzLocalUpdateRunFailures (Step.07 verification
        + Step.09 fleet-update-status renderer).

        Parallel walker: Get-DeepestErrorMessage (Private/) walks the
        same tree shape but is used by Format-AzLocalUpdateRun for the
        Get-AzLocalUpdateRuns -PassThru shape (Step.08 monitor). If
        you change the deepest-step contract here, also update
        Get-DeepestErrorMessage so the two pipelines stay in sync.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowNull()]
        $Steps,

        [Parameter(Mandatory = $false)]
        [int]$Depth = 1,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 16
    )

    $result = @{
        Depth            = 0
        Msg              = ''
        Name             = ''
        Description      = ''
        FirstDescription = ''
    }

    if ($null -eq $Steps)        { return $result }
    if ($Depth -gt $MaxDepth)    { return $result }

    # Normalise to an enumerable. ARG returns JsonArrays which behave like
    # PowerShell arrays once converted, but defensively wrap single-object
    # returns and avoid string enumeration.
    $enumerable = @()
    if ($Steps -is [System.Collections.IEnumerable] -and -not ($Steps -is [string])) {
        $enumerable = @($Steps)
    } else {
        $enumerable = @($Steps)
    }
    if ($enumerable.Count -eq 0) { return $result }

    foreach ($step in $enumerable) {
        if ($null -eq $step) { continue }

        # First non-empty top-level description wins as fallback. We
        # only capture this at depth 1 so deep recursion does not
        # overwrite it.
        if ($Depth -eq 1 -and -not $result.FirstDescription) {
            $desc = $null
            try { $desc = $step.description } catch { $desc = $null }
            if ($desc) { $result.FirstDescription = [string]$desc }
        }

        # Capture this step's errorMessage if meaningful (>10 chars,
        # matching the legacy KQL `strlen(eNMsg) > 10` threshold).
        $msg = $null
        try { $msg = $step.errorMessage } catch { $msg = $null }
        if ($null -ne $msg) {
            $msgStr = [string]$msg
            if ($msgStr.Length -gt 10 -and $Depth -ge $result.Depth) {
                # `-ge` (not `-gt`) so a tie at the same depth still
                # updates, mirroring the legacy `arg_max(mvDepth, *)`
                # last-wins semantics.
                $result.Depth = $Depth
                $result.Msg   = $msgStr
                $stepName = $null
                try { $stepName = $step.name } catch { $stepName = $null }
                $result.Name = if ($stepName) { [string]$stepName } else { '' }
                # v0.8.80: capture description at the SAME site as Msg so
                # renderers can show both. Previously only FirstDescription
                # was captured (top-level only), which silently dropped the
                # deepest step's human-readable line when an errorMessage
                # was also present (always true for HealthCheck failures).
                $stepDesc = $null
                try { $stepDesc = $step.description } catch { $stepDesc = $null }
                $result.Description = if ($stepDesc) { [string]$stepDesc } else { '' }
            }
        }

        # Recurse into nested steps. Tolerate the property being absent
        # or null.
        $childSteps = $null
        try { $childSteps = $step.steps } catch { $childSteps = $null }
        if ($null -ne $childSteps) {
            $child = Resolve-AzLocalUpdateRunDeepestError -Steps $childSteps -Depth ($Depth + 1) -MaxDepth $MaxDepth
            if ($child.Depth -gt $result.Depth) {
                $result.Depth       = $child.Depth
                $result.Msg         = $child.Msg
                $result.Name        = $child.Name
                $result.Description = $child.Description
            }
            if ($Depth -eq 1 -and -not $result.FirstDescription -and $child.FirstDescription) {
                $result.FirstDescription = $child.FirstDescription
            }
        }
    }

    return $result
}
