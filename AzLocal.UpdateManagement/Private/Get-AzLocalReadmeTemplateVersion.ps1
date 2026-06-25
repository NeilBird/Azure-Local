function Get-AzLocalReadmeTemplateVersion {
    <#
    .SYNOPSIS
        Extracts the template version stamp from the bundled repo README
        template (repo-readme-template.md) or a dropped README.md.

    .DESCRIPTION
        Private helper introduced in v0.9.0 supporting the version-gated
        self-refresh of the managed repo README that
        Copy-AzLocalPipelineExample / Update-AzLocalPipelineExample drop into a
        customer repo root. The bundled template carries a single hidden HTML
        comment of the form:

            <!-- AZLOCAL-README-VERSION: 1.0.0 -->

        Because it is an HTML comment it is invisible in rendered Markdown and
        therefore has zero display effect. Copy/Update compare the bundled
        template's version against the dropped README's version and re-render
        the file in place only when the bundled version is NEWER (so
        module-shipped doc improvements propagate to existing repos without a
        manual re-copy), while leaving an up-to-date or operator-frozen file
        untouched.

        Matching is case-insensitive on the 'AZLOCAL-README-VERSION' token and
        is tolerant of the surrounding comment syntax (only the token, colon
        and dotted version are required). Only the FIRST occurrence is
        returned. A non-version-shaped value, or no marker at all (e.g. an
        operator-owned README that predates or removed the convention), yields
        $null.

    .PARAMETER Text
        The full README text to scan. Use Get-Content -Raw or
        [IO.File]::ReadAllText to obtain it.

    .OUTPUTS
        [version] - the parsed template version, or $null when no valid marker
        is present.

    .NOTES
        Author   : Neil Bird, Microsoft
        Module   : AzLocal.UpdateManagement
        Added in : v0.9.0
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

    # (?im) case-insensitive, multiline. The marker lives inside an HTML
    # comment, so we deliberately do NOT anchor to a comment prefix - just the
    # token, colon and a dotted version anywhere on a line.
    $match = [regex]::Match($Text, '(?im)AZLOCAL-README-VERSION\s*:\s*([0-9]+(?:\.[0-9]+){1,3})')
    if (-not $match.Success) {
        return $null
    }

    [version]$parsed = $null
    if ([version]::TryParse($match.Groups[1].Value.Trim(), [ref]$parsed)) {
        return $parsed
    }

    return $null
}
