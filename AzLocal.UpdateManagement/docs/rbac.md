# AzLocal.UpdateManagement RBAC Reference

> **What you will find here:** Every Azure RBAC role and scope the module needs, broken down by cmdlet group (read-only, planning, executing updates, hybrid runners). Use this when granting an automation principal the least-privilege set of roles before wiring up a pipeline.
>
> **Cross-reference:** The main [README.md](../README.md) only summarises the role list. This file is the canonical reference.

---

## RBAC Requirements

To start updates on Azure Local clusters, users need specific permissions on the `Microsoft.AzureStackHCI` resource provider.

### Recommended Built-in Roles

| Role | Role ID | Description |
|------|---------|-------------|
| **Azure Stack HCI Administrator** | `bda0d508-adf1-4af0-9c28-88919fc3ae06` | Full access to cluster and resources, including updates |
| **Azure Stack HCI Device Management Role** | `865ae368-6a45-4bd1-8fbf-0d5151f56fc1` | Full cluster operations including updates |

### Specific Permissions Required

The following permissions are required for update + fleet-connectivity operations:

| Operation | Required Permission |
|-----------|---------------------|
| Read cluster info | `Microsoft.AzureStackHCI/clusters/read` |
| Read update summary | `Microsoft.AzureStackHCI/clusters/updateSummaries/read` |
| List available updates | `Microsoft.AzureStackHCI/clusters/updates/read` |
| **Refresh assessment ("Check for updates", preview)** | `Microsoft.AzureStackHCI/clusters/updateSummaries/default/checkUpdates` (POST action - see preview note below) |
| **Start/Apply update** | `Microsoft.AzureStackHCI/clusters/updates/apply/action` |
| Monitor update runs | `Microsoft.AzureStackHCI/clusters/updates/updateRuns/read` |
| Query clusters (Resource Graph) | `Microsoft.ResourceGraph/resources/read` |
| **Read/Write tags** | `Microsoft.Resources/tags/read`, `Microsoft.Resources/tags/write` |
| Read Arc machine agent status (Monitor: 1) | `Microsoft.HybridCompute/machines/read` |
| Read Arc machine extensions (reserved for future extension reporting) | `Microsoft.HybridCompute/machines/extensions/read` |
| Read physical NIC inventory via edge devices (Monitor: 1) | `Microsoft.AzureStackHCI/edgeDevices/read` |
| Read Azure Resource Bridge appliance status (Monitor: 1) | `Microsoft.ResourceConnector/appliances/read` |

> **v0.7.80 note:** The last three rows above were added in v0.7.80. They are required by `Get-AzLocalFleetConnectivityStatus` (introduced in v0.7.79) and therefore by the `fleet-connectivity-status.yml` pipeline. Without them, the cmdlet still returns the cluster connectivity section but every other section (Arc agents, physical NICs, Azure Resource Bridges) silently returns zero rows because ARG yields an empty `.data` array for resource types the caller cannot read. Pipelines that were created against the v0.7.79-or-earlier custom-role JSON will see 0 Arc agents / 0 NICs / 0 ARBs until the role is updated.

> **v0.8.88 note - "Check for updates" (`checkUpdates`) is preview and NOT yet in any custom role:** `Sync-AzLocalClusterUpdateSummary` and the opt-out stale-assessment auto-scan in `Export-AzLocalClusterUpdateReadinessReport` POST `Microsoft.AzureStackHCI/clusters/updateSummaries/default/checkUpdates` on the `2026-03-01-preview` API. The action is **not yet published in the `Microsoft.AzureStackHCI` provider operations catalog**, so it **cannot be added to the `Actions[]` of a custom role definition today** - `az role definition update` validates each entry against the catalog and rejects unregistered actions. The custom roles below therefore deliberately omit it. Until it GAs, only built-in roles that grant the broad `Microsoft.AzureStackHCI/*` action set (e.g. **Azure Stack HCI Administrator**) or **Contributor** authorize the refresh; under the least-privilege custom role the call returns a non-fatal `403 AuthorizationFailed` (logged, then execution continues - the readiness report still completes). Pass `-SkipStaleAssessmentScan` to suppress the auto-scan. **When `checkUpdates` GAs, add the GA'd action (expected `Microsoft.AzureStackHCI/clusters/updateSummaries/checkUpdates/action` - confirm the exact string from a 403 `AuthorizationFailed` body or `az provider operation show --namespace Microsoft.AzureStackHCI`) to every `Actions[]` block in this file and to the bundled `azlocal-update-management-custom-role.json`.**

