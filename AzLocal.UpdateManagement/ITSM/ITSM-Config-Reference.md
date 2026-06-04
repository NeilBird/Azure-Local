# ITSM Connector - Config Reference

> Module: `AzLocal.UpdateManagement` v0.7.4 (Phase 1, ServiceNow only)
> See [ITSM-Connector-Plan.md](./ITSM-Connector-Plan.md) for full design.

This file documents every field in the YAML/JSON config consumed by
`Get-AzLocalItsmConfig`. The config file is typically checked into the
consumer repo at `./.itsm/azurelocal-itsm.yml`.

## Top-level shape

```yaml
schemaVersion: 1     # required, must be 1
secrets:   { ... }   # required, see "Secrets"
defaults:  { ... }   # required, see "Defaults"
triggers:  { ... }   # required, see "Triggers"
lifecycle: { ... }   # optional (Phase 2)
mirror:    { ... }   # optional (Phase 3)
storage:   { ... }   # optional (raiseAfterConsecutiveOccurrences)
```

## Secrets

| Field | Type | Required | Notes |
|---|---|---|---|
| `secrets.source` | string | yes | `keyvault` (recommended), `envvar`, or `mixed`. |
| `secrets.keyvaultName` | string | when `source: keyvault` or `mixed` | Azure Key Vault name (no URI). |
| `secrets.servicenow.clientId` | string | yes (Phase 1) | Secret reference (see below). |
| `secrets.servicenow.clientSecret` | string | yes (Phase 1) | Secret reference. |
| `secrets.servicenow.instanceUrl` | string | yes | `https://<instance>.service-now.com` or `env://NAME`. |

### Secret reference forms

| Form | Resolution |
|---|---|
| `kv://<vault>/<secret>` | `Get-AzKeyVaultSecret` against `<vault>` (uses current `Az` session). |
| `env://<NAME>` | `$env:NAME`. Used for native GH / ADO secret fallback. |
| `<bareName>` | When `secrets.source: keyvault`, resolved as a secret in `secrets.keyvaultName`. |
| `literal://<value>` | Literal value. Only honoured when the caller passes `-AllowLiteral` (for non-secret fields like `instanceUrl`). |

## Defaults

| Field | Type | Notes |
|---|---|---|
| `defaults.itsmTarget` | string | Must be `ServiceNow` in v0.7.4. |
| `defaults.assignmentGroup` | string | Maps to ServiceNow `assignment_group`. |
| `defaults.callerId` | string | Maps to ServiceNow `caller_id`. |
| `defaults.category` | string | Cosmetic; ticket category override happens per-trigger. |
| `defaults.cmdbCi` | string | Maps to ServiceNow `cmdb_ci`. Phase 1 passes this value through verbatim; token substitution (e.g. `${cluster.resourceId}`) is planned for Phase 1.5. |
| `defaults.templates.titleTemplate` | string | Mustache template for the ticket title. |
| `defaults.templates.bodyTemplatePath` | string | Path to the Mustache template for the ticket body. Relative paths resolve against the config file. |

## Triggers

Top-level keys are JUnit `Status` values produced by `Get-AzLocalUpdateRuns` /
`Invoke-AzLocalFleetOperation` (e.g. `Failed`, `Error`, `HealthCheckBlocked`,
`SideloadedBlocked`, `ExcludedByTag`, `ScheduleBlocked`, `Skipped`, `NotReady`).

| Field | Type | Notes |
|---|---|---|
| `triggers.<Status>.raiseTicket` | bool | Required. `true` opens a ticket; `false` (default) skips. |
| `triggers.<Status>.severity` | int | 1..5; defaults to 3. Maps to ServiceNow impact/urgency per the design. |
| `triggers.<Status>.category` | string | Ticket category; overrides `defaults.category`. |
| `triggers.<Status>.mirrorTo` | list | Phase 3. Overrides `defaults.mirrorTo`. Use `[]` to suppress mirroring for this trigger. |
| `triggers.<Status>.raiseAfterConsecutiveOccurrences` | int | (Phase 1.5) Require N consecutive runs before opening a ticket. Requires `storage` to be configured. |

## Severity to ServiceNow priority

| `severity` | Impact | Urgency | Resulting SN priority |
|---|---|---|---|
| 1 (Critical) | 1 | 1 | 1 - Critical |
| 2 (High)     | 2 | 2 | 2 - High |
| 3 (Moderate) | 3 | 3 | 3 - Moderate |
| 4 (Low)      | 4 | 4 | 4 - Low |
| 5 (Planning) | 4 | 4 | 4 - Low |

## Storage (optional, for `raiseAfterConsecutiveOccurrences`)

Phase 1 ships the field-level scaffolding; the run-history store is read /
written by the Phase 1.5 follow-up. Until then, `raiseAfterConsecutiveOccurrences`
is treated as 1 (i.e. always raise on first occurrence).

| Field | Type | Notes |
|---|---|---|
| `storage.kind` | string | `blob` (default, recommended), `cicd-cache`, or `localFile`. |
| `storage.blob.accountName` | string | Storage account hosting the run-history blob. |
| `storage.blob.containerName` | string | Container name. |
| `storage.blob.blobName` | string | Blob name; tokens supported (e.g. `${pipeline.workflowName}/run-history.json`). |

## Lifecycle (Phase 2)

| Field | Type | Notes |
|---|---|---|
| `lifecycle.enabled` | bool | Whether `Sync-AzLocalIncident` should close tickets when the underlying cluster recovers. |
| `lifecycle.onSuccessAction` | string | `comment`, `resolve`, or `comment-and-resolve`. |
| `lifecycle.resolveCode` | string | ServiceNow `close_code` (required if action includes `resolve`). |
| `lifecycle.resolveNotes` | string | Mustache template for the close-out work-note. |
| `lifecycle.maxAgeDays` | int | Skip tickets older than this. Default 30. |

## Mirror (Phase 3)

| Field | Type | Notes |
|---|---|---|
| `mirror.teams.minSeverity` | int | Don't mirror triggers below this severity. |
| `mirror.teams.includeRunLogsLink` | bool | Include pipeline run URL in the Adaptive Card. |
| `mirror.slack.minSeverity` | int | Same as Teams. |
| `mirror.slack.channelOverride` | string | Optional channel override (bot token mode only). |

## Validation behaviour

`Get-AzLocalItsmConfig` throws on:

- Missing `schemaVersion`, or `schemaVersion != 1`
- Missing top-level `secrets`, `defaults`, or `triggers`
- `secrets.source` not in (`keyvault`, `envvar`, `mixed`)
- `secrets.source: keyvault` without `secrets.keyvaultName`
- `defaults.itsmTarget` not equal to `ServiceNow`
- Any `triggers.*.severity` outside the 1..5 range

It emits a warning (does not throw) when:

- No trigger has `raiseTicket: true` (in which case the connector never opens a ticket)

## Example minimal config

```yaml
schemaVersion: 1
secrets:
  source: keyvault
  keyvaultName: corp-prod-kv-01
  servicenow:
    clientId: sn-azlocal-clientid
    clientSecret: sn-azlocal-clientsecret
    instanceUrl: env://ITSM_SN_INSTANCE_URL
defaults:
  itsmTarget: ServiceNow
  assignmentGroup: AzureLocal-Ops
  templates:
    titleTemplate: "[Azure Local] {{cluster.name}} - {{trigger.category}}"
triggers:
  Failed:
    raiseTicket: true
    severity: 2
    category: "Cluster update failure"
```
