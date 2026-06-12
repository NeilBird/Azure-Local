function Export-AzLocalClusterReadinessGateReport {
    <#
    .SYNOPSIS
        Runs Get-AzLocalClusterUpdateReadiness for the given UpdateRing,
        writes readiness-report.csv to the pipeline artifact folder, emits
        step outputs READY_COUNT/TOTAL_COUNT/NOT_READY_COUNT, and renders the
        per-cluster readiness markdown table to the run summary.
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Replaces the ~80-line inline `run:`
        block that lived in both Step.7_apply-updates.yml pipelines.

        Behaviour matches the prior inline block byte-for-byte:
          - When -UpdateRing is empty/whitespace (no schedule row matched
            today): skips the readiness query, emits zero counts, and exits
            cleanly. Downstream apply-updates is gated on ready_count > 0
            and will be skipped.
          - Otherwise: discovers clusters by tag, exports CSV, counts ready
            vs not-ready, emits the same READY_COUNT/TOTAL_COUNT step outputs
            the apply-updates job consumes.
          - Markdown table: one row per assessed cluster (sorted Ready-first
            then ClusterName ASC), capped at -MaxRows (default 100). Same
            columns and emoji as Enhancement D introduced in v0.8.4.
    .PARAMETER UpdateRing
        UpdateRing tag value to filter clusters by. Empty string OR whitespace
        triggers the zero-clusters short-circuit (see DESCRIPTION).
    .PARAMETER OutputDirectory
        Directory where readiness-report.csv is written. Defaults to:
          - Azure DevOps: $env:BUILD_ARTIFACTSTAGINGDIRECTORY
          - GitHub / Local: './artifacts'
    .PARAMETER ReadinessCsvFileName
        Filename for the CSV. Default: 'readiness-report.csv'.
    .PARAMETER MaxRows
        Maximum rows rendered into the markdown table. Default 100. The CSV
        always contains every assessed cluster regardless of this cap.
    .PARAMETER SummaryFileName
        Filename for the per-task markdown summary (ADO/Local only). Default:
        'azlocal-step6-readiness-summary.md'.
    .PARAMETER PassThru
        Returns PSCustomObject with: TotalCount, ReadyCount, UpToDateCount,
        NotReadyCount, UpdateRing, ReadinessCsvPath, SummaryPath, Results (raw
        rows from Get-AzLocalClusterUpdateReadiness when not in the
        short-circuit path, else @()).
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.5 (Step.6 thin-YAML port)
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$UpdateRing = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$OutputDirectory = '',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessCsvFileName = 'readiness-report.csv',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [int]$MaxRows = 100,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-step6-readiness-summary.md',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

    # OutputDirectory default (host-specific, byte-for-byte the same as the
    # prior inline block).
    if (-not $OutputDirectory) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $OutputDirectory = $env:BUILD_ARTIFACTSTAGINGDIRECTORY
        }
        else {
            $OutputDirectory = './artifacts'
        }
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $csvPath = Join-Path -Path $OutputDirectory -ChildPath $ReadinessCsvFileName

    # Per-host step-output naming - PRESERVE existing pipeline downstream
    # bindings byte-for-byte: GH uses UPPER_SNAKE, ADO uses PascalCase
    # (e.g. stageDependencies.CheckReadiness.ReadinessCheck.outputs['readiness.ReadyCount']).
    if ($pipelineHost -eq 'AzureDevOps') {
        $nReadyCount = 'ReadyCount'; $nTotalCount = 'TotalCount'; $nNotReadyCount = 'NotReadyCount'; $nUpToDateCount = 'UpToDateCount'
    }
    else {
        $nReadyCount = 'READY_COUNT'; $nTotalCount = 'TOTAL_COUNT'; $nNotReadyCount = 'NOT_READY_COUNT'; $nUpToDateCount = 'UP_TO_DATE_COUNT'
    }

    # Short-circuit when the schedule resolver returned no ring.
    if ([string]::IsNullOrWhiteSpace($UpdateRing)) {
        Write-Host "No UpdateRing scheduled for this firing - skipping readiness check."
        Set-AzLocalPipelineOutput -Name $nReadyCount    -Value '0' -CrossJob
        Set-AzLocalPipelineOutput -Name $nTotalCount    -Value '0' -CrossJob
        Set-AzLocalPipelineOutput -Name $nUpToDateCount -Value '0' -CrossJob
        Set-AzLocalPipelineOutput -Name $nNotReadyCount -Value '0' -CrossJob
        if ($PassThru) {
            return [pscustomobject]@{
                TotalCount       = 0
                ReadyCount       = 0
                UpToDateCount    = 0
                NotReadyCount    = 0
                UpdateRing       = ''
                ReadinessCsvPath = $csvPath
                SummaryPath      = $null
                Results          = @()
            }
        }
        return
    }

    Write-Host "Checking readiness for clusters with UpdateRing = '$UpdateRing'"

    $results = @(Get-AzLocalClusterUpdateReadiness `
            -ScopeByUpdateRingTag `
            -UpdateRingValue $UpdateRing `
            -ExportPath $csvPath `
            -PassThru)

    $totalCount    = $results.Count
    $readyCount    = @($results | Where-Object { $_.ReadyForUpdate -eq $true }).Count
    # v0.8.74: Up to Date is now its own displayed bucket (shared cascade with
    # Step.5 / Step.9) so clusters that have already applied all updates are not
    # lumped into "Not Ready" - that previously implied failure for healthy,
    # fully-patched clusters. READY_COUNT (the apply-updates gate) is unchanged.
    $upToDateCount = @($results | Where-Object { (Get-AzLocalClusterReadinessStatus -ReadinessRow $_) -eq 'UpToDate' }).Count
    $notReadyCount = $totalCount - $readyCount - $upToDateCount

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Readiness Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Total Clusters: $totalCount"
    Write-Host "Ready for Update: $readyCount"
    Write-Host "Up to Date: $upToDateCount"
    Write-Host "Not Ready: $notReadyCount"

    Set-AzLocalPipelineOutput -Name $nReadyCount    -Value "$readyCount"    -CrossJob
    Set-AzLocalPipelineOutput -Name $nTotalCount    -Value "$totalCount"    -CrossJob
    Set-AzLocalPipelineOutput -Name $nUpToDateCount -Value "$upToDateCount" -CrossJob
    Set-AzLocalPipelineOutput -Name $nNotReadyCount -Value "$notReadyCount" -CrossJob

    if ($readyCount -eq 0 -and $pipelineHost -eq 'AzureDevOps') {
        # Preserve byte-for-byte the original Step.6 ADO warning text.
        Write-Host "##vso[task.logissue type=warning]No clusters are ready for updates in ring '$UpdateRing'"
    }

    # Per-cluster readiness markdown table. Heading is `# Cluster Readiness`
    # on ADO (file is its own summary card) and `## Cluster Readiness` on
    # GitHub (appended into GITHUB_STEP_SUMMARY which already has H1).
    $headingLevel = if ($pipelineHost -eq 'AzureDevOps') { '#' } else { '##' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("$headingLevel Cluster Readiness ($UpdateRing)")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("**Total:** $totalCount &nbsp;|&nbsp; **Ready:** $readyCount &nbsp;|&nbsp; **Up to Date:** $upToDateCount &nbsp;|&nbsp; **Not Ready:** $notReadyCount")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('| Cluster | Current Version | Update State | Health | Status | Recommended Update | Blocking Reasons |')
    [void]$sb.AppendLine('|---|---|---|---|---|---|---|')

    $rendered = 0
    foreach ($r in ($results | Sort-Object @{Expression = { [bool]$_.ReadyForUpdate }; Descending = $true }, ClusterName)) {
        if ($rendered -ge $MaxRows) { break }
        # v0.8.74: a readable Status cell driven by the shared readiness cascade.
        # Up-to-Date clusters now show a green check + "Up to Date" instead of the
        # no-entry icon that the old binary Ready? column rendered for them.
        $statusCell = switch (Get-AzLocalClusterReadinessStatus -ReadinessRow $r) {
            'ReadyForUpdate'     { "{0} Ready" -f [char]0x2705 }
            'UpToDate'           { "{0} Up to Date" -f [char]0x2705 }
            'InProgress'         { "{0} In Progress" -f ([string]([char]0x23F3)) }
            'SbeBlocked'         { "{0} SBE Prerequisite" -f [char]0x26D4 }
            'HealthFailure'      { "{0} Health Failure" -f [char]0x274C }
            'UpdateFailed'       { "{0} Update Failed" -f [char]0x274C }
            'ActionRequired'     { "{0} Action Required" -f [char]0x274C }
            default              { "{0} Needs Investigation" -f ([string]([char]0x26A0) + [char]0xFE0F) }
        }
        $hSt = "$($r.HealthState)"
        $hCell = switch -Regex ($hSt) {
            '^Success$' { ("{0} {1}" -f [char]0x2705, $hSt); break }
            '^Warning$' { ("{0} {1}" -f ([string]([char]0x26A0) + [char]0xFE0F), $hSt); break }
            '^Failure$' { ("{0} {1}" -f [char]0x274C, $hSt); break }
            default     { $hSt }
        }
        $blocking = "$($r.BlockingReasons)"
        if ($blocking.Length -gt 200) { $blocking = $blocking.Substring(0, 197) + '...' }
        $blocking = $blocking -replace '\|', '\|' -replace '\r?\n', ' '
        $reco = if ($r.RecommendedUpdate) { '`' + $r.RecommendedUpdate + '`' } else { '-' }
        $curr = if ($r.CurrentVersion) { '`' + $r.CurrentVersion + '`' } else { '-' }
        [void]$sb.AppendLine("| ``$($r.ClusterName)`` | $curr | $($r.UpdateState) | $hCell | $statusCell | $reco | $blocking |")
        $rendered++
    }

    if ($totalCount -gt $MaxRows) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("_Showing first $MaxRows of $totalCount clusters. Download the readiness-report.csv artifact for the full list._")
    }
    [void]$sb.AppendLine()

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown $sb.ToString() -SummaryFileName $SummaryFileName

    if ($PassThru) {
        return [pscustomobject]@{
            TotalCount       = $totalCount
            ReadyCount       = $readyCount
            UpToDateCount    = $upToDateCount
            NotReadyCount    = $notReadyCount
            UpdateRing       = $UpdateRing
            ReadinessCsvPath = $csvPath
            SummaryPath      = $summaryPath
            Results          = $results
        }
    }
}
