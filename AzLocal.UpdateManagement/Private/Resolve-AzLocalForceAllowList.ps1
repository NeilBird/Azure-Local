function Resolve-AzLocalForceAllowList {
    ########################################
    <#
    .SYNOPSIS
        Resolves the effective allowedUpdateVersions allow-list to honor for a
        FORCE (break-glass) run, given the operator's manual UpdateRing input
        (which may be a single ring, a ';'-joined list, or the '***' wildcard)
        and a parsed apply-updates schedule (schema v2).

    .DESCRIPTION
        v0.9.15 helper for the ForceImmediateUpdate path of
        Resolve-AzLocalPipelineUpdateRing.

        A FORCE run deliberately bypasses the schedule WINDOW (day/week/time
        gating) so an operator can patch outside the maintenance window. It
        must NOT, however, bypass the version allow-list: when a specific ring
        (or the fleet-wide global default) constrains which update versions are
        permitted, that constraint still applies to the forced run. Only when
        NO allow-list is configured for the target ring(s) or globally does the
        run fall back to "install the latest Ready update".

        Precedence (matching the module's scheduled-path resolver, but matching
        rows by RING instead of by date/window):

          1. PER-RING OVERRIDE (highest): the UNION of allowedUpdateVersions
             overrides across every schedule row that covers one of the target
             rings (a row 'rings' value of '***' is a wildcard covering every
             ring; a target ring of '***'/'*' means "all rings" and matches
             every row). Rows WITHOUT an explicit override contribute nothing.
             When any covering row supplies an override the top-level global is
             IGNORED (Source = 'RowOverride').
          2. TOP-LEVEL GLOBAL DEFAULT: when no covering row supplies an
             override, the schedule's top-level allowedUpdateVersions is used
             (Source = 'TopLevel').
          3. NONE: neither present -> empty allow-list (Source = 'None').

        The reserved sentinel 'Latest' (case-insensitive, appearing ALONE in
        the effective list) means "no constraint - install the latest Ready
        update". In that case EffectiveAllowList is returned empty and IsLatest
        is $true, so the caller emits no allow-list filter.

        Pure decision function: NO Azure calls, no side effects.

    .PARAMETER UpdateRing
        The operator's manual UpdateRing input. May be a single ring
        ('Ring0'), a ';'-joined list ('Ring0;Ring1'), the '***' / '*' wildcard,
        or $null / empty. Whitespace around tokens is trimmed.

    .PARAMETER Schedule
        The typed config object returned by Get-AzLocalApplyUpdatesScheduleConfig
        (exposes .AllowedUpdateVersions [string[]] and .Schedule rows each with
        .rings and .AllowedUpdateVersionsParsed).

    .OUTPUTS
        [PSCustomObject] with:
          EffectiveAllowList         [string[]] cleaned allow-list entries to
                                                apply (empty when Source='None'
                                                or when the list is the 'Latest'
                                                no-constraint sentinel)
          AllowedUpdateVersionsValue [string]   the ';'-joined string form of
                                                EffectiveAllowList (empty string
                                                when no constraint) - ready to
                                                assign to the resolver's
                                                RESOLVED_ALLOWED_UPDATE_VERSIONS
                                                step output
          Source                     'RowOverride' | 'TopLevel' | 'None'
          IsLatest                   [bool]     effective list is the 'Latest'
                                                no-constraint sentinel
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

    # Parse the manual UpdateRing input into target ring tokens.
    $targetRings = @()
    if ($UpdateRing) {
        $targetRings = @(([string]$UpdateRing) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $wantsAll = (@($targetRings | Where-Object { $_ -eq '***' -or $_ -eq '*' }).Count -gt 0)

    # Top-level (fleet-wide global) default, cleaned of empty / whitespace tokens.
    $topAllow = @()
    if ($Schedule.PSObject.Properties['AllowedUpdateVersions'] -and $Schedule.AllowedUpdateVersions) {
        $topAllow = @($Schedule.AllowedUpdateVersions | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
    }

    # Union of per-ring overrides across every row that covers a target ring.
    $rowUnion = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ($Schedule.PSObject.Properties['Schedule'] -and $Schedule.Schedule) {
        foreach ($row in @($Schedule.Schedule)) {
            if (-not $row.PSObject.Properties['rings'] -or [string]::IsNullOrWhiteSpace([string]$row.rings)) {
                continue
            }
            $ringTokens = @(([string]$row.rings) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $rowIsWildcard = ($ringTokens -contains '***')
            $covers = $wantsAll -or $rowIsWildcard -or (@($ringTokens | Where-Object {
                $tok = $_
                @($targetRings | Where-Object {
                    [string]::Equals($_, $tok, [System.StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
            }).Count -gt 0)
            if (-not $covers) { continue }

            if ($row.PSObject.Properties['AllowedUpdateVersionsParsed'] -and $row.AllowedUpdateVersionsParsed) {
                foreach ($v in @($row.AllowedUpdateVersionsParsed)) {
                    $sv = [string]$v
                    if (-not [string]::IsNullOrWhiteSpace($sv) -and $seen.Add($sv.Trim())) {
                        $rowUnion.Add($sv.Trim()) | Out-Null
                    }
                }
            }
        }
    }

    if ($rowUnion.Count -gt 0) {
        $effective = $rowUnion.ToArray()
        $source = 'RowOverride'
    }
    elseif ($topAllow.Count -gt 0) {
        $effective = @($topAllow)
        $source = 'TopLevel'
    }
    else {
        $effective = @()
        $source = 'None'
    }

    $isLatest = (@($effective).Count -gt 0) -and -not (@($effective | Where-Object {
        -not [string]::Equals([string]$_, 'Latest', [System.StringComparison]::OrdinalIgnoreCase)
    }).Count -gt 0)

    if ($isLatest) {
        $outList = @()
        $value = ''
    }
    else {
        $outList = @($effective)
        $value = ($outList -join ';')
    }

    return [PSCustomObject]@{
        EffectiveAllowList         = $outList
        AllowedUpdateVersionsValue = $value
        Source                     = $source
        IsLatest                   = $isLatest
    }
}
