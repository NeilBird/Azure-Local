function Get-AzLocalMonitorSuppressionRuleId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$ClusterResourceId)

    if ($ClusterResourceId -notmatch '^(/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+)/providers/Microsoft\.AzureStackHCI/clusters/[^/?#]+$') {
        throw 'Monitor suppression requires an exact Azure Local cluster resource ID.'
    }
    $resourceGroupId = $Matches[1]
    $hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($ClusterResourceId.ToLowerInvariant()))).Replace('-', '').ToLowerInvariant()
        return "$resourceGroupId/providers/Microsoft.AlertsManagement/actionRules/azlocal-update-$($hash.Substring(0, 32))"
    }
    finally { $hasher.Dispose() }
}

function ConvertTo-AzLocalMonitorSuppressionUtc {
    [CmdletBinding()]
    [OutputType([datetimeoffset])]
    param([Parameter(Mandatory = $true)]$Value)

    if ($Value -is [datetime] -and $Value.Kind -eq [DateTimeKind]::Unspecified) {
        $Value = [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) { return ([datetimeoffset]$Value).ToUniversalTime() }
    return [datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
}

function Invoke-AzLocalMonitorSuppression {
    <#
    .SYNOPSIS
        Creates or reconciles an opt-in, bounded cluster notification suppression.
    .DESCRIPTION
        Owns only a deterministic, exact-cluster RemoveAllActionGroups rule.
        Ensure requires explicit fleet opt-in. Reconcile requires the cluster
        ownership marker, even when the fleet setting has subsequently been disabled.
        Does not change existing alert rules, action groups, or extensions.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Ensure', 'Reconcile')][string]$Action,
        [Parameter(Mandatory = $true)][string]$ClusterResourceId,
        [string]$UpdateName,
        $ClusterTags,
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    $result = [pscustomobject]@{ Status = 'Disabled'; Ready = $false; RuleId = ''; ExpiresUtc = ''; Message = ''; ReportAction = 'Not applicable' }
    if ($Action -eq 'Ensure') {
        $settings = Get-AzLocalFleetSettings
        if (-not $settings.PSObject.Properties['SuppressMonitorNotificationsPerClusterDuringUpdates'] -or
            -not $settings.SuppressMonitorNotificationsPerClusterDuringUpdates) {
            $result.Ready = $true
            return $result
        }
        if ([string]::IsNullOrWhiteSpace($UpdateName) -or $UpdateName -match '[/\\?#]') { throw 'Monitor suppression requires an exact update name.' }
        if ($null -eq $ClusterTags) {
            $clusterRead = Invoke-AzRestJson -Uri "https://management.azure.com$ClusterResourceId`?api-version=$ApiVersion" -Method GET
            if (-not $clusterRead.Ok -or $clusterRead.Data.id -ine $ClusterResourceId) { throw 'Monitor suppression could not verify current cluster tags.' }
            $ClusterTags = $clusterRead.Data.tags
        }
    }
    $marker = Get-TagValue -Tags $ClusterTags -Name 'UpdateMonitorSuppression'
    if ($Action -eq 'Reconcile' -and -not $marker) { return $result }
    $ruleId = Get-AzLocalMonitorSuppressionRuleId -ClusterResourceId $ClusterResourceId
    $result.RuleId = $ruleId
    $uri = "https://management.azure.com$ruleId`?api-version=2021-08-08"
    $read = Invoke-AzRestJson -Uri $uri -Method GET
    $missing = -not $read.Ok -and $read.Error -match '\b(ResourceNotFound|NotFound)\b'
    if (-not $read.Ok -and -not $missing) { throw "Monitor suppression read failed: $($read.Error)" }
    $now = [datetimeoffset]::UtcNow

    if ($missing) {
        if ($Action -eq 'Reconcile') {
            if ($PSCmdlet.ShouldProcess($ClusterResourceId, 'Clear missing maintenance suppression marker')) {
                [void](Set-AzLocalClusterTagsMerge -ClusterResourceId $ClusterResourceId -Tags @{ UpdateMonitorSuppression = $null; UpdateMonitorSuppressionUntil = $null } -ApiVersion $ApiVersion -Confirm:$false)
                $result.ReportAction = 'Marker cleared'
                $result.Message = 'Owned rule was already absent; stale cluster markers cleared.'
            }
            else { $result.ReportAction = 'WhatIf' }
            $result.Status = 'Missing'
            return $result
        }
        if (-not $PSCmdlet.ShouldProcess($ClusterResourceId, 'Create 48-hour notification suppression; defer installation for 30 minutes')) {
            $result.Status = 'WhatIf'
            return $result
        }
        $operationId = [guid]::NewGuid().ToString()
        $createdUtc = $now.ToString('o')
        $expiresUtc = $now.AddHours(48).ToString('o')
        $bodyObject = @{
            location = 'Global'
            tags = @{ ManagedBy = 'AzLocal.UpdateManagement'; ClusterResourceId = $ClusterResourceId; OperationId = $operationId; UpdateName = $UpdateName; CreatedUtc = $createdUtc }
            properties = @{
                enabled = $true
                description = 'AzLocal.UpdateManagement maintenance notification suppression. Do not edit; reconcile through update monitoring.'
                scopes = @($ClusterResourceId)
                actions = @(@{ actionType = 'RemoveAllActionGroups' })
                schedule = @{ effectiveFrom = $now.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss'); effectiveUntil = $now.AddHours(48).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss'); timeZone = 'UTC' }
            }
        }
        if ($settings.PSObject.Properties['RenewMonitorSuppressionDuringUpdates'] -and $settings.RenewMonitorSuppressionDuringUpdates) {
            $bodyObject.tags.RenewalMaxExpiresUtc = $now.AddHours($settings.MonitorSuppressionMaxTotalHours).ToString('o')
            $bodyObject.tags.RenewalExpiresUtc = $expiresUtc
        }
        $body = $bodyObject | ConvertTo-Json -Depth 8 -Compress
        [void](Set-AzLocalClusterTagsMerge -ClusterResourceId $ClusterResourceId -Tags @{ UpdateMonitorSuppression = $operationId; UpdateMonitorSuppressionUntil = $expiresUtc } -ApiVersion $ApiVersion -Confirm:$false)
        $write = Invoke-AzRestJson -Uri $uri -Method PUT -Body $body
        if (-not $write.Ok) { throw "Monitor suppression creation failed; update not started. Reconciliation will retry cleanup: $($write.Error)" }
        $result.Status = 'SuppressionPending'
        $result.ExpiresUtc = $expiresUtc
        $result.Message = 'Notification suppression created. Installation deferred for at least 30 minutes; a later eligible apply run must recheck all update gates.'
        return $result
    }

    $rule = $read.Data
    if (-not $rule -or $rule.id -ine $ruleId -or
        (Get-TagValue -Tags $rule.tags -Name 'ManagedBy') -cne 'AzLocal.UpdateManagement' -or
        (Get-TagValue -Tags $rule.tags -Name 'ClusterResourceId') -ine $ClusterResourceId -or
        @($rule.properties.scopes).Count -ne 1 -or $rule.properties.scopes[0] -ine $ClusterResourceId -or
        @($rule.properties.actions).Count -ne 1 -or $rule.properties.actions[0].actionType -ne 'RemoveAllActionGroups' -or
        ($rule.properties.conditions -and @($rule.properties.conditions).Count -gt 0) -or
        ($rule.properties.schedule.recurrences -and @($rule.properties.schedule.recurrences).Count -gt 0) -or
        $rule.properties.schedule.timeZone -ne 'UTC') {
        throw "Monitor suppression ownership or configuration mismatch at '$ruleId'; no resource was changed."
    }
    $operationId = Get-TagValue -Tags $rule.tags -Name 'OperationId'
    $operationGuid = [guid]::Empty
    if (-not [guid]::TryParse($operationId, [ref]$operationGuid) -or ($marker -and $marker -ne $operationId)) {
        throw 'Monitor suppression operation marker mismatch; no resource was changed.'
    }
    $created = ConvertTo-AzLocalMonitorSuppressionUtc -Value $rule.tags.CreatedUtc
    $start = ConvertTo-AzLocalMonitorSuppressionUtc -Value $rule.properties.schedule.effectiveFrom
    $expiry = ConvertTo-AzLocalMonitorSuppressionUtc -Value $rule.properties.schedule.effectiveUntil
    $renewalLimit = $null
    $expectedExpiry = $created.AddHours(48)
    $hasRenewalExpiry = Get-TagValue -Tags $rule.tags -Name 'RenewalExpiresUtc'
    $hasRenewalLimit = Get-TagValue -Tags $rule.tags -Name 'RenewalMaxExpiresUtc'
    if ($hasRenewalExpiry -or $hasRenewalLimit) {
        if (-not $hasRenewalExpiry -or -not $hasRenewalLimit) { throw 'Monitor suppression renewal metadata is incomplete; manual review is required.' }
        $expectedExpiry = ConvertTo-AzLocalMonitorSuppressionUtc -Value $rule.tags.RenewalExpiresUtc
        $renewalLimit = ConvertTo-AzLocalMonitorSuppressionUtc -Value $rule.tags.RenewalMaxExpiresUtc
        if ($renewalLimit -lt $created.AddHours(49) -or $renewalLimit -gt $created.AddHours(720) -or
            $expectedExpiry -lt $created.AddHours(48).AddSeconds(-1) -or $expectedExpiry -gt $renewalLimit) {
            throw 'Monitor suppression renewal exceeds its bounded maximum; manual review is required.'
        }
    }
    if ([math]::Abs(($start - $created).TotalSeconds) -gt 1 -or [math]::Abs(($expiry - $expectedExpiry).TotalSeconds) -gt 1) {
        throw 'Monitor suppression schedule was changed; manual review is required.'
    }
    $ownedUpdate = Get-TagValue -Tags $rule.tags -Name 'UpdateName'
    if ([string]::IsNullOrWhiteSpace($ownedUpdate) -or $ownedUpdate -match '[/\\?#]') { throw 'Monitor suppression has an invalid update identity.' }
    $result.ExpiresUtc = $expiry.ToString('o')

    if ($Action -eq 'Ensure') {
        if ($ownedUpdate -ine $UpdateName -or $rule.properties.enabled -ne $true -or $expiry -le $now.AddMinutes(30)) {
            throw 'Monitor suppression is disabled, expired, near expiry, or belongs to another update. Run update monitoring to reconcile it before retrying.'
        }
        if (-not $marker) {
            if (-not $PSCmdlet.ShouldProcess($ClusterResourceId, 'Recover owned maintenance suppression marker')) { $result.Status = 'WhatIf'; return $result }
            [void](Set-AzLocalClusterTagsMerge -ClusterResourceId $ClusterResourceId -Tags @{ UpdateMonitorSuppression = $operationId; UpdateMonitorSuppressionUntil = $expiry.ToString('o') } -ApiVersion $ApiVersion -Confirm:$false)
        }
        $reconcileTags = @{
            UpdateMonitorSuppression = $operationId
            UpdateRetryAttempted = Get-TagValue -Tags $ClusterTags -Name 'UpdateRetryAttempted'
        }
        $reconciled = Invoke-AzLocalMonitorSuppression -Action Reconcile -ClusterResourceId $ClusterResourceId -ClusterTags $reconcileTags -ApiVersion $ApiVersion
        if ($reconciled.Status -eq 'SuppressionRemoved') {
            $result.Status = 'SuppressionPending'
            $result.Message = 'Previous update attempt completed; suppression removed. Retry on a later firing to establish a fresh maintenance window.'
            return $result
        }
        if ($reconciled.Status -ne 'SuppressionActive') {
            $result.Status = 'SuppressionPending'
            $result.Message = 'Suppression could not be confirmed after reconciliation. Installation deferred; retry on a later eligible firing.'
            return $result
        }
        $result.ExpiresUtc = $reconciled.ExpiresUtc
        $result.Ready = $now -ge $created.AddMinutes(30)
        $result.Status = if ($result.Ready) { 'SuppressionActive' } else { 'SuppressionPending' }
        $result.Message = "Maintenance notification suppression: $($result.Status); expires $($result.ExpiresUtc)."
        return $result
    }

    $shouldRemove = $now -ge $expiry
    $removalReason = 'Suppression window expired.'
    if (-not $shouldRemove) {
        $runs = @(Get-AzLocalClusterUpdateRuns -resourceId $ClusterResourceId -updateNameFilter $ownedUpdate -apiVer $ApiVersion)
        $matchingRuns = @($runs | Where-Object {
            $_.properties.timeStarted -and (ConvertTo-AzLocalMonitorSuppressionUtc -Value $_.properties.timeStarted) -ge $created
        } | Sort-Object { ConvertTo-AzLocalMonitorSuppressionUtc -Value $_.properties.timeStarted } -Descending)
        if ($matchingRuns.Count -eq 0) {
            $retryAttempt = ConvertFrom-AzLocalUpdateLastAttemptTagValue -Value (Get-TagValue -Tags $ClusterTags -Name 'UpdateRetryAttempted')
            if ($retryAttempt -and $retryAttempt.Outcome -eq 'RetryStarted' -and $retryAttempt.UpdateName -ieq $ownedUpdate -and
                $retryAttempt.AttemptUtc -ge $created.UtcDateTime -and $retryAttempt.AttemptUtc -le $now.UtcDateTime) {
                $latestRun = $runs | Where-Object { $_.properties.timeStarted } |
                    Sort-Object { ConvertTo-AzLocalMonitorSuppressionUtc -Value $_.properties.timeStarted } -Descending | Select-Object -First 1
                if ($latestRun) {
                    $runProperties = if ($latestRun.properties -is [System.Collections.IDictionary]) { [pscustomobject]$latestRun.properties } else { $latestRun.properties }
                    if ($runProperties.PSObject.Properties['lastUpdatedTime'] -and $runProperties.lastUpdatedTime) {
                        $lastUpdated = ConvertTo-AzLocalMonitorSuppressionUtc -Value $runProperties.lastUpdatedTime
                        if ($lastUpdated.UtcDateTime -ge $retryAttempt.AttemptUtc -and $lastUpdated -le $now) {
                            $matchingRuns = @($latestRun)
                        }
                    }
                }
            }
        }
        if ($matchingRuns.Count -gt 0) {
            $unfinished = @($matchingRuns | Where-Object { $_.properties.state -notin @('Succeeded', 'Failed', 'Canceled', 'Cancelled') })
            $shouldRemove = $unfinished.Count -eq 0
            if ($shouldRemove) { $removalReason = 'All matching update runs are terminal (Succeeded, Failed, or Canceled).' }
        }
    }
    if (-not $shouldRemove) {
        $result.ReportAction = if ($rule.properties.enabled -eq $true) { 'Active / Unchanged' } else { 'Disabled rule' }
        $activeRuns = @($matchingRuns | Where-Object {
            $_.properties.state -eq 'InProgress' -and
            (ConvertTo-AzLocalMonitorSuppressionUtc -Value $_.properties.timeStarted) -le $now
        })
        if ($rule.properties.enabled -eq $true -and $activeRuns.Count -gt 0 -and $expiry -le $now.AddHours(6)) {
            $settings = Get-AzLocalFleetSettings
            if ($settings.PSObject.Properties['SuppressMonitorNotificationsPerClusterDuringUpdates'] -and
                $settings.SuppressMonitorNotificationsPerClusterDuringUpdates -and
                $settings.PSObject.Properties['RenewMonitorSuppressionDuringUpdates'] -and $settings.RenewMonitorSuppressionDuringUpdates) {
                $configuredLimit = $created.AddHours($settings.MonitorSuppressionMaxTotalHours)
                if ($null -eq $renewalLimit -or $configuredLimit -lt $renewalLimit) { $renewalLimit = $configuredLimit }
                $newExpiry = $now.AddHours(48)
                if ($newExpiry -gt $renewalLimit) { $newExpiry = $renewalLimit }
                if (($newExpiry - $expiry).TotalSeconds -gt 1) {
                    if (-not $PSCmdlet.ShouldProcess($ruleId, "Renew maintenance suppression until $($newExpiry.ToString('o'))")) {
                        $result.Status = 'WhatIf'
                        $result.ReportAction = 'WhatIf'
                        return $result
                    }
                    $renewalTags = @{}
                    $tagObject = if ($rule.tags -is [System.Collections.IDictionary]) { [pscustomobject]$rule.tags } else { $rule.tags }
                    foreach ($property in $tagObject.PSObject.Properties) { $renewalTags[$property.Name] = $property.Value }
                    $renewalTags.CreatedUtc = $created.ToString('o')
                    $renewalTags.RenewalMaxExpiresUtc = $renewalLimit.ToString('o')
                    $renewalTags.RenewalExpiresUtc = $newExpiry.ToString('o')
                    $renewalBody = @{
                        location = 'Global'
                        tags = $renewalTags
                        properties = @{
                            enabled = $true
                            description = $rule.properties.description
                            scopes = @($ClusterResourceId)
                            actions = @(@{ actionType = 'RemoveAllActionGroups' })
                            schedule = @{ effectiveFrom = $start.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss'); effectiveUntil = $newExpiry.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss'); timeZone = 'UTC' }
                        }
                    } | ConvertTo-Json -Depth 8 -Compress
                    $write = Invoke-AzRestJson -Uri $uri -Method PUT -Body $renewalBody
                    if (-not $write.Ok) { throw "Monitor suppression renewal failed; reread the rule before retrying: $($write.Error)" }
                    [void](Set-AzLocalClusterTagsMerge -ClusterResourceId $ClusterResourceId -Tags @{ UpdateMonitorSuppressionUntil = $newExpiry.ToString('o') } -ApiVersion $ApiVersion -Confirm:$false)
                    $result.ExpiresUtc = $newExpiry.ToString('o')
                    $result.Status = 'SuppressionActive'
                    $result.ReportAction = 'Extended'
                    $result.Message = "Maintenance notification suppression renewed until $($result.ExpiresUtc); maximum $($renewalLimit.ToString('o'))."
                    return $result
                }
                $result.ReportAction = 'Limit reached'
            }
        }
        if ($hasRenewalExpiry) {
            $markerExpiry = Get-TagValue -Tags $ClusterTags -Name 'UpdateMonitorSuppressionUntil'
            $markerNeedsSync = $true
            if ($markerExpiry) {
                try {
                    $markerNeedsSync = [math]::Abs(((ConvertTo-AzLocalMonitorSuppressionUtc -Value $ClusterTags.UpdateMonitorSuppressionUntil) - $expiry).TotalSeconds) -gt 1
                }
                catch { $markerNeedsSync = $true }
            }
            if ($markerNeedsSync) {
                if ($PSCmdlet.ShouldProcess($ClusterResourceId, 'Synchronize renewed maintenance suppression expiry marker')) {
                    [void](Set-AzLocalClusterTagsMerge -ClusterResourceId $ClusterResourceId -Tags @{ UpdateMonitorSuppressionUntil = $expiry.ToString('o') } -ApiVersion $ApiVersion -Confirm:$false)
                }
            }
        }
        $result.Status = 'SuppressionActive'
        $result.Message = "Awaiting a matching terminal update run; current suppression expiry $($result.ExpiresUtc)."
        if ($result.ReportAction -eq 'Limit reached') { $result.Message = "No further extension permitted by the total-duration limit; current expiry $($result.ExpiresUtc)." }
        elseif ($result.ReportAction -eq 'Disabled rule') { $result.Message = "Owned rule is disabled; notifications are not suppressed. Current expiry $($result.ExpiresUtc)." }
        return $result
    }
    if ($PSCmdlet.ShouldProcess($ruleId, 'Delete owned maintenance suppression and clear cluster markers')) {
        $delete = Invoke-AzRestJson -Uri $uri -Method DELETE
        if (-not $delete.Ok) { throw "Monitor suppression cleanup failed; markers retained for retry: $($delete.Error)" }
        [void](Set-AzLocalClusterTagsMerge -ClusterResourceId $ClusterResourceId -Tags @{ UpdateMonitorSuppression = $null; UpdateMonitorSuppressionUntil = $null } -ApiVersion $ApiVersion -Confirm:$false)
        $result.Status = 'SuppressionRemoved'
        $result.ReportAction = 'Removed'
        $result.Message = "$removalReason Owned maintenance suppression removed. Existing alert rules and processing rules were not changed."
    }
    else { $result.Status = 'WhatIf'; $result.ReportAction = 'WhatIf' }
    return $result
}