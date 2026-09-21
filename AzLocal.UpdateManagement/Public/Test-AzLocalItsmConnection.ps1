function Test-AzLocalItsmConnection {
    <#
    .SYNOPSIS
        Dry-run probe of the configured ITSM endpoint and notification adapters.

    .DESCRIPTION
        Performs a minimal authenticated GET against the configured ServiceNow
        instance to verify:
          - secret references resolve (Key Vault / env)
          - OAuth client credentials grant succeeds
          - the bearer token can read the incident table

        Mirror-channel checks (Teams / Slack) are deferred to Phase 3.

        Returns a pscustomobject describing each probe step with Pass/Fail
        plus the observed message. Does NOT throw on probe failure; throws
        only on missing-config / missing-secret prerequisites so the caller
        can render the result deterministically.

    .EXAMPLE
        $cfg = Get-AzLocalItsmConfig -Path ./.itsm/azurelocal-itsm.yml
        Test-AzLocalItsmConnection -Config $cfg | Format-Table Step, Pass, Message
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [pscustomobject]$Config
    )

    $results = New-Object System.Collections.ArrayList

    function Add-ProbeResult {
        param([string]$Step, [bool]$Pass, [string]$Message)
        [void]$results.Add([pscustomobject]@{
            Step    = $Step
            Pass    = $Pass
            Message = $Message
        })
    }

    $sn = $Config.Secrets['servicenow']
    if (-not $sn) {
        throw "Test-AzLocalItsmConnection: config does not contain a 'secrets.servicenow' section."
    }
    $kv = [string]$Config.Secrets['keyvaultName']

    # 1. Resolve instance URL
    try {
        $instanceUrl = Resolve-AzLocalItsmSecret -Reference ([string]$sn['instanceUrl']) -DefaultKeyVault $kv -AllowLiteral
        Assert-AzLocalItsmUri -Uri $instanceUrl -Instance
        Add-ProbeResult -Step 'Resolve instanceUrl' -Pass $true -Message $instanceUrl
    }
    catch {
        Add-ProbeResult -Step 'Resolve instanceUrl' -Pass $false -Message $_.Exception.Message
        return $results
    }

    # 2. Resolve client_id / client_secret
    try {
        $clientId     = Resolve-AzLocalItsmSecret -Reference ([string]$sn['clientId'])     -DefaultKeyVault $kv
        $clientSecret = Resolve-AzLocalItsmSecret -Reference ([string]$sn['clientSecret']) -DefaultKeyVault $kv
        Add-ProbeResult -Step 'Resolve OAuth secrets' -Pass $true -Message 'clientId + clientSecret resolved.'
    }
    catch {
        Add-ProbeResult -Step 'Resolve OAuth secrets' -Pass $false -Message $_.Exception.Message
        return $results
    }

    # 3. Obtain token
    $accessToken = $null
    try {
        $tok = Invoke-AzLocalServiceNowAdapter -Action GetToken `
            -InstanceUrl $instanceUrl `
            -ClientId    $clientId `
            -ClientSecret $clientSecret
        $accessToken = $tok.AccessToken
        Add-ProbeResult -Step 'OAuth token grant' -Pass $true -Message "expires_in=$($tok.ExpiresIn)s"
    }
    catch {
        Add-ProbeResult -Step 'OAuth token grant' -Pass $false -Message $_.Exception.Message
        return $results
    }

    # 4. Probe incident table read
    try {
        $null = Invoke-AzLocalServiceNowAdapter -Action TestConnection `
            -InstanceUrl $instanceUrl `
            -AccessToken $accessToken
        Add-ProbeResult -Step 'Incident table read' -Pass $true -Message 'GET incident?sysparm_limit=1 succeeded.'
    }
    catch {
        Add-ProbeResult -Step 'Incident table read' -Pass $false -Message $_.Exception.Message
    }

    return $results
}
