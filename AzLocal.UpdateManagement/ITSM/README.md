# ITSM Connector for AzLocal.UpdateManagement

> Optional feature. Disabled by default. Requires `AzLocal.UpdateManagement` v0.7.4 or later; this guide describes the current v0.9.30 behavior.

This folder is the setup-and-configure landing page for the ITSM Connector. It walks an operator through every step from "nothing wired" to "the apply-updates pipeline opens a deduped ServiceNow incident when a cluster needs human intervention".

The connector is **fully opt-in**: existing pipelines that do not set `raise_itsm_ticket=true` are unchanged.

| File | Purpose |
|---|---|
| `README.md` | This page - setup walkthrough and quick start. |
| [ITSM-Config-Reference.md](./ITSM-Config-Reference.md) | Full schema reference for the YAML/JSON config (every field, every default). |
| [ITSM-Connector-Plan.md](./ITSM-Connector-Plan.md) | Design + decisions log (architecture, trigger matrix, severity mapping, security model). |

A working sample config plus the Mustache ticket-body template live at [`../Automation-Pipeline-Examples/.itsm/`](../Automation-Pipeline-Examples/.itsm/).

---

## 1. What this connector does

Five operator-attention pipelines support the connector: Monitor: 1, Monitor: 2, Monitor: 3, Update: 3, and Update: 4. When enabled, the connector reads the pipeline's JUnit results and processes each cluster row whose `Status` is configured to raise a ticket:

1. Computes a deterministic dedupe key (SHA256 of `ClusterResourceId | UpdateName | TriggerCategory`).
2. Asks ServiceNow whether an incident with that key already exists in state New / In Progress / On Hold.
3. If yes -> returns `Action='DedupedToExisting'` (no new ticket).
4. If no -> creates a new incident with the trigger's severity, category, and the five `u_azlocal_*` custom fields populated.

Ticket creation is fully opt-in and does not change pipeline success. Dry-run mode builds and exports the proposed incidents without creating them. The connector does not open Jira or Azure DevOps work items, send Teams or Slack notifications, or close incidents automatically; see the [design plan](./ITSM-Connector-Plan.md) for deferred capabilities.

---

## 2. Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Same as the rest of the module. |
| `Az.Accounts` + `Az.KeyVault` modules | Only when `secrets.source: keyvault` (recommended). `Az.KeyVault` is checked at runtime - install with `Install-Module Az.KeyVault -Scope CurrentUser` if not present. |
| `powershell-yaml` module | Only when the config file is `.yml` / `.yaml`. JSON config works on stock PowerShell. Install with `Install-Module powershell-yaml -Scope CurrentUser`. |
| An Azure Key Vault | Recommended for storing the ServiceNow OAuth client_secret. CI-native secrets (`env://NAME`) are supported as a fallback for users with no Key Vault access. |
| ServiceNow instance | Any supported release. You will register one OAuth application + import one Update Set (see Section 3). |

---

## 3. ServiceNow one-time setup

You need three things in ServiceNow: an OAuth app, five custom fields on the `incident` table, and an assignment group.

### 3.1 Register an OAuth application registry

1. In ServiceNow, navigate to **System OAuth -> Application Registry**.
2. **New -> Create an OAuth API endpoint for external clients**.
3. Name: `AzLocal Update Management`. **Save**.
4. Copy the generated **Client ID** and **Client Secret** - both go into Key Vault in Section 4.
5. Note your instance URL (e.g. `https://yourco.service-now.com`).

#### 3.1.5 Service account and roles for the OAuth client

The OAuth `client_credentials` grant ServiceNow issues is tied to a **ServiceNow user account** (commonly called the *technical user* or *integration user*). The token the connector receives carries that user's roles, and ServiceNow Table API authorisation is evaluated against those roles - not against the OAuth app itself. Misconfigure this and step 4 of the connection probe (Section 6) fails with HTTP 403 even though OAuth succeeded.

Recommended setup:

1. Create a dedicated user (e.g. `svc.azlocal.itsm`) in **User Administration -> Users**. Mark it **Web service access only** and **Internal Integration User** if your release supports those flags.
2. Open the **Application Registry** record from Section 3.1 and set **OAuth Provider Profile -> Run as user** to the new account. (On releases where Application Registries do not expose this directly, set the user inside the linked **OAuth Entity Profile**.)
3. Grant the user **`itil`** role (read + write on `incident`) AND a role that can read the table the connection probe issues a one-row read against (`itil` is sufficient). Do NOT grant `admin`.
4. If you also want the connector to read existing incidents created by humans (for dedupe), make sure those incidents are not restricted by an ACL the `itil` role cannot satisfy.

