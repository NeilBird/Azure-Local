function Resolve-AzLocalHardwareOem {
    <#
    .SYNOPSIS
        Normalises a raw cluster-node hardware manufacturer string to a concise
        OEM provider name (Dell / HPE / Lenovo / Supermicro / Microsoft / ...).
    .DESCRIPTION
        v0.9.20 helper for the Monitor: 3 - Fleet Update Status "Fleet - SBE
        Version(s) Distribution" table, which groups clusters by hardware OEM.

        Azure Local reports each node's manufacturer under the cluster resource's
        `properties.reportedProperties.nodes[].manufacturer` (e.g. 'Dell Inc.',
        'Lenovo', 'Microsoft Corporation', 'HPE'). Solution Builder Extension
        (SBE) packages are vendor-specific, and the OEM is the natural primary
        grouping for the SBE distribution - including for clusters running the
        base placeholder SBE (2.0.0.0 / 2.1.0.0) that have no vendor SBE offered.

        This performs a case-insensitive substring match on the raw manufacturer
        and returns a canonical provider label. Unrecognised, non-empty values
        are returned trimmed as-is (so a new OEM still groups sensibly); a
        $null / empty / whitespace manufacturer returns 'Unknown'.
    .PARAMETER Manufacturer
        The raw manufacturer string from reportedProperties.nodes[].manufacturer.
        May be $null / empty.
    .OUTPUTS
        [string] canonical OEM provider name (never $null; 'Unknown' when absent).
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.9.20
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Manufacturer
    )

    Set-StrictMode -Version Latest

    $raw = if ($Manufacturer) { $Manufacturer.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'Unknown' }

    switch -Regex ($raw) {
        'dell'                       { return 'Dell' }
        'lenovo'                     { return 'Lenovo' }
        'hpe|hewlett[\s-]*packard'   { return 'HPE' }
        'supermicro|super\s*micro'   { return 'Supermicro' }
        '\bhp\b'                     { return 'HPE' }
        'microsoft'                  { return 'Microsoft' }
        'intel'                      { return 'Intel' }
        'fujitsu'                    { return 'Fujitsu' }
        default                      { return $raw }
    }
}
