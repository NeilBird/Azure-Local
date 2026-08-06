#Requires -Version 5.1

########################################
<#
.SYNOPSIS
    Verifies and installs the versioned Get-HyperVVMCheckpointHealth release ZIP.
.DESCRIPTION
    Verifies the pinned SHA256 hash for the supported release ZIP, stages and validates the module,
    replaces only the Get-HyperVVMCheckpointHealth directory under InstallRoot, imports the manifest,
    and verifies the exported command. It does not run an audit.
.PARAMETER ZipPath
    Path to the previously downloaded versioned release ZIP. When omitted, the script checks its
    own directory first and then the current user's temporary directory.
.PARAMETER InstallRoot
    Parent directory under which the Get-HyperVVMCheckpointHealth module folder is installed.
    Defaults to C:\Temp.
.OUTPUTS
    A PSCustomObject describing the verified installation.
#>
########################################
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
[OutputType([pscustomobject])]
param(
    [string]$ZipPath,

    [ValidateNotNullOrEmpty()]
    [string]$InstallRoot = 'C:\Temp'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$moduleName = 'Get-HyperVVMCheckpointHealth'
$version = '0.2.33'
$expectedSha256 = 'f1b7462c5730ac104ad5b34e778936557bad5bcae779cda3f258004ee42cb9a8'
$expectedAssetName = "$moduleName-$version.zip"

if (-not $ZipPath) {
    $scriptDirectoryZipPath = Join-Path $PSScriptRoot $expectedAssetName
    $tempDirectoryZipPath = Join-Path $env:TEMP $expectedAssetName
    if (Test-Path -LiteralPath $scriptDirectoryZipPath -PathType Leaf) {
        $ZipPath = $scriptDirectoryZipPath
    }
    elseif (Test-Path -LiteralPath $tempDirectoryZipPath -PathType Leaf) {
        $ZipPath = $tempDirectoryZipPath
    }
    else {
        throw "Release ZIP was not found beside the setup script ('$scriptDirectoryZipPath') or in the temporary directory ('$tempDirectoryZipPath')."
    }
}
if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw "Release ZIP was not found: $ZipPath"
}
if ([System.IO.Path]::GetFileName($ZipPath) -ne $expectedAssetName) {
    throw "Expected release asset '$expectedAssetName', but received '$([System.IO.Path]::GetFileName($ZipPath))'."
}

$actualSha256 = & {
    $WhatIfPreference = $false
    (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256 -ErrorAction Stop).Hash
}
if (-not $actualSha256.Equals($expectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Release ZIP SHA256 verification failed. Expected $expectedSha256; received $actualSha256. Delete the ZIP and download it again from the documented release."
}

$installRootPath = [System.IO.Path]::GetFullPath($InstallRoot)
$moduleRoot = Join-Path $installRootPath $moduleName
$stageRoot = Join-Path $installRootPath ('.{0}-stage-{1}' -f $moduleName, [guid]::NewGuid().ToString('N'))
$backupRoot = Join-Path $installRootPath ('.{0}-backup-{1}' -f $moduleName, [guid]::NewGuid().ToString('N'))
$backupCreated = $false
$installCompleted = $false

if (-not $PSCmdlet.ShouldProcess($moduleRoot, "Install verified $moduleName $version")) {
    return
}

try {
    if (-not (Test-Path -LiteralPath $installRootPath)) {
        New-Item -ItemType Directory -Path $installRootPath -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $stageRoot -Force

    $stagedModuleRoot = Join-Path $stageRoot $moduleName
    $stagedManifestPath = Join-Path $stagedModuleRoot "$moduleName.psd1"
    if (-not (Test-Path -LiteralPath $stagedManifestPath -PathType Leaf)) {
        throw "The verified ZIP does not contain the expected module manifest: $moduleName.psd1"
    }
    $stagedManifest = Test-ModuleManifest -Path $stagedManifestPath -ErrorAction Stop
    if ($stagedManifest.Version.ToString() -ne $version) {
        throw "The staged module version is $($stagedManifest.Version); expected $version."
    }

    if (Test-Path -LiteralPath $moduleRoot) {
        Move-Item -LiteralPath $moduleRoot -Destination $backupRoot
        $backupCreated = $true
    }
    Move-Item -LiteralPath $stagedModuleRoot -Destination $moduleRoot
    $installCompleted = $true

    Get-ChildItem -LiteralPath $moduleRoot -Recurse -File | Unblock-File
    $installedManifestPath = Join-Path $moduleRoot "$moduleName.psd1"
    Import-Module $installedManifestPath -Force -ErrorAction Stop
    $installedCommand = Get-Command $moduleName -CommandType Function -ErrorAction Stop
    if (-not $installedCommand.Module -or $installedCommand.Module.Version.ToString() -ne $version) {
        throw "The imported command did not report expected module version $version."
    }

    [pscustomobject]@{
        ModuleName = $moduleName
        Version = $version
        InstalledPath = $moduleRoot
        SHA256 = $actualSha256.ToLowerInvariant()
        Command = $installedCommand.Name
    }
}
catch {
    if ($installCompleted -and (Test-Path -LiteralPath $moduleRoot)) {
        Remove-Item -LiteralPath $moduleRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($backupCreated -and (Test-Path -LiteralPath $backupRoot)) {
        Move-Item -LiteralPath $backupRoot -Destination $moduleRoot -ErrorAction SilentlyContinue
        $backupCreated = $false
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($backupCreated -and (Test-Path -LiteralPath $backupRoot)) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
