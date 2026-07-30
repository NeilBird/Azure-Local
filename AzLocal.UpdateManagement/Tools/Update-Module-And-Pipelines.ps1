#Requires -Version 5.1
<#
.SYNOPSIS
    Maintainer runner: install the latest published AzLocal.UpdateManagement,
    refresh the pipeline YAMLs in a target repo, then commit and push.

.DESCRIPTION
    This is the MAINTAINER-side equivalent of the customer-facing
    Update-Module-And-Pipelines.ps1 that Copy-AzLocalPipelineExample drops into
    a customer repo root. It lives under Tools\ so Publish-Module.ps1 strips it
    from the published PowerShell Gallery package (it is a repo-only helper).

    It installs/imports the latest published module version, runs
    Update-AzLocalPipelineExample against the target repo's workflow folder
    (a marker-aware merge that preserves AZLOCAL-CUSTOMIZE edits), then stages
    ONLY the workflow folder, config\, DevChannel\, managed README, and managed
    updater paths before committing and pushing any changes.

.PARAMETER RepoRoot
    Root of the repo whose pipelines should be refreshed.

.PARAMETER Platform
    Pipeline platform of the target repo.

.PARAMETER WorkflowSubPath
    Workflow / pipeline folder relative to RepoRoot.

.PARAMETER Scope
    Install scope passed to Install-Module when an upgrade is required.

.PARAMETER RequiredVersion
    Exact module version to install, import, and use for the pipeline refresh.
    Supports unlisted PowerShell Gallery candidates.

.PARAMETER LatestListed
    Explicitly resolve and use the latest listed PSGallery version, including
    when a newer unlisted version is installed side-by-side.

.PARAMETER AllowRollbackMarkerRemoval
    Allow rollback to remove AZLOCAL-CUSTOMIZE sections absent from the older
    template. Common marker bodies remain preserved.

.PARAMETER KeepNewerVersions
    Keep installed versions above the latest listed Gallery version. Without
    this switch, -LatestListed confirms and uninstalls each higher version so
    a fresh PowerShell session cannot auto-load it instead of the GA target.

.PARAMETER NoPush
    Refresh the YAMLs only - skip git add / commit / push.

.NOTES
    Author : Neil Bird, Microsoft
    Module : AzLocal.UpdateManagement (repo-only maintainer tool; not published)
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Latest')]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [ValidateSet('GitHub', 'AzureDevOps')]
    [string]$Platform = 'GitHub',

    [string]$WorkflowSubPath = '.github/workflows',

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'AllUsers',

    [Parameter(Mandatory = $true, ParameterSetName = 'Exact')]
    [ValidatePattern('^\d+\.\d+\.\d+(?:\.\d+)?$')]
    [version]$RequiredVersion,

    [Parameter(ParameterSetName = 'Latest')]
    [switch]$LatestListed,

    [switch]$AllowRollbackMarkerRemoval,

    [switch]$KeepNewerVersions,

    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'
$moduleName = 'AzLocal.UpdateManagement'

# 1. Install/upgrade to the latest published version, then import.
$installed = Get-Module -ListAvailable -Name $moduleName |
    Sort-Object Version -Descending | Select-Object -First 1
$targetVersion = $null
try {
    if ($PSBoundParameters.ContainsKey('RequiredVersion')) {
        $targetVersion = (Find-Module -Name $moduleName -RequiredVersion $RequiredVersion -Repository PSGallery -ErrorAction Stop).Version
    }
    else {
        $targetVersion = (Find-Module -Name $moduleName -Repository PSGallery -ErrorAction Stop).Version
    }
}
catch {
    if ($PSBoundParameters.ContainsKey('RequiredVersion')) {
        throw "Could not resolve exact $moduleName version $RequiredVersion from PowerShell Gallery. $($_.Exception.Message)"
    }
    if ($LatestListed.IsPresent) {
        throw "Could not resolve the latest listed $moduleName version from PowerShell Gallery. Refusing to fall back to an installed version because it may be an unlisted development-channel candidate. $($_.Exception.Message)"
    }
    Write-Warning "Could not query PowerShell Gallery for '$moduleName' ($($_.Exception.Message)). Using the installed version."
    if ($installed) { $targetVersion = $installed.Version }
}

if (-not $targetVersion) {
    throw "$moduleName is not installed and PowerShell Gallery could not be reached."
}

$installedTarget = Get-Module -ListAvailable -Name $moduleName |
    Where-Object { $_.Version -eq [version]$targetVersion } |
    Select-Object -First 1
if (-not $installedTarget) {
    $fromText = if ($installed) { $installed.Version } else { '(not installed)' }
    Write-Host "Installing $moduleName $targetVersion (highest installed: $fromText)..." -ForegroundColor Cyan
    Install-Module -Name $moduleName -Scope $Scope -RequiredVersion $targetVersion -Force -AllowClobber
}
else {
    Write-Host "$moduleName $targetVersion is already installed." -ForegroundColor Green
}

Get-Module -Name $moduleName | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module -Name $moduleName -RequiredVersion $targetVersion -Force

$version = (Get-Module -Name $moduleName).Version.ToString()

