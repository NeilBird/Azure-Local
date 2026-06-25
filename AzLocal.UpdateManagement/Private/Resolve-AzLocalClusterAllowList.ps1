function Resolve-AzLocalClusterAllowList {
    ########################################
    <#
    .SYNOPSIS
        Resolves the effective allowedUpdateVersions allow-list for a single
        cluster from a parsed apply-updates schedule (schema v2), applying the
        per-ring-override-beats-global-default precedence.

    .DESCRIPTION
        v0.9.1 mapping helper shared by the readiness assessment override.

        Given a cluster's UpdateRing tag value and the typed schedule config
        produced by Get-AzLocalApplyUpdatesScheduleConfig, this returns the
        update allow-list that applies to that cluster:

          1. PER-RING OVERRIDE (highest priority): the FIRST schedule row whose
             'rings' cell covers the cluster's ring AND carries an explicit
             'allowedUpdateVersions' override (surfaced by the schedule parser
             as row.AllowedUpdateVersionsParsed) wins. Rows are evaluated in
             schedule order, so the first matching override is deterministic.
             A row 'rings' value of '***' is treated as a wildcard matching
             every ring (the documented "every cluster" sentinel).
          2. TOP-LEVEL FLEET DEFAULT: when no matching row supplies an
             override, the schedule's top-level allowedUpdateVersions
             (cfg.AllowedUpdateVersions) is used.
          3. NONE: when neither is present, an empty allow-list is returned
             (Source = 'None').

        The reserved sentinel 'Latest' (case-insensitive, appearing ALONE)
        means "no constraint - install the latest Ready update on each
        cluster". The caller checks IsLatest to decide whether to apply the
        filter at all.

        This helper performs NO Azure calls and has no side effects - it is a
        pure decision function over the already-parsed config object, so it is
        cheap to call once per cluster and trivially unit-testable.

    .PARAMETER UpdateRing
        The cluster's 'UpdateRing' tag value. May be $null / empty (an
        untagged cluster cannot match a per-ring override, so it falls back to
        the top-level default).

    .PARAMETER Schedule
        The typed config object returned by Get-AzLocalApplyUpdatesScheduleConfig
        (exposes .AllowedUpdateVersions [string[]] and .Schedule rows each with
        .rings and .AllowedUpdateVersionsParsed).

    .OUTPUTS
        [PSCustomObject] with:
          EffectiveAllowList [string[]] the cleaned, non-empty allow-list entries
                                        (may be @('Latest'); empty when Source='None')
          Source             'RowOverride' | 'TopLevel' | 'None'
          IsLatest           [bool]    the effective list is the 'Latest' no-constraint sentinel
          MatchedRing        [string]  the ring matched to a row override, or ''
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UpdateRing,

        [Parameter(Mandatory = $true)]
        [psobject]$Schedule
    )

    Set-StrictMode -Version Latest

    # Top-level fleet default (cleaned of empty / whitespace tokens).
    $topAllow = @()
    if ($Schedule.PSObject.Properties['AllowedUpdateVersions'] -and $Schedule.AllowedUpdateVersions) {
        $topAllow = @($Schedule.AllowedUpdateVersions | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
    }

    $ring = if ($UpdateRing) { ([string]$UpdateRing).Trim() } else { '' }

    # Per-ring override: first matching row that carries an explicit override.
    $rowAllow = $null
    $matchedRing = ''
    if (-not [string]::IsNullOrWhiteSpace($ring) -and
        $Schedule.PSObject.Properties['Schedule'] -and $Schedule.Schedule) {
        foreach ($row in @($Schedule.Schedule)) {
            if (-not $row.PSObject.Properties['rings'] -or [string]::IsNullOrWhiteSpace([string]$row.rings)) {
                continue
            }
            $ringTokens = @(([string]$row.rings) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $isWildcard = ($ringTokens -contains '***')
            $isRingHit = $isWildcard -or (@($ringTokens | Where-Object {
                [string]::Equals($_, $ring, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0)
            if (-not $isRingHit) { continue }

            if ($row.PSObject.Properties['AllowedUpdateVersionsParsed'] -and $row.AllowedUpdateVersionsParsed) {
                $rowAllow = @($row.AllowedUpdateVersionsParsed | Where-Object {
                    -not [string]::IsNullOrWhiteSpace([string]$_)
                })
                $matchedRing = $ring
                break
            }
        }
    }

    if ($null -ne $rowAllow -and @($rowAllow).Count -gt 0) {
        $effective = @($rowAllow)
        $source = 'RowOverride'
    }
    elseif ($topAllow.Count -gt 0) {
        $effective = @($topAllow)
        $source = 'TopLevel'
        $matchedRing = ''
    }
    else {
        $effective = @()
        $source = 'None'
        $matchedRing = ''
    }

    $isLatest = ($effective.Count -gt 0) -and -not (@($effective | Where-Object {
        -not [string]::Equals([string]$_, 'Latest', [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0)

    return [PSCustomObject]@{
        EffectiveAllowList = $effective
        Source             = $source
        IsLatest           = $isLatest
        MatchedRing        = $matchedRing
    }
}
