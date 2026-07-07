function Get-AzLocalFleetHealthFailures {
    <#
    .SYNOPSIS
        Returns the in-flight 24-hour system health-check failures for an Azure
        Local fleet, either as per-(cluster, failure) detail rows or aggregated
        by failure reason so administrators can prioritise remediation at scale.

    .DESCRIPTION
        Health-check data for every Azure Local cluster is persisted on the
        cluster's `updateSummaries/default` resource under
        `properties.healthCheckResult[]`. Each entry carries a status, severity
        (Critical | Warning | Informational), display name, description,
        remediation, and timestamp. The 24-hour system health checks continue to
        run on the cluster even when no updates are available, which means
        clusters can be "up to date" yet still surface Critical or Warning
        health issues that administrators need to triage.

        This function executes a single Azure Resource Graph query against the
        `extensibilityresources` table for every accessible cluster (paging
        transparently for fleets larger than 1000 entries) and returns the
        failing health-check entries (status == 'Failed'). Two views are
        supported:

          - 'Detail'  (default): one row per (cluster, failing health check).
                       Useful for the per-cluster drill-down view and for
                       JUnit XML emission so failures are visible per node
                       on the pipeline run. v0.7.70 added TargetResourceName,
                       TargetResourceType, and ClusterPortalUrl columns so
                       renderers can hyperlink the cluster name and surface
                       the specific node / drive / NIC the check failed
                       against without re-querying ARG.
          - 'Summary'         : grouped by FailureReason and Severity. Rows
                                are ordered v0.7.70 with Severity FIRST
                                (Critical before Warning) so the
                                highest-blast-radius reason is at the top of
                                the report regardless of fleet size, then
                                ClusterCount desc, then FailureCount desc.
                                The AffectedClusters column lists every
                                cluster hit by that failure reason (joined
                                by '; '); AffectedClusterPortalUrls is the
                                positionally-paired list of portal links.

        Critical-severity entries are emitted before Warning. Informational
        entries are excluded.

        The function reuses the module's existing `Invoke-AzResourceGraphQuery`
        helper, which means it inherits the same skip-token pagination, error
        scrubbing, and CLI shell-out behaviour as every other fleet-wide query
        in the module.

    .PARAMETER SubscriptionId
        Optional. Limit the query to a specific Azure subscription ID. If not
        specified, queries across all accessible subscriptions (default mode).

    .PARAMETER Severity
        Severity filter applied at the ARG side. Accepts 'Critical', 'Warning',
        or 'All' (default). 'All' returns both Critical and Warning rows;
        Informational health checks are always excluded.

    .PARAMETER UpdateRingTag
        Optional. When supplied, only clusters whose 'UpdateRing' tag value
        matches this string are returned. Useful for narrowing fleet-health
        reporting to a specific wave (e.g. 'Wave1', 'Production') and for
        producing focussed reports per ring.

    .PARAMETER View
        'Detail' (default) or 'Summary'. See DESCRIPTION above.

    .PARAMETER ExportPath
        Optional. Path to export the result. Format is auto-detected from the
        file extension (.csv or .json). CSV is useful for spreadsheets and the
        JUnit emitter; JSON is useful for downstream automation.

    .PARAMETER PassThru
        Return objects to the pipeline even when -ExportPath is specified.

    .EXAMPLE
        # Per-cluster detail across the entire fleet (default view)
        Get-AzLocalFleetHealthFailures

    .EXAMPLE
        # Pivot by failure reason - "what should we fix first?" - and export
        Get-AzLocalFleetHealthFailures -View Summary -ExportPath .\fleet-health-summary.csv

    .EXAMPLE
        # Critical issues only, narrowed to one ring, for a focussed report
        Get-AzLocalFleetHealthFailures -Severity Critical -UpdateRingTag 'Wave1'

    .EXAMPLE
        # CI/CD pipeline: detail for JUnit emission, summary for the markdown summary
        $detail  = Get-AzLocalFleetHealthFailures -View Detail  -ExportPath .\reports\fleet-health-detail.csv  -PassThru
        $summary = Get-AzLocalFleetHealthFailures -View Summary -ExportPath .\reports\fleet-health-summary.csv -PassThru
        # ...emit JUnit XML from $detail, write GITHUB_STEP_SUMMARY from $summary...

    .NOTES
        Author:  Neil Bird, Microsoft.
        Added:   v0.7.65
        Module:  AzLocal.UpdateManagement
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Critical', 'Warning', 'All')]
        [string]$Severity = 'All',

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [string]$UpdateRingTag,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Detail', 'Summary')]
        [string]$View = 'Detail',

        [Parameter(Mandatory = $false)]
        [string]$ExportPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    # Pre-flight: validate export path before issuing the ARG query
    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { throw "ExportPath is not writable: $($_.Exception.Message)" }
    }

    # v0.7.76: ARG query projects the *raw* `properties.healthCheckResult`
    # array per cluster - we expand it CLIENT-SIDE in PowerShell rather than
    # using KQL `mv-expand`. This avoids ARG's silent 128-element cap on
    # `mv-expand` (each parent row can emit at most 128 expanded child rows),
    # which previously dropped >50% of health-check entries for any cluster
    # whose array exceeded 128 items. Empirical measurement showed a 313-entry
    # array being truncated to 128 mv-expanded rows, hiding Failed checks.
    # The `extensibilityresources` table holds the `updateSummaries` child
    # resource for every Azure Local cluster the caller can read. Cluster
    # identity (name, RG, subscription) is parsed from the resource ID:
    # `/subscriptions/{}/resourceGroups/{}/providers/Microsoft.AzureStackHCI/clusters/{}/updateSummaries/default`
    # so the function does not need to issue a separate cluster-resource query.
    # Status / severity filtering is applied client-side after expansion.
    $kql = @"
