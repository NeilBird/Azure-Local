function Get-AzLocalSideloadCatalog {
    <#
    .SYNOPSIS
        Parses the source-controlled sideload catalog YAML into package entries
        describing the Azure Local solution-update media (and OEM SBE packages)
        available to the on-prem sideloading automation.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation feature.
        Zero external YAML dependency - parses only the narrow shape below.

        Two package classes are supported (PackageType):

          - Solution : a Microsoft CombinedSolutionBundle.<build>.zip that is
            downloadable from a direct DownloadUri (published in the Microsoft
            Learn 'import and discover updates offline' table). Sha256 is
            REQUIRED so the download / pre-staged copy can be verified.

          - SBE : an OEM Solution Builder Extension package that Microsoft does
            NOT host. The operator stages the OEM files manually and records a
            SourceFolder (local or UNC path). DownloadUri is not applicable;
            Sha256 is optional (verified only when supplied).

        Expected YAML shape (2-space indentation):

          schemaVersion: 1
          packages:
            - version: '12.2605.1003.210'
              packageType: Solution
              buildNumber: '12.2605.1003.210'
              osBuild: '26100.4061'
              downloadUri: 'https://.../CombinedSolutionBundle.12.2605.1003.210.zip'
              sha256: 'ABCD...'
              availabilityDate: '2026-05-13'
              localPath: ''
            - version: 'DellSBE-4.1.2412.1'
              packageType: SBE
              sourceFolder: '\\fileserver\sbe\Dell\4.1.2412.1'
              sha256: ''
              availabilityDate: '2026-05-20'
              notes: 'Dell OEM SBE package, staged manually'

        Validation:
          - At least the 'version' key is required per package; duplicates are a
            hard error.
          - packageType defaults to 'Solution' when omitted; must be
            Solution or SBE (case-insensitive).
          - Solution entries require a non-empty DownloadUri OR LocalPath, plus a
            Sha256 matching ^[0-9A-Fa-f]{64}$.
          - SBE entries require a non-empty SourceFolder. Sha256, when present,
            must match ^[0-9A-Fa-f]{64}$.

        Returns an array of [PSCustomObject] package entries (empty array when
        the catalog has no packages).

    .PARAMETER Path
        Path to the catalog YAML file.

    .OUTPUTS
        [PSCustomObject[]] one entry per package.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Sideload catalog YAML not found at '$Path'. Set SIDELOAD_CATALOG_PATH (or pass -Path) to a catalog file. Generate / refresh one with Update-AzLocalSideloadCatalog."
    }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    $packages = New-Object System.Collections.Generic.List[PSCustomObject]
    $seenVersions = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    $inPackages = $false
    $current = $null
    $lineNo = 0

    # Strips one matching pair of surrounding quotes and a trailing inline
    # comment. Bare values are returned trimmed.
    $parseScalar = {
        param([string]$raw)
        $v = $raw.Trim()
        if ($v.Length -ge 2) {
            $first = $v[0]; $last = $v[$v.Length - 1]
            if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
                return $v.Substring(1, $v.Length - 2)
            }
        }
        # Strip trailing ' # comment' only on unquoted scalars.
        $hashIndex = $v.IndexOf(' #')
        if ($hashIndex -ge 0) { $v = $v.Substring(0, $hashIndex).Trim() }
        return $v
    }

    $commit = {
        param($entry)
        if ($null -eq $entry) { return }
        $version = ([string]$entry['version']).Trim()
        if ([string]::IsNullOrWhiteSpace($version)) {
            throw "Sideload catalog '$Path' has a package entry with no 'version'."
        }
        if (-not $seenVersions.Add($version)) {
            throw "Sideload catalog '$Path' contains a DUPLICATE package version '$version'. Each version must be unique."
        }

        $packageType = ([string]$entry['packageType']).Trim()
        if ([string]::IsNullOrWhiteSpace($packageType)) { $packageType = 'Solution' }
        if ($packageType -notmatch '^(?i:Solution|SBE)$') {
            throw "Sideload catalog '$Path' package '$version' has an invalid packageType '$packageType'. Must be 'Solution' or 'SBE'."
        }
        $packageType = if ($packageType -match '^(?i:SBE)$') { 'SBE' } else { 'Solution' }

        $downloadUri = ([string]$entry['downloadUri']).Trim()
        $localPath = ([string]$entry['localPath']).Trim()
        $sourceFolder = ([string]$entry['sourceFolder']).Trim()
        $sha256 = ([string]$entry['sha256']).Trim()

        if ($packageType -eq 'Solution') {
            if ([string]::IsNullOrWhiteSpace($downloadUri) -and [string]::IsNullOrWhiteSpace($localPath)) {
                throw "Sideload catalog '$Path' Solution package '$version' must have a non-empty downloadUri or localPath."
            }
            if ($sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
                throw "Sideload catalog '$Path' Solution package '$version' must have a valid SHA256 (64 hex chars). Got: '$sha256'."
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($sourceFolder)) {
                throw "Sideload catalog '$Path' SBE package '$version' must have a non-empty sourceFolder (the operator-staged OEM content path)."
            }
            if (-not [string]::IsNullOrWhiteSpace($sha256) -and $sha256 -notmatch '^[0-9A-Fa-f]{64}$') {
                throw "Sideload catalog '$Path' SBE package '$version' has an invalid SHA256 (must be 64 hex chars or empty). Got: '$sha256'."
            }
        }

        $packages.Add([PSCustomObject]@{
            Version          = $version
            PackageType      = $packageType
            BuildNumber      = ([string]$entry['buildNumber']).Trim()
            OsBuild          = ([string]$entry['osBuild']).Trim()
            DownloadUri      = $downloadUri
            Sha256           = $sha256
            AvailabilityDate = ([string]$entry['availabilityDate']).Trim()
            LocalPath        = $localPath
            SourceFolder     = $sourceFolder
            Notes            = ([string]$entry['notes']).Trim()
        })
    }

    foreach ($rawLine in $lines) {
        $lineNo++
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) { continue }

        if (-not $inPackages) {
            if ($trimmed -match '^packages:\s*$') {
                $inPackages = $true
            }
            # Top-level scalars (schemaVersion etc.) are ignored - only the
            # packages list is consumed.
            continue
        }

        if ($trimmed -match '^-\s*(.*)$') {
            # New list item - commit the previous entry first.
            & $commit $current
            $current = @{}
            $rest = $Matches[1].Trim()
            if (-not [string]::IsNullOrWhiteSpace($rest)) {
                if ($rest -match '^([A-Za-z0-9_]+):\s*(.*)$') {
                    $current[$Matches[1]] = (& $parseScalar $Matches[2])
                }
            }
            continue
        }

        if ($trimmed -match '^([A-Za-z0-9_]+):\s*(.*)$') {
            if ($null -eq $current) {
                throw "Sideload catalog '$Path' line $lineNo has a key outside a package list item: '$trimmed'."
            }
            $current[$Matches[1]] = (& $parseScalar $Matches[2])
            continue
        }
    }
    & $commit $current

    return $packages.ToArray()
}