# 2. Refresh the pipeline YAMLs (marker-aware merge; preserves customisations).
$workflowFull = Join-Path -Path $RepoRoot -ChildPath $WorkflowSubPath
if (-not (Test-Path -LiteralPath $workflowFull)) {
    throw "Workflow folder not found: '$workflowFull'."
}
$preflightResults = @(Update-AzLocalPipelineExample -Destination $workflowFull -Platform $Platform -PassThru -WhatIf 6>$null)
$preflightMarkerRemovals = @($preflightResults | Where-Object { @($_.RemovedMarkers).Count -gt 0 })
if ($LatestListed.IsPresent -and $preflightMarkerRemovals.Count -gt 0 -and -not $AllowRollbackMarkerRemoval.IsPresent) {
    $preflightDetails = ($preflightMarkerRemovals | ForEach-Object {
        "{0} [{1}]" -f (Split-Path -Leaf $_.File), ([string]::Join(',', @($_.RemovedMarkers)))
    }) -join '; '
    throw "Pipeline rollback preflight stopped because the target templates would remove AZLOCAL-CUSTOMIZE sections: $preflightDetails. Review those bodies, then rerun with -AllowRollbackMarkerRemoval. No pipeline files or installed newer module versions were changed."
}

if ($LatestListed.IsPresent) {
    $newerInstalledVersions = @(Get-Module -ListAvailable -Name $moduleName |
        Where-Object { $_.Version -gt [version]$targetVersion } |
        Select-Object -ExpandProperty Version -Unique |
        Sort-Object -Descending)
    if ($newerInstalledVersions.Count -gt 0) {
        if ($KeepNewerVersions.IsPresent) {
            Write-Warning ("Keeping module version(s) newer than latest listed {0}: {1}. A fresh PowerShell session may auto-load the highest retained version." -f $targetVersion, ($newerInstalledVersions -join ', '))
        }
        else {
            Get-Module -Name $moduleName | Remove-Module -Force -ErrorAction SilentlyContinue
            foreach ($newerVersion in $newerInstalledVersions) {
                $caption = "Confirm removal of newer-than-listed $moduleName module version: $newerVersion"
                $message = "$moduleName $newerVersion is installed above latest listed version $targetVersion. It may be an unlisted development-channel candidate and PowerShell may auto-load it in a fresh session. Remove it now?"
                if (-not $PSCmdlet.ShouldContinue($message, $caption)) {
                    throw "Latest-listed rollback cancelled because $moduleName $newerVersion remains installed. Rerun and approve removal, or pass -KeepNewerVersions to accept the auto-loading risk explicitly."
                }
                if ($PSCmdlet.ShouldProcess("$moduleName $newerVersion", 'Uninstall module version newer than latest listed')) {
                    Uninstall-Module -Name $moduleName -RequiredVersion $newerVersion -Force -ErrorAction Stop
                    Write-Host "Removed $moduleName $newerVersion." -ForegroundColor Green
                }
            }
            Import-Module -Name $moduleName -RequiredVersion $targetVersion -Force
        }
    }
}

$refreshParameters = @{
    Destination = $workflowFull
    Platform = $Platform
    PassThru = $true
}
if ($AllowRollbackMarkerRemoval -and (Get-Command Update-AzLocalPipelineExample).Parameters.ContainsKey('AllowRollbackMarkerRemoval')) {
    $refreshParameters.AllowRollbackMarkerRemoval = $true
}
$refreshResults = @(Update-AzLocalPipelineExample @refreshParameters)
$blockedRollbacks = @($refreshResults | Where-Object { $_.Action -eq 'Skipped-RollbackMarkerRemoval' })
if ($blockedRollbacks.Count -gt 0) {
    $blockedNames = ($blockedRollbacks | ForEach-Object { Split-Path -Leaf $_.File }) -join ', '
    throw "Pipeline rollback stopped because older templates would remove customized marker sections from: $blockedNames. Review the diff, then rerun with -AllowRollbackMarkerRemoval."
}

# 3. Stage ONLY the workflow folder + config\, commit and push on change.
if ($NoPush) {
    Write-Host "-NoPush set; skipping git commit/push." -ForegroundColor Yellow
    return
}

$gitPaths = @($WorkflowSubPath, 'config', 'DevChannel') |
    Where-Object { Test-Path -LiteralPath (Join-Path -Path $RepoRoot -ChildPath $_) }
if ($gitPaths.Count -eq 0) {
    Write-Warning "Neither '$WorkflowSubPath' nor 'config' exists under '$RepoRoot'; nothing to stage."
    return
}

& git -C $RepoRoot add -A -- $gitPaths
if ($LASTEXITCODE -ne 0) { throw "git add failed (exit code $LASTEXITCODE)." }

& git -C $RepoRoot diff --cached --quiet
if ($LASTEXITCODE -eq 0) {
    Write-Host "No changes to commit - pipelines already match $moduleName $version." -ForegroundColor Green
    return
}

if ($PSCmdlet.ShouldProcess($RepoRoot, "git commit and push AzLocal pipeline refresh ($moduleName $version)")) {
    & git -C $RepoRoot commit -m "Refresh AzLocal update pipelines for $moduleName $version"
    if ($LASTEXITCODE -ne 0) { throw "git commit failed (exit code $LASTEXITCODE)." }
    & git -C $RepoRoot push
    if ($LASTEXITCODE -ne 0) { throw "git push failed (exit code $LASTEXITCODE)." }
    Write-Host "Pushed pipeline refresh for $moduleName $version." -ForegroundColor Green
}
