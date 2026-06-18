#Requires -Module Pester
<#
.SYNOPSIS
    Durable LIVE-AZURE integration tests for the AzLocal.UpdateManagement module.

.DESCRIPTION
    These tests run against the real AdaptiveCloudLab subscription
    (fbaf508b-cb61-4383-9cda-a42bfa0c7bc9) via the Azure CLI ARG transport
    used by Get-AzLocalFleetHealthOverview / Get-AzLocalFleetHealthFailures /
    Get-AzLocalUpdateRunFailures.

    All Describe blocks are tagged 'Live'. The default Invoke-Tests.ps1 entry
    point excludes this tag so the standard 565-test unit suite stays hermetic.
    To opt in:

        .\Tests\Invoke-Tests.ps1 -IncludeLive
        # or
        Invoke-Pester -Path .\Tests\Live-Integration.Tests.ps1 -Tag Live

    Each Describe additionally Skips itself when:
        - az CLI is not on PATH, OR
        - az is not logged in, OR
        - The signed-in subscription is not the expected AdaptiveCloudLab id.

    These guards mean the suite is safe to leave permanently in the repo and
    safe to run on any developer machine - it auto-skips when the live
    pre-conditions aren't met.

    The expected subscription id is hard-coded (not a secret - a subscription
    id alone is not a credential; an RBAC grant on the signed-in identity is
    what makes it actionable).

    Implementation notes:
    - Every It block calls the cmdlet directly. Pester 5 BeforeAll-scope
      variables do not reliably preserve array-of-PSCustomObject semantics
      inside It blocks (one full ARG round-trip per It is cheap enough).
    - Get-AzLocalFleetHealthOverview and Get-AzLocalFleetHealthFailures
      return their result with the `return , $output` idiom to preserve
      array-ness across the cmdlet boundary. The downside is that wrapping
      the call in `@(...)` produces a single-element array containing the
      inner array. Tests therefore use the `@() + (cmdlet ...)` normalizer
      which works for all three return-shape patterns (zero, scalar, array,
      , $output-array) without double-wrapping.

.NOTES
    Author:   Neil Bird, Microsoft.
    Added:    v0.7.70
    Module:   AzLocal.UpdateManagement
    Run with: Invoke-Pester -Path .\Tests\Live-Integration.Tests.ps1 -Tag Live -Output Detailed
#>

BeforeDiscovery {
    # Expected live subscription. AdaptiveCloudLab tenant - 20 clusters under
    # management as of v0.7.70. Hard-coded in the repo source because (a) a
    # subscription id alone is not a credential and (b) it makes the durable
    # safety gate "are we pointed at the right tenant?" trivially auditable.
    $ExpectedSubscriptionId = 'fbaf508b-cb61-4383-9cda-a42bfa0c7bc9'

    # Probe the environment ONCE so each Describe -Skip decision is consistent.
    $LiveGateReason = $null
    try {
        $azCmd = Get-Command az -ErrorAction Stop
        $null = $azCmd
    } catch {
        $LiveGateReason = 'az CLI is not available on PATH'
    }

    if (-not $LiveGateReason) {
        $accountJson = $null
        try {
            $accountJson = & az account show -o json 2>$null
        } catch {
            $LiveGateReason = "az account show threw: $($_.Exception.Message)"
        }
        if (-not $LiveGateReason -and $LASTEXITCODE -ne 0) {
            $LiveGateReason = "az is not logged in (az account show exit $LASTEXITCODE)"
        }
        if (-not $LiveGateReason -and -not $accountJson) {
            $LiveGateReason = 'az account show returned empty output'
        }
        if (-not $LiveGateReason) {
            try {
                $account = $accountJson | ConvertFrom-Json
                if ($account.id -ne $ExpectedSubscriptionId) {
                    $LiveGateReason = "az signed-in subscription is $($account.id) (name=$($account.name)); expected $ExpectedSubscriptionId. Run 'az account set --subscription $ExpectedSubscriptionId' to opt in."
                }
            } catch {
                $LiveGateReason = "Failed to parse az account show output: $($_.Exception.Message)"
            }
        }
    }

    $SkipLive = [bool]$LiveGateReason

    # The provider-operations catalog (az provider operation show) is GLOBAL -
    # it is not scoped to any subscription - so the checkUpdates catalog tripwire
    # only needs az to be logged in; it does NOT require the AdaptiveCloudLab
    # subscription that the rest of the Live suite targets. Compute a lighter
    # gate that skips only when az is unavailable or not logged in.
    $CatalogGateReason = $null
    try {
        $null = Get-Command az -ErrorAction Stop
    } catch {
        $CatalogGateReason = 'az CLI is not available on PATH'
    }
    if (-not $CatalogGateReason) {
        $null = & az account show -o json 2>$null
        if ($LASTEXITCODE -ne 0) {
            $CatalogGateReason = "az is not logged in (az account show exit $LASTEXITCODE)"
        }
    }
    $SkipCatalog = [bool]$CatalogGateReason
}

