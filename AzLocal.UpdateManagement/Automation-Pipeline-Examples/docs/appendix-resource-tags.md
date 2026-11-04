# Appendix: Azure resource tags

This reference covers Azure resource tags read or written by
`AzLocal.UpdateManagement`. These are not Git tags, workflow inputs, or Pester
test tags. Return to the [CI/CD guide](../README.md).

The inventory below covers the v0.9.40 implementation: **12 cluster tags** on
`Microsoft.AzureStackHCI/clusters` and **seven rule tags** on module-owned
`Microsoft.AlertsManagement/actionRules`. Optional features do not create their
tags on every cluster. Customer-defined admission tags have no fixed names and
are described separately.

- [Operator configuration](#operator-configuration)
- [Sideload and execution state](#sideload-and-execution-state)
- [Attempt and retry state](#attempt-and-retry-state)
- [Monitor suppression cluster markers](#monitor-suppression-cluster-markers)
- [Monitor suppression rule tags](#monitor-suppression-rule-tags)
- [Customer-defined and legacy tags](#customer-defined-and-legacy-tags)
- [Operational guidance](#operational-guidance)
- [Implementation references](#implementation-references)

## Operator configuration

These five tags belong on the **cluster resource**. Operators own the desired
values; Config: 2 (`Set-AzLocalClusterUpdateRingTagFromCsv`, calling
`Set-AzLocalClusterUpdateRingTag`) applies them. Config: 1 inventories them and
compares configured desired values with live tags. Inventory alone does not
stamp tags.

| Tag | Value and purpose | Missing value | Lifecycle |
|---|---|---|---|
| `UpdateRing` | Non-empty ring name such as `Pilot` or `Production`; selects clusters for ring-scoped inventory, assessment, scheduling, and updates. | Excluded from ring-scoped selection, including `***`. Explicit cluster targeting does not require a ring. | Set during onboarding; change when moving a cluster between waves. No automatic expiry or cleanup. |
| `UpdateStartWindow` | UTC start windows, for example `Sat-Sun_02:00-06:00`; multiple windows use `;`. Read by scheduling gates and coverage audits. | No maintenance-window restriction on a selected cluster; other gates still apply. | Set or revise with change windows; persists across update runs. Remove explicitly to remove this restriction. |
| `UpdateExclusionsWindow` | Blackout date ranges such as `2026-12-20/2027-01-03`, comma-separated; `*` wildcards support recurring freezes. Exclusions take precedence over allowed windows. | No exclusion-window restriction. | Maintain as change-freeze policy. Expired entries remain tagged; the module does not delete them. |
| `UpdateExcluded` | `True` / `False` / `1` / `0`, case-insensitive. `True` or `1` is an operator hold: apply returns `ExcludedByTag`. | Config: 2 defaults an absent tag to `False`; absence alone is not a hold. | Operator sets the hold and explicitly releases it with `False`. No automatic reset after a successful run. |
| `UpdateAuthAccountId` | One to three digits, for example `001`, matching a row in `sideload-auth-map.csv`; selects the Key Vault credential mapping used by sideload planning/remoting. It is an identifier, not a credential. | The cluster is not selected by the auth-tag-based sideload planner. | Operator supplies the optional CSV value; Config: 2 writes it. Preserve leading zeros and keep the map synchronized. No automatic allocation, expiry, or reset. |

**CSV semantics:** a blank optional cell means preserve/unmanaged, not delete.
Use explicit values to reconcile optional configuration. `UpdateRing` is required
for rows managed by Config: 2. Use the documented `-Force` / pipeline force option
when intentionally overwriting an existing ring, and inspect the dry-run tag
deltas before applying. Do not use CSV blanks to clear maintenance restrictions.
The optional auth column can be exported with
`Get-AzLocalClusterInventory -IncludeSideloadColumns`.

`UpdateStartWindow` limits when installation can **start**, not its duration.
An update already running is not stopped when the window closes. Preparation-only
work has separate scheduling policy; these tags are not a blanket ban on all
preparation activity. See the [schedule guide](apply-updates-schedule.md) and
[CI/CD scheduling runbook](../README.md#8-scheduling-maintenance-windows-and-change-freeze-periods).
Malformed non-empty windows are blocked by default; use the schedule test cmdlet
to validate changes rather than relying on override switches.

See [Config: 2 setup](../README.md#63-apply-tags) and the
[sideload authentication map](sideload.md#4-authentication).

## Sideload and execution state

These three tags also live on the **cluster resource**. Do not import inventory
state columns as desired state: Config: 2 manages the five configuration tags
above, not these state tags.

| Tag | Value and reader | Writer and lifecycle | Operator handling |
|---|---|---|---|
| `UpdateSideloaded` | Boolean text (`True`, `False`, `1`, `0`, case-insensitive). Apply reads this gate; false returns `SideloadedBlocked`. Absent/empty means no boolean sideload gate. | `Invoke-AzLocalSideloadUpdate` closes the gate before staging and opens it after successful import. Matching successful-run reconciliation sets it back to `False`. | Manual sideload workflows may set it, but only open it after staging/import is verified. Removing it opts out of this gate; it does not certify content or remove other gates. |
| `UpdateSideloadedVersion` | Exact staged update name, for example `Solution12.2604.1003.209`. Apply checks it against the selected update and current allow-list. | Sideload staging clears the previous value; successful import writes the new update name. Matching reset clears it along with `UpdateVersionInProgress`. | Module-managed. Do not edit it to make another update pass. `-Force` and explicit `-UpdateName` do not bypass the staged-identity/allow-list check. |
| `UpdateVersionInProgress` | Update name used to correlate a successful run with the staged/started update. It is not a live progress percentage or proof that installation is running. | Successful sideload import writes it. `Start-AzLocalClusterUpdate` also writes it after an accepted installation apply, including non-sideload installs; preparation-only success does not stamp it. Matching reset/orphan cleanup removes it. | Module-managed. A write failure after apply is a warning: installation may already have started even if this tag is missing. |

### Sideload lifecycle

1. Before staging, the automated sideload worker sets `UpdateSideloaded=False`
	 and clears `UpdateSideloadedVersion`. It does not clear the old
	 `UpdateVersionInProgress` at this point.
2. After successful import, it sets `UpdateSideloaded=True` and writes the imported
	 update name into both version tags. Failed/incomplete staging does not open
	 the gate.
3. Apply checks the boolean gate and, when present, the staged identity. Successful
	 installation apply writes `UpdateVersionInProgress` for the selected update.
4. Reconciliation requires a latest `Succeeded` run matching
	 `UpdateVersionInProgress`. It then sets `UpdateSideloaded=False` and removes
	 both version tags.

Failed, running, or missing runs preserve the gate state. A malformed boolean,
missing correlation version, or version mismatch is not automatically reset.
If the boolean tag was removed, a matching successful run can clear the orphaned
version tags without recreating the boolean tag. If the boolean is already
`False`, the version-reset path is skipped; do not assume it removes every stale
version tag.

Use `Reset-AzLocalSideloadedTag` for explicit reconciliation. Its `-Force` bypasses
the version-match requirement, **not** the requirement for a successful run and
a true sideload gate. This is different from `-Force` on apply or retry commands.

## Attempt and retry state

These two **cluster tags** are module-managed audit pointers, not an append-only
history. The writer is best-effort; absence is not proof that no action occurred.

| Tag | Purpose and writer | Lifecycle |
|---|---|---|
| `UpdateLastAttempt` | Written by `Start-AzLocalClusterUpdate` for recorded outcomes such as `HealthCheckBlocked`, `UpdateStarted`, `PreparationStarted`, and `Failed`; retry writes `UpdateRetried` or `Failed`. Update-run monitoring uses it to report attempts without a corresponding run. Not every early skip writes a tag. | A later recorded attempt overwrites it. Successful-run reconciliation clears a matching update, or a `HealthCheckBlocked` / `Failed` attempt at least one hour old when the latest run is `Succeeded`. |
| `UpdateRetryAttempted` | Written by `Invoke-AzLocalFailedUpdateRetry` with `RetryStarted` or `RetryFailed`. Either recorded outcome for the same update blocks another automatic retry with `RetryAlreadyAttempted`. Also supplies correlation evidence for suppression cleanup when a retry reuses a run. | Successful-run reconciliation clears a matching update, or a `RetryFailed` attempt at least one hour old when the latest run is `Succeeded`. A different update can replace the record on its next retry. An explicit retry `-Force` overrides the one-time guard. |

Both use this semicolon-delimited value (maximum 256 characters):

```text
<UTC timestamp>;<Outcome>;<UpdateName>;<Reason>
2026-11-03T12:00:00Z;RetryStarted;Solution12.2604.1003.209;One-time retry of failed update initiated
```

The formatter normalizes reason whitespace, replaces reason semicolons with
commas, and truncates long values. These tags contain only the latest recorded
attempt, and their timestamps do not implement automatic TTL deletion. The
one-hour cleanup exception still requires a successful latest run and an actual
reconciliation invocation. Preserve reports and logs for durable history.

Do not manually clear a retry guard simply to make a scheduled run retry again.
Review the failed update and use the explicit retry workflow when another attempt
is intentional. See [retry behavior](../README.md#85-opt-in-single-retry-of-failed-updates-failed_updates_single_retry).

## Monitor suppression cluster markers

These optional **cluster tags** are written by the private
`Invoke-AzLocalMonitorSuppression` helper used by apply/retry and monitoring.
The feature must be enabled in fleet settings; setting tags alone is not opt-in.

| Tag | Value and purpose | Lifecycle |
|---|---|---|
| `UpdateMonitorSuppression` | Operation GUID matching the owned notification-suppression rule's `OperationId`. Establishes the relationship used for reconciliation. | Written before rule creation; can be recovered from a validated existing rule. Cleared after successful rule deletion, or when reconciliation confirms the rule is already absent. |
| `UpdateMonitorSuppressionUntil` | ISO-8601 UTC expiry mirrored from the owned rule's schedule. Used in monitoring reports; this tag itself does not suppress notifications. | Initially creation time plus 48 hours. Updated on permitted renewal and synchronized when renewal metadata requires it. Cleared with the operation marker. |

Do not edit these markers to extend a window or remove them as routine cleanup.
The helper validates rule ownership, update identity, exact cluster scope, action,
and schedule before changing an existing rule. Mismatches require investigation.
If deletion fails, markers are retained for a later cleanup attempt.

## Monitor suppression rule tags

These seven tags live on the **notification-suppression rule**, not the cluster.
The rule is named `azlocal-update-<cluster-ID hash>` in the cluster's resource
group. All are module-managed and should not be manually changed.

| Tag | Value and purpose | Lifecycle |
|---|---|---|
| `ManagedBy` | Exact value `AzLocal.UpdateManagement`; ownership validation is case-sensitive for this value. | Created with the rule; retained until the rule is deleted. |
| `ClusterResourceId` | Full ARM ID of the one cluster in the rule scope. | Created with the rule; validated during ensure/reconcile; removed with the rule. |
| `OperationId` | GUID matching the cluster's `UpdateMonitorSuppression`. | Generated for a new suppression operation; retained through renewal; removed with the rule. |
| `UpdateName` | Exact update name whose run state controls reconciliation. | Fixed for that operation; retained through renewal; removed with the rule. |
| `CreatedUtc` | ISO-8601 UTC creation timestamp, also the schedule start and origin of duration limits. | Set once per operation. Renewal preserves the creation instant; deletion removes it. |
| `RenewalExpiresUtc` | ISO-8601 UTC current expiry for a renewal-enabled rule; must match the effective schedule end. | Optional. Set at creation when renewal is enabled, or introduced by a later eligible renewal; updated on extension; removed with the rule. |
| `RenewalMaxExpiresUtc` | ISO-8601 UTC absolute total-duration ceiling anchored to `CreatedUtc`. | Optional alongside `RenewalExpiresUtc`. Recorded for renewal, may be tightened by a lower configured limit, but is not extended by merely raising the setting; removed with the rule. |

Creation establishes a 48-hour suppression window and defers installation for
at least 30 minutes. Renewal is separately opt-in and requires an enabled rule,
matching `InProgress` evidence, and expiry within six hours. Extensions are
bounded by the total-duration ceiling, not an indefinite sliding window.

Reconciliation deletes an owned rule when its window expires or all matching
runs are terminal (`Succeeded`, `Failed`, `Canceled`, or `Cancelled`). This is
different from sideload/retry tag cleanup, which requires success. Schedule expiry
ends suppression even if monitoring has not yet deleted the rule or markers.
Cleanup can still run after the fleet opt-in is disabled, provided the cluster
ownership marker remains. See the
[suppression guide](monitor-notification-suppression.md) for settings, permissions,
retry correlation, and recovery procedures.

## Customer-defined and legacy tags

- `scope.clusterTagFilters` in `fleet-settings.yml` reads arbitrary
	customer-owned tags, such as `Environment=Production`. Matching is exact and
	case-insensitive: all tag pairs in a group must match, and any matching group
	admits a cluster. The module does not create, expire, or remove these tags.
	Manage them through onboarding, Azure Policy, or your enterprise tagging process;
	use stable admission tags rather than mutable module control/state tags.
- `UpdateExclusions` is obsolete since v0.7.90 and is no longer honored. Migrate
	the blackout policy explicitly to `UpdateExclusionsWindow`; it is not an alias
	and there is no automatic tag migration.
- `HasUpdateRingTag` is a generated inventory column (`Yes` / `No`), not an Azure
	tag or desired-state input. Editing it does not change ring membership.
- Other inventory/report fields, schedule YAML keys, and ITSM configuration
	values do not become Azure tags merely because they appear beside these fields.

## Operational guidance

- Put cluster-control tags on the cluster itself, not just its resource group,
	subscription, Arc machines, or resource bridge. The module reads cluster tags;
	it does not implement parent-tag inheritance.
- Keep credentials, secrets, and tokens out of tags. `UpdateAuthAccountId` is only
	a lookup key; the authentication map points to secrets held in Key Vault.
- Distinguish configuration from state. The module does not reset operator
	configuration after each update. Conversely, do not repeatedly reapply exported
	state tags from an inventory snapshot.
- `Get-AzLocalUpdateRuns` performs tag auto-reset by default; use
	`-SkipSideloadedReset` to skip that phase, including owned suppression
	reconciliation, for that command. Update-run report generation also has its
	own suppression reconciliation; do not assume every monitoring entry point is
	read-only. Tag cleanup needs appropriate write permissions.
- Tag writes use the dedicated ARM tags endpoint, preserving unrelated tags.
	Module cleanup removes named state keys rather than replacing all cluster tags.
	`Tag Contributor` plus required reads covers cluster tagging; suppression-rule
	creation/deletion needs the additional permissions in the suppression guide.
- Use dry-run output and the next live inventory to verify configuration changes.
	Removing a maintenance or exclusion tag can broaden eligibility immediately;
	clearing an audit tag does not cancel an Azure update run.

## Implementation references

These are the implementation sources used to verify the inventory and lifecycle:

- [Tag constants](../../AzLocal.UpdateManagement.psm1),
	[Config: 2 tag writer](../../Public/Set-AzLocalClusterUpdateRingTag.ps1), and
	[parallel tag worker](../../Private/Invoke-AzLocalUpdateRingTagWorker.ps1).
- [Apply gates and attempt writes](../../Public/Start-AzLocalClusterUpdate.ps1),
	[sideload worker](../../Public/Invoke-AzLocalSideloadUpdate.ps1), and
	[retry guard](../../Public/Invoke-AzLocalFailedUpdateRetry.ps1).
- [Reset decision logic](../../Private/Invoke-AzLocalSideloadedAutoResetForCluster.ps1),
	[attempt formatter](../../Private/Format-AzLocalUpdateLastAttemptTagValue.ps1), and
	[suppression ownership and lifecycle](../../Private/Invoke-AzLocalMonitorSuppression.ps1).