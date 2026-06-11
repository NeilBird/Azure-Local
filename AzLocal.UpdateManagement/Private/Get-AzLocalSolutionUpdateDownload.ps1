function Get-AzLocalSolutionUpdateDownload {
    <#
    .SYNOPSIS
        Resolves a sideload catalog entry to a verified, locally available media
        path - serving from a shared cache, downloading the Microsoft
        CombinedSolutionBundle when needed, or returning the operator-staged OEM
        SBE source folder.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation.

        For a 'Solution' catalog entry:
          1. If LocalPath is set and exists, it is the pre-staged bundle - the
             SHA256 is still verified.
          2. Else, if the shared cache already holds the bundle and its
             Get-FileHash matches the catalog SHA256, it is served from cache.
          3. Else the bundle is downloaded from DownloadUri to a per-process temp
             file in the cache directory and atomically moved into place
             (concurrent-agent safe), then SHA256-verified.

        For an 'SBE' catalog entry: Microsoft does not host the package. The
        operator-staged SourceFolder is validated to exist; its SHA256 is
        verified only when the catalog supplies one (folder hashing is not
        attempted). No download occurs.

        Network + hashing calls are isolated in Invoke-AzLocalFileDownload and
        Get-AzLocalFileHashText so they can be mocked in unit tests.

    .PARAMETER CatalogEntry
        A catalog entry [PSCustomObject] from Get-AzLocalSideloadCatalog.

    .PARAMETER CacheRoot
        Directory used as the shared verified cache for downloaded Solution
        bundles. Created if missing.

    .OUTPUTS
        [PSCustomObject] with:
          Version       the catalog version
          PackageType   'Solution' | 'SBE'
          MediaPath     the verified bundle .zip (Solution) or staged folder (SBE)
          Sha256        the verified hash (when applicable)
          FromCache     [bool] served from the shared cache without downloading
          Downloaded    [bool] a download occurred this call
          Verified      [bool] a SHA256 comparison succeeded this call
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSCustomObject]$CatalogEntry,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CacheRoot
    )

    $version = [string]$CatalogEntry.Version
    $packageType = if ($CatalogEntry.PackageType) { [string]$CatalogEntry.PackageType } else { 'Solution' }

    # ---- SBE (operator-staged, no download) ----------------------------
    if ($packageType -eq 'SBE') {
        $sourceFolder = [string]$CatalogEntry.SourceFolder
        if ([string]::IsNullOrWhiteSpace($sourceFolder)) {
            throw "Sideload SBE package '$version' has no SourceFolder. Stage the OEM files and set SourceFolder in the catalog."
        }
        if (-not (Test-Path -LiteralPath $sourceFolder)) {
            throw "Sideload SBE package '$version' SourceFolder '$sourceFolder' does not exist or is not reachable from this runner/agent."
        }
        $verified = $false
        # Folder-level hashing is not performed; only a single-file SourceFolder
        # (pointing at a .zip) is hash-verified when a SHA256 is supplied.
        if (-not [string]::IsNullOrWhiteSpace([string]$CatalogEntry.Sha256) -and (Test-Path -LiteralPath $sourceFolder -PathType Leaf)) {
            $actual = Get-AzLocalFileHashText -Path $sourceFolder
            if (-not [string]::Equals($actual, [string]$CatalogEntry.Sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Sideload SBE package '$version' SHA256 mismatch. Expected $($CatalogEntry.Sha256), got $actual."
            }
            $verified = $true
        }
        return [PSCustomObject]@{
            Version     = $version
            PackageType = 'SBE'
            MediaPath   = $sourceFolder
            Sha256      = [string]$CatalogEntry.Sha256
            FromCache   = $false
            Downloaded  = $false
            Verified    = $verified
        }
    }

    # ---- Solution (cache / pre-staged / download) ----------------------
    $expectedSha = [string]$CatalogEntry.Sha256
    if ([string]::IsNullOrWhiteSpace($expectedSha)) {
        throw "Sideload Solution package '$version' has no SHA256 in the catalog; refusing to stage unverifiable media."
    }

    # 1. Pre-staged LocalPath.
    $localPath = [string]$CatalogEntry.LocalPath
    if (-not [string]::IsNullOrWhiteSpace($localPath) -and (Test-Path -LiteralPath $localPath -PathType Leaf)) {
        $actual = Get-AzLocalFileHashText -Path $localPath
        if (-not [string]::Equals($actual, $expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Sideload Solution package '$version' pre-staged LocalPath '$localPath' SHA256 mismatch. Expected $expectedSha, got $actual."
        }
        return [PSCustomObject]@{
            Version     = $version
            PackageType = 'Solution'
            MediaPath   = $localPath
            Sha256      = $expectedSha
            FromCache   = $false
            Downloaded  = $false
            Verified    = $true
        }
    }

    if (-not (Test-Path -LiteralPath $CacheRoot)) {
        New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
    }

    $fileName = "CombinedSolutionBundle.$version.zip"
    if ($CatalogEntry.BuildNumber) { $fileName = "CombinedSolutionBundle.$($CatalogEntry.BuildNumber).zip" }
    $cachePath = Join-Path -Path $CacheRoot -ChildPath $fileName

    # 2. Shared cache hit.
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        $actual = Get-AzLocalFileHashText -Path $cachePath
        if ([string]::Equals($actual, $expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                Version     = $version
                PackageType = 'Solution'
                MediaPath   = $cachePath
                Sha256      = $expectedSha
                FromCache   = $true
                Downloaded  = $false
                Verified    = $true
            }
        }
        Write-Log -Message "Sideload cache file '$cachePath' failed SHA256 verification (expected $expectedSha, got $actual); re-downloading." -Level Warning
    }

    # 3. Download. Write to a per-process temp file then atomically move into
    # place so concurrent runners/agents never read a partial file.
    $downloadUri = [string]$CatalogEntry.DownloadUri
    if ([string]::IsNullOrWhiteSpace($downloadUri)) {
        throw "Sideload Solution package '$version' has no DownloadUri and is not present (verified) in the cache or a pre-staged LocalPath."
    }
    $tempPath = Join-Path -Path $CacheRoot -ChildPath ("{0}.{1}.partial" -f $fileName, ([guid]::NewGuid().ToString('N')))
    try {
        Write-Log -Message "Downloading sideload bundle '$version' from '$downloadUri'." -Level Info
        Invoke-AzLocalFileDownload -Uri $downloadUri -OutFile $tempPath

        $actual = Get-AzLocalFileHashText -Path $tempPath
        if (-not [string]::Equals($actual, $expectedSha, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Sideload Solution package '$version' downloaded SHA256 mismatch. Expected $expectedSha, got $actual."
        }
        Move-Item -LiteralPath $tempPath -Destination $cachePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }

    return [PSCustomObject]@{
        Version     = $version
        PackageType = 'Solution'
        MediaPath   = $cachePath
        Sha256      = $expectedSha
        FromCache   = $false
        Downloaded  = $true
        Verified    = $true
    }
}

function Invoke-AzLocalFileDownload {
    <#
    .SYNOPSIS
        Thin wrapper around Invoke-WebRequest -OutFile, isolated for mocking.
    .OUTPUTS
        [void]
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
    catch {
        throw "Failed to download '$Uri': $($_.Exception.Message)"
    }
}

function Get-AzLocalFileHashText {
    <#
    .SYNOPSIS
        Thin wrapper around Get-FileHash (SHA256), isolated for mocking.
    .OUTPUTS
        [string] the uppercase SHA256 hex string.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop
    return ([string]$h.Hash).ToUpperInvariant()
}
