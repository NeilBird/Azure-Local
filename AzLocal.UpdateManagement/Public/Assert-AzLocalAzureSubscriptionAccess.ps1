function Assert-AzLocalAzureSubscriptionAccess {
    <#
    .SYNOPSIS
        Fails the pipeline step with a meaningful run-summary message when the
        authenticated identity can see no Azure subscriptions.

    .DESCRIPTION
        Every AzLocal.UpdateManagement monitoring / update pipeline runs
        fleet-wide Azure Resource Graph queries across EVERY subscription the
        federated identity can read. When `azure/login` (GitHub) or
        `AzureCLI@2` (Azure DevOps) authenticates successfully but the identity
        has zero subscription role assignments, `az login` may still fail hard
        with the cryptic "No subscriptions found for ***", OR the login
        "succeeds" and every downstream ARG query silently returns nothing -
        producing empty reports and a confusing cascade (e.g. the JUnit publish
        step then reports "No test report files were found").

        This cmdlet turns that failure mode into ONE clear, actionable message:
          1. Enumerates the subscriptions visible to the current `az` context
             (`az account list --output json`).
          2. Counts the ENABLED subscriptions.
          3. If the enabled count is below -MinimumCount:
               - emits a red `::error` / `##vso[task.logissue type=error]`
                 annotation via Write-AzLocalPipelineError,
               - writes a rich remediation block to the run summary via
                 Add-AzLocalPipelineStepSummary (so the operator does NOT have
                 to expand the step logs),
               - sets the `subscription_count` step output to 0,
               - throws a concise terminating error so the step exits non-zero.
          4. Otherwise it writes a one-line confirmation to the summary, sets
             the `subscription_count` step output, and (with -PassThru) returns
             the enabled count.

        Host detection (GitHub / AzureDevOps / Local) flows through the existing
        Private helpers - no per-host branching here.

    .PARAMETER MinimumCount
        Minimum number of ENABLED subscriptions that must be visible for the
        step to pass. Defaults to 1.

    .PARAMETER SubscriptionListJson
        Optional. The raw JSON array normally returned by
        `az account list --output json`. When supplied, the cmdlet does NOT
        shell out to `az` (used by unit tests and by callers that already have
        the account list in hand). When omitted, the cmdlet runs
        `az account list --output json` itself.

    .PARAMETER SummaryFileName
        Forwarded to Add-AzLocalPipelineStepSummary. Defaults to
        'azlocal-subscription-access.md'. Ignored on GitHub Actions (which uses
        a single $env:GITHUB_STEP_SUMMARY file managed by the runner).

    .PARAMETER PassThru
        When set, returns the count of enabled subscriptions on success.

    .OUTPUTS
        Nothing by default. With -PassThru, returns an [int] enabled count.
        Throws a terminating error when the enabled count is below
        -MinimumCount.

    .EXAMPLE
        Assert-AzLocalAzureSubscriptionAccess

        Default gate placed immediately after the Azure login step(s). Fails the
        job with a remediation block on the run summary when no subscriptions
        are visible.

    .EXAMPLE
        $count = Assert-AzLocalAzureSubscriptionAccess -MinimumCount 2 -PassThru
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$MinimumCount = 1,

        [Parameter()]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$SubscriptionListJson,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SummaryFileName = 'azlocal-subscription-access.md',

        [Parameter()]
        [switch]$PassThru
    )

    # 1. Obtain the account list (inject for tests, else shell out to az).
    $rawJson = $SubscriptionListJson
    if (-not $PSBoundParameters.ContainsKey('SubscriptionListJson')) {
        try {
            $rawJson = (& az account list --output json 2>$null | Out-String)
        } catch {
            $rawJson = ''
            Write-Verbose "Assert-AzLocalAzureSubscriptionAccess: 'az account list' threw - $($_.Exception.Message)"
        }
    }

    # 2. Parse. A missing / empty / non-array payload is treated as zero subscriptions.
    $accounts = @()
    if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
        try {
            $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed) { $accounts = @($parsed) }
        } catch {
            Write-Verbose "Assert-AzLocalAzureSubscriptionAccess: could not parse 'az account list' JSON - $($_.Exception.Message)"
            $accounts = @()
        }
    }

    $totalCount = $accounts.Count
    $enabled = @($accounts | Where-Object {
            $_.PSObject.Properties['state'] -and $_.state -and ($_.state -ieq 'Enabled')
        })
    # If the payload does not carry a 'state' field at all, fall back to counting
    # every returned account as accessible (older az versions / injected fixtures).
    $enabledCount = if ($accounts | Where-Object { $_.PSObject.Properties['state'] }) {
        $enabled.Count
    } else {
        $totalCount
    }

    # 3. Failure path: below the minimum -> meaningful error + run-summary block + throw.
    if ($enabledCount -lt $MinimumCount) {
        $stateNote = if ($totalCount -gt $enabledCount) {
            "The identity CAN see $totalCount subscription(s) but only $enabledCount is/are in the 'Enabled' state."
        } else {
            "The identity can see $enabledCount subscription(s) (need at least $MinimumCount)."
        }

        $summary = @"
## :x: Azure login returned no accessible subscriptions

$stateNote

This pipeline runs **fleet-wide** Azure Resource Graph queries across every
subscription the federated identity can read. With no accessible subscription,
every query returns nothing, reports are empty, and downstream steps (e.g. the
JUnit "Publish Results" step) fail with misleading errors such as
``No test report files were found``. The real cause is subscription access, not
the reporting step.

### How to fix
1. **Assign an RBAC role** to the pipeline's service principal / federated
   identity. It needs at least **Reader** on each target subscription (or on a
   management group that contains them); update operations need the appropriate
   write role. Zero role assignments = zero visible subscriptions.
2. **Confirm the tenant**: check that ``AZURE_TENANT_ID`` points to the tenant
   that owns the Azure Local clusters' subscriptions.
3. **Confirm the identity**: check that ``AZURE_CLIENT_ID`` is the intended app
   registration / managed identity (not a stale or wrong-tenant one).
4. If subscriptions exist but are not ``Enabled``, re-enable them (or clear any
   billing / policy hold) before re-running.

_Verified via ``az account list`` after the Azure login step._
"@

        Write-AzLocalPipelineError `
            -Title 'Azure login returned no accessible subscriptions' `
            -Message ("This pipeline needs at least $MinimumCount accessible (Enabled) Azure subscription but found $enabledCount. " +
                'Assign the federated identity at least Reader on the target subscription(s) or management group, and confirm AZURE_TENANT_ID / AZURE_CLIENT_ID. See the run summary for full remediation steps.')

        [void](Add-AzLocalPipelineStepSummary -Markdown $summary -SummaryFileName $SummaryFileName)
        Set-AzLocalPipelineOutput -Name 'subscription_count' -Value $enabledCount.ToString()

        throw "Assert-AzLocalAzureSubscriptionAccess: no accessible Azure subscriptions (found $enabledCount, need $MinimumCount). See the run summary for remediation."
    }

    # 4. Success path.
    Write-Host "Azure subscription access verified: $enabledCount enabled subscription(s) visible to the pipeline identity."
    $okSummary = "_Azure subscription access verified: **$enabledCount** enabled subscription(s) visible to the pipeline identity._`n"
    [void](Add-AzLocalPipelineStepSummary -Markdown $okSummary -SummaryFileName $SummaryFileName)
    Set-AzLocalPipelineOutput -Name 'subscription_count' -Value $enabledCount.ToString()

    if ($PassThru) { return $enabledCount }
}
