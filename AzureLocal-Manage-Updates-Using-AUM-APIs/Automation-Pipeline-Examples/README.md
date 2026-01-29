# CI/CD Pipeline Examples for Azure Local Cluster Update Management

This folder contains example CI/CD pipelines for automating Azure Local cluster update management using GitHub Actions and Azure DevOps.

## Overview

Three pipelines are provided for each platform:

| Pipeline | Description |
|----------|-------------|
| **Inventory Clusters** | Queries all Azure Local clusters and exports inventory to CSV with UpdateRing tag status |
| **Manage UpdateRing Tags** | Creates or updates UpdateRing tags on clusters from a CSV file |
| **Apply Updates** | Applies updates to clusters filtered by UpdateRing tag value |

## Prerequisites

Before using these pipelines, you need:

1. **Azure Subscription** with Azure Local (Azure Stack HCI) clusters
2. **Service Principal** with appropriate permissions
3. **CI/CD Platform** (GitHub or Azure DevOps)

---

## Service Principal Setup

### Step 1: Create the Service Principal

Run this command in Azure CLI to create a Service Principal with the required permissions:

```bash
# Create Service Principal with Azure Stack HCI Administrator role
az ad sp create-for-rbac \
    --name "AzureLocal-UpdateAutomation" \
    --role "Azure Stack HCI Administrator" \
    --scopes /subscriptions/{your-subscription-id}
```

**Save the output** - you'll need these values:
```json
{
  "appId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",      // This is AZURE_CLIENT_ID
  "displayName": "AzureLocal-UpdateAutomation",
  "password": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",       // This is AZURE_CLIENT_SECRET
  "tenant": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"     // This is AZURE_TENANT_ID
}
```

### Step 2: Grant Additional Permissions (if needed)

If you need to query clusters across multiple subscriptions, grant the Service Principal access to each subscription:

```bash
# Grant access to additional subscriptions
az role assignment create \
    --assignee "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" \
    --role "Azure Stack HCI Administrator" \
    --scope "/subscriptions/{additional-subscription-id}"
```

### Step 3: Verify Permissions

The Service Principal needs these permissions:

| Permission | Purpose |
|------------|---------|
| `Microsoft.AzureStackHCI/clusters/read` | Read cluster information |
| `Microsoft.AzureStackHCI/clusters/updates/read` | List available updates |
| `Microsoft.AzureStackHCI/clusters/updates/apply/action` | Apply updates |
| `Microsoft.AzureStackHCI/clusters/updateSummaries/read` | Read update summary |
| `Microsoft.AzureStackHCI/clusters/updateRuns/read` | Monitor update progress |
| `Microsoft.Resources/subscriptions/resources/read` | Query resources via Resource Graph |
| `Microsoft.Resources/tags/write` | Create/update resource tags |

---

## GitHub Actions Setup

### Step 1: Add Repository Secrets

1. Go to your GitHub repository
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Add the following secrets:

| Secret Name | Value |
|-------------|-------|
| `AZURE_CLIENT_ID` | The `appId` from Service Principal creation |
| `AZURE_CLIENT_SECRET` | The `password` from Service Principal creation |
| `AZURE_TENANT_ID` | The `tenant` from Service Principal creation |