extensibilityresources
| where type =~ 'microsoft.azurestackhci/clusters/updatesummaries'
| extend segments = split(id, '/')
| extend
    SubscriptionId    = tostring(segments[2]),
    ResourceGroup     = tostring(segments[4]),
    ClusterName       = tostring(segments[8])
| extend ClusterResourceId = strcat('/subscriptions/', SubscriptionId, '/resourceGroups/', ResourceGroup, '/providers/Microsoft.AzureStackHCI/clusters/', ClusterName)
| extend ClusterPortalUrl  = strcat('https://portal.azure.com/#@/resource', ClusterResourceId)
| project
    ClusterName,
    ResourceGroup,
    SubscriptionId,
    ClusterResourceId,
    ClusterPortalUrl,
    HealthCheckResult = properties.healthCheckResult,
    HealthCheckCount  = array_length(properties.healthCheckResult)
"@

    Write-Log -Message "Querying Azure Resource Graph for fleet health-check failures (View=$View, Severity=$Severity$(if($UpdateRingTag){", UpdateRingTag=$UpdateRingTag"})..." -Level Info

    try {
        $clusterRows = if ($SubscriptionId) {
            Invoke-AzResourceGraphQuery -Query $kql -SubscriptionId $SubscriptionId
        } else {
            Invoke-AzResourceGraphQuery -Query $kql
        }
    }
    catch {
        Write-Log -Message "Resource Graph query failed: $($_.Exception.Message)" -Level Error
        throw
    }

    if (-not $clusterRows) { $clusterRows = @() }
    Write-Log -Message "Resource Graph returned $($clusterRows.Count) cluster updateSummaries doc(s)." -Level Info

    # v0.7.76: client-side expansion of properties.healthCheckResult.
    # Iterate each cluster's array (which ARG returned in full), apply the
    # status == 'Failed' filter plus the requested severity filter, and emit
    # one detail row per matching check. Informational entries are always
    # excluded; only Critical / Warning failures are surfaced regardless of
    # the -Severity selector (mirrors the previous KQL semantics exactly).
    $allowedSeverities = switch ($Severity) {
        'Critical' { @('Critical') }
        'Warning'  { @('Warning') }
        default    { @('Critical', 'Warning') }
    }
    $expanded = New-Object System.Collections.ArrayList
    $totalChecksScanned   = 0
    $clustersWithChecks   = 0
    foreach ($cluster in @($clusterRows)) {
        $hcr = if ($cluster.PSObject.Properties['HealthCheckResult']) { $cluster.HealthCheckResult } else { $null }
        if (-not $hcr) { continue }
        $clustersWithChecks++
        foreach ($hc in @($hcr)) {
            $totalChecksScanned++
            $status = "$($hc.status)"
            if ($status -ne 'Failed') { continue }
            $sev = "$($hc.severity)"
            if ($allowedSeverities -notcontains $sev) { continue }

            $ts = $null
            if ($hc.timestamp) {
                try { $ts = [datetime]$hc.timestamp } catch { $ts = $null }
            }

            [void]$expanded.Add([PSCustomObject]@{
                ClusterName        = "$($cluster.ClusterName)"
                ResourceGroup      = "$($cluster.ResourceGroup)"
                SubscriptionId     = "$($cluster.SubscriptionId)"
                ClusterResourceId  = "$($cluster.ClusterResourceId)"
                ClusterPortalUrl   = "$($cluster.ClusterPortalUrl)"
                Severity           = $sev
                FailureName        = "$($hc.name)"
                FailureReason      = "$($hc.displayName)"
                Title              = "$($hc.title)"
                Description        = "$($hc.description)"
                Remediation        = "$($hc.remediation)"
                TargetResourceName = "$($hc.targetResourceName)"
                TargetResourceType = "$($hc.targetResourceType)"
                TargetResourceID   = "$($hc.targetResourceID)"
                LastOccurrence     = $ts
            })
        }
    }

    # Apply the same severity / cluster / reason ordering the previous KQL
    # `order by SeverityOrder asc, ClusterName asc, FailureReason asc`
    # produced, so callers see the highest-impact rows first.
    $rows = @(
        $expanded |
            Sort-Object `
                @{Expression = { if ($_.Severity -eq 'Critical') { 1 } elseif ($_.Severity -eq 'Warning') { 2 } else { 3 } }; Descending = $false},
                @{Expression = { $_.ClusterName };   Descending = $false},
                @{Expression = { $_.FailureReason }; Descending = $false}
    )

    Write-Log -Message "Expanded $totalChecksScanned health-check entries across $clustersWithChecks cluster(s); $($rows.Count) match the status='Failed' + severity='$Severity' filter." -Level Info

    # Optional UpdateRing tag filter. We do this client-side rather than
    # joining inside KQL because the updateSummaries resource does NOT carry
    # the cluster's tags - tags live on the cluster resource itself. A
    # separate ARG hop is required to map ResourceId -> UpdateRing.
    if ($UpdateRingTag) {
        # v0.7.66: support semicolon-delimited rings and the literal '***'
        # wildcard (three stars). Single '*', double '**', and quadruple '****'
        # are deliberately rejected by [ValidatePattern] so a one-character
        # typo cannot accidentally widen the scope.
        $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingTag -TagAccessor "tostring(tags['UpdateRing'])"
        $tagKql = @"
resources
| where type =~ 'microsoft.azurestackhci/clusters'
$ringFilter
| project id = tolower(id)
"@
        try {
            $tagRows = if ($SubscriptionId) {
                Invoke-AzResourceGraphQuery -Query $tagKql -SubscriptionId $SubscriptionId
            } else {
                Invoke-AzResourceGraphQuery -Query $tagKql
            }
        }
        catch {
            Write-Log -Message "UpdateRing tag filter query failed: $($_.Exception.Message)" -Level Error
            throw
        }
        $allowed = @{}
        foreach ($r in @($tagRows)) { $allowed[$r.id] = $true }
        $before = $rows.Count
        $rows   = @($rows | Where-Object { $allowed.ContainsKey(($_.ClusterResourceId).ToLower()) })
        Write-Log -Message "Filtered to UpdateRing='$UpdateRingTag': $($rows.Count) of $before rows retained." -Level Info
    }

    # Build the output the caller asked for.
    if ($View -eq 'Summary') {
        # Aggregate: one row per (FailureReason, Severity). v0.7.70 sort
        # precedence: Severity FIRST (Critical before Warning) so reviewers
        # see the highest-blast-radius row at the top regardless of cluster
        # count, then ClusterCount desc (widespread before isolated), then
        # FailureCount desc as a tie-breaker.
        $output = @($rows |
            Group-Object -Property FailureReason, Severity |
            ForEach-Object {
                $first       = $_.Group | Select-Object -First 1
                $clusterList = @($_.Group | Select-Object -ExpandProperty ClusterName -Unique | Sort-Object)
                # Pair each affected cluster with its portal URL, preserving
                # alphabetical order so the two list columns line up index
                # for index when a downstream renderer zips them into a
                # single hyperlink list.
                $clusterPortalUrls = @(
                    foreach ($cn in $clusterList) {
                        $portalRow = $_.Group | Where-Object { $_.ClusterName -eq $cn } | Select-Object -First 1
                        if ($portalRow -and $portalRow.ClusterPortalUrl) { $portalRow.ClusterPortalUrl } else { '' }
                    }
                )
                $latest      = ($_.Group | Measure-Object -Property LastOccurrence -Maximum).Maximum
                [PSCustomObject]@{
                    FailureReason            = $first.FailureReason
                    Severity                 = $first.Severity
                    ClusterCount             = $clusterList.Count
                    FailureCount             = $_.Group.Count
                    AffectedClusters         = ($clusterList -join '; ')
                    AffectedClusterPortalUrls = ($clusterPortalUrls -join '; ')
                    LatestOccurrence         = $latest
                    Description              = $first.Description
                    Remediation              = $first.Remediation
                }
            } |
            Sort-Object @{Expression={ if($_.Severity -eq 'Critical'){1}elseif($_.Severity -eq 'Warning'){2}else{3} };Descending=$false},
                       @{Expression={$_.ClusterCount};Descending=$true},
                       @{Expression={$_.FailureCount};Descending=$true}
        )
    } else {
        # Detail view: pass-through after surfacing severity ordering so that
        # JUnit and CSV consumers see Critical rows before Warning rows.
        # v0.7.70 added TargetResourceName, TargetResourceType, ClusterPortalUrl.
        # v0.8.80 added Title, TargetResourceID (the full ARM resource id
        # of the failing component; lets renderers deep-link Server/Volume
        # health failures back to the exact node or volume in the portal).
        $output = @($rows | Select-Object ClusterName, ResourceGroup, SubscriptionId, Severity, FailureReason, FailureName, Title, Description, Remediation, TargetResourceName, TargetResourceType, TargetResourceID, LastOccurrence, ClusterResourceId, ClusterPortalUrl)
    }

    # Export if requested.
    if ($ExportPath) {
        try {
            $ExportPath = Resolve-SafeOutputPath -Path $ExportPath
            $exportDir  = Split-Path -Path $ExportPath -Parent
            if ($exportDir -and -not (Test-Path -Path $exportDir)) {
                $null = New-Item -ItemType Directory -Path $exportDir -Force
            }
            $ext = [System.IO.Path]::GetExtension($ExportPath).ToLower()
            switch ($ext) {
                '.json' {
                    Write-Utf8NoBomFile -Path $ExportPath -Content ($output | ConvertTo-Json -Depth 6)
                    Write-Log -Message "Fleet health $View exported to JSON: $ExportPath" -Level Success
                }
                default {
                    $output | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Force
                    Write-Log -Message "Fleet health $View exported to CSV: $ExportPath" -Level Success
                }
            }
        }
        catch {
            Write-Log -Message "Failed to export fleet health $($View): $($_.Exception.Message)" -Level Error
        }
    }

    # Summary log to host stream.
    if ($View -eq 'Summary') {
        Write-Log -Message "" -Level Info
        Write-Log -Message "Fleet Health Failures Summary (top reasons by cluster impact):" -Level Header
        foreach ($r in ($output | Select-Object -First 10)) {
            $tag = if ($r.Severity -eq 'Critical') { 'Critical' } else { 'Warning ' }
            Write-Log -Message ("  [{0}] {1} - {2} cluster(s), {3} failure(s)" -f $tag, $r.FailureReason, $r.ClusterCount, $r.FailureCount) -Level $(if ($r.Severity -eq 'Critical') { 'Error' } else { 'Warning' })
        }
        if ($output.Count -gt 10) {
            Write-Log -Message "  (... and $($output.Count - 10) more failure reason(s); see ExportPath for the full list)" -Level Info
        }
    } else {
        $clusterCount = @($output | Select-Object -ExpandProperty ClusterName -Unique).Count
        Write-Log -Message ("Fleet Health Detail: {0} failing check(s) across {1} cluster(s)." -f $output.Count, $clusterCount) -Level Info
    }

    # Honour PassThru semantics: emit objects unless ExportPath was used and
    # the caller did not ask for them.
    if (-not $ExportPath -or $PassThru) {
        return , $output
    }
}
