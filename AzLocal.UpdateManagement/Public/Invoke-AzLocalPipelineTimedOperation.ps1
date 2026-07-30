function Invoke-AzLocalPipelineTimedOperation {
    <#
    .SYNOPSIS
        Executes one pipeline operation and records its wall-clock timing.
    .DESCRIPTION
        Maintains a durable JSON timing report shared by separate PowerShell
        tasks in one pipeline run. The report is written before execution and
        updated in a finally block, so failed operations remain visible and an
        abruptly terminated process leaves a valid Running record.

        Step numbers are ordering keys rather than contiguous indexes. Use
        10, 20, 30, and so on to leave room for future operations.
    .PARAMETER PipelineName
        Stable pipeline identifier, such as monitor-updates.
    .PARAMETER StepNumber
        Loose ordering number for this operation.
    .PARAMETER StepName
        Human-readable operation name.
    .PARAMETER ScriptBlock
        Workload to execute. Output and errors retain their normal behavior.
    .PARAMETER Enabled
        Controls timing capture. When false, ScriptBlock executes directly
        without creating a diagnostics file.
    .PARAMETER Path
        Timing report path. Defaults to ./diagnostics/pipeline-timings.json.
    .PARAMETER PipelineVersion
        Pipeline template version. Defaults to GENERATED_AGAINST_MODULE_VERSION.
    .OUTPUTS
        The unmodified output emitted by ScriptBlock.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[A-Za-z0-9._-]{1,100}$')]
        [string]$PipelineName,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 9990)]
        [int]$StepNumber,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [ValidateLength(1, 200)]
        [string]$StepName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [bool]$Enabled = $true,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Path = $(
            if ($env:AZLOCAL_PIPELINE_TIMING_PATH) { $env:AZLOCAL_PIPELINE_TIMING_PATH }
            else { Join-Path -Path 'diagnostics' -ChildPath 'pipeline-timings.json' }
        ),

        [Parameter()]
        [AllowEmptyString()]
        [string]$PipelineVersion = $env:GENERATED_AGAINST_MODULE_VERSION
    )

    if (-not $Enabled) {
        return (& $ScriptBlock)
    }

    $startedUtc = [datetime]::UtcNow
    $invocationId = [guid]::NewGuid().ToString('D')
    $module = Get-Module AzLocal.UpdateManagement | Sort-Object Version -Descending | Select-Object -First 1
    $moduleVersion = if ($module) { [string]$module.Version } else { '' }
    $platform = if ($env:GITHUB_ACTIONS -eq 'true') { 'GitHubActions' } elseif ($env:TF_BUILD -eq 'True') { 'AzureDevOps' } else { 'Local' }
    $runId = if ($platform -eq 'GitHubActions') { [string]$env:GITHUB_RUN_ID } elseif ($platform -eq 'AzureDevOps') { [string]$env:BUILD_BUILDID } else { '' }
    $runAttempt = if ($platform -eq 'GitHubActions') { [string]$env:GITHUB_RUN_ATTEMPT } elseif ($platform -eq 'AzureDevOps') { [string]$env:SYSTEM_JOBATTEMPT } else { '' }

    $operation = [ordered]@{
        stepNumber  = $StepNumber
        stepName    = $StepName
        invocationId = $invocationId
        startedUtc  = $startedUtc.ToString('o')
        endedUtc    = $null
        durationMs  = $null
        status      = 'Running'
        errorType   = $null
        errorMessage = $null
    }

    $writeReport = {
        param([System.Collections.IDictionary]$CurrentOperation)

        try {
            $parent = Split-Path -Parent $Path
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force -WhatIf:$false | Out-Null
            }

            $operations = [System.Collections.Generic.List[object]]::new()
            $reportStartedUtc = $startedUtc
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                try {
                    $existing = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    if ($existing.PSObject.Properties['startedUtc'] -and $existing.startedUtc) {
                        [datetime]$parsedStart = [datetime]::MinValue
                        if ([datetime]::TryParse([string]$existing.startedUtc, [ref]$parsedStart)) {
                            $reportStartedUtc = $parsedStart.ToUniversalTime()
                        }
                    }
                    foreach ($item in @($existing.operations)) {
                        if ($item -and [string]$item.invocationId -ne $invocationId) { [void]$operations.Add($item) }
                    }
                }
                catch {
                    Write-Warning ("Pipeline timing report could not be read and will be rebuilt: {0}" -f $_.Exception.Message)
                }
            }
            [void]$operations.Add([pscustomobject]$CurrentOperation)
            $orderedOperations = @($operations.ToArray() | Sort-Object stepNumber, startedUtc)
            $completed = @($orderedOperations | Where-Object { $_.status -ne 'Running' })
            $failed = @($orderedOperations | Where-Object { $_.status -eq 'Failed' })
            $nowUtc = [datetime]::UtcNow
            $reportStatus = if ($failed.Count -gt 0) { 'Failed' } elseif ($completed.Count -eq $orderedOperations.Count) { 'Succeeded' } else { 'Running' }
            $report = [ordered]@{
                schemaVersion = 1
                pipelineName = $PipelineName
                pipelineVersion = [string]$PipelineVersion
                platform = $platform
                runId = $runId
                runAttempt = $runAttempt
                moduleVersion = $moduleVersion
                powerShellVersion = [string]$PSVersionTable.PSVersion
                powerShellEdition = [string]$PSVersionTable.PSEdition
                startedUtc = $reportStartedUtc.ToString('o')
                lastUpdatedUtc = $nowUtc.ToString('o')
                wallClockDurationMs = [int64][math]::Round(($nowUtc - $reportStartedUtc).TotalMilliseconds, 0)
                status = $reportStatus
                operationCount = $orderedOperations.Count
                operations = $orderedOperations
            }

            $json = $report | ConvertTo-Json -Depth 8
            $tempPath = '{0}.{1}.tmp' -f $Path, $invocationId
            Write-Utf8NoBomFile -Path $tempPath -Content $json
            Move-Item -LiteralPath $tempPath -Destination $Path -Force -WhatIf:$false
        }
        catch {
            Write-Warning ("Pipeline timing telemetry write failed for step {0} '{1}': {2}" -f $StepNumber, $StepName, $_.Exception.Message)
        }
    }

    & $writeReport $operation
    Write-Verbose ("Pipeline timing started: pipeline='{0}', step={1}, name='{2}', invocationId={3}." -f $PipelineName, $StepNumber, $StepName, $invocationId)

    try {
        & $ScriptBlock
        $operation.status = 'Succeeded'
    }
    catch {
        $operation.status = 'Failed'
        $operation.errorType = $_.Exception.GetType().FullName
        $operation.errorMessage = ConvertTo-ScrubbedCliOutput -Text $_.Exception.Message
        throw
    }
    finally {
        $endedUtc = [datetime]::UtcNow
        $operation.endedUtc = $endedUtc.ToString('o')
        $operation.durationMs = [int64][math]::Round(($endedUtc - $startedUtc).TotalMilliseconds, 0)
        & $writeReport $operation
        Write-Verbose ("Pipeline timing completed: pipeline='{0}', step={1}, name='{2}', status={3}, durationMs={4}." -f $PipelineName, $StepNumber, $StepName, $operation.status, $operation.durationMs)
    }
}