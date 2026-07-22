########################################
<#
.SYNOPSIS
    Publishes AzLocal.UpdateManagement to the PowerShell Gallery.
.DESCRIPTION
    Copies an explicit allow-list of module content to a clean staging folder
    (C:\Temp\AzLocal.UpdateManagement), validates the manifest, then publishes
    via Publish-Module.

    The NuGet API key is prompted interactively and is never stored on disk.
.PARAMETER StageOnly
    Builds and validates the allow-listed staging package, then exits without
    prompting for an API key or publishing.
.NOTES
    Author  : Neil Bird, MSFT
    Version : 1.0
    Created : 2026-03-16
#>
########################################
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$StageOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths -------------------------------------------------------------------
$ModuleName  = 'AzLocal.UpdateManagement'
$SourceDir   = $PSScriptRoot                          # repo module folder
$StagingDir  = Join-Path 'C:\Temp' $ModuleName

# --- 1. Clean staging area ---------------------------------------------------
Write-Host "[$ModuleName] Cleaning staging folder: $StagingDir" -ForegroundColor Cyan
if (Test-Path $StagingDir) {
    Remove-Item $StagingDir -Recurse -Force
}

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
    'Automation-Pipeline-Examples'
    'ITSM'
    'docs\cmdlet-reference.md'
    'docs\concepts.md'
    'docs\images'
    'docs\rbac.md'
    'docs\release-history.md'
    'docs\troubleshooting.md'
    # Required at runtime by Register-AzLocalSideloadCopyTask.
    'Tools\Invoke-AzLocalSideloadCopyTask.ps1'
) | Select-Object -Unique)

Write-Host "[$ModuleName] Copying approved module content to staging..." -ForegroundColor Cyan
New-Item -Path $StagingDir -ItemType Directory -Force | Out-Null

foreach ($relativePath in $IncludePaths) {
    $sourcePath = Join-Path $SourceDir $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Required publish path is missing: $relativePath"
    }

    $destinationParent = Split-Path -Parent (Join-Path $StagingDir $relativePath)
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -Path $destinationParent -ItemType Directory -Force | Out-Null
    }

    Copy-Item -LiteralPath $sourcePath -Destination $destinationParent -Recurse -Force
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

if ($StageOnly) {
    Write-Host "[$ModuleName] Staging validation completed; publishing was not requested." -ForegroundColor Green
    return
}

# --- 6. Prompt for API key (masked) and publish ------------------------------
Write-Host ""
Write-Host "Paste your PowerShell Gallery NuGet API key (input is masked, nothing will echo):" -ForegroundColor Yellow
$secureApiKey = Read-Host -Prompt "API key" -AsSecureString
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

    if ($PSCmdlet.ShouldProcess("$ModuleName v$($manifest.Version)", 'Publish to PowerShell Gallery')) {
        Publish-Module -Path $StagingDir -Repository PSGallery -NuGetApiKey $apiKey -Verbose
        Write-Host ""
        Write-Host "[$ModuleName] Published successfully!" -ForegroundColor Green
        Write-Host "  https://www.powershellgallery.com/packages/$ModuleName/$($manifest.Version)" -ForegroundColor Gray
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
