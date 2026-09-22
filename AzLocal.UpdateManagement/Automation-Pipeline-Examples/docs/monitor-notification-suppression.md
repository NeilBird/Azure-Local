# Maintenance Notification Suppression

Available in the v0.9.39 candidate. **Strictly opt-in; disabled by default.**
This feature suppresses action-group notifications during cluster update installation.
It does not disable alert evaluation, existing alert processing rules, Insights,
Log Analytics collection, or the AzureEdgeAlerts extension.

## Enable

After completing the RBAC and pilot checks below, add this top-level setting to
your consumer repository's `config/fleet-settings.yml`:

```yaml
schemaVersion: 6
suppressMonitorNotificationsPerClusterDuringUpdates: true
```

Keep existing settings and schema declarations; do not add a second schemaVersion.
The setting accepts only unquoted `true` or `false`. Duplicate declarations are
rejected. Missing files, missing settings, commented settings, and `false` preserve
existing behavior. The bundled starter remains fully commented and shows `false`.
The earlier proposed name `disableMonitorAlertsPerClusterDuringUpdates` is not the
implemented setting: notifications are suppressed, not alert rules disabled.

`Get-AzLocalFleetSettings` resolves `AZLOCAL_FLEET_SETTINGS_PATH` first, otherwise
`./config/fleet-settings.yml`. Use the same settings path for apply, retry, and
monitoring runners. Existing consumer files are preserved by the template copier;
activate the opt-in manually. `Update-Module-And-Pipelines.ps1` automatically
migrates supported older fleet settings to schema 6 through the module updater,
backing up exact original bytes as `config/fleet-settings_v<old>.bak.yml`.
Existing v5 values, comments, section order, and line endings are preserved;
missing suppression and renewal options are appended as commented defaults.
Existing explicit values are not overwritten, and validation failure restores
the original bytes. No change to the apply schedule schema is required.

The setting applies to clusters admitted by the existing command and fleet scope,
including explicit cluster targeting. It is not a per-cluster tag opt-in. For a
pilot, use a dedicated settings file and a single explicit cluster resource ID.
Only installation and failed-update retry activate suppression. Sideload copying,
import, preparation-only runs, and `-WhatIf` do not create suppression resources.
`-Force` does not bypass the suppression requirement.

## Lifecycle And Timing

1. After eligibility checks and approval, the apply command creates a dedicated
   `Microsoft.AlertsManagement/actionRules` resource in the cluster's resource
   group, using API version `2021-08-08`, location `Global`, and an exact cluster
   resource scope. Its only action is `RemoveAllActionGroups`.
2. The rule name is `azlocal-update-` plus a deterministic hash of the cluster ID.
   Ownership tags record the module, cluster ID, update name, operation ID, and
   creation UTC time. The cluster receives `UpdateMonitorSuppression` (operation
   ID) and `UpdateMonitorSuppressionUntil` (UTC expiry).
3. The first eligible invocation returns `SuppressionPending`, without applying
   the update. Azure documents up to 30 minutes of processing-rule propagation.
   A subsequent invocation at least 30 minutes later rechecks the rule and all
   normal start gates. The command does not sleep or schedule that next invocation.
4. Ensure the apply pipeline fires again during an eligible update start window.
   A short window or a once-daily cron may defer installation until a later day.
   The 30-minute allowance is a propagation precaution, not delivery verification.
5. Suppression initially lasts 48 hours from rule creation, not installation start.
   With renewal off, that expiry is fixed. Installation is blocked when 30 minutes
   or less remain. Separately opt-in renewal below can extend an active update's
   window before expiry, subject to a maximum total duration.
6. Normal `Get-AzLocalUpdateRuns` reconciliation checks marked clusters using fresh
   ARM update-run reads. Matching runs must start at or after the recorded rule
   creation and belong to the recorded update. Suppression is removed when the
   matching attempts are terminal (`Succeeded`, `Failed`, `Canceled`, `Cancelled`),
   with no matching nonterminal attempt. An older run cannot remove a new window.
7. Cleanup also removes expired owned rules and their cluster markers. It is
   independent of `UpdateVersionInProgress` removal and works after failure. A
   retry of a completed attempt must establish a fresh suppression window first;
   waiting does not consume the one-time retry guard.

### Optional Renewal For Long Updates

To enable renewal, use these root-level settings in the same fleet settings file
on apply, retry, and monitoring runners:

```yaml
schemaVersion: 6
suppressMonitorNotificationsPerClusterDuringUpdates: true
renewMonitorSuppressionDuringUpdates: true
monitorSuppressionMaxTotalHours: 168
```

