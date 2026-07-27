function ConvertTo-AzLocalMarkdownTableCell {
    ########################################
    <#
    .SYNOPSIS
        Converts dynamic text to a safe Markdown table-cell value.
    .DESCRIPTION
        Escapes Markdown table delimiters and inline-code delimiters, and
        converts embedded line breaks to HTML breaks so one value cannot split
        or terminate its table row.
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if (-not $Value) { return '' }

    return $Value -replace '\|', '\|' -replace '`', '\`' -replace "`r`n|`r|`n", '<br>'
}