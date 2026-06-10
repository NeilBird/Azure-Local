function Add-AzLocalNoReadyClustersStepSummary {
    <#
    .SYNOPSIS
        Renders the 'No Clusters Ready for Update' markdown section emitted by
        the third Step.6 job (no-clusters-ready / NoClustersReady stage).
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Replaces the ~25-line inline `run:`
        block in both Step.6 pipelines (GH job no-clusters-ready, ADO stage
        NoClustersReady).

        Behaviour matches the prior inline block:
          - Emits the same Markdown headings and bullet lists.
          - When -TotalCount is 0: renders the "No clusters found with
            UpdateRing tag value 'X'" message.
          - When -TotalCount > 0: renders the "Found N cluster(s) ... but none
            are ready" message + "Possible reasons" bullet list.
          - On GitHub Actions ONLY: also emits Write-Warning with the same
            text the prior inline block did (matches the GH no-clusters-ready
            run block's `Write-Warning "No clusters ready for update in ring
            '<ring>'"` final line so logs are identical).
          - On Azure DevOps ONLY: emits the same task.logissue warning the
            prior inline block did.
    .PARAMETER UpdateRing
        Resolved UpdateRing label (string; may be empty for schedule-no-row case).
    .PARAMETER TotalCount
        Total count of clusters discovered by the readiness query (string-
        or-int accepted). 0 = no clusters found at all.
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
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-step6-no-ready-summary.md',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost
    $headingLevel = if ($pipelineHost -eq 'AzureDevOps') { '#' } else { '##' }
    $totalInt     = [int]([string]$TotalCount)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("$headingLevel No Clusters Ready for Update")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("**Target UpdateRing:** $UpdateRing")
    [void]$sb.AppendLine()

    if ($totalInt -eq 0) {
        [void]$sb.AppendLine("No clusters found with UpdateRing tag value '$UpdateRing'")
    }
    else {
        [void]$sb.AppendLine("Found $totalInt cluster(s) with UpdateRing='$UpdateRing', but none are ready for updates.")
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('Possible reasons:')
        [void]$sb.AppendLine('- Clusters may already be up to date')
        [void]$sb.AppendLine('- Updates may be in progress')
        [void]$sb.AppendLine('- Clusters may have health check failures')
        [void]$sb.AppendLine()
        [void]$sb.AppendLine('Download the readiness report artifact for details.')
    }

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown $sb.ToString() -SummaryFileName $SummaryFileName

    # Preserve per-host log surfacing of the warning (byte-for-byte equivalent
    # to the prior inline run-block).
    switch ($pipelineHost) {
        'GitHub'      { Write-Warning "No clusters ready for update in ring '$UpdateRing'" }
        'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]No clusters are ready for updates in ring '$UpdateRing'" }
        default       { Write-Warning "No clusters ready for update in ring '$UpdateRing'" }
    }

    if ($PassThru) {
        return [pscustomobject]@{
            SummaryPath = $summaryPath
        }
    }
}
