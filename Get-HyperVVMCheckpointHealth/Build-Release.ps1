#Requires -Version 5.1

<########################################
.SYNOPSIS
    Builds the versioned Get-HyperVVMCheckpointHealth release ZIP.
.DESCRIPTION
    Validates version consistency, stages only the runtime module files and README, verifies the
    staged manifest, and creates a ZIP with one top-level Get-HyperVVMCheckpointHealth folder.
.PARAMETER OutputPath
    Destination folder for generated release ZIP and SHA256 checksum files. Defaults to .\release.
.PARAMETER Force
    Replaces an existing ZIP and checksum for the same version.
.OUTPUTS
    A PSCustomObject describing the generated release assets.
#########################################>
[CmdletBinding(SupportsShouldProcess = $true)]
[OutputType([pscustomobject])]
param(
    [string]$OutputPath,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot 'release'
}

$moduleName = 'Get-HyperVVMCheckpointHealth'
$manifestPath = Join-Path $PSScriptRoot "$moduleName.psd1"
$modulePath = Join-Path $PSScriptRoot "$moduleName.psm1"
$licensePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'LICENSE'
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
$version = $manifest.Version.ToString()
$moduleSource = Get-Content -LiteralPath $modulePath -Raw
$moduleVersion = [regex]::Match($moduleSource, "(?m)^\`$script:ScriptVersion\s*=\s*'([^']+)'").Groups[1].Value

if (-not $moduleVersion -or $moduleVersion -ne $version) {
    throw "Version mismatch: manifest=$version; module=$moduleVersion."
}

$releaseFiles = @(
    "$moduleName.psd1",
    "$moduleName.psm1",
    'README.md',
    'Private\Get-HyperVVMCheckpointHealth.Assessment.psm1',
    'Private\Get-HyperVVMCheckpointHealth.Collection.psm1',
    'Private\Get-HyperVVMCheckpointHealth.Policy.psm1',
    'Private\Get-HyperVVMCheckpointHealth.Rendering.psm1',
    'Private\Get-HyperVVMCheckpointHealth.Storage.psm1',
    'checkpoint-health-policy.example.yml'
)
foreach ($relativePath in $releaseFiles) {
    $sourcePath = Join-Path $PSScriptRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required release file is missing: $sourcePath"
    }
}
if (-not (Test-Path -LiteralPath $licensePath -PathType Leaf)) {
    throw "Required release file is missing: $licensePath"
}

$outputRoot = [System.IO.Path]::GetFullPath($OutputPath)
$zipPath = Join-Path $outputRoot ("{0}-{1}.zip" -f $moduleName, $version)
$checksumPath = "$zipPath.sha256"
if ((Test-Path -LiteralPath $zipPath) -and -not $Force) {
    throw "Release ZIP already exists: $zipPath. Use -Force to replace it."
}

if (-not $PSCmdlet.ShouldProcess($zipPath, "Build $moduleName $version release bundle")) {
    return
}

if (-not (Test-Path -LiteralPath $outputRoot)) {
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
}

$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1}-{2}" -f $moduleName, $version, [guid]::NewGuid().ToString('N'))
$stageModuleRoot = Join-Path $stageRoot $moduleName
try {
    New-Item -ItemType Directory -Path $stageModuleRoot -Force | Out-Null
    foreach ($relativePath in $releaseFiles) {
        $sourcePath = Join-Path $PSScriptRoot $relativePath
        $destinationPath = Join-Path $stageModuleRoot $relativePath
        $destinationParent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }
    Copy-Item -LiteralPath $licensePath -Destination (Join-Path $stageModuleRoot 'LICENSE') -Force

    $stagedManifestPath = Join-Path $stageModuleRoot "$moduleName.psd1"
    $stagedManifest = Test-ModuleManifest -Path $stagedManifestPath -ErrorAction Stop
    if ($stagedManifest.Version.ToString() -ne $version) {
        throw 'Staged manifest version changed unexpectedly.'
    }

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    if (Test-Path -LiteralPath $checksumPath) { Remove-Item -LiteralPath $checksumPath -Force }
    Compress-Archive -LiteralPath $stageModuleRoot -DestinationPath $zipPath -CompressionLevel Optimal -Force

    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText($checksumPath, "$hash  $([System.IO.Path]::GetFileName($zipPath))`r`n", (New-Object System.Text.UTF8Encoding($false)))

    [pscustomobject]@{
        ModuleName = $moduleName
        Version = $version
        ZipPath = $zipPath
        ChecksumPath = $checksumPath
        SHA256 = $hash
        Files = @($releaseFiles) + @('LICENSE')
    }
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