Nothing in the connector requires elevated privileges. Keep the role footprint to `itil`.

### 3.2 Add the five custom fields on the `incident` table

The connector writes five custom fields to every incident it creates so future runs can find them. The original plan shipped an Update Set XML for this; in v0.7.4 it is a **manual procedure** (Update Set XML is deferred to a follow-up release). All five fields go on the `incident` table:

| Field name | Type | Max length | Default | Indexed | Why |
|---|---|---:|---|---|---|
| `u_azlocal_dedupe_key` | String | 64 | (empty) | **Yes - required** | SHA256 hex used by `FindByDedupe`. Without an index, every dedupe lookup performs a full table scan and breaks on large instances. |
| `u_azlocal_cluster_resource_id` | String | 512 | (empty) | No | Full Azure resource ID of the cluster - operators use this to jump to Portal. |
| `u_azlocal_update_name` | String | 64 | (empty) | No | The HCI update name (e.g. `2511.0.10.0`). |
| `u_azlocal_run_id` | String | 128 | (empty) | No | Workflow / pipeline run ID - links back to the originating CI run. |
| `u_azlocal_source` | String | 64 | `AzLocal.UpdateManagement` | No | Discriminator; lets `Sync-AzLocalIncident` (Phase 2) filter to tickets it owns. |

Procedure:

1. Sign in to ServiceNow as a user with `admin`.
2. Navigate to **System Definition -> Tables**, search for `incident`, open it.
3. In the **Columns** related list, **New** and create each row from the table above. Pick **Type: String**, set **Max length**, and set **Column name** to the value in the table (ServiceNow auto-prefixes `u_`, so type `azlocal_dedupe_key` - the `u_` shown here is the rendered column name).
4. For `u_azlocal_dedupe_key`, after saving open the column and tick **Create Index** (or **Add Index** on older releases). **This is required** - the dedupe query is `incident?sysparm_query=u_azlocal_dedupe_key=<hash>^state!=6^state!=7`, and at typical fleet sizes (low thousands of clusters) it must be index-served.
5. For `u_azlocal_source`, set **Default value** to `AzLocal.UpdateManagement` so manual record creation (if it ever happens) still tags correctly.
6. Optional: add the five new columns to the default incident form view via **Configure -> Form Layout** so operators see them when looking at a ticket.

When an Update Set XML ships in a later release, importing it will be idempotent: the manual fields you create now will be reused.

### 3.3 Create an assignment group

`AzureLocal-Ops` (or whatever you set in `defaults.assignmentGroup`). New tickets are routed here so existing on-call rotations work unchanged.

---

## 4. Pick a secret source

The connector reads three secrets at run time: `clientId`, `clientSecret`, and (cosmetically) `instanceUrl`. Two supported sources:

### 4.1 Azure Key Vault (recommended)

```yaml
secrets:
  source: keyvault
  keyvaultName: corp-prod-kv-01
  servicenow:
    clientId:     sn-azlocal-clientid       # bare name resolved in corp-prod-kv-01
    clientSecret: sn-azlocal-clientsecret
    instanceUrl:  env://ITSM_SN_INSTANCE_URL # never a secret, kept here for parity
```

Grant the pipeline service principal **Key Vault Secrets User** on the vault scope:

```powershell
az role assignment create \
    --role "Key Vault Secrets User" \
    --assignee "<sp-object-id>" \
    --scope   "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/corp-prod-kv-01"
```

No extra Azure Key Vault access policies are needed beyond this RBAC. The connector reuses the **same** Az session the rest of the module uses, so no extra service principal management.

### 4.2 CI-native secrets (fallback for users without Key Vault)

```yaml
secrets:
  source: envvar
  servicenow:
    clientId:     env://ITSM_SN_CLIENT_ID
    clientSecret: env://ITSM_SN_CLIENT_SECRET
    instanceUrl:  env://ITSM_SN_INSTANCE_URL
```

Then in your pipeline YAML, surface the GitHub / Azure DevOps secrets as environment variables on the ITSM step. See [`../Automation-Pipeline-Examples/`](../Automation-Pipeline-Examples/) for working YAML.

> **Never put a raw secret in the config file.** The only literal-value form is `literal://<value>` and it is rejected unless the caller passes `-AllowLiteral` (used internally for `instanceUrl`, which is not a secret).

