function Export-AzLocalSideloadStatusReport {
    <#
    .SYNOPSIS
        Builds a sideload status report (markdown + JUnit XML) from the shared
        state records and optional plan error rows.

    .DESCRIPTION
        Public reporting helper for the v0.8.7 on-prem sideloading automation. Reads
        every per-cluster state JSON under StateRoot\state, summarises progress by
        state (Queued / Copying / Copied / Discovering / NeedsSbe / ImportFailed /
        Imported / Failed / Stale)
        with throughput + ETA, and appends any plan error rows (NotInAllowList,
        UnknownAuthAccountId, NoCatalogEntry). Optionally writes the markdown and a
        JUnit XML (one test case per cluster; Failed/error rows fail) to disk.

    .PARAMETER StateRoot
        Shared UNC root containing state\.

    .PARAMETER Plan
        Optional plan rows from Resolve-AzLocalSideloadPlan, used to surface
        configuration/selection error rows in the report.

    .PARAMETER OutputPath
        Optional directory to write sideload-status.md and sideload-junit.xml.

    .OUTPUTS
        [PSCustomObject] with Markdown, JUnitXml, Counts, HasFailures.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StateRoot,
        [Parameter(Mandatory = $false)][PSCustomObject[]]$Plan,
        [Parameter(Mandatory = $false)][string]$OutputPath
    )

    $stateDir = Join-Path -Path $StateRoot -ChildPath 'state'
    $states = @()
    $stateReadErrors = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $stateDir) {
        $states = @(
            Get-ChildItem -LiteralPath $stateDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
                try { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
                catch {
                    $stateReadErrors.Add([PSCustomObject]@{ Path = $_.FullName; Message = $_.Exception.Message })
                    $null
                }
            } | Where-Object { $null -ne $_ }
        )
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## Sideload status')
    $lines.Add('')

    if ($states.Count -gt 0) {
        $lines.Add('| Cluster | Version | State | Progress | Mbps | ETA (UTC) | Owner | Retries | Message |')
        $lines.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
        foreach ($s in ($states | Sort-Object ClusterName)) {
            $pct = if ([long]$s.TotalBytes -gt 0) { ('{0}%' -f [math]::Round(([double]$s.CopiedBytes / [double]$s.TotalBytes) * 100, 1)) } else { '-' }
            $rowText = ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f `
                    $s.ClusterName, $s.Version, $s.State, $pct, $s.Mbps, $s.EtaUtc, $s.OwningMachine, $s.Retries, $s.Message)
            $lines.Add($rowText)
        }
        $lines.Add('')
    }
    else {
        $lines.Add('_No sideload state records found._')
        $lines.Add('')
    }

    $diagnosticStates = @($states | Where-Object { [string]$_.State -in @('Copying', 'Failed', 'ImportFailed', 'NeedsSbe') })
    if ($diagnosticStates.Count -gt 0) {
        $lines.Add('### Diagnostics and remediation')
        $lines.Add('')
        $lines.Add('| Cluster | Operation | Worker PID | Robocopy PID | Log | Remediation |')
        $lines.Add('| --- | --- | --- | --- | --- | --- |')
        foreach ($s in $diagnosticStates) {
            $operationId = if ($s.PSObject.Properties['OperationId']) { [string]$s.OperationId } else { '-' }
            $workerPid = if ($s.PSObject.Properties['WorkerProcessId'] -and $s.WorkerProcessId) { [string]$s.WorkerProcessId } else { '-' }
            $robocopyPid = if ($s.PSObject.Properties['RobocopyProcessId'] -and $s.RobocopyProcessId) { [string]$s.RobocopyProcessId } else { '-' }
            $logPath = if ($s.PSObject.Properties['LogPath'] -and $s.LogPath) { [string]$s.LogPath } else { '-' }
            $remediation = switch ([string]$s.State) {
                'NeedsSbe' { 'Stage the required OEM SBE package, then rerun reconciliation.' }
                'ImportFailed' { 'Review the WinRM/import error and rerun; media is retained and will not be recopied.' }
                'Failed' { 'Review the worker log and task identity/share permissions, then rerun.' }
                default { 'Confirm heartbeat/progress and that the listed worker processes are running.' }
            }
            $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $s.ClusterName, $operationId, $workerPid, $robocopyPid, $logPath, $remediation))
        }
        $lines.Add('')
    }

    if ($stateReadErrors.Count -gt 0) {
        $lines.Add('### Unreadable state records')
        $lines.Add('')
        foreach ($readError in $stateReadErrors) {
            $lines.Add(('- `{0}`: {1}' -f $readError.Path, $readError.Message))
        }
        $lines.Add('')
    }

    $errorRows = @()
    if ($Plan) {
        $errorRows = @($Plan | Where-Object { @('NotInAllowList', 'UnknownAuthAccountId', 'NoCatalogEntry', 'NoneReady') -contains [string]$_.Status })
    }
    if ($errorRows.Count -gt 0) {
        $lines.Add('### Plan warnings / errors')
        $lines.Add('')
        $lines.Add('| Cluster | Status | Message |')
        $lines.Add('| --- | --- | --- |')
        foreach ($e in $errorRows) {
            $lines.Add(('| {0} | {1} | {2} |' -f $e.ClusterName, $e.Status, $e.Message))
        }
        $lines.Add('')
    }

    $markdown = ($lines -join [Environment]::NewLine)

    # JUnit: one case per cluster state; Failed (and plan errors) fail.
    $cases = New-Object System.Collections.Generic.List[object]
    foreach ($s in $states) {
        if ([string]$s.State -in @('Failed', 'ImportFailed')) {
            $cases.Add(@{ Name = ('{0} ({1})' -f $s.ClusterName, $s.Version); Failure = @{ Message = [string]$s.Message; Type = ('Sideload{0}' -f $s.State) } })
        }
        else {
            $cases.Add(@{ Name = ('{0} ({1}) [{2}]' -f $s.ClusterName, $s.Version, $s.State) })
        }
    }
    foreach ($e in $errorRows) {
        $cases.Add(@{ Name = ('{0} [{1}]' -f $e.ClusterName, $e.Status); Failure = @{ Message = [string]$e.Message; Type = [string]$e.Status } })
    }
    foreach ($readError in $stateReadErrors) {
        $cases.Add(@{ Name = ('Unreadable state: {0}' -f (Split-Path -Leaf $readError.Path)); Failure = @{ Message = [string]$readError.Message; Type = 'StateReadError' } })
    }

    $suites = @(@{ Name = 'Sideload'; TestCases = $cases.ToArray() })
    $junit = New-AzLocalPipelineJUnitXml -TestSuitesName 'AzLocalSideload' -Suites $suites

    $counts = $states | Group-Object State | ForEach-Object { [PSCustomObject]@{ State = $_.Name; Count = $_.Count } }
    $hasFailures = (@($states | Where-Object { [string]$_.State -in @('Failed', 'ImportFailed') }).Count -gt 0) -or ($errorRows.Count -gt 0) -or ($stateReadErrors.Count -gt 0)

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
        Write-Utf8NoBomFile -Path (Join-Path $OutputPath 'sideload-status.md') -Content $markdown
        Write-Utf8NoBomFile -Path (Join-Path $OutputPath 'sideload-junit.xml') -Content $junit
    }

    return [PSCustomObject]@{
        Markdown    = $markdown
        JUnitXml    = $junit
        Counts      = @($counts)
        HasFailures = $hasFailures
    }
}

function Add-AzLocalSideloadStepSummary {
    <#
    .SYNOPSIS
        Renders the sideload status report into the CI/CD step summary.
    .DESCRIPTION
        Thin wrapper that calls Export-AzLocalSideloadStatusReport and appends the
        markdown to the pipeline step summary (GitHub/ADO/Local handled internally
        by Add-AzLocalPipelineStepSummary).
    .OUTPUTS
        [PSCustomObject] the report object from Export-AzLocalSideloadStatusReport.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StateRoot,
        [Parameter(Mandatory = $false)][PSCustomObject[]]$Plan,
        [Parameter(Mandatory = $false)][string]$OutputPath
    )

    $report = Export-AzLocalSideloadStatusReport -StateRoot $StateRoot -Plan $Plan -OutputPath $OutputPath
    Add-AzLocalPipelineStepSummary -Markdown $report.Markdown | Out-Null
    return $report
}