BeforeAll {
    # Import the module under test.
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop
    Write-Host "[Live-Integration] Module $(Get-Module AzLocal.UpdateManagement | Select-Object -ExpandProperty Version) loaded against subscription fbaf508b-cb61-4383-9cda-a42bfa0c7bc9." -ForegroundColor Cyan
}

AfterAll {
    Remove-Module AzLocal.UpdateManagement -Force -ErrorAction SilentlyContinue
}

Describe 'Live-Integration: Authentication and ARG transport pre-conditions' -Tag 'Live' -Skip:$SkipLive {

    It 'az CLI is logged in and points at the expected subscription' {
        $expected = 'fbaf508b-cb61-4383-9cda-a42bfa0c7bc9'
        $account = & az account show -o json | ConvertFrom-Json
        $account.id | Should -Be $expected
    }

    It 'az graph subcommand is reachable (Invoke-AzResourceGraphQuery transport pre-req)' {
        $help = & az graph --help 2>&1 | Out-String
        $help | Should -Match 'query' -Because '`az graph query` must be reachable for ARG transport to work'
    }

    It 'Resource Graph is reachable: at least one Azure Local cluster is visible to the signed-in identity' {
        $kql = "resources | where type =~ 'microsoft.azurestackhci/clusters' | summarize count()"
        $resp = & az graph query -q $kql --first 1 -o json | ConvertFrom-Json
        $count = 0
        if ($resp -is [System.Collections.IEnumerable] -and -not ($resp -is [string])) {
            $count = $resp[0].count_
        } elseif ($resp.data) {
            $count = $resp.data[0].count_
        }
        $count | Should -BeGreaterThan 0 -Because 'Live tests require at least one cluster in the signed-in subscription'
    }
}