### Roles That Do NOT Have Update Permissions

| Role | Reason |
|------|--------|
| Azure Stack HCI VM Contributor | Only has `clusters/read` - cannot apply updates |
| Azure Stack HCI VM Reader | Read-only access to VMs, no cluster update permissions |
| Contributor (generic) | Does not include `Microsoft.AzureStackHCI` permissions by default |

### Custom "Azure Stack HCI Update Operator (custom)" Role Definition (Least Privilege)

If you need a least-privilege custom role specifically for update operations:

> **JSON format - CLI/PowerShell vs Portal "JSON tab":** The role definition below is in the **CLI / PowerShell format** (top-level `Name`, `IsCustom`, `Actions`, `AssignableScopes`) - the shape consumed by `az role definition create` / `update` and `New-AzRoleDefinition`. The Azure portal's **Edit a custom role -> JSON tab** uses a different shape (the ARM resource representation, wrapped in `properties` with lowercase camelCase and `actions` nested under `permissions[0]`). Pasting this JSON into the portal JSON tab will fail with `Malformed JSON: "properties" property not present or value is null`. To update an existing role from the portal, use the **Permissions** tab (add or remove the actions there) instead of the JSON tab, or run `az role definition create` / `update --role-definition <file>` from a shell.

> **UTF-8 BOM gotcha (`az` CLI):** `az role definition create` / `update` uses Python's `json` parser, which rejects files that start with a UTF-8 BOM and fails with `Failed to parse string as JSON ... Expecting value: line 1 column 1 (char 0)`. If you copy the JSON below into a file via Windows PowerShell `Out-File` / `Set-Content` / `>` redirection, or Notepad `Save As -> UTF-8`, the file may pick up a BOM. Verify with `'{0:X2}' -f [IO.File]::ReadAllBytes($f)[0]` (expect `7B` for `{`, not `EF`). To strip a BOM in place: `[IO.File]::WriteAllText($f, [IO.File]::ReadAllText($f, [Text.UTF8Encoding]::new($false)), [Text.UTF8Encoding]::new($false))`. The bundled file at [`Automation-Pipeline-Examples/azlocal-update-management-custom-role.json`](../Automation-Pipeline-Examples/azlocal-update-management-custom-role.json) ships BOM-free.

```json
{
  "Name": "Azure Stack HCI Update Operator (custom)",
  "IsCustom": true,
  "Description": "Customer-managed custom role - reference by roleDefinitionId (GUID) in automation rather than by name to remain stable if Microsoft later ships a built-in role with a similar display name. Can read and apply Azure Local cluster updates, manage UpdateRing tags, and read the fleet-connectivity inventory (Arc-enabled machines, edge-device NICs, Azure Resource Bridges) needed to assess pre-update connectivity.",
  "Actions": [
    "Microsoft.AzureStackHCI/clusters/read",
    "Microsoft.AzureStackHCI/clusters/updateSummaries/read",
    "Microsoft.AzureStackHCI/clusters/updates/read",
    "Microsoft.AzureStackHCI/clusters/updates/apply/action",
    "Microsoft.AzureStackHCI/clusters/updates/updateRuns/read",
    "Microsoft.AzureStackHCI/edgeDevices/read",
    "Microsoft.HybridCompute/machines/read",
    "Microsoft.HybridCompute/machines/extensions/read",
    "Microsoft.ResourceConnector/appliances/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.ResourceGraph/resources/read",
    "Microsoft.Resources/tags/read",
    "Microsoft.Resources/tags/write"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/subscriptions/{subscription-id}"
  ]
}
```

Save this JSON to a file named `azlocal-update-management-custom-role.json`, then create the custom role using Azure CLI:

