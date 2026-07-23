function Get-AzLocalFleetHealthOverview {
    <#
    .SYNOPSIS
        Returns one row per Azure Local cluster summarising health state,
        update state, current version, SBE version, Azure connectivity, and
        the age (in days) of the last 24-hour health-check run, so an
        operator can see the whole fleet's readiness at a glance.

    .DESCRIPTION
        Returns an ARG-first fleet health summary, one row per cluster:
        joins the `microsoft.azurestackhci/clusters` resource (for cluster
        identity, tags, node count, Azure connectivity) with its
        `updateSummaries/default` child (for healthState, update state,
        currentVersion, healthCheckDate, packageVersions[]). Solution
        Builder Extension (SBE) version is rolled up from packageVersions
        by `mv-expand` + `maxif(packageType =~ 'SBE')` so callers get one
        SbeVersion column per cluster regardless of how many package rows
        the cluster reports.

        Where the existing `Get-AzLocalFleetHealthFailures` cmdlet
        focuses on individual failing checks, this cmdlet answers
        "how is the fleet doing overall?" - one row per cluster, sorted
        with the staleest health-check result first (HealthResultsAgeDays
        desc) so out-of-date check runs surface immediately.

        The query runs through the module's `Invoke-AzResourceGraphQuery`
        helper, which transparently pages for fleets larger than 1000
        clusters.

    .PARAMETER SubscriptionId
        Optional. Limit the query to a specific Azure subscription ID.
        Omit to query every subscription the caller can read.

    .PARAMETER UpdateRingTag
        Optional UpdateRing tag filter. Accepts the same syntax as the
        rest of the module: a single ring (e.g. 'Wave1'),
        semicolon-delimited list (e.g. 'Wave1;Wave2'), or the literal
        '***' wildcard. ValidatePattern rejects '*', '**', '****' so a
        single-character typo cannot accidentally widen the scope.

    .PARAMETER ExportPath
        Optional. Path to export the result. Format is auto-detected from
        the file extension (.csv or .json).

    .PARAMETER PassThru
        Return objects to the pipeline even when -ExportPath is specified.

    .OUTPUTS
        PSCustomObject[] with the columns (in this order):
          ClusterName, ClusterPortalUrl, HealthStatus, UpdateStatus,
          CurrentVersion, SbeVersion, AzureConnection, LastChecked,
          HealthResultsAgeDays, ResourceGroup, NodeCount, SubscriptionId.

        HealthStatus values (normalised from ARG `properties.healthState`
        to an operator-friendly vocabulary): Healthy (Success), Critical
        (Failure), Warning, In progress (InProgress), Unknown (empty or
        NotKnown). Any other raw value the platform may add in future is
        passed through unchanged so it is still visible.

    .EXAMPLE
        Get-AzLocalFleetHealthOverview

    .EXAMPLE
        Get-AzLocalFleetHealthOverview -UpdateRingTag Wave1 -ExportPath .\fleet-overview.csv

    .NOTES
        Author:  Neil Bird, Microsoft.
        Added:   v0.7.70
        Module:  AzLocal.UpdateManagement
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [string]$UpdateRingTag,

        [Parameter(Mandatory = $false)]
        [string]$ExportPath,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    if ($ExportPath) {
        try { Test-ExportPathWritable -Path $ExportPath | Out-Null }
        catch { throw "ExportPath is not writable: $($_.Exception.Message)" }
    }

    # Optional UpdateRing tag filter (KQL fragment) injected into the
    # cluster-side branch of the join so the filter is evaluated server-
    # side rather than client-side.
    $ringFilter = ''
    if ($UpdateRingTag) {
        $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingTag -TagAccessor "tostring(tags['UpdateRing'])"
    }
    $globalTagFilter = Get-AzLocalClusterTagFilterKqlClause

    # KQL: join clusters with their updateSummaries/default child, project
    # the raw packageVersions array (rolled up to SbeVersion client-side
    # below), compute HealthResultsAgeDays. Both sides of the join
    # lower-case the resource id so the ARM mixed-case vs the
    # extensibilityresources path (also mixed-case but built from split
    # segments) match deterministically.
    #
    # v0.7.74: HealthStatus normalises raw ARG `properties.healthState`
    # (Success / Failure / InProgress / Warning / NotKnown) to the documented
    # operator-friendly vocabulary the rest of the module + pipeline samples
    # consume: Healthy / Critical / Warning / In progress / Unknown. Any
    # future-added raw state passes through unchanged so it is still visible.
    #
    # v0.7.76: SBE roll-up moved client-side. The previous implementation
    # used `mv-expand pkg = properties.packageVersions | summarize ... maxif()
    # by ClusterResourceIdLower` server-side, but ARG silently caps
    # `mv-expand` at 128 expanded child rows per parent. While
    # `packageVersions` has historically been small (~4 entries), there is
    # no schema-level upper bound, so we now project the raw array and
    # find the SBE entry in PowerShell. This eliminates the entire class
    # of silent-truncation bugs for this cmdlet.
    #
    # IMPORTANT: keep this wire query lean. The az CLI argument layer truncates
    # very long single-arg payloads (observed regression in v0.7.73 at ~3.1KB
    # producing a KQL ParserFailure with token=<EOF>). Do NOT add `//` KQL
    # comments inside the here-string - document with PowerShell `#` comments
    # above the assignment instead.
    $kql = @"
resources
| where type =~ 'microsoft.azurestackhci/clusters'
$globalTagFilter
$ringFilter
| extend ClusterResourceIdLower = tolower(tostring(id))
| extend NodeCount = iif(isnull(properties.reportedProperties.nodes), 0, toint(array_length(properties.reportedProperties.nodes)))
| extend AzureConnection = tostring(properties.connectivityStatus)
| project ClusterName=name, ClusterResourceId=tostring(id), ClusterResourceIdLower, ResourceGroup=tostring(resourceGroup), SubscriptionId=tostring(subscriptionId), NodeCount, AzureConnection
| join kind=leftouter (
    extensibilityresources
    | where type =~ 'microsoft.azurestackhci/clusters/updatesummaries'
    | extend segs = split(id, '/')
    | extend ClusterResourceIdLower = tolower(strcat('/subscriptions/', segs[2], '/resourceGroups/', segs[4], '/providers/Microsoft.AzureStackHCI/clusters/', segs[8]))
    | project ClusterResourceIdLower,
              HealthState     = tostring(properties.healthState),
              UpdateState     = tostring(properties.state),
              CurrentVersion  = tostring(properties.currentVersion),
              LastChecked     = todatetime(properties.healthCheckDate),
              PackageVersions = properties.packageVersions
) on ClusterResourceIdLower
| extend HealthResultsAgeDays = iif(isnull(LastChecked), -1, datetime_diff('day', now(), LastChecked))
| extend ClusterPortalUrl = strcat('https://portal.azure.com/#@/resource', ClusterResourceId)
| project ClusterName, ClusterPortalUrl, HealthStatus = case(isempty(HealthState),'Unknown', HealthState =~ 'Success','Healthy', HealthState =~ 'Failure','Critical', HealthState =~ 'InProgress','In progress', HealthState =~ 'NotKnown','Unknown', HealthState), UpdateStatus = iif(isempty(UpdateState),'Unknown',UpdateState), CurrentVersion = iif(isempty(CurrentVersion),'(unknown)',CurrentVersion), SbeVersion = '', PackageVersions, AzureConnection = iif(isempty(AzureConnection),'Unknown',AzureConnection), LastChecked, HealthResultsAgeDays, ResourceGroup, NodeCount, SubscriptionId
| order by HealthResultsAgeDays desc, SubscriptionId asc, ClusterName asc
"@

    Write-Log -Message "Querying Azure Resource Graph for fleet health overview$(if($UpdateRingTag){", UpdateRingTag=$UpdateRingTag"})..." -Level Info

    try {
        $output = if ($SubscriptionId) {
            Invoke-AzResourceGraphQuery -Query $kql -SubscriptionId $SubscriptionId
        } else {
            Invoke-AzResourceGraphQuery -Query $kql
        }
    }
    catch {
        Write-Log -Message "Resource Graph query failed: $($_.Exception.Message)" -Level Error
        throw
    }

    if (-not $output) { $output = @() }
    $output = @($output)

    # v0.7.76: SBE roll-up moved client-side to avoid ARG `mv-expand`
    # 128-cap. The KQL projects `PackageVersions` as a raw array and
    # `SbeVersion` as an empty placeholder. We walk the array here to
    # find the entry with `packageType == 'SBE'` (case-insensitive) and
    # overwrite SbeVersion with its `version` field. Tests that mock the
    # already-projected ARG response (no PackageVersions column) are
    # left alone so backward compatibility is preserved.
    foreach ($row in $output) {
        if ($null -eq $row) { continue }
        $hasPackageVersions = ($row.PSObject -and ($row.PSObject.Properties.Match('PackageVersions').Count -gt 0))
        if (-not $hasPackageVersions) { continue }

        $pkgs = $row.PackageVersions
        $sbeVersion = '(none)'
        if ($null -ne $pkgs) {
            foreach ($pkg in @($pkgs)) {
                if ($null -eq $pkg) { continue }
                $type = $null
                try { $type = $pkg.packageType } catch { $type = $null }
                if (-not $type) {
                    try { $type = $pkg.PackageType } catch { $type = $null }
                }
                if ($type -and ([string]$type).Trim() -ieq 'SBE') {
                    $ver = $null
                    try { $ver = $pkg.version } catch { $ver = $null }
                    if (-not $ver) {
                        try { $ver = $pkg.Version } catch { $ver = $null }
                    }
                    if ($ver) {
                        $sbeVersion = [string]$ver
                        break
                    }
                }
            }
        }

        if ($row.PSObject.Properties.Match('SbeVersion').Count -gt 0) {
            $row.SbeVersion = $sbeVersion
        } else {
            $row | Add-Member -NotePropertyName 'SbeVersion' -NotePropertyValue $sbeVersion -Force
        }
    }

    # Strip the intermediate PackageVersions column so callers see the
    # documented schema only.
    $output = @($output | ForEach-Object {
        if ($null -eq $_) { return }
        if ($_.PSObject.Properties.Match('PackageVersions').Count -gt 0) {
            $_ | Select-Object -Property * -ExcludeProperty PackageVersions
        } else {
            $_
        }
    })

    Write-Log -Message "Fleet Health Overview: $($output.Count) cluster row(s)." -Level Info

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
                    Write-Log -Message "Fleet health overview exported to JSON: $ExportPath" -Level Success
                }
                default {
                    $output | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Force
                    Write-Log -Message "Fleet health overview exported to CSV: $ExportPath" -Level Success
                }
            }
        }
        catch {
            Write-Log -Message "Failed to export fleet health overview: $($_.Exception.Message)" -Level Error
        }
    }

    if (-not $ExportPath -or $PassThru) {
        return , $output
    }
}
