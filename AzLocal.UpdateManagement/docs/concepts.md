# AzLocal.UpdateManagement Concepts and Background

> **What you will find here:** Background on the update lifecycle (states, ARM-direct vs. PowerShell wrappers, Az.StackHCI parity), and the CI/CD automation pattern this module is built for. Useful when first onboarding to the module, or when you need to explain to a colleague why a particular update is "stuck" in a given state.
>
> **Cross-reference:** Operational guidance for individual cmdlets lives in [cmdlet-reference.md](cmdlet-reference.md). Troubleshooting recipes live in [troubleshooting.md](troubleshooting.md).

---

## Update States

### Cluster Update Summary States

| State | Description | Can Start Update? |
|-------|-------------|-------------------|
| `UpdateAvailable` | Updates are available | Yes |
| `AppliedSuccessfully` | All updates applied | No - already up to date |
| `UpdateInProgress` | Update is running | No - wait for completion |
| `UpdateFailed` | Last update failed | Investigate first |
| `NeedsAttention` | Manual intervention needed | Resolve issues first |

### Individual Update States

| State | Description | Can Apply? |
|-------|-------------|------------|
| `Ready` | Update is ready to install | Yes |
| `ReadyToInstall` | Preparation complete | Yes |
| `HasPrerequisite` | Prerequisites required | No - install prerequisites first (see SBE dependency info) |
| `Installing` | Currently installing | No - in progress |
| `Installed` | Successfully installed | No - already done |
| `InstallationFailed` | Installation failed | Retry or investigate |

## Using Azure CLI Directly

You can also use `az rest` commands directly:

```powershell
# List all clusters in subscription
az rest --method GET --uri "https://management.azure.com/subscriptions/{subscriptionId}/providers/Microsoft.AzureStackHCI/clusters?api-version=2025-10-01"

# Get update summary
az rest --method GET --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}/updateSummaries/default?api-version=2025-10-01"

# List available updates
az rest --method GET --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}/updates?api-version=2025-10-01"

# Apply an update (no body required)
az rest --method POST --uri "https://management.azure.com/subscriptions/{subscriptionId}/resourceGroups/{resourceGroup}/providers/Microsoft.AzureStackHCI/clusters/{clusterName}/updates/{updateName}/apply?api-version=2025-10-01"
```

## Alternative: Az.StackHCI PowerShell Module

Microsoft also provides native PowerShell cmdlets in the `Az.StackHCI` module:

```powershell
# Install the module
Install-Module -Name Az.StackHCI -Force

# Apply an update
Invoke-AzStackHciUpdate -ClusterName 'MyCluster' -Name 'Solution12.2601.1002.38' -ResourceGroupName 'MyRG'
```

## CI/CD Automation

> **The complete CI/CD guide lives in [Automation-Pipeline-Examples/README.md](../Automation-Pipeline-Examples/README.md).** It covers OIDC / Managed Identity / Service Principal setup, federated credentials, GitHub Actions and Azure DevOps templates, and automation diagrams. **Start there for any pipeline work.** This section only documents the module-level features that pipelines depend on.

The module is pipeline-friendly out of the box:

- **Authentication**: works with OIDC (recommended), Managed Identity, or Service Principal + secret. See `Connect-AzLocalServicePrincipal` and the pipeline guide above.
- **JUnit XML export**: any function that takes `-ExportPath` / `-ExportResultsPath` will emit JUnit XML when the path ends in `.xml`. Consumed natively by Azure DevOps **Publish Test Results**, GitHub Actions (`dorny/test-reporter`, `mikepenz/action-junit-report`), Jenkins, GitLab CI (`artifacts:reports:junit`), and TeamCity.
- **CSV / JSON export**: pass `.csv` or `.json` for the same paths to drive downstream reporting / Power BI / Log Analytics ingestion.
- **`-WhatIf` and `-PassThru`**: every state-changing function supports `-WhatIf` (counted as `WouldUpdate` in the summary) so dry-runs are auditable; `-PassThru` returns structured objects for pipeline-stage chaining.
- **Parallelism**: `-ThrottleLimit 1..16` on per-cluster operations; default 4. Tune for your runner and ARM throttling envelope.

Minimal example - export update results as JUnit XML:

```powershell
Start-AzLocalClusterUpdate -ScopeByUpdateRingTag -UpdateRingValue 'Ring1' -Force `
    -ExportResultsPath './test-results/update-results.xml'
```

For full GitHub Actions / Azure DevOps YAML, federated-credential setup, and the recommended two-stage "collect once, render later" pattern, see [Automation-Pipeline-Examples/README.md](../Automation-Pipeline-Examples/README.md).

<!-- Detailed CI/CD examples removed in v0.7.1; canonical content now in Automation-Pipeline-Examples/README.md -->

