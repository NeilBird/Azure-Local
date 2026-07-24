function Get-CurrentStepPath {
    <#
    .SYNOPSIS
        Recursively walks the update run step hierarchy to find the deepest InProgress or Failed step.
    .DESCRIPTION
        Update runs can have steps nested up to 8-9 levels deep. This function traverses
        the step.steps children recursively and returns the full path (e.g., "Step1 > Step2 > Step3").
        Looks for InProgress or Error/Failed status, returning the deepest match.
        Also captures the errorMessage from the deepest failed step if available.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [array]$Steps,

        [Parameter(Mandatory = $false)]
        [string]$ParentPath = "",

        [Parameter(Mandatory = $false)]
        [switch]$IncludeErrorMessage,

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 20
    )

    if (-not $Steps -or $Steps.Count -eq 0 -or $MaxDepth -le 0) { return "" }

    foreach ($step in $Steps) {
        if ($null -eq $step) { continue }
        # v0.9.18: guard name/status/steps/errorMessage under Set-StrictMode -Version Latest.
        # A leaf step in a failed run can omit these; a bare read THROWS "The property
        # 'steps' cannot be found on this object" (observed live: Tacoma failed run bae9704e).
        $stepName = if ($step.PSObject.Properties['name']) { $step.name } else { $null }
        if (-not $stepName) { continue }
        $currentPath = if ($ParentPath) { "$ParentPath > $stepName" } else { $stepName }

        $stepStatus = if ($step.PSObject.Properties['status']) { $step.status } else { $null }
        if ($stepStatus -in @("InProgress", "Error", "Failed")) {
            # Check if there are deeper nested steps with the same status
            $childSteps = if ($step.PSObject.Properties['steps']) { $step.steps } else { $null }
            if ($childSteps -and @($childSteps).Count -gt 0) {
                $deeper = Get-CurrentStepPath -Steps $childSteps -ParentPath $currentPath -IncludeErrorMessage:$IncludeErrorMessage -MaxDepth ($MaxDepth - 1)
                if ($deeper) { return $deeper }
            }
            # At the deepest level - append error message if requested and available
            $stepErr = if ($step.PSObject.Properties['errorMessage']) { $step.errorMessage } else { $null }
            if ($IncludeErrorMessage -and $stepErr) {
                return "$currentPath : $stepErr"
            }
            return $currentPath
        }
    }
    return ""
}
