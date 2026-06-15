function Invoke-AzLocalSideloadedAutoResetForCluster {
    <#
    .SYNOPSIS
        Evaluates and (when matched) flips UpdateSideloaded=False + clears UpdateVersionInProgress for one cluster.
    .DESCRIPTION
        Implements the auto-reset decision matrix used by Get-AzLocalUpdateRuns
        (default-on) and Reset-AzLocalSideloadedTag (explicit). Returns a single
        PSCustomObject describing the action taken or the reason it was skipped.

        Decision matrix (LatestRunState=Succeeded only - any other state -> Skipped/RunNotSucceeded):
            UpdateSideloaded absent, no version  -> NoTag (cluster opted out; nothing to do)
            UpdateSideloaded absent, orphan ver  -> OrphanCleared (clear stale UpdateVersionInProgress only)
            UpdateSideloaded=False               -> Skipped (already reset)
            UpdateSideloaded=True, no version    -> Skipped (warning: no UpdateVersionInProgress)
            UpdateSideloaded=True, mismatch      -> Skipped (mismatch reason)
            UpdateSideloaded=True, match         -> Reset (PATCH both tags)
            UpdateSideloaded=True, -Force        -> Reset (bypass match check)

        UpdateSideloaded with malformed value is treated as Skipped (with reason) so
        a typo cannot cause a silent reset.

        Orphan cleanup: if a cluster was previously updated through this module and then
        the operator removed the UpdateSideloaded tag (opting out of the workflow), the
        UpdateVersionInProgress tag would otherwise linger forever. When the latest run
        is Succeeded AND its name matches that tag, we clear it on a best-effort basis.
        We never write UpdateSideloaded in this path - the operator has explicitly opted
        out, and we only clean up our own breadcrumb.
    .PARAMETER ClusterName
        Display name of the cluster (for logging/output only).
    .PARAMETER ClusterResourceId
        Full ARM resource ID of the cluster.
    .PARAMETER LatestRunState
        State of the cluster's most recent update run (e.g. 'Succeeded', 'InProgress', 'Failed').
    .PARAMETER LatestRunUpdateName
        UpdateName of the cluster's most recent update run (used for match check).
    .PARAMETER ApiVersion
        ARM api-version for the cluster GET/PATCH.
    .PARAMETER Force
        When specified, bypasses the UpdateVersionInProgress match check and resets the
        tags as long as UpdateSideloaded=True and the latest run state is Succeeded.
    .OUTPUTS
        PSCustomObject with ClusterName, Action (Reset|OrphanCleared|Skipped|NoTag|NoRuns|RunNotSucceeded),
        PreviousSideloaded, NewSideloaded, StagedVersion, MatchedRunUpdateName, Message.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClusterName,

        [Parameter(Mandatory = $true)]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LatestRunState,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$LatestRunUpdateName,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    $result = [ordered]@{
        ClusterName          = $ClusterName
        Action               = 'Skipped'
        PreviousSideloaded   = $null
        NewSideloaded        = $null
        StagedVersion        = $null
        MatchedRunUpdateName = $LatestRunUpdateName
        Message              = ''
    }

    # GET cluster to read current tags.
    # v0.7.67: route through Invoke-AzRestJson so the stderr/stdout stream-split
    # + JSON parse error handling is centralised. The previous inline pattern
    # (`$json = az rest ... 2>&1; $cluster = $json | ConvertFrom-Json`) silently
    # corrupted parsing whenever the CLI emitted a stderr warning (e.g. the
    # cp1252 encode warning on non-UTF-8 Windows runners), which would abort
    # the auto-reset for that cluster.
    $getUri = "https://management.azure.com$ClusterResourceId`?api-version=$ApiVersion"
    $resp = Invoke-AzRestJson -Uri $getUri -Method GET
    if (-not $resp.Ok) {
        $result.Action = 'Skipped'
        $result.Message = "Failed to fetch cluster tags: $($resp.Error)"
        return [PSCustomObject]$result
    }
    $cluster = $resp.Data
    $tagSideloaded = Get-TagValue -Tags $cluster.tags -Name $script:UpdateSideloadedTagName
    $tagVersion = Get-TagValue -Tags $cluster.tags -Name $script:UpdateVersionInProgressTagName
    $result.PreviousSideloaded = $tagSideloaded
    $result.StagedVersion = $tagVersion

    # v0.8.82: independent auto-clear for the UpdateLastAttempt audit tag.
    # Runs regardless of UpdateSideloaded so it works on every fleet cluster.
    # Clear when EITHER (a) latest Succeeded run's UpdateName matches the tag's
    # recorded UpdateName, OR (b) the tag is a stale Blocked/Failed attempt
    # (>1h old) and a Succeeded run has subsequently materialised.
    $tagLastAttempt = Get-TagValue -Tags $cluster.tags -Name $script:UpdateLastAttemptTagName
    if (-not [string]::IsNullOrWhiteSpace($tagLastAttempt) -and $LatestRunState -eq 'Succeeded') {
        $parsedAttempt = ConvertFrom-AzLocalUpdateLastAttemptTagValue -Value $tagLastAttempt
        if ($parsedAttempt) {
            $shouldClear = $false
            if (-not [string]::IsNullOrWhiteSpace($parsedAttempt.UpdateName) `
                -and -not [string]::IsNullOrWhiteSpace($LatestRunUpdateName) `
                -and $parsedAttempt.UpdateName.Trim() -ieq $LatestRunUpdateName.Trim()) {
                $shouldClear = $true
            }
            elseif ($parsedAttempt.Outcome -in @('HealthCheckBlocked','Failed') `
                    -and ((Get-Date).ToUniversalTime() - $parsedAttempt.AttemptUtc).TotalHours -ge 1) {
                $shouldClear = $true
            }
            if ($shouldClear) {
                try {
                    [void](Set-AzLocalClusterTagsMerge `
                        -ClusterResourceId $ClusterResourceId `
                        -Tags @{ $script:UpdateLastAttemptTagName = $null } `
                        -ApiVersion $ApiVersion)
                    Write-Verbose "Cleared stale UpdateLastAttempt='$tagLastAttempt' for '$ClusterName' (latest run '$LatestRunUpdateName' Succeeded)."
                }
                catch {
                    Write-Verbose "Failed to clear UpdateLastAttempt for '$ClusterName': $($_.Exception.Message)"
                }
            }
        }
    }

    # 1. UpdateSideloaded tag absent
    if ([string]::IsNullOrWhiteSpace($tagSideloaded)) {
        # Orphan-cleanup branch: if there's a leftover UpdateVersionInProgress tag
        # (e.g. the cluster was updated via this module while opted-in, and the operator
        # has since removed UpdateSideloaded to opt out) and the latest run matches that
        # tag and succeeded, clear UpdateVersionInProgress on a best-effort basis. We do
        # NOT write UpdateSideloaded in this path - the cluster has explicitly opted out.
        if (-not [string]::IsNullOrWhiteSpace($tagVersion) `
            -and $LatestRunState -eq 'Succeeded' `
            -and (Test-AzLocalUpdateVersionInProgressMatch -TagValue $tagVersion -RunUpdateName $LatestRunUpdateName)) {

            if (-not $PSCmdlet.ShouldProcess($ClusterResourceId, "Clear orphan UpdateVersionInProgress (UpdateSideloaded tag absent)")) {
                $result.Action = 'NoTag'
                $result.Message = "WhatIf: would clear orphan UpdateVersionInProgress='$tagVersion'."
                return [PSCustomObject]$result
            }

            try {
                [void](Set-AzLocalClusterTagsMerge `
                    -ClusterResourceId $ClusterResourceId `
                    -Tags @{ $script:UpdateVersionInProgressTagName = $null } `
                    -ApiVersion $ApiVersion)
                $result.Action = 'OrphanCleared'
                $result.Message = "UpdateSideloaded tag absent; cleared orphan UpdateVersionInProgress='$tagVersion' (latest run '$LatestRunUpdateName' Succeeded)."
            }
            catch {
                $result.Action = 'NoTag'
                $result.Message = "UpdateSideloaded tag absent; failed to clear orphan UpdateVersionInProgress: $($_.Exception.Message)"
            }
            return [PSCustomObject]$result
        }

        $result.Action = 'NoTag'
        $result.Message = 'UpdateSideloaded tag not set; nothing to reset.'
        return [PSCustomObject]$result
    }

    # 2. Parse UpdateSideloaded - malformed -> skip (do not reset on malformed input)
    try {
        $sideloadedBool = ConvertFrom-AzLocalUpdateSideloaded -Value $tagSideloaded
    }
    catch {
        $result.Action = 'Skipped'
        $result.Message = "Malformed UpdateSideloaded tag '$tagSideloaded'; not resetting. ($($_.Exception.Message))"
        return [PSCustomObject]$result
    }

    # 3. Already False -> nothing to do
    if (-not $sideloadedBool) {
        $result.Action = 'Skipped'
        $result.Message = 'UpdateSideloaded=False already; no reset needed.'
        return [PSCustomObject]$result
    }

    # 4. Latest run must be Succeeded
    if ([string]::IsNullOrWhiteSpace($LatestRunState)) {
        # Distinct from "RunNotSucceeded" - cluster has no run history at all.
        # Surface as its own action so operators can tell "no runs yet" apart from
        # "latest run is InProgress / Failed".
        $result.Action = 'NoRuns'
        $result.Message = 'Cluster has no update runs yet; UpdateSideloaded preserved.'
        return [PSCustomObject]$result
    }
    if ($LatestRunState -ne 'Succeeded') {
        $result.Action = 'RunNotSucceeded'
        $result.Message = "Latest run state is '$LatestRunState'; UpdateSideloaded preserved (will be reset when a matching run succeeds)."
        return [PSCustomObject]$result
    }

    # 5. Match check (unless -Force)
    if (-not $Force) {
        if ([string]::IsNullOrWhiteSpace($tagVersion)) {
            $result.Action = 'Skipped'
            $result.Message = "UpdateSideloaded=True with no UpdateVersionInProgress tag (run started outside this module?). Skipping; use Reset-AzLocalSideloadedTag -Force to override."
            return [PSCustomObject]$result
        }
        if (-not (Test-AzLocalUpdateVersionInProgressMatch -TagValue $tagVersion -RunUpdateName $LatestRunUpdateName)) {
            $result.Action = 'Skipped'
            $result.Message = "Latest succeeded run '$LatestRunUpdateName' does not match UpdateVersionInProgress '$tagVersion'; UpdateSideloaded preserved."
            return [PSCustomObject]$result
        }
    }

    # 6. Perform the flip
    $describe = if ($Force) { "force-reset (skipping version match)" } else { "matched version '$tagVersion'" }
    if (-not $PSCmdlet.ShouldProcess($ClusterResourceId, "Reset UpdateSideloaded=False, clear UpdateVersionInProgress ($describe)")) {
        $result.Action = 'Skipped'
        $result.Message = 'WhatIf: would reset UpdateSideloaded=False and clear UpdateVersionInProgress.'
        return [PSCustomObject]$result
    }

    try {
        [void](Set-AzLocalClusterTagsMerge `
            -ClusterResourceId $ClusterResourceId `
            -Tags @{
                $script:UpdateSideloadedTagName        = 'False'
                $script:UpdateVersionInProgressTagName = $null
            } `
            -ApiVersion $ApiVersion)
        $result.Action = 'Reset'
        $result.NewSideloaded = 'False'
        $result.Message = if ($Force) {
            "UpdateSideloaded reset to False and UpdateVersionInProgress cleared (forced)."
        } else {
            "UpdateSideloaded reset to False and UpdateVersionInProgress cleared (matched run '$LatestRunUpdateName')."
        }
    }
    catch {
        $result.Action = 'Skipped'
        $result.Message = "Failed to PATCH tags: $($_.Exception.Message)"
    }

    return [PSCustomObject]$result
}