Both booleans default to `false` and require unquoted `true` or `false`. The total
maximum defaults to `168` hours (7 days) and accepts an unquoted integer from `49`
to `720` (30 days). Duplicate declarations are rejected. Older runtime schemas
remain supported without these settings; all three options require schema 6.

On each reconciliation, the helper first checks for terminal attempts or expiry.
Only an **enabled, owned rule** with **six hours or less remaining** can renew.
A fresh ARM read must show an `InProgress` run for the exact recorded cluster and
update, started at or after the original rule creation and not in the future.
Missing, older, unknown-state, or unreadable runs cannot authorize an extension.
Both suppression and renewal must still be opted in on that runner.

Renewal sets expiry to the earlier of **48 hours from the current check** and the
**original creation time plus the maximum total hours**. The rule's start time,
operation ID, update identity, exact scope, and action remain unchanged. The cap
is recorded in `RenewalMaxExpiresUtc` when created with renewal enabled, or on
the first renewal of an existing unrenewed rule. `RenewalExpiresUtc` records the
expected schedule end. Increasing YAML limits cannot raise that operation's
recorded cap. A lower limit restricts later extensions but does not shorten an
already-authorized window. Do not edit these metadata tags or the schedule.

Keep **Update: 4 - Monitor Updates** running at least hourly and keep the cluster
in its scope. Azure rule changes can take up to 30 minutes to propagate; six hours
is a renewal opportunity, not a delivery guarantee. If checks miss expiry, or the
maximum is reached, notifications can resume even while the update continues.
**Expired rules are never renewed or recreated by monitoring.** Their resources
and markers are cleaned up; the update itself is not stopped or restarted.

Turning either opt-in off prevents further extensions, but existing suppression
lasts until matching terminal cleanup or its current expiry. If monitoring stops,
Azure still ends suppression at the last saved expiry without a runner. A failed
renewal is reported for investigation/retry; if Azure accepted the rule update but
the cluster expiry-tag write failed, the next reconciliation repairs that marker
without unnecessarily extending the rule again. `-WhatIf` performs no writes.

Keep **Update: 4 - Monitor Updates** running for the affected clusters. Its
`Export-AzLocalUpdateRunMonitorReport` command performs suppression reconciliation
for marked inventory entries, even with `-SkipWhenIdle` and no update runs. It
retains the pipeline's existing behavior of not resetting sideload tags.

### Pipeline summary evidence

The apply pipeline's **Cluster Actions** table includes **Alert Suppression**:
`Enabled` means the owned rule was confirmed before starting the update, `N/A`
means suppression was opted out (or the operation was preparation-only), and
`Pending` means installation was deferred. Historical results without this field
show `Not recorded`; current settings are not used to reinterpret earlier runs.

Update: 4 adds **Alert Suppression Actions** when it checks marked clusters. The
table shows the cluster, action, expiry in UTC, and reason **during this monitoring
run**, not a permanent cluster state:

| Action | Meaning |
| --- | --- |
| Extended | Renewal PUT and expiry-marker write succeeded. |
| Removed | Owned-rule DELETE and marker cleanup succeeded after terminal runs or expiry. |
| Active / Unchanged | The owned rule is enabled and unexpired; no extension occurred. |
| Limit reached | A current active run is eligible for renewal, but the total-duration limit permits no further extension. |
| Marker cleared | The rule was already absent; stale markers were removed. |
| Disabled rule | The owned rule exists but is disabled; it is not suppressing notifications. |
| Failed | Reconciliation failed; investigate the reason and rerun monitoring. |

Successful actions reflect successful API responses, not an independent readback
or a notification-delivery test. A failed action may have partially completed
(for example, renewal succeeded but its expiry-marker write failed); any displayed
expiry is last known, not a guarantee. `WhatIf` is never reported as a successful
change. Cleanup remains visible after opt-out while markers remain. No section
is shown when there are no marked clusters to check.

The same evidence is saved in `update-monitor-suppression.csv` and
`update-monitor-suppression.json`, including cluster/resource IDs, rule ID,
checked-at UTC, action, status, expiry, and reason. Both pipeline platforms already
upload these through their report-directory artifact step. Empty runs overwrite
these files with an empty dataset to avoid stale evidence. Custom CSV report names
use the same basename with the `-suppression` suffix. `-PassThru` also exposes
`SuppressionActions`, `SuppressionCsvPath`, and `SuppressionJsonPath`.

Suppression actions are separate from update progress: existing counters, update
CSV rows, JUnit classifications, and ITSM triggers are unchanged. Suppression
failures appear in this table and the warning log, not as failed update runs.

