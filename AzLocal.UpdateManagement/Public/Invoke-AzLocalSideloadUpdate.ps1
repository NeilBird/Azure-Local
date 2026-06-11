function Invoke-AzLocalSideloadUpdate {
    <#
    .SYNOPSIS
        Re-entrant Step.6 state machine that drives on-prem sideloading of Azure
        Local solution updates: stage media, detached robocopy to the cluster
        import share, remote SHA256 verify, Add-SolutionUpdate import, then flip the
        UpdateSideloaded gate True.

    .DESCRIPTION
        Public entry point for the v0.8.7 on-prem sideloading automation, designed
        to be invoked repeatedly on a CRON by a single short-lived pipeline run.
        Each invocation advances every in-scope cluster by ONE state transition and
        exits; the multi-hour copy itself runs in a detached Windows Scheduled Task
        (Tools/Invoke-AzLocalSideloadCopyTask.ps1) so no pipeline run is ever
        long-lived. Progress is tracked in shared-UNC state JSON so any runner/agent
        can advance/report without cross-agent remoting.

        Per cluster, the current shared state determines the action:
          - (no state) + due-now      -> set UpdateSideloaded=False, ensure media in
                                          the shared cache, register+start the copy
                                          Scheduled Task, write Copying state.
          - Copying + fresh heartbeat  -> report progress, leave running.
          - Copying + stale heartbeat  -> re-drive on this (live) host (bounded).
          - Copied                     -> open WinRM session, verify remote hash,
                                          import (Add-SolutionUpdate + discovery),
                                          flip UpdateSideloaded=True +
                                          UpdateVersionInProgress, mark Imported,
                                          remove the task.
          - Failed                     -> bounded retry, else surface error.
          - Imported                   -> done.

        All Azure tag writes reuse Set-AzLocalClusterTagsMerge (Tag Contributor
        RBAC only). The KV-derived AD credential is used solely for WinRM.

    .PARAMETER Plan
        Plan rows from Resolve-AzLocalSideloadPlan. Only rows whose Status is
        'Planned' (due now) or which have existing in-flight state are advanced.

    .PARAMETER StateRoot
        Shared UNC root for state\ and logs\.

    .PARAMETER CacheRoot
        Shared verified media cache. Defaults to StateRoot\cache.

    .PARAMETER RobocopySwitches
        Extra robocopy switches for the copy worker.

    .PARAMETER HeartbeatStaleMinutes
        Minutes after which a Copying heartbeat is considered stale (dead host).

    .PARAMETER MaxRetries
        Maximum copy re-drive attempts per cluster.

    .PARAMETER UseSsl
        Use WinRM HTTPS (5986). Default $true.

    .PARAMETER TaskLogonType / TaskPrincipalUserId / TaskPassword
        Scheduled-task identity controls (see Register-AzLocalSideloadCopyTask).

    .OUTPUTS
        [PSCustomObject[]] one result row per processed cluster.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSCustomObject[]]$Plan,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$StateRoot,

        [Parameter(Mandatory = $false)]
        [string]$CacheRoot,

        [Parameter(Mandatory = $false)]
        [string]$RobocopySwitches = '/R:5 /W:30',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1440)]
        [int]$HeartbeatStaleMinutes = 60,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 20)]
        [int]$MaxRetries = 3,

        [Parameter(Mandatory = $false)]
        [bool]$UseSsl = $true,

        [Parameter(Mandatory = $false)]
        [ValidateSet('S4U', 'Password', 'ServiceAccount', 'Interactive')]
        [string]$TaskLogonType = 'S4U',

        [Parameter(Mandatory = $false)]
        [string]$TaskPrincipalUserId,

        [Parameter(Mandatory = $false)]
        [System.Security.SecureString]$TaskPassword
    )

    if ([string]::IsNullOrWhiteSpace($CacheRoot)) {
        $CacheRoot = Join-Path -Path $StateRoot -ChildPath 'cache'
    }

    $results = New-Object System.Collections.Generic.List[object]

    foreach ($p in $Plan) {
        $clusterName = [string]$p.ClusterName
        $state = Get-AzLocalSideloadState -StateRoot $StateRoot -ClusterName $clusterName

        # Skip clusters that are neither due now nor already in flight.
        if ($null -eq $state -and $p.Status -ne 'Planned') {
            $results.Add([PSCustomObject]@{
                ClusterName = $clusterName; Action = 'Skip'; State = $p.Status; Version = [string]$p.SelectedVersion; Message = [string]$p.Message
            })
            continue
        }

        try {
            # ---------------- Terminal / in-flight state handling ----------------
            # NOTE: 'continue' inside a PowerShell switch targets the switch, not the
            # enclosing foreach, so each case uses 'break' and the kickoff is guarded
            # by 'else' to avoid falling through after handling existing state.
            if ($null -ne $state) {
                switch ([string]$state.State) {
                    'Imported' {
                        $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'None'; State = 'Imported'; Version = [string]$state.Version; Message = 'Already imported.' })
                        break
                    }
                    'Copying' {
                        if (Test-AzLocalSideloadHeartbeatStale -State $state -StaleMinutes $HeartbeatStaleMinutes) {
                            if ([int]$state.Retries -ge $MaxRetries) {
                                $state.State = 'Failed'; $state.Message = "Copy heartbeat stale and max retries ($MaxRetries) reached."
                                if ($PSCmdlet.ShouldProcess($clusterName, 'Persist Failed state (stale, retries exhausted)')) { Set-AzLocalSideloadState -StateRoot $StateRoot -State $state }
                                $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'Failed'; State = 'Failed'; Version = [string]$state.Version; Message = $state.Message })
                            }
                            else {
                                $advanced = Invoke-SideloadCopyStart -Plan $p -StateRoot $StateRoot -CacheRoot $CacheRoot -RobocopySwitches $RobocopySwitches -TaskLogonType $TaskLogonType -TaskPrincipalUserId $TaskPrincipalUserId -TaskPassword $TaskPassword -Retries ([int]$state.Retries + 1) -SkipGateFlip
                                $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'ReDrive'; State = 'Copying'; Version = [string]$p.SelectedVersion; Message = "Stale heartbeat; re-driven (retry $($advanced.Retries))." })
                            }
                        }
                        else {
                            $pct = if ([long]$state.TotalBytes -gt 0) { [math]::Round(([double]$state.CopiedBytes / [double]$state.TotalBytes) * 100, 1) } else { 0 }
                            $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'InProgress'; State = 'Copying'; Version = [string]$state.Version; Message = "Copy in progress ($pct`%, $($state.Mbps) Mbps, ETA $($state.EtaUtc))." })
                        }
                        break
                    }
                    'Copied' {
                        $imp = Complete-SideloadImport -Plan $p -State $state -StateRoot $StateRoot -UseSsl $UseSsl
                        $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'Import'; State = $imp.State; Version = [string]$state.Version; Message = $imp.Message })
                        break
                    }
                    'Failed' {
                        if ([int]$state.Retries -lt $MaxRetries) {
                            $advanced = Invoke-SideloadCopyStart -Plan $p -StateRoot $StateRoot -CacheRoot $CacheRoot -RobocopySwitches $RobocopySwitches -TaskLogonType $TaskLogonType -TaskPrincipalUserId $TaskPrincipalUserId -TaskPassword $TaskPassword -Retries ([int]$state.Retries + 1) -SkipGateFlip
                            $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'Retry'; State = 'Copying'; Version = [string]$p.SelectedVersion; Message = "Retrying copy (retry $($advanced.Retries))." })
                        }
                        else {
                            $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'Failed'; State = 'Failed'; Version = [string]$state.Version; Message = "Copy failed; max retries ($MaxRetries) reached. $($state.Message)" })
                        }
                        break
                    }
                    default {
                        # Queued / Verified / Stale - report and let next run advance.
                        $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'Observe'; State = [string]$state.State; Version = [string]$state.Version; Message = [string]$state.Message })
                        break
                    }
                }
            }
            else {
                # ---------------- No state + due now: kick off the copy ----------------
                $null = Invoke-SideloadCopyStart -Plan $p -StateRoot $StateRoot -CacheRoot $CacheRoot -RobocopySwitches $RobocopySwitches -TaskLogonType $TaskLogonType -TaskPrincipalUserId $TaskPrincipalUserId -TaskPassword $TaskPassword -Retries 0
                $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'Start'; State = 'Copying'; Version = [string]$p.SelectedVersion; Message = "Sideload started; media staged and copy task launched." })
            }
        }
        catch {
            $results.Add([PSCustomObject]@{ ClusterName = $clusterName; Action = 'Error'; State = 'Failed'; Version = [string]$p.SelectedVersion; Message = $_.Exception.Message })
        }
    }

    return $results.ToArray()
}