> **Secret memory residency:** once `Resolve-AzLocalItsmSecret` reads a value out of Key Vault or an environment variable it materialises that value as a normal `[string]` inside the PowerShell session for the duration of the OAuth `client_credentials` token grant and the subsequent ServiceNow table calls. The connector does not load these values into `[SecureString]`, because the ServiceNow REST and OAuth surfaces require a plaintext POST body. This is comparable to the way most CI/CD secrets are handled at run time, but worth knowing: the secret will be reachable to anything that has process-memory access to the pipeline runner. Mitigations baked into the module are (1) the secret is never echoed - all log/error/throw paths route through `ConvertTo-ScrubbedCliOutput`; (2) URIs are redacted via the `(client_secret|access_token|password)=[^&]+ -> $1=***` rule before being logged; (3) the temp body files used by `az rest` PATCH callers are deleted in `finally` blocks. Keep your runner host trusted, rotate ServiceNow OAuth client secrets, and prefer Key Vault over env-vars wherever the runner supports it.

---

## 5. Author the trigger matrix

Drop a file at `./.itsm/azurelocal-itsm.yml` in the consumer repo. The full schema is in [`ITSM-Config-Reference.md`](./ITSM-Config-Reference.md). A minimum-viable matrix is:

```yaml
schemaVersion: 1
secrets:
  source: keyvault
  keyvaultName: corp-prod-kv-01
  servicenow:
    clientId:     sn-azlocal-clientid
    clientSecret: sn-azlocal-clientsecret
    instanceUrl:  env://ITSM_SN_INSTANCE_URL
defaults:
  itsmTarget: ServiceNow
  assignmentGroup: AzureLocal-Ops
triggers:
  Failed:             { raiseTicket: true,  severity: 2, category: 'Cluster update failure' }
  Error:              { raiseTicket: true,  severity: 2, category: 'Cluster update failure' }
  HealthCheckBlocked: { raiseTicket: true,  severity: 3, category: 'Pre-update health resolution' }
  SideloadedBlocked:  { raiseTicket: true,  severity: 4, category: 'Operator action: stage sideloaded payload' }
  ExcludedByTag:      { raiseTicket: false }   # operator-set UpdateExcluded=True; opt-in if you want a per-run audit ticket
  ScheduleBlocked:    { raiseTicket: false }   # self-resolves; opt-in if desired
  Skipped:            { raiseTicket: false }
  NotReady:           { raiseTicket: false }
  # --- v0.7.70 Phase D: fleet-health-failure statuses ---
  # Get-AzLocalFleetHealthFailures emits Severity = Critical / Warning / Information.
  # Critical-first sort means the highest-impact rows are processed first.
  Critical:           { raiseTicket: true,  severity: 1, category: 'Cluster health: critical failure' }
  Warning:            { raiseTicket: true,  severity: 3, category: 'Cluster health: warning' }
  Information:        { raiseTicket: false }
```

A ready-to-copy version with comments lives at [`../Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml`](../Automation-Pipeline-Examples/.itsm/azurelocal-itsm.yml).

---

## 6. Validate before you wire it into a pipeline

Run these two probes from any host that has the module + an Az session pointed at the same tenant the pipeline will use:

```powershell
Import-Module ./AzLocal.UpdateManagement.psd1 -Force
$cfg = Get-AzLocalItsmConfig -Path ./.itsm/azurelocal-itsm.yml
$cfg.SchemaVersion              # -> 1
$cfg.Triggers['Failed']         # -> normalised hashtable

Test-AzLocalItsmConnection -Config $cfg | Format-Table Step, Pass, Message
# Expected output: 4 rows all Pass=True
#   Resolve instanceUrl   True   https://yourco.service-now.com
#   Resolve OAuth secrets True   clientId + clientSecret resolved.
#   OAuth token grant     True   expires_in=1800s
#   Incident table read   True   GET incident?sysparm_limit=1 succeeded.
```

If any step shows `Pass=False`, fix that step before enabling the pipeline.

#### What a failure looks like

A typical first-time-setup failure surfaces as:

```
Step                  Pass  Message
----                  ----  -------
Resolve instanceUrl   True  https://yourco.service-now.com
Resolve OAuth secrets True  clientId + clientSecret resolved.
OAuth token grant     True  expires_in=1800s
Incident table read   False HTTP 403 Forbidden - GET /api/now/table/incident?sysparm_limit=1. Body: { "error": { "message": "User Not Authorized", "detail": "..." } }
```

The first three rows passing tells you OAuth and the secret pipeline work. The fourth-row 403 always means the ServiceNow user backing the OAuth client (Section 3.1.5) is missing the `itil` role. Fix the role, re-run the probe.

Other shapes worth recognising:

