Function Test-AzLocalNotFoundError {
    <#
    .SYNOPSIS
        Determines whether an Azure error represents a genuine HTTP 404.
    .DESCRIPTION
        Uses exact ARM error codes and HTTP status values instead of broad message
        fragments that can misclassify subscription, authorization, or context errors.
    #>

    [OutputType([bool])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory = $false)]
        [string[]]$ErrorCode = @('ResourceNotFound')
    )

    $signals = @([string]$ErrorRecord.FullyQualifiedErrorId, [string]$ErrorRecord.Exception.Message)
    if ($ErrorRecord.PSObject.Properties['ErrorDetails'] -and $ErrorRecord.ErrorDetails -and
        $ErrorRecord.ErrorDetails.PSObject.Properties['Message']) {
        $signals += [string]$ErrorRecord.ErrorDetails.Message
    }
    if ($ErrorRecord.Exception.PSObject.Properties['Body'] -and $ErrorRecord.Exception.Body -and
        $ErrorRecord.Exception.Body.PSObject.Properties['Code']) {
        $signals += [string]$ErrorRecord.Exception.Body.Code
    }

    foreach ($code in $ErrorCode) {
        $codePattern = '(?i)(?<![A-Za-z0-9]){0}(?![A-Za-z0-9])' -f [regex]::Escape($code)
        if (@($signals | Where-Object { $_ -match $codePattern }).Count -gt 0) {
            return $true
        }
    }

    $statusOwners = @($ErrorRecord.Exception)
    if ($ErrorRecord.Exception.PSObject.Properties['Response'] -and $ErrorRecord.Exception.Response) {
        $statusOwners += $ErrorRecord.Exception.Response
    }
    foreach ($statusOwner in $statusOwners) {
        if ($statusOwner -and $statusOwner.PSObject.Properties['StatusCode']) {
            try {
                if ([int]$statusOwner.StatusCode -eq 404) { return $true }
            } catch {
                Write-Verbose "Unable to parse Azure response status code '$($statusOwner.StatusCode)'."
            }
        }
    }

    return $false
}