![GitHub Secrets Setup](https://docs.github.com/assets/cb-28266/images/help/repository/actions-secrets-and-variables.png)

### Step 2: Copy Workflow Files

Copy the workflow files from `github-actions/` to your repository's `.github/workflows/` folder:

```
.github/
└── workflows/
    ├── inventory-clusters.yml
    ├── manage-updatering-tags.yml
    └── apply-updates.yml
```

### Step 3: Run Workflows

1. Go to **Actions** tab in your repository
2. Select the workflow you want to run
3. Click **Run workflow**
4. Fill in the required inputs
5. Click **Run workflow** (green button)

---

## Azure DevOps Setup

### Step 1: Create a Service Connection

1. Go to your Azure DevOps project
2. Navigate to **Project Settings** → **Service connections**
3. Click **New service connection**
4. Select **Azure Resource Manager**
5. Choose **Service principal (manual)**
6. Fill in the details:

| Field | Value |
|-------|-------|
| **Subscription ID** | Your Azure subscription ID |
| **Subscription Name** | A friendly name for the subscription |
| **Service Principal ID** | The `appId` from Service Principal creation |
| **Service Principal Key** | The `password` from Service Principal creation |
| **Tenant ID** | The `tenant` from Service Principal creation |
| **Service connection name** | `AzureLocal-ServiceConnection` (or your preferred name) |

7. Check **Grant access permission to all pipelines**
8. Click **Verify and save**

### Step 2: Create Pipeline Variable Group (Optional)

For additional configuration, create a variable group:

1. Go to **Pipelines** → **Library**
2. Click **+ Variable group**
3. Name it `AzureLocal-Config`
4. Add variables as needed (e.g., default UpdateRing values)

### Step 3: Create Pipelines

For each pipeline definition in `azure-devops/`:

1. Go to **Pipelines** → **Pipelines**
2. Click **New pipeline**
3. Select **Azure Repos Git** (or your repo source)
4. Select your repository
5. Choose **Existing Azure Pipelines YAML file**
6. Select the path to the YAML file (e.g., `/Automation-Pipeline-Examples/azure-devops/inventory-clusters.yml`)
7. Click **Continue** and then **Save** (not Run, unless you want to test immediately)

Repeat for each pipeline file.

---

## Pipeline Descriptions

### 1. Inventory Clusters Pipeline

**Purpose:** Queries all Azure Local clusters and generates an inventory report showing:
- Cluster names and resource groups
- Current UpdateRing tag values
- Clusters without UpdateRing tags

**Outputs:**
- CSV file artifact with cluster inventory
- Console summary of UpdateRing distribution

**Use Case:** Run this first to understand your cluster landscape and identify clusters that need UpdateRing tags.

### 2. Manage UpdateRing Tags Pipeline

**Purpose:** Creates or updates UpdateRing tags on clusters based on a CSV input file.

**Inputs:**
- CSV file with `ResourceId` and `UpdateRing` columns
- Optional: Force flag to overwrite existing tags

**Workflow:**
1. Run Inventory pipeline to get current state
2. Download the CSV artifact
3. Edit the CSV to set desired UpdateRing values
4. Upload the modified CSV to the repository or as pipeline input
5. Run this pipeline to apply the tags

**Use Case:** Organize clusters into update rings (Wave1, Wave2, Production, etc.) for staged rollouts.

### 3. Apply Updates Pipeline

**Purpose:** Applies available updates to clusters filtered by UpdateRing tag.

**Inputs:**
- UpdateRing value to target (e.g., "Wave1")
- Optional: Specific update version to apply

**Outputs:**
- JUnit XML test results for CI/CD visualization
- CSV logs of started/skipped updates
- Detailed execution logs

**Use Case:** Execute updates on a specific ring of clusters as part of a staged deployment.

---

## Typical Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                     Initial Setup                                │
├─────────────────────────────────────────────────────────────────┤
│  1. Run "Inventory Clusters" pipeline                           │
│  2. Download CSV artifact                                        │
│  3. Edit CSV in Excel - assign UpdateRing values                │
│  4. Run "Manage UpdateRing Tags" pipeline with edited CSV       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Update Deployment                            │
├─────────────────────────────────────────────────────────────────┤
│  5. Run "Apply Updates" for Wave1/Pilot clusters                │
│  6. Verify updates completed successfully                        │
│  7. Run "Apply Updates" for Wave2 clusters                      │
│  8. Verify updates completed successfully                        │
│  9. Run "Apply Updates" for Production clusters                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Ongoing Maintenance                          │
├─────────────────────────────────────────────────────────────────┤
│  - Schedule "Inventory Clusters" weekly/monthly                 │
│  - Review inventory for new clusters needing tags               │
│  - Schedule "Apply Updates" per ring on maintenance windows     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Security Best Practices

1. **Least Privilege**: Create a custom role with only the required permissions instead of using "Azure Stack HCI Administrator" if you want tighter security.

2. **Secret Rotation**: Rotate the Service Principal secret regularly (e.g., every 90 days).

3. **Audit Logging**: Enable Azure Activity Log monitoring for the Service Principal.

4. **Approval Gates**: Add manual approval steps before the "Apply Updates" pipeline in production.

5. **Branch Protection**: Require PR reviews for changes to pipeline definitions.

---

## Troubleshooting

### "Azure CLI not authenticated"
- Verify the Service Principal credentials are correct
- Check that secrets are properly configured in GitHub/Azure DevOps
- Ensure the Service Principal has not expired

### "No clusters found"
- Verify the Service Principal has access to the subscription(s)
- Check that clusters exist and are in "Connected" state
- Ensure the `resource-graph` extension is installed (pipelines do this automatically)

### "Permission denied applying tags"
- Verify the Service Principal has `Microsoft.Resources/tags/write` permission
- Check that the scope includes the resource groups containing the clusters

### "Update failed to start"
- Check cluster health status in Azure Portal
- Verify the update is in "Ready" state
- Review the detailed logs in the pipeline output

---

## File Structure

```
Automation-Pipeline-Examples/
├── README.md                           # This file
├── github-actions/
│   ├── inventory-clusters.yml          # GitHub Actions: Inventory pipeline
│   ├── manage-updatering-tags.yml      # GitHub Actions: Tag management pipeline
│   └── apply-updates.yml               # GitHub Actions: Update application pipeline
└── azure-devops/
    ├── inventory-clusters.yml          # Azure DevOps: Inventory pipeline
    ├── manage-updatering-tags.yml      # Azure DevOps: Tag management pipeline
    └── apply-updates.yml               # Azure DevOps: Update application pipeline
```

---

## Related Documentation

- [Azure Local Update Management Module](../README.md)
- [Azure Stack HCI documentation](https://learn.microsoft.com/en-us/azure-stack/hci/)
- [GitHub Actions documentation](https://docs.github.com/en/actions)
- [Azure DevOps Pipelines documentation](https://learn.microsoft.com/en-us/azure/devops/pipelines/)
