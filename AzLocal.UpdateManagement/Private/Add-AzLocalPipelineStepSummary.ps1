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
    $summaryFile = $null
    $isFirstWrite = $false
    switch ($pipelineHost) {
        'GitHub' {
            $summaryFile = $env:GITHUB_STEP_SUMMARY
            if (-not $summaryFile) {
                throw "Add-AzLocalPipelineStepSummary: GITHUB_ACTIONS is true but GITHUB_STEP_SUMMARY env var is not set. This indicates a corrupt runner environment."
            }
        }
        'AzureDevOps' {
            $stagingDir = $env:BUILD_ARTIFACTSTAGINGDIRECTORY
            if (-not $stagingDir) { $stagingDir = $env:AGENT_TEMPDIRECTORY }
            if (-not $stagingDir) {
                throw "Add-AzLocalPipelineStepSummary: TF_BUILD is true but neither BUILD_ARTIFACTSTAGINGDIRECTORY nor AGENT_TEMPDIRECTORY is set. This indicates a corrupt agent environment."
            }
            $summaryFile = Join-Path -Path $stagingDir -ChildPath $SummaryFileName
            $isFirstWrite = -not (Test-Path -LiteralPath $summaryFile)
        }
        default {
            $localDir = $env:TEMP
            if (-not $localDir) { $localDir = [System.IO.Path]::GetTempPath() }
            $summaryFile = Join-Path -Path $localDir -ChildPath $SummaryFileName
        }
    }

    $maxSummaryBytes = (Get-AzLocalFleetSettings).MaxSummaryBytes
    $currentBytes = if (Test-Path -LiteralPath $summaryFile -PathType Leaf) {
        (Get-Item -LiteralPath $summaryFile).Length
    }
    else { 0 }
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $appendBytes = $utf8.GetByteCount($Markdown + [Environment]::NewLine)
    if (($currentBytes + $appendBytes) -gt $maxSummaryBytes) {
        $skippedBytes = $appendBytes
        $Markdown = '> **Summary size limit reached.** Additional detail was omitted from this pipeline summary. Download the CSV, JSON, JUnit, and HTML report artifacts for the complete results.'
        $appendBytes = $utf8.GetByteCount($Markdown + [Environment]::NewLine)
        Write-Warning ("Add-AzLocalPipelineStepSummary: skipped {0:N0} UTF-8 bytes because appending them would exceed the configured {1:N0}-byte summary limit." -f $skippedBytes, $maxSummaryBytes)
        if (($currentBytes + $appendBytes) -gt $maxSummaryBytes) {
            return $summaryFile
        }
    }

    # -WhatIf:$false: a step summary is diagnostic reporting, not a state
    # change to the managed system. It must always be emitted even when an
    # upstream cmdlet runs under -WhatIf.
    $Markdown | Out-File -FilePath $summaryFile -Encoding utf8 -Append -WhatIf:$false
    if ($pipelineHost -eq 'AzureDevOps' -and $isFirstWrite) {
        Write-Host "##vso[task.uploadsummary]$summaryFile"
    }
    elseif ($pipelineHost -eq 'Local') {
        Write-Host "[pipeline-step-summary] $summaryFile"
    }
    return $summaryFile
}
