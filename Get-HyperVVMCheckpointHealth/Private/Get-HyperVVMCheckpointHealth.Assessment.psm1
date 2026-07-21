Set-StrictMode -Version Latest

function Get-HyperVEventPolicy {
    [OutputType([pscustomobject])]
    param()

    [pscustomobject]@{
        CriticalIds         = @(3216)
        OperationFailureIds = @(18012, 19100, 16300)
        LowSignalIds        = @(3280, 12240, 15268, 19090, 32510)
        ContextIds          = @(18500, 18510, 19070, 19080)
        MergeFailureIds     = @(19090, 19100, 32510)
        MergeSuccessIds     = @(19080)
        ForkCommitHResults  = @('0x80048102', '0x800703EE')
        LeadingHResults     = @('0x800480BD', '0x800480BC')
        SymptomHResults     = @('0x80070020', '0x80070002')
    }
}

function Get-HyperVEventSignalAssessment {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][int]$EventId,
        [AllowEmptyString()][string]$Log,
        [AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)]$Policy
    )

    $hasCheckpointContext = ($Message -match '(?i)checkpoint|differencing|fork|virtual\s+hard\s+disk|\bvhdx?\b')
    $hasCommitForkError = ($Message -match [regex]::Escape('0x80048102'))
    $hasFileInvalid = ($Message -match [regex]::Escape('0x800703EE'))
    $isContextual3216 = (($EventId -eq 3216) -and ($Log -eq 'Worker') -and $hasCheckpointContext)
    $isConfirming = ($hasCommitForkError -or $isContextual3216 -or ($hasFileInvalid -and $hasCheckpointContext))
    $hasLeadingCode = @($Policy.LeadingHResults | Where-Object { $Message -match [regex]::Escape($_) }).Count -gt 0
    $hasSymptomCode = @($Policy.SymptomHResults | Where-Object { $Message -match [regex]::Escape($_) }).Count -gt 0
    $role = if ($isConfirming) { 'Confirming' } elseif ($hasLeadingCode) { 'Leading' } elseif (($Policy.OperationFailureIds -contains $EventId) -or ($Policy.LowSignalIds -contains $EventId) -or $hasSymptomCode) { 'Operational' } elseif ($Policy.ContextIds -contains $EventId) { 'Context' } else { 'Other' }
    [pscustomobject]@{ Role = $role; IsConfirmingFork = [bool]$isConfirming; HasCheckpointContext = [bool]$hasCheckpointContext }
}

