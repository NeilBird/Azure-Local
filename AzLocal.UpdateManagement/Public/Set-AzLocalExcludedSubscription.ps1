function Set-AzLocalExcludedSubscription {
    ########################################
    <#
    .SYNOPSIS
        Sets, or clears, the subscription IDs that are excluded from all
        AzLocal.UpdateManagement Azure Resource Graph queries this session.

    .DESCRIPTION
        v0.9.1 explicit override for the optional subscription exclusion list.
        Use this for interactive / local runs, or in a pipeline step that wants
        to load the list programmatically rather than via the
        AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH environment variable.

        An explicit call takes precedence over the environment variable for the
        remainder of the process. Excluded subscriptions are filtered out
        centrally inside Invoke-AzResourceGraphQuery, so every cmdlet and report
        (inventory, readiness, fleet status, update runs, ...) inherits the
        exclusion automatically.

        Three mutually exclusive modes:

          -Path <csv>            : load + validate the exclusion list from a CSV
                                   (same format as the AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH
                                   file: only the "Subscription IDs" column is read).
          -SubscriptionId <ids>  : set the list directly from one or more GUIDs.
          -Clear                 : remove all exclusions for this session
                                   (subsequent queries exclude nothing, and the
                                   environment variable is NOT re-consulted).

        A header-only CSV (or a -SubscriptionId list with no valid GUIDs) does
        NOT fail: the list is set to empty and a warning is emitted, because an
        empty list simply means "exclude nothing".

    .PARAMETER Path
        Path to the exclusion CSV. Only the "Subscription IDs" column is read;
        non-GUID values are skipped with a warning.

    .PARAMETER SubscriptionId
        One or more subscription-id GUIDs to exclude. Non-GUID values are
        skipped with a warning.

    .PARAMETER Clear
        Clears all exclusions for this session.

    .PARAMETER PassThru
        Returns the resulting exclusion state (same shape as
        Get-AzLocalExcludedSubscription). By default the cmdlet writes nothing
        to the pipeline.

    .OUTPUTS
        None by default. With -PassThru, a [PSCustomObject] describing the
        resulting exclusion state.

    .EXAMPLE
        Set-AzLocalExcludedSubscription -Path ./config/Excluded-Subscription-Ids.csv

        Loads the exclusion list from a CSV for the current session.

    .EXAMPLE
        Set-AzLocalExcludedSubscription -SubscriptionId '11111111-1111-1111-1111-111111111111' -PassThru

        Excludes a single subscription and returns the resulting state.

    .EXAMPLE
        Set-AzLocalExcludedSubscription -Clear

        Removes all subscription exclusions for this session.

    .NOTES
        Author : AzLocal.UpdateManagement
        Version: 0.9.1
    #>
    ########################################
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low', DefaultParameterSetName = 'Path')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Path')]
        [string]$Path,

        [Parameter(Mandatory = $true, ParameterSetName = 'List')]
        [string[]]$SubscriptionId,

        [Parameter(Mandatory = $true, ParameterSetName = 'Clear')]
        [switch]$Clear,

        [Parameter(Mandatory = $false)]
        [switch]$PassThru
    )

    Set-StrictMode -Version Latest

    switch ($PSCmdlet.ParameterSetName) {
        'Clear' {
            if ($PSCmdlet.ShouldProcess('AzLocal subscription exclusion list', 'Clear all exclusions for this session')) {
                $script:ExcludedSubscriptionIds = @()
                $script:ExcludedSubscriptionSource = 'Explicit:Cleared'
                $script:ExcludedSubscriptionsExplicit = $true
                $script:ExcludedSubscriptionsResolved = $true
                Write-Verbose 'AzLocal: subscription exclusion list cleared for this session.'
            }
        }
        'Path' {
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "Set-AzLocalExcludedSubscription: file not found: '$Path'."
            }
            if ($PSCmdlet.ShouldProcess($Path, 'Load AzLocal subscription exclusion list')) {
                $result = Resolve-AzLocalExcludedSubscriptionId -Path $Path
                $script:ExcludedSubscriptionIds = $result.SubscriptionIds
                $script:ExcludedSubscriptionSource = $Path
                $script:ExcludedSubscriptionsExplicit = $true
                $script:ExcludedSubscriptionsResolved = $true

                if ($result.SubscriptionIds.Count -eq 0) {
                    Write-Warning ("AzLocal: '{0}' contains no valid subscription IDs (header-only file or all rows invalid). No subscriptions will be excluded." -f $Path)
                }
                else {
                    Write-Verbose ("AzLocal: loaded {0} excluded subscription ID(s) from '{1}'." -f $result.SubscriptionIds.Count, $Path)
                }

                if ($result.Skipped.Count -gt 0) {
                    $badValues = (@($result.Skipped | ForEach-Object { $_.Value }) -join ', ')
                    Write-Warning ("AzLocal: {0} row(s) in '{1}' were skipped because they are not valid GUIDs: {2}." -f $result.Skipped.Count, $Path, $badValues)
                }
            }
        }
        'List' {
            if ($PSCmdlet.ShouldProcess('AzLocal subscription exclusion list', 'Set exclusions from supplied subscription IDs')) {
                $validList = [System.Collections.Generic.List[string]]::new()
                $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                $skipped = [System.Collections.Generic.List[string]]::new()

                foreach ($sid in $SubscriptionId) {
                    if ([string]::IsNullOrWhiteSpace($sid)) { continue }
                    $trimmed = $sid.Trim()
                    $parsed = [guid]::Empty
                    if ([guid]::TryParse($trimmed, [ref]$parsed)) {
                        $normalized = $parsed.ToString().ToLower()
                        if ($seen.Add($normalized)) {
                            $validList.Add($normalized)
                        }
                    }
                    else {
                        $skipped.Add($trimmed)
                    }
                }

                $script:ExcludedSubscriptionIds = $validList.ToArray()
                $script:ExcludedSubscriptionSource = 'Explicit:Parameter'
                $script:ExcludedSubscriptionsExplicit = $true
                $script:ExcludedSubscriptionsResolved = $true

                if ($validList.Count -eq 0) {
                    Write-Warning 'AzLocal: no valid subscription IDs were supplied. No subscriptions will be excluded.'
                }
                if ($skipped.Count -gt 0) {
                    Write-Warning ("AzLocal: {0} supplied value(s) were skipped because they are not valid GUIDs: {1}." -f $skipped.Count, ($skipped.ToArray() -join ', '))
                }
            }
        }
    }

    if ($PassThru.IsPresent) {
        $ids = @($script:ExcludedSubscriptionIds)
        return [PSCustomObject]@{
            SubscriptionIds = $ids
            Count           = $ids.Count
            Source          = $script:ExcludedSubscriptionSource
            IsExplicit      = [bool]$script:ExcludedSubscriptionsExplicit
        }
    }
}
