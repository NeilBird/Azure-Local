function Add-AzLocalFailedUpdateRetryHintSummary {
    <#
    .SYNOPSIS
        Appends an opt-in awareness notice for the FAILED_UPDATES_SINGLE_RETRY
        capability to the consolidated pipeline summary. Rendered by the Apply
        Updates (Step 3) and Monitor In-Flight Updates (Step 4) pipelines when
        the feature is NOT enabled, so operators discover it without changing
        any default behaviour.
    .DESCRIPTION
        v0.8.95 discoverability helper. The guarded one-time retry of FAILED
        cluster updates (Invoke-AzLocalReadinessGatedFailedUpdateRetry) is OFF by
        default and only runs when the pipeline variable
        FAILED_UPDATES_SINGLE_RETRY is set to 'true'. To make the opt-in
        capability discoverable, both the Apply-Updates and Monitor pipelines
        call this helper on every run where the feature is disabled; it appends a
        short, host-tailored notice (with the exact enable command) to the same
        consolidated job summary and points at the CI/CD README documentation.

        When -IsEnabled is supplied (the feature IS turned on) this helper renders
        NOTHING and returns $null - the retry step produces its own summary
        section in that case, so a hint would be redundant.

        Host detection (Get-AzLocalPipelineHost) tailors the enable instructions:
          - GitHub Actions : `gh variable set FAILED_UPDATES_SINGLE_RETRY --body true`
          - Azure DevOps   : pipeline variable / variable group entry
                             FAILED_UPDATES_SINGLE_RETRY = true
          - Local          : both, for reference.
    .PARAMETER IsEnabled
        Switch. Pass this when FAILED_UPDATES_SINGLE_RETRY is already 'true'. The
        helper then renders nothing (the retry step owns the summary section).
    .PARAMETER DocReference
        Repo-relative path to the CI/CD documentation that describes the opt-in
        variable. Default 'AzLocal.UpdateManagement/Automation-Pipeline-Examples/README.md'.
    .PARAMETER SummaryFileName
        Per-task markdown filename (ADO/Local only). Default
        'azlocal-failed-update-retry-hint.md'.
    .PARAMETER PassThru
        Returns a PSCustomObject with Rendered (bool) and SummaryPath.
    .OUTPUTS
        PSCustomObject (with -PassThru) or none.
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.95
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [switch]$IsEnabled,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$DocReference = 'AzLocal.UpdateManagement/Automation-Pipeline-Examples/README.md',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-failed-update-retry-hint.md',

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Feature already on -> the retry step renders its own section; nothing to do.
    if ($IsEnabled) {
        if ($PassThru) {
            return [pscustomobject]@{ Rendered = $false; SummaryPath = $null }
        }
        return
    }

    $pipelineHost = Get-AzLocalPipelineHost

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## :bulb: Opt-in available: one-time auto-retry of failed updates')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Clusters whose latest update run ended in a **failed** state (NeedsAttention / UpdateFailed / PreparationFailed) are currently **left as-is** - no automatic retry is attempted.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('You can enable a **guarded, one-time** retry that re-applies the same update version for those clusters (the same action as the portal''s "Try again" button). It is safe-by-design:')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('- Retries each failed cluster **exactly once** per update version (a durable `UpdateRetryAttempted` cluster tag prevents retry loops).')
    [void]$sb.AppendLine('- The guard **auto-clears** once the retried run reaches Succeeded, re-arming a future retry naturally.')
    [void]$sb.AppendLine('- **In-progress / stalled** runs are never retried.')
    [void]$sb.AppendLine('- Reuses the existing readiness report - no extra discovery, no change to clusters that are healthy or already up to date.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('**To enable**, set the pipeline variable `FAILED_UPDATES_SINGLE_RETRY` to `true`:')
    [void]$sb.AppendLine('')
    switch ($pipelineHost) {
        'AzureDevOps' {
            [void]$sb.AppendLine('Azure DevOps - add a pipeline variable (or variable-group entry):')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine('FAILED_UPDATES_SINGLE_RETRY = true')
            [void]$sb.AppendLine('```')
        }
        'GitHub' {
            [void]$sb.AppendLine('GitHub Actions - set a repository Variable:')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine('gh variable set FAILED_UPDATES_SINGLE_RETRY --body true')
            [void]$sb.AppendLine('```')
        }
        default {
            [void]$sb.AppendLine('GitHub Actions:')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine('gh variable set FAILED_UPDATES_SINGLE_RETRY --body true')
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('Azure DevOps - add a pipeline variable (or variable-group entry):')
            [void]$sb.AppendLine('')
            [void]$sb.AppendLine('```')
            [void]$sb.AppendLine('FAILED_UPDATES_SINGLE_RETRY = true')
            [void]$sb.AppendLine('```')
        }
    }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Full setup and behaviour: see **$DocReference** -> ""Opt-in: single-retry of failed updates"".")
    [void]$sb.AppendLine('')

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown $sb.ToString() -SummaryFileName $SummaryFileName

    if ($PassThru) {
        return [pscustomobject]@{ Rendered = $true; SummaryPath = $summaryPath }
    }
}
