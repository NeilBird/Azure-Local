########################################
<#
.SYNOPSIS
    Normalizes a legacy (v0.9.1) commented Excluded-Subscription-Ids.csv to the
    clean, comment-free v0.9.10 format while preserving any real subscription-id
    rows the operator added.
.DESCRIPTION
    v0.9.1 shipped a starter Excluded-Subscription-Ids.csv that embedded '#'
    guidance comment lines above the CSV header. Those comments parse fine as
    long as the file is untouched, but once an operator opens the file in Excel
    (or another spreadsheet editor) and saves it, the editor re-quotes the
    comment lines and pads them with trailing commas, so they no longer start
    with '#'. The exclusion parser then mistakes the first quoted comment for the
    header and throws, silently disabling every real exclusion row.

    v0.9.10 splits the guidance into a sidecar Excluded-Subscription-Ids_README.txt
    and ships a clean header-only CSV. Because Copy-/Update-AzLocalPipelineExample
    never overwrite an existing file, an early adopter who already landed on
    v0.9.1 would keep the fragile commented CSV. This helper proactively strips
    the legacy comment lines during the next Copy/Update so the latent Excel
    footgun is removed BEFORE it can be triggered.

    The detection is the presence of any '#' comment line - a clean v0.9.10 CSV
    has none, so this is a no-op (returns $false) for already-clean files and is
    safe to call unconditionally and repeatedly (idempotent). Real subscription-id
    rows are extracted with a GUID regex over the RAW lines (NOT ConvertFrom-Csv),
    so the helper still recovers the operator's GUIDs even if the file has already
    been mangled by Excel. The original file is recoverable from git history (the
    turnkey updater commits the config folder), so no separate backup is written.
.PARAMETER Path
    Full path to the Excluded-Subscription-Ids.csv to inspect and, if it is in
    the legacy commented format, normalize in place.
.OUTPUTS
    [bool] $true when the file was rewritten (legacy format detected and
    normalized); $false when no action was taken (file missing, or already in the
    clean comment-free format).
.NOTES
    Author : AzLocal.UpdateManagement
    Added  : v0.9.10

    ONE-TIME MIGRATION. This helper exists solely to normalize files dropped by
    the short-lived v0.9.1 commented-CSV format. It is a permanent no-op for any
    clean v0.9.10+ CSV (no '#' lines), so it is safe to leave in place, but it
    can be removed in a future release once we are confident no v0.9.1-format
    files remain in the wild (the format was published only briefly). When
    removing, also delete its NestedModules entry in the manifest, the two call
    sites in Copy-/Update-AzLocalPipelineExample, and the v0.9.10 migration
    tests in Tests/ExcludedSubscriptions.Tests.ps1.
#>
########################################
function Repair-AzLocalExcludedSubscriptionCsv {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $rawLines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)

    # Legacy-format signature: any '#' comment line. A clean v0.9.10 CSV carries
    # none, so already-clean files return $false (idempotent, safe to re-run).
    # Tolerate Excel-mangled comments wrapped in double quotes ("# ...",,).
    $hasComments = @($rawLines | Where-Object { $_.TrimStart().TrimStart('"').StartsWith('#') }).Count -gt 0
    if (-not $hasComments) {
        return $false
    }

    # Recover real subscription-id rows from the RAW lines so this survives a
    # file that Excel has already re-quoted (ConvertFrom-Csv would throw on it).
    $guidRegex = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    $preserved = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $rawLines) {
        $trimmed = $line.TrimStart()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed.StartsWith('#'))                { continue }

        # First field is the subscription-id column. Tolerate Excel-added
        # surrounding double quotes; keep the remaining columns verbatim.
        $parts      = $line -split ',', 2
        $firstField = $parts[0].Trim().Trim('"').Trim()
        if ($firstField -match $guidRegex) {
            $rest = if ($parts.Count -gt 1) { $parts[1] } else { '' }
            $preserved.Add(($firstField + ',' + $rest))
        }
    }

    $clean = New-Object 'System.Collections.Generic.List[string]'
    $clean.Add('Subscription IDs,Subscription Name,Comment / Notes')
    foreach ($row in $preserved) {
        $clean.Add($row)
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Normalize legacy commented Excluded-Subscription-Ids.csv to clean comment-free CSV')) {
        Set-Content -LiteralPath $Path -Value $clean.ToArray() -Encoding ASCII -ErrorAction Stop
        return $true
    }

    return $false
}