For direct `Get-AzLocalUpdateRuns` calls, the existing `-SkipSideloadedReset`
switch also skips suppression reconciliation; `-Raw` returns before it. Do not
use either on a direct cleanup run. A single-cluster query with no runs does not
perform the existing auto-reset phase; use the fleet resource-ID form instead:

```powershell
Get-AzLocalUpdateRuns -ClusterResourceIds @($clusterResourceId) -Latest -PassThru
```

If the cluster leaves the monitored ring or fleet filter, scheduled cleanup may
not visit it. Keep it in scope until cleanup completes. Never remove markers as
a substitute for removing the rule. Expiry is the fallback when monitoring stops.

**Serialize apply, retry, and manual maintenance operations for the same cluster.**
Cluster tags and the processing-rule API do not constitute a distributed lock.
Do not run independent apply/retry pipelines concurrently against the same cluster.
Ownership checks detect mismatches but are not transactional concurrency control.
Serialize reconciliation with those operations too; a deterministic resource name
does not make simultaneous creation and deletion atomic. Suppression can begin
during the propagation wait, even if a later eligibility check prevents installation.

Check the subscription's current Azure Monitor processing-rule quota before
enabling this across a large fleet. Each cluster with an outstanding maintenance
window consumes a rule; expired resources still require cleanup. Existing rules
also count against service limits. Creation failures block opted-in installation.

## RBAC

The existing [Azure Stack HCI Update Operator (custom) role](../azlocal-update-management-custom-role.json)
is unchanged. Users who leave suppression off need no additional permissions.

The optional [Azure Stack HCI Monitor Suppression Operator (custom) role](../azlocal-monitor-suppression-custom-role.json)
adds exactly these management-plane permissions:

| Permission | Purpose |
|---|---|
| `Microsoft.AlertsManagement/actionRules/read` | Inspect the owned rule and verify scope, ownership, and expiry |
| `Microsoft.AlertsManagement/actionRules/write` | Create and optionally renew the bounded maintenance rule |
| `Microsoft.AlertsManagement/actionRules/delete` | End suppression after terminal state or expiry |

Cluster reads, update-run reads, resource-group reads, Resource Graph access, and
`Microsoft.Resources/tags/read` and `/write` remain supplied by the existing role.
No Log Analytics data access, extension write/delete, action-group write, or
metric/log alert-rule write permissions are required for suppression.
Renewal uses the same permissions; the monitoring identity must have the companion
role's write action as well as read/delete and the existing cluster tag permissions.

### Recommended: Companion Role

1. Have an RBAC administrator replace `<your-mg-id>` in the optional JSON with the
   appropriate management-group ID, or use subscription assignable scopes.
2. Create the custom role through your normal role-definition process. The file
   uses CLI/PowerShell role-definition format, not the Azure portal's wrapped ARM
   JSON format; use the portal Permissions editor when creating it interactively.
3. Assign it to the OIDC service principal or managed identity at each participating
   **cluster resource group**, where the processing rule is created. A grant at
   the cluster resource alone does not cover its sibling processing rule.
4. Give the apply/retry identity read/write/delete. A separate cleanup identity can
   use a narrower role with read/delete plus existing cluster tag/read permissions.
   RBAC role creation and assignment require an administrator; the runtime role
   intentionally cannot grant itself permissions.
5. Ensure `Microsoft.AlertsManagement` is registered in the target subscription
   and Azure Policy permits the rule type, `Global` location, and ownership tags.
   The module does not register providers or change Azure Policy.

OIDC and managed identity are authentication methods; both require the same RBAC
actions. Use the service principal's object ID, not an application/client ID, when
selecting the assignee. No new credentials or Azure CLI extension are needed;
the implementation uses the existing authenticated ARM REST helper.

The existing DINE role-assignment policy does not automatically assign this new
companion role. Extend your deployment policy explicitly if granting it at scale.
Resource-group assignment is preferred over subscription-wide assignment: these
permissions authorize all processing rules in the assigned scope, not only rules
with the module's tags. Ownership restrictions are application safeguards, not RBAC.

### Alternative: Extend Your Existing Custom Role

Add the three actions above to the existing role's `Actions` array through your
approved role-definition update process. Preserve its role-definition GUID and
all existing actions/scopes. Existing assignments then inherit the extra powers;
this broadens access for every assignee of that role. Do not replace the update
operator's definition with the companion JSON, which contains no update rights.
Prefer a companion role when only some fleets or identities opt in.

`Monitoring Contributor` also covers these operations but grants substantially
more monitoring privileges and is not the least-privilege recommendation.

