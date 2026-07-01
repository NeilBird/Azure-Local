function Write-AzLocalPipelineError {
    <#
    .SYNOPSIS
        Emits a host-appropriate error annotation.
    .DESCRIPTION
        Replaces the boilerplate:
          GitHub Actions : `Write-Host "::error title=$Title::$Message"`
                           which surfaces as a red entry in the Checks UI
                           annotation panel AND at the top of the run summary.
          Azure DevOps   : `Write-Host "##vso[task.logissue type=error]$Message"`
                           which adds a red error entry under the run Issues
                           count. ADO does not support a 'title' field on
                           logissue, so the title is prefixed into the message.
          Local          : plain Write-Error so an interactive operator sees
                           it in red without the host-specific syntax.

        This is the error-severity sibling of Write-AzLocalPipelineWarning /
        Write-AzLocalPipelineNotice. It only EMITS the annotation - it does NOT
        throw. Callers that want to fail the step throw a concise message after
        calling this so the operator gets both the rich annotation AND a
        non-zero exit.

        Multi-line messages are encoded the same way the sibling helpers do,
        preserving consistent emission.
    .PARAMETER Title
        Short headline. On GitHub Actions this renders as the annotation title
        in the Checks UI panel; on Azure DevOps it is prefixed into the message
        body (ADO has no title field on task.logissue).
    .PARAMETER Message
        Error body. Multi-line is allowed; GitHub Actions encodes newlines via
        `%0A` per their logging-command spec.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message
    )

    $pipelineHost = Get-AzLocalPipelineHost
    switch ($pipelineHost) {
        'GitHub' {
            $encodedMessage = $Message -replace "`r`n", '%0A' -replace "`n", '%0A' -replace "`r", '%0A'
            Write-Host "::error title=$Title::$encodedMessage"
        }
        'AzureDevOps' {
            Write-Host "##vso[task.logissue type=error]$Title`: $Message"
        }
        default {
            # Non-terminating by contract: this helper only EMITS the annotation.
            # A bare Write-Error becomes TERMINATING under $ErrorActionPreference='Stop'
            # (which the pipeline inline scripts set), which would abort the caller
            # BEFORE it can write the run-summary block / step output and throw its
            # own concise message. Force -ErrorAction Continue so it never throws.
            Write-Error ("{0}: {1}" -f $Title, $Message) -ErrorAction Continue
        }
    }
}
