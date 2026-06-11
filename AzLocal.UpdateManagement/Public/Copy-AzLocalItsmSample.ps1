function Copy-AzLocalItsmSample {
    <#
    .SYNOPSIS
        Copy the bundled ITSM connector sample (matrix config + Mustache
        ticket-body template) out of the module install location into a
        target folder of the user's choice.

    .DESCRIPTION
        The AzLocal.UpdateManagement module ships a ready-to-edit ITSM
        connector sample under its
        `Automation-Pipeline-Examples/.itsm/` subfolder:

          - `azurelocal-itsm.yml`             - the trigger matrix /
                                                authentication / defaults
                                                config consumed by
                                                `Get-AzLocalItsmConfig`
                                                and `New-AzLocalIncident`.
          - `templates/incident-body.md`      - the Mustache template used
                                                to render the ServiceNow
                                                ticket body.

        Both files are CI-platform-agnostic. The YAML defines what is
        ticketed (trigger matrix) and how secrets are sourced (env vars,
        Key Vault, or both). The runtime difference between GitHub Actions
        and Azure DevOps is only in how secret values reach the runner's
        process environment - the YAML is identical for both.

        The bundled sample lives inside the PowerShell module install path
        (typically `C:\Program Files\WindowsPowerShell\Modules\AzLocal.Update
        Management\<version>\Automation-Pipeline-Examples\.itsm\` for AllUsers
        installs or the equivalent under
        `%USERPROFILE%\Documents\PowerShell\Modules\` for CurrentUser
        installs), which is awkward to browse manually.

        This function copies the sample into `-Destination` so it can be
        committed to a repository alongside the workflow / pipeline YAMLs
        copied by `Copy-AzLocalPipelineExample`. The default
        `-Destination` is `.\.itsm` - the relative path that both
        `Step.7_apply-updates.yml` workflows default `itsm_config_path` /
        `itsmConfigPath` to (resolved relative to the repo root at job
        runtime).

        The function is read-only relative to the module install (it never
        modifies anything under `$module.ModuleBase`). By default it also
        REFUSES to overwrite any file that already exists at the destination
        - all conflicts are listed in the error message and the copy is
        aborted. To refresh after a module upgrade pass `-Update`: you will
        be prompted per file (Y / A / N / L / S / ?) before each overwrite.
        Pair with `-Confirm:$false` to bypass the prompts (useful in CI).
        Use `-WhatIf` to preview without changing anything. Sample files
        are expected to live under git source control, so any overwrites
        can be reviewed via `git diff` before commit.
        Supports `-WhatIf` and `-Confirm`.

    .PARAMETER Destination
        Target folder to copy the ITSM sample into. Created if missing.

        Defaults to `.\.itsm` (relative to the current working directory).
        Run this from your repo root and the workflow defaults (which look
        for `./.itsm/azurelocal-itsm.yml` at job runtime) will work
        unchanged.

    .PARAMETER Update
        Allow overwriting destination files that already exist. Without this
        switch the function aborts with a list of conflicting files. With
        `-Update` you are prompted per file (`ShouldContinue` Y/A/N/L/S/?)
        before each overwrite - independent of `$ConfirmPreference`. Pass
        `-Confirm:$false` to suppress the prompts and overwrite
        unconditionally (suitable for scripted / CI refresh). `-WhatIf`
        overrides everything and only prints what would change.

    .PARAMETER PassThru
        Return the [System.IO.DirectoryInfo] of the destination folder. By
        default the function writes only informational messages.

    .OUTPUTS
        [System.IO.DirectoryInfo] when -PassThru is specified. Nothing
        otherwise.

    .EXAMPLE
        Copy-AzLocalItsmSample

        Copies the ITSM connector sample into `.\.itsm\` under the current
        directory. Run from your repo root so the workflow defaults
        (`./.itsm/azurelocal-itsm.yml`) resolve unchanged.

    .EXAMPLE
        Copy-AzLocalItsmSample -Destination C:\repos\fleet\.itsm

        Copies the ITSM connector sample into an explicit folder.

    .EXAMPLE
        Copy-AzLocalItsmSample -Update

        Refresh the ITSM sample files from a (newer) installed module. You
        are prompted per file (Y / A / N / L / S / ?) before each
        overwrite. Review the result with `git diff` before committing.

    .EXAMPLE
        Copy-AzLocalItsmSample -Update -Confirm:$false

        Same as above but without per-file prompts - suitable for scripted /
        CI refresh, typically after a `git diff` review against a fresh
        copy.

    .EXAMPLE
        Copy-AzLocalItsmSample -WhatIf

        Preview what would be copied without changing anything on disk.

    .NOTES
        Author      : Neil Bird, Microsoft
        Module      : AzLocal.UpdateManagement
        Added in    : v0.7.50

        Pair with `Copy-AzLocalPipelineExample` to lay out a fresh
        Apply-Updates pipeline that has ITSM ticketing enabled. The two
        functions target different destinations on purpose:

          - `Copy-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub`
            (or `-Platform AzureDevOps` into your pipelines folder)
          - `Copy-AzLocalItsmSample` from the same starting directory
            (the repo root), so the sample lands at `.\.itsm\` where the
            workflow defaults look for it.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([System.IO.DirectoryInfo])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination = (Join-Path -Path $PWD.Path -ChildPath '.itsm'),

        # Allow overwriting destination files that already exist. Without
        # -Update, conflicts cause the function to abort. With -Update,
        # ShouldContinue prompts per file (bypassable via -Confirm:$false).
        [switch]$Update,

        [switch]$PassThru
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

    $sourceRoot = Join-Path -Path $moduleRoot -ChildPath 'Automation-Pipeline-Examples\.itsm'
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
        throw "Copy-AzLocalItsmSample: ITSM sample folder not found at '$sourceRoot'. The module install may be corrupt or this is a development checkout without the sample folder."
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
    # 3. Build the (Source, Destination) pair list by mirroring the
    #    `.itsm/` source tree under -Destination. The whole tree is
    #    in-scope (azurelocal-itsm.yml + templates/incident-body.md);
    #    there is no platform discriminator here because the ITSM sample
    #    is CI-platform-agnostic.
    # ------------------------------------------------------------------
    $copyPairs = New-Object System.Collections.Generic.List[pscustomobject]
    Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force | ForEach-Object {
        $relative = $_.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
        [void]$copyPairs.Add([pscustomobject]@{
            Source      = $_.FullName
            Destination = Join-Path -Path $destResolved -ChildPath $relative
        })
    }

    if ($copyPairs.Count -eq 0) {
        Write-Warning "Copy-AzLocalItsmSample: nothing to copy - source folder '$sourceRoot' is empty."
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
            throw ("Copy-AzLocalItsmSample: refusing to overwrite {0} existing file(s) under '{1}'. Pass -Update to refresh (you will be prompted per file unless you also pass -Confirm:`$false). Sample files are expected to be under git source control so 'git diff' shows exactly what changed.`n{2}" -f $conflicts.Count, $destResolved, $conflictList)
        }
        Write-Verbose ("Copy-AzLocalItsmSample: -Update specified; {0} existing file(s) may be overwritten - will prompt per file unless -Confirm:`$false is set.{1}{2}" -f $conflicts.Count, [Environment]::NewLine, $conflictList)
    }

    # ------------------------------------------------------------------
    # 5. Perform the copy. One ShouldProcess gate at the operation level
    #    rather than per file. Per-file ShouldContinue prompts are
    #    emitted only when overwriting an existing file under -Update
    #    (see below). Parent folders for each destination file are
    #    created on demand (e.g. templates/).
    # ------------------------------------------------------------------
    $copyDescription = "Copy {0} ITSM sample file(s) from '{1}' to '{2}'{3}" -f `
        $copyPairs.Count, $sourceRoot, $destResolved, $(if ($Update) { ' (-Update)' } else { '' })
    if (-not $PSCmdlet.ShouldProcess($destResolved, $copyDescription)) {
        return
    }

    # ShouldContinue state: Yes-to-All / No-to-All flags survive across
    # iterations so the user can pick a sample-wide choice once. They are
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
            Write-Verbose ("Copy-AzLocalItsmSample: skipped (No-to-All overwrite suppression): {0}" -f $pair.Destination)
            $skippedCount++
            continue
        }

        if ($destExists -and -not $confirmExplicitlyDisabled -and -not $yesToAll) {
            $shouldOverwrite = $PSCmdlet.ShouldContinue(
                ("Overwrite existing file '{0}'?" -f $pair.Destination),
                'Confirm ITSM sample overwrite',
                [ref]$yesToAll,
                [ref]$noToAll
            )
            if ($noToAll) {
                Write-Verbose "Copy-AzLocalItsmSample: user chose No-to-All - remaining overwrites will be skipped (new files will still be copied)."
                $skippedCount++
                continue
            }
            if (-not $shouldOverwrite) {
                Write-Verbose ("Copy-AzLocalItsmSample: skipped (user declined overwrite): {0}" -f $pair.Destination)
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

    Write-Verbose "Copied $copiedCount ITSM sample file(s) from '$sourceRoot' to '$destResolved' (skipped: $skippedCount)."

    # ------------------------------------------------------------------
    # 6. Friendly "what now" summary. Same Write-Host rationale as
    #    Copy-AzLocalPipelineExample - operator-facing UI text, not
    #    pipeline output.
    # ------------------------------------------------------------------
    Write-Host ""
    Write-Host "Copy-AzLocalItsmSample - copy complete" -ForegroundColor Green
    Write-Host ("  Source      : {0}" -f $sourceRoot)
    Write-Host ("  Destination : {0}" -f $destResolved)
    Write-Host ("  Files copied: {0}" -f $copiedCount)
    if ($skippedCount -gt 0) {
        Write-Host ("  Files skipped: {0} (user declined overwrite or -WhatIf)" -f $skippedCount) -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Review the sample - especially the 'secrets:' block (keyvault vs envvar) and the 'triggers:' matrix. See ITSM/README.md for the full reference."
    Write-Host "  2. Wire the secrets in your CI platform:"
    Write-Host "       - GitHub Actions: create repo / environment secrets ITSM_SN_INSTANCE_URL, ITSM_SN_CLIENT_ID, ITSM_SN_CLIENT_SECRET."
    Write-Host "       - Azure DevOps : create a variable group named 'AzureLocal-ITSM-Secrets' containing the same three variable names (marked secret)."
    Write-Host "  3. In the workflow / pipeline run, set 'raise_itsm_ticket=true' (GitHub) or 'raiseItsmTicket=true' (ADO) to enable ticketing. The defaults preserve byte-identical pre-ITSM behaviour."
    Write-Host "  4. Validate end-to-end in dry-run mode first: 'itsm_dry_run=true' / 'itsmDryRun=true' builds payloads and runs the dedupe check without creating tickets in ServiceNow."
    Write-Host ""

    if ($PassThru.IsPresent) {
        return Get-Item -LiteralPath $destResolved
    }
}
