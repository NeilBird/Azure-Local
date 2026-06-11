function Update-AzLocalSideloadCatalog {
    <#
    .SYNOPSIS
        Refreshes or scaffolds the sideload catalog YAML from the Microsoft Learn
        'import and discover updates offline' download table.

    .DESCRIPTION
        Operator-run helper for the v0.8.7 on-prem sideloading automation. Fetches
        the published Microsoft Learn page that lists the Azure Local
        CombinedSolutionBundle releases, parses each table row, and merges the
        discovered Microsoft 'Solution' packages into the catalog YAML for the
        operator to REVIEW and commit.

        Parsing contract (per table row):
          - The version anchor TEXT is the solution version (e.g. 12.2605.1003.210).
          - The version anchor HREF is the direct download URI.
          - The notes column carries the SHA256 (64 hex chars) and an
            'Availability date: YYYY-MM-DD' string.
          - The OS build column (e.g. 26100.4061) is captured when present.

        Rules:
          - Only 'Solution' (Microsoft) packages are touched. Existing 'SBE'
            (OEM) entries and any operator-authored fields are PRESERVED verbatim.
          - A discovered version that already exists as a Solution entry is
            updated in place (download URI / SHA256 / OS build / availability
            date); new versions are appended.
          - A discovered row with NO resolvable download URI is still written but
            FLAGGED (a warning is emitted and a '# TODO: fill downloadUri'
            comment is added) so the operator can complete it manually.
          - The runtime copy path never calls this function; it reads only the
            committed catalog.

        The catalog file is written WITHOUT a BOM. This function honours
        -WhatIf / -Confirm and does not overwrite the file under -WhatIf.

    .PARAMETER Path
        Path to the catalog YAML to create or update.

    .PARAMETER SourceUri
        The Microsoft Learn page URL to parse. Defaults to the documented
        'import and discover updates offline' article.

    .PARAMETER Html
        Optional raw HTML to parse instead of fetching SourceUri (used for
        offline / air-gapped refresh and for unit testing).

    .OUTPUTS
        [PSCustomObject[]] the merged package entries that were written.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceUri = 'https://learn.microsoft.com/en-us/azure/azure-local/manage/import-discover-updates-offline-23h2',

        [Parameter(Mandatory = $false)]
        [string]$Html
    )

    # ---- Acquire HTML --------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($Html)) {
        Write-Log -Message "Update-AzLocalSideloadCatalog: fetching catalog source '$SourceUri'." -Level Info
        try {
            $response = Invoke-WebRequest -Uri $SourceUri -UseBasicParsing -ErrorAction Stop
            $Html = [string]$response.Content
        }
        catch {
            throw "Failed to fetch sideload catalog source '$SourceUri': $($_.Exception.Message)"
        }
    }

    $discovered = Get-AzLocalSideloadCatalogRowFromHtml -Html $Html

    if ($discovered.Count -eq 0) {
        Write-Log -Message "Update-AzLocalSideloadCatalog: no solution-version rows were parsed from the source. The page layout may have changed; review the catalog manually." -Level Warning
    }

    # ---- Load existing catalog (preserve SBE + manual entries) ---------
    $existing = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existing = @(Get-AzLocalSideloadCatalog -Path $Path)
    }

    $merged = New-Object System.Collections.Generic.List[PSCustomObject]
    $solutionByVersion = @{}
    foreach ($entry in $existing) {
        $merged.Add($entry)
        if ($entry.PackageType -eq 'Solution') {
            $solutionByVersion[$entry.Version] = $entry
        }
    }

    foreach ($row in $discovered) {
        if ([string]::IsNullOrWhiteSpace($row.DownloadUri)) {
            Write-Log -Message "Update-AzLocalSideloadCatalog: discovered version '$($row.Version)' has no resolvable download URI - written with a TODO flag for manual completion." -Level Warning
        }
        if ($solutionByVersion.ContainsKey($row.Version)) {
            $target = $solutionByVersion[$row.Version]
            $target.BuildNumber = $row.BuildNumber
            $target.OsBuild = $row.OsBuild
            $target.DownloadUri = $row.DownloadUri
            $target.Sha256 = $row.Sha256
            $target.AvailabilityDate = $row.AvailabilityDate
        }
        else {
            $newEntry = [PSCustomObject]@{
                Version          = $row.Version
                PackageType      = 'Solution'
                BuildNumber      = $row.BuildNumber
                OsBuild          = $row.OsBuild
                DownloadUri      = $row.DownloadUri
                Sha256           = $row.Sha256
                AvailabilityDate = $row.AvailabilityDate
                LocalPath        = ''
                SourceFolder     = ''
                Notes            = ''
            }
            $merged.Add($newEntry)
            $solutionByVersion[$row.Version] = $newEntry
        }
    }

    $yaml = ConvertTo-AzLocalSideloadCatalogYaml -Packages $merged.ToArray() -SourceUri $SourceUri

    if ($PSCmdlet.ShouldProcess($Path, "Write sideload catalog with $($merged.Count) package(s)")) {
        $parent = Split-Path -Parent $Path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-Utf8NoBomFile -Path $Path -Content $yaml
        Write-Log -Message "Update-AzLocalSideloadCatalog: wrote $($merged.Count) package(s) to '$Path'. Review and commit." -Level Success
    }

    return $merged.ToArray()
}

