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

    if ($PassThru) {
        return $results.ToArray()
    }
}
