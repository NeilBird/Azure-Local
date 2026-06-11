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
        digits, hyphens and underscores. It is unique per file. Examples
        currently shipped:

            schedule-triggers   (every main pipeline)
            itsm-secrets        (Step.7_apply-updates.yml only)

        Per source YAML the cmdlet:

          1. Locates the matching destination file under -Destination.
             - Net-new files in the source set are CREATED (full copy).
             - Files present at -Destination but not in the source set are
               left untouched (orphaned customer-only files survive).

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
            File              - destination path
            Action            - 'Created' | 'Updated' | 'Updated-PinOnly'
                                | 'Unchanged' | 'Overwritten'
                                | 'Skipped-NeedsForce' | 'Skipped-NoChange'
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
    # 3. Build the list of source YAMLs. Match on exact filename at the
    #    destination so renames stay the caller's responsibility.
    # ------------------------------------------------------------------
    $srcFiles = @(Get-ChildItem -LiteralPath $platformSrc -Filter '*.yml' -File -ErrorAction Stop)
    if ($srcFiles.Count -eq 0) {
        Write-Log -Message "Update-AzLocalPipelineExample: no source *.yml files found under '$platformSrc'." -Level Warning
        return
    }

    $results = New-Object System.Collections.Generic.List[pscustomobject]

    foreach ($srcFile in $srcFiles) {
        $destFile = Join-Path -Path $destResolved -ChildPath $srcFile.Name

        $row = [PSCustomObject]@{
            File             = $destFile
            Action           = ''
            PreservedMarkers = @()
            NewMarkers       = @()
            RemovedMarkers   = @()
        }

        # 3a. Net-new file: simple copy. -------------------------------
        if (-not (Test-Path -LiteralPath $destFile)) {
            if ($PSCmdlet.ShouldProcess($destFile, "Create new file from bundled sample")) {
                $srcText = [System.IO.File]::ReadAllText($srcFile.FullName, [System.Text.UTF8Encoding]::new($false))
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

        # 3b. File exists. Read both ----------------------------------
        $srcText  = [System.IO.File]::ReadAllText($srcFile.FullName, [System.Text.UTF8Encoding]::new($false))
        $destText = [System.IO.File]::ReadAllText($destFile,           [System.Text.UTF8Encoding]::new($false))

        $srcMarkers  = Get-AzLocalPipelineCustomiseMarkers -Text $srcText
        $destMarkers = Get-AzLocalPipelineCustomiseMarkers -Text $destText

        $hasSrcMarkers  = $srcMarkers.Count  -gt 0
        $hasDestMarkers = $destMarkers.Count -gt 0

        # 3c. Both files marker-free -> straight diff/overwrite path. -
        if (-not $hasSrcMarkers -and -not $hasDestMarkers) {
            if ($srcText -eq $destText) {
                $row.Action = 'Unchanged'
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
            $row.Action = 'Unchanged'
            [void]$results.Add($row)
            continue
        }

        if ($PSCmdlet.ShouldProcess($destFile, "Update YAML (preserve $($preserved.Count) marker block(s))")) {
            Write-Utf8NoBomFile -Path $destFile -Content $merged
            $kept     = if ($preserved.Count -gt 0) { ", preserved=$([string]::Join(',', $preserved))" } else { '' }
            $added    = if ($row.NewMarkers.Count  -gt 0) { ", new=$([string]::Join(',', $row.NewMarkers))" }     else { '' }
            $removed  = if ($row.RemovedMarkers.Count -gt 0) { ", removed=$([string]::Join(',', $row.RemovedMarkers))" } else { '' }
            Write-Log -Message "  Updated : $($srcFile.Name)${kept}${added}${removed}" -Level Success
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

    if ($PassThru) {
        return $results.ToArray()
    }
}