- **HTTP 401** on step 4 (token issued, then immediately rejected on the read) almost always means the OAuth Entity Profile is wired to a disabled user. Re-enable the user, regenerate the secret if you suspect rotation.
- **HTTP 200 but no body fields** is harmless - the probe only asserts a 2xx + a JSON envelope; field-presence checks are deferred to a follow-up phase.
- **Operation timed out** at step 3 with a `.service-now.com` URL usually means a proxy in the agent's outbound path is intercepting OAuth. Open the proxy or pin the agent to a route that hits ServiceNow directly.

---

## 7. Dry run against a real JUnit file

Once `Test-AzLocalItsmConnection` is all-green, run `New-AzLocalIncident` in `-DryRun` mode to see what would be ticketed without making any HTTP writes:

```powershell
$cfg = Get-AzLocalItsmConfig -Path ./.itsm/azurelocal-itsm.yml

New-AzLocalIncident `
    -InputArtifactPath ./artifacts/update-results.xml `
    -Config            $cfg `
    -RunMetadata       @{ Platform='manual'; RunId='dryrun-001'; RunUrl='n/a' } `
    -DryRun `
    -ExportPath        ./artifacts/itsm-dryrun.csv |
  Format-Table ClusterName, Status, Action, Severity, DedupeKey -AutoSize
```

`Action` will be one of: `Skipped` (status not raised by matrix), `DryRun` (would have created), `DedupedToExisting` (existing open incident found - DryRun still queries because Phase 1 dedupe is read-only), or `Created` / `CreateFailed` (only outside DryRun).

> **WhatIf vs DryRun**: `-DryRun` skips ALL HTTP writes. `-WhatIf` (PowerShell-native, via `SupportsShouldProcess`) still authenticates and de-duplicates - it only blocks the final `POST /incident` write.

---

## 8. Wire into the pipeline

The example pipelines under [`../Automation-Pipeline-Examples/`](../Automation-Pipeline-Examples/) ship the connector in **five** places:

| Pipeline | Trigger source | JUnit input | Default behaviour |
|---|---|---|---|
| `fleet-connectivity-status.yml` (Monitor: 1) | `Get-AzLocalFleetConnectivityStatus` (Critical / Warning Arc-machine / ARB / NIC / cluster connectivity failures) | `./reports/fleet-connectivity-status.xml` | **v0.7.76+**, default OFF |
| `apply-updates.yml` (Update: 3) | `Get-AzLocalUpdateRunFailures` (live, from the run that just executed) | `./reports/update-results.xml` | Wired since v0.7.4 |
| `fleet-update-status.yml` (Monitor: 3) | `Get-AzLocalUpdateRunFailures -State Failed -OnlyUnresolved` (fleet, last 30 days) | `./reports/fleet-update-status.xml` | **v0.7.70 Phase D**, default OFF |
| `fleet-health-status.yml` (Monitor: 2) | `Get-AzLocalFleetHealthFailures -View Detail` (Critical-first) | `./reports/fleet-health-status.xml` | **v0.7.70 Phase D**, default OFF |
| `monitor-updates.yml` (Update: 4) | In-flight failures and configured long-running conditions | `./reports/update-monitor.xml` | Default OFF |

All five are gated on `raise_itsm_ticket` (a `workflow_dispatch` choice or pipeline parameter, default `false`). Use `itsm_dry_run` to preview ticket payloads before enabling creation; use `itsm_force_create` only when intentionally bypassing dedupe.

Key points from the wired step (full YAML in the example files):

```yaml
- name: Raise ITSM tickets
  if: ${{ github.event.inputs.raise_itsm_ticket == 'true' }}
  shell: pwsh
  env:
    # BEGIN-AZLOCAL-CUSTOMIZE:itsm-secrets
    ITSM_SN_INSTANCE_URL:  ${{ secrets.ITSM_SN_INSTANCE_URL }}
    ITSM_SN_CLIENT_ID:     ${{ secrets.ITSM_SN_CLIENT_ID }}
    ITSM_SN_CLIENT_SECRET: ${{ secrets.ITSM_SN_CLIENT_SECRET }}
    # END-AZLOCAL-CUSTOMIZE:itsm-secrets
  run: |
    Import-Module ${{ env.MODULE_PATH }}/AzLocal.UpdateManagement.psd1 -Force
    $cfg = Get-AzLocalItsmConfig -Path "${{ github.event.inputs.itsm_config_path }}"
    New-AzLocalIncident `
        -InputArtifactPath ./reports/fleet-health-status.xml `
        -Config $cfg `
        -RunMetadata @{
            Platform = 'github'
            RunId    = $env:GITHUB_RUN_ID
            RunUrl   = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
        } `
        -DryRun:([bool]::Parse($env:INPUT_ITSM_DRY_RUN)) `
        -ExportPath      ./reports/itsm-results.csv `
        -ExportJUnitPath ./reports/itsm-results.xml