## Coverage And Observability

Azure Local OS Health Service faults are forwarded by `AzureEdgeAlerts` directly
to Azure Monitor; they do not require Log Analytics or customer-authored alert
rules. An enabled suppression rule takes precedence over rules adding action
groups. Existing health faults and alert history remain visible.

Suppression removes **all action groups** from matching alerts, including ticketing
and webhook actions. It does not suppress Azure Service Health alerts. Exact
cluster targeting does not automatically cover Arc nodes, VMs, or alerts whose
target is a Log Analytics workspace. Confirm actual alert target IDs during the
pilot; do not widen scope to a shared resource group just to catch them.
Notifications suppressed during the window are not replayed when it ends.
Keep update-failure signaling outside the suppressed action-group path.

Apply/retry results show `SuppressionPending`; pipeline counters and JUnit classify
it as skipped/deferred. Monitoring logs show suppression status and cleanup warnings.
Cluster tags expose the operation ID and expiry; the owned rule stores durable
identity and schedule across runners. There are no misleading "alerts disabled"
counts because no existing alert rules or processing rules are disabled.

## Failure Handling And Rollback

| Situation | Behavior and operator action |
|---|---|
| Missing permission, policy denial, unreadable rule | Installation fails closed when opted in. Resolve the reported error before retrying. |
| Creation fails after marker write | Update is not started. Monitoring clears markers if a fresh read confirms the rule is missing. |
| Apply request fails or times out without a visible run | Acceptance can be ambiguous. Retain bounded suppression until a terminal run or expiry; inspect Azure before manual removal. |
| Completed update but cleanup fails | Keep markers for retry; inspect cleanup warnings and restore the monitoring identity's access. |
| Rule ownership, scope, schedule, or operation marker differs | Do not overwrite or delete it automatically. Investigate operator changes or overlapping automation. |
| Rule disabled by an operator | Installation is blocked rather than silently re-enabling it. |
| Renewal write fails | Check monitoring warnings and Azure state. Retry before the current expiry; do not assume an error means Azure did not accept the write. |
| Runner stops, cluster removed from scope, or no run materializes | Suppression ends at the last saved expiry without runner intervention (48 hours initially, potentially later after renewal). Resources and tags still need reconciliation. |
| Total maximum reached while update is active | No further renewal. Notifications can resume at expiry; the update continues and monitoring cleans up the rule and markers. |

To opt out, set the flag to `false` or remove it. This stops creation immediately;
it does not abandon outstanding owned rules. Continue monitoring until those
rules are reconciled, then remove the optional role assignment if no longer needed.
For urgent recovery, use Azure Monitor's Alert processing rules view to inspect
and disable/delete **only the exact owned rule**, then run reconciliation to
clear its cluster markers. Rule changes are not an instantaneous-delivery guarantee.

## Pilot Acceptance

Use an explicitly approved test cluster and identity before production rollout:

1. Verify `false`, omitted settings, preparation, and `-WhatIf` make no suppression
   writes. Confirm the base role alone still supports opted-out workflows.
2. Grant the companion role on the test cluster resource group and enable the flag.
3. Verify the exact scope, UTC schedule, ownership tags, and pending status. No
   update should start on the initial creation run.
4. After propagation, generate an approved test alert and inspect its target and
   History tab to verify suppression. Check an unrelated resource still notifies.
5. Exercise an approved update and verify terminal success/failure cleanup, retry
   behavior, opt-out with an outstanding rule, permission failures, and expiry.
6. With renewal explicitly enabled, verify near-expiry extension for a matching
   active run, original-cap enforcement, no extension after opt-out, recovery
   after denied writes, and expiry without revival when monitoring misses it.
7. Verify no existing rule, extension, Insights setting, or workspace was modified.

The standalone `Reset-AzLocalSideloadedTag` command shares the same marked-cluster
reconciliation path. It does not bypass suppression ownership or terminal checks.

Local mocked tests verify orchestration, not Azure propagation or delivery. Live
write-enabled pilot acceptance remains required; the read-only live suite does
not establish those guarantees.

## References

- [Azure Local health alerts](https://learn.microsoft.com/en-us/azure/azure-local/manage/health-alerts-via-azure-monitor-alerts)
- [Azure Monitor processing rules, propagation, and suppression](https://learn.microsoft.com/en-us/azure/azure-monitor/alerts/alerts-processing-rules)
- [Action rule API schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.alertsmanagement/2021-08-08/actionrules)
- [Monitoring Contributor permissions](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/monitor#monitoring-contributor)