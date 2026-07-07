function Add-AzLocalPipelineSupportFooter {
    <#
    .SYNOPSIS
        Appends the standard support-disclaimer footer to the pipeline run
        summary. Intended to be the LAST step of every AzLocal.UpdateManagement
        automation pipeline so the disclaimer renders at the very bottom.

    .DESCRIPTION
        v0.9.18. Writes a single markdown block - a horizontal rule followed by
        a bold "Support disclaimer:" label and an italic sentence - to the
        rendered step summary via Add-AzLocalPipelineStepSummary (GitHub Actions
        GITHUB_STEP_SUMMARY / Azure DevOps task.uploadsummary card). The wording
        makes clear these example pipelines are not a supported Microsoft
        service offering and tells the operator how to raise a support request.

        Add this as the final step of each pipeline job with `if: always()`
        (GitHub) / `condition: always()` (Azure DevOps) and
        `continue-on-error` / `continueOnError: true` so the disclaimer is shown
        even when an earlier step failed and a footer failure never reds a run.

    .PARAMETER SummaryFileName
        Forwarded to Add-AzLocalPipelineStepSummary (Azure DevOps / Local only).
        Defaults to 'azlocal-support-footer.md'. Ignored on GitHub Actions,
        which uses the single runner-managed $env:GITHUB_STEP_SUMMARY file.

    .PARAMETER PassThru
        When set, returns the summary file path written by
        Add-AzLocalPipelineStepSummary.

    .OUTPUTS
        Nothing by default (side effect only). When -PassThru is set, the
        summary file path [string].

    .EXAMPLE
        Add-AzLocalPipelineSupportFooter

        Appends the support-disclaimer footer to the current run summary.

    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.9.18
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-support-footer.md',

        [Parameter()]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    # Leading blank line + horizontal rule so the footer separates cleanly from
    # whatever content precedes it (the blank line prevents `---` from being
    # parsed as a setext H2 underline for the preceding text).
    $footer = "`n`n---`n`n**Support disclaimer:** _this pipeline and automation is NOT a supported Microsoft service offering. If you encounter an Azure Local cluster update issue(s), please re-create or report the issue(s) outside of this pipeline when opening a support request (SR) case with Microsoft._`n`n_To report an issue with the logic or outcome of this pipeline, please open a [GitHub issue](https://aka.ms/AzLocal.UpdateManagement/issues) - (no guarantees or time scales can be provided for resolution)._`n"

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown $footer -SummaryFileName $SummaryFileName

    if ($PassThru) { return $summaryPath }
}