Describe 'Live-Integration: Get-AzLocalFleetHealthOverview' -Tag 'Live' -Skip:$SkipLive {

    It 'Returns at least one cluster row' {
        $rows = @() + (Get-AzLocalFleetHealthOverview -PassThru -ErrorAction Stop)
        $rows.Count | Should -BeGreaterThan 0
    }

    It 'Every row exposes the v0.7.70 ARG-first projection columns' {
        $expected = @(
            'ClusterName'
            'ClusterPortalUrl'
            'HealthStatus'
            'UpdateStatus'
            'CurrentVersion'
            'SbeVersion'
            'AzureConnection'
            'LastChecked'
            'HealthResultsAgeDays'
        )
        $rows = @() + (Get-AzLocalFleetHealthOverview -PassThru -ErrorAction Stop)
        foreach ($row in $rows) {
            $present = @($row.PSObject.Properties.Name)
            $missing = @($expected | Where-Object { $present -notcontains $_ })
            $missing | Should -BeNullOrEmpty -Because "row for $($row.ClusterName) must expose every v0.7.70 column"
        }
    }

    It 'ClusterPortalUrl points at https://portal.azure.com/#@/resource/...' {
        $rows = @() + (Get-AzLocalFleetHealthOverview -PassThru -ErrorAction Stop)
        foreach ($row in $rows) {
            if ([string]::IsNullOrEmpty($row.ClusterPortalUrl)) { continue }
            $row.ClusterPortalUrl | Should -Match '^https://portal\.azure\.com/#@/resource/' -Because "ClusterPortalUrl on $($row.ClusterName) must be a portal deep-link"
        }
    }

    It 'HealthResultsAgeDays is either null, the -1 sentinel (no LastChecked), or a non-negative integer' {
        # KQL emits -1 as the documented sentinel for "no LastChecked timestamp"
        # (see Get-AzLocalFleetHealthOverview.ps1: iif(isnull(LastChecked), -1, ...)).
        $rows = @() + (Get-AzLocalFleetHealthOverview -PassThru -ErrorAction Stop)
        foreach ($row in $rows) {
            if ($null -eq $row.HealthResultsAgeDays) { continue }
            $age = [int]$row.HealthResultsAgeDays
            ($age -eq -1 -or $age -ge 0) | Should -BeTrue -Because "HealthResultsAgeDays on $($row.ClusterName) must be null, the -1 sentinel, or a non-negative integer (got $age)"
        }
    }

    It 'AzureConnection is one of the documented connectivity-status values' {
        $allowed = @('Connected', 'Disconnected', 'NotYetRegistered', 'NotSpecified', 'PartiallyConnected', '', $null)
        $rows = @() + (Get-AzLocalFleetHealthOverview -PassThru -ErrorAction Stop)
        foreach ($row in $rows) {
            $row.AzureConnection | Should -BeIn $allowed -Because "AzureConnection on $($row.ClusterName) must be one of the documented Azure Arc connectivity-status enum values"
        }
    }
}

Describe 'Live-Integration: Get-AzLocalFleetHealthFailures' -Tag 'Live' -Skip:$SkipLive {

    It 'Detail view returns rows (fleet has known unresolved failures)' {
        $detail = @() + (Get-AzLocalFleetHealthFailures -View Detail -PassThru -ErrorAction Stop)
        $detail.Count | Should -BeGreaterThan 0
    }

    It 'Detail rows expose the documented v0.7.70 columns' {
        $expected = @('ClusterName', 'ClusterPortalUrl', 'Severity', 'FailureReason', 'Description', 'Remediation')
        $detail = @() + (Get-AzLocalFleetHealthFailures -View Detail -PassThru -ErrorAction Stop)
        $sample = if ($detail.Count -gt 5) { 5 } else { $detail.Count }
        for ($i = 0; $i -lt $sample; $i++) {
            $row = $detail[$i]
            $present = @($row.PSObject.Properties.Name)
            $missing = @($expected | Where-Object { $present -notcontains $_ })
            $missing | Should -BeNullOrEmpty -Because "detail row must include every v0.7.70 column"
        }
    }

    It 'Summary view rolls up by FailureReason x Severity' {
        $summary = @() + (Get-AzLocalFleetHealthFailures -View Summary -PassThru -ErrorAction Stop)
        $summary.Count | Should -BeGreaterThan 0
        $first = $summary[0]
        $present = @($first.PSObject.Properties.Name)
        $present | Should -Contain 'FailureReason'
        $present | Should -Contain 'Severity'
        $present | Should -Contain 'ClusterCount'
        $present | Should -Contain 'FailureCount'
        $present | Should -Contain 'AffectedClusterPortalUrls'
    }

    It 'Severity=Critical filter returns only Critical rows' {
        $critical = @() + (Get-AzLocalFleetHealthFailures -Severity Critical -View Detail -PassThru -ErrorAction Stop)
        foreach ($row in $critical) {
            $row.Severity | Should -Be 'Critical'
        }
    }
}

