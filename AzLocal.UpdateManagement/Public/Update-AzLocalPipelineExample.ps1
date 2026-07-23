function Update-AzLocalPipelineExample {
    <#
    .SYNOPSIS
        Refreshes the bundled CI/CD pipeline YAMLs in a customer repo while
        preserving operator customisations bracketed by AZLOCAL-CUSTOMIZE markers.

    .DESCRIPTION
        Companion to Copy-AzLocalPipelineExample. Where Copy is a CLEAN
        OVERWRITE tool (intended for the initial drop, or for forcing a hard
        reset to the bundled samples), Update is a MARKER-AWARE MERGE tool
        intended for module-upgrade refreshes after the customer has
        customised the pipelines.

        Layer 1 customisation marker convention (introduced in v0.7.68):

            # BEGIN-AZLOCAL-CUSTOMIZE:<section>
            <... customer-editable content ...>
            # END-AZLOCAL-CUSTOMIZE:<section>

        Both markers are plain YAML comments (the leading '#' character) and
        therefore have zero runtime effect on either GitHub Actions or Azure
        DevOps. The <section> name is an identifier consisting of letters,
        digits, hyphens and underscores. It is unique per file. Regions
        currently shipped:

            schedule-triggers          (cron/schedule trigger block - main pipelines)
            itsm-secrets               (ITSM secret bindings - apply-updates.yml)
            service-connection-<job>   (Azure DevOps WIF service connection name on
                                        each AzureCLI@2/AzurePowerShell@5 task; one
                                        region per task, suffixed by the job name)
            runner-target-<job>        (the hosted agent pool / GitHub runs-on label
                                        that selects where the job runs)
            sideload-runner-<job>      (the self-hosted pool/runner that the sideload
                                        Advance job must run on - on-prem agents that
                                        advertise the 'azlocal-sideload' capability)

        Added in v0.8.94 (service-connection / runner-target / sideload-runner):
        these wrap operator-owned INFRASTRUCTURE values (service connection
        name, agent pool, runner label) so an edit inside the region survives
        Update - including with -Force, which otherwise reverts out-of-marker
        edits. Per-run INPUT defaults (e.g. updateRing, config paths, throttle)
        are deliberately NOT marker-wrapped: they are already overridable per
        run and via variable groups, and wrapping them would FREEZE the module
        author's ability to improve those defaults on each release.

        Per source YAML the cmdlet:

          1. Locates the matching destination file under -Destination BY
             STABLE LOGICAL ID (v0.8.7), not by filename. Each bundled YAML
             carries a '# AZLOCAL-PIPELINE-ID: <id>' header comment; the
             cmdlet matches a destination file by (a) the canonical filename,
             else (b) a destination YAML whose embedded ID equals the source
             ID, else (c) a legacy 'Step.N_<base>.yml' alias filename recorded
             in the bundled pipeline manifest. A (b)/(c) match whose filename
             differs from the canonical name is RENAMED on disk to the
             canonical name as part of the merge, carrying the customer's
             marker bodies (e.g. schedule CRONs) forward. This means a module
             release that renames or renumbers a pipeline is no longer a
             breaking change - the customer's CRONs follow the pipeline.
             - Net-new files in the source set are CREATED (full copy).
             - Files present at -Destination but not in the source set (and
               not matched by ID/alias) are left untouched (orphaned
               customer-only files survive).

          2. Parses both files for marker pairs. For every marker name found
             in BOTH files the destination body (the lines between BEGIN and
             END) is grafted into the source text in place of the source's
             body, while the BEGIN and END lines themselves are taken from
             the source - so any improvements the module author makes to the
             marker COMMENT itself (the guidance text inside the marker
             lines, e.g. an updated example cron) reach the customer.

          3. Reports per file: Action (Created / Updated / Unchanged /
             Skipped / Overwritten), PreservedMarkers (names whose body was
             carried over from destination), NewMarkers (names introduced in
             this module version), RemovedMarkers (names present at the
             destination but no longer in the source - their bodies are
             discarded; the customer must hand-migrate any content).

        Safety:
          - The destination is required to already exist - this is an UPDATE
            tool. Use Copy-AzLocalPipelineExample for the initial drop.
          - If the destination YAML has NO markers and the source DOES (the
            common state when refreshing from a pre-v0.7.68 copy), the
            cmdlet REFUSES to write unless -Force is supplied, because we
            cannot infer what the customer customised. With -Force the
            file is overwritten and the customer is expected to re-apply
            any edits manually.
          - If both files have no markers at all and they differ, the
            cmdlet refuses to write unless -Force is supplied - EXCEPT
            when the only line-level difference is the
            GENERATED_AGAINST_MODULE_VERSION pin (added in v0.7.95).
            That field is mechanically bumped on every module release and
            is not an operator customisation surface, so a pin-only diff
            is auto-refreshed and reported as 'Updated-PinOnly' without
            requiring -Force. Handles both the single-line GitHub Actions
            shape ('GENERATED_AGAINST_MODULE_VERSION: \'X\'') and the
            two-line Azure DevOps name/value shape.
          - File encoding on write is UTF-8 WITHOUT BOM (the GitHub
            Actions / Azure DevOps YAML convention).
          - The cmdlet uses Get-Content -Raw and preserves whatever line
            endings the source ships (LF on the bundled samples).

        The cmdlet is read-only relative to the module install (it never
        modifies anything under (Get-Module).ModuleBase). Supports
        -WhatIf and -Confirm.

    .PARAMETER Destination
        Folder containing the customer's pipeline YAMLs. Must exist. For
        GitHub Actions the canonical layout is the repo's .\.github\workflows
        directory; for Azure DevOps it is whatever folder you imported the
        YAMLs from. Defaults to the current working directory ($PWD).

    .PARAMETER Platform
        Which platform's bundled sample set to compare against.

    .PARAMETER Force
        Allow first-migration overwrites (destination has no markers, source
        does) and forced overwrites of files that diverged outside the
        marker regions. Without -Force these cases produce a
        'Skipped-NeedsForce' result row and no write.

    .PARAMETER PassThru
        Emit the per-file result objects to the pipeline. By default the
        cmdlet only writes summary log messages.

    .PARAMETER SkipStarterUpdater
        Suppress the v0.8.98 turnkey refresh-script drop. By default Update
        also (re)creates a self-contained `Update-Module-And-Pipelines.ps1`
        in the repo root when it is absent (with the chosen platform and
        workflow subpath baked in), so a repo that was first set up before
        v0.8.98 - and is therefore upgraded via Update rather than Copy -
        still receives the one-shot "install latest module + refresh YAMLs +
        commit/push" script. The dropped script carries an
        `AZLOCAL-UPDATER-VERSION` stamp: when the module ships a newer
        template version, Update re-renders the script in place (logged as
        `Updated`). An up-to-date copy, or a file with no version marker (i.e.
        operator-owned), is left untouched. Operator behaviour is tuned via
        the script's PARAMETERS (-Scope, -NoPush, etc.), not by editing its
        body - body edits are replaced on a version-gated refresh. Pass
        -SkipStarterUpdater to freeze the file entirely.

    .PARAMETER SkipReadme
        Suppress the v0.9.0 managed repo README drop / version-gated refresh.
        By default Update also drops a lightweight, link-first `README.md` at
        the repo root when the repo has no usable README (missing,
        whitespace-only, or a GitHub "Add a README" default stub), and
        refreshes an existing module-managed README (one carrying the hidden
        `<!-- AZLOCAL-README-VERSION: x.y.z -->` marker) in place when the
        bundled template is newer. Any other non-empty README is treated as
        operator-owned and is never modified; remove the marker line to freeze
        a managed README as your own. Pass -SkipReadme to suppress entirely.

    .PARAMETER UpgradeFleetSettingsSchema
        Retained for backward compatibility. Existing active
        config/fleet-settings.yml schema version 1 files are upgraded to
        version 2 automatically during every update. The file is validated
        first, its exact original bytes are saved as
        config/fleet-settings_v1.bak.yml, and the active schemaVersion is
        changed before a fully commented clusterTagFilters example is
        appended. Existing operator values, comments, order, and line endings
        are preserved. Supports -WhatIf and -Confirm.

    .OUTPUTS
        PSCustomObject[] (with -PassThru) - one row per source file with:
            File              - destination path (always the CANONICAL,
                                de-numbered filename)
            Action            - 'Created' | 'Updated' | 'Updated-PinOnly'
                                | 'Renamed' | 'Unchanged' | 'Overwritten'
                                | 'Skipped-NeedsForce' | 'Skipped-NoChange'
            RenamedFrom       - legacy filename the destination file was
                                matched under and renamed FROM (e.g.
                                'Step.7_apply-updates.yml'), or $null when no
                                rename occurred. A non-null value means the
                                file was physically renamed to the canonical
                                name; if Action is also 'Updated'/'Overwritten'
                                the content was refreshed in the same pass.
            PreservedMarkers  - [string[]] marker names whose body was
                                preserved from the destination
            NewMarkers        - [string[]] marker names introduced in this
                                module version
            RemovedMarkers    - [string[]] marker names that existed at the
                                destination but are no longer in the source

    .EXAMPLE
        Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub

        Marker-aware refresh of the GitHub Actions workflow YAMLs. Any
        BEGIN/END-AZLOCAL-CUSTOMIZE block content already in your repo
        survives the upgrade; everything else is brought up to date.

    .EXAMPLE
        Update-AzLocalPipelineExample -Destination .\pipelines -Platform AzureDevOps -PassThru |
            Where-Object Action -ne 'Unchanged' |
            Format-Table File, Action, PreservedMarkers, NewMarkers

        Show only the files that actually changed in this upgrade, with the
        marker names that were preserved or newly introduced.

    .EXAMPLE
        Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -WhatIf

        Preview which files would be created / updated / skipped without
        writing anything.

    .EXAMPLE
        Update-AzLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Force

        First-time migration from a pre-v0.7.68 copy: overwrite YAMLs that
        do not yet contain BEGIN/END-AZLOCAL-CUSTOMIZE markers. Re-apply
        any operator customisations manually after the run.

    .NOTES
        Author      : Neil Bird, Microsoft
        Module      : AzLocal.UpdateManagement
        Added in    : v0.7.68
        Changed in  : v0.8.98 - also (re)drops the turnkey
                      Update-Module-And-Pipelines.ps1 into the repo root when
                      absent (never overwrites). Pass -SkipStarterUpdater to
                      suppress.
        See also    : Copy-AzLocalPipelineExample (clean-overwrite tool)
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Destination = $PWD.Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('GitHub', 'AzureDevOps')]
        [string]$Platform,

        [switch]$Force,

        # v0.8.85: when set, remove deprecated workflow filenames that are
        # superseded by newer merged pipelines (for example, GitHub
        # authentication-test.yml + inventory-clusters.yml replaced by
        # setup-validate-and-inventory.yml). Default OFF so upgrades remain
        # non-destructive unless explicitly requested.
        [switch]$PruneDeprecated,

        # v0.8.98: also (re)drop the turnkey Update-Module-And-Pipelines.ps1
        # refresh script into the repo root when it is absent, so existing
        # repos that upgrade via Update (not Copy) still receive it. Never
        # overwrites an existing copy. Pass -SkipStarterUpdater to suppress.
        [switch]$SkipStarterUpdater,

        # v0.9.0: also drop / version-gate refresh the managed repo README.md
        # at the repo root. Written only when the repo has no usable README
        # (missing / whitespace-only / GitHub default stub); an existing
        # managed README (carrying the AZLOCAL-README-VERSION marker) is
        # refreshed only when the bundled template is newer; any other
        # non-empty README is preserved. Pass -SkipReadme to suppress.
        [switch]$SkipReadme,

        # v0.9.1: also drop the header-only Excluded-Subscription-Ids.csv
        # skeleton into config\ when it is absent, so existing repos that
        # upgrade via Update (not Copy) still receive it. Never overwrites an
        # existing file. The skeleton is inert until the operator creates the
        # AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH variable. Pass -SkipStarterExclusions
        # to suppress.
        [switch]$SkipStarterExclusions,

        # Suppress the default inert config\fleet-settings.yml drop. Existing
        # operator-owned files are always preserved.
        [switch]$SkipStarterFleetSettings,

        # v0.9.23 compatibility switch. Active schema-v1 fleet settings are
        # now backed up and migrated automatically during every normal update.
        [switch]$UpgradeFleetSettingsSchema,

        [switch]$PassThru
    )

    # ------------------------------------------------------------------
    # 1. Locate the module install (sourceRoot). Match the resolution
    #    pattern used by Copy-AzLocalPipelineExample so a side-by-side
    #    development checkout works the same way the installed module
    #    does.
    # ------------------------------------------------------------------
    $module = Get-Module -Name 'AzLocal.UpdateManagement' |
                Sort-Object Version -Descending |
                Select-Object -First 1
    if (-not $module) {
        $moduleRoot = Split-Path -Parent $PSScriptRoot
    }
    else {
        $moduleRoot = $module.ModuleBase
    }

    $platformSubfolder = if ($Platform -eq 'GitHub') { 'github-actions' } else { 'azure-devops' }
    $sourceRoot       = Join-Path -Path $moduleRoot -ChildPath 'Automation-Pipeline-Examples'
    $platformSrc      = Join-Path -Path $sourceRoot -ChildPath $platformSubfolder

    if (-not (Test-Path -LiteralPath $platformSrc -PathType Container)) {
        throw "Update-AzLocalPipelineExample: bundled $Platform pipeline source folder not found at '$platformSrc'. The module install may be corrupt or this is a development checkout without the sample folder."
    }

    # ------------------------------------------------------------------
    # 2. Verify destination exists. Update is not a creation tool.
    # ------------------------------------------------------------------
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        throw "Update-AzLocalPipelineExample: -Destination folder '$Destination' does not exist. Use Copy-AzLocalPipelineExample for the initial drop, then re-run Update from the same folder."
    }
    $destResolved = (Resolve-Path -LiteralPath $Destination -ErrorAction Stop).ProviderPath

    Write-Log -Message "Update-AzLocalPipelineExample: comparing bundled $Platform samples in '$platformSrc' against destination '$destResolved'." -Level Info

    # ------------------------------------------------------------------
    # 3. Build the list of source YAMLs and the rename-aware matching maps.
    #
    #    v0.8.7: pipelines are matched to their destination counterpart by
    #    STABLE LOGICAL ID (the '# AZLOCAL-PIPELINE-ID:' header comment), not
    #    by filename. This lets the cmdlet follow a pipeline across a filename
    #    rename or a Step.N renumber WITHOUT stranding the customer's
    #    BEGIN/END-AZLOCAL-CUSTOMIZE marker bodies (e.g. their schedule CRONs).
    #
    #    Resolution order for each source file's destination match:
    #      (a) canonical filename present at -Destination, else
    #      (b) a destination *.yml whose embedded AZLOCAL-PIPELINE-ID equals
    #          the source ID (the customer renamed it, or it is a newer copy),
    #          else
    #      (c) a legacy 'Step.N_<base>.yml' alias filename listed in the
    #          manifest (a pre-v0.8.7 copy that predates the ID comment).
    #    A (b)/(c) match whose filename differs from the canonical name is
    #    RENAMED on disk to the canonical name after the marker-aware merge.
    # ------------------------------------------------------------------
    $srcFiles = @(Get-ChildItem -LiteralPath $platformSrc -Filter '*.yml' -File -ErrorAction Stop)
    if ($srcFiles.Count -eq 0) {
        Write-Log -Message "Update-AzLocalPipelineExample: no source *.yml files found under '$platformSrc'." -Level Warning
        return
    }

    # Manifest: logical ID -> canonical filename + legacy alias filenames.
    $manifest = @(Get-AzLocalPipelineManifest)

    # Pre-scan the destination folder once, indexing any *.yml that carries an
    # AZLOCAL-PIPELINE-ID comment by that ID (first occurrence wins). Used for
    # resolution path (b).
    $destIdMap = @{}
    foreach ($destYml in @(Get-ChildItem -LiteralPath $destResolved -Filter '*.yml' -File -ErrorAction SilentlyContinue)) {
        try {
            $destYmlText = [System.IO.File]::ReadAllText($destYml.FullName, [System.Text.UTF8Encoding]::new($false))
            $destYmlId   = Get-AzLocalPipelineId -Text $destYmlText
            if ($destYmlId -and -not $destIdMap.ContainsKey($destYmlId)) {
                $destIdMap[$destYmlId] = $destYml.FullName
            }
        }
        catch {
            Write-Verbose "Update-AzLocalPipelineExample: could not read '$($destYml.FullName)' during ID pre-scan: $($_.Exception.Message)"
        }
    }

    $results = New-Object System.Collections.Generic.List[pscustomobject]

    foreach ($srcFile in $srcFiles) {
        # Canonical destination path = the bundled (already de-numbered)
        # filename dropped into -Destination. This is always the WRITE target.
        $destFile = Join-Path -Path $destResolved -ChildPath $srcFile.Name

        # Resolve the source pipeline's logical ID. Prefer the embedded
        # AZLOCAL-PIPELINE-ID comment; fall back to the de-numbered base name.
        $srcText = [System.IO.File]::ReadAllText($srcFile.FullName, [System.Text.UTF8Encoding]::new($false))
        $srcId   = Get-AzLocalPipelineId -Text $srcText
        if (-not $srcId) {
            $srcId = [System.IO.Path]::GetFileNameWithoutExtension($srcFile.Name)
        }

        $row = [PSCustomObject]@{
            File             = $destFile
            Action           = ''
            RenamedFrom      = $null
            PreservedMarkers = @()
            NewMarkers       = @()
            RemovedMarkers   = @()
        }

        # Resolve the EXISTING destination representation to merge FROM.
        #   (a) canonical filename, (b) ID match, (c) alias filename.
        # $existingDestFile is the READ source; $destFile stays the WRITE
        # target. When they differ, this is a rename.
        $existingDestFile = $null
        $renamedFrom      = $null
        if (Test-Path -LiteralPath $destFile) {
            $existingDestFile = $destFile
            # If a canonical file exists AND a legacy alias also lingers, the
            # alias is a stale orphan from a prior layout. Flag it (do not
            # touch it - the canonical file is authoritative).
            foreach ($mEntry in @($manifest | Where-Object { $_.Id -eq $srcId })) {
                foreach ($aliasName in $mEntry.Aliases) {
                    $aliasPath = Join-Path -Path $destResolved -ChildPath $aliasName
                    if ((Test-Path -LiteralPath $aliasPath) -and ($aliasPath -ne $destFile)) {
                        Write-Log -Message "  Note    : '$aliasName' is a stale orphan (canonical '$($srcFile.Name)' already present). Safe to delete." -Level Warning
                    }
                }
            }
        }
        elseif ($destIdMap.ContainsKey($srcId)) {
            $existingDestFile = $destIdMap[$srcId]
            $renamedFrom      = Split-Path -Leaf $existingDestFile
        }
        else {
            foreach ($mEntry in @($manifest | Where-Object { $_.Id -eq $srcId })) {
                foreach ($aliasName in $mEntry.Aliases) {
                    $aliasPath = Join-Path -Path $destResolved -ChildPath $aliasName
                    if (Test-Path -LiteralPath $aliasPath) {
                        $existingDestFile = $aliasPath
                        $renamedFrom      = $aliasName
                        break
                    }
                }
                if ($existingDestFile) { break }
            }
        }

        if ($renamedFrom) {
            $row.RenamedFrom = $renamedFrom
            Write-Log -Message "  Rename  : '$renamedFrom' -> '$($srcFile.Name)' (matched by pipeline ID '$srcId'). Marker bodies (e.g. schedule CRONs) will be carried over." -Level Warning
            Write-Log -Message "            Platform note: renaming a workflow/pipeline file resets its run history grouping and can break branch-protection required status checks (GitHub) or orphan the pipeline definition until you re-point it at the new YAML path (Azure DevOps). Re-point/re-register after this run." -Level Warning
        }

        # 3a. Net-new file: simple copy. -------------------------------
        if (-not $existingDestFile) {
            if ($PSCmdlet.ShouldProcess($destFile, "Create new file from bundled sample")) {
                Write-Utf8NoBomFile -Path $destFile -Content $srcText
                $row.Action = 'Created'
                $srcMarkers = Get-AzLocalPipelineCustomiseMarkers -Text $srcText
                $row.NewMarkers = @($srcMarkers.Keys)
                Write-Log -Message "  Created : $($srcFile.Name)" -Level Success
            }
            else {
                $row.Action = 'Created'   # what WHATIF would do
            }
            [void]$results.Add($row)
            continue
        }

        # 3b. File exists. Read the existing (possibly aliased) destination
        #     representation. $srcText was already read above.
        $destText = [System.IO.File]::ReadAllText($existingDestFile, [System.Text.UTF8Encoding]::new($false))

        $srcMarkers  = Get-AzLocalPipelineCustomiseMarkers -Text $srcText
        $destMarkers = Get-AzLocalPipelineCustomiseMarkers -Text $destText

        $hasSrcMarkers  = $srcMarkers.Count  -gt 0
        $hasDestMarkers = $destMarkers.Count -gt 0

        # 3c. Both files marker-free -> straight diff/overwrite path. -
        if (-not $hasSrcMarkers -and -not $hasDestMarkers) {
            if ($srcText -eq $destText) {
                if ($renamedFrom) {
                    # Content identical but the file is at a legacy name -> rename to canonical.
                    if ($PSCmdlet.ShouldProcess($destFile, "Rename '$renamedFrom' -> '$($srcFile.Name)' (content identical)")) {
                        Write-Utf8NoBomFile -Path $destFile -Content $srcText
                        if (($existingDestFile -ne $destFile) -and (Test-Path -LiteralPath $existingDestFile)) { Remove-Item -LiteralPath $existingDestFile -Force }
                        Write-Log -Message "  Renamed : '$renamedFrom' -> '$($srcFile.Name)' (content identical)" -Level Success
                    }
                    $row.Action = 'Renamed'
                }
                else {
                    $row.Action = 'Unchanged'
                }
                [void]$results.Add($row)
                continue
            }
            # 3c.i. Pin-only short-circuit (v0.7.95): if the ONLY content
            # difference is the GENERATED_AGAINST_MODULE_VERSION pin
            # (mechanically bumped on every release, not an operator
            # customisation surface), refresh it in place without -Force.
            # Normalise the pin to a placeholder in BOTH texts and compare;
            # equal-after-normalisation means the pin is the only diff.
            # Pattern matches both the single-line GitHub Actions shape
            # ('GENERATED_AGAINST_MODULE_VERSION: ''X''') and the two-line
            # Azure DevOps name/value shape ('- name: GENERATED_..., value: ''X''').
            $pinPattern = "(?m)(?:^\s*GENERATED_AGAINST_MODULE_VERSION\s*:\s*'[^']+'|^\s*-?\s*name\s*:\s*GENERATED_AGAINST_MODULE_VERSION\s*\r?\n\s*value\s*:\s*'[^']+')"
            $pinPlaceholder = "__AZLOCAL_PIN_PLACEHOLDER__"
            $srcNorm  = [regex]::Replace($srcText,  $pinPattern, { param($m) [regex]::Replace($m.Value, "'[^']+'", "'$pinPlaceholder'") })
            $destNorm = [regex]::Replace($destText, $pinPattern, { param($m) [regex]::Replace($m.Value, "'[^']+'", "'$pinPlaceholder'") })
            if ($srcNorm -eq $destNorm) {
                # Pin is the only line that changed. Extract both values
                # for the success log line, then write src verbatim.
                $srcPinMatch  = [regex]::Match($srcText,  $pinPattern)
                $destPinMatch = [regex]::Match($destText, $pinPattern)
                $srcPinValue  = if ($srcPinMatch.Success)  { ([regex]::Match($srcPinMatch.Value,  "'([^']+)'")).Groups[1].Value } else { '?' }
                $destPinValue = if ($destPinMatch.Success) { ([regex]::Match($destPinMatch.Value, "'([^']+)'")).Groups[1].Value } else { '?' }
                if ($PSCmdlet.ShouldProcess($destFile, "Bump GENERATED_AGAINST_MODULE_VERSION from '$destPinValue' to '$srcPinValue' (pin-only diff)")) {
                    Write-Utf8NoBomFile -Path $destFile -Content $srcText
                    if ($renamedFrom -and ($existingDestFile -ne $destFile) -and (Test-Path -LiteralPath $existingDestFile)) { Remove-Item -LiteralPath $existingDestFile -Force }
                    Write-Log -Message "  Updated : $($srcFile.Name), pin-only ('$destPinValue' -> '$srcPinValue')" -Level Success
                }
                $row.Action = 'Updated-PinOnly'
                [void]$results.Add($row)
                continue
            }
            if (-not $Force) {
                $row.Action = 'Skipped-NeedsForce'
                Write-Log -Message "  Skipped : $($srcFile.Name) - diverged from bundled sample, no markers to merge on. Pass -Force to overwrite, or hand-merge the diff." -Level Warning
                [void]$results.Add($row)
                continue
            }
            if ($PSCmdlet.ShouldProcess($destFile, "Overwrite (no markers, -Force supplied)")) {
                Write-Utf8NoBomFile -Path $destFile -Content $srcText
                if ($renamedFrom -and ($existingDestFile -ne $destFile) -and (Test-Path -LiteralPath $existingDestFile)) { Remove-Item -LiteralPath $existingDestFile -Force }
                Write-Log -Message "  Overwritten (forced): $($srcFile.Name)" -Level Warning
            }
            $row.Action = 'Overwritten'
            [void]$results.Add($row)
            continue
        }

        # 3d. Source has markers, destination doesn't -> first-migration
        #     from a pre-v0.7.68 copy. Cannot infer what to preserve.
        if ($hasSrcMarkers -and -not $hasDestMarkers) {
            if (-not $Force) {
                $row.Action = 'Skipped-NeedsForce'
                $row.NewMarkers = @($srcMarkers.Keys)
                Write-Log -Message "  Skipped : $($srcFile.Name) - destination has no AZLOCAL-CUSTOMIZE markers (pre-v0.7.68 copy). Pass -Force to migrate (re-apply customisations afterwards), or add BEGIN/END markers around your edits first." -Level Warning
                [void]$results.Add($row)
                continue
            }
            if ($PSCmdlet.ShouldProcess($destFile, "First-migration overwrite (destination has no markers, -Force supplied)")) {
                Write-Utf8NoBomFile -Path $destFile -Content $srcText
                if ($renamedFrom -and ($existingDestFile -ne $destFile) -and (Test-Path -LiteralPath $existingDestFile)) { Remove-Item -LiteralPath $existingDestFile -Force }
                Write-Log -Message "  Overwritten (first migration): $($srcFile.Name) - re-apply any customisations now." -Level Warning
            }
            $row.Action = 'Overwritten'
            $row.NewMarkers = @($srcMarkers.Keys)
            [void]$results.Add($row)
            continue
        }

        # 3e. Destination has markers, source doesn't -> reverse case.
        #     We have nowhere to graft the destination body into, so the
        #     destination bodies would be lost. Refuse without -Force.
        if (-not $hasSrcMarkers -and $hasDestMarkers) {
            if (-not $Force) {
                $row.Action = 'Skipped-NeedsForce'
                $row.RemovedMarkers = @($destMarkers.Keys)
                Write-Log -Message "  Skipped : $($srcFile.Name) - destination has AZLOCAL-CUSTOMIZE markers but the new bundled sample does not. Bodies would be discarded. Pass -Force to overwrite anyway." -Level Warning
                [void]$results.Add($row)
                continue
            }
            if ($PSCmdlet.ShouldProcess($destFile, "Overwrite (markers removed by upgrade, -Force supplied)")) {
                Write-Utf8NoBomFile -Path $destFile -Content $srcText
                if ($renamedFrom -and ($existingDestFile -ne $destFile) -and (Test-Path -LiteralPath $existingDestFile)) { Remove-Item -LiteralPath $existingDestFile -Force }
                Write-Log -Message "  Overwritten (markers removed): $($srcFile.Name) - destination marker bodies discarded." -Level Warning
            }
            $row.Action = 'Overwritten'
            $row.RemovedMarkers = @($destMarkers.Keys)
            [void]$results.Add($row)
            continue
        }

        # 3f. Both have markers -> marker-aware merge.
        #
        # Walk the source string and, for every BEGIN/END pair in the source
        # whose <section> name also exists at the destination, splice the
        # destination's body in. We process matches RIGHT-TO-LEFT so the
        # captured indices stay valid as we mutate the working copy.
        $merged          = $srcText
        $preserved       = New-Object System.Collections.Generic.List[string]
        $srcMarkerOrder  = $srcMarkers.GetEnumerator() | Sort-Object { $_.Value.Index } -Descending

        foreach ($entry in $srcMarkerOrder) {
            $name = $entry.Key
            if ($destMarkers.ContainsKey($name)) {
                $srcBlock  = $entry.Value
                $destBlock = $destMarkers[$name]
                # Keep src's BeginLine + EndLine (canonical comment text)
                # and inject dest's preserved body.
                $newBlockText = $srcBlock.BeginLine + $destBlock.Body + $srcBlock.EndLine
                $merged = $merged.Substring(0, $srcBlock.Index) +
                          $newBlockText +
                          $merged.Substring($srcBlock.Index + $srcBlock.Length)
                [void]$preserved.Add($name)
            }
        }

        $row.PreservedMarkers = @($preserved)
        $row.NewMarkers       = @($srcMarkers.Keys  | Where-Object { -not $destMarkers.ContainsKey($_) })
        $row.RemovedMarkers   = @($destMarkers.Keys | Where-Object { -not $srcMarkers.ContainsKey($_) })

        if ($merged -eq $destText) {
            if ($renamedFrom) {
                # Merged content identical to the destination but the file is
                # at a legacy name -> rename to canonical (carries markers).
                if ($PSCmdlet.ShouldProcess($destFile, "Rename '$renamedFrom' -> '$($srcFile.Name)' (merged content identical)")) {
                    Write-Utf8NoBomFile -Path $destFile -Content $merged
                    if (($existingDestFile -ne $destFile) -and (Test-Path -LiteralPath $existingDestFile)) { Remove-Item -LiteralPath $existingDestFile -Force }
                    Write-Log -Message "  Renamed : '$renamedFrom' -> '$($srcFile.Name)' (merged content identical, markers preserved)" -Level Success
                }
                $row.Action = 'Renamed'
            }
            else {
                $row.Action = 'Unchanged'
            }
            [void]$results.Add($row)
            continue
        }

        if ($PSCmdlet.ShouldProcess($destFile, "Update YAML (preserve $($preserved.Count) marker block(s))")) {
            Write-Utf8NoBomFile -Path $destFile -Content $merged
            if ($renamedFrom -and ($existingDestFile -ne $destFile) -and (Test-Path -LiteralPath $existingDestFile)) { Remove-Item -LiteralPath $existingDestFile -Force }
            $kept     = if ($preserved.Count -gt 0) { ", preserved=$([string]::Join(',', $preserved))" } else { '' }
            $added    = if ($row.NewMarkers.Count  -gt 0) { ", new=$([string]::Join(',', $row.NewMarkers))" }     else { '' }
            $removed  = if ($row.RemovedMarkers.Count -gt 0) { ", removed=$([string]::Join(',', $row.RemovedMarkers))" } else { '' }
            $renamed  = if ($renamedFrom) { ", renamedFrom=$renamedFrom" } else { '' }
            Write-Log -Message "  Updated : $($srcFile.Name)${kept}${added}${removed}${renamed}" -Level Success
        }
        $row.Action = 'Updated'
        [void]$results.Add($row)
    }

    # ------------------------------------------------------------------
    # 4. Summary log line + optional PassThru emission.
    # ------------------------------------------------------------------
    $byAction = $results | Group-Object Action | Sort-Object Name
    $summary  = ($byAction | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    Write-Log -Message "Update-AzLocalPipelineExample: $($results.Count) source file(s) processed - $summary" -Level Info

    # v0.8.85: optional cleanup for deprecated merged GitHub workflows.
    if ($Platform -eq 'GitHub') {
        $replacementPath = Join-Path -Path $destResolved -ChildPath 'setup-validate-and-inventory.yml'
        $deprecatedFiles = @(
            [PSCustomObject]@{ Path = (Join-Path -Path $destResolved -ChildPath 'authentication-test.yml'); ExpectedId = 'authentication-test' }
            [PSCustomObject]@{ Path = (Join-Path -Path $destResolved -ChildPath 'inventory-clusters.yml');  ExpectedId = 'inventory-clusters' }
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
                        Write-Log -Message "  Note    : could not inspect '$([System.IO.Path]::GetFileName($deprecatedPath))' for AZLOCAL-PIPELINE-ID; leaving file untouched. $($_.Exception.Message)" -Level Warning
                    }

                    if (-not $canDelete) {
                        Write-Log -Message "  Note    : '$([System.IO.Path]::GetFileName($deprecatedPath))' does not match expected pipeline ID '$expectedId'; leaving file untouched." -Level Warning
                        continue
                    }

                    if ($PSCmdlet.ShouldProcess($deprecatedPath, 'Remove deprecated workflow replaced by setup-validate-and-inventory.yml')) {
                        Remove-Item -LiteralPath $deprecatedPath -Force -ErrorAction Stop
                        Write-Log -Message "  Removed : deprecated workflow '$([System.IO.Path]::GetFileName($deprecatedPath))' (replaced by setup-validate-and-inventory.yml)" -Level Success
                    }
                }
            }
            else {
                $deprecatedList = ($existingDeprecated | ForEach-Object { "  - $([System.IO.Path]::GetFileName($_.Path))" }) -join [Environment]::NewLine
                Write-Log -Message ("  Note    : deprecated workflow file(s) detected (replaced by setup-validate-and-inventory.yml). Left in place by default to avoid destructive changes:{0}{1}{0}            Rerun with -PruneDeprecated to remove them automatically." -f [Environment]::NewLine, $deprecatedList) -Level Warning
            }
        }
    }

    # ------------------------------------------------------------------
    # 5 (v0.8.98). Turnkey refresh-script drop parity with
    #    Copy-AzLocalPipelineExample. Existing users upgrade by running
    #    Update (not Copy), so Update must ALSO (re)create the turnkey
    #    Update-Module-And-Pipelines.ps1 at the repo root when it is
    #    absent - otherwise pre-v0.8.98 repos would never receive it.
    #    Default-on; NEVER overwrites an existing copy (operator edits
    #    win); suppressed by -SkipStarterUpdater. The bundled source
    #    carries two tokens substituted at drop time:
    #       __PLATFORM__         -> 'GitHub' | 'AzureDevOps'
    #       __WORKFLOW_SUBPATH__ -> the workflow folder relative to the
    #                               repo root (forward-slashed).
    # ------------------------------------------------------------------
    if (-not $SkipStarterUpdater.IsPresent) {
        $updaterSrc = Join-Path -Path $sourceRoot -ChildPath 'update-module-and-pipelines.ps1'

        # Repo-root resolution mirrors Copy-AzLocalPipelineExample: for the
        # canonical GitHub layout (.github\workflows) the repo root is two
        # levels up; for Azure DevOps / other layouts it is one level up.
        $trimmedTarget = $destResolved.TrimEnd('\', '/')
        $oneLevelUp    = Split-Path -Parent $trimmedTarget
        if ($Platform -eq 'GitHub' -and ($trimmedTarget -match '[\\/]\.github[\\/]workflows$')) {
            $repoRoot = Split-Path -Parent $oneLevelUp
        }
        else {
            $repoRoot = $oneLevelUp
        }
        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
            $repoRoot = $trimmedTarget
        }

        $updaterDest = Join-Path -Path $repoRoot -ChildPath 'Update-Module-And-Pipelines.ps1'

        if (-not (Test-Path -LiteralPath $updaterSrc -PathType Leaf)) {
            Write-Log -Message ("  Note    : updater script source '{0}' not found; skipping turnkey script drop." -f $updaterSrc) -Level Warning
        }
        else {
            # Fresh-drop vs version-gated refresh vs no-op. The bundled
            # template carries an AZLOCAL-UPDATER-VERSION stamp; an EXISTING
            # file is only re-rendered when the bundled version is NEWER (so
            # module-shipped improvements reach repos that upgrade via Update),
            # and is otherwise preserved (operator edits / up-to-date copies
            # are never clobbered).
            $bundledText    = Get-Content -LiteralPath $updaterSrc -Raw
            $bundledVersion = Get-AzLocalUpdaterScriptVersion -Text $bundledText
            $updaterExists  = Test-Path -LiteralPath $updaterDest -PathType Leaf
            $isRefresh      = $false
            if ($updaterExists) {
                $existingVersion = Get-AzLocalUpdaterScriptVersion -Text (Get-Content -LiteralPath $updaterDest -Raw)
                # Only re-render when the existing file carries a parseable
                # AZLOCAL-UPDATER-VERSION marker that is STRICTLY OLDER than the
                # bundled template. A file with NO marker is treated as
                # operator-owned and preserved (never clobbered).
                if ($existingVersion -and $bundledVersion -and $bundledVersion -gt $existingVersion) {
                    $isRefresh = $true
                }
            }

            if ($updaterExists -and -not $isRefresh) {
                Write-Verbose ("Update-AzLocalPipelineExample: updater script preserved (already present and up to date at '{0}'); not copied." -f $updaterDest)
            }
            else {
                $shouldMsg = if ($isRefresh) {
                    "Refresh turnkey Update-Module-And-Pipelines.ps1 to v$bundledVersion (Platform=$Platform)"
                }
                else {
                    "Write turnkey Update-Module-And-Pipelines.ps1 (Platform=$Platform)"
                }
                if ($PSCmdlet.ShouldProcess($updaterDest, $shouldMsg)) {
                    $repoRootTrim    = $repoRoot.TrimEnd('\', '/')
                    $workflowSubPath = $trimmedTarget.Substring($repoRootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
                    if ([string]::IsNullOrWhiteSpace($workflowSubPath)) {
                        $workflowSubPath = (Split-Path -Leaf $trimmedTarget)
                    }

                    $updaterText = $bundledText.Replace('__PLATFORM__', $Platform).Replace('__WORKFLOW_SUBPATH__', $workflowSubPath)
                    # UTF-8 without BOM (PS 5.1 Set-Content -Encoding UTF8 would add one).
                    [System.IO.File]::WriteAllText($updaterDest, $updaterText, [System.Text.UTF8Encoding]::new($false))
                    if ($isRefresh) {
                        Write-Log -Message ("  Updated : turnkey refresh script 'Update-Module-And-Pipelines.ps1' refreshed to template v{0} at repo root '{1}'" -f $bundledVersion, $repoRoot) -Level Success
                    }
                    else {
                        Write-Log -Message "  Created : turnkey refresh script 'Update-Module-And-Pipelines.ps1' at repo root '$repoRoot'" -Level Success
                    }
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # 6 (v0.9.0). Managed repo README drop / version-gated refresh parity
    #    with Copy-AzLocalPipelineExample (section 6d). Existing users
    #    upgrade via Update, so Update must also drop the managed README at
    #    the repo root when the repo has no usable README (missing /
    #    whitespace-only / GitHub default stub), and refresh an older
    #    module-managed README (carrying the AZLOCAL-README-VERSION marker)
    #    in place. Operator-owned READMEs are never modified. Suppressed by
    #    -SkipReadme.
    # ------------------------------------------------------------------
    if (-not $SkipReadme.IsPresent) {
        $readmeSrc = Join-Path -Path $sourceRoot -ChildPath 'repo-readme-template.md'

        # Repo-root resolution mirrors section 5 / Copy-AzLocalPipelineExample.
        $trimmedTarget = $destResolved.TrimEnd('\', '/')
        $oneLevelUp    = Split-Path -Parent $trimmedTarget
        if ($Platform -eq 'GitHub' -and ($trimmedTarget -match '[\\/]\.github[\\/]workflows$')) {
            $repoRoot = Split-Path -Parent $oneLevelUp
        }
        else {
            $repoRoot = $oneLevelUp
        }
        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
            $repoRoot = $trimmedTarget
        }

        $readmeDest = Join-Path -Path $repoRoot -ChildPath 'README.md'

        if (-not (Test-Path -LiteralPath $readmeSrc -PathType Leaf)) {
            Write-Log -Message ("  Note    : README template source '{0}' not found; skipping README drop." -f $readmeSrc) -Level Warning
        }
        else {
            # Fresh-drop vs version-gated refresh vs preserve. A repo with no
            # usable README (missing / whitespace-only / GitHub default stub)
            # gets the managed README; a README already carrying the
            # AZLOCAL-README-VERSION marker is re-rendered only when the
            # bundled template is NEWER; any other non-empty README is
            # operator-owned and preserved.
            $bundledReadme         = Get-Content -LiteralPath $readmeSrc -Raw
            $bundledReadmeVersion  = Get-AzLocalReadmeTemplateVersion -Text $bundledReadme
            $readmeExists          = Test-Path -LiteralPath $readmeDest -PathType Leaf
            $existingReadmeText    = if ($readmeExists) { Get-Content -LiteralPath $readmeDest -Raw } else { '' }
            $existingReadmeVersion = Get-AzLocalReadmeTemplateVersion -Text $existingReadmeText

            $writeReadme     = $false
            $isReadmeRefresh = $false
            if (-not $readmeExists) {
                $writeReadme = $true
            }
            elseif ($existingReadmeVersion) {
                if ($bundledReadmeVersion -and $bundledReadmeVersion -gt $existingReadmeVersion) {
                    $writeReadme     = $true
                    $isReadmeRefresh = $true
                }
            }
            elseif (Test-AzLocalReadmeReplaceable -Text $existingReadmeText -RepoName (Split-Path -Leaf $repoRoot.TrimEnd('\', '/'))) {
                $writeReadme = $true
            }

            if (-not $writeReadme) {
                Write-Verbose ("Update-AzLocalPipelineExample: README preserved (operator-owned or already up to date at '{0}'); not written." -f $readmeDest)
            }
            else {
                $shouldMsg = if ($isReadmeRefresh) {
                    "Refresh managed README.md to v$bundledReadmeVersion"
                }
                else {
                    "Write managed README.md"
                }
                if ($PSCmdlet.ShouldProcess($readmeDest, $shouldMsg)) {
                    $repoRootTrim    = $repoRoot.TrimEnd('\', '/')
                    $workflowSubPath = $trimmedTarget.Substring($repoRootTrim.Length).TrimStart('\', '/') -replace '\\', '/'
                    if ([string]::IsNullOrWhiteSpace($workflowSubPath)) {
                        $workflowSubPath = (Split-Path -Leaf $trimmedTarget)
                    }
                    $readmeText = $bundledReadme.Replace('__PLATFORM__', $Platform).Replace('__WORKFLOW_SUBPATH__', $workflowSubPath)
                    # UTF-8 without BOM (PS 5.1 Set-Content -Encoding UTF8 would add one).
                    [System.IO.File]::WriteAllText($readmeDest, $readmeText, [System.Text.UTF8Encoding]::new($false))
                    if ($isReadmeRefresh) {
                        Write-Log -Message ("  Updated : managed README.md refreshed to template v{0} at repo root '{1}'" -f $bundledReadmeVersion, $repoRoot) -Level Success
                    }
                    else {
                        Write-Log -Message "  Created : managed README.md at repo root '$repoRoot'" -Level Success
                    }
                }
            }
        }
    }

    # ------------------------------------------------------------------
    # 7. Fleet settings starter drop parity with Copy-AzLocalPipelineExample.
    # Existing repos upgraded via Update receive the fully commented starter;
    # an existing schema v1 file is backed up before the v2 settings are added.
    # ------------------------------------------------------------------
    $trimmedTarget = $destResolved.TrimEnd('\', '/')
    $oneLevelUp = Split-Path -Parent $trimmedTarget
    if ($Platform -eq 'GitHub' -and ($trimmedTarget -match '[\\/]\.github[\\/]workflows$')) {
        $repoRoot = Split-Path -Parent $oneLevelUp
    }
    else {
        $repoRoot = $oneLevelUp
    }
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        $repoRoot = $trimmedTarget
    }

    $fleetSettingsSrc = Join-Path -Path $sourceRoot -ChildPath 'fleet-settings.example.yml'
    $fleetSettingsDest = Join-Path -Path (Join-Path -Path $repoRoot -ChildPath 'config') -ChildPath 'fleet-settings.yml'
    if (Test-Path -LiteralPath $fleetSettingsDest -PathType Leaf) {
        $validatedSettings = Get-AzLocalFleetSettings -Path $fleetSettingsDest
        $settingsBytes = [System.IO.File]::ReadAllBytes($fleetSettingsDest)
        $settingsText = [System.IO.File]::ReadAllText($fleetSettingsDest, [System.Text.UTF8Encoding]::new($false))
        $conversion = Convert-AzLocalFleetSettingsSchemaVersion -Text $settingsText -SourcePath $fleetSettingsDest
        if ($validatedSettings.SchemaVersion -eq 1 -and $conversion.Migrated -and
            $PSCmdlet.ShouldProcess($fleetSettingsDest, 'Back up schema v1 and upgrade fleet-settings.yml to schema v2')) {
            $fleetSettingsBackup = Join-Path -Path (Split-Path -Parent $fleetSettingsDest) -ChildPath 'fleet-settings_v1.bak.yml'
            if (Test-Path -LiteralPath $fleetSettingsBackup -PathType Leaf) {
                $backupBytes = [System.IO.File]::ReadAllBytes($fleetSettingsBackup)
                if ([Convert]::ToBase64String($backupBytes) -ne [Convert]::ToBase64String($settingsBytes)) {
                    throw "Update-AzLocalPipelineExample: Backup '$fleetSettingsBackup' already exists with different content. Preserve or rename it before retrying the schema upgrade."
                }
            }
            else {
                [System.IO.File]::WriteAllBytes($fleetSettingsBackup, $settingsBytes)
                Write-Log -Message "  Created : schema v1 backup at '$fleetSettingsBackup'" -Level Success
            }
            [System.IO.File]::WriteAllText($fleetSettingsDest, $conversion.NewText, [System.Text.UTF8Encoding]::new($false))
            Write-Log -Message "  Updated : fleet-settings.yml upgraded from schema v1 to v2 at '$fleetSettingsDest'" -Level Success
        }
        elseif (-not $conversion.Migrated) {
            Write-Verbose ("Update-AzLocalPipelineExample: fleet-settings.yml schema upgrade not required ({0})." -f $conversion.Reason)
        }
    }
    elseif ($SkipStarterFleetSettings.IsPresent) {
        Write-Verbose 'Update-AzLocalPipelineExample: starter fleet-settings.yml creation skipped by -SkipStarterFleetSettings.'
    }
    elseif (-not (Test-Path -LiteralPath $fleetSettingsSrc -PathType Leaf)) {
        Write-Log -Message ("  Note    : fleet settings source '{0}' not found; skipping starter copy." -f $fleetSettingsSrc) -Level Warning
    }
    elseif ($PSCmdlet.ShouldProcess($fleetSettingsDest, 'Write starter fleet-settings.yml')) {
        $fleetSettingsParent = Split-Path -Parent $fleetSettingsDest
        if (-not (Test-Path -LiteralPath $fleetSettingsParent)) {
            $null = New-Item -ItemType Directory -Path $fleetSettingsParent -Force -ErrorAction Stop
        }
        Copy-Item -LiteralPath $fleetSettingsSrc -Destination $fleetSettingsDest -ErrorAction Stop
        Write-Log -Message "  Created : inert starter fleet-settings.yml at '$fleetSettingsDest'" -Level Success
    }

    # ------------------------------------------------------------------
    # 8. Sideload settings/config parity with Copy-AzLocalPipelineExample.
    # Settings, auth-map, and catalog files are created only when absent and
    # are never overwritten here.
    # ------------------------------------------------------------------
    $trimmedTarget = $destResolved.TrimEnd('\', '/')
    $oneLevelUp = Split-Path -Parent $trimmedTarget
    if ($Platform -eq 'GitHub' -and ($trimmedTarget -match '[\\/]\.github[\\/]workflows$')) {
        $repoRoot = Split-Path -Parent $oneLevelUp
    }
    else {
        $repoRoot = $oneLevelUp
    }
    if ([string]::IsNullOrWhiteSpace($repoRoot)) { $repoRoot = $trimmedTarget }

    $sideloadConfigDir = Join-Path -Path $repoRoot -ChildPath 'config'
    $sideloadSettingsDest = Join-Path -Path $sideloadConfigDir -ChildPath 'sideload-settings.yml'
    $sideloadAuthMapDest = Join-Path -Path $sideloadConfigDir -ChildPath 'sideload-auth-map.csv'
    $sideloadCatalogDest = Join-Path -Path $sideloadConfigDir -ChildPath 'sideload-catalog.yml'

    $sideloadSettingsSrc = Join-Path -Path $sourceRoot -ChildPath 'sideload-settings.example.yml'
    if (Test-Path -LiteralPath $sideloadSettingsDest -PathType Leaf) {
        Write-Verbose ("Update-AzLocalPipelineExample: sideload-settings.yml preserved (already exists at '{0}')." -f $sideloadSettingsDest)
    }
    elseif (-not (Test-Path -LiteralPath $sideloadSettingsSrc -PathType Leaf)) {
        Write-Log -Message "  Note    : sideload settings template not found at '$sideloadSettingsSrc'." -Level Warning
    }
    elseif ($PSCmdlet.ShouldProcess($sideloadSettingsDest, 'Create starter sideload-settings.yml')) {
        if (-not (Test-Path -LiteralPath $sideloadConfigDir)) {
            $null = New-Item -ItemType Directory -Path $sideloadConfigDir -Force -ErrorAction Stop
        }
        Copy-Item -LiteralPath $sideloadSettingsSrc -Destination $sideloadSettingsDest -ErrorAction Stop
        Write-Log -Message "  Created : starter '$sideloadSettingsDest'" -Level Success
    }

    foreach ($sideloadDataFile in @(
        @{ Path = $sideloadAuthMapDest; Lines = @(
            '# Sideload auth-map. The first four columns are required.'
            'UpdateAuthAccountId,KeyVaultName,UsernameSecretName,PasswordSecretName,RemotingTargetFqdn,FqdnSuffix,AuthMechanism,ImportSharePath,CopyProfile'
        ) }
        @{ Path = $sideloadCatalogDest; Lines = @('schemaVersion: 1', 'packages:') }
    )) {
        if (-not (Test-Path -LiteralPath $sideloadDataFile.Path -PathType Leaf) -and
            $PSCmdlet.ShouldProcess($sideloadDataFile.Path, 'Create starter sideload data file')) {
            if (-not (Test-Path -LiteralPath $sideloadConfigDir)) {
                $null = New-Item -ItemType Directory -Path $sideloadConfigDir -Force -ErrorAction Stop
            }
            Set-Content -LiteralPath $sideloadDataFile.Path -Value $sideloadDataFile.Lines -Encoding ASCII -ErrorAction Stop
            Write-Log -Message "  Created : starter '$($sideloadDataFile.Path)'" -Level Success
        }
    }

    # ------------------------------------------------------------------
    # 9 (v0.9.1; split in v0.9.10). Subscription-exclusion starter drop parity
    #    with Copy-AzLocalPipelineExample (section 6b-2). Existing users upgrade
    #    via Update, so Update must also drop BOTH starter files into config\
    #    when absent: a CLEAN, comment-free Excluded-Subscription-Ids.csv (header
    #    row only, so it round-trips through Excel) and a sidecar
    #    Excluded-Subscription-Ids_README.txt carrying the operator guidance.
    #    NEVER overwrites an existing file (each evaluated independently). The
    #    CSV is inert until the operator creates the
    #    AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH variable. Suppressed by
    #    -SkipStarterExclusions.
    # ------------------------------------------------------------------
    if (-not $SkipStarterExclusions.IsPresent) {
        # config\ resolution mirrors section 5/6: repo root is the config parent.
        $trimmedTarget = $destResolved.TrimEnd('\', '/')
        $oneLevelUp    = Split-Path -Parent $trimmedTarget
        if ($Platform -eq 'GitHub' -and ($trimmedTarget -match '[\\/]\.github[\\/]workflows$')) {
            $repoRoot = Split-Path -Parent $oneLevelUp
        }
        else {
            $repoRoot = $oneLevelUp
        }
        if ([string]::IsNullOrWhiteSpace($repoRoot)) {
            $repoRoot = $trimmedTarget
        }

        $exclusionsConfigDir = Join-Path -Path $repoRoot -ChildPath 'config'
        $exclusionsDest      = Join-Path -Path $exclusionsConfigDir -ChildPath 'Excluded-Subscription-Ids.csv'
        $exclusionsReadmeDest = Join-Path -Path $exclusionsConfigDir -ChildPath 'Excluded-Subscription-Ids_README.txt'

        # --- 7a. Clean CSV (header row only, NO '#' comments). ---
        if (Test-Path -LiteralPath $exclusionsDest -PathType Leaf) {
            # Already present. If it is the legacy v0.9.1 commented format,
            # proactively normalize it to the clean comment-free CSV (preserving
            # any real subscription-id rows) so a later Excel save can never
            # mangle the embedded '#' comment lines. Otherwise leave it alone.
            # NOTE: Repair-AzLocalExcludedSubscriptionCsv is a one-time v0.9.1 ->
            # v0.9.10 migration; it is a no-op on clean CSVs and can be retired
            # in a future release.
            if (Repair-AzLocalExcludedSubscriptionCsv -Path $exclusionsDest) {
                Write-Log -Message "  Updated : normalized legacy Excluded-Subscription-Ids.csv to clean comment-free format at '$exclusionsDest' (subscription-id rows preserved)" -Level Success
            }
            else {
                Write-Verbose ("Update-AzLocalPipelineExample: Excluded-Subscription-Ids.csv preserved (already exists at '{0}'); not written." -f $exclusionsDest)
            }
        }
        elseif ($PSCmdlet.ShouldProcess($exclusionsDest, 'Write starter Excluded-Subscription-Ids.csv')) {
            $exclusionsStarter = @(
                'Subscription IDs,Subscription Name,Comment / Notes'
            )
            $exclusionsParent = Split-Path -Parent $exclusionsDest
            if (-not (Test-Path -LiteralPath $exclusionsParent)) {
                $null = New-Item -ItemType Directory -Path $exclusionsParent -Force -ErrorAction Stop
            }
            Set-Content -LiteralPath $exclusionsDest -Value $exclusionsStarter -Encoding ASCII -ErrorAction Stop
            Write-Log -Message "  Created : starter Excluded-Subscription-Ids.csv at '$exclusionsDest'" -Level Success
        }

        # --- 7b. Sidecar README (.txt) with the guidance the CSV used to embed. ---
        if (Test-Path -LiteralPath $exclusionsReadmeDest -PathType Leaf) {
            Write-Verbose ("Update-AzLocalPipelineExample: Excluded-Subscription-Ids_README.txt preserved (already exists at '{0}'); not written." -f $exclusionsReadmeDest)
        }
        elseif ($PSCmdlet.ShouldProcess($exclusionsReadmeDest, 'Write starter Excluded-Subscription-Ids_README.txt')) {
            $exclusionsReadme = @(
                'Excluded-Subscription-Ids.csv - optional subscription exclusion list (v0.9.10)'
                '============================================================================='
                ''
                'PURPOSE'
                '  List Azure subscription IDs (one GUID per row, under the "Subscription IDs"'
                '  column) to EXCLUDE every resource in those subscriptions from ALL'
                '  AzLocal.UpdateManagement Azure Resource Graph queries - inventory, readiness,'
                '  fleet status, update runs, connectivity, etc. Useful for carving out'
                '  decommissioned, lab, or out-of-scope subscriptions without changing any'
                '  pipeline logic.'
                ''
                'HOW TO ACTIVATE (manual, one-time)'
                '  1. Add one subscription-id GUID per row to Excluded-Subscription-Ids.csv'
                '     under the "Subscription IDs" column, then commit the file.'
                '  2. Create a pipeline variable named AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH whose'
                '     value is the repo-relative path to the CSV, e.g.'
                '        ./config/Excluded-Subscription-Ids.csv'
                '       - GitHub Actions: a repository or organization Actions *variable*.'
                '       - Azure DevOps:  a pipeline variable (or variable group entry).'
                '  Until that variable is set, the CSV does nothing.'
                ''
                'RULES'
                '  - Only the "Subscription IDs" column is read. The "Subscription Name" and'
                '    "Comment / Notes" columns are for humans and are ignored.'
                '  - Each value must be a GUID. Non-GUID values are skipped with a warning.'
                '  - A header-only file (no data rows) is valid and excludes nothing; the run'
                '    emits a warning rather than failing.'
                ''
                'EDITING'
                '  - Keep this guidance in THIS .txt file, NOT in the .csv. The CSV must stay a'
                '    clean comma-separated file (header row + GUID rows only) so it round-trips'
                '    safely through Excel and other spreadsheet editors.'
                ''
                'WORKED EXAMPLE (what a populated CSV looks like)'
                '  Subscription IDs,Subscription Name,Comment / Notes'
                '  00000000-0000-0000-0000-000000000000,Contoso-Lab,Example only - replace or delete this row'
                '  11111111-1111-1111-1111-111111111111,Contoso-Decommissioned,Excluded pending tenant cleanup'
            )
            $exclusionsReadmeParent = Split-Path -Parent $exclusionsReadmeDest
            if (-not (Test-Path -LiteralPath $exclusionsReadmeParent)) {
                $null = New-Item -ItemType Directory -Path $exclusionsReadmeParent -Force -ErrorAction Stop
            }
            Set-Content -LiteralPath $exclusionsReadmeDest -Value $exclusionsReadme -Encoding ASCII -ErrorAction Stop
            Write-Log -Message "  Created : starter Excluded-Subscription-Ids_README.txt at '$exclusionsReadmeDest'" -Level Success
        }
    }

    if ($PassThru) {
        return $results.ToArray()
    }
}