```

- **Secrets are mapped via `env:`** on the step, not passed on the PowerShell command line. The module picks them up via `env://NAME` references in the config file. This keeps secret values off process listings, off the rendered step inputs, and out of CI logs.
- **`BEGIN-AZLOCAL-CUSTOMIZE:itsm-secrets` / `END-AZLOCAL-CUSTOMIZE:itsm-secrets` markers** wrap the secret bindings. `Update-AzLocalPipelineExample` preserves everything inside those markers across module upgrades, so operator-side secret remapping survives a `Update-AzLocalPipelineExample` run.
- The step writes **two** artefacts (`itsm-results.csv` for humans, `itsm-results.xml` for `dorny/test-reporter` / `PublishTestResults@2`). Both upload happens unconditionally if the step ran, including in `-DryRun`, so an audit trail exists either way. The ADO Publish task uses `azlocal-fleet-*-itsm-results_$(stamp.artifactStamp)` to match the v0.7.66 timestamped-artifact convention.
- The Azure DevOps mirror is the same shape with `AzureCLI@2` + a `- group: AzureLocal-ITSM-Secrets` variable group (kept commented out by default so the example file loads cleanly for users who have not yet wired the variable group).

The first production run should keep `raise_itsm_ticket=false` (or set `itsm_dry_run=true`) and inspect the CSV / JUnit artefact before flipping the switch.

---

## 9. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Test-AzLocalItsmConnection` step 1 fails with `not a recognised form` | A secret reference is malformed. | Confirm `kv://<vault>/<secret>` / `env://<NAME>` / bare-name format. Bare names need `secrets.source: keyvault` + `keyvaultName`. |
| Step 1 succeeds, step 2 fails with `Failed to read Key Vault secret` | Service principal lacks RBAC on the vault. | Grant `Key Vault Secrets User`. See Section 4.1. |
| Step 3 fails with `ServiceNow OAuth response did not contain an access_token` | Wrong client_id / client_secret, or the OAuth app is restricted to a different grant type. | Re-issue the secret in ServiceNow; ensure `Application Registry -> Auth Scope` allows the API endpoints used. |
| Step 4 fails with HTTP 403 | The ServiceNow integration user lacks incident-table access. | Grant the dedicated integration user the `itil` role and verify no additional ACL blocks the required rows; do not grant `admin`. |
| Connector creates a new ticket every run for the same problem | Custom field `u_azlocal_dedupe_key` not installed, so `FindByDedupe` always returns empty. | Install the custom fields (Section 3.2). |
| `Action='Skipped'` for a status you wanted to ticket | Status not in `triggers`, or `raiseTicket: false`. | Add an entry with `raiseTicket: true`. |
| `Action='CreateFailed'` with rate-limit messages | ServiceNow per-instance throttle (default 100 req/min). | The HTTP layer honours `Retry-After` automatically; if it still fails, lower the concurrent cluster count on the run or contact your SN admin. |

For deeper traces, run the step with `-Verbose`. The HTTP layer logs every attempt and retry; secret values in URLs are redacted.

---

## 10. Security model summary

- **No raw secrets ever live in config or on disk.** All secrets are read from Key Vault or environment variables at run time. The token is held in memory only.
- **The ServiceNow instance URL is not a secret**, but it identifies the tenant. The example config exposes it as `instanceUrl: env://ITSM_SN_INSTANCE_URL` so a tenant migration only needs a CI-secret rotation rather than a config-file change, and so the value is consistent with how the OAuth secrets are wired. The connector treats it as cosmetic for redaction purposes (instance hostnames are not stripped from `Verbose` logs - bearer tokens are) but never persists it.
- **Bearer tokens are redacted** in verbose logs (URL query and header values).
- **All free-text inputs** (cluster names, error text) are **HTML-escaped** when rendered into ticket descriptions to defend against ITSM-side HTML injection. Titles use plain text (no escape needed; ServiceNow `short_description` is plain text).
- **TLS 1.2+** is enforced before every HTTP call.
- **CSV-injection sanitisation** on inputs is unchanged (already present from v0.7.0).

Full security review: [`ITSM-Connector-Plan.md` Section 11](./ITSM-Connector-Plan.md).
