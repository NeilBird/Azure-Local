function Write-AzLocalPipelineNotice {
    <#
    .SYNOPSIS
        Emits a host-appropriate informational annotation.
    .DESCRIPTION
        Replaces the boilerplate:
          GitHub Actions : `Write-Host "::notice title=$Title::$Message"`
          Azure DevOps   : ADO has no "notice" severity in `task.logissue` (only
                           warning/error), so this maps to a plain `Write-Host`
                           line with a recognisable `[notice]` prefix so log
                           parsers can still find it.
          Local          : `Write-Host "[notice] $Title: $Message"`

        Use Write-AzLocalPipelineWarning when the message is a drift/staleness
        signal you want to surface in the Checks UI / annotation panel.
    .PARAMETER Title
        Short headline. On GitHub Actions this renders as the annotation
        title in the Checks UI panel.
    .PARAMETER Message
        Body of the annotation. Multi-line is allowed; GitHub Actions encodes
        newlines via `%0A` per their logging-command spec.
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
            Write-Host "::notice title=$Title::$encodedMessage"
        }
        'AzureDevOps' {
            Write-Host "[notice] $Title`: $Message"
        }
        default {
            Write-Host "[notice] $Title`: $Message"
        }
    }
}
