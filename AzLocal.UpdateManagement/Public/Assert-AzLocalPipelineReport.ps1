function Assert-AzLocalPipelineReport {
    <#
    .SYNOPSIS
        Fails the pipeline step with a meaningful run-summary message when the
        expected diagnostic report file(s) were not produced.

    .DESCRIPTION
        The AzLocal.UpdateManagement pipelines write their JUnit / CSV / JSON
        reports to a working directory (e.g. ./reports or ./artifacts) which a
        later `dorny/test-reporter` (GitHub) or `PublishTestResults` (Azure
        DevOps) step then publishes. When the collect step fails or produces no
        output (most commonly because of an upstream Azure login / subscription
        failure), the publish step emits the misleading error
        "No test report files were found" - a symptom, not the cause.

        This cmdlet is the meaningful gate placed BETWEEN the collect step and
        the publish step:
          1. Expands each -Path glob and gathers the matching files.
          2. When -RequireNonEmpty (the default) is set, ignores zero-byte files.
          3. If no qualifying file exists:
               - emits a red `::error` / `##vso[task.logissue type=error]`
                 annotation via Write-AzLocalPipelineError,
               - writes a rich explanation to the run summary via
                 Add-AzLocalPipelineStepSummary (so the operator does NOT have
                 to expand the step logs),
               - throws a concise terminating error so the step exits non-zero
                 BEFORE the confusing publish-step error can fire.
          4. Otherwise it writes a one-line confirmation to the summary and
             (with -PassThru) returns the matching file paths.

    .PARAMETER Path
        One or more file paths or globs that the collect step is expected to
        have produced (e.g. './reports/*.xml'). At least one qualifying file
        across all paths must exist for the step to pass.

    .PARAMETER ProducingStepName
        Friendly name of the step that was supposed to produce the reports,
        used in the summary text (e.g. 'Collect Fleet Health Status'). Defaults
        to 'the collect step'.

    .PARAMETER AllowEmpty
        By default a matching file must be larger than zero bytes to count. Set
        -AllowEmpty to accept zero-byte files as well.

    .PARAMETER SummaryFileName
        Forwarded to Add-AzLocalPipelineStepSummary. Defaults to
        'azlocal-report-check.md'. Ignored on GitHub Actions.

    .PARAMETER PassThru
        When set, returns the array of matching file paths on success.

    .OUTPUTS
        Nothing by default. With -PassThru, returns [string[]] of matching file
        paths. Throws a terminating error when no qualifying file exists.

    .EXAMPLE
        Assert-AzLocalPipelineReport -Path './reports/*.xml' -ProducingStepName 'Collect Fleet Health Status'

    .EXAMPLE
        $files = Assert-AzLocalPipelineReport -Path './artifacts/assess-readiness.xml' -PassThru
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ProducingStepName = 'the collect step',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-report-check.md',

        # When present, zero-byte matches also count as valid reports. Off by
        # default so an empty (0-byte) report file is treated as "no report".
        [Parameter()]
        [switch]$AllowEmpty,

        [Parameter()]
        [switch]$PassThru
    )

    # 1. Expand every glob and collect matching FILES.
    $matched = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Path) {
        $items = Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            if (-not $AllowEmpty -and $item.Length -le 0) { continue }
            $matched.Add($item.FullName)
        }
    }
    $matchedFiles = $matched.ToArray()

    # 2. Failure path: nothing produced -> meaningful error + run-summary block + throw.
    if ($matchedFiles.Count -eq 0) {
        $pathList = ($Path | ForEach-Object { "``$_``" }) -join ', '
        $emptyNote = if ($AllowEmpty) { '' } else { ' (non-empty)' }

        $summary = @"
## :x: No diagnostic reports were produced

$ProducingStepName produced no$emptyNote report file(s) matching: $pathList

The publish step that follows would normally report "No test report files were
found" - but that is a **symptom**, not the cause. The collect step above did
not write any output, which almost always means an **upstream failure** (most
commonly the Azure login / subscription-access step). Check the earlier steps in
this job for the first red step and fix that; the reports and their published
results will follow.
"@

        Write-AzLocalPipelineError `
            -Title 'No diagnostic reports were produced' `
            -Message ("$ProducingStepName produced no$emptyNote report files matching $pathList. " +
                'This is caused by an upstream failure (commonly Azure login / subscription access), not the publish step. See the run summary and check the first failing step above.')

        [void](Add-AzLocalPipelineStepSummary -Markdown $summary -SummaryFileName $SummaryFileName)

        throw "Assert-AzLocalPipelineReport: no report files produced by '$ProducingStepName' (expected: $($Path -join ', ')). See the run summary for details."
    }

    # 3. Success path.
    Write-Host "Diagnostic reports verified: $($matchedFiles.Count) file(s) produced by '$ProducingStepName'."
    $okSummary = "_Diagnostic reports verified: **$($matchedFiles.Count)** file(s) produced by ${ProducingStepName}._`n"
    [void](Add-AzLocalPipelineStepSummary -Markdown $okSummary -SummaryFileName $SummaryFileName)

    if ($PassThru) { return $matchedFiles }
}
