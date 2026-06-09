function Write-AzLocalPipelineWarning {
    <#
    .SYNOPSIS
        Emits a host-appropriate warning annotation.
    .DESCRIPTION
        Replaces the boilerplate:
          GitHub Actions : `Write-Host "::warning title=$Title::$Message"`
                           which surfaces in the Checks UI annotation panel.
          Azure DevOps   : `Write-Host "##vso[task.logissue type=warning]$Message"`
                           which adds a yellow warning entry under the run
                           Issues count. ADO does not support a 'title' field
                           on logissue, so the title is prefixed into the message.
          Local          : plain Write-Warning so an interactive operator sees
                           it in yellow without the host-specific syntax.

        Multi-line messages are encoded the same way the prior inline
        run-block text did, preserving byte-identical emission.
    .PARAMETER Title
        Short headline. On GitHub Actions this renders as the annotation
        title in the Checks UI panel; on Azure DevOps it is prefixed into the
        message body (ADO has no title field on task.logissue).
    .PARAMETER Message
        Warning body. Multi-line is allowed; GitHub Actions encodes newlines
        via `%0A` per their logging-command spec.
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
            Write-Host "::warning title=$Title::$encodedMessage"
        }
        'AzureDevOps' {
            Write-Host "##vso[task.logissue type=warning]$Title`: $Message"
        }
        default {
            Write-Warning ("{0}: {1}" -f $Title, $Message)
        }
    }
}
