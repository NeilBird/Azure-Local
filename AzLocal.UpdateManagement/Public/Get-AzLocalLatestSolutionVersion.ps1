function Get-AzLocalLatestSolutionVersion {
    <#
    .SYNOPSIS
        Queries the Microsoft Azure Edge Updates manifest to determine the latest released
        Azure Local solution version and the resulting "rolling N-month support window".

    .DESCRIPTION
        Azure Local solution-bundle versions follow the format <prefix>.YYMM.X.X (e.g.
        Solution12.2604.1003.1006). Microsoft publishes the catalog of currently-applicable
        solution bundles at the unauthenticated endpoint https://aka.ms/AzureEdgeUpdates (an
        XML manifest under the root element ASZSolutionBundleUpdates).

        This cmdlet downloads that manifest, parses the Version strings under both
        ApplicableUpdate/UpdateInfo and PackageMetadata/ServicesUpdates/Update/UpdateInfo,
        extracts the YYMM token (validated as YY=20-99 and MM=01-12), takes the highest
        YYMM as the anchor for the support window, and computes the supported YYMM list by
        stepping back month-by-month (calendar arithmetic, so 2601 -> 2512 -> 2511, etc.).

        The intent is to drive the SupportStatus column in the Step.6 Fleet Update Status
        pipeline: as soon as Microsoft publishes any release with a newer YYMM, the window
        slides forward and the oldest in-window YYMM falls out - even if no cluster in the
        fleet has installed the new release yet.

        Output is a single PSCustomObject. On any failure (network unreachable, non-2xx,
        malformed XML, no parseable YYMM tokens), the function throws a structured error;
        callers (typically the Step.6 pipeline YAML) are expected to wrap the call in
        try/catch and fall back to the legacy fleet-observed window.

    .PARAMETER ManifestUrl
        URL of the Azure Edge Updates manifest. Defaults to https://aka.ms/AzureEdgeUpdates
        (the official Microsoft-curated catalog). Override only for offline testing or
        air-gapped mirrors.

    .PARAMETER SupportWindowMonths
        Number of months in the rolling support window, inclusive of the latest YYMM.
        Defaults to 6 (i.e. LatestYYMM and the five preceding months). Must be between 1
        and 24.

    .PARAMETER TimeoutSeconds
        HTTP timeout in seconds for the manifest fetch. Defaults to 30.

    .OUTPUTS
        PSCustomObject with the following properties:
          - LatestYYMM           : string (e.g. '2604') - the highest YYMM in the manifest
          - LatestVersion        : string - the highest full version string at LatestYYMM
          - SupportedYYMMs       : string[] - the N most-recent YYMM strings, newest first
          - AllReleases          : PSCustomObject[] - UpdateName, Version, Yymm, Source (xpath)
          - ManifestUrl          : string - the URL fetched
          - ManifestFetchedAt    : DateTime - UTC timestamp of the successful fetch
          - SupportWindowMonths  : int - the requested window size
          - Source               : string - constant 'aka.ms/AzureEdgeUpdates'

    .EXAMPLE
        Get-AzLocalLatestSolutionVersion
        # Returns: LatestYYMM=2604, SupportedYYMMs=@('2604','2603','2602','2601','2512','2511'), ...

    .EXAMPLE
        # Manual SupportStatus classification for a cluster's CurrentVersion
        $manifest = Get-AzLocalLatestSolutionVersion
        $clusterYymm = ($cluster.CurrentVersion -split '\.')[1]
        if ($manifest.SupportedYYMMs -contains $clusterYymm) { 'Supported' } else { 'Unsupported' }

    .EXAMPLE
        # Used by Step.9_fleet-update-status pipeline (Step.8 before the v0.8.7 sideload renumber; Step.7 before v0.7.90);
        # falls back to fleet-observed top-6 if the manifest is unreachable
        try {
            $m = Get-AzLocalLatestSolutionVersion -ErrorAction Stop
            $supportedYymms = $m.SupportedYYMMs
            $supportSource  = 'Microsoft manifest'
        } catch {
            $supportedYymms = $fleetObservedYymms  # legacy fallback
            $supportSource  = 'fleet-observed'
        }

    .NOTES
        Author       : Neil Bird, Microsoft
        Version      : v0.7.70
        Added        : v0.7.70 (Phase E - rolling support window anchored on Microsoft manifest)
        Endpoint     : https://aka.ms/AzureEdgeUpdates (unauthenticated, public catalog)
        Network      : Single GET request; respects $env:HTTPS_PROXY via Invoke-WebRequest defaults.
        Rate limits  : None observed; manifest is small (~tens of KB) and CDN-fronted.

    .LINK
        https://learn.microsoft.com/azure/azure-local/whats-new
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidatePattern('^https?://')]
        [string]$ManifestUrl = 'https://aka.ms/AzureEdgeUpdates',

        [Parameter()]
        [ValidateRange(1, 24)]
        [int]$SupportWindowMonths = 6,

        [Parameter()]
        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 30
    )

    # ------------------------------------------------------------------
    # 1) Fetch the manifest
    # ------------------------------------------------------------------
    Write-Verbose "Fetching Azure Edge Updates manifest from $ManifestUrl (timeout=${TimeoutSeconds}s)."
    $fetchedAt = [DateTime]::UtcNow
    try {
        $response = Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
    }
    catch {
        throw "Failed to fetch Azure Edge Updates manifest from '$ManifestUrl': $($_.Exception.Message)"
    }

    if (-not $response -or $response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        $code = if ($response) { $response.StatusCode } else { '<no response>' }
        throw "Azure Edge Updates manifest fetch returned HTTP $code (expected 2xx)."
    }

    # ------------------------------------------------------------------
    # 2) Parse XML
    # ------------------------------------------------------------------
    $rawText = $null
    if ($response.Content -is [byte[]]) {
        $rawText = [System.Text.Encoding]::UTF8.GetString($response.Content)
    }
    else {
        $rawText = [string]$response.Content
    }

    if ([string]::IsNullOrWhiteSpace($rawText)) {
        throw "Azure Edge Updates manifest at '$ManifestUrl' returned an empty body."
    }

    [xml]$manifest = $null
    try {
        $manifest = [xml]$rawText
    }
    catch {
        throw "Azure Edge Updates manifest at '$ManifestUrl' is not valid XML: $($_.Exception.Message)"
    }

    if (-not $manifest.ASZSolutionBundleUpdates) {
        throw "Azure Edge Updates manifest at '$ManifestUrl' has no <ASZSolutionBundleUpdates> root element."
    }

    # ------------------------------------------------------------------
    # 3) Collect all Version + UpdateName pairs from the two known UpdateInfo locations
    # ------------------------------------------------------------------
    $releases = New-Object System.Collections.Generic.List[object]

    $applicable = $manifest.ASZSolutionBundleUpdates.ApplicableUpdate
    if ($applicable) {
        foreach ($u in @($applicable.UpdateInfo)) {
            if ($null -ne $u -and $u.Version) {
                $releases.Add([PSCustomObject]@{
                    UpdateName = [string]$u.UpdateName
                    Version    = [string]$u.Version
                    Source     = 'ApplicableUpdate.UpdateInfo'
                })
            }
        }
    }

    $services = $manifest.ASZSolutionBundleUpdates.PackageMetadata.ServicesUpdates
    if ($services) {
        foreach ($svc in @($services.Update)) {
            if ($null -ne $svc -and $svc.UpdateInfo -and $svc.UpdateInfo.Version) {
                $releases.Add([PSCustomObject]@{
                    UpdateName = [string]$svc.UpdateInfo.UpdateName
                    Version    = [string]$svc.UpdateInfo.Version
                    Source     = 'PackageMetadata.ServicesUpdates.Update.UpdateInfo'
                })
            }
        }
    }

    if ($releases.Count -eq 0) {
        throw "Azure Edge Updates manifest at '$ManifestUrl' contains no parseable UpdateInfo entries with a Version attribute."
    }

    # ------------------------------------------------------------------
    # 4) Annotate each release with its YYMM (first dotted token matching YY=20-99 & MM=01-12)
    # ------------------------------------------------------------------
    $yymmRegex = '^[0-9]{4}$'
    foreach ($r in $releases) {
        $parts = ([string]$r.Version) -split '\.'
        $foundYymm = $null
        foreach ($p in $parts) {
            if ($p -match $yymmRegex) {
                $yy = [int]$p.Substring(0, 2)
                $mm = [int]$p.Substring(2, 2)
                if ($yy -ge 20 -and $yy -le 99 -and $mm -ge 1 -and $mm -le 12) {
                    $foundYymm = $p
                    break
                }
            }
        }
        $r | Add-Member -MemberType NoteProperty -Name Yymm -Value $foundYymm -Force
    }

    $withYymm = @($releases | Where-Object { $_.Yymm })
    if ($withYymm.Count -eq 0) {
        throw "Azure Edge Updates manifest at '$ManifestUrl' contains UpdateInfo entries but none have a YYMM token in their Version string (expected format: <prefix>.YYMM.X.X)."
    }

    # ------------------------------------------------------------------
    # 5) Identify LatestYYMM and the highest full Version string at that YYMM
    # ------------------------------------------------------------------
    $latestYymm = ($withYymm | Sort-Object -Property Yymm -Descending | Select-Object -First 1).Yymm
    $atLatest = @($withYymm | Where-Object { $_.Yymm -eq $latestYymm })
    # Pick the highest Version string at LatestYYMM. Parse with [version] when possible
    # (strip the leading alpha prefix from the first token); fall back to string compare.
    $latestVersion = ($atLatest | Sort-Object -Property @{
        Expression = {
            $vstr = ($_.Version -replace '^[A-Za-z]+', '')
            try { [version]$vstr } catch { $null }
        }
    }, @{
        Expression = 'Version'
    } -Descending | Select-Object -First 1).Version

    # ------------------------------------------------------------------
    # 6) Compute the rolling support window by stepping the calendar back
    # ------------------------------------------------------------------
    $supportedYymms = New-Object System.Collections.Generic.List[string]
    $yy = [int]$latestYymm.Substring(0, 2)
    $mm = [int]$latestYymm.Substring(2, 2)
    for ($i = 0; $i -lt $SupportWindowMonths; $i++) {
        $supportedYymms.Add(('{0:D2}{1:D2}' -f $yy, $mm))
        # Decrement one month
        $mm--
        if ($mm -lt 1) { $mm = 12; $yy-- }
        # Guard against unrealistic underflow (YY < 20)
        if ($yy -lt 20) { break }
    }

    # ------------------------------------------------------------------
    # 7) Emit
    # ------------------------------------------------------------------
    $allReleases = @($releases | Sort-Object -Property Yymm, Version -Descending)
    return [PSCustomObject]@{
        LatestYYMM          = $latestYymm
        LatestVersion       = $latestVersion
        SupportedYYMMs      = $supportedYymms.ToArray()
        AllReleases         = $allReleases
        ManifestUrl         = $ManifestUrl
        ManifestFetchedAt   = $fetchedAt
        SupportWindowMonths = $SupportWindowMonths
        Source              = 'aka.ms/AzureEdgeUpdates'
    }
}