Describe 'Live-Integration: Get-AzLocalUpdateRunFailures' -Tag 'Live' -Skip:$SkipLive {

    It 'Returns at least one Failed unresolved row (fleet has known unresolved runs)' {
        $rows = @() + (Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since (Get-Date).ToUniversalTime().AddDays(-30) -ErrorAction Stop)
        $rows.Count | Should -BeGreaterThan 0
    }

    It 'Every row exposes the v0.7.70 update-history columns' {
        $expected = @(
            'ClusterName'
            'Status'
            'CurrentStep'
            'Duration'
            'LastUpdated'
            'UpdateRunPortalUrl'
            'DeepestErrMsg'
            'ErrorCategory'
        )
        $rows = @() + (Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since (Get-Date).ToUniversalTime().AddDays(-30) -ErrorAction Stop)
        $sample = if ($rows.Count -gt 5) { 5 } else { $rows.Count }
        for ($i = 0; $i -lt $sample; $i++) {
            $row = $rows[$i]
            $present = @($row.PSObject.Properties.Name)
            $missing = @($expected | Where-Object { $present -notcontains $_ })
            $missing | Should -BeNullOrEmpty -Because "update-failure row must include every v0.7.70 column"
        }
    }

    It 'UpdateRunPortalUrl is a SingleInstanceHistoryDetails portal deep-link with an URL-encoded ClusterResourceId' {
        $rows = @() + (Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since (Get-Date).ToUniversalTime().AddDays(-30) -ErrorAction Stop)
        foreach ($row in $rows) {
            if ([string]::IsNullOrEmpty($row.UpdateRunPortalUrl)) { continue }
            $row.UpdateRunPortalUrl | Should -Match 'SingleInstanceHistoryDetails' -Because "Step.6 testcases rely on this deep-link shape"
            $row.UpdateRunPortalUrl | Should -Match '%2Fsubscriptions%2F'        -Because "ClusterResourceId must be URL-encoded inside the ReactView fragment"
        }
    }

    It 'OnlyUnresolved limits results to Status != Succeeded' {
        $rows = @() + (Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved -Since (Get-Date).ToUniversalTime().AddDays(-30) -ErrorAction Stop)
        foreach ($row in $rows) {
            $row.Status | Should -Not -Be 'Succeeded' -Because '-OnlyUnresolved must exclude rows where the next attempt succeeded'
        }
    }
}