`AssignableScopes` must contain a real subscription ID - the literal `{subscription-id}` placeholder will be rejected by `az role definition create`. Capture the current subscription first, or hard-code the IDs you intend to manage:

```powershell
# Use the current az CLI subscription, or set $subId manually
$subId = az account show --query id -o tsv
```

```powershell
# Option 1: File already on disk - substitute the placeholder, then create
(Get-Content ./azlocal-update-management-custom-role.json -Raw) `
    -replace '\{subscription-id\}', $subId |
    Set-Content ./azlocal-update-management-custom-role.json -Encoding UTF8

az role definition create --role-definition ./azlocal-update-management-custom-role.json

# Option 2: Create the file and role in one step using PowerShell (expanding here-string - $subId is interpolated)
@"
{
  "Name": "Azure Stack HCI Update Operator (custom)",
  "IsCustom": true,
  "Description": "Customer-managed custom role - reference by roleDefinitionId (GUID) in automation rather than by name to remain stable if Microsoft later ships a built-in role with a similar display name. Can read and apply Azure Local cluster updates, manage UpdateRing tags, and read the fleet-connectivity inventory (Arc-enabled machines, edge-device NICs, Azure Resource Bridges) needed to assess pre-update connectivity.",
  "Actions": [
    "Microsoft.AzureStackHCI/clusters/read",
    "Microsoft.AzureStackHCI/clusters/updateSummaries/read",
    "Microsoft.AzureStackHCI/clusters/updates/read",
    "Microsoft.AzureStackHCI/clusters/updates/apply/action",
    "Microsoft.AzureStackHCI/clusters/updates/updateRuns/read",
    "Microsoft.AzureStackHCI/edgeDevices/read",
    "Microsoft.HybridCompute/machines/read",
    "Microsoft.HybridCompute/machines/extensions/read",
    "Microsoft.ResourceConnector/appliances/read",
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

> **Note**: Option 2 uses a double-quoted here-string (`@"..."@`) so PowerShell expands `$subId` before writing the JSON to disk. A literal here-string (`@'...'@`) would NOT expand the variable - you would have to substitute the placeholder yourself as in Option 1.

### Scaling AssignableScopes with management groups + Azure Policy (recommended for large or growing estates)

The per-subscription `AssignableScopes` pattern above works well for a handful of subscriptions but becomes painful at scale:

- Every time a new subscription is added to the fleet, you must `az role definition update` to extend `AssignableScopes` AND `az role assignment create` for the pipeline identity.
- The role definition itself has a **hard cap of 2000 entries** in `AssignableScopes`.
- Drift is hard to detect - a subscription that was provisioned without the assignment silently disappears from the pipeline's reach.

For estates of more than ~5-10 subscriptions, or any estate where new subscriptions are provisioned regularly, scale this out with three standard Azure primitives:

1. **A single management-group entry in `AssignableScopes`** on the custom role definition (custom roles can be assigned at or below any scope listed in `AssignableScopes`, and management-group scopes have been supported since 2020).
2. **An Entra security group** that the role is granted to (rather than granting it directly to the pipeline service principal). Onboarding or rotating a pipeline identity then becomes a single group-membership change with zero RBAC privilege.
3. **An Azure Policy `deployIfNotExists` (DINE) assignment at that management group** that creates the per-subscription role assignment (to the group) automatically. Existing subscriptions are picked up by a one-time remediation task; new subscriptions are auto-remediated as they are created. This is the standard Azure Landing Zones pattern.

The result: when a new subscription joins the management group, the operators security group gets the `Azure Stack HCI Update Operator (custom)` role at that subscription with zero manual steps, and every member of that group (the OIDC pipeline identity plus any break-glass operators) inherits it.

**Step 1 - role definition with a management-group `AssignableScopes`**

Replace the per-subscription entry shown above with one (or more) management-group scope(s). The MG scope must be the **resource path**, NOT just the MG name:

```json
{
  "Name": "Azure Stack HCI Update Operator (custom)",
  "IsCustom": true,
  "Description": "Customer-managed custom role - reference by roleDefinitionId (GUID) in automation rather than by name to remain stable if Microsoft later ships a built-in role with a similar display name. Can read and apply Azure Local cluster updates, manage UpdateRing tags, and read the fleet-connectivity inventory (Arc-enabled machines, edge-device NICs, Azure Resource Bridges) needed to assess pre-update connectivity.",
  "Actions": [
    "Microsoft.AzureStackHCI/clusters/read",
    "Microsoft.AzureStackHCI/clusters/updateSummaries/read",
    "Microsoft.AzureStackHCI/clusters/updates/read",
    "Microsoft.AzureStackHCI/clusters/updates/apply/action",
    "Microsoft.AzureStackHCI/clusters/updates/updateRuns/read",
    "Microsoft.AzureStackHCI/edgeDevices/read",
    "Microsoft.HybridCompute/machines/read",
    "Microsoft.HybridCompute/machines/extensions/read",
    "Microsoft.ResourceConnector/appliances/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read",
    "Microsoft.ResourceGraph/resources/read",
    "Microsoft.Resources/tags/read",
    "Microsoft.Resources/tags/write"
  ],
  "NotActions": [],
  "DataActions": [],
  "NotDataActions": [],
  "AssignableScopes": [
    "/providers/Microsoft.Management/managementGroups/<your-mg-id>"
  ]
}
```

Create the role exactly as before with `az role definition create --role-definition <file>`. The signed-in identity needs `Microsoft.Authorization/roleDefinitions/write` at the MG (most narrowly granted by **Role Based Access Control Administrator** on the MG).

**Step 2 - capture the role definition ID** (referenced by the policy):

```powershell
$roleId = az role definition list `
    --custom-role-only true `
    --name "Azure Stack HCI Update Operator (custom)" `
    --query "[0].name" -o tsv
# Returns the role's GUID. The policy references it as:
# "/providers/Microsoft.Authorization/roleDefinitions/$roleId"
```

**Step 3 - create an Entra security group and capture its object ID** (the principal that the role assignment grants the role TO):

> **Recommended: assign the role to a security GROUP, not directly to the pipeline service principal.** When the DINE policy grants the role to a group, onboarding (or rotating) a pipeline identity becomes a single `az ad group member add` - no RBAC privilege and no policy change required. Add the OIDC service principal (and any human break-glass operators) to this group; everything they need across the whole estate flows from group membership. This is the flow documented as the happy path in the CI/CD README.

```powershell
# Create a standard Entra security group (one-time). A plain security group is
# sufficient - it does NOT need to be mail-enabled or role-assignable.
$groupId = az ad group create `
    --display-name "AzureLocal-UpdateAutomation-Operators" `
    --mail-nickname "AzureLocal-UpdateAutomation-Operators" `
    --query id -o tsv

# If the group already exists, capture its object ID instead:
# $groupId = az ad group show --group "AzureLocal-UpdateAutomation-Operators" --query id -o tsv
```

> **Alternative - assign directly to the pipeline identity** (smaller estates, or where you do not want a group): capture the principal object ID instead of a group and set `principalType` to `ServicePrincipal` in Step 4. `$groupId = az ad sp show --id <appId> --query id -o tsv` for a service principal / App Registration, or `az identity show -g <rg> -n <mi-name> --query principalId -o tsv` for a user-assigned managed identity. The Step 5 step that adds the SP to the group is then not needed.

**Step 4 - create the policy definition at the management group**

The `deployIfNotExists` policy below targets `Microsoft.Resources/subscriptions` and, where the named role assignment does not already exist, deploys a subscription-scoped role assignment from a nested ARM template:

```jsonc
{
  "properties": {
    "displayName": "Assign 'Azure Stack HCI Update Operator (custom)' to update-automation pipeline",
    "description": "DeployIfNotExists policy that auto-grants the named custom role to the update-automation pipeline identity on every subscription under the management group it is assigned at.",
    "mode": "All",
    "policyType": "Custom",
    "parameters": {
      "roleDefinitionId": {
        "type": "String",
        "metadata": { "displayName": "Custom role definition resource ID" }
      },
      "principalId": {
        "type": "String",
        "metadata": { "displayName": "Security group (or pipeline identity) object ID" }
      },
      "principalType": {
        "type": "String",
        "defaultValue": "Group",
        "allowedValues": [ "Group", "ServicePrincipal" ],
        "metadata": { "displayName": "Principal type - Group (recommended) or ServicePrincipal" }
      }
    },
    "policyRule": {
      "if": {
        "field": "type",
        "equals": "Microsoft.Resources/subscriptions"
      },
      "then": {
        "effect": "deployIfNotExists",
        "details": {
          "type": "Microsoft.Authorization/roleAssignments",
          "roleDefinitionIds": [
            "[parameters('roleDefinitionId')]"
          ],
          "existenceCondition": {
            "allOf": [
              { "field": "Microsoft.Authorization/roleAssignments/principalId",
                "equals": "[parameters('principalId')]" },
              { "field": "Microsoft.Authorization/roleAssignments/roleDefinitionId",
                "equals": "[parameters('roleDefinitionId')]" }
            ]
          },
          "deployment": {
            "properties": {
              "mode": "Incremental",
              "parameters": {
                "roleDefinitionId": { "value": "[parameters('roleDefinitionId')]" },
                "principalId":      { "value": "[parameters('principalId')]" },
                "principalType":    { "value": "[parameters('principalType')]" }
              },
              "template": {
                "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
                "contentVersion": "1.0.0.0",
                "parameters": {
                  "roleDefinitionId": { "type": "string" },
                  "principalId":      { "type": "string" },
                  "principalType":    { "type": "string" }
                },
                "variables": {
                  "assignmentName": "[guid(subscription().id, parameters('roleDefinitionId'), parameters('principalId'))]"
                },
                "resources": [
                  {
                    "type": "Microsoft.Authorization/roleAssignments",
                    "apiVersion": "2022-04-01",
                    "name": "[variables('assignmentName')]",
                    "properties": {
                      "roleDefinitionId": "[parameters('roleDefinitionId')]",
                      "principalId":      "[parameters('principalId')]",
                      "principalType":    "[parameters('principalType')]"
                    }
                  }
                ]
              }
            }
          }
        }
      }
    }
  }
}
```

Save the file (for example as `assign-azlocal-update-operator-policy.json`) and create the policy definition at the MG:

```powershell
az policy definition create `
    --name        "assign-azlocal-update-operator" `
    --display-name "Assign Azure Stack HCI Update Operator (custom) to update-automation pipeline" `
    --management-group <your-mg-id> `
    --rules    "./assign-azlocal-update-operator-policy.json" `
    --mode All
```

**Step 5 - assign the policy at the management group with a system-assigned managed identity**

DINE policies need a managed identity that can create the role assignments. Azure Policy creates one automatically when you supply `--mi-system-assigned` and `--location`:

```powershell
$assignment = az policy assignment create `
    --name "assign-azlocal-update-operator" `
    --display-name "Assign Azure Stack HCI Update Operator (custom) to update-automation pipeline" `
    --policy "assign-azlocal-update-operator" `
    --scope "/providers/Microsoft.Management/managementGroups/<your-mg-id>" `
    --mi-system-assigned `
    --location <region> `
    --params @"
{
  \"roleDefinitionId\": { \"value\": \"/providers/Microsoft.Authorization/roleDefinitions/$roleId\" },
  \"principalId\":      { \"value\": \"$groupId\" },
  \"principalType\":    { \"value\": \"Group\" }
}
"@ -o json | ConvertFrom-Json

# Grant the policy's managed identity rights to create role assignments at the MG.
# Use User Access Administrator (or Role Based Access Control Administrator) at the MG scope.
az role assignment create `
    --assignee-object-id      $assignment.identity.principalId `
    --assignee-principal-type ServicePrincipal `
    --role "User Access Administrator" `
    --scope "/providers/Microsoft.Management/managementGroups/<your-mg-id>"
```

> **Required permissions for this step**: You need `Owner` or `User Access Administrator` (or `Role Based Access Control Administrator`) at the management-group scope to create the policy assignment AND to grant the policy's MI `User Access Administrator`. This is intentionally a privileged one-time setup - day-to-day onboarding of new subscriptions then requires no RBAC privilege at all (the policy does it).

**Step 6 - remediate existing subscriptions** (one-time):

```powershell
az policy remediation create `
    --name "remediate-existing-subs-azlocal-update-operator" `
    --policy-assignment "/providers/Microsoft.Management/managementGroups/<your-mg-id>/providers/Microsoft.Authorization/policyAssignments/assign-azlocal-update-operator" `
    --resource-discovery-mode ReEvaluateCompliance
```

This walks every subscription already under the MG, evaluates compliance, and creates the missing role assignment where required. New subscriptions added to the MG after this point are auto-remediated as they are created (the DINE effect runs on resource create).

**Step 7 - add the pipeline identity (and any human operators) to the security group**

This is the only step you repeat when onboarding or rotating a pipeline identity. Because the role is granted to the group across the whole management group, adding a principal to the group grants it the full `Azure Stack HCI Update Operator (custom)` reach on every in-scope subscription - with no RBAC privilege and no policy change:

```powershell
# Add the CI/CD OIDC service principal (App Registration) to the operators group.
# $appId is the Application (client) ID of the federated-credential app registration.
$spObjectId = az ad sp show --id <appId> --query id -o tsv
az ad group member add `
    --group "AzureLocal-UpdateAutomation-Operators" `
    --member-id $spObjectId

# (Optional) add human break-glass operators by their user object ID:
# az ad group member add --group "AzureLocal-UpdateAutomation-Operators" --member-id <user-object-id>
```

> **Group object ID propagation**: a newly created Entra group and new memberships are usually usable within a minute or two, but can take longer to propagate to all regions. If the first pipeline run after onboarding reports missing permissions, wait a few minutes and re-run before investigating further.

**Trade-offs vs the per-subscription `AssignableScopes` list**

| Aspect | Per-subscription `AssignableScopes` list | Management group + Policy DINE |
|---|---|---|
| Onboarding a new subscription | `az role definition update` to extend `AssignableScopes`, then `az role assignment create` per sub | Automatic - just move the sub under the MG |
| Scale cap | 2000 entries per role definition | Effectively unbounded |
| Standing privilege required | `Microsoft.Authorization/roleDefinitions/write` + `roleAssignments/write` at each subscription, every time | `Owner` / `UAA` at the MG once, then nothing |
| Drift correction | Manual audit | Automatic - non-compliant subs visible in Policy compliance and re-remediable on demand |
| Audit surface | RBAC blade per sub | Azure Policy compliance dashboard + Activity Log per subscription |
| Time-to-onboard | Manual, per-sub | Sub-creation -> policy evaluation (~minutes) |

**When to stick with the per-subscription list:**

- You don't have access to a management group covering the in-scope subscriptions.
- The estate is small (1-5 subscriptions) and doesn't change.
- You explicitly want each role grant to be a deliberate manual operation (e.g. for regulatory reasons).



If you created the custom role against the v0.7.79-or-earlier definition above, you are missing the three new fleet-connectivity reads (`Microsoft.HybridCompute/machines/read`, `Microsoft.AzureStackHCI/edgeDevices/read`, `Microsoft.ResourceConnector/appliances/read`). Update the existing role in place rather than recreating it (recreating it would invalidate the role ID and break every existing role assignment):

```powershell
# Refresh the local JSON to the v0.7.80 definition (re-run Option 1 or Option 2 above to overwrite the file),
# then update the role in Azure RBAC. Role permission changes propagate within a few minutes; no need to re-assign.
az role definition update --role-definition ./azlocal-update-management-custom-role.json
```

You can also use the Azure portal: Subscription > Access control (IAM) > Roles > "Azure Stack HCI Update Operator (custom)" > Clone/Edit > Permissions > add the three reads. Avoid the "Delete and recreate" path - it changes the role's GUID and unassigns every principal currently using it.

### Assigning a Role

```powershell
# Assign Azure Stack HCI Administrator role to a user
az role assignment create `
  --assignee "user@contoso.com" `
  --role "Azure Stack HCI Administrator" `
  --scope "/subscriptions/{subscription-id}/resourceGroups/{resource-group}"
```

> **Reference**: [Azure built-in roles for Hybrid + multicloud](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/hybrid-multicloud)