function Invoke-SideloadCopyStart {
    # Module-private helper (NOT exported): stage media + register the copy task.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [PSCustomObject]$Plan,
        [string]$StateRoot,
        [string]$CacheRoot,
        [string]$RobocopySwitches,
        [string]$TaskLogonType,
        [string]$TaskPrincipalUserId,
        [System.Security.SecureString]$TaskPassword,
        [int]$Retries = 0,
        [switch]$SkipGateFlip
    )

    $clusterName = [string]$Plan.ClusterName
    if (-not $PSCmdlet.ShouldProcess($clusterName, "Stage media and start sideload copy ($($Plan.SelectedVersion))")) {
        return [PSCustomObject]@{ Retries = $Retries }
    }

    # 1. Close the apply gate so Step.7 cannot apply mid-stage.
    if (-not $SkipGateFlip) {
        Set-AzLocalClusterTagsMerge -ClusterResourceId ([string]$Plan.ClusterResourceId) -Tags @{ $script:UpdateSideloadedTagName = 'False' } | Out-Null
    }

    # 2. Ensure verified media in the shared cache.
    $download = Get-AzLocalSolutionUpdateDownload -CatalogEntry $Plan.CatalogEntry -CacheRoot $CacheRoot

    # 3. Compute source + destination. SBE content lands in a named subfolder.
    if ([string]$download.PackageType -eq 'SBE') {
        $leaf = Split-Path -Path $download.MediaPath -Leaf
        $dest = Join-Path -Path ([string]$Plan.TargetPath) -ChildPath $leaf
        $mediaFileName = $leaf
    }
    else {
        $dest = [string]$Plan.TargetPath
        $mediaFileName = Split-Path -Path $download.MediaPath -Leaf
    }

    # 4. Register + start the detached copy Scheduled Task.
    $taskName = ('AzLocalSideload_{0}' -f ($clusterName -replace '[^A-Za-z0-9._-]', '_'))
    $regParams = @{
        TaskName         = $taskName
        ClusterName      = $clusterName
        Version          = [string]$Plan.SelectedVersion
        SourcePath       = [string]$download.MediaPath
        TargetPath       = $dest
        StateRoot        = $StateRoot
        RobocopySwitches = $RobocopySwitches
        LogonType        = $TaskLogonType
    }
    if ($TaskPrincipalUserId) { $regParams['PrincipalUserId'] = $TaskPrincipalUserId }
    if ($TaskPassword) { $regParams['Password'] = $TaskPassword }
    Register-AzLocalSideloadCopyTask @regParams | Out-Null

    # 5. Write initial Copying state (carrying media/dest details + retries).
    $state = New-AzLocalSideloadState -ClusterName $clusterName -Version ([string]$Plan.SelectedVersion) -State 'Copying' -TaskName $taskName -MediaPath ([string]$download.MediaPath) -TargetPath $dest
    $state.Retries = $Retries
    $state.Message = if ($Retries -gt 0) { "Copy re-driven (retry $Retries)." } else { 'Copy task launched.' }
    Set-AzLocalSideloadState -StateRoot $StateRoot -State $state

    return [PSCustomObject]@{ Retries = $Retries; MediaFileName = $mediaFileName }
}