Describe 'Live-Integration: Get-AzLocalFleetConnectivityStatus (v0.7.79)' -Tag 'Live' -Skip:$SkipLive {
    # v0.7.79: End-to-end validation of the new module cmdlet that replaced Step.4's
    # inline ARG queries. Validates that all 7 output properties are present, schemas
    # are correct, and ArcSummary is grouped client-side (not via KQL summarize).

    BeforeAll {
        $script:connectivityData = Get-AzLocalFleetConnectivityStatus -PassThru
    }

    It 'Returns a result object' {
        $script:connectivityData | Should -Not -BeNullOrEmpty
    }

    It 'ClusterRows is present and non-empty' {
        $script:connectivityData.ClusterRows | Should -Not -BeNullOrEmpty
        $script:connectivityData.ClusterRows.Count | Should -BeGreaterThan 0
    }

    It 'ClusterRows has expected columns' {
        $row = $script:connectivityData.ClusterRows[0]
        $row.PSObject.Properties.Name | Should -Contain 'ClusterName'
        $row.PSObject.Properties.Name | Should -Contain 'ConnectivityStatus'
        $row.PSObject.Properties.Name | Should -Contain 'ClusterStatus'
        $row.PSObject.Properties.Name | Should -Contain 'NodeCount'
        $row.PSObject.Properties.Name | Should -Contain 'Location'
        $row.PSObject.Properties.Name | Should -Contain 'ResourceGroup'
        $row.PSObject.Properties.Name | Should -Contain 'SubscriptionId'
    }

    It 'ClusterRows ClusterName values are not null or blank' {
        foreach ($row in $script:connectivityData.ClusterRows) {
            [string]::IsNullOrWhiteSpace($row.ClusterName) | Should -BeFalse -Because "ClusterName must be populated for row $($row.ClusterId)"
        }
    }

    It 'ArcSummary is present' {
        $script:connectivityData.PSObject.Properties.Name | Should -Contain 'ArcSummary'
    }

    It 'ArcSummary has AgentStatus and Count columns' {
        $row = $script:connectivityData.ArcSummary | Select-Object -First 1
        if ($row) {
            $row.PSObject.Properties.Name | Should -Contain 'AgentStatus'
            $row.PSObject.Properties.Name | Should -Contain 'Count'
        }
    }

    It 'ArcSummary Count values are integers greater than zero' {
        foreach ($row in $script:connectivityData.ArcSummary) {
            $row.Count | Should -BeGreaterThan 0 -Because "ArcSummary row for '$($row.AgentStatus)' must have Count > 0"
        }
    }

    It 'ArcSummary is grouped (fewer rows than total machines)' {
        # If ArcSummary rows == total machine count it means summarize was not applied
        # and we got raw machine rows - the bug we fixed in v0.7.79
        $totalMachineCount = ($script:connectivityData.ArcSummary | Measure-Object -Property Count -Sum).Sum
        $script:connectivityData.ArcSummary.Count | Should -BeLessThan $totalMachineCount `
            -Because 'ArcSummary must be grouped by status (fewer groups than total machines)'
    }

    It 'NonConnectedMachines is present' {
        $script:connectivityData.PSObject.Properties.Name | Should -Contain 'NonConnectedMachines'
    }

    It 'NicIssues is present' {
        $script:connectivityData.PSObject.Properties.Name | Should -Contain 'NicIssues'
    }

    It 'NicAll is present' {
        $script:connectivityData.PSObject.Properties.Name | Should -Contain 'NicAll'
    }

    It 'NicStats is present and has NicType, NicStatus, Count columns' {
        $script:connectivityData.PSObject.Properties.Name | Should -Contain 'NicStats'
        $row = $script:connectivityData.NicStats | Select-Object -First 1
        if ($row) {
            $row.PSObject.Properties.Name | Should -Contain 'NicType'
            $row.PSObject.Properties.Name | Should -Contain 'NicStatus'
            $row.PSObject.Properties.Name | Should -Contain 'Count'
        }
    }

    It 'ArbRows is present' {
        $script:connectivityData.PSObject.Properties.Name | Should -Contain 'ArbRows'
    }

    It 'ArbRows has expected columns when appliances exist' {
        $row = $script:connectivityData.ArbRows | Select-Object -First 1
        if ($row) {
            $row.PSObject.Properties.Name | Should -Contain 'ArbName'
            $row.PSObject.Properties.Name | Should -Contain 'ArbStatus'
            $row.PSObject.Properties.Name | Should -Contain 'ClusterName'
            $row.PSObject.Properties.Name | Should -Contain 'ResourceGroup'
            $row.PSObject.Properties.Name | Should -Contain 'SubscriptionId'
        }
    }
}

Describe 'Live-Integration: Export-*Report cmdlets emit non-empty artifacts (v0.8.5 thin-YAML wrappers)' -Tag 'Live' -Skip:$SkipLive {
    # v0.8.5: One read-only round-trip per non-destructive Export-* cmdlet
    # added by the thin-YAML refactor. Asserts the cmdlet produces the
    # documented artifact files (CSV / JSON / JUnit XML / markdown) and the
    # -PassThru payload exposes the documented top-level properties. The
    # destructive cmdlets Invoke-AzLocalReadinessGatedClusterUpdate and
    # Set-AzLocalClusterUpdateRingTagFromCsv are deliberately NOT covered
    # here - they need a scratch-cluster fixture pattern (tracked as a
    # follow-up: "Live-Integration coverage for destructive v0.8.5 cmdlets").
    #
    # Each It block uses a per-test temp OutputDirectory and cleans it up in
    # a finally{} so the runner workspace stays tidy even on failure.

    BeforeAll {
        $script:liveExportRoot = Join-Path (Get-Item -LiteralPath $env:TEMP).FullName "azlocal-live-exp-$([guid]::NewGuid().Guid.Substring(0,8))"
        New-Item -ItemType Directory -Path $script:liveExportRoot -Force | Out-Null
    }

    AfterAll {
        if ($script:liveExportRoot -and (Test-Path -LiteralPath $script:liveExportRoot)) {
            Remove-Item -LiteralPath $script:liveExportRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '[Step.0] Export-AzLocalAuthValidationReport emits JSON + CSV + JUnit XML and PassThru exposes documented properties' {
        $outDir = Join-Path $script:liveExportRoot "s0-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalAuthValidationReport -ReportDirectory $outDir -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.AuthValid              | Should -BeTrue
        $r.SubscriptionCount      | Should -BeGreaterThan 0
        $r.ClusterCount           | Should -BeGreaterThan 0
        Test-Path -LiteralPath $r.JUnitXmlPath          | Should -BeTrue -Because 'Step.0 must emit the JUnit XML'
        Test-Path -LiteralPath $r.SubscriptionsJsonPath | Should -BeTrue -Because 'Step.0 must emit the subscriptions JSON'
        Test-Path -LiteralPath $r.SubscriptionsCsvPath  | Should -BeTrue -Because 'Step.0 must emit the subscriptions CSV'
        (Get-Item -LiteralPath $r.JUnitXmlPath).Length          | Should -BeGreaterThan 0
        (Get-Item -LiteralPath $r.SubscriptionsJsonPath).Length | Should -BeGreaterThan 0
    }

    It '[Step.3] Export-AzLocalApplyUpdatesScheduleAudit emits audit + matrix CSV, recommend MD, JUnit XML and PassThru exposes counts' {
        $modRoot = Split-Path -Path (Get-Module AzLocal.UpdateManagement | Select-Object -First 1).Path -Parent
        $schedule = Join-Path $modRoot 'Automation-Pipeline-Examples\apply-updates-schedule.example.yml'
        $pipelineYml = Join-Path $modRoot 'Automation-Pipeline-Examples\github-actions\apply-updates-schedule-audit.yml'
        Test-Path -LiteralPath $schedule    | Should -BeTrue -Because 'bundled schedule example must exist'
        Test-Path -LiteralPath $pipelineYml | Should -BeTrue -Because 'bundled Step.3 pipeline yml must exist'

        $outDir = Join-Path $script:liveExportRoot "s3-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalApplyUpdatesScheduleAudit `
                -OutputDirectory $outDir `
                -PipelineYamlPath $pipelineYml `
                -SchedulePath $schedule `
                -Platform GitHubActions `
                -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.TotalRows | Should -BeGreaterThan 0
        Test-Path -LiteralPath $r.AuditCsvPath    | Should -BeTrue
        Test-Path -LiteralPath $r.MatrixCsvPath   | Should -BeTrue
        Test-Path -LiteralPath $r.RecommendMdPath | Should -BeTrue
        Test-Path -LiteralPath $r.JUnitXmlPath    | Should -BeTrue
        (Get-Item -LiteralPath $r.AuditCsvPath).Length | Should -BeGreaterThan 0
    }

    It '[Step.4] Export-AzLocalFleetConnectivityStatusReport emits artifacts and PassThru exposes counts + rollups' {
        $outDir = Join-Path $script:liveExportRoot "s4-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalFleetConnectivityStatusReport -OutputDirectory $outDir -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.ClusterTotal | Should -BeGreaterThan 0
        $r.PSObject.Properties.Name | Should -Contain 'ArcSummary'
        $r.PSObject.Properties.Name | Should -Contain 'NicStats'
        $r.PSObject.Properties.Name | Should -Contain 'JUnitXmlPath'
        Test-Path -LiteralPath $r.JUnitXmlPath | Should -BeTrue
        Test-Path -LiteralPath $r.SummaryPath  | Should -BeTrue
    }

    It '[Step.5] Export-AzLocalClusterUpdateReadinessReport emits readiness + health artifacts and PassThru exposes counts' {
        $outDir = Join-Path $script:liveExportRoot "s5-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalClusterUpdateReadinessReport -OutputDirectory $outDir -Scope all -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.TotalCount | Should -BeGreaterThan 0
        Test-Path -LiteralPath $r.ReadinessCsvPath | Should -BeTrue
        Test-Path -LiteralPath $r.ReadinessXmlPath | Should -BeTrue
        Test-Path -LiteralPath $r.CombinedXmlPath  | Should -BeTrue
        (Get-Item -LiteralPath $r.ReadinessCsvPath).Length | Should -BeGreaterThan 0
    }

    It '[Step.6] Export-AzLocalClusterReadinessGateReport short-circuits cleanly when -UpdateRing is empty (no-op, read-only)' {
        # Empty -UpdateRing is the documented short-circuit. The cmdlet does
        # NOT call Get-AzLocalClusterUpdateReadiness and does NOT trigger any
        # update; it just emits zero counts. This is the only safe Live test
        # for Step.6 - the populated-ring path overlaps Step.5 coverage and
        # the apply-updates side (Invoke-AzLocalReadinessGatedClusterUpdate)
        # is deliberately deferred (destructive).
        $outDir = Join-Path $script:liveExportRoot "s6-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalClusterReadinessGateReport -OutputDirectory $outDir -UpdateRing '' -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.TotalCount    | Should -Be 0
        $r.ReadyCount    | Should -Be 0
        $r.NotReadyCount | Should -Be 0
        $r.UpdateRing    | Should -BeNullOrEmpty
        $r.Results       | Should -BeNullOrEmpty
    }

    It '[Step.7] Export-AzLocalUpdateRunMonitorReport emits CSV + JUnit XML and PassThru exposes the in-flight + failure counts' {
        $outDir = Join-Path $script:liveExportRoot "s7-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalUpdateRunMonitorReport -OutputDirectory $outDir -Scope all -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.PSObject.Properties.Name | Should -Contain 'InFlightCount'
        $r.PSObject.Properties.Name | Should -Contain 'UnresolvedFailureCount'
        $r.PSObject.Properties.Name | Should -Contain 'CsvPath'
        $r.PSObject.Properties.Name | Should -Contain 'XmlPath'
        Test-Path -LiteralPath $r.CsvPath | Should -BeTrue
        Test-Path -LiteralPath $r.XmlPath | Should -BeTrue
    }

    It '[Step.8] Export-AzLocalFleetUpdateStatusReport emits inventory + readiness + run-history artifacts and PassThru exposes version-distribution counts' {
        $outDir = Join-Path $script:liveExportRoot "s8-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalFleetUpdateStatusReport -OutputDirectory $outDir -Scope all -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.TotalClusters | Should -BeGreaterThan 0
        $r.PSObject.Properties.Name | Should -Contain 'VersionDistCount'
        $r.PSObject.Properties.Name | Should -Contain 'InventoryCsvPath'
        $r.PSObject.Properties.Name | Should -Contain 'ReadinessCsvPath'
        $r.PSObject.Properties.Name | Should -Contain 'XmlPath'
        Test-Path -LiteralPath $r.InventoryCsvPath | Should -BeTrue
        Test-Path -LiteralPath $r.ReadinessCsvPath | Should -BeTrue
        Test-Path -LiteralPath $r.XmlPath          | Should -BeTrue
        (Get-Item -LiteralPath $r.InventoryCsvPath).Length | Should -BeGreaterThan 0
    }

    It '[Step.9] Export-AzLocalFleetHealthStatusReport emits overview + detail + summary artifacts and PassThru exposes failure counts' {
        $outDir = Join-Path $script:liveExportRoot "s9-$([guid]::NewGuid().Guid.Substring(0,8))"
        $r = Export-AzLocalFleetHealthStatusReport -OutputDirectory $outDir -Scope all -Severity All -PassThru -ErrorAction Stop
        $r | Should -Not -BeNullOrEmpty
        $r.TotalClusters | Should -BeGreaterThan 0
        $r.PSObject.Properties.Name | Should -Contain 'CriticalCount'
        $r.PSObject.Properties.Name | Should -Contain 'WarningCount'
        $r.PSObject.Properties.Name | Should -Contain 'DetailCsvPath'
        $r.PSObject.Properties.Name | Should -Contain 'OverviewCsvPath'
        $r.PSObject.Properties.Name | Should -Contain 'XmlPath'
        Test-Path -LiteralPath $r.OverviewCsvPath  | Should -BeTrue
        Test-Path -LiteralPath $r.OverviewJsonPath | Should -BeTrue
        Test-Path -LiteralPath $r.XmlPath          | Should -BeTrue
        (Get-Item -LiteralPath $r.OverviewCsvPath).Length | Should -BeGreaterThan 0
    }
}

