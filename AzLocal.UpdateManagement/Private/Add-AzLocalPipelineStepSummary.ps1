function Add-AzLocalPipelineStepSummary {
    <#
    .SYNOPSIS
        Appends markdown content to the current step's summary in a host-appropriate way.
    .DESCRIPTION
        Replaces the boilerplate:
          GitHub Actions : append to $env:GITHUB_STEP_SUMMARY
          Azure DevOps   : write to a file under $env:BUILD_ARTIFACTSTAGINGDIRECTORY
                           (or $env:AGENT_TEMPDIRECTORY as fallback) and emit
                           `Write-Host "##vso[task.uploadsummary]<path>"` ONCE
                           per file. ADO renders one summary file per task in
                           the run Summary tab.
          Local          : writes to a per-session file under $env:TEMP and
                           prints the path. The path is also returned via the
                           pipeline so test harnesses can read it back.

        ADO note: every call to this function with a fresh -SummaryFileName
        produces a new uploadsummary directive. To accumulate content into one
        rendered card, callers pass the SAME -SummaryFileName across multiple
        calls and the function append-writes the markdown then re-emits the
        uploadsummary line (idempotent on ADO).

        IMPORTANT: byte-for-byte the same emission as the prior inline
        run-block text, including the exact env-var file used and the exact
        logging command syntax.
    .PARAMETER Markdown
        Markdown content to append (no trailing newline added; the caller
        controls layout).
    .PARAMETER SummaryFileName
        ADO + Local only: the filename used for the per-task summary file.
        Required so multiple tasks/cmdlets in the same job get distinct
        summary cards. Ignored on GitHub Actions (it uses a single
        GITHUB_STEP_SUMMARY file managed by the runner).
    .OUTPUTS
        Returns the absolute file path written/appended to. On GitHub Actions
        this is $env:GITHUB_STEP_SUMMARY; on ADO/Local this is the per-task
        file path so the caller can re-reference it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Markdown,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-step-summary.md'
    )

    $pipelineHost = Get-AzLocalPipelineHost
    switch ($pipelineHost) {
        'GitHub' {
            $summaryFile = $env:GITHUB_STEP_SUMMARY
            if (-not $summaryFile) {
                throw "Add-AzLocalPipelineStepSummary: GITHUB_ACTIONS is true but GITHUB_STEP_SUMMARY env var is not set. This indicates a corrupt runner environment."
            }
            $Markdown | Out-File -FilePath $summaryFile -Encoding utf8 -Append
            return $summaryFile
        }
        'AzureDevOps' {
            $stagingDir = $env:BUILD_ARTIFACTSTAGINGDIRECTORY
            if (-not $stagingDir) { $stagingDir = $env:AGENT_TEMPDIRECTORY }
            if (-not $stagingDir) {
                throw "Add-AzLocalPipelineStepSummary: TF_BUILD is true but neither BUILD_ARTIFACTSTAGINGDIRECTORY nor AGENT_TEMPDIRECTORY is set. This indicates a corrupt agent environment."
            }
            $summaryPath = Join-Path -Path $stagingDir -ChildPath $SummaryFileName
            $isFirstWrite = -not (Test-Path -LiteralPath $summaryPath)
            $Markdown | Out-File -FilePath $summaryPath -Encoding utf8 -Append
            if ($isFirstWrite) {
                Write-Host "##vso[task.uploadsummary]$summaryPath"
            }
            return $summaryPath
        }
        default {
            $localDir = $env:TEMP
            if (-not $localDir) { $localDir = [System.IO.Path]::GetTempPath() }
            $summaryPath = Join-Path -Path $localDir -ChildPath $SummaryFileName
            $Markdown | Out-File -FilePath $summaryPath -Encoding utf8 -Append
            Write-Host "[pipeline-step-summary] $summaryPath"
            return $summaryPath
        }
    }
}
