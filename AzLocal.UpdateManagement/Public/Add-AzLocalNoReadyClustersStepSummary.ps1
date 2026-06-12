function Add-AzLocalNoReadyClustersStepSummary {
    <#
    .SYNOPSIS
        Renders the 'No Clusters Ready for Update' markdown section emitted by
        the third Step.6 job (no-clusters-ready / NoClustersReady stage).
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Replaces the ~25-line inline `run:`
        block in both Step.6 pipelines (GH job no-clusters-ready, ADO stage
        NoClustersReady).

        Behaviour:
          - When -UpdateRing is empty/whitespace (the schedule resolver found
            NO row matching this firing's date/time): renders an informational
            "No UpdateRing Scheduled for This Firing" section explaining this
            is an EXPECTED idle cron tick (not a misconfiguration), and emits a
            plain informational log line - NOT a warning - so the run does not
            surface a spurious warning annotation. (v0.8.74)
          - When -UpdateRing is non-empty and -TotalCount is 0: renders the
            "No clusters found with UpdateRing tag value 'X'" message.
          - When -UpdateRing is non-empty and -TotalCount > 0: renders the
            "Found N cluster(s) ... but none are ready" message + "Possible
            reasons" bullet list.
          - For the two non-empty-ring cases above, emits a Write-Warning
            (GitHub / Local) or task.logissue warning (Azure DevOps) with the
            ring name, matching the prior inline block byte-for-byte.
    .PARAMETER UpdateRing
        Resolved UpdateRing label (string; may be empty for schedule-no-row case).
    .PARAMETER TotalCount
        Total count of clusters discovered by the readiness query (string-
        or-int accepted). 0 = no clusters found at all.
    .PARAMETER UpToDateCount
        Count of discovered clusters that are already fully patched (the
        readiness gate's Up-to-Date bucket). Optional; pass -1 (the default)
        when the caller does not have the breakdown - the summary then falls
        back to the generic "possible reasons" list. (v0.8.74)
    .PARAMETER NotReadyCount
        Count of discovered clusters that are held back and need attention
        before they can update. Optional; pass -1 (the default) when the
        caller does not have the breakdown. (v0.8.74)
    .PARAMETER SummaryFileName
        Per-task markdown filename (ADO/Local). Default
        'azlocal-step6-no-ready-summary.md'.
    .PARAMETER PassThru
        Returns PSCustomObject with: SummaryPath.
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.5 (Step.6 thin-YAML port)
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$UpdateRing,

        [Parameter(Mandatory = $false)]
        [object]$TotalCount = 0,

        [Parameter(Mandatory = $false)]
        [object]$UpToDateCount = -1,

        [Parameter(Mandatory = $false)]
        [object]$NotReadyCount = -1,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-step6-no-ready-summary.md',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost
    $headingLevel = if ($pipelineHost -eq 'AzureDevOps') { '#' } else { '##' }
    $totalInt     = [int]([string]$TotalCount)
    # Defensive parse: a count may arrive as an empty string when an upstream
    # pipeline variable / job output was not set (e.g. an unresolved ADO
    # $(macro)). Treat any non-integer value as -1 (unknown) so the summary
    # falls back to the generic message instead of throwing.
    $parseCount = {
        param($value)
        $parsed = 0
        if ([int]::TryParse([string]$value, [ref]$parsed)) { return $parsed }
        return -1
    }
    $upToDateInt  = & $parseCount $UpToDateCount
    $notReadyInt  = & $parseCount $NotReadyCount
    $haveBreakdown = ($upToDateInt -ge 0 -or $notReadyInt -ge 0)
    $ringIsEmpty  = [string]::IsNullOrWhiteSpace($UpdateRing)

    $checkChar = [string][char]0x2705                       # green check
    $warnChar  = [string][char]0x26A0 + [string][char]0xFE0F # warning sign

    $sb = New-Object System.Text.StringBuilder

    if ($ringIsEmpty) {
        # v0.8.74: the schedule resolver returned NO ring for this firing
        # (e.g. a cron tick on a day/cycleWeek with no schedule row). This is
        # an EXPECTED idle run, not a "no clusters found" failure - render an
        # informational section that says so rather than the misleading
        # "No clusters found with UpdateRing tag value ''" message.
        [void]$sb.AppendLine("$headingLevel No UpdateRing Scheduled for This Firing")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("This scheduled run did not match any row in the apply-updates schedule for the current date/time, so there is no UpdateRing to process. **This is expected** on cron firings that fall outside your configured maintenance windows - no action is required and no clusters were queried.")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('- Apply-updates was skipped cleanly (the readiness gate reported ready_count=0).')
        [void]$sb.AppendLine('- See the **Resolve UpdateRing from schedule** step log for the cycleWeek / dayOfWeek that was evaluated and why no schedule row matched.')
        [void]$sb.AppendLine('- To change which days trigger updates, edit your `apply-updates-schedule.yml`.')
    }
    else {
        [void]$sb.AppendLine("$headingLevel No Clusters Ready for Update")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine("**Target UpdateRing:** $UpdateRing")
        [void]$sb.AppendLine()

        if ($totalInt -eq 0) {
            [void]$sb.AppendLine("No clusters found with UpdateRing tag value '$UpdateRing'")
        }
        elseif ($haveBreakdown) {
            # v0.8.74: clusters were found but none are ready to START a new
            # update. Break the outcome down so "no clusters ready" is not
            # alarming - clusters that are already fully patched are a HEALTHY
            # steady state, not a failure. Per-cluster "why" lives in the
            # Check Update Readiness table + readiness-report.csv (re-deriving
            # status from the CSV here is unsafe - imported booleans are
            # strings, e.g. [bool]'False' is $true).
            $udShown = if ($upToDateInt -ge 0) { $upToDateInt } else { 0 }
            $nrShown = if ($notReadyInt -ge 0) { $notReadyInt } else { $totalInt - $udShown }

            if ($nrShown -le 0 -and $udShown -gt 0) {
                [void]$sb.AppendLine("All $totalInt cluster(s) tagged UpdateRing='$UpdateRing' are already up to date - there is nothing to apply. This is a healthy steady state, not a failure.")
            }
            else {
                [void]$sb.AppendLine("Found $totalInt cluster(s) tagged UpdateRing='$UpdateRing'. None are ready to start a new update right now.")
            }
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('| Outcome | Clusters |')
            [void]$sb.AppendLine('|---|---|')
            [void]$sb.AppendLine(("| {0} Up to Date (already fully patched - no action needed) | {1} |" -f $checkChar, $udShown))
            [void]$sb.AppendLine(("| {0} Not Ready (needs attention before updating) | {1} |" -f $warnChar, $nrShown))
            [void]$sb.AppendLine()
            if ($nrShown -gt 0) {
                [void]$sb.AppendLine("**Not Ready** clusters were held back for one or more of: an update already in progress, a pending SBE / prerequisite update, or a blocking health-check failure. See the per-cluster **Status** and **Blocking Reasons** columns in the **Check Update Readiness** summary (or the ``readiness-report.csv`` artifact) for the exact reason on each cluster.")
            }
            else {
                [void]$sb.AppendLine("See the **Check Update Readiness** summary table (or the ``readiness-report.csv`` artifact) for the per-cluster detail.")
            }
        }
        else {
            # Fallback when the caller did not supply the Up-to-Date / Not-Ready
            # breakdown (older callers / -UpToDateCount and -NotReadyCount left
            # at the -1 default).
            [void]$sb.AppendLine("Found $totalInt cluster(s) with UpdateRing='$UpdateRing', but none are ready for updates.")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('Possible reasons:')
            [void]$sb.AppendLine('- Clusters may already be up to date')
            [void]$sb.AppendLine('- Updates may be in progress')
            [void]$sb.AppendLine('- Clusters may have health check failures')
            [void]$sb.AppendLine()
            [void]$sb.AppendLine('Download the readiness report artifact for details.')
        }
    }

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown $sb.ToString() -SummaryFileName $SummaryFileName

    # Per-host log surfacing. For a non-empty ring with no ready clusters this
    # is a genuine warning. For the empty-ring (no schedule row matched) case
    # it is an EXPECTED idle firing, so emit a plain informational line - NOT a
    # warning - to avoid a spurious warning annotation on the run. (v0.8.74)
    # Likewise, when EVERY discovered cluster is already up to date (the
    # breakdown shows zero Not-Ready) that is a healthy steady state, so emit a
    # notice rather than a warning. (v0.8.74)
    $allUpToDate = ($haveBreakdown -and ($notReadyInt -le 0) -and ($upToDateInt -gt 0))
    if ($ringIsEmpty) {
        switch ($pipelineHost) {
            'GitHub'      { Write-Host "::notice title=No UpdateRing scheduled for this firing::No schedule row matched the current date/time - apply-updates skipped cleanly (expected)." }
            'AzureDevOps' { Write-Host "No UpdateRing scheduled for this firing - apply-updates skipped cleanly (expected). No schedule row matched the current date/time." }
            default       { Write-Host "[notice] No UpdateRing scheduled for this firing - apply-updates skipped cleanly (expected)." }
        }
    }
    elseif ($allUpToDate) {
        switch ($pipelineHost) {
            'GitHub'      { Write-Host "::notice title=All clusters up to date::All clusters in ring '$UpdateRing' are already up to date - nothing to apply (expected)." }
            'AzureDevOps' { Write-Host "All clusters in ring '$UpdateRing' are already up to date - nothing to apply (expected)." }
            default       { Write-Host "[notice] All clusters in ring '$UpdateRing' are already up to date - nothing to apply (expected)." }
        }
    }
    else {
        switch ($pipelineHost) {
            'GitHub'      { Write-Warning "No clusters ready for update in ring '$UpdateRing'" }
            'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]No clusters are ready for updates in ring '$UpdateRing'" }
            default       { Write-Warning "No clusters ready for update in ring '$UpdateRing'" }
        }
    }

    if ($PassThru) {
        return [pscustomobject]@{
            SummaryPath = $summaryPath
        }
    }
}
