#Requires -Version 5.1
# AZLOCAL-DEVELOPMENT-CHANNEL-VERSION: 1.3.0
<#
.SYNOPSIS
    Pins AzLocal pipelines to an exact module version.
.DESCRIPTION
    This script is managed under the repository's DevChannel folder. It
    detects GitHub Actions when a .github/workflows folder exists at the parent
    repository root; otherwise it selects Azure DevOps. Use -Platform to
    override detection in an unusual mixed-layout repository.

    For GitHub, the script creates or updates the non-secret repository
    variable REQUIRED_MODULE_VERSION through the authenticated GitHub CLI. For
    Azure DevOps, it prints the exact variable-group create/update command for
    the supplied version. Every bundled pipeline then installs that exact
    PowerShell Gallery candidate through Install-Module -RequiredVersion.

    Before applying the pin, the script invokes the sibling
    Update-Module-And-Pipelines.ps1 with -RequiredVersion so the exact module
    is installed/imported and the pipeline YAMLs are refreshed from its
    templates. With -Disable, it invokes the updater with -LatestListed before
    removing or describing removal of the pin.

    By default, the script verifies that the exact candidate resolves from
    PowerShell Gallery before changing the repository. Use -Disable after the
    candidate is listed to delete the variable and restore latest-listed
    module resolution.
.PARAMETER RequiredVersion
    Exact AzLocal.UpdateManagement version to assign to the repository variable.
.PARAMETER Disable
    Deletes the repository variable and restores latest-listed resolution.
.PARAMETER Repository
    GitHub repository in owner/name form. Defaults to the repository associated
    with the current directory. Ignored for Azure DevOps.
.PARAMETER Platform
    Pipeline platform. Auto selects GitHub when .github/workflows exists at the
    repository root and AzureDevOps otherwise.
.PARAMETER VariableName
    Repository variable to manage. Defaults to REQUIRED_MODULE_VERSION.
.PARAMETER SkipGalleryValidation
    Skips the exact-version PowerShell Gallery lookup. Intended only for
    diagnosing Gallery propagation delays.
.PARAMETER Scope
    Install scope passed to Update-Module-And-Pipelines.ps1.
.PARAMETER NoPush
    Passes -NoPush to Update-Module-And-Pipelines.ps1 so refreshed files remain
    uncommitted for local review.
.PARAMETER SkipPipelineRefresh
    Skips local module installation/import and pipeline refresh. Use only when
    the repository content has already been prepared or when removing a stale
    pin during recovery.
.PARAMETER AllowRollbackMarkerRemoval
    Passes narrow rollback approval to Update-Module-And-Pipelines.ps1. Use
    only after reviewing customization sections that exist in the current
    YAMLs but not in the older target templates.
.PARAMETER KeepNewerVersions
    With -Disable, keeps locally installed module versions above the latest
    listed Gallery version. Without it, the updater confirms removal so a new
    PowerShell session cannot auto-load the former development candidate.
.EXAMPLE
    .\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion 0.9.29 -Repository contoso/azure-local-operations

    Validate v0.9.29 and pin every bundled GitHub pipeline in the target repo.
.EXAMPLE
    .\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -Disable -Repository contoso/azure-local-operations

    Remove the development-channel pin after the candidate is listed.
.EXAMPLE
    .\DevChannel\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion 0.9.29 -Platform AzureDevOps

    Print the Azure DevOps variable-group commands for candidate v0.9.29.
.NOTES
    Requires GitHub CLI authentication with permission to manage Actions
    repository variables. REQUIRED_MODULE_VERSION is configuration, not a
    secret; never use this helper to store credentials.
#>
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Enable')]
param(
    [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Enable')]
    [ValidatePattern('^\d+\.\d+\.\d+(?:\.\d+)?$')]
    [version]$RequiredVersion,

    [Parameter(Mandatory = $true, ParameterSetName = 'Disable')]
    [switch]$Disable,

    [Parameter()]
    [ValidatePattern('^[^/\s]+/[^/\s]+$')]
    [string]$Repository,

    [Parameter()]
    [ValidateSet('Auto', 'GitHub', 'AzureDevOps')]
    [string]$Platform = 'Auto',

    [Parameter()]
    [ValidatePattern('^[A-Z][A-Z0-9_]{0,99}$')]
    [string]$VariableName = 'REQUIRED_MODULE_VERSION',

    [Parameter(ParameterSetName = 'Enable')]
    [switch]$SkipGalleryValidation,

    [Parameter()]
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string]$Scope = 'CurrentUser',

    [Parameter()]
    [switch]$NoPush,

    [Parameter()]
    [switch]$SkipPipelineRefresh,

    [Parameter()]
    [switch]$AllowRollbackMarkerRemoval,

    [Parameter(ParameterSetName = 'Disable')]
    [switch]$KeepNewerVersions
)

$ErrorActionPreference = 'Stop'
$moduleName = 'AzLocal.UpdateManagement'

