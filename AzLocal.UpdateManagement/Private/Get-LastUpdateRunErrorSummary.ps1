function Get-LastUpdateRunErrorSummary {
    <#
    .SYNOPSIS
        Gets the error details from the most recent failed update run for a cluster.
    .DESCRIPTION
        Queries the Azure REST API for the most recent update run for a cluster
        and extracts the error step name and message if the update failed.
        
        Note: Update runs are nested under specific updates, so we need to:
        1. List all updates for the cluster
        2. Get update runs for each update
        3. Find the most recent failed run across all updates
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = "2025-10-01"
    )

    try {
        # First, get all updates for this cluster
        $updatesUri = "https://management.azure.com$ClusterResourceId/updates?api-version=$ApiVersion"
        $updatesResult = (Invoke-AzRestJson -Uri $updatesUri).Data
        
        if ($LASTEXITCODE -ne 0 -or -not $updatesResult.value) {
            return @{ ErrorStep = ""; ErrorMessage = "" }
        }

        # Collect all failed runs from all updates
        $allFailedRuns = @()
        
        foreach ($update in $updatesResult.value) {
            if ($null -eq $update) { continue }
            $updateName = $update.name
            $runsUri = "https://management.azure.com$ClusterResourceId/updates/$updateName/updateRuns?api-version=$ApiVersion"
            $runsResult = (Invoke-AzRestJson -Uri $runsUri).Data
            
            if ($LASTEXITCODE -eq 0 -and $runsResult.value) {
                $failedRuns = $runsResult.value | Where-Object { $null -ne $_ -and $_.properties.state -eq "Failed" }
                if ($failedRuns) {
                    $allFailedRuns += $failedRuns
                }
            }
        }

        if ($allFailedRuns.Count -eq 0) {
            return @{ ErrorStep = ""; ErrorMessage = "" }
        }

        # Find the most recent failed update run across all updates
        # Sort by lastUpdatedTime first (when the run actually failed), fall back to timeStarted
        $latestFailed = $allFailedRuns | Sort-Object { 
            # Prefer lastUpdatedTime as it reflects when the failure actually occurred
            if ($_.properties.lastUpdatedTime) { 
                [datetime]$_.properties.lastUpdatedTime 
            } 
            elseif ($_.properties.timeStarted) { 
                [datetime]$_.properties.timeStarted 
            }
            else { 
                [datetime]::MinValue 
            }
        } -Descending | Select-Object -First 1
        $progress = if ($latestFailed.properties.PSObject.Properties['progress']) { $latestFailed.properties.progress } else { $null }

        # v0.9.17: guard `steps` under Set-StrictMode -Version Latest. A failed run's
        # `progress` object can exist but omit `steps`, and a bare `$progress.steps`
        # read THROWS "The property 'steps' cannot be found on this object".
        if (-not $progress -or -not ($progress.PSObject.Properties['steps'] -and $progress.steps)) {
            return @{ ErrorStep = ""; ErrorMessage = "" }
        }

        # Recursively search for the deepest error step with an error message
        function Find-DeepestError {
            param($steps)
            foreach ($step in $steps) {
                if ($null -eq $step) { continue }
                # v0.9.18: guard status/steps/errorMessage/name under Set-StrictMode -Version
                # Latest - a leaf step in a failed run can omit these and a bare read THROWS.
                $stepStatus = if ($step.PSObject.Properties['status']) { $step.status } else { $null }
                if ($stepStatus -eq "Error" -or $stepStatus -eq "Failed") {
                    $stepErr = if ($step.PSObject.Properties['errorMessage']) { $step.errorMessage } else { $null }
                    if ($stepErr) {
                        $stepName = if ($step.PSObject.Properties['name']) { $step.name } else { '' }
                        return @{ Name = $stepName; Message = $stepErr }
                    }
                }
                $childSteps = if ($step.PSObject.Properties['steps']) { $step.steps } else { $null }
                if ($childSteps) {
                    $nestedResult = Find-DeepestError -steps $childSteps
                    if ($nestedResult.Message) {
                        return $nestedResult
                    }
                }
            }
            return @{ Name = ""; Message = "" }
        }

        $deepestError = Find-DeepestError -steps $progress.steps
        $errorStep = $deepestError.Name
        $errorMessage = $deepestError.Message

        # Clean up error message for CSV (remove newlines and extra spaces)
        if ($errorMessage) {
            $errorMessage = $errorMessage -replace '\r?\n', ' ' -replace '\s+', ' '
            # Truncate if too long for CSV readability
            if ($errorMessage.Length -gt 500) {
                $errorMessage = $errorMessage.Substring(0, 500) + "..."
            }
        }

        return @{ ErrorStep = $errorStep; ErrorMessage = $errorMessage }
    }
    catch {
        Write-Verbose "Error getting update run details: $_"
        return @{ ErrorStep = ""; ErrorMessage = "" }
    }
}
