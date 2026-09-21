function Invoke-AzLocalServiceNowAdapter {
    <#
    .SYNOPSIS
        ServiceNow Table API adapter for the AzLocal.UpdateManagement ITSM connector.

    .DESCRIPTION
        Handles every ServiceNow HTTP interaction needed by Phase 1:
          - Action 'GetToken'       -> OAuth 2.0 client_credentials grant
          - Action 'FindByDedupe'   -> GET /api/now/table/incident filtered by u_azlocal_dedupe_key
          - Action 'CreateIncident' -> POST /api/now/table/incident
          - Action 'AddWorkNote'    -> PATCH /api/now/table/incident/{sys_id} with work_notes
          - Action 'AttachFile'     -> POST /api/now/attachment/file?table_name=incident&table_sys_id=...
          - Action 'TransitionState'-> PATCH /api/now/table/incident/{sys_id} with state/close_code/close_notes
          - Action 'TestConnection' -> GET /api/now/table/incident?sysparm_limit=1 (auth + incident-scope probe)

        Phase 1 supports only the OAuth 2.0 client_credentials grant; tokens are
        acquired per call (caching is planned for a later phase).
        All HTTP calls flow through Invoke-AzLocalItsmHttp (TLS 1.2, retry, backoff).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GetToken','FindByDedupe','CreateIncident','AddWorkNote','AttachFile','TransitionState','TestConnection')]
        [string]$Action,

        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$InstanceUrl,

        # Auth (used by GetToken; otherwise ignored if -AccessToken supplied)
        [Parameter(Mandatory = $false)][string]$ClientId,
        [Parameter(Mandatory = $false)][string]$ClientSecret,

        # Pre-obtained bearer token (skips GetToken if supplied)
        [Parameter(Mandatory = $false)][string]$AccessToken,

        # Action-specific
        [Parameter(Mandatory = $false)][string]$DedupeKey,
        [Parameter(Mandatory = $false)][hashtable]$IncidentFields,
        [Parameter(Mandatory = $false)][string]$SysId,
        [Parameter(Mandatory = $false)][string]$WorkNote,
        [Parameter(Mandatory = $false)][string]$AttachmentPath,
        [Parameter(Mandatory = $false)][int]$NewState,
        [Parameter(Mandatory = $false)][string]$CloseCode,
        [Parameter(Mandatory = $false)][string]$CloseNotes
    )

    Assert-AzLocalItsmUri -Uri $InstanceUrl -Instance
    $base = $InstanceUrl.TrimEnd('/')

    # --- Token acquisition / cache lookup ---------------------------------
    if ($Action -eq 'GetToken') {
        if ([string]::IsNullOrEmpty($ClientId) -or [string]::IsNullOrEmpty($ClientSecret)) {
            throw "ServiceNow GetToken requires -ClientId and -ClientSecret."
        }
        $tokenUri = "$base/oauth_token.do"
        $form = @{
            grant_type    = 'client_credentials'
            client_id     = $ClientId
            client_secret = $ClientSecret
        }

        $bodyStr = ($form.GetEnumerator() | ForEach-Object {
            "{0}={1}" -f [Uri]::EscapeDataString($_.Key), [Uri]::EscapeDataString([string]$_.Value)
        }) -join '&'

        $resp = Invoke-AzLocalItsmHttp -Method POST -Uri $tokenUri -Body $bodyStr -ContentType 'application/x-www-form-urlencoded'
        if (-not $resp.access_token) {
            throw "ServiceNow OAuth response did not contain an access_token."
        }
        return [pscustomobject]@{
            AccessToken = [string]$resp.access_token
            ExpiresIn   = if ($resp.PSObject.Properties['expires_in']) { [int]$resp.expires_in } else { 1800 }
            TokenType   = if ($resp.PSObject.Properties['token_type']) { [string]$resp.token_type } else { 'Bearer' }
        }
    }

    if ([string]::IsNullOrEmpty($AccessToken)) {
        throw "ServiceNow $Action requires an -AccessToken (obtain via -Action GetToken first)."
    }

    $authHeaders = @{
        Authorization = "Bearer $AccessToken"
        Accept        = 'application/json'
    }

    switch ($Action) {
        'TestConnection' {
            $uri = "$base/api/now/table/incident?sysparm_limit=1&sysparm_fields=sys_id"
            return Invoke-AzLocalItsmHttp -Method GET -Uri $uri -Headers $authHeaders
        }

        'FindByDedupe' {
            if ([string]::IsNullOrEmpty($DedupeKey)) { throw "FindByDedupe requires -DedupeKey." }
            $q = "u_azlocal_dedupe_key=$DedupeKey^stateIN1,2,3"
            $uri = "$base/api/now/table/incident?sysparm_query=$([Uri]::EscapeDataString($q))&sysparm_limit=1&sysparm_fields=sys_id,number,state,assigned_to,assignment_group,u_azlocal_dedupe_key"
            $resp = Invoke-AzLocalItsmHttp -Method GET -Uri $uri -Headers $authHeaders
            if ($resp.result -and $resp.result.Count -gt 0) {
                return $resp.result[0]
            }
            return $null
        }

        'CreateIncident' {
            if (-not $IncidentFields) { throw "CreateIncident requires -IncidentFields." }
            $uri = "$base/api/now/table/incident"
            $resp = Invoke-AzLocalItsmHttp -Method POST -Uri $uri -Headers $authHeaders -Body $IncidentFields
            return $resp.result
        }

        'AddWorkNote' {
            if ([string]::IsNullOrEmpty($SysId)) { throw "AddWorkNote requires -SysId." }
            if ([string]::IsNullOrEmpty($WorkNote)) { throw "AddWorkNote requires -WorkNote." }
            $uri = "$base/api/now/table/incident/$SysId"
            $resp = Invoke-AzLocalItsmHttp -Method PATCH -Uri $uri -Headers $authHeaders -Body @{ work_notes = $WorkNote }
            return $resp.result
        }

        'TransitionState' {
            if ([string]::IsNullOrEmpty($SysId)) { throw "TransitionState requires -SysId." }
            if (-not $NewState) { throw "TransitionState requires -NewState." }
            $payload = @{ state = $NewState }
            if ($CloseCode)  { $payload['close_code']  = $CloseCode }
            if ($CloseNotes) { $payload['close_notes'] = $CloseNotes }
            $uri = "$base/api/now/table/incident/$SysId"
            $resp = Invoke-AzLocalItsmHttp -Method PATCH -Uri $uri -Headers $authHeaders -Body $payload
            return $resp.result
        }

        'AttachFile' {
            if ([string]::IsNullOrEmpty($SysId)) { throw "AttachFile requires -SysId." }
            if ([string]::IsNullOrEmpty($AttachmentPath)) { throw "AttachFile requires -AttachmentPath." }
            if (-not (Test-Path -Path $AttachmentPath -PathType Leaf)) {
                throw "AttachFile: file not found at '$AttachmentPath'."
            }
            $fileName = Split-Path -Path $AttachmentPath -Leaf
            $uri = "$base/api/now/attachment/file?table_name=incident&table_sys_id=$SysId&file_name=$([Uri]::EscapeDataString($fileName))"
            $bytes = [IO.File]::ReadAllBytes($AttachmentPath)
            $resp = Invoke-AzLocalItsmHttp -Method POST -Uri $uri -Headers $authHeaders -Body $bytes -ContentType 'application/octet-stream'
            return $resp.result
        }
    }
}
