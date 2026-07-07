function Add-AzLocalPipelineVersionBanner {
    <#
    .SYNOPSIS
        Emits the module-version drift banner and step outputs that every
        AzLocal.UpdateManagement Step.*.yml install step needs.

    .DESCRIPTION
        Foundation cmdlet for the v0.8.5 thin-YAML refactor. Condenses the
        ~50-line install/drift/banner block that the v0.8.4 Step.*.yml
        files inline into ONE cmdlet call. The Step.*.yml install step
        becomes a three-liner:

            Install-Module AzLocal.UpdateManagement -Scope CurrentUser -Force -AllowClobber
            Import-Module  AzLocal.UpdateManagement -Force
            Add-AzLocalPipelineVersionBanner -GeneratedAgainstVersion $env:GENERATED_AGAINST_MODULE_VERSION -PinnedVersion $env:REQUIRED_MODULE_VERSION

        The cmdlet:
          1. Resolves the INSTALLED module version (handling the
             multi-entry Get-Module quirk when nested modules are loaded)
          2. Looks up the LATEST version on PSGallery via Find-Module
             (unless -SkipPSGalleryQuery is set)
          3. Prints a "Module version summary" console block (identical
             shape to the v0.8.4 inline block so log greps keep working)
          4. Emits up to three drift annotations via
             Write-AzLocalPipelineWarning / Write-AzLocalPipelineNotice:
               - WARNING when installed < generated (YAML newer than module)
               - NOTICE  when installed > generated (YAML older than module)
               - NOTICE  when latest    > installed (newer module on PSGallery)
          5. Appends a one-line banner to the rendered step summary via
             Add-AzLocalPipelineStepSummary
          6. Emits three step outputs via Set-AzLocalPipelineOutput:
               installed_module_version, generated_against_version,
               latest_on_psgallery
          7. Optionally returns a PSCustomObject describing the verdict
             when -PassThru is set (for test harnesses + downstream steps).

        Host detection (GitHub / AzureDevOps / Local) flows through the
        existing Phase 0 Private helpers - no per-host branching inside
        this cmdlet.

    .PARAMETER GeneratedAgainstVersion
        The module version this workflow YAML was generated against
        (typically '$env:GENERATED_AGAINST_MODULE_VERSION'). Required;
        must parse as a [version].

    .PARAMETER PinnedVersion
        The module version the operator pinned via the
        REQUIRED_MODULE_VERSION env var / workflow input. Empty / $null
        means "latest (fix-forward)". Used only for the human-readable
        "pin status" segment of the rendered banner.

    .PARAMETER ModuleName
        The PSGallery module to look up. Defaults to
        'AzLocal.UpdateManagement'. Parameterised so the cmdlet can be
        unit-tested against a synthetic module without touching the
        real Find-Module call.

    .PARAMETER PSGalleryRepositoryName
        The Find-Module -Repository value. Defaults to 'PSGallery'.

    .PARAMETER SkipPSGalleryQuery
        When set, the cmdlet does NOT call Find-Module. The "latest on
        PSGallery" segment of the banner renders as
        '(PSGallery lookup skipped)' and the step output
        'latest_on_psgallery' is the empty string. Use for offline
        runners or in tests.

    .PARAMETER SummaryFileName
        Forwarded to Add-AzLocalPipelineStepSummary. Defaults to
        'azlocal-version-banner.md'. Ignored on GitHub Actions (which
        uses a single $env:GITHUB_STEP_SUMMARY file managed by the
        runner).

    .PARAMETER PassThru
        When set, returns a PSCustomObject with InstalledVersion,
        GeneratedAgainstVersion, LatestOnPSGallery, PinStatus, Verdict.

    .OUTPUTS
        Nothing by default (side effects only). When -PassThru is set,
        returns a single PSCustomObject:
          InstalledVersion         [version]
          GeneratedAgainstVersion  [version]
          LatestOnPSGallery        [version] or $null
          PinStatus                [string] - 'pinned to vX.Y.Z' or 'latest (fix-forward)'
          Verdict                  [string] - one of:
                                       'in sync'
                                       'YAML newer than module - check REQUIRED_MODULE_VERSION'
                                       'YAML older than module - run Update-AzLocalPipelineExample to refresh'
                                       'newer module available on PSGallery'

    .EXAMPLE
        Add-AzLocalPipelineVersionBanner -GeneratedAgainstVersion '0.8.5'

        Default usage from a Step.*.yml install step. Emits drift
        annotations + banner + step outputs.

    .EXAMPLE
        $info = Add-AzLocalPipelineVersionBanner -GeneratedAgainstVersion '0.8.5' -PinnedVersion '0.8.5' -PassThru
        if ($info.Verdict -ne 'in sync') { ... }
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^\d+\.\d+\.\d+(\.\d+)?$')]
        [string]$GeneratedAgainstVersion,

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$PinnedVersion,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleName = 'AzLocal.UpdateManagement',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$PSGalleryRepositoryName = 'PSGallery',

        [Parameter()]
        [switch]$SkipPSGalleryQuery,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-version-banner.md',

        [Parameter()]
        [switch]$PassThru
    )

    $generated = [version]$GeneratedAgainstVersion

    $installedModule = Get-Module -Name $ModuleName | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $installedModule) {
        throw "Add-AzLocalPipelineVersionBanner: module '$ModuleName' is not loaded. Call Import-Module before invoking this cmdlet."
    }
    $installed = [version]$installedModule.Version

    $latest = $null
    if (-not $SkipPSGalleryQuery) {
        try {
            $found = Find-Module -Name $ModuleName -Repository $PSGalleryRepositoryName -ErrorAction Stop
            if ($found -and $found.Version) {
                $latest = [version]$found.Version
            }
        } catch {
            Write-Verbose "Add-AzLocalPipelineVersionBanner: Find-Module lookup failed - $($_.Exception.Message)"
        }
    }

    $pinStatus = if ([string]::IsNullOrWhiteSpace($PinnedVersion)) { 'latest (fix-forward)' } else { "pinned to v$PinnedVersion" }
    $latestStr = if ($SkipPSGalleryQuery) { '(PSGallery lookup skipped)' } elseif ($latest) { "v$latest" } else { '(PSGallery lookup failed)' }
    $verdict   = if ($installed -lt $generated) { 'YAML newer than module - check REQUIRED_MODULE_VERSION' }
                 elseif ($installed -gt $generated) { 'YAML older than module - run Update-AzLocalPipelineExample to refresh' }
                 elseif ($latest -and ($latest -gt $installed)) { 'newer module available on PSGallery' }
                 else { 'in sync' }

    # v0.8.75: tailor the refresh-command hint to the detected pipeline host so the
    # operator can copy-paste the exact -Platform and a sensible -Destination from the
    # annotation. The customer runs the refresh from their LAPTOP (not the runner),
    # so the destination uses a `<repo-root>` placeholder rather than the runner's
    # workspace path. Falls back to GitHub conventions for local invocations.
    $hostKind = Get-AzLocalPipelineHost
    $refreshPlatform = if ($hostKind -eq 'AzureDevOps') { 'AzureDevOps' } else { 'GitHub' }
    $refreshDestHint = if ($hostKind -eq 'AzureDevOps') { '<repo-root>\pipelines' } else { '<repo-root>\.github\workflows' }
    $refreshCommand = "Update-AzLocalPipelineExample -Destination '$refreshDestHint' -Platform $refreshPlatform"

    Write-Host ''
    Write-Host 'Module version summary'
    Write-Host "  Installed on runner       : $installed"
    Write-Host "  YAML generated against    : $generated"
    Write-Host "  Latest on PSGallery       : $(if ($SkipPSGalleryQuery) { '(skipped)' } elseif ($latest) { $latest } else { '(lookup failed - check network)' })"
    Write-Host "  Pin status                : $pinStatus"
    Write-Host "  Verdict                   : $verdict"
    Write-Host ''

    if ($installed -lt $generated) {
        Write-AzLocalPipelineWarning `
            -Title "$ModuleName is older than workflow YAML expects" `
            -Message "$ModuleName v$installed is OLDER than the version this workflow YAML was generated against (v$generated). Cmdlets, parameters, or output schemas referenced by this YAML may not exist in v$installed. Either pin REQUIRED_MODULE_VERSION to v$generated so the runner installs the matching version, or refresh the YAML to match the installed module by running (from your laptop): $refreshCommand. Update preserves your customisations bracketed by AZLOCAL-CUSTOMIZE markers (CRON schedules, ITSM secrets, etc.)."
    }
    if ($installed -gt $generated) {
        Write-AzLocalPipelineNotice `
            -Title 'Workflow YAML may be stale' `
            -Message "Workflow YAML was generated against $ModuleName v$generated but the runner installed v$installed. Pipeline steps may have been improved in later releases. From your laptop, refresh with: $refreshCommand. Update preserves your customisations bracketed by AZLOCAL-CUSTOMIZE markers (CRON schedules, ITSM secrets, etc.). Pipeline YAMLs are under git so 'git diff' shows exactly what changed before commit."
    }
    if ($latest -and ($latest -gt $installed)) {
        Write-AzLocalPipelineNotice `
            -Title "Newer $ModuleName version available on PSGallery" `
            -Message "$ModuleName v$latest is available on PSGallery; this run installed v$installed. Review the module CHANGELOG before bumping REQUIRED_MODULE_VERSION (or clear the pin to install the latest automatically)."
    }

    $banner = "_Pipeline YAML v$generated | Module v$installed installed ($pinStatus) | PSGallery latest $latestStr | ${verdict}_`n`n_Support caveat: The automation pipelines provided in the $ModuleName module are NOT a supported Microsoft service offering._`n"
    [void](Add-AzLocalPipelineStepSummary -Markdown $banner -SummaryFileName $SummaryFileName)

    Set-AzLocalPipelineOutput -Name 'installed_module_version'  -Value $installed.ToString()
    Set-AzLocalPipelineOutput -Name 'generated_against_version' -Value $generated.ToString()
    Set-AzLocalPipelineOutput -Name 'latest_on_psgallery'       -Value $(if ($latest) { $latest.ToString() } else { '' })

    if ($PassThru) {
        [PSCustomObject]@{
            InstalledVersion        = $installed
            GeneratedAgainstVersion = $generated
            LatestOnPSGallery       = $latest
            PinStatus               = $pinStatus
            Verdict                 = $verdict
        }
    }
}
