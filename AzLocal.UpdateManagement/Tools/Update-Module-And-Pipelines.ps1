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
    ONLY the workflow folder + config\ and commits/pushes any changes.

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

.PARAMETER NoPush
    Refresh the YAMLs only - skip git add / commit / push.

.NOTES
    Author : Neil Bird, Microsoft
    Module : AzLocal.UpdateManagement (repo-only maintainer tool; not published)
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [ValidateSet('GitHub', 'AzureDevOps')]
    [string]$Platform = 'GitHub',

    [string]$WorkflowSubPath = '.github/workflows',

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'AllUsers',

    [ValidatePattern('^\d+\.\d+\.\d+(?:\.\d+)?$')]
    [version]$RequiredVersion,

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
Update-AzLocalPipelineExample -Destination $workflowFull -Platform $Platform

# 3. Stage ONLY the workflow folder + config\, commit and push on change.
if ($NoPush) {
    Write-Host "-NoPush set; skipping git commit/push." -ForegroundColor Yellow
    return
}

$gitPaths = @($WorkflowSubPath, 'config') |
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
