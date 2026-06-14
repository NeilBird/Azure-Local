function Get-HealthCheckFailureSummary {
    <#
    .SYNOPSIS
        Extracts health check failure reasons from an update summary object.
    .DESCRIPTION
        Analyzes the healthCheckResult property from an Azure Local update summary
        to extract critical and warning health check failures. Returns a summary
        string suitable for CSV logging.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object]$UpdateSummary
    )

    # v0.8.77: guard property reads - bare `$UpdateSummary.properties.healthCheckResult`
    # THROWS under Set-StrictMode -Version Latest when the property is absent.
    $summaryProps = if ($UpdateSummary) { $UpdateSummary.PSObject.Properties['properties'] } else { $null }
    $hasHCR = $summaryProps -and $UpdateSummary.properties.PSObject.Properties['healthCheckResult'] -and $UpdateSummary.properties.healthCheckResult
    if (-not $hasHCR) {
        return ""
    }

    # Bucket failures by severity so Critical entries are always emitted first.
    # The readiness gate in Get-AzLocalClusterUpdateReadiness runs
    # -match '\[Critical\]' on the truncated summary; without this ordering,
    # a Critical failure could be hidden behind 5+ Warning failures returned
    # earlier by ARM and the gate would silently miss it.
    $criticals = @()
    $warnings  = @()
    $healthChecks = $UpdateSummary.properties.healthCheckResult

    # Dedup byte-identical duplicates emitted by ARM upstream (v0.7.76 fix
    # for the same bug as Test-AzLocalClusterHealth: the
    # updateSummaries.healthCheckResult feed sometimes contains repeated
    # entries for the same logical check, producing readiness summary
    # lines like "[Critical] Foo (Bar); [Critical] Foo (Bar)").
    $seenEntries = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($check in $healthChecks) {
        if ($check.status -eq "Failed") {
            $severity = if ($check.severity) { $check.severity } else { "Unknown" }
            # Only include Critical and Warning severities (skip Informational)
            if ($severity -notin @("Critical", "Warning")) {
                continue
            }
            $displayName = if ($check.displayName) { $check.displayName } elseif ($check.name) { ($check.name -split '/')[0] } else { "Unknown Check" }
            $targetNode = if ($check.targetResourceName) { " ($($check.targetResourceName))" } else { "" }
            $entry = "[$severity] $displayName$targetNode"
            if (-not $seenEntries.Add($entry)) {
                # Already seen this exact entry; skip silently. Verbose
                # diagnostics live in Test-AzLocalClusterHealth where the
                # dedup is the primary code path.
                continue
            }
            if ($severity -eq "Critical") {
                $criticals += $entry
            }
            else {
                $warnings += $entry
            }
        }
    }

    # Critical-first, then Warning (insertion order preserved within each bucket).
    $failures = @($criticals) + @($warnings)

    if ($failures.Count -gt 0) {
        # Limit to top 5 failures to keep CSV readable
        $topFailures = $failures | Select-Object -First 5
        $summary = $topFailures -join "; "
        if ($failures.Count -gt 5) {
            $summary += " (+$($failures.Count - 5) more)"
        }
        return $summary
    }

    return ""
}
