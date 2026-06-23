function Invoke-AzLocalReadinessGatedFailedUpdateRetry {
    <#
    .SYNOPSIS
        Step.6 thin-YAML adapter that retries previously FAILED cluster updates
        for the clusters in the readiness CSV, emits per-status step outputs,
        persists per-cluster results to apply-retry-results.json, and appends a
        dedicated 'Failed Update Single-Retry' section to the consolidated
        pipeline summary.
    .DESCRIPTION
        v0.8.95 opt-in companion to Invoke-AzLocalReadinessGatedClusterUpdate.

        The apply-updates pipeline already produces readiness-report.csv (one row
        per cluster in the UpdateRing scope, with ReadyForUpdate, UpdateState and
        ClusterResourceId columns). The readiness gate marks clusters whose latest
        run terminated in a FAILED state as ReadyForUpdate=False (NotReady), so the
        primary apply step never touches them. This adapter consumes the SAME CSV
        and selects exactly those failed-state rows, then calls the per-cluster
        primitive Invoke-AzLocalFailedUpdateRetry once for each.

        The guard against re-applying in a loop lives in the primitive (the
        durable UpdateRetryAttempted cluster tag), NOT here - this adapter is a
        thin fan-out. It invokes the primitive with -Confirm:$false (unattended)
        but WITHOUT -Force, so the one-time guard stays in force: a cluster that
        was already retried once for the same update version returns
        'RetryAlreadyAttempted' and is not re-applied. The guard tag is
        auto-cleared once the retried run reaches Succeeded
        (Invoke-AzLocalSideloadedAutoResetForCluster), re-arming a future retry.

        This step is OPT-IN at the pipeline layer: the bundled apply-updates.yml
        pipelines only invoke it when the FAILED_UPDATES_SINGLE_RETRY pipeline
        variable is 'true'. The cmdlet itself never reads that variable - the
        gating is entirely in the YAML.

        Failed updateSummary states recognised: NeedsAttention, UpdateFailed,
        PreparationFailed. UpdateInProgress (including stalled/orphaned runs) is
        intentionally NOT retried - the primitive skips those.
    .PARAMETER ReadinessCsvPath
        Path to readiness-report.csv produced by the check-readiness job.
    .PARAMETER UpdateRing
        UpdateRing label used in console/summary output. Cosmetic only; the retry
        scope comes from the CSV.
    .PARAMETER DryRun
        Switch. When set, the primitive is invoked with -WhatIf so no retry is
        actually issued.
    .PARAMETER OutputDirectory
        Directory where apply-retry-results.json is written. Defaults to the
        readiness CSV's parent directory.
    .PARAMETER RetryResultsJsonFileName
        Per-cluster JSON filename. Default 'apply-retry-results.json'.
    .PARAMETER SummaryFileName
        Per-task markdown filename (ADO/Local only). Default
        'azlocal-step6-retry-summary.md'.
    .PARAMETER ApiVersion
        Azure REST API version forwarded to the primitive. Defaults to the module
        default API version.
    .PARAMETER PassThru
        Returns a PSCustomObject with the four counters (RetryStarted,
        RetryAlreadyAttempted, RetrySkipped, RetryFailed) plus Results,
        RetryResultsJsonPath, FailedResourceIds and SummaryPath.
    .OUTPUTS
        PSCustomObject (with -PassThru) or none.
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.95
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessCsvPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$UpdateRing = '',

        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$OutputDirectory = '',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RetryResultsJsonFileName = 'apply-retry-results.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-step6-retry-summary.md',

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

    # updateSummary states that mark a terminal failed/aborted run. Mirrors the
    # gate in Invoke-AzLocalFailedUpdateRetry; the primitive re-validates per
    # cluster, so this CSV-level filter is only a coarse pre-selection.
    $failedStates = @('NeedsAttention', 'UpdateFailed', 'PreparationFailed')

    # OutputDirectory default: parent of the readiness CSV.
    if (-not $OutputDirectory) {
        $OutputDirectory = Split-Path -Path $ReadinessCsvPath -Parent
        if (-not $OutputDirectory) { $OutputDirectory = '.' }
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }
    $retryJsonPath = Join-Path -Path $OutputDirectory -ChildPath $RetryResultsJsonFileName

    # Per-host step-output naming: GH UPPER_SNAKE, ADO PascalCase.
    if ($pipelineHost -eq 'AzureDevOps') {
        $nStarted = 'RetryStarted'; $nAlready = 'RetryAlready'
        $nSkipped = 'RetrySkipped'; $nFailed = 'RetryFailed'
    }
    else {
        $nStarted = 'RETRY_STARTED'; $nAlready = 'RETRY_ALREADY'
        $nSkipped = 'RETRY_SKIPPED'; $nFailed = 'RETRY_FAILED'
    }

    # Lexically-scoped emitter (no .GetNewClosure() - that severs module
    # SessionState and hides the private Set-AzLocalPipelineOutput function).
    $emitCounters = {
        param($st, $al, $sk, $f)
        Set-AzLocalPipelineOutput -Name $nStarted -Value "$st" -CrossJob
        Set-AzLocalPipelineOutput -Name $nAlready -Value "$al" -CrossJob
        Set-AzLocalPipelineOutput -Name $nSkipped -Value "$sk" -CrossJob
        Set-AzLocalPipelineOutput -Name $nFailed  -Value "$f"  -CrossJob
    }

    if (-not (Test-Path -LiteralPath $ReadinessCsvPath)) {
        throw "Invoke-AzLocalReadinessGatedFailedUpdateRetry: Readiness CSV not found at '$ReadinessCsvPath'. The check-readiness job did not upload a readiness-report artifact - cannot determine which clusters to retry."
    }

    $readinessRows = @(Import-Csv -Path $ReadinessCsvPath)
    if ($readinessRows.Count -gt 0) {
        $cols = $readinessRows[0].PSObject.Properties.Name
        if (-not ($cols -contains 'ClusterResourceId')) {
            throw "Invoke-AzLocalReadinessGatedFailedUpdateRetry: Readiness CSV at '$ReadinessCsvPath' is missing the 'ClusterResourceId' column. Re-run check-readiness with v0.7.62+ or refresh the pipeline YAML via Copy-AzLocalPipelineExample -Update."
        }
        if (-not ($cols -contains 'UpdateState')) {
            throw "Invoke-AzLocalReadinessGatedFailedUpdateRetry: Readiness CSV at '$ReadinessCsvPath' is missing the 'UpdateState' column - cannot identify failed clusters to retry."
        }
    }

    # Coarse pre-selection: failed updateSummary state AND a usable resource id.
    $failedRows = @($readinessRows | Where-Object {
            $_.ClusterResourceId -and ($_.UpdateState -in $failedStates)
        })
    [string[]]$failedResourceIds = @($failedRows | ForEach-Object { [string]$_.ClusterResourceId })

    Write-Host "Readiness CSV: $($readinessRows.Count) row(s), $($failedResourceIds.Count) in a failed update state eligible for single-retry."

    # Local helper to render + emit the summary section, so every early-return
    # path still contributes a section to the consolidated summary.
    $renderSummary = {
        param($Rows, $StartedN, $AlreadyN, $SkippedN, $FailedN)
        $okIcon = ':white_check_mark:'; $alreadyIcon = ':fast_forward:'
        $skipIcon = ':no_entry:'; $failIcon = ':x:'
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('## Failed Update Single-Retry')
        [void]$sb.AppendLine('')
        if (-not [string]::IsNullOrWhiteSpace($UpdateRing)) {
            [void]$sb.AppendLine("Target UpdateRing: **$UpdateRing**")
            [void]$sb.AppendLine('')
        }
        if ($DryRun) {
            [void]$sb.AppendLine('> This was a dry run - no retries were actually issued.')
            [void]$sb.AppendLine('')
        }
        [void]$sb.AppendLine('| Result | Count |')
        [void]$sb.AppendLine('|---|---|')
        [void]$sb.AppendLine("| $okIcon Retry started | $StartedN |")
        [void]$sb.AppendLine("| $alreadyIcon Already retried (guard) | $AlreadyN |")
        [void]$sb.AppendLine("| $skipIcon Skipped | $SkippedN |")
        [void]$sb.AppendLine("| $failIcon Failed | $FailedN |")
        [void]$sb.AppendLine('')
        if ($Rows -and @($Rows).Count -gt 0) {
            [void]$sb.AppendLine('| Cluster | Status | Update | Message |')
            [void]$sb.AppendLine('|---|---|---|---|')
            foreach ($row in @($Rows)) {
                $msg = if ($row.PSObject.Properties['Message'] -and $row.Message) {
                    ([string]$row.Message) -replace '\|', '\|' -replace '\r?\n', ' '
                }
                else { '' }
                if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 197) + '...' }
                $upd = if ($row.PSObject.Properties['UpdateName'] -and $row.UpdateName) { [string]$row.UpdateName } else { '' }
                [void]$sb.AppendLine(('| {0} | {1} | {2} | {3} |' -f $row.ClusterName, $row.Status, $upd, $msg))
            }
            [void]$sb.AppendLine('')
        }
        else {
            [void]$sb.AppendLine('No clusters were in a failed update state - nothing to retry.')
            [void]$sb.AppendLine('')
        }
        return (Add-AzLocalPipelineStepSummary -Markdown $sb.ToString() -SummaryFileName $SummaryFileName)
    }

    if ($failedResourceIds.Count -eq 0) {
        & $emitCounters 0 0 0 0
        $summaryPath = & $renderSummary @() 0 0 0 0
        @() | ConvertTo-Json -Depth 4 | Out-File -FilePath $retryJsonPath -Encoding utf8 -Force
        if ($PassThru) {
            return [pscustomobject]@{
                RetryStarted          = 0
                RetryAlreadyAttempted = 0
                RetrySkipped          = 0
                RetryFailed           = 0
                Results               = @()
                RetryResultsJsonPath  = $retryJsonPath
                FailedResourceIds     = @()
                SummaryPath           = $summaryPath
            }
        }
        return
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Single-retry of FAILED updates (UpdateRing: $UpdateRing)" -ForegroundColor Cyan
    Write-Host "  Clusters in failed state (from readiness CSV): $($failedResourceIds.Count)" -ForegroundColor Cyan
    if ($DryRun) { Write-Host "  DRY RUN MODE - no retries will be issued" -ForegroundColor Yellow }
    Write-Host "========================================" -ForegroundColor Cyan

    $results = @()
    foreach ($resId in $failedResourceIds) {
        $retryParams = @{
            ClusterResourceId = $resId
            ApiVersion        = $ApiVersion
            Confirm           = $false
        }
        if ($DryRun) { $retryParams['WhatIf'] = $true }
        # Primitive is best-effort per cluster; never let one cluster abort the
        # fan-out (the primitive already wraps its body in try/catch and returns
        # a Failed row, but guard the invocation itself defensively).
        try {
            $results += @(Invoke-AzLocalFailedUpdateRetry @retryParams)
        }
        catch {
            $name = ($resId -split '/')[-1]
            Write-Host "::warning::Retry invocation threw for '$name': $($_.Exception.Message)"
            $results += [pscustomobject]@{
                ClusterName = $name
                Status      = 'Failed'
                Message     = $_.Exception.Message
                UpdateName  = $null
                StartTime   = (Get-Date)
                EndTime     = (Get-Date)
                Duration    = '00:00:00'
            }
        }
    }
    $results = @($results)

    Write-Host ""
    Write-Host "Single-retry operation complete"

    $retryStarted = @($results | Where-Object { $_.Status -eq 'RetryStarted' }).Count
    $retryAlready = @($results | Where-Object { $_.Status -eq 'RetryAlreadyAttempted' }).Count
    $retrySkipped = @($results | Where-Object { $_.Status -in @('Skipped', 'NotFound', 'WhatIf') }).Count
    $retryFailed  = @($results | Where-Object { $_.Status -in @('Failed', 'Error') }).Count

    & $emitCounters $retryStarted $retryAlready $retrySkipped $retryFailed

    @($results) | Select-Object ClusterName, Status, UpdateName, Duration, Message |
        ConvertTo-Json -Depth 4 |
        Out-File -FilePath $retryJsonPath -Encoding utf8 -Force
    Write-Host "Wrote per-cluster retry results to $retryJsonPath"

    $summaryPath = & $renderSummary $results $retryStarted $retryAlready $retrySkipped $retryFailed

    # ADO-only per-bucket warning lines (preserve CI surface parity).
    if ($pipelineHost -eq 'AzureDevOps') {
        if ($retryFailed -gt 0) {
            Write-Host "##vso[task.logissue type=warning]$retryFailed cluster(s) failed to retry. See apply-retry-results.json for per-cluster detail."
        }
        if ($retryAlready -gt 0) {
            Write-Host "##vso[task.logissue type=warning]$retryAlready cluster(s) were already retried once (one-time guard). Use Invoke-AzLocalFailedUpdateRetry -Force to override manually."
        }
    }

    if ($PassThru) {
        return [pscustomobject]@{
            RetryStarted          = $retryStarted
            RetryAlreadyAttempted = $retryAlready
            RetrySkipped          = $retrySkipped
            RetryFailed           = $retryFailed
            Results               = $results
            RetryResultsJsonPath  = $retryJsonPath
            FailedResourceIds     = $failedResourceIds
            SummaryPath           = $summaryPath
        }
    }
}
