function ConvertTo-ScrubbedCliOutput {
    <#
    .SYNOPSIS
        Masks credential-shaped fragments in Azure CLI output before it is
        written to a log, thrown as an exception message, or bubbled back to
        the caller.
    .DESCRIPTION
        'az rest', 'az graph query', and 'az login' errors occasionally echo
        headers, body fragments, or command lines that contain bearer tokens,
        refresh tokens, client secrets, or passwords. Those strings must
        never land in log files or screen output.

        The scrubber replaces the secret value in each of these shapes with
        the literal '<redacted>' while keeping the surrounding key/field so
        the log remains diagnostically useful:

        - Bearer <jwt>
        - "access_token" / "refresh_token" / "id_token" / "password" /
          "client_secret" / "secret" / "authorization" : "..."
        - Standalone JWT tokens (three dot-separated base64url segments
          starting with 'eyJ').
        - CLI-argument forms: --password <v>, --client-secret <v>,
          --tenant-secret <v>, -p <v>.
        - HTTP header forms: Authorization: <v>
    .PARAMETER Text
        The CLI output to scrub. Null / empty input is returned unchanged.
    .OUTPUTS
        [string] with secret values replaced.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false, ValueFromPipeline = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    process {
        if ([string]::IsNullOrEmpty($Text)) { return $Text }

        $s = $Text

        # 1. Bearer <token>
        $s = [regex]::Replace($s, '(?i)(bearer\s+)[A-Za-z0-9\-_\.=]+', '$1<redacted>')

        # 2. JSON-style credential fields: "name":"value"
        $jsonKeys = '(?i)(\"(?:access_?token|refresh_?token|id_?token|password|client_?secret|clientSecret|secret|authorization|sas_?token|sasToken)\"\s*:\s*\")[^\"]*(\")'
        $s = [regex]::Replace($s, $jsonKeys, '$1<redacted>$2')

        # 2b. Unquoted diagnostic fragments: access_token=value / password: value
        $plainKeys = '(?i)(\b(?:access_?token|refresh_?token|id_?token|password|client_?secret|clientSecret|secret|authorization|sas_?token|sasToken)\b\s*[:=]\s*)(?!<redacted>)[^\s,;]+'
        $s = [regex]::Replace($s, $plainKeys, '$1<redacted>')

        # 3. Standalone JWTs (3 base64url segments, middle segment typically starts with eyJ)
        $s = [regex]::Replace($s, 'eyJ[A-Za-z0-9\-_]{8,}\.[A-Za-z0-9\-_]{8,}\.[A-Za-z0-9\-_]{8,}', '<redacted-jwt>')

        # 4. CLI argument forms: --password foo  /  -p foo
        $cliArgs = '(?i)(--(?:password|client-?secret|tenant-?secret|sas-?token|token|key)\s+)\S+'
        $s = [regex]::Replace($s, $cliArgs, '$1<redacted>')

        # 5. HTTP header form: Authorization: ...
        $s = [regex]::Replace($s, '(?im)^(\s*authorization\s*:\s*).*$', '$1<redacted>')

        return $s
    }
}
