function Set-AzLocalPipelineOutput {
    <#
    .SYNOPSIS
        Writes a named output value in the host-appropriate format.
    .DESCRIPTION
        Replaces the boilerplate:
          GitHub Actions : `"NAME=VALUE" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append`
          Azure DevOps   : `Write-Host "##vso[task.setvariable variable=NAME;isOutput=$bool]VALUE"`
          Local          : `Write-Host "[output] NAME=VALUE"` (visibility only; no side effect)

        The host is detected via Get-AzLocalPipelineHost. Callers do not branch.

        IMPORTANT: byte-for-byte the same emission as the prior inline run-block
        text, including the exact env-var file used (GITHUB_OUTPUT) and the
        exact logging-command syntax (##vso[task.setvariable...]).
    .PARAMETER Name
        Output variable name (matches the existing pipeline conventions, e.g.
        READY_COUNT, RESOLVED_UPDATE_RING, subscription_count).
    .PARAMETER Value
        Output value. $null becomes empty string. Multi-line values are
        forbidden for GitHub Actions (their parser breaks on embedded newlines
        without a heredoc) - throws so the caller catches it in tests.
    .PARAMETER CrossJob
        For Azure DevOps only: when set, emits `isOutput=true` so the variable
        is consumable by a downstream job via the `dependencies.<job>.outputs`
        map. GitHub Actions does not have this distinction - every value
        written to GITHUB_OUTPUT is consumable cross-job via
        `needs.<job>.outputs.<name>`. Default is $false (step-scoped on ADO).
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value,

        [switch]$CrossJob
    )

    if ($null -eq $Value) { $Value = '' }
    if ($Value -match "`r|`n") {
        throw "Set-AzLocalPipelineOutput: multi-line values are not supported (Name='$Name'). Use Add-AzLocalPipelineStepSummary for markdown blocks."
    }

    $pipelineHost = Get-AzLocalPipelineHost
    switch ($pipelineHost) {
        'GitHub' {
            $githubOutput = $env:GITHUB_OUTPUT
            if (-not $githubOutput) {
                throw "Set-AzLocalPipelineOutput: GITHUB_ACTIONS is true but GITHUB_OUTPUT env var is not set. This indicates a corrupt runner environment."
            }
            "$Name=$Value" | Out-File -FilePath $githubOutput -Encoding utf8 -Append
        }
        'AzureDevOps' {
            $isOutput = if ($CrossJob) { 'true' } else { 'false' }
            Write-Host "##vso[task.setvariable variable=$Name;isOutput=$isOutput]$Value"
        }
        default {
            Write-Host "[pipeline-output] $Name=$Value"
        }
    }
}
