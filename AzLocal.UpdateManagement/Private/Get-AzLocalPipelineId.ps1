function Get-AzLocalPipelineId {
    <#
    .SYNOPSIS
        Extracts the stable logical pipeline ID from a bundled pipeline YAML's
        '# AZLOCAL-PIPELINE-ID:' header comment.

    .DESCRIPTION
        Private helper introduced in v0.8.7 supporting the rename-aware
        behaviour of Update-AzLocalPipelineExample. Every bundled YAML carries
        a single header comment of the form:

            # AZLOCAL-PIPELINE-ID: apply-updates

        The marker is a plain YAML comment (leading '#') and therefore has
        zero runtime effect on GitHub Actions or Azure DevOps. The ID is the
        de-numbered base name and is the STABLE identity that survives both
        filename renames and display-step renumbering.

        Matching is case-insensitive on the 'AZLOCAL-PIPELINE-ID' token; any
        leading whitespace and one-or-more '#' characters are tolerated. Only
        the FIRST occurrence is returned. The captured ID is trimmed.

    .PARAMETER Text
        The full YAML text to scan. Use Get-Content -Raw or
        [IO.File]::ReadAllText to obtain it.

    .OUTPUTS
        [string] - the logical pipeline ID, or $null if no marker is present
        (e.g. a pre-v0.8.7 copy that predates the ID convention).

    .NOTES
        Author   : Neil Bird, Microsoft
        Module   : AzLocal.UpdateManagement
        Added in : v0.8.7
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $null
    }

    # (?m) multiline so ^ matches each line start. Tolerate leading spaces,
    # one-or-more '#', spaces around the colon. Capture the identifier
    # ([A-Za-z0-9_-]+).
    $match = [regex]::Match($Text, '(?im)^\s*#+\s*AZLOCAL-PIPELINE-ID\s*:\s*([A-Za-z0-9_-]+)\s*$')
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }

    return $null
}
