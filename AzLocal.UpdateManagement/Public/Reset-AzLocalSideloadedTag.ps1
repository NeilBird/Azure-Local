function Reset-AzLocalSideloadedTag {
    <#
    .SYNOPSIS
        Resets the UpdateSideloaded tag (True->False) and clears UpdateVersionInProgress
        on Azure Local clusters whose latest update run has succeeded.
    .DESCRIPTION
        Provides an explicit, scope-required entry point for the same auto-reset logic
        invoked by Get-AzLocalUpdateRuns. Use this for:
        - Manual cleanup after an out-of-band update where Get-AzLocalUpdateRuns
          was not run (or was run with -SkipSideloadedReset).
        - Forcing a reset (-Force) when an UpdateSideloaded=True tag is stuck because
          the operator abandoned the staged payload, or UpdateVersionInProgress is
          missing/mismatched.

        For each in-scope cluster the function fetches the latest update run, then
        applies the same decision matrix:
            UpdateSideloaded absent              -> NoTag
            UpdateSideloaded=False               -> Skipped (already reset)
            Latest run state != Succeeded        -> RunNotSucceeded (preserved)
            UpdateSideloaded=True, no version    -> Skipped (use -Force to override)
            UpdateSideloaded=True, mismatch      -> Skipped (use -Force to override)
            UpdateSideloaded=True, match         -> Reset
            -Force                               -> Reset (bypasses match check; still
                                                     requires latest run state Succeeded)

        Scope must be explicit (no implicit -AllClusters): supply -ClusterNames,
        -ClusterResourceIds, or -ScopeByUpdateRingTag/-UpdateRingValue.
    .PARAMETER ClusterNames
        One or more cluster names to evaluate.
    .PARAMETER ClusterResourceIds
        One or more full ARM cluster resource IDs to evaluate.
    .PARAMETER ScopeByUpdateRingTag
        Selects clusters by an UpdateRing tag value via Azure Resource Graph.
        Must be paired with -UpdateRingValue.
    .PARAMETER UpdateRingValue
        The UpdateRing tag value to match when -ScopeByUpdateRingTag is used.
    .PARAMETER ResourceGroupName
        Optional - scopes -ClusterNames lookup to a single resource group.
    .PARAMETER SubscriptionId
        Optional - subscription context. Defaults to the current az subscription.
    .PARAMETER ApiVersion
        ARM api-version. Default is the module's default API version.
    .PARAMETER Force
        Bypasses the UpdateVersionInProgress match check. Still requires the cluster's
        latest run state to be 'Succeeded'.
    .OUTPUTS
        PSCustomObject[] - one row per cluster with ClusterName, Action, PreviousSideloaded,
        NewSideloaded, StagedVersion, MatchedRunUpdateName, Message.
    .EXAMPLE
        Reset-AzLocalSideloadedTag -ClusterNames 'cl-01','cl-02'
    .EXAMPLE
        Reset-AzLocalSideloadedTag -ScopeByUpdateRingTag -UpdateRingValue 'Wave1'
    .EXAMPLE
        # Force-clear stuck tag (operator abandoned the staged payload)
        Reset-AzLocalSideloadedTag -ClusterNames 'cl-03' -Force -Confirm:$false
    .NOTES
        Requires az CLI authenticated with Microsoft.Resources/tags/read +
        Microsoft.Resources/tags/write on the cluster scope. No additional RBAC
        beyond what is already required by Set-AzLocalClusterUpdateRingTag.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'ByName')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName')]
        [string[]]$ClusterNames,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByResourceId')]
        [string[]]$ClusterResourceIds,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [switch]$ScopeByUpdateRingTag,

        [ValidatePattern('^(\*\*\*|[A-Za-z0-9_-]{1,64}(;[A-Za-z0-9_-]{1,64})*)$')]
        [Parameter(Mandatory = $true, ParameterSetName = 'ByTag')]
        [string]$UpdateRingValue,

        [Parameter(Mandatory = $false, ParameterSetName = 'ByName')]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    Test-AzCliAvailable | Out-Null

    if (-not $SubscriptionId) {
        $SubscriptionId = (az account show --query id -o tsv)
    }

    # Resolve in-scope clusters to {Name, ResourceId}
    $targets = @()
    switch ($PSCmdlet.ParameterSetName) {
        'ByResourceId' {
            foreach ($rid in $ClusterResourceIds) {
                if ($rid -match '/clusters/([^/]+)$') {
                    $targets += [PSCustomObject]@{ Name = $matches[1]; ResourceId = $rid }
                }
                else {
                    # v0.7.67: surface malformed inputs explicitly. The other
                    # resolvers below ('ByName', 'ByTag') warn on lookup
                    # failure - the ByResourceId path previously dropped
                    # malformed entries (typos, trailing slash, wrong provider)
                    # without any operator-visible signal, so the operator
                    # never noticed the entry was excluded from the reset.
                    Write-Log -Message "Reset-AzLocalSideloadedTag: skipping '$rid' - does not match an Azure Local cluster Resource ID (must end in '/clusters/<name>')." -Level Warning
                }
            }
        }
        'ByName' {
            foreach ($name in $ClusterNames) {
                $info = Get-AzLocalClusterInfo -ClusterName $name `
                    -ResourceGroupName $ResourceGroupName `
                    -SubscriptionId $SubscriptionId `
                    -ApiVersion $ApiVersion
                if ($info) {
                    $targets += [PSCustomObject]@{ Name = $name; ResourceId = $info.id }
                }
                else {
                    Write-Log -Message "Cluster '$name' not found - skipping." -Level Warning
                }
            }
        }
        'ByTag' {
            # v0.7.66: support semicolon-delimited rings and '*' (match all).
            $ringFilter = ConvertTo-AzLocalUpdateRingKqlFilter -UpdateRingValue $UpdateRingValue
            $globalTagFilter = Get-AzLocalClusterTagFilterKqlClause
            $kqlQuery = @"
resources
| where type =~ 'microsoft.azurestackhci/clusters'
$globalTagFilter
$ringFilter
| project name, id
"@
            $rows = Invoke-AzResourceGraphQuery -Query $kqlQuery
            foreach ($row in $rows) {
                $targets += [PSCustomObject]@{ Name = $row.name; ResourceId = $row.id }
            }
        }
    }

    if ($targets.Count -eq 0) {
        Write-Log -Message "Reset-AzLocalSideloadedTag: no matching clusters found." -Level Warning
        return @()
    }

    Write-Log -Message "Reset-AzLocalSideloadedTag: evaluating $($targets.Count) cluster(s)..." -Level Info

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        # Fetch the latest update run state + name
        $latestRun = Get-AzLocalClusterUpdateRuns -resourceId $t.ResourceId -updateNameFilter $null -apiVer $ApiVersion |
            Sort-Object { $_.properties.timeStarted } -Descending |
            Select-Object -First 1

        $state = ''
        $updName = ''
        if ($latestRun) {
            $state = [string]$latestRun.properties.state
            if ($latestRun.id -match '/updates/([^/]+)/updateRuns/') {
                $updName = $matches[1]
            }
        }

        # Honour -WhatIf / -Confirm. ShouldProcess gates the per-cluster
        # tag mutation; the underlying helper still no-ops on NoTag / NoRuns /
        # RunNotSucceeded states so this prompt only fires for clusters where
        # a tag write could actually occur.
        if (-not $PSCmdlet.ShouldProcess($t.Name, 'Reset UpdateSideloaded tag')) {
            Write-Log -Message "[$($t.Name)] Skipped (ShouldProcess declined)." -Level Info
            continue
        }

        $r = Invoke-AzLocalSideloadedAutoResetForCluster `
            -ClusterName $t.Name `
            -ClusterResourceId $t.ResourceId `
            -LatestRunState $state `
            -LatestRunUpdateName $updName `
            -ApiVersion $ApiVersion `
            -Force:$Force
        switch ($r.Action) {
            'Reset'           { Write-Log -Message "[$($t.Name)] $($r.Message)" -Level Success }
            'OrphanCleared'   { Write-Log -Message "[$($t.Name)] $($r.Message)" -Level Info }
            'NoTag'           { Write-Log -Message "[$($t.Name)] $($r.Message)" -Level Info }
            'NoRuns'          { Write-Log -Message "[$($t.Name)] $($r.Message)" -Level Info }
            'RunNotSucceeded' { Write-Log -Message "[$($t.Name)] $($r.Message)" -Level Info }
            default           { Write-Log -Message "[$($t.Name)] $($r.Message)" -Level Warning }
        }
        $results.Add($r) | Out-Null
    }

    return $results.ToArray()
}
