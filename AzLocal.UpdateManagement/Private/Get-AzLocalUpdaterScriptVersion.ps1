function Get-AzLocalUpdaterScriptVersion {
    <#
    .SYNOPSIS
        Extracts the template version stamp from the turnkey
        Update-Module-And-Pipelines.ps1 refresh script.

    .DESCRIPTION
        Private helper introduced in v0.8.98 supporting the version-gated
        self-refresh of the turnkey updater script that
        Copy-AzLocalPipelineExample / Update-AzLocalPipelineExample drop into a
        customer repo root. The bundled template carries a single header
        comment of the form:

            # AZLOCAL-UPDATER-VERSION: 1.0.0

        The marker is a plain PowerShell comment (leading '#') and therefore
        has zero runtime effect. Copy/Update compare the bundled template's
        version against the dropped file's version and re-render the script in
        place only when the bundled version is NEWER (so module-shipped
        improvements propagate to existing repos without a manual re-copy),
        while leaving an up-to-date or operator-frozen file untouched.

        Matching is case-insensitive on the 'AZLOCAL-UPDATER-VERSION' token;
        leading whitespace and one-or-more '#' characters are tolerated. Only
        the FIRST occurrence is returned. A non-version-shaped value, or no
        marker at all (e.g. a pre-v0.8.98 drop that predates the convention),
        yields $null.

    .PARAMETER Text
        The full script text to scan. Use Get-Content -Raw or
        [IO.File]::ReadAllText to obtain it.

    .OUTPUTS
        [version] - the parsed template version, or $null when no valid marker
        is present.

    .NOTES
        Author   : Neil Bird, Microsoft
        Module   : AzLocal.UpdateManagement
        Added in : v0.8.98
    #>
    [CmdletBinding()]
    [OutputType([version])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $null
    }

    # (?m) multiline so ^ matches each line start. Tolerate leading spaces,
    # one-or-more '#', spaces around the colon. Capture a dotted version.
    $match = [regex]::Match($Text, '(?im)^\s*#+\s*AZLOCAL-UPDATER-VERSION\s*:\s*([0-9]+(?:\.[0-9]+){1,3})\s*$')
    if (-not $match.Success) {
        return $null
    }

    [version]$parsed = $null
    if ([version]::TryParse($match.Groups[1].Value.Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $null
}
