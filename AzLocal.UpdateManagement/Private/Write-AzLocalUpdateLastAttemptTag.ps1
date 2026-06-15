function Write-AzLocalUpdateLastAttemptTag {
    <#
    .SYNOPSIS
        Best-effort writer for the UpdateLastAttempt cluster tag.
    .DESCRIPTION
        Wraps Set-AzLocalClusterTagsMerge + Format-AzLocalUpdateLastAttemptTagValue
        so callers in Start-AzLocalClusterUpdate keep a single one-liner per
        outcome path. Failures are logged at Warning level and SWALLOWED
        (this is an informational/audit tag - never block the calling flow).

        Tag format documented on $script:UpdateLastAttemptTagName.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [datetime]$AttemptUtc,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Outcome,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Reason,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    try {
        $value = Format-AzLocalUpdateLastAttemptTagValue `
            -AttemptUtc $AttemptUtc `
            -Outcome $Outcome `
            -UpdateName $UpdateName `
            -Reason $Reason

        [void](Set-AzLocalClusterTagsMerge `
            -ClusterResourceId $ClusterResourceId `
            -Tags @{ $script:UpdateLastAttemptTagName = $value } `
            -ApiVersion $ApiVersion)

        Write-Log -Message "Set $($script:UpdateLastAttemptTagName) tag on '$ClusterName' to '$value'" -Level Verbose
    }
    catch {
        Write-Log -Message "Warning: failed to write $($script:UpdateLastAttemptTagName) tag on '$ClusterName': $($_.Exception.Message)" -Level Warning
    }
}
