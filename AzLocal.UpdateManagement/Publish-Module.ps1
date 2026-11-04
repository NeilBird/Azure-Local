########################################
<#
.SYNOPSIS
    Publishes AzLocal.UpdateManagement to the PowerShell Gallery.
.DESCRIPTION
    Copies an explicit allow-list of module content to a clean staging folder
    (C:\Temp\AzLocal.UpdateManagement), validates the manifest, publishes via
    Publish-Module, then immediately unlists that exact version through the
    PowerShell Gallery NuGet API for staged release validation.

    All source files must be declared within this script's module directory.
    Unexpected bundled assets, unsafe paths, and linked paths stop packaging.
    Staged file names and SHA256 hashes must match the approved source files.

    The NuGet API key is supplied as a SecureString or prompted interactively
    and is never stored on disk by this script.
.PARAMETER StageOnly
    Builds and validates the allow-listed staging package, then exits without
    prompting for an API key or publishing.
.PARAMETER List
    Leaves the published version listed in PowerShell Gallery. By default, a
    successful publish is immediately unlisted so the exact version remains
    available for staged validation without becoming the default install.
.PARAMETER NuGetApiKey
    Optional SecureString supplied by a protected automation secret. When omitted,
    the script prompts interactively. Never pass a literal key in source control.
.EXAMPLE
    .\Publish-Module.ps1

    Publish the module, then immediately unlist that exact version for staged
    validation.
.EXAMPLE
    .\Publish-Module.ps1 -List

    Publish the module and leave it listed as the default Gallery release.
.EXAMPLE
    .\Publish-Module.ps1 -StageOnly

    Build and validate the package without publishing or requesting an API key.
.NOTES
    Author  : Neil Bird, MSFT
    Version : 1.3
    Created : 2026-03-16
    Updated : 2026-11-03
#>
########################################
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$StageOnly,

    [switch]$List,

    [System.Security.SecureString]$NuGetApiKey
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths -------------------------------------------------------------------
$ModuleName  = 'AzLocal.UpdateManagement'
$SourceDir   = $PSScriptRoot                          # repo module folder
$StagingDir  = Join-Path 'C:\Temp' $ModuleName

# --- 2. Copy approved module content to staging ------------------------------
# Every published path must be declared here. New repository files remain out
# of the package until a maintainer deliberately adds them to this allow-list.
$sourceManifestPath = Join-Path $SourceDir "$ModuleName.psd1"
$sourceManifest = Import-PowerShellDataFile -Path $sourceManifestPath