Describe 'Live-Integration: checkUpdates provider-operations catalog tripwire' -Tag 'Live' -Skip:$SkipCatalog {
    # v0.8.89: LIVE companion to the OFFLINE tripwire in
    # AzLocal.UpdateManagement.Tests.ps1 ('v0.8.89 RBAC checkUpdates action ...').
    #
    # The offline tripwire fires when a HUMAN adds checkUpdates to the role JSON.
    # THIS live test queries the REAL Microsoft.AzureStackHCI provider operations
    # catalog via Az CLI (az provider operation show) and FAILS the moment Azure
    # PUBLISHES 'Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action'
    # - i.e. the moment it becomes a registered action that az role definition
    # create/update will accept, and therefore the moment it is safe to add to the
    # least-privilege custom role.
    #
    # Gated by $SkipCatalog (only requires az to be logged in - the catalog is
    # global, not subscription-scoped) and Tag 'Live' (excluded from the default
    # unit run). Run it with:
    #     .\Tests\Invoke-Tests.ps1 -IncludeLive
    #     # or just this file:
    #     Invoke-Pester -Path .\Tests\Live-Integration.Tests.ps1 -Tag Live
    #
    # WHEN the 'still absent' test below goes RED:
    #   1. Add "Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action"
    #      to every Actions[] block: bundled azlocal-update-management-custom-role.json,
    #      docs/rbac.md (x3 blocks), Automation-Pipeline-Examples/README.md.
    #   2. Flip the OFFLINE tripwire assertions (Not -Contain -> Contain) in
    #      AzLocal.UpdateManagement.Tests.ps1.
    #   3. Update the prose in docs/rbac.md, Automation README, top-level README,
    #      and docs/cmdlet-reference.md to say the action is now in the role.
    #   4. Flip the assertion in this live test (Should -BeNullOrEmpty ->
    #      Should -Not -BeNullOrEmpty) so it then guards continued availability.

    BeforeAll {
        $script:checkUpdatesAction = 'Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action'
        # One operation name per line (-o tsv). Case-insensitive comparisons below.
        $script:catalogOps  = & az provider operation show --namespace Microsoft.AzureStackHCI --query "resourceTypes[].operations[].name" -o tsv 2>$null
        $script:catalogExit = $LASTEXITCODE
    }

    It 'az provider operation show returns the Microsoft.AzureStackHCI catalog' {
        $script:catalogExit | Should -Be 0 -Because 'the catalog query must succeed for this tripwire to be meaningful'
        ($script:catalogOps | Measure-Object).Count | Should -BeGreaterThan 0 -Because 'the provider must expose at least one operation'
    }

    It 'The four update actions the custom role relies on are still present in the catalog' {
        $required = @(
            'Microsoft.AzureStackHCI/clusters/updateSummaries/read',
            'Microsoft.AzureStackHCI/clusters/updates/read',
            'Microsoft.AzureStackHCI/clusters/updates/apply/action',
            'Microsoft.AzureStackHCI/clusters/updates/updateRuns/read'
        )
        $catalogLower = @($script:catalogOps | ForEach-Object { $_.ToLowerInvariant() })
        foreach ($action in $required) {
            $catalogLower | Should -Contain $action.ToLowerInvariant() -Because "the custom role grants $action; it must still exist in the provider operations catalog"
        }
    }

    It 'checkUpdates is STILL absent from the catalog (when this fails, add it to the custom role - see comments)' {
        # TRIPWIRE: this is the auto-detector. While checkUpdates is unregistered
        # the match is empty and the test is green. The day Azure publishes the
        # action, the match is non-empty and this test goes red - that is the
        # signal to add it to the role and flip both tripwires (see the 4-step
        # comment block at the top of this Describe).
        $present = @($script:catalogOps | Where-Object { $_ -match 'checkUpdates' })
        $present | Should -BeNullOrEmpty -Because "checkUpdates has appeared in the Microsoft.AzureStackHCI provider operations catalog - it is now safe to add '$($script:checkUpdatesAction)' to the least-privilege custom role and flip the offline tripwire in AzLocal.UpdateManagement.Tests.ps1. Catalog entries matching 'checkUpdates': $($present -join ', ')"
    }
}

