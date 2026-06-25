function Test-AzLocalReadmeReplaceable {
    <#
    .SYNOPSIS
        Decides whether an existing repo README.md is "empty enough" to be
        safely replaced by the module-managed README template.

    .DESCRIPTION
        Private helper introduced in v0.9.0 for the managed repo README drop in
        Copy-AzLocalPipelineExample / Update-AzLocalPipelineExample. A README is
        treated as REPLACEABLE (safe to overwrite with the bundled template)
        when it carries no operator content worth keeping, specifically:

          * the file is missing / null / whitespace-only, OR
          * it is a GitHub "Add a README" default stub - an H1 whose text
            matches the repository name (case- and punctuation-insensitive),
            optionally followed by a single short plain-prose description line,
            and nothing else (no second heading, list, table, code fence,
            blockquote, link-only line or image).

        Anything richer than that (two-plus content lines beyond the optional
        description, any markdown structure, or an H1 that does not match the
        repo name) is treated as OPERATOR-OWNED and is NOT replaceable.

        Callers handle the module-managed case (a README carrying an
        AZLOCAL-README-VERSION marker) separately via
        Get-AzLocalReadmeTemplateVersion; this helper only judges marker-less
        content.

    .PARAMETER Text
        The full README text. Pass an empty string for a missing file.

    .PARAMETER RepoName
        The repository folder name (e.g. Split-Path -Leaf $repoRoot). Used to
        confirm an H1 is the GitHub default repo-name heading. When empty, a
        lone heading is treated as operator-owned (conservative: preserve).

    .OUTPUTS
        [bool] - $true when the README is safe to overwrite, else $false.

    .NOTES
        Author   : Neil Bird, Microsoft
        Module   : AzLocal.UpdateManagement
        Added in : v0.9.0
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$RepoName = ''
    )

    # Missing / whitespace-only -> always safe to write.
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $true
    }

    # Non-blank, trimmed content lines. -split uses regex; "`r?`n" matches both
    # CRLF and LF line endings.
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

    if ($lines.Count -eq 0) {
        return $true
    }
    # More than (H1 + one description line) of content -> operator-owned.
    if ($lines.Count -gt 2) {
        return $false
    }

    # First content line must be a single H1 heading: "# Title".
    $h1 = [regex]::Match($lines[0], '^#\s+(.+?)\s*$')
    if (-not $h1.Success) {
        return $false
    }

    # An optional second line must be plain prose - reject any markdown
    # structure (heading, list, ordered list, blockquote, table, code fence,
    # image, or a line that is itself a markdown link).
    if ($lines.Count -eq 2) {
        if ($lines[1] -match '^(#|-|\*|>|\||```|\d+\.|!\[|\[)') {
            return $false
        }
    }

    # The H1 must match the repository name (GitHub's default README uses the
    # repo name verbatim). Normalise by lowercasing and stripping anything that
    # is not a letter or digit so 'My-Repo' and 'my repo' compare equal.
    if ([string]::IsNullOrWhiteSpace($RepoName)) {
        return $false
    }
    $h1Norm   = ($h1.Groups[1].Value -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    $repoNorm = ($RepoName -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()

    return ($h1Norm -ne '' -and $h1Norm -eq $repoNorm)
}