$effectivePlatform = $Platform
if ($effectivePlatform -eq 'Auto') {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $githubWorkflowsPath = Join-Path -Path $repoRoot -ChildPath '.github\workflows'
    $effectivePlatform = if (Test-Path -LiteralPath $githubWorkflowsPath -PathType Container) { 'GitHub' } else { 'AzureDevOps' }
    Write-Host "Detected pipeline platform: $effectivePlatform" -ForegroundColor Cyan
}

$versionText = $null
if (-not $Disable) {
    $versionText = $RequiredVersion.ToString()
    if (-not $SkipGalleryValidation) {
        try {
            $candidate = Find-Module -Name $moduleName -RequiredVersion $versionText -Repository PSGallery -ErrorAction Stop
        }
        catch {
            throw "PowerShell Gallery cannot resolve $moduleName $versionText by exact version. Wait for Gallery propagation or verify the version before retrying. $($_.Exception.Message)"
        }
        if ([version]$candidate.Version -ne $RequiredVersion) {
            throw "PowerShell Gallery returned $($candidate.Version), not requested version $versionText."
        }
    }
}

if (-not $SkipPipelineRefresh) {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $updaterPath = Join-Path -Path $repoRoot -ChildPath 'Update-Module-And-Pipelines.ps1'
    if (-not (Test-Path -LiteralPath $updaterPath -PathType Leaf)) {
        throw "Required sibling updater not found at '$updaterPath'. Re-run Copy-AzLocalPipelineExample or Update-AzLocalPipelineExample, or use -SkipPipelineRefresh only if the repository is already prepared."
    }

    $updaterParameters = @{
        Scope = $Scope
    }
    if ($Disable) {
        $updaterParameters.LatestListed = $true
    }
    else {
        $updaterParameters.RequiredVersion = $RequiredVersion
    }
    if ($NoPush) {
        $updaterParameters.NoPush = $true
    }
    if ($AllowRollbackMarkerRemoval) {
        $updaterParameters.AllowRollbackMarkerRemoval = $true
    }
    if ($KeepNewerVersions) {
        $updaterParameters.KeepNewerVersions = $true
    }

    $refreshDescription = if ($Disable) {
        'restore the latest listed module and pipeline templates'
    }
    else {
        "install module $versionText and refresh its pipeline templates"
    }
    if ($PSCmdlet.ShouldProcess($updaterPath, $refreshDescription)) {
        & $updaterPath @updaterParameters
    }
}

if ($effectivePlatform -eq 'AzureDevOps') {
    Write-Host 'Azure DevOps variable-group action required.' -ForegroundColor Yellow
    Write-Host 'Replace <group-id> with the ID of the variable group linked to the AzLocal pipelines.'
    if ($Disable) {
        Write-Host 'Remove the candidate pin to restore latest-listed module resolution:'
        Write-Host "  az pipelines variable-group variable delete --group-id <group-id> --name $VariableName" -ForegroundColor Cyan
    }
    else {
        Write-Host "Create the candidate pin if $VariableName is absent:"
        Write-Host "  az pipelines variable-group variable create --group-id <group-id> --name $VariableName --value $versionText" -ForegroundColor Cyan
        Write-Host 'Or update the existing variable:'
        Write-Host "  az pipelines variable-group variable update --group-id <group-id> --name $VariableName --value $versionText" -ForegroundColor Cyan
    }
    return
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required. Install it and run gh auth login.'
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated. Run gh auth login and retry.'
}

if (-not $Repository) {
    $repoOutput = @(& gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>&1)
    if ($LASTEXITCODE -ne 0 -or -not $repoOutput) {
        throw "Could not infer the GitHub repository from the current directory. Pass -Repository owner/name. $($repoOutput -join ' ')"
    }
    $Repository = ([string]$repoOutput[-1]).Trim()
}

if ($Disable) {
    $existing = @(& gh variable list --repo $Repository --json name --jq ".[] | select(.name == `"$VariableName`") | .name" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not inspect repository variables for '$Repository'. $($existing -join ' ')"
    }

    if (-not (@($existing | Where-Object { ([string]$_).Trim() -eq $VariableName }).Count)) {
        Write-Host "$VariableName is already absent from $Repository. Latest-listed module resolution is active." -ForegroundColor Green
        return
    }

    if ($PSCmdlet.ShouldProcess($Repository, "delete GitHub Actions variable $VariableName")) {
        $deleteOutput = @(& gh variable delete $VariableName --repo $Repository 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Could not delete $VariableName from '$Repository'. $($deleteOutput -join ' ')"
        }
        Write-Host "Development channel disabled for $Repository. Pipelines will install the latest listed $moduleName version." -ForegroundColor Green
    }
    return
}

if ($PSCmdlet.ShouldProcess($Repository, "set GitHub Actions variable $VariableName=$versionText")) {
    $setOutput = @(& gh variable set $VariableName --repo $Repository --body $versionText 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set $VariableName in '$Repository'. $($setOutput -join ' ')"
    }
    Write-Host "Development channel enabled for ${Repository}: $VariableName=$versionText" -ForegroundColor Green
    Write-Host "All bundled pipelines now install the exact candidate with Install-Module -RequiredVersion."
}