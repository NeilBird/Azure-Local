function Export-AzLocalClusterInventoryDriftReport {
    <#
    .SYNOPSIS
        Compares live Azure Local cluster inventory with the source-controlled configuration CSV.
    .DESCRIPTION
        Produces read-only CSV, JSON, JUnit, and markdown reports that identify
        clusters missing from either side and operator-managed tag values that
        differ from config/ClusterUpdateRings.csv. A missing source CSV is
        reported as an onboarding state and does not fail the command.
    .PARAMETER LiveInventory
        Live rows returned by Invoke-AzLocalClusterInventory.
    .PARAMETER SourceCsvPath
        Path to the source-controlled desired-state CSV.
    .PARAMETER OutputDirectory
        Directory for drift report artifacts.
    .PARAMETER PassThru
        Returns the drift report summary object.
    .OUTPUTS
        Nothing by default. PSCustomObject when PassThru is specified.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$LiveInventory,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceCsvPath = './config/ClusterUpdateRings.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvFileName = 'cluster-inventory-drift.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$JsonFileName = 'cluster-inventory-drift.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlFileName = 'cluster-inventory-drift.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'cluster-inventory-drift-summary.md',

        [Parameter(Mandatory = $false)]
        [datetime]$Timestamp = (Get-Date),

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $pipelineHost = Get-AzLocalPipelineHost
    if (-not $OutputDirectory) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $OutputDirectory = $env:BUILD_ARTIFACTSTAGINGDIRECTORY
        }
        else {
            $OutputDirectory = './artifacts'
        }
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force -WhatIf:$false | Out-Null
    }

    $csvPath = Join-Path -Path $OutputDirectory -ChildPath $CsvFileName
    $jsonPath = Join-Path -Path $OutputDirectory -ChildPath $JsonFileName
    $xmlPath = Join-Path -Path $OutputDirectory -ChildPath $XmlFileName
    $managedFields = @('UpdateRing', 'UpdateStartWindow', 'UpdateExclusionsWindow', 'UpdateExcluded', 'UpdateAuthAccountId')
    $driftRows = New-Object System.Collections.ArrayList
    $sourceRows = @()
    $status = 'NotConfigured'

    if (Test-Path -LiteralPath $SourceCsvPath -PathType Leaf) {
        $sourceRows = @(Import-Csv -LiteralPath $SourceCsvPath -ErrorAction Stop)
        $sourceColumns = if ($sourceRows.Count -gt 0) {
            @($sourceRows[0].PSObject.Properties.Name)
        }
        else {
            $headerLine = Get-Content -LiteralPath $SourceCsvPath -TotalCount 1
            @($headerLine -split ',' | ForEach-Object { $_.Trim().Trim('"') })
        }
        foreach ($requiredColumn in @('ResourceId', 'ClusterName', 'UpdateRing')) {
            if ($requiredColumn -notin $sourceColumns) {
                throw "Source inventory CSV '$SourceCsvPath' is missing required column '$requiredColumn'."
            }
        }

        $sourceById = @{}
        foreach ($sourceRow in $sourceRows) {
            $resourceId = ([string]$sourceRow.ResourceId).Trim()
            if (-not $resourceId) {
                throw "Source inventory CSV '$SourceCsvPath' contains a row with an empty ResourceId."
            }
            $key = $resourceId.ToLowerInvariant()
            if ($sourceById.ContainsKey($key)) {
                throw "Source inventory CSV '$SourceCsvPath' contains duplicate ResourceId '$resourceId'."
            }
            $sourceById[$key] = $sourceRow
        }

        $liveById = @{}
        foreach ($liveRow in @($LiveInventory)) {
            if (-not $liveRow.PSObject.Properties['ResourceId'] -or -not $liveRow.ResourceId) {
                throw 'Live inventory contains a row with an empty ResourceId.'
            }
            $resourceId = ([string]$liveRow.ResourceId).Trim()
            $key = $resourceId.ToLowerInvariant()
            if ($liveById.ContainsKey($key)) {
                throw "Live inventory contains duplicate ResourceId '$resourceId'."
            }
            $liveById[$key] = $liveRow
        }

        foreach ($key in @($liveById.Keys | Sort-Object)) {
            $liveRow = $liveById[$key]
            if (-not $sourceById.ContainsKey($key)) {
                [void]$driftRows.Add([pscustomobject][ordered]@{
                    Status       = 'LiveOnly'
                    ClusterName  = [string]$liveRow.ClusterName
                    ResourceId   = [string]$liveRow.ResourceId
                    Field        = ''
                    SourceValue  = ''
                    LiveValue    = ''
                    Detail       = 'Cluster exists in Azure but is missing from the source-controlled CSV.'
                })
                continue
            }

            $sourceRow = $sourceById[$key]
            foreach ($field in $managedFields) {
                if ($field -notin $sourceColumns) { continue }
                $sourceValue = if ($sourceRow.PSObject.Properties[$field]) { ([string]$sourceRow.$field).Trim() } else { '' }
                $liveValue = if ($liveRow.PSObject.Properties[$field]) { ([string]$liveRow.$field).Trim() } else { '' }
                if (-not [string]::Equals($sourceValue, $liveValue, [StringComparison]::Ordinal)) {
                    [void]$driftRows.Add([pscustomobject][ordered]@{
                        Status       = 'TagMismatch'
                        ClusterName  = [string]$liveRow.ClusterName
                        ResourceId   = [string]$liveRow.ResourceId
                        Field        = $field
                        SourceValue  = $sourceValue
                        LiveValue    = $liveValue
                        Detail       = "Source value '$sourceValue' differs from live value '$liveValue'."
                    })
                }
            }
        }

        foreach ($key in @($sourceById.Keys | Sort-Object)) {
            if ($liveById.ContainsKey($key)) { continue }
            $sourceRow = $sourceById[$key]
            [void]$driftRows.Add([pscustomobject][ordered]@{
                Status       = 'SourceOnly'
                ClusterName  = [string]$sourceRow.ClusterName
                ResourceId   = [string]$sourceRow.ResourceId
                Field        = ''
                SourceValue  = ''
                LiveValue    = ''
                Detail       = 'Cluster exists in the source-controlled CSV but is not visible in the live inventory.'
            })
        }
        $status = if ($driftRows.Count -gt 0) { 'Drift' } else { 'Clean' }
    }

    $rows = @($driftRows.ToArray() | Sort-Object Status, ClusterName, Field)
    $liveOnlyRows = @($rows | Where-Object { $_.Status -eq 'LiveOnly' })
    $sourceOnlyRows = @($rows | Where-Object { $_.Status -eq 'SourceOnly' })
    $tagMismatchRows = @($rows | Where-Object { $_.Status -eq 'TagMismatch' })
    $tagMismatchClusters = @($tagMismatchRows | Select-Object -ExpandProperty ResourceId -Unique)
    $matchingCount = if ($status -eq 'NotConfigured') { 0 } else {
        @($LiveInventory).Count - $liveOnlyRows.Count - $tagMismatchClusters.Count
    }

    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8 -WhatIf:$false
    }
    else {
        Set-Content -LiteralPath $csvPath -Value 'Status,ClusterName,ResourceId,Field,SourceValue,LiveValue,Detail' -Encoding UTF8 -WhatIf:$false
    }

    $report = [pscustomobject][ordered]@{
        Status                  = $status
        SourceCsvPath           = $SourceCsvPath
        LiveClusterCount        = [int]@($LiveInventory).Count
        SourceClusterCount      = [int]$sourceRows.Count
        MatchingClusterCount    = [int]$matchingCount
        LiveOnlyCount           = [int]$liveOnlyRows.Count
        SourceOnlyCount         = [int]$sourceOnlyRows.Count
        TagMismatchClusterCount = [int]$tagMismatchClusters.Count
        FieldDiscrepancyCount   = [int]$tagMismatchRows.Count
        DriftCount              = [int]$rows.Count
        CsvPath                 = $csvPath
        JsonPath                = $jsonPath
        XmlPath                 = $xmlPath
        Rows                    = $rows
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8 -WhatIf:$false

    $membershipCases = @()
    $tagCases = @()
    if ($status -eq 'NotConfigured') {
        $membershipCases = @(@{
            Name = 'Source-controlled cluster inventory is configured'
            Skipped = "Source CSV not found at '$SourceCsvPath'."
        })
        $tagCases = @(@{
            Name = 'Managed cluster tags match source control'
            Skipped = 'Tag comparison requires a source-controlled inventory CSV.'
        })
    }
    else {
        $membershipMessage = "$($liveOnlyRows.Count) live-only cluster(s); $($sourceOnlyRows.Count) source-only cluster(s)."
        $membershipCase = @{ Name = 'Live and source-controlled cluster membership match' }
        if ($liveOnlyRows.Count -gt 0 -or $sourceOnlyRows.Count -gt 0) {
            $membershipCase.Failure = @{ Message = $membershipMessage; Type = 'InventoryMembershipDrift'; Body = $membershipMessage }
        }
        else { $membershipCase.SystemOut = 'No cluster membership drift detected.' }
        $membershipCases = @($membershipCase)

        $tagMessage = "$($tagMismatchClusters.Count) cluster(s) have $($tagMismatchRows.Count) managed-tag discrepancy(s)."
        $tagCase = @{ Name = 'Managed cluster tags match source control' }
        if ($tagMismatchRows.Count -gt 0) {
            $tagCase.Failure = @{ Message = $tagMessage; Type = 'ManagedTagDrift'; Body = $tagMessage }
        }
        else { $tagCase.SystemOut = 'No managed tag drift detected.' }
        $tagCases = @($tagCase)
    }
    [void](New-AzLocalPipelineJUnitXml -TestSuitesName 'Config: 1 - Cluster Inventory Drift' -Suites @(
        @{ Name = 'Inventory Membership'; ClassName = 'ClusterInventoryDrift'; TestCases = $membershipCases }
        @{ Name = 'Managed Tags'; ClassName = 'ClusterInventoryDrift'; TestCases = $tagCases }
    ) -OutputPath $xmlPath -Timestamp $Timestamp)

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine('## Cluster Inventory Drift')
    [void]$md.AppendLine('')
    if ($status -eq 'NotConfigured') {
        [void]$md.AppendLine(":information_source: **Status: NOT CONFIGURED** - source CSV not found at ``$SourceCsvPath``.")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('Download the generated inventory artifact, assign update-management values, and commit it as `config/ClusterUpdateRings.csv`. Drift comparison will begin on the next run.')
    }
    else {
        $statusIcon = if ($status -eq 'Clean') { ':white_check_mark:' } else { ':warning:' }
        [void]$md.AppendLine("$statusIcon **Status: $($status.ToUpperInvariant())**")
        [void]$md.AppendLine('')
        [void]$md.AppendLine('| Metric | Count |')
        [void]$md.AppendLine('|--------|------:|')
        [void]$md.AppendLine("| Live clusters | $(@($LiveInventory).Count) |")
        [void]$md.AppendLine("| Source-controlled clusters | $($sourceRows.Count) |")
        [void]$md.AppendLine("| Matching clusters | $matchingCount |")
        [void]$md.AppendLine("| New live clusters missing from source control | $($liveOnlyRows.Count) |")
        [void]$md.AppendLine("| Source-controlled clusters missing from live inventory | $($sourceOnlyRows.Count) |")
        [void]$md.AppendLine("| Clusters with managed-tag drift | $($tagMismatchClusters.Count) |")
        [void]$md.AppendLine("| Managed-tag field discrepancies | $($tagMismatchRows.Count) |")
        if ($rows.Count -gt 0) {
            [void]$md.AppendLine('')
            [void]$md.AppendLine('### Discrepancies')
            [void]$md.AppendLine('')
            [void]$md.AppendLine('| Status | Cluster | Field | Source | Live |')
            [void]$md.AppendLine('|--------|---------|-------|--------|------|')
            foreach ($row in @($rows | Select-Object -First 50)) {
                $clusterCell = ConvertTo-AzLocalMarkdownTableCell -Value ([string]$row.ClusterName)
                $fieldCell = if ($row.Field) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$row.Field) } else { '-' }
                $sourceCell = if ($row.SourceValue) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$row.SourceValue) } else { '-' }
                $liveCell = if ($row.LiveValue) { ConvertTo-AzLocalMarkdownTableCell -Value ([string]$row.LiveValue) } else { '-' }
                [void]$md.AppendLine("| $($row.Status) | $clusterCell | $fieldCell | $sourceCell | $liveCell |")
            }
            if ($rows.Count -gt 50) {
                [void]$md.AppendLine('')
                [void]$md.AppendLine("_Showing 50 of $($rows.Count) discrepancies. Download ``$CsvFileName`` for the full report._")
            }
        }
    }
    Add-AzLocalPipelineStepSummary -Markdown $md.ToString() -SummaryFileName $SummaryFileName | Out-Null

    Set-AzLocalPipelineOutput -Name 'inventory_drift_status' -Value $status
    Set-AzLocalPipelineOutput -Name 'inventory_drift_count' -Value ([string]$rows.Count)
    Set-AzLocalPipelineOutput -Name 'inventory_live_only_count' -Value ([string]$liveOnlyRows.Count)
    Set-AzLocalPipelineOutput -Name 'inventory_source_only_count' -Value ([string]$sourceOnlyRows.Count)
    Set-AzLocalPipelineOutput -Name 'inventory_tag_mismatch_count' -Value ([string]$tagMismatchClusters.Count)

    if ($status -eq 'Drift') {
        Write-AzLocalPipelineWarning -Title 'Cluster inventory drift detected' -Message "$($rows.Count) discrepancy row(s) found. Review the pipeline summary and '$CsvFileName' artifact."
    }

    if ($PassThru) { return $report }
}