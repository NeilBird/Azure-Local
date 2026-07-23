Function Test-AzLocalIPv4Cidr {
    <#
    .SYNOPSIS
        Validates an IPv4 CIDR value, including octet and prefix ranges.
    #>

    [OutputType([bool])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Value
    )

    $parts = $Value -split '/', 2
    if ($parts.Count -ne 2) { return $false }

    $address = [System.Net.IPAddress]::None
    if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$address) -or
        $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $prefixLength = 0
    return [int]::TryParse($parts[1], [ref]$prefixLength) -and $prefixLength -ge 0 -and $prefixLength -le 32
}