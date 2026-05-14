# CI/CD Pipeline Examples for Azure Local Cluster Update Management

> **Disclaimer**: This module is **NOT** a Microsoft supported service offering or product. It is provided as example code only, with no warranty or official support. Refer to the [MIT license](https://github.com/NeilBird/Azure-Local/blob/main/LICENSE) for further information.

This folder is the setup-and-configure landing page for the example GitHub Actions and Azure DevOps pipelines that ship with the `AzLocal.UpdateManagement` PowerShell module. It walks an operator from "nothing wired" to "a staged-rollout update programme runs itself, with optional ServiceNow ticketing on failures".

It is written in the same step-by-step style as [`ITSM/README.md`](../ITSM/README.md). If something here is unclear, that file is a good cross-reference for the connector portion.

---

## Table of contents

1. [What you'll have when you're done](#1-what-youll-have-when-youre-done)
2. [Prerequisites](#2-prerequisites)
3. [Choose your CI/CD platform and authentication](#3-choose-your-cicd-platform-and-authentication)
   - [3.1 GitHub Actions with OpenID Connect (recommended)](#31-github-actions-with-openid-connect-recommended)
   - [3.2 Azure DevOps with Workload Identity Federation (recommended)](#32-azure-devops-with-workload-identity-federation-recommended)
   - [3.3 Self-hosted runners with Managed Identity](#33-self-hosted-runners-with-managed-identity)
   - [3.4 Service Principal + client secret (legacy fallback)](#34-service-principal--client-secret-legacy-fallback)
4. [Required Azure permissions](#4-required-azure-permissions)
5. [Wire the pipeline files into your repo](#5-wire-the-pipeline-files-into-your-repo)
   - [5.1 GitHub Actions](#51-github-actions)
   - [5.2 Azure DevOps](#52-azure-devops)
6. [End-to-end runbook: bring an estate online](#6-end-to-end-runbook-bring-an-estate-online)
   - [6.1 Inventory the estate](#61-inventory-the-estate)
   - [6.2 Plan update rings, windows, and exclusions](#62-plan-update-rings-windows-and-exclusions)
   - [6.3 Apply tags](#63-apply-tags)
   - [6.4 Pre-flight readiness assessment](#64-pre-flight-readiness-assessment)
   - [6.5 Apply updates - one wave at a time](#65-apply-updates---one-wave-at-a-time)
   - [6.6 Continuous fleet monitoring](#66-continuous-fleet-monitoring)
7. [Optional: open ITSM tickets for clusters needing operator action](#7-optional-open-itsm-tickets-for-clusters-needing-operator-action)
8. [Scheduling, maintenance windows, and change-freeze periods](#8-scheduling-maintenance-windows-and-change-freeze-periods)
9. [Tuning throughput (`-ThrottleLimit`)](#9-tuning-throughput--throttlelimit)
10. [Standalone HTML report (no pipeline)](#10-standalone-html-report-no-pipeline)
11. [Security model](#11-security-model)
12. [Troubleshooting](#12-troubleshooting)
13. [File layout](#13-file-layout)
14. [Appendix A: Pipeline reference](#appendix-a-pipeline-reference)
15. [Appendix B: Release history](#appendix-b-release-history)
    - [B.1 v0.7.4 (current)](#b1-v074-current)
    - [B.2 v0.7.2](#b2-v072)
    - [B.3 v0.7.1](#b3-v071)
    - [B.4 v0.7.0](#b4-v070)
16. [Related documentation](#16-related-documentation)

---

## 1. What you'll have when you're done

By the end of this guide you will have:

- A federated identity (no client secrets) wired into your CI/CD platform with the **minimum** Azure RBAC needed for cluster update management.
- Five working pipelines committed to your repo and visible in the Actions / Pipelines UI:
  - **Inventory** - enumerate every Azure Local cluster the identity can see and export a CSV.
  - **Manage UpdateRing tags** - bulk-apply `UpdateRing`, `UpdateWindow`, `UpdateExclusions` tags from that CSV.
  - **Assess Update Readiness** - pre-flight, report-only readiness + blocking-health snapshot, published as JUnit XML.
  - **Apply Updates** - apply updates to a single `UpdateRing` wave at a time, with WhatIf / dry-run support.
  - **Fleet Update Status** - scheduled daily snapshot of fleet update state, surfaced in the Tests tab.
- An end-to-end "ring-based" rollout pattern: Pilot -> Wave2 -> Production, with each ring gated on the previous wave's success.
- **Optional**: a ServiceNow integration that opens deduped incidents for clusters whose run status indicates the module's own retries cannot recover (failures, blocking health checks, sideloaded payload missing) - see [section 7](#7-optional-open-itsm-tickets-for-clusters-needing-operator-action).

The pipelines are **fully opt-in additive layers** over the module. The PowerShell functions also work without any pipeline at all - see [section 10](#10-standalone-html-report-no-pipeline) for the ad-hoc / desktop story.

---

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| Azure subscription(s) containing Azure Local clusters | One or many; multi-subscription is supported and is the common state at >~500 clusters because the per-subscription storage-account quota caps how many witness accounts (and therefore clusters) fit in one subscription. |
| Permissions to create app registrations in Microsoft Entra ID, or an existing one | Required so you can either set up Workload Identity Federation (recommended) or, as a fallback, a Service Principal + client secret. |
| GitHub repository **or** Azure DevOps project | The pipeline YAMLs are checked in to one of these and run on the platform's hosted Windows agents (or your self-hosted runners). |
| PowerShell 5.1 or later | Used by every pipeline step. Microsoft-hosted `windows-latest` agents ship with PowerShell 5.1 and PowerShell 7+ already installed - no extra install needed there. |
| `Az.Accounts` + `Az.KeyVault` modules | `Az.Accounts` is required by all pipelines. `Az.KeyVault` is required only if you opt in to the ITSM connector with Key Vault-sourced secrets (recommended). The pipelines install these on the agent as needed. |
| `powershell-yaml` module | Required only if you opt in to the ITSM connector and your matrix config is YAML (default). JSON config works on stock PowerShell. The pipeline installs this on the agent only when the ITSM step runs. |

You do **not** need any cluster-side prerequisites for the inventory, tag-management, readiness, or fleet-status pipelines. The Apply Updates pipeline does require the clusters be in a healthy ARM state for the update API to accept the request - that is what the readiness pre-flight in section 6.4 measures.

---

## 3. Choose your CI/CD platform and authentication

There are three supported authentication patterns, listed from **most to least secure**. Pick one - you do not need all three.

| Method | Security | Secret to manage | Best for |
|---|---|---|---|
| **OpenID Connect (OIDC) / Workload Identity Federation** | Strongest | None (secretless) | GitHub Actions and Azure DevOps. **Recommended for all new setups.** |
| **Managed Identity** | Strong | None | Self-hosted runners on Azure VMs. |
| **Service Principal + client secret** | Weak | Client secret (expires, leaks, must rotate) | Legacy environments where OIDC / federation is not available. |

> **Microsoft strongly recommends OIDC / Workload Identity Federation** over client secrets. Tokens are short-lived, scoped, and never stored anywhere you have to rotate.

### 3.1 GitHub Actions with OpenID Connect (recommended)

OIDC has the workflow request a short-lived token from Azure at runtime, with no stored secret. Subject claim binding ensures only **your** repository's workflows can mint the token.

**Step 1 - create the App Registration**

```bash
# Create App Registration (no client secret needed)
az ad app create --display-name "AzureLocal-UpdateAutomation-OIDC"
# Note the appId from the output - this becomes AZURE_CLIENT_ID.
```

**Step 2 - create the Service Principal and assign a role**

First create the Service Principal:

```bash
az ad sp create --id <appId-from-step-1>
```

Then assign **one** of the following. The custom role is recommended for production / governed estates because it grants only the actions the pipelines actually use; the built-in role is a quick-start option for lab and PoC work.

**Option A (recommended) - assign the least-privilege custom role**

This pattern grants the Service Principal only the actions the five pipelines need (read clusters, read/apply updates, read update runs, read/write tags, Resource Graph queries). The full JSON role definition and `az role definition create` command live in [section 4 below](#4-required-azure-permissions) - run that block once per tenant first, then assign:

```bash
az role assignment create `
    --assignee <appId-from-step-1> `
    --role    "Azure Stack HCI Update Operator" `
    --scope   "/subscriptions/<your-subscription-id>"
```

**Option B (quick start) - assign the built-in Azure Stack HCI Administrator role**

Use this only for lab / PoC where over-grant is acceptable. It includes broad cluster-management permissions far beyond what the pipelines exercise.

```bash
az role assignment create `
    --assignee <appId-from-step-1> `
    --role    "Azure Stack HCI Administrator" `
    --scope   "/subscriptions/<your-subscription-id>"
```

For multi-subscription estates, run the `role assignment create` step once per subscription. The custom role definition itself is created once per tenant, then assigned at each subscription scope.

**Step 3 - federate the workflow**

```bash
az ad app federated-credential create `
    --id <appId-from-step-1> `
    --parameters '{
        "name": "GitHubActions-main",
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:<owner>/<repo>:ref:refs/heads/main",
        "audiences": ["api://AzureADTokenExchange"]
    }'

# For manually-triggered workflow_dispatch runs from a protected environment:
az ad app federated-credential create `
    --id <appId-from-step-1> `
    --parameters '{
        "name": "GitHubActions-production",
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:<owner>/<repo>:environment:production",
        "audiences": ["api://AzureADTokenExchange"]
    }'
```

Subject-claim patterns for other trigger types:

| Trigger | Subject claim |
|---|---|
| Push to a branch | `repo:<owner>/<repo>:ref:refs/heads/<branch>` |
| Pull request | `repo:<owner>/<repo>:pull_request` |
| Environment | `repo:<owner>/<repo>:environment:<env>` |
| Tag | `repo:<owner>/<repo>:ref:refs/tags/<tag>` |

**Step 4 - add the (three) GitHub secrets**

| Secret name | Value |
|---|---|
| `AZURE_CLIENT_ID` | The App Registration `appId` from step 1. |
| `AZURE_TENANT_ID` | Your Entra ID tenant ID. |
| `AZURE_SUBSCRIPTION_ID` | The subscription that hosts (or contains the management-group rollup of) your clusters. |

No `AZURE_CLIENT_SECRET` is needed.

For public repositories, prefer [environment secrets with required reviewers](https://docs.github.com/en/actions/deployment/targeting-different-environments/using-environments-for-deployment#environment-secrets) over repository-level secrets - they restrict who can run the workflow against production identities.

Microsoft Learn reference: [Use GitHub Actions with OpenID Connect](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect).

### 3.2 Azure DevOps with Workload Identity Federation (recommended)

Workload Identity Federation is the Azure DevOps equivalent of OIDC. ADO creates the App Registration and federated credential for you.

1. Open your Azure DevOps project.
2. **Project Settings -> Service connections -> New service connection**.
3. Pick **Azure Resource Manager**.
4. Pick **Workload Identity federation (automatic)**.
5. Select your subscription and scope.
6. Name the connection **`AzureLocal-ServiceConnection`** so the example YAMLs work without edits. If you pick a different name, update the `azureSubscription:` value in each ADO YAML.
7. **Save**.

The first run will create the App Registration in Entra ID. Grant the **`Azure Stack HCI Update Operator`** custom role from [section 4.1](#41-custom-role-azure-stack-hci-update-operator-recommended) on the same scope you selected in step 5 (or, for quick-start labs only, the built-in `Azure Stack HCI Administrator` role).

### 3.3 Self-hosted runners with Managed Identity

If your GitHub Actions runner or Azure DevOps agent is a VM in Azure, Managed Identity is the cleanest option - no secret, no federation config.

```bash
# System-assigned managed identity on the agent VM
az vm identity assign --name runner-vm --resource-group runners-rg

# Grant the role to that identity (recommended: custom role from section 4.1)
$principalId = az vm show -n runner-vm -g runners-rg --query identity.principalId -o tsv
az role assignment create `
    --assignee $principalId `
    --role    "Azure Stack HCI Update Operator" `
    --scope   "/subscriptions/<your-subscription-id>"

# Quick-start / lab fallback - built-in role with broader privileges:
# az role assignment create `
#     --assignee $principalId `
#     --role    "Azure Stack HCI Administrator" `
#     --scope   "/subscriptions/<your-subscription-id>"
```

In GitHub Actions, log in with:

```yaml
- name: Azure CLI Login (Managed Identity)
  uses: azure/login@v2
  with:
    auth-type: IDENTITY
    client-id: ${{ secrets.AZURE_CLIENT_ID }}  # only required for user-assigned identity
```

In the PowerShell module directly:

```powershell
Connect-AzureLocalServicePrincipal -UseManagedIdentity
```

### 3.4 Service Principal + client secret (legacy fallback)

Use this **only** if OIDC and Workload Identity Federation are unavailable.

Create the SP first, then assign the custom role from [section 4.1](#41-custom-role-azure-stack-hci-update-operator-recommended) (recommended) so the legacy client-secret identity is still least-privilege:

```bash
# Create SP without assigning any role yet
az ad sp create-for-rbac --name "AzureLocal-UpdateAutomation" --skip-assignment

# Recommended: assign the custom role (after running the role-definition create from section 4.1)
az role assignment create `
    --assignee <appId-from-create-for-rbac> `
    --role    "Azure Stack HCI Update Operator" `
    --scope   "/subscriptions/<your-subscription-id>"

# Quick-start / lab fallback - one-shot create + assign the built-in role:
# az ad sp create-for-rbac `
#     --name   "AzureLocal-UpdateAutomation" `
#     --role   "Azure Stack HCI Administrator" `
#     --scopes "/subscriptions/<your-subscription-id>"
```

Save the `appId`, `password`, and `tenant` from the output - they go into four secrets:

| Secret name | Value |
|---|---|
| `AZURE_CLIENT_ID` | `appId` from the command output. |
| `AZURE_CLIENT_SECRET` | `password` from the command output. **Expires - rotate every 90 days.** |
| `AZURE_TENANT_ID` | `tenant` from the command output. |
| `AZURE_SUBSCRIPTION_ID` | Your subscription ID. |

In the example GitHub Actions YAMLs, the OIDC step is active by default and the client-secret variant is left commented out. Switch the comments around (and remove the OIDC `permissions:` block) to flip to client-secret auth.

If you must use client secrets:

1. **Expire fast** - 90 days or less.
2. **Rotate on a schedule** - automate it; do not rely on humans.
3. **Use environment-level secrets** with required reviewers for public repos.
4. **Audit** - enable Activity Log monitoring for the Service Principal's sign-ins.

---

## 4. Required Azure permissions

The identity created in section 3 needs the following permissions on every subscription that contains clusters in scope. The built-in **Azure Stack HCI Administrator** role covers all of them; the custom-role definition below is the **recommended** least-privilege alternative for production / governed estates.

| Permission | Used by |
|---|---|
| `Microsoft.AzureStackHCI/clusters/read` | All pipelines (inventory + readiness + apply + status). |
| `Microsoft.AzureStackHCI/clusters/updates/read` | Apply Updates, Fleet Update Status. |
| `Microsoft.AzureStackHCI/clusters/updates/apply/action` | Apply Updates. |
| `Microsoft.AzureStackHCI/clusters/updateSummaries/read` | Apply Updates, Fleet Update Status. |
| `Microsoft.AzureStackHCI/clusters/updates/updateRuns/read` | Apply Updates, Fleet Update Status. |
| `Microsoft.ResourceGraph/resources/read` | All pipelines (Resource Graph lookups). |
| `Microsoft.Resources/subscriptions/resourceGroups/read` | All pipelines (resolve cluster scopes). |
| `Microsoft.Resources/tags/read` | Manage UpdateRing Tags, sideloaded workflow. |
| `Microsoft.Resources/tags/write` | Manage UpdateRing Tags, sideloaded workflow (`UpdateSideloaded` + `UpdateVersionInProgress`). |

If you opt in to the ITSM connector with Key Vault-sourced secrets, the identity additionally needs **Key Vault Secrets User** on the configured vault. No other new RBAC.

### 4.1 Custom role: `Azure Stack HCI Update Operator` (recommended)

This is the least-privilege role that supports every pipeline in this folder. The same definition is documented in the module-level [`AzLocal.UpdateManagement/README.md`](../README.md#permissions-required-for-update-operations) and is reproduced here so this folder is self-contained.

**Role definition (`azlocal-update-management-custom-role.json`):**

```json
{
  "Name": "Azure Stack HCI Update Operator",
  "IsCustom": true,
  "Description": "Can view and apply updates on Azure Local clusters, manage UpdateRing tags",
  "Actions": [
    "Microsoft.AzureStackHCI/clusters/read",
    "Microsoft.AzureStackHCI/clusters/updateSummaries/read",
    "Microsoft.AzureStackHCI/clusters/updates/read",
    "Microsoft.AzureStackHCI/clusters/updates/apply/action",
    "Microsoft.AzureStackHCI/clusters/updates/updateRuns/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.ResourceGraph/resources/read",
    "Microsoft.Resources/tags/read",
    "Microsoft.Resources/tags/write"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/<your-subscription-id>"
  ]
}
```

Add every in-scope subscription ID to `AssignableScopes` before creating the role - a custom role can only be assigned at or below a scope listed here.

**Who can run these commands?**

Creating a custom role definition and assigning it are **separate, privileged Azure RBAC operations** - they are not granted by the new custom role itself. The user (or automation identity) running the commands needs the underlying RBAC actions in the table below at the scope listed in `AssignableScopes`.

| Operation | Required action | Built-in Azure RBAC roles that grant it |
|---|---|---|
| `az role definition create` / `update` | `Microsoft.Authorization/roleDefinitions/write` | **Owner**, **User Access Administrator**, **Role Based Access Control Administrator** |
| `az role assignment create` / `delete` | `Microsoft.Authorization/roleAssignments/write` | **Owner**, **User Access Administrator**, **Role Based Access Control Administrator** |

> **Note**: The Entra ID **Global Administrator** directory role is **not** by itself an Azure RBAC role and does not grant `Microsoft.Authorization/*` actions. A Global Administrator can, however, [elevate access](https://learn.microsoft.com/azure/role-based-access-control/elevate-access-global-admin) once to gain **User Access Administrator** at the tenant root (`/`) scope, then perform these operations or delegate them. For day-to-day work, grant **Role Based Access Control Administrator** on the target subscription(s) to the operator instead.

If you don't hold one of those roles, ask whoever does (typically a subscription Owner or your platform team) to either run the commands for you or grant you **Role Based Access Control Administrator** scoped to the in-scope subscription(s). [`Microsoft.Authorization/roleDefinitions/write`](https://learn.microsoft.com/azure/role-based-access-control/role-definitions) is the smallest action you actually need.

**Create the role (one time per tenant):**

`AssignableScopes` must contain a real subscription ID (or a list of them) - the literal `<your-subscription-id>` placeholder will be rejected by `az role definition create`. Capture the current subscription first, or hard-code the IDs you intend to manage:

```powershell
# Use the current az CLI subscription, or set $subId manually
$subId = az account show --query id -o tsv
# For multiple subscriptions, build an array of scope strings instead:
# $scopes = @("/subscriptions/00000000-0000-0000-0000-000000000000",
#             "/subscriptions/11111111-1111-1111-1111-111111111111")
```

```powershell
# Option 1 - JSON file already on disk: substitute the placeholder, then create
(Get-Content ./azlocal-update-management-custom-role.json -Raw) `
    -replace '<your-subscription-id>', $subId |
    Set-Content ./azlocal-update-management-custom-role.json -Encoding UTF8

az role definition create --role-definition ./azlocal-update-management-custom-role.json

# Option 2 - inline create with an expanding PowerShell here-string ($subId is interpolated)
@"
{
  "Name": "Azure Stack HCI Update Operator",
  "IsCustom": true,
  "Description": "Can view and apply updates on Azure Local clusters, manage UpdateRing tags",
  "Actions": [
    "Microsoft.AzureStackHCI/clusters/read",
    "Microsoft.AzureStackHCI/clusters/updateSummaries/read",
    "Microsoft.AzureStackHCI/clusters/updates/read",
    "Microsoft.AzureStackHCI/clusters/updates/apply/action",
    "Microsoft.AzureStackHCI/clusters/updates/updateRuns/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.ResourceGraph/resources/read",
    "Microsoft.Resources/tags/read",
    "Microsoft.Resources/tags/write"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/$subId"
  ]
}
"@ | Out-File -FilePath ./azlocal-update-management-custom-role.json -Encoding UTF8

az role definition create --role-definition ./azlocal-update-management-custom-role.json
```

> **Note**: The here-string in Option 2 uses double quotes (`@"..."@`) so PowerShell expands `$subId` into the JSON before it's written to disk. If you switch to a literal here-string (`@'...'@`), the variable is not expanded and you must substitute the placeholder yourself like in Option 1.

**Assign the custom role to the pipeline identity (per subscription):**

```bash
az role assignment create `
    --assignee <appId-or-principalId> `
    --role    "Azure Stack HCI Update Operator" `
    --scope   "/subscriptions/<your-subscription-id>"
```

To extend the custom role to additional subscriptions, first update `AssignableScopes` with `az role definition update`, then run the `az role assignment create` command above against each new subscription scope.

**Common errors and how to fix them**

| Error | Cause | Fix |
|---|---|---|
| `(AuthorizationFailed) ... does not have authorization to perform action 'Microsoft.Authorization/roleDefinitions/write'` | The signed-in identity is not **Owner**, **User Access Administrator**, or **Role Based Access Control Administrator** on the subscription in `AssignableScopes`. | Have a subscription Owner grant you **Role Based Access Control Administrator** on that subscription (least privilege), or ask them to run the command for you. See "Who can run these commands?" above. |
| `(AuthorizationFailed) ... 'Microsoft.Authorization/roleAssignments/write'` | Same as above but for the assignment step. | Same fix - the same three built-in roles grant both `roleDefinitions/write` and `roleAssignments/write`, so a single role grant unblocks both commands. |
| `RoleDefinitionWithSameNameExists` | A role definition with `Name = "Azure Stack HCI Update Operator"` already exists in the tenant. | Use `az role definition update --role-definition ./azlocal-update-management-custom-role.json` instead of `create`, or pick a unique `Name`. |
| `AssignableScopeNotUnderRoleDefinitionScope` when running `az role assignment create` | The scope you are assigning to is not listed in the role definition's `AssignableScopes`. | Update `AssignableScopes` (`az role definition update`) before re-running the assignment. |
| `Readonly attribute type will be ignored in class ... RoleDefinition` (warning, not an error) | Cosmetic Azure CLI warning emitted by the Python SDK when it sees a read-only field in the JSON; the command still succeeds. | Safe to ignore. |

**Example: AuthorizationFailed when creating the role**

The command and message look like this (subscription / tenant / user identifiers obfuscated):

```text
az role definition create --role-definition "C:\Users\joe.bloggs\azlocal-update-management-custom-role.json"
Readonly attribute type will be ignored in class <class 'azure.mgmt.authorization.models._models_py3.RoleDefinition'>
(AuthorizationFailed) The client 'joe.bloggs@contoso.com' with object id 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
does not have authorization to perform action 'Microsoft.Authorization/roleDefinitions/write' over scope
'/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/providers/Microsoft.Authorization/roleDefinitions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
or the scope is invalid. If access was recently granted, please refresh your credentials.
Code: AuthorizationFailed
```

The fix is **not** to escalate to Global Administrator (an Entra ID role, see note above). The fix is to temporarily give the identity running this command an Azure RBAC role on the subscription that grants `Microsoft.Authorization/roleDefinitions/write` - **Role Based Access Control Administrator** is the most narrowly-scoped built-in option. Alternatively, ask another person / administrator who has the permissions in your tenant to run this one-time setup command on your behalf.

**Example: AuthorizationFailed when assigning the role**

The role definition can be created successfully (often by a platform / RBAC admin) but the **assignment** step then fails for a less-privileged operator. The two operations require different RBAC actions, so passing the `create` step does **not** guarantee `assignment create` will work:

```text
az role assignment create `
    --assignee xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx `
    --role    "Azure Stack HCI Update Operator" `
    --scope   "/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
(AuthorizationFailed) The client 'joe.bloggs@contoso.com' with object id 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write' over scope
'/subscriptions/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/providers/Microsoft.Authorization/roleAssignments/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
or the scope is invalid. If access was recently granted, please refresh your credentials.
Code: AuthorizationFailed
```

Same remediation as the create case: have a subscription Owner grant the operator **Role Based Access Control Administrator** on the target subscription (least privilege - covers both `roleDefinitions/write` and `roleAssignments/write`), or have that admin run the `az role assignment create` step on the operator's behalf. **Role Based Access Control Administrator** can additionally be scoped with [conditions](https://learn.microsoft.com/azure/role-based-access-control/role-assignments-conditions-overview) that restrict which roles the holder can assign (e.g. "only `Azure Stack HCI Update Operator`"), which is the cleanest way to delegate this single role grant without handing out broader RBAC powers.

You can verify your effective access on the target subscription with:

```powershell
az role assignment list --assignee <upn-or-objectId> --scope "/subscriptions/<your-subscription-id>" -o table
```

> **Tip**: If you started with the built-in `Azure Stack HCI Administrator` role and want to migrate to the custom role with no downtime, assign the custom role first, verify a pipeline run succeeds, then remove the built-in assignment with `az role assignment delete`.

### 4.2 Extending to additional subscriptions (built-in role)

If you accepted the built-in role in section 3, extend it to additional subscriptions with:

```bash
az role assignment create `
    --assignee <appId-or-principalId> `
    --role    "Azure Stack HCI Administrator" `
    --scope   "/subscriptions/<additional-subscription-id>"
```

---

## 5. Wire the pipeline files into your repo

Both platforms expect the YAML files inside this folder to land in a platform-specific location in your **consumer** repo.

> **Shortcut**: install the module first and use `Copy-AzureLocalPipelineExample` to copy this entire folder out of the module install location into a working folder, instead of cloning the repo or hunting through `$module.ModuleBase`:
>
> ```powershell
> Install-Module -Name AzLocal.UpdateManagement -Scope CurrentUser
> Import-Module AzLocal.UpdateManagement
>
> # Copy everything to the current folder (creates .\Automation-Pipeline-Examples\)
> Copy-AzureLocalPipelineExample
>
> # Or only the GitHub Actions YAML straight into .github\workflows\ in your repo
> New-Item -ItemType Directory .\.github\workflows -Force | Out-Null
> Copy-AzureLocalPipelineExample -Destination .\.github\workflows -Platform GitHub -Flatten -Force
> ```
>
> The function prints a short "next steps" summary pointing at the copied README and the platform-specific YAML folder. Supports `-Platform GitHub | AzureDevOps | All`, `-Flatten`, `-Force`, `-PassThru`, `-WhatIf`, `-Confirm`.

### 5.1 GitHub Actions

1. Copy every file from [`github-actions/`](./github-actions/) into `.github/workflows/` in your repo:
    ```text
    .github/
      workflows/
        inventory-clusters.yml
        manage-updatering-tags.yml
        assess-update-readiness.yml
        apply-updates.yml
        fleet-update-status.yml
    ```
2. Commit and push. The workflows appear in the **Actions** tab.
3. Each workflow exposes its inputs via the **Run workflow** button (workflow_dispatch). The scheduled triggers (e.g. fleet-update-status.yml runs daily at 06:00 UTC) activate automatically once the file is on the default branch.

### 5.2 Azure DevOps

1. Copy every file from [`azure-devops/`](./azure-devops/) into your repository at a path of your choice (the README assumes the same folder layout as this repo).
2. **Pipelines -> New pipeline -> Azure Repos Git -> your repo -> Existing Azure Pipelines YAML file**, then point at the path of each file. Repeat for all five.
3. After the pipeline is created, click **Save** (not **Run**) until you are ready to execute.
4. Each pipeline references a service connection named `AzureLocal-ServiceConnection`. Either name your service connection to match, or change `azureSubscription:` in each YAML.

Optional: create a variable group named **`AzureLocal-Config`** in **Pipelines -> Library** for default values (e.g. the default `UpdateRing` for your most-common rollout). The example YAMLs do not require it.

---

## 6. End-to-end runbook: bring an estate online

This is the canonical "nothing wired -> staged rollout working" sequence. Follow it in order for the first rollout; afterwards sections 6.4-6.6 become recurring.

```text
+-----------------------------------------------------------------------+
|                          PHASE 1: INVENTORY                            |
|  6.1  inventory-clusters.yml  ->  cluster-inventory.csv                |
+-----------------------------------------------------------------------+
                              v
+-----------------------------------------------------------------------+
|                          PHASE 2: TAG                                  |
|  6.2  Edit the CSV (UpdateRing, UpdateWindow, UpdateExclusions)        |
|  6.3  manage-updatering-tags.yml                                       |
+-----------------------------------------------------------------------+
                              v
+-----------------------------------------------------------------------+
|                          PHASE 3: ROLLOUT                              |
|  6.4  assess-update-readiness.yml  (report-only pre-flight)            |
|  6.5  apply-updates.yml  Wave1 -> validate -> Wave2 -> Production      |
+-----------------------------------------------------------------------+
                              v
+-----------------------------------------------------------------------+
|                          PHASE 4: STEADY STATE                         |
|  6.6  fleet-update-status.yml  (scheduled, daily 06:00 UTC)            |
+-----------------------------------------------------------------------+
```

### 6.1 Inventory the estate

Run **Inventory Clusters** with no parameters. It exports a CSV with one row per cluster and the current value of every update-management tag.

- **GitHub Actions**: *Actions -> Inventory Azure Local Clusters -> Run workflow*.
- **Azure DevOps**: *Pipelines -> Inventory Clusters -> Run pipeline*.

Download `cluster-inventory.csv` from the run artifacts. It contains `SubscriptionId`, `ResourceGroupName`, `ClusterName`, `ResourceId`, `UpdateRing`, `UpdateWindow`, `UpdateExclusions`, and the sideloaded-workflow columns added in v0.7.1.

> If you would rather skip the inventory pipeline entirely, the same operation runs from a local PowerShell session: `Import-Module ./AzLocal.UpdateManagement.psd1; Get-AzureLocalClusterInventory -ExportPath ./cluster-inventory.csv`. This is the same code path the pipeline uses.

### 6.2 Plan update rings, windows, and exclusions

Open the CSV and fill in three columns:

| Column | Required | Values | Purpose |
|---|---|---|---|
| `UpdateRing` | Yes | Free-form (e.g. `Wave1`, `Pilot`, `Production`) | Defines the wave the cluster belongs to. Apply Updates targets one ring at a time. |
| `UpdateWindow` | No | `<days>_<HH:MM>-<HH:MM>` in UTC, semicolon-separated | Allowed maintenance window. Updates outside it return `ScheduleBlocked`. |
| `UpdateExclusions` | No | `YYYY-MM-DD/YYYY-MM-DD`, comma-separated. Supports `*` wildcards. | Blackout / change-freeze periods. **Exclusions take priority over windows.** |

Example:

| ClusterName | UpdateRing | UpdateWindow | UpdateExclusions |
|---|---|---|---|
| HCI-Pilot01 | Wave1 | | |
| HCI-Pilot02 | Wave1 | | |
| HCI-Prod01  | Wave2 | `Sat-Sun_02:00-06:00` | `20**-12-20/20**-01-03` |
| HCI-Critical | Production | `Sat_02:00-06:00` | `20**-12-20/20**-01-03` |

Section 8 documents the full schedule grammar (multi-window, overnight, wrap-around, wildcards) and shows how to test it interactively with `Test-AzureLocalUpdateScheduleAllowed` before committing the tag.

### 6.3 Apply tags

Two equivalent ways to apply the edited CSV - pick whichever fits your workflow.

**Option A - via the pipeline (audit trail in CI/CD):**

1. Commit the edited CSV to your repo (e.g. `./cluster-tags.csv`).
2. Run **Manage UpdateRing Tags** and point its `csv_path` input at the committed CSV.
3. Inspect the run summary - it reports added / updated / unchanged tag counts per cluster.

**Option B - from PowerShell (faster for one-off changes):**

```powershell
Import-Module ./AzLocal.UpdateManagement.psd1
Set-AzureLocalClusterUpdateRingTag -InputCsvPath ./cluster-tags.csv
```

Either way verifies the tags in Azure with a follow-up read. Both paths use the same module function under the hood.

### 6.4 Pre-flight readiness assessment

Run **Assess Update Readiness** for the ring you are about to roll. It produces two JUnit XML files (visible in the Tests / Checks tab) and two CSV artefacts:

| Artefact | What it shows |
|---|---|
| `readiness.xml` / `readiness.csv` | One test per cluster from `Get-AzureLocalClusterUpdateReadiness`. Fails if `ReadyForUpdate = $false` (e.g. missing SBE prerequisite, no updates available, cluster in `Updating`). |
| `health-blocking.xml` / `health-blocking.csv` | One test per cluster from `Test-AzureLocalClusterHealth -BlockingOnly`. Fails if any **Critical** health failure exists. Non-critical findings are surfaced but do not fail the test. |

The pipeline itself is **report-only and always succeeds**. Per-cluster red tests are signal, not a stop condition for the wave - in a large fleet, one or two clusters out at any given moment is the norm, and blocking the entire wave on those is rarely what you want. `Start-AzureLocalClusterUpdate` is per-cluster-scoped and will no-op on the un-ready clusters anyway.

Common failure classes and where to fix them (the module *detects* blockers, it does not *remediate* them):

| Symptom | Remediation owner |
|---|---|
| Storage / drive / stamp health failure | Azure Local docs + Environment Checker. |
| SBE / firmware / driver prerequisite | Hardware vendor SBE package (Dell, HPE, Lenovo, DataON, ...). The `SBEDependency` and `HasPrerequisiteUpdates` columns identify the publisher and release-notes URL. |
| ADDS connectivity / certificate drift | Azure Local certificate rotation runbook. |
| Workload state preventing host updates | Windows Admin Center cluster validation. |

If you do want a hard go / no-go gate (typical for first production wave), have a downstream workflow read the job outputs `not_ready` and `critical_failures` and apply your own tolerance threshold there.

### 6.5 Apply updates - one wave at a time

For each ring in turn (Wave1 -> validate -> Wave2 -> validate -> Production), run **Apply Updates** with:

| Input | Value |
|---|---|
| `update_ring` | The ring to target (e.g. `Wave1`). |
| `update_name` | Leave blank to apply the latest ready update; set explicitly to pin a version. |
| `dry_run` | `true` for the first run of any new ring - prints the cluster list and intended actions without starting an update. |
| `throttle_limit` | See section 9. Default 4 is fine for fleets up to ~50 clusters. |

The pipeline publishes one test per cluster to the Tests tab and writes per-cluster status to artefacts:

| Status | Meaning | Action |
|---|---|---|
| `Started` / `UpdateStarted` / `Success` | Update is running or finished. | None. |
| `Skipped` | Cluster is up to date or has no ready updates. | None. |
| `ScheduleBlocked` | Cluster is outside its `UpdateWindow` or inside an `UpdateExclusions` period. | Re-run during the window, or update the tag if the schedule has drifted. |
| `HealthCheckBlocked` | Cluster has critical health failures. | Remediate per section 6.4. |
| `SideloadedBlocked` | Cluster has `UpdateSideloaded=False` waiting for an operator to stage the payload. | Stage the payload and flip the tag (or run `Reset-AzureLocalSideloadedTag`). |
| `Failed` / `Error` | The update request returned a non-success response. | Check pipeline logs and the cluster in Azure Portal. |

Use the duration data in `update-runs.csv` from the wave you just finished to size the maintenance window for the next ring.

For tighter control around production rollouts, add a manual approval gate between waves:

- **Azure DevOps**: a separate stage with a `ManualValidation@0` step (the `apply-updates.yml` shipped here includes a commented-out `WaitForApproval` block ready to enable).
- **GitHub Actions**: an `environment:` on the production job with required reviewers, configured in *Settings -> Environments*.

### 6.6 Continuous fleet monitoring

**Fleet Update Status** is scheduled to run daily at 06:00 UTC once you push the YAML. It does no writes - it builds a fleet-wide JUnit + CSV + JSON snapshot for dashboards and alerting.

| Artefact | Description |
|---|---|
| `readiness-status.xml` | JUnit XML, one cluster per test (`Passed` = healthy + up to date, `Failed` = needs attention, `Failed/HasPrerequisite` = vendor SBE update required first). |
| `readiness-status.csv` | Spreadsheet view of the same data plus `UpdateWindow`, `UpdateExclusions`, `SBEDependency`. |
| `readiness-status.json` | Machine-readable, with summary counts. |
| `update-summaries.csv` | Update-summary state per cluster from Azure. |
| `available-updates.csv` | Every available update across the fleet with version + health state. |
| `update-runs.csv` | Recent run history per cluster (durations, failure summaries) - this is what section 6.5's "size the next maintenance window" advice consumes. |

Configure your CI/CD platform's alerting on the JUnit failures - GitHub Actions surfaces them in the run summary and Azure DevOps shows them in the Tests tab with trend analytics.

---

## 7. Optional: open ITSM tickets for clusters needing operator action

> **This is optional and disabled by default.** Pipelines that do not toggle `raise_itsm_ticket=true` continue to behave exactly as before. The connector adds an additive step **after** `Publish Test Results` and never affects the apply-updates exit status.

The connector reads the JUnit results the Apply Updates pipeline already publishes and, for each cluster whose status matches your configured trigger matrix (default: `Failed`, `Error`, `HealthCheckBlocked`, `SideloadedBlocked`), opens a deduped ServiceNow incident via the Table API. Idempotency is enforced via a SHA256 dedupe key written to a custom `u_azlocal_dedupe_key` column, so re-running the same workflow does not create duplicates.

This README does not duplicate the setup - it is a single-source-of-truth in [`../ITSM/README.md`](../ITSM/README.md). Here is the high-level wiring you'll do over there:

| Step | Where it's documented |
|---|---|
| Register a ServiceNow OAuth application + technical user with the `itil` role | [ITSM/README.md section 3](../ITSM/README.md#3-servicenow-one-time-setup) |
| Add the five `u_azlocal_*` custom fields to the `incident` table (manual procedure in v0.7.4) | [ITSM/README.md section 3.2](../ITSM/README.md#32-add-the-five-custom-fields-on-the-incident-table) |
| Pick a secret source (Azure Key Vault recommended, environment-variable fallback) | [ITSM/README.md section 4](../ITSM/README.md#4-pick-a-secret-source) |
| Author the trigger matrix at `./.itsm/azurelocal-itsm.yml` (a ready-to-copy version ships in [`./.itsm/`](./.itsm/)) | [ITSM/README.md section 5](../ITSM/README.md#5-author-the-trigger-matrix) |
| Validate end-to-end with `Test-AzureLocalItsmConnection` before flipping the pipeline switch | [ITSM/README.md section 6](../ITSM/README.md#6-validate-before-you-wire-it-into-a-pipeline) |

Once the ServiceNow side is set up, the pipeline-side change is **already in `apply-updates.yml`** in this folder. You enable it by:

1. Setting `raise_itsm_ticket=true` when you trigger Apply Updates (workflow input in GH Actions, parameter in Azure DevOps).
2. Wiring the three secrets the step expects:
   - `ITSM_SN_INSTANCE_URL`
   - `ITSM_SN_CLIENT_ID`
   - `ITSM_SN_CLIENT_SECRET`
3. (Azure DevOps only) Uncomment the `- group: AzureLocal-ITSM-Secrets` line at the top of `apply-updates.yml` once the variable group exists.

The first production run should keep `itsm_dry_run=true` (the connector still resolves secrets and performs the read-only dedupe lookup so you can validate the matrix + templates against a real workload, without creating tickets). The dry-run output includes a CSV + JUnit projection of "what would have been ticketed" - inspect those before flipping the switch.

Phase 2 (lifecycle close-out via `Sync-AzureLocalIncident`) and Phase 3 (Teams + Slack mirror) are designed in [`ITSM-Connector-Plan.md`](../ITSM/ITSM-Connector-Plan.md) but **deferred** - they are not shipped in v0.7.4. The example pipeline reserves the slot for the Sync step with `if: false` so the wiring is forward-compatible.

---

## 8. Scheduling, maintenance windows, and change-freeze periods

The `UpdateWindow` and `UpdateExclusions` tags on each cluster control when **Apply Updates** is allowed to start an update.

| Tag | Format | Example | Behaviour |
|---|---|---|---|
| `UpdateWindow` | `<days>_<HH:MM>-<HH:MM>` (UTC) | `Sat-Sun_02:00-06:00` | Updates only start while current UTC time is inside the window. |
| `UpdateExclusions` | `YYYY-MM-DD/YYYY-MM-DD`, comma-separated, supports `*` wildcards | `20**-12-20/20**-01-03,2027-06-01/2027-06-10` | No updates start during these dates. **Exclusions override windows.** |

Grammar details:

- **Multiple windows** - separate with `;`: `Mon-Fri_22:00-06:00;Sat-Sun_02:00-10:00`.
- **Day ranges** - wrap-around is supported: `Fri-Mon_22:00-06:00` covers Friday through Monday.
- **Overnight windows** - `Sat_22:00-06:00` means Saturday 22:00 UTC to Sunday 06:00 UTC.
- **Recurring annual exclusions** - use `**` for the year: `20**-12-20/20**-01-03` means every year's Christmas freeze.
- **No tags at all** - updates proceed with no schedule restriction.
- **Malformed tag values** - blocking by default. v0.7.0+ refuses to start the update; pass `-Force` if you intentionally want to update with a known-bad schedule tag.

Test logic interactively before tagging:

```powershell
# Right now in UTC?
Test-AzureLocalUpdateScheduleAllowed -UpdateWindow "Sat-Sun_02:00-06:00" -UpdateExclusions "2026-12-20/2027-01-03"

# A specific past or future moment
Test-AzureLocalUpdateScheduleAllowed -UpdateWindow "Sat_02:00-06:00" -TestTime ([datetime]"2026-04-19 03:00:00")
```

### Multi-stage rollouts with approval gates

For production-critical environments, gate the production wave on the previous wave's success and a human's sign-off.

**Azure DevOps:**

```yaml
stages:
  - stage: Wave1
    jobs:
      - job: ApplyWave1Updates
        # ...

  - stage: ValidateWave1
    dependsOn: Wave1
    jobs:
      - job: WaitForApproval
        pool: server
        steps:
          - task: ManualValidation@0
            inputs:
              notifyUsers: 'ops-team@company.com'
              instructions: 'Review Wave1 update results before proceeding to Wave2.'

  - stage: Wave2
    dependsOn: ValidateWave1
    # ...
```

**GitHub Actions:**

```yaml
jobs:
  wave1:
    runs-on: windows-latest
    environment: wave1  # no approval required
    # ...

  wave2:
    needs: wave1
    runs-on: windows-latest
    environment: production  # configure required reviewers in repo settings
    # ...
```

---

## 9. Tuning throughput (`-ThrottleLimit`)

v0.7.0 runs per-cluster ARM calls in parallel `Start-Job` batches. The `throttle_limit` workflow input on Apply Updates and Fleet Update Status flows into every function that exposes it:

| Function | `-ThrottleLimit` exposed | Used by pipeline |
|---|---|---|
| `Get-AzureLocalClusterUpdateReadiness` | Yes (default 4) | Apply Updates (pre-check), Fleet Update Status, Assess Update Readiness. |
| `Get-AzureLocalUpdateSummary` | Yes (default 4) | Fleet Update Status. |
| `Get-AzureLocalUpdateRuns` | Yes | Fleet Update Status. |
| `Get-AzureLocalFleetStatusData` | Yes (default 4, max 8) | Fleet Update Status, `New-AzureLocalFleetStatusHtmlReport`. |
| `New-AzureLocalFleetStatusHtmlReport` | Yes (default 4, max 8) | Standalone report. |
| `Start-AzureLocalClusterUpdate` (apply-side fleet ops) | Internal via `Invoke-FleetJobsInParallel`; no user-facing `-ThrottleLimit` in v0.7.0. | Apply Updates. |

Suggested starting values:

| Fleet size | `throttle_limit` | Notes |
|---|---|---|
| 1 - 50 clusters | `4` (default) | No tuning needed. |
| 50 - 500 clusters | `6` - `8` | Readiness / fleet-status pipelines complete measurably faster. |
| 500 - 1500+ clusters | `8` - `16` | Required for the fleet-status pipeline to finish inside a 6-hour runner window. Watch for `429 TooManyRequests` and back off. |

> **Throttling is influenced by subscription topology, not just fleet size.** ARM and Azure Resource Graph limits apply per-subscription **and** per-tenant, so the safe `throttle_limit` depends on how clusters are distributed.
>
> Fleets above ~400-500 clusters are almost always already spread across multiple subscriptions because the per-subscription storage-account quota caps the number of clusters that fit in one subscription.
>
> - **Few subscriptions, dense (hundreds per subscription)**: per-subscription ARM quotas exhaust first. Use the lower end of each range and stagger schedules.
> - **Many subscriptions (10+), evenly distributed**: tenant-wide ARG limits and the runner's outbound connection pool dominate. You can usually push to the upper end.
> - **Mixed**: the densest subscription dictates the safe ceiling. Consider splitting the pipeline by subscription (matrix job) so each leg's throttle is sized to its own subscription.
>
> If you see `429 TooManyRequests`, check `x-ms-ratelimit-remaining-*` response headers in verbose logs to identify whether you're hitting subscription, tenant, or resource-type limits before adjusting.

Lower values (`1` - `2`) are useful on constrained self-hosted runners and when you need sequential deterministic logs for debugging.

---

## 10. Standalone HTML report (no pipeline)

For ad-hoc / offline reporting outside CI/CD, `New-AzureLocalFleetStatusHtmlReport` generates a self-contained HTML report you can email or upload to SharePoint. The function is the same code path the Fleet Update Status pipeline uses internally - no pipeline required.

```powershell
Import-Module ./AzLocal.UpdateManagement.psd1

# All clusters the current Az session can see (v0.7.0: uncapped by default; -MaxClusters trims)
New-AzureLocalFleetStatusHtmlReport -AllClusters `
    -OutputPath "C:\Reports\fleet-all.html" `
    -IncludeHealthDetails -IncludeUpdateRuns

# A single named cluster (auto-titles "Seattle - Update Status Report")
New-AzureLocalFleetStatusHtmlReport -ClusterNames Seattle `
    -OutputPath "C:\Reports\seattle.html" `
    -IncludeHealthDetails -IncludeUpdateRuns

# A whole ring at once
New-AzureLocalFleetStatusHtmlReport -ScopeByUpdateRingTag -UpdateRingValue Wave1 `
    -OutputPath "C:\Reports\wave1-status.html" `
    -IncludeHealthDetails -IncludeUpdateRuns

# Capture HTML for an email body
$html = New-AzureLocalFleetStatusHtmlReport -ClusterNames @('Cluster01','Cluster02') `
    -OutputPath "C:\Reports\fleet.html" -PassThru
```

The report includes executive summary cards, cluster information, a status table with Active Update and Recommended Update columns, full update-run history with recursive step traversal, and severity-filtered health-check failures.

---

## 11. Security model

- **Least privilege** - the role list in section 4 is the minimum. The `Azure Stack HCI Update Operator` custom role in [section 4.1](#41-custom-role-azure-stack-hci-update-operator-recommended) is the recommended default; the built-in `Azure Stack HCI Administrator` role is a quick-start convenience that over-grants for production.
- **OIDC / Workload Identity Federation** is the default authentication path. No client secret is stored, federated subject claims bind tokens to your repo / project, and tokens are short-lived.
- **No raw secrets in pipeline YAML or config.** ITSM secrets (when enabled) resolve from Azure Key Vault or CI-native secrets; bearer tokens live in agent memory only.
- **Step-level `env:` mapping** - secrets are mapped into the ITSM step's environment variables, not passed on the PowerShell command line. They never appear in process listings, rendered step inputs, or CI logs.
- **Approval gates** - require manual approval before the Production wave (section 8).
- **Branch protection** - require pull-request reviews for changes to pipeline definitions.
- **TLS 1.2+** is enforced before every HTTP call in the module.
- **CSV-injection sanitisation** - every CSV field produced by the module is neutralised for Excel formula injection (`=`, `+`, `-`, `@`, tab leaders), and CR/LF stripped (v0.7.0+).
- **HTML-escaping** - free-text fields rendered into ITSM tickets are HTML-escaped to defend against ITSM-side HTML injection.

---

## 12. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Azure CLI not authenticated` | Federated credential subject claim does not match the trigger that started the run (e.g. you triggered via `workflow_dispatch` from `production` environment but only federated `refs/heads/main`). | Add a federated credential for the actual subject claim (section 3.1). |
| `No clusters found` | Identity does not see the subscription, or clusters are not `Connected`. | Verify the role assignment scope; confirm cluster state in Azure Portal. The resource-graph extension is auto-installed by the pipelines. |
| `Permission denied applying tags` | Identity is missing `Microsoft.Resources/tags/write`. | Grant per section 4. Same permission covers the v0.7.1 sideloaded-workflow tag writes (`UpdateSideloaded`, `UpdateVersionInProgress`). |
| `Update failed to start` | Cluster is not in `Ready` state, or another update is in progress. | Check cluster health and update state in Azure Portal; review pipeline logs. |
| Apply Updates reports `ScheduleBlocked` for an unexpected cluster | Tag is set but the current UTC time is outside the window, or an `UpdateExclusions` blackout is active. | Confirm the tag value with `Test-AzureLocalUpdateScheduleAllowed` (section 8). |
| Apply Updates reports `SideloadedBlocked` | Cluster has `UpdateSideloaded=False`. | Operator must stage the sideloaded payload and flip the tag, or run `Reset-AzureLocalSideloadedTag` after the next successful run. |
| Fleet Update Status leaves a cluster's update missing from `update-runs.csv` | Pre-v0.7.2: `cp1252` warnings on `az rest` output corrupted JSON parsing. | Upgrade to v0.7.2+ (`--only-show-errors` is now passed everywhere). |
| `429 TooManyRequests` from ARM during fleet operations | Throttle limit too high for the subscription topology. | Reduce `throttle_limit`; consider matrix-by-subscription (section 9). |
| ITSM step always creates duplicates | `u_azlocal_dedupe_key` column was not indexed during ServiceNow setup. | Index it. See [ITSM/README.md section 3.2](../ITSM/README.md#32-add-the-five-custom-fields-on-the-incident-table). |

For ITSM-specific failures, the troubleshooting matrix in [`ITSM/README.md` section 9](../ITSM/README.md#9-troubleshooting) is more specific.

---

## 13. File layout

```text
Automation-Pipeline-Examples/
  README.md                           # This file.
  .itsm/                              # Ready-to-copy ITSM connector config.
    azurelocal-itsm.yml               #   - Matrix config (secrets, defaults, triggers).
    templates/
      incident-body.md                #   - Mustache-style ticket body template.
  github-actions/
    inventory-clusters.yml            # 1. Inventory.
    manage-updatering-tags.yml        # 2. Apply UpdateRing / UpdateWindow / UpdateExclusions tags.
    assess-update-readiness.yml       # 3. Pre-flight readiness report (v0.7.0).
    apply-updates.yml                 # 4. Apply updates to one UpdateRing (with optional ITSM step, v0.7.4).
    fleet-update-status.yml           # 5. Scheduled fleet status snapshot.
  azure-devops/
    inventory-clusters.yml
    manage-updatering-tags.yml
    assess-update-readiness.yml
    apply-updates.yml
    fleet-update-status.yml
```

---

## Appendix A: Pipeline reference

This appendix summarises each pipeline's inputs and outputs without duplicating the YAML.

### A.1 Inventory Clusters

| Aspect | Value |
|---|---|
| **Purpose** | Enumerate every Azure Local cluster the identity can see and export to CSV. |
| **Inputs** | None. |
| **Artefacts** | `cluster-inventory.csv` (one row per cluster, includes current `UpdateRing` / `UpdateWindow` / `UpdateExclusions` and sideloaded-workflow tags). |
| **When to run** | First run of a new estate; periodically to detect new clusters or tag drift. |

### A.2 Manage UpdateRing Tags

| Aspect | Value |
|---|---|
| **Purpose** | Bulk-apply `UpdateRing`, `UpdateWindow`, `UpdateExclusions` tags from a CSV. |
| **Inputs** | `csv_path` (required). |
| **Artefacts** | Pipeline log with added / updated / unchanged counts per cluster. |
| **When to run** | After editing the inventory CSV; whenever ring membership or maintenance windows change. |

### A.3 Assess Update Readiness

| Aspect | Value |
|---|---|
| **Purpose** | Pre-flight, report-only readiness + blocking-health snapshot for a single `UpdateRing`. **Always succeeds** - per-cluster failures show up as JUnit test failures. |
| **Inputs** | `update_ring` (required), `throttle_limit` (optional). |
| **Artefacts** | `readiness.xml`, `readiness.csv`, `health-blocking.xml`, `health-blocking.csv`. |
| **When to run** | Before an Apply Updates run; or on a schedule a day or two ahead of the maintenance window. |

### A.4 Apply Updates

| Aspect | Value |
|---|---|
| **Purpose** | Apply updates to clusters filtered by `UpdateRing` tag value. |
| **Inputs** | `update_ring` (required), `update_name` (optional - leave blank for latest), `dry_run` (optional), `throttle_limit` (optional). **v0.7.4 adds** `raise_itsm_ticket`, `itsm_config_path`, `itsm_dry_run`, `itsm_force_create` (all optional, defaults preserve existing behaviour). |
| **Artefacts** | `update-results.xml` (JUnit, one cluster per test), `update-logs/*` (CSV + detail). When ITSM is enabled: `itsm-results.csv`, `itsm-results.xml`. |
| **When to run** | During the maintenance window for each ring, after the readiness assessment is reviewed. |

### A.5 Fleet Update Status

| Aspect | Value |
|---|---|
| **Purpose** | Daily fleet-wide snapshot of cluster update state. Read-only. |
| **Inputs** | Scope (`-AllClusters` or `-ScopeByUpdateRingTag`), `throttle_limit` (optional). |
| **Schedule** | Daily at 06:00 UTC (configurable in the YAML). |
| **Artefacts** | `readiness-status.xml` / `.csv` / `.json`, `cluster-inventory.csv`, `update-summaries.csv`, `available-updates.csv`, `update-runs.csv`. |
| **When to run** | Hands-off scheduled. Trigger manually for ad-hoc reporting. |

---

## Appendix B: Release history

The body of this document tracks **v0.7.4** behaviour. Older versions are preserved below for reference.

### B.1 v0.7.4 (current)

- **ITSM Connector - Phase 1 (ServiceNow)**. Apply Updates can now open ServiceNow incidents for clusters that need operator action (`Failed`, `Error`, `HealthCheckBlocked`, `SideloadedBlocked`) via the new `New-AzureLocalIncident` function, with idempotent SHA256 dedupe so re-running the same workflow does not create duplicates. **Fully opt-in** - pipelines that do not set `raise_itsm_ticket=true` are byte-identical to v0.7.3 behaviour. Sample config + Mustache ticket-body template ship at [`./.itsm/`](./.itsm/). Setup, secret sourcing, and troubleshooting documented in [`../ITSM/README.md`](../ITSM/README.md); design + decisions log in [`../ITSM/ITSM-Connector-Plan.md`](../ITSM/ITSM-Connector-Plan.md).
- **OAuth 2.0 `client_credentials`** only in Phase 1. Secrets resolve from Azure Key Vault (`kv://<vault>/<secret>`, **recommended**), environment variables (`env://NAME`, native-secret fallback), or explicit `literal://...` values guarded by `-AllowLiteral`. The pipeline service principal needs `Key Vault Secrets User` on the configured vault; no other new RBAC.
- **DryRun mode** (`-DryRun` on `New-AzureLocalIncident`, or pipeline input `itsm_dry_run=true`) resolves secrets, runs the read-only dedupe lookup, builds the full ticket payload, but does not POST. Output CSV + JUnit projection let you validate the trigger matrix and template rendering before pointing at production ServiceNow.
- **`Test-AzureLocalItsmConnection`** runs the OAuth token grant and a one-row read against `/api/now/table/incident`, matching the least-privilege scope used by ticket creation. Run it manually before flipping `raise_itsm_ticket=true`.
- **New JUnit projection** (`-ExportJUnitPath` on `New-AzureLocalIncident`) emits per-cluster ITSM actions as a JUnit XML artefact - `CreateFailed` -> `<failure>`, `Skipped` / `WhatIf` -> `<skipped>`, default -> success. Consumed by `dorny/test-reporter` / `PublishTestResults@2` so ITSM activity is visible in the Tests tab.
- **Phase 2 (`Sync-AzureLocalIncident` close-out)** and **Phase 3 (Teams + Slack mirror)** are designed in [`ITSM-Connector-Plan.md`](../ITSM/ITSM-Connector-Plan.md) and **deferred** to a future release. The `lifecycle` and `notifications` sections of the config schema are parsed and stored but not yet acted on.

### B.2 v0.7.2

- **Fleet read paths now work as documented under `-ThrottleLimit > 1`**. The `fleet-update-status.yml` workflow (and any direct caller of `Get-AzureLocalUpdateRuns`, `Get-AzureLocalUpdateSummary`, or `Get-AzureLocalClusterUpdateReadiness` with `-ThrottleLimit` greater than 1) previously failed for every cluster with `The term 'Get-AzLocalClusterUpdateRuns' is not recognized...` because module-private helpers were not visible inside `Start-Job` child runspaces. Resolved via `& $module { ... }` dispatch through the loaded module's session state. **Action**: re-enable `-ThrottleLimit` in your fleet workflows.
- **Stray `cp1252` warnings no longer break JSON parsing on hosted Windows runners**. Default `windows-latest` GitHub runners and Azure DevOps `windows-2022` agents both run with the `cp1252` console code page; the Azure CLI emitted `WARNING: Unable to encode the output with cp1252 encoding...` on any ARM response containing non-ASCII characters. Captured via `2>&1`, that warning was prepended to the JSON body and silently broke `ConvertFrom-Json`, dropping update runs and available updates from pipeline reports. v0.7.2 passes `--only-show-errors` to every `az rest` and `az graph query` invocation. **No pipeline configuration change required** - upgrade and the runs/summaries are simply complete again.
- Full root-cause writeup: [main README v0.7.2 entry](../README.md#whats-new-in-v072).

### B.3 v0.7.1

- **Sideloaded payload workflow**. Two new tags coordinate human-driven sideloaded update payloads with the apply-updates pipeline:
  - `UpdateSideloaded` (operator-set, `True`/`False`/`1`/`0`) gates `Start-AzureLocalClusterUpdate`. When `False`, the apply-updates pipeline skips the cluster with `Status = SideloadedBlocked`.
  - `UpdateVersionInProgress` (module-managed; do not set manually) holds the staged update name. `Get-AzureLocalUpdateRuns` auto-resets `UpdateSideloaded -> False` and clears `UpdateVersionInProgress` when the latest run is `Succeeded` and its update name matches. Use `-SkipSideloadedReset` on read-only paths.
- **New public function** `Reset-AzureLocalSideloadedTag` for explicit-scope manual reset. Three parameter sets: `-ClusterNames`, `-ClusterResourceIds`, or `-ScopeByUpdateRingTag -UpdateRingValue`. Supports `-WhatIf`/`-Confirm`. Default behaviour requires `latest run = Succeeded` **and** a case-insensitive update-name match against `UpdateVersionInProgress`. `-Force` bypasses the version-match check (still requires `Succeeded` state). Returns one row per cluster with `Action` / `PreviousSideloaded` / `NewSideloaded` / `StagedVersion` / `MatchedRunUpdateName` / `Message`.
- **No new RBAC** - the existing `Microsoft.Resources/tags/read|write` permissions cover it.
- **Fully opt-in** - clusters without the `UpdateSideloaded` tag behave exactly as in v0.7.0.
- Full runbook: [main README sideloaded workflow section](../README.md#7a-sideloaded-payload-workflow-v071).

### B.4 v0.7.0

- **Parallel per-cluster operations**. `Get-AzureLocalClusterUpdateReadiness`, `Test-AzureLocalClusterHealth`, `Get-AzureLocalUpdateSummary`, `Get-AzureLocalAvailableUpdates`, `Get-AzureLocalUpdateRuns`, and `Set-AzureLocalClusterUpdateRingTag` now run per-cluster ARM calls in parallel `Start-Job` batches. `Invoke-AzureLocalFleetOperation -ThrottleLimit` is honoured end-to-end. Expected 5-10x speedup on 1500-cluster runs.
- **`-ThrottleLimit` is a workflow input** on Apply Updates and Fleet Update Status (default 4, range 1-16).
- **ARG queries paginate**. All scope-resolving queries follow the `$skipToken` until exhausted (previously capped silently at 1000).
- **`-AllClusters` cap removed**. `New-AzureLocalFleetStatusHtmlReport -AllClusters` and `Get-AzureLocalFleetStatusData -AllClusters` no longer truncate at 100; use `-MaxClusters <n>` to trim explicitly.
- **CSV sanitisation**. Every CSV field is protected against Excel formula injection (`=`, `+`, `-`, `@`, tab leaders neutralised, CR/LF stripped).
- **Token refresh mid-run**. `Invoke-AzRestJson` refreshes on HTTP 401 so long-running apply jobs no longer die at the 1-hour token boundary.
- **Schedule-tag parse errors are blocking by default** unless `-Force`. A malformed `UpdateWindow` / `UpdateExclusions` no longer lets the update sneak through with just a warning.

---

## 16. Related documentation

- [Azure Local Update Management module README](../README.md)
- [ITSM Connector setup guide (`ITSM/README.md`)](../ITSM/README.md) - optional, opt-in ServiceNow integration.
- [ITSM Connector design + decisions log (`ITSM/ITSM-Connector-Plan.md`)](../ITSM/ITSM-Connector-Plan.md)
- [Azure Stack HCI documentation](https://learn.microsoft.com/azure-stack/hci/)
- [GitHub Actions documentation](https://docs.github.com/en/actions)
- [Azure DevOps Pipelines documentation](https://learn.microsoft.com/azure/devops/pipelines/)
