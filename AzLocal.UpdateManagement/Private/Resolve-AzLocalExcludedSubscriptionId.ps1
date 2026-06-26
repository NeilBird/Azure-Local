function Resolve-AzLocalExcludedSubscriptionId {
    ########################################
    <#
    .SYNOPSIS
        Parses an optional "excluded subscriptions" CSV and returns the
        validated set of Azure subscription IDs to exclude from Azure Resource
        Graph queries.

    .DESCRIPTION
        v0.9.1 single-source-of-truth parser for the optional subscription
        exclusion list. Given the path to a CSV file, this reads ONLY the
        "Subscription IDs" column (header matching is tolerant of casing,
        spacing and common variants such as 'SubscriptionId' / 'Subscription ID'),
        validates every value as a GUID, lowercases and de-duplicates the valid
        IDs, and records any invalid rows so the caller can warn.

        The file format is a normal CSV with the documented headers:

            Subscription IDs,Subscription Name,Comment / Notes

        Lines that are blank or begin with '#' (after optional leading
        whitespace) are treated as comments and ignored, so the shipped
        skeleton can carry operator guidance above the header row. Only the
        "Subscription IDs" column is consumed; the other columns are purely for
        human readability.

        A header-only file (no data rows) is VALID and returns an empty
        SubscriptionIds set - the caller is expected to surface a warning rather
        than fail, because an empty list simply means "exclude nothing".

        This helper performs NO Azure calls and has no side effects - it is a
        pure parse/validate function over a local file, so it is cheap and
        trivially unit-testable.

    .PARAMETER Path
        Path to the exclusion CSV file. Must exist; a missing file throws a
        terminating error (callers that want a soft "no file = no exclusions"
        behaviour should Test-Path first).

    .OUTPUTS
        [PSCustomObject] with:
          - Path            : the resolved input path
          - Column          : the header name that was matched as the
                              subscription-id column (or $null if none / empty)
          - SubscriptionIds : [string[]] valid, lowercased, de-duplicated GUIDs
          - Skipped         : [PSCustomObject[]] of { Value; Reason } for every
                              non-empty row value that failed GUID validation
          - RowCount        : count of data rows parsed (excluding header)

    .NOTES
        Author : AzLocal.UpdateManagement
        Version: 0.9.1
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Set-StrictMode -Version Latest

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Resolve-AzLocalExcludedSubscriptionId: file not found: '$Path'."
    }

    $validList = [System.Collections.Generic.List[string]]::new()
    $seen      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $skipped   = [System.Collections.Generic.List[object]]::new()

    # Read every line, then drop blank lines and '#' comment lines so the
    # shipped skeleton can carry guidance text above the header row.
    $rawLines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    $dataLines = @($rawLines | Where-Object { $_ -ne $null -and $_.Trim().Length -gt 0 -and ($_.TrimStart() -notmatch '^#') })

    if ($dataLines.Count -eq 0) {
        # No header at all (file empty or entirely comments/blank).
        return [PSCustomObject]@{
            Path            = $Path
            Column          = $null
            SubscriptionIds = $validList.ToArray()
            Skipped         = $skipped.ToArray()
            RowCount        = 0
        }
    }

    # Identify the subscription-id column from the header line. Normalisation
    # strips every non-alphanumeric char and lowercases, so 'Subscription IDs',
    # 'SubscriptionId' and 'Subscription ID' all map to the same token.
    $headerCells = @(($dataLines[0] -split ',') | ForEach-Object { $_.Trim().Trim('"').Trim() })
    $targetHeader = $headerCells |
        Where-Object { ($_ -replace '[^a-zA-Z0-9]', '').ToLower() -in @('subscriptionid', 'subscriptionids') } |
        Select-Object -First 1

    if (-not $targetHeader) {
        throw "Resolve-AzLocalExcludedSubscriptionId: '$Path' does not contain a 'Subscription IDs' column. Expected header: 'Subscription IDs,Subscription Name,Comment / Notes'."
    }

    $normTarget = ($targetHeader -replace '[^a-zA-Z0-9]', '').ToLower()

    $records = @($dataLines | ConvertFrom-Csv)

    foreach ($rec in $records) {
        # Find the subscription-id property on this record by normalised name
        # so trailing spaces in the header do not break the lookup.
        $prop = $rec.PSObject.Properties |
            Where-Object { ($_.Name -replace '[^a-zA-Z0-9]', '').ToLower() -eq $normTarget } |
            Select-Object -First 1

        if (-not $prop) { continue }

        $value = [string]$prop.Value
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $trimmed = $value.Trim()
        $parsed = [guid]::Empty
        if ([guid]::TryParse($trimmed, [ref]$parsed)) {
            $normalized = $parsed.ToString().ToLower()
            if ($seen.Add($normalized)) {
                $validList.Add($normalized)
            }
        }
        else {
            $skipped.Add([PSCustomObject]@{
                    Value  = $trimmed
                    Reason = 'NotAGuid'
                })
        }
    }

    return [PSCustomObject]@{
        Path            = $Path
        Column          = $targetHeader
        SubscriptionIds = $validList.ToArray()
        Skipped         = $skipped.ToArray()
        RowCount        = $records.Count
    }
}
