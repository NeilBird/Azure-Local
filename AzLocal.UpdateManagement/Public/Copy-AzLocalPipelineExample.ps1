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

        By default (v0.7.92+; relocated to `config\` in v0.8.7) the
        function ALSO drops a starter `apply-updates-schedule.yml` into a
        `config\` folder at the REPO ROOT - the same folder as the
        documented `config/ClusterUpdateRings.csv` that Step.2 consumes, so
        all operator-authored config sits together and the path is
        IDENTICAL on GitHub and Azure DevOps. The repo root is resolved from
        `-Destination`: two levels up for the canonical GitHub layout
        (`.github\workflows`), one level up otherwise. The starter is only
        written when no file already exists at `config\apply-updates-schedule.yml`.
        The starter is a verbatim copy of the bundled
        `apply-updates-schedule.example.yml` and is safe to land alongside
        a freshly copied `apply-updates` pipeline (the bundled pipeline ships
        with every `cron:` line COMMENTED OUT, so the schedule file cannot
        cause `apply-updates` to fire on a `schedule:` trigger until the operator
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

    .PARAMETER SkipStarterSideloadConfig
        Only meaningful with `-Platform GitHub` or `-Platform AzureDevOps`.

        By default (v0.8.7+) the function ALSO drops two starter on-prem
        sideloading config files into the SAME `config\` folder as the
        starter schedule and the ring CSV (one path, both platforms):
          - `sideload-auth-map.csv`  - header row + guidance comments only.
          - `sideload-catalog.yml`   - `schemaVersion` + an empty `packages:`
                                       list.

        Both starters are HEADER / SKELETON ONLY (no demo data rows), so they
        are inert even if `SIDELOAD_UPDATES` is flipped to `true` before they
        are populated: an empty auth-map produces an `UnknownAuthAccountId`
        status and an empty catalog produces `NoCatalogEntry` - neither
        performs a Key Vault lookup or stages any media. The Step.6 sideload
        pipeline is itself hard-gated OFF unless `SIDELOAD_UPDATES == 'true'`,
        so the files have zero effect for operators who never opt in.

        As with the starter schedule, existing files are NEVER overwritten.

        Pass `-SkipStarterSideloadConfig` to suppress the drop entirely. Has
        no effect when `-Platform All` is in use.

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
        Changed in  : v0.8.7 - for `-Platform GitHub|AzureDevOps` ALL starter
                      operator config now lands in a `config\` folder at the
                      repo root (one path on both platforms, matching the
                      documented `config/ClusterUpdateRings.csv`). The starter
                      `apply-updates-schedule.yml` MOVED here from its v0.7.92
                      location (parent of `.github\workflows\` / pipelines
                      folder). The function now ALSO drops two starter on-prem
                      sideloading config files (`sideload-auth-map.csv` +
                      `sideload-catalog.yml`, header/skeleton only) into the
                      same `config\` folder. Existing files are NEVER
                      overwritten. Pass `-SkipStarterSchedule` /
                      `-SkipStarterSideloadConfig` to suppress. The sideload
                      starters are inert until populated AND
                      `SIDELOAD_UPDATES=true`, so they are safe for operators
                      who never sideload.
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
        [switch]$SkipStarterSchedule,

        # v0.8.7: when set, suppress the default starter sideload-config
        # drop (sideload-auth-map.csv + sideload-catalog.yml) for
        # Platform=GitHub|AzureDevOps. Default OFF. Existing files are
        # always preserved regardless of this switch.
        [switch]$SkipStarterSideloadConfig,

        # v0.8.85: when set, remove deprecated workflow filenames that are
        # superseded by newer merged pipelines (for example, GitHub
        # authentication-test.yml + inventory-clusters.yml replaced by
        # setup-validate-and-inventory.yml). Default OFF to avoid deleting
        # operator-edited files without explicit opt-in.
        [switch]$PruneDeprecated
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
    # 5b (v0.8.85). Optional cleanup of deprecated sample filenames that
    #     were superseded by merged pipelines.
    # ------------------------------------------------------------------
    if ($Platform -eq 'GitHub') {
        $replacementPath = Join-Path -Path $targetRoot -ChildPath 'setup-validate-and-inventory.yml'
        $deprecatedFiles = @(
            [PSCustomObject]@{ Path = (Join-Path -Path $targetRoot -ChildPath 'authentication-test.yml'); ExpectedId = 'authentication-test' }
            [PSCustomObject]@{ Path = (Join-Path -Path $targetRoot -ChildPath 'inventory-clusters.yml');  ExpectedId = 'inventory-clusters' }
        )
        $existingDeprecated = @($deprecatedFiles | Where-Object { Test-Path -LiteralPath $_.Path -PathType Leaf })
        if ((Test-Path -LiteralPath $replacementPath -PathType Leaf) -and $existingDeprecated.Count -gt 0) {
            if ($PruneDeprecated.IsPresent) {
                foreach ($deprecatedEntry in $existingDeprecated) {
                    $deprecatedPath = $deprecatedEntry.Path
                    $expectedId = $deprecatedEntry.ExpectedId
                    $canDelete = $false
                    try {
                        $deprecatedText = [System.IO.File]::ReadAllText($deprecatedPath, [System.Text.UTF8Encoding]::new($false))
                        $deprecatedId = Get-AzLocalPipelineId -Text $deprecatedText
                        $canDelete = ($deprecatedId -eq $expectedId)
                    }
                    catch {
                        Write-Warning ("Copy-AzLocalPipelineExample: could not inspect '{0}' for AZLOCAL-PIPELINE-ID; leaving file untouched. {1}" -f $deprecatedPath, $_.Exception.Message)
                    }

                    if (-not $canDelete) {
                        Write-Warning ("Copy-AzLocalPipelineExample: '{0}' does not match expected pipeline ID '{1}'. Leaving file untouched." -f $deprecatedPath, $expectedId)
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess($deprecatedPath, 'Remove deprecated workflow replaced by setup-validate-and-inventory.yml')) {
                        Remove-Item -LiteralPath $deprecatedPath -Force -ErrorAction Stop
                        Write-Verbose ("Copy-AzLocalPipelineExample: removed deprecated workflow '{0}'." -f $deprecatedPath)
                    }
                }
            }
            else {
                $deprecatedList = ($existingDeprecated | ForEach-Object { "  - $($_.Path)" }) -join [Environment]::NewLine
                Write-Warning ("Copy-AzLocalPipelineExample: found deprecated workflow file(s) replaced by 'setup-validate-and-inventory.yml'. They were left in place to preserve operator edits.{0}{1}{0}To remove them automatically on refresh, rerun with -PruneDeprecated." -f [Environment]::NewLine, $deprecatedList)
            }
        }
    }

    # ------------------------------------------------------------------
    # 6 (v0.7.92, relocated to config\ in v0.8.7). Starter
    #    apply-updates-schedule.yml drop.
    #    Default-on for -Platform GitHub|AzureDevOps; suppressed by
    #    -SkipStarterSchedule. The starter lands in a `config\` folder at
    #    the REPO ROOT (the same location as the documented
    #    `config/ClusterUpdateRings.csv` that Step.2 consumes), so ALL
    #    operator-authored config (ring CSV, schedule, sideload auth-map +
    #    catalog) sits together in one folder and the path is IDENTICAL on
    #    GitHub and Azure DevOps. NEVER overwrites an existing file - the
    #    existing file is always preserved and reported in the Next-steps
    #    summary. Safe to land alongside Step.6 because Step.6 ships with
    #    every `cron:` line commented out.
    #
    #    Repo-root resolution: for the canonical GitHub layout
    #    (`-Destination .github\workflows`) the repo root is TWO levels up
    #    (so config\ lands next to .github\, not inside it). For Azure
    #    DevOps (and any other layout) it is ONE level up from the
    #    pipelines folder. In both cases config\ ends up at the repo root.
    # ------------------------------------------------------------------
    $configDir = $null
    if ($Platform -in @('GitHub', 'AzureDevOps')) {
        $trimmedTarget = $targetRoot.TrimEnd('\', '/')
        $oneLevelUp = Split-Path -Parent $trimmedTarget
        if ($Platform -eq 'GitHub' -and ($trimmedTarget -match '[\\/]\.github[\\/]workflows$')) {
            # .github\workflows -> step up past .github to the repo root.
            $repoRoot = Split-Path -Parent $oneLevelUp
        }
        else {
            $repoRoot = $oneLevelUp
        }
        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
            # Defensive: drive root or no parent - fall back to the target.
            $repoRoot = $trimmedTarget
        }
        $configDir = Join-Path -Path $repoRoot -ChildPath 'config'
    }

    $scheduleSrc        = Join-Path -Path $sourceRoot -ChildPath 'apply-updates-schedule.example.yml'
    $scheduleDest       = $null
    $scheduleAction     = $null  # 'Copied' | 'Preserved' | 'Skipped' | 'Missing'
    if ($Platform -in @('GitHub', 'AzureDevOps') -and -not $SkipStarterSchedule.IsPresent) {
        $scheduleDest = Join-Path -Path $configDir -ChildPath 'apply-updates-schedule.yml'

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
            # Create the config\ folder on demand.
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
        if ($configDir) {
            $scheduleDest = Join-Path -Path $configDir -ChildPath 'apply-updates-schedule.yml'
        }
    }

    # ------------------------------------------------------------------
    # 6b (v0.8.7). Starter on-prem sideloading config drop
    #    (sideload-auth-map.csv + sideload-catalog.yml). Default-on for
    #    -Platform GitHub|AzureDevOps; suppressed by
    #    -SkipStarterSideloadConfig. Lands in the SAME `config\` folder as
    #    the starter schedule and the ring CSV, so all operator config files
    #    sit together at the repo root. Both files are HEADER / SKELETON
    #    ONLY (no demo data rows), so they are inert even if SIDELOAD_UPDATES
    #    is flipped on before they are populated: an empty auth-map yields
    #    UnknownAuthAccountId and an empty catalog yields NoCatalogEntry -
    #    neither performs a Key Vault lookup nor stages media. The Step.6
    #    sideload pipeline is itself hard-gated OFF unless
    #    SIDELOAD_UPDATES == 'true'. NEVER overwrites an existing file.
    # ------------------------------------------------------------------
    $sideloadAuthMapDest  = $null
    $sideloadCatalogDest  = $null
    $sideloadConfigAction = $null   # 'Copied' | 'Preserved' | 'Skipped' | 'SkippedBySwitch'
    if ($Platform -in @('GitHub', 'AzureDevOps')) {
        $sideloadAuthMapDest = Join-Path -Path $configDir -ChildPath 'sideload-auth-map.csv'
        $sideloadCatalogDest = Join-Path -Path $configDir -ChildPath 'sideload-catalog.yml'

        if ($SkipStarterSideloadConfig.IsPresent) {
            $sideloadConfigAction = 'SkippedBySwitch'
        }
        else {
            # Header / skeleton starter content (NOT a copy of the worked
            # .example files, which carry demo rows). ASCII-only so
            # Set-Content -Encoding ASCII writes no BOM.
            $authMapStarter = @(
                '# Sideload auth-map starter (v0.8.7 on-prem sideloading). Worked example:'
                '#   Automation-Pipeline-Examples/sideload-auth-map.example.csv'
                "# Lines starting with '#' are stripped at runtime by Get-AzLocalSideloadAuthMap;"
                '# the first non-comment line is the CSV header. UpdateAuthAccountId must be'
                '# numeric (1-3 digits) and unique. The first four columns are required.'
                'UpdateAuthAccountId,KeyVaultName,UsernameSecretName,PasswordSecretName,RemotingTargetFqdn,FqdnSuffix,AuthMechanism,ImportSharePath'
            )
            $catalogStarter = @(
                '# Sideload catalog starter (v0.8.7 on-prem sideloading). Worked example:'
                '#   Automation-Pipeline-Examples/sideload-catalog.example.yml'
                '# Run Update-AzLocalSideloadCatalog to populate Solution rows from the'
                '# Microsoft Learn offline-updates table; add OEM SBE rows manually.'
                'schemaVersion: 1'
                'packages:'
            )

            $sideloadWroteAny = $false
            $sideloadPreservedAny = $false
            foreach ($drop in @(
                @{ Dest = $sideloadAuthMapDest; Content = $authMapStarter; Label = 'sideload-auth-map.csv' }
                @{ Dest = $sideloadCatalogDest; Content = $catalogStarter; Label = 'sideload-catalog.yml' }
            )) {
                if (Test-Path -LiteralPath $drop.Dest -PathType Leaf) {
                    $sideloadPreservedAny = $true
                    Write-Verbose ("Copy-AzLocalPipelineExample: starter {0} preserved (already exists at '{1}')." -f $drop.Label, $drop.Dest)
                }
                elseif ($PSCmdlet.ShouldProcess($drop.Dest, ("Write starter {0}" -f $drop.Label))) {
                    $dropParent = Split-Path -Parent $drop.Dest
                    if (-not (Test-Path -LiteralPath $dropParent)) {
                        $null = New-Item -ItemType Directory -Path $dropParent -Force -ErrorAction Stop
                    }
                    Set-Content -LiteralPath $drop.Dest -Value $drop.Content -Encoding ASCII -ErrorAction Stop
                    $sideloadWroteAny = $true
                }
            }
            if ($sideloadWroteAny)          { $sideloadConfigAction = 'Copied' }
            elseif ($sideloadPreservedAny)  { $sideloadConfigAction = 'Preserved' }
            else                            { $sideloadConfigAction = 'Skipped' }
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
    if ($sideloadConfigAction -eq 'Copied') {
        Write-Host ("  Starter sideload config dropped at: {0}" -f $sideloadAuthMapDest) -ForegroundColor Green
        Write-Host ("                                      {0}" -f $sideloadCatalogDest) -ForegroundColor Green
    }
    elseif ($sideloadConfigAction -eq 'Preserved') {
        Write-Host "  Starter sideload config preserved (existing sideload-auth-map.csv / sideload-catalog.yml left untouched)" -ForegroundColor Yellow
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
    # Optional sideload (Step.6) sub-message - only emitted when a starter
    # sideload config was dropped or already exists. Sideloading is OFF by
    # default (SIDELOAD_UPDATES gate), so this is purely informational.
    $sideloadHintLines = @()
    if ($sideloadConfigAction -in @('Copied', 'Preserved')) {
        $sideloadHintLines += "  *. OPTIONAL on-prem sideloading (Step.6, OFF by default): two starter config files are in place:"
        if ($sideloadAuthMapDest) { $sideloadHintLines += ("       {0}" -f $sideloadAuthMapDest) }
        if ($sideloadCatalogDest) { $sideloadHintLines += ("       {0}" -f $sideloadCatalogDest) }
        $sideloadHintLines += "     Populate both, set repository variable SIDELOAD_UPDATES=true, then dry-run the sideload-updates pipeline. Until then they are inert. See Automation-Pipeline-Examples/docs/sideload.md."
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
            Write-Host "  2. RECOMMENDED: run 'setup-validate-and-inventory.yml' FIRST (one-shot) to validate OIDC / RBAC and generate your initial cluster inventory before wiring the other workflows. See section 5.1 of the Automation-Pipeline-Examples README."
            Write-Host "  3. Wire up authentication (OIDC / Workload Identity / Managed Identity / SP) - see section 3 of the README."
            Write-Host "  4. SCHEDULED apply-updates requires apply-updates-schedule.yml:" -ForegroundColor Yellow
            foreach ($line in $scheduleHintLines) { Write-Host $line }
            Write-Host "     See section 5.1 step 5 + section 8 of the README for the full schema, multi-stage rollouts, and the allowedUpdateVersions allow-list."
            Write-Host "  5. Optional: enable the ITSM connector by setting 'raise_itsm_ticket=true' (setup in ITSM/README.md)."
            foreach ($line in $sideloadHintLines) { Write-Host $line }
        }
        'AzureDevOps' {
            Write-Host ("  1. Commit the YAML files from '{0}' to your Azure Repo." -f $targetRoot)
            Write-Host "  2. RECOMMENDED: import 'setup-validate-and-inventory.yml' FIRST (one-shot) to validate the service connection / RBAC before wiring the other pipelines. See section 5.2 of the Automation-Pipeline-Examples README."
            Write-Host "  3. For each remaining YAML: Pipelines -> New pipeline -> Existing Azure Pipelines YAML file -> point at the file -> Save."
            Write-Host "  4. Each pipeline references service connection 'AzureLocal-ServiceConnection' - either name yours to match or edit 'azureSubscription:' in each YAML."
            Write-Host "  5. SCHEDULED apply-updates requires apply-updates-schedule.yml:" -ForegroundColor Yellow
            foreach ($line in $scheduleHintLines) { Write-Host $line }
            Write-Host "     apply-updates reads APPLY_UPDATES_SCHEDULE_PATH (default './config/apply-updates-schedule.yml'). Override the variable in the pipeline if you keep the schedule elsewhere. See section 5.2 step 6 + section 8 of the README."
            Write-Host "  6. Optional: enable the ITSM connector by setting 'raise_itsm_ticket=true' (setup in ITSM/README.md)."
            foreach ($line in $sideloadHintLines) { Write-Host $line }
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
