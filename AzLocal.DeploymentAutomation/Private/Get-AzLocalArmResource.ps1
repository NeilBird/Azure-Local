Function Get-AzLocalArmResource {
    <#
    .SYNOPSIS

    Existence-aware wrapper around Get-AzResource that does not mask real errors.

    .DESCRIPTION

    Calling Get-AzResource for a resource ID with -ErrorAction SilentlyContinue
    silently swallows ALL errors - including HTTP 400 "unsupported api-version"
    and transport / auth / RBAC failures - and returns $null. Callers then
    misinterpret that $null as "the resource does not exist", producing misleading
    errors such as "Arc node not found" when the lookup actually failed for an
    unrelated reason.

    This wrapper distinguishes the three possible outcomes:

      * Resource exists           -> returns the resource object.
      * Resource genuinely absent -> returns $null (HTTP 404 / ResourceNotFound).
      * Any other failure         -> throws, surfacing the real ARM error message.

    It also self-heals the api-version negotiation problem. If ARM rejects the
    auto-negotiated api-version (HTTP 400 "No registered resource provider found
    ... The supported api-versions are ..."), it parses the supported versions
    from ARM's own error message and retries once with the newest stable
    (non-preview) version. This avoids hard-coding api-versions that age out.

    .PARAMETER ResourceId

    The full Azure resource ID to look up.

    .PARAMETER ResourceKind

    Friendly label used in verbose and error messages (e.g. 'Arc node', 'cluster').
    Defaults to 'resource'.

    .PARAMETER ApiVersion

    Optional explicit api-version for the FIRST lookup attempt (e.g. a resource
    type's known GA version). If ARM rejects it, the function self-heals by
    parsing the supported-versions list and retrying with the newest stable one.

    .OUTPUTS

    The resource object when it exists, or $null when it genuinely does not exist.

    .NOTES
    Author : Azure-Local DeploymentAutomation
    Purpose: Prevent Get-AzResource from masking real failures (api-version,
             auth, RBAC, transport) as "resource not found".
    #>

    [OutputType([object])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ResourceId,

        [Parameter(Mandatory = $false, Position = 1)]
        [string]$ResourceKind = 'resource',

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion
    )

    # Error-message fragments that indicate the resource genuinely does not exist
    # (as opposed to a transport / validation / authorization failure).
    $notFoundPattern = 'ResourceNotFound|was not found|could not be found|StatusCode:\s*404'

    # Seed the first call with a caller-supplied api-version when provided (e.g. the
    # known GA version for the resource type). If ARM rejects it, the catch block
    # below self-heals by parsing ARM's supported-versions list and retrying.
    $getParams = @{ ResourceId = $ResourceId; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($ApiVersion)) { $getParams['ApiVersion'] = $ApiVersion }

    try {
        return Get-AzResource @getParams
    } catch {
        $msg = [string]$_.Exception.Message

        # Genuine absence -> this is an expected, non-error outcome.
        if ($msg -match $notFoundPattern) {
            Write-Verbose "$ResourceKind '$ResourceId' not found (genuine 404)."
            return $null
        }

        # Unsupported auto-negotiated api-version -> parse the supported versions
        # from ARM's error and retry once with the newest stable (non-preview) one.
        if ($msg -match 'No registered resource provider found' -or $msg -match 'supported api-versions') {
            $supportedSegment = $msg
            $idx = $msg.IndexOf('supported api-versions are')
            if ($idx -ge 0) { $supportedSegment = $msg.Substring($idx) }

            $versions = @([regex]::Matches($supportedSegment, '\d{4}-\d{2}-\d{2}(?:-preview)?') |
                ForEach-Object { $_.Value } | Select-Object -Unique)
            $stable = @($versions | Where-Object { $_ -notmatch 'preview' } | Sort-Object -Descending)
            $retryVersion = if ($stable.Count -gt 0) {
                $stable[0]
            } elseif ($versions.Count -gt 0) {
                (@($versions | Sort-Object -Descending))[0]
            } else {
                $null
            }

            if ($retryVersion) {
                Write-Verbose "Default api-version was rejected for $ResourceKind '$ResourceId'; retrying with supported api-version '$retryVersion'."
                try {
                    return Get-AzResource -ResourceId $ResourceId -ApiVersion $retryVersion -ErrorAction Stop
                } catch {
                    $retryMsg = [string]$_.Exception.Message
                    if ($retryMsg -match $notFoundPattern) {
                        Write-Verbose "$ResourceKind '$ResourceId' not found (genuine 404) at api-version '$retryVersion'."
                        return $null
                    }
                    throw "Failed to query $ResourceKind '$ResourceId' at api-version '$retryVersion': $retryMsg"
                }
            }
        }

        # Any other failure (auth, RBAC, throttling, transport) - surface the real
        # error instead of masking it as "not found".
        throw "Failed to query $ResourceKind '$ResourceId': $msg"
    }
}