function Resolve-HyperVOperationRecovery {
    [OutputType([pscustomobject])]
    param(
        [object[]]$Events = @(),
        [int[]]$FailureIds = @(18012, 19100, 16300),
        [int[]]$CompletionIds = @(19080),
        [int[]]$CompletionEligibleFailureIds = @(19100),
        [ValidateRange(1, 1440)][int]$MaxMinutes = 30
    )

    $failures = @($Events | Where-Object { $FailureIds -contains [int]$_.Id } | Sort-Object 'Time (UTC)')
    $completions = @($Events | Where-Object { $CompletionIds -contains [int]$_.Id } | Sort-Object 'Time (UTC)')
    if ($failures.Count -eq 0) { return [pscustomobject]@{ Status = 'NotApplicable'; FailureCount = 0; CompletionCount = $completions.Count; CausalMatchCount = 0; ApparentMatchCount = 0; UnresolvedCount = 0 } }
    $causalMatchCount = 0
    $apparentMatchCount = 0
    $unresolvedCount = 0
    $evidencePattern = '(?i)(?:[a-z]:\\[^\r\n|"''<>]+?\.(?:avhdx|vhdx|vhd)|(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f]))'
    foreach ($failure in $failures) {
        if ($CompletionEligibleFailureIds -notcontains [int]$failure.Id) { $unresolvedCount++; continue }
        try { $failureTime = [datetime]::ParseExact([string]$failure.'Time (UTC)', 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal) } catch { $unresolvedCount++; continue }
        $boundedCompletions = @($completions | Where-Object {
            try {
                $completionTime = [datetime]::ParseExact([string]$_.'Time (UTC)', 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
                ($completionTime -ge $failureTime) -and ($completionTime -le $failureTime.AddMinutes($MaxMinutes))
            } catch { $false }
        })
        if ($boundedCompletions.Count -eq 0) { $unresolvedCount++; continue }
        $failureKeys = @([regex]::Matches([string]$failure.FullMessage, $evidencePattern) | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
        $causalCompletion = @($boundedCompletions | Where-Object {
            $completionKeys = @([regex]::Matches([string]$_.FullMessage, $evidencePattern) | ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
            @($failureKeys | Where-Object { $completionKeys -contains $_ }).Count -gt 0
        } | Select-Object -First 1)
        if ($failureKeys.Count -gt 0 -and $causalCompletion.Count -gt 0) { $causalMatchCount++ } else { $apparentMatchCount++ }
    }
    $status = if ($unresolvedCount -gt 0) { 'Unresolved' } elseif ($causalMatchCount -eq $failures.Count) { 'ConfirmedRecovered' } else { 'ApparentlyRecovered' }
    [pscustomobject]@{ Status = $status; FailureCount = $failures.Count; CompletionCount = $completions.Count; CausalMatchCount = $causalMatchCount; ApparentMatchCount = $apparentMatchCount; UnresolvedCount = $unresolvedCount }
}

function Compare-VMCollectionStateToken {
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$StartToken, [Parameter(Mandatory)]$EndToken)
    $reasons = [System.Collections.Generic.List[string]]::new()
    if (-not ([string]$StartToken.OwnerNode).Equals([string]$EndToken.OwnerNode, [StringComparison]::OrdinalIgnoreCase)) { [void]$reasons.Add('OwnerNode') }
    if (-not ([string]$StartToken.State).Equals([string]$EndToken.State, [StringComparison]::OrdinalIgnoreCase)) { [void]$reasons.Add('State') }
    if ([int]$StartToken.CheckpointCount -ne [int]$EndToken.CheckpointCount) { [void]$reasons.Add('CheckpointCount') }
    $startPaths = @($StartToken.DiskPaths | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    $endPaths = @($EndToken.DiskPaths | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    if (($startPaths -join "`n") -ne ($endPaths -join "`n")) { [void]$reasons.Add('DiskPaths') }
    if ([string]$StartToken.ConfigLastWriteUtc -ne [string]$EndToken.ConfigLastWriteUtc) { [void]$reasons.Add('ConfigLastWriteUtc') }
    [pscustomobject]@{ Changed = ($reasons.Count -gt 0); Reasons = $reasons.ToArray() }
}

function Get-HyperVReplicationAssessment {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][bool]$Enabled,
        [AllowEmptyString()][string]$State,
        [AllowEmptyString()][string]$Health,
        [AllowEmptyString()][string]$Mode,
        [bool]$MeasurementsAvailable = $false,
        [datetime]$LastReplicationTimeUtc = [datetime]::MinValue,
        [long]$PendingBytes = 0,
        [double]$LatencySeconds = 0,
        [long]$MissedCount = 0,
        [double]$FrequencySeconds = 0,
        [long]$AverageReplicationBytes = 0,
        [long]$SuccessfulCount = -1,
        [double]$MonitoringIntervalSeconds = 0,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$MaxAgeMinutes = 60,
        [long]$MaxPendingMB = 1024,
        [int]$MaxLatencySeconds = 300,
        [int]$MaxMissedCount = 0,
        [double]$MaxAgeCycles = 12,
        [double]$MaxPendingCycles = 2,
        [double]$MaxLatencyCycles = 2,
        [double]$MaxMissedRatePercent = 10,
        [long]$MinMissedCountForConcern = 3
    )
    if (-not $Enabled) {
        return [pscustomobject]@{
            Severity = 'NotApplicable'; ProductSeverity = 'NotApplicable'; MeasurementStatus = 'NotApplicable'
            IsConcern = $false; HasAdvisory = $false; IsCritical = $false
            State = $State; Health = $Health; Mode = $Mode; Reason = 'Hyper-V Replica is disabled.'
            ThresholdBreaches = @(); ConcernBreaches = @(); AdvisoryBreaches = @(); MeasurementsAvailable = $false
        }
    }
    $normalizedHealth = $Health.Trim()
    $normalizedState = $State.Trim()
    $productSeverity = switch ($normalizedHealth.ToLowerInvariant()) { 'critical' { 'Critical'; break } 'warning' { 'Warning'; break } 'normal' { if ($normalizedState) { 'Healthy' } else { 'Unknown' }; break } default { 'Unknown' } }
    $thresholdBreaches = [System.Collections.Generic.List[string]]::new()
    $concernBreaches = [System.Collections.Generic.List[string]]::new()
    $advisoryBreaches = [System.Collections.Generic.List[string]]::new()
    $effectiveAgeMinutes = [double]$MaxAgeMinutes
    $effectivePendingBytes = [long]($MaxPendingMB * 1MB)
    $effectiveLatencySeconds = [double]$MaxLatencySeconds
    if ($FrequencySeconds -gt 0) {
        $effectiveAgeMinutes = [math]::Max($effectiveAgeMinutes, (($FrequencySeconds * $MaxAgeCycles) / 60.0))
        $effectiveLatencySeconds = [math]::Max($effectiveLatencySeconds, ($FrequencySeconds * $MaxLatencyCycles))
    }
    if ($AverageReplicationBytes -gt 0) {
        $relativePendingBytes = [double]$AverageReplicationBytes * $MaxPendingCycles
        if ($relativePendingBytes -gt $effectivePendingBytes) { $effectivePendingBytes = [long][math]::Ceiling($relativePendingBytes) }
    }
    $lastReplicationAgeMinutes = $null
    $missedRatePercent = $null
    if ($MeasurementsAvailable) {
        if ($LastReplicationTimeUtc -ne [datetime]::MinValue) {
            $lastReplicationAgeMinutes = ($NowUtc.ToUniversalTime() - $LastReplicationTimeUtc.ToUniversalTime()).TotalMinutes
            if ($lastReplicationAgeMinutes -gt $MaxAgeMinutes) {
                [void]$thresholdBreaches.Add('LastReplicationAge')
                if ($lastReplicationAgeMinutes -gt $effectiveAgeMinutes) { [void]$concernBreaches.Add('LastReplicationAge') } else { [void]$advisoryBreaches.Add('LastReplicationAge') }
            }
        }
        if ($PendingBytes -gt ($MaxPendingMB * 1MB)) {
            [void]$thresholdBreaches.Add('PendingBytes')
            if ($PendingBytes -gt $effectivePendingBytes) { [void]$concernBreaches.Add('PendingBytes') } else { [void]$advisoryBreaches.Add('PendingBytes') }
        }
        if ($LatencySeconds -gt $MaxLatencySeconds) {
            [void]$thresholdBreaches.Add('Latency')
            if ($LatencySeconds -gt $effectiveLatencySeconds) { [void]$concernBreaches.Add('Latency') } else { [void]$advisoryBreaches.Add('Latency') }
        }
        if ($MissedCount -gt $MaxMissedCount) {
            [void]$thresholdBreaches.Add('MissedCount')
            $totalMeasuredCount = $SuccessfulCount + $MissedCount
            if ($SuccessfulCount -ge 0 -and $totalMeasuredCount -gt 0) { $missedRatePercent = (100.0 * $MissedCount) / $totalMeasuredCount }
            $missedIsConcern = ($MissedCount -ge $MinMissedCountForConcern) -and (($null -eq $missedRatePercent) -or ($missedRatePercent -gt $MaxMissedRatePercent))
            if ($missedIsConcern) { [void]$concernBreaches.Add('MissedCount') } else { [void]$advisoryBreaches.Add('MissedCount') }
        }
    }
    $measurementStatus = if ($concernBreaches.Count -gt 0) { 'Concern' } elseif ($advisoryBreaches.Count -gt 0) { 'Advisory' } elseif ($MeasurementsAvailable) { 'Healthy' } else { 'Unavailable' }
    $severity = if ($productSeverity -eq 'Healthy' -and $measurementStatus -eq 'Concern') { 'Warning' } else { $productSeverity }
    $isConcern = ($productSeverity -in @('Critical', 'Warning', 'Unknown')) -or ($measurementStatus -eq 'Concern')
    [pscustomobject]@{
        Severity = $severity; ProductSeverity = $productSeverity; MeasurementStatus = $measurementStatus
        IsConcern = $isConcern; HasAdvisory = ($measurementStatus -eq 'Advisory'); IsCritical = ($productSeverity -eq 'Critical')
        State = $normalizedState; Health = $normalizedHealth; Mode = $Mode.Trim()
        MeasurementsAvailable = $MeasurementsAvailable; LastReplicationTimeUtc = $LastReplicationTimeUtc
        LastReplicationAgeMinutes = $lastReplicationAgeMinutes
        PendingBytes = $PendingBytes; LatencySeconds = $LatencySeconds; MissedCount = $MissedCount
        FrequencySeconds = $FrequencySeconds; AverageReplicationBytes = $AverageReplicationBytes
        SuccessfulCount = $SuccessfulCount; MissedRatePercent = $missedRatePercent
        MonitoringIntervalSeconds = $MonitoringIntervalSeconds
        EffectiveMaxAgeMinutes = $effectiveAgeMinutes; EffectiveMaxPendingBytes = $effectivePendingBytes
        EffectiveMaxLatencySeconds = $effectiveLatencySeconds; MaxMissedRatePercent = $MaxMissedRatePercent
        ThresholdBreaches = $thresholdBreaches.ToArray()
        ConcernBreaches = $concernBreaches.ToArray(); AdvisoryBreaches = $advisoryBreaches.ToArray()
        Reason = if ($productSeverity -eq 'Critical') { 'Hyper-V Replica health is Critical.' } elseif ($productSeverity -eq 'Warning') { 'Hyper-V Replica health is Warning.' } elseif ($productSeverity -eq 'Unknown') { 'Hyper-V Replica is enabled but health or state evidence is unavailable.' } elseif ($measurementStatus -eq 'Concern') { 'Hyper-V Replica measurements materially exceed effective relationship-aware limits.' } elseif ($measurementStatus -eq 'Advisory') { 'Hyper-V Replica reports Normal health with measurement drift that warrants observation.' } else { 'Hyper-V Replica reports Normal health with an available state.' }
    }
}

function Resolve-HyperVEventAttribution {
    [OutputType([pscustomobject])]
    param([AllowEmptyString()][string]$Message, [AllowEmptyString()][string]$VMName, [AllowEmptyString()][string]$VMId)
    $normalizedTargetId = $VMId.Trim().Trim('{', '}', '(', ')')
    $guidPattern = '(?i)(?<![0-9a-f])[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(?![0-9a-f])'
    $guidMatches = [regex]::Matches($Message, $guidPattern)
    if ($guidMatches.Count -gt 0) {
        $attributed = $false
        foreach ($guidMatch in $guidMatches) { if ($normalizedTargetId -and $guidMatch.Value.Equals($normalizedTargetId, [StringComparison]::OrdinalIgnoreCase)) { $attributed = $true; break } }
        return [pscustomobject]@{ Attributed = $attributed; Method = 'StructuredGuid'; Confidence = 'High'; StructuredIdentifierPresent = $true }
    }
    $namePattern = '(?i)\b(?:virtual\s+machine|vm)\s+(?:name\s*[:=]?\s*)?[''\"](?<Name>[^''\"]+)[''\"]'
    $nameMatches = [regex]::Matches($Message, $namePattern)
    if ($nameMatches.Count -gt 0) {
        $attributed = $false
        foreach ($nameMatch in $nameMatches) { if ($VMName -and $nameMatch.Groups['Name'].Value.Equals($VMName, [StringComparison]::OrdinalIgnoreCase)) { $attributed = $true; break } }
        return [pscustomobject]@{ Attributed = $attributed; Method = 'StructuredName'; Confidence = 'High'; StructuredIdentifierPresent = $true }
    }
    $fallbackAttributed = $false
    if ($VMName) { $boundedNamePattern = '(?i)(?<![\p{L}\p{N}_\\/-])' + [regex]::Escape($VMName) + '(?![\p{L}\p{N}_\\/-])'; $fallbackAttributed = [regex]::IsMatch($Message, $boundedNamePattern) }
    [pscustomobject]@{ Attributed = $fallbackAttributed; Method = 'BoundedNameFallback'; Confidence = if ($fallbackAttributed) { 'Low' } else { 'None' }; StructuredIdentifierPresent = $false }
}

function Resolve-EventCoverage {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CoverageRows,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedNodes,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExpectedChannels,
        [Parameter(Mandatory)][datetime]$EarliestWindowStart
    )
    $rowsByKey = @{}
    foreach ($row in @($CoverageRows)) { if (-not $row) { continue }; $node = [string]$row.Node; $channel = [string]$row.Channel; if (-not $node -or -not $channel) { continue }; $rowsByKey[("{0}|{1}" -f $node.ToLowerInvariant(), $channel.ToLowerInvariant())] = $row }
    $assessmentRows = [System.Collections.Generic.List[object]]::new()
    foreach ($node in @($ExpectedNodes | Where-Object { $_ } | Sort-Object -Unique)) {
        foreach ($channel in @($ExpectedChannels | Where-Object { $_ } | Sort-Object -Unique)) {
            $key = "{0}|{1}" -f $node.ToLowerInvariant(), $channel.ToLowerInvariant()
            $row = if ($rowsByKey.ContainsKey($key)) { $rowsByKey[$key] } else { $null }
            $querySucceeded = [bool]($row -and $row.QuerySucceeded)
            $enablementKnown = [bool]($row -and $row.PSObject.Properties['IsEnabled'] -and ($row.IsEnabled -is [bool]))
            $isEnabled = if ($enablementKnown) { [bool]$row.IsEnabled } else { $false }
            $oldest = if ($row -and $row.OldestAvailable) { [datetime]$row.OldestAvailable } else { $null }
            $status = if (-not $row -or -not $querySucceeded) { 'Unavailable' } elseif (-not $enablementKnown) { 'Unavailable' } elseif (-not $isEnabled) { 'Disabled' } elseif (-not $oldest) { 'EnabledEmpty' } elseif ($oldest.ToUniversalTime() -gt $EarliestWindowStart.ToUniversalTime()) { 'Wrapped' } else { 'Covered' }
            $sufficient = ($status -in @('Covered', 'EnabledEmpty'))
            [void]$assessmentRows.Add([pscustomobject]@{ Node = [string]$node; Channel = [string]$channel; Status = $status; Sufficient = [bool]$sufficient; QuerySucceeded = $querySucceeded; IsEnabled = if ($enablementKnown) { $isEnabled } else { $null }; OldestAvailable = $oldest; Error = if ($row -and $row.Error) { [string]$row.Error } elseif (-not $row) { 'Coverage row was not returned.' } elseif (-not $enablementKnown) { 'Channel enablement state was not returned.' } else { '' } })
        }
    }
    $rows = $assessmentRows.ToArray()
    $complete = ($rows.Count -gt 0 -and @($rows | Where-Object { -not $_.Sufficient }).Count -eq 0)
    [pscustomobject]@{ Complete = [bool]$complete; OverallStatus = if ($complete) { 'Covered' } else { 'Incomplete' }; Rows = $rows; CoveredCount = @($rows | Where-Object Status -eq 'Covered').Count; WrappedCount = @($rows | Where-Object Status -eq 'Wrapped').Count; EnabledEmptyCount = @($rows | Where-Object Status -eq 'EnabledEmpty').Count; DisabledCount = @($rows | Where-Object Status -eq 'Disabled').Count; UnavailableCount = @($rows | Where-Object Status -eq 'Unavailable').Count }
}

function Get-VMCheckpointVerdictAssessment {
    [OutputType([pscustomobject])]
    param(
        [bool]$ConfirmingForkSignature,
        [bool]$HasAttachedLayers,
        [bool]$HasIncompleteChain,
        [bool]$HasStaleEvidence,
        [bool]$SnapshotLayerMismatch,
        [bool]$HasOrphans,
        [bool]$VssUnhealthy,
        [bool]$ReplicationConcern,
        [bool]$StorageConcern,
        [int]$EscalatingEventCount,
        [bool]$RequiredEvidenceUnavailable,
        [bool]$StateInconclusive
    )

    $holdState = ($ConfirmingForkSignature -and $HasAttachedLayers)
    $investigate = ((-not $holdState) -and ($HasIncompleteChain -or $HasStaleEvidence -or
        $SnapshotLayerMismatch -or $HasOrphans -or $VssUnhealthy -or $ReplicationConcern -or $StorageConcern -or
        ($EscalatingEventCount -gt 0) -or $RequiredEvidenceUnavailable -or $StateInconclusive))
    [pscustomobject]@{
        HoldState = [bool]$holdState
        Investigate = [bool]$investigate
        Recommendation = if ($holdState) { 'HOLD STATE' } elseif ($investigate) { 'INVESTIGATE' } else { 'OK' }
    }
}

function Select-DiscoveredVMsForAudit {
    [OutputType([pscustomobject])]
    param(
        [object[]]$Candidates,
        [Nullable[int]]$Maximum
    )

    if ($null -ne $Maximum -and ($Maximum -lt 1 -or $Maximum -gt 1000)) {
        throw 'Maximum must be between 1 and 1000 when specified.'
    }

    $byName = @{}
    foreach ($candidate in @($Candidates)) {
        if (-not $candidate -or -not $candidate.Name) { continue }
        $name = [string]$candidate.Name
        $key = $name.ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) {
            $byName[$key] = [pscustomobject]@{
                Name    = $name
                Reasons = [System.Collections.Generic.List[string]]::new()
                Score   = 0
            }
        }

        $reason = [string]$candidate.Reason
        if ($reason -and -not $byName[$key].Reasons.Contains($reason)) {
            [void]$byName[$key].Reasons.Add($reason)
        }
        $reasonScore = if ($reason -match 'fork|3216|0x80048102') {
            400
        } elseif ($reason -match '19100|16300') {
            300
        } elseif ($reason -match '0x80070020|sharing violation') {
            200
        } elseif ($reason -match '19090') {
            100
        } else {
            0
        }
        if ($reasonScore -gt $byName[$key].Score) { $byName[$key].Score = $reasonScore }
    }

    $ranked = @($byName.Values | ForEach-Object {
        $orderedReasons = @($_.Reasons | Sort-Object {
            if ($_ -match 'fork|3216|0x80048102') { 0 }
            elseif ($_ -match '19100|16300') { 1 }
            elseif ($_ -match '0x80070020|sharing violation') { 2 }
            elseif ($_ -match '19090') { 3 }
            else { 4 }
        }, { $_ })
        [pscustomobject]@{
            Name    = $_.Name
            Reason  = if ($orderedReasons.Count -gt 0) { $orderedReasons[0] } else { 'High-risk checkpoint/merge signal' }
            Reasons = $orderedReasons
            Score   = $_.Score
        }
    } | Sort-Object @{ Expression = { $_.Score }; Descending = $true }, Name)

    $audit = $ranked
    $deferred = @()
    if ($null -ne $Maximum) {
        $audit = @($ranked | Select-Object -First $Maximum)
        $deferred = @($ranked | Select-Object -Skip $Maximum)
    }

    [pscustomobject]@{
        EligibleCount = $ranked.Count
        Audit         = @($audit)
        Deferred      = @($deferred)
        Cap           = $Maximum
    }
}