function Get-AzLocalSideloadCatalogRowFromHtml {
    <#
    .SYNOPSIS
        Parses CombinedSolutionBundle rows out of the Microsoft Learn offline-update
        table HTML. Isolated so it can be unit-tested without a network call.
    .OUTPUTS
        [PSCustomObject[]] with Version, BuildNumber, OsBuild, DownloadUri,
        Sha256, AvailabilityDate.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Html
    )

    $rows = New-Object System.Collections.Generic.List[PSCustomObject]
    if ([string]::IsNullOrWhiteSpace($Html)) { return $rows.ToArray() }

    # Find every CombinedSolutionBundle download anchor. The href carries the
    # version + build inside the path/filename; the anchor text is the version.
    $anchorPattern = '(?is)<a\b[^>]*?href\s*=\s*"(?<href>[^"]*CombinedSolutionBundle[^"]*\.zip)"[^>]*>(?<text>.*?)</a>'
    $anchorMatches = [regex]::Matches($Html, $anchorPattern)

    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $anchorMatches) {
        $href = $m.Groups['href'].Value.Trim()
        $text = ([regex]::Replace($m.Groups['text'].Value, '<[^>]+>', '')).Trim()

        # Prefer an explicit version in the anchor text; otherwise derive it
        # from the filename CombinedSolutionBundle.<version>.zip.
        $version = $null
        if ($text -match '\d+\.\d+\.\d+\.\d+') { $version = $Matches[0] }
        elseif ($href -match 'CombinedSolutionBundle\.(?<v>\d+\.\d+\.\d+\.\d+)\.zip') { $version = $Matches['v'] }
        if (-not $version) { continue }
        if (-not $seen.Add($version)) { continue }

        # Look at a window of HTML following the anchor for the SHA256, the
        # availability date, and the OS build that accompany this row.
        $tail = $Html.Substring($m.Index, [Math]::Min(2000, $Html.Length - $m.Index))
        $sha256 = if ($tail -match '\b([0-9A-Fa-f]{64})\b') { $Matches[1].ToUpperInvariant() } else { '' }
        $availabilityDate = if ($tail -match '(?i)Availability date[^0-9]*([0-9]{4}-[0-9]{2}-[0-9]{2})') { $Matches[1] } else { '' }
        $osBuild = if ($tail -match '\b(26\d{3}\.\d+)\b') { $Matches[1] } else { '' }

        $rows.Add([PSCustomObject]@{
            Version          = $version
            BuildNumber      = $version
            OsBuild          = $osBuild
            DownloadUri      = $href
            Sha256           = $sha256
            AvailabilityDate = $availabilityDate
        })
    }

    return $rows.ToArray()
}

function ConvertTo-AzLocalSideloadCatalogYaml {
    <#
    .SYNOPSIS
        Serialises sideload catalog package entries to the narrow YAML shape
        consumed by Get-AzLocalSideloadCatalog.
    .OUTPUTS
        [string] the YAML document.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$Packages,

        [Parameter(Mandatory = $false)]
        [string]$SourceUri = ''
    )

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('# Sideload catalog - generated/refreshed by Update-AzLocalSideloadCatalog.')
    [void]$sb.AppendLine('# Review and commit. SBE (OEM) entries are operator-maintained and preserved.')
    if (-not [string]::IsNullOrWhiteSpace($SourceUri)) {
        [void]$sb.AppendLine(('# Source: {0}' -f $SourceUri))
    }
    [void]$sb.AppendLine('schemaVersion: 1')
    [void]$sb.AppendLine('packages:')

    foreach ($pkg in $Packages) {
        $packageType = if ($pkg.PackageType) { $pkg.PackageType } else { 'Solution' }
        [void]$sb.AppendLine(("  - version: '{0}'" -f $pkg.Version))
        [void]$sb.AppendLine(("    packageType: {0}" -f $packageType))
        if ($pkg.BuildNumber) { [void]$sb.AppendLine(("    buildNumber: '{0}'" -f $pkg.BuildNumber)) }
        if ($pkg.OsBuild) { [void]$sb.AppendLine(("    osBuild: '{0}'" -f $pkg.OsBuild)) }
        if ($packageType -eq 'Solution') {
            if ([string]::IsNullOrWhiteSpace([string]$pkg.DownloadUri)) {
                [void]$sb.AppendLine("    # TODO: fill downloadUri - not resolved automatically")
                [void]$sb.AppendLine("    downloadUri: ''")
            }
            else {
                [void]$sb.AppendLine(("    downloadUri: '{0}'" -f $pkg.DownloadUri))
            }
            if ($pkg.LocalPath) { [void]$sb.AppendLine(("    localPath: '{0}'" -f $pkg.LocalPath)) }
        }
        else {
            [void]$sb.AppendLine(("    sourceFolder: '{0}'" -f $pkg.SourceFolder))
        }
        [void]$sb.AppendLine(("    sha256: '{0}'" -f $pkg.Sha256))
        if ($pkg.AvailabilityDate) { [void]$sb.AppendLine(("    availabilityDate: '{0}'" -f $pkg.AvailabilityDate)) }
        if ($pkg.Notes) { [void]$sb.AppendLine(("    notes: '{0}'" -f $pkg.Notes)) }
    }

    return $sb.ToString()
}
