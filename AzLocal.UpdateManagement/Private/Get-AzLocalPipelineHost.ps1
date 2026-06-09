function Get-AzLocalPipelineHost {
    <#
    .SYNOPSIS
        Detects which CI/CD host the current process is running on.
    .DESCRIPTION
        Inspects well-known CI/CD environment variables to identify the host:
          - GitHub Actions sets $env:GITHUB_ACTIONS to 'true' on every step.
          - Azure DevOps sets $env:TF_BUILD to 'True' on every task.
          - Anything else is treated as 'Local' (laptop / Pester / interactive shell).

        Used by the pipeline output helpers (Set-AzLocalPipelineOutput,
        Add-AzLocalPipelineStepSummary, Write-AzLocalPipelineNotice,
        Write-AzLocalPipelineWarning) to route emissions to the right surface
        without callers having to branch.

        Returns 'GitHub', 'AzureDevOps', or 'Local'. Never throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($env:GITHUB_ACTIONS -eq 'true') { return 'GitHub' }
    if ($env:TF_BUILD -and ($env:TF_BUILD -ieq 'true')) { return 'AzureDevOps' }
    return 'Local'
}
