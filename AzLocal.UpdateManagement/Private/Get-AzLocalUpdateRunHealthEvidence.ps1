function Get-AzLocalUpdateRunHealthEvidence {
    <#
    .SYNOPSIS
        Returns same-cluster Critical healthCheckResult entries that occurred
        within a +/-2h window of a failed update run, used to enrich
        HealthCheck-category failures with the actual blocking checks.

    .DESCRIPTION
        When Get-AzLocalUpdateRunFailures categorises a failed run as
        ErrorCategory='HealthCheck' the operator typically wants to know
        WHICH health check fired. That information is NOT on the update run
        itself - it lives on the cluster's `updateSummaries/default` child
        resource as `properties.healthCheckResult[]`. This helper queries
        Azure Resource Graph for that array (using the same anti-mv-expand
        pattern as Get-AzLocalFleetHealthFailures) and filters down to:

          * the supplied ClusterResourceId
          * status == 'Failed'
          * severity == 'Critical' (Warning/Informational are excluded by
            default to keep the evidence list short and triage-focused)
          * timestamp within [RunStartTime - WindowBefore,
                              RunEndTime   + WindowAfter]

        Each returned row is a minimal projection (Title, FailureReason,
        TargetResourceName, TargetResourceID, Timestamp, Remediation) so
        the Step.09 renderer can fold it into a collapsible <details>
        block without pulling in heavy fields.

    .PARAMETER ClusterResourceId
        Full ARM resource id of the cluster the failed run belongs to.

    .PARAMETER RunStartTime
        The run's StartedAt (UTC DateTime). Pre-window evidence is
        captured back to RunStartTime - WindowBefore.

    .PARAMETER RunEndTime
        The run's EndedAt (UTC DateTime). If the run is still in progress
        pass [datetime]::UtcNow.

    .PARAMETER WindowBefore
        TimeSpan to look back before RunStartTime. Default 2 hours -
        covers the readiness check that immediately preceded the run.

    .PARAMETER WindowAfter
        TimeSpan to look forward past RunEndTime. Default 1 hour -
        catches the post-failure health refresh that the orchestrator
        triggers on a failed run.

    .PARAMETER MinSeverity
        'Critical' (default) or 'Warning' to include Warning-severity
        entries as well. Informational is never returned.

    .PARAMETER SubscriptionId
        Optional subscription scope for the ARG query. Defaults to all
        subscriptions the caller can read.

    .OUTPUTS
        PSCustomObject[] - one row per matching healthCheckResult entry,
        sorted Timestamp descending (most recent first). Returns an
        empty array if the cluster doc cannot be found or no rows
        match the window/severity filter.

    .NOTES
        Author:  Neil Bird, Microsoft.
        Added:   v0.8.80 (HealthCheck failure enrichment)
        Module:  AzLocal.UpdateManagement (private helper)
        Caller:  Get-AzLocalUpdateRunFailures -EnrichWithHealthEvidence

        Reuses the same ARG query shape as Get-AzLocalFleetHealthFailures
        to dodge the documented mv-expand 128-row cap. Differences:
        scoped to a single cluster id, scoped to a time window, returns
        a slim projection.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IEnumerable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$ClusterResourceId,

        [Parameter(Mandatory = $true)]
        [datetime]$RunStartTime,

        [Parameter(Mandatory = $true)]
        [datetime]$RunEndTime,

        [Parameter(Mandatory = $false)]
        [timespan]$WindowBefore = ([timespan]::FromHours(2)),

        [Parameter(Mandatory = $false)]
        [timespan]$WindowAfter  = ([timespan]::FromHours(1)),

        [Parameter(Mandatory = $false)]
        [ValidateSet('Critical','Warning')]
        [string]$MinSeverity = 'Critical',

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId
    )

    $clusterIds = @($ClusterResourceId | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ } | Select-Object -Unique)
    $clusterIdSet = @{}
    foreach ($clusterId in $clusterIds) { $clusterIdSet[$clusterId] = $true }
    $windowFrom = $RunStartTime.ToUniversalTime() - $WindowBefore
    $windowTo   = $RunEndTime.ToUniversalTime()   + $WindowAfter

    # KQL: project the raw healthCheckResult array per cluster, scoped to
    # the supplied cluster id. We use `parent` id derived from segments
    # rather than a `tolower(id) startswith` so the query stays selective.
    $kql = @"
extensibilityresources
| where type =~ 'microsoft.azurestackhci/clusters/updatesummaries'
| extend segments = split(id, '/')
| extend
    SubscriptionId = tostring(segments[2]),
    ResourceGroup  = tostring(segments[4]),
    ClusterName    = tostring(segments[8])
| extend ClusterResourceId = tolower(strcat('/subscriptions/', SubscriptionId, '/resourceGroups/', ResourceGroup, '/providers/Microsoft.AzureStackHCI/clusters/', ClusterName))
| project
    ClusterResourceId,
    HealthCheckResult = properties.healthCheckResult
"@

    Write-Verbose "Get-AzLocalUpdateRunHealthEvidence: one scoped ARG query for $($clusterIds.Count) cluster(s), window [$windowFrom .. $windowTo], severity>=$MinSeverity"

    try {
        $rows = if ($SubscriptionId) {
            Invoke-AzResourceGraphQuery -Query $kql -SubscriptionId $SubscriptionId
        } else {
            Invoke-AzResourceGraphQuery -Query $kql
        }
    }
    catch {
        Write-Verbose "Get-AzLocalUpdateRunHealthEvidence ARG query failed: $($_.Exception.Message)"
        return @()
    }

    if (-not $rows -or $rows.Count -eq 0) { return @() }

    $allowedSeverities = if ($MinSeverity -eq 'Warning') { @('Critical','Warning') } else { @('Critical') }

    $evidence = New-Object System.Collections.ArrayList
    foreach ($cluster in @($rows)) {
        $currentClusterId = if ($cluster.PSObject.Properties['ClusterResourceId']) { ([string]$cluster.ClusterResourceId).ToLower() } else { '' }
        if (-not $clusterIdSet.ContainsKey($currentClusterId)) { continue }
        $hcr = if ($cluster.PSObject.Properties['HealthCheckResult']) { $cluster.HealthCheckResult } else { $null }
        if (-not $hcr) { continue }
        foreach ($hc in @($hcr)) {
            $status = "$($hc.status)"
            if ($status -ne 'Failed') { continue }
            $sev = "$($hc.severity)"
            if ($allowedSeverities -notcontains $sev) { continue }

            $ts = $null
            if ($hc.timestamp) {
                try { $ts = ([datetime]$hc.timestamp).ToUniversalTime() } catch { $ts = $null }
            }
            if (-not $ts) { continue }
            if ($ts -lt $windowFrom -or $ts -gt $windowTo) { continue }

            [void]$evidence.Add([PSCustomObject]@{
                ClusterResourceId   = $currentClusterId
                Timestamp          = $ts
                Severity           = $sev
                Title              = "$($hc.title)"
                FailureReason      = "$($hc.displayName)"
                Description        = "$($hc.description)"
                Remediation        = "$($hc.remediation)"
                TargetResourceName = "$($hc.targetResourceName)"
                TargetResourceType = "$($hc.targetResourceType)"
                TargetResourceID   = "$($hc.targetResourceID)"
            })
        }
    }

    if ($evidence.Count -eq 0) { return @() }

    # Most recent first - operators want to see the latest evidence at the
    # top of the collapsed <details> block.
    return @($evidence | Sort-Object -Property Timestamp -Descending)
}
