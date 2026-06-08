function Get-DeepestErrorMessage {
    <#
    .SYNOPSIS
        Recursively walks the update run step hierarchy and returns the deepest non-empty errorMessage from any Error/Failed step.
    .DESCRIPTION
        The ARM payload nests errorMessage on whichever leaf actually threw. Older parents in the
        chain may carry a duplicate or summarised message, or no message at all. This helper
        mirrors the LENS-Workbook coalesce(e8Msg..e1Msg) pattern: walk the tree, prefer the
        deepest non-empty errorMessage on an Error/Failed-status step. Used by
        Format-AzLocalUpdateRun in v0.7.96 to surface a dedicated ErrorMessage column so
        operators can triage failed runs without clicking through to the Azure portal.
    .NOTES
        Returns an empty string when no error message is found (callers can if-guard cheaply).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [array]$Steps,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 20
    )

    if (-not $Steps -or $Steps.Count -eq 0 -or $MaxDepth -le 0) { return '' }

    foreach ($step in $Steps) {
        if ($step.status -notin @('Error', 'Failed')) { continue }

        if ($step.steps -and $step.steps.Count -gt 0) {
            $deeper = Get-DeepestErrorMessage -Steps $step.steps -MaxDepth ($MaxDepth - 1)
            if ($deeper) { return $deeper }
        }
        if ($step.PSObject.Properties['errorMessage'] -and $step.errorMessage) {
            return [string]$step.errorMessage
        }
    }
    return ''
}
