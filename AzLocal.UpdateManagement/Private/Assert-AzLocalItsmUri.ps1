function Assert-AzLocalItsmUri {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [switch]$Instance
    )

    $parsedUri = $null
    if (-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsedUri) -or
        $parsedUri.Scheme -ne 'https' -or -not $parsedUri.Host -or
        $parsedUri.UserInfo -or $parsedUri.Fragment -or
        ($Instance -and ($parsedUri.Query -or $parsedUri.AbsolutePath -ne '/'))) {
        throw 'ITSM requires an absolute HTTPS URL without credentials or a fragment; the instance URL must contain only the origin.'
    }
}