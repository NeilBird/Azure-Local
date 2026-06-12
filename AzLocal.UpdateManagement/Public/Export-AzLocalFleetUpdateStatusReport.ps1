function Export-AzLocalFleetUpdateStatusReport {
    <#
    .SYNOPSIS
        Snapshots fleet-wide Azure Local update status and emits the full
        Step.8 artefact bundle (CSV + JSON + JUnit XML + markdown summary).

    .DESCRIPTION
        Public entry-point for the v0.8.5 thin-YAML refactor of the Step.8
        fleet-update-status pipeline. Before v0.8.5 the GitHub Actions and
        Azure DevOps Step.8 YAML files each carried ~830 lines of inline
        PowerShell (cluster inventory + readiness + JUnit XML construction +
        markdown summary rendering + step-output emission). This cmdlet
        condenses that workload into a single Public PowerShell entry-point
        that both pipeline platforms call with a thin parameter splat.

        The cmdlet:
          1. Inventories every Azure Local cluster the caller can read
             (or, with -Scope by-update-ring, every cluster whose UpdateRing
             tag matches -UpdateRing).
          2. Computes readiness, current version, health state and update
             state per cluster.
          3. Pivots clusters by CurrentVersion to produce a Fleet Version
             Distribution view, anchored against the latest released Azure
             Local solution version from the Microsoft Edge Updates manifest
             (with a fleet-observed top-6 YYMM fallback when the manifest is
             unreachable).
          4. Generates a 3-testsuite JUnit XML document
             (Fleet Version Distribution + AzureLocalFleetUpdateStatus +
             Update Run History and Error Details) using the shared
             New-AzLocalPipelineJUnitXml emitter. Each testcase carries
             <properties> that the optional New-AzLocalIncident ITSM
             connector consumes to compute the SHA256 dedupe key.
          5. Collects supplementary fleet-wide CSVs
             (update-summaries.csv, available-updates.csv, optional
             update-runs.csv) and the verbose run-history bundle
             (update-run-history.csv + .json) from
             Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved.
          6. Emits 22 step outputs (lowercase snake_case) describing fleet
             bucket counts so downstream pipeline steps can branch.
          7. Renders the full markdown summary to the host's step-summary
             surface (GitHub Actions GITHUB_STEP_SUMMARY or Azure DevOps
             ##vso[task.uploadsummary]) including the YYMM-grouped version
             distribution table, the Critical Health Status pass/fail table,
             the Primary Status priority cascade table, the Actions Required
             bullet list and the Update Run History collapsible-error table.

        The cmdlet replaces the inline 'Collect Fleet Update Status' AND the
        downstream 'Create Status Summary' steps from the pre-v0.8.5 YAML.

    .PARAMETER OutputDirectory
        Directory to write artefacts into. When omitted, defaults to
        $env:BUILD_ARTIFACTSTAGINGDIRECTORY on Azure DevOps hosts (resolved
        via Get-AzLocalPipelineHost) and './reports' everywhere else
        (GitHub Actions, local interactive use).

    .PARAMETER Scope
        Fleet selector: 'all' (every cluster the caller can read) or
        'by-update-ring' (clusters whose UpdateRing tag matches -UpdateRing).

    .PARAMETER UpdateRing
        UpdateRing tag value to filter on when Scope='by-update-ring'.
        Accepts a single value, a ';'-delimited list, or '***' (three stars)
        as a wildcard. Ignored when Scope='all'.

    .PARAMETER IncludeUpdateRuns
        When $true (default), runs Step 4c (Get-AzLocalUpdateRuns -Latest
        across the fleet) and writes update-runs.csv. Set $false to skip
        the recent-runs collection to shorten run time on very large fleets.

    .PARAMETER RunHistorySinceDays
        How far back to look for unresolved Failed update runs when
        building the 'Update Run History and Error Details' testsuite.
        Default 30 days. Must be 1..365.

    .PARAMETER RunHistoryTopRows
        Maximum number of rows persisted to the run-history base64 blob
        consumed by the markdown summary. Default 25. Must be 1..500.
        Does NOT cap the JUnit XML or CSV emit (those include every row).

    .PARAMETER InventoryCsvFileName
        Override the default 'cluster-inventory.csv' filename.

    .PARAMETER ReadinessCsvFileName
        Override the default 'readiness-status.csv' filename.

    .PARAMETER ReadinessJsonFileName
        Override the default 'readiness-status.json' filename.

    .PARAMETER XmlFileName
        Override the default 'readiness-status.xml' JUnit filename.

    .PARAMETER SummariesCsvFileName
        Override the default 'update-summaries.csv' filename.

    .PARAMETER AvailableCsvFileName
        Override the default 'available-updates.csv' filename.

    .PARAMETER RunsCsvFileName
        Override the default 'update-runs.csv' filename.

    .PARAMETER RunHistoryCsvFileName
        Override the default 'update-run-history.csv' filename.

    .PARAMETER RunHistoryJsonFileName
        Override the default 'update-run-history.json' filename.

    .PARAMETER SummaryFileName
        Override the default 'fleet-update-status-summary.md' filename
        (the markdown rendered into GITHUB_STEP_SUMMARY / ADO upload-summary).

    .PARAMETER InstalledModuleVersion
        Optional version string rendered in the markdown footer (e.g. v0.8.5).
        When omitted, no footer line is appended.

    .PARAMETER Now
        Optional [datetime] used as 'snapshot time' in the markdown summary
        (Generated at ...). Defaults to (Get-Date). Parameterised so unit
        tests can assert against a fixed value.

    .PARAMETER PassThru
        Return a PSCustomObject describing the fleet snapshot (counts +
        file paths + Rows + RunHistoryRows + VersionDistribution). Default
        is no return value (the cmdlet only writes files + step outputs +
        markdown summary).

    .OUTPUTS
        [PSCustomObject] when -PassThru is supplied. Properties:
          - TotalClusters, CriticalHealthPassed, CriticalHealthFailed
          - UpdateFailedCount, ActionRequiredCount, HealthFailureCount,
            SbeBlockedCount, InProgressCount, ReadyForUpdateCount,
            UpToDateCount, NeedsInvestigationCount
          - HasPrerequisiteCount, RunHistoryCount
          - VersionDistCount, SupportedClusters, UnsupportedClusters,
            UnknownVersionClusters, SupportSource, SupportedYymmWindow,
            LatestReleasedYymm, LatestReleasedVersion
          - InventoryCsvPath, ReadinessCsvPath, ReadinessJsonPath,
            XmlPath, SummariesCsvPath, AvailableCsvPath, RunsCsvPath,
            RunHistoryCsvPath, RunHistoryJsonPath, SummaryPath
          - Rows (readiness rows), RunHistoryRows, VersionDistribution

    .EXAMPLE
        Export-AzLocalFleetUpdateStatusReport
        # All-cluster snapshot; writes the full artefact bundle to ./reports/.

    .EXAMPLE
        Export-AzLocalFleetUpdateStatusReport -Scope by-update-ring -UpdateRing Prod -PassThru
        # Restricts to clusters tagged UpdateRing=Prod and returns the
        # snapshot object for downstream PowerShell use.

    .EXAMPLE
        # Used by Step.9_fleet-update-status.yml (GitHub Actions + Azure DevOps):
        Export-AzLocalFleetUpdateStatusReport `
            -Scope $env:INPUT_SCOPE `
            -UpdateRing $env:INPUT_UPDATE_RING `
            -IncludeUpdateRuns:($env:INPUT_INCLUDE_UPDATE_RUNS -eq 'true') `
            -InstalledModuleVersion (Get-Module AzLocal.UpdateManagement).Version

    .NOTES
        Author : Neil Bird, Microsoft
        Version: v0.8.5
        Added  : v0.8.5 (Step.8 thin-YAML port - condenses ~830 lines of inline
                 PowerShell into a single Public entry-point).
        Reuses : Get-AzLocalClusterInventory, Get-AzLocalClusterUpdateReadiness,
                 Get-AzLocalUpdateSummary, Get-AzLocalAvailableUpdates,
                 Get-AzLocalUpdateRuns, Get-AzLocalUpdateRunFailures,
                 Get-AzLocalLatestSolutionVersion, New-AzLocalPipelineJUnitXml,
                 Set-AzLocalPipelineOutput, Add-AzLocalPipelineStepSummary,
                 Get-AzLocalPipelineHost.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$OutputDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateSet('all', 'by-update-ring')]
        [string]$Scope = 'all',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$UpdateRing,

        [Parameter(Mandatory = $false)]
        [bool]$IncludeUpdateRuns = $true,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 365)]
        [int]$RunHistorySinceDays = 30,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 500)]
        [int]$RunHistoryTopRows = 25,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$InventoryCsvFileName = 'cluster-inventory.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessCsvFileName = 'readiness-status.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReadinessJsonFileName = 'readiness-status.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$XmlFileName = 'readiness-status.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummariesCsvFileName = 'update-summaries.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$AvailableCsvFileName = 'available-updates.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RunsCsvFileName = 'update-runs.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RunHistoryCsvFileName = 'update-run-history.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$RunHistoryJsonFileName = 'update-run-history.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'fleet-update-status-summary.md',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$InstalledModuleVersion,

        [Parameter(Mandatory = $false)]
        [datetime]$Now = (Get-Date),

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $pipelineHost = Get-AzLocalPipelineHost

    if (-not $OutputDirectory) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $OutputDirectory = Join-Path -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY -ChildPath 'reports'
        }
        else {
            $OutputDirectory = './reports'
        }
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $inventoryCsv     = Join-Path -Path $OutputDirectory -ChildPath $InventoryCsvFileName
    $readinessCsv     = Join-Path -Path $OutputDirectory -ChildPath $ReadinessCsvFileName
    $readinessJson    = Join-Path -Path $OutputDirectory -ChildPath $ReadinessJsonFileName
    $readinessXml     = Join-Path -Path $OutputDirectory -ChildPath $XmlFileName
    $summariesCsv     = Join-Path -Path $OutputDirectory -ChildPath $SummariesCsvFileName
    $availableCsv     = Join-Path -Path $OutputDirectory -ChildPath $AvailableCsvFileName
    $runsCsv          = Join-Path -Path $OutputDirectory -ChildPath $RunsCsvFileName
    $runHistoryCsv    = Join-Path -Path $OutputDirectory -ChildPath $RunHistoryCsvFileName
    $runHistoryJson   = Join-Path -Path $OutputDirectory -ChildPath $RunHistoryJsonFileName

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Fleet Update Status Collection" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Scope: $Scope"
    if ($UpdateRing) { Write-Host "UpdateRing Filter: $UpdateRing" }
    Write-Host "Include Update Runs: $IncludeUpdateRuns"
    Write-Host ""

    # ---- Step 1: cluster inventory ----------------------------------------
    Write-Host "Step 1: Getting cluster inventory..." -ForegroundColor Yellow
    $inventory = Get-AzLocalClusterInventory -ExportPath $inventoryCsv -PassThru
    $inventoryCount = @($inventory).Count
    Write-Host "Found $inventoryCount total cluster(s)" -ForegroundColor Green

    if ($inventoryCount -eq 0) {
        Write-Warning "No clusters found in inventory; emitting empty artefact bundle and step outputs."
        # Emit empty JUnit document + zero-valued step outputs so downstream
        # pipeline steps (dorny/test-reporter, ITSM connector) don't crash.
        $null = New-AzLocalPipelineJUnitXml -TestSuitesName 'Fleet Update Status' -Suites @(
            @{ Name = 'Fleet Version Distribution'; ClassName = 'FleetVersionDistribution'; TestCases = @() }
            @{ Name = 'AzureLocalFleetUpdateStatus'; ClassName = 'AzureLocalFleetUpdateStatus'; TestCases = @() }
            @{ Name = "Update Run History and Error Details"; ClassName = 'UpdateRunHistory'; TestCases = @() }
        ) -OutputPath $readinessXml -Timestamp $Now
        foreach ($n in @('total_clusters','critical_health_passed','critical_health_failed','up_to_date','in_progress','ready','sbe_blocked','health_failure','update_failed','action_required','needs_investigation','failures','has_prerequisite','run_history_count','version_dist_count','supported_clusters','unsupported_clusters','unknown_version_clusters')) {
            Set-AzLocalPipelineOutput -Name $n -Value '0'
        }
        foreach ($n in @('supported_yymm_window','support_source','latest_released_yymm','latest_released_version')) {
            Set-AzLocalPipelineOutput -Name $n -Value ''
        }
        $emptyMd = "## Fleet Update Status Summary  _(generated $($Now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')))_`n`n_No clusters found in inventory._"
        Add-AzLocalPipelineStepSummary -Markdown $emptyMd -SummaryFileName $SummaryFileName | Out-Null
        if ($PassThru) {
            return [pscustomobject]@{
                TotalClusters            = 0
                CriticalHealthPassed     = 0
                CriticalHealthFailed     = 0
                UpdateFailedCount        = 0
                ActionRequiredCount      = 0
                HealthFailureCount       = 0
                SbeBlockedCount          = 0
                InProgressCount          = 0
                ReadyForUpdateCount      = 0
                UpToDateCount            = 0
                NeedsInvestigationCount  = 0
                HasPrerequisiteCount     = 0
                RunHistoryCount          = 0
                VersionDistCount         = 0
                SupportedClusters        = 0
                UnsupportedClusters      = 0
                UnknownVersionClusters   = 0
                SupportedYymmWindow      = ''
                SupportSource            = ''
                LatestReleasedYymm       = ''
                LatestReleasedVersion    = ''
                InventoryCsvPath         = $inventoryCsv
                ReadinessCsvPath         = $readinessCsv
                ReadinessJsonPath        = $readinessJson
                XmlPath                  = $readinessXml
                SummariesCsvPath         = $summariesCsv
                AvailableCsvPath         = $availableCsv
                RunsCsvPath              = $runsCsv
                RunHistoryCsvPath        = $runHistoryCsv
                RunHistoryJsonPath       = $runHistoryJson
                Rows                     = @()
                RunHistoryRows           = @()
                VersionDistribution      = @()
            }
        }
        return
    }

    # ---- Step 2: readiness ------------------------------------------------
    Write-Host ""
    Write-Host "Step 2: Checking update readiness..." -ForegroundColor Yellow

    $readinessParams = @{ ExportPath = $readinessCsv; PassThru = $true }
    if ($Scope -eq 'by-update-ring' -and $UpdateRing) {
        $readinessParams['ScopeByUpdateRingTag'] = $true
        $readinessParams['UpdateRingValue']      = $UpdateRing
    }
    else {
        $readinessParams['ClusterResourceIds'] = @($inventory | Select-Object -ExpandProperty ResourceId)
    }
    $readiness = @(Get-AzLocalClusterUpdateReadiness @readinessParams)
    $totalTests = $readiness.Count

    # ---- Status bucket classification (priority cascade) ------------------
    # Cluster is counted exactly once. Priority (first match wins):
    #   UpdateFailed > ActionRequired > HealthFailure > SbeBlocked >
    #   InProgress > ReadyForUpdate > UpToDate > NeedsInvestigation
    # v0.8.74: the cascade lives in the shared Private helper
    # Get-AzLocalClusterReadinessStatus so Step.5 / Step.7 / Step.9 classify
    # "Up to Date" identically (was previously re-implemented inline here).
    $failureStates = @('Failed','UpdateFailed','NeedsAttention','PreparationFailed')
    $stUpdateFailed = 0
    $stActionRequired = 0
    $stHealthFailure = 0
    $stSbeBlocked = 0
    $stInProgress = 0
    $stReadyForUpdate = 0
    $stUpToDate = 0
    $stOther = 0
    foreach ($c in $readiness) {
        switch (Get-AzLocalClusterReadinessStatus -ReadinessRow $c) {
            'UpdateFailed'   { $stUpdateFailed++ }
            'ActionRequired' { $stActionRequired++ }
            'HealthFailure'  { $stHealthFailure++ }
            'SbeBlocked'     { $stSbeBlocked++ }
            'InProgress'     { $stInProgress++ }
            'ReadyForUpdate' { $stReadyForUpdate++ }
            'UpToDate'       { $stUpToDate++ }
            default          { $stOther++ }
        }
    }
    $hasPrerequisite = @($readiness | Where-Object { $_.HasPrerequisiteUpdates -ne '' -and $null -ne $_.HasPrerequisiteUpdates }).Count

    # Critical Health Status = JUnit pass/fail bucket
    $criticalHealthFailed = @($readiness | Where-Object {
        $_.HealthState -eq 'Failure' -or
        ($_.UpdateState -in $failureStates) -or
        ($_.HasPrerequisiteUpdates -ne '' -and $null -ne $_.HasPrerequisiteUpdates)
    }).Count
    $criticalHealthPassed = $totalTests - $criticalHealthFailed

    # ---- readiness-status.json --------------------------------------------
    $readinessExport = [ordered]@{
        Timestamp     = $Now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
        TotalClusters = $totalTests
        Summary       = [ordered]@{
            ReadyForUpdate    = @($readiness | Where-Object { $_.ReadyForUpdate -eq $true }).Count
            UpToDate          = $stUpToDate
            InProgress        = @($readiness | Where-Object { $_.UpdateState -in @('UpdateInProgress','PreparationInProgress') }).Count
            HealthFailures    = @($readiness | Where-Object { $_.HealthState -eq 'Failure' }).Count
            UpdateFailures    = @($readiness | Where-Object { $_.UpdateState -in @('Failed','UpdateFailed','NeedsAttention') }).Count
            ActionRequired    = @($readiness | Where-Object { $_.UpdateState -eq 'PreparationFailed' }).Count
            HasPrerequisite   = $hasPrerequisite
            NotReadyForUpdate = ($totalTests - $stReadyForUpdate - $stUpToDate - $stInProgress)
        }
        Clusters      = $readiness
    }
    $readinessExport | ConvertTo-Json -Depth 10 | Out-File -FilePath $readinessJson -Encoding utf8

    # ---- Fleet Version Distribution + support window ----------------------
    $versionGroups = @($readiness | Group-Object {
        if ([string]::IsNullOrWhiteSpace($_.CurrentVersion)) { '(unknown)' } else { [string]$_.CurrentVersion }
    } | Sort-Object Count -Descending)
    $versionDistribution = @($versionGroups | ForEach-Object {
        $clusterNames = @($_.Group | Sort-Object ClusterName | ForEach-Object { [string]$_.ClusterName })
        [pscustomobject]@{
            Version    = $_.Name
            Count      = $_.Count
            Percentage = if ($totalTests -gt 0) { [math]::Round(($_.Count / $totalTests) * 100, 1) } else { 0 }
            Clusters   = ($clusterNames -join ', ')
        }
    })
    $distinctVersions     = $versionDistribution.Count
    $mostCommonVersion    = if ($distinctVersions -gt 0) { $versionDistribution[0].Version } else { '(none)' }
    $mostCommonVersionPct = if ($distinctVersions -gt 0) { $versionDistribution[0].Percentage } else { 0 }

    # Anchor support window on Microsoft manifest (preferred) or
    # fleet-observed top-6 YYMM fallback when the manifest is unreachable.
    $supportSource         = 'fleet-observed'
    $latestReleasedYymm    = ''
    $latestReleasedVersion = ''
    $manifestFetchedAt     = ''
    $manifestUrl           = 'https://aka.ms/AzureEdgeUpdates'
    $supportedYymms        = @()
    try {
        Write-Host "Querying $manifestUrl for the latest released Azure Local solution version..."
        $manifestProbe = Get-AzLocalLatestSolutionVersion -ErrorAction Stop
        $supportedYymms        = @($manifestProbe.SupportedYYMMs)
        $supportSource         = 'Microsoft manifest'
        $latestReleasedYymm    = [string]$manifestProbe.LatestYYMM
        $latestReleasedVersion = [string]$manifestProbe.LatestVersion
        if ($manifestProbe.ManifestFetchedAt) {
            $manifestFetchedAt = $manifestProbe.ManifestFetchedAt.ToString('o')
        }
        Write-Host ("Latest released solution version: {0} (YYMM={1}); support window anchored on Microsoft manifest." -f $latestReleasedVersion, $latestReleasedYymm) -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to query $manifestUrl - falling back to fleet-observed top-6 YYMM window. Error: $($_.Exception.Message)"
        $observedYymms = @($versionDistribution | ForEach-Object {
            $parts = ([string]$_.Version) -split '\.'
            if ($parts.Count -ge 2) { $parts[1] } else { '' }
        } | Where-Object { $_ -match '^[0-9]{4}$' } | Sort-Object -Unique)
        $supportedYymms = @($observedYymms | Sort-Object -Descending | Select-Object -First 6)
    }
    $supportedCount      = 0
    $unsupportedCount    = 0
    $unknownVersionCount = 0
    foreach ($v in $versionDistribution) {
        $parts = ([string]$v.Version) -split '\.'
        $yymm  = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        $supportStatus = if ($yymm -match '^[0-9]{4}$') {
            if ($supportedYymms -contains $yymm) { 'Supported' } else { 'Unsupported' }
        }
        else { 'Unknown' }
        $v | Add-Member -MemberType NoteProperty -Name Yymm          -Value $yymm          -Force
        $v | Add-Member -MemberType NoteProperty -Name SupportStatus -Value $supportStatus -Force
        switch ($supportStatus) {
            'Supported'   { $supportedCount      += [int]$v.Count }
            'Unsupported' { $unsupportedCount    += [int]$v.Count }
            'Unknown'     { $unknownVersionCount += [int]$v.Count }
        }
    }
    $supportedYymmWindow = if ($supportedYymms.Count -gt 0) { ($supportedYymms -join ',') } else { '(none)' }

    Write-Host ""
    Write-Host "Fleet Version Distribution ($distinctVersions distinct version(s) across $totalTests cluster(s)):" -ForegroundColor Cyan
    Write-Host ("Support source: {0}" -f $supportSource)
    if ($latestReleasedYymm) {
        Write-Host ("Latest released YYMM (Microsoft manifest): {0} ({1})" -f $latestReleasedYymm, $latestReleasedVersion)
    }
    Write-Host ("Supported YYMM window (top {0}): {1}" -f $supportedYymms.Count, $supportedYymmWindow)
    foreach ($v in $versionDistribution) {
        Write-Host ("  {0,-30} {1,5} cluster(s)  ({2,5}%)  [{3}]" -f $v.Version, $v.Count, $v.Percentage, $v.SupportStatus)
    }

    # ---- Step 3b: Update Run History (must run before JUnit XML build) ---
    Write-Host ""
    Write-Host "Step 3b: Collecting Update Run History + Verbose Error Details (ARG-first, fleet-scale)..." -ForegroundColor Yellow
    $runFailures = @()
    try {
        $runFailures = @(Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since $Now.AddDays(-1 * $RunHistorySinceDays))
    }
    catch {
        Write-Warning "Get-AzLocalUpdateRunFailures threw: $($_.Exception.Message). Continuing with empty run-history section."
        $runFailures = @()
    }
    $runFailures = @($runFailures | Sort-Object @{Expression='StartTime';Descending=$true}, @{Expression='ClusterName';Descending=$false})
    $runHistoryCount = $runFailures.Count
    Write-Host "Found $runHistoryCount unresolved Failed update run(s)." -ForegroundColor $(if ($runHistoryCount -gt 0) { 'Yellow' } else { 'Green' })

    if ($runHistoryCount -gt 0) {
        $runFailures |
            Select-Object ClusterName, UpdateName, State, Status, CurrentStep, Duration, StartTime, LastUpdated, DeepestStepName, ErrorCategory, DeepestErrMsg, UpdateRunPortalUrl, ClusterResourceId, RunId |
            Export-Csv -Path $runHistoryCsv -NoTypeInformation -Force
        $runFailures | ConvertTo-Json -Depth 4 | Out-File -FilePath $runHistoryJson -Encoding utf8
    }
    else {
        '' | Set-Content -LiteralPath $runHistoryCsv -Encoding utf8
        '[]' | Set-Content -LiteralPath $runHistoryJson -Encoding utf8
    }

    # ---- Step 3: JUnit XML via the shared emitter -------------------------
    Write-Host ""
    Write-Host "Step 3: Generating JUnit XML report..." -ForegroundColor Yellow

    # Suite 1: Fleet Version Distribution (one testcase per CurrentVersion, all passed)
    $vdTestCases = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($v in $versionDistribution) {
        $vdTestCases.Add(@{
            Name       = "Version-$($v.Version)"
            ClassName  = 'FleetVersionDistribution'
            Time       = 0.0
            Properties = ([ordered]@{
                Version       = $v.Version
                Yymm          = $v.Yymm
                SupportStatus = $v.SupportStatus
                ClusterCount  = $v.Count
                Percentage    = $v.Percentage
                Clusters      = $v.Clusters
            })
            SystemOut  = "Version: $($v.Version)`nYYMM: $($v.Yymm)`nSupportStatus: $($v.SupportStatus)`nClusters: $($v.Count)`nPercentage: $($v.Percentage)%`nClusterNames: $($v.Clusters)"
        }) | Out-Null
    }
    $vdSuite = @{
        Name       = 'Fleet Version Distribution'
        ClassName  = 'FleetVersionDistribution'
        TestCases  = @($vdTestCases)
        Properties = ([ordered]@{
            testCategory               = 'FleetVersionDistribution'
            description                = "Overall Fleet Update Status - cluster count and percentage per distinct CurrentVersion. SupportStatus uses the rolling 6-month YYMM window anchored on the latest released Azure Local solution version (supportSource='Microsoft manifest' or fleet-observed fallback)."
            scope                      = $Scope
            updateRing                 = [string]$UpdateRing
            totalClusters              = $totalTests
            distinctVersions           = $distinctVersions
            mostCommonVersion          = [string]$mostCommonVersion
            mostCommonVersionPercentage = $mostCommonVersionPct
            supportSource              = $supportSource
            latestReleasedYymm         = $latestReleasedYymm
            latestReleasedVersion      = $latestReleasedVersion
            manifestUrl                = $manifestUrl
            manifestFetchedAt          = $manifestFetchedAt
            supportedYymmWindow        = $supportedYymmWindow
            supportedClusters          = $supportedCount
            unsupportedClusters        = $unsupportedCount
            unknownVersionClusters     = $unknownVersionCount
        })
    }

    # Suite 2: AzureLocalFleetUpdateStatus - one testcase per cluster.
    # Failed clusters first (alphabetical), then passed clusters (alphabetical).
    $failedClusters = @()
    $passedClusters = @()
    foreach ($c in $readiness) {
        if ($c.HealthState -eq 'Failure' -or ($c.UpdateState -in $failureStates) -or ($c.HasPrerequisiteUpdates -ne '' -and $null -ne $c.HasPrerequisiteUpdates)) {
            $failedClusters += $c
        }
        else {
            $passedClusters += $c
        }
    }
    $orderedClusters = @($failedClusters | Sort-Object ClusterName) + @($passedClusters | Sort-Object ClusterName)
    $fsTestCases = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($cluster in $orderedClusters) {
        $isFail        = $false
        $failureType   = ''
        $failureMessage = ''
        if ($cluster.HealthState -eq 'Failure' -or ($cluster.UpdateState -in $failureStates)) {
            $isFail = $true
            $failureType = if ($cluster.UpdateState -eq 'PreparationFailed') { 'PreparationFailed' } else { 'UpdateFailure' }
            $failureMessage = "UpdateState: $($cluster.UpdateState), Health: $($cluster.HealthState)"
            if ($cluster.HealthCheckFailures) { $failureMessage += ", Issues: $($cluster.HealthCheckFailures)" }
        }
        elseif ($cluster.HasPrerequisiteUpdates -ne '' -and $null -ne $cluster.HasPrerequisiteUpdates) {
            $isFail = $true
            $failureType = 'HasPrerequisite'
            $failureMessage = "Updates blocked by SBE prerequisite: $($cluster.HasPrerequisiteUpdates)"
            if ($cluster.SBEDependency) { $failureMessage += " - Vendor: $($cluster.SBEDependency)" }
        }

        $systemOut = @(
            "Cluster: $($cluster.ClusterName)"
            "Resource Group: $($cluster.ResourceGroup)"
            "Subscription: $($cluster.SubscriptionId)"
            "Update State: $($cluster.UpdateState)"
            "Health State: $($cluster.HealthState)"
            "Ready for Update: $($cluster.ReadyForUpdate)"
            "All Available Updates: $($cluster.AllAvailableUpdates)"
            "Ready Updates: $($cluster.ReadyUpdates)"
            "Has Prerequisite Updates: $($cluster.HasPrerequisiteUpdates)"
            "SBE Dependency: $($cluster.SBEDependency)"
            "Recommended Update: $($cluster.RecommendedUpdate)"
        ) -join "`n"

        $clusterPortalUrl = if ($cluster.ResourceId) { "https://portal.azure.com/#@/resource$($cluster.ResourceId)" } else { '' }
        $statusValue = if ($isFail) { $failureType } else { 'Success' }

        $tc = @{
            Name       = "UpdateStatus-$($cluster.ClusterName)"
            ClassName  = "AzureLocalFleetUpdateStatus.$($cluster.ResourceGroup)"
            Time       = 0.0
            Properties = ([ordered]@{
                ClusterName       = [string]$cluster.ClusterName
                ClusterResourceId = [string]$cluster.ResourceId
                UpdateName        = [string]$cluster.RecommendedUpdate
                Status            = $statusValue
                ClusterPortalUrl  = $clusterPortalUrl
            })
            SystemOut  = $systemOut
        }
        if ($isFail) {
            $tc['Failure'] = @{ Message = 'Critical Health Status: Failed'; Type = $failureType; Body = $failureMessage }
        }
        $fsTestCases.Add($tc) | Out-Null
    }
    $fsSuite = @{
        Name       = 'AzureLocalFleetUpdateStatus'
        ClassName  = 'AzureLocalFleetUpdateStatus'
        TestCases  = @($fsTestCases)
        Properties = ([ordered]@{
            testCategory               = 'CriticalHealthStatus'
            description                = "Each testcase = one cluster's Critical Health Status. PASSED = healthy + no failures + not SBE-blocked. FAILED = HealthState=Failure OR UpdateState in (Failed,UpdateFailed,NeedsAttention,PreparationFailed) OR SBE prerequisite blocked."
            scope                      = $Scope
            updateRing                 = [string]$UpdateRing
            totalClusters              = $totalTests
            criticalHealthPassed       = $criticalHealthPassed
            criticalHealthFailed       = $criticalHealthFailed
            primaryUpdateFailed        = $stUpdateFailed
            primaryActionRequired      = $stActionRequired
            primaryHealthFailure       = $stHealthFailure
            primarySbeBlocked          = $stSbeBlocked
            primaryInProgress          = $stInProgress
            primaryReadyForUpdate      = $stReadyForUpdate
            primaryUpToDate            = $stUpToDate
            primaryNeedsInvestigation  = $stOther
        })
    }

    # Suite 3: Update Run History and Error Details
    $rhTestCases = New-Object 'System.Collections.Generic.List[hashtable]'
    foreach ($f in $runFailures) {
        $rowSec = 0
        if ($f.PSObject.Properties['DurationMinutes'] -and $null -ne $f.DurationMinutes) {
            try { $rowSec = [int][math]::Round([double]$f.DurationMinutes * 60, 0) } catch { $rowSec = 0 }
            if ($rowSec -lt 0) { $rowSec = 0 }
        }
        $errBody = if ($f.DeepestErrMsg) {
            if ([string]$f.DeepestErrMsg.Length -gt 4000) { ([string]$f.DeepestErrMsg).Substring(0,4000) + ' ... (truncated)' } else { [string]$f.DeepestErrMsg }
        } else { '(no error message captured)' }

        $sysOutLines = @(
            "Cluster: $($f.ClusterName)"
            "Update: $($f.UpdateName)"
            "Update State: Failed"
            "Status: $($f.Status)"
            "Current Step: $($f.CurrentStep)"
            "Duration: $($f.Duration)"
            "Time Started: $($f.StartTime)"
            "Last Updated: $($f.LastUpdated)"
            "Error Category: $($f.ErrorCategory)"
            "Portal Link: $($f.UpdateRunPortalUrl)"
        )
        if ($f.StackTracePreview) { $sysOutLines += "Stack Trace Preview: $($f.StackTracePreview)" }

        $fClusterPortal = if ($f.ClusterResourceId) { "https://portal.azure.com/#@/resource$($f.ClusterResourceId)" } else { '' }

        $rhTestCases.Add(@{
            Name       = "$($f.ClusterName) - $($f.UpdateName)"
            ClassName  = 'UpdateRunHistory'
            Time       = [double]$rowSec
            Properties = ([ordered]@{
                ClusterName        = [string]$f.ClusterName
                ClusterResourceId  = [string]$f.ClusterResourceId
                UpdateName         = [string]$f.UpdateName
                Status             = 'Failed'
                UpdateState        = [string]$f.Status
                CurrentStep        = [string]$f.CurrentStep
                Duration           = [string]$f.Duration
                ErrorCategory      = [string]$f.ErrorCategory
                UpdateRunPortalUrl = [string]$f.UpdateRunPortalUrl
                ClusterPortalUrl   = $fClusterPortal
            })
            SystemOut  = ($sysOutLines -join "`n")
            Failure    = @{
                Message = "$($f.ClusterName) / $($f.UpdateName) failed at: $($f.CurrentStep)"
                Type    = [string]$f.ErrorCategory
                Body    = $errBody
            }
        }) | Out-Null
    }
    $rhSuite = @{
        Name       = "Update Run History and Error Details"
        ClassName  = 'UpdateRunHistory'
        TestCases  = @($rhTestCases)
        Properties = ([ordered]@{
            description    = "Verbose error details for each unresolved Failed update run (ARG-first, fleet-scale)."
            sourceCmdlet   = "Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since (Get-Date).AddDays(-$RunHistorySinceDays)"
            failedRunCount = $runHistoryCount
        })
    }

    $null = New-AzLocalPipelineJUnitXml -TestSuitesName 'Fleet Update Status' -Suites @($vdSuite, $fsSuite, $rhSuite) -OutputPath $readinessXml -Timestamp $Now
    Write-Host "JUnit XML saved to: $readinessXml" -ForegroundColor Green

    # ---- Step 4: supplementary fleet-wide CSVs ----------------------------
    $fleetResourceIds = if ($Scope -eq 'by-update-ring' -and $UpdateRing) {
        @($readiness | Where-Object { $_.SubscriptionId -and $_.ResourceGroup -and $_.ClusterName } | ForEach-Object {
            "/subscriptions/$($_.SubscriptionId)/resourceGroups/$($_.ResourceGroup)/providers/Microsoft.AzureStackHCI/clusters/$($_.ClusterName)"
        })
    }
    else {
        @($inventory | Select-Object -ExpandProperty ResourceId)
    }

    Write-Host ""
    Write-Host "Step 4a: Collecting fleet update summaries..." -ForegroundColor Yellow
    $summaries = Get-AzLocalUpdateSummary -ClusterResourceIds $fleetResourceIds -ExportPath $summariesCsv -PassThru
    Write-Host "Update summaries collected for $(@($summaries).Count) cluster(s)" -ForegroundColor Green

    Write-Host ""
    Write-Host "Step 4b: Collecting available updates..." -ForegroundColor Yellow
    $available = Get-AzLocalAvailableUpdates -ClusterResourceIds $fleetResourceIds -ExportPath $availableCsv -PassThru
    Write-Host "Found $(@($available).Count) available update(s) across fleet" -ForegroundColor Green

    if ($IncludeUpdateRuns) {
        Write-Host ""
        Write-Host "Step 4c: Collecting recent update run history..." -ForegroundColor Yellow
        $allRuns = Get-AzLocalUpdateRuns -ClusterResourceIds $fleetResourceIds -Latest -ExportPath $runsCsv -PassThru
        $allRunsCount = @($allRuns).Count
        $succeeded     = @($allRuns | Where-Object { $_.State -eq 'Succeeded' }).Count
        $inProgressRuns = @($allRuns | Where-Object { $_.State -eq 'InProgress' }).Count
        $failedRuns    = @($allRuns | Where-Object { $_.State -eq 'Failed' }).Count
        Write-Host "Update runs collected for $allRunsCount cluster(s)" -ForegroundColor Green
        Write-Host "  Succeeded: $succeeded, In Progress: $inProgressRuns, Failed: $failedRuns"
    }

    # ---- Step 5: console summary + step outputs ---------------------------
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Fleet Status Summary" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Total Clusters: $totalTests"
    Write-Host ""
    Write-Host "Critical Health Status (matches JUnit XML pass/fail):" -ForegroundColor White
    Write-Host "  Passed: $criticalHealthPassed" -ForegroundColor Green
    Write-Host "  Failed: $criticalHealthFailed" -ForegroundColor $(if ($criticalHealthFailed -gt 0) { 'Red' } else { 'Green' })
    Write-Host ""
    Write-Host "Primary Status (each cluster counted once; rows sum to Total):" -ForegroundColor White
    Write-Host "  Up to Date: $stUpToDate" -ForegroundColor Green
    Write-Host "  Ready for Update: $stReadyForUpdate" -ForegroundColor Cyan
    Write-Host "  Update In Progress: $stInProgress" -ForegroundColor Yellow
    Write-Host "  SBE Prerequisite Blocked: $stSbeBlocked" -ForegroundColor $(if ($stSbeBlocked -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Health Failure: $stHealthFailure" -ForegroundColor $(if ($stHealthFailure -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  Update Failed: $stUpdateFailed" -ForegroundColor $(if ($stUpdateFailed -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  Action Required: $stActionRequired" -ForegroundColor $(if ($stActionRequired -gt 0) { 'Red' } else { 'Green' })
    Write-Host "  Needs Investigation: $stOther" -ForegroundColor $(if ($stOther -gt 0) { 'Yellow' } else { 'Green' })

    Set-AzLocalPipelineOutput -Name 'total_clusters'          -Value ([string]$totalTests)
    Set-AzLocalPipelineOutput -Name 'critical_health_passed'  -Value ([string]$criticalHealthPassed)
    Set-AzLocalPipelineOutput -Name 'critical_health_failed'  -Value ([string]$criticalHealthFailed)
    Set-AzLocalPipelineOutput -Name 'up_to_date'              -Value ([string]$stUpToDate)
    Set-AzLocalPipelineOutput -Name 'in_progress'             -Value ([string]$stInProgress)
    Set-AzLocalPipelineOutput -Name 'ready'                   -Value ([string]$stReadyForUpdate)
    Set-AzLocalPipelineOutput -Name 'sbe_blocked'             -Value ([string]$stSbeBlocked)
    Set-AzLocalPipelineOutput -Name 'health_failure'          -Value ([string]$stHealthFailure)
    Set-AzLocalPipelineOutput -Name 'update_failed'           -Value ([string]$stUpdateFailed)
    Set-AzLocalPipelineOutput -Name 'action_required'         -Value ([string]$stActionRequired)
    Set-AzLocalPipelineOutput -Name 'needs_investigation'     -Value ([string]$stOther)
    Set-AzLocalPipelineOutput -Name 'failures'                -Value ([string]$criticalHealthFailed)
    Set-AzLocalPipelineOutput -Name 'has_prerequisite'        -Value ([string]$hasPrerequisite)
    Set-AzLocalPipelineOutput -Name 'run_history_count'       -Value ([string]$runHistoryCount)
    Set-AzLocalPipelineOutput -Name 'version_dist_count'      -Value ([string]$distinctVersions)
    Set-AzLocalPipelineOutput -Name 'supported_yymm_window'   -Value $supportedYymmWindow
    Set-AzLocalPipelineOutput -Name 'supported_clusters'      -Value ([string]$supportedCount)
    Set-AzLocalPipelineOutput -Name 'unsupported_clusters'    -Value ([string]$unsupportedCount)
    Set-AzLocalPipelineOutput -Name 'unknown_version_clusters' -Value ([string]$unknownVersionCount)
    Set-AzLocalPipelineOutput -Name 'support_source'          -Value $supportSource
    Set-AzLocalPipelineOutput -Name 'latest_released_yymm'    -Value $latestReleasedYymm
    Set-AzLocalPipelineOutput -Name 'latest_released_version' -Value $latestReleasedVersion

    # ---- Step 6: render markdown summary ----------------------------------
    $generatedUtc = $Now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')
    $md = New-Object 'System.Collections.Generic.List[string]'
    [void]$md.Add("## Fleet Update Status Summary  _(generated $generatedUtc)_")
    [void]$md.Add('')

    # Version distribution table (YYMM-grouped, with support-status emoji)
    if ($distinctVersions -gt 0) {
        try {
            $versionSection = @()
            $versionSection += '### Fleet Version Distribution'
            $versionSection += ''
            $versionSection += "_$distinctVersions distinct version(s) across $totalTests cluster(s). Anchor source: ``$supportSource``"
            if ($latestReleasedYymm) { $versionSection[-1] += ". Latest released YYMM (Microsoft manifest): ``$latestReleasedYymm`` (``$latestReleasedVersion``)" }
            $versionSection[-1] += "._"
            $versionSection += ''
            $versionSection += '| YYMM | Update Versions | Support | Clusters | % | Cluster Names (first 15 shown only) |'
            $versionSection += '|------|-----------------|---------|----------|---|--------------------------------------|'
            $byYymm = $versionDistribution | Group-Object Yymm | Sort-Object @{Expression={ if ($_.Name) { $_.Name } else { '' } }; Descending=$true}
            foreach ($g in $byYymm) {
                $groupRows = @($g.Group | Sort-Object Count -Descending)
                $totalCount = ($groupRows | Measure-Object Count -Sum).Sum
                $totalPct   = if ($totalTests -gt 0) { [math]::Round(($totalCount / $totalTests) * 100, 1) } else { 0 }
                $yymmDisplay = if ($g.Name) { $g.Name } else { '_(unknown)_' }
                $supportStatusForYymm = $groupRows[0].SupportStatus
                $supportEmoji = switch ($supportStatusForYymm) {
                    'Supported'   { ':white_check_mark: Supported' }
                    'Unsupported' { ':warning: Unsupported' }
                    default       { ':grey_question: Unknown' }
                }
                $updateVersionsCell = (($groupRows | ForEach-Object { '{0} x {1}' -f $_.Version, $_.Count }) -join '<br>')
                $clusterNames = @()
                foreach ($r in $groupRows) {
                    if ($r.Clusters) {
                        $clusterNames += @($r.Clusters -split ',\s*' | Where-Object { $_ })
                    }
                }
                $clusterNames = @($clusterNames | Sort-Object -Unique)
                $clCell = if ($clusterNames.Count -le 15) {
                    $clusterNames -join '; '
                }
                else {
                    (($clusterNames | Select-Object -First 15) -join '; ') + (' ... (+{0} more)' -f ($clusterNames.Count - 15))
                }
                $clCell = $clCell -replace '\|','\|'
                $versionSection += ('| {0} | {1} | {2} | {3} | {4}% | {5} |' -f $yymmDisplay, $updateVersionsCell, $supportEmoji, $totalCount, $totalPct, $clCell)
            }
            $versionSection += ''
            $versionSection += "_Support roll-up: Supported = $supportedCount cluster(s), Unsupported = $unsupportedCount, Unknown = $unknownVersionCount. Anchor source: ``$supportSource``._"
            $versionSection += "_Note: the **Clusters (first 15 shown only)** column is intentionally truncated for readability. Download ``$ReadinessCsvFileName`` from artifacts to see the full cluster-name list._"
            $versionSection += ''
            foreach ($line in $versionSection) { [void]$md.Add($line) }
        }
        catch {
            Write-Warning "Failed to render Fleet Version Distribution markdown table: $($_.Exception.Message)"
        }
    }

    # Critical Health Status table
    [void]$md.Add('### Critical Health Status (matches JUnit XML pass/fail)')
    [void]$md.Add('')
    [void]$md.Add('| Metric | Count | Status |')
    [void]$md.Add('|--------|-------|--------|')
    [void]$md.Add("| **Passed** (healthy, no failures, not SBE-blocked) | $criticalHealthPassed | :white_check_mark: |")
    $chFailedIcon = if ($criticalHealthFailed -gt 0) { ':x:' } else { ':white_check_mark:' }
    [void]$md.Add("| **Failed** (HealthState=Failure OR UpdateState=Failed OR SBE prerequisite blocked) | $criticalHealthFailed | $chFailedIcon |")
    [void]$md.Add('')

    # Primary Status table
    [void]$md.Add('### Primary Status (each cluster counted once; rows sum to Total Clusters)')
    [void]$md.Add('')
    [void]$md.Add('| Metric | Count | Status |')
    [void]$md.Add('|--------|-------|--------|')
    [void]$md.Add("| **Total Clusters** | $totalTests | :information_source: |")
    [void]$md.Add("| **Up to Date** | $stUpToDate | :white_check_mark: |")
    [void]$md.Add("| **Ready for Update** | $stReadyForUpdate | :green_circle: |")
    [void]$md.Add("| **Update In Progress** | $stInProgress | :arrows_counterclockwise: |")
    $sbeIcon = if ($stSbeBlocked -gt 0) { ':yellow_circle:' } else { ':white_check_mark:' }
    [void]$md.Add("| **SBE Prerequisite Blocked** | $stSbeBlocked | $sbeIcon |")
    $hfIcon = if ($stHealthFailure -gt 0) { ':x:' } else { ':white_check_mark:' }
    [void]$md.Add("| **Health Failure** (HealthState=Failure) | $stHealthFailure | $hfIcon |")
    $ufIcon = if ($stUpdateFailed -gt 0) { ':x:' } else { ':white_check_mark:' }
    [void]$md.Add("| **Update Failed** (Failed / UpdateFailed / NeedsAttention) | $stUpdateFailed | $ufIcon |")
    $arIcon = if ($stActionRequired -gt 0) { ':x:' } else { ':white_check_mark:' }
    [void]$md.Add("| **Action Required** (PreparationFailed) | $stActionRequired | $arIcon |")
    $niIcon = if ($stOther -gt 0) { ':warning:' } else { ':white_check_mark:' }
    [void]$md.Add("| **Needs Investigation** | $stOther | $niIcon |")
    [void]$md.Add('')
    [void]$md.Add('Priority cascade used to bucket each cluster exactly once:')
    [void]$md.Add('Update Failed > Action Required > Health Failure > SBE Prerequisite Blocked > Update In Progress > Ready for Update > Up to Date > Needs Investigation.')
    [void]$md.Add('')

    # Actions Required bullet list
    $actions = @()
    if ($stUpdateFailed -gt 0)    { $actions += "- **$stUpdateFailed cluster(s) have UpdateState in (Failed, UpdateFailed, NeedsAttention)** - Review the most recent update run in Azure Portal and the ``$RunsCsvFileName`` artifact for the failure detail." }
    if ($stActionRequired -gt 0)  { $actions += "- **$stActionRequired cluster(s) have UpdateState=PreparationFailed** - Update preparation hit a blocker before the run started. Inspect the cluster activity log (most common: prerequisite-check failure, missing SBE content, ARB extension drift). Resolve before re-arming the update." }
    if ($stHealthFailure -gt 0)   { $actions += "- **$stHealthFailure cluster(s) have HealthState=Failure** - Resolve critical health check issues in Azure Portal before retrying any updates." }
    if ($hasPrerequisite -gt 0)   { $actions += "- **$hasPrerequisite cluster(s) blocked by SBE prerequisite** - Install the required Solution Builder Extension (SBE) update from the hardware vendor. See ``$AvailableCsvFileName`` for vendor details (Publisher, Family)." }
    if ($actions.Count -gt 0) {
        [void]$md.Add('### Actions Required')
        [void]$md.Add('')
        foreach ($a in $actions) { [void]$md.Add($a) }
        [void]$md.Add('')
    }

    # Update Run History collapsible-error table
    if ($runHistoryCount -gt 0) {
        try {
            # v0.7.90 dedupe: collapse same-error reruns - group by
            # (ClusterName, UpdateName, DeepestErrMsg); canonical row = latest StartTime.
            $groups = @($runFailures) | Group-Object -Property @{
                Expression = { "$($_.ClusterName)|$($_.UpdateName)|$($_.DeepestErrMsg)" }
            }
            $renderRows = @()
            foreach ($g in $groups) {
                $ordered = @($g.Group | Sort-Object @{ Expression = 'StartTime'; Descending = $true })
                $latest = $ordered[0]
                $extras = @($ordered | Select-Object -Skip 1)
                $latest | Add-Member -NotePropertyName 'EarlierOccurrences' -NotePropertyValue $extras -Force
                $renderRows += $latest
            }
            $renderRows = @($renderRows | Sort-Object @{Expression='StartTime';Descending=$true}, @{Expression='ClusterName';Descending=$false} | Select-Object -First $RunHistoryTopRows)
            $totalRowsCnt = $runHistoryCount
            $groupCount   = $renderRows.Count
            $dedupSuffix  = if ($groupCount -lt $totalRowsCnt) {
                " (collapsed $totalRowsCnt run(s) into $groupCount unique failure group(s); older same-error reruns are listed inside each row's 'Show error' panel)"
            }
            else { '' }
            [void]$md.Add("### :scroll: Update Run History and Error Details")
            [void]$md.Add('')
            [void]$md.Add("_ARG-first, fleet-scale failure-detail view. Shows up to $RunHistoryTopRows most recent unresolved Failed update runs (last $RunHistorySinceDays days). Source cmdlet: ``Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved``.$dedupSuffix._")
            [void]$md.Add('')
            [void]$md.Add('| Cluster Name | Update Name | Update State | Status | Current Step | Verbose Error Details | Duration | Time Started | Last Updated |')
            [void]$md.Add('|---|---|---|---|---|---|---|---|---|')
            foreach ($r in $renderRows) {
                $errCell = if ($r.DeepestErrMsg) {
                    $e = [string]$r.DeepestErrMsg
                    $e = $e -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
                    $e = $e -replace "`r`n",'<br>' -replace "`n",'<br>' -replace '\|','\|'
                    $extraBlock = ''
                    if ($r.EarlierOccurrences -and @($r.EarlierOccurrences).Count -gt 0) {
                        $bullets = (@($r.EarlierOccurrences) | ForEach-Object {
                            $dur = if ($_.Duration) { " (Duration: $($_.Duration))" } else { '' }
                            "&bull; Started $($_.StartTime), Last updated $($_.LastUpdated)$dur"
                        }) -join '<br>'
                        $extraBlock = '<br><br><b>Earlier occurrences with the same error (' + (@($r.EarlierOccurrences).Count) + '):</b><br>' + $bullets
                    }
                    '<details><summary>Show error</summary><br><code>' + $e + '</code>' + $extraBlock + '</details>'
                }
                else { '_(none)_' }
                $clusterCell = if ($r.ClusterResourceId) { '<a href="https://portal.azure.com/#@/resource{0}" target="_blank">{1}</a>' -f $r.ClusterResourceId, $r.ClusterName } else { [string]$r.ClusterName }
                $updCell     = if ($r.UpdateRunPortalUrl) { '<a href="{0}" target="_blank">{1}</a>' -f $r.UpdateRunPortalUrl, $r.UpdateName } else { [string]$r.UpdateName }
                [void]$md.Add("| $clusterCell | $updCell | $($r.State) | $($r.Status) | $($r.CurrentStep) | $errCell | $($r.Duration) | $($r.StartTime) | $($r.LastUpdated) |")
            }
            [void]$md.Add('')
        }
        catch {
            Write-Warning "Failed to render Update Run History markdown table: $($_.Exception.Message)"
        }
    }

    # Reports list
    [void]$md.Add('### Reports Available')
    [void]$md.Add("- ``$ReadinessCsvFileName`` - Detailed cluster status for spreadsheet analysis")
    [void]$md.Add("- ``$ReadinessJsonFileName`` - Machine-readable format for integrations")
    [void]$md.Add("- ``$XmlFileName`` - JUnit XML for CI/CD visualization (includes the 'Update Run History and Error Details' suite)")
    [void]$md.Add("- ``$InventoryCsvFileName`` - Full cluster inventory")
    [void]$md.Add("- ``$SummariesCsvFileName`` - Fleet-wide update state summaries")
    [void]$md.Add("- ``$AvailableCsvFileName`` - All available updates across fleet")
    if ($IncludeUpdateRuns) {
        [void]$md.Add("- ``$RunsCsvFileName`` - Recent update run history")
    }
    [void]$md.Add("- ``$RunHistoryCsvFileName`` - Verbose error details for unresolved Failed update runs (ARG-first, fleet-scale)")
    [void]$md.Add("- ``$RunHistoryJsonFileName`` - Same as above in JSON form for integrations")
    [void]$md.Add('')
    [void]$md.Add("_Generated at $generatedUtc_")
    if ($InstalledModuleVersion) {
        [void]$md.Add('')
        [void]$md.Add(('_Generated by AzLocal.UpdateManagement v{0}._' -f $InstalledModuleVersion))
    }

    $summaryPath = Add-AzLocalPipelineStepSummary -Markdown ($md -join [Environment]::NewLine) -SummaryFileName $SummaryFileName

    if ($criticalHealthFailed -gt 0) {
        Write-Warning "$criticalHealthFailed cluster(s) have update failures, health issues, or SBE prerequisite blocks. Check the detailed reports."
    }

    if ($PassThru) {
        return [pscustomobject]@{
            TotalClusters            = [int]$totalTests
            CriticalHealthPassed     = [int]$criticalHealthPassed
            CriticalHealthFailed     = [int]$criticalHealthFailed
            UpdateFailedCount        = [int]$stUpdateFailed
            ActionRequiredCount      = [int]$stActionRequired
            HealthFailureCount       = [int]$stHealthFailure
            SbeBlockedCount          = [int]$stSbeBlocked
            InProgressCount          = [int]$stInProgress
            ReadyForUpdateCount      = [int]$stReadyForUpdate
            UpToDateCount            = [int]$stUpToDate
            NeedsInvestigationCount  = [int]$stOther
            HasPrerequisiteCount     = [int]$hasPrerequisite
            RunHistoryCount          = [int]$runHistoryCount
            VersionDistCount         = [int]$distinctVersions
            SupportedClusters        = [int]$supportedCount
            UnsupportedClusters      = [int]$unsupportedCount
            UnknownVersionClusters   = [int]$unknownVersionCount
            SupportedYymmWindow      = $supportedYymmWindow
            SupportSource            = $supportSource
            LatestReleasedYymm       = $latestReleasedYymm
            LatestReleasedVersion    = $latestReleasedVersion
            InventoryCsvPath         = $inventoryCsv
            ReadinessCsvPath         = $readinessCsv
            ReadinessJsonPath        = $readinessJson
            XmlPath                  = $readinessXml
            SummariesCsvPath         = $summariesCsv
            AvailableCsvPath         = $availableCsv
            RunsCsvPath              = $runsCsv
            RunHistoryCsvPath        = $runHistoryCsv
            RunHistoryJsonPath       = $runHistoryJson
            SummaryPath              = $summaryPath
            Rows                     = $readiness
            RunHistoryRows           = $runFailures
            VersionDistribution      = $versionDistribution
        }
    }
}
