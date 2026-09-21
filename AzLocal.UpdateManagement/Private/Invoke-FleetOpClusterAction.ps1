function Invoke-FleetOpClusterAction {
    <#
    .SYNOPSIS
        Invokes a single fleet operation against one cluster with bounded
        retries and mutates the supplied ClusterState object in place.
    .DESCRIPTION
        Centralises the "attempt -> catch -> backoff -> retry" pattern used
        by the fleet orchestration functions. Mutates the ClusterState
        PSCustomObject so that callers that accumulate state across jobs
        can see the final Status/Attempts/LastError/Result.

        On success: Status='Succeeded', LastError=$null, Result=<operation output>.
        On persistent failure after -MaxRetries retries: Status='Failed',
        LastError=<last exception message>.
    .PARAMETER ClusterState
        A PSCustomObject with at least ResourceId and these writable
        properties: Status, Attempts, LastAttempt, LastError, Result.
    .PARAMETER Operation
        One of ApplyUpdate, CheckReadiness, GetStatus.
    .PARAMETER MaxRetries
        Number of additional retries after the first attempt. 0 means a
        single attempt with no retries.
    .PARAMETER RetryDelaySeconds
        Base delay in seconds. Actual delay uses exponential backoff
        (base * 2^(attempt-1)) capped at 600 seconds.
    .PARAMETER OperationParameters
        Optional hashtable of extra parameters splatted to the underlying
        cmdlet.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $ClusterState,

        [Parameter(Mandatory = $true)]
        [ValidateSet('ApplyUpdate', 'CheckReadiness', 'GetStatus')]
        [string]$Operation,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 10)]
        [int]$MaxRetries = 2,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 600)]
        [int]$RetryDelaySeconds = 10,

        [Parameter(Mandatory = $false)]
        [hashtable]$OperationParameters = @{}
    )

    $maxAttempts = $MaxRetries + 1
    $attempts = 0
    $lastError = $null
    $result = $null
    $succeeded = $false

    while ($attempts -lt $maxAttempts) {
        $attempts++
        $ClusterState.Attempts = $attempts
        $ClusterState.LastAttempt = Get-Date
        try {
            switch ($Operation) {
                'GetStatus' {
                    $result = Get-AzLocalUpdateSummary -ClusterResourceId $ClusterState.ResourceId @OperationParameters
                }
                'CheckReadiness' {
                    # Note: Get-AzLocalClusterUpdateReadiness only exposes the plural
                    # -ClusterResourceIds parameter, so wrap the single ID in an array.
                    $result = Get-AzLocalClusterUpdateReadiness -ClusterResourceIds @($ClusterState.ResourceId) @OperationParameters
                }
                'ApplyUpdate' {
                    # Start-AzLocalClusterUpdate also only exposes -ClusterResourceIds.
                    # It returns PSCustomObject[] (may be single item for one cluster);
                    # treat Status != 'UpdateStarted' as a retryable failure so callers
                    # get consistent 'Succeeded'/'Failed' semantics via this helper.
                    $applyParams = @{
                        ClusterResourceIds = @($ClusterState.ResourceId)
                    }
                    if (-not $OperationParameters.ContainsKey('Force')) {
                        $applyParams['Force'] = $true
                    }
                    foreach ($k in $OperationParameters.Keys) {
                        $applyParams[$k] = $OperationParameters[$k]
                    }
                    $applyParams['PassThru'] = $true
                    $applyResult = Start-AzLocalClusterUpdate @applyParams
                    # Normalize to the first (and usually only) result for a single cluster
                    $primary = if ($applyResult -is [System.Collections.IEnumerable] -and -not ($applyResult -is [string])) {
                        @($applyResult) | Select-Object -First 1
                    } else { $applyResult }
                    if (-not $primary) {
                        throw "Start-AzLocalClusterUpdate returned no result for cluster '$($ClusterState.ResourceId)'"
                    }
                    if ($primary.PSObject.Properties['Status'] -and $primary.Status -ne 'UpdateStarted') {
                        $msg = if ($primary.PSObject.Properties['Message']) { $primary.Message } else { 'no details' }
                        throw "Update not started (Status=$($primary.Status)): $msg"
                    }
                    $result = $primary
                }
            }
            $succeeded = $true
            $lastError = $null
            break
        }
        catch {
            $lastError = $_.Exception.Message
            if ($attempts -lt $maxAttempts -and $RetryDelaySeconds -gt 0) {
                $delay = [int][Math]::Min(600, $RetryDelaySeconds * [Math]::Pow(2, $attempts - 1))
                Start-Sleep -Seconds $delay
            }
        }
    }

    $ClusterState.Result = $result
    $ClusterState.LastError = $lastError
    $ClusterState.Status = if ($succeeded) { 'Succeeded' } else { 'Failed' }
}
