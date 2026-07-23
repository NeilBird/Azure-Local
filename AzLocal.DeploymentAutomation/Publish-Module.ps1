########################################
<#
.SYNOPSIS
    Publishes AzLocal.DeploymentAutomation to the PowerShell Gallery.
.DESCRIPTION
    Copies an explicit allowlist of module files to a clean per-user staging
    folder (under the current user's TEMP), scans the staged package for
    secrets, validates the manifest, then publishes via Publish-Module.

    Module code is included from the manifest's RootModule and NestedModules
    lists. Runtime assets and examples are listed explicitly below. Files not
    included by those lists cannot enter the published package.

    The NuGet API key is prompted interactively and is never stored on disk.
.NOTES
    Author  : Neil Bird, MSFT
    Version : 1.0
    Created : 2026-03-16
#>
########################################
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Paths
$ModuleName  = 'AzLocal.DeploymentAutomation'
$SourceDir   = $PSScriptRoot                          # repo module folder
# Stage under the current user's TEMP (ACL-scoped to this user) rather than the
# predictable, often world-writable C:\Temp, so the transient staged copy cannot
# be read or tampered with by other local users during publish.
$StagingDir  = Join-Path ([System.IO.Path]::GetTempPath()) $ModuleName

# 1. Clean staging area
# NOTE: Staging refresh deliberately bypasses -WhatIf via -WhatIf:$false so that
# Test-ModuleManifest in step 5 always validates the CURRENT source. Without this,
# a -WhatIf dry-run would skip Remove-Item/Copy-Item and validate a STALE staging
# copy from a previous publish, hiding version mismatches.
Write-Host "[$ModuleName] Cleaning staging folder: $StagingDir" -ForegroundColor Cyan
if (Test-Path $StagingDir) {
    Remove-Item $StagingDir -Recurse -Force -WhatIf:$false
}

# 2. Build and copy the package allowlist
$sourceManifestPath = Join-Path $SourceDir "$ModuleName.psd1"
$sourceManifest = Import-PowerShellDataFile -Path $sourceManifestPath

$packageFiles = New-Object 'System.Collections.Generic.List[string]'
[void]$packageFiles.Add("$ModuleName.psd1")
[void]$packageFiles.Add([string]$sourceManifest.RootModule)
foreach ($nestedModule in @($sourceManifest.NestedModules)) {
    [void]$packageFiles.Add([string]$nestedModule)
}

$packageAssets = @(
    'README.md'
    '.config\naming-standards-config.json'
    'templates\azure-local-deployment-template.json'
    'templates\azure-local-deployment-template-san.json'
    'template-parameter-files\single-node-parameters-file.json'
    'template-parameter-files\storage-switched-parameters-file.json'
    'template-parameter-files\storage-switchless-2node-parameters-file.json'
    'template-parameter-files\storage-switchless-3node-parameters-file.json'
    'template-parameter-files\storage-switchless-4node-parameters-file.json'
    'template-parameter-files\rack-aware-parameters-file.json'
    'template-parameter-files\disaggregated-parameters-file.json'
    'automation-pipelines\README.md'
    'automation-pipelines\cluster-deployments.csv'
    'automation-pipelines\azure-devops\deploy-clusters.yml'
    'automation-pipelines\azure-devops\validate-deployments.yml'
    'automation-pipelines\azure-devops\deployment-status-report.yml'
    'automation-pipelines\azure-devops\deployment-monitor.yml'
    'automation-pipelines\github-actions\deploy-clusters.yml'
    'automation-pipelines\github-actions\validate-deployments.yml'
    'automation-pipelines\github-actions\deployment-status-report.yml'
    'automation-pipelines\github-actions\deployment-monitor.yml'
)
foreach ($packageAsset in $packageAssets) {
    [void]$packageFiles.Add($packageAsset)
}

$duplicatePackageFiles = @($packageFiles | Group-Object | Where-Object Count -gt 1)
if ($duplicatePackageFiles.Count -gt 0) {
    throw "Package allowlist contains duplicate entries: $($duplicatePackageFiles.Name -join ', ')"
}

Write-Host "[$ModuleName] Copying explicitly included files to staging..." -ForegroundColor Cyan
New-Item -Path $StagingDir -ItemType Directory -Force -WhatIf:$false | Out-Null
foreach ($relativePath in $packageFiles) {
    $sourcePath = Join-Path $SourceDir $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Required package file is missing: $relativePath"
    }

    $destinationPath = Join-Path $StagingDir $relativePath
    $destinationDirectory = Split-Path -Path $destinationPath -Parent
    if (-not (Test-Path -LiteralPath $destinationDirectory)) {
        New-Item -Path $destinationDirectory -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
    Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -WhatIf:$false
}

$stagedRelativePaths = @(Get-ChildItem $StagingDir -Recurse -File | ForEach-Object {
    $_.FullName.Substring($StagingDir.Length + 1)
})
$unexpectedStagedFiles = @($stagedRelativePaths | Where-Object { $_ -notin $packageFiles })
if ($unexpectedStagedFiles.Count -gt 0) {
    throw "Staged package contains files outside the allowlist: $($unexpectedStagedFiles -join ', ')"
}

# 3. Show what will be published
Write-Host ""
Write-Host "[$ModuleName] Files to be published:" -ForegroundColor Yellow
Get-ChildItem $StagingDir -Recurse -File | ForEach-Object {
    Write-Host "  $($_.FullName.Replace($StagingDir + '\', ''))" -ForegroundColor Gray
}
Write-Host ""

# 4. Pre-publish secret-leak guard
# Defense-in-depth: even explicitly included files are scanned for content that
# must never reach a public gallery (real
# subscription/tenant/object GUIDs, private keys, storage keys). Known-legitimate
# values - synthetic placeholders, this module's manifest GUID, and Azure built-in
# role-definition GUIDs - are skipped below so the shipped examples do not trip it.
Write-Host "[$ModuleName] Scanning staged files for secrets..." -ForegroundColor Cyan

$secretPatterns = [ordered]@{
    'Real subscription/tenant/object GUID' = '(?<![0-9a-fA-F])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![0-9a-fA-F])'
    'Private key block'                    = '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'
    'Storage account key'                  = 'AccountKey=[A-Za-z0-9+/=]{20,}'
}

# GUIDs that are legitimate, public, fixed identifiers - never secrets:
#   * obviously-synthetic placeholders where every dash-group is a single repeated
#     character (e.g. 00000000-0000-0000-0000-000000000000, or the sample
#     aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee subscription ID), and
#   * this module's own manifest GUID (read dynamically below).
# Azure built-in role-definition GUIDs in the ARM templates are skipped separately
# via the 'roleDefinition' context check, so new role assignments never trip this.
$placeholderGuidPattern = '^(.)\1{7}-(.)\2{3}-(.)\3{3}-(.)\4{3}-(.)\5{11}$'
$manifestGuid = ''
try { $manifestGuid = [string](Import-PowerShellDataFile -Path (Join-Path $StagingDir "$ModuleName.psd1")).Guid } catch { }
$secretAllowList = @()
if (-not [string]::IsNullOrWhiteSpace($manifestGuid)) { $secretAllowList += $manifestGuid }

$secretHits = New-Object System.Collections.Generic.List[string]
Get-ChildItem $StagingDir -Recurse -File | ForEach-Object {
    $stagedFile = $_
    $content = Get-Content -LiteralPath $stagedFile.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrEmpty($content)) { return }
    foreach ($label in $secretPatterns.Keys) {
        foreach ($match in [regex]::Matches($content, $secretPatterns[$label])) {
            if ($secretAllowList -contains $match.Value) { continue }
            # Skip obviously-synthetic placeholder GUIDs (repeated char per segment).
            if ($match.Value -match $placeholderGuidPattern) { continue }
            # Skip Azure built-in role-definition GUIDs (public, tenant-invariant).
            $windowStart = [Math]::Max(0, $match.Index - 60)
            $preceding = $content.Substring($windowStart, $match.Index - $windowStart)
            if ($preceding -match 'roleDefinition') { continue }
            $relPath = $stagedFile.FullName.Replace($StagingDir + '\', '')
            $secretHits.Add(('  {0}: {1} -> ''{2}''' -f $relPath, $label, $match.Value))
        }
    }
}

if ($secretHits.Count -gt 0) {
    Write-Host ''
    Write-Host "[$ModuleName] SECRET SCAN FAILED - the following look like real secrets:" -ForegroundColor Red
    $secretHits | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw 'Refusing to publish: staged package contains values that look like real secrets. Replace them with placeholders or remove the file from the package allowlist, then retry.'
}

# Belt-and-braces: the shipped naming config MUST remain placeholder-only so a
# locally customised .config never ships real tenant/object IDs.
$stagedConfig = Join-Path $StagingDir '.config\naming-standards-config.json'
if (Test-Path $stagedConfig) {
    $cfg = Get-Content -LiteralPath $stagedConfig -Raw | ConvertFrom-Json
    $envTenant = if ($cfg.environment.PSObject.Properties['tenantId']) { [string]$cfg.environment.tenantId } else { '' }
    $envObjId  = if ($cfg.environment.PSObject.Properties['hciResourceProviderObjectID']) { [string]$cfg.environment.hciResourceProviderObjectID } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($envTenant) -and $envTenant -notmatch '^[xX-]+$') {
        throw "Refusing to publish: .config/naming-standards-config.json environment.tenantId is not a placeholder ('$envTenant'). Reset it before publishing."
    }
    if (-not [string]::IsNullOrWhiteSpace($envObjId)) {
        throw "Refusing to publish: .config/naming-standards-config.json environment.hciResourceProviderObjectID is populated ('$envObjId'). Reset it before publishing."
    }
}

Write-Host '  No secrets detected in staged package.' -ForegroundColor Green

# 5. Validate manifest
Write-Host "[$ModuleName] Validating module manifest..." -ForegroundColor Cyan
$manifestPath = Join-Path $StagingDir "$ModuleName.psd1"
$manifest = Test-ModuleManifest -Path $manifestPath -ErrorAction Stop
Write-Host "  Module:  $($manifest.Name)" -ForegroundColor Green
Write-Host "  Version: $($manifest.Version)" -ForegroundColor Green

# 6. Prompt for API key (masked) and publish
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
