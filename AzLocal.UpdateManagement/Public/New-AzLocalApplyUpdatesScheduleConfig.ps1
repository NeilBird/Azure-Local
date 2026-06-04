function New-AzLocalApplyUpdatesScheduleConfig {
    <#
    .SYNOPSIS
        Generates a STRAWMAN apply-updates-schedule.yml (schema v1) from
        either the live fleet's UpdateRing tag values or an explicit
        list of rings. The generated schedule rows are intentionally
        commented OUT so the operator must consciously review and
        opt-in to each ring's firing window before the pipeline can run.

    .DESCRIPTION
        v0.7.69 onboarding helper. Run this once after tagging your
        fleet with Set-AzLocalClusterUpdateRingTag - it discovers
        every distinct UpdateRing tag value via Azure Resource Graph,
        sorts them into a safe-by-default order (canary-like names
        first, prod-like names last), and writes a strawman schedule
        that allocates each ring to its own week in the cycle on
        Mon-Thu. Every generated row is emitted as a COMMENTED-OUT
        block in the YAML so the operator must explicitly uncomment
        (and edit) each row before the apply-updates pipeline will
        run.

        Why commented out?
          Choosing which UpdateRing fires on which day of which week
          is a CHANGE-CONTROL decision. The generator has no insight
          into the operator's risk appetite, change-freeze windows,
          regulatory constraints, or business rhythms. Emitting live
          rows would make those decisions silently. Emitting commented
          rows makes the operator confirm them.

        Safety gate (no edits required):
          Get-AzLocalApplyUpdatesScheduleConfig throws when the
          schedule list is empty, and the apply-updates pipeline calls
          that reader before resolving the current ring. So a strawman
          file with every row commented out is a hard STOP for the
          pipeline until the operator uncomments at least one row.

        Default behaviour:
          * Discovery: Azure Resource Graph query (same shape as
            Test-AzLocalApplyUpdatesScheduleCoverage uses) over the
            current subscription (or -SubscriptionId).
          * Ordering: rings whose name starts with 'canary', 'dev', or
            'test' (case-insensitive) sort first; rings whose name
            starts with 'prod' sort last; the rest sort lexically in
            the middle. Tie-breakers are alphabetical.
          * CycleWeeks: max(N rings, 4) so adding a 5th ring later
            doesn't immediately force a cycle bump.
          * CycleAnchor: the current ISO week / year (UTC). Operators
            can edit afterwards.
          * Schedule rows: one COMMENTED-OUT block per discovered ring,
            on Mon-Thu, with a generated 'notes' line documenting the
            heuristic. Uncomment after review.

        The output is intentionally a STARTING POINT, not a finished
        schedule. After uncommenting at least one row, run
        Get-AzLocalApplyUpdatesScheduleNextFirings against the result
        to preview what each day in the first cycle will do.

    .PARAMETER OutputPath
        Where to write the generated file. Default: '.\apply-updates-schedule.yml'.

    .PARAMETER SubscriptionId
        Optional. Subscription scope for the discovery query. Default:
        current az context subscription.

    .PARAMETER Rings
        Optional explicit list of UpdateRing values. If supplied, the
        Resource Graph query is skipped entirely (offline mode, useful
        for tests and air-gapped bootstrapping).

    .PARAMETER CycleWeeks
        Optional override for the generated cycleWeeks value. Default:
        max(N rings, 4). Must be 1..52.

    .PARAMETER Force
        Overwrite -OutputPath if it already exists. Without this switch
        the cmdlet refuses to overwrite (so an operator who edited the
        file and then re-ran the generator by mistake does not lose
        their work).

    .OUTPUTS
        [System.IO.FileInfo] of the written file.

    .EXAMPLE
        New-AzLocalApplyUpdatesScheduleConfig -OutputPath .\apply-updates-schedule.yml

    .EXAMPLE
        New-AzLocalApplyUpdatesScheduleConfig -Rings 'Canary','Ring1','Ring2','Prod' -OutputPath .\schedule.yml
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath = '.\apply-updates-schedule.yml',

        [Parameter(Mandatory = $false)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [string[]]$Rings,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 52)]
        [int]$CycleWeeks = 0,

        [Parameter(Mandatory = $false)]
        [switch]$Force
    )

    # ---- 1. Resolve OutputPath + overwrite guard ----------------------
    $resolvedOut = if ([IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath
    } else {
        Join-Path (Get-Location).Path $OutputPath
    }
    if ((Test-Path -LiteralPath $resolvedOut) -and -not $Force) {
        throw "New-AzLocalApplyUpdatesScheduleConfig: '$resolvedOut' already exists. Pass -Force to overwrite, or pick a different -OutputPath."
    }

    # ---- 2. Discover (or accept) the ring list ----------------------
    if (-not $Rings -or @($Rings).Count -eq 0) {
        $kql = @"
resources
| where type =~ 'microsoft.azurestackhci/clusters'
| project UpdateRing = tostring(tags['UpdateRing'])
| where isnotempty(UpdateRing)
| distinct UpdateRing
"@
        Write-Log -Message "Discovering UpdateRing tag values via Azure Resource Graph..." -Level Info
        $rows = if ($SubscriptionId) {
            Invoke-AzResourceGraphQuery -Query $kql -SubscriptionId $SubscriptionId
        } else {
            Invoke-AzResourceGraphQuery -Query $kql
        }
        $Rings = @($rows | ForEach-Object { $_.UpdateRing } | Where-Object { $_ } | Select-Object -Unique)
        if (@($Rings).Count -eq 0) {
            throw "No clusters with an UpdateRing tag were found. Tag the fleet first via Set-AzLocalClusterUpdateRingTag, then re-run."
        }
        Write-Log -Message "Discovered $($Rings.Count) distinct UpdateRing value(s): $($Rings -join ', ')." -Level Info
    } else {
        Write-Log -Message "Using $($Rings.Count) explicit ring value(s) from -Rings parameter (skipping Resource Graph discovery)." -Level Info
    }

    # ---- 3. Sort: canary-like first, prod-like last, rest in middle ---
    function Get-AzLocalRingSortKey([string]$ring) {
        $low = $ring.ToLowerInvariant()
        # 0 = canary/dev/test (first), 1 = middle, 2 = prod (last)
        if ($low -match '^(canary|dev|test)') { return 0 }
        if ($low -match '^prod')              { return 2 }
        return 1
    }
    $sorted = @($Rings | Sort-Object @{Expression = { Get-AzLocalRingSortKey $_ } }, @{Expression = { $_ }})

    # ---- 4. CycleWeeks default = max(N rings, 4) -----------------------
    if ($CycleWeeks -eq 0) {
        $CycleWeeks = [Math]::Max($sorted.Count, 4)
    }
    if ($sorted.Count -gt $CycleWeeks) {
        throw "New-AzLocalApplyUpdatesScheduleConfig: -CycleWeeks ($CycleWeeks) is smaller than the discovered ring count ($($sorted.Count)). Increase -CycleWeeks or use the union row pattern (edit by hand after generation)."
    }

    # ---- 5. Compute anchor (this week, this ISO year) ------------------
    function Get-AzLocalCurrentISOWeek {
        $d = [datetime]::UtcNow.Date
        $dayIso = ((($d.DayOfWeek.value__ + 6) % 7))
        $thu = $d.AddDays(3 - $dayIso)
        $yr = $thu.Year
        $jan4 = [datetime]::new($yr, 1, 4, 0, 0, 0, [DateTimeKind]::Utc)
        $jan4Iso = ((($jan4.DayOfWeek.value__ + 6) % 7))
        $w1Mon = $jan4.AddDays(-1 * $jan4Iso)
        $wk = [int]([math]::Floor(($thu - $w1Mon).TotalDays / 7)) + 1
        [pscustomobject]@{ Year = $yr; Week = $wk }
    }
    $iso = Get-AzLocalCurrentISOWeek

    # ---- 6. Emit YAML text --------------------------------------------
    # Worked example date for the cycle-anchor comment block: Monday of
    # ISO Week 1 of the anchor year. Computed dynamically so it stays
    # accurate regardless of which year the generator runs in. NOTE:
    # this is illustrative only - the actual anchor written below is
    # the CURRENT ISO week (so week 1 of the cycle = the week you ran
    # the generator); operators can edit if they prefer a January 1
    # reset or a fiscal-year anchor.
    $jan4 = [datetime]::new($iso.Year, 1, 4, 0, 0, 0, [DateTimeKind]::Utc)
    $jan4Iso = ((($jan4.DayOfWeek.value__ + 6) % 7))
    $w1Mon = $jan4.AddDays(-1 * $jan4Iso)
    $w1MonStr = $w1Mon.ToString('dddd, dd MMMM yyyy', [Globalization.CultureInfo]::InvariantCulture)
    $cycleDays = $CycleWeeks * 7

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# =====================================================================')
    [void]$sb.AppendLine('# apply-updates-schedule.yml - schema v1   *** STRAWMAN - REVIEW REQUIRED ***')
    [void]$sb.AppendLine("# Generated by New-AzLocalApplyUpdatesScheduleConfig on $([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC.")
    [void]$sb.AppendLine('# =====================================================================')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# This is the single source of truth for "which UpdateRing(s) is/are')
    [void]$sb.AppendLine('# eligible to apply updates on a given UTC date". It is consumed by:')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('#   * Step.6_apply-updates.yml    - reads it at every cron firing and')
    [void]$sb.AppendLine('#                                   resolves the UpdateRingValue to use')
    [void]$sb.AppendLine('#                                   for that run.')
    [void]$sb.AppendLine('#   * Step.3_apply-updates-schedule-audit.yml')
    [void]$sb.AppendLine('#                                 - audits this file against the live')
    [void]$sb.AppendLine('#                                   fleet (UpdateRing + UpdateStartWindow')
    [void]$sb.AppendLine('#                                   tags) and emits a two-way coverage')
    [void]$sb.AppendLine('#                                   delta.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# KEY CONCEPT - three independent layers control "what runs when":')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('#   1. This file (day-grain): the calendar week / day of week says')
    [void]$sb.AppendLine('#      WHICH UpdateRing tag values are eligible TODAY in UTC.')
    [void]$sb.AppendLine('#   2. The Step.5 cron schedule (intra-day-grain): says HOW OFTEN the')
    [void]$sb.AppendLine('#      apply-updates job wakes up (e.g. hourly).')
    [void]$sb.AppendLine('#   3. Per-cluster `UpdateStartWindow` tag (minute-grain): says WHEN, during')
    [void]$sb.AppendLine('#      an eligible day, the actual update is allowed to start.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# A cron firing that lands on a day with NO matching schedule rows is')
    [void]$sb.AppendLine('# logged and exits 0 - no errors, no failures.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# !!! IMPORTANT - CHANGE-CONTROL DECISION REQUIRED !!!')
    [void]$sb.AppendLine('# Every row below is a COMMENTED-OUT proposal generated from a heuristic')
    [void]$sb.AppendLine('# (canary/dev/test first, prod last, one ring per week, Mon-Thu). The')
    [void]$sb.AppendLine('# generator has NO insight into your risk appetite, change-freeze')
    [void]$sb.AppendLine('# windows, regulatory constraints, or business rhythms. Choosing which')
    [void]$sb.AppendLine('# UpdateRing fires on which day of which week is YOUR decision and your')
    [void]$sb.AppendLine("# organisation's responsibility - the module author accepts no liability")
    [void]$sb.AppendLine('# for outages caused by an unreviewed schedule.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# Review each row, edit weeksInCycle / daysOfWeek / rings / notes as')
    [void]$sb.AppendLine('# needed, then UNCOMMENT (remove the leading "# ") to activate it. The')
    [void]$sb.AppendLine('# apply-updates pipeline will hard-fail until at least one row is')
    [void]$sb.AppendLine("# active (Get-AzLocalApplyUpdatesScheduleConfig throws 'schedule:' list")
    [void]$sb.AppendLine('# is empty - at least one row is required).')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# After uncommenting, preview the cycle BEFORE committing:')
    [void]$sb.AppendLine('#   Get-AzLocalApplyUpdatesScheduleNextFirings `')
    [void]$sb.AppendLine("#     -Schedule (Get-AzLocalApplyUpdatesScheduleConfig -Path .\apply-updates-schedule.yml)")
    [void]$sb.AppendLine('# =====================================================================')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('schemaVersion:        2')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# ---- AllowedUpdateVersions (schema v2, MANDATORY top-level) -------')
    [void]$sb.AppendLine('# >>> ALLOWED-UPDATE-VERSIONS-V2 <<<')
    [void]$sb.AppendLine('# Fleet-wide allow-list of Azure Local solution-update names or')
    [void]$sb.AppendLine('# version strings that Step.6 (apply-updates) is permitted to install.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine("# Default 'Latest' (case-insensitive) is a reserved sentinel meaning")
    [void]$sb.AppendLine("# 'no constraint - install the latest Ready update on each cluster'")
    [void]$sb.AppendLine('# (the historic v0.7.88 default). Keeping it as Latest preserves the')
    [void]$sb.AppendLine('# pre-v2 behaviour.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine("# To enforce a 'minimum updates' policy (~4 updates per year - YY04 +")
    [void]$sb.AppendLine('# YY10 feature updates plus the preceding YY03 + YY09 cumulative')
    [void]$sb.AppendLine("# updates), replace 'Latest' with a semicolon-separated list of")
    [void]$sb.AppendLine('# explicit update names or version strings. Clusters with no Ready')
    [void]$sb.AppendLine("# update matching the list are SKIPPED with status 'NotInAllowList'")
    [void]$sb.AppendLine("# (strict no-op; never falls back to 'latest').")
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine("# Format: semicolon-separated string (same convention as 'rings:').")
    [void]$sb.AppendLine('# Per-row override: any schedule row below may set its own')
    [void]$sb.AppendLine("# 'allowedUpdateVersions:' field. Per-row beats top-level; multiple")
    [void]$sb.AppendLine("# matching rows UNION their lists; rows without the field on a UNION")
    [void]$sb.AppendLine("# day are treated as 'no opinion' (not 'allow nothing'); if any")
    [void]$sb.AppendLine("# matching row contributes 'Latest', the effective list is 'Latest'")
    [void]$sb.AppendLine('# (no constraint).')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# Example (replace the line below with explicit versions to opt-in):')
    [void]$sb.AppendLine("#   allowedUpdateVersions: '10.2604.0.123;10.2610.0.456'")
    [void]$sb.AppendLine("allowedUpdateVersions: 'Latest'")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# ---- Cycle anchor --------------------------------------------------')
    [void]$sb.AppendLine('# Every cron firing in UTC is mapped to a (cycleWeek, dayOfWeek) pair')
    [void]$sb.AppendLine('# relative to this anchor. After `cycleWeeks` weeks the calendar loops')
    [void]$sb.AppendLine('# back to cycleWeek=1.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# ISO reference: https://en.wikipedia.org/wiki/ISO_week_date')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine("# Worked example (illustrative): ISO Week 1 of $($iso.Year) began on $w1MonStr.")
    [void]$sb.AppendLine("# With cycleWeeks = $CycleWeeks the schedule repeats every $CycleWeeks weeks ($cycleDays days);")
    [void]$sb.AppendLine('# once the cycle completes, the resolver wraps back to cycleWeek = 1.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# cycleAnchorISOWeek + cycleAnchorYear identify the ISO-8601 week that')
    [void]$sb.AppendLine('# is "week 1" of the cycle. cycleWeeks tells the resolver when to wrap.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# The generator anchored this file at the CURRENT ISO week so that')
    [void]$sb.AppendLine('# "week 1 of the cycle" = the week you ran the generator. Edit the two')
    [void]$sb.AppendLine('# anchor fields below if you want the cycle to start at a different')
    [void]$sb.AppendLine('# point (e.g. ISO Week 1 of the year for a January 1 reset, or week N')
    [void]$sb.AppendLine('# to align with a fiscal-year boundary).')
    [void]$sb.AppendLine("cycleWeeks:           $CycleWeeks")
    [void]$sb.AppendLine("cycleAnchorISOWeek:   $($iso.Week)")
    [void]$sb.AppendLine("cycleAnchorYear:      $($iso.Year)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('# ---- Schedule entries ----------------------------------------------')
    [void]$sb.AppendLine('# UNION semantics: if multiple rows match the current (cycleWeek, dow)')
    [void]$sb.AppendLine("# tuple, the resolver concatenates their 'rings' columns with ';' and")
    [void]$sb.AppendLine("# passes the result to -UpdateRingValue. Wildcards: '*' on weeksInCycle")
    [void]$sb.AppendLine('# or daysOfWeek means "every week" / "every day". Ranges (1-4) and')
    [void]$sb.AppendLine('# comma lists (1,3,5) are both supported.')
    [void]$sb.AppendLine('#')
    [void]$sb.AppendLine('# Fields:')
    [void]$sb.AppendLine("#   weeksInCycle  '*' | 'N' | 'N-M' | 'N,M,P,...'  (1..cycleWeeks)")
    [void]$sb.AppendLine("#   daysOfWeek    '*' | 'Mon' | 'Mon-Fri' | 'Tue,Thu' | 0-6 form")
    [void]$sb.AppendLine('#                 (0=Sun, 1=Mon, ... 6=Sat)')
    [void]$sb.AppendLine("#   rings         ';'-separated UpdateRing tag values, or '***' for")
    [void]$sb.AppendLine('#                 every cluster carrying an UpdateRing tag (use with')
    [void]$sb.AppendLine('#                 care - matches the Set/Start cmdlet semantics).')
    [void]$sb.AppendLine('#   notes         Free text. Surfaced in audit reports and ITSM')
    [void]$sb.AppendLine('#                 tickets. Recommended: change-control reference.')
    [void]$sb.AppendLine("#   allowedUpdateVersions  OPTIONAL (schema v2). ';'-separated allow-list of update")
    [void]$sb.AppendLine("#                 names or version strings. When set on a row, it OVERRIDES the")
    [void]$sb.AppendLine("#                 top-level allowedUpdateVersions for that (cycleWeek, dayOfWeek)")
    [void]$sb.AppendLine('#                 match. Useful for per-ring policies (e.g. canary ring gets new')
    [void]$sb.AppendLine('#                 cumulative immediately, prod ring waits for the feature update).')
    [void]$sb.AppendLine('schedule:')
    [void]$sb.AppendLine('  # ---------------------------------------------------------------')
    [void]$sb.AppendLine('  # STRAWMAN ROWS - all commented out. Uncomment after review.')
    [void]$sb.AppendLine('  # ---------------------------------------------------------------')
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $ring = $sorted[$i]
        $weekN = $i + 1
        $note = if ((Get-AzLocalRingSortKey $ring) -eq 0) {
            "Auto-generated row: [$ring] looks like a canary/dev/test ring - allocated to week $weekN (first soak). REVIEW BEFORE UNCOMMENTING."
        } elseif ((Get-AzLocalRingSortKey $ring) -eq 2) {
            "Auto-generated row: [$ring] looks like a production ring - allocated to week $weekN (last in cycle). REVIEW BEFORE UNCOMMENTING."
        } else {
            "Auto-generated row: [$ring] - allocated to week $weekN. REVIEW BEFORE UNCOMMENTING."
        }
        [void]$sb.AppendLine("  # - weeksInCycle: '$weekN'")
        [void]$sb.AppendLine("  #   daysOfWeek:   'Mon-Thu'")
        [void]$sb.AppendLine("  #   rings:        '$ring'")
        [void]$sb.AppendLine("  #   notes:        '$note'")
        [void]$sb.AppendLine("  #   # allowedUpdateVersions: '10.2604.0.123;10.2610.0.456'  # optional row-level override (schema v2)")
    }
    [void]$sb.AppendLine('  # ---------------------------------------------------------------')
    [void]$sb.AppendLine('  # END STRAWMAN ROWS')
    [void]$sb.AppendLine('  # ---------------------------------------------------------------')

    $text = $sb.ToString()

    # ---- 7. Write (ShouldProcess gate) ---------------------------------
    if (-not $PSCmdlet.ShouldProcess($resolvedOut, "Write schedule file ($($sorted.Count) ring(s), cycleWeeks=$CycleWeeks, anchor=ISO-W$($iso.Week)/$($iso.Year))")) {
        return
    }
    # Split-Path -LiteralPath is in a different parameter set than -Parent
    # on PS 5.1 (works on PS 7). Use .NET directly for cross-version safety.
    $parent = [System.IO.Path]::GetDirectoryName($resolvedOut)
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # UTF-8 NO BOM to match other YAML conventions in the bundle.
    [System.IO.File]::WriteAllText($resolvedOut, $text, [System.Text.UTF8Encoding]::new($false))

    Write-Log -Message "Wrote $resolvedOut ($($sorted.Count) STRAWMAN row(s) - ALL COMMENTED OUT, cycleWeeks=$CycleWeeks, anchor=ISO-W$($iso.Week)/$($iso.Year))." -Level Success
    Write-Log -Message "!!! ACTION REQUIRED: every schedule row in '$resolvedOut' is commented out. The apply-updates pipeline will REFUSE to run until you review the strawman and UNCOMMENT at least one row." -Level Warning
    Write-Log -Message "Choosing which UpdateRing fires on which day is a CHANGE-CONTROL decision. The generator made a heuristic suggestion (canary/dev/test first, prod last, one ring per week, Mon-Thu); your organisation owns the final schedule." -Level Warning
    Write-Log -Message "After uncommenting, preview the cycle BEFORE committing: Get-AzLocalApplyUpdatesScheduleNextFirings -Schedule (Get-AzLocalApplyUpdatesScheduleConfig -Path '$resolvedOut')" -Level Info

    return (Get-Item -LiteralPath $resolvedOut)
}