function Complete-SideloadImport {
    # Module-private helper (NOT exported): verify remote hash + import + flip gate.
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [PSCustomObject]$Plan,
        [PSCustomObject]$State,
        [string]$StateRoot,
        [bool]$UseSsl = $true
    )

    $clusterName = [string]$Plan.ClusterName
    if (-not $PSCmdlet.ShouldProcess($clusterName, "Verify + import solution update '$($State.Version)'")) {
        return [PSCustomObject]@{ State = 'Copied'; Message = 'WhatIf - import not performed.' }
    }

    $authRow = $Plan.AuthRow
    $credential = Resolve-AzLocalSideloadCredential -AuthRow $authRow
    $authMech = if (-not [string]::IsNullOrWhiteSpace([string]$authRow.AuthMechanism)) { [string]$authRow.AuthMechanism } else { 'Negotiate' }

    $session = $null
    try {
        $session = New-AzLocalPSRemotingSession -ComputerName ([string]$Plan.RemotingHost) -Credential $credential -UseSsl $UseSsl -Authentication $authMech

        # Convert the UNC import target to the node-local path + media file path.
        $nodeImportRoot = ConvertTo-AzLocalNodeLocalPath -UncPath ([string]$Plan.TargetPath)
        $isSbe = ([string]$Plan.PackageType -eq 'SBE')
        $mediaLeaf = Split-Path -Path ([string]$State.TargetPath) -Leaf

        if ($isSbe) {
            # SBE content lives under the node import root in its named subfolder.
            $importState = Invoke-AzLocalRemoteSolutionImport -Session $session -ImportRoot $nodeImportRoot -MediaFileName $mediaLeaf -PackageType 'SBE' -Version ([string]$State.Version)
        }
        else {
            $mediaFileName = Split-Path -Path ([string]$State.MediaPath) -Leaf
            $remoteFile = Join-Path -Path $nodeImportRoot -ChildPath $mediaFileName
            $expectedSha = [string]$Plan.CatalogEntry.Sha256
            if (-not [string]::IsNullOrWhiteSpace($expectedSha)) {
                $verify = Test-AzLocalRemoteFileHash -Session $session -RemotePath $remoteFile -ExpectedSha256 $expectedSha
                if (-not $verify.Match) {
                    $State.State = 'Failed'; $State.Message = "Remote SHA256 mismatch (expected $expectedSha, got $($verify.ActualSha256))."
                    Set-AzLocalSideloadState -StateRoot $StateRoot -State $State
                    return [PSCustomObject]@{ State = 'Failed'; Message = $State.Message }
                }
            }
            $importState = Invoke-AzLocalRemoteSolutionImport -Session $session -ImportRoot $nodeImportRoot -MediaFileName $mediaFileName -PackageType 'Solution' -Version ([string]$State.Version)
        }

        switch ($importState.ImportState) {
            'Imported' {
                # Flip the gate: UpdateSideloaded=True + record the staged version.
                Set-AzLocalClusterTagsMerge -ClusterResourceId ([string]$Plan.ClusterResourceId) -Tags @{
                    $script:UpdateSideloadedTagName        = 'True'
                    $script:UpdateVersionInProgressTagName = [string]$State.Version
                } | Out-Null
                $State.State = 'Imported'; $State.Message = "Imported '$($importState.DiscoveredName)'; UpdateSideloaded=True."
                Set-AzLocalSideloadState -StateRoot $StateRoot -State $State
                if (-not [string]::IsNullOrWhiteSpace([string]$State.TaskName)) {
                    Remove-AzLocalSideloadCopyTask -TaskName ([string]$State.TaskName)
                }
                return [PSCustomObject]@{ State = 'Imported'; Message = $State.Message }
            }
            'NeedsSbe' {
                $State.State = 'Verified'; $State.Message = "Solution discovered but requires OEM SBE content (AdditionalContentRequired). Stage SBE and re-run."
                Set-AzLocalSideloadState -StateRoot $StateRoot -State $State
                return [PSCustomObject]@{ State = 'NeedsSbe'; Message = $State.Message }
            }
            'Discovering' {
                $State.Message = $importState.Message
                Set-AzLocalSideloadState -StateRoot $StateRoot -State $State
                return [PSCustomObject]@{ State = 'Discovering'; Message = $importState.Message }
            }
            default {
                $State.State = 'Failed'; $State.Message = $importState.Message
                Set-AzLocalSideloadState -StateRoot $StateRoot -State $State
                return [PSCustomObject]@{ State = 'Failed'; Message = $importState.Message }
            }
        }
    }
    finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        $credential = $null
    }
}

function ConvertTo-AzLocalNodeLocalPath {
    # Module-private helper: \\host\C$\rest -> C:\rest ; passthrough otherwise.
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$UncPath)

    $m = [regex]::Match($UncPath, '^\\\\[^\\]+\\([A-Za-z])\$\\(.*)$')
    if ($m.Success) {
        return ('{0}:\{1}' -f $m.Groups[1].Value, $m.Groups[2].Value)
    }
    return $UncPath
}
