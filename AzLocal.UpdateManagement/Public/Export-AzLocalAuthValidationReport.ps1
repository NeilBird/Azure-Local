function Export-AzLocalAuthValidationReport {
    <#
    .SYNOPSIS
        Validates the pipeline identity's Azure authentication, RBAC, and
        subscription scope, and emits a JUnit XML report + step-summary
        markdown for the v0.8.5 thin-YAML Step.0 pipeline.

    .DESCRIPTION
        Phase 1 (v0.8.5) of the thin-YAML refactor. Condenses the
        ~200-line inline `run: |` block in the v0.8.4
        `Step.0_authentication-test.yml` (GitHub Actions + Azure DevOps)
        into a single cmdlet call so the per-platform yml shrinks to a
        few lines and the logic becomes unit-testable against synthetic
        `az` CLI responses.

        The cmdlet probes four auth-relevant facts in sequence:

          1. `az account show` (proves OIDC / Workload Identity Federation
             token exchange, secret wiring).
          2. Role assignments for the pipeline identity's appId (proves
             RBAC grant). Surfaced to the console only (matches the
             v0.8.4 yml behaviour, which used `-o table` for log inspection).
          3. `az account list --refresh` (proves which subscriptions the
             identity can actually see; the authoritative count). Subscription
             rows are persisted as both `subscriptions.json` and
             `subscriptions.csv` in the report directory.
          4. Azure Resource Graph query for `microsoft.azurestackhci/clusters`
             (proves cluster reachability for the downstream fleet pipelines).

        All four facts feed FOUR JUnit `<testsuite>` blocks in the emitted
        XML (Authentication / Subscription Scope / Resource Graph
        Reachability / Module Version Drift). The markdown step summary
        renders the same data as a table + subscription roster. Three step
        outputs (`subscription_count`, `cluster_count`, `auth_valid`) are
        emitted via the Phase 0 `Set-AzLocalPipelineOutput` helper so
        downstream jobs / steps can consume them on either platform.

        Internal reuse (per the v0.8.5 thin-YAML consistency contract):
          * `Invoke-AzCliJson` for every `az` subcommand (safe stderr/stdout
            split; never the inline `2>&1 | ConvertFrom-Json` pattern).
          * `Install-AzGraphExtension` for the resource-graph extension
            (idempotent install).
          * `Invoke-AzResourceGraphQuery` for the cluster reachability KQL.
          * `New-AzLocalPipelineJUnitXml` (Private) for the JUnit XML.
          * `Add-AzLocalPipelineStepSummary` for the rendered markdown.
          * `Set-AzLocalPipelineOutput` for the three step outputs.
          * `Get-AzLocalPipelineHost` is implicit (all of the above branch
            on it internally).

    .PARAMETER AzureClientId
        The pipeline identity's appId. Used to scope the
        `az role assignment list --assignee <appId>` console echo. When
        empty / null, the cmdlet falls back to `account.user.name` from
        `az account show` (the same fallback the v0.8.4 ADO yml uses,
        because ADO service connections do not expose the appId via a
        secret).

    .PARAMETER ReportDirectory
        Directory to write the JUnit XML and the subscription artifacts
        (`subscriptions.json`, `subscriptions.csv`) into. Created if it
        does not exist. Defaults to `./reports` (which is what the v0.8.4
        GH yml uses) or, on AzureDevOps, to
        `$env:BUILD_ARTIFACTSTAGINGDIRECTORY/auth-report` if that env var
        is set (matching the v0.8.4 ADO yml).

    .PARAMETER ReportFileName
        Filename for the JUnit XML (relative to `-ReportDirectory`).
        Default `auth-report.xml`.

    .PARAMETER SubscriptionsJsonFileName
        Filename for the JSON subscription artifact. Default
        `subscriptions.json`.

    .PARAMETER SubscriptionsCsvFileName
        Filename for the CSV subscription artifact. Default
        `subscriptions.csv`.

    .PARAMETER MaxClusters
        Upper bound on the ARG `--first` page size for the cluster query.
        Default 1000.

    .PARAMETER InstalledModuleVersion
        Optional [version] / [string] for the Module Version Drift JUnit
        suite. When all three of InstalledModuleVersion /
        GeneratedAgainstVersion / LatestOnPSGallery are empty, the
        Module Version Drift suite is omitted.

    .PARAMETER GeneratedAgainstVersion
        See InstalledModuleVersion.

    .PARAMETER LatestOnPSGallery
        See InstalledModuleVersion.

    .PARAMETER PassThru
        When set, returns a single PSCustomObject summarising the run
        (Account, SubscriptionCount, ClusterCount, AuthValid, JUnitXmlPath,
        SubscriptionsJsonPath, SubscriptionsCsvPath). Without -PassThru
        the cmdlet emits nothing to the pipeline; the artifacts and step
        outputs are still produced.

    .OUTPUTS
        Nothing by default. When -PassThru is set, a single PSCustomObject:
          Account                [PSCustomObject] (name, id, tenantId, user)
          SubscriptionCount      [int]
          Subscriptions          [PSCustomObject[]] (one per subscription)
          ClusterCount           [int]
          AuthValid              [bool]
          JUnitXmlPath           [string]
          SubscriptionsJsonPath  [string]
          SubscriptionsCsvPath   [string]

    .EXAMPLE
        Export-AzLocalAuthValidationReport -PassThru

        Runs the four probes against the currently-authenticated `az`
        context, writes auth-report.xml + subscriptions.{json,csv} to
        ./reports, emits the rendered markdown to the active pipeline
        host's step-summary, sets three step outputs, and returns the
        summary object.

    .NOTES
        Module: AzLocal.UpdateManagement (v0.8.5+)
        Roadmap: Step.0 — Authentication Validation and Subscription Scope Report.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$AzureClientId,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReportDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ReportFileName = 'auth-report.xml',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionsJsonFileName = 'subscriptions.json',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionsCsvFileName = 'subscriptions.csv',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 5000)]
        [int]$MaxClusters = 1000,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$InstalledModuleVersion,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$GeneratedAgainstVersion,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$LatestOnPSGallery,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    $pipelineHost = Get-AzLocalPipelineHost

    if (-not $ReportDirectory) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $ReportDirectory = Join-Path -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY -ChildPath 'auth-report'
        }
        else {
            $ReportDirectory = './reports'
        }
    }
    if (-not (Test-Path -LiteralPath $ReportDirectory)) {
        New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
    }

    Write-Host '--- 1. az account show (proves authentication wiring) ---'
    $accountResult = Invoke-AzCliJson -Arguments @('account', 'show')
    if (-not $accountResult.Ok) {
        throw "Export-AzLocalAuthValidationReport: az account show failed - $($accountResult.Error)"
    }
    $account = $accountResult.Data
    if (-not $account) {
        throw "Export-AzLocalAuthValidationReport: az account show returned an empty body. The pipeline identity is not authenticated."
    }
    $account | Format-List name, id, tenantId, user | Out-Host

    if (-not $AzureClientId) {
        if ($account.user -and $account.user.name) {
            $AzureClientId = [string]$account.user.name
            Write-Host "AzureClientId not supplied - derived '$AzureClientId' from az account show (account.user.name)."
        }
    }

    Write-Host ''
    Write-Host '--- 2. role assignments for the pipeline identity (proves RBAC grant) ---'
    if ($AzureClientId) {
        $rolesResult = Invoke-AzCliJson -Arguments @('role', 'assignment', 'list', '--assignee', $AzureClientId, '--all')
        if ($rolesResult.Ok) {
            $rolesRows = @()
            if ($rolesResult.Data) {
                $rolesRows = @($rolesResult.Data | Select-Object roleDefinitionName, principalType, scope)
            }
            if ($rolesRows.Count -gt 0) {
                $rolesRows | Format-Table -AutoSize | Out-Host
            }
            else {
                Write-Host "(no role assignments returned for appId '$AzureClientId' - confirm the App Registration's service principal has RBAC grants on at least one subscription / management group)"
            }
        }
        else {
            $rolesError = if ([string]::IsNullOrWhiteSpace([string]$rolesResult.Error)) { 'Azure CLI returned no error details' } else { [string]$rolesResult.Error }
            Write-Host "(role assignment lookup failed: $rolesError)"
        }
    }
    else {
        Write-Host "(skipped - no AzureClientId supplied and az account show did not expose account.user.name)"
    }

    Write-Host ''
    Write-Host '--- 3. Subscription Scope: enumerating all subscriptions visible to the pipeline identity ---'
    $subsResult = Invoke-AzCliJson -Arguments @('account', 'list', '--refresh', '--query', '[].{name:name, subscriptionId:id, tenantId:tenantId, state:state}')
    if (-not $subsResult.Ok) {
        throw "Export-AzLocalAuthValidationReport: az account list --refresh failed - $($subsResult.Error)"
    }
    $subs = @()
    if ($subsResult.Data) {
        $subs = @($subsResult.Data | Sort-Object name)
    }
    $subCount = $subs.Count
    Write-Host "Count of subscriptions accessible = $subCount"
    if ($subCount -gt 0) {
        $subs | Format-Table @{N='#';E={[array]::IndexOf($subs,$_)+1}}, name, subscriptionId, state -AutoSize | Out-Host
    }

    $subsJsonPath = Join-Path -Path $ReportDirectory -ChildPath $SubscriptionsJsonFileName
    $subsCsvPath  = Join-Path -Path $ReportDirectory -ChildPath $SubscriptionsCsvFileName
    $subsJsonContent = if ($subs.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject $subs -Depth 4 }
    $subsJsonContent | Out-File -FilePath $subsJsonPath -Encoding utf8
    $subs | Select-Object name, subscriptionId, tenantId, state |
        Export-Csv -Path $subsCsvPath -NoTypeInformation -Encoding utf8

    Write-Host ''
    Write-Host '--- 4. Resource Graph query (proves cluster reachability) ---'
    [void](Install-AzGraphExtension)
    $globalTagFilter = Get-AzLocalClusterTagFilterKqlClause
    $clusterKql = "resources | where type =~ 'microsoft.azurestackhci/clusters' $globalTagFilter | project name, resourceGroup, subscriptionId"
    $clusterRows = @()
    try {
        # NOTE: Invoke-AzResourceGraphQuery uses unary-comma return (`return , $allRows.ToArray()`).
        # Direct assignment only - never @() wrap on the call itself, or the entire row set
        # collapses to Object[1] and `Resource Graph reachability` reports `1 cluster(s) visible`
        # no matter the real count.
        $clusterRows = Invoke-AzResourceGraphQuery -Query $clusterKql -First $MaxClusters -ErrorAction Stop
        if ($null -eq $clusterRows) { $clusterRows = @() }
    }
    catch {
        Write-Warning "Cluster ARG query failed: $($_.Exception.Message)"
        $clusterRows = @()
    }
    # v0.8.6: defensive @() on the VARIABLE (not on the helper call) - idempotent
    # on Object[N], turns a bare scalar into Object[1]. Needed when a mock or a
    # future helper-return shape change emits a single PSCustomObject; without
    # this $clusterRows.Count returns $null under strict mode.
    $clusterRows  = @($clusterRows)
    $clusterCount = $clusterRows.Count
    Write-Host "Clusters visible to the pipeline identity = $clusterCount"
    if ($clusterCount -gt 0) {
        $clusterRows | Select-Object -First 10 | Format-Table -AutoSize | Out-Host
    }

    # ------------------------------------------------------------------
    # Build JUnit XML via the shared helper
    # ------------------------------------------------------------------
    $authSuite = @{
        Name      = "&#x1F510; Authentication"
        ClassName = 'Authentication'
        TestCases = @(
            @{
                Name = 'OIDC token exchange (az account show succeeded)'
                SystemOut = "Tenant: $($account.tenantId)`nSubscription: $($account.name) ($($account.id))`nIdentity: $(if ($account.user) { $account.user.name } else { '(none)' })"
            }
            @{ Name = "Default CLI subscription (authentication context only; not fleet scope) = $($account.name)" }
            @{ Name = "Pipeline identity (appId) = $(if ($account.user) { $account.user.name } else { '(none)' })" }
        )
    }

    $subTestCases = @(
        @{ Name = "Count of subscriptions accessible = $subCount" }
    )
    $i = 0
    foreach ($s in $subs) {
        $i++
        $subTestCases += @{ Name = "#$i  $($s.name)  ($($s.subscriptionId))  [$($s.state)]" }
    }
    $subSuite = @{
        Name      = "&#x1F4CB; Subscription Scope (count=$subCount)"
        ClassName = 'SubscriptionScope'
        TestCases = $subTestCases
    }

    $rgSuite = @{
        Name      = "&#x1F310; Resource Graph Reachability"
        ClassName = 'ResourceGraph'
        TestCases = @(
            @{ Name = "Clusters visible to pipeline identity = $clusterCount" }
        )
    }

    $suites = @($authSuite, $subSuite, $rgSuite)

    $emitDriftSuite = ($InstalledModuleVersion -or $GeneratedAgainstVersion -or $LatestOnPSGallery)
    if ($emitDriftSuite) {
        $latestRender = if ($LatestOnPSGallery) { $LatestOnPSGallery } else { '(lookup failed)' }
        $suites += @{
            Name      = "&#x1F4E6; Module Version Drift"
            ClassName = 'ModuleVersion'
            TestCases = @(
                @{ Name = "Installed AzLocal.UpdateManagement = $InstalledModuleVersion" }
                @{ Name = "YAML generated against = $GeneratedAgainstVersion" }
                @{ Name = "Latest on PSGallery = $latestRender" }
            )
        }
    }

    $xmlPath = Join-Path -Path $ReportDirectory -ChildPath $ReportFileName
    [void](New-AzLocalPipelineJUnitXml -TestSuitesName 'Authentication Validation and Subscription Scope Report' -Suites $suites -OutputPath $xmlPath)
    Write-Host "JUnit XML written to: $xmlPath"

    # ------------------------------------------------------------------
    # Build markdown step summary via the shared helper
    # ------------------------------------------------------------------
    $md = [System.Text.StringBuilder]::new()
    [void]$md.AppendLine('## Authentication Validation and Subscription Scope Report')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Check | Result |')
    [void]$md.AppendLine('|---|---|')
    [void]$md.AppendLine("| Authentication | :white_check_mark: working |")
    [void]$md.AppendLine("| Default CLI subscription | $($account.name) (``$($account.id)``) - authentication context only; not fleet scope |")
    [void]$md.AppendLine("| Tenant | ``$($account.tenantId)`` |")
    $identityName = if ($account.user) { $account.user.name } else { '(none)' }
    [void]$md.AppendLine("| Pipeline identity (appId) | ``$identityName`` |")
    [void]$md.AppendLine("| Resource Graph reachability | :white_check_mark: $clusterCount cluster(s) visible |")
    if ($emitDriftSuite) {
        $latestRender = if ($LatestOnPSGallery) { $LatestOnPSGallery } else { '(lookup failed)' }
        [void]$md.AppendLine("| AzLocal.UpdateManagement (installed) | ``$InstalledModuleVersion`` |")
        [void]$md.AppendLine("| AzLocal.UpdateManagement (YAML generated against) | ``$GeneratedAgainstVersion`` |")
        [void]$md.AppendLine("| AzLocal.UpdateManagement (latest on PSGallery) | ``$latestRender`` |")
    }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('The default CLI subscription is selected after login so Azure CLI has an account context. Fleet scope is the accessible-subscription set below, not that default subscription.')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("### Count of subscriptions accessible = $subCount")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('<details>')
    [void]$md.AppendLine('<summary>Expand for subscription details</summary>')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| # | Subscription Name | Subscription ID | Tenant ID | State |')
    [void]$md.AppendLine('|---|---|---|---|---|')
    $i = 0
    foreach ($s in $subs) {
        $i++
        [void]$md.AppendLine("| $i | $($s.name) | ``$($s.subscriptionId)`` | ``$($s.tenantId)`` | $($s.state) |")
    }
    [void]$md.AppendLine('')
    [void]$md.AppendLine('</details>')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("*Generated at $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss UTC'))*")

    [void](Add-AzLocalPipelineStepSummary -Markdown $md.ToString() -SummaryFileName 'auth-report-summary.md')

    # ------------------------------------------------------------------
    # Step outputs (consumed by downstream jobs / steps)
    # ------------------------------------------------------------------
    $authValid = ($null -ne $account) -and ($subCount -gt 0)
    Set-AzLocalPipelineOutput -Name 'subscription_count' -Value ([string]$subCount)
    Set-AzLocalPipelineOutput -Name 'cluster_count'      -Value ([string]$clusterCount)
    Set-AzLocalPipelineOutput -Name 'auth_valid'         -Value ([string]$authValid.ToString().ToLowerInvariant())

    if ($PassThru) {
        return [PSCustomObject]@{
            Account               = $account
            SubscriptionCount     = $subCount
            Subscriptions         = $subs
            ClusterCount          = $clusterCount
            AuthValid             = $authValid
            JUnitXmlPath          = $xmlPath
            SubscriptionsJsonPath = $subsJsonPath
            SubscriptionsCsvPath  = $subsCsvPath
        }
    }
}
