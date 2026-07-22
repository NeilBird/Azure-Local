# AzLocal.UpdateManagement Troubleshooting

> **What you will find here:** Symptom-to-fix table for common failure modes (auth errors, RBAC gaps, ARM polling timeouts, KQL `ParserFailure: token=<EOF>`, healthCheckResult duplicates, etc.) plus a handful of "did you forget X" reminders. Look here first when a pipeline step fails.
>
> **Cross-reference:** Recurring fixes that change behaviour are also written up in [release-history.md](release-history.md) under the version that shipped them.

---

## Troubleshooting

### Common Issues

1. **"Cluster not found"**: Verify the cluster name and ensure you have access to the subscription.

2. **"No updates available"**: The cluster may already be up to date. Check the update summary state.

3. **"Update not in Ready state"**: Updates may be downloading or have prerequisites. Check the update's state property.

4. **"Cluster not in valid state"**: The cluster must be "Connected" and the update summary state must be "UpdateAvailable".

5. **"Service Principal authentication failed"**: Verify the `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, and `AZURE_TENANT_ID` values are correct and the Service Principal has the required permissions.

### ARG `ResponsePayloadTooLarge` / response exceeds 16 MiB

**Symptom**

- A fleet pipeline fails in `az graph query` with code `ResponsePayloadTooLarge` and text similar to `Response payload size ... exceeded the limit of 16777216`.
- The fleet can contain fewer than 1,000 clusters, so the failure appears even though ordinary row-count pagination should not yet be necessary.

**Cause**

ARG limits response bytes independently of its 1,000-row maximum. Dynamic arrays such as `properties.healthCheckResult`, nested update-run progress trees, or unprojected full resource documents can exceed 16 MiB before ARG returns the first page or a `skip_token`.

**Fix**

Upgrade to **AzLocal.UpdateManagement v0.9.22 or later**. Every ARG-backed cmdlet uses the shared `Invoke-AzResourceGraphQuery` helper, which now halves `--first` and retries the same page when this error occurs. Monitor: 1 also projects lean response shapes, and Monitor: 2 begins its intentionally dynamic health-result query at 50 cluster rows.

If the error says **one result row exceeds the ARG response payload limit**, that individual resource is too large to fix through paging. Reduce the fields returned by the custom KQL query; do not increase `MaxPages`, because pagination cannot begin until one page succeeds.

### `WARNING: Unable to encode the output with cp1252 encoding`

**Symptom**

- One or more `WARNING: Unable to encode the output with cp1252 encoding. Unsupported characters are discarded.` lines appear in the module's verbose/output stream, often interspersed with empty result tables.
- `Get-AzLocalUpdateRuns`, `Get-AzLocalAvailableUpdates`, or `Get-AzLocalFleetStatusData` returns placeholder `Error` rows for some clusters with otherwise valid Azure access.
- Affected clusters typically have non-ASCII characters somewhere in the ARM payload (smart quotes / accented characters in tag values, localised health-check messages, etc.).

**Cause**

On Windows hosts where the console code page is `cp1252` (the English-US default - includes default GitHub `windows-latest` runners and Azure DevOps `windows-2022` agents), the Azure CLI emits this warning to stderr whenever it cannot encode a response character. Captured via `2>&1` it is prepended to the JSON body and breaks `ConvertFrom-Json`. Setting `$env:PYTHONIOENCODING = 'utf-8'` does **not** help: `az.cmd` launches Python with `-I` (isolated mode), which causes Python to ignore all `PYTHON*` environment variables ([Azure/azure-cli#28497](https://github.com/Azure/azure-cli/issues/28497)).

**Fix**

Upgrade to **AzLocal.UpdateManagement v0.7.2 or later**. The module passes `--only-show-errors` to every `az rest` / `az graph query` invocation, which suppresses the warning at source ([Azure/azure-cli#14426](https://github.com/Azure/azure-cli/issues/14426)). Genuine errors (auth failures, 4xx/5xx ARM responses, invalid args) still surface normally.

```powershell
# Verify your installed module version is >= 0.7.2
(Get-Module AzLocal.UpdateManagement -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version
```

If you still see the warning after upgrading, you are most likely calling `az` directly outside the module (e.g. in a custom pre/post step). Add `--only-show-errors` to your direct calls.

### ARM is stale - readiness recommends an already-installed update

**Symptom**

- `Get-AzLocalClusterUpdateReadiness` recommends an update that is already installed on the cluster (e.g. portal shows `CurrentVersion = 12.2603.1002.500` but `RecommendedUpdate = Solution12.2603.1002.500`).
- Azure portal shows contradictory banners on the cluster **Updates** blade ("Update(s) available" header + "There is no update available to install" banner).
- `updateSummaries.lastChecked` / `lastUpdated` timestamps are hours or days old.
- Running `Get-SolutionUpdate` on a cluster node shows the correct state (the newer update as `Ready`, older ones as `Installed`), but the ARM `/updates` and `/updateSummaries` child resources do not reflect it.

**Cause**

The `Azure Stack HCI Update Service` is a **manual-start, on-demand** Windows service on each cluster node. It is the component that pushes `/updates` and `/updateSummaries` state to ARM. If it has not been triggered recently (by the LCM scheduler or by a user action), ARM's view of the cluster drifts out of sync with the node-local `Get-SolutionUpdate` store. The module correctly reports what ARM returns - ARM is wrong, not the module.

Note: v0.7.0+ `Get-AzLocalClusterUpdateReadiness` already mitigates this by short-circuiting to `UpToDate` when every entry in `/updates` is in the terminal `Installed` state, even if `updateSummaries.state` is stale. But once a genuinely new update (like `Solution12.2604.xxxx`) is published, the staleness becomes visible again until ARM is refreshed.

**Fix**

Start the update service on every node. It will reconcile with local LCM and push to ARM, then return to `Stopped` (that is normal - it is a one-shot worker, not a daemon):

```powershell
# From any machine with WinRM access to the cluster nodes:
$nodes = (Get-ClusterNode -Cluster <ClusterName>).Name
Invoke-Command -ComputerName $nodes -ScriptBlock {
    Write-Host "[$env:COMPUTERNAME] Starting 'Azure Stack HCI Update Service'..."
    Start-Service -Name 'Azure Stack HCI Update Service' -ErrorAction Continue
    Start-Sleep 3
    Get-Service 'Azure Stack HCI Update Service', 'HciCloudManagementSvc',
                'Azure Stack HCI Orchestrator Service' |
        Format-Table Name, Status, StartType -AutoSize
}
```

Give it ~2-5 minutes, then re-check ARM:

```powershell
$rid = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.AzureStackHCI/clusters/<ClusterName>'
(az rest --method get --uri "https://management.azure.com$rid/updateSummaries?api-version=2025-10-01" |
    ConvertFrom-Json).value[0].properties |
    Select-Object state, currentVersion, lastChecked, lastUpdated
```

`lastChecked` should jump to a recent timestamp and `currentVersion` should match what `Get-SolutionUpdate` shows on the node.

**If it still does not refresh**

Check the ECE/HCI event logs on a node for push errors:

```powershell
Get-WinEvent -LogName Application -ProviderName ECEAgent -MaxEvents 30 |
    Select-Object TimeCreated, LevelDisplayName, Message | Format-List
```

Look for repeated ARM or `UpdateService` failures. If the Arc connected-machine agent (`himds`, `GCArcService`, `ExtensionService`) is unhealthy, the push side will be blocked regardless - `azcmagent show` on each node confirms Arc connectivity.

### Verbose Logging

Enable verbose output for debugging:

```powershell
Start-AzLocalClusterUpdate -ClusterNames "MyCluster" -Verbose
```

