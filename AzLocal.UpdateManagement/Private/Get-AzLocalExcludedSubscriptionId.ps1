function Get-AzLocalExcludedSubscriptionId {
    ########################################
    <#
    .SYNOPSIS
        Returns the subscription IDs that are currently being excluded from all
        Azure Resource Graph queries this session.

    .DESCRIPTION
        v0.9.1 lazy resolver for the optional subscription exclusion list. The
        effective list is determined once per process in this precedence order:

          1. EXPLICIT module state (highest priority): if an operator called
             Set-AzLocalExcludedSubscription this session, that list wins and
             the environment variable is ignored.
          2. ENVIRONMENT VARIABLE auto-load: if AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH
             is set and points at an existing CSV, the file is parsed and
             validated via Resolve-AzLocalExcludedSubscriptionId. This is the
             zero-wiring CI/CD "single source of truth" path: set the variable
             once at the pipeline level and every step's fresh process
             auto-loads it.
          3. NONE: otherwise the list is empty and nothing is excluded.

        The environment-variable resolution runs at most once per process (the
        result is cached in module scope), so the warning emitted for a
        header-only / missing / unreadable file fires once - not on every ARG
        call. A header-only file is NOT an error: it resolves to an empty list
        with a warning so the operator knows the variable is wired but no
        subscriptions are actually excluded.

    .OUTPUTS
        [string[]] of lowercased subscription-id GUIDs (possibly empty).

    .NOTES
        Author : AzLocal.UpdateManagement
        Version: 0.9.1
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    Set-StrictMode -Version Latest

    if ($script:ExcludedSubscriptionsExplicit) {
        return $script:ExcludedSubscriptionIds
    }

    if (-not $script:ExcludedSubscriptionsResolved) {
        $script:ExcludedSubscriptionsResolved = $true

        $envPath = $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH
        if (-not [string]::IsNullOrWhiteSpace($envPath)) {
            if (Test-Path -LiteralPath $envPath -PathType Leaf) {
                try {
                    $result = Resolve-AzLocalExcludedSubscriptionId -Path $envPath
                    $script:ExcludedSubscriptionIds = $result.SubscriptionIds
                    $script:ExcludedSubscriptionSource = $envPath

                    if ($result.SubscriptionIds.Count -eq 0) {
                        Write-Warning ("AzLocal: AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH points at '{0}' but it contains no valid subscription IDs (header-only file or all rows invalid). No subscriptions will be excluded from Azure Resource Graph queries." -f $envPath)
                    }
                    else {
                        Write-Verbose ("AzLocal: loaded {0} excluded subscription ID(s) from '{1}'." -f $result.SubscriptionIds.Count, $envPath)
                    }

                    if ($result.Skipped.Count -gt 0) {
                        $badValues = (@($result.Skipped | ForEach-Object { $_.Value }) -join ', ')
                        Write-Warning ("AzLocal: {0} row(s) in '{1}' were skipped because they are not valid GUIDs: {2}." -f $result.Skipped.Count, $envPath, $badValues)
                    }
                }
                catch {
                    Write-Warning ("AzLocal: failed to read AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH '{0}': {1}. No subscriptions will be excluded." -f $envPath, $_.Exception.Message)
                    $script:ExcludedSubscriptionIds = @()
                }
            }
            else {
                Write-Warning ("AzLocal: AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH is set to '{0}' but the file was not found. No subscriptions will be excluded from Azure Resource Graph queries." -f $envPath)
            }
        }
    }

    return $script:ExcludedSubscriptionIds
}
