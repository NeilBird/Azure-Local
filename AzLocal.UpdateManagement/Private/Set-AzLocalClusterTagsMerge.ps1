function Set-AzLocalClusterTagsMerge {
    <#
    .SYNOPSIS
        Merges a set of tag key/value pairs into an Azure Local cluster's tags via the
        ARM tags subresource.
    .DESCRIPTION
        Private helper that performs an additive tag merge on a single Azure Local
        cluster resource using the generic ARM tags subresource:

            PATCH https://management.azure.com{resourceId}/providers/Microsoft.Resources/tags/default?api-version=2021-04-01

        Two PATCH operations are emitted when needed:
          - operation=Merge  for any tag key being set/overwritten (non-$null value)
          - operation=Delete for any tag key whose value is $null in the input

        Existing tags not mentioned in the input are preserved by the subresource
        contract; no read-modify-write of the cluster body is required.

        RBAC: this path requires only Microsoft.Resources/tags/* (Tag Contributor)
        on the resource, plus read on the resource group. It does NOT require the
        broader microsoft.azurestackhci/clusters/write that the old full-PATCH
        approach demanded, which is what v0.7.62 fixes.

        Used by:
        - Start-AzLocalClusterUpdate to write UpdateVersionInProgress at update start.
        - Reset-AzLocalSideloadedTag (and the auto-reset path in Get-AzLocalUpdateRuns)
          to flip UpdateSideloaded=False and clear UpdateVersionInProgress on matched success.

        Failures are surfaced as terminating errors so callers can wrap in try/catch and
        decide whether to treat the failure as fatal (reset) or warn-and-continue (start).
    .PARAMETER ClusterResourceId
        The full ARM resource ID of the microsoft.azurestackhci/clusters resource.
    .PARAMETER Tags
        Hashtable of tag keys to set. Use $null as a value to remove a tag key.
    .PARAMETER ApiVersion
        Retained for backward compatibility with existing callers; ignored. The tags
        subresource always uses api-version=2021-04-01.
    .OUTPUTS
        [bool] - $true on success. Throws on failure.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ClusterResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [hashtable]$Tags,

        [Parameter(Mandatory = $false)]
        [string]$ApiVersion = $script:DefaultApiVersion
    )

    if ($Tags.Count -eq 0) {
        Write-Verbose "Set-AzLocalClusterTagsMerge: no tags supplied; nothing to do."
        return $true
    }

    if (-not (Test-AzLocalClusterResourceInGlobalScope -ClusterResourceId $ClusterResourceId)) {
        throw "GlobalFilterMismatch: cluster '$ClusterResourceId' does not match the configured scope.clusterTagFilters policy. No tags were changed."
    }

    # Tags subresource is implemented by ARM itself (not by the HCI RP) and uses a
    # fixed api-version. Do not substitute the cluster RP's api-version here.
    $tagsApiVersion = '2021-04-01'
    $tagsUri = "https://management.azure.com$ClusterResourceId/providers/Microsoft.Resources/tags/default`?api-version=$tagsApiVersion"

    # Split incoming Tags into merge-set (keys to set/overwrite) and delete-set
    # (keys whose requested value is $null, meaning remove).
    $toMergeRequested  = [ordered]@{}
    $toDeleteRequested = [ordered]@{}
    foreach ($key in $Tags.Keys) {
        if ($null -eq $Tags[$key]) {
            $toDeleteRequested[$key] = $true
        }
        else {
            $toMergeRequested[$key] = [string]$Tags[$key]
        }
    }

    # Read current tags via the tags subresource (requires Microsoft.Resources/tags/read).
    # This is what enables idempotency: skip PATCHes that would be a no-op against
    # the cluster's current state.
    # v0.7.67: route through Invoke-AzRestJson so the stderr/stdout stream-split
    # + JSON parse error handling is centralised. The previous inline pattern
    # (`$json = az rest ... 2>&1; $existing = $json | ConvertFrom-Json`) silently
    # corrupted parsing whenever the CLI emitted a stderr warning (e.g. the
    # cp1252 encode warning on non-UTF-8 Windows runners) - and since this is
    # the WRITE path for every tag operation, a stray warning would throw and
    # abort tag writes across the fleet.
    $tagsResp = Invoke-AzRestJson -Uri $tagsUri -Method GET
    if (-not $tagsResp.Ok) {
        throw "Set-AzLocalClusterTagsMerge: failed to read tags subresource for '$ClusterResourceId': $($tagsResp.Error)"
    }
    $existing = $tagsResp.Data
    $existingTags = @{}
    if ($existing -and $existing.properties -and $existing.properties.tags) {
        foreach ($prop in $existing.properties.tags.PSObject.Properties) {
            if ($prop.MemberType -eq 'NoteProperty') {
                $existingTags[$prop.Name] = [string]$prop.Value
            }
        }
    }

    # Idempotency: only Merge keys whose value differs from what's already on the resource.
    $toMerge = [ordered]@{}
    foreach ($key in $toMergeRequested.Keys) {
        $current = if ($existingTags.ContainsKey($key)) { $existingTags[$key] } else { $null }
        if ($null -eq $current -or $current -cne $toMergeRequested[$key]) {
            $toMerge[$key] = $toMergeRequested[$key]
        }
    }
    # Idempotency: only Delete keys that actually exist on the resource. ARM's Delete
    # operation expects a {key:value} dictionary; we pass the existing value (its
    # content is not used for matching, only the key is, but ARM requires the shape).
    $toDelete = [ordered]@{}
    foreach ($key in $toDeleteRequested.Keys) {
        if ($existingTags.ContainsKey($key)) {
            $toDelete[$key] = $existingTags[$key]
        }
    }

    if ($toMerge.Count -eq 0 -and $toDelete.Count -eq 0) {
        Write-Verbose "Set-AzLocalClusterTagsMerge: no tag changes for '$ClusterResourceId'; skipping PATCH."
        return $true
    }

    $describe = (@($Tags.Keys | ForEach-Object { "$_=$($Tags[$_])" })) -join ', '
    if (-not $PSCmdlet.ShouldProcess($ClusterResourceId, "Merge/Delete tags ($describe)")) {
        return $true
    }

    # Emit up to two PATCHes against the tags subresource: Merge first (to set
    # values), then Delete (to remove keys). Order matters only insofar as ARM
    # processes each request independently; this ordering matches operator
    # intent of "stage new value before removing the old breadcrumb".
    if ($toMerge.Count -gt 0) {
        $mergeBodyObj = [PSCustomObject]@{
            operation  = 'Merge'
            properties = [PSCustomObject]@{ tags = [PSCustomObject]$toMerge }
        }
        $mergeBody = $mergeBodyObj | ConvertTo-Json -Compress -Depth 10
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            Write-Utf8NoBomFile -Path $tempFile -Content $mergeBody
            $patchResult = az rest --method PATCH --uri $tagsUri --body "@$tempFile" --headers "Content-Type=application/json" --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) {
                $scrubbed = ConvertTo-ScrubbedCliOutput -Text ($patchResult | Out-String).Trim()
                throw "Set-AzLocalClusterTagsMerge: PATCH (Merge) failed for '$ClusterResourceId': $scrubbed"
            }
        }
        finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue -WhatIf:$false }
        }
    }

    if ($toDelete.Count -gt 0) {
        $deleteBodyObj = [PSCustomObject]@{
            operation  = 'Delete'
            properties = [PSCustomObject]@{ tags = [PSCustomObject]$toDelete }
        }
        $deleteBody = $deleteBodyObj | ConvertTo-Json -Compress -Depth 10
        $tempFile = [System.IO.Path]::GetTempFileName()
        try {
            Write-Utf8NoBomFile -Path $tempFile -Content $deleteBody
            $patchResult = az rest --method PATCH --uri $tagsUri --body "@$tempFile" --headers "Content-Type=application/json" --only-show-errors 2>&1
            if ($LASTEXITCODE -ne 0) {
                $scrubbed = ConvertTo-ScrubbedCliOutput -Text ($patchResult | Out-String).Trim()
                throw "Set-AzLocalClusterTagsMerge: PATCH (Delete) failed for '$ClusterResourceId': $scrubbed"
            }
        }
        finally {
            if (Test-Path $tempFile) { Remove-Item $tempFile -Force -ErrorAction SilentlyContinue -WhatIf:$false }
        }
    }

    return $true
}
