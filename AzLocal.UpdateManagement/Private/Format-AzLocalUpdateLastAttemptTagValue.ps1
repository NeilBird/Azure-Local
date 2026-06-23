function Format-AzLocalUpdateLastAttemptTagValue {
    <#
    .SYNOPSIS
        Build the value string written to the UpdateLastAttempt cluster tag.
    .DESCRIPTION
        Format is intentionally simple, semicolon-delimited, parseable by
        ConvertFrom-AzLocalUpdateLastAttemptTagValue:

            <ISO-8601 UTC>;<Outcome>;<UpdateName>;<Reason>

        Truncated to 256 chars (Azure tag value upper limit). Reason is
        truncated first when the total length would exceed 256.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$AttemptUtc,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Outcome,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$UpdateName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Reason
    )

    $ts = $AttemptUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $u  = if ([string]::IsNullOrWhiteSpace($UpdateName)) { '' } else { $UpdateName.Trim() }
    $r  = if ([string]::IsNullOrWhiteSpace($Reason)) { '' } else {
        # collapse whitespace + strip semicolons so the field stays a single token
        ($Reason -replace ';', ',' -replace '\s+', ' ').Trim()
    }

    $head = "$ts;$Outcome;$u;"
    $maxReasonLen = 256 - $head.Length
    if ($maxReasonLen -lt 0) { $maxReasonLen = 0 }
    if ($r.Length -gt $maxReasonLen) {
        if ($maxReasonLen -gt 1) {
            $r = $r.Substring(0, $maxReasonLen - 1) + '~'
        } else {
            $r = ''
        }
    }

    # Final hard clamp (v0.8.95 guard rail): the Reason truncation above keeps the
    # value <= 256 in the normal case, but a pathologically long Outcome or
    # UpdateName could make $head alone exceed 256 (driving $maxReasonLen to 0 yet
    # still over-length). Azure rejects tag values > 256 chars, so clamp the whole
    # string defensively as a last line of defence regardless of which field is long.
    $final = $head + $r
    if ($final.Length -gt 256) {
        $final = $final.Substring(0, 256)
    }
    return $final
}
