function New-AzLocalIncident {
    <#
    .SYNOPSIS
        Opens or de-duplicates ServiceNow incidents from a JUnit results file.

    .DESCRIPTION
        Consumes the JUnit XML produced by Get-AzLocalUpdateRuns /
        Invoke-AzLocalFleetOperation, applies the configured trigger
        matrix (Get-AzLocalItsmConfig), and for each cluster row that
        matches a 'raiseTicket: true' trigger:

          1. Computes a deterministic SHA256 dedupe key.
          2. Queries ServiceNow for an existing incident with the same key
             in states (New, In Progress, On Hold). Skips re-creation if
             found (returns Action='DedupedToExisting' with the sys_id),
             unless -ForceCreate is supplied.
          3. Otherwise creates a new incident with category / severity /
             custom fields populated from the trigger matrix and run
             metadata. Returns Action='Created' with the new sys_id.

        In -DryRun mode the function still parses, evaluates triggers, and
        builds the payloads, but performs zero HTTP writes. It DOES perform
        the read-only dedupe lookup (GET /api/now/table/incident) when an
        access token can be obtained, so the returned Action correctly shows
        DedupedToExisting / DryRun. If the OAuth grant or dedupe GET fails,
        DryRun degrades gracefully to a fully offline payload build and
        emits Action='DryRun' with a Reason annotation.

        Phase 2 (Sync-AzLocalIncident) handles close-out on subsequent
        successful runs. Phase 3 mirrors to Teams / Slack.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$InputArtifactPath,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [pscustomobject]$Config,

        [Parameter(Mandatory = $false)]
        [hashtable]$RunMetadata,

        [Parameter(Mandatory = $false)]
        [switch]$DryRun,

        [Parameter(Mandatory = $false)]
        [switch]$ForceCreate,

        [Parameter(Mandatory = $false)]
        [ValidateRange(-1, 1000)]
        [int]$MaxIncidentsPerRun = -1,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 100)]
        [int]$ConsecutiveApiFailureLimit = 5,

        [Parameter(Mandatory = $false)]
        [string]$ExportPath,

        [Parameter(Mandatory = $false)]
        [string]$ExportJUnitPath
    )

    if (-not (Test-Path -Path $InputArtifactPath -PathType Leaf)) {
        throw "New-AzLocalIncident: input artefact not found at '$InputArtifactPath'."
    }

    if (-not $RunMetadata) { $RunMetadata = @{} }
    if ($MaxIncidentsPerRun -lt 0) {
        $MaxIncidentsPerRun = (Get-AzLocalFleetSettings).MaxIncidentsPerRun
    }

    # 1. Parse JUnit -> per-cluster rows ------------------------------------
    [xml]$xml = Get-Content -Path $InputArtifactPath -Raw
    $rows = New-Object System.Collections.ArrayList
    foreach ($tc in $xml.SelectNodes('//testcase')) {
        $status = 'Unknown'
        $message = $null
        if ($tc.failure) { $status = 'Failed'; $message = [string]$tc.failure.'#text' }
        elseif ($tc.error)   { $status = 'Error';  $message = [string]$tc.error.'#text' }
        elseif ($tc.skipped) { $status = 'Skipped' }
        else { $status = 'Success' }

        # Module's JUnit writer (Export-ResultsToJUnitXml) emits properties on each testcase
        $props = @{}
        if ($tc.properties -and $tc.properties.property) {
            foreach ($p in $tc.properties.property) {
                $props[[string]$p.name] = [string]$p.value
            }
        }
        if ($props.ContainsKey('Status') -and -not [string]::IsNullOrWhiteSpace($props['Status'])) {
            $status = $props['Status']
        }

        [void]$rows.Add([pscustomobject]@{
            ClassName         = [string]$tc.classname
            Name              = [string]$tc.name
            Status            = $status
            Message           = $message
            ClusterName       = if ($props.ContainsKey('ClusterName')) { $props['ClusterName'] } else { [string]$tc.name }
            ClusterResourceId = if ($props.ContainsKey('ClusterResourceId')) { $props['ClusterResourceId'] } else { '' }
            UpdateName        = if ($props.ContainsKey('UpdateName')) { $props['UpdateName'] } else { '' }
            Properties        = $props
        })
    }

    # 2. Resolve ServiceNow secrets / token --------------------------------
    # In DryRun we still attempt the (read-only) auth + dedupe lookup so the
    # returned Action accurately reflects what would happen on a real run.
    # If auth fails in DryRun we degrade gracefully (no throw) and skip the
    # dedupe lookup; outside DryRun a token-grant failure is a hard error.
    $instanceUrl = $null
    $accessToken = $null
    $authError   = $null
    $sn = $Config.Secrets['servicenow']
    $kv = [string]$Config.Secrets['keyvaultName']
    if (-not $sn) { throw "New-AzLocalIncident: config missing 'secrets.servicenow'." }

    try {
        $instanceUrl  = Resolve-AzLocalItsmSecret -Reference ([string]$sn['instanceUrl'])  -DefaultKeyVault $kv -AllowLiteral
        $clientId     = Resolve-AzLocalItsmSecret -Reference ([string]$sn['clientId'])     -DefaultKeyVault $kv
        $clientSecret = Resolve-AzLocalItsmSecret -Reference ([string]$sn['clientSecret']) -DefaultKeyVault $kv

        $tok = Invoke-AzLocalServiceNowAdapter -Action GetToken `
            -InstanceUrl $instanceUrl -ClientId $clientId -ClientSecret $clientSecret
        $accessToken = $tok.AccessToken
    }
    catch {
        $authError = $_.Exception.Message
        if (-not $DryRun) {
            throw
        }
        Write-Warning "New-AzLocalIncident: DryRun continuing without ServiceNow auth (dedupe lookup will be skipped): $authError"
    }

    # 3. Evaluate triggers + create / dedupe per row ------------------------
    $results = New-Object System.Collections.ArrayList
    $incidentAttempts = 0
    $consecutiveApiFailures = 0
    $defaults = $Config.Defaults
    $titleTemplate = if ($defaults -and $defaults['templates'] -and $defaults['templates']['titleTemplate']) {
        [string]$defaults['templates']['titleTemplate']
    } else {
        '[Azure Local] {{cluster.name}} - {{trigger.category}} ({{run.updateName}})'
    }
    $bodyTemplatePath = if ($defaults -and $defaults['templates'] -and $defaults['templates']['bodyTemplatePath']) {
        Resolve-AzLocalItsmTemplatePath -RawPath ([string]$defaults['templates']['bodyTemplatePath']) -ConfigSourcePath $Config.SourcePath
    } else { $null }

    foreach ($row in $rows) {
        $decision = Get-AzLocalItsmTriggerDecision -Status $row.Status -Triggers $Config.Triggers -Defaults $defaults

        if (-not $decision.ShouldTicket) {
            [void]$results.Add([pscustomobject]@{
                ClusterName       = $row.ClusterName
                ClusterResourceId = $row.ClusterResourceId
                UpdateName        = $row.UpdateName
                Status            = $row.Status
                Action            = 'Skipped'
                Severity          = $null
                TicketId          = $null
                TicketSysId       = $null
                TicketUrl         = $null
                DedupeKey         = $null
                Reason            = $decision.Reason
            })
            continue
        }

        $dedupeInputsValid = -not ([string]::IsNullOrWhiteSpace($row.ClusterResourceId) -or [string]::IsNullOrWhiteSpace($row.UpdateName))
        if (-not $dedupeInputsValid) {
            [void]$results.Add([pscustomobject]@{
                ClusterName       = $row.ClusterName
                ClusterResourceId = $row.ClusterResourceId
                UpdateName        = $row.UpdateName
                Status            = $row.Status
                Action            = 'Skipped'
                Severity          = $null
                TicketId          = $null
                TicketSysId       = $null
                TicketUrl         = $null
                DedupeKey         = $null
                Reason            = "Row missing ClusterResourceId or UpdateName; cannot compute dedupe key. Ensure your JUnit emitter writes both properties on each testcase."
            })
            continue
        }

        $dedupeKey = Get-AzLocalItsmDedupeKey `
            -ClusterResourceId $row.ClusterResourceId `
            -UpdateName        $row.UpdateName `
            -TriggerCategory   $decision.Category

        $context = @{
            cluster = @{
                name        = $row.ClusterName
                resourceId  = $row.ClusterResourceId
            }
            trigger = @{
                category = $decision.Category
                severity = $decision.Severity
                status   = $row.Status
            }
            run = @{
                updateName = $row.UpdateName
                id         = if ($RunMetadata['RunId']) { $RunMetadata['RunId'] } else { '' }
                url        = if ($RunMetadata['RunUrl']) { $RunMetadata['RunUrl'] } else { '' }
                platform   = if ($RunMetadata['Platform']) { $RunMetadata['Platform'] } else { '' }
            }
            message = $row.Message
        }

        $title = Format-AzLocalIncidentBody -Template $titleTemplate -Context $context -NoHtmlEscape
        $body  = if ($bodyTemplatePath) {
            Format-AzLocalIncidentBody -TemplatePath $bodyTemplatePath -Context $context
        } else {
            "Status: {0}`nCluster: {1}`nUpdate: {2}`nRun: {3}`n`n{4}" -f $row.Status, $row.ClusterName, $row.UpdateName, $context.run.url, $row.Message
        }

        $action = 'Created'
        $sysId = $null; $ticketNumber = $null; $ticketUrl = $null
        $existing = $null
        $extraReason = $null

        # Read-only dedupe lookup. Runs in DryRun too (read-only by definition)
        # provided we managed to acquire a token. If the lookup itself fails,
        # we degrade to "treat as new" with a Reason annotation.
        if (-not $ForceCreate -and $accessToken) {
            try {
                $existing = Invoke-AzLocalServiceNowAdapter -Action FindByDedupe `
                    -InstanceUrl $instanceUrl -AccessToken $accessToken -DedupeKey $dedupeKey
            }
            catch {
                $extraReason = "FindByDedupe failed: $($_.Exception.Message)"
                Write-Warning "New-AzLocalIncident: FindByDedupe failed for $($row.ClusterName) / ${dedupeKey}: $($_.Exception.Message)"
            }
        }
        elseif (-not $ForceCreate -and $DryRun -and -not $accessToken) {
            $extraReason = "Dedupe lookup skipped (DryRun, no ServiceNow auth): $authError"
        }

        if ($existing) {
            $action       = 'DedupedToExisting'
            $consecutiveApiFailures = 0
            $sysId        = [string]$existing.sys_id
            $ticketNumber = [string]$existing.number
            $ticketUrl    = "$instanceUrl/nav_to.do?uri=incident.do?sys_id=$sysId"
        }
        elseif ($incidentAttempts -ge $MaxIncidentsPerRun) {
            $action = 'Skipped'
            $extraReason = "Incident creation limit reached ($MaxIncidentsPerRun per run)."
        }
        elseif ($ConsecutiveApiFailureLimit -gt 0 -and $consecutiveApiFailures -ge $ConsecutiveApiFailureLimit) {
            $action = 'Skipped'
            $extraReason = "ServiceNow circuit breaker opened after $consecutiveApiFailures consecutive incident creation failures."
        }
        elseif ($DryRun) {
            $incidentAttempts++
            $action = 'DryRun'
        }
        else {
            $incidentAttempts++
            $impact, $urgency = Get-AzLocalItsmPriorityFromSeverity -Severity $decision.Severity
            $fields = @{
                short_description              = $title
                description                    = $body
                impact                         = $impact
                urgency                        = $urgency
                category                       = $decision.Category
                u_azlocal_dedupe_key           = $dedupeKey
                u_azlocal_cluster_resource_id  = $row.ClusterResourceId
                u_azlocal_update_name          = $row.UpdateName
                u_azlocal_run_id               = [string]$context.run.id
                u_azlocal_source               = 'AzLocal.UpdateManagement'
            }
            if ($defaults['assignmentGroup']) { $fields['assignment_group'] = [string]$defaults['assignmentGroup'] }
            if ($defaults['callerId'])        { $fields['caller_id']        = [string]$defaults['callerId'] }
            if ($defaults['cmdbCi'])          { $fields['cmdb_ci']          = [string]$defaults['cmdbCi'] }

            if ($PSCmdlet.ShouldProcess($row.ClusterName, "Create ServiceNow incident for trigger '$($row.Status)'")) {
                try {
                    $created = Invoke-AzLocalServiceNowAdapter -Action CreateIncident `
                        -InstanceUrl $instanceUrl -AccessToken $accessToken -IncidentFields $fields
                    $sysId        = [string]$created.sys_id
                    $ticketNumber = [string]$created.number
                    $ticketUrl    = "$instanceUrl/nav_to.do?uri=incident.do?sys_id=$sysId"
                    $consecutiveApiFailures = 0
                }
                catch {
                    $action = 'CreateFailed'
                    $consecutiveApiFailures++
                    Write-Warning "New-AzLocalIncident: CreateIncident failed for $($row.ClusterName): $($_.Exception.Message)"
                }
            }
            else {
                $action = 'WhatIf'
            }
        }

        $finalReason = $decision.Reason
        if ($extraReason) {
            $finalReason = "$finalReason | $extraReason"
        }

        [void]$results.Add([pscustomobject]@{
            ClusterName       = $row.ClusterName
            ClusterResourceId = $row.ClusterResourceId
            UpdateName        = $row.UpdateName
            Status            = $row.Status
            Action            = $action
            Severity          = $decision.Severity
            TicketId          = $ticketNumber
            TicketSysId       = $sysId
            TicketUrl         = $ticketUrl
            DedupeKey         = $dedupeKey
            Reason            = $finalReason
        })
    }

    if ($ExportPath) {
        try {
            $exportDir = Split-Path -Path $ExportPath -Parent
            if ($exportDir -and -not (Test-Path -Path $exportDir)) {
                New-Item -Path $exportDir -ItemType Directory -Force | Out-Null
            }
            $results | ConvertTo-SafeCsvCollection | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8 -Force
        }
        catch {
            Write-Warning "New-AzLocalIncident: failed to export results to '$ExportPath': $($_.Exception.Message)"
        }
    }

    if ($ExportJUnitPath) {
        try {
            $junitDir = Split-Path -Path $ExportJUnitPath -Parent
            if ($junitDir -and -not (Test-Path -Path $junitDir)) {
                New-Item -Path $junitDir -ItemType Directory -Force | Out-Null
            }
            # Project ITSM results onto the shape expected by
            # Export-ResultsToJUnitXml: Action becomes the synthetic Status so
            # CreateFailed -> <failure>, Skipped/WhatIf -> <skipped>, and
            # Created / DedupedToExisting / DryRun -> success with system-out.
            $junitRows = @($results | ForEach-Object {
                $syntheticStatus = switch ($_.Action) {
                    'CreateFailed'      { 'Failed' }
                    'WhatIf'            { 'Skipped' }
                    'Skipped'           { 'Skipped' }
                    default             { 'Success' }
                }
                $msgParts = @("ITSM Action: $($_.Action)")
                if ($_.TicketId)     { $msgParts += "Ticket: $($_.TicketId)" }
                if ($_.TicketUrl)    { $msgParts += "Url: $($_.TicketUrl)" }
                if ($_.Status)       { $msgParts += "ClusterStatus: $($_.Status)" }
                if ($_.Severity)     { $msgParts += "Severity: $($_.Severity)" }
                if ($_.DedupeKey)    { $msgParts += "DedupeKey: $($_.DedupeKey)" }
                if ($_.Reason)       { $msgParts += "Reason: $($_.Reason)" }
                [pscustomobject]@{
                    ClusterName  = $_.ClusterName
                    Status       = $syntheticStatus
                    Message      = ($msgParts -join ' | ')
                    UpdateName   = $_.UpdateName
                }
            })
            if ($junitRows.Count -gt 0) {
                Export-ResultsToJUnitXml -Results $junitRows -OutputPath $ExportJUnitPath `
                    -TestSuiteName 'AzureLocalItsm' -OperationType 'IncidentAction'
            } else {
                # Emit an empty suite so dorny/test-reporter still consumes it cleanly.
                $emptyJUnit = "<?xml version=`"1.0`" encoding=`"UTF-8`"?>`n<testsuites>`n  <testsuite name=`"AzureLocalItsm`" tests=`"0`" failures=`"0`" errors=`"0`" skipped=`"0`" time=`"0`" timestamp=`"$(Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')`"></testsuite>`n</testsuites>"
                Set-Content -Path $ExportJUnitPath -Value $emptyJUnit -Encoding UTF8 -Force
            }
        }
        catch {
            Write-Warning "New-AzLocalIncident: failed to export JUnit results to '$ExportJUnitPath': $($_.Exception.Message)"
        }
    }

    return $results
}

function Resolve-AzLocalItsmTemplatePath {
    <#
    .SYNOPSIS
        Resolves a template path from the ITSM config (relative paths
        are resolved against the config file's directory).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$RawPath,
        [Parameter(Mandatory = $true)][string]$ConfigSourcePath
    )
    if ([IO.Path]::IsPathRooted($RawPath)) { return $RawPath }
    $configDir = Split-Path -Path $ConfigSourcePath -Parent
    return (Join-Path $configDir $RawPath)
}

function Get-AzLocalItsmPriorityFromSeverity {
    <#
    .SYNOPSIS
        Maps a 1..5 severity to ServiceNow (impact, urgency) per the design.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1,5)][int]$Severity
    )
    switch ($Severity) {
        1 { return @(1,1) }
        2 { return @(2,2) }
        3 { return @(3,3) }
        4 { return @(4,4) }
        5 { return @(4,4) }
    }
}
