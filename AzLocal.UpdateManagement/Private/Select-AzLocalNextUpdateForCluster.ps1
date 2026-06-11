function Select-AzLocalNextUpdateForCluster {
    <#
    .SYNOPSIS
        Selects the next Azure Local solution update to install for a cluster,
        applying the optional AllowedUpdateVersions allow-list and the
        latest-by-YYMM auto-pick rule.

    .DESCRIPTION
        Pure decision helper extracted from Start-AzLocalClusterUpdate (v0.8.7)
        so the apply path AND the on-prem sideloading automation agree on which
        update is "next" for a given cluster. No side effects beyond the
        Get-LatestUpdateByYYMM warning - callers own all logging, CSV, and
        result-object emission.

        Selection rules (identical to the historic Start-AzLocalClusterUpdate
        behaviour):
          - If -UpdateName is supplied, that explicit choice wins. The named
            update must be present in -ReadyUpdates (matched on 'name'),
            otherwise Reason = 'UpdateNotFound'.
          - Otherwise, when -AllowedUpdateVersions is supplied and is NOT the
            'Latest' no-constraint sentinel, the Ready pool is filtered to
            updates whose 'name' OR 'properties.version' is an EXACT
            (case-insensitive) match for a supplied entry. An empty result =
            Reason 'NotInAllowList' (strict no-op, never falls back to latest).
          - 'Latest' (case-insensitive) appearing ALONE means "no constraint";
            the filter is skipped.
          - The winner is the latest Ready update by YYMM (Get-LatestUpdateByYYMM).
          - An empty -ReadyUpdates pool yields Reason 'NoneReady'.

    .PARAMETER ReadyUpdates
        The updates already filtered to a Ready state (Ready / ReadyToInstall).

    .PARAMETER AllowedUpdateVersions
        Optional allow-list of update names / version strings. 'Latest' (alone)
        disables filtering. Empty / whitespace entries are ignored.

    .PARAMETER UpdateName
        Optional explicit update name that overrides the allow-list.

    .OUTPUTS
        [PSCustomObject] with:
          Reason             'Selected' | 'NotInAllowList' | 'UpdateNotFound' | 'NoneReady'
          SelectedUpdate     the chosen update object, or $null
          FilteredUpdates    the Ready updates passing the allow-list (array)
          AllowOnlyLatest    [bool] the allow-list was the 'Latest' sentinel
          AllowListEffective the cleaned non-empty allow-list entries (array)
          AllowDisplay       comma-joined allow-list for messaging
          ReadyDisplay       'name (vVersion)' list of Ready updates for messaging
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [array]$ReadyUpdates,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$AllowedUpdateVersions,

        [Parameter(Mandatory = $false)]
        [string]$UpdateName
    )

    $readyArr = @($ReadyUpdates | Where-Object { $null -ne $_ })
    $readyDisplay = (@($readyArr | ForEach-Object { "$($_.name) (v$($_.properties.version))" }) -join '; ')

    $allowListEffective = @($AllowedUpdateVersions | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    })
    $allowDisplay = (@($allowListEffective) -join ', ')
    $allowOnlyLatest = ($allowListEffective.Count -gt 0) -and (
        -not (@($allowListEffective | Where-Object {
            -not [string]::Equals([string]$_, 'Latest', [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0)
    )

    if ($readyArr.Count -eq 0) {
        return [PSCustomObject]@{
            Reason             = 'NoneReady'
            SelectedUpdate     = $null
            FilteredUpdates    = @()
            AllowOnlyLatest    = $allowOnlyLatest
            AllowListEffective = $allowListEffective
            AllowDisplay       = $allowDisplay
            ReadyDisplay       = $readyDisplay
        }
    }

    # Explicit -UpdateName wins over the allow-list.
    if ($UpdateName) {
        $named = @($readyArr | Where-Object { $_.name -eq $UpdateName })
        if ($named.Count -eq 0) {
            return [PSCustomObject]@{
                Reason             = 'UpdateNotFound'
                SelectedUpdate     = $null
                FilteredUpdates    = $readyArr
                AllowOnlyLatest    = $allowOnlyLatest
                AllowListEffective = $allowListEffective
                AllowDisplay       = $allowDisplay
                ReadyDisplay       = $readyDisplay
            }
        }
        return [PSCustomObject]@{
            Reason             = 'Selected'
            SelectedUpdate     = $named[0]
            FilteredUpdates    = $named
            AllowOnlyLatest    = $allowOnlyLatest
            AllowListEffective = $allowListEffective
            AllowDisplay       = $allowDisplay
            ReadyDisplay       = $readyDisplay
        }
    }

    # Allow-list filter (skipped when only 'Latest' or no list supplied).
    $pool = $readyArr
    if ($allowListEffective.Count -gt 0 -and -not $allowOnlyLatest) {
        $allowSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($a in $allowListEffective) {
            $sa = [string]$a
            if (-not [string]::IsNullOrWhiteSpace($sa)) { [void]$allowSet.Add($sa.Trim()) }
        }
        $filtered = @($readyArr | Where-Object {
            ($_.name -and $allowSet.Contains([string]$_.name)) -or
            ($_.properties -and $_.properties.version -and $allowSet.Contains([string]$_.properties.version))
        })
        if ($filtered.Count -eq 0) {
            return [PSCustomObject]@{
                Reason             = 'NotInAllowList'
                SelectedUpdate     = $null
                FilteredUpdates    = @()
                AllowOnlyLatest    = $allowOnlyLatest
                AllowListEffective = $allowListEffective
                AllowDisplay       = $allowDisplay
                ReadyDisplay       = $readyDisplay
            }
        }
        $pool = $filtered
    }

    $selected = Get-LatestUpdateByYYMM -Updates $pool
    return [PSCustomObject]@{
        Reason             = 'Selected'
        SelectedUpdate     = $selected
        FilteredUpdates    = $pool
        AllowOnlyLatest    = $allowOnlyLatest
        AllowListEffective = $allowListEffective
        AllowDisplay       = $allowDisplay
        ReadyDisplay       = $readyDisplay
    }
}
