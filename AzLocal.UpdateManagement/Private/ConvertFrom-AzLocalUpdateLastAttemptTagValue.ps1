function ConvertFrom-AzLocalUpdateLastAttemptTagValue {
    <#
    .SYNOPSIS
        Parse the value written by Format-AzLocalUpdateLastAttemptTagValue.
    .DESCRIPTION
        Returns a PSCustomObject with AttemptUtc (DateTime), Outcome (string),
        UpdateName (string), Reason (string). Returns $null when the value is
        empty / cannot be parsed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }

    $parts = $Value -split ';', 4
    if ($parts.Count -lt 2) { return $null }

    [datetime]$ts = [datetime]::MinValue
    if (-not [datetime]::TryParse($parts[0], [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$ts)) {
        return $null
    }

    $outcome = $parts[1]
    $updateName = if ($parts.Count -ge 3) { $parts[2] } else { '' }
    $reason = if ($parts.Count -ge 4) { $parts[3] } else { '' }

    return [PSCustomObject]@{
        AttemptUtc = $ts.ToUniversalTime()
        Outcome    = [string]$outcome
        UpdateName = [string]$updateName
        Reason     = [string]$reason
    }
}
