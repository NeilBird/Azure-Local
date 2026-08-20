function Invoke-AzLocalReadinessGatedClusterUpdate {
    <#
    .SYNOPSIS
        Loads the readiness CSV produced by Export-AzLocalClusterReadinessGateReport,
        applies updates to the gated cluster set via Start-AzLocalClusterUpdate,
        emits per-status step outputs (SUCCEEDED/SKIPPED/FAILED/HEALTH_BLOCKED/
        SCHEDULE_BLOCKED/SIDELOADED_BLOCKED/EXCLUDED_BY_TAG), and persists
        per-cluster apply results to apply-results.json.
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Replaces the ~110-line inline `run:`
        block that lived in both Step.7_apply-updates.yml pipelines.

        Behaviour matches the prior inline block byte-for-byte:
          - Loads readiness-report.csv, validates the ClusterResourceId
            column exists (introduced in v0.7.62), extracts rows with
            ReadyForUpdate='True' AND non-empty ClusterResourceId.
          - When the ready set is empty: emits zero counts and exits cleanly
            (matches the prior 'nothing to apply' short-circuit).
          - Otherwise: invokes Start-AzLocalClusterUpdate with the same
            parameter shape the inline block built (-ClusterResourceIds,
            -Force, -LogFolderPath, -ExportResultsPath, optional -UpdateName,
            optional -AllowedUpdateVersions, optional -WhatIf for dry runs).
          - Counts results into the seven status buckets and writes them as
            cross-job step outputs.
          - Persists per-cluster results to apply-results.json (selected
            columns: ClusterName, Status, UpdateName, Duration, Message).
          - On Azure DevOps: emits the same per-bucket warning/error
            task.logissue lines the inline block did (preserving CI behaviour).
    .PARAMETER ReadinessCsvPath
        Path to readiness-report.csv produced by the check-readiness job.
    .PARAMETER UpdateRing
        UpdateRing label used in console output (e.g. 'Wave1'). Cosmetic only;
        the actual apply scope comes from ReadinessCsvPath.
    .PARAMETER UpdateName
        Optional specific update name to apply (forwarded to
        Start-AzLocalClusterUpdate -UpdateName). Empty/whitespace = the
        cmdlet picks the latest Ready update on each cluster.
    .PARAMETER DryRun
        Switch. When set, Start-AzLocalClusterUpdate -WhatIf is invoked so no
        updates actually start.
    .PARAMETER PrepareOnly
        Switch. When set, forwards -PrepareOnly so update content is downloaded,
        validated, extracted, and health checked without starting installation.
    .PARAMETER PrepareOnlyFirst
        Switch. When set, forwards -PrepareOnlyFirst so Ready updates are prepared
        first and ReadyToInstall updates are installed on a later eligible firing.
    .PARAMETER AllowPrepareOnlyOutsideOfUpdateStartWindow
        Boolean forwarded to Start-AzLocalClusterUpdate. True allows out-of-window
        preparation; false enforces UpdateStartWindow while preparing.
    .PARAMETER AllowedUpdateVersions
        String[] or single ';'-joined string. Allow-list resolved from
        apply-updates-schedule.yml schema-v2 'allowedUpdateVersions'. Empty =
        no allow-list applied.
    .PARAMETER OutputDirectory
        Directory where logs / update-results.xml / apply-results.json are
        written. Defaults to the readiness CSV's parent directory.
    .PARAMETER JUnitFileName
        JUnit XML filename. Default 'update-results.xml'.
    .PARAMETER ApplyResultsJsonFileName
        Per-cluster JSON filename consumed by Add-AzLocalApplyUpdatesStepSummary.
        Default 'apply-results.json'.
    .PARAMETER PassThru
        Returns PSCustomObject with all seven counters + Results +
        JUnitPath + ApplyResultsJsonPath + ReadyResourceIds (the ARM IDs
        actually handed to Start-AzLocalClusterUpdate).
    .PARAMETER ForceImmediateUpdate
        v0.8.79 break-glass override. When set, forwards `-IgnoreScheduleTags` to
        Start-AzLocalClusterUpdate so the per-cluster Step 3c maintenance-schedule
        gate (UpdateStartWindow / UpdateExclusionsWindow tags) is BYPASSED for every
        cluster in the readiness CSV. Intended for emergency / out-of-window patching
        driven by an on-call operator. The bundled apply-updates.yml pipelines only
        expose this through `workflow_dispatch` (GHA) and `Manual` queue (ADO); schedule-
        triggered runs never honour it (guarded at the YAML layer). A prominent banner
        is logged at the start of the apply.
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.5 (Step.6 thin-YAML port)
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessCsvPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$UpdateRing = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$UpdateName = '',

        [switch]$DryRun,

        [switch]$PrepareOnly,

        [switch]$PrepareOnlyFirst,

        [Parameter(Mandatory = $false)]
        [bool]$AllowPrepareOnlyOutsideOfUpdateStartWindow = $true,

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [object]$AllowedUpdateVersions,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$OutputDirectory = '',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$JUnitFileName = 'update-results.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ApplyResultsJsonFileName = 'apply-results.json',

        [switch]$PassThru,

        [switch]$ForceImmediateUpdate
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

    # Normalise AllowedUpdateVersions into a [string[]] (accept string,
    # string[], or null/empty).
    [string[]]$allowList = @()
    if ($AllowedUpdateVersions) {
        if ($AllowedUpdateVersions -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($AllowedUpdateVersions)) {
                $allowList = @(($AllowedUpdateVersions -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            }
        }
        else {
            $allowList = @($AllowedUpdateVersions | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        }
    }

    # OutputDirectory default: parent of the readiness CSV.
    if (-not $OutputDirectory) {
        $OutputDirectory = Split-Path -Path $ReadinessCsvPath -Parent
        if (-not $OutputDirectory) { $OutputDirectory = '.' }
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $junitPath = Join-Path -Path $OutputDirectory -ChildPath $JUnitFileName
    $applyJsonPath = Join-Path -Path $OutputDirectory -ChildPath $ApplyResultsJsonFileName

    # Per-host step-output naming - PRESERVE existing pipeline downstream
    # bindings byte-for-byte: GH uses UPPER_SNAKE, ADO uses PascalCase
    # (e.g. stageDependencies...outputs['applyUpdates.Succeeded']).
    if ($pipelineHost -eq 'AzureDevOps') {
        $nSucceeded = 'Succeeded'; $nPrepared = 'Prepared'; $nSkipped = 'Skipped'; $nFailed = 'Failed'
        $nHealth   = 'HealthBlocked'; $nSchedule = 'ScheduleBlocked'
        $nSideload = 'SideloadedBlocked'; $nExcluded = 'ExcludedByTag'
    }
    else {
        $nSucceeded = 'SUCCEEDED'; $nPrepared = 'PREPARED'; $nSkipped = 'SKIPPED'; $nFailed = 'FAILED'
        $nHealth   = 'HEALTH_BLOCKED'; $nSchedule = 'SCHEDULE_BLOCKED'
        $nSideload = 'SIDELOADED_BLOCKED'; $nExcluded = 'EXCLUDED_BY_TAG'
    }

    # Helper to emit the seven counters as step outputs. Do NOT call
    # .GetNewClosure() here - it severs the scriptblock from the module's
    # SessionState, making the private Set-AzLocalPipelineOutput function
    # invisible. Lexical scoping already gives this scriptblock access to
    # the $n* variables since '& $emitCounters' is invoked from within the
    # same function.
    $emitCounters = {
        param($s, $p, $sk, $f, $hb, $scb, $sb, $ebt)
        Set-AzLocalPipelineOutput -Name $nSucceeded -Value "$s"   -CrossJob
        Set-AzLocalPipelineOutput -Name $nPrepared  -Value "$p"   -CrossJob
        Set-AzLocalPipelineOutput -Name $nSkipped   -Value "$sk"  -CrossJob
        Set-AzLocalPipelineOutput -Name $nFailed    -Value "$f"   -CrossJob
        Set-AzLocalPipelineOutput -Name $nHealth    -Value "$hb"  -CrossJob
        Set-AzLocalPipelineOutput -Name $nSchedule  -Value "$scb" -CrossJob
        Set-AzLocalPipelineOutput -Name $nSideload  -Value "$sb"  -CrossJob
        Set-AzLocalPipelineOutput -Name $nExcluded  -Value "$ebt" -CrossJob
    }

    if (-not (Test-Path -LiteralPath $ReadinessCsvPath)) {
        throw "Invoke-AzLocalReadinessGatedClusterUpdate: Readiness CSV not found at '$ReadinessCsvPath'. The check-readiness job did not upload a readiness-report artifact - cannot determine which clusters to apply."
    }

    $readinessRows = @(Import-Csv -Path $ReadinessCsvPath)
    if ($readinessRows.Count -gt 0 -and -not ($readinessRows[0].PSObject.Properties.Name -contains 'ClusterResourceId')) {
        throw "Invoke-AzLocalReadinessGatedClusterUpdate: Readiness CSV at '$ReadinessCsvPath' is missing the 'ClusterResourceId' column. This column was added in AzLocal.UpdateManagement v0.7.62. Re-run check-readiness with v0.7.62+ or refresh the pipeline YAML via Copy-AzLocalPipelineExample -Update."
    }

    [string[]]$readyResourceIds = @($readinessRows |
            Where-Object { $_.ReadyForUpdate -eq 'True' -and $_.ClusterResourceId } |
            ForEach-Object { $_.ClusterResourceId })

    Write-Host "Readiness CSV: $($readinessRows.Count) row(s), $($readyResourceIds.Count) marked ReadyForUpdate=True."

    if ($readyResourceIds.Count -eq 0) {
        # Preserve original per-host wording for the 'nothing to apply' warning.
        switch ($pipelineHost) {
            'GitHub'      { Write-Host "::warning::Readiness CSV reports zero clusters with ReadyForUpdate=True - nothing to apply." }
            'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]Readiness CSV reports zero clusters with ReadyForUpdate=True - nothing to apply." }
            default       { Write-Warning "Readiness CSV reports zero clusters with ReadyForUpdate=True - nothing to apply." }
        }
        & $emitCounters 0 0 0 0 0 0 0 0
        '[]' | Out-File -FilePath $applyJsonPath -Encoding utf8 -Force -WhatIf:$false
        if ($PassThru) {
            return [pscustomobject]@{
                Succeeded             = 0
                Prepared              = 0
                Skipped               = 0
                Failed                = 0
                HealthBlocked         = 0
                ScheduleBlocked       = 0
                SideloadedBlocked     = 0
                ExcludedByTag         = 0
                Results               = @()
                JUnitPath             = $junitPath
                ApplyResultsJsonPath  = $applyJsonPath
                ReadyResourceIds      = @()
            }
        }
        return
    }

    $applyParams = @{
        ClusterResourceIds = $readyResourceIds
        Force              = $true
        LogFolderPath      = $OutputDirectory
        ExportResultsPath  = $junitPath
    }

    if ($UpdateName -and $UpdateName -ne '') {
        $applyParams['UpdateName'] = $UpdateName
        Write-Host "Applying specific update: $UpdateName"
    }

    if ($allowList.Count -gt 0) {
        $applyParams['AllowedUpdateVersions'] = $allowList
        Write-Host "AllowedUpdateVersions allow-list (schema v2): [$($allowList -join ', ')]. Clusters with no Ready update matching the list will be skipped with status 'NotInAllowList'."
    }

    if ($DryRun) {
        $applyParams['WhatIf'] = $true
        # Preserve original per-host wording.
        switch ($pipelineHost) {
            'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]DRY RUN MODE - No updates will be applied" }
            default       { Write-Host "DRY RUN MODE - No updates will be applied" }
        }
    }

    if ($PrepareOnly) {
        $applyParams['PrepareOnly'] = $true
        Write-Host "PREPARE ONLY MODE - Update content and health checks will run, but installation will not start. UpdateExclusionsWindow remains enforced."
    }

    if ($PrepareOnlyFirst) {
        $applyParams['PrepareOnlyFirst'] = $true
        Write-Host "PREPARE FIRST MODE - Ready updates will be prepared now; ReadyToInstall updates will install only when schedule tags permit."
    }

    $applyParams['AllowPrepareOnlyOutsideOfUpdateStartWindow'] = $AllowPrepareOnlyOutsideOfUpdateStartWindow
    Write-Host "Prepare UpdateStartWindow policy: AllowOutsideWindow=$AllowPrepareOnlyOutsideOfUpdateStartWindow"

    if ($ForceImmediateUpdate) {
        # v0.8.79 break-glass override. Surface a HIGH-VISIBILITY warning on every
        # supported pipeline host so the override is unmistakable in run logs and
        # PR annotations. The actual bypass is enforced inside Start-AzLocalClusterUpdate
        # Step 3c via the forwarded -IgnoreScheduleTags switch.
        $applyParams['IgnoreScheduleTags'] = $true
        $forceMsg = "FORCE IMMEDIATE UPDATE enabled. UpdateStartWindow and UpdateExclusionsWindow tags will be IGNORED for every cluster in this run. This is a break-glass override intended for emergency / out-of-window patching."
        switch ($pipelineHost) {
            'GitHub'      { Write-Host "::warning::$forceMsg" }
            'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]$forceMsg" }
            default       { Write-Warning $forceMsg }
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    $operationHeading = if ($PrepareOnly) { 'Preparing Updates for UpdateRing' } else { 'Applying Updates to UpdateRing' }
    Write-Host "$operationHeading`: $UpdateRing" -ForegroundColor Cyan
    Write-Host "  Clusters (from readiness CSV): $($readyResourceIds.Count)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    $results = @(Start-AzLocalClusterUpdate @applyParams -PassThru)

    Write-Host ""
    Write-Host "Update operation complete"

    $succeeded         = @($results | Where-Object { $_.Status -eq 'Started' -or $_.Status -eq 'Success' -or $_.Status -eq 'UpdateStarted' }).Count
    $prepared          = @($results | Where-Object { $_.Status -in @('PreparationStarted', 'AlreadyPrepared') }).Count
    $skipped           = @($results | Where-Object { $_.Status -in @('Skipped', 'NotReady', 'NoUpdatesAvailable', 'NoReadyUpdates', 'NotFound', 'UpdateNotFound', 'NotInAllowList') }).Count
    $failed            = @($results | Where-Object { $_.Status -in @('Failed', 'Error') }).Count
    $healthBlocked     = @($results | Where-Object { $_.Status -eq 'HealthCheckBlocked' }).Count
    $scheduleBlocked   = @($results | Where-Object { $_.Status -eq 'ScheduleBlocked' }).Count
    $sideloadedBlocked = @($results | Where-Object { $_.Status -eq 'SideloadedBlocked' }).Count
    $excludedByTag     = @($results | Where-Object { $_.Status -eq 'ExcludedByTag' }).Count

    & $emitCounters $succeeded $prepared $skipped $failed $healthBlocked $scheduleBlocked $sideloadedBlocked $excludedByTag

    # Persist per-cluster apply results to JSON for the downstream Summary step.
    $projectedResults = @($results | Select-Object ClusterName, Status, UpdateName, Duration, Message)
    $applyJsonContent = if ($projectedResults.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $projectedResults -Depth 4 }
    $applyJsonContent | Out-File -FilePath $applyJsonPath -Encoding utf8 -Force -WhatIf:$false
    Write-Host "Wrote per-cluster apply results to $applyJsonPath"

    # ADO-only: per-bucket warning/error log lines (preserves CI surface).
    if ($pipelineHost -eq 'AzureDevOps') {
        if ($failed -gt 0) {
            if ($succeeded -eq 0 -and $skipped -eq 0 -and $healthBlocked -eq 0 -and $scheduleBlocked -eq 0 -and $sideloadedBlocked -eq 0 -and $excludedByTag -eq 0) {
                Write-Host "##vso[task.logissue type=error]All $failed cluster(s) in scope failed to start updates. Review the Azure Local portal, cluster health, and the published update-results.xml for per-cluster detail."
            }
            else {
                Write-Host "##vso[task.logissue type=warning]$failed cluster(s) failed to start updates. $succeeded succeeded, $skipped skipped, $healthBlocked health-blocked, $scheduleBlocked schedule-blocked, $sideloadedBlocked sideloaded-blocked, $excludedByTag excluded-by-tag. See update-results.xml for per-cluster detail."
            }
        }
        if ($healthBlocked -gt 0) {
            Write-Host "##vso[task.logissue type=warning]$healthBlocked cluster(s) blocked by critical health check failures"
        }
        if ($scheduleBlocked -gt 0) {
            Write-Host "##vso[task.logissue type=warning]$scheduleBlocked cluster(s) blocked by maintenance schedule (outside UpdateStartWindow or in UpdateExclusionsWindow period)"
        }
        if ($sideloadedBlocked -gt 0) {
            Write-Host "##vso[task.logissue type=warning]$sideloadedBlocked cluster(s) blocked by UpdateSideloaded=False - operator must stage the sideloaded payload and flip the tag (or run Reset-AzLocalSideloadedTag) before updates can proceed"
        }
        if ($excludedByTag -gt 0) {
            Write-Host "##vso[task.logissue type=warning]$excludedByTag cluster(s) excluded by UpdateExcluded=True operator override - flip the UpdateExcluded tag to False (Azure portal or 'az tag update') once the cluster should rejoin automation"
        }
    }

    if ($PassThru) {
        return [pscustomobject]@{
            Succeeded            = $succeeded
            Prepared             = $prepared
            Skipped              = $skipped
            Failed               = $failed
            HealthBlocked        = $healthBlocked
            ScheduleBlocked      = $scheduleBlocked
            SideloadedBlocked    = $sideloadedBlocked
            ExcludedByTag        = $excludedByTag
            Results              = $results
            JUnitPath            = $junitPath
            ApplyResultsJsonPath = $applyJsonPath
            ReadyResourceIds     = $readyResourceIds
        }
    }
}
