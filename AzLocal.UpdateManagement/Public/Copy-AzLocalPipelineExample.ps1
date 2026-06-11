function Copy-AzLocalPipelineExample {
    <#
    .SYNOPSIS
        Copy the bundled Automation-Pipeline-Examples files out of the module
        install location into a target folder of the user's choice.

    .DESCRIPTION
        The AzLocal.UpdateManagement module ships a working set of CI/CD
        pipeline files (GitHub Actions YAML, Azure DevOps Pipelines YAML, an
        ITSM example config and ticket-body template, plus a step-by-step
        README) under its `Automation-Pipeline-Examples/` subfolder. Those
        files live inside the PowerShell module install path (typically
        `C:\Program Files\WindowsPowerShell\Modules\AzLocal.UpdateManagement\
        <version>\Automation-Pipeline-Examples\` for AllUsers installs or the
        equivalent under `%USERPROFILE%\Documents\PowerShell\Modules\` for
        CurrentUser installs), which is awkward to browse manually.

        Behaviour depends on -Platform:
          - 'All' (default)  - copies the full `Automation-Pipeline-Examples`
                               source tree (both platform subfolders, the
                               shared README and the .itsm samples) into a
                               child folder named `Automation-Pipeline-Examples`
                               under `-Destination`. Intended for browsing
                               or inspecting the samples before committing to
                               a platform.
          - 'GitHub'         - copies ONLY the `.yml` workflow files from the
                               source `github-actions/` subfolder directly
                               into `-Destination` (flat - no wrapper folder,
                               no README, no .itsm). Drop
                               `-Destination .\.github\workflows` for the
                               canonical GitHub Actions layout.
          - 'AzureDevOps'    - copies ONLY the `.yml` pipeline files from the
                               source `azure-devops/` subfolder directly into
                               `-Destination` (flat). ADO has no fixed-path
                               convention, so any folder works.

        The function is read-only relative to the module install (it never
        modifies anything under `$module.ModuleBase`). By default it also
        REFUSES to overwrite any file that already exists at the destination
        - all conflicts are listed in the error message and the copy is
        aborted. To refresh after a module upgrade pass `-Update`: you will
        be prompted per file (Y / A / N / L / S / ?) before each overwrite.
        Pair with `-Confirm:$false` to bypass the prompts (useful in CI).
        Use `-WhatIf` to preview without changing anything. Pipeline files
        are expected to live under git source control, so any overwrites
        can be reviewed via `git diff` before commit.
        Supports `-WhatIf` and `-Confirm`.

    .PARAMETER Destination
        Target folder to copy into. Created if missing.

        For `-Platform GitHub` and `-Platform AzureDevOps` the YAMLs land
        directly here (flat). For the default `-Platform All`, an
        `Automation-Pipeline-Examples` child folder is created underneath it
        (matching the source layout).

        Defaults to the current working directory ($PWD).

    .PARAMETER Platform
        Which platform's pipeline files to copy. See the Description for the
        exact layout produced by each value. Valid values:
          - 'All'         - full source tree into an `Automation-Pipeline-Examples` child (default)
          - 'GitHub'      - only `*.yml` from `github-actions/`, flat into -Destination
          - 'AzureDevOps' - only `*.yml` from `azure-devops/`, flat into -Destination

    .PARAMETER PassThru
        Return the [System.IO.DirectoryInfo] of the destination folder. By
        default the function writes only informational messages.

    .PARAMETER SkipStarterSchedule
        Only meaningful with `-Platform GitHub` or `-Platform AzureDevOps`.

        By default (v0.7.92+) the function ALSO drops a starter
        `apply-updates-schedule.yml` one level UP from `-Destination` (i.e.
        the parent of `.github\workflows\` for GitHub, or the parent of
        the pipelines folder you chose for ADO) when no file already
        exists at that path. The starter is a verbatim copy of the bundled
        `apply-updates-schedule.example.yml` and is safe to land alongside
        a freshly copied Step.6 pipeline (the bundled Step.6 ships with
        every `cron:` line COMMENTED OUT, so the schedule file cannot
        cause Step.6 to fire on a `schedule:` trigger until the operator
        explicitly adds at least one cron entry).

        Two safety rails apply:
          1. If `apply-updates-schedule.yml` already exists at the target
             path, it is NEVER overwritten - the function leaves it alone
             and reports the existing path in the Next-steps summary.
          2. The starter ships with DEMO ring names (Canary, DevTest,
             Ring1, Ring2, Prod) which almost certainly do NOT match a
             real fleet's UpdateRing tag values. The recommended next
             step (printed in the summary) is to regenerate from the
             live fleet:
               New-AzLocalApplyUpdatesScheduleConfig -OutputPath <path> -Force

        Pass `-SkipStarterSchedule` to suppress the copy entirely - the
        Next-steps summary then prints the pre-v0.7.92 wording reminding
        the operator to generate the schedule via
        `New-AzLocalApplyUpdatesScheduleConfig`. Use this in scripted /
        IaC scenarios where the schedule file is managed independently.

        Has no effect when `-Platform All` is in use (the starter is only
        relevant for actively-installed CI YAMLs).

    .PARAMETER Update
        Allow overwriting destination files that already exist. Without this
        switch the function aborts with a list of conflicting files. With
        `-Update` you are prompted per file (`ShouldContinue` Y/A/N/L/S/?)
        before each overwrite - independent of `$ConfirmPreference`. Pass
        `-Confirm:$false` to suppress the prompts and overwrite
        unconditionally (suitable for scripted / CI refresh). `-WhatIf`
        overrides everything and only prints what would change.

    .OUTPUTS
        [System.IO.DirectoryInfo] when -PassThru is specified. Nothing
        otherwise.

    .EXAMPLE
        Copy-AzLocalPipelineExample

        Copies the full sample tree into
        `.\Automation-Pipeline-Examples\` under the current directory
        (browse / inspect mode).

    .EXAMPLE
        New-Item -ItemType Directory .\.github\workflows -Force | Out-Null
        Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub

        Copies the GitHub Actions workflow `*.yml` files straight into
        `.\.github\workflows\` where the GitHub Actions runner expects them.

    .EXAMPLE
        New-Item -ItemType Directory .\pipelines -Force | Out-Null
        Copy-AzLocalPipelineExample -Destination .\pipelines -Platform AzureDevOps

        Copies the Azure DevOps pipeline `*.yml` files straight into
        `.\pipelines\`. Then import each YAML as a new pipeline via
        Pipelines -> New pipeline -> Existing Azure Pipelines YAML file.

    .EXAMPLE
        $dest = Copy-AzLocalPipelineExample -Destination C:\repos\fleet -PassThru
        Set-Location $dest

        Copy the full sample tree and cd into the destination folder.

    .EXAMPLE
        Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Update

        Refresh the GitHub Actions workflow YAMLs from a (newer) installed
        module. You are prompted per file (Y / A / N / L / S / ?) before
        each overwrite. Review the result with `git diff` before committing.

    .EXAMPLE
        Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Update -Confirm:$false

        Same as above but without per-file prompts - suitable for scripted /
        CI refresh, typically after a `git diff` review against a fresh copy.

    .EXAMPLE
        Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -SkipStarterSchedule

        Copy ONLY the GitHub Actions workflow YAMLs - do not drop a starter
        `apply-updates-schedule.yml`. Use this when the schedule file is
        already managed independently (IaC, separate repo, generator script).

    .NOTES
        Author      : Neil Bird, Microsoft
        Module      : AzLocal.UpdateManagement
        Added in    : v0.7.4
        Changed in  : v0.7.50 - removed `-Flatten` and `-Force` switches.
                      Platform-specific copies now drop YAMLs directly into
                      `-Destination` (no intermediate `github-actions\` or
                      `azure-devops\` subfolder), and the function refuses
                      to overwrite any pre-existing destination file by
                      default. Added `-Update` with per-file ShouldContinue
                      prompts (and `-Confirm:$false` bypass) as the
                      controlled refresh path - files are expected to be
                      under git source control so `git diff` provides the
                      safety net.
        Changed in  : v0.7.92 - for `-Platform GitHub|AzureDevOps` the
                      function now ALSO drops a starter
                      `apply-updates-schedule.yml` one level up from
                      `-Destination` (parent of `.github\workflows\` for
                      GitHub, parent of the pipelines folder for ADO) when
                      no file already exists at that path. Existing files
                      are NEVER overwritten. Pass `-SkipStarterSchedule`
                      to suppress. The Next-steps summary now reports the
                      starter status (Copied / Preserved / Skipped) and
                      points at the live-fleet regenerator
                      `New-AzLocalApplyUpdatesScheduleConfig -OutputPath
                      <path> -Force` for the operator's next move.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination = $PWD.Path,

        [ValidateSet('All', 'GitHub', 'AzureDevOps')]
        [string]$Platform = 'All',

        # Allow overwriting destination files that already exist. Without
        # -Update, conflicts cause the function to abort. With -Update,
        # ShouldContinue prompts per file (bypassable via -Confirm:$false).
        [switch]$Update,

        [switch]$PassThru,

        # v0.7.92: when set, suppress the default starter
        # apply-updates-schedule.yml copy (Platform=GitHub|AzureDevOps).
        # Default OFF, i.e. the starter IS copied unless one already
        # exists at the destination (in which case the existing file is
        # always preserved, regardless of this switch).
        [switch]$SkipStarterSchedule
    )

    # ------------------------------------------------------------------
    # 1. Locate the module install folder. We deliberately use
    #    (Get-Module).ModuleBase rather than $PSScriptRoot so the function
    #    works correctly when imported via the .psd1 path AND when the
    #    function is dot-sourced standalone (e.g. in some test scenarios).
    # ------------------------------------------------------------------
    $module = Get-Module -Name 'AzLocal.UpdateManagement' | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) {
        # Fallback: walk up from this file (Public/ -> module root)
        $moduleRoot = Split-Path -Parent $PSScriptRoot
    }
    else {
        $moduleRoot = $module.ModuleBase
    }

    $sourceRoot = Join-Path -Path $moduleRoot -ChildPath 'Automation-Pipeline-Examples'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Copy-AzLocalPipelineExample: pipeline examples folder not found at '$sourceRoot'. The module install may be corrupt or this is a development checkout without the sample folder."
    }

    # ------------------------------------------------------------------
    # 2. Resolve destination. Create parent if missing.
    # ------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $Destination)) {
        if ($PSCmdlet.ShouldProcess($Destination, 'Create destination folder')) {
            $null = New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop
        }
    }
    # When -WhatIf is supplied and the destination did not pre-exist, it still
    # does not exist at this point; fall back to the literal -Destination string
    # so the rest of the function can describe what *would* happen without
    # throwing on Resolve-Path.
    $destResolved = if (Test-Path -LiteralPath $Destination) {
        (Resolve-Path -LiteralPath $Destination -ErrorAction Stop).ProviderPath
    }
    else {
        # Best-effort absolute path for WhatIf messaging
        [System.IO.Path]::GetFullPath($Destination)
    }

    # ------------------------------------------------------------------
    # 3. Decide what to copy based on -Platform. Build a flat list of
    #    (Source, Destination) pairs so the collision check (step 4) and
    #    copy loop (step 5) can be uniform across all -Platform values.
    # ------------------------------------------------------------------
    $copyPairs = New-Object System.Collections.Generic.List[pscustomobject]
    $targetRoot = $null
    switch ($Platform) {
        'GitHub' {
            # Platform-specific: copy ONLY *.yml from github-actions/ into
            # -Destination directly. No README, no .itsm/, no wrapper folder.
            $targetRoot = $destResolved
            $platformSrc = Join-Path -Path $sourceRoot -ChildPath 'github-actions'
            if (-not (Test-Path -LiteralPath $platformSrc -PathType Container)) {
                throw "Copy-AzLocalPipelineExample: GitHub Actions source folder not found at '$platformSrc'."
            }
            Get-ChildItem -LiteralPath $platformSrc -Filter '*.yml' -File | ForEach-Object {
                [void]$copyPairs.Add([pscustomobject]@{
                    Source      = $_.FullName
                    Destination = Join-Path -Path $targetRoot -ChildPath $_.Name
                })
            }
        }
        'AzureDevOps' {
            # Platform-specific: copy ONLY *.yml from azure-devops/ into
            # -Destination directly. Same flat semantics as 'GitHub'.
            $targetRoot = $destResolved
            $platformSrc = Join-Path -Path $sourceRoot -ChildPath 'azure-devops'
            if (-not (Test-Path -LiteralPath $platformSrc -PathType Container)) {
                throw "Copy-AzLocalPipelineExample: Azure DevOps source folder not found at '$platformSrc'."
            }
            Get-ChildItem -LiteralPath $platformSrc -Filter '*.yml' -File | ForEach-Object {
                [void]$copyPairs.Add([pscustomobject]@{
                    Source      = $_.FullName
                    Destination = Join-Path -Path $targetRoot -ChildPath $_.Name
                })
            }
        }
        default {
            # 'All' - mirror the full source tree under .\Automation-Pipeline-Examples\
            $targetRoot = Join-Path -Path $destResolved -ChildPath 'Automation-Pipeline-Examples'
            Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force | ForEach-Object {
                $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
                [void]$copyPairs.Add([pscustomobject]@{
                    Source      = $_.FullName
                    Destination = Join-Path -Path $targetRoot -ChildPath $relative
                })
            }
        }
    }

    if ($copyPairs.Count -eq 0) {
        Write-Warning "Copy-AzLocalPipelineExample: nothing to copy for -Platform '$Platform'."
        return
    }

    # ------------------------------------------------------------------
    # 4. Pre-flight check on existing destinations. Default behaviour is
    #    to refuse the operation entirely. -Update opts into per-file
    #    overwrite prompts (ShouldContinue, see step 5). Either way we
    #    collect every conflicting destination so the user sees the full
    #    list up front rather than discovering them one at a time.
    # ------------------------------------------------------------------
    $conflicts = @($copyPairs | Where-Object { Test-Path -LiteralPath $_.Destination -PathType Leaf })
    if ($conflicts.Count -gt 0) {
        $conflictList = ($conflicts | ForEach-Object { "  - $($_.Destination)" }) -join [Environment]::NewLine
        if (-not $Update) {
            throw ("Copy-AzLocalPipelineExample: refusing to overwrite {0} existing file(s) under '{1}'. Pass -Update to refresh (you will be prompted per file unless you also pass -Confirm:`$false). Pipeline files are expected to be under git source control so 'git diff' shows exactly what changed.`n{2}" -f $conflicts.Count, $targetRoot, $conflictList)
        }
        Write-Verbose ("Copy-AzLocalPipelineExample: -Update specified; {0} existing file(s) may be overwritten - will prompt per file unless -Confirm:`$false is set.{1}{2}" -f $conflicts.Count, [Environment]::NewLine, $conflictList)
    }

    # ------------------------------------------------------------------
    # 5. Perform the copy. One ShouldProcess gate at the operation level
    #    rather than per file - the per-platform filter already limits
    #    scope, and per-file -Confirm would be unusably chatty for the
    #    routine "first install" case. Per-file ShouldContinue prompts
    #    are emitted only when overwriting an existing file under
    #    -Update (see below). Parent folders for each destination file
    #    are created on demand.
    # ------------------------------------------------------------------
    $copyDescription = "Copy {0} file(s) from '{1}' to '{2}' (Platform='{3}'{4})" -f `
        $copyPairs.Count, $sourceRoot, $targetRoot, $Platform, $(if ($Update) { '; -Update' } else { '' })
    if (-not $PSCmdlet.ShouldProcess($targetRoot, $copyDescription)) {
        return
    }

    # ShouldContinue state: Yes-to-All / No-to-All flags survive across
    # iterations so the user can pick a fleet-wide choice once. They are
    # only consulted when -Update is set AND a destination file exists.
    $yesToAll = $false
    $noToAll  = $false
    # -Confirm:$false (explicit) suppresses the per-file ShouldContinue
    # prompts entirely. This is the documented automation bypass.
    $confirmExplicitlyDisabled = $PSBoundParameters.ContainsKey('Confirm') -and -not [bool]$PSBoundParameters['Confirm']

    $copiedCount = 0
    $skippedCount = 0
    foreach ($pair in $copyPairs) {
        $destExists = Test-Path -LiteralPath $pair.Destination -PathType Leaf

        # No-to-All only suppresses OVERWRITES; a brand-new file (no existing
        # destination) is still copied, because ShouldContinue would never
        # have prompted for it in the first place. This matches PowerShell's
        # canonical No-to-All semantics ("answer No to all remaining prompts")
        # rather than "halt all subsequent operations".
        if ($noToAll -and $destExists) {
            Write-Verbose ("Copy-AzLocalPipelineExample: skipped (No-to-All overwrite suppression): {0}" -f $pair.Destination)
            $skippedCount++
            continue
        }

        if ($destExists -and -not $confirmExplicitlyDisabled -and -not $yesToAll) {
            # ShouldContinue is independent of $ConfirmPreference. It always
            # prompts unless the caller has explicitly passed -Confirm:$false
            # (handled above) or the user has already chosen Yes-to-All.
            $shouldOverwrite = $PSCmdlet.ShouldContinue(
                ("Overwrite existing file '{0}'?" -f $pair.Destination),
                'Confirm pipeline example overwrite',
                [ref]$yesToAll,
                [ref]$noToAll
            )
            if ($noToAll) {
                Write-Verbose "Copy-AzLocalPipelineExample: user chose No-to-All - remaining overwrites will be skipped (new files will still be copied)."
                $skippedCount++
                continue
            }
            if (-not $shouldOverwrite) {
                Write-Verbose ("Copy-AzLocalPipelineExample: skipped (user declined overwrite): {0}" -f $pair.Destination)
                $skippedCount++
                continue
            }
        }

        $destDir = Split-Path -Parent $pair.Destination
        if (-not (Test-Path -LiteralPath $destDir)) {
            $null = New-Item -ItemType Directory -Path $destDir -Force -ErrorAction Stop
        }
        # -Force lets Copy-Item replace files even when they're marked read-only.
        # Safe here because step 4 already gated overwrites behind -Update and
        # the loop above gated each overwrite behind ShouldContinue.
        Copy-Item -LiteralPath $pair.Source -Destination $pair.Destination -Force -ErrorAction Stop
        $copiedCount++
    }

    Write-Verbose "Copied $copiedCount file(s) from '$sourceRoot' to '$targetRoot' (skipped: $skippedCount)."

    # ------------------------------------------------------------------
    # 6 (v0.7.92). Starter apply-updates-schedule.yml drop.
    #    Default-on for -Platform GitHub|AzureDevOps; suppressed by
    #    -SkipStarterSchedule. The starter lands ONE LEVEL UP from the
    #    pipelines folder (sibling of .github\workflows\ for GitHub, or
    #    sibling of the ADO pipelines folder) so the schedule file is
    #    not co-mingled with CI YAMLs. NEVER overwrites an existing
    #    file - the existing file is always preserved and reported in
    #    the Next-steps summary. Safe to land alongside Step.6 because
    #    Step.6 ships with every `cron:` line commented out (verified
    #    in github-actions/Step.7_apply-updates.yml).
    # ------------------------------------------------------------------
    $scheduleSrc        = Join-Path -Path $sourceRoot -ChildPath 'apply-updates-schedule.example.yml'
    $scheduleDest       = $null
    $scheduleAction     = $null  # 'Copied' | 'Preserved' | 'Skipped' | 'Missing'
    if ($Platform -in @('GitHub', 'AzureDevOps') -and -not $SkipStarterSchedule.IsPresent) {
        $scheduleParent = Split-Path -Parent ($targetRoot.TrimEnd('\','/'))
        if ([string]::IsNullOrWhiteSpace($scheduleParent)) {
            # Defensive: if $targetRoot has no parent (e.g. a drive root),
            # fall back to dropping the schedule alongside the YAMLs.
            $scheduleParent = $targetRoot
        }
        $scheduleDest = Join-Path -Path $scheduleParent -ChildPath 'apply-updates-schedule.yml'

        if (-not (Test-Path -LiteralPath $scheduleSrc -PathType Leaf)) {
            # Source missing - should never happen in a healthy install but
            # we record the state so the summary can hint at the cause.
            $scheduleAction = 'Missing'
            Write-Warning ("Copy-AzLocalPipelineExample: starter schedule source '{0}' not found; skipping starter copy." -f $scheduleSrc)
        }
        elseif (Test-Path -LiteralPath $scheduleDest -PathType Leaf) {
            # Never overwrite - the operator's tailored file always wins.
            $scheduleAction = 'Preserved'
            Write-Verbose ("Copy-AzLocalPipelineExample: starter schedule preserved (already exists at '{0}'); not copied." -f $scheduleDest)
        }
        elseif ($PSCmdlet.ShouldProcess($scheduleDest, "Copy starter apply-updates-schedule.yml from '$scheduleSrc'")) {
            # Create parent on demand (e.g. .github\ may not exist when the
            # caller created .github\workflows\ via a single -Force New-Item).
            $newScheduleParent = Split-Path -Parent $scheduleDest
            if (-not (Test-Path -LiteralPath $newScheduleParent)) {
                $null = New-Item -ItemType Directory -Path $newScheduleParent -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $scheduleSrc -Destination $scheduleDest -ErrorAction Stop
            $scheduleAction = 'Copied'
        }
        else {
            # -WhatIf path or operator declined the prompt.
            $scheduleAction = 'Skipped'
        }
    }
    elseif ($Platform -in @('GitHub', 'AzureDevOps')) {
        # -SkipStarterSchedule was explicitly set.
        $scheduleAction = 'SkippedBySwitch'
        $scheduleParent = Split-Path -Parent ($targetRoot.TrimEnd('\','/'))
        if (-not [string]::IsNullOrWhiteSpace($scheduleParent)) {
            $scheduleDest = Join-Path -Path $scheduleParent -ChildPath 'apply-updates-schedule.yml'
        }
    }

    # ------------------------------------------------------------------
    # 7. Friendly "what now" summary so the user does not have to open
    #    the README first to know what they just copied. Uses Write-Host
    #    (intentional - this is operator-facing UI text, not pipeline
    #    output; per Microsoft guidance Write-Host is appropriate for
    #    interactive cmdlet output that should not pollute the pipeline).
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "Copy-AzLocalPipelineExample - copy complete" -ForegroundColor Green
    Write-Host ("  Source      : {0}" -f $sourceRoot)
    Write-Host ("  Destination : {0}" -f $targetRoot)
    Write-Host ("  Platform    : {0}" -f $Platform)
    Write-Host ("  Files copied: {0}" -f $copiedCount)
    if ($skippedCount -gt 0) {
        Write-Host ("  Files skipped: {0} (user declined overwrite or -WhatIf)" -f $skippedCount) -ForegroundColor Yellow
    }
    if ($scheduleAction -eq 'Copied') {
        Write-Host ("  Starter schedule dropped at: {0}" -f $scheduleDest) -ForegroundColor Green
    }
    elseif ($scheduleAction -eq 'Preserved') {
        Write-Host ("  Starter schedule preserved (existing file): {0}" -f $scheduleDest) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    # Helper for step 4/5/6 messaging: the schedule sub-message branches
    # on $scheduleAction so the operator sees exactly what was (or was
    # not) done with apply-updates-schedule.yml on this invocation.
    $scheduleHintLines = @()
    switch ($scheduleAction) {
        'Copied' {
            $scheduleHintLines += "     Starter schedule (bundled example) was copied to:"
            $scheduleHintLines += ("       {0}" -f $scheduleDest)
            $scheduleHintLines += "     IMPORTANT: the starter ships with DEMO ring names (Canary, DevTest, Ring1, Ring2, Prod). Replace with your fleet's actual UpdateRing tag values - the easiest path is to regenerate from the live fleet, overwriting the demo file:"
            $scheduleHintLines += ("       New-AzLocalApplyUpdatesScheduleConfig -OutputPath '{0}' -Force" -f $scheduleDest)
            $scheduleHintLines += "     The starter is safe to leave in place until then - the bundled Step.6 ships with every 'cron:' line commented out, so it cannot fire on a 'schedule:' trigger until you explicitly add a cron entry. Manual workflow_dispatch / queue runs of Step.6 ignore the schedule file entirely (they take UpdateRing verbatim from the run-form input)."
        }
        'Preserved' {
            $scheduleHintLines += "     Existing schedule file preserved at:"
            $scheduleHintLines += ("       {0}" -f $scheduleDest)
            $scheduleHintLines += "     To refresh from your current live fleet (overwrites the file):"
            $scheduleHintLines += ("       New-AzLocalApplyUpdatesScheduleConfig -OutputPath '{0}' -Force" -f $scheduleDest)
        }
        'Missing' {
            $scheduleHintLines += "     Starter schedule source was missing in the module install; generate one from your live fleet:"
            if ($scheduleDest) {
                $scheduleHintLines += ("       New-AzLocalApplyUpdatesScheduleConfig -OutputPath '{0}'" -f $scheduleDest)
            }
        }
        'SkippedBySwitch' {
            $scheduleHintLines += "     -SkipStarterSchedule was set; no schedule file was copied. Generate one from your live fleet via:"
            if ($scheduleDest) {
                $scheduleHintLines += ("       New-AzLocalApplyUpdatesScheduleConfig -OutputPath '{0}'" -f $scheduleDest)
            } else {
                $scheduleHintLines += "       New-AzLocalApplyUpdatesScheduleConfig -OutputPath .\apply-updates-schedule.yml"
            }
        }
        'Skipped' {
            $scheduleHintLines += "     Starter schedule was not written (declined or -WhatIf). When ready:"
            if ($scheduleDest) {
                $scheduleHintLines += ("       New-AzLocalApplyUpdatesScheduleConfig -OutputPath '{0}'" -f $scheduleDest)
            }
        }
    }
    switch ($Platform) {
        'GitHub' {
            # Detect the canonical .github\workflows\ destination so we can
            # tell the user they are already done vs. need to move files.
            $normalised = ($targetRoot -replace '[\\/]+$', '')
            $isWorkflowsFolder = $normalised -match '[\\/]\.github[\\/]workflows$'
            if ($isWorkflowsFolder) {
                Write-Host "  1. You are already in '.github\workflows\' - commit and push:" -ForegroundColor Yellow
                Write-Host "       git add . ; git commit -m 'Add AzLocal update workflows' ; git push"
            }
            else {
                Write-Host ("  1. Move the YAML files from '{0}' into '.github\workflows\' in your repo, then commit and push." -f $targetRoot)
            }
            Write-Host "  2. RECOMMENDED: run 'Step.0_authentication-test.yml' FIRST (one-shot) to validate OIDC / RBAC before wiring the other workflows. See section 5.1 of the Automation-Pipeline-Examples README."
            Write-Host "  3. Wire up authentication (OIDC / Workload Identity / Managed Identity / SP) - see section 3 of the README."
            Write-Host "  4. SCHEDULED Step.6 (apply-updates) requires apply-updates-schedule.yml:" -ForegroundColor Yellow
            foreach ($line in $scheduleHintLines) { Write-Host $line }
            Write-Host "     See section 5.1 step 5 + section 8 of the README for the full schema, multi-stage rollouts, and the allowedUpdateVersions allow-list."
            Write-Host "  5. Optional: enable the ITSM connector by setting 'raise_itsm_ticket=true' (setup in ITSM/README.md)."
        }
        'AzureDevOps' {
            Write-Host ("  1. Commit the YAML files from '{0}' to your Azure Repo." -f $targetRoot)
            Write-Host "  2. RECOMMENDED: import 'Step.0_authentication-test.yml' FIRST (one-shot) to validate the service connection / RBAC before wiring the other pipelines. See section 5.2 of the Automation-Pipeline-Examples README."
            Write-Host "  3. For each remaining YAML: Pipelines -> New pipeline -> Existing Azure Pipelines YAML file -> point at the file -> Save."
            Write-Host "  4. Each pipeline references service connection 'AzureLocal-ServiceConnection' - either name yours to match or edit 'azureSubscription:' in each YAML."
            Write-Host "  5. SCHEDULED Step.6 (apply-updates) requires apply-updates-schedule.yml:" -ForegroundColor Yellow
            foreach ($line in $scheduleHintLines) { Write-Host $line }
            Write-Host "     Step.7 reads APPLY_UPDATES_SCHEDULE_PATH (default './apply-updates-schedule.yml' at repo root). Override the variable in the pipeline if you keep the schedule elsewhere. See section 5.2 step 6 + section 8 of the README."
            Write-Host "  6. Optional: enable the ITSM connector by setting 'raise_itsm_ticket=true' (setup in ITSM/README.md)."
        }
        default {
            $readmePath = Join-Path -Path $targetRoot -ChildPath 'README.md'
            if (Test-Path -LiteralPath $readmePath) {
                Write-Host "  1. Open the step-by-step setup guide:"
                Write-Host ("       {0}" -f $readmePath) -ForegroundColor Yellow
            }
            else {
                Write-Host "  1. Refer to the module's online README for the step-by-step setup guide:"
                Write-Host "       https://github.com/NeilBird/Azure-Local/blob/main/AzLocal.UpdateManagement/Automation-Pipeline-Examples/README.md" -ForegroundColor Yellow
            }
            Write-Host "  2. Pick the platform you use and copy the YAML into your repo (or re-run this function with -Platform GitHub or -Platform AzureDevOps):"
            Write-Host ("       - GitHub Actions  : copy '{0}\github-actions\*.yml' to '.github\workflows\'" -f $targetRoot)
            Write-Host ("       - Azure DevOps    : import '{0}\azure-devops\*.yml' as new pipelines" -f $targetRoot)
            Write-Host "  3. Wire up authentication (OIDC / Workload Identity / Managed Identity / SP) - see section 3 of the README."
            Write-Host "  4. Optional: enable the ITSM connector by setting 'raise_itsm_ticket=true' (setup in ITSM/README.md)."
        }
    }
    Write-Host ""

    if ($PassThru.IsPresent) {
        return Get-Item -LiteralPath $targetRoot
    }
}
