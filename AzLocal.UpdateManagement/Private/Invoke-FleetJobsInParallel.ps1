function Invoke-FleetJobsInParallel {
    <#
    .SYNOPSIS
        Dispatches a scriptblock across a set of input items using Start-Job
        with a throttled batch model. Intended as the single parallelisation
        primitive used by fleet-wide functions in this module.
    .DESCRIPTION
        By default, items are divided into at most -ThrottleLimit batches. When
        -MaxItemsPerJob is supplied, fixed-size batches are created and run in
        waves with at most -ThrottleLimit jobs active at once. Each batch runs
        as one Start-Job so that per-job startup cost stays low for large
        fleets. When -ThrottleLimit is 1 the scriptblock is invoked inline
        (no Start-Job overhead) which is the fast path used by unit tests.

        The scriptblock receives positional arguments in the order:
            [object[]]$Batch, <ArgumentList...>, [string]$ModulePath

        The trailing $ModulePath is always appended so jobs can re-import
        the module with 'Import-Module $ModulePath -Force' before calling
        any exported function.
    .PARAMETER InputItems
        The collection of items to shard across batches. Empty collections
        return an empty [object[]] result.
    .PARAMETER ScriptBlock
        The scriptblock executed once per batch.
    .PARAMETER ThrottleLimit
        Maximum number of concurrent Start-Job instances. Defaults to 4.
        ThrottleLimit=1 triggers the inline fast-path.
    .PARAMETER ArgumentList
        Additional positional arguments forwarded to the scriptblock after
        $Batch and before the trailing $ModulePath.
    .PARAMETER MaxItemsPerJob
        Optional maximum number of input items assigned to one job. When this
        creates more jobs than ThrottleLimit, jobs run in bounded waves.
    .PARAMETER JobTimeoutSeconds
        Per-job maximum wall-clock wait. Defaults to 30 minutes. Jobs that
        exceed this are stopped and reported as Failed with a timeout error.
    .PARAMETER ActivityName
        Prefix used to name the jobs (helpful when debugging with Get-Job).
    .OUTPUTS
        [object[]] of [PSCustomObject]@{
            BatchIndex; Items; Failed; Output; Error; DurationSeconds
        }
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$InputItems,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 32)]
        [int]$ThrottleLimit = 4,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [object[]]$ArgumentList = @(),

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10000)]
        [Nullable[int]]$MaxItemsPerJob,

        [Parameter(Mandatory = $false)]
        [ValidateRange(30, 86400)]
        [int]$JobTimeoutSeconds = 1800,

        [Parameter(Mandatory = $false)]
        [string]$ActivityName = 'FleetJob'
    )

    $results = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $InputItems -or $InputItems.Count -eq 0) {
        return , $results.ToArray()
    }

    # Resolve the ROOT module manifest path so child Start-Job runspaces can
    # Import-Module the WHOLE module (root + every nested helper) rather than
    # this single helper file. See Get-AzLocalModuleRootManifestPath for the
    # full rationale. Until this fix, $PSCommandPath was passed verbatim and
    # resolved to this .ps1 inside Public/ or Private/ - Import-Module then
    # loaded only that one file as a transient module named
    # 'Invoke-FleetJobsInParallel' and every '& $mod { ... }' against module-
    # private helpers failed at runtime.
    $modulePath = Get-AzLocalModuleRootManifestPath -CallerScriptPath $PSCommandPath
    if (-not $modulePath) {
        # Last-resort fallback - keep the inline (ThrottleLimit=1) path
        # working even when the helper can't locate the root manifest. The
        # parallel path will still fail loudly inside the child runspace.
        $modulePath = $PSCommandPath
    }

    $batchSize = if ($null -ne $MaxItemsPerJob) {
        [int]$MaxItemsPerJob
    }
    else {
        [int][Math]::Max(1, [Math]::Ceiling($InputItems.Count / [double]$ThrottleLimit))
    }
    $batches = [System.Collections.Generic.List[object[]]]::new()
    for ($i = 0; $i -lt $InputItems.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $InputItems.Count - 1)
        [void]$batches.Add(@($InputItems[$i..$end]))
    }

    if ($ThrottleLimit -le 1) {
        # Inline fast-path: run each batch in-process, no Start-Job.
        for ($batchIndex = 0; $batchIndex -lt $batches.Count; $batchIndex++) {
            $batch = $batches[$batchIndex]
            $allArgs = @(, [object[]]$batch) + $ArgumentList + @($modulePath)
            $started = Get-Date
            try {
                $out = & $ScriptBlock @allArgs
                [void]$results.Add([PSCustomObject]@{
                    BatchIndex      = $batchIndex
                    Items           = $batch
                    Failed          = $false
                    Output          = $out
                    Error           = $null
                    DurationSeconds = ((Get-Date) - $started).TotalSeconds
                })
            }
            catch {
                [void]$results.Add([PSCustomObject]@{
                    BatchIndex      = $batchIndex
                    Items           = $batch
                    Failed          = $true
                    Output          = $null
                    Error           = $_.Exception.Message
                    DurationSeconds = ((Get-Date) - $started).TotalSeconds
                })
            }
        }
        return , $results.ToArray()
    }

    # Parallel path: start at most ThrottleLimit jobs per wave. This keeps the
    # concurrency bound independent from the total number of fixed-size jobs.
    for ($waveStart = 0; $waveStart -lt $batches.Count; $waveStart += $ThrottleLimit) {
        $waveEnd = [Math]::Min($waveStart + $ThrottleLimit - 1, $batches.Count - 1)
        $jobs = @()
        for ($batchIndex = $waveStart; $batchIndex -le $waveEnd; $batchIndex++) {
            $jobArgs = @(, [object[]]$batches[$batchIndex]) + $ArgumentList + @($modulePath)
            $job = Start-Job -Name "$ActivityName-$batchIndex" -ScriptBlock $ScriptBlock -ArgumentList $jobArgs
            $jobs += [PSCustomObject]@{ BatchIndex = $batchIndex; Batch = $batches[$batchIndex]; Job = $job; Start = Get-Date }
        }

        foreach ($jobRecord in $jobs) {
            $elapsed = ((Get-Date) - $jobRecord.Start).TotalSeconds
            $remaining = [int][Math]::Max(1, $JobTimeoutSeconds - $elapsed)
            $finished = Wait-Job -Job $jobRecord.Job -Timeout $remaining
            if (-not $finished) {
                try { Stop-Job -Job $jobRecord.Job -ErrorAction SilentlyContinue } catch { Write-Verbose "Stop-Job failed: $($_.Exception.Message)" }
                [void]$results.Add([PSCustomObject]@{
                    BatchIndex      = $jobRecord.BatchIndex
                    Items           = $jobRecord.Batch
                    Failed          = $true
                    Output          = $null
                    Error           = "Job timed out after $JobTimeoutSeconds seconds"
                    DurationSeconds = ((Get-Date) - $jobRecord.Start).TotalSeconds
                })
            }
            else {
                try {
                    $out = Receive-Job -Job $jobRecord.Job -ErrorAction Stop
                    [void]$results.Add([PSCustomObject]@{
                        BatchIndex      = $jobRecord.BatchIndex
                        Items           = $jobRecord.Batch
                        Failed          = $false
                        Output          = $out
                        Error           = $null
                        DurationSeconds = ((Get-Date) - $jobRecord.Start).TotalSeconds
                    })
                }
                catch {
                    [void]$results.Add([PSCustomObject]@{
                        BatchIndex      = $jobRecord.BatchIndex
                        Items           = $jobRecord.Batch
                        Failed          = $true
                        Output          = $null
                        Error           = $_.Exception.Message
                        DurationSeconds = ((Get-Date) - $jobRecord.Start).TotalSeconds
                    })
                }
            }
            Remove-Job -Job $jobRecord.Job -Force -ErrorAction SilentlyContinue
        }
    }

    return , $results.ToArray()
}