$IncludePaths = @(@(
    "$ModuleName.psd1"
    [string]$sourceManifest.RootModule
    @($sourceManifest.NestedModules)
    'README.md'
    'example-update-request.json'
    'Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml'
    'Automation-Pipeline-Examples/.itsm/templates/incident-body.md'
    'Automation-Pipeline-Examples/apply-module-development-channel.ps1'
    'Automation-Pipeline-Examples/apply-updates-schedule.example.yml'
    'Automation-Pipeline-Examples/azlocal-monitor-suppression-custom-role.json'
    'Automation-Pipeline-Examples/azlocal-update-management-custom-role.json'
    'Automation-Pipeline-Examples/azure-devops/apply-updates-schedule-audit.yml'
    'Automation-Pipeline-Examples/azure-devops/apply-updates.yml'
    'Automation-Pipeline-Examples/azure-devops/assess-update-readiness.yml'
    'Automation-Pipeline-Examples/azure-devops/fleet-connectivity-status.yml'
    'Automation-Pipeline-Examples/azure-devops/fleet-health-status.yml'
    'Automation-Pipeline-Examples/azure-devops/fleet-update-status.yml'
    'Automation-Pipeline-Examples/azure-devops/manage-updatering-tags.yml'
    'Automation-Pipeline-Examples/azure-devops/monitor-updates.yml'
    'Automation-Pipeline-Examples/azure-devops/setup-validate-and-inventory.yml'
    'Automation-Pipeline-Examples/azure-devops/sideload-updates.yml'
    'Automation-Pipeline-Examples/docs/appendix-github-environments.md'
    'Automation-Pipeline-Examples/docs/appendix-module-version-pinning.md'
    'Automation-Pipeline-Examples/docs/appendix-pipelines.md'
    'Automation-Pipeline-Examples/docs/appendix-resource-tags.md'
    'Automation-Pipeline-Examples/docs/appendix-release-history.md'
    'Automation-Pipeline-Examples/docs/apply-updates-schedule.md'
    'Automation-Pipeline-Examples/docs/development-channel-testing.md'
    'Automation-Pipeline-Examples/docs/monitor-notification-suppression.md'
    'Automation-Pipeline-Examples/docs/sideload-robocopy.md'
    'Automation-Pipeline-Examples/docs/sideload.md'
    'Automation-Pipeline-Examples/excluded-subscription-ids.example.csv'
    'Automation-Pipeline-Examples/fleet-settings.example.yml'
    'Automation-Pipeline-Examples/github-actions/apply-updates-schedule-audit.yml'
    'Automation-Pipeline-Examples/github-actions/apply-updates.yml'
    'Automation-Pipeline-Examples/github-actions/assess-update-readiness.yml'
    'Automation-Pipeline-Examples/github-actions/fleet-connectivity-status.yml'
    'Automation-Pipeline-Examples/github-actions/fleet-health-status.yml'
    'Automation-Pipeline-Examples/github-actions/fleet-update-status.yml'
    'Automation-Pipeline-Examples/github-actions/manage-updatering-tags.yml'
    'Automation-Pipeline-Examples/github-actions/monitor-updates.yml'
    'Automation-Pipeline-Examples/github-actions/setup-validate-and-inventory.yml'
    'Automation-Pipeline-Examples/github-actions/sideload-updates.yml'
    'Automation-Pipeline-Examples/README.md'
    'Automation-Pipeline-Examples/repo-readme-template.md'
    'Automation-Pipeline-Examples/sideload-auth-map.example.csv'
    'Automation-Pipeline-Examples/sideload-catalog.example.yml'
    'Automation-Pipeline-Examples/sideload-settings.example.yml'
    'Automation-Pipeline-Examples/update-module-and-pipelines.ps1'
    'ITSM/ITSM-Config-Reference.md'
    'ITSM/ITSM-Connector-Plan.md'
    'ITSM/README.md'
    'docs\cmdlet-reference.md'
    'docs\concepts.md'
    'docs/images/apply-updates-schedule-audit-part1.png'
    'docs/images/apply-updates-schedule-audit-part2.png'
    'docs/images/apply-updates-schedule-audit-part3.png'
    'docs/images/apply-updates-summary.png'
    'docs/images/apply-updates-update-readiness.png'
    'docs/images/auth-smoke-test-validate-oidc.png'
    'docs/images/fleet-health-status-part-2.png'
    'docs/images/fleet-health-status-part1.png'
    'docs/images/fleet-update-status.png'
    'docs/images/github-actions-10-pipelines-view.png'
    'docs/images/inventory-clusters-run-output.png'
    'docs/images/monitor-inflight-updates.png'
    'docs/images/README.md'
    'docs\rbac.md'
    'docs\release-history.md'
    'docs\troubleshooting.md'
    # Required at runtime by Register-AzLocalSideloadCopyTask.
    'Tools\Invoke-AzLocalSideloadCopyTask.ps1'
    'Tools\Export-AzLocalSideloadDiagnostics.ps1'
) | Select-Object -Unique)

$approvedPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$sourceHashes = @{}
foreach ($relativePath in $IncludePaths) {
    if ($relativePath -isnot [string] -or [string]::IsNullOrWhiteSpace($relativePath) -or
        [System.IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '[:*?\[\]]') {
        throw 'Publish paths must be literal module-relative file paths.'
    }
    $normalisedPath = $relativePath.Replace('\', '/')
    if (@($normalisedPath.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "Unsafe publish path: $relativePath"
    }
    if (-not $approvedPaths.Add($normalisedPath)) { throw "Duplicate publish path: $relativePath" }
    $sourcePath = Join-Path $SourceDir $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required publish file is missing or is not a file: $relativePath"
    }
    $entry = Get-Item -LiteralPath $sourcePath -Force
    while ($null -ne $entry) {
        if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Linked publish paths are not allowed: $relativePath"
        }
        if ($entry.FullName -eq $SourceDir) { break }
        if ($entry -is [System.IO.FileInfo]) { $entry = $entry.Directory }
        else { $entry = $entry.Parent }
    }
    $sourceHashes[$normalisedPath] = (Get-FileHash -LiteralPath (Join-Path $SourceDir $relativePath) -Algorithm SHA256).Hash
}

$directories = [System.Collections.Generic.Queue[string]]::new()
foreach ($assetRoot in @('Automation-Pipeline-Examples', 'ITSM', 'docs/images')) {
    $directories.Enqueue((Join-Path $SourceDir $assetRoot))
}
while ($directories.Count -gt 0) {
    foreach ($entry in Get-ChildItem -LiteralPath $directories.Dequeue() -Force) {
        $relativePath = $entry.FullName.Substring($SourceDir.Length + 1).Replace('\', '/')
        if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Linked publish assets are not allowed: $relativePath"
        }
        if ($entry.PSIsContainer) { $directories.Enqueue($entry.FullName) }
        elseif (-not $approvedPaths.Contains($relativePath)) { throw "Unexpected publish asset: $relativePath" }
    }
}

$stagingAncestor = [System.IO.Path]::GetFullPath($StagingDir)
while ($stagingAncestor) {
    if (Test-Path -LiteralPath $stagingAncestor) {
        if ((Get-Item -LiteralPath $stagingAncestor -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw 'Linked staging paths are not allowed.'
        }
    }
    $stagingAncestor = Split-Path -Path $stagingAncestor -Parent
}
if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess($StagingDir, 'Stage and publish module')
    return
}

Write-Host "[$ModuleName] Cleaning staging folder: $StagingDir" -ForegroundColor Cyan
if (Test-Path -LiteralPath $StagingDir) { Remove-Item -LiteralPath $StagingDir -Recurse -Force }
Write-Host "[$ModuleName] Copying approved module content to staging..." -ForegroundColor Cyan
New-Item -Path $StagingDir -ItemType Directory -Force | Out-Null
foreach ($relativePath in $IncludePaths) {
    $sourcePath = Join-Path $SourceDir $relativePath
    $destinationParent = Split-Path -Parent (Join-Path $StagingDir $relativePath)
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -Path $destinationParent -ItemType Directory -Force | Out-Null
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destinationParent -Force
    Write-Host "  Included: $relativePath" -ForegroundColor DarkGray
}

# --- 4. Show what will be published ------------------------------------------
Write-Host ""
Write-Host "[$ModuleName] Files to be published:" -ForegroundColor Yellow
Get-ChildItem $StagingDir -Recurse -File | ForEach-Object {
    Write-Host "  $($_.FullName.Replace($StagingDir + '\', ''))" -ForegroundColor Gray
}
Write-Host ""

# --- 5. Validate manifest ----------------------------------------------------
Write-Host "[$ModuleName] Validating module manifest..." -ForegroundColor Cyan
$manifestPath = Join-Path $StagingDir "$ModuleName.psd1"
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Write-Host "  Module:  $($manifest.Name)" -ForegroundColor Green
Write-Host "  Version: $($manifest.Version)" -ForegroundColor Green

$stagedFiles = @(Get-ChildItem -LiteralPath $StagingDir -Recurse -Force -File)
if ($stagedFiles.Count -ne $approvedPaths.Count) { throw 'Staged package file count does not match the allow-list.' }
foreach ($file in $stagedFiles) {
    $relativePath = $file.FullName.Substring($StagingDir.Length + 1).Replace('\', '/')
    if (-not $approvedPaths.Contains($relativePath) -or
        (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $sourceHashes[$relativePath]) {
        throw "Staged package does not match approved source: $relativePath"
    }
}

if ($StageOnly) {
    Write-Host "[$ModuleName] Staging validation completed; publishing was not requested." -ForegroundColor Green
    return
}

# --- 6. Confirm, prompt for API key, publish, and immediately unlist ---------
$publishAction = if ($List.IsPresent) {
    'Publish to PowerShell Gallery and leave listed'
}
else {
    'Publish to PowerShell Gallery and immediately unlist'
}

if (-not $PSCmdlet.ShouldProcess("$ModuleName v$($manifest.Version)", $publishAction)) {
    return
}

Write-Host ""
if ($PSBoundParameters.ContainsKey('NuGetApiKey')) {
    if ($null -eq $NuGetApiKey -or $NuGetApiKey.Length -eq 0) {
        throw 'API key cannot be empty. Publish cancelled.'
    }
    $secureApiKey = $NuGetApiKey.Copy()
}
else {
    Write-Host "Paste your PowerShell Gallery NuGet API key (input is masked, nothing will echo):" -ForegroundColor Yellow
    $secureApiKey = Read-Host -Prompt "API key" -AsSecureString
}
if ($null -eq $secureApiKey -or $secureApiKey.Length -eq 0) {
    throw 'API key cannot be empty. Publish cancelled.'
}

# Convert SecureString to plaintext only at the moment of use, then scrub it.
$bstr   = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureApiKey)
$apiKey = $null
try {
    $apiKey = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw 'API key cannot be empty. Publish cancelled.'
    }

    Write-Host ""
    Write-Host "[$ModuleName] Publishing v$($manifest.Version) to PSGallery..." -ForegroundColor Cyan

    Publish-Module -Path $StagingDir -Repository PSGallery -NuGetApiKey $apiKey -ErrorAction Stop
    Write-Host ""
    Write-Host "[$ModuleName] Published successfully!" -ForegroundColor Green
    Write-Host "  https://www.powershellgallery.com/packages/$ModuleName/$($manifest.Version)" -ForegroundColor Gray

    if ($List.IsPresent) {
        Write-Host "[$ModuleName] Version remains listed because -List was specified." -ForegroundColor Green
    }
    else {
        $escapedModuleName = [System.Uri]::EscapeDataString($ModuleName)
        $escapedVersion = [System.Uri]::EscapeDataString($manifest.Version.ToString())
        $unlistUri = "https://www.powershellgallery.com/api/v2/package/$escapedModuleName/$escapedVersion"

        Write-Host "[$ModuleName] Unlisting v$($manifest.Version) for staged validation..." -ForegroundColor Cyan
        try {
            Invoke-RestMethod -Uri $unlistUri -Method Delete -Headers @{ 'X-NuGet-ApiKey' = $apiKey } -ErrorAction Stop | Out-Null
        }
        catch {
            throw "Published $ModuleName v$($manifest.Version), but automatic unlisting failed. The package may still be listed; unlist it immediately in the PowerShell Gallery portal before continuing staged validation. $($_.Exception.Message)"
        }
        Write-Host "[$ModuleName] Unlisted successfully. Exact -RequiredVersion lookup remains available." -ForegroundColor Green
    }
}
finally {
    # Zero the unmanaged plaintext buffer and drop references so the key
    # is not left sitting in process memory after publish completes.
    if ($bstr -ne [IntPtr]::Zero) {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
    }
    $apiKey = $null
    if ($secureApiKey) { $secureApiKey.Dispose() }
    $secureApiKey = $null
    [System.GC]::Collect()
}
