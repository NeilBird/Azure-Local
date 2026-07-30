#Requires -Version 5.1
<#
.SYNOPSIS
    Pins a GitHub repository's AzLocal pipelines to an exact module version.
.DESCRIPTION
    Creates or updates the non-secret GitHub Actions repository variable
    REQUIRED_MODULE_VERSION by using the authenticated GitHub CLI. This lets
    every bundled pipeline install an unlisted PowerShell Gallery candidate
    through Install-Module -RequiredVersion.

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
    with the current directory.
.PARAMETER VariableName
    Repository variable to manage. Defaults to REQUIRED_MODULE_VERSION.
.PARAMETER SkipGalleryValidation
    Skips the exact-version PowerShell Gallery lookup. Intended only for
    diagnosing Gallery propagation delays.
.EXAMPLE
    .\Apply-ModuleDevelopmentChannel.ps1 -RequiredVersion 0.9.29 -Repository contoso/azure-local-operations

    Validate v0.9.29 and pin every bundled GitHub pipeline in the target repo.
.EXAMPLE
    .\Apply-ModuleDevelopmentChannel.ps1 -Disable -Repository contoso/azure-local-operations

    Remove the development-channel pin after the candidate is listed.
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
    [ValidatePattern('^[A-Z][A-Z0-9_]{0,99}$')]
    [string]$VariableName = 'REQUIRED_MODULE_VERSION',

    [Parameter(ParameterSetName = 'Enable')]
    [switch]$SkipGalleryValidation
)

$ErrorActionPreference = 'Stop'
$moduleName = 'AzLocal.UpdateManagement'

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

if ($PSCmdlet.ShouldProcess($Repository, "set GitHub Actions variable $VariableName=$versionText")) {
    $setOutput = @(& gh variable set $VariableName --repo $Repository --body $versionText 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set $VariableName in '$Repository'. $($setOutput -join ' ')"
    }
    Write-Host "Development channel enabled for ${Repository}: $VariableName=$versionText" -ForegroundColor Green
    Write-Host "All bundled pipelines now install the exact candidate with Install-Module -RequiredVersion."
}