function Resolve-ActiveCheckpointHistoricVerdict {
    [OutputType([object])]
    param(
        [bool]$HoldState,
        [bool]$Investigate,
        [bool]$LowSignalOnly,
        [int]$SeverityScore,
        [bool]$ForkConfirmed,
        [bool]$CoverageIncomplete
    )

    if ($ForkConfirmed) {
        $HoldState = $true
        $Investigate = $false
        $LowSignalOnly = $false
        $SeverityScore = 100
    } elseif ($CoverageIncomplete -and -not $HoldState) {
        $Investigate = $true
        $LowSignalOnly = $false
        if ($SeverityScore -lt 55) { $SeverityScore = 55 }
    }

    [pscustomobject]@{
        HoldState = $HoldState
        Investigate = $Investigate
        LowSignalOnly = $LowSignalOnly
        SeverityScore = $SeverityScore
    }
}

Export-ModuleMember -Function Get-HyperVEventPolicy, Get-HyperVEventSignalAssessment, Resolve-HyperVOperationRecovery, Compare-VMCollectionStateToken, Get-HyperVReplicationAssessment, Resolve-HyperVEventAttribution, Resolve-EventCoverage, Get-VMCheckpointVerdictAssessment, Select-DiscoveredVMsForAudit, Resolve-ActiveCheckpointHistoricVerdict
